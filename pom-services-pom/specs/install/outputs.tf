output "service_specification_id" {
  value       = module.service_definition.service_specification_id
  description = "ID of the created pom-services-pom service specification."
}

output "service_specification_slug" {
  value       = module.service_definition.service_specification_slug
  description = "Slug of the created pom-services-pom service specification."
}

output "notification_channel_id" {
  value       = module.service_definition_agent_association.id
  description = "ID of the notification channel wiring the agent to the pom-services-pom service."
}
