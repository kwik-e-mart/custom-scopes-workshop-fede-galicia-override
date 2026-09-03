# Demo S2S — detalle, decisiones y camino a productivo

Complemento de `GUIA-DEMO.md`: qué corre cada paso por dentro, qué propiedades de seguridad sostiene
el diseño (y cuáles no), qué se decidió y por qué, y qué falta para llevarlo a producción.

## Qué hace falta para correr esto en otra laptop

Cinco dependencias. **Sólo una es automatizable**, las otras cuatro son credenciales
personales o setup manual en consolas de terceros:

| # | Qué | Cómo se resuelve |
|---|---|---|
| 1 | **CRC** (el OpenShift de la PoC) | `./scripts/crc-up.sh` — instala, dimensiona (6 cpu / 16 GB / 80 GB, medido) y arranca. Necesita un **pull secret de Red Hat**, personal, y ~24 GB de RAM física |
| 2 | **AWS, cuenta `984449730514`** (perfil `galicia-1`) | No automatizable. Y no es sólo para el EKS: ahí viven el **tfstate** de *todos* los layers —`clusters/crc` incluido— y la **imagen de las apps** en ECR. Sin AWS ni el lado local hace `tofu init` |
| 3 | **Tailnet de Tailscale** | Manual: 2 OAuth clients + los tags `tag:s2s-eks`/`tag:s2s-crc` declarados en el policy file. Ver el `.example` en `infrastructure/tailscale/` |
| 4 | **API key de nullplatform** | Gitignoreada: no viaja con el clon. Más las 2 instancias del service (abajo) |
| 5 | **CLIs** | `tofu kubectl helm jq curl` (los exige `up.sh`) + `np` y `aws` (los usa `demo.sh`) |

Tailscale es **andamiaje, no diseño**: CRC vive detrás de NAT en la laptop y EKS está en AWS,
así que no hay ruta entre los dos. En el Banco ese rol lo cumple Direct Connect, y el
mecanismo de identidad no se entera del cambio. Lo usan sólo dos cosas, ambas cross-cluster:
que cada validador alcance el **JWKS del peer**, y que el Gateway de egreso alcance el
**ingreso del peer**.

### El instalador de CRC

```bash
./scripts/crc-up.sh
```

| Paso | Qué hace | Por qué así |
|---|---|---|
| 1 | Binario `crc`, RAM física y disco libre | Todo lo caro (bajar el bundle, crear la VM) va después: un chequeo de recursos al final es un chequeo que descubrís a los 20 minutos |
| 2 | Pull secret | Se exige **sólo si hay que arrancar**. Con la VM ya corriendo no se usa, y abortar por una credencial que no vas a consumir es gratuito |
| 3 | `crc config set cpus/memory/disk-size` | **6 cpu / 16 GB / 80 GB**, medidos sobre la instalación que corre la demo. Con los 4 cpus del default los pods pedirían ~96% de lo asignable. Sobre una VM corriendo no se toca: `crc config set` se guarda pero no aplica hasta el próximo arranque, y cambiarlo daría una falsa sensación de haber redimensionado |
| 4 | `crc setup` + `crc start` | Los dos idempotentes. La 1ª vez baja el bundle (~40 GB) y tarda ~20 min |
| 5 | `kubectl --context crc-admin get ns` | **Exactamente** el chequeo que hace `up.sh` en su paso 0, para que "el instalador dio OK" y "`up.sh` arranca" no puedan discrepar |

Termina imprimiendo las cuatro dependencias que **no** cubre, con el comando para verificar
cada una. Sin eso, "CRC listo" se lee como "la demo corre".

Overrides por env si tu laptop es distinta: `CRC_CPUS`, `CRC_MEMORY` (MB), `CRC_DISK` (GB),
`CRC_PULL_SECRET_FILE`, `CRC_CTX`.

⚠️ **El camino de instalación desde cero no está ejecutado.** Probarlo exige borrar una
instalación que sostiene la demo. Sí están probadas —con exit code verificado— las ramas de
"ya corriendo" (0), "falta el binario" (1), "falta el pull secret" (1) y "RAM insuficiente" (1).

