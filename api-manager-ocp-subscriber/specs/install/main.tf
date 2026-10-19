module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=feat/service-definition-action-external"

  nrn          = var.nrn
  service_name = "API Manager OCP Subscriber"
  service_path = "api-manager-ocp-subscriber"

  git_provider      = "local"
  local_specs_path  = abspath("${path.module}/../..")
  repository_branch = "main"

  available_actions = ["create-subscription", "change-plan", "delete-subscription"]
  available_links   = ["connect"]

  extra_visibile_to_nrns = var.extra_visible_to_nrns
}

module "actions_api_key" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/api_key?ref=v9.0.0"

  type              = "custom"
  nrn               = var.nrn
  custom_name       = "SERVICE-NOTIFICATION-CHANNEL-API-MANAGER-OCP-SUBSCRIBER"
  custom_role_slugs = ["controlplane:agent", "ops"]
}

module "external_api_key" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/api_key?ref=v9.0.0"

  type              = "custom"
  nrn               = var.nrn
  custom_name       = "EXTERNAL-CONTEXT-CHANNEL-API-MANAGER-OCP-SUBSCRIBER"
  custom_role_slugs = ["controlplane:agent"]
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

resource "terraform_data" "external_api_key_trigger" {
  input = module.external_api_key.api_key
}

resource "nullplatform_notification_channel" "external_context" {
  nrn         = var.nrn
  type        = "agent"
  source      = ["service"]
  description = "Planes de APIM para el formulario del subscriber"

  configuration {
    agent {
      api_key = module.external_api_key.api_key
      command {
        type = "exec"
        data = {
          cmdline = "${var.base_clone_path}/${var.repository_service_spec_repo}/${var.service_path}/entrypoint/external"
          environment = jsonencode({
            NP_ACTION_CONTEXT = "'$${NOTIFICATION_CONTEXT}'"
          })
        }
      }
      selector = var.tags_selectors
    }
  }

  filters = jsonencode({
    action = { "$in" = ["list-apim-plans"] }
  })

  lifecycle {
    replace_triggered_by = [terraform_data.external_api_key_trigger]
  }
}
