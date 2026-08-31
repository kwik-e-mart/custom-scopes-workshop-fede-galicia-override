setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  export LIB="${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib"
  export OUT="$BATS_TEST_TMPDIR/out"
  export CTX="$BATS_TEST_TMPDIR/ctx.json"
  source "${BATS_TEST_DIRNAME}/../logging"
  export -f log
  BASE='{
    "namespace":"payments","route_name":"api-manager-1","app_target":"payments.reports",
    "gateway_name":"s2s-ingress","gateway_namespace":"gateways","api_key_header":"x-api-key",
    "managed_label":"api-manager.nullplatform.io/managed",
    "target_label":"apimgr-target",
    "authpolicy_api_version":"kuadrant.io/v1",
    "hosts":["api.expuesta.com"],
    "routes":[{"path":"/r1","methods":["GET"],"scope":"prod","backend":"appy.internas.com"}]
  }'
}

render_ctx() {
  printf %s "$BASE" | jq -c ". + $1" >"$CTX"
  source "$LIB"
  render_manifests "$CTX" "$OUT" >/dev/null
}

@test "el httproute lleva un match por metodo y el backend de la ruta" {
  run render_ctx '{"routes":[{"path":"/r1","methods":["GET","POST"],"scope":"prod","backend":"appy.internas.com"}]}'
  [ "$status" -eq 0 ]
  [ "$(yq '.spec.rules[0].matches | length' "$OUT/10-httproute.yaml")" = "2" ]
  [ "$(yq -r '.spec.rules[0].backendRefs[0].kind' "$OUT/10-httproute.yaml")" = "Hostname" ]
  [ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$OUT/10-httproute.yaml")" = "appy.internas.com" ]
}

@test "cada match conserva el path de su ruta y no queda vacio" {
  run render_ctx '{"routes":[{"path":"/pagos","methods":["GET","POST"],"scope":"prod","backend":"appy.internas.com"}]}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules[0].matches[0].path.value' "$OUT/10-httproute.yaml")" = "/pagos" ]
  [ "$(yq -r '.spec.rules[0].matches[1].path.value' "$OUT/10-httproute.yaml")" = "/pagos" ]
}

@test "un path con asterisco se traduce a PathPrefix sin el asterisco" {
  run render_ctx '{"routes":[{"path":"/files/*","methods":["GET"],"scope":"prod","backend":"appy.internas.com"}]}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules[0].matches[0].path.type' "$OUT/10-httproute.yaml")" = "PathPrefix" ]
  [ "$(yq -r '.spec.rules[0].matches[0].path.value' "$OUT/10-httproute.yaml")" = "/files/" ]
}

@test "cada ruta apunta al backend de SU scope y no al de la primera" {
  run render_ctx '{"routes":[
    {"path":"/a","methods":["GET"],"scope":"prod","backend":"prod.internas.com"},
    {"path":"/b","methods":["GET"],"scope":"dev","backend":"dev.internas.com"}]}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$OUT/10-httproute.yaml")" = "prod.internas.com" ]
  [ "$(yq -r '.spec.rules[1].backendRefs[0].name' "$OUT/10-httproute.yaml")" = "dev.internas.com" ]
}

@test "el httproute declara todos los hosts" {
  run render_ctx '{"hosts":["a.example.com","b.example.com"]}'
  [ "$status" -eq 0 ]
  [ "$(yq '.spec.hostnames | length' "$OUT/10-httproute.yaml")" = "2" ]
}

@test "la authpolicy autoriza por igualdad exacta y no por regexp" {
  run render_ctx '{}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules.authorization["allowed-target"].patternMatching.patterns[0].operator' "$OUT/20-authpolicy.yaml")" = "eq" ]
}

@test "la authpolicy autoriza contra el app_target del contexto" {
  run render_ctx '{"app_target":"payments.reports"}'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.rules.authorization["allowed-target"].patternMatching.patterns[0].value' "$OUT/20-authpolicy.yaml")" = "payments.reports" ]
}

@test "el selector de apiKey NO filtra por app, para que una key ajena de 403 y no 401" {
  run render_ctx '{"app_target":"payments.reports"}'
  [ "$status" -eq 0 ]
  run yq -r '.spec.rules.authentication["consumer-key"].apiKey.selector.matchLabels | keys | .[]' "$OUT/20-authpolicy.yaml"
  ! echo "$output" | grep -q 'target'
}

@test "render_manifests falla si el directorio de manifiestos esta vacio" {
  export MANIFESTS_DIR="$BATS_TEST_TMPDIR/vacio"
  mkdir -p "$MANIFESTS_DIR"
  run timeout 10 bash -c 'source "$LIB"; render_manifests "$CTX" "$OUT"'
  [ "$status" -eq 1 ]
}
