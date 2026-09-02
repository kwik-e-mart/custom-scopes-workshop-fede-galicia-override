{{- $ns := .namespace -}}
apiVersion: {{ .authpolicy_api_version | quote }}
kind: AuthPolicy
metadata:
  name: {{ .route_name | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    {{ .managed_label }}: "true"
    {{ .target_label }}: {{ .app_target | quote }}
    {{ .app_label }}: {{ .app_label_value | quote }}
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
      success:
        headers:
          "x-np-token":
            wristband:
              issuer: {{ $ns | quote }}
              tokenDuration: {{ .token_duration | conv.ToInt }}
              customClaims:
                "ns":
                  value: {{ $ns | quote }}
              signingKeyRefs:
                - name: {{ .wristband_secret | quote }}
                  algorithm: RS256
