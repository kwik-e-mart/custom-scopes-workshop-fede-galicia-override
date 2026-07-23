output "specification_id" {
  description = "ID of the created AppDynamics provider specification."
  value       = nullplatform_provider_specification.appdynamics_specification.id
}

output "slug" {
  description = "Slug of the AppDynamics provider specification (server-computed)."
  value       = nullplatform_provider_specification.appdynamics_specification.slug
}

output "name" {
  description = "Name of the AppDynamics provider specification."
  value       = local.config.name
}

output "appdynamics_configurations" {
  description = "Created AppDynamics provider configs (id, nrn, dimensions), keyed by instance key."
  value = {
    for key, cfg in nullplatform_provider_config.appdynamics_configurations : key => {
      id         = cfg.id
      nrn        = cfg.nrn
      dimensions = cfg.dimensions
    }
  }
}

output "build_metadata_specification" {
  description = "Build metadata specification: the specification id, name, entity and metadata key registered for builds."
  value = {
    id       = nullplatform_metadata_specification.build.id
    name     = nullplatform_metadata_specification.build.name
    entity   = nullplatform_metadata_specification.build.entity
    metadata = nullplatform_metadata_specification.build.metadata
  }
}
