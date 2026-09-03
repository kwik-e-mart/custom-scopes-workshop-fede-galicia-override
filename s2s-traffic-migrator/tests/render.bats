#!/usr/bin/env bats
# El render es un template de gomplate. Se ejercita como en producción: contexto JSON → gomplate.
#
# El modelo que se asserta acá: una regla declara el nombre del servicio del lado OpenShift y el
# FQDN de su scope del lado EKS. `percent` es SIEMPRE el porcentaje que va a EKS, sin importar
# desde dónde se llame. La rama que cruza de sustrato sale siempre por el ingreso del peer
# (peer_gateway_host), nunca directo al destino.

setup() {
  # En el bash 3.2 de macOS un test con varias `[[ ]]` evalúa sólo la última: la suite daría
  # verde sin probar nada.
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v gomplate >/dev/null && command -v yq >/dev/null || {
    echo "bats necesita gomplate y yq." >&2; return 1
  }
  source "${BATS_TEST_DIRNAME}/../logging"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib"
  PEER=kuadrant.peer.example.io
  LOCAL_IN=s2s-ingress-istio.gateways.svc.cluster.local
  GW_NS=gateways
  FQDN=gal-poc-reports-dev-cvbdn.galicia-poc.nullapps.io
}

# render <platform> <interceptions-json>
render() {
  jq -n --arg platform "$1" --argjson interceptions "$2" --arg peer "$PEER" --arg li "$LOCAL_IN" --arg gwns "$GW_NS" '{
    namespace:"payments", gateway_name:"s2s-egress", gateway_class:"istio",
    listen_port:8080, token_duration:300, wristband_secret:"payments-wristband-key",
    peer_ca_secret:"s2s-remote-ca", peer_gateway_host:$peer, local_ingress_host:$li, gateway_namespace:$gwns, cluster_label:"crc-openshift",
    authpolicy_api_version:"kuadrant.io/v1",
    managed_label:"egress-interceptor/managed",
    platform:$platform, interceptions:$interceptions }' > "$BATS_TEST_TMPDIR/ctx.json"
  # Como en producción: se rendea el directorio entero y se concatena. Las aserciones siguen
  # mirando el stream completo, así que lo que se asserta es lo que se termina aplicando.
  local out="$BATS_TEST_TMPDIR/out"
  rm -rf "$out"
  render_manifests "$BATS_TEST_TMPDIR/ctx.json" "$out" >"$BATS_TEST_TMPDIR/list.txt" || return 1
  # El `---` va ENTRE archivos y no antes del primero: un separador al inicio agrega un documento
  # `null` al stream que después tienen que esquivar todas las aserciones.
  local f first=1
  while IFS= read -r f; do
    [ "$first" = 1 ] && first=0 || printf -- '---\n'
    cat "$f"
  done <"$BATS_TEST_TMPDIR/list.txt"
}

# Los archivos rendeados con contenido, en orden de aplicación (sólo el basename).
rendered_files() {
  jq -n --arg platform "$1" --argjson interceptions "$2" --arg peer "$PEER" --arg li "$LOCAL_IN" --arg gwns "$GW_NS" '{
    namespace:"payments", gateway_name:"s2s-egress", gateway_class:"istio",
    listen_port:8080, token_duration:300, wristband_secret:"payments-wristband-key",
    peer_ca_secret:"s2s-remote-ca", peer_gateway_host:$peer, local_ingress_host:$li, gateway_namespace:$gwns, cluster_label:"crc-openshift",
    authpolicy_api_version:"kuadrant.io/v1",
    managed_label:"egress-interceptor/managed",
    platform:$platform, interceptions:$interceptions }' > "$BATS_TEST_TMPDIR/ctx2.json"
  local out="$BATS_TEST_TMPDIR/out2"
  rm -rf "$out"
  render_manifests "$BATS_TEST_TMPDIR/ctx2.json" "$out" | xargs -n1 basename
}

