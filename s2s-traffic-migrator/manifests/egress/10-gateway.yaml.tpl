{{- $ns := .namespace -}}
# El data plane del egreso. Istio lo auto-provisiona a partir de este objeto: no hay Deployment
# nuestro en el camino del dato.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: {{ .gateway_name | quote }}
  namespace: {{ $ns | quote }}
  labels:
    kuadrant.io/gateway: "true"
    {{ .managed_label }}: "true"
    nullplatform: "true"
  annotations:
    # Sin esto el controller crea un Service LoadBalancer y este Gateway —que autentica con
    # `anonymous`— queda alcanzable desde fuera: cualquiera se lleva un JWT firmado.
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: {{ .gateway_class | quote }}
  listeners:
    - name: mesh-internal
      protocol: HTTP
      port: {{ .listen_port | conv.ToInt }}
      allowedRoutes:
        namespaces:
          from: Same
