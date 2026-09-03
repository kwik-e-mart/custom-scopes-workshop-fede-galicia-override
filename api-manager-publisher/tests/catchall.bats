#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v gomplate >/dev/null && command -v jq >/dev/null \
    && command -v yq >/dev/null && command -v openssl >/dev/null || {
    echo "bats necesita gomplate, jq, yq y openssl." >&2; return 1
  }

  source "${BATS_TEST_DIRNAME}/../logging"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/labels_lib"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/collisions_lib"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/gitops_lib"
  export -f log

  export NAMESPACE=payments
  export ROUTE_NAME=api-manager-svc-1
  export SITE=openshift-crc

  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  : >"$KUBECTL_CALLS_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS_LOG"
[ "${KUBECTL_MOCK_FAIL:-}" = get-httproutes ] && exit 1
printf '{"items":%s}\n' "${KUBECTL_MOCK_ROUTES:-[]}"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset KUBECTL_MOCK_FAIL KUBECTL_MOCK_ROUTES
}

ctx_para() {
  local target="$1" host="${2:-api.expuesta.com}" out="$BATS_TEST_TMPDIR/ctx-$target.json"
  jq -n --arg app_target "$target" --arg host "$host" '{
    namespace: "payments", route_name: ("api-manager-" + $app_target), app_target: $app_target,
    gateway_name: "s2s-ingress", gateway_namespace: "gateways", api_key_header: "x-api-key",
    managed_label: "api-manager.nullplatform.io/managed", target_label: "apimgr-target",
    authpolicy_api_version: "kuadrant.io/v1", hosts: [$host]
  }' >"$out"
  printf '%s' "$out"
}

@test "el nombre de la catch-all es determinístico: dos services sobre el mismo host lo derivan igual" {
  local a b
  a=$(catchall_name_for_host api.expuesta.com)
  b=$(catchall_name_for_host api.expuesta.com)
  [ "$a" = "$b" ]
}

@test "hosts distintos dan nombres distintos" {
  [ "$(catchall_name_for_host api.expuesta.com)" != "$(catchall_name_for_host otro.expuesta.com)" ]
}

@test "hosts que normalizan igual NO colapsan al mismo nombre" {
  [ "$(catchall_name_for_host a.b-c.com)" != "$(catchall_name_for_host a-b.c.com)" ]
}