# doc <render> <kind>: el documento de ese kind, sin comentarios. Se borran a propósito: varios
# explican qué pasaría con la config equivocada (`LoadBalancer`, `insecureSkipVerify`) y una
# aserción por substring los leería como si estuvieran configurados.
doc() { echo "$1" | yq "select(.kind == \"$2\") | ... comments=\"\""; }
# Con origen EKS hay DOS DestinationRule: el del peer y el del FQDN del scope.
named() { echo "$1" | yq "select(.kind == \"$2\" and .metadata.name == \"$3\") | ... comments=\"\""; }

rule() {  # <percent> [service]
  jq -nc --arg f "$FQDN" --argjson p "$1" --arg s "${2:-reports}" \
    '[{service_name:$s, scope:"dev", scope_fqdn:$f, percent:$p}]'
}

@test "el render es YAML válido y trae los cuatro objetos" {
  run render openshift "$(rule 100)"
  [ "$status" -eq 0 ]
  echo "$output" | yq 'true' >/dev/null
  [[ "$output" == *"kind: Gateway"* ]]
  [[ "$output" == *"kind: AuthPolicy"* ]]
  [[ "$output" == *"kind: HTTPRoute"* ]]
  [[ "$output" == *"kind: DestinationRule"* ]]
}

@test "no queda nada de OpenResty en el camino del dato" {
  run render openshift "$(rule 100)"
  [[ "$output" != *"openresty"* ]]
  [[ "$output" != *"nginx"* ]]
  [[ "$output" != *"kind: Deployment"* ]]
}

@test "el Gateway se auto-provisiona como ClusterIP: un gateway de egreso no se expone afuera" {
  run render openshift "$(rule 100)"
  local gw; gw=$(doc "$output" Gateway)
  [[ "$gw" == *"networking.istio.io/service-type: ClusterIP"* ]]
  [[ "$gw" != *"LoadBalancer"* ]]
  [[ "$gw" == *'kuadrant.io/gateway: "true"'* ]]
  [[ "$gw" == *"from: Same"* ]]
}

@test "la AuthPolicy firma con la clave de SU namespace, en RS256" {
  run render openshift "$(rule 100)"
  local ap; ap=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap" | yq '.spec.rules.response.success.headers.x-np-token.wristband.signingKeyRefs[0].name')" = "payments-wristband-key" ]
  [ "$(echo "$ap" | yq '.spec.rules.response.success.headers.x-np-token.wristband.signingKeyRefs[0].algorithm')" = "RS256" ]
  [[ "$ap" != *"ES256"* ]]
}

@test "la AuthPolicy cuelga del Gateway, no de cada HTTPRoute" {
  run render openshift "$(rule 100)"
  local ap; ap=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap" | yq '.spec.targetRef.kind')" = "Gateway" ]
  [ "$(echo "$ap" | yq '.spec.targetRef.name')" = "s2s-egress" ]
}

@test "el claim de identidad es el namespace, y el token va sin prefijo Bearer" {
  run render openshift "$(rule 100)"
  local ap; ap=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap" | yq '.spec.rules.response.success.headers.x-np-token.wristband.customClaims.ns.value')" = "payments" ]
  [[ "$ap" != *"Bearer"* ]]
}

@test "la HTTPRoute matchea las cuatro formas del Host" {
  run render openshift "$(rule 100)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '.spec.hostnames | join(",")')" = "reports,reports.payments,reports.payments.svc,reports.payments.svc.cluster.local" ]
}

# ── el destino de cada rama depende del ORIGEN ───────────────────────────────

@test "la rama que CRUZA de sustrato sale por el ingreso del peer, nunca directo al destino" {
  # Es donde se valida la identidad. Si el egreso fuera directo al FQDN del scope, el token no lo
  # miraría nadie y el aislamiento entre namespaces dejaría de existir.
  # Cuál de las dos ramas cruza depende del origen: desde OpenShift cruza lo que va a EKS
  # (percent=100), desde EKS cruza lo que va a OpenShift (percent=0). En los dos casos el 100%
  # del tráfico tiene que salir al peer.
  local platform pct
  for platform in openshift eks; do
    [ "$platform" = "openshift" ] && pct=100 || pct=0
    run render "$platform" "$(rule $pct)"
    local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
    [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].kind')" = "Hostname" ]
    [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].name')" = "$PEER" ]
    [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].port')" -eq 443 ]
  done
}

