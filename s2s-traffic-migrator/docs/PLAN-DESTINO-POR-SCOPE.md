# Plan — el destino de una intercepción es un **scope**, no un FQDN

Sucede a `plans/egress-gateway-por-namespace.md`, que está cerrado. Ese plan dejó el service andando
con Kuadrant, pero con un campo mal puesto: la regla pedía un `target_fqdn`, y lo que se cargaba ahí
era `s2s-remote-gateway.tailscale.svc.cluster.local` — la **dirección de transporte del Kuadrant
remoto**, que es andamiaje de la PoC. Le estábamos pidiendo al dev que conozca la topología.

**El cambio:** la regla declara un `scope`. La dirección del Kuadrant remoto pasa a ser configuración
del service. Decidido con el usuario el 2026-08-25.

## Cómo retomar esto desde cero

1. Leé este archivo entero antes de tocar nada, y después `services/s2s-traffic-migrator/README.md`.
2. El código del service está en `services/egress-interceptor/`; la capa de plataforma en
   `accounts/galicia/demo-kuadrant-s2s/modules/kuadrant-s2s/`.
3. El diagrama `services/egress-interceptor/arquitectura-egress.drawio` describe el diseño **viejo**:
   hay que rehacerlo (ver Fase 5). No lo uses como referencia hasta entonces.

---

## El modelo decidido

Una regla tiene **tres** campos: `service_name`, `scope`, `percent`.

> `service_name` es la dirección de ese servicio **del lado OpenShift** (un Service, este-oeste).
> `scope` es su dirección **del lado EKS** (un fqdn, norte-sur).
> `percent` es cuánto del tráfico se va al **otro** sustrato — el opuesto al del que llama.

> ⚠️ **Superado el 2026-08-27.** `percent` pasó a significar siempre **qué % se atiende en EKS**, sin importar desde dónde se llame: `0` es todo en OpenShift y `100` todo en EKS. La implementación para origen EKS estaba invertida respecto de eso y se corrigió. Se deja el texto original porque describe el diseño con el que se cerró este plan.

La declara el **dueño del servicio**, no el que lo consume: la instancia se cuelga de la aplicación
destino. Así una sola regla reparte el tráfico de todos los callers, y ninguno de ellos declara nada
ni se entera de que hubo una migración.

La regla describe **el servicio**, no la topología del que llama. Por eso la misma regla sirve para
los dos orígenes, y cuál de las dos direcciones es "local" lo decide el origen y no el form.

| Origen | Rama local (`100-percent`) | Rama migrada (`percent`) |
|---|---|---|
| **OpenShift** | Service `<svc>-local` (clon, este-oeste) | ingreso de EKS, con `Host` = fqdn del scope |
| **EKS** | ingreso local, con `Host` = fqdn del scope | ingreso de OpenShift, header `X-NP-SVC: <svc>` |

**El fqdn del scope viaja como `Host`, no como backend.** Un `backendRef` necesita un host del
registro de Istio; el fqdn de un scope sólo existe como `hostnames` de un `HTTPRoute`, y eso hace
que el Gateway lo ATIENDA, no que un Envoy pueda conectarse ahí. Apuntarle directo da 500 sin
cluster — costó un 500 en el egreso y otro en el ingreso antes de entenderlo.

Y se entra **siempre por el `HTTPRoute` del propio scope**, que es el que lleva los pesos del
blue/green y el nombre del backend de turno: es lo que evita que el service tenga que actualizarse
en cada despliegue.

Con origen EKS: `percent=0` → todo al fqdn del scope; `percent=100` → todo a OpenShift.

**Por qué en EKS no hay `-local`:** en EKS no hay tráfico por `svc.cluster.local`. Con blue/green el
nombre del Service cambia en cada deployment, así que la única dirección estable es el fqdn del
scope — y su `HTTPRoute` es el que reparte entre los deployments. Apuntar a un Service se saltearía
ese reparto. Ninguna regla nuestra en EKS termina referenciando un Service: siempre norte-sur. En
OpenShift el este-oeste **sí** queda.

## Lo que NO cambia

