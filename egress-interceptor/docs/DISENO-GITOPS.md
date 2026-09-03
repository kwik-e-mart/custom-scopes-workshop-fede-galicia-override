# Publicar los manifiestos del egress-interceptor a un repo (pata 1 de GitOps)

**Estado:** **implementado y verificado** (`services/egress-interceptor/scripts/k8s/gitops_lib`,
40 tests en `tests/gitops_publish.bats`) · **Plan de implementación:** [`plans/egress-interceptor-gitops-publish.md`](./PLAN-GITOPS.md)
**Service:** [`services/egress-interceptor/`](../) · **Diseño del que se cuelga:** [`docs/s2s-egress-sin-openresty.md`](s2s-egress-sin-openresty.md)

## El objetivo, y lo que explícitamente no es

Hoy el `reconcile` del egress-interceptor rendea manifiestos y los aplica con `kubectl`. El estado
final es solamente el cluster: no queda registro versionado de qué se aplicó ni de quién lo pidió.

El destino es GitOps: nosotros generamos los manifiestos, los pusheamos a un repo del cliente, y un
reconciler del cliente (Argo CD o Flux) hace el apply. Esta es la **pata 1** de ese camino:

- **seguimos aplicando nosotros** — el `kubectl apply` no se toca;
- **además** publicamos los manifiestos a un repo git configurable.

En la pata 1 el repo es un **registro del estado deseado**, no un disparador. Nada lo consume
todavía. Lo que se está fijando acá y lo que hay que hacer bien es el **contrato de layout**, porque
es la superficie de la que va a depender el reconciler de la pata 2.

**No es parte de esto:** que el cliente reconcilie, que dejemos de aplicar, ni cerrar el gap de los
objetos imperativos (ver "Lo que el repo no describe").

## Layout del repo

```
<prefix>/<substrato>/<namespace>/          ← objetos de namespace
<prefix>/<substrato>/<namespace>/<svc>/    ← objetos por servicio interceptado
```

Concreto, con `prefix` vacío:

```
eks/payments/
├── 10-gateway.yaml
├── 20-authpolicy.yaml
├── 30-destinationrule-peer.yaml
├── 40-destinationrule-local-ingress.yaml
├── reports/
│   └── 50-httproute-egress.yaml
└── checkout/
    └── 50-httproute-egress.yaml

openshift/payments/
├── 10-gateway.yaml
├── 20-authpolicy.yaml
├── 30-destinationrule-peer.yaml
└── reports/
    ├── 50-httproute-egress.yaml
    └── 60-httproute-ingress.yaml
```

El segmento de substrato se **deriva** de `ORIGIN` (`eks` cuando `ORIGIN=EKS`, `openshift` en
cualquier otro caso). No es configurable: es una propiedad del cluster donde corre el agente.

### Por qué el substrato va antes del namespace

Argo CD (`Application.spec.source.path`) y Flux (`Kustomization.spec.path`) apuntan a **un prefijo
contiguo** del repo, y un reconciler está atado a un cluster. Con este layout, "todo el estado
deseado de este cluster" es literalmente un subárbol: `eks/`. Un `Application` por cluster y listo.

El layout alternativo que se consideró —`<namespace>/<svc>/<substrato>/`— deja los manifiestos de un
cluster esparcidos en cada hoja del repo: hace falta un `ApplicationSet` con generator de
directorios y wildcards, y no existe ningún subárbol que signifique "esto es lo mío". Tres corolarios
del mismo eje:

- **Prune por cluster** es un walk de un subárbol acá, y un scan del repo entero allá.
- **Ownership** en git es path-based: `/eks/ @cloudplatform` en CODEOWNERS sale gratis. Es el eje que
  le importa al equipo que opera los clusters, que en Galicia es CloudPlatform y no el equipo de la
  Sigla.
- **Diffs legibles**: un cambio de `percent` toca dos hojas en los dos layouts, pero acá el diff se
  lee como "cambió el cluster de OpenShift y cambió el de EKS".

Lo que el layout alternativo tenía a favor —las dos patas de una migración lado a lado, que para un
service cuyo trabajo *es* migrar no es poca cosa— se recupera con un `git log --all -- '*/reports/*'`.
La contigüidad por cluster no se recupera de ningún lado.

### El substrato hace de identificador del cluster, y eso caduca

