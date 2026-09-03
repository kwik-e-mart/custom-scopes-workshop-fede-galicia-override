# EKS vs CRC: en qué se diferencian los dos clusters

> ⚠️ Documenta la **etapa anterior** del PoC: el wristband se acuñaba a partir de una apiKey sobre un Gateway compartido, y el split iba por `VirtualService` en la malla. Hoy el wristband se acuña sobre un **Gateway de egreso por namespace** y el split va por `backendRefs` ponderados de `HTTPRoute`; `mesh_routing.tf` ya no existe. Se conserva por el valor de sus hallazgos, no como instructivo. Vigente: `GUIA-DEMO.md`.

El **mismo módulo** (`modules/kuadrant-s2s/`) se aplica a los dos. Desde el rol dual, **los dos
hacen exactamente lo mismo**: emiten identidad para el tráfico que sale y la validan en el que
entra. Todo lo que queda distinto es **de plataforma o de entorno**, nunca de rol.

Vale subrayarlo porque durante la ida no era así, y esa asociación falsa —"el issuer es el de
OpenShift", "el validador es el vanilla"— se coló en el código dos veces y las dos rompieron
algo al activar el rol dual (findings #29 y el gate de `istio.tf`). Si al leer el módulo
aparece un `count` que mezcla rol con plataforma, es un bug.

| | **CRC** (`clusters/crc/`) | **EKS** (`clusters/eks/`) |
|---|---|---|
| Qué emula | el on-prem del Banco | la nube |
| Rol | **dual** — emite y valida | **dual** — emite y valida |
| Sustrato | OpenShift Local, single-node, arm64 | EKS `gal-kuadrant-poc`, 2× t3.large, amd64 |
| Imagen de la demo | `hello-world:v1-arm64` | `hello-world:v1` |
| Autenticación del provider | contexto `crc-admin` del kubeconfig | `exec` con `aws eks get-token` |
| Issuer que acuña | `s2s-crc-jwks.kuadrant-system:8080` | `s2s-eks-jwks.kuadrant-system:8080` |
| Costo | $0 (~9 GB de RAM local) | ~$140/mo si queda arriba |

## Las diferencias que importan

### 1. Istio se instala distinto — **por plataforma, no por rol**

**EKS** usa el módulo upstream `commons/istio`. **CRC no puede**: ese módulo hardcodea el `set`
de istiod y no expone `pilot.cni.*`, que es justo lo que OpenShift necesita. Por eso
`istio_openshift.tf` instala base + CNI + istiod con `helm_release` propios, con los valores del
profile oficial `platform-openshift.yaml`.

Los dos caminos son **mutuamente excluyentes y se gatean por `var.is_openshift`**. Venían
gateados por el rol —porque el validador *resultaba ser* el cluster vanilla— y en rol dual eso
instalaba un segundo istiod encima del de OpenShift.

> Consecuencia: en CRC **no** se instala el chart `gateway` (ingressgateway clásico) ni se
> consume `istio_service_type`. No hacen falta: el `Gateway` de Gateway API auto-provisiona su
> propio Deployment/Service. En EKS el chart queda instalado y sin uso — ver `FINDINGS.md` #10.

### 2. Cómo se publica el Gateway de ingreso

Los dos clusters tienen un `s2s-ingress` que termina TLS con su propio cert, pero se exponen
distinto, y eso lo decide **el layer**, no el módulo:

- **EKS**: Service `LoadBalancer` → NLB **`internal`** (nunca `internet-facing`: ver el
  incidente del finding #5) con `source-ranges`.
- **CRC**: no hay cloud provider que atienda un LoadBalancer, así que va `ClusterIP` vía la
  annotation `networking.istio.io/service-type`.

En los dos casos el peer llega por el overlay, y el módulo no se entera: recibe
`ingress_gateway_annotations` como un map opaco.

El **Gateway de egreso** (`s2s-egress`) sí es idéntico en los dos: HTTP plano y `ClusterIP`
forzado. Sólo lo consume la malla local — un balanceador ahí no expone una capacidad, expone un
agujero.

### 3. OpenShift necesita permisos que EKS no

La SCC `restricted-v2` rechaza el sidecar de Istio. Con **Istio CNI** desaparece el
init-container que pedía `NET_ADMIN`/root, pero **no alcanza**: `istio-proxy` corre con UID
1337, fuera del rango que OpenShift asigna por namespace. Hace falta además `anyuid`.

Neto, y sólo en CRC:

- `privileged` para **una** SA de infraestructura (`istio-cni`, escribe config en el nodo) y
  para la SA `proxies` del operator del overlay (finding #28).
- `anyuid` (UID arbitrario, sin capabilities ni acceso al host) para las 3 SAs de app.
- Una `NetworkAttachmentDefinition` por namespace inyectado: sin ella Multus no invoca el plugin
  y el sidecar queda **sin iptables** — la malla decorativa, sin error.
- Un `ClusterRole` extra para `proxygroups/finalizers`: OpenShift habilita el admission plugin
  `OwnerReferencesPermissionEnforcement`, que vanilla trae apagado.

En EKS nada de esto existe. Detalle en `FINDINGS.md` #3, #20 y #28.

### 4. Los CRDs de Gateway API

**CRC no los instala**: los gestiona el Ingress Operator de OpenShift, y una
`ValidatingAdmissionPolicy` bloquea el apply manual. **EKS sí los instala** (no vienen de
fábrica). Es el flag `manage_gateway_api_crds`, `false` en CRC y `true` en EKS.

### 5. El pull de imágenes

EKS pullea del ECR privado gratis: el node role trae `AmazonEC2ContainerRegistryReadOnly`.
**CRC no tiene identidad de AWS**, así que sin un `imagePullSecret` explícito los 3 deployments
quedan en `ImagePullBackOff`. Por eso `clusters/crc` pasa `ecr_pull_credentials` (un
`data.aws_ecr_authorization_token`) y `clusters/eks` no.

> ⚠️ Ese token dura **12 h**. Un `tofu apply` lo refresca; pasadas 12 h sin apply, un pod nuevo
> en CRC no puede pullear. `FINDINGS.md` #11.

### 6. Terraform pelea con los controladores de OpenShift

OpenShift inyecta lo suyo en objetos que Terraform cree que posee: annotations
`openshift.io/sa.scc.*` en los namespaces, y un dockercfg por ServiceAccount. Sin
`ignore_changes` cada plan quiere borrarlos y el controlador los repone: **drift permanente**.

Los `lifecycle.ignore_changes` de `workloads.tf` están por esto. En EKS esos campos no existen,
así que ignorarlos no oculta nada allá. `FINDINGS.md` #9.

### 7. La NetworkPolicy se enforcea en uno solo

Corre en los dos clusters, pero **sólo tiene efecto en CRC**: en EKS el nodeagent del VPC CNI no
está en modo enforcing, así que la política existe y es inerte. Por eso la aserción 8 de
`verify.sh` sólo prueba aislamiento L4 del lado CRC.

Eso escondió un bug hasta el rol dual: la regla intra-namespace no admite al pod del Gateway de
ingreso, que vive en `gateways`. En EKS nunca se notó; en CRC el hop cross-cluster habría
muerto a L4 **después** de pasar la `AuthPolicy`, que se lee como identidad rota. El módulo hoy
admite explícitamente al Gateway de ingreso hacia `payments` cuando el cluster valida.

## Qué recurso existe en cuál

Casi todo existe en los dos. Lo que no, es por plataforma o por entorno:

| Recurso | CRC | EKS |
|---|---|---|
| Istio (base/istiod) | charts propios + **CNI** | módulo upstream |
| RoleBindings de SCC + `NetworkAttachmentDefinition` + `proxygroups/finalizers` | ✅ | — |
| Secret `ecr-pull` | ✅ | — |
| CRDs de Gateway API | — (los trae OpenShift) | ✅ |
| `Gateway` `s2s-egress` (HTTP :80, `ClusterIP`) | ✅ | ✅ |
| `Gateway` `s2s-ingress` (HTTPS :443, Terminate) | ✅ (`ClusterIP`) | ✅ (NLB `internal`) |
| `AuthPolicy` **emisora** (valida apiKey, acuña wristband) | ✅ | ✅ |
| `AuthPolicy` **validadora** (valida el wristband del peer) | ✅ | ✅ |
| Endpoint del JWKS propio | ✅ `s2s-crc-jwks` | ✅ `s2s-eks-jwks` |
| Secret de la apiKey + `VirtualService` del split | ✅ | ✅ |
| `ServiceEntry` + `DestinationRule` (TLS al remoto) | ✅ | ✅ |
| `HTTPRoute` de egreso e ingreso | ✅ | ✅ |
| Cert de servidor (`pki/`) | ✅ `["crc"]` | ✅ `["eks"]` |
| `RateLimitPolicy` | — | ✅ (smoke, 5/min) |
| NetworkPolicy + `PeerAuthentication` STRICT | ✅ | ✅ (inerte, ver arriba) |

## Por qué el Gateway de egreso es HTTP plano

No es un descuido: la credencial viaja en un **header**, no en la sesión TLS. Se exploraron dos
mecanismos que sí la habrían necesitado —SPIFFE en el Gateway y TLS Mutual— y los dos quedaron
descartados con evidencia (`SPIKES.md`, spikes B y C). El Gateway de egreso no termina TLS y no
tiene ningún cert.

El TLS aparece en el **segundo hop**, cuando el Gateway de egreso sale hacia el Gateway de
ingreso del peer y valida su cert contra nuestra CA propia.

## El apply sí es simétrico

Cada cluster necesita un ciclo de dos pasadas —`apply` → `scripts/fetch-jwks.sh <cluster>` →
`apply`— porque Authorino **genera** el JWKS al arrancar y recién entonces se puede publicar.
Pero los dos ciclos son **independientes**: no hay orden obligatorio entre clusters y ninguna
clave viaja de uno al otro. Antes no era así (`FINDINGS.md` #33).

Todo eso lo hace `scripts/up.sh`; el paso a paso está en el [`README.md`](README.md).
