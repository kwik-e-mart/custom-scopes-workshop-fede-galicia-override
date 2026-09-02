apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .catchall_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    {{ .catchall_label }}: "true"
    nullplatform: "true"
spec:
  parentRefs:
    - name: {{ .gateway_name | quote }}
      namespace: {{ .gateway_namespace | quote }}
  hostnames:
    - {{ .host | quote }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
---
apiVersion: {{ .authpolicy_api_version | quote }}
kind: AuthPolicy
metadata:
  name: {{ .catchall_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    {{ .catchall_label }}: "true"
    nullplatform: "true"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: {{ .catchall_name | quote }}
  rules:
    authentication:
      "consumer-key":
        apiKey:
          selector:
            matchLabels:
              {{ .managed_label }}: "true"
        credentials:
          customHeader:
            name: {{ .api_key_header | quote }}
    authorization:
      "deny-all":
        patternMatching:
          patterns:
            - selector: "context.request.http.method"
              operator: eq
              value: "__api-manager-nunca-matchea__"