- El ingreso: `s2s-ingress` sigue siendo un Gateway propio, con su `AuthPolicy` validando el
  wristband y su `RateLimitPolicy`. El tráfico S2S pasa por nuestro Gateway, no por el de la
  plataforma. Se descartó montar la `AuthPolicy` sobre el Gateway que sirve los fqdn de scope:
  ese Gateway también atiende tráfico que no es S2S, y una policy que exige wristband le daría 401.
- El contrato de identidad completo: wristband RS256, clave por (cluster × namespace), `overrides`
  fijando la identidad según qué clave validó, `authorized_namespaces` con `eq`.
- El hijack de selector **del lado OpenShift**, y el alias `<svc>-local` ahí.
- La derivación del header desde el origen.

⚠️ Esto **rompe el invariante 5** del plan anterior ("el contrato externo no cambia"): cambia el
form, cambia el valor de `X-NP-Scope` y cambian los cuatro escenarios del runbook. Es a propósito.

---

## Fase 1 — El form

- [x] `specs/service-spec.json.tpl`: sacar `target_fqdn` de `interceptions.items`, agregar `scope`:

  ```json
  "scope": {
    "type": "string",
    "title": "Scope",
    "order": 2,
    "additionalKeywords": {
      "enum": "[.scopes[]?.slug] | if length == 0 then [\"No scopes available for selected environment\"] else . end"
    }
  }
  ```

  `.scopes` es contexto **nativo** de `additionalKeywords` (no hace falta external field ni agente):
  el contexto es `{service, link, scope, application, scopes, services, namespace, account,
  dimensions, external}` y cada clave aparece si el request trae el parámetro correspondiente. El
  `dimensions` del contexto es lo que hace que la lista se filtre por environment sola.
- [x] `required` de la regla pasa a `["service_name", "scope", "percent"]`.
- [x] `uiSchema`: reemplazar el Control de `target_fqdn` por el de `scope`.
- [x] El atributo read-only `resolved` pasa a mostrar el fqdn resuelto por scope (es el único lugar
      donde el dev puede ver a qué se tradujo su elección).
- [ ] Republicar el spec.

### Quién declara la regla, y por qué `.scopes` es la lista correcta

La instancia del service se cuelga de la **aplicación destino**: la dueña de `reports`, la que tiene
el scope en EKS que va a recibir el tráfico. No de la aplicación que llama.

De ahí sale que `.scopes` sea exactamente la lista que hace falta —son los scopes de la app dueña del
servicio— y que **una sola regla alcance para todos los que llaman**: se intercepta el Service
`reports` en el namespace de `reports`, que es el nombre por el que lo alcanzan todos, y el reparto
queda hecho para cualquier caller sin que ninguno declare nada.

Consecuencia para las fases 3 y 4: el namespace donde aterrizan los manifests es el **del destino**,
no el del caller. `build_context` ya lo resuelve bien —sale del provider `container-orchestration` de
la instancia— pero el nombre de la variable y los comentarios hablan de "el namespace de la app" como
si fuera el del que llama. Hay que corregir el vocabulario para que no confunda a quien lo lea.

## Fase 2 — Resolver scope → fqdn

- [x] `build_context` resuelve cada `scope` (slug) a su `domain`. El application id sale del
      `$CONTEXT` que arma `--build-context`:

  ```bash
  np scope list --application-id "$APP_ID" --status active \
    --query '[.results[]? // .[]? | select(.slug==$slug)] | .[0].domain'
  ```

  Verificar la forma real de la salida (`{results:[…]}` vs array pelado) antes de fijar el filtro.
- [x] Fallar **ruidosamente** si un slug no resuelve o si el `domain` es `"To be defined"` — un scope
      sin desplegar tiene ese literal, y dejarlo pasar rendería un `HTTPRoute` que apunta a un
      hostname inválido sin que nada se queje.
- [x] Validar el fqdn resuelto con el mismo `require_match` que el resto: se interpola en YAML.
- [x] Test en `tests/build_context.bats`: slug que resuelve, slug que no existe, `domain` sin definir.

## Fase 3 — El render

- [x] `manifests/egress/`: el backend de cada rama depende de `origin` (un archivo por objeto).
  - `origin=OS`: migrada → `kind: Hostname` = **la dirección del Kuadrant remoto** (config, no la
    regla), header `X-NP-Scope: <fqdn del scope>`; local → Service `<svc>-local`.
  - `origin=EKS`: migrada → `kind: Hostname` = la dirección del Kuadrant remoto, header
    `X-NP-SVC: <svc>`; local → `kind: Hostname` = **el fqdn del scope**, puerto 443.
