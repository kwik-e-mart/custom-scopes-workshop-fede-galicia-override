# Findings y smells de la PoC — con caminos post-PoC

> ⚠️ **Este archivo mezcla etapas.** La mayoría de las entradas siguen vigentes (verificadas contra
> `egress_transport.tf` y `auth_ingress.tf`), pero las que hablan de `mesh_routing.tf`, del
> `VirtualService` del split o de la apiKey describen mecanismos **eliminados**: están marcadas una
> por una. El modelo actual está en `docs/s2s-egress-sin-openresty.md`.

Registro de lo que la PoC encontró y de lo que dejó pendiente a propósito.

Dos categorías:

- **Finding**: algo que la PoC descubrió y que informa la implementación real.
- **Smell**: algo que la PoC hace y que **no** debería replicarse tal cual en producción.

Cada entrada dice qué se hizo acá, por qué, y qué haría en serio.

---

## 1. (Smell) La apiKey viaja en cleartext dentro del `VirtualService`

> ⚠️ **Mecanismo eliminado.** `mesh_routing.tf` ya no existe y no hay apiKey: la identidad es un
> wristband RS256 firmado con la clave del namespace. El smell se conserva como registro.

**Qué hace la PoC.** `mesh_routing.tf` inyecta la identidad con
`headers.request.set = { Authorization = "APIKEY <valor>" }`. El valor queda literal
en un objeto `VirtualService`, que es namespaced pero **no** un `Secret`: alcanza
`get virtualservice` en `payments` para leerlo, mientras que el `Secret`
`payments-apikey` exige `get secret`. Además queda en el state de Terraform (esto
último es inherente: lo genera `pki/`).

**Por qué está así.** Es un *fallback*:
tres spikes probaron que la identidad criptográfica real no es alcanzable en este
stack (SPIFFE en Gateway → el listener no hereda mTLS; TLS Mutual →
`frontendValidation` es de canal experimental en el Gateway API v1.3.0 que instala
OpenShift; `HTTPRoute` de malla sin Gateway → Kuadrant no genera enforcement). Con un
token estático inyectado por la malla, el token tiene que estar escrito en la config
de la malla en algún lado.

**Camino post-PoC (en orden de preferencia).**

1. **Identidad criptográfica, sin token compartido.** Es el fix de fondo: elimina el
   secreto en vez de esconderlo.
   - **Ambient + waypoint**: el `ztunnel` transporta la identidad SPIFFE y el waypoint
     es un Gateway real, así que la `AuthPolicy` de Kuadrant vuelve a tener un
     `Gateway` ancestro **y** mTLS en el hop. Cierra las dos causas que bloquearon los
     spikes B y E de una sola vez.
   - **Gateway API ≥ v1.5** (`frontendValidation` graduó a canal `standard` en feb-2026):
     desbloquea el camino x509/TLS Mutual del spike C sin salirse de sidecars. Depende
     de la versión de OCP que corra el Banco.
2. **Si hay que quedarse con un token**: no escribirlo en la config de la malla.
   Sacarlo del `VirtualService` y que lo agregue un componente que lo lea de un
   `Secret` montado (un sidecar/filtro propio). Trae de vuelta el componente custom
   que la PoC justamente venía a eliminar — mal trade, pero es una salida.
3. **Mitigación pobre, solo si no hay otra**: acotar por RBAC quién lee
   `virtualservice` en esos namespaces al mismo conjunto que lee `secret`. En la PoC no
   se hizo porque sobre un CRC de un solo admin es puro teatro.

**Nota para el entregable.** Este smell es, en sí, un argumento a favor de correr la
identidad S2S sobre un stack donde SPIFFE/Ambient funcione. Vale contarlo como
conclusión, no esconderlo.

**Impacto en el tráfico EKS → on-prem:** la superficie de este smell **se duplica** al
agregar la dirección inversa, y decidir entre "seguir con token estático" o "pasar a
identidad criptográfica" **cambia el diseño de la vuelta** en vez de agregarse después.
Ver [`BIDIRECTIONAL.md`](BIDIRECTIONAL.md), obstáculo 5.

---

## 2. (Finding) Kuadrant no enforcea nada sin un `Gateway` **con ruta** como ancestro

**Qué se descubrió.** Una `AuthPolicy` que targetea un `Gateway` sin ningún
`HTTPRoute` colgando queda completamente inerte: Kuadrant no genera `AuthConfig`,
`EnvoyFilter` ni `WasmPlugin` (verificado cluster-wide en el spike E, y otra vez cuando faltaba el `HTTPRoute` del
validador). No falla ruidosamente — no hace nada.

**Impacto real.** Es la clase de bug que se ve como "todo verde": los objetos existen,
los status dicen `Accepted`, y el tráfico pasa sin autenticar. El `HTTPRoute` llegó a faltar y hubiera dejado la `AuthPolicy` validadora muda.

**Camino post-PoC.** Chequeo explícito en el pipeline: por cada `AuthPolicy`, afirmar
`Enforced=True` (no solo `Accepted=True`) y que exista al menos una ruta con ese
`Gateway` como ancestro. Un smoke test negativo (request sin credencial → 401) es la
única prueba que realmente distingue "enforcea" de "existe".

---

## 3. (Finding) `restricted-v2` de OpenShift rechaza los sidecars de Istio — y CNI solo resuelve la mitad

**Qué se descubrió.** Con sidecars clásicos, el init-container `istio-init` pide
`NET_ADMIN`/`NET_RAW` y `runAsUser: 0`: `restricted-v2` lo rechaza y el `Deployment`
nunca crea el pod (con `oc run` no se ve, porque lo admite la identidad admin — así lo
esquivaron los spikes).

Instalar **Istio CNI** elimina el init-container (el plugin hace el iptables a nivel
nodo), pero **no alcanza solo**: `istio-proxy` y el init-container `istio-validation`
que agrega el propio CNI corren con UID 1337, fuera del rango que OpenShift asigna por
namespace. Hace falta además `anyuid` en las SAs de los workloads.

**Dónde quedó el privilegio.** Con CNI: `privileged` para **una** SA de
infraestructura (`istio-cni`, que escribe config en el nodo) + `anyuid` (UID
arbitrario, sin capabilities ni acceso al host) para las 3 SAs de aplicación. Sin CNI
hubiera hecho falta `privileged` en las SAs de aplicación — mucho peor.

**Camino post-PoC.** Ambient elimina los sidecars por completo: el `ztunnel` es un
DaemonSet de infraestructura y los pods de aplicación quedan sin ningún requisito de
SCC. Es el camino que además resuelve el finding #1.

---

## 4. (Smell) El flavour de OpenShift no usa el módulo upstream de Istio

**Qué hace la PoC.** `istio_openshift.tf` instala base + cni + istiod con
`helm_release` propios (gateados a `role == "issuer"`), en vez de
`tofu-modules//infrastructure/commons/istio`. El validador (EKS) sí usa el upstream.

**Por qué está así.** El módulo upstream hardcodea el `set` de istiod (solo
`pilot.replicaCount`/`autoscaleMin`) y no expone hook para `pilot.cni.*`, que es
exactamente lo que OpenShift necesita. Se eligió validar primero acá y contribuir
después con evidencia, en vez de tocar un módulo compartido a ciegas.

