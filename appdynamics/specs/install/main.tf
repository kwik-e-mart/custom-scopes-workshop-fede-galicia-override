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
}

resource "nullplatform_metadata_specification" "build" {
  name        = "Build metadata"
  description = "Add metadata to builds"
  nrn         = var.nrn
  entity      = "build"
  metadata    = "details"

  schema = jsonencode({
    type = "object"
    properties = {
      "appName" = {
        description = "Application name"
        type        = "string"
      }
      "organization" = {
        description = "Organization name"
        type        = "string"
      }
      "sigla" = {
        description = "Application sigla"
        type        = "string"
      }
      "appType" = {
        description = "Application type"
        type        = "string"
      }
      "version" = {
        description = "Build version"
        type        = "string"
      }
      "branch" = {
        description = "Source branch"
        type        = "string"
      }
      "environment" = {
        description = "Target environment"
        type        = "string"
      }
      "tech" = {
        description = "Application technology"
        type        = "string"
        enum        = ["python", "node", "java", "dotnet"]
      }
      "techVersion" = {
        description = "Technology version"
        type        = "string"
      }
      "runtime" = {
        description = "Application runtime"
        type        = "string"
      }
      "buildId" = {
        description = "Build identifier"
        type        = "integer"
      }
      "buildUser" = {
        description = "User that triggered the build"
        type        = "string"
      }
      "pipelineUrl" = {
        description = "CI pipeline URL"
        type        = "string"
      }
      "source" = {
        description = "Source repository URL"
        type        = "string"
      }
    }
    required = [
      "appName",
      "organization",
      "sigla",
      "appType",
      "version",
      "branch",
      "environment",
      "tech",
      "techVersion",
      "runtime",
      "buildId",
      "buildUser",
      "pipelineUrl",
      "source"
    ]
    additionalProperties = false
  })
}