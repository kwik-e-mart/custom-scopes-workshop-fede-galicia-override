apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: np-agent }
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "pods"]
    verbs: ["get", "list"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways", "httproutes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["kuadrant.io"]
    resources: ["authpolicies"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.istio.io"]
    resources: ["destinationrules"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: np-agent }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: np-agent }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
{{/*
# ALTERNATIVA: lista explícita de namespaces, sin ClusterRoleBinding.

# Para activarla: borrar el ClusterRoleBinding de arriba, sacar las dos líneas que abren y cierran
# este comentario, y rendear con TARGET_NAMESPACES:

#   TARGET_NAMESPACES=payments,imagenes,gateways KEYS_NAMESPACE=kuadrant-system \
#   AGENT_SA=np-agent AGENT_NAMESPACE=nullplatform-tools \
#     gomplate -f rbac/np-agent-rbac-gitops.yaml.tpl | kubectl apply -f -

# El ClusterRole np-agent de arriba NO se toca: un ClusterRole es sólo una definición de reglas y no
# otorga nada hasta que algo lo bindea. Un RoleBinding namespaced puede referenciar un ClusterRole, y
# entonces esas reglas valen únicamente dentro de ese namespace.

# TARGET_NAMESPACES tiene que incluir GATEWAY_NAMESPACE (`gateways`): ahí viven las HTTPRoute de
# ingreso cuyo status espera el s2s-traffic-migrator.

# El ClusterRole np-agent-httproutes-read de abajo NO es opcional y no se puede reemplazar por
# RoleBindings: la detección de colisiones hace `kubectl get httproutes -A`, que es un LIST de alcance
# cluster, y un RoleBinding no puede autorizar eso por más namespaces que se listen.

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: np-agent-httproutes-read }
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: np-agent-httproutes-read }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: np-agent-httproutes-read }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
{{- range (getenv "TARGET_NAMESPACES" | strings.Split ",") }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: np-agent, namespace: {{ . | strings.TrimSpace }} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: np-agent }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
{{- end }}
*/}}
---
# La api key se emite por link y se devuelve en el resultado de la acción: no puede publicarse en el
# repo gitops. Es la única escritura que sobrevive en este modo.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: np-agent-keys, namespace: {{ getenv "KEYS_NAMESPACE" }} }
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: np-agent-keys, namespace: {{ getenv "KEYS_NAMESPACE" }} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: np-agent-keys }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
