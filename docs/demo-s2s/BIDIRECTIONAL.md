# Tráfico EKS → on-prem: qué faltaba y qué pasó

> ⚠️ Documenta la **etapa anterior** del PoC: el wristband se acuñaba a partir de una apiKey sobre un Gateway compartido, y el split iba por `VirtualService` en la malla. Hoy el wristband se acuña sobre un **Gateway de egreso por namespace** y el split va por `backendRefs` ponderados de `HTTPRoute`; `mesh_routing.tf` ya no existe. Se conserva por el valor de sus hallazgos, no como instructivo. Vigente: `GUIA-DEMO.md`.

> **Estado: IMPLEMENTADO** (2026-08-07). Los dos clusters corren en **rol dual** y el tráfico
> autenticado va en ambas direcciones: `verify.sh` da **20/20** con los dos splits en 100.
>
> Este archivo se escribió **antes** de construirlo, como análisis de diseño. Se conserva con
> el estado real de cada obstáculo encima, porque el contraste entre lo que se predijo y lo
> que pasó es la parte útil: **dos de las cinco predicciones estaban equivocadas**, y no en
> los detalles.
>
> Lo que la vuelta **no** prueba —el sustrato de red es un stub declarado— está en
> [`FIDELITY.md`](FIDELITY.md).

## Resumen: qué pasó con cada obstáculo