**Ya no hace falta** recargar `xt_REDIRECT`/`xt_owner`/`iptable_nat` tras un `crc stop`/`start`:
eran para el `istio-init` que hacía la intercepción por iptables, y este modelo no inyecta sidecars
en los pods de aplicación (verificado: ningún pod tiene `istio-init`). Si lo ves en notas viejas,
ignoralo.

## Prerequisito: las instancias del service, creadas por UI

`demo.sh crear [eks|crc]` **crea las instancias**, y es el paso que ejercita el camino de `create`
—el que provisiona el Gateway de egreso, su AuthPolicy y las rutas desde cero—. También se pueden
crear desde la consola, sobre la aplicación **`hello world poc`** del namespace **`galicia-poc`**,
eligiendo el service **`egress-interceptor`** (tipo *dependency*). Son **dos**, una por cluster.

| Instancia | Cluster que la reconcilia | Interception inicial |
|---|---|---|
| `egress-eks` | EKS `gal-kuadrant-poc` | `service_name=reports`, `scope=<slug>`, `percent=0` |
| `egress-crc` | CRC (OpenShift) | `service_name=reports`, `scope=<slug>`, `percent=0` |

`percent=0` es "todavía no migrado": las dos arrancan mandando el tráfico a OpenShift. Para la
instancia de EKS eso implica cruzar, así que necesita el peer arriba desde el vamos.

Sobre los campos del form:

- **La regla tiene tres campos y ninguno más.** `service_name` es la dirección del servicio del lado
  **OpenShift** (un Service, este-oeste); `scope` es su dirección del lado **EKS** (de ahí sale el
  FQDN); `percent` es qué **% del tráfico se atiende en EKS** — `0` todo en OpenShift, `100` todo en
  EKS. Significa lo mismo desde los dos orígenes: si eso implica cruzar de sustrato lo decide dónde
  corre el que llama, no el form.
- **Ningún campo lleva una dirección de transporte.** La del Kuadrant remoto es configuración del
  workflow (`PEER_GATEWAY_HOST`), y el FQDN del scope lo resuelve el service con `np scope list`. Si
  un campo del form contiene un hostname de infraestructura, es un bug.
- **`scope` es un enum dinámico**: sale de `.scopes` del contexto del spec, que la plataforma filtra
  por el environment elegido. No hace falta external field ni agente para resolverlo.
- **El namespace no es un campo**: sale del provider `container-orchestration`. Y es el del servicio
  **destino** — la instancia se cuelga de la aplicación dueña de `reports`, que es lo que hace que
  una sola regla reparta el tráfico de todos los que llaman.
- **`interceptions` es editable**, y es lo único que toca `demo.sh`: cada paso reescribe `percent`.
  Los valores de la tabla son sólo el estado inicial.
- El nombre de cada instancia importa: `demo.sh` las busca por `egress-eks` y `egress-crc` exactos.

Qué **no** hace falta crear por UI: el spec del service (lo registra Terraform con
`git_provider = "local"`), el channel de notificaciones, ni los Gateways/AuthPolicy de los clusters.

## El camino de un request

Con origen **OpenShift** y `percent = 100` (la migración de verdad):

```
ledger ──► Service `reports`           el reconcile le robó el selector: apunta al Gateway de egreso
       ──► Gateway de egreso (Istio)   AuthPolicy de Kuadrant: Authorino acuña el wristband
                                       x-np-token (RS256, clave del namespace)
                                       headers: X-NP-Origin: OS · X-NP-Scope: <FQDN del scope>
       ──► DestinationRule             origina TLS contra el peer, con la CA propia
       ──► s2s-ingress (destino)       Terminate; AuthPolicy: Authorino valida la firma contra el
                                       JWKS del emisor y fija la identidad por overrides;
                                       Limitador cuenta
       ──► HTTPRoute del ingreso       matchea X-NP-Scope, reescribe el Host al FQDN del scope
       ──► HTTPRoute del scope         el que crea el exposer: reparte entre deployments (blue/green)
       ──► la app
```

La rama que **no** se migró (`100 - percent`) se atiende en OpenShift. Si quien llama está en
OpenShift no sale del cluster —va al Service `reports-local`, este-oeste—; si está en EKS, es esa
rama la que cruza. Dicho al revés: **el `percent` decide dónde se atiende y el llamador decide cuál
de las dos ramas cruza.**

