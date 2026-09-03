apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: egress-interceptor, namespace: {{ getenv "NAMESPACE" }} }
rules:
  # El hijack del Service y el alias <svc>-local.
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  # El guardarraíl de percent<100 mira si el destino local tiene endpoints antes de repartir.
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list"]
  # Sólo lectura: el Deployment del data plane lo crea y lo posee el controller de Istio a
  # partir del Gateway. El reconcile únicamente espera a que esté listo.
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways", "httproutes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["kuadrant.io"]
    resources: ["authpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.istio.io"]
    resources: ["destinationrules"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
# Sin permisos sobre Secrets: la clave de firma vive en kuadrant-system y la referencia la
# AuthPolicy por nombre. El agente no la lee nunca — no tiene por qué poder.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: egress-interceptor, namespace: {{ getenv "NAMESPACE" }} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: egress-interceptor }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
---
# El ingreso de OpenShift: su HTTPRoute vive en el namespace del Gateway, no en el de la app.
# Sólo httproutes, y sólo ahí: el Gateway y la AuthPolicy son del layer.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: egress-interceptor-ingress, namespace: {{ getenv "GATEWAY_NAMESPACE" }} }
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Sólo lectura: la AuthPolicy del ingreso es del layer, el service no la toca. Los verbos son los
  # que necesita `kubectl wait` para esperar a que quede Enforced tras colgarle su route.
  - apiGroups: ["kuadrant.io"]
    resources: ["authpolicies"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: egress-interceptor-ingress, namespace: {{ getenv "GATEWAY_NAMESPACE" }} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: egress-interceptor-ingress }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
