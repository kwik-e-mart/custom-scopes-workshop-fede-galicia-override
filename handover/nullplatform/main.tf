###############################################################################
# Service definitions
###############################################################################

module "service_definitions_packages" {
  source   = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v7.9.1"
  for_each = local.service_definitions_packages_enabled

  nrn                 = var.nrn
  repository_org      = try(each.value.repository_org, null)
  repository_name     = try(each.value.repository_name, null)
  repository_branch   = each.value.repository_branch
  repository_ref_type = each.value.repository_ref_type
  repository_token    = var.github_token
  service_path        = try(each.value.install_path, each.value.service_path)
  service_name        = each.value.service_name
  available_links     = each.value.available_links
  dimensions          = try(each.value.dimensions, {})

  git_provider     = try(each.value.git_provider, "github")
  local_specs_path = try(each.value.local_specs_path, null)

  package = {
    version = coalesce(try(each.value.package_version, null), each.value.repository_branch)
    default = true

    artifacts = [
      {
        name   = each.value.service_name
        type   = "git_repository"
        lookup = each.value.package_artifact_lookup
        meta = {
          url       = "https://github.com/${each.value.repository_org}/${each.value.repository_name}"
          reference = each.value.repository_branch
        }
      }
    ]
  }
}