@test "el nombre es un DNS-1123 subdomain válido" {
  local n
  n=$(catchall_name_for_host "*.MiXeD.Example.Com.")
  [[ "$n" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
  [ "${#n}" -le 253 ]
}

@test "el manifiesto de la catch-all NO lleva ninguna etiqueta de dueño" {
  local ctx dir
  ctx=$(ctx_para payments.appx)
  render_catchalls "$ctx" "$BATS_TEST_TMPDIR/out-x" >/dev/null
  dir=$(printf '%s' "$BATS_TEST_TMPDIR/out-x"/*)
  ! grep -q "apimgr-target" "$dir/catchall.yaml"
  ! grep -q "appx" "$dir/catchall.yaml"
}

@test "dos services distintos sobre el mismo host renderizan la catch-all IDENTICA" {
  local ctx_x ctx_y dir_x dir_y
  ctx_x=$(ctx_para payments.appx)
  ctx_y=$(ctx_para payments.appy)
  render_catchalls "$ctx_x" "$BATS_TEST_TMPDIR/out-x" >/dev/null
  render_catchalls "$ctx_y" "$BATS_TEST_TMPDIR/out-y" >/dev/null
  dir_x=$(printf '%s' "$BATS_TEST_TMPDIR/out-x"/*)
  dir_y=$(printf '%s' "$BATS_TEST_TMPDIR/out-y"/*)
  [ "$(basename "$dir_x")" = "$(basename "$dir_y")" ]
  diff "$dir_x/catchall.yaml" "$dir_y/catchall.yaml"
}

@test "la catch-all deniega a cualquiera que autentique" {
  local ctx dir
  ctx=$(ctx_para payments.appx)
  render_catchalls "$ctx" "$BATS_TEST_TMPDIR/out-x" >/dev/null
  dir=$(printf '%s' "$BATS_TEST_TMPDIR/out-x"/*)
  run yq -r 'select(.kind == "AuthPolicy") | .spec.rules.authorization."deny-all".patternMatching.patterns[0].value' "$dir/catchall.yaml"
  [ "$output" = "__api-manager-nunca-matchea__" ]
}

@test "la catch-all matchea todo el dominio con PathPrefix /" {
  local ctx dir
  ctx=$(ctx_para payments.appx)
  render_catchalls "$ctx" "$BATS_TEST_TMPDIR/out-x" >/dev/null
  dir=$(printf '%s' "$BATS_TEST_TMPDIR/out-x"/*)
  run yq -r 'select(.kind == "HTTPRoute") | .spec.rules[0].matches[0].path | .type + " " + .value' "$dir/catchall.yaml"
  [ "$output" = "PathPrefix /" ]
}

@test "render_catchalls produce una catch-all por cada host declarado" {
  local ctx
  ctx="$BATS_TEST_TMPDIR/ctx-multi.json"
  jq -n '{namespace:"payments", gateway_name:"s2s-ingress", gateway_namespace:"gateways",
          api_key_header:"x-api-key", managed_label:"api-manager.nullplatform.io/managed",
          authpolicy_api_version:"kuadrant.io/v1", hosts:["a.expuesta.com","b.expuesta.com"]}' >"$ctx"
  run render_catchalls "$ctx" "$BATS_TEST_TMPDIR/out-multi"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
}

@test "el guard de colisiones IGNORA las catch-all: si no, la segunda app del dominio queda rechazada" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"api-manager-deny-api-expuesta-com-abc","namespace":"payments","labels":{"api-manager.nullplatform.io/catchall":"true"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/"}}]}]}}]'
  run find_route_conflicts api-manager-svc-2 "$MANAGED_LABEL" "$APP_LABEL" '["api.expuesta.com"]' '[{"path":"/y"}]'
  [ "$status" -eq 0 ]
}

@test "el guard sigue detectando una colisión real entre dos apps" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"api-manager-svc-1","namespace":"payments","labels":{"apimgr-app":"payments.appx"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/y"}}]}]}}]'
  run find_route_conflicts api-manager-svc-2 "$MANAGED_LABEL" "$APP_LABEL" '["api.expuesta.com"]' '[{"path":"/y"}]'
  [ "$status" -eq 1 ]
}

@test "host_still_claimed es verdadero si otra ruta del namespace declara el host" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"api-manager-svc-9","labels":{"apimgr-app":"payments.appy"}},"spec":{"hostnames":["api.expuesta.com"]}}]'
  run host_still_claimed payments api.expuesta.com "$MANAGED_LABEL" "$CATCHALL_LABEL"
  [ "$status" -eq 0 ]
}

@test "host_still_claimed NO cuenta la propia catch-all del host" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"api-manager-deny-x","labels":{"api-manager.nullplatform.io/catchall":"true"}},"spec":{"hostnames":["api.expuesta.com"]}}]'
  run host_still_claimed payments api.expuesta.com "$MANAGED_LABEL" "$CATCHALL_LABEL"
  [ "$status" -ne 0 ]
}

@test "host_still_claimed es falso si nadie mas declara el host" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"api-manager-svc-9","labels":{"apimgr-app":"payments.appy"}},"spec":{"hostnames":["otro.expuesta.com"]}}]'
  run host_still_claimed payments api.expuesta.com "$MANAGED_LABEL" "$CATCHALL_LABEL"
  [ "$status" -ne 0 ]
}

@test "si falla el listado, host_still_claimed FALLA CERRADO y conserva la catch-all" {
  export KUBECTL_MOCK_FAIL=get-httproutes
  run host_still_claimed payments api.expuesta.com "$MANAGED_LABEL" "$CATCHALL_LABEL"
  [ "$status" -eq 0 ]
}

@test "el subárbol compartido cuelga de _shared, hermano del subárbol por service" {
  run gitops_shared_subtree api-manager-deny-x
  [ "$output" = "cross-namespace-rules/openshift-crc/payments/_shared/api-manager-deny-x" ]
}

@test "el subárbol compartido es un subárbol relativo válido" {
  run gitops_valid_subtree "$(gitops_shared_subtree api-manager-deny-x)"
  [ "$status" -eq 0 ]
}

@test "el publish por service NO toca el subárbol compartido" {
  local propio compartido
  propio=$(gitops_subtree)
  compartido=$(gitops_shared_subtree api-manager-deny-x)
  [[ "$compartido" != "$propio"/* ]]
}
