variable "kubeconfig_path" {
  type        = string
  description = "Ruta al kubeconfig del cluster donde se instalan los prerequisitos."
}

variable "kube_context" {
  type        = string
  description = "Contexto dentro de ese kubeconfig. Explícito a propósito: no se usa el current-context."
}

variable "manage_gateway_api_crds" {
  type        = bool
  default     = false
  description = "Instalar los CRDs de Gateway API desde upstream. OpenShift ya los trae y los gestiona su propio operator, así que ahí tiene que quedar en false; en EKS suele hacer falta ponerlo en true."
}

variable "gateway_api_version" {
  type        = string
  default     = "v1.3.0"
  description = "Tag de release de kubernetes-sigs/gateway-api para el standard-install.yaml. Sólo se usa si manage_gateway_api_crds = true."
}

variable "kuadrant_chart" {
  type        = string
  default     = "kuadrant-operator"
  description = "Nombre del chart, sin prefijo de alias de repo: el repository va explícito en main.tf."
}

variable "kuadrant_chart_version" {
  type        = string
  default     = "1.5.2"
  description = "Versión del chart kuadrant-operator. La 1.5.2 es la validada en la PoC, incluida la verificación de que las imágenes tienen build arm64."
}

variable "kuadrant_namespace" {
  type        = string
  default     = "kuadrant-system"
  description = "Namespace del operator. NO es arbitrario: Kuadrant traduce toda AuthPolicy a un AuthConfig en este namespace, y Authorino resuelve las claves de firma contra él. Cambiarlo obliga a mover también los Secrets de firma."
}
