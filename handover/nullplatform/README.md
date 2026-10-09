# nullplatform — service definitions (Galicia)

Layer de OpenTofu que registra los **service definitions** de la organización
Galicia (`organization=1636958496`) en nullplatform.

## Alcance

Incluye:

- Los 9 service definitions, todos registrados como **package** versionado.

No incluye:

- **Scope definitions** (containers, scheduled tasks, static files, lambda).
- La `metadata_specification` de aplicación.

Esos se siguen administrando del lado de nullplatform, en otro layer.

## Prerrequisitos

- OpenTofu >= 1.6.0
- Credenciales de AWS con acceso al bucket de tfstate
- Una API key de nullplatform con scope **Organization**
- Un **GitHub token válido** — ver la nota más abajo, es la causa de error
  más común en la primera corrida

`gomplate` no hace falta en este layer.

## Setup

1. Copiar `backend.tfbackend.example` a `backend.tfbackend` y completar
   `bucket` y `profile`.

2. Copiar `terraform.tfvars.example` a `terraform.tfvars`.

3. Exportar las credenciales:

   ```
   export TF_VAR_np_api_key="..."
   export TF_VAR_github_token="..."
   ```

4. Inicializar y planificar:

   ```
   tofu init -backend-config=backend.tfbackend
   tofu plan -var-file=./terraform.tfvars
   ```

## El GitHub token

Las specs se leen de los repos de Galicia en `galicia-trfm-terraform`, que son
privados, así que el token tiene que tener acceso de lectura a ellos.

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

`version` no acepta branches móviles (`main`, `master`, `latest`): el módulo
valida que sea un ref pineado, para que el mismo apply no registre contenido
distinto según el día.

## Estado

Este directorio es solo la configuración. El `tfstate` con los recursos ya
registrados se entrega por separado — no corras `apply` contra un state vacío
sin confirmar antes que los recursos no existan ya en nullplatform.
