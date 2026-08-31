apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .route_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    {{ .target_label }}: {{ .app_target | quote }}
    nullplatform: "true"
spec:
  parentRefs:
    - name: {{ .gateway_name | quote }}
      namespace: {{ .gateway_namespace | quote }}
  hostnames:
{{- range .hosts }}
    - {{ . | quote }}
{{- end }}
  rules:
{{- range .routes }}
{{- $path := .path }}
    - matches:
{{- range .methods }}
        - path:
            type: {{ if strings.HasSuffix "*" $path }}PathPrefix{{ else }}Exact{{ end }}
            value: {{ strings.TrimSuffix "*" $path | quote }}
          method: {{ . | quote }}
{{- end }}
      backendRefs:
        - group: networking.istio.io
          kind: Hostname
          name: {{ .backend | quote }}
          port: {{ index $ "backend_port" | default 80 }}
{{- end }}
