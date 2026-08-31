apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: api-manager, namespace: {{ getenv "NAMESPACE" }} }
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  - apiGroups: ["kuadrant.io"]
    resources: ["authpolicies"]
    verbs: ["get", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: api-manager, namespace: {{ getenv "NAMESPACE" }} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: api-manager }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: api-manager-keys, namespace: {{ getenv "KEYS_NAMESPACE" }} }
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: api-manager-keys, namespace: {{ getenv "KEYS_NAMESPACE" }} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: api-manager-keys }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: api-manager-httproutes-read }
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: api-manager-httproutes-read }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: api-manager-httproutes-read }
subjects:
  - { kind: ServiceAccount, name: {{ getenv "AGENT_SA" }}, namespace: {{ getenv "AGENT_NAMESPACE" }} }
