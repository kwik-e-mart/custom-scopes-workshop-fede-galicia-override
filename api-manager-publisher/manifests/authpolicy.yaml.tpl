apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: {{ printf "%s-%s" .api_id .route | quote }}
  namespace: {{ .namespace | quote }}
  labels:
    app.kubernetes.io/managed-by: api-manager-publisher
    api-id: {{ .api_id | quote }}
    scope_id: {{ .scope_id | quote }}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: {{ .route | quote }}
  defaults:
    strategy: merge
    rules:
      authentication:
        {{ .api_id | quote }}:
          apiKey:
            selector:
              matchLabels:
                api-id: {{ .api_id | quote }}
            allNamespaces: true
          credentials:
            customHeader:
              name: app_key
      authorization:
        {{ printf "%s-app-id" .api_id | quote }}:
          when:
            - predicate: has(request.headers.app_key)
          patternMatching:
            patterns:
              - predicate: auth.identity.metadata.labels['app-id'] == request.headers.app_id
