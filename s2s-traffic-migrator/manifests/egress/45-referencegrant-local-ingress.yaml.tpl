{{- if and .interceptions (eq .platform "eks") }}
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: {{ printf "%s-to-%s" .namespace .local_ingress_service | quote }}
  namespace: {{ .local_ingress_service_namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    nullplatform: "true"
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: {{ .namespace | quote }}
  to:
    - group: ""
      kind: Service
      name: {{ .local_ingress_service | quote }}
{{- end }}
