# Registra el service specification del Egress Interceptor y le asocia un notification channel,
# para que un agente tome sus acciones.
#
# Los prerequisitos de CLUSTER (Gateway API, Kuadrant) están en `../prerequisites/` y se aplican
# aparte: este layer es de organización y corre una sola vez; aquél es por cluster.

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v6.3.0"

  nrn          = var.nrn
  service_name = "Egress Interceptor"
  service_path = var.service_path

  # Las specs se leen de ESTE repo en vez de traerlas de git. `local_specs_path` apunta al
  # directorio del service, o sea dos niveles arriba de specs/install/.
  git_provider     = "local"
  local_specs_path = abspath("${path.module}/../..")

  # Sin acciones custom ni links: el service usa las acciones por defecto (create/update/delete),
  # que es lo que declara `use_default_actions` en el spec.
  available_actions = []
  available_links   = []

  extra_visibile_to_nrns = var.extra_visible_to_nrns
}

# El channel es lo que hace que la acción llegue a un agente. El selector por tags es lo que decide
# CUÁL: cada cluster corre su propio agente y las instancias se rutean por el atributo `cluster`.
module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v6.3.0"

  nrn                          = var.nrn
  api_key                      = var.agent_api_key
  service_specification_slug   = module.service_definition.service_specification_slug
  repository_service_spec_repo = var.repository_service_spec_repo
  service_path                 = var.service_path
  tags_selectors               = var.tags_selectors
}