@test "percent es SIEMPRE el % que va a EKS, desde los dos orígenes" {
  # La invariante del form: el dev declara "cuánto migro a EKS" y eso no cambia de significado
  # según dónde corra el que llama. Traducirlo a los backendRefs sí depende del origen, porque el
  # peer es cada vez uno distinto — y es justo ahí donde la implementación estaba invertida hasta
  # el 2026-08-27: desde EKS, percent mandaba tráfico a OpenShift.
  #
  # Quién atiende cada rama:
  #   origen OpenShift → EKS es el PEER,  OpenShift es reports-local
  #   origen EKS       → EKS es LOCAL_IN, OpenShift es el PEER
  local r peso_eks
  for pct in 0 25 60 100; do
    # Desde OpenShift: lo que va a EKS es el backendRef al peer.
    run render openshift "$(rule $pct)"
    r=$(named "$output" HTTPRoute s2s-egress-reports)
    peso_eks=$(echo "$r" | yq ".spec.rules[0].backendRefs[] | select(.name == \"$PEER\") | .weight // 0")
    [ "${peso_eks:-0}" -eq "$pct" ]

    # Desde EKS: lo que va a EKS es el backendRef al ingreso local.
    run render eks "$(rule $pct)"
    r=$(named "$output" HTTPRoute s2s-egress-reports)
    peso_eks=$(echo "$r" | yq ".spec.rules[0].backendRefs[] | select(.name == \"$LOCAL_IN\") | .weight // 0")
    [ "${peso_eks:-0}" -eq "$pct" ]
  done
}

@test "percent=0 no manda NADA a EKS, desde los dos orígenes" {
  # El caso que más importa no equivocar: 0 tiene que dejar todo en OpenShift. Con la semántica
  # vieja, 0 desde EKS mandaba el 100% a OpenShift por casualidad, pero 100 desde EKS también
  # dejaba todo en OpenShift — o sea que el dial estaba dado vuelta.
  run render openshift "$(rule 0)"
  [[ "$(named "$output" HTTPRoute s2s-egress-reports)" != *"$PEER"* ]]
  run render eks "$(rule 0)"
  [[ "$(named "$output" HTTPRoute s2s-egress-reports)" != *"$LOCAL_IN"* ]]
}

@test "desde OpenShift la rama local es el Service clonado" {
  run render openshift "$(rule 30)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].weight')" -eq 30 ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[1].name')" = "reports-local" ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[1].weight')" -eq 70 ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[1].port')" -eq 8080 ]
}

@test "desde EKS la rama local entra por el ingreso local, no por el FQDN del scope" {
  # Un backendRef necesita un host del registro de Istio. El FQDN de un scope sólo existe como
  # `hostnames` de un HTTPRoute: eso hace que el Gateway lo ATIENDA, no que un Envoy pueda
  # conectarse ahí. Apuntarle directo da 500 sin cluster (mismo patrón que FINDINGS #27).
  # Desde EKS la rama servida por EKS es `percent`: con 30, son 30 los que se quedan acá.
  run render eks "$(rule 30)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[1].kind')" = "Hostname" ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[1].name')" = "$LOCAL_IN" ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[1].port')" -eq 443 ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[1].weight')" -eq 30 ]
  [[ "$r" != *"reports-local"* ]]
}

@test "el Host se reescribe al FQDN del scope: es lo que hace entrar por SU HTTPRoute" {
  # Ese route es el que lleva los pesos del blue/green y el nombre del backend de turno. Entrar
  # por ahí es lo que evita que el service tenga que actualizarse en cada despliegue.
  for origin in OS EKS; do
    run render "$origin" "$(rule 100)"
    local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
    [ "$(echo "$r" | yq '[.spec.rules[0].filters[] | select(.type == "URLRewrite")] | .[0].urlRewrite.hostname')" = "$FQDN" ]
  done
}

