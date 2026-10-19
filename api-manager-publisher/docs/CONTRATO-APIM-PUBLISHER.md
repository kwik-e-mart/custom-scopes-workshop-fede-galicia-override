# Contrato con el API Publisher de APIM

Estado: firma recibida de APIM (octubre 2026); la parte de publicación del service todavía no está
implementada. La firma completa está en [`apim-publisher.openapi.json`](./apim-publisher.openapi.json).

## Endpoint

`POST /v1/kuadrant/manifests/publish` clona el repo fuente (con el OpenAPI en la raíz), genera
`httproute.yaml`, `ratelimitpolicy.yaml`, `authpolicy.yaml` y `apiproduct.yaml`, los publica en
`clusters/{cluster}/apis/{namespace}/{name}` del repo de manifiestos del ambiente y después sigue Argo CD de
forma asíncrona: si sincroniza registra la API (`SYNCED` / `REGISTERED`); si falla o vence el timeout borra
los manifiestos (`CANCELED`).

Respuestas: `200` con `status` `pushed` / `synced` / `canceled`, o `400` con `{status: "error", message}`
para validación o fallas del workflow (clone, push).

**Falta en la firma y lo vamos a pedir igual que en el subscriber:** `callbackUrl`, para que el Publisher
cierre la acción de nullplatform con el formato del mini doc de avisos
(`PATCH https://api.nullplatform.com/service/{service_id}/action/{action_id}`).

## De dónde sale cada campo (notas de la reunión)

| Campo | De dónde sale |
|---|---|
| `organization`, `repository` | Org y repo de la API que se publica. |
| `branch` / `tag` / `commit` | La versión que se publica; uno de los tres (precedencia branch, tag, commit). |
| `environment` | Hoy no se publica en `dev`. |
| `tenant` | `b2b` o `b2c`. **A investigar de dónde sale**; por ahora todo `b2c`. |
| `cluster` | Nombre del cluster donde vive la API publicada. |
| `legajo` | El del usuario que publica (`l#######`). |
| `metadata.name` | Nombre de la API = nombre del repo. |
| `metadata.namespace` | Namespace donde está la app en el cluster. |
| `metadata.labels.app` | Nombre del repo. |
| `metadata.parentRefs` | Sale de una API de scheduler que todavía no existe (la están armando; van a pasar un mock). |

## Respuesta que usamos

- `hostname`: para mostrarlo en la UI.
- `apiId` (nombre de la API + namespace + tenant): hay que guardarlo para republicar y para dar de baja.
- Van a agregar los métodos que se publican (salen del swagger del repo).

## Pendiente de APIM

- **Republicar**: cuando cambia el swagger del repo hay que volver a publicar desde nullplatform. No está
  implementado; Fer pidió que una actualización de commit sobre la misma API la republique (va a ser un
  endpoint nuevo, con el `apiId`).
- **Delete**: un endpoint de baja que reciba solo el `apiId`.

## Pedidos a APIM que salen de la implementación

- `callbackUrl` en el publish, con el formato del mini doc de avisos (el usuario ya lo pidió).
- Aceptar un backend `kind: Hostname` (`networking.istio.io`): la regla tiene que apuntar al dominio del scope,
  no a un Service de un despliegue.
- Endpoint de baja por `apiId`.
- En el API Subscriber: aceptar el `apiId` en el pedido de suscripción y rechazar el RITM si es de otra API.
  Sin eso, un link a la API X con un RITM aprobado para la API Y suscribe a Y.

## Para discutir cuando hagamos la publicación en el service

- Cómo tener aprobaciones para QA / producción (lo preguntaron en la reunión).
- No hay casos de error que tenga que manejar el service más allá de `400`.
- De dónde sale el `tenant`.
- Cómo se consume la API de scheduler para `parentRefs`.

## Mock

`mocks/apim-mock` implementa este endpoint (más `callbackUrl`) y un `DELETE` provisorio para poder probar el
service antes de tener el Publisher real.
