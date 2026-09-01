# Api Manager — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir el service de nullplatform "Api Manager", que permite a una aplicación declarar qué paths expone bajo qué hosts para ser consumidos desde otros namespaces, con API key por consumidor validada por Kuadrant.

**Architecture:** Un service de nullplatform con acciones `create`/`update`/`delete` y un link `connect`. Las acciones materializan un `HTTPRoute` (colgado del Gateway global del cluster, con `backendRef` de `kind: Hostname` al dominio del scope) y una `AuthPolicy` de Kuadrant en el namespace de la app. El link genera una API key opaca, la guarda como `Secret` en `kuadrant-system` y la exporta como secret parameter al consumidor.

**Tech Stack:** Bash + `np` CLI + `kubectl` + `gomplate` (templates), BATS (tests), OpenTofu (registro), Kuadrant/Authorino + Gateway API (Istio).

**Spec:** [`plans/api-manager-diseno.md`](./api-manager-diseno.md) — leerlo completo antes de empezar. El plan argumenta desde ahí.

**Repo destino:** `~/nullplatform/galicia/custom-scopes-workshop-fede-galicia-override/`, carpeta nueva `api-manager/`, branch nuevo, PR nuevo.

**Referencia de convención:** `egress-interceptor/` en ese mismo repo. Leer sus archivos antes de escribir el equivalente.

---

## Global Constraints