@test "ningún backendRef apunta al FQDN del scope" {
  # El invariante que costó un 500 en los dos lados: el FQDN de un scope nunca es destino de una
  # conexión, sólo el Host con el que se entra al Gateway.
  for origin in OS EKS; do
    for p in 0 50 100; do
      run render "$origin" "$(rule $p)"
      [ "$(echo "$output" | yq -N 'select(.kind == "HTTPRoute") | .spec.rules[0].backendRefs[].name' | grep -cx "$FQDN")" -eq 0 ]
    done
  done
}

@test "cuando todo el tráfico va a un solo lado se emite UN solo backendRef" {
  # Un backendRef con weight 0 igual exige que el backend resuelva: si falta, la route entera
  # queda ResolvedRefs=False y se cae también la otra rama, que no lo usa.
  local origin pct
  for origin in OS EKS; do
    for pct in 0 100; do
      run render "$origin" "$(rule $pct)"
      local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
      [ "$(echo "$r" | yq '.spec.rules[0].backendRefs | length')" -eq 1 ]
      [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].weight')" -eq 100 ]
    done
  done
}

@test "con 0% migrado no se emite la rama remota: nada sale al otro sustrato" {
  run render openshift "$(rule 0)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs | length')" -eq 1 ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].name')" = "reports-local" ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].weight')" -eq 100 ]
}

@test "con 100% desde EKS todo entra por el ingreso local, que es donde atiende EKS" {
  run render eks "$(rule 100)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs | length')" -eq 1 ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].name')" = "$LOCAL_IN" ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].weight')" -eq 100 ]
}

# ── los headers de ruteo ─────────────────────────────────────────────────────

@test "desde EKS el header de ruteo es X-NP-SVC con el nombre del Service" {
  # Lo migrado corre en OpenShift, que identifica al destino por nombre de Service.
  run render eks "$(rule 100)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '[.spec.rules[0].filters[] | select(.type == "RequestHeaderModifier")][0].requestHeaderModifier.set[] | select(.name == "X-NP-SVC") | .value')" = "reports" ]
  [ "$(echo "$r" | yq '[.spec.rules[0].filters[] | select(.type == "RequestHeaderModifier")][0].requestHeaderModifier.set[] | select(.name == "X-NP-Origin") | .value')" = "eks" ]
}

@test "desde OpenShift el header de ruteo es X-NP-Scope con el FQDN del scope" {
  # Lo migrado corre en EKS, que identifica al destino por el FQDN de su scope — no por un nombre
  # de Service, que allá no es estable.
  run render openshift "$(rule 100)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '[.spec.rules[0].filters[] | select(.type == "RequestHeaderModifier")][0].requestHeaderModifier.set[] | select(.name == "X-NP-Scope") | .value')" = "$FQDN" ]
  [ "$(echo "$r" | yq '[.spec.rules[0].filters[] | select(.type == "RequestHeaderModifier")][0].requestHeaderModifier.set[] | select(.name == "X-NP-Origin") | .value')" = "openshift" ]
}

@test "va UN solo header de ruteo, no los dos" {
  # Mandar los dos haría más difícil leer a qué sustrato salió un request mirando la traza.
  for origin in OS EKS; do
    run render "$origin" "$(rule 100)"
    local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
    [ "$(echo "$r" | yq '[[.spec.rules[0].filters[] | select(.type == "RequestHeaderModifier")][0].requestHeaderModifier.set[] | select(.name | test("X-NP-(SVC|Scope)"))] | length')" -eq 1 ]
  done
}

@test "los filtros van a nivel de regla, no de backendRef" {
  # Gateway API no soporta filtros por backendRef con más de un backend (istio#39136): puestos
  # ahí, Istio los ignora en silencio.
  run render openshift "$(rule 50)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '.spec.rules[0].filters | length')" -eq 3 ]
  [ "$(echo "$r" | yq '[.spec.rules[0].backendRefs[] | select(has("filters"))] | length')" -eq 0 ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs | length')" -eq 2 ]
}

