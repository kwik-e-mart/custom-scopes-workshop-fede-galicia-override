variable "np_api_key" {
  type        = string
  sensitive   = true
  description = "API key con la que el provider de nullplatform crea el spec y el channel."
}

variable "nrn" {
  type        = string
  description = "Nullplatform Resource Name (organization=...:account=...) dueño del spec."
}

variable "agent_api_key" {
  type        = string
  sensitive   = true
  description = "API key que queda embebida en el notification channel para que el agente pueda responderle a la plataforma."
}

variable "tags_selectors" {
  type        = map(string)
  description = "Selector de tags que decide qué agente atiende las notificaciones de este service. Con un agente por cluster, es lo que hace que la acción caiga en el cluster correcto."
}

variable "repository_service_spec_repo" {
  type        = string
  default     = "kwik-e-mart/custom-scopes-workshop-fede-galicia-override"
  description = "Repo que clona el agente; se usa para armar la ruta del entrypoint."
}

variable "service_path" {
  type        = string
  default     = "api-manager"
  description = "Ruta del directorio del service dentro del repo."
}

variable "extra_visible_to_nrns" {
  type        = list(string)
  default     = []
  description = "NRNs adicionales que tienen que ver el service specification."
}
