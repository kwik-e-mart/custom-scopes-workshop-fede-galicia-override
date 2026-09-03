{{- if .interceptions }}
# Cómo se origina el TLS hacia el ingreso del sustrato OPUESTO. Sólo hace falta si hay alguna
# regla: sin intercepciones no sale tráfico por acá.
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: {{ printf "%s-peer" .gateway_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    nullplatform: "true"
spec:
  # El ingreso del sustrato opuesto. Es UNO para todas las reglas: la dirección la conoce el
  # service por configuración, no la declara el dev en cada regla.
  host: {{ .peer_gateway_host | quote }}
  # Sin exportTo la regla es visible en toda la malla y cualquier namespace originaría TLS con
  # la CA de éste.
  exportTo:
    - "."
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 64
      http:
        http1MaxPendingRequests: 64
        # Por debajo del idle timeout del balanceador del destino (350 s en un NLB de AWS, no
        # configurable). Sin pool aparecen 503 URX,UF bajo concurrencia con RTT real.
        idleTimeout: 300s
    tls:
      mode: SIMPLE
      # El Gateway no puede montar volúmenes (su podTemplate lo genera Istio), así que
      # caCertificates con una ruta de archivo no es opción.
      credentialName: {{ .peer_ca_secret | quote }}
      sni: {{ .peer_gateway_host | quote }}
{{- end }}
