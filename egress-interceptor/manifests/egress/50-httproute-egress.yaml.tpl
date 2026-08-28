{{- /*
Una route por regla declarada. Es el reparto de SALIDA: toma el tráfico que la app manda al nombre
del servicio y lo parte entre EKS y OpenShift.

`percent` es SIEMPRE el porcentaje que va a EKS, no "al sustrato opuesto al que llama". Es lo que
declara el dev y lo que dice el form, y no cambia de significado según dónde corra el que llama:
migrar es mover tráfico hacia EKS, en una sola dirección.

Traducir eso a los dos backendRefs depende del origen, porque "el peer" es cada vez uno distinto:

  origen OpenShift → el peer ES EKS        → al peer va percent
  origen EKS       → el peer es OpenShift  → al peer va 100 - percent

`$to_peer` hace esa traducción una sola vez, y de ahí para abajo el template no vuelve a razonar
sobre orígenes: reparte entre peer y local.
*/ -}}
{{- range .interceptions }}
{{- $svc := .service_name -}}
{{- $pct := conv.ToInt .percent -}}
{{- $to_peer := $pct -}}
{{- if eq $.origin "EKS" }}{{ $to_peer = math.Sub 100 $pct }}{{ end -}}
{{- $fqdn := .scope_fqdn }}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ printf "%s-%s" $.gateway_name $svc | quote }}
  namespace: {{ $.namespace | quote }}
  labels:
    {{ $.managed_label }}: "true"
    nullplatform: "true"
spec:
  parentRefs:
    - name: {{ $.gateway_name | quote }}
      sectionName: mesh-internal
  hostnames:
    - {{ $svc | quote }}
    - {{ printf "%s.%s" $svc $.namespace | quote }}
    - {{ printf "%s.%s.svc" $svc $.namespace | quote }}
    - {{ printf "%s.%s.svc.cluster.local" $svc $.namespace | quote }}
  rules:
    # Los filtros van a nivel de regla: Gateway API no los soporta por backendRef cuando hay más
    # de un backend (istio#39136).
    - filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-NP-Origin
                value: {{ $.origin | quote }}
              # Lo migrado corre siempre en el sustrato opuesto al origen, y el ingreso de allá
              # matchea por el nombre con que ese sustrato identifica al destino: EKS lo conoce
              # por el FQDN de su scope, OpenShift por el nombre de su Service.
{{- if eq $.origin "EKS" }}
              - name: X-NP-SVC
                value: {{ $svc | quote }}
{{- else }}
              - name: X-NP-Scope
                value: {{ $fqdn | quote }}
{{- end }}
        # El Host es lo que hace que el HTTPRoute del scope tome el request. Es lo único que no
        # se puede resolver con headers: ese route matchea por hostname, y es el que lleva los
        # pesos del blue/green y el nombre del backend de turno. Entrar por ahí es lo que evita
        # que el service tenga que actualizarse en cada despliegue.
        #
        # Va a nivel de REGLA porque Gateway API no soporta filtros por backendRef con más de un
        # backend (istio#39136). En la rama que va a un Service el Host es inerte: Envoy rutea
        # por cluster, no por Host.
        - type: URLRewrite
          urlRewrite:
            hostname: {{ $fqdn | quote }}
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              - name: X-Egress-Gateway
                value: {{ printf "%s.%s" $.gateway_name $.namespace | quote }}
      backendRefs:
{{- if gt $to_peer 0 }}
        # La rama migrada sale SIEMPRE por el ingreso del sustrato opuesto, nunca directo al
        # destino: es ahí donde se valida la identidad.
        # `kind: Hostname` referencia un host del registro de Istio, no un Service: evita un
        # ReferenceGrant en el namespace del destino.
        - group: networking.istio.io
          kind: Hostname
          name: {{ $.peer_gateway_host | quote }}
          port: 443
          weight: {{ $to_peer }}
{{- end }}
{{- if lt $to_peer 100 }}
{{- if eq $.origin "EKS" }}
        # Al Gateway de ingreso de este cluster, NO al FQDN del scope: un backendRef necesita un
        # host del registro de Istio, y el FQDN de un scope sólo existe como `hostnames` de un
        # HTTPRoute — eso hace que el Gateway lo ATIENDA, no que un Envoy pueda conectarse ahí.
        # El Host reescrito arriba es lo que hace que del otro lado lo tome el route del scope.
        - group: networking.istio.io
          kind: Hostname
          name: {{ $.local_ingress_host | quote }}
          port: 443
          weight: {{ math.Sub 100 $to_peer }}
{{- else }}
        # En OpenShift el este-oeste sí queda: el clon del Service original.
        - name: {{ printf "%s-local" $svc | quote }}
          port: {{ $.listen_port | conv.ToInt }}
          weight: {{ math.Sub 100 $to_peer }}
{{- end }}
{{- end }}
{{- end }}
