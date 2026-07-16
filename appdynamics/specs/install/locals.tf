locals {
  config = jsondecode(data.external.appdynamics_spec.result.json)

  # Computed in HCL rather than read from the template's visible_to field (see data.tf).
  spec_visible_to = [var.nrn]
}
