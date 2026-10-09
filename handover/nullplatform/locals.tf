locals {
  ###############################################################################
  # Service definitions
  ###############################################################################
  rds_postgres_server_definition = {
    repository_org          = "galicia-trfm-terraform"
    repository_name         = "np-services-postgresql-rds"
    service_path            = "rds-postgres-server"
    service_name            = "RDS Postgres Server"
    available_links         = ["connect"]
    agent_arguments         = []
    use_package             = true
    package_artifact_lookup = true
  }

  rds_postgres_db_definition = {
    repository_org  = "galicia-trfm-terraform"
    repository_name = "np-services-postgresql-rds"
    service_path    = "rds-postgres-db"
    service_name    = "RDS Postgres Database"
    available_links = ["connect"]
    agent_arguments = []
    use_package     = true
  }

  aws_s3_bucket_definition = {
    repository_org  = "nullplatform"
    repository_name = "services-s-3"
    service_path    = "aws-s3-bucket"
    service_name    = "AWS S3 Bucket"
    available_links = ["connect"]
    agent_arguments = []
    use_package     = true
  }

  aws_dynamodb_definition = {
    repository_org  = "galicia-trfm-terraform"
    repository_name = "np-services-dynamo-db"
    service_path    = "dynamodb"
    service_name    = "AWS DynamoDB"
    available_links = ["connect", "trigger"]
    agent_arguments = []
    use_package     = true
  }

  aws_valkey_definition = {
    repository_org  = "galicia-trfm-terraform"
    repository_name = "np-services-valkey"
    service_path    = "valkey"
    service_name    = "AWS Valkey"
    available_links = ["connect"]
    agent_arguments = []
    use_package     = true
  }

  rds_sqlserver_server_definition = {
    repository_org  = "galicia-trfm-terraform"
    repository_name = "np-services-sqlserver-rds"
    service_path    = "rds-sqlserver-server"
    service_name    = "RDS SQL Server"
    available_links = []
    agent_arguments = []
    use_package     = true
  }

  rds_sqlserver_db_definition = {
    repository_org          = "galicia-trfm-terraform"
    repository_name         = "np-services-sqlserver-rds"
    service_path            = "rds-sqlserver-db"
    service_name            = "RDS SQL Server DB"
    available_links         = ["connect"]
    agent_arguments         = []
    use_package             = true
    package_artifact_lookup = true
  }

  s2s_traffic_migrator_definition = {
    repository_org  = "galicia-integrations"
    repository_name = "terraform_np_installation"
    service_path    = "s2s-traffic-migrator"
    service_name    = "Migrador de tráfico service-to-service a EKS"
    available_links = []
    dimensions = {
      environment = { required = true }
      site        = { required = true }
    }

    agent_arguments = []
    use_package     = true

    git_provider     = "local"
    local_specs_path = abspath("${path.module}/services/s2s-traffic-migrator")
  }

  api_manager_publisher_definition = {
    repository_org  = "galicia-integrations"
    repository_name = "terraform_np_installation"
    service_path    = "api-manager-publisher"
    service_name    = "API Manager Publisher"
    available_links = ["connect"]
    dimensions = {
      environment = { required = true }
      site        = { required = true }
    }

    agent_arguments = []
    use_package     = true

    git_provider     = "local"
    local_specs_path = abspath("${path.module}/services/api-manager-publisher")
  }

  service_definitions_catalog = {
    rds_postgres_server   = local.rds_postgres_server_definition
    rds_postgres_db       = local.rds_postgres_db_definition
    aws_s3_bucket         = local.aws_s3_bucket_definition
    aws_dynamodb          = local.aws_dynamodb_definition
    aws_valkey            = local.aws_valkey_definition
    rds_sqlserver_server  = local.rds_sqlserver_server_definition
    rds_sqlserver_db      = local.rds_sqlserver_db_definition
    s2s_traffic_migrator  = local.s2s_traffic_migrator_definition
    api_manager_publisher = local.api_manager_publisher_definition
  }

  service_definitions_resolved = {
    for k, v in local.service_definitions_catalog : k => merge(v, {
      repository_branch       = try(var.service_definitions[k].version, "main")
      repository_ref_type     = try(var.service_definitions[k].ref_type, "heads")
      package_version         = try(var.service_definitions[k].package_version, null)
      package_artifact_lookup = try(v.package_artifact_lookup, false)
    })
    if try(var.service_definitions[k].enabled, true)
  }

  service_definitions_packages_enabled = {
    for k, v in local.service_definitions_resolved : k => v if v.use_package
  }

}
