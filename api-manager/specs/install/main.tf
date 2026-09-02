module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v6.3.0"

  nrn          = var.nrn
  service_name = "API Manager Publisher"
  service_path = var.service_path

  git_provider     = "local"
  local_specs_path = abspath("${path.module}/../..")

  available_actions = []
  available_links   = ["connect"]

  extra_visibile_to_nrns = var.extra_visible_to_nrns
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v6.3.0"
  count  = var.manage_notification_channel ? 1 : 0

  nrn                          = var.nrn
  api_key                      = var.agent_api_key
  service_specification_slug   = module.service_definition.service_specification_slug
  repository_service_spec_repo = var.repository_service_spec_repo
  service_path                 = var.service_path
  tags_selectors               = var.tags_selectors
}