@test "la respuesta sella que el hop de egreso ocurrió" {
  run render openshift "$(rule 100)"
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '[.spec.rules[0].filters[] | select(.type == "ResponseHeaderModifier")] | .[0].responseHeaderModifier.set[0].value')" = "s2s-egress.payments" ]
}

# ── TLS: dos destinos con material de confianza distinto ─────────────────────

@test "el hop al peer valida su cert contra la CA propia" {
  run render openshift "$(rule 100)"
  local dr; dr=$(named "$output" DestinationRule s2s-egress-peer)
  [ "$(echo "$dr" | yq '.spec.host')" = "$PEER" ]
  [ "$(echo "$dr" | yq '.spec.trafficPolicy.tls.mode')" = "SIMPLE" ]
  [ "$(echo "$dr" | yq '.spec.trafficPolicy.tls.credentialName')" = "s2s-remote-ca" ]
  [ "$(echo "$dr" | yq '.spec.trafficPolicy.tls.sni')" = "$PEER" ]
  [[ "$dr" != *"insecureSkipVerify"* ]]
}

@test "el DestinationRule del peer es UNO solo, aunque haya varias reglas" {
  # La dirección del peer es configuración del service, no un campo por regla.
  run render openshift "$(jq -nc --arg f "$FQDN" '[
    {service_name:"reports", scope:"dev", scope_fqdn:$f, percent:100},
    {service_name:"ledger",  scope:"dev", scope_fqdn:$f, percent:100}]')"
  [ "$(echo "$output" | yq -N 'select(.kind == "DestinationRule") | .metadata.name' | grep -c .)" -eq 1 ]
}

@test "el ingreso local se origina con TLS contra la misma CA que el peer" {
  # Los certs de los dos clusters los firma la misma raíz de la PoC, y el SAN del Gateway local
  # está en esa lista.
  run render eks "$(rule 30)"
  local dr; dr=$(named "$output" DestinationRule s2s-egress-local-ingress)
  [ "$(echo "$dr" | yq '.spec.host')" = "$LOCAL_IN" ]
  [ "$(echo "$dr" | yq '.spec.trafficPolicy.tls.mode')" = "SIMPLE" ]
  [ "$(echo "$dr" | yq '.spec.trafficPolicy.tls.sni')" = "$LOCAL_IN" ]
  [ "$(echo "$dr" | yq '.spec.trafficPolicy.tls.credentialName')" = "s2s-remote-ca" ]
}

@test "desde OpenShift no se emite el DestinationRule del ingreso local" {
  # Ahí la rama local es un Service este-oeste: no hay hop por ningún Gateway.
  run render openshift "$(rule 30)"
  [ "$(echo "$output" | yq -N 'select(.kind == "DestinationRule") | .metadata.name' | grep -c .)" -eq 1 ]
}

@test "ningún DestinationRule se filtra al resto de la malla" {
  run render eks "$(rule 30)"
  [ "$(echo "$output" | yq -N 'select(.kind == "DestinationRule") | .spec.exportTo[0]' | sort -u)" = "." ]
}

@test "el hop remoto declara pool de conexiones" {
  # Sin pool, con RTT real y concurrencia, Envoy abre y cierra una conexión por request:
  # aparecen 503 URX,UF y el p99 se va a 3 RTT. Contra un destino de RTT cero es invisible.
  run render openshift "$(rule 100)"
  local dr; dr=$(named "$output" DestinationRule s2s-egress-peer)
  [ "$(echo "$dr" | yq '.spec.trafficPolicy.connectionPool.http.idleTimeout')" = "300s" ]
  [ "$(echo "$dr" | yq '.spec.trafficPolicy.connectionPool.tcp.maxConnections')" -eq 64 ]
}

