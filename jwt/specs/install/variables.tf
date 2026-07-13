variable "np_api_key" {
  type        = string
  sensitive   = true
  description = "API key used by the nullplatform provider to create the specs and channel."
}

variable "nrn" {
  type        = string
  description = "Nullplatform Resource Name (organization=...:account=... format) that owns the specs."
}

variable "agent_api_key" {
  type        = string
  sensitive   = true
  description = "API key baked into the notification channel so the agent can call back to the platform."
}

variable "tags_selectors" {
  type        = map(string)
  description = "Tag selectors used to pick which agent(s) handle this service's notifications."
}

variable "repository_service_spec_repo" {
  type        = string
  default     = "custom-scopes-workshop-fede-galicia-override"
  description = "Repository name the agent clones; used to build the entrypoint cmdline path."
}

variable "service_path" {
  type        = string
  default     = "jwt"
  description = "Path to the service directory within the repository."
}

variable "extra_visible_to_nrns" {
  type        = list(string)
  default     = []
  description = "Additional NRNs that should see the service specification."
}
