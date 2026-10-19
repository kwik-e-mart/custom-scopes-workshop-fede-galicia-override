output "service_specification_slug" {
  value       = module.service_definition.service_specification_slug
  description = "Slug del service specification registrado."
}

output "external_context_channel_id" {
  value = nullplatform_notification_channel.external_context.id
}