@test "soporta múltiples servicios con una route cada uno" {
  run render openshift "$(jq -nc --arg f "$FQDN" '[
    {service_name:"reports", scope:"dev",  scope_fqdn:$f, percent:100},
    {service_name:"ledger",  scope:"prod", scope_fqdn:"otro.example.io", percent:0}]')"
  [ "$status" -eq 0 ]
  echo "$output" | yq 'true' >/dev/null
  # Un solo Gateway y una sola AuthPolicy para los dos.
  [ "$(echo "$output" | yq -N '.kind' | grep -cx Gateway)" -eq 1 ]
  [ "$(echo "$output" | yq -N '.kind' | grep -cx AuthPolicy)" -eq 1 ]
  [ "$(echo "$output" | yq -N 'select(.kind == "HTTPRoute") | .metadata.name' | grep -c '^s2s-egress-')" -eq 2 ]
}

@test "cada regla usa el FQDN de SU scope, no el de la primera" {
  run render openshift "$(jq -nc --arg f "$FQDN" '[
    {service_name:"reports", scope:"dev",  scope_fqdn:$f, percent:100},
    {service_name:"ledger",  scope:"prod", scope_fqdn:"otro.example.io", percent:100}]')"
  local scope_headers
  scope_headers=$(echo "$output" | yq -N 'select(.kind == "HTTPRoute") | [.spec.rules[0].filters[] | select(.type == "RequestHeaderModifier")][0].requestHeaderModifier.set[] | select(.name == "X-NP-Scope") | .value')
  [[ "$scope_headers" == *"$FQDN"* ]]
  [[ "$scope_headers" == *"otro.example.io"* ]]
}

@test "todo lo que emite el render queda marcado como propio" {
  # El `delete` borra por egress-interceptor/managed. Los alias `<svc>-local` que provisiona
  # Terraform NO la llevan, y por eso sobreviven al delete de la instancia.
  # Con origen OS son cinco: Gateway, AuthPolicy, DestinationRule del peer, la route de egreso
  # y la de ingreso —que vive en OTRO namespace y por eso el delete la borra aparte.
  run render openshift "$(rule 100)"
  [ "$(echo "$output" | grep -c 'egress-interceptor/managed: "true"')" -eq 5 ]
  [ "$(echo "$output" | grep -c 'nullplatform: "true"')" -eq 5 ]

  # Con origen EKS y rama local hay un DestinationRule más, y también tiene que quedar marcado o
  # el delete lo dejaría huérfano.
  run render eks "$(rule 30)"
  [ "$(echo "$output" | grep -c 'egress-interceptor/managed: "true"')" -eq 5 ]
  [ "$(echo "$output" | grep -c 'nullplatform: "true"')" -eq 5 ]
}

# ── el template no puede ser un vector de inyección ──────────────────────────
# Los valores vienen de los attributes de la instancia y del FQDN que devuelve la API, y terminan
# en YAML que se aplica con credenciales del cluster. gomplate los tipa (conv.ToInt) o los
# escapa (quote).

@test "un percent no numérico ABORTA el render en vez de inyectar YAML" {
  run render openshift "$(jq -nc '[{service_name:"reports",scope:"dev",scope_fqdn:"a.example.io",percent:"100\n        - name: robado\n          weight: 100"}]')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not convert"* ]]
}

@test "un service_name con salto de línea queda escapado, no inyecta claves" {
  run render openshift "$(jq -nc '[{service_name:"reports\n  evil: si",scope:"dev",scope_fqdn:"a.example.io",percent:100}]')"
  [ "$status" -eq 0 ]
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '.evil // "ausente"')" = "ausente" ]
  [ "$(echo "$r" | yq '.spec.evil // "ausente"')" = "ausente" ]
}

@test "un scope_fqdn con comillas queda escapado en el URLRewrite" {
  run render eks "$(jq -nc '[{service_name:"reports",scope:"dev",scope_fqdn:"a.io\" evil: si",percent:30}]')"
  [ "$status" -eq 0 ]
  echo "$output" | yq 'true' >/dev/null
  local r; r=$(named "$output" HTTPRoute s2s-egress-reports)
  [ "$(echo "$r" | yq '.evil // "ausente"')" = "ausente" ]
  [ "$(echo "$r" | yq '.spec.evil // "ausente"')" = "ausente" ]
}

