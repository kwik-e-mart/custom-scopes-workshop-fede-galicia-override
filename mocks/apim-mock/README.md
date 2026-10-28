# apim-mock

Mock del **API Subscriber** y del **API Publisher** de APIM para probar `api-manager-ocp-subscriber` y
`api-manager-publisher` contra un cluster sin el APIM real. Guarda lo que está suscripto y publicado en un
ConfigMap, así las repeticiones se comportan como en APIM aunque el pod se reinicie.

## Qué simula

**API Subscriber** (contrato: *Integración Null ↔ API Subscriber* y `subscriber.yaml`):

| Endpoint | Comportamiento |
|---|---|
| `POST /v1/subscriptions` | `202` con la operación `Committed`; a los `callbackDelaySeconds` crea el Secret de la credencial y avisa `success` al `callbackUrl`. |
| `GET /v1/subscriptions/{id}` | La suscripción (`Syncing` → `Registered`) o `404`. |
| `PATCH /v1/subscriptions/{id}` | Cambio de plan con `planId`, `approvalRef` y `callbackUrl` (otro campo → `422`): `202`, aplica el plan y el ticket y avisa `success`. Con `RITM9990422` → `422`. |
| `DELETE /v1/subscriptions/{id}` | Baja: `202` (no avisa: el contrato no trae `callbackUrl`). Borra la credencial del gateway; no borra el Secret del namespace. |
| `GET /v1/plans` | `bronze` (5), `gold` (20), `no-limits`. |
| `GET /v1/operations/{id}` | Estado de la operación (respaldo del polling). |

Si el `callbackUrl` es de un link (`/link/{id}/action/{id}`), el mock lee el link en nullplatform y la API es
la del service publicado (`apim-<serviceId>`), así la suscripción queda atada a lo que publicó el publisher;
si no puede leer el link responde `503`. Con otro callback, la API sale del RITM (`RITM0012345` → `api-0012345`). El id es `sub-<api>--<namespace>`: repetir la
misma API en el mismo namespace da `409`, como una suscripción namespace × API ya existente.

| RITM | Respuesta |
|---|---|
| cualquiera | `202` y después `success` |
| `RITM9990409` | `409` con el `sub-…` en el `detail` |
| `RITM9990422` | `422` "no está aprobada en ServiceNow" |
| `RITM9990503` | `503` (no guarda nada) |
| `RITM9990666` | `202` y después `failed`: la suscripción se deshace (`RolledBack`) |

Plan fuera del catálogo → `422`. `Idempotency-Key` es obligatoria en el alta y el cambio de plan: con otro
cuerpo → `422`; con el mismo cuerpo (o una baja repetida) → la misma operación. Los namespaces `kube-*` y
`default` no se pueden suscribir.

**Credencial**: en el primer alta exitosa de un namespace crea `secret-apim-<tenant>` (`b2c` por default) en ese
namespace con `app_id = mock-app-<namespace>` y `app_key = mock-key-<namespace>`. Por cada suscripción crea
además la credencial que lee Authorino en `credentialSecrets.gatewayNamespace` (`kuadrant-system`), con
`api_key = mock-key-<namespace>` y los labels `api-id` y `app-id`.

**API Publisher** (contrato: [`api-manager-publisher/docs/CONTRATO-APIM-PUBLISHER.md`](../../api-manager-publisher/docs/CONTRATO-APIM-PUBLISHER.md)):

| Endpoint | Comportamiento |
|---|---|
| `POST /v1/kuadrant/manifests/publish` | Valida la firma, `sigla` y `project` incluidos (`400 {status: error, message}`); `200 commited` con `apiId` y `hostname`; después avisa `success` al `callbackUrl` (o `failed` si el repo empieza con `fail-`). |
| `POST /v1/kuadrant/manifests/delete` | Busca la API por `name`, `namespace`, `tenant` y `environment`: `202 Commited` con el `deletionId`; a los `callbackDelaySeconds` borra los objetos y avisa `success` (`Deleted`). Con legajo `l9990666` avisa `failed` (`RolledBack`) y deja la API. Sin manifests → `404`; publicación o baja en curso → `400`. |
| `GET /v1/kuadrant/manifests/delete/{deletionId}` | Estado de la baja o `404`. |

