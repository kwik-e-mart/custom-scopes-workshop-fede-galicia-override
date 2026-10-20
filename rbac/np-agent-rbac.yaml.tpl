apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: np-agent }
rules:
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
  # El Gateway de egreso lo crea el chart del namespace: acá sólo se espera a que quede Programmed.
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Sólo lectura: los ReferenceGrant los administra el equipo del cluster. El service verifica que
  # exista el que habilita su backendRef cross-namespace y aborta si falta.
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["referencegrants"]
    verbs: ["get", "list"]
  - apiGroups: ["kuadrant.io"]
    resources: ["authpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.istio.io"]
    resources: ["destinationrules"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Lectura y nada más: estos objetos son del chart del namespace. El service los mira para no
  # reaplicar encima de lo que el chart ya creó, y necesita distinguir "no está" de "no puedo ver".
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list"]
  - apiGroups: ["external-secrets.io"]
    resources: ["externalsecrets"]
    verbs: ["get", "list"]

{{/*
# SÓLO para NAMESPACE_SETUP_ENABLED=true, el modo con el que el service crea el alta del namespace
# que normalmente hace el chart. Es excepcional: se usa en un namespace donde el chart no corrió o
# quedó a medias. Mientras el flag esté en false estos permisos NO hacen falta, y por eso no están
# en el ClusterRole de arriba.

  - apiGroups: [""]
    resources: ["serviceaccounts", "configmaps"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["create", "delete"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  - apiGroups: ["external-secrets.io"]
    resources: ["externalsecrets"]
    verbs: ["create", "update", "patch", "delete"]

# Y en KEYS_NAMESPACE, el Role np-agent-keys de más abajo con create/delete sobre secrets.
*/}}
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
#     gomplate -f rbac/np-agent-rbac.yaml.tpl | kubectl apply -f -

# El ClusterRole np-agent de arriba NO se toca: un ClusterRole es sólo una definición de reglas y no
# otorga nada hasta que algo lo bindea. Un RoleBinding namespaced puede referenciar un ClusterRole, y
# entonces esas reglas valen únicamente dentro de ese namespace. Las reglas se declaran una vez y lo
# que se repite es el binding.

# TARGET_NAMESPACES tiene que incluir GATEWAY_NAMESPACE (`gateways`): ahí es donde el
# s2s-traffic-migrator escribe las HTTPRoute de ingreso.

# Onboardear una app nueva pasa a requerir un RoleBinding más. Sin él, el reconcile de esa instancia
# falla con Forbidden en el primer apply.

# El ClusterRole np-agent-httproutes-read de abajo NO es opcional y no se puede reemplazar por
# RoleBindings: la detección de colisiones hace `kubectl get httproutes -A`, que es un LIST de alcance
# cluster, y un RoleBinding no puede autorizar eso por más namespaces que se listen. Es lectura sobre
# un solo recurso.

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
{{/*
# El Role np-agent-keys con create/delete sobre secrets en KEYS_NAMESPACE NO se usa: los Secrets de
# la clave de firma los crea el ExternalSecret, y el que lo declara es el SA `rotador` desde adentro
# del Job, no el agente. Se deja documentado por si el flujo cambia.

---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: np-agent-keys, namespace: KEYS_NAMESPACE }
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "delete"]
*/}}
