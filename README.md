# Custom Scopes Workshop — Galicia

Personalizaciones de nullplatform para Galicia: **overrides de scope** que inyectan
secrets en los deployments, una **librería compartida** para montarlos de forma
idempotente y segura, y un **servicio custom** ("Servicios POM") con su registro por
Terraform.

Todo corre sobre el modelo *agent-backed scopes* de nullplatform: la plataforma envía
notificaciones a un agente, que ejecuta workflows (pasos de script bash) contra el
cluster.

---

## Estructura

```
.
├── shared/
│   └── scripts/
│       ├── mount_files              # librería: monta secrets como volumes/volumeMounts
│       └── strip_route_headers      # librería: saca headers del HTTPRoute del scope
├── override/                        # override del scope base (certificados cabanco)
│   ├── values.yaml                  # CABANCO_MOUNTS + S2S_STRIP_HEADERS
│   └── deployment/
│       ├── scripts/mount_certificates
│       ├── scripts/strip_s2s_headers
│       └── workflows/{initial,blue_green}.yaml
├── pom-services/                    # servicio "Servicios POM" (spec + link + acciones)
│   ├── specs/
│   │   ├── service-spec.json.tpl    # definición del servicio
│   │   ├── links/pom-services.json.tpl
│   │   └── install/                 # Terraform que registra todo en la plataforma
│   ├── entrypoint/{entrypoint,service,link}   # router de acciones → workflows
│   ├── workflows/{create,update,delete,read,link,unlink}.yaml   # no-op (log ok)
│   ├── scripts/noop
│   ├── values.yaml
│   └── override/                    # override de scope propio del servicio
│       ├── values.yaml              # POM_SERVICES_MOUNTS
│       └── deployment/
│           ├── scripts/mount_certificates   # monta jwt-secret si el link está asociado
│           └── workflows/{initial,blue_green}.yaml
└── examples/                        # manifests de Secret placeholder para probar
```

---

## Requisitos

| Herramienta | Uso |
|-------------|-----|
| `bash`      | scripts de workflow (`set -euo pipefail`) |
| `yq` (mikefarah v4) | manipular los manifiestos YAML |
| `jq`        | parsear contexto y respuestas de la API |
| `kubectl`   | verificar existencia de secrets en el cluster |
| `tofu` (OpenTofu) | registrar el servicio (`pom-services/specs/install/`) |
| `np` (nullplatform CLI) | ejecución de acciones/workflows y consultas de links |

---

## `shared/scripts/mount_files`

Librería *sourceable* que inyecta secrets del cluster como volumes (a nivel pod) y
volumeMounts (solo en el container `application`) de cada `deployment-*.yaml` renderizado.

```bash
source "<repo>/shared/scripts/mount_files"
mount_files "<descripción>" "$MOUNTS"
```

`$MOUNTS` es una lista (YAML o JSON) donde cada elemento tiene:

```yaml
- name: jwt-secret          # nombre del volume/volumeMount
  secretName: jwt-secret    # nombre del Secret en el cluster
  mode: 420                 # defaultMode del volume
  path: /opt/jwt            # mountPath
  readOnly: true
```

Qué garantiza:

- **Deployment y CronJob**: resuelve la ruta del pod spec según `.kind`
  (`.spec.template.spec` vs `.spec.jobTemplate.spec.template.spec`).
- **Solo el container `application`** recibe los volumeMounts.
- **Idempotente**: `unique_by(.name)` — correrlo N veces nunca duplica una entrada, y
  múltiples llamadas (p. ej. cabanco + pom-services) **appendean** sobre el mismo deployment.
- **Valida existencia de secrets**: antes de montar, chequea cada `secretName` en el
  namespace del deployment. Si falta alguno, lista **todos** los faltantes de una vez y
  sale con `exit 1` sin montar nada.

---

## Overrides de scope

Los overrides se aplican al scope base vía `--overrides-path`. Cada workflow de override
inyecta un paso `mount_certificates` después de `create deployment`. Cada override define
su propia lista de mounts en su `values.yaml` (el motor de workflows la expone como env
var), **con un nombre de variable distinto** para que no se pisen entre sí.

| Override | Variable | Qué monta |
|----------|----------|-----------|
| `override/` (base) | `CABANCO_MOUNTS` | 4 secrets de certificados cabanco en `/opt/cabanco/*` |
| `pom-services/override/` | `POM_SERVICES_MOUNTS` | `jwt-secret` en `/opt/jwt`, **solo si** el scope tiene el link de Servicios POM |

El override de `pom-services` primero consulta la API (`np link list`) para decidir si el
scope tiene un link del servicio asociado — sea **a nivel scope** (`entity_nrn` == scope)
o **a nivel application con dimensiones que matchean** el scope. Si no hay link, loguea y
hace skip sin tocar el deployment.