- **CERO comentarios en el código.** Ni en bash, ni en YAML, ni en HCL, ni en los tests. El `egress-interceptor` tiene comentarios densos: **no** son licencia para agregar más. Toda la justificación (por qué este orden, qué bug previene, qué alternativa se descartó) va en la **descripción del PR**, nunca en el archivo. Si algo es inexplicable sin nota, hacer el código más claro.
- **Idioma:** castellano rioplatense en mensajes de log, errores y documentación. Términos técnicos en inglés (Gateway, scope, HTTPRoute).
- **`set -e` no protege.** El runner de la CLI de nullplatform sourcea los steps desde un contexto `if !`, lo que **neutraliza `errexit`**. Todo comando cuyo fallo importa lleva `|| die "..."` explícito.
- **`for x in $(cmd)` no dispara errexit** cuando `cmd` falla: el loop itera cero veces y el script sigue. Capturar en variable con su propio chequeo.
- **`local x=$(cmd)` enmascara el status** de `cmd`. Separar: `local x; x=$(cmd)`.
- **Nunca esperar `ResolvedRefs`** en un `HTTPRoute` con `backendRefs` de `kind: Hostname`: Istio reporta `ResolvedRefs=False (BackendNotFound)` con el tráfico funcionando (gotcha #27). La única condición válida es `Accepted`.
- **`kubectl wait --for=condition=` no funciona en `HTTPRoute`**: mira `.status.conditions`, que siempre está vacío. Las condiciones viven en `.status.parents[]`, una entrada por controller.
- **Nombre del service:** `Api Manager`. La API calcula el slug del `name` → `api-manager`. **No declarar un campo `slug`** en el spec: la API lo ignora.
- **Prefijo de labels:** `api-manager.nullplatform.io/`. Env var exportada: `API_MANAGER_API_KEY`. Header: `x-api-key`.
- **Identificador de app expuesta** (valor del label `target` y de la regla de authorization): `<k8s-namespace>.<application-slug>`, ej. `payments.reports`. Máximo 63 caracteres (límite de valor de label).
- **Tests:** BATS, requieren `bash >= 4`. Correr con `PATH=/opt/homebrew/bin:$PATH bats tests/`. Todo test nuevo se corre **primero contra el código sin arreglar** para confirmar que falla.
- **Commits:** una sola línea, prefijo convencional, sin cuerpo. **Nunca** poner a Claude como contributor.
- **Nada de secretos versionados.** Verificar antes de cada commit.

---

## File Structure

```
api-manager/
├── README.md                              # doc del service (Task 10)
├── logging                                # copiado verbatim del egress-interceptor (Task 1)
├── entrypoint/
│   ├── entrypoint                         # router del agente (Task 1)
│   ├── service                            # acciones de service → workflows/istio/<action>.yaml (Task 1)
│   └── link                               # acciones de link → workflows/istio/<link|unlink>.yaml (Task 7)
├── workflows/istio/
│   ├── create.yaml  update.yaml  delete.yaml   (Tasks 1, 5)
│   └── link.yaml    unlink.yaml                (Task 7)
├── scripts/k8s/
│   ├── build_context                      # notificación + resolución de scopes → dominios (Task 3)
│   ├── manifests_lib                      # render + apply (Task 4)
│   ├── reconcile                          # apply / delete (Task 5)
│   ├── check_collisions                   # (host, path) ya tomado (Task 6)
│   ├── mint_key                           # link (Task 7)
│   ├── revoke_key                         # unlink (Task 7)
│   └── write_service_outputs              # resultados de la acción (Task 5)
├── manifests/
│   ├── expose/
│   │   ├── 10-httproute.yaml.tpl          (Task 4)
│   │   └── 20-authpolicy.yaml.tpl         (Task 4)
│   └── rbac.yaml.tpl                      (Task 9)
├── specs/
│   ├── service-spec.json.tpl              (Task 2)
│   ├── links/connect.json.tpl             (Task 2)
│   ├── install/                           (Task 9)
│   └── prerequisites/                     (Task 9)
└── tests/
    ├── build_context.bats                 (Task 3)
    ├── render.bats                        (Task 4)
    ├── fail_fast.bats                     (Task 5)
    ├── collisions.bats                    (Task 6)
    └── keys.bats                          (Task 7)
```

---

### Task 0: Validar en el cluster que Authorino expone los labels del Secret

Es el supuesto §7.4 del diseño y **compuerta de todo lo demás**: la regla de authorization de la `AuthPolicy` lee `auth.identity.metadata.labels[...]`. Si eso no resuelve, el selector de autorización cambia y varias tareas se reescriben. No escribir nada más hasta cerrar esto.

**Files:** ninguno. Es una verificación manual contra el cluster.

**Interfaces:**
- Produce: la confirmación (o el reemplazo) del selector `auth.identity.metadata.labels.apimgr-target`, que consumen las Tasks 4 y 7.

- [ ] **Step 1: Levantar un target mínimo con su HTTPRoute**

Usar el cluster de la demo. Crear un namespace de prueba con un echo server y un `HTTPRoute` colgado del Gateway global. Reutilizar lo que ya existe en `accounts/galicia/demo-kuadrant-s2s/` en lugar de armarlo de cero.

- [ ] **Step 2: Crear dos Secrets de API key con labels distintos**

```bash
kubectl -n kuadrant-system create secret generic apimgr-test-ok \
  --from-literal=api_key="$(openssl rand -hex 32)"
kubectl -n kuadrant-system label secret apimgr-test-ok \
  authorino.kuadrant.io/managed-by=authorino \
  api-manager.nullplatform.io/managed=true \
  apimgr-target=payments.reports

kubectl -n kuadrant-system create secret generic apimgr-test-otra \
  --from-literal=api_key="$(openssl rand -hex 32)"
kubectl -n kuadrant-system label secret apimgr-test-otra \
  authorino.kuadrant.io/managed-by=authorino \
  api-manager.nullplatform.io/managed=true \
  apimgr-target=otra.app
```

- [ ] **Step 3: Aplicar la AuthPolicy con el selector a validar**

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: apimgr-test
  namespace: <ns-de-prueba>
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: <route-de-prueba>
  rules:
    authentication:
      consumer-key:
        apiKey:
          selector:
            matchLabels:
              api-manager.nullplatform.io/managed: "true"
        credentials:
          customHeader:
            name: x-api-key
    authorization:
      allowed-target:
        patternMatching:
          patterns:
            - selector: auth.identity.metadata.labels.apimgr-target
              operator: eq
              value: "payments.reports"
```

- [ ] **Step 4: Confirmar que quedó Enforced, no sólo Accepted**

```bash
kubectl -n <ns-de-prueba> get authpolicy apimgr-test \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
```

Esperado: `True`. Si dice `False` o no existe la condición, la policy no está enforceando (gotcha #22): revisar que el `HTTPRoute` esté colgado del Gateway antes de seguir.

- [ ] **Step 5: Probar las cuatro respuestas**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<host>/<path>
curl -s -o /dev/null -w '%{http_code}\n' -H "x-api-key: no-existe" https://<host>/<path>
curl -s -o /dev/null -w '%{http_code}\n' -H "x-api-key: $(kubectl -n kuadrant-system get secret apimgr-test-otra -o jsonpath='{.data.api_key}' | base64 -d)" https://<host>/<path>
curl -s -o /dev/null -w '%{http_code}\n' -H "x-api-key: $(kubectl -n kuadrant-system get secret apimgr-test-ok -o jsonpath='{.data.api_key}' | base64 -d)" https://<host>/<path>
```

Esperado, en orden: `401`, `401`, **`403`**, `200`.

El tercero es el que valida el supuesto. Si da `401` en vez de `403`, Authorino **no** está resolviendo los labels y hay que cambiar de mecanismo (probar con un segundo campo dentro del `Secret` en lugar del label, y ajustar Tasks 4 y 7 antes de escribirlas).

- [ ] **Step 6: Limpiar**

```bash
kubectl -n kuadrant-system delete secret apimgr-test-ok apimgr-test-otra
kubectl -n <ns-de-prueba> delete authpolicy apimgr-test
```

- [ ] **Step 7: Registrar el resultado en el diseño**

Editar `plans/api-manager-diseno.md` §7.4: reemplazar "Sin verificar" por el resultado y la fecha. Commit en `galicia-banco`:

```bash
git add plans/api-manager-diseno.md
git commit -m "docs(api-manager): confirmar la resolucion de labels del Secret en Authorino"
```

---

### Task 1: Esqueleto del service

Deja el service enrutando acciones aunque todavía no hagan nada. Entregable testeable: el agente toma una acción `create` y llega al workflow sin romper.

**Files:**
- Create: `api-manager/logging`
- Create: `api-manager/entrypoint/entrypoint`
- Create: `api-manager/entrypoint/service`
- Create: `api-manager/workflows/istio/create.yaml`

**Interfaces:**
- Produce: la función `log <level> <message>`, que consumen todos los scripts. Los niveles son `debug` < `info` < `warn` < `error`, filtrados por `LOG_LEVEL` (default `info`); `error` va a stderr.
- Produce: `SERVICE_PATH` (absoluto, dir del service), `CONTEXT` (`.notification` de la notificación), `SERVICE_ACTION` (`.slug`), `SERVICE_ACTION_TYPE` (`.type`), que consume `entrypoint/service`.

- [ ] **Step 1: Crear el branch**

```bash
cd ~/nullplatform/galicia/custom-scopes-workshop-fede-galicia-override
git checkout main && git pull
git checkout -b feat/api-manager
mkdir -p api-manager/{entrypoint,workflows/istio,scripts/k8s,manifests/expose,specs/links,tests}
```

- [ ] **Step 2: Copiar `logging` verbatim**

```bash
cp egress-interceptor/logging api-manager/logging
chmod +x api-manager/logging
```

No editarlo. Viene de `scopes/k8s/logging` de la plataforma; si allá cambia, se re-copia.

- [ ] **Step 3: Escribir `entrypoint/entrypoint`**

Copiar de `egress-interceptor/entrypoint/entrypoint` **quitando todos los comentarios**. Contenido:

```bash
#!/bin/bash
set -euo pipefail

if [ -z "${NP_ACTION_CONTEXT:-}" ]; then
  echo "NP_ACTION_CONTEXT is not set. Exiting."
  exit 1
fi

if [ -n "${NP_API_KEY:-}" ] && [ -z "${NULLPLATFORM_API_KEY:-}" ]; then
  export NULLPLATFORM_API_KEY="$NP_API_KEY"
fi

CLEAN_CONTEXT=$(echo "$NP_ACTION_CONTEXT" | sed "s/^'//;s/'$//")
export NP_ACTION_CONTEXT="$CLEAN_CONTEXT"
export CONTEXT=$(echo "$CLEAN_CONTEXT" | jq '.notification')
export SERVICE_ACTION=$(echo "$CONTEXT" | jq -r '.slug')
export SERVICE_ACTION_TYPE=$(echo "$CONTEXT" | jq -r '.type')
export NOTIFICATION_ACTION=$(echo "$CONTEXT" | jq -r '.action')

export WORKING_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVICE_PATH="$(dirname "$WORKING_DIRECTORY")"
if [[ "$SERVICE_PATH" != /* ]]; then
  if [ -d "$SERVICE_PATH" ]; then
    SERVICE_PATH="$(cd "$SERVICE_PATH" && pwd)"
  elif [ -d "$HOME/.np/$SERVICE_PATH" ]; then
    SERVICE_PATH="$(cd "$HOME/.np/$SERVICE_PATH" && pwd)"
  else
    echo "ERROR: no resuelvo SERVICE_PATH='$SERVICE_PATH' desde CWD=$(pwd) ni ~/.np/"
    exit 1
  fi
fi
export SERVICE_PATH

np service-action exec --live-output --live-report --script="$WORKING_DIRECTORY/service"
```

- [ ] **Step 4: Escribir `entrypoint/service`**

```bash
#!/bin/bash
set -euo pipefail
echo "Executing service action=$SERVICE_ACTION type=$SERVICE_ACTION_TYPE"

ACTION_TO_EXECUTE="$SERVICE_ACTION_TYPE"
case "$SERVICE_ACTION_TYPE" in
  "custom") ACTION_TO_EXECUTE="$SERVICE_ACTION" ;;
esac

if [[ ! "$ACTION_TO_EXECUTE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "acción inválida: '$ACTION_TO_EXECUTE'" >&2
  exit 1
fi

WORKFLOW_PATH="$SERVICE_PATH/workflows/istio/$ACTION_TO_EXECUTE.yaml"

np service workflow exec --workflow "$WORKFLOW_PATH" --build-context --include-secrets
```

El regex de `ACTION_TO_EXECUTE` es anti-inyección: el valor viene del CONTEXT y se interpola en un path. **No usar `eval`.**

- [ ] **Step 5: Escribir `workflows/istio/create.yaml` mínimo**

```yaml
provider_categories:
  - container-orchestration
configuration:
  GATEWAY_NAME: s2s-ingress
  GATEWAY_NAMESPACE: gateways
  KEYS_NAMESPACE: kuadrant-system
  API_KEY_HEADER: x-api-key
steps:
  - name: load logging
    type: script
    file: "$SERVICE_PATH/logging"
    output:
      - name: log
        type: function
        parameters:
          level: string
          message: string
```

- [ ] **Step 6: Permisos y verificación de sintaxis**

```bash
chmod +x api-manager/entrypoint/entrypoint api-manager/entrypoint/service
bash -n api-manager/entrypoint/entrypoint && bash -n api-manager/entrypoint/service && echo "sintaxis OK"
```

- [ ] **Step 7: Verificar que no quedaron comentarios**

```bash
grep -n '^\s*#' api-manager/entrypoint/entrypoint api-manager/entrypoint/service | grep -v '^\S*:1:#!/bin/bash'
```

Esperado: sin salida. El único `#` admitido es el shebang.

- [ ] **Step 8: Commit**

```bash
git add api-manager/
git commit -m "feat(api-manager): esqueleto del service y router de acciones"
```

---

### Task 2: Specs del service y del link

Entregable testeable: los dos JSON son válidos y renderizan con gomplate, y el formulario se ve en la UI.

**Files:**
- Create: `api-manager/specs/service-spec.json.tpl`
- Create: `api-manager/specs/links/connect.json.tpl`

**Interfaces:**
- Produce: los nombres de atributos `hosts` (array de string) y `routes` (array de objetos con `path`, `methods`, `scope`), que consume `build_context` (Task 3).
- Produce: el atributo de link `api_key` (string, exportado como `API_MANAGER_API_KEY`), que consume `mint_key` (Task 7).

- [ ] **Step 1: Escribir `specs/service-spec.json.tpl`**

El `uiSchema` lleva el `Label` de markdown **primero**, después los dos `Control`. El bloque `routes` copia el patrón de detalle del endpoint-exposer upstream (`~/nullplatform/apps/services-endpoint-exposer/specs/service-spec.json.tpl`), incluidos su regex de `path` y su enum de `methods`.

```json
{
  "name": "Api Manager",
  "type": "dependency",
  "visible_to": ["{{ env.Getenv `NRN` }}"],
  "dimensions": {},
  "scopes": {},
  "assignable_to": "any",
  "use_default_actions": true,
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": ["hosts", "routes"],
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          {
            "type": "Label",
            "options": { "format": "markdown" },
            "text": "## Api Manager\n\n### FAQ\n\n**¿Cuándo tengo que usarlo?** Cuando otra aplicación, que corre en otro namespace, necesita consumir la tuya. Por defecto las aplicaciones de distintos namespaces no se ven entre sí.\n\n**¿Qué hace el servicio?** Publica los paths que declarás acá bajo los dominios que elijas, y los deja alcanzables desde otros namespaces. Lo que no declarás sigue siendo inalcanzable.\n\n**¿Cómo hace otra app para consumirme?** Se linkea a este servicio. En ese momento recibe su propia credencial como variable de entorno, sin que nadie copie ni pegue nada.\n\n**¿Puedo cortarle el acceso a alguien?** Sí, borrando el link. Es inmediato y sólo afecta a esa aplicación.\n\n**¿Tengo que cambiar algo en mi código?** No. Tu aplicación sigue escuchando donde escucha hoy."
          },
          {
            "type": "Control",
            "label": "Dominios",
            "scope": "#/properties/hosts"
          },
          {
            "type": "Control",
            "scope": "#/properties/routes",
            "options": {
              "elementLabelProp": "summary",
              "showSortButtons": true,
              "detail": {
                "type": "VerticalLayout",
                "elements": [
                  { "type": "Control", "label": "Verbos", "scope": "#/properties/methods" },
                  {
                    "type": "HorizontalLayout",
                    "elements": [
                      { "type": "Control", "label": "Path", "scope": "#/properties/path" },
                      { "type": "Control", "label": "Scope", "scope": "#/properties/scope" }
                    ]
                  }
                ]
              }
            }
          }
        ]
      },
      "properties": {
        "hosts": {
          "type": "array",
          "title": "Dominios",
          "description": "Dominios por los que se expone la aplicación. Otras apps la van a consumir por acá.",
          "minItems": 1,
          "uniqueItems": true,
          "items": {
            "type": "string",
            "pattern": "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"
          }
        },
        "routes": {
          "type": "array",
          "title": "Rutas expuestas",
          "minItems": 1,
          "items": {
            "type": "object",
            "required": ["methods", "path", "scope"],
            "properties": {
              "path": {
                "type": "string",
                "title": "Path",
                "pattern": "^/([a-zA-Z0-9_\\-\\.:\\*{}/]*)?$",
                "description": "Tiene que empezar con /. Ejemplos: /, /api, /api/v1/users, /items/{id}, /files/*"
              },
              "scope": {
                "type": "string",
                "title": "Scope",
                "description": "Scope de la aplicación que atiende esta ruta.",
                "additionalKeywords": {
                  "enum": "[.scopes[]?.slug] | if length == 0 then [\"No hay scopes disponibles\"] else . end"
                }
              },
              "methods": {
                "type": "array",
                "title": "Verbos",
                "minItems": 1,
                "uniqueItems": true,
                "items": {
                  "type": "string",
                  "enum": ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
                }
              },
              "summary": {
                "type": "string",
                "title": "Resumen",
                "editableOn": ["create", "update"],
                "visibleOn": []
              }
            }
          }
        }
      }
    },
    "values": {}
  },
  "selectors": {
    "category": "Networking",
    "imported": false,
    "provider": "Kuadrant",
    "sub_category": "API Exposure"
  }
}
```

- [ ] **Step 2: Escribir `specs/links/connect.json.tpl`**

```json
{
  "name": "Connect",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [],
      "properties": {
        "api_key": {
          "type": "string",
          "title": "API key",
          "readOnly": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "export": {
            "type": "environment_variable",
            "target": "API_MANAGER_API_KEY",
            "secret": true
          }
        }
      },
      "additionalProperties": false
    },
    "values": {}
  }
}
```

`readOnly` + `editableOn: []` porque el valor lo genera la acción, no el usuario. `secret: true` hace que la plataforma cree un **secret parameter** en la app consumidora en vez de una env var en texto plano.

- [ ] **Step 3: Verificar que los dos son JSON válido tras renderizar**

```bash
cd api-manager
NRN="organization=1636958496:account=1374028000" \
  gomplate -f specs/service-spec.json.tpl | jq -e '.name == "Api Manager"' \
  && echo "service-spec OK"
gomplate -f specs/links/connect.json.tpl | jq -e '.attributes.schema.properties.api_key.export.target == "API_MANAGER_API_KEY"' \
  && echo "connect OK"
```

Esperado: `true` + el mensaje, para los dos.

- [ ] **Step 4: Verificar que el markdown del Label sobrevive el render**

```bash
NRN="x" gomplate -f specs/service-spec.json.tpl \
  | jq -r '.attributes.schema.uiSchema.elements[0] | select(.type=="Label") | .text' | head -5
```

Esperado: el markdown con `## Api Manager` y `### FAQ`. Si sale vacío, el `\n` quedó mal escapado.

- [ ] **Step 5: Commit**

```bash
git add api-manager/specs/
git commit -m "feat(api-manager): service spec con FAQ y link spec que exporta la api key"
```

---

### Task 3: `build_context` — notificación y resolución de scopes

Entregable testeable: dado un `NP_ACTION_CONTEXT`, produce el JSON de contexto con los backends resueltos, o falla ruidosamente.

**Files:**
- Create: `api-manager/scripts/k8s/build_context`
- Test: `api-manager/tests/build_context.bats`

**Interfaces:**
- Consume: `log` (Task 1); los atributos `hosts` y `routes` (Task 2).
- Produce, como variables de entorno para los steps siguientes: `NAMESPACE`, `APP_TARGET` (`<ns>.<app-slug>`), `SERVICE_ID`, `HOSTS_JSON` (array), `ROUTES_JSON` (array de `{path, methods, scope, backend}`), `GATEWAY_NAME`, `GATEWAY_NAMESPACE`, `KEYS_NAMESPACE`, `API_KEY_HEADER`.

- [ ] **Step 1: Escribir el test que falla — resolución del dominio del scope**

`tests/build_context.bats`. Copiar el `setup()` y el mock de `np` de `egress-interceptor/tests/build_context.bats` (incluido el guard de bash >= 4 y el log de invocaciones), y agregar:

```bash
@test "resuelve el backend de cada ruta desde el dominio del scope" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'gal-poc-reports-prod-xiist.galicia-poc.nullapps.io'
}

@test "falla si el scope no esta entre los activos de la aplicacion" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"inexistente"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "inexistente"
}

@test "falla si el scope existe pero no esta desplegado" {
  export NP_MOCK_SCOPES='[{"slug":"prod","domain":"To be defined"}]'
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "todavía no está desplegado"
}

@test "falla si np devuelve 403 en vez de seguir con cero scopes" {
  export NP_MOCK_MODE=forbidden
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
}

@test "falla si un host no tiene forma de FQDN" {
  ATTRS='{"hosts":["no un host"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
}

@test "arma APP_TARGET como namespace.application" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'APP_TARGET=payments.reports'
}
```

Agregar el helper `notif()` que arma la notificación con `.service.attributes` = `$ATTRS`, y `ctx()` que arma el `$CONTEXT` con el namespace del provider y el `application.id`, ambos calcados de los del `egress-interceptor`.

- [ ] **Step 2: Correr los tests y verificar que fallan**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/build_context.bats
```

Esperado: FAIL en los 6 — el archivo `build_context` no existe todavía.

- [ ] **Step 3: Escribir `build_context`**

Sin comentarios. Estructura:

```bash
#!/usr/bin/env bash
set -euo pipefail

NOTIFICATION=$(printf %s "$NP_ACTION_CONTEXT" | jq -c '.notification')
SERVICE_ATTRS=$(printf %s "$NOTIFICATION" | jq -c '(.service.attributes // {}) * (.parameters // {})')
HOSTS_JSON=$(printf %s "$SERVICE_ATTRS" | jq -c '.hosts // []')
ROUTES_JSON=$(printf %s "$SERVICE_ATTRS" | jq -c '.routes // []')
SERVICE_ID=$(printf %s "$NOTIFICATION" | jq -r '.service.id // empty')

NAMESPACE="${NAMESPACE_OVERRIDE:-}"
if [ -z "$NAMESPACE" ]; then
  NAMESPACE=$(echo "$CONTEXT" | jq -r '.providers["container-orchestration"].cluster.namespace // empty' 2>/dev/null || true)
fi
NAMESPACE="${NAMESPACE:-nullplatform}"

APPLICATION_ID=$(echo "$CONTEXT" | jq -r '.application.id // empty')
APPLICATION_SLUG=$(echo "$CONTEXT" | jq -r '.application.slug // empty')

GATEWAY_NAME="${GATEWAY_NAME:-s2s-ingress}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-gateways}"
KEYS_NAMESPACE="${KEYS_NAMESPACE:-kuadrant-system}"
API_KEY_HEADER="${API_KEY_HEADER:-x-api-key}"

require_match() {
  local val="$1" re="$2" name="$3"
  if [[ ! "$val" =~ $re ]]; then
    log error "api-manager build_context: valor inválido para ${name}: '${val}'"
    exit 1
  fi
}

require_match "$NAMESPACE" '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' "namespace"
require_match "$APPLICATION_SLUG" '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' "application.slug"
[ -n "$SERVICE_ID" ] && require_match "$SERVICE_ID" '^[a-zA-Z0-9_-]{1,64}$' "service.id"

APP_TARGET="${NAMESPACE}.${APPLICATION_SLUG}"
if [ "${#APP_TARGET}" -gt 63 ]; then
  log error "api-manager: '$APP_TARGET' excede los 63 caracteres que admite un valor de label."
  exit 1
fi
```

Luego las validaciones de hosts y rutas, y la resolución de scopes:

```bash
if [ "$(printf %s "$HOSTS_JSON" | jq 'length')" -eq 0 ]; then
  log error "api-manager: no hay dominios declarados. Declarar al menos uno."
  exit 1
fi

while IFS= read -r HOST; do
  require_match "$HOST" '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' "dominio"
done < <(printf %s "$HOSTS_JSON" | jq -r '.[]')

if [ "$(printf %s "$ROUTES_JSON" | jq 'length')" -eq 0 ]; then
  log error "api-manager: no hay rutas declaradas. Sin rutas la aplicación no queda expuesta."
  exit 1
fi

if [ "$(printf %s "$ROUTES_JSON" | jq '[.[] | select((.scope // "") == "")] | length')" -gt 0 ]; then
  log error "api-manager: hay rutas sin scope. Cada ruta declara qué despliegue la atiende."
  exit 1
fi

[ -n "$APPLICATION_ID" ] || { log error "api-manager: el CONTEXT no trae application.id."; exit 1; }

ACTIVE_SCOPES=$(np scope list --application-id "$APPLICATION_ID" --status active --format json \
  --query '[ (.results? // .) | .[]? | {slug, domain} ]') \
  || { log error "api-manager: falló el listado de scopes de la aplicación $APPLICATION_ID."; exit 1; }

ROUTES_JSON=$(printf %s "$ROUTES_JSON" | jq -c --argjson scopes "$ACTIVE_SCOPES" '
  map(. as $r | . + {
    backend: ([$scopes[] | select(.slug == $r.scope) | .domain] | first // "")
  })')

while IFS=$'\t' read -r ROUTE_SCOPE ROUTE_BACKEND; do
  if [ -z "$ROUTE_BACKEND" ]; then
    log error "api-manager: el scope '$ROUTE_SCOPE' no está entre los scopes activos de la aplicación $APPLICATION_ID."
    exit 1
  fi
  if [ "$ROUTE_BACKEND" = "To be defined" ]; then
    log error "api-manager: el scope '$ROUTE_SCOPE' existe pero todavía no está desplegado (domain: 'To be defined')."
    exit 1
  fi
  require_match "$ROUTE_BACKEND" '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' "el backend del scope '$ROUTE_SCOPE'"
done < <(printf %s "$ROUTES_JSON" | jq -r '.[] | [.scope, .backend] | @tsv')
```

Y al final, la exportación:

```bash
export NAMESPACE APP_TARGET SERVICE_ID HOSTS_JSON ROUTES_JSON
export GATEWAY_NAME GATEWAY_NAMESPACE KEYS_NAMESPACE API_KEY_HEADER

log info "api-manager: exponiendo $APP_TARGET"
printf %s "$HOSTS_JSON" | jq -r '.[] | "  dominio: \(.)"' | while IFS= read -r L; do log info "$L"; done
printf %s "$ROUTES_JSON" | jq -r '.[] | "  ruta: \(.methods | join(",")) \(.path) → scope \(.scope) = \(.backend)"' \
  | while IFS= read -r L; do log info "$L"; done
echo "APP_TARGET=$APP_TARGET"
```

El `require_match` del backend **no** valida contra `To be defined` por sí solo: el espacio lo haría fallar con un mensaje genérico. El chequeo explícito va antes para dar el mensaje útil.

- [ ] **Step 4: Correr los tests y verificar que pasan**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/build_context.bats
```

Esperado: 6 passing.

- [ ] **Step 5: Verificar que no hay comentarios**

```bash
grep -n '^\s*#' scripts/k8s/build_context | grep -v ':1:#!'
```

Esperado: sin salida.

- [ ] **Step 6: Commit**

```bash
git add api-manager/scripts/k8s/build_context api-manager/tests/build_context.bats
git commit -m "feat(api-manager): build_context con resolucion de scopes y guardas"
```

---

### Task 4: Manifiestos y librería de render

Entregable testeable: dado un contexto, se renderizan un `HTTPRoute` y una `AuthPolicy` válidos.

**Files:**
- Create: `api-manager/manifests/expose/10-httproute.yaml.tpl`
- Create: `api-manager/manifests/expose/20-authpolicy.yaml.tpl`
- Create: `api-manager/scripts/k8s/manifests_lib`
- Test: `api-manager/tests/render.bats`

**Interfaces:**
- Consume: `HOSTS_JSON`, `ROUTES_JSON`, `NAMESPACE`, `APP_TARGET`, `GATEWAY_NAME`, `GATEWAY_NAMESPACE`, `API_KEY_HEADER` (Task 3).
- Produce: `render_manifests <contexto.json> <outdir>` → escribe en stdout las rutas de los manifiestos con contenido, en orden de aplicación; devuelve 1 si falla. `apply_manifests <archivo>...` → aplica uno por uno; devuelve 1 al primer fallo. Las consume `reconcile` (Task 5).

- [ ] **Step 1: Escribir `manifests_lib`**

Copiar `egress-interceptor/scripts/k8s/manifests_lib` **quitando todos los comentarios** y cambiando dos cosas: el default de `MANIFESTS_DIR` apunta a `../../manifests/expose`, y los mensajes de error dicen `api-manager` en vez de `egress-interceptor`.

Conservar sin tocar, porque cada uno tapa un fallo real:
- `[ -e "$tpl" ] || break` — un glob sin matches se expande a sí mismo.
- El guard de `${#outs[@]}` -eq 0 — **gomplate sin ningún `-f` lee stdin y cuelga para siempre**.
- Una sola invocación de gomplate con todos los pares `-f/-o`.
- `</dev/null` en la invocación.
- El chequeo explícito del exit status (no delegar a `set -e`: esto se sourcea desde los tests).
- El descarte de outputs vacíos o inexistentes (gomplate no crea el archivo cuando el render es vacío).
- El `return 0` final explícito.
- Los guards `if ! type -t <fn> >/dev/null 2>&1` para que los tests puedan mockear.

- [ ] **Step 2: Escribir `10-httproute.yaml.tpl`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .route_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    nullplatform: "true"
spec:
  parentRefs:
    - name: {{ .gateway_name | quote }}
      namespace: {{ .gateway_namespace | quote }}
  hostnames:
{{- range .hosts }}
    - {{ . | quote }}
{{- end }}
  rules:
{{- range .routes }}
{{- $path := .path }}
    - matches:
{{- range .methods }}
        - path:
            type: {{ if hasSuffix "*" $path }}PathPrefix{{ else }}Exact{{ end }}
            value: {{ trimSuffix "*" $path | quote }}
          method: {{ . | quote }}
{{- end }}
      backendRefs:
        - group: networking.istio.io
          kind: Hostname
          name: {{ .backend | quote }}
          port: 80
{{- end }}
```

Dos cosas que no son obvias y que los tests del Step 4 fijan:

- **Un `match` por método.** Gateway API no admite una lista de métodos dentro de un solo match, así que el `range` interno multiplica los matches de cada ruta.
- **`$path` se captura antes del `range` interno.** Adentro de ese loop, `.` es el método, no la ruta: leer `.path` ahí devuelve vacío y el manifiesto sale con paths en blanco, que Istio acepta como `/`. O sea, **cada ruta expondría toda la aplicación**. Falla en silencio: el YAML es válido y el apply funciona.

- [ ] **Step 3: Escribir `20-authpolicy.yaml.tpl`**

```yaml
apiVersion: {{ .authpolicy_api_version | quote }}
kind: AuthPolicy
metadata:
  name: {{ .route_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    nullplatform: "true"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: {{ .route_name | quote }}
  rules:
    authentication:
      "consumer-key":
        apiKey:
          selector:
            matchLabels:
              {{ .managed_label }}: "true"
        credentials:
          customHeader:
            name: {{ .api_key_header | quote }}
    authorization:
      "allowed-target":
        patternMatching:
          patterns:
            - selector: {{ printf "auth.identity.metadata.labels.%s" .target_label }}
              operator: eq
              value: {{ .app_target | quote }}
    response:
      success: {}
```

`eq` y no `matches`: `matches` es regexp de Go sin anclar y `payments.reports` autorizaría a `payments.reports-evil`.

El selector del `apiKey` matchea **todas** las keys del servicio, no sólo las de esta app: si filtrara por app, una key ajena daría 401 en vez del 403 que queremos.

- [ ] **Step 4: Escribir el test de render que falla**

`tests/render.bats`, con el guard de bash >= 4 en `setup()`. Definir primero el helper que arma el
contexto y renderiza, mergeando lo que cada test pase sobre una base válida:

```bash
setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  LIB="${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib"
  OUT="$BATS_TEST_TMPDIR/out"
  CTX="$BATS_TEST_TMPDIR/ctx.json"
  source "${BATS_TEST_DIRNAME}/../logging"
  export -f log
  BASE='{
    "namespace":"payments","route_name":"api-manager-1","app_target":"payments.reports",
    "gateway_name":"s2s-ingress","gateway_namespace":"gateways","api_key_header":"x-api-key",
    "managed_label":"api-manager.nullplatform.io/managed",
    "target_label":"apimgr-target",
    "authpolicy_api_version":"kuadrant.io/v1",
    "hosts":["api.expuesta.com"],
    "routes":[{"path":"/r1","methods":["GET"],"scope":"prod","backend":"appy.internas.com"}]
  }'
}

render_ctx() {
  printf %s "$BASE" | jq -c ". + $1" >"$CTX"
  source "$LIB"
  render_manifests "$CTX" "$OUT" >/dev/null
}
```

Los tests:

```bash
@test "el httproute lleva un match por metodo y el backend de la ruta" {
  run render_ctx '{"routes":[{"path":"/r1","methods":["GET","POST"],"scope":"prod","backend":"appy.internas.com"}]}'
  [ "$status" -eq 0 ]
  [ "$(yq '.spec.rules[0].matches | length' "$OUT/10-httproute.yaml")" = "2" ]
  [ "$(yq -r '.spec.rules[0].backendRefs[0].kind' "$OUT/10-httproute.yaml")" = "Hostname" ]
  [ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$OUT/10-httproute.yaml")" = "appy.internas.com" ]
}

@test "cada match conserva el path de su ruta y no queda vacio" {
  run render_ctx '{"routes":[{"path":"/pagos","methods":["GET","POST"],"scope":"prod","backend":"appy.internas.com"}]}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules[0].matches[0].path.value' "$OUT/10-httproute.yaml")" = "/pagos" ]
  [ "$(yq -r '.spec.rules[0].matches[1].path.value' "$OUT/10-httproute.yaml")" = "/pagos" ]
}

@test "un path con asterisco se traduce a PathPrefix sin el asterisco" {
  run render_ctx '{"routes":[{"path":"/files/*","methods":["GET"],"scope":"prod","backend":"appy.internas.com"}]}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules[0].matches[0].path.type' "$OUT/10-httproute.yaml")" = "PathPrefix" ]
  [ "$(yq -r '.spec.rules[0].matches[0].path.value' "$OUT/10-httproute.yaml")" = "/files/" ]
}

@test "cada ruta apunta al backend de SU scope y no al de la primera" {
  run render_ctx '{"routes":[
    {"path":"/a","methods":["GET"],"scope":"prod","backend":"prod.internas.com"},
    {"path":"/b","methods":["GET"],"scope":"dev","backend":"dev.internas.com"}]}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$OUT/10-httproute.yaml")" = "prod.internas.com" ]
  [ "$(yq -r '.spec.rules[1].backendRefs[0].name' "$OUT/10-httproute.yaml")" = "dev.internas.com" ]
}

