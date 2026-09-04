# API Manager Publisher (service nullplatform)

Deja que una aplicación exponga rutas HTTP hacia aplicaciones de **otros** namespaces del cluster,
sin tocar código y sin que nadie copie ni pegue una credencial.

## El problema que resuelve

Por default, un `Service` de Kubernetes en el namespace `payments` no es alcanzable desde el
namespace `reports`: la network policy base del cluster corta el tráfico cross-namespace. Api
Manager es la manera declarativa de abrir un agujero **controlado** en esa barrera: sólo los paths
que la aplicación declara quedan expuestos, bajo los dominios que ella elige, y sólo a quien tenga
una credencial válida para consumirlos. Todo lo que no se declara sigue siendo inalcanzable.

## Qué declara el desarrollador

Al instanciar el service sobre una aplicación, el formulario pide:

- **Dominios** (`hosts`): por lo menos uno. Otras apps van a consumir la tuya por acá.
- **Rutas expuestas** (`routes`): por lo menos una, cada una con:
  - **Path** (`/`, `/api`, `/api/v1/users`, `/items/{id}`, `/files/*` — el `*` final marca prefijo,
    cualquier otro path es exacto),
  - **Verbos** (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`),
  - **Scope**: qué scope de la propia aplicación atiende esa ruta.

El backend nunca se escribe a mano. El service resuelve, a partir del scope declarado, cuál es el
dominio interno de esa release y arma el `HTTPRoute` contra ese backend — ninguna URL interna se
tipea en el formulario. Si el scope elegido no está activo o todavía no tiene una release desplegada
(`domain: "To be defined"`), la instanciación falla antes de tocar el cluster.

## Cómo la consume otra aplicación

La aplicación consumidora se **linkea** a este service (link `connect`). En ese momento se le emite
una credencial propia (una key opaca, no un JWT ni nada que se pueda decodificar) y la recibe como
variable de entorno `${service.slug}_API_KEY`, inyectada como secret parameter — nunca en texto plano en
ningún lado que un humano tenga que copiar. Ese `${service.slug}_API_KEY` va en el header `x-api-key` de
cada request hacia la app expuesta. Borrar el link revoca el acceso de inmediato: no hay expiración
que esperar.

Comportamiento que ve la app consumidora:

| Situación | Código |
|---|---|
| Sin el header `x-api-key` | 401 |
| Header con una key que no existe | 401 |
| Header con una key válida pero emitida para **otra** aplicación | 403 |
| Path no declarado por la app expuesta | 404 |
| Todo lo anterior en orden | 200 |

## Compartir un dominio está permitido

Dos aplicaciones distintas pueden publicar bajo el mismo dominio (por ejemplo, las dos bajo
`api.expuesta.com`) siempre que sus paths no se pisen. Lo que se rechaza, al crear o actualizar, es
declarar el mismo par `(dominio, path)` que ya declaró otra aplicación — la unidad de colisión es el
par, no el dominio solo. Esto sorprende la primera vez: no hace falta "ser dueño" de un dominio para
exponer algo bajo él.

## Instalación

`specs/` tiene dos layers de Terraform con alcance y momento de aplicación distintos.

| | alcance | cuándo |
|---|---|---|
| `specs/prerequisites/` | **por cluster** | una vez por cada cluster donde va a correr el service |
| `specs/install/` | **por organización** | una sola vez, registra el service y su notification channel |

### `specs/prerequisites/`

Instala Gateway API (opcional — algunas distros ya lo traen) y Kuadrant (con el CR `Kuadrant`, que
levanta Authorino). Sin ese CR las `AuthPolicy` quedan aceptadas y **nunca enforceadas**.

```bash
cd specs/prerequisites
cp terraform.tfvars.example terraform.tfvars   # completar kube_context
tofu init && tofu apply
```

Este layer **no** crea con Terraform el Gateway de ingreso (`s2s-ingress`, en el namespace
`gateways`) contra el que este service cuelga sus `HTTPRoute`, ni la clave de firma del wristband.
Eso va como **manifiestos explícitos** en
[`specs/prerequisites/manifests/`](./specs/prerequisites/manifests), con los placeholders y el orden
de aplicación en [`specs/prerequisites/README.md`](./specs/prerequisites/README.md).

### `specs/install/`

Registra el service specification leyendo las specs de este mismo repo (`git_provider = "local"`) y
le asocia el notification channel.

```bash
cd specs/install
cp terraform.tfvars.example terraform.tfvars   # completar nrn y las dos api keys
tofu init && tofu apply
```

`tags_selectors` decide qué agente atiende las notificaciones de este service.

## Tests

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/
```

Requiere localmente **bash >= 4**, **gomplate** y **coreutils** (por el `timeout` que usa uno de
los tests — macOS no lo trae de fábrica y sin él ese test cuelga la suite en vez de fallar rápido).

## Dos cosas para mirar en los objetos del cluster

- La `AuthPolicy` puede reportar `Accepted=True` sin estar enforceando nada. La señal que importa es
  `Enforced=True`.
- Las `HTTPRoute` de este service reportan `ResolvedRefs=False (BackendNotFound)` **estando bien**:
  usan `backendRefs` de `kind: Hostname` (una extensión de Istio), que Istio no marca como resuelta.
  No es un síntoma de nada roto.

## Procedencia

Basado en [`nullplatform/services-endpoint-exposer`](https://github.com/nullplatform/services-endpoint-exposer),
adaptado. Una diferencia importante: el upstream declara el link `connect` y trae su
`specs/links/connect.json.tpl`, pero no incluye ningún `workflows/istio/link.yaml` — sólo
create/update/delete/read. La emisión de la credencial al linkear (`mint_key`) y su revocación al
unlink (`revoke_key`) no vienen del upstream: se escribieron acá.
