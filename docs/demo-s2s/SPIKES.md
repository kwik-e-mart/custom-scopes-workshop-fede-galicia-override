# Registro de spikes — fase 0

## Spike A — arm64 de las imágenes de Kuadrant
**Fecha:** 2026-08-03
**Veredicto:** OK
**Evidencia:**

Tags estables más recientes (excluyendo `latest`, `nightly-*`, `-rc*`/`-alpha*`/`-testing*`, y tags por SHA de commit) relevados vía `quay.io/api/v1/repository/kuadrant/<repo>/tag/?limit=100&onlyActiveTags=true`:

| Imagen | Tag | Plataformas |
|---|---|---|
| authorino | v0.26.2 | linux/amd64, linux/arm64, linux/ppc64le, linux/s390x |
| limitador | v2.4.2 | linux/amd64, linux/arm64, linux/s390x |
| kuadrant-operator | v1.5.2 | linux/amd64, linux/arm64, linux/s390x |

Verificado con `docker manifest inspect quay.io/kuadrant/<repo>:<tag>` — las tres imágenes publican manifest list multi-arch con `linux/arm64` incluido.

**Conclusión:** el operator (`kuadrant-operator`) y los dos controllers que instala (`authorino`, `limitador`) soportan `arm64` en sus tags estables más recientes. No hace falta rebuild propio ni forzar el cluster A a `amd64`/x86 — un cluster A en `arm64` (p. ej. EKS Graviton) es viable para la PoC.

## Entorno de spikes
**Fecha:** 2026-08-03
**Cluster:** CRC (OpenShift Local) v4.21.14, nodo único `crc` (`aarch64`, CoreOS), contexto kubeconfig `crc-admin`.

### Gateway API — gestionado nativamente por OpenShift, no instalable a mano

El Step 2 original del brief (`oc apply` del `standard-install.yaml` de `kubernetes-sigs/gateway-api`) **no aplica en OpenShift 4.21**: el Ingress Operator ya trae los CRDs de Gateway API instalados y los protege con una `ValidatingAdmissionPolicy` (`openshift-ingress-operator-gatewayapi-crd-admission`) que rechaza cualquier `apply`/`create`/`replace` externo sobre esos CRDs ("*Gateway API Custom Resource Definitions are managed by the Ingress Operator and may not be modified*").

Confirmado en el cluster:
- Featuregates `GatewayAPI` y `GatewayAPIController` habilitados (`oc get featuregate cluster`).
- `clusteroperator/ingress` `Available=True` (versión 4.21.14).
- CRDs `gatewayclasses`, `gateways`, `grpcroutes`, `httproutes`, `referencegrants` ya presentes y `Established=True`, con anotación `gateway.networking.k8s.io/bundle-version: v1.3.0`.
- `backendtlspolicies` (parte del canal `standard` en el release upstream v1.6.1) **no** está entre los CRDs que el Ingress Operator instala — el bundle que trae OpenShift es más acotado que el último release upstream.

**Versión de Gateway API aplicada:** ninguna instalación manual — se usa el bundle nativo del Ingress Operator de OpenShift 4.21.14, `bundle-version v1.3.0` (release upstream más reciente al momento del spike: `v1.6.1`, no usado).

### Istio (Helm, mismos charts que `commons/istio`)

Repo `https://istio-release.storage.googleapis.com/charts` resolvió sin problemas. No hay pin de versión de Istio en el HCL existente del repo (`commons/istio` no fija chart version), así que se tomó la última estable publicada al momento del spike.

- **Versión del chart de Istio:** `1.30.3` (`istio/base` e `istio/istiod`, misma versión para ambos).
- `istio-base` e `istiod` instalados en el namespace `istio-system` con `helm install ... --wait`; `istiod` quedó `1/1 Running`.

### Kuadrant — repo HTTP funcionó, no hizo falta OCI

El repo HTTP (`https://kuadrant.io/helm-charts/`) resolvió sin problemas (`helm repo add` + `helm search repo` con éxito) y expone exactamente la versión validada como arm64-safe en Spike A (`v1.5.2`). No fue necesario probar la vía OCI (`oci://quay.io/kuadrant/charts/kuadrant-operator`).

**Coordenadas exactas usadas:**
```
helm repo add kuadrant https://kuadrant.io/helm-charts/
helm install kuadrant-operator kuadrant/kuadrant-operator -n kuadrant-system --create-namespace --version 1.5.2 --wait
```

Tras el `helm install`, todos los deployments en `kuadrant-system` (`kuadrant-operator-controller-manager`, `authorino-operator`, `limitador-operator-controller-manager`, `dns-operator-controller-manager`, `kuadrant-console-plugin`) quedaron `Available`/`1/1 Running`.

Se aplicó el CR que dispara la instalación de Authorino + Limitador:
```yaml
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
```
Resultado: pods `authorino-*` y `limitador-limitador-*` `1/1 Running`; `status.conditions` del CR `Kuadrant` en `Ready=True` ("Kuadrant is ready").

### apiVersion reales (mandan sobre cualquier ejemplo de la documentación)

| Kind | apiVersion real en el cluster |
|---|---|
| `AuthPolicy` | `kuadrant.io/v1` |
| `RateLimitPolicy` | `kuadrant.io/v1` |
| `TLSPolicy` | `kuadrant.io/v1` |
| `DNSPolicy` | `kuadrant.io/v1` |
| `Kuadrant` (CR del operator) | `kuadrant.io/v1beta1` |
| `AuthConfig` (Authorino, usado internamente por `AuthPolicy`) | `authorino.kuadrant.io/v1beta3` |
| `Authorino` (CR del authorino-operator) | `operator.authorino.kuadrant.io/v1beta1` |
| `Limitador` (CR del limitador-operator) | `limitador.kuadrant.io/v1alpha1` |

Confirmado con `oc api-resources | grep -iE 'authpolicy|ratelimitpolicy|kuadrant|authconfig'` y `oc explain authpolicy --recursive` / `oc explain kuadrant`.

## Spike B — principal SPIFFE
**Fecha:** 2026-08-03
**Veredicto:** BLOCKED (en la topología Gateway API actual) — con hallazgo positivo importante a nivel mesh.

### Resumen

La expresión CEL que la documentación/RFC de Kuadrant declara correcta —
`source.principal` / `destination.principal` (sin el wrapper `context.` que traía el
brief) — **compila y es la sintaxis correcta** en Authorino v0.26.2. Pero en la
topología que arma este spike (`AuthPolicy` con `targetRef` a un `Gateway` de
`gatewayClassName: istio`, listener `protocol: HTTP`), el valor **llega vacío**: el
hop caller→Gateway **no es mTLS**, así que no hay principal que leer. El fallback
XFCC (Step 4 del brief) falla por la misma razón: no hay handshake mTLS en ese hop,
por lo tanto tampoco hay XFCC que generar. Verificado con evidencia de `config_dump`
(abajo).

Como contraprueba, se validó que el mecanismo SPIFFE/mTLS de Istio en sí **sí
distingue correctamente** `caller-a` de `caller-b` cuando la llamada es
sidecar-a-sidecar directa (sin pasar por el `Gateway`) — ver "Contraprueba" más abajo.
El gap es específicamente que el `AuthPolicy` de Kuadrant solo puede targetear
`Gateway`/`HTTPRoute` (modelo de policy attachment de Gateway API), y el listener
`HTTP` de ese `Gateway` es plaintext por diseño de Gateway API — la malla no lo
envuelve en mTLS automáticamente como sí hace con el tráfico sidecar-a-sidecar
interceptado por iptables.

### Paso 0 (gotcha de entorno, no estaba en el brief): módulos de kernel faltantes en el nodo CRC

El primer intento de levantar `caller-a`/`caller-b` con sidecar inyectado falló:
`istio-init` quedaba en `CrashLoopBackOff` con:

```
error	Command error: xtables resource problem: Extension REDIRECT revision 0 not supported, missing kernel module?
...
iptables-nft-restore v1.8.10 (nf_tables):
line 7: RULE_APPEND failed (No such file or directory): rule in chain ISTIO_REDIRECT
```

Causa: al nodo `crc` (RHCOS aarch64) le faltaban cargados los módulos `xt_REDIRECT`,
`xt_owner`, `iptable_nat` (sí estaban `ip_tables`, `nf_nat`, `nf_conntrack`). Fix
(vía `oc debug node/crc` → `chroot /host` → `modprobe xt_REDIRECT xt_owner
iptable_nat`, exit code 0 en los tres). Es un ajuste de runtime sobre la VM efímera
de CRC (no toca ningún repo de Terraform ni infra gestionada), pero conviene dejarlo
registrado porque **se pierde en cada `crc stop`/`crc start` o `crc delete`** — hay
que repetirlo si CRC se recicla.