Hubo una versión de este diseño con un segmento `<cluster>` entre el substrato y el namespace. Se
sacó: mientras haya **un cluster por substrato** —hoy un CRC y un EKS— el substrato ya identifica al
cluster, el subárbol por reconciler sigue siendo contiguo, y el segmento extra solo agregaba ruido a
cada path.

Lo que hay que tener presente, porque no es cosmético: **dos clusters del mismo substrato colisionan**.
Los dos escribirían `eks/<namespace>/`, y como el publisher es autoritativo sobre el subárbol y lo
reemplaza entero, cada corrida borraría lo que publicó el otro — un ping-pong silencioso, porque
ninguno de los dos falla.

Cuándo hay que volver a meter el segmento: cuando caiga el **Gap #1** (criterio de partición de
clusters y cuentas, ver `README.md`), o antes si aparece un segundo EKS por multi-región. El cambio es
localizado: `gitops_subtree` en `scripts/k8s/gitops_lib` y la variable de configuración que lo
alimente. Nada del algoritmo de push ni del fan-out del render depende de la cantidad de segmentos.

### Por qué hay dos niveles y no uno

Los seis manifiestos no tienen la misma cardinalidad. Solo dos hacen `range .interceptions`:

| archivo | cardinalidad | nivel |
|---|---|---|
| `10-gateway.yaml` | 1 por namespace | namespace |
| `20-authpolicy.yaml` | 1 por namespace | namespace |
| `30-destinationrule-peer.yaml` | 1 por namespace (si hay reglas) | namespace |
| `40-destinationrule-local-ingress.yaml` | 1 por namespace (solo `ORIGIN=EKS`) | namespace |
| `50-httproute-egress.yaml` | 1 por regla | servicio |
| `60-httproute-ingress.yaml` | 1 por regla (solo `ORIGIN=OS`) | servicio |

Los cuatro de namespace van sueltos en el nivel del namespace, sin carpeta de servicio. Duplicarlos
en cada hoja daría N `Gateway` homónimos peleándose por el mismo objeto.

Archivos y directorios como hermanos en el mismo nivel es lo que quieren Kustomize y el modo
recursivo de Argo: recorren el subárbol y aplican todo lo que encuentran. No hace falta un
`_shared/`.

Efecto lateral deseable: una instancia con **cero** intercepciones deja el namespace con los cuatro
compartidos y ninguna hoja. El diff se lee como "el Gateway sigue en pie, no hay tráfico
interceptado", que es el estado real.

### El path es ownership, no el namespace del objeto

`60-httproute-ingress.yaml` declara un `HTTPRoute` en el namespace **`gateways`**, no en el de la
app, y vive igual bajo el path del namespace de la app: es la contracara del `50-` y su ciclo de vida
es el de la intercepción.

Consecuencia para la pata 2: **el `Kustomization`/`Application` que tome este subárbol no puede
forzar el namespace** (nada de `namespace:` en un `kustomization.yaml`, nada de
`spec.destination.namespace` sin `Namespace` explícito en los objetos). Todos los manifiestos traen
su `metadata.namespace` puesto; reescribirlo mandaría la route de ingreso al namespace equivocado y
el tráfico de entrada del namespace se quedaría sin puerta.

## Autoridad y prune

El publisher es autoritativo sobre **el subárbol `<prefix>/<substrato>/<namespace>/`
completo**. Cada corrida lo borra y lo reescribe con lo que rindió.

Eso hace que el prune de una regla que dejó de estar declarada sea gratis y consistente, y espeja la
autoridad que el `reconcile` ya se toma en el cluster (`kubectl delete -l egress-interceptor/managed=true`
sobre el namespace). El `delete` de la instancia borra el subárbol entero y commitea.

Corolario operativo: **una sola instancia del service por (cluster, namespace)**. Ya es la única
configuración sana en el cluster —el `Gateway` se llama `s2s-egress` y es uno por namespace— así que
esto no agrega una restricción nueva, la hace explícita.

## Cómo se parte el render en hojas por servicio

El render no está partido por intercepción: `50-` y `60-` emiten N documentos en un archivo. Para
llenar las hojas, **el publisher vuelve a llamar a `render_manifests` una vez por regla**, con el
contexto filtrado a esa sola intercepción, y de esa salida se queda solo con los archivos de nivel
servicio. Los cuatro de namespace salen del render completo que el `reconcile` ya hizo.

Por qué así:

