# API Manager OCP Subscriber — diseño

Fecha: 2026-10-19 · Estado: propuesto

## Qué es

Un service de nullplatform que suscribe el namespace de una aplicación a una API de APIM (Kuadrant)
que **no** está en nuestro catálogo, usando el API Subscriber de APIM.

- **Instancia del service = una suscripción**: el namespace consumidor × una API externa.
- **Link = uso**: indica qué aplicaciones usan la suscripción. No toca APIM.
- El código de alta, cambio de plan y baja vive acá. Más adelante el link de `api-manager-publisher`
  lo va a llamar para suscribirse a APIs del catálogo; esa integración no es parte de este diseño.

Fuentes: *Integración Null ↔ API Subscriber* (APIM, 2026-10-09), `subscriber.yaml` (0.7.0-draft) y
*Avisos de estado del API Publisher y el API Subscriber a nullplatform* (nullplatform, octubre 2026).
Cuando el Swagger y el documento difieren, vale el documento (`callbackUrl` en lugar de `nullTaskId`).

## Configuración del agente

El agente que atiende este service tiene que tener dos variables de entorno:

| Variable | Uso |
|---|---|
| `API_SUBSCRIBER_URL` | Base del API Subscriber, sin `/v1` |
| `API_SUBSCRIBER_TOKEN` | Credencial de nullplatform para el API Subscriber (en el MVP, un token estático) |

Un agente por tier (nonprd / prd) apunta a su API Subscriber; `tags_selectors` del install elige el agente.
Si falta alguna de las dos, la acción falla con un mensaje que la nombra.

## Formularios

`service-spec.json.tpl` lleva `"use_default_actions": false`: las acciones `create`, `update` y
`delete` son action specifications propias en `specs/actions/`, porque las autogeneradas no admiten
`external`.

**Atributos del service** (lo que queda guardado en la instancia):

| Atributo | Origen | Notas |
|---|---|---|
| `api_name` | usuario | Informativo: el nombre con el que el equipo reconoce la API. La API real sale del RITM. |
| `approval_ref` | usuario | RITM aprobado en ServiceNow. Texto de ayuda: el sugerido por APIM. |
| `plan_id` | usuario, desplegable | Planes de `GET /v1/plans` (external context). |
| `subscription_id` | resultado | `sub-<api>--<namespace>`, devuelto por el API Subscriber. Solo lectura. |
| `operation_id` | resultado | Última operación pedida. Solo lectura. |
| `consumer_namespace` | resultado | Namespace con el que se suscribió. Solo lectura. |

**Acciones:**

| Acción | Tipo | Parámetros | Editable |
|---|---|---|---|
| `create-subscription` | `create` | `api_name`, `approval_ref`, `plan_id` | — |
| `change-plan` | `update` | `plan_id` | solo el plan |
| `delete-subscription` | `delete` | — | — |

`create-subscription` y `change-plan` declaran:

```json
"external": {
  "action": "list-apim-plans",
  "output_schema": {
    "type": "object",
    "required": ["plans"],
    "properties": {
      "plans": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" }, "maxTps": { "type": "number" } }
        }
      }
    }
  }
}
```

y `plan_id` arma el desplegable con `additionalKeywords`, mostrando el TPS y mandando el `id`:

```json
"additionalKeywords": {
  "oneOf": ".external.plans | map({const: .id, title: (.id + \" (\" + (if .maxTps then (.maxTps | tostring) + \" TPS\" else \"sin límite\" end) + \")\")})"
}
```

Si `oneOf` no resuelve por `additionalKeywords`, se cae a `"enum": ".external.plans | map(.id)"`
(se pierde el TPS en la etiqueta, no la funcionalidad). Se verifica en la primera prueba real.

## Flujos

### Planes (external context)

Handler `entrypoint/external`, disparado por la acción `list-apim-plans`:

1. `GET $API_SUBSCRIBER_URL/v1/plans` con `Authorization: Bearer $API_SUBSCRIBER_TOKEN`.
2. Escribe en stdout **solo** `{"plans": [...]}` con los `items` de la respuesta. Todo log va a stderr.
3. Cualquier falla (variable faltante, HTTP no 2xx, JSON inválido) sale con código distinto de 0 y
   nada en stdout: nullplatform marca `agent_error` y el formulario muestra el aviso.

### Alta (`create-subscription`)

El entrypoint corre las acciones del service con `np service-action exec --disable-auto-action-update`:
**el script decide cuándo se cierra la acción**.

1. Lee `approval_ref` y `plan_id` de los parámetros, `service.id` y el id de la acción de la notificación.
2. `consumerNamespace` = `providers["container-orchestration"].cluster.namespace` del build context.
   Si no viene, falla. Nunca se arma con sigla, slug ni ambiente.
3. `callbackUrl` = `https://api.nullplatform.com/service/{service_id}/action/{action_id}`.
4. `POST /v1/subscriptions` con `Idempotency-Key: <action_id>` y
   `{approvalRef, consumerNamespace, planId, callbackUrl}`.
5. Según la respuesta:

