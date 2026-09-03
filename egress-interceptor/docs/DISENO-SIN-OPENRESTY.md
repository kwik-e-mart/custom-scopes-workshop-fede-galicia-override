# S2S sin OpenResty: Gateway de egreso por namespace

**Estado:** **implementado y verificado en los dos clusters (2026-08-24)** · **Branch:** `feat/kuadrant-s2s-vuelta`

> Lo de abajo se escribió como diseño previo. Las secciones §4 (spikes) y §5 (riesgos) quedaron
> resueltas; §10 registra lo que cambió respecto de lo planeado y lo que se aprendió aplicándolo.

Reemplazar el OpenResty del egreso por un **Gateway de egreso de Istio por namespace**, con Kuadrant
acuñando el JWT. Objetivo: eliminar el código propio del camino del dato (el Lua que firma y
pondera) sin degradar las propiedades de seguridad ni cambiar el contrato externo de la demo.

Documento de referencia para retomar el trabajo. Todo lo marcado **medido** se verificó contra el POC;
todo lo marcado **sin verificar** es una incógnita que hay que spikear antes de escribir código.

---

## 1. Punto de partida: cómo funciona hoy

Un OpenResty **por namespace**, desplegado por el service `egress-interceptor` de nullplatform.

```
ns payments
  Deployment egress-gateway          ← OpenResty. Nuestra imagen, nuestro Lua
  ConfigMap  egress-gateway-cfg      ← 1 server block por servicio interceptado
  Secret     egress-jwt-key          ← la privada de payments, montada en /etc/jwt
  Service    reports                 selector → app=egress-gateway   (hijackeado)
  Service    reports-local           selector → app=reports          (el alias al backend real)
  NetworkPolicy allow-intra-namespace
```

**El camino de un request** (`ledger` → `reports`, destino remoto):

```
ledger → Service reports (hijackeado) → OpenResty
   firma un JWT RS256 con /etc/jwt/private.pem, iss = $POD_NAMESPACE
   setea X-NP-Token, X-NP-Origin y el header de ruteo (X-NP-Scope | X-NP-SVC)
   reescribe el path a /intra-namespace/… y sortea por peso (math.random(100) <= pct)
→ Gateway de ingreso del destino (Envoy)
   Kuadrant/Authorino valida contra el JWKS del emisor y fija la identidad
→ HTTPRoute matchea header + prefijo y strippea /intra-namespace
→ Service reports del destino (también hijackeado) → OpenResty del destino
   ve el token presente ⇒ "esto viene del ingreso", entrega a reports-local
→ la app
```

### Las dos patas de la garantía (el invariante a preservar)

| Pata | Mecanismo | Qué impide |
|---|---|---|
| **Material de firma** | `Secret` montado en `/etc/jwt`, sólo el del propio namespace | que el firmante use la clave de otro namespace. No hay código que elija clave: hay una sola alcanzable |
| **Quién puede pedir firma** | `NetworkPolicy allow-intra-namespace` (ingress sólo desde el mismo ns) | que un pod de otro namespace le pida a este firmante que firme por él |

Las dos son expresables **porque el firmante vive dentro del namespace**. Cualquier reemplazo tiene
que reproducirlas o aceptar explícitamente que se degradan.

### La identidad no sale del token

La `AuthPolicy` del ingreso (medido, 4 reglas hoy) fija la identidad con `overrides`:

```
local-other      jwksUrl=…/other/jwks.json      overrides={"ns":{"value":"other"}}
local-payments   jwksUrl=…/payments/jwks.json   overrides={"ns":{"value":"payments"}}
peer-other       jwksUrl=…crc…/other/…          overrides={"ns":{"value":"other"}}
peer-payments    jwksUrl=…crc…/payments/…       overrides={"ns":{"value":"payments"}}
```

El claim `iss` **no participa de ninguna decisión**: cuando la firma verifica contra el JWKS de
`payments`, Authorino sobrescribe la identidad con `ns=payments` pase lo que pase en el payload. Por
eso firmar con la clave de `other` declarando `iss=payments` da **403** y no 200.

