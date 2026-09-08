#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v gomplate >/dev/null && command -v yq >/dev/null || {
    echo "bats necesita gomplate y yq." >&2; return 1
  }
  source "${BATS_TEST_DIRNAME}/../logging"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib"
}

contexto() {  # <platform> <interceptions-json>
  jq -n --arg platform "$1" --argjson interceptions "$2" '{
    namespace: "payments", gateway_name: "s2s-egress", listen_port: 8080,
    managed_label: "egress-interceptor/managed", role_label: "egress-interceptor/role",
    original_selector_annotation: "egress-interceptor/original-selector",
    platform: $platform, interceptions: $interceptions
  }' >"$BATS_TEST_TMPDIR/ctx.json"
}

render() {  # <platform> <interceptions-json>
  contexto "$1" "$2"
  local out="$BATS_TEST_TMPDIR/out" f
  rm -rf "$out"
  render_manifests_from "$SERVICES_MANIFESTS_DIR" "$BATS_TEST_TMPDIR/ctx.json" "$out" \
    >"$BATS_TEST_TMPDIR/list.txt" || return 1
  while IFS= read -r f; do cat "$f"; done <"$BATS_TEST_TMPDIR/list.txt"
}

archivos_rendeados() {  # <platform> <interceptions-json>
  contexto "$1" "$2"
  local out="$BATS_TEST_TMPDIR/out2"
  rm -rf "$out"
  render_manifests_from "$SERVICES_MANIFESTS_DIR" "$BATS_TEST_TMPDIR/ctx.json" "$out" | xargs -n1 basename
}

svc() { echo "$1" | yq "select(.kind == \"Service\" and .metadata.name == \"$2\") | ... comments=\"\""; }

regla() {  # <service>
  jq -nc --arg s "$1" '{
    service_name: $s, scope: "eks", scope_fqdn: "\($s).example.io", percent: 50,
    original: {
      selector: {app: $s, tier: "api"},
      ports: [{name: "http", port: 8080, targetPort: "web", protocol: "TCP", appProtocol: "http"},
              {name: "grpc", port: 9090, targetPort: 9090, protocol: "TCP"}]
    }
  }'
}

sin_service_previo() {  # <service>
  jq -nc --arg s "$1" '{
    service_name: $s, scope: "eks", scope_fqdn: "\($s).example.io", percent: 50,
    original: {selector: {}, ports: []}
  }'
}

@test "el render es YAML válido y trae los dos Services en OpenShift" {
  run render openshift "[$(regla reports)]"
  [ "$status" -eq 0 ]
  echo "$output" | yq 'true' >/dev/null
  [ "$(echo "$output" | yq -N 'select(.kind == "Service") | .metadata.name' | sort | tr '\n' ' ')" = "reports reports-local " ]
}

@test "el alias hereda el selector y los ports del Service original" {
  local out alias
  out=$(render openshift "[$(regla reports)]")
  alias=$(svc "$out" reports-local)
  [ "$(echo "$alias" | yq '.spec.selector.app')" = "reports" ]
  [ "$(echo "$alias" | yq '.spec.selector.tier')" = "api" ]
  [ "$(echo "$alias" | yq '.spec.ports | length')" = "2" ]
  [ "$(echo "$alias" | yq '.spec.ports[0].targetPort')" = "web" ]
  [ "$(echo "$alias" | yq '.spec.ports[0].appProtocol')" = "http" ]
  [ "$(echo "$alias" | yq '.spec.ports[1].port')" = "9090" ]
}

@test "el targetPort numérico se publica como número y no como string" {
  local out
  out=$(render openshift "[$(regla reports)]")
  [ "$(svc "$out" reports-local | yq '.spec.ports[1].targetPort | tag')" = "!!int" ]
  [ "$(svc "$out" reports-local | yq '.spec.ports[0].targetPort | tag')" = "!!str" ]
}

@test "el alias lleva las labels del interceptor porque es un objeto nuestro" {
  local alias
  alias=$(svc "$(render openshift "[$(regla reports)]")" reports-local)
  [ "$(echo "$alias" | yq '.metadata.labels["egress-interceptor/managed"]')" = "true" ]
  [ "$(echo "$alias" | yq '.metadata.labels["egress-interceptor/role"]')" = "local-alias" ]
  [ "$(echo "$alias" | yq '.metadata.labels.nullplatform')" = "true" ]
}

@test "el Service que captura apunta al Gateway y conserva los ports originales" {
  local captura
  captura=$(svc "$(render openshift "[$(regla reports)]")" reports)
  [ "$(echo "$captura" | yq '.spec.selector["gateway.networking.k8s.io/gateway-name"]')" = "s2s-egress" ]
  [ "$(echo "$captura" | yq '.spec.selector | length')" = "1" ]
  [ "$(echo "$captura" | yq '.spec.ports | length')" = "2" ]
  [ "$(echo "$captura" | yq '.spec.ports[0].port')" = "8080" ]
}

@test "el Service que captura guarda el selector original en la annotation" {
  local captura
  captura=$(svc "$(render openshift "[$(regla reports)]")" reports)
  [ "$(echo "$captura" | yq '.metadata.annotations["egress-interceptor/original-selector"]')" = '{"app":"reports","tier":"api"}' ]
}

@test "el Service que captura NO lleva las labels del interceptor: el objeto no es nuestro" {
  local captura
  captura=$(svc "$(render openshift "[$(regla reports)]")" reports)
  [ "$(echo "$captura" | yq '.metadata.labels // "sin labels"')" = "sin labels" ]
}

@test "sin Service previo el que captura se rendea con el listen_port y las labels del interceptor" {
  local captura
  captura=$(svc "$(render eks "[$(sin_service_previo reports)]")" reports)
  [ "$(echo "$captura" | yq '.spec.ports | length')" = "1" ]
  [ "$(echo "$captura" | yq '.spec.ports[0].port')" = "8080" ]
  [ "$(echo "$captura" | yq '.spec.ports[0].targetPort')" = "8080" ]
  [ "$(echo "$captura" | yq '.metadata.labels["egress-interceptor/role"]')" = "gateway-service" ]
  [ "$(echo "$captura" | yq '.metadata.annotations // "sin annotations"')" = "sin annotations" ]
}

@test "en EKS no se rendea el alias" {
  run archivos_rendeados eks "[$(sin_service_previo reports)]"
  [ "$status" -eq 0 ]
  [ "$output" = "90-service-capture.yaml" ]
}

@test "en OpenShift se rendean los dos archivos, el alias antes que el que captura" {
  run archivos_rendeados openshift "[$(regla reports)]"
  [ "$status" -eq 0 ]
  [ "$output" = "70-service-local.yaml
90-service-capture.yaml" ]
}

@test "con varias reglas hay un alias y una captura por servicio" {
  local out
  out=$(render openshift "[$(regla reports),$(regla checkout)]")
  [ "$(echo "$out" | yq -N 'select(.kind == "Service") | .metadata.name' | sort | tr '\n' ' ')" = "checkout checkout-local reports reports-local " ]
  [ "$(svc "$out" checkout-local | yq '.spec.selector.app')" = "checkout" ]
}

@test "sin reglas no se rendea ningún Service" {
  run archivos_rendeados openshift '[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
