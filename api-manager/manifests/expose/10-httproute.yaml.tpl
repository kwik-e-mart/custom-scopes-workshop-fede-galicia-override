apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .route_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    {{ .target_label }}: {{ .app_target | quote }}
    {{ .app_label }}: {{ .app_label_value | quote }}
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
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: {{ .backend | quote }}
      backendRefs:
        - group: networking.istio.io
          kind: Hostname
          name: {{ index $ "local_ingress_host" | quote }}
          port: 443
{{- end }}