Los headers de respuesta dejan la traza: `x-egress-gateway` (hop de egreso, lo pone el origen) y
`x-egress-route: inbound` + `x-s2s-cluster` (hop de ingreso, los pone el destino). La **ausencia**
de `x-s2s-cluster` dice que se atendió sin cruzar.

## Qué corre cada paso

| Paso | Por dentro |
|---|---|
| `preflight` | `aws sts get-caller-identity` sobre el perfil de EKS (va primero: `kubectl` resuelve el token con `aws eks get-token`, así que una sesión vencida tumba todos los pasos de EKS a la vez); `kubectl get gateway/authpolicy -o jsonpath` en los dos clusters exigiendo `Programmed=True` y **`Enforced=True`**; y un `wget` al JWKS del peer desde un pod de cada lado, verificando que devuelva `RS256` |
| `esc1` / `esc2` / `esc3` | `np service action create` de tipo `update`, UNA sola llamada: los `parameters` de la acción pisan a los attributes guardados y la API los persiste cuando termina OK. Después espera el gateway nuevo y hace 1 request de calentamiento + 3 medidos con `wget -S` |
| `barrido` | lo mismo, tres veces, con `percent` 0/50/100 y 20 requests por punto; clasifica contando `X-Egress-Route` |
| `aislamiento` | lee la clave privada de `other` (`kubectl get secret`), acuña dos JWT con `openssl dgst -sha256 -sign` (uno `iss=other`, otro `iss=payments`) y los manda con `curl` **desde un pod de `other`** contra el ingreso; después corre el control positivo |
| `estado` | `/service?nrn=…` de la API + `kubectl get pod` de los dos gateways |

**Por qué el patch y la acción son dos cosas:** el patch sólo persiste el atributo; el reconcile lo
ejecuta el agente cuando le llega la notificación de la acción. Sin la acción, la UI muestra el valor
nuevo y el cluster sigue con el viejo.

**Por qué el paso de aislamiento acuña el token afuera:** es equivalente a que lo haga un workload de
`other`, porque ese namespace **tiene su propia clave de firma**. No es un atajo del
test: es el modelo de amenaza real, y evita desplegar un firmante extra sólo para atacar.

## Correr un paso a mano

Cada escenario es la misma instancia del service con distinta configuración. Lo que cambia:

| Escenario | Instancia | `percent` | Dónde se atiende |
|---|---|---|---|
| Nada migrado, origen EKS | `egress-eks` | `0` | el FQDN del scope, en EKS |
| EKS→OpenShift | `egress-eks` | `100` | el Service `reports` en OpenShift, vía `X-NP-SVC` |
| Nada migrado, origen OpenShift | `egress-crc` | `0` | el Service `reports-local`, este-oeste en CRC |
| OpenShift→EKS | `egress-crc` | `100` | el FQDN del scope, vía `X-NP-Scope` |

El body es el mismo en los cuatro: lo único que cambia es `percent` y sobre qué instancia se
dispara. Y `percent` significa lo mismo en los dos orígenes — cuánto del servicio ya se atiende en
EKS.

La sonda es siempre la misma —el Service interceptado, desde el pod de la app— y lo que se lee son los
headers de traza:

```bash
CTX=arn:aws:eks:us-east-1:984449730514:cluster/gal-kuadrant-poc   # o: oc --context crc-admin
kubectl --context "$CTX" exec -n payments deploy/ledger -- \
  wget -S -qO- --timeout=25 http://reports.payments.svc.cluster.local:8080/ 2>&1 | tr -d '\r'
```

Para confirmar qué header de ruteo quedó rendido (`X-NP-SVC` con destino OpenShift, `X-NP-Scope` con
destino EKS):

```bash
kubectl --context "$CTX" -n payments get httproute s2s-egress-reports -o yaml \
  | grep -A6 requestHeaderModifier
```

## La traza de identidad

`esc1`, `esc2` y `esc3` muestran, por request, quién firmó y quién validó:

```
── Traza — qué viajó y quién lo validó
  egreso      s2s-egress.payments (cluster eks-kuadrant)
  entrega     inbound → reports-local.payments.svc.cluster.local
  atendió     crc-openshift  ✓ coincide con el destino configurado
  decisiones  1 en eks-kuadrant (acuñó) · 1 en crc-openshift (validó)
```

De dónde sale cada línea:

