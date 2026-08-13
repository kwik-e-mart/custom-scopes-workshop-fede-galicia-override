variable "nrn" {
  description = "NRN where the provider specification is anchored (the top-level scope it belongs to)."
  type        = string
}

variable "np_api_key" {
  description = "nullplatform API key used to configure the provider and register the AppDynamics provider specification."
  type        = string
  sensitive   = true
}

variable "instances" {
  description = <<-EOT
    AppDynamics provider configurations to create, keyed by a stable identifier
    (used in for_each). Each entry anchors at its own NRN, with its own dimensions
    and an `attributes` object matching the provider specification schema:
      { global = { variables = [{ name, type, value }, ...] },
        python = { variables = [...] },   # optional
        node   = { variables = [...] },   # optional
        java   = { variables = [...] },   # optional
        dotnet = { variables = [...] } }  # optional
    Only `global` is required. `attributes` is typed as `any` so callers write the
    object directly; it is JSON-encoded when sent to the provider.
  EOT
  type = map(object({
    nrn        = string
    dimensions = optional(map(string), {})
    attributes = any
  }))
  default = {}
}