@test "el rango de percent lo garantiza el schema del service, no el render" {
  run yq -r '.attributes.schema.properties.interceptions.items.properties.percent | "\(.type) \(.minimum) \(.maximum)"' \
    "${BATS_TEST_DIRNAME}/../specs/service-spec.json.tpl"
  [ "$output" = "integer 0 100" ]
}

@test "el form ya no pide un FQDN: el dev declara un scope" {
  # Es el invariante del rediseño. Cualquier campo del form que contenga un hostname de
  # infraestructura es un bug.
  run grep -c 'target_fqdn' "${BATS_TEST_DIRNAME}/../specs/service-spec.json.tpl"
  [ "$output" -eq 0 ]
  run yq -r '.attributes.schema.properties.interceptions.items.required | join(",")' \
    "${BATS_TEST_DIRNAME}/../specs/service-spec.json.tpl"
  [ "$output" = "service_name,scope,percent" ]
}

# ── el ingreso de OpenShift lo declara el service, no el layer ────────────────

@test "con origen OpenShift se emite la route de ingreso, en el namespace del Gateway" {
  # Su backend es el alias `<svc>-local`, que también es del service. Declararla desde el layer
  # obligaba a crear los alias antes que nadie para que el backendRef resolviera.
  run render openshift "$(rule 100)"
  local r; r=$(named "$output" HTTPRoute s2s-ingress-reports)
  [ "$(echo "$r" | yq '.metadata.namespace')" = "$GW_NS" ]
  [ "$(echo "$r" | yq '.spec.parentRefs[0].name')" = "s2s-ingress" ]
  [ "$(echo "$r" | yq '.spec.parentRefs[0].namespace')" = "$GW_NS" ]
  [ "$(echo "$r" | yq '.spec.rules[0].matches[0].headers[0].name')" = "X-NP-SVC" ]
  [ "$(echo "$r" | yq '.spec.rules[0].matches[0].headers[0].value')" = "reports" ]
}

@test "la route de ingreso entrega al alias, no al Service interceptado" {
  # Entregarle el tráfico de entrada a `reports` lo mandaría de vuelta a salir por el egreso.
  run render openshift "$(rule 100)"
  local r; r=$(named "$output" HTTPRoute s2s-ingress-reports)
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].name')" = "reports-local" ]
  [ "$(echo "$r" | yq '.spec.rules[0].backendRefs[0].namespace')" = "payments" ]
}

@test "la route de ingreso sella la respuesta con el cluster que atendió" {
  run render openshift "$(rule 100)"
  local r; r=$(named "$output" HTTPRoute s2s-ingress-reports)
  local set; set=$(echo "$r" | yq -o=json '.spec.rules[0].filters[0].responseHeaderModifier.set')
  [ "$(echo "$set" | jq -r '.[] | select(.name=="X-Egress-Route") | .value')" = "inbound" ]
  [ "$(echo "$set" | jq -r '.[] | select(.name=="X-S2S-Cluster") | .value')" = "crc-openshift" ]
  [ "$(echo "$set" | jq -r '.[] | select(.name=="X-Egress-Target") | .value')" = "reports-local.payments.svc.cluster.local" ]
}

@test "desde EKS NO se emite route de ingreso: la del scope ya cuelga del Gateway" {
  run render eks "$(rule 100)"
  [[ "$output" != *"s2s-ingress-reports"* ]]
}

# ── El split en un archivo por objeto ────────────────────────────────────────────────────────
# Lo que se aplica es el DIRECTORIO, así que qué archivos quedan —y en qué orden— es parte del
# comportamiento, no un detalle de organización.