@test "el httproute declara todos los hosts" {
  run render_ctx '{"hosts":["a.example.com","b.example.com"]}'
  [ "$status" -eq 0 ]
  [ "$(yq '.spec.hostnames | length' "$OUT/10-httproute.yaml")" = "2" ]
}

@test "la authpolicy autoriza por igualdad exacta y no por regexp" {
  run render_ctx '{}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules.authorization["allowed-target"].patternMatching.patterns[0].operator' "$OUT/20-authpolicy.yaml")" = "eq" ]
}

@test "la authpolicy autoriza contra el app_target del contexto" {
  run render_ctx '{"app_target":"payments.reports"}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules.authorization["allowed-target"].patternMatching.patterns[0].value' "$OUT/20-authpolicy.yaml")" = "payments.reports" ]
}

@test "el selector de apiKey NO filtra por app, para que una key ajena de 403 y no 401" {
  run render_ctx '{"app_target":"payments.reports"}'
  [ "$status" -eq 0 ]
  run yq -r '.spec.rules.authentication["consumer-key"].apiKey.selector.matchLabels | keys | .[]' "$OUT/20-authpolicy.yaml"
  ! echo "$output" | grep -q 'target'
}

@test "render_manifests falla si el directorio de manifiestos esta vacio" {
  MANIFESTS_DIR="$BATS_TEST_TMPDIR/vacio"
  mkdir -p "$MANIFESTS_DIR"
  run timeout 10 bash -c 'source "$LIB"; render_manifests "$CTX" "$OUT"'
  [ "$status" -eq 1 ]
}
```

El último test lleva `timeout 10` a propósito: sin el guard, gomplate se queda leyendo stdin y el test **cuelga** en vez de fallar.

- [ ] **Step 5: Correr y verificar que fallan**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/render.bats
```

