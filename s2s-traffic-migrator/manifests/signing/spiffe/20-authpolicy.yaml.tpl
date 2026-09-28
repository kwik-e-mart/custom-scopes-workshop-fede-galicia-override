{{- $gw := .gateway_name -}}
{{- $ns := .namespace -}}
apiVersion: {{ .authpolicy_api_version | quote }}
kind: AuthPolicy
metadata:
  name: {{ $gw | quote }}
  namespace: {{ $ns | quote }}
  labels:
    {{ .managed_label }}: "true"
    nullplatform: "true"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: {{ $gw | quote }}
  rules:
    authentication:
      "workload-del-namespace":
        anonymous: {}
    metadata:
      "vault_mint":
        http:
          url: {{ printf "%s/v1/%s/role/%s/mintjwt" .vault_addr .vault_spiffe_mount .vault_spiffe_role | quote }}
          method: POST
{{- if .vault_namespace }}
          headers:
            "X-Vault-Namespace":
              value: {{ .vault_namespace | quote }}
{{- end }}
          sharedSecretRef:
            name: {{ .vault_token_secret | quote }}
            key: client_token
          credentials:
            customHeader:
              name: "X-Vault-Token"
          # Sin esto Authorino manda form-urlencoded y Vault responde sin `data`, como un token vencido.
          contentType: application/json
          body:
            expression: '{{ printf "%q" (dict "audience" .peer_gateway_host | data.ToJSON) }}'
        cache:
          key:
            expression: '{{ printf "%q" .vault_spiffe_role }}'
          ttl: 250
    authorization:
      "vault_mint_check":
        patternMatching:
          patterns:
            # `has(a.b.c)` propaga el error si falta `b`; el `&&` de CEL lo absorbe y rinde un deny limpio.
            - predicate: >-
                has(auth.metadata.vault_mint) &&
                has(auth.metadata.vault_mint.data) &&
                has(auth.metadata.vault_mint.data.token)
    response:
      unauthorized:
        message:
          value: "no se pudo acuñar el token de egreso: el emisor no devolvió uno"
      success:
        headers:
          "x-np-token":
            plain:
              expression: 'auth.metadata.vault_mint.data.token'
