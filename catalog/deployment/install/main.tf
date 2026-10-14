resource "nullplatform_entity_hook_action" "deployment_update" {
  nrn    = var.nrn
  entity = "deployment"
  action = "deployment:write"
  type   = "hook"
  when   = "after"
  on     = "update"

  dimensions = var.hook_dimensions
}

resource "terraform_data" "agent_api_key_trigger" {
  input = var.agent_api_key
}

resource "nullplatform_notification_channel" "deployment_status" {
  nrn         = var.nrn
  type        = "agent"
  source      = ["entity"]
  description = "Notifica a control-null el estado final de deployments"

  configuration {
    agent {
      api_key = var.agent_api_key
      command {
        type = "exec"
        data = {
          cmdline = "${var.base_clone_path}/${var.repository}/${var.entrypoint_path}"
          environment = jsonencode({
            NP_ACTION_CONTEXT = "'$${NOTIFICATION_CONTEXT}'"
            CONTROL_NULL_URL  = var.control_null_url
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
