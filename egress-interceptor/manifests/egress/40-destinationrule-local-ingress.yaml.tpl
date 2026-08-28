{{- if and .interceptions (eq .origin "EKS") }}
# Sólo con origen EKS. Allá la rama NO migrada tampoco va a un Service del destino: entra por el
# ingreso de este mismo cluster, así que también necesita originar TLS.
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: {{ printf "%s-local-ingress" .gateway_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    nullplatform: "true"
spec:
  # El ingreso de ESTE cluster. Con origen EKS la rama no migrada tampoco va a un Service del
  # destino: entra por el Gateway para que la atienda el HTTPRoute del scope.
  host: {{ .local_ingress_host | quote }}
  exportTo:
    - "."
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 64
      http:
        http1MaxPendingRequests: 64
        idleTimeout: 300s
    tls:
      mode: SIMPLE
      # Misma CA que el peer: los certs de los dos clusters los firma la misma raíz de la PoC.
      credentialName: {{ .peer_ca_secret | quote }}
      sni: {{ .local_ingress_host | quote }}
{{- end }}
