# Los dos providers apuntan al MISMO cluster. Se configuran por kubeconfig explícito y no por el
# current-context: con dos clusters en juego, un `use-context` en otra terminal mandaría el apply
# al cluster equivocado sin que nada avise.

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = var.kube_context
  load_config_file = true
}
