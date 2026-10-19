{{- define "apim-mock.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "apim-mock.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "apim-mock.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "apim-mock.npSecretName" -}}
{{- if .Values.npApiKey.existingSecret -}}
{{- .Values.npApiKey.existingSecret -}}
{{- else -}}
{{- include "apim-mock.fullname" . -}}
{{- end -}}
{{- end -}}
