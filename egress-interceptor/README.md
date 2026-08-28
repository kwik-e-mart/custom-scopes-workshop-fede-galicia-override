# Egress Interceptor (service nullplatform)

Lado emisor del patrón S2S, empaquetado como service instalable de nullplatform. Al crear una
instancia sobre un namespace, el agente np reconcilia y deja el namespace con:

- un **`Gateway` de egreso** (clase `istio`, listener HTTP interno) que auto-provisiona su
  Deployment y su Service de Envoy;
- una **`AuthPolicy` de Kuadrant** colgada de ese Gateway, que le hace acuñar a Authorino un
  JWT de corta vida (*festival wristband*, RS256) y lo inyecta en `X-NP-Token`;
- una **`HTTPRoute` por servicio interceptado**, con el reparto local/remoto en
  `backendRefs[].weight` y el juego de headers de ruteo en un `RequestHeaderModifier`;
- un **`DestinationRule`** que origina el TLS hacia el ingreso del peer validando su cert
  contra la CA propia.

La intercepción es un **swap de selector**: el `Service` original pasa a seleccionar los pods
del Gateway (misma ClusterIP, mismo nombre, mismo puerto — el cliente no se entera) y el alias
`<svc>-local` conserva el selector real. El selector original queda guardado en la annotation
`egress-interceptor/original-selector`, que es lo que hace reversible el `delete`.

`percent` es la perilla de migración, reversible en cualquier momento.

**No hay código propio en el camino del dato.** Antes este service desplegaba un OpenResty con
Lua que firmaba y sorteaba por peso; hoy ese pod es el Envoy del Gateway. El pod que ves en el namespace es el data plane que Istio
auto-provisiona a partir del `Gateway`, no un componente de este service.

## Alcance: intra-namespace

La migración es **intra-namespace**. El interceptor actúa sobre el `Service` del namespace del
destino — la instancia se cuelga de la aplicación dueña del servicio y todas las operaciones van
con `-n $NAMESPACE`. Migrar tráfico que cruza namespaces no es parte de este service: para eso
está **Endpoint Exposer**.

