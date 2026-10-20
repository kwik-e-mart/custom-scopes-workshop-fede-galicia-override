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

`gomplate` no hace falta en este layer.

## Setup

1. Copiar `backend.tfbackend.example` a `backend.tfbackend` y completar
   `bucket` y `profile`. El `key` define dónde vive el state dentro del bucket.

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
   tofu state list            # tiene que estar vacío antes de cargarlo
   tofu state push terraform.tfstate
   tofu state list            # ahora lista los recursos
   ```

   Alternativa: subir el archivo directo al bucket, en la ruta del `key`,
   antes del `tofu init`.

2. Planificar:

   ```sh
   tofu plan -var-file=./terraform.tfvars -out=handover.tfplan
   ```

   El resultado esperado es **sin cambios** o, a lo sumo, updates in place.
   Si el plan muestra `create` o `destroy` de `nullplatform_service_specification`
   o `nullplatform_package`, el state no corresponde a la organización del
   `nrn`/API key o no se cargó bien: frenar y revisar antes de seguir.

3. Recién con el plan revisado:

   ```sh
   tofu apply handover.tfplan
   ```

## Operación

Cualquier cambio sigue el mismo ciclo: editar, `tofu plan`, revisar, `tofu apply`.
Los cambios hechos a mano desde la UI de nullplatform sobre estos recursos se
pierden en el próximo apply.

### Habilitar, deshabilitar o cambiar versión de un servicio

Se hace con `var.service_definitions`. Ojo: definirla en `terraform.tfvars`
**reemplaza el mapa completo** del default de `variables.tf`, no lo mergea. Un
servicio que no aparezca en el mapa queda con los defaults (`enabled = true`,
`version = "main"`), y `main` no es un ref válido (ver
[Versionado](#versionado)). Por eso, si se sobreescribe, copiar el mapa entero
y modificar solo la entrada que cambia; o editar el default directamente en
`variables.tf`.

Deshabilitar un servicio (`enabled = false`) lo **elimina** de nullplatform en
el próximo apply. Antes de hacerlo, confirmar que no tenga instancias creadas.

## El GitHub token

Las specs de los servicios de `galicia-trfm-terraform` se leen de sus repos,
que son privados, así que el token tiene que tener acceso de lectura a ellos.
`api_manager_publisher` y `s2s_traffic_migrator` usan specs locales
(`services/`) y no dependen del token.

Un token inválido, vencido o sin permiso sobre el repo hace que
`raw.githubusercontent.com` devuelva **404**, y el provider `http` no valida el
status: el 404 llega como un cuerpo de texto `"404: Not Found"` y el error
recién aparece al parsearlo, sin mencionar el token por ningún lado:

```
Call to function "jsondecode" failed: extraneous data after JSON object.
```

Si ves eso en el primer `plan`, revisá el token y los permisos del repo antes
que cualquier otra cosa.

## Versionado

Cada servicio pinea dos cosas por separado, en el default de
`var.service_definitions` (`variables.tf`):

| campo | qué pinea |
|---|---|
| `version` + `ref_type` | el tag del repo del servicio, de donde salen las specs y el código |
| `package_version` | el semver con el que se publica el package en nullplatform |

Son independientes: el package se versiona con su propio criterio y no tiene
por qué seguir la numeración del repo.

`version` no acepta branches móviles (`main`, `master`, `head`, `latest`): el
módulo valida que sea un ref pineado, para que el mismo apply no registre
contenido distinto según el día. La excepción son `api_manager_publisher` y
`s2s_traffic_migrator`: sus specs son locales (`services/`), no se lee ningún
repo, y en ellos solo cuenta `package_version`.