- **Cero dependencias nuevas de runtime.** `gomplate` ya es dependencia dura. Partir el YAML
  multi-documento pediría `yq`, que hoy el camino del `reconcile` no usa (solo `kubectl`, `jq`,
  `gomplate`).
- **No toca el camino del apply.** `render_manifests` hace una sola invocación de `gomplate` con
  todos los pares `-f/-o` a propósito, y `render.bats` asserta sobre el stream concatenado. Emitir
  un archivo por regla desde los templates pediría N invocaciones y tocaría el hot path.
- **La pertenencia se resuelve por construcción.** "¿Qué objetos son de `reports`?" se contesta
  rindiendo con `reports` como única regla, no parseando el nombre `s2s-egress-reports`. Inferir
  pertenencia de una convención de nombres es exactamente el acoplamiento silencioso que este
  service viene sacando.

Costo: una invocación extra de `gomplate` (~0,5 s) por regla.

### La clasificación es una fuente de verdad chequeada

El publisher necesita saber qué archivos son de nivel servicio. Lo declara como constante
(`GITOPS_PER_SERVICE_MANIFESTS`), y va con un **test de exhaustividad** que recorre
`manifests/egress/*.yaml.tpl` y falla si aparece un template que no está clasificado en ninguno de
los dos niveles. Un template nuevo obliga a decidir en vez de caer en un default silencioso.

## Orden y semántica de fallo

**Se publica antes de aplicar, y un fallo de git aborta la corrida.** El repo es el estado
*deseado*: escribirlo antes que el cluster es la semántica correcta y es el orden que la pata 2 va a
necesitar.

El punto de inserción es dentro del `reconcile`, entre `render_manifests` y `apply_manifests`. Ahí
—y no como step separado del workflow— porque es el único lugar donde la garantía es verificable: el
contexto de render ya existe y todavía no se aplicó nada.

Precisión necesaria: **"antes de tocar el cluster" no es literal.** El `reconcile` ya escribe en el
cluster antes del render — chequea endpoints y crea el alias `<svc>-local`. Lo que sí se garantiza es
publicar antes del `apply_manifests` y antes del swap de selector, o sea antes de cualquier cambio
que **mueva tráfico**. La creación del alias es idempotente y neutral para el tráfico.

En el `delete`, la publicación del borrado va al principio de la rama, antes del `revert_service`.

⚠️ **Eso abre una ventana de divergencia que la pata 2 tiene que contemplar.** Si la publicación del
borrado entra pero un paso posterior aborta —el caso concreto es `revert_service` encontrándose sin
la annotation `egress-interceptor/original-selector`—, el repo queda diciendo "acá no hay estado"
mientras el cluster sigue con el `Gateway`, las routes y el `Service` hijackeado.

Con el repo como registro pasivo, que es lo que hay hoy, es benigno: el siguiente `apply` republica
el subárbol y la divergencia se cierra sola. **Con un reconciler activo deja de serlo**: un
`Application` de Argo con prune leería ese subárbol vacío como "borrá todo esto" y ejecutaría el
borrado que el `reconcile` justamente no pudo completar, dejando el namespace sin el camino de
entrada y sin el Service original. El orden inverso —revertir primero y publicar después— tampoco
sirve: ahí la ventana es la simétrica y peor, porque el cluster pierde el tráfico mientras el repo
todavía declara que tiene que estar.

No se resuelve en esta pata. Las salidas a evaluar cuando se escriba el reconciler son publicar el
borrado en dos fases (marcar la intención, confirmar después de que el cluster convergió), o que el
reconciler no prunee lo que no vio nacer.

Un fallo de git aborta con `die`, igual que cualquier otro fallo del `reconcile`. En ese momento no
se movió tráfico, así que abortar es seguro y es lo que corresponde: la alternativa —seguir con un
warn— es el modo de fallo silencioso que este service viene combatiendo (ver el comentario de
`errexit` en `reconcile`).

## Push concurrente

Corren varias instancias a la vez, en dos substratos, sobre varios namespaces. El algoritmo:

```
clone --depth=1 --branch $BRANCH        ← acá se valida credencial, URL y branch: falla rápido
por intento (máx 5):
  rm -rf <subárbol>
  escribir los manifiestos
  git add -A -- <subárbol>
  nada staged → salir 0                ← sin commits vacíos
  git commit
  git push origin HEAD:$BRANCH
    ok        → listo
    rechazado → git fetch origin $BRANCH
                git reset --hard origin/$BRANCH
                sleep backoff + jitter
                reintentar
```