Esperado: FAIL en los 9.

- [ ] **Step 6: Ajustar templates hasta que pasen**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/render.bats
```

Esperado: 9 passing.

- [ ] **Step 7: Commit**

```bash
git add api-manager/manifests/ api-manager/scripts/k8s/manifests_lib api-manager/tests/render.bats
git commit -m "feat(api-manager): manifiestos de httproute y authpolicy con render por template"
```

---

### Task 5: `reconcile` — apply y delete

Entregable testeable: aplica los manifiestos y espera a que la ruta quede `Accepted`; borra todo en el delete; **aborta ante cualquier fallo**.

**Files:**
- Create: `api-manager/scripts/k8s/reconcile`
- Create: `api-manager/scripts/k8s/write_service_outputs`
- Create: `api-manager/workflows/istio/update.yaml`, `api-manager/workflows/istio/delete.yaml`
- Modify: `api-manager/workflows/istio/create.yaml`
- Test: `api-manager/tests/fail_fast.bats`

**Interfaces:**
- Consume: `render_manifests`, `apply_manifests` (Task 4); todas las variables de Task 3.
- Produce: `die <mensaje>` (log error + exit 1) y `wait_route_condition <ns> <route> <cond> <timeout>` (devuelve 0 cuando algún parent reporta la condición en `True` y ninguno la reporta distinto de `True`).

- [ ] **Step 1: Escribir los tests de fail-fast que fallan**

`tests/fail_fast.bats`. La premisa: **`set -e` está neutralizado** por el runner, así que cada fallo tiene que abortar por su `|| die`.

```bash
@test "aborta si falla el apply de un manifiesto" {
  export KUBECTL_MOCK_FAIL=apply
  run bash "$RECONCILE" apply
  [ "$status" -ne 0 ]
}

