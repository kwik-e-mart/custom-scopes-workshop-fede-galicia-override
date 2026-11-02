{{- if ne .platform "eks" }}
{{- $destinos := dict }}
{{- range .interceptions }}
{{- $destinos = merge (dict .scope_fqdn .service_name) $destinos }}
{{- end }}
{{- range $fqdn, $svc := $destinos }}
---
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: {{ printf "%s-peer-%s" $.gateway_name $svc | quote }}
  namespace: {{ $.namespace | quote }}
  labels:
    {{ $.managed_label }}: "true"
    nullplatform: "true"
spec:
  hosts:
    - {{ $fqdn | quote }}
  exportTo:
    - "."
  location: MESH_EXTERNAL
  resolution: DNS
  endpoints:
    - address: {{ $.peer_gateway_host | quote }}
  ports:
    - number: 443
      name: http-for-tls-origination
      protocol: HTTP
{{- end }}
{{- end }}
