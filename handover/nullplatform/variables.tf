###############################################################################
# nullplatform configuration
###############################################################################

variable "np_api_key" {
  description = "nullplatform API key. Must have Organization scope with admin, secops, and ops roles."
  type        = string
  sensitive   = true
}

variable "nrn" {
  description = "Organization NRN in the form 'organization=<ORGANIZATION_ID>'."
  type        = string
}

###############################################################################
# GitHub credentials
###############################################################################
variable "github_token" {
  description = "GitHub PAT with read access to private repos."
  type        = string
  sensitive   = true
}

###############################################################################
# Service definitions
###############################################################################

variable "service_definitions" {
  description = "Configuration for service_definitions, keyed by service slug (keys must match local.service_definitions_catalog). 'enabled' toggles registration (default true); 'version' pins the upstream module ref (default 'main'); 'package_version' is the semver published for the package when use_package is set — required when 'version' is a branch, since a branch name is not valid semver; it defaults to 'version'; 'ref_type' is the git namespace 'version' lives in — 'heads' for a branch (default), 'tags' for a tag, '' for a raw commit SHA. Only the v7.1.0 module (use_package) honours ref_type; the v4.5.1 one always resolves refs/heads."
  type = map(object({
    enabled         = optional(bool, true)
    version         = optional(string, "main")
    ref_type        = optional(string, "heads")
    package_version = optional(string)
  }))
  default = {
    rds_postgres_server   = { enabled = true, version = "v0.4.4", ref_type = "tags", package_version = "v1.1.0" }
    rds_postgres_db       = { enabled = true, version = "v0.4.4", ref_type = "tags", package_version = "v1.1.0" }
    aws_s3_bucket         = { enabled = true, version = "v0.5.4", ref_type = "tags" }
    aws_dynamodb          = { enabled = true, version = "v0.4.4", ref_type = "tags", package_version = "v1.1.0" }
    aws_valkey            = { enabled = true, version = "v0.4.0", ref_type = "tags", package_version = "v1.1.0" }
    rds_sqlserver_server  = { enabled = true, version = "v0.2.1", ref_type = "tags", package_version = "v1.1.0" }
    rds_sqlserver_db      = { enabled = true, version = "v0.2.1", ref_type = "tags", package_version = "v1.1.0" }
    api_manager_publisher = { enabled = true, version = "main", package_version = "v0.0.2" }
    s2s_traffic_migrator  = { enabled = true, version = "main", package_version = "v0.0.2" }
  }
}
