# API Manager Publisher (service nullplatform)

Publica la API de una aplicación en APIM (Kuadrant) a través del **API Publisher** de APIM, y deja que otras
aplicaciones se suscriban a ella con un link. El service no genera manifiestos ni toca el cluster: APIM los
genera a partir del OpenAPI del repo, los commitea, espera a Argo CD y registra la API.

Contrato con APIM: [`docs/CONTRATO-APIM-PUBLISHER.md`](./docs/CONTRATO-APIM-PUBLISHER.md).

## Cómo se usa

- **Crear la instancia = publicar.** El formulario pide el **scope** que atiende la API (APIM genera su
  HTTPRoute contra el gateway privado y reescribe el host al dominio de ese scope), la referencia del repo (`branch` / `tag` / `commit`,
  por default `main`), el legajo y, opcional, el rate limit (`window` + `hits_per_window`). La acción queda en
  curso hasta que APIM avisa `registered` (éxito) o `canceled` (falla). Quedan guardados `api_id`, `hostname` y
  `manifest_path`.
- **Actualizar = republicar** con otra referencia o rate limit (APIM sobrescribe la misma ruta).
- **Borrar**: APIM todavía no tiene endpoint de baja. La acción cierra bien y avisa que la API sigue
  publicada; la baja se pide a APIM por fuera.
- **Linkear una app = suscribirla.** El link pide el RITM aprobado y el plan, y usa el mismo flujo que
  [`api-manager-ocp-subscriber`](../api-manager-ocp-subscriber) con el callback del link. El unlink da de baja
  la suscripción solo si ese link la creó.

Qué se manda a APIM y de dónde sale:

| Campo | Origen |
|---|---|
| `organization`, `repository` | `repository_url` de la aplicación |
| `branch` / `tag` / `commit` | formulario |
| `environment` | dimensión `environment` del scope elegido (`int`, `qas`, `prd`; `dev` no se publica), o `APIM_PUBLISH_ENVIRONMENT` |
| `tenant` | `b2c` fijo por ahora |
| `cluster` | nombre del cluster del provider, o `APIM_CLUSTER_NAME` |
| `metadata.name`, `labels.app` | nombre del repo |
| `metadata.namespace` | namespace del provider |
| `metadata.parentRefs` | `APIM_PUBLISH_PARENT_REFS` (hasta que exista la API de scheduler) |
| `metadata.backend` | Service del ingreso del cluster: `name` y `namespace` de `LOCAL_INGRESS_HOST` (igual que `s2s-traffic-migrator`), `port` `APIM_GATEWAY_PORT` (`443`) |
| `metadata.backend.destinationFqdn` | `https://` + dominio del scope elegido; APIM reescribe el host a ese valor |
| `callbackUrl` | la acción de nullplatform |

El tráfico de la API vuelve a entrar por el gateway privado con el host del scope, así que siempre llega al
despliegue activo del scope (también durante un blue-green) sin republicar.

## Configuración del agente

| Variable | Uso |
|---|---|
| `APIM_PUBLISHER_URL`, `APIM_PUBLISHER_TOKEN` | API Publisher (https) |
| `APIM_PUBLISH_PARENT_REFS` | Gateways: `namespace/nombre[:listener]` separados por coma (por ejemplo `gateways/s2s-ingress`) o una lista JSON |
| `APIM_CLUSTER_NAME` | opcional: reemplaza el nombre del cluster del provider |
| `APIM_PUBLISH_ENVIRONMENT` | **solo para pruebas**: `int`, `qas` o `prd`; reemplaza el ambiente que sale del scope en todo lo que publique ese agente. Nunca en un agente productivo: un scope de dev quedaría publicado como `prd` |
| `LOCAL_INGRESS_HOST` | Service del ingreso del cluster como `<service>.<namespace>[.svc.cluster.local]` (default `s2s-ingress-istio.gateways.svc.cluster.local`); va como backend de la API |
| `APIM_GATEWAY_PORT` | opcional: puerto de ese Service (`443`) |
| `API_SUBSCRIBER_URL`, `API_SUBSCRIBER_TOKEN` | API Subscriber, para los links |
| `APIM_CA_CERT` | opcional: CA con la que validar a APIM si usa una privada, en PEM o en base64 |

## Override del scope: la credencial en el deployment

`override/` agrega a cada deploy de un scope linkeado a este servicio la credencial de APIM del namespace como
variables de entorno del container `application`:

| Variable | Sale de |
|---|---|
| `APIM_APP_ID` | Secret `secret-apim-b2c`, key `app_id` |
| `APIM_APP_KEY` | Secret `secret-apim-b2c`, key `app_key` |

El link se busca por `selectors.provider` (`APIM_PUBLISHER_PROVIDER`, `API Manager`), a nivel scope o a nivel
aplicación con dimensiones que coinciden con las del scope, igual que en `pom-services/override/`. Sin link, el paso
no toca el deployment; con link y sin el Secret en el namespace, el deploy falla. Para usarlo, el channel del scope
tiene que pasar `--overrides-path=<repo>/api-manager-publisher/override`.

## Instalación

```bash
cd specs/install
cp terraform.tfvars.example terraform.tfvars   # np_api_key, nrn y tags_selectors
tofu init && tofu apply
```

## Migración desde la versión anterior

La versión anterior publicaba por su cuenta (HTTPRoute, AuthPolicy y una API key por link en
`kuadrant-system`). Esta versión no tiene ese código, así que **no revoca esas keys ni borra esos recursos**.
Antes de instalarla en un cluster que usó la anterior, borrá las instancias viejas con la versión vieja, o
limpiá a mano los Secrets `api-manager-*` de `kuadrant-system` y los HTTPRoute/AuthPolicy `api-manager-*`.

## Tests

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/
```

Requiere bash >= 4, jq y yq. Los tests reusan los mocks de `api-manager-ocp-subscriber/tests/helpers.bash`.
