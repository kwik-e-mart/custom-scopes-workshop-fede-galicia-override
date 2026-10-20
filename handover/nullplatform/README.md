# nullplatform — service definitions (Galicia)

Layer de OpenTofu que registra los **service definitions** de la organización
de Galicia en nullplatform.

## Alcance

Incluye los 9 service definitions, todos registrados como **package** versionado:

| key | servicio | specs desde |
|---|---|---|
| `rds_postgres_server` | RDS Postgres Server | `galicia-trfm-terraform/np-services-postgresql-rds` |
| `rds_postgres_db` | RDS Postgres Database | `galicia-trfm-terraform/np-services-postgresql-rds` |
| `rds_sqlserver_server` | RDS SQL Server | `galicia-trfm-terraform/np-services-sqlserver-rds` |
| `rds_sqlserver_db` | RDS SQL Server DB | `galicia-trfm-terraform/np-services-sqlserver-rds` |
| `aws_dynamodb` | AWS DynamoDB | `galicia-trfm-terraform/np-services-dynamo-db` |
| `aws_valkey` | AWS Valkey | `galicia-trfm-terraform/np-services-valkey` |
| `aws_s3_bucket` | AWS S3 Bucket | `nullplatform/services-s-3` |
| `api_manager_publisher` | API Manager Publisher | `services/api-manager-publisher` (local) |
| `s2s_traffic_migrator` | Migrador de tráfico service-to-service a EKS | `services/s2s-traffic-migrator` (local) |

No incluye:

- **Scope definitions** (containers, scheduled tasks, static files, lambda).
- La `metadata_specification` de aplicación.

Esos se siguen administrando del lado de nullplatform, en otro layer.

## Prerrequisitos

- OpenTofu >= 1.6.0
- Credenciales de AWS con acceso al bucket de tfstate
- Una API key de nullplatform con scope **Organization** y roles `admin`,
  `secops` y `ops`
- Un **GitHub token válido** con lectura sobre los repos de
  `galicia-trfm-terraform`. Ver [El GitHub token](#el-github-token): es la
  causa de error más común en la primera corrida.
- `git` y salida a `github.com` / `raw.githubusercontent.com`: el módulo se
  descarga por `git::https` y las specs se leen de GitHub.

## Setup

1. Copiar `backend.tfbackend.example` a `backend.tfbackend` y completar
   `bucket`, `profile` y `region`. El `key` define dónde vive el state dentro
   del bucket.

2. Copiar `terraform.tfvars.example` a `terraform.tfvars` y completar `nrn`
   con el NRN de la organización (`organization=<ORGANIZATION_ID>`).

3. Exportar las credenciales (no van en archivos):

   ```sh
   export TF_VAR_np_api_key="..."
   export TF_VAR_github_token="..."
   ```

4. Inicializar:

   ```sh
   tofu init -backend-config=backend.tfbackend
   ```

## Primera corrida: adoptar el state existente

Los service definitions **ya están registrados** en nullplatform. Este
directorio es solo la configuración; el `tfstate` con esos recursos se entrega
por separado. Correr `apply` contra un state vacío intenta crearlos de nuevo y
termina en duplicados o en errores de conflicto.

1. Con el backend ya inicializado, cargar el state entregado:

   ```sh
   tofu state list            # sin recursos antes de cargarlo
   tofu state push terraform.tfstate
   tofu state list            # ahora lista module.service_definitions_packages["<key>"]...
   ```

   Si el backend ya tiene un state propio, `push` falla por lineage o serial:
   no usar `-force` sin revisar cuál de los dos es el correcto.

   Alternativa: subir el archivo con `aws s3 cp` al mismo `key` del
   `backend.tfbackend` y después correr `tofu init`.

2. Planificar:

   ```sh
   tofu plan -out=handover.tfplan
   ```

   `terraform.tfvars` se carga solo. El `.tfplan` contiene los valores de las
   variables sensibles (API key, token): no compartirlo.

   El resultado esperado es **sin cambios** o, a lo sumo, updates in place.
   Si el plan muestra `create` o `destroy` de `nullplatform_service_specification`
   o `nullplatform_package`, frenar y revisar antes de seguir. Las causas
   habituales son: el state no se cargó o el backend apunta a otro `key`, el
   state es de otra organización que la del `nrn`/API key, o las direcciones
   del state no coinciden con `module.service_definitions_packages["<key>"]`.

3. Recién con el plan revisado:

   ```sh
   tofu apply handover.tfplan
   ```

## Operación

Cualquier cambio sigue el mismo ciclo: editar, `tofu plan`, revisar, `tofu apply`.
Los cambios hechos a mano desde la UI de nullplatform sobre atributos que
maneja este layer se revierten en el próximo apply: revisar siempre el plan.

### Habilitar, deshabilitar o cambiar versión de un servicio

Se hace con `var.service_definitions`. Ojo: definirla en `terraform.tfvars`
**reemplaza el mapa completo** del default de `variables.tf`, no lo mergea. Un
servicio que no aparezca en el mapa queda con los defaults (`enabled = true`,
`version = "main"`): en los servicios que leen specs de GitHub `main` falla la
validación (ver [Versionado](#versionado)), y los servicios locales publican el
package con versión `main`. Por eso, si se sobreescribe, copiar el mapa entero
y modificar solo la entrada que cambia; o editar el default directamente en
`variables.tf`.

Deshabilitar un servicio (`enabled = false`) lo **elimina** de nullplatform en
el próximo apply. Antes de hacerlo, confirmar que no tenga instancias creadas.

## El GitHub token

Las specs de los servicios de `galicia-trfm-terraform` se leen de sus repos,
que son privados, así que el token tiene que tener acceso de lectura a ellos.
`api_manager_publisher` y `s2s_traffic_migrator` usan specs locales
(`services/`) y no dependen del token.

Un token inválido, vencido o sin acceso al repo hace que
`raw.githubusercontent.com` devuelva 401, 403 o 404, y el `plan` falla con:

```
Fetch of https://raw.githubusercontent.com/<org>/<repo>/refs/<ref_type>/<version>/... returned HTTP 404, expected 200.
```

Un 404 también puede ser un `version`/`ref_type` que no existe (por ejemplo un
tag con `ref_type = "heads"`). Revisar el token y el ref antes que cualquier
otra cosa.

## Versionado

Cada servicio pinea dos cosas por separado, en el default de
`var.service_definitions` (`variables.tf`):

| campo | qué pinea |
|---|---|
| `version` + `ref_type` | el ref del repo del servicio, de donde salen las specs y el código. `ref_type`: `tags` para un tag, `heads` para un branch (default), `""` para un SHA |
| `package_version` | el semver con el que se publica el package en nullplatform |

Son independientes: el package se versiona con su propio criterio y no tiene
por qué seguir la numeración del repo. Si `package_version` se omite, el package
usa el valor de `version` (caso `aws_s3_bucket`).

El módulo rechaza `version` vacío o `main`, `master`, `head`, `latest`, para
que el mismo apply no registre contenido distinto según el día. Cualquier otro
branch pasa la validación: para que sea inmutable usar `ref_type = "tags"` o un
SHA.

En `api_manager_publisher` y `s2s_traffic_migrator` las specs son locales
(`services/`): la validación no aplica y no se lee ningún repo, pero `version`
igual se registra como `reference` del artifact del package.