### Higiene de headers S2S

El override base agrega además un paso `strip_s2s_headers` que saca del `HTTPRoute` del scope
los headers que el patrón S2S le cuelga al request, para que no lleguen a la aplicación.

| Variable | Dónde | Qué saca |
|----------|-------|----------|
| `S2S_STRIP_HEADERS` | `override/values.yaml` | `x-np-token`, `x-np-origin`, `x-np-svc`, `x-np-scope`, `x-api-key` |

El motivo inmediato es de tamaño: hay aplicaciones Tomcat cerca del `maxHttpHeaderSize` con
sus propios headers, y un JWT RS256 son ~400-800 bytes. El efecto secundario es de seguridad
—el token deja de llegar vivo a la app, que hasta ahora podía replayearlo hasta que expirara.

El paso corre `after: create deployment`, que en el scope base cae **después** de que
`route traffic` rinde `ingress-$SCOPE_ID-$DEPLOYMENT_ID.yaml` y **antes** del `apply`.

Dos cosas que lo condicionan:

- **Gateway API admite un solo `RequestHeaderModifier` por rule** (`RequestHeaderModifier
  filter cannot be repeated`, validado por el CRD). Por eso la librería mergea dentro del
  filtro existente en vez de appendear uno nuevo.
- **Sólo cubre lo que pasa por el `HTTPRoute` del scope.** El camino s2s hacia OpenShift entra
  por `s2s-ingress-<svc>` y va derecho al alias `<svc>-local`, sin tocar la route del scope:
  ese lado lo resuelve el template del `s2s-traffic-migrator`.

La lógica vive en `shared/scripts/strip_route_headers` y es idempotente: correrla N veces deja
un solo filtro y sin headers repetidos.

El link se identifica por `selectors.provider` (configurado en `POM_SERVICES_PROVIDER`
del `values.yaml` del override), **no** por el `specification_id`. Así el override no
queda acoplado a un id que cambia cada vez que se corre el Terraform en un cliente distinto.

---

## Servicio "Servicios POM" (`pom-services/`)

Servicio custom de nullplatform con acciones por defecto implementadas como workflows
no-op (solo loguean `ok`) y un link asociable a nivel dimension y scope.

- `specs/service-spec.json.tpl` — servicio, `slug` derivado del `name`, sin parámetros.
- `specs/links/pom-services.json.tpl` — link, `assignable_to: any` (dimension + scope).
- `entrypoint/` — `entrypoint` rutea a `service` o `link` según la notificación; cada uno
  mapea la acción a un workflow (`create.yaml`, `link.yaml`, etc.).
- `workflows/` — no-op: cada uno corre `scripts/noop`.

### Registrar el servicio en la plataforma

El registro es por Terraform (OpenTofu), usando los módulos de
[`nullplatform/tofu-modules`](https://github.com/nullplatform/tofu-modules):
`service_definition` (crea service spec + link spec leyendo `specs/` local) y
`service_definition_agent_association` (crea la notification channel que conecta al agente).

```bash
cd pom-services/specs/install
cp terraform.tfvars.example terraform.tfvars   # completar api_keys, nrn, tags_selectors
tofu init
tofu apply
```

Variables principales (ver `variables.tf`):

- `np_api_key` — para que el provider cree los recursos.
- `agent_api_key` — la que queda en la notification channel para que el agente llame de vuelta.
- `nrn` — organización/cuenta destino.
- `tags_selectors` — qué agente(s) atienden las notificaciones.
- `service_path` (default `pom-services`), `repository_service_spec_repo`.

> El módulo **deriva el slug del `name`** del spec (ignora el `slug` del archivo). El filtro
> de la notification channel usa el slug real (output del módulo), así que queda consistente.

---

## Probar en un cluster

Los volumes referencian Secrets que deben existir en el **mismo namespace** que el pod.
`examples/` trae manifests placeholder (contenido dummy — no son secrets reales):

```bash
kubectl apply -f examples/           # namespace nullplatform
```

Un pod cuyo `secret` volume apunta a un Secret inexistente queda en `ContainerCreating`
(`FailedMount`); por eso `mount_files` valida y falla temprano listando lo que falta.

---

## Convenciones

- Todos los scripts arrancan con `set -euo pipefail`.
- Los mensajes de error incluyen causa y cómo arreglarlo (`💡`/`🔧`).
- Los `.json.tpl` que consume el módulo de Terraform son **JSON puro** (se leen con
  `jsondecode`, no pasan por gomplate).
- **Nunca** se commitea `terraform.tfvars` ni `*.tfstate` (contienen credenciales reales) —
  están en `.gitignore`.