**Nunca rebase, nunca merge.** La escritura es el reemplazo total de un subárbol calculado desde
entradas locales, así que replayarla es determinístico: `reset --hard` + reescribir es estrictamente
más robusto que un rebase, porque elimina *todo* camino de resolución de conflictos del bash. Y sigue
siendo correcto incluso si otra instancia tocó un path solapado — el último escritor de ese subárbol
gana, y solo de ese subárbol.

Como cada instancia escribe en un subárbol disjunto, lo único que se espera es el rechazo por
non-fast-forward. La autenticación y la existencia del branch se validan en el `clone`, así que a la
altura del push cualquier fallo se trata como contención y se reintenta.

Backoff exponencial arrancando en 1 s, con jitter, tope 8 s, 5 intentos: peor caso ~30 s.

**`GIT_TERMINAL_PROMPT=0` siempre.** Una credencial mala no puede quedar esperando un prompt: es la
misma lección que el `</dev/null` de `gomplate` en `manifests_lib` — colgarse sin log y sin timeout
es el peor modo de fallar adentro de un agente.

La identidad del committer va por `git -c user.name=... -c user.email=...` en cada invocación: el
contenedor del agente no tiene config global y no queremos escribirle una.

## Configuración

Todo por env var.

| variable | default | qué es |
|---|---|---|
| `GITOPS_REPO_URL` | — | la URL del repo, con la credencial adentro. Prende el publisher. |
| `GITOPS_BRANCH` | `main` | branch destino. |
| `GITOPS_PATH_PREFIX` | vacío | subdirectorio raíz, para que el repo pueda hostear otras cosas. |
| `GITOPS_PUSH_RETRIES` | `5` | intentos de push. |

**Sin URL, el publisher está apagado**: loguea un `info` y el `reconcile` sigue como hoy. Es lo que
mantiene la demo andando y hace que esto se pueda desplegar sin coordinar con el cliente. Con URL
presente y cualquier otra cosa mal, es fallo duro.

La validación de todo esto vive en `build_context`, con el mismo `require_match` que el resto: pasa
antes de que nada toque el cluster. La excepción es la URL, que valida `gitops_lib` — ver más abajo.

## El token no puede aparecer en ningún log

En esta versión la credencial viaja **dentro de la URL**: `https://$GITHUB_TOKEN@host/org/repo.git`.
Es lo que el cliente nos va a dar; una GitHub App es el paso siguiente y no cambia nada del layout ni
del algoritmo de push. Tres consecuencias que hay que implementar, no solo documentar:

1. **La URL no atraviesa el plumbing de outputs del workflow.** El resto de la configuración se
   exporta desde `build_context` y se declara en `output: [{type: environment}]` de cada workflow. La
   URL no: `build_context` solo mira si está definida —nunca su valor— y el publisher la resuelve por
   su cuenta desde el env en el momento de usarla. Así el secreto nunca entra en la
   maquinaria que el runner del CLI puede loguear.
2. **Todo log propio usa una forma redactada.** Se imprime `https://***@host/org/repo.git`.
3. **El stderr de git se scrubea.** Hay mensajes de git que filtran el userinfo de la URL
   (`could not read Username for 'https://...'`). El stderr de cada invocación pasa por
   `sed 's#//[^@]*@#//***@#g'` antes de llegar al log.

Y por la misma razón la URL **no puede ir en el `configuration:` de los workflows**: esos YAML están
versionados en este repo.

El regex de redacción es `://[^/]*@` y no `//.*@` ni `//[^@/]*@`. Las dos alternativas fallan y de
formas opuestas: con `.*` greedy, una URL sin credencial como `https://github.com/o/r.git@v1` se come
medio path; con `[^@/]*` la redacción corta en el **primer** `@`, así que una credencial que contiene
un `@` sin codificar —que git sí acepta, porque parte en el último— deja el secreto en cleartext.
Hay un test por cada una de las tres propiedades.

### La URL se valida, no solo se redacta

`gitops_lib` exige que la URL tenga una de dos formas: `https://[credencial@]host[:puerto]/path`, o un
path absoluto local (que es lo que usan los tests contra un bare repo, y lo que serviría para un repo
montado). Todo lo demás se rechaza antes de invocar git. Cierra tres cosas a la vez:

- **`ext::<comando>`**, el transporte de remote helper de git, que ejecuta un comando arbitrario. Sin
  esta validación alcanzaba con poder escribir la configuración del workflow para lograr ejecución de
  comandos en el contexto del agente.
