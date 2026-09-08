{{- if ne .platform "eks" }}
{{- range .interceptions }}
{{- if .original.ports }}
{{- $svc := .service_name }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ printf "%s-local" $svc | quote }}
  namespace: {{ $.namespace | quote }}
  labels:
    {{ $.managed_label }}: "true"
    {{ $.role_label }}: local-alias
    nullplatform: "true"
spec:
  selector:
{{ .original.selector | data.ToYAML | strings.Indent 4 | strings.TrimSuffix "\n" }}
  ports:
{{ .original.ports | data.ToYAML | strings.Indent 4 | strings.TrimSuffix "\n" }}
{{- end }}
{{- end }}
{{- end }}