El `apiId` es `apim-<serviceId>`, con el service sacado del `callbackUrl`; sin callback de service,
`<namespace>-<name>-<tenant>-1`. Publicar otra vez el mismo `apiId` con el mismo branch/tag/commit →
`400 ya está publicada`; con otro ref → `200` (republicación).

Al terminar la publicación crea en `metadata.namespace`, con el nombre `metadata.name`:
- un `HTTPRoute` colgado de `metadata.parentRefs`, con el `hostname` publicado, los paths de `mock.routePaths` (`/whoami` por default, para simular lo que expone el swagger; vacío = `PathPrefix /`) y el backend de
  `metadata.backend` (o el Service `metadata.name:8080`); si viene `metadata.backend.destinationFqdn`
  (un hostname), la regla reescribe el host a ese valor (`URLRewrite`) y el backend es el gateway;
- una `AuthPolicy` que pide `app_key` (credenciales con `api-id` de la API) y `app_id` igual al de la credencial;
- una `RateLimitPolicy` con `hitsPerWindow` por `window`, solo si vienen los dos.

Al republicar borra lo que la versión anterior creó y la nueva ya no usa (otro nombre o namespace, o la
`RateLimitPolicy` si se sacó el rate limit). Si el cluster los rechaza, avisa `failed` y borra la publicación
y sus objetos. La baja los borra. Solo publica en los
namespaces de `credentialSecrets` (si no, `400`).

**Utilidades**: `GET /mock/state` (todo el estado), `POST /mock/reset` (lo vacía), `GET /healthz`.

Si el pod se reinicia con operaciones o publicaciones pendientes, las reprograma al arrancar.

## Avisos a nullplatform

Hace lo mismo que el APIM real según el mini doc de avisos: canjea `NP_API_KEY` por un token y manda
`PATCH` al `callbackUrl` (un avance y después el resultado). Solo llama a acciones de nullplatform:
`https://<host de mock.npApiUrl>/service|link/{id}/action/{id}`, sin query. Sin `NP_API_KEY` no avisa y la
acción queda abierta.

## Instalación

```bash
helm upgrade --install apim-mock mocks/apim-mock/chart -n apim-mock --create-namespace \
  --set image.repository=docker.io/federicomalehnullplatform/apim-mock \
  --set mock.token=<el API_SUBSCRIBER_TOKEN del agente> \
  --set npApiKey.existingSecret=<secret con NP_API_KEY> \
  --set 'credentialSecrets.namespaces={<namespace de la app>}' \
  --set 'httpRoute.parentRefs[0].name=<gateway>' \
  --set 'httpRoute.parentRefs[0].namespace=<namespace del gateway>' \
  --set 'httpRoute.hostnames[0]=<hostname>'
```

Después, en el agente: `API_SUBSCRIBER_URL=https://<hostname>` y `API_SUBSCRIBER_TOKEN=<mock.token>`.

`mock.token` es obligatorio (el mock no arranca sin token): es el Bearer que manda el service, y viaja en un
Secret del chart.

En los namespaces de las apps el chart da permiso de **crear** (no leer) Secrets y de aplicar y borrar
`HTTPRoute`, `AuthPolicy` y `RateLimitPolicy`:
- `credentialSecrets.namespaces: [ns-a, ns-b]` (obligatorio) crea un Role por namespace y el mock rechaza los demás;
- `credentialSecrets.allowAllNamespaces=true` usa un ClusterRole en lugar de la lista: solo para clusters de prueba;
- `credentialSecrets.gatewayNamespace` (`kuadrant-system`) recibe un Role para las credenciales de Authorino;
- `credentialSecrets.create=false` apaga los Secrets y el alta termina igual sin credencial.

## Imagen

```bash
docker login -u federicomalehnullplatform
mocks/apim-mock/scripts/publish
```

Publica `docker.io/federicomalehnullplatform/apim-mock:<appVersion del chart>` para `linux/amd64`. `IMAGE_REPO=…`
y `TAG=…` cambian el destino; un `IMAGE_REPO` de `public.ecr.aws` hace el login de ECR público solo.

## Tests

```bash
cd mocks/apim-mock
python3 -m unittest discover -s tests
PATH=/opt/homebrew/bin:$PATH bats tests/chart.bats
```

Requiere Python >= 3.9, helm, yq y bats.

Para correrlo local: `MOCK_TOKEN=t STATE_BACKEND=memory CREATE_CREDENTIAL_SECRET=false python3 app/server.py`.