@test "cada objeto se rendea a su propio archivo" {
  run rendered_files openshift "$(rule 50)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"10-gateway.yaml"* ]]
  [[ "$output" == *"20-authpolicy.yaml"* ]]
  [[ "$output" == *"30-destinationrule-peer.yaml"* ]]
  [[ "$output" == *"50-httproute-egress.yaml"* ]]
  [[ "$output" == *"60-httproute-ingress.yaml"* ]]
}

@test "un template cuya condición no se cumple NO deja archivo" {
  # `kubectl apply -f` sobre un archivo vacío falla, así que el render vacío tiene que
  # desaparecer y no simplemente quedar en blanco.
  run rendered_files openshift "$(rule 50)"
  [[ "$output" != *"40-destinationrule-local-ingress"* ]]
  run rendered_files eks "$(rule 50)"
  [[ "$output" == *"40-destinationrule-local-ingress.yaml"* ]]
  [[ "$output" != *"60-httproute-ingress"* ]]
}

@test "sin ninguna regla sólo quedan el Gateway y su AuthPolicy" {
  run rendered_files openshift '[]'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c .)" -eq 2 ]
  [[ "$output" == *"10-gateway.yaml"* ]]
  [[ "$output" == *"20-authpolicy.yaml"* ]]
}

@test "el orden de aplicación pone al Gateway antes de lo que lo referencia" {
  # No porque aplicar al revés rompa —los controllers reconcilian solo—, sino para que el orden
  # sea determinístico y no dependa de cómo caigan los nombres al ordenarse alfabéticamente.
  # Lo que este test cuida es que alguien saque los prefijos y el orden cambie sin que se note.
  run rendered_files eks "$(rule 50)"
  [ "$(echo "$output" | head -1)" = "10-gateway.yaml" ]
  [ "$(echo "$output" | grep -n 'authpolicy' | cut -d: -f1)" -lt "$(echo "$output" | grep -n 'httproute' | head -1 | cut -d: -f1)" ]
  [ "$(echo "$output" | grep -n 'destinationrule' | head -1 | cut -d: -f1)" -lt "$(echo "$output" | grep -n 'httproute' | head -1 | cut -d: -f1)" ]
}

@test "un directorio de manifiestos vacío ABORTA en vez de aplicar nada" {
  # Sin esto un MANIFESTS_DIR mal resuelto haría un reconcile que no aplica ningún objeto y sale
  # con 0: el Gateway nunca se crearía y el fallo aparecería recién en el wait, sin decir por qué.
  MANIFESTS_DIR="$BATS_TEST_TMPDIR/no-hay-nada"
  mkdir -p "$MANIFESTS_DIR"
  echo '{}' > "$BATS_TEST_TMPDIR/vacio.json"
  run render_manifests "$BATS_TEST_TMPDIR/vacio.json" "$BATS_TEST_TMPDIR/salida"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no tiene ningún"* ]]
}

@test "un template que no compila ABORTA nombrando el archivo" {
  run render openshift "$(jq -nc '[{service_name:"reports", scope:"dev", scope_fqdn:"f.io", percent:"cincuenta"}]')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"50-httproute-egress"* ]]
}

@test "un render que sale EN BLANCO tampoco se aplica" {
  # gomplate no crea el archivo cuando la salida es vacía del todo, pero sí lo crea cuando queda
  # whitespace. `kubectl apply -f` sobre eso falla igual, así que las dos formas se descartan.
  MANIFESTS_DIR="$BATS_TEST_TMPDIR/tpl"
  mkdir -p "$MANIFESTS_DIR"
  printf '\n\n  \n' > "$MANIFESTS_DIR/99-en-blanco.yaml.tpl"
  printf 'kind: ConfigMap\n' > "$MANIFESTS_DIR/98-con-contenido.yaml.tpl"
  echo '{}' > "$BATS_TEST_TMPDIR/c.json"
  run render_manifests "$BATS_TEST_TMPDIR/c.json" "$BATS_TEST_TMPDIR/o"
  [ "$status" -eq 0 ]
  [[ "$output" == *"98-con-contenido.yaml"* ]]
  [[ "$output" != *"99-en-blanco"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/o/99-en-blanco.yaml" ]
}