- [x] Con `origin=EKS` el `DestinationRule` del fqdn del scope necesita su propio TLS: es un fqdn
      público (`*.nullapps.io`), no el peer con la CA de la PoC. Son **dos** DestinationRule
      distintos, con material de confianza distinto.
- [x] Nueva variable de configuración del workflow (`create.yaml`), no del form: la dirección del
      Kuadrant remoto. En la PoC `s2s-remote-gateway.tailscale.svc.cluster.local`; en producción el
      DNS del Banco resuelto por Direct Connect.
- [x] Tests de render en `tests/render.bats` para las cuatro combinaciones (2 orígenes × percent
      0/50/100), asertando **qué backend** tiene cada rama, no sólo que renderiza.

## Fase 4 — El reconcile

- [x] `origin=EKS`: **crear** el Service `<svc>` apuntando a los pods del Gateway de egreso (no hay
      nada que hijackear), con las labels `egress-interceptor/managed=true` y `nullplatform=true`
      para que el delete lo pueda borrar.
- [x] `origin=EKS`: no crear el alias `<svc>-local`, y no exigir endpoints locales cuando
      `percent < 100` — el chequeo actual asume un backend in-cluster que ahí no existe.
- [x] `origin=OS`: sin cambios.
- [x] El delete tiene que distinguir los dos casos: con `origin=EKS` borra el Service que creó; con
      `origin=OS` revierte el selector desde la annotation. Hoy sólo sabe hacer lo segundo.

## Fase 5 — Plataforma, demo y docs

- [x] ⚠️ **Superado — ver "Cerrado el 2026-08-26" más abajo:** el ingreso de EKS terminó sin
      ninguna route nuestra (la del scope ya cuelga del Gateway) y `scope_backends` se eliminó. Lo
      que sigue describe el diseño intermedio.
      `modules/kuadrant-s2s`: el `HTTPRoute` del ingreso **de EKS** pasa a matchear
      `X-NP-Scope: <fqdn del scope>` y a reenviar a ese fqdn (`kind: Hostname`), en vez de matchear
      el nombre del servicio y entregar a `<svc>-local`. La var `intra_namespace_backends` deja de
      describir Services y pasa a describir fqdn de scope aceptados. El ingreso **de OpenShift** no
      cambia: sigue matcheando `X-NP-SVC` y entregando al Service `-local`.
- [ ] **Dependencia externa:** hace falta un scope desplegado en EKS. Al 2026-08-25 no hay ninguno
      (el único activo de la app tiene `domain: "To be defined"`). Sin eso los escenarios con destino
      EKS no se pueden correr.
- [x] `demo.sh`: los bodies pasan a mandar `scope` en vez de `target_fqdn`.
- [x] `RUNBOOK-PRUEBAS.md`: los cuatro escenarios cambian. Con origen EKS ya no hay rama local
      in-cluster, así que el `wget` a `reports.payments.svc.cluster.local` sólo aplica del lado
      OpenShift.
- [ ] `arquitectura-egress.drawio`: rehacer **al final**, cuando el modelo esté probado contra el
      cluster. Sigue el código, no al revés. Las cuatro páginas describen el diseño viejo; lo más
      equivocado es la página 3 (los cuatro casos) y el `-local` del lado EKS en la página 1.
- [x] `docs/s2s-egress-sin-openresty.md` y `GUIA-DEMO-DETALLE.md`.

---

## Invariantes que no se negocian

Los cinco del plan anterior, con el 5 reemplazado:

1. **Una clave de firma por (cluster × namespace)**, nunca una por cluster.
2. **La identidad se deriva de qué clave verificó la firma**, nunca del claim `iss`.
3. **El material de firma no sale de un `Secret`**.
4. **La `NetworkPolicy allow-intra-namespace` sigue acotando quién puede pedir firma.**
5. **El dev no declara direcciones de transporte.** Declara identidades de nullplatform (un scope, un
   nombre de servicio) y la plataforma las resuelve. Es la razón de ser de este plan: cualquier campo
   del form que contenga un hostname de infraestructura es un bug.

