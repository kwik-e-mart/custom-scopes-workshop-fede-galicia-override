# Prerequisitos de cluster del Egress Interceptor.
#
# Este layer NO instala el service: instala lo que el service da por hecho que ya existe en cada
# cluster donde va a correr. El registro del service está en `../install/`.
#
# Es un EJEMPLO de referencia. Las versiones están pineadas a las que se validaron en la PoC; el
# cluster destino puede tener otras, y varias piezas —el CNI, el ingress controller, la política de
# red— dependen de decisiones que no toma este archivo.

###############################################################################
# Gateway API
###############################################################################

# Prerequisito de Istio y de Kuadrant. OpenShift los trae de fábrica; EKS no, por eso el toggle.
# Instalarlos dos veces sobre un cluster que ya los gestiona genera drift con el operator que los
# tiene a cargo, así que el default es NO tocarlos.
data "http" "gateway_api_crds" {
  count = var.manage_gateway_api_crds ? 1 : 0
  url   = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml"
}

resource "kubectl_manifest" "gateway_api_crds" {
  # El documento 0 del YAML upstream es el header de licencia Apache: tiene contenido, así que
  # `trimspace(doc) != ""` no lo descarta, y kubectl_manifest falla con "Object 'Kind' is missing".
  # Se filtra por la presencia real de un `kind:`.
  for_each = var.manage_gateway_api_crds ? {
    for i, doc in split("---", data.http.gateway_api_crds[0].response_body) : i => doc
    if can(regex("(?m)^kind:", doc))
  } : {}

  yaml_body = each.value
}

###############################################################################
# Kuadrant
###############################################################################

resource "helm_release" "kuadrant_operator" {
  name = "kuadrant-operator"

  # `repository` explícito y no un alias: sin esto, `chart` sólo resuelve si el alias de repo Helm
  # ya está registrado en la máquina que corre el apply (`~/.config/helm`). Anda en la laptop de
  # quien hizo `helm repo add` y rompe en cualquier otra máquina y en CI.
  repository = "https://kuadrant.io/helm-charts/"
  chart      = var.kuadrant_chart
  version    = var.kuadrant_chart_version

  namespace        = var.kuadrant_namespace
  create_namespace = true
  wait             = true

  depends_on = [kubectl_manifest.gateway_api_crds]
}

# El operator instala los CRDs; el CR `Kuadrant` es el que efectivamente levanta Authorino y el
# Limitador. Sin él las AuthPolicy quedan aceptadas y nunca enforceadas — un modo de fallo callado:
# los objetos se ven en verde y el tráfico pasa sin validar.
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