- **`egreso`** es el header `X-Egress-Gateway`, que sella el Envoy del Gateway de egreso del
  namespace. Si falta, el Service no está interceptado y el request nunca pasó por ahí.
- **`entrega`** y **`atendió`** son `X-Egress-Route` / `X-Egress-Target` / `X-S2S-Cluster`, que sella
  el `HTTPRoute` de ingreso del destino. Que existan **prueba que el request cruzó**: la rama local no
  atraviesa ningún ingreso y no los trae.
- **`decisiones`** es el contador de `outgoing authorization response` de Authorino a cada lado.
  Acuñar y validar son las dos mitades del contrato y se miden con la **misma** señal.

⚠️ **Hacia EKS los sellos NO llegan, y no es una falla.** Ahí se entra por el `HTTPRoute` del propio
scope —el que lleva los pesos del blue/green—, que lo maneja la plataforma y no sella nada. La prueba
de que cruzó es el contador del validador del destino. Por eso la traza dice `(sin sello: o se
atendió local, o entró por la route de un scope)` en vez de dar un veredicto que no puede sostener.

**El token nunca se loguea.** Un JWT en un log es una credencial.

⚠️ **La correlación entre los dos lados es temporal** (`kubectl logs --since-time` + conteo), no por
request-id: cada Authorino genera el suyo y no hay identificador compartido entre los dos clusters.
Alcanza porque la demo dispara un request por vez; bajo carga concurrente no serviría.

Si `entrega` aparece con un guion, el gateway de ese cluster todavía corre el rendering anterior:
cada cluster lo toma recién cuando corre el escenario que lo tiene como **origen**.

`barrido` y `aislamiento` no muestran traza a propósito: 60 requests con traza es ilegible, y en el
aislamiento lo que importa es el código de rechazo.

## Si algo falla

Los tres modos de fallo vistos en vivo. Ninguno fue del contrato de identidad: dos son del entorno y
uno es de la espera del script.