### Paso 0.1 (gotcha de entorno): SCC deniega el sidecar cuando el pod lo crea un Deployment

Al reemplazar el backend dummy por un backend real (`kennethreitz/httpbin`) vía
`Deployment`, el pod quedó en `0/1` con:

```
FailedCreate  Error creating: pods "echo-backend-..." is forbidden: unable to
validate against any security context constraint: [... provider restricted-v2:
.initContainers[0].capabilities.add: Invalid value: "NET_ADMIN": capability may
not be added ...]
```

Los pods `caller-a`/`caller-b` (creados con `oc run` directo, bajo la sesión
`crc-admin`) habían levantado sin problema (solo un *warning* de PodSecurity, no
bloqueante). La diferencia es **quién crea el Pod**: `oc run` lo crea la identidad
admin (con acceso a SCCs permisivas); un `Deployment` lo crea el
`replicaset-controller` a nombre de la ServiceAccount del pod (`default` en este
caso), que solo tiene la SCC `restricted-v2` — insuficiente para el `NET_ADMIN`/root
que pide el init-container de Istio. Workaround usado: crear el backend también con
`oc run` (mismo patrón que los callers) en vez de `Deployment`. Para un fix
definitivo (fuera de alcance de este spike) haría falta bindear una SCC permisiva a
la ServiceAccount de los workloads inyectados, o migrar a Istio CNI.

### Paso 1: fix de la expresión CEL — `context.source.principal` no compila

Con el `AuthPolicy` tal cual lo arma el brief (`context.source.principal` /
`context.destination.principal`), Authorino rechaza la config:

```
error: "ERROR: <input>:1:1: undeclared reference to 'context' (in container '')
 | context.source.principal
 | ^"
```

(`AuthConfig.status.conditions[type=Ready].status=False`, `reason=Invalid`, mismo
mensaje). `context` no es una variable declarada en el entorno CEL de
`response.success.headers[].json.properties[].expression` de Authorino v0.26.2.

