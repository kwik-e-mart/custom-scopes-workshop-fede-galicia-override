output "service_specification_slug" {
  value       = module.service_definition.service_specification_slug
  description = "Slug del service specification registrado. Es con lo que el agente matchea las notificaciones."
}