@test "aborta si la route nunca queda Accepted" {
  export KUBECTL_MOCK_ROUTE_COND=False
  export WAIT_TIMEOUT=1
  run bash "$RECONCILE" apply
  [ "$status" -ne 0 ]
}

@test "no borra nada si falla el listado de rutas propias" {
  export KUBECTL_MOCK_FAIL=get-httproutes
  run bash "$RECONCILE" delete
  [ "$status" -ne 0 ]
  ! grep -q 'delete' "$KUBECTL_CALLS_LOG"
}

@test "el delete borra tambien las keys de la app" {
  run bash "$RECONCILE" delete
  [ "$status" -eq 0 ]
  grep -q "delete secret" "$KUBECTL_CALLS_LOG"
}

@test "wait_route_condition acepta con un parent True y ninguno distinto" {
  source "$RECONCILE_LIB"
  export KUBECTL_MOCK_PARENTS='[{"conditions":[{"type":"Accepted","status":"True"}]}]'
  run wait_route_condition ns route Accepted 2
  [ "$status" -eq 0 ]
}

@test "wait_route_condition rechaza si algun parent reporta distinto de True" {
  source "$RECONCILE_LIB"
  export KUBECTL_MOCK_PARENTS='[{"conditions":[{"type":"Accepted","status":"True"}]},{"conditions":[{"type":"Accepted","status":"False"}]}]'
  run wait_route_condition ns route Accepted 1
  [ "$status" -ne 0 ]
}

@test "NO espera ResolvedRefs, que es falso negativo con kind Hostname" {
  run bash "$RECONCILE" apply
  ! grep -q 'ResolvedRefs' "$KUBECTL_CALLS_LOG"
}
```

El mock de `kubectl` loguea cada invocación en `$KUBECTL_CALLS_LOG` y respeta `KUBECTL_MOCK_FAIL` para fallar en un subcomando puntual.

- [ ] **Step 2: Correr y verificar que fallan**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/fail_fast.bats
```

Esperado: FAIL en los 7.

- [ ] **Step 3: Escribir `reconcile`**

```bash
#!/usr/bin/env bash
set -euo pipefail

RECONCILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RECONCILE_DIR/manifests_lib"

die() {
  log error "$1"
  exit 1
}

wait_route_condition() {
  local ns="$1" route="$2" cond="$3" timeout="${4:-60}"
  local deadline=$(( SECONDS + timeout )) buenas malas
  while [ "$SECONDS" -lt "$deadline" ]; do
    read -r buenas malas < <(kubectl -n "$ns" get "httproute/$route" -o json 2>/dev/null \
      | jq -r --arg c "$cond" '[.status.parents[]?.conditions[]? | select(.type == $c)] as $cs
          | "\([$cs[] | select(.status == "True")] | length) \([$cs[] | select(.status != "True")] | length)"' \
      2>/dev/null || echo "0 0")
    if [ "${buenas:-0}" -gt 0 ] && [ "${malas:-1}" -eq 0 ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}
```

La condición es "alguno en True y ninguno distinto de True", **no** "todos en True": Gateway API escribe una entrada en `.status.parents[]` por controller, y Kuadrant agrega la suya segundos después. Exigir que todos estén presentes vuelve la espera dependiente del timing.

El cuerpo, con `|| die` en cada comando relevante:

```bash
ACTION="${1:-${ARGS:-apply}}"
ROUTE_NAME="api-manager-${SERVICE_ID}"
OUTDIR=$(mktemp -d) || die "api-manager: no se pudo crear el directorio temporal."
trap 'rm -rf "$OUTDIR"' EXIT

case "$ACTION" in
  apply)
    CTX="$OUTDIR/context.json"
    jq -n \
      --arg namespace "$NAMESPACE" \
      --arg route_name "$ROUTE_NAME" \
      --arg app_target "$APP_TARGET" \
      --arg gateway_name "$GATEWAY_NAME" \
      --arg gateway_namespace "$GATEWAY_NAMESPACE" \
      --arg api_key_header "$API_KEY_HEADER" \
      --arg managed_label "api-manager.nullplatform.io/managed" \
      --arg target_label "apimgr-target" \
      --arg authpolicy_api_version "${AUTHPOLICY_API_VERSION:-kuadrant.io/v1}" \
      --argjson hosts "$HOSTS_JSON" \
      --argjson routes "$ROUTES_JSON" \
      '$ARGS.named' >"$CTX" || die "api-manager: no se pudo armar el contexto de render."

    mapfile -t MANIFESTS < <(render_manifests "$CTX" "$OUTDIR") \
      || die "api-manager: falló el render de los manifiestos."
    [ "${#MANIFESTS[@]}" -gt 0 ] || die "api-manager: el render no produjo ningún manifiesto."

    apply_manifests "${MANIFESTS[@]}" || die "api-manager: falló el apply de los manifiestos."

    wait_route_condition "$NAMESPACE" "$ROUTE_NAME" Accepted "${WAIT_TIMEOUT:-60}" \
      || die "api-manager: la HTTPRoute '$ROUTE_NAME' no quedó Accepted. Revisar que el Gateway '$GATEWAY_NAME' exista en '$GATEWAY_NAMESPACE' y admita routes de este namespace."

    log info "api-manager: $APP_TARGET expuesto."
    ;;
  delete)
    kubectl -n "$NAMESPACE" delete authpolicy "$ROUTE_NAME" --ignore-not-found \
      || die "api-manager: falló el borrado de la AuthPolicy '$ROUTE_NAME'."
    kubectl -n "$NAMESPACE" delete httproute "$ROUTE_NAME" --ignore-not-found \
      || die "api-manager: falló el borrado de la HTTPRoute '$ROUTE_NAME'."
    kubectl -n "$KEYS_NAMESPACE" delete secret \
      -l "apimgr-target=$APP_TARGET" --ignore-not-found \
      || die "api-manager: falló el borrado de las api keys de '$APP_TARGET'. Quedan credenciales vivas para una app que ya no está expuesta."
    log info "api-manager: $APP_TARGET dado de baja."
    ;;
  *)
    die "api-manager: acción desconocida '$ACTION'."
    ;;
esac
```

El borrado de las keys en el `delete` no es opcional: sin él quedan Secrets huérfanos, y si la app se recrea con el mismo slug los consumidores viejos recuperan acceso sin re-linkearse.

- [ ] **Step 4: Escribir `write_service_outputs`**

Guarda en los results de la acción los hosts y las rutas efectivas, para que se vean en la UI:

```bash
#!/usr/bin/env bash
set -euo pipefail

RESULTS=$(printf %s "$NP_ACTION_CONTEXT" | jq -c \
  --argjson hosts "$HOSTS_JSON" \
  --argjson routes "$ROUTES_JSON" \
  '(.notification.parameters // .parameters // {}) + {hosts: $hosts, routes: $routes}') \
  || { log error "api-manager: no se pudieron armar los resultados de la acción."; exit 1; }

np service action update --results "$RESULTS" \
  || { log error "api-manager: falló la escritura de los resultados de la acción."; exit 1; }
```

- [ ] **Step 5: Completar los tres workflows**

`create.yaml` y `update.yaml` son idénticos: `load logging` → `build context` → `check collisions` (se agrega en Task 6) → `reconcile apply` → `write outputs`. `delete.yaml`: `load logging` → `build context` → `reconcile delete`.

El bloque `output:` de `build context` declara cada variable que exporta: `NAMESPACE`, `APP_TARGET`, `SERVICE_ID`, `HOSTS_JSON`, `ROUTES_JSON`, `GATEWAY_NAME`, `GATEWAY_NAMESPACE`, `KEYS_NAMESPACE`, `API_KEY_HEADER`. Una variable que no esté declarada acá **no llega** al step siguiente.

- [ ] **Step 6: Correr los tests y verificar que pasan**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/
```

Esperado: todo passing (build_context + render + fail_fast).

- [ ] **Step 7: Commit**

```bash
git add api-manager/scripts/k8s/reconcile api-manager/scripts/k8s/write_service_outputs api-manager/workflows/ api-manager/tests/fail_fast.bats
git commit -m "feat(api-manager): reconcile apply y delete con abort ante cualquier fallo"
```

---

### Task 6: `check_collisions` — rechazar `(host, path)` ya tomado

Entregable testeable: el `create` falla si otra aplicación ya declaró el mismo par host+path; **no** falla si comparten host con paths distintos.

**Files:**
- Create: `api-manager/scripts/k8s/check_collisions`
- Modify: `api-manager/workflows/istio/create.yaml`, `api-manager/workflows/istio/update.yaml`
- Test: `api-manager/tests/collisions.bats`

**Interfaces:**
- Consume: `HOSTS_JSON`, `ROUTES_JSON`, `NAMESPACE`, `APP_TARGET` (Task 3); `log` (Task 1).
- Produce: exit 0 si no hay colisión; exit 1 con el detalle si la hay.

- [ ] **Step 1: Escribir los tests que fallan**

```bash
@test "permite el mismo host con paths distintos" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"otra","namespace":"reports","labels":{"apimgr-target":"reports.otra"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/reportes"}}]}]}}]'
  export HOSTS_JSON='["api.expuesta.com"]'
  export ROUTES_JSON='[{"path":"/pagos","methods":["GET"],"scope":"prod","backend":"b.com"}]'
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "rechaza el mismo host con el mismo path de otra app" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"otra","namespace":"reports","labels":{"apimgr-target":"reports.otra"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/pagos"}}]}]}}]'
  export HOSTS_JSON='["api.expuesta.com"]'
  export ROUTES_JSON='[{"path":"/pagos","methods":["GET"],"scope":"prod","backend":"b.com"}]'
  run bash "$CHECK"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "reports.otra"
}

@test "no colisiona consigo misma en un update" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"propia","namespace":"payments","labels":{"apimgr-target":"payments.reports"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/pagos"}}]}]}}]'
  export APP_TARGET=payments.reports
  export HOSTS_JSON='["api.expuesta.com"]'
  export ROUTES_JSON='[{"path":"/pagos","methods":["GET"],"scope":"prod","backend":"b.com"}]'
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "aborta si falla el listado de rutas en vez de dar via libre" {
  export KUBECTL_MOCK_FAIL=get
  run bash "$CHECK"
  [ "$status" -ne 0 ]
}
```

El último es el que importa de verdad: si el listado falla y el script devuelve 0, **toda colisión pasa desapercibida** justo cuando menos información tenemos.

- [ ] **Step 2: Correr y verificar que fallan**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/collisions.bats
```

Esperado: FAIL en los 4.

- [ ] **Step 3: Escribir `check_collisions`**

```bash
#!/usr/bin/env bash
set -euo pipefail

EXISTING=$(kubectl get httproutes -A -l "api-manager.nullplatform.io/managed=true" -o json) \
  || { log error "api-manager: no se pudo listar las rutas existentes. No se aplica nada: sin ese listado no hay cómo detectar una colisión de dominios."; exit 1; }

CLAIMED=$(printf %s "$EXISTING" | jq -c --arg self "$APP_TARGET" '
  [ .items[]
    | .metadata.labels["apimgr-target"] as $owner
    | select($owner != $self)
    | . as $r
    | $r.spec.hostnames[] as $h
    | $r.spec.rules[]?.matches[]?.path.value as $p
    | {host: $h, path: $p, owner: $owner} ]')

WANTED=$(jq -nc --argjson hosts "$HOSTS_JSON" --argjson routes "$ROUTES_JSON" '
  [ $hosts[] as $h | $routes[] | {host: $h, path: .path} ]')

CONFLICTS=$(jq -nr --argjson claimed "$CLAIMED" --argjson wanted "$WANTED" '
  [ $wanted[] as $w | $claimed[] | select(.host == $w.host and .path == $w.path) ]
  | .[] | "  \(.host)\(.path) ya está tomado por \(.owner)"')

if [ -n "$CONFLICTS" ]; then
  log error "api-manager: hay dominios y paths ya declarados por otra aplicación."
  log error "$CONFLICTS"
  log error "  Compartir un dominio está permitido: lo que no se puede es repetir el mismo path."
  exit 1
fi
```

La unidad de colisión es el par `(host, path)`, **no** el host: dos apps pueden compartir `api.expuesta.com` mientras sus paths no se pisen.

- [ ] **Step 4: Correr y verificar que pasan**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/collisions.bats
```

Esperado: 4 passing.

- [ ] **Step 5: Sumar el step a los workflows**

En `create.yaml` y `update.yaml`, entre `build context` y `reconcile apply`:

```yaml
  - name: check collisions
    type: script
    file: $SERVICE_PATH/scripts/k8s/check_collisions
```

- [ ] **Step 6: Commit**

```bash
git add api-manager/scripts/k8s/check_collisions api-manager/tests/collisions.bats api-manager/workflows/
git commit -m "feat(api-manager): rechazar dominios y paths ya declarados por otra aplicacion"
```

---

### Task 7: Link — generar y revocar la API key

Entregable testeable: el link crea un Secret con los labels correctos y devuelve la key en los results; el unlink lo borra.

**Files:**
- Create: `api-manager/entrypoint/link`
- Create: `api-manager/scripts/k8s/mint_key`
- Create: `api-manager/scripts/k8s/revoke_key`
- Create: `api-manager/workflows/istio/link.yaml`, `api-manager/workflows/istio/unlink.yaml`
- Test: `api-manager/tests/keys.bats`

**Interfaces:**
- Consume: `APP_TARGET`, `KEYS_NAMESPACE` (Task 3); el atributo `api_key` del link spec (Task 2).
- Produce: un `Secret` en `$KEYS_NAMESPACE` llamado `api-manager-<link_id>`, con `stringData.api_key`, y los labels `authorino.kuadrant.io/managed-by=authorino`, `api-manager.nullplatform.io/managed=true`, `apimgr-target=<APP_TARGET>`.

- [ ] **Step 1: Escribir `entrypoint/link`**

Igual que `entrypoint/service`, pero mapeando `create`→`link` y `delete`→`unlink`, con el mismo regex anti-inyección:

```bash
#!/bin/bash
set -euo pipefail
echo "Executing link action=$SERVICE_ACTION type=$SERVICE_ACTION_TYPE"

ACTION_TO_EXECUTE="$SERVICE_ACTION_TYPE"
case "$SERVICE_ACTION_TYPE" in
  "custom") ACTION_TO_EXECUTE="$SERVICE_ACTION" ;;
  "create") ACTION_TO_EXECUTE="link" ;;
  "delete") ACTION_TO_EXECUTE="unlink" ;;
