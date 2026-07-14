# Registers the pom-services service specification + link specification from the
# local specs/, then associates a notification channel so an agent handles its actions.
# Modules: nullplatform/tofu-modules//nullplatform/{service_definition,service_definition_agent_association}

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v6.3.0"

  nrn          = var.nrn
  service_name = "Servicios POM"
  service_path = var.service_path

  # Read the specs from this repo instead of fetching them from git.
  # local_specs_path points at the service dir, i.e. two levels up from specs/install/.
  git_provider     = "local"
  local_specs_path = abspath("${path.module}/../..")

  # No custom actions — the service and link use their default actions.
  available_actions = []
  available_links   = ["pom-services"]

  extra_visibile_to_nrns = var.extra_visible_to_nrns
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v6.3.0"

  nrn                          = var.nrn
  api_key                      = var.agent_api_key
  service_specification_slug   = module.service_definition.service_specification_slug
  repository_service_spec_repo = var.repository_service_spec_repo
  service_path                 = var.service_path
  tags_selectors               = var.tags_selectors
}