Es una afirmación de alcance, no una barrera que el data plane imponga: los objetos de Istio que
se generan no llevan `exportTo`, así que un caller de otro namespace podría atravesar la ruta de
forma incidental (Gotcha #19). Si eso hay que impedirlo, es un cambio aparte.

El nombre del servicio se declara como lo invoca la app que llama: el nombre corto o cualquiera de
sus formas DNS del cluster. `build_context` las normaliza al nombre corto antes de que nada más
las vea, porque abajo de ahí el nombre se usa como **nombre de objeto** (`s2s-egress-<svc>`,
`s2s-ingress-<svc>`, `<svc>-local`), como el **Service que se hijackea** y como valor del header
`X-NP-SVC` — y los tres quieren el nombre corto.

| Se escribe | Queda |
|---|---|
| `reports` | `reports` |
| `reports.<ns>` | `reports` |
| `reports.<ns>.svc` | `reports` |
| `reports.<ns>.svc.cluster.local` | `reports` |

Cualquier otro sufijo aborta en `build_context`, antes de tocar el cluster: un namespace que no es
el del destino, un typo en `cluster.local` o un host externo. `cluster.local` va literal porque los
templates lo emiten literal en `hostnames`; un cluster con otro dominio pediría parametrizarlo en
los dos lugares a la vez.

## Dos cosas que no son obvias y rompen en silencio

**La clave de firma vive en `kuadrant-system`, no en el namespace de la app.** Kuadrant traduce
toda `AuthPolicy` a un `AuthConfig` en `kuadrant-system` sin importar el namespace de la policy,
y Authorino resuelve `signingKeyRefs` contra el namespace del `AuthConfig`. Con el Secret en el
namespace de la app el `AuthConfig` no reconcilia, el `ext_authz` falla cerrado y se cae el
camino de la app entera. Hay una consecuencia de autorización que se hereda de esto: ver el
comentario de `egress_transport.tf` en el layer.

**RSA 2048 en PKCS#1, y el formato no es un detalle.** El verificador `jwt` de Authorino está
fijado a RS256; el firmador acepta RS256 pero sólo parsea la clave en PKCS#1. Con EC el destino
rechaza el 100% de los tokens con un 401 idéntico a "falta el token"; con PKCS#8 el firmador
falla con `invalid signing key algorithm`, que culpa al algoritmo cuando el problema es el
encoding. Y el `kid` del token lo deriva Authorino del **nombre del Secret**: si no coincide con
el `kid` del JWKS que publica el destino, ninguna clave se prueba y todo da 401 con los objetos
en verde.

## Templating

Los manifests son templates de **gomplate**, renderizados contra un contexto JSON:

- `manifests/egress/` — **un archivo por objeto de Kubernetes**. El contexto lo arma `reconcile`
  con `jq`; `scripts/k8s/manifests_lib` rendea el directorio entero y aplica archivo por archivo.

  | archivo | objeto | cuándo se emite |
  |---|---|---|
  | `10-gateway.yaml.tpl` | `Gateway` de egreso | siempre |
  | `20-authpolicy.yaml.tpl` | `AuthPolicy` (firma el wristband) | siempre |
  | `30-destinationrule-peer.yaml.tpl` | TLS hacia el ingreso del sustrato opuesto | si hay reglas |
  | `40-destinationrule-local-ingress.yaml.tpl` | TLS hacia el ingreso de este cluster | si hay reglas **y** `origin=EKS` |
  | `50-httproute-egress.yaml.tpl` | `HTTPRoute` de salida, una por regla | una por regla |
  | `60-httproute-ingress.yaml.tpl` | `HTTPRoute` de entrada, en el ns del Gateway | una por regla, sólo `origin=OS` |

  El orden de aplicación sale del glob, que es alfabético. El prefijo numérico lo vuelve
  explícito —el `Gateway` primero, después lo que lo referencia— en vez de dejarlo librado a cómo
  caigan los nombres. **No es una dependencia dura:** los controllers son level-triggered, así que
  un `HTTPRoute` aplicado antes que su `Gateway` queda un momento en `Accepted=False` y reconcilia
  solo. Los saltos de 10 dejan lugar para insertar un objeto sin renumerar el resto.

  Los cuatro condicionales renderean vacío cuando su condición no se cumple. `kubectl apply -f`
  sobre un archivo vacío falla, así que el loop los descarta — y gomplate directamente no crea el
  archivo cuando la salida es vacía.
- `manifests/rbac.yaml.tpl` — usa `{{ getenv "VAR" }}` porque se renderiza a mano, fuera del
  workflow.

Los valores que vienen de los attributes de la instancia se tipan (`conv.ToInt`) o se escapan
(`quote`) en el template: es lo que impide que un valor con saltos de línea inyecte claves en un
manifest que después se aplica con credenciales del cluster.

## Publicación a un repo GitOps

El `reconcile` **sigue aplicando los manifiestos con `kubectl`**. Además, si hay un repo
configurado, los publica antes de aplicarlos. Por ahora el repo es un **registro del estado
deseado** que nadie reconcilia: es la pata 1 del camino a GitOps y lo que fija es el contrato de
layout del que va a depender la pata 2.

El árbol tiene **dos niveles**, porque los manifiestos no tienen la misma cardinalidad: cuatro son
uno por namespace y dos son uno por servicio interceptado.

```
eks/<namespace>/                              openshift/<namespace>/
├── 10-gateway.yaml                           ├── 10-gateway.yaml
├── 20-authpolicy.yaml                        ├── 20-authpolicy.yaml
├── 30-destinationrule-peer.yaml              ├── 30-destinationrule-peer.yaml
├── 40-destinationrule-local-ingress.yaml     └── <svc>/
└── <svc>/                                        ├── 50-httproute-egress.yaml
    └── 50-httproute-egress.yaml                  └── 60-httproute-ingress.yaml
```

El segmento de substrato se **deriva** de `ORIGIN`; no se configura. Va primero para que "todo el
estado deseado de este cluster" sea un prefijo contiguo (`eks/`): en la pata 2 eso es un solo
`Application` de Argo o un solo `Kustomization` de Flux.

⚠️ El substrato hace de identificador del cluster, y eso sirve **mientras haya un cluster por
substrato**. Dos EKS escribirían los dos en `eks/<namespace>/` y, como el publisher reemplaza el
subárbol entero, se borrarían mutuamente sin que ninguno falle. Hay que volver a meter un segmento
de cluster cuando caiga el Gap #1 o aparezca un segundo EKS por multi-región; el cambio es
`gitops_subtree` y nada más.

El publisher es **autoritativo sobre el subárbol del namespace**: cada corrida lo borra y lo
reescribe, así que sacar una regla borra su hoja y el `delete` borra el subárbol entero. Corolario:
**una sola instancia del service por (cluster, namespace)** — que ya es la única configuración sana,
porque el `Gateway` se llama `s2s-egress` y es uno por namespace.

### Configuración

| variable | default | qué es |
|---|---|---|
| `GITOPS_REPO_URL` | — | la URL del repo, con la credencial adentro. Prende el publisher. |
| `GITOPS_BRANCH` | `main` | branch destino. |
| `GITOPS_PATH_PREFIX` | vacío | subdirectorio raíz, para que el repo pueda hostear otras cosas. |
| `GITOPS_PUSH_RETRIES` | `5` | intentos de push ante contención. |

**Sin URL el publisher está apagado** y el `reconcile` anda como siempre. Con URL presente,
cualquier otro error es **fallo duro**: se aborta sin haber movido tráfico.

La URL lleva la credencial (`https://$GITHUB_TOKEN@host/org/repo.git`) y llega **solo por el env del
agente**, igual que `ORIGIN` y `CLUSTER_LABEL`:

```bash
np-agent ... -command-executor-env "...,GITOPS_REPO_URL=https://$GITHUB_TOKEN@github.com/cliente/gitops.git"
```

`-command-executor-env` separa por **coma**, así que el valor no puede contener una (una URL de
GitHub no tiene).

Por llevar el token, la URL **no va en el `configuration:` de los workflows** —esos YAML están
versionados en este repo— ni en sus `output:`, que es la maquinaria que el runner del CLI puede
loguear. `build_context` no la lee: la resuelve `gitops_lib` en el momento de usarla. Todo log propio
y el stderr de git pasan por un scrub que la reemplaza por `https://***@…`.

Se aceptan **solo** dos formas de URL: `https://[credencial@]host[:puerto]/path`, o un path absoluto
local. Cualquier otra cosa se rechaza antes de invocar git — en particular `ext::<comando>`, que es un
transporte de git que ejecuta comandos arbitrarios. **Riesgo aceptado en esta versión:** el token
queda en el `argv` del `git clone`, visible por `ps` para otros procesos del host; se cierra al pasar
a GitHub App o a `http.extraHeader`.

### Dos cosas para la pata 2

**El path es ownership, no el namespace del objeto.** `60-httproute-ingress` declara un `HTTPRoute`
en el namespace `gateways` y vive igual bajo el path del namespace de la app, porque su ciclo de vida
es el de la intercepción. Un `Kustomization` sobre este subárbol **no puede forzar el namespace**:
todos los manifiestos traen el suyo puesto, y reescribirlo mandaría la route de ingreso al namespace
equivocado.

**El subárbol describe el plano de ruteo, no el estado completo.** El swap de selector del `Service`
y el alias `<svc>-local` son imperativos —se calculan en runtime a partir del `Service` real— y no
salen de ningún template.

## Puesta en marcha

El service lo ejecuta un **agente de nullplatform** con `runtime host` o in-cluster. Hay dos juegos
de configuración y viven en lugares distintos a propósito.

### 1. Propiedades del cluster: van en el env del agente

Son de la instalación, no del formulario, así que las pasa quien levanta el agente
(`-command-executor-env` con `runtime host`, o el `env` del chart in-cluster). Un agente por cluster.

| variable | qué es |
|---|---|
| `ORIGIN` | `EKS` o `OS`. **Decide qué manifiestos se emiten** y de qué lado queda cada rama del reparto. Default `OS`. |
| `CLUSTER_LABEL` | cómo se identifica este cluster en el header `X-S2S-Cluster` de las respuestas. |
| `KUBECONFIG` | dedicado, no el `~/.kube/config` del usuario: los scripts invocan `kubectl` sin `--context`, así que dependen del `current-context`. Un `use-context` en otra terminal redirigiría el reconcile a otro cluster sin avisar. |
| `PATH` | tiene que resolver `bash` **>= 4**, `kubectl`, `jq`, `gomplate` y `git`. En macOS el `/bin/bash` 3.2 rompe el `logging` con *bad substitution*. |

Y las del publisher GitOps, opcionales — ver **Configuración** más arriba:
`GITOPS_REPO_URL`, `GITOPS_BRANCH`, `GITOPS_PATH_PREFIX`, `GITOPS_PUSH_RETRIES`.

⚠️ **`GITOPS_REPO_URL` lleva la credencial adentro: nunca va en el `configuration:` de un workflow**,
que está versionado. Va sólo por el env del agente.

### 2. Direcciones del sustrato: van en el `configuration:` de los workflows

Esas sí están versionadas, en `workflows/openshift/*.yaml`. Son iguales para todas las instancias de
un cluster y ninguna es un secreto:

| clave | qué es |
|---|---|
| `PEER_GATEWAY_HOST` | ingreso del sustrato **opuesto**, por donde sale todo lo que cruza. |
| `LOCAL_INGRESS_HOST` | ingreso de **este** cluster. Con `ORIGIN=EKS` la rama que atiende EKS también entra por acá. |
| `GATEWAY_NAMESPACE` | namespace del Gateway de ingreso. |
| `INGRESS_AUTHPOLICY` | la `AuthPolicy` que valida el token en el ingreso. El service no la crea: espera a que quede `Enforced` después de colgarle su route. |
| `WRISTBAND_SECRET_NAME` | Secret con la clave de firma. `{namespace}` se interpola. |
| `PEER_CA_SECRET` | CA con la que se valida el cert del peer. |
| `GATEWAY_CLASS`, `LISTEN_PORT`, `TOKEN_DURATION` | del Gateway y del token. |

⚠️ **Los valores que vienen en este repo son los de la PoC** y hay que cambiarlos antes de usarlo.
El más importante es `PEER_GATEWAY_HOST`: apunta a un overlay de Tailscale, que era el andamiaje
para conectar un OpenShift local con un EKS en AWS. En el destino real ese rol lo cumple la
conectividad corporativa y el valor es otro. El mecanismo de identidad no se entera del cambio.

### 3. Lo que tiene que existir antes

Este service **no provisiona el layer de plataforma**. Da por hecho, en cada cluster:

- el `Gateway` de **ingreso** y su `AuthPolicy` de validación, en `GATEWAY_NAMESPACE`;
- los Secrets de firma en `kuadrant-system` y la CA del peer;
- Kuadrant y Gateway API instalados, con una `GatewayClass` utilizable;
- el RBAC de abajo, aplicado una vez por namespace destino.

Con `GITOPS_REPO_URL` configurada, además: la **rama destino tiene que existir** en el repo —el
publisher clona con `--branch`— y el token necesita permiso de escritura sobre ella. Si la rama está
protegida contra push directo, el publisher falla en cada corrida y aborta el reconcile.

## Tests

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/
```

Requieren **bash >= 4**, **yq**, **gomplate** y **git**. La suite aborta si falta alguno en vez de saltear los tests:
en el bash 3.2 de macOS un test con varias `[[ ]]` evalúa sólo la última y la suite daría verde
sin probar nada.

## RBAC

El agente np necesita permisos sobre `services` y sobre los objetos de Gateway API, Kuadrant e
Istio del namespace target. **No necesita leer Secrets**: la clave de firma la referencia la
`AuthPolicy` por nombre y vive en otro namespace. El operador del cluster aplica una vez por
namespace target:

```bash
NAMESPACE=payments AGENT_SA=np-agent AGENT_NAMESPACE=nullplatform \
  gomplate -f services/egress-interceptor/manifests/rbac.yaml.tpl | kubectl apply -f -
```

Ajustar `AGENT_SA`/`AGENT_NAMESPACE` al ServiceAccount real del agente en el cluster.

---

## Procedencia

Este service se desarrolló y se validó punta a punta en el repo de implementación de la PoC
(`nullplatform-implementations/galicia-banco`, bajo `services/egress-interceptor/`). Acá viaja
**sólo el service**: código, manifiestos, spec, workflows y tests.

Lo que quedó allá y no hace falta para correrlo:

- los planes de diseño y los documentos de decisiones;
- el runbook de pruebas y los scripts de la demo;
- los launchers del agente de la PoC, atados a un CRC local, a un perfil de AWS y a un overlay de
  Tailscale. Lo que esos scripts hacían está descripto en **Puesta en marcha**: son las variables
  que hay que pasarle al agente, no código del service.

El layer de plataforma que este service **asume que ya existe** —el `Gateway` de ingreso, su
`AuthPolicy` de validación, la PKI y los Secrets de firma— tampoco viaja: se provisiona aparte.
