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
| `RITM9990409` | `409` con el `sub-…` en el `detail` |
| `RITM9990422` | `422` "no está aprobada en ServiceNow" |
| `RITM9990503` | `503` (no guarda nada) |
| `RITM9990666` | `202` y después `failed`: la suscripción se deshace (`RolledBack`) |

Plan fuera del catálogo → `422`. `Idempotency-Key` es obligatoria en el alta y el cambio de plan: con otro
cuerpo → `422`; con el mismo cuerpo (o una baja repetida) → la misma operación. Los namespaces `kube-*`,
`default` y el del propio mock no se pueden suscribir.

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

Si el pod se reinicia con operaciones o publicaciones pendientes, las reprograma al arrancar.

## Avisos a nullplatform

Hace lo mismo que el APIM real según el mini doc de avisos: canjea `NP_API_KEY` por un token y manda
`PATCH` al `callbackUrl` (un avance y después el resultado). Solo llama a acciones de nullplatform:
`https://<host de mock.npApiUrl>/service|link/{id}/action/{id}`, sin query. Sin `NP_API_KEY` no avisa y la
acción queda abierta.

## Instalación

```bash
helm upgrade --install apim-mock mocks/apim-mock/chart -n apim-mock --create-namespace \
  --set image.repository=<repo de la imagen> \
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

Para dejar la credencial donde vive la app, el chart da permiso de **crear** (no leer) Secrets:
- `credentialSecrets.namespaces: [ns-a, ns-b]` (obligatorio) crea un Role por namespace y el mock rechaza los demás;
- `credentialSecrets.allowAllNamespaces=true` usa un ClusterRole en lugar de la lista: solo para clusters de prueba;
- `credentialSecrets.create=false` lo apaga y el alta termina igual sin Secret.

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

Para correrlo local: `MOCK_TOKEN=t STATE_BACKEND=memory CREATE_CREDENTIAL_SECRET=false python3 app/server.py`.
