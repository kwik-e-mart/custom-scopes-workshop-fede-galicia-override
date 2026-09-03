{{- $gw := .gateway_name -}}
{{- $ns := .namespace -}}
# Lo que le da identidad al tráfico que sale: Authorino le cuelga a cada request un JWT firmado
# (festival wristband) con el namespace de origen. El destino valida ese token en SU ingreso.
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
                # RS256 con la clave en PKCS#1 es la única combinación que cierra: el verificador
                # está fijado a RS256 y el firmador no parsea PKCS#8. Cualquiera de las dos mal
                # deja el AuthConfig sin reconciliar y tumba el camino de la app.
                - name: {{ .wristband_secret | quote }}
                  algorithm: RS256