esac

if [[ ! "$ACTION_TO_EXECUTE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "acción inválida: '$ACTION_TO_EXECUTE'" >&2
  exit 1
fi

WORKFLOW_PATH="$SERVICE_PATH/workflows/istio/$ACTION_TO_EXECUTE.yaml"

np service workflow exec --workflow "$WORKFLOW_PATH" --build-context --include-secrets
```

`entrypoint/entrypoint` tiene que delegar en `link` cuando la notificación es de un link. Ajustar la última línea para elegir el handler según `$NOTIFICATION_ACTION`.

- [ ] **Step 2: Escribir los tests que fallan**

```bash
@test "mint_key crea el secret con los tres labels" {
  run bash "$MINT"
  [ "$status" -eq 0 ]
  grep -q "authorino.kuadrant.io/managed-by=authorino" "$KUBECTL_CALLS_LOG"
  grep -q "api-manager.nullplatform.io/managed=true" "$KUBECTL_CALLS_LOG"
  grep -q "apimgr-target=payments.reports" "$KUBECTL_CALLS_LOG"
}

@test "mint_key genera una key distinta en cada corrida" {
  run bash "$MINT"; local a="$output"
  run bash "$MINT"; local b="$output"
  [ "$a" != "$b" ]
}

@test "mint_key no escribe la key en el log" {
  run bash "$MINT"
  ! grep -qi "api_key=" "$LOG_FILE"
}

@test "mint_key aborta si falla la creacion del secret" {
  export KUBECTL_MOCK_FAIL=create
  run bash "$MINT"
  [ "$status" -ne 0 ]
}

@test "revoke_key borra el secret del link" {
  run bash "$REVOKE"
  [ "$status" -eq 0 ]
  grep -q "delete secret api-manager-777" "$KUBECTL_CALLS_LOG"
}

@test "revoke_key aborta si falla el borrado en vez de reportar exito" {
  export KUBECTL_MOCK_FAIL=delete
  run bash "$REVOKE"
  [ "$status" -ne 0 ]
}
```

El tercero cubre un modo de falla silencioso y caro: una credencial en los logs del agente.

- [ ] **Step 3: Correr y verificar que fallan**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/keys.bats
```

Esperado: FAIL en los 6.

- [ ] **Step 4: Escribir `mint_key`**

```bash
#!/usr/bin/env bash
set -euo pipefail

LINK_ID=$(printf %s "$NP_ACTION_CONTEXT" | jq -r '.notification.link.id // empty')
[ -n "$LINK_ID" ] || { log error "api-manager: la notificación no trae link.id."; exit 1; }
[[ "$LINK_ID" =~ ^[a-zA-Z0-9-]{1,48}$ ]] || { log error "api-manager: link.id inválido: '$LINK_ID'"; exit 1; }

SECRET_NAME="api-manager-${LINK_ID}"
API_KEY=$(openssl rand -hex 32) || { log error "api-manager: no se pudo generar la api key."; exit 1; }

kubectl -n "$KEYS_NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=api_key="$API_KEY" --dry-run=client -o yaml \
  | kubectl apply -f - \
  || { log error "api-manager: falló la creación del Secret '$SECRET_NAME' en '$KEYS_NAMESPACE'."; exit 1; }

kubectl -n "$KEYS_NAMESPACE" label secret "$SECRET_NAME" --overwrite \
  "authorino.kuadrant.io/managed-by=authorino" \
  "api-manager.nullplatform.io/managed=true" \
  "apimgr-target=$APP_TARGET" \
  || { log error "api-manager: falló el etiquetado del Secret '$SECRET_NAME'. Sin labels, Authorino no la ve y el consumidor recibe una key que no sirve."; exit 1; }

RESULTS=$(jq -nc --arg k "$API_KEY" '{api_key: $k}') \
  || { log error "api-manager: no se pudieron armar los resultados del link."; exit 1; }

np service action update --results "$RESULTS" \
  || { log error "api-manager: falló la escritura de los resultados del link."; exit 1; }

log info "api-manager: credencial emitida para consumir $APP_TARGET."
```

**Nunca** loguear `$API_KEY`. El `log info` final nombra el target, no la credencial.

- [ ] **Step 5: Escribir `revoke_key`**

```bash
#!/usr/bin/env bash
set -euo pipefail

LINK_ID=$(printf %s "$NP_ACTION_CONTEXT" | jq -r '.notification.link.id // empty')
[ -n "$LINK_ID" ] || { log error "api-manager: la notificación no trae link.id."; exit 1; }
[[ "$LINK_ID" =~ ^[a-zA-Z0-9-]{1,48}$ ]] || { log error "api-manager: link.id inválido: '$LINK_ID'"; exit 1; }

kubectl -n "$KEYS_NAMESPACE" delete secret "api-manager-${LINK_ID}" --ignore-not-found \
  || { log error "api-manager: falló el borrado de la credencial del link $LINK_ID. La credencial sigue siendo válida."; exit 1; }

log info "api-manager: credencial del link $LINK_ID revocada."
```

- [ ] **Step 6: Escribir `link.yaml` y `unlink.yaml`**

Mismos `configuration` y `build context` que los otros workflows; el step final es `mint_key` o `revoke_key`.

- [ ] **Step 7: Correr toda la suite**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/
```

Esperado: todo passing.

- [ ] **Step 8: Commit**

```bash
git add api-manager/entrypoint/link api-manager/scripts/k8s/mint_key api-manager/scripts/k8s/revoke_key api-manager/workflows/ api-manager/tests/keys.bats
git commit -m "feat(api-manager): emision y revocacion de api keys por link"
```

---

### Task 8: RBAC

Entregable testeable: el template renderiza un `Role`/`RoleBinding` que cubre lo que el service hace, y **nada más**.

**Files:**
- Create: `api-manager/manifests/rbac.yaml.tpl`

**Interfaces:**
- Consume: `NAMESPACE`, `GATEWAY_NAMESPACE`, `KEYS_NAMESPACE`, `AGENT_SA`, `AGENT_NAMESPACE` (env vars al renderizar).

- [ ] **Step 1: Escribir el template**

Tres pares `Role`/`RoleBinding`: uno en el namespace de la app, uno en el del Gateway (sólo lectura), y uno en `kuadrant-system`.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: api-manager, namespace: {{ getenv "NAMESPACE" }} }
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["kuadrant.io"]
    resources: ["authpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: api-manager-keys, namespace: {{ getenv "KEYS_NAMESPACE" }} }
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "update", "patch", "delete"]
```

**El `Role` de `kuadrant-system` no lleva `get` ni `list`.** En ese namespace también vive la clave de firma del wristband del `egress-interceptor`: el agente tiene que poder crear y borrar las suyas, no leer las ajenas. `create` no admite `resourceNames` en RBAC, pero negar `get`/`list` sí es efectivo.

El `check_collisions` hace `kubectl get httproutes -A`, así que además hace falta un `ClusterRole` de sólo lectura sobre `httproutes`. Declararlo en el mismo archivo.

- [ ] **Step 2: Verificar que renderiza**

```bash
cd api-manager
NAMESPACE=payments GATEWAY_NAMESPACE=gateways KEYS_NAMESPACE=kuadrant-system \
AGENT_SA=np-agent AGENT_NAMESPACE=nullplatform \
  gomplate -f manifests/rbac.yaml.tpl | kubectl apply --dry-run=client -f - \
  && echo "rbac OK"
```

- [ ] **Step 3: Verificar que el Role de keys no puede leer**

```bash
gomplate -f manifests/rbac.yaml.tpl | yq 'select(.metadata.name == "api-manager-keys") | .rules[0].verbs'
```

Esperado: `create`, `update`, `patch`, `delete`. **Sin `get` ni `list`.**

- [ ] **Step 4: Commit**

```bash
git add api-manager/manifests/rbac.yaml.tpl
git commit -m "feat(api-manager): rbac sin lectura de secrets en kuadrant-system"
```

---

### Task 9: Terraform de instalación y prerequisitos

Entregable testeable: `tofu validate` pasa y un `apply` real registra el service con el slug `api-manager`.

**Files:**
- Create: `api-manager/specs/install/{main,variables,outputs,providers,versions}.tf`, `terraform.tfvars.example`
- Create: `api-manager/specs/prerequisites/{main,variables,providers,versions}.tf`, `terraform.tfvars.example`

**Interfaces:**
- Produce: el output `service_specification_slug` (= `api-manager`), que consume el channel.

- [ ] **Step 1: Copiar la estructura del egress-interceptor**

```bash
cp -r egress-interceptor/specs/install api-manager/specs/install
cp -r egress-interceptor/specs/prerequisites api-manager/specs/prerequisites
rm -rf api-manager/specs/install/.terraform* api-manager/specs/prerequisites/.terraform*
```

- [ ] **Step 2: Ajustar `install/main.tf`**

Cambiar `service_name` a `"Api Manager"` y declarar el link. **Quitar los comentarios** que arrastra la copia.

```hcl
module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v6.3.0"

  nrn          = var.nrn
  service_name = "Api Manager"
  service_path = var.service_path

  git_provider     = "local"
  local_specs_path = abspath("${path.module}/../..")

  available_actions = []
  available_links   = ["connect"]

  extra_visibile_to_nrns = var.extra_visible_to_nrns
}
```

`available_links = ["connect"]` es lo que hace que el módulo levante `specs/links/connect.json.tpl`. Sin eso el link no existe y la key nunca se emite.

- [ ] **Step 3: Verificar que no quedaron secretos ni state**

```bash
cd api-manager/specs/install
ls -la | grep -E 'tfvars$|tfstate' && echo "REVISAR" || echo "limpio"
grep -rn "nullplatform_api_key\|np_api_key" terraform.tfvars.example
```

En `terraform.tfvars.example` sólo puede haber placeholders. **Nunca** commitear `terraform.tfvars` ni `terraform.tfstate`.

- [ ] **Step 4: Validar**

```bash
cd api-manager/specs/install && tofu init -backend=false && tofu validate
cd ../prerequisites && tofu init -backend=false && tofu validate
```

Esperado: `Success!` en los dos.

- [ ] **Step 5: Commit**

```bash
cd ~/nullplatform/galicia/custom-scopes-workshop-fede-galicia-override
git add api-manager/specs/
git commit -m "feat(api-manager): terraform de instalacion y prerequisitos"
```

---

### Task 10: README y PR

**Files:**
- Create: `api-manager/README.md`
- Modify: `README.md` (raíz), si lista los services del repo

- [ ] **Step 1: Escribir el README**

Seguir la estructura de `egress-interceptor/README.md`: qué hace, qué ve el dev, cómo lo consume otra app, instalación (prerequisites → install), y procedencia. Sin detalles de implementación que el dev no necesite.

- [ ] **Step 2: Verificar que el repo quedó limpio**

```bash
cd ~/nullplatform/galicia/custom-scopes-workshop-fede-galicia-override
git status --short
grep -rn "BEGIN.*PRIVATE KEY\|api_key.*=.*['\"][A-Za-z0-9]\{20,\}" api-manager/ || echo "sin secretos"
```

- [ ] **Step 3: Correr la suite completa una última vez**

```bash
cd api-manager && PATH=/opt/homebrew/bin:$PATH bats tests/
```

- [ ] **Step 4: Push y PR**

```bash
git push -u origin feat/api-manager
gh pr create --title "feat(api-manager): service de exposicion de APIs entre namespaces" --body-file /tmp/pr-body.md
```

El cuerpo del PR es donde va **toda** la justificación que no está en el código: por qué la key es opaca y no un JWT, por qué el selector de `apiKey` no filtra por app, por qué no se espera `ResolvedRefs`, por qué el `Role` de `kuadrant-system` no tiene `get`, y por qué la unidad de colisión es `(host, path)`.

**No** poner a Claude como contributor.

- [ ] **Step 5: Actualizar el diseño**

Marcar en `plans/api-manager-diseno.md` que está implementado, con el link al PR. Commit en `galicia-banco`.

---

### Task 11: Runbook de pruebas paso a paso

Entregable: un documento que permita a otra persona probar el service de punta a punta contra el CRC,
sin conocer la implementación.

**Files:**
- Create: `accounts/galicia/demo-api-manager/RUNBOOK-PRUEBAS.md` (en el repo **galicia-banco**, no en
  el de overrides — ahí sólo va código y README)

**Interfaces:**
- Consume: todo lo construido en Tasks 1-10.

- [ ] **Step 1: Leer el runbook de referencia**

`accounts/galicia/demo-kuadrant-s2s/RUNBOOK-PRUEBAS.md` (1921 líneas) es el modelo. Copiar su
estructura y su tono, no su contenido:

- **Índice** al principio.
- **Paso 0 — ¿Se puede arrancar?**: prerrequisitos (herramientas, CRC arriba, kubectl responde) y
  verificación de que el estado de partida está limpio.
- Pasos numerados, cada uno con el comando **explícito** y su salida esperada marcada con `# →`.
- Avisos sobre los falsos negativos conocidos, en el punto donde muerden.
- Tabla de troubleshooting al final.

- [ ] **Step 2: Escribir el runbook**

Cubrir, en este orden:

1. **Paso 0** — prerrequisitos y estado de partida limpio.
2. **Levantar el agente** apuntando al CRC.
3. **Registrar el service** con el Terraform de `specs/install/`.
4. **Crear la instancia** desde la UI o el CLI: declarar `hosts` y `routes`.
5. **Verificar lo que se materializó**: `HTTPRoute` `Accepted`, `AuthPolicy` **`Enforced`**.
6. **Linkear una app consumidora** y comprobar que la env var `API_MANAGER_API_KEY` le llega.
7. **Los cuatro códigos**: 401 sin header, 401 con key inventada, **403 con key de otra app**,
   200 con la propia.
8. **Colisión de dominios**: intentar declarar un `(host, path)` ya tomado y ver el rechazo.
9. **Revocar**: borrar el link y comprobar que la misma key pasa a dar 401.
10. **Teardown**: borrar la instancia y verificar que no quedan `HTTPRoute`, `AuthPolicy` ni Secrets.

- [ ] **Step 3: Los avisos que no pueden faltar**

Estos tres son falsos negativos verificados. Sin ellos el runbook da por bueno un sistema roto:

1. **`Accepted=True` no es enforcement.** La señal válida de la `AuthPolicy` es **`Enforced=True`**
   (gotcha #22). Kuadrant no enforcea una policy que no esté en el camino de ninguna route, y no
   falla ruidosamente.
2. **`ResolvedRefs=False (BackendNotFound)` es esperado y correcto** en las `HTTPRoute` de este
   service, porque usan `backendRefs` de `kind: Hostname` (gotcha #27). No es un síntoma.
3. **Probar el 200 es obligatorio, no opcional.** Un selector de authorization mal escrito rechaza a
   TODAS las keys con 403, que es indistinguible de "la key es de otra app". Verificado el
   2026-08-31: una tanda que sólo mirase 401 y 403 habría dado en verde una `AuthPolicy` que no
   autorizaba a nadie. El 200 es lo único que distingue los dos casos.

- [ ] **Step 4: Verificar que los comandos corren**

Ejecutar el runbook completo contra el CRC, de arriba a abajo, y corregir todo comando cuya salida no
coincida con la documentada. Un runbook sin correr no es un runbook.

- [ ] **Step 5: Commit**

```bash
cd ~/nullplatform/galicia/galicia-banco
git add accounts/galicia/demo-api-manager/RUNBOOK-PRUEBAS.md
git commit -m "docs(api-manager): runbook de pruebas paso a paso"
```

---

## Notas de ejecución

**Orden.** Task 0 es compuerta: si el supuesto de los labels no se cumple, Tasks 4 y 7 cambian. Las demás van en orden; 8 y 9 se pueden hacer en paralelo con 6 y 7.

**Deuda conocida, heredada del `egress-interceptor`:** los tests mockean `kubectl`, así que no ven el comportamiento real de Istio ni la propagación de labels; y no corren bajo `set -u`. No arreglarlo en este plan, pero no reportar como "verificado end-to-end" lo que sólo pasó por los mocks.

**Verificación real.** Antes de dar el service por terminado, correr el flujo completo contra el cluster: crear la instancia, linkear una app consumidora, comprobar que la env var llega, y validar los cuatro códigos de respuesta (401 sin header, 401 con key inventada, 403 con key de otra app, 200 con la propia).
