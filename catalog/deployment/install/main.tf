resource "nullplatform_entity_hook_action" "deployment_update" {
  nrn    = var.nrn
  entity = "deployment"
  action = "deployment:write"
  type   = "hook"
  when   = "after"
  on     = "update"

  dimensions = var.hook_dimensions
}

module "channel_api_key" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/api_key?ref=v4.5.1"

  type        = "custom"
  custom_name = "DEPLOYMENT-NOTIFICATION-CHANNEL-CONTROL-NULL"
  # custom_grants instead of nrn: the module's nrn path requires an account-level NRN
  custom_grants = [
    for role in ["controlplane:agent", "ops"] : { nrn = var.nrn, role_slug = role }
  ]
  custom_tags = [
    for part in split(":", var.nrn) : { key = split("=", part)[0], value = split("=", part)[1] }
  ]
}

resource "terraform_data" "agent_api_key_trigger" {
  input = module.channel_api_key.api_key
}

resource "nullplatform_notification_channel" "deployment_status" {
  nrn         = var.nrn
  type        = "agent"
  source      = ["entity"]
  description = "Notifica a control-null el estado final de deployments"

  configuration {
    agent {
      api_key = module.channel_api_key.api_key
      command {
        type = "exec"
        data = {
          cmdline = "${var.base_clone_path}/${var.repository}/${var.entrypoint_path}"
          environment = jsonencode({
            NP_ACTION_CONTEXT = "'$${NOTIFICATION_CONTEXT}'"
          })
        }
      }
      selector = var.tags_selectors
    }
  }

  filters = jsonencode({
    "entity"              = "deployment"
    "request_body.status" = { "$in" = var.deployment_statuses }
  })

  lifecycle {
    replace_triggered_by = [terraform_data.agent_api_key_trigger]
  }
}