La cantidad de reglas crece como `namespaces × (1 + clusters_peer)`: 10 namespaces sobre 2 clusters
son **20 reglas**. Ver §9 (pendiente de benchmark).

---

## 2. Arquitectura propuesta

Un **Gateway de egreso por namespace**, en el mismo namespace donde hoy vive el OpenResty. Un
`Gateway` de clase `istio` auto-provisiona su Deployment y su Service (verificado: el Service del
Gateway de ingreso tiene `ownerReferences: Gateway/s2s-ingress` y su pod corre
`registry.istio.io/release/proxyv2:1.30.3`). O sea: **un pod de Envoy donde hoy hay un pod de
OpenResty. El conteo de procesos no cambia.**

### Objetos que el service tiene que generar, por namespace

```
ns payments
  Gateway     s2s-egress            clase istio, listener HTTP :8080
    └── auto-crea Deployment + Service (Envoy)          ← reemplaza al pod de OpenResty
  HTTPRoute   <svc>                 hostname <svc>.payments.svc.cluster.local
                                    backendRefs ponderados: local / remoto
                                    filter: URLRewrite → prefijo /intra-namespace en la rama remota
  AuthPolicy  s2s-egress-payments   targetRef → Gateway/s2s-egress
                                    response.success.headers.X-NP-Token = wristband
                                    customClaims.namespace = "payments"  (literal)
                                    signingKeyRefs → clave PROPIA de payments
  Secret      payments-wristband-key   (en kuadrant-system, label managed-by=authorino)
  Service     <svc>                 selector → gateway.networking.k8s.io/gateway-name=s2s-egress
  Service     <svc>-local           selector → app=<svc>            (igual que hoy)
  NetworkPolicy allow-intra-namespace                                (igual que hoy, sirve tal cual)
  ReferenceGrant                    en ns tailscale, para que el HTTPRoute pueda apuntar al
                                    Service del overlay (cruzar namespaces es explícito en Gateway API)
```

### Cómo se preservan las dos patas

| Pata | Hoy | Propuesto |
|---|---|---|
| Material de firma | `Secret` montado en el pod de OpenResty | `signingKeyRefs` de la `AuthPolicy` de **ese** Gateway → una clave por namespace, distinta por cada uno |
| Quién puede pedir firma | `NetworkPolicy` del namespace | **la misma** `NetworkPolicy`: el Envoy vive en el namespace, así que el ingress-from-same-namespace aplica sin cambios |

La identidad sigue siendo estructural: el Envoy de `payments` sólo recibe tráfico de `payments`
(por la NetworkPolicy) y sólo puede firmar con la clave de `payments` (por su `AuthPolicy`). El
`customClaims.namespace` puede ser un **literal** porque el anclaje ya prueba el origen — no hace
falta que nadie presente una credencial para demostrar quién es.

### Qué desaparece

- La imagen de OpenResty y todo el `nginx.conf.tpl` (~150 líneas de Lua interpolado).
- `render_server_blocks` y `render_nginx_conf` de `scripts/k8s/lib_render.sh`.
- El sorteo por peso en Lua (`math.random(100) <= pct`) → pasa a `backendRefs[].weight`.
- El corte de loop por presencia de `X-NP-Token` → **desaparece**: el `HTTPRoute` del ingreso apunta
  directo a `<svc>-local`, así que los dos caminos son disjuntos por topología (§5, resuelto).

### Qué NO cambia (contrato externo)

Esto es lo que hace que la demo y el runbook sigan valiendo:

- Los headers: `X-NP-Token`, `X-NP-Origin`, `X-NP-Scope` / `X-NP-SVC`.
- Los headers de traza `X-Egress-Route` / `X-Egress-Target` (hay que reproducirlos con
  `ResponseHeaderModifier`; ver §5).
