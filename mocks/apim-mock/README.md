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
| `PATCH /v1/subscriptions/{id}` | Cambio de plan: `202`, aplica el plan y avisa `success`. |
| `DELETE /v1/subscriptions/{id}` | Baja: `202` (no avisa: el contrato no trae `callbackUrl`). No borra el Secret, que es del namespace. |
| `GET /v1/plans` | `bronze` (5), `gold` (20), `no-limits`. |
| `GET /v1/operations/{id}` | Estado de la operación (respaldo del polling). |

La API sale del RITM (`RITM0012345` → `api-0012345`) y el id es `sub-api-0012345--<namespace>`: repetir el
mismo RITM en el mismo namespace da `409`, como una suscripción namespace × API ya existente.

| RITM | Respuesta |
|---|---|
| cualquiera | `202` y después `success` |
| termina en `409` | `409` con el `sub-…` en el `detail` |
| termina en `422` | `422` "no está aprobada en ServiceNow" |
| termina en `503` | `503` (no guarda nada) |
| termina en `666` | `202` y después `failed`: la suscripción se deshace (`RolledBack`) |

Plan fuera del catálogo → `422`; misma `Idempotency-Key` con otro cuerpo → `422`; misma key y mismo cuerpo →
la misma operación.

**Credencial**: en el primer alta exitosa de un namespace crea `secret-apim-<tenant>` (`b2c` por default) en ese
namespace con `app_id = mock-app-<namespace>` y `app_key = mock-key-<namespace>`.

**API Publisher** (contrato: [`api-manager-publisher/docs/CONTRATO-APIM-PUBLISHER.md`](../../api-manager-publisher/docs/CONTRATO-APIM-PUBLISHER.md)):

| Endpoint | Comportamiento |
|---|---|
| `POST /v1/kuadrant/manifests/publish` | Valida la firma (`400 {status: error, message}`); `200 pushed` con `apiId` y `hostname`; después avisa `success` al `callbackUrl` (o `failed` si el repo empieza con `fail-`). |
| `DELETE /v1/kuadrant/manifests/{apiId}` | **Provisorio** hasta que APIM pase el endpoint real: `200` o `404`. |

Publicar otra vez el mismo `apiId` con el mismo branch/tag/commit → `400 ya está publicada`; con otro ref →
`200` (republicación).

**Utilidades**: `GET /mock/state` (todo el estado), `POST /mock/reset` (lo vacía), `GET /healthz`.

## Avisos a nullplatform

Hace lo mismo que el APIM real según el mini doc de avisos: canjea `NP_API_KEY` por un token y manda
`PATCH` al `callbackUrl` (un avance y después el resultado). Solo llama a URLs `https` del host de
`mock.npApiUrl`. Sin `NP_API_KEY` no avisa y la acción queda abierta.

## Instalación

```bash
helm upgrade --install apim-mock mocks/apim-mock/chart -n apim-mock --create-namespace \
  --set image.repository=<repo de la imagen> \
  --set mock.token=<el API_SUBSCRIBER_TOKEN del agente> \
  --set npApiKey.existingSecret=<secret con NP_API_KEY> \
  --set 'httpRoute.parentRefs[0].name=<gateway>' \
  --set 'httpRoute.parentRefs[0].namespace=<namespace del gateway>' \
  --set 'httpRoute.hostnames[0]=<hostname>'
```

Después, en el agente: `API_SUBSCRIBER_URL=https://<hostname>` y `API_SUBSCRIBER_TOKEN=<mock.token>`.

El chart crea un ClusterRole que puede leer y crear Secrets en cualquier namespace (para dejar la credencial
donde vive la app). Es para clusters de prueba; `credentialSecrets.create=false` lo apaga y el alta termina
igual sin Secret.

## Imagen

```bash
IMAGE_REPO=public.ecr.aws/<alias>/apim-mock mocks/apim-mock/scripts/publish
```

El tag sale de `appVersion` del chart (o `TAG=…`).

## Tests

```bash
cd mocks/apim-mock
python3 -m unittest discover -s tests
PATH=/opt/homebrew/bin:$PATH bats tests/chart.bats
```

Requiere Python >= 3.9, helm, yq y bats.
