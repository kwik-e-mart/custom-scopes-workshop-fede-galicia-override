apiVersion: {{ .authpolicy_api_version | quote }}
kind: AuthPolicy
metadata:
  name: {{ .route_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    nullplatform: "true"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: {{ .route_name | quote }}
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
      "allowed-target":
        patternMatching:
          patterns:
            - selector: {{ printf "auth.identity.metadata.labels.%s" .target_label }}
              operator: eq
              value: {{ .app_target | quote }}
    response:
      success: {}