**Fix:** los *well-known attributes* de Kuadrant (RFC
[`0002-well-known-attributes`](https://github.com/Kuadrant/architecture/blob/main/rfcs/0002-well-known-attributes.md))
exponen `source.principal` / `destination.principal` **directo, sin el prefijo
`context.`** — mapean 1:1 al `AttributeContext.Peer.principal` de Envoy pero como
variables CEL de primer nivel. Con:

```yaml
response:
  success:
    headers:
      x-src-principal: { plain: { expression: "source.principal" } }
      x-dst-principal: { plain: { expression: "destination.principal" } }
```

el `AuthConfig` compila y reconcilia sin error (confirmado en el log crudo de
Authorino, `"msg":"resource reconciled"` sin `"level":"error"` posterior al fix —
**ojo:** `AuthConfig.status.conditions` quedó *stale* mostrando el error viejo mucho
después de que el reconcile realmente había tenido éxito; para validar salud del
`AuthConfig` en esta versión conviene mirar el log crudo de `authorino`, no
confiar ciegamente en `.status.conditions`).

### Paso 2: el valor evaluado llega vacío en la topología Gateway

Con la expresión corregida, se probaron tres variantes de header de debug:

1. `plain.value: "hello-world"` (string estático, sin CEL) → **sí aparece** en el
   request reenviado al backend, aunque serializado mal (bug de Kuadrant/wasm-shim,
   imprime el `%v` de un struct Go en vez del string:
   `X-Debug-Static: "{[34 104 101 108 108 111 45 119 111 114 108 100 34] <nil>}"` —
   son los bytes ASCII de `"hello-world"`). Sirve igual como prueba de que el
   mecanismo de inyección de headers **está bien wireado**.
2. `plain.expression: "source.principal"` / `"destination.principal"` →
   **el header no aparece en absoluto** (ni en la respuesta al cliente ni
   reenviado al backend). Ausencia total, no un valor vacío visible — consistente
   con que Kuadrant omite el header cuando el CEL evalúa a `""`.
3. `plain.expression: "request.headers['x-forwarded-client-cert']"` → **tampoco
   aparece**. No hay XFCC que leer en ese punto.

El log crudo de Authorino (`"incoming authorization request"`) para el hop
caller-a→Gateway solo trae `source.address` (IP:puerto del sidecar de caller-a),
`destination.address` (IP:puerto del pod del Gateway) y `request.http`
(method/path/host/scheme) — **ningún campo de certificado o principal**, ni en el
compact log ni reflejado en los headers reenviados.

### Paso 3: causa raíz confirmada — el listener del Gateway es plaintext

`envoy config_dump` del pod `spike-istio-*` (vía `oc exec ... -c istio-proxy --
curl -s localhost:15000/config_dump`), sección `ListenersConfigDump`, listener
`0.0.0.0_80` (el que expone el `Gateway`):

```json
{"name": "0.0.0.0_80", "address": {"socket_address": {"address": "0.0.0.0", "port_value": 80}},
 "filterChains": [{"filterChainMatch": null, "transportSocket": null}]}
```

`transportSocket: null` — **no hay TLS/mTLS configurado en ese listener en
absoluto**. Búsquedas globales en el config_dump de `forward_client_cert_details`,
`require_client_certificate`, `ISTIO_MUTUAL`/`istio_mutual` no encontraron ninguna
coincidencia real. Esto es coherente con el diseño de Gateway API: un `Gateway`
`gatewayClassName: istio` con `listeners[].protocol: HTTP` genera un listener Envoy
en modo *router* (no *sidecar*) que sigue el protocolo declarado literalmente — no
hereda el mTLS automático que Istio aplica al tráfico sidecar-a-sidecar
interceptado por iptables (`virtualInbound`, gobernado por `PeerAuthentication`).
El cluster no tiene ninguna `GatewayClass` de tipo *waypoint* (`oc get gatewayclass`
solo lista `istio` e `istio-remote`), que sería el mecanismo estándar de Istio
Ambient para meter un punto de policy-attachment *dentro* del path mTLS de la malla.

### Contraprueba: el mecanismo SPIFFE/mTLS de Istio sí distingue caller-a de caller-b (sidecar-a-sidecar directo, sin pasar por el Gateway)

```
$ oc exec caller-a -c caller-a -- curl -s http://echo-backend.spike-b.svc.cluster.local/anything
...
"X-Forwarded-Client-Cert": "By=spiffe://cluster.local/ns/spike-b/sa/default;Hash=9104ff...;Subject=\"\";URI=spiffe://cluster.local/ns/spike-b/sa/caller-a"

$ oc exec caller-b -c caller-b -- curl -s http://echo-backend.spike-b.svc.cluster.local/anything
...
"X-Forwarded-Client-Cert": "By=spiffe://cluster.local/ns/spike-b/sa/default;Hash=471cc4...;Subject=\"\";URI=spiffe://cluster.local/ns/spike-b/sa/caller-b"
```

El `URI=` de la SAN del certificado cliente distingue perfectamente `sa/caller-a`
de `sa/caller-b` — **mismo namespace, SAs distintas, hashes de cert distintos**.
Esto prueba que el mecanismo subyacente (mTLS + SPIFFE de Istio) funciona
exactamente como se necesita para la aserción 4 del spec. El bloqueo NO es del
mecanismo SPIFFE en sí, sino específicamente de que **Kuadrant `AuthPolicy` solo
puede adjuntarse a `Gateway`/`HTTPRoute`** (modelo de policy attachment de Gateway
API), y el `Gateway` de este spike no es un punto mTLS.

### Conclusión y próximos pasos sugeridos (fuera de alcance de este spike)

- **Variable `spiffe_principal_expression` de la tarea 8: NO hay un valor que
  entregar** — con esta topología (`Gateway` API HTTP + `AuthPolicy` de Kuadrant)
  ninguna expresión CEL puede leer el principal del caller porque el dato
  simplemente no llega a Authorino en ese hop.
- Caminos posibles para destrabar (a evaluar en conjunto, no implementados acá):
  (a) Istio Ambient + *waypoint* proxy (`gatewayClassName` tipo waypoint) como
  punto de `AuthPolicy` — el waypoint sí se sienta dentro del path mTLS por
  servicio/SA; requiere instalar componentes Ambient (ztunnel) no presentes en
  este cluster. (b) Configurar el listener del `Gateway` como `HTTPS` con
  validación de client-cert contra la CA raíz de Istio — no es un patrón
  soportado de forma nativa por el ALPN `istio-peer-exchange` que usan los
  sidecars, requeriría investigación adicional. (c) Abandonar Kuadrant/Authorino
  para esta aserción puntual y usar la `AuthorizationPolicy` nativa de Istio
  (`source.principals`), que sí opera a nivel sidecar/mTLS sin round-trip a un
  ext_authz externo — pero se aparta del diseño Kuadrant-céntrico de la PoC.

## Spike C — wristband vía TLS Mutual
**Fecha:** 2026-08-04
**Veredicto:** BLOCKED — el bundle de Gateway API que instala el Ingress Operator
de OpenShift en este cluster (canal `standard`, `bundle-version: v1.3.0`) **no
tiene ningún mecanismo** para pedir/validar el client cert en un `Gateway` de
Gateway API. Ni `frontendValidation` (el campo que asumía el brief) ni un
`mode: Mutual` standalone existen en el schema real. Confirmado por tres vías
independientes (schema, prune test, `config_dump` de Envoy en vivo). El bloqueo
es previo y de raíz distinta al de Spike B, pero llega a la misma conclusión
práctica: este mecanismo no es viable en la topología Gateway API de este
cluster tal cual está.

Con evidencia positiva importante igual: el schema real de `authentication.x509`
de Authorino quedó confirmado, y una `AuthPolicy` con ese schema real **sí llega
a `Enforced=True`** — el problema no es la `AuthPolicy` en sí, es que nunca le
llega nada que autenticar.

### Paso 1: certs y secrets — sin cambios respecto al brief

Se generaron tal cual el Step 1 del brief (CA propia, cert de servidor con SAN
`spike-gateway.spike-c.svc.cluster.local`, client cert con `CN=payments`, clave
de firma del wristband independiente). Secrets `gateway-tls` (tls.crt/tls.key/ca.crt)
y `wristband-signing-key` creados en `spike-c` — este último tuvo que
recrearse luego en `kuadrant-system` (ver Paso 3).

### Paso 2: el listener HTTPS Mutual — bloqueado en el schema, no solo en la sintaxis

`oc explain gateway.spec.listeners.tls --recursive` en este cluster expone
**solo tres campos**: `certificateRefs`, `mode` (enum `Terminate`, `Passthrough`
— **sin `Mutual`**), y `options` (`map[string]string` genérico para tuning tipo
cipher-suites, no para referenciar un CA secret). **No existe `frontendValidation`
en ningún path** (ni bajo `listeners[].tls`, confirmado con `oc explain` y con
el dump completo del schema OpenAPI de la CRD).

La anotación de la propia CRD lo explica:
```
gateway.networking.k8s.io/bundle-version: v1.3.0
gateway.networking.k8s.io/channel: standard
```
`frontendValidation` (GEP-91 / GEP-1897, client-cert validation) es parte del
**canal `experimental`** de Gateway API, no del `standard` — y el Ingress
Operator de OpenShift 4.21 solo instala el canal `standard` (mismo patrón que
ya se había visto con `backendtlspolicies`, ver "Entorno de spikes" arriba). No
se puede instalar el canal experimental a mano: la `ValidatingAdmissionPolicy`
del Ingress Operator rechaza cualquier `apply`/`replace` externo sobre esos CRDs,
y Task 2 estableció explícitamente no tocarlos.

**Prueba empírica de que el campo no sobrevive (structural pruning):** se aplicó
el YAML del Step 2 tal cual lo escribe el brief, con `frontendValidation.caCertificateRefs`
incluido. El `apply` no dio error — pero el objeto guardado en etcd **no tiene el
campo**:
```yaml
spec:
  listeners:
  - tls:
      certificateRefs:
      - group: ""
        kind: Secret
        name: gateway-tls
      mode: Terminate
      # frontendValidation: pruneado silenciosamente por el apiserver
```

**Confirmación final, en vivo, contra Envoy:** el `Gateway` con `gatewayClassName: istio`
sí auto-desplegó su propio pod+Service (`spike-gateway-istio`, `Deployment` 1/1
Running, `Service` tipo `LoadBalancer`). El `config_dump` del listener `0.0.0.0_443`
muestra el `DownstreamTlsContext` real que arma Envoy:
```json
{
  "name": "envoy.transport_sockets.tls",
  "typed_config": {
    "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext",
    "common_tls_context": {
      "tls_certificate_sds_secret_configs": [
        { "name": "kubernetes-gateway://spike-c/gateway-tls", "sds_config": {"ads": {}} }
      ]
    },
    "require_client_certificate": false
  }
}
```
`require_client_certificate: false` — no hay forma, con este `Gateway` API CRD,
de subir ese flag a `true` desde el objeto Kubernetes.

### Paso 3: schema real de `authentication.x509` (confirmado vía `oc explain`, distinto del asumido en el brief)

El brief asumía un campo `allowedIssuers` para el `x509` rule. **No existe.** El
schema real (`oc explain authpolicy.spec.rules.authentication.x509 --recursive`,
`apiVersion: kuadrant.io/v1`):

```
x509:
  allNamespaces: <boolean>
  selector: <Object> -required-        # label selector de Secrets K8s
    matchLabels: <map[string]string>
    matchExpressions: [...]
  source: <Object>
    xfccHeader: <string>          # uno de estos tres, mutuamente excluyentes
    clientCertHeader: <string>    # formato RFC 9440 (Client-Cert header)
    expression: <string>          # CEL custom
```

Descripción textual (`oc explain`): *"Authentication based on client X.509
certificates. The certificates presented by the clients must be signed by a
trusted CA whose certificates are stored in Kubernetes secrets."* — es decir,
Authorino **no lee la sesión TLS negociada por Envoy directamente**: valida el
cert contra su propio trust store (Secrets K8s con `tls.crt`/`ca.crt`,
etiquetados con `authorino.kuadrant.io/managed-by=authorino` + un label propio
que matchea `x509.selector.matchLabels`), y **necesita que el cert del cliente
le llegue serializado en un header** (`xfccHeader` o `clientCertHeader`) — el
mismo problema de fondo que Spike B: sin mTLS real en el listener, no hay XFCC
que generar, así que da igual qué `source` se declare.

Por default, los Secrets de trust store deben vivir en el **mismo namespace
que el `AuthConfig`** (no el de la `AuthPolicy`/`Gateway`) salvo que se declare
`x509.allNamespaces: true`.

### Paso 3bis (hallazgo no anticipado): el `AuthConfig` generado vive en `kuadrant-system`, no en el namespace del target

Este Authorino corre como instancia **cluster-wide, singleton**: el
`kuadrant-operator` materializa el `AuthConfig` derivado de cada `AuthPolicy`
siempre en el namespace `kuadrant-system` (nombre = hash de la policy), sin
importar en qué namespace vive la `AuthPolicy`/`Gateway` target (`spike-c` acá).
Consecuencia práctica: **el Secret de `signingKeyRefs` del wristband también se
resuelve relativo al namespace del `AuthConfig`** (`kuadrant-system`), no al de
la `AuthPolicy`. El campo `signingKeyRefs[].name` no admite `namespace` (confirmado
con `oc explain`). Con el secret `wristband-signing-key` solo en `spike-c`, Authorino
logueaba en loop: `"error":"Secret \"wristband-signing-key\" not found"`. Recreando
el mismo secret en `kuadrant-system` (y agregando `x509.allNamespaces: true`, para
no tener que además replicar el Secret de la CA) el `AuthConfig` reconcilió sin error.

**Gotcha heredado de Spike B, reproducido:** `AuthConfig.status.conditions`
quedó *stale* mostrando el error viejo (`Secret ... not found`) varios minutos
después de que el log crudo de `authorino` ya mostraba `"resource reconciled"`
sin error — confirmar salud por el log, no solo por `.status`.

### Paso 4: `AuthPolicy` con el schema real — SÍ llega a `Enforced=True`

Con el schema corregido (`x509.selector` + `x509.source.xfccHeader` +
`allNamespaces: true`, secret de wristband en `kuadrant-system`), la policy
reconcilia limpio:

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: { name: spike-issuer, namespace: spike-c }
spec:
  targetRef: { group: gateway.networking.k8s.io, kind: Gateway, name: spike-gateway }
  rules:
    authentication:
      client-cert:
        x509:
          allNamespaces: true
          selector: { matchLabels: { spike: c } }
          source: { xfccHeader: x-forwarded-client-cert }
    response:
      success:
        headers:
          x-service-identity:
            wristband:
              issuer: "http://s2s-jwks.kuadrant-system.svc.cluster.local:8080"
              tokenDuration: 300
              customClaims:
                namespace: { expression: "auth.identity.CommonName" }   # NO VERIFICADO EN TRÁFICO REAL — ver Paso 5
              signingKeyRefs: [{ name: wristband-signing-key, algorithm: RS256 }]
```

```
$ oc get authpolicy spike-issuer -n spike-c -o jsonpath='{.status.conditions}'
[{"type":"Accepted","status":"True","reason":"Accepted","message":"AuthPolicy has been accepted"},
 {"type":"Enforced","status":"True","reason":"Enforced","message":"AuthPolicy has been successfully enforced"}]
$ oc get authconfig -n kuadrant-system -o jsonpath='{.items[0].status.conditions}'
[{"type":"Available","status":"True","reason":"HostsLinked"},
 {"type":"Ready","status":"True","reason":"Reconciled"}]
```
(Requirió además crear el echo backend + un `HTTPRoute` colgando del `Gateway`
— sin ruta atada, `Enforced` quedaba en `False`/`Unknown` con `"AuthPolicy is
not in the path to any existing routes"`.)

### Paso 5: tráfico real — el rechazo es HTTP 401, NO un fallo de TLS handshake

Con el `Gateway` + `AuthPolicy` `Enforced=True`, tráfico real vía
`port-forward` al Service del gateway:

**Sin client cert:**
```
* SSL connection using TLSv1.3 ... Server certificate verify ok.
> GET / HTTP/2
< HTTP/2 401
< www-authenticate: Basic realm="client-cert"
< x-ext-auth-reason: failed to extract XFCC header: header x-forwarded-client-cert not found in request
```

**Con `--cert client-payments.crt --key client-payments.key`:** idéntico —
mismo handshake TLS exitoso (el cliente ofrece el cert, pero el servidor nunca
lo pide vía `CertificateRequest`, así que TLS lo ignora), mismo `401` con el
mismo `x-ext-auth-reason`.

**Conclusión empírica, respondiendo la pregunta central del spike:** el rechazo
sin cert **no ocurre en el handshake TLS** (que siempre completa OK, server-only
auth) — ocurre más tarde, a nivel HTTP, vía el `ext_authz` de Kuadrant, porque
nunca existe un XFCC que leer. Es el resultado opuesto al que pide la aserción
1 de `verify.sh` (Task 11): con este mecanismo, un caller sin cert **sí llega a
HTTP** (solo que recibe 401), no es rechazado a nivel de conexión.

**Corolario:** el `customClaims.namespace.expression: "auth.identity.CommonName"`
del Paso 4 **nunca se pudo ejercitar con una autenticación x509 exitosa** — todo
request de prueba fue rechazado antes de llegar a evaluar `response.success`
(no hay forma de producir una request con XFCC/client-cert header real dado el
bloqueo del Paso 2). El nombre de campo (`CommonName`) queda **sin confirmar
empíricamente**; es una suposición razonable por convención de Go
(`x509.Certificate.Subject.CommonName`) pero no se vio en un dump real de
`auth.identity`, a diferencia de `source.principal`/`destination.principal` en
Spike B que sí se validaron contra tráfico real.

### Paso 6: JWKS / OIDC — el path real usa namespace+nombre del `AuthConfig`, no de la `AuthPolicy`

El brief asumía el path `/{authpolicy-namespace}/{authpolicy-name}/{header}/...`
(`/spike-c/spike-issuer/x-service-identity/...`) — **da 404**. El path real usa
el namespace y nombre del **`AuthConfig` generado** (`kuadrant-system` + el hash),
no los de la `AuthPolicy`:

```
$ oc -n kuadrant-system get svc authorino-authorino-oidc
authorino-authorino-oidc   ClusterIP   10.217.5.93   <none>   8083/TCP

$ curl http://localhost:8083/kuadrant-system/5868b8a7a296380fb4dba1698ab27210acac591506f78dcde142ea2065988b73/x-service-identity/.well-known/openid-configuration
{"issuer":"http://s2s-jwks.kuadrant-system.svc.cluster.local:8080",
 "jwks_uri":"http://s2s-jwks.kuadrant-system.svc.cluster.local:8080/.well-known/openid-connect/certs",
 "id_token_signing_alg_values_supported":["ES256","ES384","ES512","RS256","RS384","RS512"]}

$ curl http://localhost:8083/kuadrant-system/5868b8a7a296380fb4dba1698ab27210acac591506f78dcde142ea2065988b73/x-service-identity/.well-known/openid-connect/certs
{"keys":[{"use":"sig","kty":"RSA","kid":"wristband-signing-key","alg":"RS256", "n":"...", "e":"AQAB"}]}
```
`kid = wristband-signing-key` (= nombre del Secret con la clave de firma). El
puerto real del servicio OIDC es **8083** (no 8080 como asumía el brief); el
`issuer` configurado en la `AuthPolicy` sigue siendo un hostname `s2s-jwks...:8080`
arbitrario (no necesita resolver — solo es un string que Authorino usa/emite
como `iss` del JWT, distinto del puerto real del Service).

### Conclusión y próximos pasos sugeridos (fuera de alcance de este spike)

El mecanismo "TLS Mutual explícito en el `Gateway` + `authentication.x509`" es
**correcto en el diseño de Kuadrant/Authorino** (el schema existe, la policy
reconcilia, el flujo del wristband funciona hasta donde se pudo probar) pero
**no es aplicable en la topología Gateway API de este cluster concreto**,
porque el `Gateway` de Gateway API (canal `standard`, bundle v1.3.0 del Ingress
Operator de OpenShift) no tiene ningún campo para pedir/validar el client cert
en el listener. Caminos posibles a evaluar con el usuario (no implementados):
(a) usar el `Gateway` **nativo de Istio** (`networking.istio.io/v1`, confirmado
presente en este cluster vía `oc api-resources`) en vez del de Gateway API para
*este* listener puntual — soporta `tls.mode: MUTUAL` de forma nativa desde hace
años, pero se aparta del patrón "Gateway API vainilla" que se quería validar
compatible con `nullplatform/base`; (b) instalar el canal `experimental` de
Gateway API en un cluster que no sea CRC/OpenShift (donde no exista la
`ValidatingAdmissionPolicy` que protege los CRDs), para poder usar
`frontendValidation` tal cual lo diseña Kuadrant upstream; (c) terminar el mTLS
en una capa distinta del `Gateway` (p. ej. un sidecar/proxy propio delante,
o Istio Ambient + waypoint, mismo camino (a) que ya había quedado abierto en
Spike B) y dejar que ese componente sea el que exponga el CN via XFCC hacia
Authorino.

## Spike D — split en dos hops (sidecar→Gateway local, Gateway→host externo)
**Fecha:** 2026-08-04
**Veredicto:** OK — funcionó el mecanismo primario en ambos hops, **sin
necesidad del fallback `VirtualService`** del Step 4 del brief. El `HTTPRoute`
con `backendRefs kind: Hostname` sobre el `Gateway` fue aceptado
(`Accepted=True`, `ResolvedRefs=True`) al primer intento. Apareció sí un
gotcha real y no anticipado en el propio hop 2 (no relacionado con el
mecanismo `kind: Hostname` en sí, sino con `auto_sni` de Istio) que bloqueaba
el tráfico end-to-end hasta fijar el `sni` explícito en la `DestinationRule`.

### Resumen

Esta tarea NO depende de Kuadrant — es pura mecánica de ruteo Istio/Gateway
API, sin `AuthPolicy` ni `apiKey` de por medio. Los módulos de kernel
(`xt_REDIRECT`/`xt_owner`/`iptable_nat`) seguían cargados en el nodo `crc` (no
hubo `crc stop`/`start` de por medio) — no hizo falta `modprobe`. Todos los
pods (`local-backend`, `client`) se crearon con `oc run` directo (gotcha de
SCC heredado de Spike B), y salieron `Running` al primer intento.

### Paso 1: escenario base — sin sorpresas

`spike-d` namespace con `istio-injection=enabled`, `local-backend`
(`ealen/echo-server:0.9.2`, vía `oc run`) expuesto como `reports-local`,
`client` (`curlimages/curl:8.10.1`, vía `oc run`) y el `Gateway`
`spike-gateway` (`gatewayClassName: istio`, listener HTTP puro, igual que
Spikes C/F) tal cual el Step 1 del brief. El `Service` auto-provisionado por
el `Gateway` confirmó el mismo patrón de nombre ya visto en Spikes C/F:
`spike-gateway-istio` (no matcheó el selector `istio.io/gateway-name` que
sugería el brief para buscarlo — se confirmó por `oc get svc -n spike-d`
directo).

### Paso 2: Hop 1 — split ponderado sidecar→backend-local / sidecar→Gateway — limpio, sin gotchas

`VirtualService` `split-hop1` tal cual el Step 2 del brief, con el
`destination` del segundo peso apuntando a
`spike-gateway-istio.spike-d.svc.cluster.local`. Sin `HTTPRoute` todavía
colgando del `Gateway`, un loop de 20 requests contra
`reports-local.spike-d.svc.cluster.local/get` repartió exactamente **10/10**
entre `200` (backend local) y `404` (llegó al Gateway, sin ruta aún que lo
resuelva — comportamiento esperado en este punto intermedio, confirma que el
tráfico efectivamente llega al Service del Gateway). Tráfico 100% in-cluster,
sin `ServiceEntry`, tal cual anticipaba el brief — cero fricción.

### Paso 3: Hop 2 — el `backendRef kind: Hostname` fue ACEPTADO, no hizo falta el fallback

`ServiceEntry` + `DestinationRule` + `HTTPRoute` `gateway-egress` tal cual el
Step 3 del brief (`parentRefs` al `Gateway`, `backendRefs` con
`group: networking.istio.io`, `kind: Hostname`, `name: httpbin.org`). El
`apply` no dio ningún error de admisión, y el status confirmó lo que el brief
marcaba como la incógnita central del spike:

```
$ oc get httproute gateway-egress -n spike-d -o jsonpath='{.status.parents}' | jq
[{
  "controllerName": "istio.io/gateway-controller",
  "parentRef": {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": "spike-gateway"},
  "conditions": [
    {"type": "Accepted", "status": "True", "reason": "Accepted", "message": "Route was valid"},
    {"type": "ResolvedRefs", "status": "True", "reason": "ResolvedRefs", "message": "All references resolved"}
  ]
}]
```

`Accepted=True` / `ResolvedRefs=True` — el `backendRef kind: Hostname` es un
valor sintético que Istio interpreta directo en su implementación de Gateway
API (no es un CRD real: `oc api-resources | grep -i hostname` no devuelve
nada, y no hace falta ningún `ReferenceGrant`). El `dynamic_route_configs` del
`config_dump` de Envoy confirmó que la ruta efectivamente resuelve al cluster
correcto (`outbound|443||httpbin.org`) — la traducción Gateway API → Envoy
route funciona limpio. **No hizo falta el fallback del Step 4
(`VirtualService` clásico con `gateways: ["spike-gateway"]`)** — quedó sin
aplicar.

### Gotcha no anticipado: `auto_sni: true` rompe el tráfico real (no es un problema del `backendRef kind: Hostname`, es de la `DestinationRule`)

Con el `HTTPRoute`/`ServiceEntry`/`DestinationRule` tal cual el brief
(`trafficPolicy.tls: { mode: SIMPLE }`, sin `sni` explícito), el tráfico real
contra el `Service` del Gateway falló consistentemente:

```
$ oc exec client -c client -n spike-d -- curl -s -D - -o /dev/null http://spike-gateway-istio.spike-d.svc.cluster.local/get
HTTP/1.1 503 Service Unavailable
...
upstream connect error or disconnect/reset before headers. retried and the latest reset reason: remote connection failure
```

Causa raíz confirmada por `config_dump` del cluster `outbound|443||httpbin.org`:
la `typed_extension_protocol_options` traía `auto_sni: true` — Envoy deriva el
SNI del TLS ClientHello hacia `httpbin.org` a partir del header `Host`/
`:authority` del request **entrante**, no del host real de la `DestinationRule`.
Como el cliente le pega al `Gateway` con
`Host: spike-gateway-istio.spike-d.svc.cluster.local` (no `httpbin.org`), el
SNI que sale hacia el upstream real es el equivocado — confirmado
enviando manualmente `-H "Host: httpbin.org"` (con eso, `200 OK` inmediato,
sin tocar ningún YAML). Esto además iba a romper el Step 5 sin arreglo, porque
el cliente en el flujo combinado siempre manda
`Host: reports-local.spike-d.svc.cluster.local` — nunca `httpbin.org`.

**Fix aplicado** (una línea en la `DestinationRule`, sin tocar el `HTTPRoute`
ni el `ServiceEntry`): fijar el SNI de forma explícita, independiente del
`Host` entrante:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: { name: external-target, namespace: spike-d }
spec:
  host: httpbin.org
  trafficPolicy:
    tls: { mode: SIMPLE, sni: httpbin.org }
```

Con el fix, tráfico real sin necesidad de tocar ningún header del cliente:

```
$ oc exec client -c client -n spike-d -- curl -s -D - -o /dev/null http://spike-gateway-istio.spike-d.svc.cluster.local/get
HTTP/1.1 200 OK
...
```

**Nota para Task 10 (`mesh_routing.tf`):** cualquier `DestinationRule` que
origine TLS hacia un host externo real (no solo `httpbin.org` de este spike)
necesita `trafficPolicy.tls.sni` explícito si el tráfico que la alimenta no
llega ya con el `Host`/`:authority` correcto — que va a ser el caso general en
la Fase 1, donde el caller le habla al `Gateway` por su propio Service DNS
interno, no por el hostname externo real.

### Paso 5: medición combinada end-to-end (hop 1 + hop 2)

Con el fix aplicado, loop de 20 requests contra
`reports-local.spike-d.svc.cluster.local/get` (weight 50/50 en `split-hop1`),
clasificando por contenido del body (`httpbin` vs. el JSON propio de
`ealen/echo-server`):

```
9 GATEWAY->HTTPBIN
11 LOCAL-BACKEND
```

~50/50 (9/11 sobre 20 muestras). Los extremos confirmaron el mecanismo sin
ambigüedad:

- `weight: 100` local / `weight: 0` gateway → **20 LOCAL-BACKEND / 0 GATEWAY**
- `weight: 0` local / `weight: 100` gateway → **0 LOCAL-BACKEND / 20 GATEWAY->HTTPBIN**

### Conclusión

Los dos hops de la corrección post spike B/C quedan validados de
punta a punta en este cluster:

1. **Hop 1** (sidecar del llamador → backend local **o** Service del Gateway
   propio): tráfico 100% in-cluster, sin `ServiceEntry`, split ponderado
   exacto vía `VirtualService` estándar — sin gotchas.
2. **Hop 2** (el propio `Gateway` → host externo real): mecanismo elegido
   **`HTTPRoute` con `backendRefs kind: Hostname`** (`group:
   networking.istio.io`) — **funcionó, no hizo falta el fallback
   `VirtualService`**. El único bloqueo fue el gotcha de `auto_sni`/SNI
   explícito en la `DestinationRule`, ortogonal al mecanismo de `backendRef`
   en sí y ya resuelto arriba.

**Para Task 10 (`mesh_routing.tf`):** usar el YAML de `HTTPRoute` +
`ServiceEntry` + `DestinationRule` (con `sni` explícito) documentado en esta
sección tal cual — es el que funcionó en tráfico real, no el del Step 3 del
brief sin el fix.

### Limpieza

```bash
oc delete project spike-d
```

## Spike E — AuthPolicy sobre HTTPRoute de malla
**Fecha:** 2026-08-04
**Veredicto:** NO FUNCIONA — confirmado por una tercera vía, con causa raíz
**distinta** a la de Spike B. El header `x-debug-principal` llega vacío (ausente,
igual que en Spike B), pero esta vez no es porque falte mTLS en el hop: es
porque Kuadrant **nunca llegó a generar ningún mecanismo de enforcement**
(`AuthConfig`, `EnvoyFilter`, `WasmPlugin`) para una `AuthPolicy` targeteando un
`HTTPRoute` cuyo único `parentRef` es un `Service` (patrón GAMMA / malla
este-oeste). La hipótesis central de esta tarea —que adjuntar la policy a ese
tipo de `HTTPRoute` haría que el `ext_authz` se evaluara en el sidecar del
propio llamador— cae en un punto **previo** al que se imaginaba: Kuadrant ni
siquiera llega a intentarlo, porque su motor de topología no reconoce ese
`HTTPRoute` como parte de ningún camino con un `Gateway` real.

### Resumen

Se recreó la topología base de Spike B (namespace `spike-e`, `caller-a`/
`caller-b` con SAs distintas, `PeerAuthentication` `STRICT`) sin sorpresas — a
diferencia de spikes anteriores, los módulos de kernel (`xt_REDIRECT`,
`xt_owner`, `iptable_nat`) seguían cargados en el nodo `crc` (no hubo
`crc stop`/`start` de por medio) y no hizo falta el `modprobe`. Se usó `oc run`
también para `echo-backend` (no `Deployment`), aplicando el fix de SCC
descubierto en Spike B (Paso 0.1) preventivamente en vez de reproducir el
fallo.

El `HTTPRoute` de malla (`parentRefs: [{kind: Service, name: echo-backend}]`)
**sí fue aceptado por Istio** — este es un hallazgo positivo en sí mismo, y
responde el primer punto de fallo posible que anticipaba el Step 2 del brief:

```
$ oc get httproute mesh-route -n spike-e -o jsonpath='{.status.parents}' | jq
[{
  "controllerName": "istio.io/gateway-controller",
  "parentRef": {"group": "", "kind": "Service", "name": "echo-backend", "port": 80},
  "conditions": [
    {"type": "Accepted", "status": "True", "reason": "Accepted", "message": "Route was valid"},
    {"type": "ResolvedRefs", "status": "True", "reason": "ResolvedRefs", "message": "All references resolved"}
  ]
}]
```

Istio soporta el patrón GAMMA (`HTTPRoute` parenteado a un `Service` en vez de
un `Gateway`) sin objeciones. El bloqueo aparece un paso después, en Kuadrant.

### Paso 3: `AuthPolicy` — `Enforced=False`, mismo mensaje que Task 4, pero confirmado NO stale esta vez

```
$ oc get authpolicy spike-mesh-auth -n spike-e -o jsonpath='{.status.conditions}' | jq
[
  {"type": "Accepted", "status": "True", "reason": "Accepted", "message": "AuthPolicy has been accepted"},
  {"type": "Enforced", "status": "False", "reason": "Unknown", "message": "AuthPolicy is not in the path to any existing routes"}
]
```

A diferencia de Spikes B/C (donde el gotcha de `.status` stale hacía necesario
mirar el log crudo para no confundirse), acá se verificó **activamente** que
esto no es staleness sino el estado real y final:

- El log del `kuadrant-operator-controller-manager` muestra, en el mismo
  segundo del `apply` (`15:43:56`), que el reconciler sí corrió
  (`AuthorinoIstioIntegrationReconciler`, `IstioExtensionReconciler.buildWasmConfigs`
  `status: started` → `completed`) — pero, a diferencia de los eventos
  equivalentes en Spike C (que sí generaron `EnvoyFilter`+`AuthConfig`, ver
  log línea `2026-08-03T22:54:10`), **ningún evento posterior crea
  `AuthConfig`, `EnvoyFilter` ni `WasmPlugin`** para `spike-mesh-auth`.
- `oc get authconfig -A`, `oc get envoyfilter -A`, `oc get wasmplugin -A` →
  **`No resources found`** en las tres, en todo el cluster. Kuadrant nunca
  materializó ningún objeto derivado de esta `AuthPolicy` — ni siquiera un
  `AuthConfig` roto o con error (que sí hubo en Spike B/C). La policy quedó
  aceptada a nivel API pero completamente inerte.
- El log de `authorino` no tiene ninguna entrada nueva desde el apply (las
  últimas son de la sesión anterior, teardown de `spike-c` a las
  `13:42:46Z`) — consistente con que nunca le llegó ningún `AuthConfig` que
  reconciliar.

**Conclusión de este paso:** el mensaje "AuthPolicy is not in the path to any
existing routes" es literal y preciso desde la perspectiva de Kuadrant: su
motor de resolución de topología (necesario para saber en qué `Gateway`/proxy
inyectar el filtro WASM de `ext_authz`) camina el grafo `Gateway → HTTPRoute →
Service`. Un `HTTPRoute` cuyo único `parentRef` es un `Service` no tiene ningún
`Gateway` como ancestro — el grafo no tiene raíz — así que Kuadrant no tiene
dónde construir el enforcement, y ni siquiera lo intenta (no genera un
`AuthConfig` con error; no genera nada). Esto es distinto del bloqueo de Spike
B (ahí sí había un `Gateway`, sí había `AuthConfig`, y el dato llegaba vacío
por falta de mTLS en el listener) — acá el bloqueo es un nivel más arriba, en
el propio modelo de policy-attachment de Kuadrant v1.5.2, que asume (al menos
en esta versión) que toda `AuthPolicy` cuelga, directa o indirectamente, de un
`Gateway` real.

### Paso 4: tráfico real — confirma el vacío, y revalida la contraprueba de Spike B

```
$ oc exec caller-a -c caller-a -- curl -s -D - -o /dev/null http://echo-backend.spike-e.svc.cluster.local/anything
HTTP/1.1 200 OK
(sin x-debug-principal)

$ oc exec caller-b -c caller-b -- curl -s -D - -o /dev/null http://echo-backend.spike-e.svc.cluster.local/anything
HTTP/1.1 200 OK
(sin x-debug-principal)
```

Ambos requests pasan derecho con `200 OK` — ninguna autorización se aplicó en
absoluto (coherente con que no existe ningún `WasmPlugin`/`EnvoyFilter` que
intercepte el tráfico). Se descartó que fuera un problema del sidecar en sí
inspeccionando el `config_dump` de Envoy del pod `echo-backend`: el string
`ext_authz` aparece, pero únicamente dentro de
`BootstrapConfigDump.bootstrap.static_resources` → listado de **extensiones
compiladas en el binario** (`envoy.filters.http.ext_authz`,
`envoy.filters.network.ext_authz`, categoría `envoy.filters.*`, sin
`type_urls` activos ni cluster asociado) — es el catálogo de filtros
disponibles, no una filter chain activa. Ningún listener tiene un filtro
`ext_authz` real configurado.

Como contraprueba (igual que en Spike B), se confirmó que el mecanismo mTLS/
SPIFFE de Istio en sí **sigue distinguiendo perfectamente** `caller-a` de
`caller-b` en este mismo tráfico — el cuerpo de la respuesta de
`echo-server` (que hace echo de los headers recibidos) trae el XFCC completo:

```
caller-a → X-Forwarded-Client-Cert: By=spiffe://cluster.local/ns/spike-e/sa/default;
  Hash=866f64f1...;Subject="";URI=spiffe://cluster.local/ns/spike-e/sa/caller-a

caller-b → X-Forwarded-Client-Cert: By=spiffe://cluster.local/ns/spike-e/sa/default;
  Hash=f522d81d...;Subject="";URI=spiffe://cluster.local/ns/spike-e/sa/caller-b
```

Es decir: el dato que la hipótesis quería recuperar (identidad per-workload
via SPIFFE) **sigue estando disponible en el XFCC del hop sidecar-a-sidecar**,
tal cual se probó en Spike B. Lo que no funciona es específicamente que
Kuadrant pueda leerlo desde ahí a través de una `AuthPolicy` sobre un
`HTTPRoute` de malla — el problema no es de Istio ni de mTLS, es de la
cobertura de policy-attachment de Kuadrant.

### Step 5 (wristband) — no ejercitado

Per el propio brief, el Step 5 (acuñar el wristband con `customClaims.principal`)
solo aplica "si funciona" el Step 4. Como el header vino vacío (misma condición
de corte que en Spike B), no se ejecutó — no hay tráfico autenticado real
sobre el cual acuñar nada.

### Conclusión y comparación con Spike B/C

Tres bloqueos independientes, tres causas raíz distintas, mismo resultado
observable (el dato de identidad no llega a Kuadrant):

| Spike | Target de la `AuthPolicy` | Causa raíz | `Enforced` |
|---|---|---|---|
| B | `Gateway` (listener HTTP) | Listener plaintext, sin mTLS — no hay principal que leer | `False`/`Unknown` (via ext_authz llamado, pero campo vacío) — la policy sí corre, el dato es vacío |
| C | `Gateway` (listener HTTPS, x509) | El CRD de Gateway API (canal `standard`) no expone ningún campo para pedir client-cert en el listener | `True` (llegó a Enforced) pero el rechazo es un 401 HTTP, no hay TLS mutual real — nunca hay XFCC que validar |
| **E** | `HTTPRoute` con `parentRef` a `Service` (malla/GAMMA) | Kuadrant no reconoce ningún `Gateway` como ancestro del `HTTPRoute` — no genera ningún mecanismo de enforcement, la policy queda inerte | **`False`, y ni siquiera llega a ejecutarse** (sin `AuthConfig`/`EnvoyFilter`/`WasmPlugin`) |

**Esta tarea confirma, con una tercera vía de evidencia, que la mejora
per-workload (identidad SPIFFE del llamador vía Kuadrant `AuthPolicy`) no es
alcanzable en este cluster con ninguna de las tres formas de policy-attachment
de Gateway API probadas hasta ahora** (`Gateway` HTTP, `Gateway` HTTPS/x509,
`HTTPRoute` de malla). El mecanismo SPIFFE/mTLS subyacente de Istio funciona
correctamente en los tres spikes — el bloqueo es siempre en el punto donde
Kuadrant necesita engancharse a ese dato, y ese punto de enganche (Gateway API
`targetRef`) no tiene, en la versión de Kuadrant probada (`v1.5.2`) y en la
topología de este cluster (OpenShift 4.21, canal `standard` de Gateway API),
ningún camino que preserve la identidad per-workload.

**Recomendación (no aplicada — requiere confirmación del usuario, ver gate del
Step 7 del brief):** el mecanismo namespace-level de Task 4 (con su propio
bloqueo documentado aparte) sigue siendo, junto con mover el sustrato o
esperar una versión de Kuadrant/Gateway API con soporte GAMMA explícito, la
única ruta real hacia adelante. **No corresponde revertir la corrección de
el mecanismo namespace-level** de vuelta a per-workload con la evidencia de este
spike — al contrario, esta tarea la refuerza: confirma por tercera vez, con un
mecanismo de ataque distinto cada vez, que la vía per-workload vía Kuadrant no
es viable en este cluster tal cual está montado.

### Limpieza

```bash
oc delete project spike-e
```

## Spike F — apiKey + inyección transparente de header
**Fecha:** 2026-08-04
**Veredicto:** OK — confirma el mecanismo final de identidad decidido con el
usuario. `authentication.apiKey` de Kuadrant reconcilia limpio, `Enforced=True`
al primer intento, y la inyección transparente del header vía
`requestHeaderModifier` funciona en una **única** ruta de malla (GAMMA,
`HTTPRoute` parenteada a un `Service`) — no hizo falta partirla en dos objetos
como el brief anticipaba como posibilidad. El claim `namespace` del wristband
se puede derivar directo de `auth.identity.metadata.namespace`, sin ambigüedad.

### Resumen

A diferencia de los Spikes B/C/E (todos BLOCKED, cada uno con una causa raíz
distinta al intentar leer identidad *per-workload* vía la sesión mTLS del
sidecar), este spike valida el mecanismo *namespace-level* que el usuario
decidió como definitivo: un token estático (`apiKey`) por namespace, que la
malla inyecta en el request **sin que la app lo sepa**, vía un `HTTPRoute` de
traffic-shaping puro (sin `AuthPolicy` adjunta a él — esa vive en el
`Gateway`). Los dos objetos cumplen roles distintos y no se pisan:

- El **`Gateway`+`AuthPolicy`** (con `authentication.apiKey`) es el punto de
  *enforcement* — igual patrón que Task 4 (Spike C) confirmó necesario para
  que `Enforced` llegue a `True`.
- El **`HTTPRoute` de malla** (`parentRefs: [{kind: Service}]`, patrón GAMMA,
  el mismo que Spike E probó que Kuadrant no puede instrumentar con una
  `AuthPolicy`) se usa acá para lo que **sí** hace nativamente sin involucrar a
  Kuadrant: reescribir headers de tráfico saliente vía
  `RequestHeaderModifier`. Ningún `AuthPolicy` cuelga de esta ruta — es pura
  malla/Envoy.

### Paso 1–2: Gateway + HTTPRoute — sin sorpresas, gotchas conocidos se repiten

Namespace `spike-f`, `istio-injection=enabled`. El backend (`echo-backend`) se
creó con `oc run` (no `Deployment`), reusando preventivamente el fix de SCC de
Spike B (Paso 0.1) — no hizo falta, salió `2/2 Running` al primer intento. Los
módulos de kernel (`xt_REDIRECT`/`xt_owner`/`iptable_nat`) seguían cargados en
el nodo (no hubo `crc stop/start` entre sesiones) — no hizo falta el
`modprobe`.

`Gateway` `spike-gateway` (`gatewayClassName: istio`, listener HTTP puro, sin
Mutual TLS — ya no hace falta con este mecanismo) + `HTTPRoute` `spike-route`
colgando de él, igual que Task 4 (Spike C) confirmó necesario:

```
$ oc get httproute spike-route -n spike-f -o jsonpath='{.status.parents}'
[{"conditions":[{"type":"Accepted","status":"True",...},{"type":"ResolvedRefs","status":"True",...}],
  "controllerName":"istio.io/gateway-controller","parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"spike-gateway"}}]
```

`Gateway.status` quedó `Programmed=False` ("address pending", típico de un
`Service` `LoadBalancer` sin cloud-controller en CRC) — no bloqueante, mismo
comportamiento ya visto en Spike C; el tráfico intra-cluster vía el `Service`
`ClusterIP`/`LoadBalancer` (`spike-gateway-istio.spike-f.svc.cluster.local`)
funciona igual.

### Paso 3: schema real de `authentication.apiKey` — coincide con lo que asumía el brief, con un matiz

```
$ oc explain authpolicy.spec.rules.authentication.apiKey --recursive
FIELD: apiKey <Object>
DESCRIPTION: Authentication based on API keys stored in Kubernetes secrets.
FIELDS:
  allNamespaces	<boolean>
  selector	<Object> -required-
    matchExpressions	<[]Object>
      key	<string> -required-
      operator	<string> -required-
      values	<[]string>
    matchLabels	<map[string]string>
```

Mismo shape que `x509.selector`/`x509.allNamespaces` (Spike C) — un label
selector de Secrets K8s + el flag para buscar cross-namespace. La diferencia
con `x509`: **no existe un campo `source`** (no hay `xfccHeader`/
`clientCertHeader` que declarar) porque `apiKey` no necesita extraer nada de un
header serializado por el proxy — la extracción de la credencial es un
mecanismo genérico, declarado en un campo **hermano** de `apiKey` dentro de la
misma regla nombrada (`authentication.<name>.credentials`), no anidado dentro
de `apiKey`:

```
$ oc explain authpolicy.spec.rules.authentication.credentials --recursive
DESCRIPTION: Defines where credentials are required to be passed in the request...
  If omitted, it defaults to credentials passed in the HTTP Authorization
  header and the "Bearer" prefix prepended to the secret credential value.
FIELDS:
  authorizationHeader	<Object>
    prefix	<string>
  cookie	<Object>
    name	<string> -required-
  customHeader	<Object>
    name	<string> -required-
  queryString	<Object>
    name	<string> -required-
```

El YAML de ejemplo del brief (`credentials: { authorizationHeader: { prefix:
APIKEY } }` como hermano de `apiKey`, no anidado) resultó ser **exactamente**
correcto — la única corrección real fue confirmar que no hay `source` dentro
de `apiKey` (a diferencia de lo que el patrón de `x509` podía sugerir).

### Paso 4: Secret + `AuthPolicy` — `Enforced=True` al primer intento, sin gotcha de namespace

```bash
oc create secret generic payments-apikey --from-literal=api_key=<openssl rand -hex 24> -n spike-f
oc label secret payments-apikey -n spike-f "authorino.kuadrant.io/managed-by=authorino" "kuadrant.io/apikey=spike-f"
```

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: { name: spike-apikey, namespace: spike-f }
spec:
  targetRef: { group: gateway.networking.k8s.io, kind: Gateway, name: spike-gateway }
  rules:
    authentication:
      s2s-key:
        apiKey:
          allNamespaces: true
          selector: { matchLabels: { "kuadrant.io/apikey": "spike-f" } }
        credentials: { authorizationHeader: { prefix: APIKEY } }
    response:
      success:
        headers:
          x-debug-identity:
            json:
              properties:
                identity: { expression: "auth.identity" }
```

```
$ oc get authpolicy spike-apikey -n spike-f -o jsonpath='{.status.conditions}'
[{"type":"Accepted","status":"True","reason":"Accepted"},
 {"type":"Enforced","status":"True","reason":"Enforced","message":"AuthPolicy has been successfully enforced"}]
```

Confirmado también contra el log crudo de `authorino` (disciplina heredada de
Task 4, donde `.status` había quedado *stale*): acá **no hubo staleness** —
`"resource reconciled"` aparece en el mismo segundo que `Enforced` pasa a
`True`, sin ningún error posterior.

**A diferencia de Spike C (x509)**, donde el Secret de identidad tuvo que
recrearse en `kuadrant-system` para el `signingKeyRefs` del wristband aunque
`allNamespaces: true` alcanzaba para el Secret de trust store: acá, con
`allNamespaces: true` en `apiKey`, el Secret **se quedó en `spike-f`** (su
namespace natural) y el `AuthConfig` (materializado, como siempre, en
`kuadrant-system` con nombre-hash) lo encontró sin fricción — no hubo que
duplicar nada. Este spike no ejercitó `signingKeyRefs`/wristband (no era parte
del deliverable: la Produces del brief pide confirmar el *path* del claim, no
acuñar el wristband real), así que el gotcha de Spike C sobre el Secret de
firma viviendo forzosamente en `kuadrant-system` **sigue aplicando igual** para
cuando Task 8 arme el wristband real — no queda invalidado por este hallazgo.

### Paso 5: rechazo sin header, éxito con header, dump de `auth.identity`

```
$ curl -D - -o /dev/null http://spike-gateway-istio.spike-f.svc.cluster.local/anything
HTTP/1.1 401 Unauthorized
www-authenticate: APIKEY realm="s2s-key"
x-ext-auth-reason: credential not found

$ curl -H "Authorization: APIKEY <valor>" http://spike-gateway-istio.spike-f.svc.cluster.local/anything
HTTP/1.1 200 OK
```

El dump de `x-debug-identity` (reenviado al backend, visible en el echo)
confirma que **`auth.identity` es el objeto `Secret` completo de Kubernetes**,
serializado como JSON:

```json
{"identity":{"apiVersion":"v1","data":{"api_key":"<base64>"},"kind":"Secret",
 "metadata":{"creationTimestamp":"...","labels":{"authorino.kuadrant.io/managed-by":"authorino","kuadrant.io/apikey":"spike-f"},
 "name":"payments-apikey","namespace":"spike-f","resourceVersion":"...","uid":"..."},"type":"Opaque"}}
```

**El path exacto para el claim `namespace` es `auth.identity.metadata.namespace`**
— el namespace donde vive físicamente el Secret de la apiKey. Se confirmó
aislado con un segundo header de debug:

```yaml
x-debug-namespace-claim:
  plain: { expression: "auth.identity.metadata.namespace" }
```

```
$ curl http://spike-gateway-istio.spike-f.svc.cluster.local/anything
...
"x-debug-namespace-claim":"spike-f"
```

Esto es limpio y sin ambigüedad porque el diseño es 1-secret-por-namespace: el
propio Secret vive en el namespace que representa (`spike-f` acá, en
producción sería el namespace real del caller, ej. `payments`), así que su
`metadata.namespace` **es** el claim que se necesita — no hace falta ninguna
label/anotación adicional ni convención de nombre a parsear, a diferencia de
la incertidumbre que había quedado abierta en Spike C con `CommonName`.

### Paso 6: inyección transparente vía `requestHeaderModifier` — funciona en una sola ruta de malla, sin partirla

El punto central del spike. Se probaron dos variantes, ambas con **un único**
`HTTPRoute` (patrón GAMMA, `parentRefs: [{kind: Service}]`, sin `AuthPolicy`
adjunta — pura malla):

**Variante A — self-loop sobre el backend** (la del brief, `parentRef` y
`backendRef` apuntan al mismo `Service` `echo-backend`):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: spike-inject, namespace: spike-f }
spec:
  parentRefs: [{ group: "", kind: Service, name: echo-backend, port: 80 }]
  rules:
    - filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add: [{ name: Authorization, value: "APIKEY <valor>" }]
      backendRefs: [{ name: echo-backend, port: 80 }]
```

```
$ curl http://echo-backend.spike-f.svc.cluster.local/anything   # SIN header manual
...
"headers":{... ,"authorization":"APIKEY 4d595f031269b154959622dbe2ac20eb009091cf0e70ebb4", ...}
```

Un caller que llama a `echo-backend` **directo, sin mandar ningún header**,
recibe el request con `Authorization` ya agregado por su propio sidecar antes
de salir — la app cliente no sabe nada de esto. `HTTPRoute` `Accepted=True`,
`ResolvedRefs=True` (Istio soporta GAMMA sin objeciones, confirmado también en
Spike E).

**Variante B — end-to-end contra el `Gateway` real, con enforcement Kuadrant
de por medio** (extensión propia, no pedida literal por el brief, pero es la
prueba que realmente importa para la Fase 1): mismo patrón, pero el
`parentRef`/`backendRef` apuntan al `Service` del **propio `Gateway`
enforced** (`spike-gateway-istio`), no al backend:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: spike-inject-gw, namespace: spike-f }
spec:
  parentRefs: [{ group: "", kind: Service, name: spike-gateway-istio, port: 80 }]
  rules:
    - filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add: [{ name: Authorization, value: "APIKEY <valor>" }]
      backendRefs: [{ name: spike-gateway-istio, port: 80 }]
```

```
$ curl -D - -o /dev/null http://spike-gateway-istio.spike-f.svc.cluster.local/anything   # SIN header manual
HTTP/1.1 200 OK
```

Un caller que le pega **directo al `Gateway` enforced, sin ningún header**,
recibe `200` — la ruta de malla inyecta el `Authorization` antes de que el
request llegue al pod del `Gateway`, y ahí la `AuthPolicy` de Kuadrant lo
valida contra el Secret real. **Confirma el flujo completo de punta a punta
con un único objeto `HTTPRoute`** — no hizo falta separar "ruta hacia el
Gateway" de "ruta que agrega el header" en dos objetos distintos, la
preocupación que anticipaba el brief no se materializó.

#### Gotcha no anticipado: `RequestHeaderModifier.add` es aditivo, no reemplaza — headers duplicados rompen la comparación de apiKey

Con la ruta `spike-inject-gw` de la Variante B todavía activa, un intento
posterior de probar el header `x-debug-namespace-claim` mandando **también**
un `Authorization` manual (para reusar el mismo comando de curl del Paso 5)
empezó a fallar con `401` y una razón nueva:

```
x-ext-auth-reason: the API Key provided is invalid
```

(distinta de `credential not found` del Paso 5 — la credencial sí se extrajo,
pero no matcheó ningún Secret). Se investigó a fondo (recrear el Secret,
reiniciar `authorino`, revertir la `AuthPolicy`) antes de encontrar la causa
real: la acción `add` de `RequestHeaderModifier` **agrega** el header sin
tocar uno preexistente con el mismo nombre — no es un `set`/overwrite. Con la
ruta de inyección todavía interceptando el tráfico hacia
`spike-gateway-istio`, cualquier request que **ya** traía su propio
`Authorization` terminaba con **dos** headers `Authorization` en la request
final; Authorino extrae un valor que no matchea ningún Secret conocido (no
concatena limpio a "APIKEY valor"), de ahí el `invalid`. Quitando el header
manual del comando de curl (dejando que la inyección transparente sea la
única fuente) todo volvió a `200` limpio — ver el dump del Paso 6 arriba.

**Implicación real, no solo un artefacto de testing:** este comportamiento es
en realidad la semántica correcta y deseada para el diseño de producción — la
app cliente **nunca** debe mandar el header ella misma (es exactamente la
premisa de "inyección transparente"). Si por error una app intentara mandarlo
igual, terminaría con un `401` en vez de con dos identidades ambiguas
silenciosamente resueltas a una — un fail-closed más seguro que un fail-open.
Vale como gotcha para Task 11 (`verify.sh`): al escribir las aserciones de
"caller sin la app enterada", asegurarse de que el pod de prueba **no** mande
manualmente el header que la ruta de inyección ya agrega, o el resultado se
lee como una falla del mecanismo cuando en realidad es un artefacto del script
de prueba.

### Confirmación final: el rechazo sigue siendo HTTP 401 (no TLS-handshake), consistente con Spike C

Con este mecanismo, igual que Spike C (x509) había encontrado, el rechazo por
falta de credencial ocurre a nivel HTTP (`401`, vía el `ext_authz` de
Kuadrant), nunca a nivel de conexión/TLS — el listener del `Gateway` es HTTP
plano, sin ningún componente TLS/Mutual involucrado en absoluto (ni siquiera
server-only TLS, a diferencia de Spike C). Esto es coherente con la aserción 1
de `verify.sh` (Task 11) tal como quedó corregida tras Spike C: un caller sin
la key **llega** a HTTP y recibe `401`, no se corta en el handshake.

### Conclusión

El mecanismo namespace-level vía `authentication.apiKey` + inyección
transparente por `requestHeaderModifier` en una ruta de malla GAMMA queda
**validado de punta a punta** en este cluster: schema real confirmado (muy
cercano a lo que asumía el brief, con la corrección de que `credentials` es
hermano de `apiKey`, no anidado), `AuthPolicy` `Enforced=True` sin gotchas de
namespace de Secret (a diferencia de x509), rechazo/aceptación HTTP
verificados con tráfico real, dump completo de `auth.identity` capturado, y el
claim `namespace` derivable sin ambigüedad de `auth.identity.metadata.namespace`.
La inyección transparente funciona con un único `HTTPRoute` (se probaron dos
variantes — self-loop sobre el backend, y end-to-end contra el `Gateway`
enforced — ambas exitosas), sin necesidad de partirla en dos objetos. El único
hallazgo no anticipado (semántica aditiva de `add`, headers duplicados si el
caller manda igual el header) es una nota operativa para `verify.sh`, no un
bloqueo del mecanismo.

**Reemplaza formalmente** el mecanismo x509/TLS Mutual de Task 4 (Spikes B/C/E,
los tres BLOCKED) como identidad de A hacia el wristband cross-cluster: ya no
hace falta cert de cliente ni cert de servidor de A, ni montaje de Secret de
CA en el sidecar — el `Gateway` de A vuelve a ser HTTP puro (o HTTPS
server-only si se quiere, sin ningún requisito de Mutual), y la identidad la
resuelve un token estático namespace-level más la inyección transparente de la
malla.

### Limpieza

```bash
oc delete project spike-f
```

`AuthConfig` derivado (`kuadrant-system`) confirmado garbage-collected junto
con el `AuthPolicy` al borrar el proyecto (`oc get authconfig -n
kuadrant-system` → `No resources found`).
