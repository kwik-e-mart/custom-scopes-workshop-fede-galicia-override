{{- $ns := .namespace -}}
{{- $raiz := . -}}
{{- /*
Una AuthPolicy por HTTPRoute de destino, no una por Gateway.

A nivel Gateway, una policy con `rules` y sin bloque `defaults` la heredan TODAS las routes
colgadas de ese Gateway, incluidas las de negocio de otros namespaces: empiezan a exigir el
wristband y devuelven 401. El Gateway de ingreso lo comparten otras aplicaciones y no es nuestro.

Kuadrant compila igual una policy de Gateway a un actionSet por route, así que en el data plane
las dos formas pesan lo mismo; lo que cambia es cuántas routes quedan alcanzadas.

La regla del peer se omite si no hay JWKS del otro sustrato configurado. Authorino falla CERRADO
para el request entero cuando no puede bajar el JWKS de UNA de sus reglas, así que un peer apagado
—o que todavía no existe— dejaría al destino sin poder recibir tráfico local.

El `when` sobre el `iss` no es decorativo: Authorino evalúa TODAS las reglas de authorization en
AND, así que sin él un token tendría que cumplir también el `src_namespace` de los otros orígenes
y nunca pasaría.
*/ -}}
{{- range .interceptions }}
{{- $ruta := index . "ingress_route" | default "" }}
{{- if $ruta }}
---
apiVersion: {{ $raiz.authpolicy_api_version | quote }}
kind: AuthPolicy
metadata:
  name: {{ printf "%s-%s" $raiz.ingress_authpolicy $ruta | quote }}
  namespace: {{ $ns | quote }}
  labels:
    {{ $raiz.managed_label }}: "true"
    nullplatform: "true"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: {{ $ruta | quote }}
  defaults:
    strategy: merge
    rules:
      authentication:
        "local-{{ $ns }}":
          jwt:
            jwksUrl: {{ $raiz.local_jwks_url | quote }}
            ttl: {{ $raiz.token_duration | conv.ToInt }}
          credentials:
            customHeader:
              name: x-egress-token
{{- if $raiz.peer_jwks_url }}
        "peer-{{ $ns }}":
          jwt:
            jwksUrl: {{ $raiz.peer_jwks_url | quote }}
            ttl: {{ $raiz.token_duration | conv.ToInt }}
          credentials:
            customHeader:
              name: x-egress-token
{{- end }}
      authorization:
        "claims-{{ $ns }}":
          when:
            - predicate: auth.identity.iss == {{ $raiz.egress_issuer | quote }}
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
{{- end }}
{{- end }}