| Síntoma | Causa | Qué hacer |
|---|---|---|
| Todos los pasos de EKS fallan de golpe | Sesión SSO vencida — `kubectl` saca el token con `aws eks get-token` | `aws sso login --profile galicia-1`. El `preflight` lo chequea primero justamente para que no aparezca a mitad de la demo |
| `hace falta el agente de 'X'` con el agente corriendo | El proceso murió y su heartbeat todavía figura, o el agente es del *otro* cluster | El mensaje ahora distingue los casos: si dice "registrados pero sin latir", relanzá el agente; si dice "NINGÚN agente", nunca llegó a registrar (mirá su terminal) |
| `hay 2 agentes latiendo` | Quedaron los dos prendidos; el channel filtra sólo por `role`, así que la acción puede caer en el cluster equivocado | `Ctrl-C` en la terminal del que no corresponde al escenario. El paso aborta antes de disparar nada, así que no deja estado a medias |
| `el gateway no convergió a '…'` en `esc2` | CRC: multus con el token vencido, no nace **ningún** pod | Canario con `busybox`; si queda en `ContainerCreating`, `kubectl delete pod -n openshift-multus -l app=multus`. **Reintentar el paso**: el CNI tarda minutos en estabilizarse |
| `crc-up.sh`: "no encuentro el pull secret" | Es una credencial personal de Red Hat, no viaja con el repo | Bajarlo de [console.redhat.com](https://console.redhat.com/openshift/create/local) a `~/.crc/pull-secret.json`, o apuntar con `CRC_PULL_SECRET_FILE` |
| `crc-up.sh`: "la laptop tiene N GB" | La VM pide 16 GB y no queda margen para el host | Bajar la VM con `CRC_MEMORY=<MB>`, sabiendo que por debajo de ~12 GB no entra la malla |
| `crc-up.sh`: "arrancó pero no llego al contexto" | CRC registró el contexto con otro nombre | El error lista los contextos disponibles; correr con `CRC_CTX=<nombre>` (y pasarlo también a `up.sh` y `demo.sh`) |

El reconcile puede haber funcionado aunque el paso dé error: lo que se cuelga en ese último caso es el
`rollout status`, no el rendering. Se verifica mirando los `backendRefs` del `HTTPRoute` de egreso con
el comando de la sección anterior.

## Valores de referencia (medidos 2026-08-12)

Barrido de pesos, 20 requests por punto, destino CRC (sin rate limit del lado del destino):

| `percent` | `local` | `cloud` |
|---|---|---|
| 0 | 20 | 0 |
| 50 | 11 | 9 |
| 100 | 0 | 20 |

Los `inbound` acompañan a los `cloud` uno a uno: cada request remoto atravesó el interceptor del destino.

Aislamiento: positivo desde `payments` **200**; sin token desde `other` **401**; con la clave de `other`
**403** tanto declarando `iss=other` como `iss=payments`.

**Rate limit.** `s2s-smoke` existe **sólo en EKS** (200 req/60s; CRC no lo declara y su default de 0 lo
desactiva) y se aplica al **ingreso del destino**: un escenario con destino CRC no lo toca.

**Reversibilidad.** El `percent` es la perilla: a 0 todo queda local, sin destruir nada. Borrar la
instancia dispara el `delete`, que restaura el selector del Service desde la annotation
`egress-interceptor/original-selector` y elimina el gateway y el alias `-local`.

## Consideraciones de seguridad

**Lo que el diseño sostiene**

- **Identidad infalsificable entre namespaces.** Cada regla de `authentication` del validador fija la
  identidad con `overrides` según **qué clave verificó la firma**, no según el claim `iss`. Un atacante
  con una clave legítima que declara ser otro namespace obtiene 403 (verificado). El `iss` no participa
  de la autorización: es el reemplazo del `consumer.key == iss` de Kong, y es más fuerte que atar la
  clave al `kid`.
- **Autorización explícita por namespace.** `authorized_namespaces` es una lista blanca; la
  autorización compara `auth.identity.ns` contra ella y todo lo demás cae en 403.
- **Sin credencial no se entra**: 401 antes de llegar a la autorización.
- **El upstream no ve la credencial** (`response.success = {}` en la AuthPolicy).
- **TLS verificado en el hop remoto**: `proxy_ssl_verify on` con la CA del peer montada, y el nombre
  viaja como SNI. Un cert que no matchee el nombre corta el hop.
- **Las claves de firma son per (cluster × namespace)**: cuatro claves distintas, cada una montada sólo
  con la clave de su namespace. El radio de daño de una clave filtrada es ese namespace.

**Lo que NO sostiene (y hay que decirlo)**

- **Replay dentro de la ventana.** El token dura 60 s y no lleva `aud` ni `jti`: quien lo capture puede
  reusarlo hasta que expire. Mitigable con TTL más corto, audiencia y nonce.
- **Quien pueda crear una `AuthPolicy` en cualquier namespace puede pedirle a Authorino que firme con
  cualquiera de las claves de `kuadrant-system`**, porque `signingKeyRefs` referencia por nombre dentro
  de ese namespace compartido. Con OpenResty el control era RBAC sobre Secrets del propio namespace;
  ahora es RBAC sobre `AuthPolicy`. Lo que sostiene la frontera es que la `AuthPolicy` la renderice el
  service `egress-interceptor` y no la escriban los equipos de aplicación.
- **CA autofirmada compartida** por los dos clusters, generada por Terraform y con la privada en el
  state. Es andamiaje de PoC, no PKI.
- **La API key del agente viaja por línea de comandos** (`np-agent -api-key …`), así que es visible en
  `ps` de la máquina. Y es una key de organización con roles amplios: alcanza para el PoC en una laptop,
  no para producción.
- **La regla de SG que abre 443 pod-a-pod** en el node group de EKS es cluster-wide. Es lo que permite
  que el Gateway de egreso alcance al proxy del overlay, que corre en otro namespace del mismo cluster;
  en producción conviene acotarla al SG del gateway.
- **El rate limit es un smoke** (200 req/60s global en el Gateway), no una política por identidad.
- **Artefactos de demo**: la app `hello-world`, el pod `intruso` con imagen de `curl`, y todo el
  andamiaje de Tailscale (`tailscale-transport.tf`) no existen en producción.

## Decisiones tomadas

| Decisión | Por qué, y qué se descartó |
|---|---|
| **Kuadrant acuña en el egreso** (wristband) y valida en el ingreso | Se probó una etapa con OpenResty firmando en cada namespace y se volvió a Authorino: saca el código propio del camino del dato sin perder ninguna de las dos patas de la garantía (una clave por namespace + la `NetworkPolicy` que acota quién puede pedir firma). La identidad no sale de la malla porque el spike de Istio **ambient** dio rojo: Kuadrant 1.5.2 no se adjunta a su data plane (`gateway-controller` vs `mesh-controller`) |
| **`jwksUrl` en vez de `issuerUrl`** | Sin OIDC discovery no hay issuer declarado contra el que comparar el claim, así que el `iss = <namespace>` de la PoC de Kong sirve **sin tocar la firma**. Verificado con tráfico real |
| **Identidad por `overrides`**, no por `kid` | El `kid` ata la clave al header, pero nada obliga a que `iss == kid`: un namespace podía firmar con su clave declarando otro `iss`. Con `overrides` la identidad sale de qué clave validó |
| **Corte de loop por presencia de token**, no reescribiendo el backend del `HTTPRoute` | Es independiente de la topología y no acopla la config del Gateway al estado de la intercepción. La alternativa (apuntar el backend a `<svc>-local`) se rompe si se borra la instancia |
| **Sin malla en los pods de aplicación** | La identidad no depende de un sidecar: la pone el interceptor del namespace. Los pods de app no llevan `istio-proxy` |
| **`percent` como perilla de migración** | Permite mover tráfico de a poco y volver atrás sin destruir nada. A 0 todo queda local |
| **Un agente a la vez** | El channel selecciona por `role` sin discriminar cluster. Conviven dos si se parte por namespace de nullplatform (un channel por cluster) |
| **`ignore_changes` en los campos de otros dueños** | El selector del Service y su annotation los escribe el reconcile; el `external_name` lo pisa el operator de Tailscale. Declararlo evita que un apply revierta la intercepción en silencio |

## Pendientes para evolucionar a productivo

**Bloqueantes**

1. **Agente in-cluster.** Hoy corre como proceso host en una laptop: si se cae, no se puede cambiar
   configuración, y el origen de los scripts del service es ese filesystem (`git_provider = "local"`).
   Los prerequisitos ya están aplicados (rol IAM + API key) y el cutover está detrás de un toggle con
   rollback. **Único gate: una credencial de lectura del repo** para que el pod clone — la branch ya
   está pusheada. Ojo que **el chart no soporta GitHub App** (no tiene `appId`/`installationId`/
   `privateKey`): clona con `git` pelado y el único auth es token en la URL.
2. **PKI real.** Reemplazar la CA autofirmada por ACM / cert-manager, con rotación.
3. **Reemplazar el overlay de Tailscale por Direct Connect** con DNS del Banco. Todo
   `tailscale-transport.tf` es andamiaje y desaparece.
4. **Endurecer el token**: audiencia, TTL más corto y anti-replay.

**Importantes**

5. **`authorized_namespaces` desde una fuente de verdad** (gobierno / CMDB) en vez de una lista en HCL.
6. **Descubrimiento de destinos alcanzables**: hoy el dev declara `service_name` + `scope` a mano en
   la regla; en producción esos destinos tienen que derivarse del inventario de servicios.
7. **RBAC del agente**: el chart trae `clusterWide: true` con `*/*/*`. El service ya incluye el Role
   mínimo (`manifests/rbac.yaml.tpl`) pero **nadie lo renderiza**; cablearlo permite bajar el chart.
8. **Rate limit por identidad**, no un smoke global.
9. **Key management**: rotación de las claves de firma y de la CA, hoy en el state de Terraform.

**Menores**

10. El atributo `resolved` de la instancia queda vacío: el patch de `write_service_outputs` entra, pero
    la plataforma re-commitea los attributes al cerrar la acción. Es cosmético.
11. **El lado local depende de AWS igual**: `clusters/crc` guarda su tfstate en S3 y las apps salen
    de ECR privado, así que sin credenciales de la org ni la mitad de CRC hace `tofu init`. Cortar
    esa atadura (state local + imagen pública) es lo que haría al repo realmente clonable.
12. El token del repo para el agente in-pod va **embebido en la URL**, que es el único mecanismo que
    el chart ofrece. Las alternativas de scope mínimo (deploy key SSH, o un ConfigMap con el código)
    exigen `volumes`/`initContainers`, que el módulo `nullplatform/agent` no expone: habría que
    reemplazarlo por un `helm_release` crudo o agregar el passthrough upstream.