## Cosas que ya sabemos y conviene no volver a descubrir

Además de las del plan anterior:

- El fqdn de un scope es un `HTTPRoute`, y es el que hace el blue/green entre deployments. Cualquier
  cosa que apunte a un Service en EKS se saltea ese reparto.
- `.scopes` en `additionalKeywords` no necesita agente; `.external` sí.
- Un scope sin desplegar tiene `domain: "To be defined"` — un string, no `null`.

---

## Estado al 2026-08-25

Fases 1-4 completas y la parte de Terraform de la 5. **62/62 BATS, los dos layers validan.**
Verificado por mutación: los tests nuevos fallan contra el código viejo (10/10 en `build_context`,
21/33 en `render`).

**Bloqueado en:** no hay ningún scope desplegado en EKS. Sin eso `tofu plan` de `clusters/eks` falla
por la precondition de `scope_backends` —a propósito— y el reconcile aborta al resolver el slug.
Sólo el Paso 14 del runbook (origen OpenShift, `percent=0`, todo este-oeste) corre sin eso.

**Sin verificar contra la plataforma**, porque la API key del repo da 403 en `np scope list`:
1. Que `$CONTEXT` traiga `.application.id` con ese nombre exacto.
2. La forma del envelope de `np scope list` (el filtro aguanta las dos: `(.results? // .)`).

Las dos fallan ruidosamente si no se cumplen, y las dos se despejan con el primer `create` real.

### Deuda de documentación, preexistente

`GUIA-DEMO-DETALLE.md` tiene una sección de observabilidad (los bloques de log `s2s-sign`,
request-id, y el ejemplo de salida) que describe líneas que emitía **OpenResty** y que hoy no
existen. Es drift anterior a este plan; necesita su propia pasada.

---

## Cerrado el 2026-08-26

La demo corrió entera: aislamiento 401/403/403/200, los cuatro escenarios y el barrido
(0 → 20 local · 50 → 9/11 · 100 → 20 remoto). 68/68 tests, los dos layers validan.

### Lo que cambió respecto de lo planeado

- **El ingreso de EKS no lleva ninguna route nuestra.** La del scope ya cuelga del Gateway y queda
  bajo la `AuthPolicy`; duplicarla obligaría a actualizarla en cada despliegue. `scope_backends`
  se eliminó.
- **El Gateway de ingreso se mudó a `gateways`**, no `istio-system`: el template de `HTTPRoute` de
  los scopes hardcodea ese namespace en su `parentRef`. Se parametrizó con `var.gateway_namespace`.
- **`x-s2s-cluster` ya no llega desde EKS**, porque lo estampaba nuestra route. La señal de que un
  request cruzó pasó a ser el **contador de Authorino del destino**, que además prueba más. Para
  ver por request quién atendió, `/whoami` devuelve el pod.
- **El `delete` podía perder el selector original** y dejar el Service sin endpoints, sin nada para
  recuperarlo. Pasó de verdad en EKS. Ahora relee el selector antes de soltar la annotation,
  rechaza una annotation envenenada y se niega a borrar el Gateway si algún Service lo apunta
  (`tests/revert.bats`).

### Costo medido

Un hop de Gateway con validación: **p50 12.9 ms** contra 1.2 ms directo al pod (n=60, conexión
reusada, intra-cluster). Con origen EKS y `percent=0` se pagan dos hops (~25 ms), porque también
la rama local entra por el ingreso. Sin reuso de conexión el número sube a ~33 ms por el handshake
TLS, pero Envoy poolea: ese no es el número real.

### Pendiente

- Rehacer `arquitectura-egress.drawio`: describe el diseño de dos iteraciones atrás.
- La regla de SG que abre :80 pod-a-pod en el node group de EKS se agregó **por CLI**, fuera de
  Terraform (`sgr-020f430778a433c00`). Sin ella el traffic-manager de un scope sólo responde si
  cae en el mismo nodo que el Gateway.
- `cluster` sigue siendo required en los `parameters` del action spec de update, aunque el selector
  del channel lo defaultea desde los attributes. `demo.sh` lo manda para no depender de eso.