| # | Obstáculo | Estado | Qué se predijo mal |
|---|---|---|---|
| 1 | Rol dual del cluster | **Resuelto** | Se predijo *un* Gateway con dos listeners. Es imposible: Kuadrant admite una sola `AuthPolicy` por `targetRef` (finding #32) |
| 2 | Alcanzabilidad de red | **Resuelto con un stub declarado** | Nada; era el bloqueante real y se resolvió como decía la tabla de opciones (túnel), asumiendo su baja fidelidad |
| 3 | JWKS circulares | **Resuelto, y se disolvió** | Se predijo un segundo mirror y cuatro pasadas. El mirror era el **síntoma** de la asimetría, no un requerimiento (finding #33) |
| 4 | CA por namespace | **Abierto** | — (es un problema de escala, no de la PoC) |
| 5 | Identidad namespace-level | **Abierto** | — (es la granularidad del mecanismo, no un atajo) |

## Por qué la primera iteración cubría sólo la ida

> **Lo que se creía entonces.** Se conserva porque explica el punto de partida — y porque la
> asimetría resultó ser **del sustrato**, no del diseño: en cuanto la red dejó de ser
> asimétrica, el modelo de identidad se volvió simétrico solo (ver obstáculo 3).

No es una simplificación de conveniencia: **la ida y la vuelta no son simétricas en este
diseño**, ni en red ni en el modelo de identidad.

La ida funciona porque **B es alcanzable y A no**. El Gateway de B tiene un NLB con
hostname resoluble; A le habla por ahí y todo el resto (mTLS, wristband, validación) se
apoya en esa alcanzabilidad. Del otro lado no hay nada equivalente: el on-prem de la PoC
es una VM local sin IP alcanzable desde EKS.

Quedó fuera del alcance de la primera iteración a propósito: meterlo hubiera acoplado el resultado del PoC de identidad —que es lo que se
venía a probar— a una decisión de red que **no es nuestra** (ver obstáculo 2).

## Los cinco obstáculos

### 1. Rol dual del cluster — ✅ RESUELTO

> **Cómo terminó.** `var.role` se partió en `issue_identity` / `validate_identity`, tal cual
> proponía este análisis, y los dos clusters quedaron en `(true, true)`.
>
> **La predicción que falló:** acá abajo dice que el `Gateway` "s2s" necesita **dos listeners,
> no dos Gateways**. Es exactamente al revés. Kuadrant admite **una sola `AuthPolicy` por
> `targetRef`**, y el rol dual necesita dos policies con reglas opuestas — así que hay que
> partir el Gateway en `s2s-egress` y `s2s-ingress` (finding #32). La unidad de política es el
> Gateway.
>
> La otra observación de esta sección **sí** acertó y se aplicó: `istio_openshift.tf` dejó de
> ser "el flavour del issuer" para ser "el flavour de OpenShift". Es más: el mismo error
> estaba también en `istio.tf` gateando el flavour vanilla por `validate_identity`, y en rol
> dual instalaba un segundo istiod encima del de OpenShift.

Hoy cada cluster tiene **un** rol y son excluyentes: `issuer` (A, acuña el wristband) o
`validator` (B, lo valida). En bidireccional **los dos clusters son las dos cosas a la
vez**, y eso rompe una suposición estructural del módulo, no solo su configuración.

| Pieza | Hoy (one-way) | Bidireccional |
|---|---|---|
| `var.role` | `issuer` \| `validator`, excluyentes | insuficiente: ambos roles conviven |
| Gateway de A | HTTP plano, `ClusterIP` (nadie entra) | necesita listener de **ingress con TLS** y exposición (`NodePort`) |
| Cert de servidor | solo B (`remote_gateway_*` en `pki/`) | también A → segundo par en `pki/` |
| apiKey | solo en `payments` de A | también en el namespace llamador de B |
| Split + inyección de header | solo en A | también en B |
| Mirror de JWKS | solo en B (clave de A) | también en A (clave de B) → ver obstáculo 3 |
| `AuthPolicy` | emisora en A, validadora en B | **las dos, en los dos** |

**La forma honesta no es un tercer valor `"both"`** —los `count = var.role == ...` quedarían
ilegibles— sino partir el rol en dos flags independientes, que es lo que cada recurso
realmente expresa:

```hcl
variable "issues_identity"    { type = bool }  # acuña wristband para tráfico saliente
variable "validates_identity" { type = bool }  # valida wristband en tráfico entrante
```

One-way queda `(true,false)` y `(false,true)`; bidireccional, `(true,true)` en ambos.
Refactor mecánico pero transversal: toca `auth_egress.tf`, `auth_ingress.tf`,
`mesh_routing.tf`, `gateway.tf`, `jwks_mirror.tf`, `istio_openshift.tf`.

Dos cosas que **no** se duplican bien:

- **El `Gateway` "s2s"** es un solo objeto por cluster: necesita **dos listeners** (el HTTP
  de egress que ya tiene + uno HTTPS de ingress), no dos Gateways.
- **`istio_openshift.tf`** dejaría de ser "el flavour del issuer" para ser "el flavour de
  OpenShift", ortogonal a los roles. Conviene renombrar la condición antes de que la
  asociación falsa se fosilice.

### 2. Alcanzabilidad de red — ✅ RESUELTO EN LA PoC con un stub declarado; **Gap #2 sigue abierto para producción**

> **Cómo terminó.** Se tomó la primera opción de la tabla de abajo —un overlay, Tailscale— con
> los ojos abiertos sobre su baja fidelidad. Lo que la PoC prueba con eso es la **simetría**
> (que cualquiera de los dos lados pueda iniciar la conexión), no el medio.
>
> La disciplina que hace que el stub no contamine el resultado: **el andamiaje del transporte
> vive fuera del módulo reutilizable**, en `clusters/*/tailscale-transport.tf`. El módulo
> recibe un hostname y un map de annotations opaco; ningún recurso de Istio o Kuadrant nombra
> al proveedor. El día del Direct Connect se borra ese archivo.
>
> **Lo que sigue bloqueado por el Banco no cambió:** los CIDRs de Plaza y Centro. El NLB ya
> está en `internal` y con `source-ranges`, o sea que la *forma* del control está puesta, pero
> calibrada con valores de mentira. Ver [`FIDELITY.md`](FIDELITY.md).

Era el **único bloqueante duro**; todo el resto era configuración.

El Gap #2 del relevamiento (`README.md`, *Identified Gaps for the AWS Greenfield*) es
**"AWS ingress and traffic — traffic would enter through on-prem"**. Dos consecuencias
directas para esta fase:

1. **La dirección declarada del diseño es la contraria.** El tráfico *entra* desde on-prem
   hacia AWS (F5 → DMZ HAProxy → Direct Connect → NLB interno). Que EKS *salga* hacia
   on-prem es un camino que el diseño de red todavía no describe.
2. **Los CIDRs on-prem siguen pendientes** (Plaza y Centro, ver
   `proposal/ANALISIS-TRAFICO.md`). Sin ellos no se puede escribir ni el security group
   del lado que recibe: es el mismo pendiente que ya bloquea el hardening de red privada
   (`docs/private-network-hardening.md`).

O sea: **la fase 6 no está bloqueada por Kuadrant ni por Istio, está bloqueada por una
decisión del Banco.** Por eso tiene gate propio y no condiciona lo que ya está construido.

Opciones para desbloquearla en la PoC:

| Opción | Qué implica | Fidelidad al target |
|---|---|---|
| **Túnel** (`cloudflared`, `tailscale`, `ngrok`) | rápido, sin tocar AWS; el Gateway on-prem queda detrás del hostname del túnel | **baja** — no se parece a producción |
| **VPN site-to-site** a la VPC | más trabajo; el on-prem detrás de un endpoint IPsec | media |
| **Mover el lado on-prem a un OpenShift alcanzable** (OCI/OKE) | reemplaza CRC por el sustrato real del target | **alta** |

Para *validar el mecanismo* alcanza el túnel y es barato. Para que la PoC **prediga
producción**, la tercera: el destino declarado del on-prem es **OCI**, no CRC, y varias
fricciones de esta PoC son de CRC como entorno (finding #13) más que de OpenShift. Además `infrastructure/oci/oke` ya existe en `tofu-modules` y este módulo usa solo
providers `kubernetes`/`helm`, así que mover el lado on-prem **no exige refactor**.

### 3. JWKS circulares — ✅ RESUELTO, y el problema se disolvió

> **Cómo terminó.** No hay segundo mirror: **no hay ningún mirror**. El análisis de abajo
> parte de una premisa equivocada —que el validador tiene que *hospedar* la clave del
> emisor— y de ahí deduce correctamente un bootstrap de cuatro pasadas. La premisa era un
> workaround de alcanzabilidad disfrazado de requerimiento (finding #33).
>
> Con sustrato simétrico, cada **emisor publica su propia clave pública** y el validador la
> **descubre en vivo** resolviendo el issuer. El ciclo extraer-y-reaplicar sigue existiendo
> (Authorino genera el JWKS al arrancar) pero queda contenido en un solo cluster: **dos
> ciclos independientes, no cuatro encadenados**.
>
> **La predicción que sí acertó, y de lleno: la colisión de `issuer`.** Los dos clusters no
> pueden compartir el string del issuer. Se resolvió como sugiere el último bullet de esta
> sección —issuers distinguibles: `s2s-crc-jwks` y `s2s-eks-jwks`— y el módulo **deriva** el
> nombre del Service del host del issuer para que no haya dos fuentes del mismo dato. Una
> precondition rechaza que las dos URLs coincidan, porque ese caso es un cluster validando
> sus propios wristbands, todo en verde.

Hoy la cadena de confianza es lineal: A firma con `key_A`, y B valida contra un **mirror
del JWKS de A hospedado dentro de B** (se hospeda en B justamente para no
depender de alcanzabilidad inversa). Eso ya obliga a un **apply en dos pasadas**: levantar
A → `scripts/fetch-jwks.sh` → aplicar B con validación.

En bidireccional la cadena se cierra sobre sí misma: **cada cluster tiene que hospedar un
mirror del JWKS del otro**. Consecuencias concretas:

- **Bootstrap circular.** Pasa de dos pasadas a **cuatro**: A up → fetch JWKS de A → B up
  con validación → fetch JWKS de B → A up con validación. Ninguno de los dos puede quedar
  completo antes que el otro exista.
- **Acoplamiento en cada cambio de policy.** El path del endpoint OIDC incluye el **nombre
  hasheado del `AuthConfig`**, que Kuadrant regenera con cada cambio de la `AuthPolicy` (ya
  drifteó `5868b8a7…` → `292bca04…` durante esta PoC). Con dos lados, **tocar la policy de
  un cluster invalida el path de fetch del otro** — y el síntoma sería un 401 genérico,
  no un error de configuración. `scripts/fetch-jwks.sh` ya descubre el hash en vivo por
  esto mismo; la versión bidireccional necesita hacerlo **en las dos direcciones**.
- **Colisión de `issuer`.** `wristband_issuer_url` hoy tiene un default único
  (`s2s-jwks.kuadrant-system.svc.cluster.local:8080`). Si los dos clusters usan el mismo
  valor para **claves distintas**, cada validador puede terminar validando contra el JWKS
  equivocado. Los issuers tienen que ser distinguibles (ej. `s2s-jwks-a` / `s2s-jwks-b`)
  **antes** de escribir el segundo mirror.

Salida más limpia a futuro: una **PKI/issuer común** a los dos clusters (o un OIDC
alcanzable por ambos) en vez de dos mirrors espejados. Eso elimina la circularidad de
raíz, a cambio de introducir un componente compartido.

### 4. CA por namespace — ⏳ ABIERTO (problema de escala, no de la vuelta)

La TLS origination hacia el cluster remoto se configura con una `DestinationRule` que
entrega la CA por SDS (`credentialName` + `workloadSelector`, finding #12). Esa confianza
es **config de malla, por namespace** — y eso tiene un lado bueno y uno malo.

**El lado bueno, ya verificado:** es una barrera de seguridad real y gratuita. El
finding #20 lo documenta: `intruso@other` no puede alcanzar B porque su namespace **no
tiene** la `DestinationRule` con la CA, así que el handshake falla antes de cualquier
chequeo de credencial. Un namespace nuevo **no hereda** el acceso cross-cluster por
accidente.

**El lado malo para la fase 6:** hay que replicar ese material y esa config **en cada
namespace de cada cluster que necesite hablar hacia el otro lado**. Con ~400-500
namespaces (el orden de magnitud del relevamiento) eso es una superficie de configuración
que crece linealmente y que, si se automatiza mal, se convierte en "la CA está en todos
lados" — perdiendo justamente la barrera del finding #20.

Preguntas a resolver antes de escalarlo:

- ¿La CA se distribuye por namespace (barrera intacta, más config) o una vez a nivel malla
  (menos config, barrera perdida)?
- ¿Quién la rota, y qué pasa con los namespaces que quedaron atrás en una rotación?
- ¿Se usa una CA propia como en la PoC, o la PKI corporativa del Banco? Lo segundo cambia
  quién emite y quién revoca.

### 5. Identidad namespace-level — ⏳ ABIERTO (es la granularidad del mecanismo)

**La vuelta no mejora la granularidad: la hereda.** El mecanismo final da
identidad **a nivel namespace**, no per-workload — es el titular honesto de la aserción 4
de `verify.sh`: `reports@payments` llega a B con una ServiceAccount distinta de `ledger`
porque **son el mismo namespace, o sea la misma identidad**. Misma granularidad que Kong.

Dos cosas se agravan al duplicar la dirección:

- **La superficie del smell #1 se duplica.** La credencial es un token estático inyectado
  por config de ruteo, así que **la identidad queda atada al host que llamás, no a quién
  sos**. El finding #21 mostró que eso es explotable de verdad, no en teoría: un
  `VirtualService` sin `exportTo` le regaló la identidad de `payments` a toda la malla, y
  un pod de otro namespace llegó a B con un wristband ajeno. Cada ruta nueva de la vuelta
  trae el mismo riesgo, y es una omisión **invisible en review**.
- **No hay forma de expresar "este servicio, no su vecino"** en ninguna de las dos
  direcciones. Si el requisito real es identidad per-workload, el trabajo **no es
  bidireccionalidad**: es Ambient/SPIFFE (findings #1 y #3). Conviene decidir eso antes,
  porque cambia el diseño de la vuelta en lugar de agregarse después.

## Lo que la ida ya dejó resuelto

Cosas verificadas en las fases 1-5 que **no** hay que redescubrir:

- **`credentialName` + `workloadSelector`** para entregar la CA al pod del Gateway por SDS,
  sin montar volúmenes (finding #12). Sin `workloadSelector`, Istio ignora
  `credentialName` **en silencio**.
- **`sni` explícito** en la `DestinationRule`: sin él Envoy lo deriva del `Host` entrante
  (`auto_sni`) y el handshake sale con el nombre equivocado (gotcha del Spike D).
- **El Secret de firma va en el namespace de Authorino**, no en el del Gateway
  (finding #15).
- **Dos labels en el Secret de la apiKey** — el de *watch* de Authorino y el del selector
  de la `AuthPolicy` (finding #16) — más `allNamespaces = true`.
- **La `AuthPolicy` no enforcea sin un `HTTPRoute` colgado del Gateway** (finding #2). Vale
  para el listener de ingress nuevo del lado on-prem.
- **En OpenShift, Istio CNI + `anyuid`** (finding #3): CNI elimina el `istio-init` con
  `NET_ADMIN`/root, pero **no alcanza solo** — el UID 1337 igual necesita `anyuid`.
- **El path del endpoint OIDC incluye el hash del `AuthConfig`**, que rota con cada cambio
  de policy: descubrirlo en vivo, nunca hardcodearlo.

## Aserciones — qué se implementó

`verify.sh` pasó de 10 a **15 aserciones**. Las tres primeras de esta lista existen hoy; las
otras tres siguen pendientes.

| # | Aserción | Estado |
|---|---|---|
| B1 | Llamador en **EKS** → on-prem, flujo completo | ✅ **aserción 13** — devuelve `crc-openshift` |
| B2 | Externo → Gateway de ingress **on-prem** sin wristband | ✅ **aserción 14** — 401 |
| B3 | Intruso en **EKS** → host del split de EKS | ✅ **aserción 15** — rechazado reportando la barrera |
| B4 | **`exportTo` explícito en todos** los `VirtualService` de los dos clusters | ⏳ pendiente — sigue siendo la más barata y la que sola hubiera atrapado el finding #21 |
| B5 | Ida y vuelta **simultáneas** | ⏳ pendiente — hoy se ejercitan las dos, pero no a la vez |
| B6 | Anti-bucle: request con `x-s2s-hop: 2` | ⏳ pendiente — **ver abajo: el riesgo resultó ser menor de lo previsto** |

Además se agregaron dos aserciones que este análisis no anticipaba, las dos transversales:
**11** (cada Gateway con su `AuthPolicy` en `Enforced=True`, no sólo `Accepted`) y **12** (el
discovery del issuer del peer responde, en los dos sentidos).

**Sobre B6 (anti-bucle):** con los dos splits en 100 no hay rebote A→B→A. El `HTTPRoute` de
ingreso de cada cluster tiene un único `backendRef` que apunta a `ledger`, un workload común y
no al host del split, así que la cadena termina ahí. El riesgo existiría si el ingreso ruteara
al mismo host que el `VirtualService` intercepta — vale tenerlo presente al agregar rutas, pero
hoy no hay bucle que cortar.

**B4 es la más barata de todas y la que sola hubiera atrapado el finding #21.** Vale
implementarla como lint de CI incluso antes de que la fase 6 se apruebe: protege también a
la ida.

B6 cubre un riesgo que hoy no existe: con split en los dos lados, un `weight_remote > 0` en
ambos y un host que resuelva cruzado puede rebotar A→B→A. Conviene un `x-s2s-hop` que se
incremente y se corte en 2.

Y el rate limit se vuelve simétrico: el límite bajo de B ya interfiere con las mediciones
(resuelto en `verify.sh` contando el 429 como "llegó a B", finding #22). Con límite en los
dos lados, las aserciones de la vuelta necesitan el mismo cuidado.

## Orden sugerido — ejecutado

> Se siguió casi tal cual, con una diferencia de peso: **el paso 1 no se "decidió", se
> stubeó**. Los pasos 2, 3 y 4 salieron primero, como decía el cierre de esta sección, y eso
> dejó el terreno listo. La numeración real quedó en el plan de la vuelta (tareas 1-7).
>
> Lo que el orden no anticipaba y apareció al ejecutar: partir el Gateway (por el finding #32)
> tuvo que ir **antes** del rol dual, y el paso 6 —"segundo mirror de JWKS"— desapareció.

1. **Decidir la red** (obstáculo 2 / Gap #2). Sin esto no empieza.
2. Refactor `role` → `issues_identity` / `validates_identity`, con las fases 1-5 pasando
   igual (`verify.sh` como red de seguridad del refactor).
3. `pki/`: segundo cert de servidor, para el lado on-prem.
4. `issuer` URLs distinguibles **antes** de tocar los mirrors (obstáculo 3).
5. Listener de ingress HTTPS en el Gateway on-prem + su `HTTPRoute`.
6. Segundo mirror de JWKS + `fetch-jwks.sh` bidireccional.
7. `AuthPolicy` validadora on-prem y emisora en EKS; apiKey en el namespace llamador.
8. Split en EKS, **con `exportTo` desde el primer commit**.
9. Aserciones B1-B6.

Los pasos **2, 3 y 4 no dependen del túnel**: se pueden hacer antes de resolver la red y
dejan el terreno listo. Si la fase 6 se aprueba, arrancar por ahí gana tiempo sin
comprometer la decisión de red. **B4 (paso 9) conviene adelantarla ya**, porque protege la
ida que está en producción de la demo.
