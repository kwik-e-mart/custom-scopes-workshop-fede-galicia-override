{{- range .interceptions }}
{{- $svc := .service_name }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $svc | quote }}
  namespace: {{ $.namespace | quote }}
{{- if .original.ports }}
  annotations:
    {{ $.original_selector_annotation }}: {{ .original.selector | data.ToJSON | quote }}
{{- else }}
  labels:
    {{ $.managed_label }}: "true"
    {{ $.role_label }}: gateway-service
    nullplatform: "true"
{{- end }}
spec:
  selector:
    gateway.networking.k8s.io/gateway-name: {{ $.gateway_name | quote }}
  ports:
{{- if .original.ports }}
{{ .original.ports | data.ToYAML | strings.Indent 4 | strings.TrimSuffix "\n" }}
{{- else }}
    - name: http
      port: {{ $.listen_port | conv.ToInt }}
      targetPort: {{ $.listen_port | conv.ToInt }}
{{- end }}
{{- end }}