- El `AuthPolicy` del **ingreso**: no se toca.
- Los atributos de la instancia del service: `service_name`, `scope`, `percent`.
- El `RUNBOOK-PRUEBAS.md`: los 16 pasos siguen aplicando, incluido el Paso 5 de aislamiento.

---

## 3. Alternativas descartadas

| Alternativa | Por qué no |
|---|---|
| **Malla (sidecar o ambient) con identidad SPIFFE** | Descartada por decisión del equipo: no se quiere mesh. Y técnicamente, Kuadrant **no se adjunta al data plane de ambient**: `istio-waypoint` corre bajo `istio.io/mesh-controller` y Kuadrant construye su topología desde Gateways de ingreso. Evidencia: `accounts/galicia/demo-kuadrant-s2s/spikes/ambient-waypoint/SPIKE-FINDINGS.md` (CP1 rojo, `Enforced=False`, `curl` sin credencial → 200) |
| **Un solo Gateway de egreso compartido + apiKey inyectada por la ruta** | El valor de la credencial tiene que vivir en el `HTTPRoute`, que **no es un Secret**: legible con `get httproute`, y queda en el state de Terraform. Además un Envoy compartido recibe tráfico de todos los namespaces, así que la `NetworkPolicy` namespaced deja de poder acotar quién pide firma (Gotcha #19), y el wristband lo firmaría **una sola clave por cluster** — una filtración compromete todos los namespaces en vez de uno. Es el modelo que existió en `auth_egress.tf` + `mesh_routing.tf` (vivos en `main`, borrados en este branch) |
| **Seleccionar la clave por el claim `iss`** | No es inseguro (si el `iss` elige la clave, firmar con otra da 401), pero Authorino **no tiene lookup dinámico**: se expresa igual como N reglas. Y ataría el `iss` a la validación, lo que obliga a `issuerUrl` con OIDC discovery y a que cada namespace publique un `/.well-known/openid-configuration` — hoy `jwks_endpoint.tf` sirve el JWKS pelado |

---

## 4. Incógnitas a spikear ANTES de escribir código — **las tres en verde**

Los tres spikes se contestaron sin correrlos por separado: la contrapropuesta del cliente
(`../poc-kuadrant/`) ya los había ejercitado sobre su propio par de clusters, y la implementación
los confirmó de punta a punta acá. Evidencia en §10.


Las tres se pueden probar sobre EKS solo, sin CRC, en un namespace de prueba. Si alguna da rojo, el
diseño cambia.

| # | Pregunta | Cómo probarla | Si da rojo |
|---|---|---|---|
| **S1** | ¿Un `Service` puede apuntar por selector a los pods de un Gateway, y Envoy rutear por `Host`? | Crear `Gateway` con listener HTTP :8080 + `HTTPRoute` con hostname `probe.<ns>.svc.cluster.local`, y un `Service probe` con selector `gateway.networking.k8s.io/gateway-name`. Pegarle desde un pod | Sin esto no hay forma de interceptar sin tocar la app. El diseño muere |
| **S2** | ¿Kuadrant acuña el wristband sobre un Gateway de **egreso** (sin malla, sin ingreso real)? | `AuthPolicy` con `response.success.headers.wristband` sobre ese Gateway; verificar que el header llega al upstream y que `Enforced=True` | Habría que volver a firmar con algo propio → el objetivo se cae |
| **S3** | ¿El hop remoto puede ser un `backendRef` con TLS originado y CA privada? | `BackendTLSPolicy` (v1alpha3) o `DestinationRule` con `caCertificates` + `sni` apuntando al Service del overlay | Fallback: mantener sólo el hop remoto con un componente propio, o terminar TLS distinto |

**Nota sobre S2:** hay evidencia a favor. El `SPIKE-FINDINGS.md` describe el wristband de
`auth_egress.tf` como *"el método de identidad conocido-bueno"*, y ese archivo acuñaba exactamente
esto sobre un `Gateway` normal. Pero se usaba con la malla inyectando el header de identidad, no con
un anclaje por namespace.

---

## 5. Riesgos y puntos abiertos del diseño

**Los headers de traza. ACEPTADO (decisión del 24/08).** Se emiten con `ResponseHeaderModifier` en
**ambas** ramas del `HTTPRoute`. En el peor caso alguno resulta redundante —por ejemplo con destino
OpenShift→OpenShift— y simplemente se ignora. Queda por verificar el soporte de Istio en un
`backendRefs` ponderado, pero no es bloqueante: si no se puede por rama, se ponen a nivel de regla.

**El corte de loop. RESUELTO (verificado 2026-08-24).** Se elimina como problema apuntando el
`backendRef` del `HTTPRoute` de **ingreso** a `<svc>-local` en vez de a `<svc>`. Los dos caminos
quedan disjuntos por topología:

```
entrada:  Gateway de ingreso → reports-local → la app     (nunca toca el egreso)
salida:   ledger → reports (hijackeado) → Gateway de egreso → firma → remoto
```

Las tres piezas verificadas contra el POC:

| Pieza | Estado |
|---|---|
| El `HTTPRoute` de ingreso hoy apunta a `reports:8080` (ns payments) | es el Service hijackeado — hay que cambiarlo |
| `reports-local` existe con `selector={"app":"reports"}`, puerto 8080 | apunta a la app real |
| El `ReferenceGrant` es `to=[{"group":"","kind":"Service"}]`, **sin `name`** | cubre todos los Services del ns: no hay que tocarlo |

Es **un campo**, y además **elimina una debilidad documentada** en `GUIA-DEMO-DETALLE.md` ("lo que NO
sostiene"): *"el corte de loop confía en la presencia de `X-NP-Token`; un pod del mismo namespace
puede mandar ese header para que el interceptor lo entregue local"*. Ya no hay header que engañar,
porque no hay decisión en runtime.

**Consecuencia:** al no pasar por ningún interceptor del destino, desaparecen los headers de respuesta
`x-egress-route: inbound` y `x-egress-target: reports-local…`, que hoy los emite el OpenResty del
destino. Se recuperan con `ResponseHeaderModifier` en la regla del ingreso (constantes por regla).

**La semántica del `percent`. ACEPTADO (decisión del 24/08).** Lo que importa es la capacidad de
dividir tráfico, no el algoritmo. Los valores de referencia del runbook (`0 → 20 local`,
`50 → ~11/9`, `100 → 20 cloud`) pueden moverse; se re-documentan con lo medido.

**Consumo declarado. NO ES UN PROBLEMA (decisión del 24/08).** Medido: el Envoy del Gateway pide
`100m CPU / 128Mi` (limits `2 CPU / 1Gi`); el OpenResty de hoy corre **sin requests ni limits**
(BestEffort, artefacto de POC). En una implementación productiva al OpenResty habría que ponerle
recursos explícitos igual, y no se espera diferencia relevante de consumo entre los dos.

**Acoplamiento de versión. IRRELEVANTE (decisión del 24/08).** Un bug de Kuadrant pasaría a poder
afectar el egreso además del ingreso; se acepta.

---

## 6. Archivos del repo que hay que tocar

| Archivo | Cambio |
|---|---|
| `services/egress-interceptor/openresty/nginx.conf.tpl` | se elimina |
| `services/egress-interceptor/scripts/k8s/lib_render.sh` | se elimina `render_server_blocks` / `render_nginx_conf`; se agrega el render de `Gateway` + `HTTPRoute` + `AuthPolicy` |
| `services/egress-interceptor/scripts/k8s/reconcile` | aplica manifests declarativos en vez de ConfigMap + Deployment |
| `services/egress-interceptor/manifests/egress-gateway.yaml.tpl` | se reemplaza por los manifests de Gateway API |
| `services/egress-interceptor/tests/render.bats` | reescribir: hoy assertea sobre el `nginx.conf` |
| `services/egress-interceptor/specs/service-spec.json.tpl` | revisar si los atributos siguen alcanzando (probablemente sí) |
| `accounts/galicia/demo-kuadrant-s2s/modules/kuadrant-s2s/` | la clave de firma por namespace pasa a ser un Secret de wristband en `kuadrant-system`; `pki` puede tener que emitirlas |
| `accounts/galicia/demo-kuadrant-s2s/RUNBOOK-PRUEBAS.md` | el Paso 4 (`pod_gw`, `esperar`) apunta a `app=egress-gateway`: hay que reapuntarlo al label del Gateway |

---

## 6.bis Cambios necesarios en el runbook (corregido)

La versión inicial de este documento decía "sólo los selectores del Paso 4". **Es falso.** Son tres
categorías y sólo la primera es mecánica:

**A. Selectores (mecánico), 4 lugares.** `-l app=egress-gateway` →
`-l gateway.networking.k8s.io/gateway-name=s2s-egress`. Líneas 286 y 298 (dentro de `esperar`), 641
(el `GW=` del test con CA real) y 861 (verificación manual del Paso 12).

**B. El chequeo del `ConfigMap` — reescribir, no reapuntar.** El `ConfigMap egress-gateway-cfg` con el
`nginx.conf` deja de existir (líneas 262-263 en `esperar`, y 859-860 en el Paso 12). `esperar` tiene
que inspeccionar el `HTTPRoute` (sus `backendRefs[].weight` y el filtro del header) en vez del render
de nginx. **Su segunda condición —confirmar por comportamiento leyendo `X-Egress-Target`— sigue
valiendo igual**, y era la única confiable.

**C. La evidencia de "quién firmó" — se reemplaza por algo mejor.** Las líneas que hacen
`grep -oE "s2s-(sign|inbound)[^,]*"` (925, 1003, 1004, 1069, 1148, 1150) leen logs del Lua, que Envoy
no emite. Pero si Authorino acuña el wristband, **el Authorino del origen también registra una
decisión**: "quién firmó" pasa a medirse con el mismo helper `desde` que ya mide "quién validó".

```bash
T0=$(marca)
# …el request…
echo "acuñó el origen:   $(desde "$EKS" "$T0")"    # ≥1
echo "validó el destino: $(desde "$CRC" "$T0")"    # ≥1
```

Hoy la evidencia es asimétrica (origen = log de Lua, destino = log de Authorino); después son dos
decisiones de Authorino, una por lado. El modelo de evidencia del runbook se simplifica.

---

## 7. Criterio de éxito

El cambio está listo cuando, **con sólo los cambios del §6.bis en el runbook**:

1. Los cuatro escenarios (Pasos 12-15) dan 200 con la evidencia del validador del destino.
2. El Paso 5 sigue dando **401 / 403 / 403 / 200** — en particular el tercer caso (clave de `other`
   declarando `iss=payments` → 403), que es el que prueba que la identidad no sale del claim.
3. El Paso 16 (barrido de pesos) muestra la progresión 0 / ~50 / 100.
4. No queda ningún pod con imagen propia en el camino del dato.

Si (2) falla, el cambio es un downgrade de seguridad y no se mergea.

---

## 8. Fuera de alcance

- La **`AuthPolicy` del ingreso** (`s2s-validator`) y el `Gateway s2s-ingress` no se tocan.
  El **`HTTPRoute` del ingreso SÍ cambia**: su `backendRef` pasa de `<svc>` a `<svc>-local` (corte de
  loop, §5) y gana un `ResponseHeaderModifier` con los headers de traza del hop de entrada.
- El overlay de Tailscale sigue siendo andamiaje; se reemplaza por Direct Connect en el Banco.
- El agente in-cluster sigue pendiente por su propia razón (credencial de lectura del repo).

---

## 9. Pendiente: benchmark de N reglas de authentication

Con 10 namespaces × 2 clusters son **20 reglas** en la `AuthPolicy` del ingreso. Falta medir si
Authorino las evalúa en paralelo o en serie y cuál es el costo marginal.

**Cómo medirlo** sin crear 20 namespaces: comparar la latencia de un token que matchea la **primera**
regla, uno que matchea la **última**, y uno inválido (fuerza a evaluar todas, termina en 401). Si los
tres dan lo mismo, la evaluación es concurrente y el costo es irrelevante.

Las métricas de Authorino (`auth_server_evaluator_duration_seconds`) serían la medición precisa, pero
`authorino-controller-metrics:8080` y el `:5001` del server no devolvieron nada desde un pod de app —
habría que revisar si hace falta `spec.metrics.deep: true` en el CR. Medición alternativa válida:
`curl -w '%{time_total}'` en loop **dentro** del pod, 30 requests por caso, comparando p50.

Este pendiente **no bloquea** la implementación: aplica igual al diseño actual.

---

## 10. Lo que pasó al implementarlo (2026-08-24)

### 10.1 Verificado end-to-end

Los cuatro escenarios, sin ningún pod de imagen propia en el camino del dato:

| Escenario | Resultado | Evidencia |
|---|---|---|
| EKS→EKS | 200 | `x-s2s-cluster: eks-kuadrant`, 2 decisiones de Authorino (acuñar + validar) |
| OpenShift→OpenShift | 200 | `x-s2s-cluster: crc-openshift` |
| EKS→OpenShift | 200 | `x-s2s-cluster: crc-openshift` |
| OpenShift→EKS | 200 | `x-s2s-cluster: eks-kuadrant` |
| Aislamiento (los 2 clusters) | **401 / 403 / 403** | el tercero es clave de `other` declarando `iss=payments` |
| Barrido de pesos | 0 / 9 / 20 sobre 20 | `percent` 0, 50, 100 |
| Ciclo `delete` | selector restaurado, 0 objetos residuales | el alias del layer sobrevive |

El criterio de aceptación del §7 se cumple: **el Paso 5 sigue dando 403** cuando se firma con la
clave legítima de `other` declarando `iss=payments`. La identidad la sigue fijando qué clave validó.

### 10.2 Tres restricciones de Authorino que no estaban en el diseño

Ninguna se ve como error: las tres fallan con los objetos en verde.

1. **El verificador `jwt` está fijado a RS256.** No hay campo para declarar otro algoritmo. Con una
   clave EC el destino rechaza el 100% de los tokens con un 401 idéntico a "falta el token".
2. **El firmador sólo parsea RSA en PKCS#1.** Con PKCS#8 falla con `invalid signing key algorithm`
   —mensaje que culpa al algoritmo cuando el problema es el encoding— y deja el `AuthConfig` del
   **egreso** sin reconciliar, o sea que tumba el camino de la app entera. `pki/main.tf` lo verifica
   con un `postcondition` en vez de asumirlo.
3. **El `kid` del token lo deriva Authorino del nombre del Secret**, y `go-oidc` sólo prueba una
   clave del JWKS si el `kid` coincide (o si la JWK no declara ninguno). El JWKS que publicábamos no
   tenía `kid`: con el firmador poniéndolo, ninguna clave se habría probado. `rsa-to-jwks.sh` ahora
   lo exige como parámetro.

Las tres salieron de la PoC del cliente (`poc-kuadrant/poc-egress-kuadrant/HALLAZGOS.md`, H9) y se
confirmaron acá.

### 10.3 Dónde vive la clave: una propiedad de seguridad que cambió

Kuadrant traduce toda `AuthPolicy` a un `AuthConfig` en `kuadrant-system` y Authorino resuelve
`signingKeyRefs` contra el namespace del `AuthConfig`. **La clave no puede vivir en el namespace de
la app.** Eso mueve una de las dos patas de la garantía:

| Pata | Con OpenResty | Ahora |
|---|---|---|
| Quién puede pedir firma | `NetworkPolicy` del namespace | **igual**: el Envoy vive en el namespace |
| Quién puede usar la clave | RBAC sobre Secrets del namespace | **RBAC sobre `AuthPolicy`** |

`signingKeyRefs` referencia por **nombre** dentro de un namespace compartido: quien pueda crear una
`AuthPolicy` en cualquier namespace puede pedirle a Authorino que firme con cualquier clave. En este
modelo la `AuthPolicy` la renderiza el service y los equipos de aplicación no la escriben — **ésa es
la frontera, y hay que sostenerla a propósito**. Es la misma limitación que el cliente registró como
`OQ-11` y escaló a Red Hat (ticket 1b de `REDHAT-DESIGN-AND-LIMITATIONS.md`).

### 10.4 Cambios respecto de lo diseñado

- **El prefijo `/intra-namespace` se fue del camino.** Estaba planeado como `URLRewrite` sólo en la
  rama remota, y eso no se puede: Gateway API no soporta filtros por `backendRef` cuando la regla
  tiene más de un backend ([istio#39136](https://github.com/istio/istio/issues/39136)). A nivel de
  regla rompía la rama local, que no atraviesa ningún ingreso que lo strippee. El `HTTPRoute` del
  ingreso ahora matchea sólo por el header de ruteo; el path no participaba de ninguna decisión de
  seguridad.
- **Los headers de traza los pone el destino, no el origen.** Por la misma limitación no se puede
  marcar la rama desde el egreso. El ingreso del destino sella `x-egress-route`, `x-egress-target` y
  `x-s2s-cluster`; el egreso sella `x-egress-gateway`. Salió **mejor** que lo diseñado: antes la rama
  era una afirmación del origen sobre lo que creía haber hecho (un 502 del hop contaba como `cloud`),
  y ahora la presencia del sello es prueba de que el request llegó y fue autorizado.
- **El alias `<svc>-local` lo provisiona el service, no el layer.** Esto se decidió al revés en un
  primer momento y se dio vuelta el 2026-08-26: declararlo desde el layer obligaba a saber de
  antemano qué servicios se van a interceptar y dejaba dos dueños para el mismo objeto. Hoy lo crea
  el `reconcile` al interceptar y lo borra al revertir — junto con el `HTTPRoute` de ingreso que lo
  referencia, así que no hay ventana en la que la route apunte a un backend que no existe
  (`modules/kuadrant-s2s/workloads.tf` lo documenta en el lugar donde NO se declara).
- **La rama que no cruza no se emite cuando le tocaría `weight: 0`.** Un `backendRef` con peso cero
  igual exige que el backend exista; si faltara, la route entera quedaría `ResolvedRefs=False` y se
  caería también el tráfico de la otra rama, que no lo usa. ⚠️ Cuál de las dos ramas es ésa depende
  del origen: desde el 2026-08-27 `percent` es siempre el porcentaje que atiende **EKS**, así que con
  origen OpenShift la rama local se apaga en `percent=100` y con origen EKS, en `percent=0`.

### 10.5 Dos bugs propios que el cambio destapó

- **`patch --type=merge` fusiona el mapa del selector, no lo reemplaza.** Funcionaba mientras el
  selector viejo y el nuevo compartían la clave `app`; al pasar a
  `gateway.networking.k8s.io/gateway-name` quedaron las dos claves y el Service se quedó sin
  endpoints. Estaba en el swap **y** en el revert, así que el `delete` habría dejado el Service roto.
  Va con `--type=json` y `op: replace`.
- **El swap sólo actuaba "la primera vez"** (si no existía la annotation). Un Service ya interceptado
  apuntando a un gateway anterior quedaba anotado y roto. Ahora converge al selector deseado.

### 10.6 `ResolvedRefs=False (BackendNotFound)` es un falso negativo

Istio no marca como resueltos los `backendRefs` de `kind: Hostname` (su extensión para referenciar
hosts del registro). Los dos clusters reportan `ResolvedRefs=False` **con el tráfico funcionando**. No
usar esa condición como señal de salud de esta route.
