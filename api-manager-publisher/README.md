# API Manager Publisher (service nullplatform)

Publica la API de una aplicación en APIM (Kuadrant) a través del **API Publisher** de APIM, y deja que otras
aplicaciones se suscriban a ella con un link. El service no genera manifiestos ni toca el cluster: APIM los
genera a partir del OpenAPI del repo, los commitea, espera a Argo CD y registra la API.

Contrato con APIM: [`docs/CONTRATO-APIM-PUBLISHER.md`](./docs/CONTRATO-APIM-PUBLISHER.md).

## Cómo se usa

- **Crear la instancia = publicar.** El formulario pide el **scope** que atiende la API (APIM genera su
  HTTPRoute contra el Service del despliegue activo de ese scope), la referencia del repo (`branch` / `tag` / `commit`,
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
| `environment` | dimensión `environment` del service (`int`, `qas`, `prd`; `dev` no se publica) |
| `tenant` | `b2c` fijo por ahora |
| `cluster` | nombre del cluster del provider, o `APIM_CLUSTER_NAME` |
| `metadata.name`, `labels.app` | nombre del repo |
| `metadata.namespace` | namespace del provider |
| `metadata.parentRefs` | `APIM_PUBLISH_PARENT_REFS` (hasta que exista la API de scheduler) |
| `metadata.backend` | Service del despliegue activo del scope: el backend con más peso de sus HTTPRoute (`nullplatform=true,scope_id=<id>`) |
| `callbackUrl` | la acción de nullplatform |

> [!WARNING]
> El HTTPRoute de APIM apunta al Service del despliegue que estaba activo al publicar. Después de un deploy
> nuevo del scope, ese Service cambia (`d-<scope>-<deployment>`) y la ruta de APIM queda apuntando al anterior
> hasta que se republique. Cómo sincronizarlo está pendiente de definir con APIM.

## Configuración del agente

| Variable | Uso |
|---|---|
| `APIM_PUBLISHER_URL`, `APIM_PUBLISHER_TOKEN` | API Publisher (https) |
| `APIM_PUBLISH_PARENT_REFS` | JSON con los Gateways, por ejemplo `[{"name":"s2s-ingress","namespace":"gateways"}]` |
| `APIM_CLUSTER_NAME` | opcional: reemplaza el nombre del cluster del provider |
| `API_SUBSCRIBER_URL`, `API_SUBSCRIBER_TOKEN` | API Subscriber, para los links |
| `APIM_CA_CERT` | opcional: PEM de la CA con la que validar a APIM (si usa una CA privada) |

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