- **Una URL que arranca con `-`**, que git parsearía como opción y no como argumento posicional. El
  `clone` además lleva `--` antes de los posicionales.
- **Una credencial con `/` sin codificar**, que no es una URL con credencial en absoluto —git parsea
  como host lo que está antes de la primera barra— y que ninguna redacción por regex puede tapar. Se
  vuelve inexpresable en vez de quedar a cargo del filtro.

La validación vive en `gitops_lib` y no en `build_context` **a propósito**: es la función que hace la
operación peligrosa, y es la única que lee la URL. `build_context` valida la configuración no secreta
y nunca toca el secreto.

Por la misma razón `gitops_lib` valida el subárbol que armó antes del `rm -rf`, en vez de confiar en
que el caller ya validó `GITOPS_PATH_PREFIX` y el namespace: hoy los workflows
siempre pasan por `build_context`, pero el lib re-lee el env en el momento de usarlo y una corrida
directa —debug, un workflow futuro que saltee el step— no tendría ninguna red.

### Riesgo aceptado: el token en el `argv`

`git clone <url-con-token>` deja la credencial en el `argv` del proceso hijo, que es legible por
cualquier proceso que pueda leer `/proc/<pid>/cmdline` del contenedor: un agente de EDR a nivel host,
un PID namespace compartido, un `kubectl exec` al pod. Queda **fuera** del alcance de la redacción,
que solo cubre lo que el script imprime.

Es la consecuencia conocida de meter la credencial en la URL, que es la decisión explícita para esta
versión. El camino de salida no cambia nada del layout ni del algoritmo de push: pasar a GitHub App,
o mantener la URL sin credencial y dar el token por `http.extraHeader` o por un credential helper de
vida corta, de modo que nunca aparezca en el `argv`. Para un cliente que plausiblemente corre
monitoreo de procesos a nivel host, esto conviene cerrarlo antes de producción.

## Lo que el repo no describe (gaps de la pata 2)

Esto no bloquea la pata 1, pero hay que tenerlo escrito antes de que alguien asuma que el subárbol es
el estado deseado completo:

- **El swap de selector no es un manifiesto.** La intercepción es un `kubectl patch` sobre el
  `Service` original, con el selector previo guardado en una annotation. Un reconciler GitOps no
  puede hacer eso: el `Service` no es nuestro, y el dato para revertir se calcula en el momento.
- **El alias `<svc>-local` se clona del `Service` real** en runtime (hereda puertos y
  `appProtocol`), así que tampoco sale de un template.
- **Los `wait` de condiciones tampoco.** El orden "data plane arriba → recién ahí desviar el
  tráfico" lo garantiza el `reconcile`, no el repo.

O sea: el subárbol describe el **plano de ruteo** completo, y el swap de tráfico sigue siendo
imperativo. La pata 2 va a tener que decidir qué hace con eso — probablemente dejar el swap en el
service y darle al reconciler solo el plano de ruteo.

## Tests

`services/egress-interceptor/tests/gitops_publish.bats`, con **git de verdad**: el remoto es un
`git init --bare` en `$BATS_TEST_TMPDIR`. Sin mocks de git — un mock de git que no modela el rechazo
por non-fast-forward pasaría en verde mientras el git real falla.

Casos:

- **Carrera:** dos publishers en paralelo contra el mismo bare repo. Los dos aterrizan y los dos
  subárboles quedan presentes.
- **Exhaustividad** de la clasificación de templates por nivel.
- **Layout:** los cuatro de namespace en el nivel del namespace, `50-`/`60-` en la hoja del servicio,
  substrato derivado de `ORIGIN`, prefix aplicado.
- **Equivalencia:** los objetos publicados son los mismos que los aplicados.
- **Prune:** sacar una regla borra su hoja; el `delete` borra el subárbol.
- **No-op:** sin cambios no se crea commit.
- **Apagado** sin URL; **fallo duro** con URL inválida, con esquema no soportado y con un subárbol que escaparía del clon.
- **Redacción:** el token no aparece en stdout ni en stderr, ni en los mensajes de error de git.
- **Orden:** con el publisher fallando, no se llega a `apply_manifests`.

Cada test se corre contra el código sin la implementación para confirmar que falla antes de creerle.

```bash
cd services/egress-interceptor
PATH=/opt/homebrew/bin:$PATH bats tests/
```
