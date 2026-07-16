resource "nullplatform_provider_specification" "appdynamics_specification" {
  name             = local.config.name
  icon             = local.config.icon
  description      = local.config.description
  category         = local.config.category
  allow_dimensions = local.config.allow_dimensions
  visible_to       = local.spec_visible_to
  schema           = jsonencode(local.config.schema)
}

resource "nullplatform_provider_config" "appdynamics_configurations" {
  for_each = var.instances

  nrn        = each.value.nrn
  type       = nullplatform_provider_specification.appdynamics_specification.slug
  dimensions = each.value.dimensions
  attributes = jsonencode(each.value.attributes)

  lifecycle {
    # The API strips nested attribute keys on read-back, and patching attributes
    # once the config is in use by an active scope fails with a 500. Ignore changes
    # to avoid perpetual drift / failed patches. To iterate the attributes before
    # the config is in use, recreate it: tofu apply -replace='nullplatform_provider_config.scope_configuration["<key>"]'
    ignore_changes = [attributes]
  }
}

resource "nullplatform_metadata_specification" "metadata_application" {
  name        = "Metadata build"
  description = "Add technology metadata to builds"
  nrn         = "organization=1255165411:account=95118862:namespace=1249051863:application=2132488335"
  # nrn         = var.nrn
  entity      = "build"
  metadata    = "technology"

  schema = jsonencode({
    type = "object"
    properties = {
      "runtime" = {
        description = "Application runtime"
        type        = "string"
        enum        = ["python", "node", "java"]
      }
    }
    required = [
      "runtime"
    ]
    additionalProperties = false
  })
}