**Camino post-PoC.** Subir la capacidad a `nullplatform/tofu-modules`: un
`extra_set`/`values` pass-through en el `helm_release` de istiod (o directo un flag
`cloud_provider = "openshift"` que aplique el profile `platform-openshift.yaml`
oficial). Con eso el flavour local desaparece y el módulo vuelve a ser uno solo.
Los valores validados están en `istio_openshift.tf`, listos para portar.

---

## 5. (Finding) `internet-facing` sin source-ranges default a `0.0.0.0/0`, y se nota

**Qué hace la PoC.** El `Gateway` del validador lleva
`service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing`, para que
`verify.sh` pueda hacer `curl` directo desde afuera. Layer throwaway, no el stack
productivo.

**Lo que eso costó, medido.** El scheme era una decisión consciente; su consecuencia no.
Sin `load-balancer-source-ranges` el AWS LB Controller abre el SG frontend a
`0.0.0.0/0`, y el Gateway empezó a recibir escaneo de fondo de internet dentro de las
primeras horas: GuardDuty levantó un `Recon:EC2/PortProbeUnprotectedPort` con **25
eventos en 18 h** desde `192.248.150.180` (Vultr, UK). La AuthPolicy aguantó — todo
devolvió 401 y no hubo ningún finding de acceso no autorizado — pero la puerta estuvo
abierta al mundo sin que nadie lo hubiera pedido.

Dos cosas hicieron el diagnóstico más lento de lo necesario:

- **El puerto del finding no es el del listener.** GuardDuty reportó el **NodePort**
  (`32610`), no el 443. Con target group `type=instance` el NLB reescribe el puerto
  destino pero **preserva la IP del cliente**, así que la telemetría ve el flujo en la
  ENI del nodo. Buscar "443" en los findings no encuentra nada.
- **`Blocked: False` no significa "el SG está abierto".** El SG del *nodo* estaba bien
  (NodePorts sólo desde el SG del NLB); el tráfico entraba legítimamente **a través** del
  balanceador. El agujero estaba un salto más arriba, en el SG frontend del NLB.

**Qué se hizo.** `allowed_source_cidrs` en el módulo → annotation
`load-balancer-source-ranges`, restringiendo 443 y 15021 al `/32` del host que corre
CRC (de ahí sale la ida). El valor va en `source-ranges.auto.tfvars`, gitignoreado: es
una IP de origen y no se versiona. La variable tiene una `validation` que **rechaza
`0.0.0.0/0`** — no para tapar el default abierto, sino para que nadie lo reintroduzca a
mano creyendo que destraba algo.

**Camino post-PoC.** El `/32` es un parche con fecha de vencimiento: es una IP
residencial y rota. El cierre real es el que el diseño del repo ya prescribe — NLB
**interno**, ingress privado, y las aserciones corriendo desde adentro del cluster
(`kubectl exec`) en vez de desde el laptop. Y la lección transferible: **`scheme` y
`source-ranges` son una sola decisión**, no dos. Setear el primero sin el segundo es
elegir exposición sin nombrarla. Ver también `docs/private-network-hardening.md`.

---

## 6. (Finding) El default de scheme del AWS Load Balancer Controller está invertido respecto al provider in-tree

**Qué se descubrió.** Sin annotation de scheme explícita, el controller standalone
default a **`internal`** (el provider in-tree legacy defaulteaba a `internet-facing`).
El síntoma no dice nada de scheme: `"Evaluated 0 subnets: 0 are tagged for other
clusters, and 0 have insufficient available IP addresses"`. La causa se confirmó por
CloudTrail, mirando los `requestParameters` reales del `DescribeSubnets` — filtraba por
`tag:kubernetes.io/role/internal-elb`, no por `elb`.

**Camino post-PoC.** Setear `aws-load-balancer-scheme` **siempre explícito**, nunca
depender del default. Y taggear las subnets para los dos roles si conviven LBs
internos y públicos. Para diagnosticar este tipo de cosas, CloudTrail
(`requestParameters`) dice qué pidió el controller de verdad; los logs del controller
solo dicen que no encontró nada.

---

## 7. (Finding) El webhook de istiod usa un puerto que el módulo de EKS no pre-abre

**Qué se descubrió.** El `Service` de istiod expone 443 pero mapea a container port
**15017**. El node security group de `terraform-aws-modules/eks/aws` pre-abre una lista
curada de puertos de webhook (443/4443/6443/8443/9443/10250) que **no** incluye 15017:
las llamadas del control plane a istiod se quedan colgadas hasta el timeout. El
síntoma (`context deadline exceeded` en el `helm_release`) no menciona red ni SG, y el
self-check interno del validador de istiod venía fallando desde el arranque del pod.

**Camino post-PoC.** Abrir 15017 explícito en el node SG en cualquier EKS con Istio
(está en `infrastructure/aws/main.tf` como `node_security_group_additional_rules`).
Vale como entrada de checklist para cualquier cluster nuevo con malla.

---

## 8. (Smell) `ReferenceGrant` más amplio de lo necesario

**Qué hace la PoC.** El `ReferenceGrant` de `payments` permite que cualquier
`HTTPRoute` de `istio-system` apunte a **cualquier** `Service` del namespace: el
bloque `to` no fija `name`.

**Camino post-PoC.** Fijar `to[].name` al Service concreto. En la PoC quedó abierto
porque hay un solo backend y no cambiaba el resultado, pero en producción el
`ReferenceGrant` es justamente el control de qué se puede exponer cross-namespace.

---

## 9. (Finding) Terraform pelea con los controladores de OpenShift si no se le dice que no

**Qué se descubrió.** OpenShift inyecta lo suyo en objetos que Terraform cree que
posee: annotations `openshift.io/sa.scc.*` (rangos de UID/MCS) en cada namespace, y un
dockercfg por ServiceAccount, linkeado vía `secret` + `image_pull_secret` +
annotation. Sin `ignore_changes`, cada plan quiere borrarlos y el controlador los
repone: drift permanente que ensucia todo plan futuro (y, en el caso del pull secret,
borrarlo rompería el pull del registry interno).

**Camino post-PoC.** `lifecycle.ignore_changes` sobre `metadata[0].annotations` en
namespaces, y sobre `annotations` + `secret` + `image_pull_secret` en SAs, en cualquier
módulo que se aplique sobre OpenShift. No aplica en EKS (esos campos no existen), así
que ignorarlos no oculta nada allá.

---

## 10. (Smell) El `istio-ingressgateway` clásico queda sin uso en EKS

**Qué hace la PoC.** El módulo upstream instala el chart `gateway`
(`istio-ingressgateway`) y además Gateway API auto-provisiona su propio
Deployment/Service por objeto `Gateway` (`s2s-istio`). El status del `Gateway` apunta
al segundo; el primero queda colgado, con su propio NLB.

**Por qué está así.** Viene del módulo upstream, no se desactivó para no divergir. El
flavour de OpenShift ya lo omite.

