{{- $ns := .namespace -}}
{{- /*
Trae SOLO las reglas de este namespace. El objeto es uno por cluster —Kuadrant admite una sola
AuthPolicy por Gateway— pero su contenido es por namespace de origen, porque cada uno firma con
su propia clave y por lo tanto tiene su propio JWKS. El reconcile no lo pisa: si ya existe,
mergea estas tres claves y deja las de los demás namespaces intactas.

El `when` no es decorativo: Authorino evalúa TODAS las reglas de authorization en AND, así que
sin él el token de este namespace tendría que cumplir también el `src_namespace` de los otros y
nunca pasaría. Con el `when` sobre el `iss`, cada token evalúa únicamente su propia regla.
*/ -}}
apiVersion: {{ .authpolicy_api_version | quote }}
kind: AuthPolicy
metadata:
  name: {{ .ingress_authpolicy | quote }}
  namespace: {{ .gateway_namespace | quote }}
  labels:
    nullplatform: "true"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: {{ .ingress_gateway_name | quote }}
  rules:
    authentication:
      "local-{{ $ns }}":
        jwt:
          jwksUrl: {{ .local_jwks_url | quote }}
          ttl: {{ .token_duration | conv.ToInt }}
        credentials:
          customHeader:
            name: x-egress-token
      "peer-{{ $ns }}":
        jwt:
          jwksUrl: {{ .peer_jwks_url | quote }}
          ttl: {{ .token_duration | conv.ToInt }}
        credentials:
          customHeader:
            name: x-egress-token
    authorization:
      "claims-{{ $ns }}":
        when:
          - predicate: auth.identity.iss == {{ .egress_issuer | quote }}
        patternMatching:
          patterns:
            - predicate: auth.identity.src_namespace == {{ $ns | quote }}
    response:
      unauthenticated:
        message:
          value: "falta el token de egreso en x-egress-token, o no lo firmó ninguna clave conocida"
      unauthorized:
        message:
          value: "el token no corresponde a un namespace habilitado en este ingreso"
      success: {}
