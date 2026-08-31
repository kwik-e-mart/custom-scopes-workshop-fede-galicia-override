data "http" "gateway_api_crds" {
  count = var.manage_gateway_api_crds ? 1 : 0
  url   = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml"
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each = var.manage_gateway_api_crds ? {
    for i, doc in split("---", data.http.gateway_api_crds[0].response_body) : i => doc
    if can(regex("(?m)^kind:", doc))
  } : {}

  yaml_body = each.value
}

resource "helm_release" "kuadrant_operator" {
  name = "kuadrant-operator"

  repository = "https://kuadrant.io/helm-charts/"
  chart      = var.kuadrant_chart
  version    = var.kuadrant_chart_version

  namespace        = var.kuadrant_namespace
  create_namespace = true
  wait             = true

  depends_on = [kubectl_manifest.gateway_api_crds]
}

resource "kubectl_manifest" "kuadrant" {
  yaml_body = yamlencode({
    apiVersion = "kuadrant.io/v1beta1"
    kind       = "Kuadrant"
    metadata = {
      name      = "kuadrant"
      namespace = var.kuadrant_namespace
    }
    spec = {}
  })

  depends_on = [helm_release.kuadrant_operator]
}