**Camino post-PoC.** Si se usa Gateway API, no instalar el ingressgateway clásico —
son dos NLBs y uno no sirve. Requiere que el módulo upstream permita desactivarlo
(mismo PR del smell #4).

---

## 11. (Finding) El token de pull de ECR expira; en CRC hace falta explícito

**Qué se descubrió.** En EKS el pull del ECR privado sale gratis por el rol del node
group (`AmazonEC2ContainerRegistryReadOnly`). CRC no tiene identidad de AWS: sin un
`imagePullSecret` explícito, los 3 deployments quedan en `ImagePullBackOff`. Se
resolvió con `data.aws_ecr_authorization_token` → `Secret` dockerconfigjson.

**Limitación conocida.** Ese token dura **12 h**. Un `tofu apply` lo refresca; después
de 12 h sin apply, un pod nuevo no puede pullear. En la PoC es aceptable.

**Camino post-PoC.** Para clusters fuera de AWS que tiren de ECR: un renovador
(CronJob que refresca el Secret, o `ecr-credential-provider` a nivel kubelet), no un
token en el state. Alternativa más simple: replicar las imágenes a un registry que el
cluster ya pueda leer.

---

## 12. (Finding) `credentialName` de `DestinationRule` exige `workloadSelector`

**Qué se descubrió.** La CA propia para validar el cert de B no se puede montar en el
pod del Gateway: ese pod lo genera Istio desde el objeto `Gateway` y no controlamos su
`podTemplate`. La vía limpia es SDS —
`DestinationRule.trafficPolicy.tls.credentialName` apuntando a un `Secret` del mismo
namespace— **pero solo funciona si la `DestinationRule` trae `workloadSelector`**; sin
él Istio lo ignora en silencio.

Error de diseño propio en el camino: se había puesto la CA como `ConfigMap` montado por
`sidecar.istio.io/userVolume` en los pods de aplicación. Doble error — el `ConfigMap`
vivía en otro namespace que los pods (`FailedMount`), y sobre todo **el sidecar de la
app nunca origina TLS hacia B**: hop 1 es HTTP plano al Gateway propio, y quien
origina TLS es el pod del Gateway.

**Camino post-PoC.** Con `credentialName` + `workloadSelector` queda resuelto y sin
volúmenes. Vale recordar dónde ocurre cada hop antes de decidir dónde va el material
criptográfico.

---

## 13. (Finding, entorno) CRC se degrada con el uptime

**Qué se descubrió.** Con ~54 días de uptime, Multus empezó a devolver `Unauthorized`
al crear **cualquier** pod, cluster-wide (también en `openshift-marketplace`): la
credencial que el pod de Multus arma al arrancar había quedado vieja. Reiniciar los
pods de `openshift-multus` lo resolvió (el DaemonSet los recrea idénticos, cero drift).

**Camino post-PoC.** Es propio de CRC como entorno de laboratorio, no de OpenShift
productivo. Si CRC va a sostener demos, reciclarlo periódicamente. Recordar que
`crc stop`/`start` además se lleva los módulos de kernel
(`xt_REDIRECT`/`xt_owner`/`iptable_nat`) que hay que volver a cargar.

---

## 14. (Finding) Race de discovery de CRDs en el primer apply

**Qué se descubrió.** `RateLimitPolicy` falló con "resource isn't valid for cluster"
segundos después de que el Helm que instala sus CRDs terminara, mientras un manifest
hermano de un CRD igual de nuevo (`Kuadrant`) sí pasó en el mismo apply. Un
re-plan/re-apply sin tocar HCL funcionó al toque.

**Camino post-PoC.** Mismo patrón que el Gotcha #4 del repo. Separar en un apply la
instalación de CRDs de la creación de CRs de esos mismos CRDs, o aceptar el re-apply
como parte del bootstrap y documentarlo. No es un bug de config.

---

## 26. (Finding) En Kuadrant el rate limit se evalúa ANTES que la autenticación

**Qué se descubrió.** Con el presupuesto del `RateLimitPolicy` agotado, un request **sin
credencial** contra B recibe **429**, no **401**: el limitador contesta antes de que el
`ext_authz` llegue a evaluar nada. Apareció al correr `verify.sh` dos veces seguidas — la
aserción 2 (que espera 401) devolvió 429.

**Por qué importa más allá del test.** Tráfico **no autenticado consume el presupuesto de
rate limit**. Un atacante sin credenciales válidas puede agotar el límite del Gateway y
degradar el servicio para los llamadores legítimos, sin autenticarse nunca. Con el orden
inverso (auth primero), el tráfico anónimo se cortaría en el 401 sin tocar el contador.

**Camino post-PoC.**
- Si el límite es de **protección de capacidad**, el orden actual está bien (protege al
  backend de cualquier volumen, autenticado o no).
- Si el límite es de **cuota por cliente**, hay que indexar el contador por una identidad
  ya autenticada (el claim del wristband) — el `RateLimitPolicy` de Kuadrant soporta
  `counters` por selector. Así el tráfico anónimo no consume la cuota de nadie.
- La PoC usa el límite como smoke test (5/min), no como control real, así que no se
  cambió — pero la elección **hay que hacerla a conciencia** en producción.

**Consecuencia para `verify.sh`:** la aserción 2 reintenta con espera si ve 429, porque a
efectos de esa aserción el 429 es ruido de otra corrida.

---

## 27. (Finding) Un Service sin puertos es invisible para Istio, y el fallback de passthrough lo disimula

**Qué se descubrió.** Al llevar el hop cross-cluster por un overlay de red (Tailscale) en vez
del DNS público del NLB, el Gateway empezó a cortar con **500 antes de emitir el request**, sin
un solo log en el destino. Un `wget` desde cualquier pod hacia **el mismo hostname** funcionaba
perfecto (401 legítimo del destino). La contradicción parecía un problema de red o de TLS; no
era ninguno de los dos.

La cadena real, leída del `/config_dump` del pod del Gateway:

1. El `Service` que publica el destino es de tipo `ExternalName`. Istio ≥1.21 lo trata como
   **alias** (`ENABLE_EXTERNAL_NAME_ALIAS`, default `true`): la ruta se genera apuntando al
   *target* del alias, no al Service que uno declaró.
2. Ese target es un `Service` **headless y sin `spec.ports`** — al proveedor del overlay le
   alcanza, porque redirige por iptables sin mirar el modelo de Service de Kubernetes.
3. Istio construye clusters **por puerto**. Sin puertos declarados, no hay cluster.
4. Resultado: `route → outbound|443||<target>` existe, y el cluster al que apunta **no existe**.
   Envoy responde 500.

**Por qué el `wget` engañaba.** Es el mismo Envoy en los dos casos — cambia el fallback. El
sidecar de un pod, al no encontrar cluster, cae al `PassthroughCluster` (`outboundTrafficPolicy:
ALLOW_ANY`) y abre un TCP directo contra la IP que resolvió el DNS: funciona *a pesar* de que
Istio no conoce el servicio. El Gateway no tiene ese fallback — su ruta viene de un `HTTPRoute`
y apunta a un cluster nombrado. **Un `curl`/`wget` verde prueba conectividad L3/L4, no prueba
que Istio sepa rutear ahí.** Confundir las dos cosas costó una tarde de diagnóstico.

**Señal de diagnóstico correcta.** Cuando Envoy corta con 5xx sin que el destino registre nada,
comparar rutas contra clusters en `/config_dump` — no seguir mirando la red:

```bash
POD=$(kubectl -n istio-system get pods -l gateway.networking.k8s.io/gateway-name=<gw> -o jsonpath='{.items[0].metadata.name}')
kubectl -n istio-system exec "$POD" -c istio-proxy -- curl -s localhost:15000/clusters | grep <destino>
kubectl -n istio-system exec "$POD" -c istio-proxy -- curl -s "localhost:15000/config_dump?resource=dynamic_route_configs"
```

Ojo también con el **status verde**: el `HTTPRoute` reportaba `ResolvedRefs=True` y
`Accepted=True` mientras el tráfico moría en 500. El status valida la referencia declarada, no
que exista un cluster utilizable detrás — misma familia de trampa que el `Accepted` vs
`Enforced` de Kuadrant (finding #2).

**Cómo se resolvió.** No peleando con el `ExternalName`, sino **declarando el Service que la
malla consume**: un `ClusterIP` normal, con el puerto explícito, cuyo selector apunta a los pods
del proxy por las labels de ownership que el propio operator les pone (derivadas del nombre y
namespace del Service que uno declaró, o sea estables por construcción, no identificadores
generados). El controlador nativo de EndpointSlices lo puebla solo. Istio ve un Service común y
corriente y arma el cluster sin saber que hay un overlay detrás.

Queda separado en dos objetos con roles distintos, y conviene nombrarlos como tales: uno le
**pide** la salida al operator (el `ExternalName` anotado), otro es el **hostname que consume la
malla**. Mezclarlos es lo que hacía que el detalle de implementación del proveedor se filtrara al
camino de datos.

**Camino post-PoC.** Cualquier integración que le entregue destinos a Istio por medio de un
`ExternalName` gestionado por un tercero (overlays de red, operadores de conectividad) tiene que
verificarse a nivel de **cluster de Envoy**, no de conectividad. Y el andamiaje de transporte no
debería vivir en el módulo reutilizable: acá se movió a los layers, con el módulo recibiendo sólo
un hostname y un map de annotations opacas. Así lo que se instala en producción no conoce al
proveedor, y el día que el transporte sea ruteo nativo se borra un archivo del layer sin tocar
una línea del módulo.

---

## 28. (Finding) OpenShift necesita permisos que los charts de terceros no declaran — tercera vez

**Qué se descubrió.** Habilitar el modo del proveedor que sí publica `ClusterIP` con puertos
(finding #27) destapó **dos** bloqueos más, ambos por controles que OpenShift trae encendidos y
Kubernetes vanilla no. El chart funciona tal cual en EKS y falla en CRC en los dos casos:

1. **`OwnerReferencesPermissionEnforcement`.** OpenShift habilita este admission plugin por
   defecto; vanilla lo trae apagado. Exige que quien setea `blockOwnerDeletion: true` en un
   `ownerReference` tenga `update` sobre el subrecurso **`finalizers`** del owner. El
   `ClusterRole` del chart declaraba el recurso y su `/status`, pero no `/finalizers`, así que
   el operator no podía crear los Secrets de config de sus propios pods.
2. **SCC sobre una segunda ServiceAccount.** Los pods proxy corren `privileged: true`, y el
   binding de SCC que ya existía cubría sólo la SA de los proxies "standalone". El modo nuevo
   crea **una SA propia por cada agrupación de proxies, con el mismo nombre que la agrupación** —
   sin cubrirla, los pods no pasan admisión.

**El patrón, que es lo que importa para producción.** Es el tercer caso idéntico en esta PoC
(los otros dos: el SCC contra `istio-init`, finding #20, y `$HOME` sin setear bajo UID
arbitrario). Cualquier operator de tercero que se despliegue on-prem sobre OpenShift necesita un
paso explícito de "permisos y contexto de seguridad que el chart no declara porque asume
vanilla". Conviene **presupuestarlo de entrada** en la estimación de cada componente, en vez de
descubrirlo de a uno con el cluster a medio andar.

**Dos trampas de diagnóstico que costaron tiempo acá:**

- **Leer el `status` sin mirar los timestamps.** Tras otorgar el permiso, el `status` del recurso
  seguía mostrando el error viejo y parecía que el fix no había servido. En realidad el
  controlador estaba en **backoff exponencial** y su último intento era anterior al permiso.
  Comparar la hora del último reintento contra la de creación del `ClusterRole` antes de concluir
  que un fix falló.
- **`auth can-i` sin el namespace correcto.** Las SCC se evalúan en el contexto del namespace
  donde nace el pod. `kubectl auth can-i use securitycontextconstraints.../privileged
  --as=system:serviceaccount:<ns>:<sa>` responde **no** sin `-n <ns>` y **yes** con él, para el
  mismo permiso correctamente otorgado. Sin el flag, la verificación miente.

**Y un race al recrear:** el operator le pone finalizers a sus CRs. Un `tofu apply -replace`
sobre uno de ellos puede procesar el delete **después** del create y llevarse el objeto nuevo —
queda en el state de Terraform pero no en el cluster. Se detecta con un `plan` (aparece como
`will be created`) y se arregla con un `apply` normal; no hay que tocar el cluster a mano.

---

## 29. (Finding) El rol dual estrena a los workloads como CLIENTES de la malla, y ahí aparece lo que nunca se ejercitó

**Qué se descubrió.** Al activar el rol dual, la vuelta EKS→CRC devolvía el cluster **local**:
el `VirtualService` del split no se aplicaba. Los pods de EKS **no tenían sidecar** — el
namespace estaba etiquetado `istio-injection=enabled`, pero se habían creado 37 segundos
**antes** de que existiera istiod, así que el webhook inyector todavía no estaba registrado.

**Por qué pasó desapercibido tanto tiempo.** Hasta esta tarea, los workloads de EKS eran
**sólo servidores**: el tráfico entraba por el Gateway de ingress y se ruteaba hacia ellos, y
eso no necesita sidecar. El split es ruteo **del lado del cliente**: vive únicamente en el
Envoy de quien llama. Sin sidecar, `ledger` resolvía `reports` por kube-proxy y nunca salía
del cluster. La dirección de ida no podía detectarlo ni en principio.

**El módulo ya tenía el `depends_on` correcto** (los Deployments dependen de `module.istio` y
del istiod de OpenShift, con un comentario que nombra exactamente esta falla). Lo que falló no
fue la configuración sino el orden histórico de un apply concreto, y **nada vuelve a inyectar
un pod ya creado**: la malla queda decorativa y en verde.

**Cómo detectarlo.** `kubectl get pod -o custom-columns=...spec.containers[*].name` **no
alcanza**: desde Kubernetes 1.29 Istio inyecta el sidecar como *native sidecar*, o sea un
`initContainer`. Un pod inyectado muestra `app` como único container y `istio-proxy` entre los
`initContainers`. Mirar sólo `containers` hace parecer que **ningún** pod está inyectado.

**Camino post-PoC.** Aserción explícita de "todo pod de la malla tiene `istio-proxy`" en el
pipeline. El `depends_on` ordena el primer apply pero no repara un cluster que ya quedó mal.

---

## 30. (Finding) El proxy de egreso del overlay sólo sirve a clientes de su propio nodo — y el fix de #27 lo esconde

**Qué se descubrió.** Con los sidecars ya inyectados, la vuelta seguía fallando: timeout. La
matriz de pruebas dio un patrón nítido:

| cliente | nodo del cliente | proxy de egreso | nodo del proxy | resultado |
|---|---|---|---|---|
| `ledger` | 1 | JWKS | 2 | OK |
| `intruso` | 2 | JWKS | 2 | OK |
| `ledger` | 1 | datos | 1 | OK |
| Gateway de egreso | 2 | datos | 1 | **falla** |

Conectividad pod-a-pod cross-node entre esos mismos nodos funciona (se probó: `connection
refused` y `reset` **instantáneos** contra otros pods del nodo 1). El tráfico llega al pod del
proxy; lo que no vuelve es la respuesta.

**Por qué no se había visto.** CRC es **single-node**: cliente y proxy están siempre
co-locados, así que la dependencia no existe de ese lado. En EKS el pod del Gateway de egreso
cayó en el otro nodo y la vuelta se cortó entera. El workaround del finding #27 —declarar
nosotros un `ClusterIP` que la malla pueda consumir— **funciona igual de bien co-locado y por
eso disimula el problema**: no es el `ClusterIP` lo que falla (pegarle directo a la IP del pod
falla igual).

**Cómo se demostró la vuelta.** Cordoneando el otro nodo y reciclando el pod del Gateway para
que quede junto al proxy:

```bash
kubectl cordon <nodo-sin-proxy>
kubectl -n istio-system delete pod -l gateway.networking.k8s.io/gateway-name=s2s-egress
kubectl uncordon <nodo-sin-proxy>   # una vez reprogramado
```

**Es andamiaje, no mecanismo.** Con Direct Connect el destino remoto es una IP ruteada y no hay
proxy de por medio: esta clase de dependencia desaparece. Lo que la PoC prueba de la vuelta —
identidad acuñada en un cluster y validada en el otro— no depende de esto, y de hecho la
aserción 14 (sin wristband → 401 del peer) atraviesa el mismo hop y da correcto aun con el
problema presente.

**Trampa de diagnóstico.** Un proxy de **egreso** DNATea *todos* los puertos hacia su target,
así que sondear "otro puerto del mismo pod" para ver si el pod responde **no distingue nada**:
todo se va al túnel. Para separar "no llegan los paquetes" de "se pierde la respuesta" hay que
comparar contra **otro pod** del mismo nodo, no contra otro puerto del mismo pod.

---

## 31. (Finding) La primera validación contra un issuer nuevo devuelve 500, no 401

**Qué se descubrió.** El primer request de la vuelta con wristband válido devolvió **500**, y
el siguiente **200**. En el log del Gateway del validador:
`kuadrant-wasm-shim: gRPC status code is not OK`.

**Causa.** Authorino resuelve el JWKS del issuer **en vivo** por OIDC discovery. Mientras esa
primera resolución está en vuelo, la llamada de ext_authz falla y Envoy responde 500 — no 401.
El código engaña: sugiere un problema del Gateway o del upstream, cuando es la caché fría del
validador.

**Consecuencia práctica.** Una demo que dispare un solo request después de aplicar puede
mostrar un 500 que se arregla solo. Vale un request de calentamiento antes de mostrar la
vuelta, o esperar a que el `AuthConfig` del validador esté `Ready=True`.

---

## 32. (Finding) Kuadrant admite UNA sola `AuthPolicy` por `targetRef`, y eso decide la topología de Gateways

**Qué se descubrió.** El diseño de la vuelta asumía que el `Gateway` "s2s" iba a crecer un
**segundo listener** (el HTTP de egreso que ya tenía, más uno HTTPS de ingreso): un solo objeto,
dos puertos. No se puede. Kuadrant admite **una sola `AuthPolicy` por `targetRef`**, y en rol
dual hacen falta dos policies con reglas opuestas sobre el mismo cluster: una que **acuña**
identidad para lo que sale y otra que la **valida** en lo que entra.

Con un solo Gateway hay que elegir cuál de las dos aplicar. No es una limitación de
configuración: es estructural, y define la topología.

**Fix:** partir el Gateway en dos —`s2s-egress` (HTTP:80, sin balanceador, lo consume sólo la
malla local) y `s2s-ingress` (HTTPS:443, publicado)— cada uno con su propia policy. Que además
es el patrón estándar de Istio: separar el gateway de salida del de entrada.

**Por qué importa más allá de la PoC.** Si el `targetRef` es el Gateway, entonces **la unidad de
política es el Gateway**. Cualquier requisito que necesite dos políticas distintas sobre el
mismo tráfico obliga a partir el objeto, no a apilar reglas. Vale tenerlo en cuenta al
dimensionar cuántos Gateways va a tener cada cluster en producción: no salen del volumen de
tráfico sino de **cuántas políticas distintas hay que enforcear**.

---

## 33. (Finding) El mirror de JWKS no era un requerimiento: era el síntoma de una asimetría

**Qué se descubrió.** La ida hospedaba un **mirror del JWKS del emisor dentro del validador**,
con la clave pública copiada de un cluster al otro por tfvars. Parecía una decisión de diseño
—"el validador tiene que tener la clave"— y arrastraba dos costos que se daban por inevitables:
un **apply en dos pasadas** encadenadas entre clusters, y la promesa de que en bidireccional
serían **cuatro**.

Ninguno de los dos era necesario. El mirror existía por una sola razón: **el validador no podía
alcanzar al emisor**. Era un workaround de alcanzabilidad disfrazado de requerimiento de
identidad. En cuanto el sustrato dejó de ser asimétrico, la forma correcta apareció sola: **el
emisor publica su propia clave pública** —es su dueño— y el validador la **descubre en vivo**
resolviendo el hostname del issuer.

**Lo que se ganó,** más allá de borrar un nginx:

- Muere la dependencia de orden entre clusters. El ciclo extraer-y-reaplicar sigue existiendo
  (Authorino genera el JWKS al arrancar) pero queda **contenido dentro de un solo cluster**: en
  rol dual son dos ciclos independientes, no cuatro encadenados.
- La clave no viaja más por tfvars, así que no hay copia que pueda quedar vieja en silencio.

**La lección, que es reusable.** Cuando un componente hospeda datos que pertenecen a otro, vale
preguntarse si eso expresa el diseño o si está **compensando una limitación del sustrato**. Acá
la pista era que el mirror sólo tenía sentido en una dirección. Un diseño simétrico no debería
necesitar piezas asimétricas.

**Lo que NO se hizo, y por qué:** hacer proxy del endpoint OIDC propio de Authorino, que sirve
exactamente esto en vivo. Su path incluye el nombre del `AuthConfig`, que Kuadrant genera como
un hash y **regenera ante cualquier cambio de la `AuthPolicy`** (verificado: drifteó dos veces
durante la PoC). Un valor así no se puede fijar desde Terraform sin quedar viejo en silencio.

---

## 34. (Finding) El teardown se traba: Terraform destruye el operator antes que los objetos que él finaliza

**Qué se descubrió.** El `tofu destroy` del layer de CRC se colgó **20 minutos** en un solo
recurso y terminó abortando:

```
module.s2s.kubernetes_service.jwks_endpoint[0]: Still destroying... [19m50s elapsed]
Error: Service (kuadrant-system/s2s-crc-jwks) still exists
```

**Causa.** El operator del overlay le pone `tailscale.com/finalizer` a cada Service que
publica. Terraform no sabe que ese operator tiene que **sobrevivir** a los objetos que
finaliza: su grafo de dependencias dice lo contrario —los Services dependen del operator, así
que en el destroy se van *después*— y para cuando le toca el turno al Service, el namespace
`tailscale` ya está vacío. Nadie puede procesar el finalizer, y no va a poder nunca: es un
bloqueo permanente por construcción.

Afecta a **todos** los objetos publicados en el overlay, incluidos los que Terraform no maneja
(el Service que Istio auto-provisiona para el Gateway de ingreso también queda trabado).

**Fix.** Sacar el finalizer a mano y reintentar el destroy. Es seguro justamente porque el
controlador dueño ya no existe: el objeto está en `Terminating` y el finalizer sólo puede
bloquearlo para siempre.

```bash
kubectl get svc -A -o json | jq -r '.items[]
  | select((.metadata.finalizers // []) | length > 0)
  | "\(.metadata.namespace) \(.metadata.name)"' |
while read -r ns n; do
  kubectl -n "$ns" patch svc "$n" -p '{"metadata":{"finalizers":null}}' --type=merge
done
```

**Por qué no pasó del otro lado.** El destroy de EKS salió limpio en la misma corrida: el orden
dentro del grafo no es determinista entre recursos sin dependencia declarada, así que ahí el
operator alcanzó a procesar los finalizers antes de irse. O sea que el síntoma es
**intermitente** — peor que uno consistente, porque un teardown exitoso no prueba que el
próximo lo sea.

**Trampa de diagnóstico, y esta es de uno mismo:** el destroy corría como
`tofu destroy ... | tail -6`, y el pipeline devolvió **exit 0** aunque tofu había fallado. El
código de salida del pipe es el del último comando. Para cualquier cosa cuyo resultado importe,
redirigir a un archivo y mirar `$?` — no encadenar un filtro que se come el error.

**Camino post-PoC.** Si el overlay no existe (Direct Connect), el finding desaparece con él.
Para cualquier operator que use finalizers, el patrón general es el mismo: **el que finaliza
tiene que ser lo último en irse**, y Terraform no lo deduce solo.

---

## 35. (Finding) GuardDuty deja DOS objetos que Terraform no conoce y que traban el destroy de la VPC

**Qué se descubrió.** Con el cluster EKS ya borrado, el `tofu destroy` de la infra se quedó
reintentando: el state no bajaba de 29 recursos y los security groups no se iban. En la VPC
quedaban dos ENIs de un **VPC endpoint que no está en ningún state**:

```
vpce-...  ->  com.amazonaws.us-east-1.guardduty-data
```

**Causa.** GuardDuty (Runtime Monitoring para EKS) se auto-provisiona un endpoint en la VPC del
cluster. Terraform no lo creó, así que no lo destruye — pero sus ENIs usan los security groups
del cluster, y eso alcanza para que el borrado de SGs, subnets y VPC falle con
`DependencyViolation`. El síntoma es un destroy que "no avanza" en vez de un error claro,
porque el provider reintenta.

**Y no es uno solo: son dos.** Borrado el endpoint, el destroy avanzó de 29 a 2 recursos y se
volvió a trabar. GuardDuty también deja un **security group propio**
(`GuardDutyManagedSecurityGroup-<vpc-id>`) que el borrado del endpoint **no** se lleva, y un SG
no-default impide borrar la VPC. O sea que el mismo destroy se traba **dos veces seguidas por
la misma causa**, con síntomas distintos.

**Fix (requiere AWS CLI, fuera de Terraform):**

```bash
aws ec2 delete-vpc-endpoints  --vpc-endpoint-ids <vpce-id> --region us-east-1
aws ec2 delete-security-group --group-id <sg-id>           --region us-east-1
```

Después el destroy sigue solo (la VPC tardó 3 min más). Es la misma familia que el gotcha del repo sobre
`eks delete-addon aws-guardduty-agent`: **GuardDuty aprovisiona objetos dentro de nuestros
clusters y VPCs por su cuenta**, y ninguno de ellos aparece en el código.

**Cómo detectarlo rápido.** Si un destroy se queda clavado en security groups o subnets:

```bash
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc-id> \
  --query 'NetworkInterfaces[].{id:NetworkInterfaceId,desc:Description}' --output table
```

La descripción de la ENI dice quién la tiene. Lo que aparezca ahí y no esté en `tofu state
list` es un objeto aprovisionado fuera del código.

**Camino post-PoC.** En cuentas con GuardDuty habilitado, cualquier teardown de una VPC con EKS
tiene este paso. Vale automatizarlo en el runbook de teardown, o dejar el detector apagado en
las cuentas de PoC.

---

## 25. (Finding) `matches` de Authorino es un regexp SIN anclar — y con la lista vacía autoriza todo

**Qué se descubrió** (review final). La regla de autorización usaba
`operator = "matches"` con `value = join("|", var.authorized_namespaces)`. `matches` es un
regexp de Go **sin anclar**, así que con `["payments"]` un claim `payments-evil` o
`xpayments` **matchea y queda autorizado**. Peor: con el default del módulo
(`authorized_namespaces = []`) el value es la cadena vacía, **que matchea cualquier
claim** — la regla autoriza a todos mientras parece estar enforceando.

El PoC desplegado no estaba abierto (pasa `["payments"]` explícito), pero **el módulo
shippeaba un default que desactiva la autorización en silencio**.

**Fix:** un patrón `eq` por namespace dentro de un `any` (OR de comparaciones exactas), más
una `precondition` en el recurso que rechaza la lista vacía en el rol validator. Va como
precondition y no como `validation` de la variable porque el issuer legítimamente no la
setea.

**Trampa de schema al aplicar el fix — costó un 403 en producción de la demo.** Los
elementos de `any` son patrones **directos** (`selector`/`operator`/`value`). Envolverlos
en una clave `pattern` —una suposición razonable— hace que Kuadrant **ignore la expresión
y rechace todo con 403**, sin error de validación en el apply ni en el status de la
`AuthPolicy` (siguió `Enforced=True`). Otra instancia del patrón del finding #2: se ve
configurado y no lo está. Verificado con `oc explain authpolicy.spec.rules.authorization.patternMatching.patterns --recursive`
contra el CRD real, que es lo que había que hacer desde el principio.

**Camino post-PoC.** Nunca `matches` para identidad: anclar (`^(a|b)$`) o usar `eq`. Y ante
cualquier cambio de una policy de autorización, **un smoke positivo además del negativo**:
el 401 sin credencial seguía dando OK con la autorización rota; solo el 200 del caso
legítimo lo detectó.

---

## 24. (Smell, testing) El harness reportaba "rate limit" para un 403 de autorización

**Qué pasaba.** `cluster_via_split` solo clasificaba el 429; cualquier otro código caía al
`sed` que extrae el `cluster` del body, no matcheaba nada y devolvía vacío. Con la
autorización rota (finding #25) B respondía **403**, y las aserciones 3 y 4 reportaban
*"solo 429 en 8 intentos: presupuesto de rate limit quemado, esperar 60s"*.

**El costo real:** el mensaje mandó a esperar ventanas de rate limit dos veces antes de
mirar el código HTTP crudo. El harness no mentía sobre el fallo —fallaba, correctamente—
pero **mentía sobre la causa**, que es casi tan caro.

**Fix.** `cluster_via_split` devuelve `HTTP:<code>` para cualquier código inesperado, y
`reaches_remote` lo reporta **antes** que el rate limit (el 429 suele ser ruido secundario
cuando hay otra cosa mal).

**Camino post-PoC.** Un clasificador de test que colapsa "no fue lo esperado" en una sola
categoría conocida induce diagnósticos equivocados. Que el caso desconocido se reporte
como desconocido, con el dato crudo.

---

## 23. (Smell, testing) "Sin evidencia" contado como "prueba" en una aserción de seguridad

**Qué pasaba.** La aserción 5 clasificaba la barrera que rechazó al intruso con un `case`,
y el catch-all `*)` reportaba **OK** con `barrera: sin respuesta HTTP`. Consecuencia: si
fallaba el propio harness (pod inexistente, container mal nombrado, error de RBAC), no
había respuesta, no matcheaba ningún patrón de barrera conocida… y el script decía que la
seguridad estaba bien.

**Por qué es peor que una aserción faltante.** Una aserción ausente se nota. Una que
reporta OK sin evidencia **genera confianza falsa** — y en este caso sobre una propiedad
de seguridad. Las aserciones 1-4 no tenían el problema: fallan limpio porque comparan
contra un valor esperado y un string vacío nunca lo iguala.

**Fix.** Solo cuenta como OK si se **identificó** la barrera (TLS, timeout L4, o un código
HTTP concreto). Cualquier otra cosa —incluido el harness roto— falla, e imprime el error
crudo.

**Camino post-PoC.** Regla general para aserciones negativas: exigir evidencia positiva
del mecanismo de rechazo, nunca inferir seguridad de la ausencia de éxito. Encontrado por
el review de la Task 11.

---

## 22. (Finding, testing) Varias aserciones dependen del peso del split y hay que gatearlas

**Qué se descubrió.** Al barrer la perilla 0/50/100 aparecieron dos fallas que **no eran
defectos del sistema** sino de las aserciones:

- **A peso 50**, las aserciones 3 y 4 fallaban por azar: afirmaban sobre **un** request, y
  a 50/50 la moneda cae local la mitad de las veces. Lo que prueban de verdad es "esta
  identidad PUEDE llegar a B", no "todo request va a B" → ahora reintentan hasta 8 veces.
- **A peso 0**, la aserción 10 reportaba "el wristband NO rota": sin tráfico al Gateway no
  se acuña **ningún** wristband, y el script leía dos tokens viejos del access log de
  corridas anteriores. Falso negativo → ahora se saltea, igual que 3/4/9.

**Clasificación resultante.** Independientes del peso: 1, 2, 5, 6, 7, 8. Dependientes
(se saltean a 0): 3, 4, 9, 10.

**Por qué importa más allá del script.** Es el mismo patrón que el finding #21: un test que
solo corre en el estado default no ejercita los estados donde aparecen los problemas. La
perilla hay que barrerla **de punta a punta** — el agujero de `exportTo` solo se abría a
peso > 0, y estos dos falsos negativos solo aparecían a 0 y a 50.

**Camino post-PoC.** Si esto se automatiza en CI, correr la matriz completa de pesos, no
un punto. Y que cada aserción declare de qué estado depende, en vez de asumir uno.

---

## 21. (Finding CRÍTICO) Sin `exportTo`, un `VirtualService` regala la identidad a toda la malla

> ⚠️ **El objeto concreto ya no existe**, pero la lección sí: quedó como Gotcha #19 en
> `docs/gotchas.md`, y por eso los `DestinationRule` que hoy emite el service llevan `exportTo: ["."]`.

**El hallazgo más importante de la PoC.** Un `VirtualService` sin `exportTo` default a
`*`: es visible para **toda la malla**, no solo para el namespace donde está definido.
El del split vive en `payments` e inyecta la apiKey de `payments`. Consecuencia: cualquier
sidecar de **cualquier** namespace que llame a `reports.payments.svc.cluster.local` se
lleva (a) el ruteo al Gateway y (b) **la apiKey de `payments` inyectada por la malla**.

**Verificado con tráfico real, no teórico:**

```
# ANTES (sin exportTo), weight_remote=100
$ oc -n other exec deploy/intruso -c app -- \
    wget -qO- http://reports.payments.svc.cluster.local:8080/whoami
{"service":"ledger","namespace":"payments","cluster":"eks-kuadrant",...}   # ← 200

# DESPUÉS (exportTo: ["."])
$ oc -n other exec deploy/intruso -c app -- \
    wget -T 20 -qO- http://reports.payments.svc.cluster.local:8080/whoami
wget: download timed out                                                   # ← L4
```

`intruso@other` llegó al cluster B con identidad `namespace=payments`. La NetworkPolicy
no lo frenaba porque **no lo tenía que frenar**: guarda la entrada a `payments`
pod-a-pod, y el tráfico iba al Gateway, que vive en `istio-system`. El wristband se
acuñó con el claim `payments` aunque el llamador estaba en `other`.

**Por qué la Task 10 no lo vio.** Con `weight_remote=0` el split manda todo al `reports`
local, y ahí sí la NetworkPolicy corta a L4 — el mismo check daba timeout y parecía
correcto. **El agujero solo se abre cuando la perilla se mueve.** Un test que corre solo
en el estado default nunca lo encuentra.

**Fix aplicado.** `exportTo = ["."]` en el `VirtualService`: la ruta solo existe para los
sidecars de `payments`; los de afuera caen al ruteo normal del `Service` y ahí la
NetworkPolicy los corta. El flujo legítimo (`ledger@payments`) no cambia.

**Lo que revela del diseño.** Es la consecuencia directa del smell #1: con la credencial
inyectada por config de ruteo, **la identidad queda atada al host que llamás, no a quién
sos**. `exportTo` la vuelve a atar al namespace, pero por convención de configuración,
no por criptografía. Un `exportTo` olvidado en cualquier ruta futura reabre el agujero,
en silencio.

**Camino post-PoC (más allá del fix).**
1. **Identidad criptográfica** (Ambient/SPIFFE, ver #1 y #3): el llamador no puede
   presentar una identidad que no tiene, sin importar qué ruta consuma. Elimina la clase
   de bug entera.
2. **Defensa en profundidad mientras tanto:** `AuthorizationPolicy` de Istio en el
   Gateway restringiendo los `source.namespaces` admitidos. Así, aunque una ruta quede
   mal exportada, el Gateway igual rechaza al llamador ajeno.
3. **Guardrail de linting:** fallar el CI ante cualquier `VirtualService` sin `exportTo`
   explícito. Es una omisión invisible en review y de impacto alto.

---

## 20. (Finding) Hay una tercera barrera contra el intruso que el spec no anticipaba

**Qué se descubrió.** El las aserciones de `verify.sh` esperaba que `intruso@other` fuera rechazado por una de
dos barreras: NetworkPolicy L4, o un `401` de Kuadrant si llegaba al Gateway sin el
header. En la práctica salta una **tercera, antes que las dos**: `other` no tiene
`DestinationRule` con la CA de B, así que la TLS origination falla en la validación del
certificado y **no hay ni respuesta HTTP** (`certificate verify failed`).

**Por qué vale registrarlo.** Es defensa en profundidad real y gratuita: la confianza
criptográfica hacia el cluster remoto es config de malla **por namespace**, así que un
namespace que no fue habilitado explícitamente no puede ni completar el handshake —
independientemente de credenciales. Un namespace nuevo no hereda el acceso cross-cluster
por accidente.

**Consecuencia para las aserciones.** La aserción 5 de `verify.sh` afirma "rechazado" y
**reporta qué barrera saltó**, en vez de exigir un `401` puntual: forzar el 401 ahí sería
falsear el resultado (y taparía esta barrera). La barrera del `401` queda probada de
todos modos por la aserción 2, que llega a B sin wristband desde afuera.

**Nota de tooling.** El wget de BusyBox de la imagen de demo no tiene
`--no-check-certificate`, así que desde los pods no se puede bypassear la validación del
cert ni para diagnosticar. Para probar el `401` de B hay que usar `curl -k` desde fuera
del cluster.

**Impacto en el tráfico EKS → on-prem:** esta barrera es config de malla **por namespace**,
así que la dirección inversa obliga a replicar la CA en cada namespace que necesite hablar
hacia el otro lado — y automatizarlo mal ("la CA en todos lados") **pierde justamente esta
barrera**. Ver [`BIDIRECTIONAL.md`](BIDIRECTIONAL.md), obstáculo 4.

---

## 18. (Smell) La inyección del header asume UN solo destino remoto por bloque `http[]`

**Qué hace la PoC.** El `VirtualService` del split (`mesh_routing.tf`) usa un único
bloque `http[]` con dos `route` ponderados (local y Gateway) y **un** `headers.request.set`
a nivel del bloque. Funciona porque el único destino no-local de esa lista es el
Gateway propio, así que el header se aplica donde tiene que aplicarse.

**Dónde se rompe.** En cuanto haya **más de un destino remoto con identidad distinta**
en el mismo bloque, el `set` los pisa a todos con la misma credencial: Istio aplica
`headers.request.set` al resultado del bloque, no por `route`. Habría que partirlo en
bloques `http[]` independientes con `match` por destino.

**Camino post-PoC.** Si el split crece a varios destinos remotos, partir en bloques
`http[]` por identidad. Está anotado inline en `mesh_routing.tf`, pero se registra acá
también porque la Task 12 es la que mueve `weight_remote` y es donde primero se
notaría. Relacionado con el smell #1: el problema de fondo es que la identidad viaja
como header estático en la config de ruteo.

---

## 19. (Smell, menor) `gateway_api_version` es un parámetro muerto en el rol issuer

**Qué hace la PoC.** `clusters/crc/variables.tf` declara `gateway_api_version` solo
para que `main.tf` pueda pasárselo al módulo sin condicionales, pero en CRC no se usa
(`manage_gateway_api_crds = false`: los CRDs los gestiona el Ingress Operator).

**Camino post-PoC.** Cosmético. Un `default = null` con el comentario haría más
evidente en el call site que es un parámetro inerte para ese rol.

---

## 17. (Smell, proceso) Un `git add` selectivo dejó commits que no compilaban

**Qué pasó.** Los 3 commits de la Task 10 agregaron los archivos **nuevos** del
módulo pero no los **modificados**, que eran co-requisito. Un checkout limpio de ese
punto fallaba `tofu validate`: `clusters/crc/main.tf` pasaba
`ecr_pull_credentials` a un módulo que todavía no declaraba la variable, y con
`module.istio` sin gatear el rol issuer hubiera instalado Istio dos veces.

**Causa.** Un `git add` con brace expansion traía un pathspec mal escrito
(`terraform.tf` en vez de `terraform.tfvars`). Git **aborta el add completo** ante un
pathspec inválido — no agrega lo que sí matcheaba. El re-add con rutas explícitas
omitió cinco archivos, y los marcadores `M` (unstaged) del `git status` estaban a la
vista y no se leyeron.

**Por qué importa.** Todo lo verificado en vivo era el árbol de trabajo, no la rama.
El síntoma es invisible mientras trabajás en el mismo directorio: solo aparece en un
clone/checkout limpio o en CI.

**Camino post-PoC.**
- Preferir `git add <dir>` sobre listas de archivos cuando el cambio abarca un
  módulo entero (es lo que el brief de la tarea decía, de hecho).
- Después de `git add`, leer el `git status`: cualquier `M` en la primera columna
  (working tree) sobre un archivo relacionado es una bandera.
- Verificación barata que lo hubiera atrapado: `git archive HEAD | tar -x -C $(mktemp -d)`
  y correr `tofu validate` ahí. Vale como gate antes de cerrar cualquier tarea.

---

## 16. (Finding) Los Secrets de Authorino necesitan DOS labels con propósitos distintos

**Qué se descubrió.** El brief le ponía al Secret de la apiKey solo
`kuadrant.io/apikey: s2s`. Con eso el enforcement anda (request sin credencial → 401)
pero **la credencial correcta también da 401**, con
`"the API Key provided is invalid"` en el log de Authorino.

Los dos labels hacen cosas separadas:

| Label | Para qué |
|---|---|
| `authorino.kuadrant.io/managed-by: authorino` | Selector de **watch** de Authorino (su default cuando `secretLabelSelector` es `null`). Sin esto Authorino **ni indexa** el Secret. |
| `kuadrant.io/apikey: s2s` | Lo que matchea `apiKey.selector.matchLabels` de la propia `AuthPolicy`, para elegir cuáles de los Secrets ya vigilados pertenecen a esa regla. |

**Por qué cuesta diagnosticarlo.** El mensaje dice "invalid", que se lee como "el valor
está mal" — cuando en realidad no había **ningún** valor cargado. Los dos síntomas
posibles se parecen mucho y tienen causas opuestas:

- `"credential not found"` → no llegó el header (o llegó vacío).
- `"the API Key provided is invalid"` → llegó el header, pero ningún Secret indexado
  matchea. Puede ser **valor equivocado**, **headers duplicados** (el gotcha de Spike F:
  `headers.request.set` es aditivo) **o el Secret no vigilado** (este caso).

**Camino post-PoC.** Poner los dos labels siempre, y ante un "invalid" chequear primero
que el Secret tenga el label de watch antes de sospechar del valor. Verificable rápido:
si `oc logs` de Authorino no muestra un `resource reconciled` para ese Secret, no está
indexado.

---

## 15. (Finding) El Secret de firma del wristband va en el namespace de Authorino, no en el del Gateway

**Qué se descubrió.** El brief ponía `wristband-signing-key` en `istio-system` (junto al
`Gateway` y a la `AuthPolicy`). Authorino resuelve `signingKeyRefs` en el namespace del
**`AuthConfig`**, que Kuadrant genera en su propio namespace (`kuadrant-system`) con un
nombre hasheado. Con el Secret en `istio-system`, el `AuthConfig` queda
`Ready=False / "Secret not found"` y la `AuthPolicy`, `Enforced=False`.

**Por qué importa más de lo que parece.** Es otra instancia del finding #2: el
`Gateway` dice `Programmed=True`, el `HTTPRoute` `Accepted=True/ResolvedRefs=True`, la
`AuthPolicy` `Accepted=True`, y los `EnvoyFilter` existen. Todo "verde" salvo una
condición anidada dos niveles abajo, en un objeto de nombre hasheado que nadie mira.
Sin chequear `Enforced` explícitamente se pasa por alto.

**Detalle operativo.** Authorino reintenta el reconcile del `AuthConfig` con un backoff
largo (~17 min observados). Aunque su controller de Secrets detecta el Secret nuevo al
instante, el `AuthConfig` no se re-evalúa hasta el siguiente ciclo: entre el fix y el
`Ready=True` pasan minutos, y el status queda mostrando el error viejo (con su
`lastTransitionTime` desactualizado) todo ese rato. Fácil de leer como "el fix no
funcionó".

**Camino post-PoC.** Aserción explícita de `AuthPolicy.Enforced=True` en el pipeline,
con espera acotada, más el smoke test negativo (sin credencial → 401). Y tener presente
que "el Secret existe" y "Authorino lo tomó" son dos hechos separados en el tiempo.
