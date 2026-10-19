variable "np_api_key" {
  type        = string
  sensitive   = true
  description = "API key con la que el provider de nullplatform registra el service y los channels."
}

variable "nrn" {
  type        = string
  description = "NRN (organization=...:account=...) dueño del service."
}

variable "tags_selectors" {
  type        = map(string)
  description = "Selector de tags del agente que atiende este service; ese agente tiene que tener API_SUBSCRIBER_URL y API_SUBSCRIBER_TOKEN."
}

variable "repository_service_spec_repo" {
  type        = string
  default     = "galicia-integrations/terraform_np_installation"
  description = "Repo que clona el agente."
}

variable "service_path" {
  type        = string
  default     = "galicia-deployment-override/api-manager-ocp-subscriber"
  description = "Ruta del service dentro del repo que clona el agente."
}

variable "base_clone_path" {
  type        = string
  default     = "/home/agent/.np"
  description = "Ruta donde el agente clona el repo."
}

variable "extra_visible_to_nrns" {
  type        = list(string)
  default     = []
  description = "NRNs adicionales que tienen que ver el service specification."
}
