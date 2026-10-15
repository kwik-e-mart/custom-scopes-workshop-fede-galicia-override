variable "np_api_key" {
  type        = string
  sensitive   = true
  description = "API key con la que el provider de nullplatform crea el hook y el channel."
}

variable "nrn" {
  type        = string
  description = "NRN (organization=...:account=...) donde se registran el hook y el channel."
}

variable "tags_selectors" {
  type        = map(string)
  description = "Selector de tags que decide qué agente atiende las notificaciones."
}

variable "hook_dimensions" {
  type        = map(string)
  default     = {}
  description = "Dimensiones que acotan sobre qué deployments dispara el hook."
}

variable "deployment_statuses" {
  type        = list(string)
  default     = ["finalized", "rolled_back", "failed"]
  description = "Estados del deployment que el channel deja pasar al agente."
}

variable "repository" {
  type        = string
  default     = "galicia-integrations/terraform_np_installation"
  description = "Repo que clona el agente; se usa para armar la ruta del entrypoint."
}

variable "base_clone_path" {
  type        = string
  default     = "/home/agent/.np"
  description = "Ruta donde el agente clona el repo."
}

variable "entrypoint_path" {
  type        = string
  default     = "galicia-deployment-override/catalog/deployment/entrypoint"
  description = "Ruta del entrypoint dentro del repo."
}