| HTTP | Qué hace |
|---|---|
| `202` | Guarda `subscription_id` (`target`), `operation_id` (`id`) y `consumer_namespace` en los results, manda un mensaje de avance y **deja la acción abierta**. La cierra el API Subscriber con `PATCH` al `callbackUrl` (`success` / `failed`). |
| `409` | Cierra `success`: "Tu namespace ya tiene acceso a esta API". **No** guarda `subscription_id`: la suscripción la creó otro pedido, y si esta instancia la guardara, borrarla le quitaría el acceso a quien la creó. Sin `subscription_id`, el cambio de plan falla y la baja no toca APIM. |
| `503` | Reintenta hasta 3 veces, 5 s entre intentos, con la misma `Idempotency-Key`. Si sigue, `failed`. |
| otro | Cierra `failed` con el `detail` del `application/problem+json` (o `title`, o el cuerpo crudo). |

Un `trap` sobre `ERR`/`EXIT` cierra la acción `failed` si el script termina sin haberla cerrado ni
dejado abierta a propósito: con el cierre automático apagado, una acción que nadie cierra queda
pendiente para siempre.

### Cambio de plan (`change-plan`)

1. Lee `subscription_id` de los atributos del service. Si no está, falla (la suscripción nunca se dio de alta).
2. `PATCH /v1/subscriptions/{subscription_id}` con `Idempotency-Key: <action_id>` y
   `{planId, callbackUrl}` (mismo `callbackUrl` que el alta, con el id de esta acción).
3. `202` → guarda `operation_id`, deja la acción abierta. `404` / `422` / otro → `failed` con el
   `detail`. `503` → mismos reintentos que el alta.

### Baja (`delete-subscription`)

1. Lee `subscription_id` de los atributos. Si no está, cierra `success`: no hay nada que dar de baja.
2. `DELETE /v1/subscriptions/{subscription_id}` con `Idempotency-Key: <action_id>`.
3. `202` o `404` → `success`. `503` → reintentos. Otro → `failed` con el `detail`.

El `DELETE` del API Subscriber no recibe `callbackUrl`, así que la baja **no espera** el aviso de
APIM: se cierra con el `202`. Si se quiere esperar, APIM tiene que aceptar `callbackUrl` en el `DELETE`.

### Link y unlink

No-op: se cierran `success` sin tocar APIM. Corren con el cierre automático de `np service-action exec`
(el `--disable-auto-action-update` es solo para las acciones del service). Más adelante, un override del scope va a montar en la
aplicación el Secret `secret-apim-<tenant>` que deja External Secrets; eso no es parte de este diseño.

## Avisos del API Subscriber

Los manda APIM al `callbackUrl`, con el contrato del mini doc de nullplatform: `PATCH` con
`messages` para avances y con `status` (`success` / `failed`) para el resultado final, autenticado con
una API key de servicio que nullplatform le entrega a APIM. Este service no los procesa: los recibe
directamente la API de nullplatform.

## Install (`specs/install/`)

- `service_definition` con `git_provider = "local"`, `use_default_actions = false` y
  `available_actions = ["create-subscription", "change-plan", "delete-subscription"]`.
- **Channel de acciones**: tipo agent, `source = ["service"]`, filtrado por
  `service.specification.slug`, con su API key del módulo `api_key`.
- **Channel de external context**: tipo agent, `source = ["service"]`, filtrado por
  `action $in ["list-apim-plans"]` (sin filtros sobre `service.*`, que no existen al crear),
  con su API key del módulo `api_key`.

## Cambio en `tofu-modules`

`nullplatform/service_definition` pasa `external` a las link specifications pero no a las action
specifications, aunque el provider lo soporta. Se agrega a `nullplatform_action_specification.from_templates`:

```hcl
external = try(jsonencode(local.action_specs_parsed[each.key].external), null)
```

PR aparte en `nullplatform/tofu-modules`, con su test; el install de este service fija la versión que lo incluya.

## Estructura

```
api-manager-ocp-subscriber/
  entrypoint/{entrypoint,service,link,external}
  workflows/{create-subscription,change-plan,delete-subscription,link,unlink}.yaml
  scripts/{subscriber_lib,subscribe,change_plan,unsubscribe,list_plans}
  specs/service-spec.json.tpl
  specs/actions/{create-subscription,change-plan,delete-subscription}.json.tpl
  specs/links/connect.json.tpl
  specs/install/
  tests/*.bats
  docs/DISENO.md
```

`subscriber_lib` concentra el HTTP contra el API Subscriber (headers, reintentos de `503`, lectura del
`detail`) y el cierre de la acción, para que el publisher lo reuse.

## Tests (BATS)

Mocks de `curl`, `np` y `kubectl` que modelan el comportamiento real (códigos HTTP, cuerpo
`problem+json`, `-w '%{http_code}'`) y registran cada invocación en un archivo.

- Alta: `202` deja la acción abierta y guarda los results; `409` cierra `success`; `422` cierra
  `failed` con el `detail`; `503` reintenta y después cierra `failed`; sin namespace en el provider
  falla sin llamar a APIM; error inesperado cierra `failed` por el `trap`; falta una variable del agente.
- Cambio de plan: `202`; sin `subscription_id`; `422`.
- Baja: `202`, `404` y sin `subscription_id` cierran `success`; otro código cierra `failed`.
- Planes: stdout es solo JSON; ante error, stdout vacío y exit ≠ 0.
- Link / unlink: no llaman a `curl`.

Cada test nuevo se corre primero contra la implementación sin el cambio para ver que falla.

## Fuera de este diseño

- Integración con `api-manager-publisher` y la parte de publish (llega aparte).
- Override que monta `secret-apim-<tenant>` en la aplicación.
- Confirmar un `409` con `GET /v1/subscriptions/{id}`.
- Polling de `GET /v1/operations/{id}` como respaldo de los avisos.
