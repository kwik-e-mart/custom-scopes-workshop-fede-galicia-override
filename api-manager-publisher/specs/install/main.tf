module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v9.0.0"

  nrn          = var.nrn
  service_name = "API Manager Publisher"
  service_path = "api-manager-publisher"

  git_provider      = "local"
  local_specs_path  = abspath("${path.module}/../..")
  repository_branch = "main"

  available_actions = ["publish-api", "republish-api", "unpublish-api"]
  available_links   = ["connect"]

  extra_visibile_to_nrns = var.extra_visible_to_nrns
}

module "actions_api_key" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/api_key?ref=v9.0.0"

  type              = "custom"
  nrn               = var.nrn
  custom_name       = "SERVICE-NOTIFICATION-CHANNEL-API-MANAGER-PUBLISHER"
  custom_role_slugs = ["controlplane:agent", "ops"]
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v9.0.0"

  nrn                          = var.nrn
  api_key                      = module.actions_api_key.api_key
  service_specification_slug   = module.service_definition.service_specification_slug
  repository_service_spec_repo = var.repository_service_spec_repo
  service_path                 = var.service_path
  base_clone_path              = var.base_clone_path
  tags_selectors               = var.tags_selectors
}
