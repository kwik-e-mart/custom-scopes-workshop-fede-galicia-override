{{- /*
Sólo con origen OpenShift, y en el namespace del Gateway de INGRESO, no en el de la app.
Es la contracara de 50-: lo que EKS manda para acá tiene que encontrar por dónde entrar.

Lo declara el service y no el layer porque su backend es el alias `<svc>-local`, que también es
del service: si el layer lo declarara sin que exista una intercepción, el backendRef no
resolvería y —peor— el Gateway se quedaría sin ninguna route, con lo que Kuadrant deja de
enforcear en silencio (Gotcha #22).

En EKS no hay equivalente: allá el destino se alcanza por el HTTPRoute del propio scope, que ya
cuelga de ese Gateway.
*/ -}}
{{- if ne .platform "eks" }}
{{- range .interceptions }}
{{- $svc := .service_name }}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ printf "s2s-ingress-%s" $svc | quote }}
  namespace: {{ $.gateway_namespace | quote }}
  labels:
    {{ $.managed_label }}: "true"
    nullplatform: "true"
spec:
  parentRefs:
    - name: s2s-ingress
      namespace: {{ $.gateway_namespace | quote }}
  rules:
    - matches:
        - headers:
            - type: Exact
              name: X-NP-SVC
              value: {{ $svc | quote }}
      filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              # Sella el hop de ENTRADA: es lo que permite, del lado del que llamó, distinguir
              # que el request cruzó de verdad.
              - name: X-Egress-Route
                value: inbound
              - name: X-Egress-Target
                value: {{ printf "%s-local.%s.svc.cluster.local" $svc $.namespace | quote }}
              - name: X-S2S-Cluster
                value: {{ $.cluster_label | quote }}
      # Al alias y NO al Service <svc>: ése está hijackeado y apunta al Gateway de EGRESO, así
      # que entregarle el tráfico de entrada lo mandaría de vuelta a salir.
      backendRefs:
        - name: {{ printf "%s-local" $svc | quote }}
          namespace: {{ $.namespace | quote }}
          port: {{ $.listen_port | conv.ToInt }}
{{- end }}
{{- end }}
