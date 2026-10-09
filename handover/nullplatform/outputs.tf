###############################################################################
# Service definitions
###############################################################################

output "service_definitions" {
  description = "service_definitions keyed by service. Each entry contains the service_specification id/slug and the catalog metadata (repository_org, repository_name, service_path, agent_arguments). 'package_id' and 'package_published_revision_id' are null for services registered without packaging. Only enabled services are included."
  value = {
    for k, m in module.service_definitions_packages : k => {
      id              = m.service_specification_id
      slug            = m.service_specification_slug
      repository_org  = try(local.service_definitions_resolved[k].repository_org, null)
      repository_name = try(local.service_definitions_resolved[k].repository_name, null)
      service_path    = local.service_definitions_resolved[k].service_path
      agent_arguments = local.service_definitions_resolved[k].agent_arguments

      package_id                    = try(m.package_id, null)
      package_published_revision_id = try(m.package_published_revision_id, null)
    }
  }
}
