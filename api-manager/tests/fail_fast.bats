#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  RECONCILE="${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile"
  RECONCILE_LIB="${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile_lib"
  source "${BATS_TEST_DIRNAME}/../logging"
  export -f log

  export NAMESPACE=payments
  export APP_TARGET=payments.reports
  export SERVICE_ID=svc-1
  export HOSTS_JSON='["api.expuesta.com"]'
  export ROUTES_JSON='[{"path":"/r1","methods":["GET"],"scope":"prod","backend":"appy.internas.com"}]'
  export GATEWAY_NAME=s2s-ingress
  export GATEWAY_NAMESPACE=gateways
  export KEYS_NAMESPACE=kuadrant-system
  export API_KEY_HEADER=x-api-key

  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  : >"$KUBECTL_CALLS_LOG"
  unset KUBECTL_MOCK_FAIL KUBECTL_MOCK_ROUTE_COND KUBECTL_MOCK_PARENTS

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS_LOG"

case " $* " in
  *" apply "*)
    [ "${KUBECTL_MOCK_FAIL:-}" = apply ] && exit 1
    exit 0
    ;;
esac

case "$*" in
  *httproute/*)
    PARENTS="${KUBECTL_MOCK_PARENTS:-}"
    if [ -z "$PARENTS" ]; then
      STATUS="${KUBECTL_MOCK_ROUTE_COND:-True}"
      PARENTS="[{\"conditions\":[{\"type\":\"Accepted\",\"status\":\"$STATUS\"}]}]"
    fi
    printf '{"status":{"parents":%s}}\n' "$PARENTS"
    exit 0
    ;;
  *httproutes*)
    [ "${KUBECTL_MOCK_FAIL:-}" = get-httproutes ] && exit 1
    echo '{"items":[]}'
    exit 0
    ;;
esac

exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "aborta si falla el apply de un manifiesto" {
  export KUBECTL_MOCK_FAIL=apply
  run bash "$RECONCILE" apply
  [ "$status" -ne 0 ]
}

@test "aborta si la route nunca queda Accepted" {
  export KUBECTL_MOCK_ROUTE_COND=False
  export WAIT_TIMEOUT=1
  run bash "$RECONCILE" apply
  [ "$status" -ne 0 ]
}

@test "no borra nada si falla el listado de rutas propias" {
  export KUBECTL_MOCK_FAIL=get-httproutes
  run bash "$RECONCILE" delete
  [ "$status" -ne 0 ]
  ! grep -q 'delete' "$KUBECTL_CALLS_LOG"
}

@test "el delete borra tambien las keys de la app" {
  run bash "$RECONCILE" delete
  [ "$status" -eq 0 ]
  grep -q "delete secret" "$KUBECTL_CALLS_LOG"
}

@test "wait_route_condition acepta con un parent True y ninguno distinto" {
  source "$RECONCILE_LIB"
  export KUBECTL_MOCK_PARENTS='[{"conditions":[{"type":"Accepted","status":"True"}]}]'
  run wait_route_condition ns route Accepted 2
  [ "$status" -eq 0 ]
}

@test "wait_route_condition rechaza si algun parent reporta distinto de True" {
  source "$RECONCILE_LIB"
  export KUBECTL_MOCK_PARENTS='[{"conditions":[{"type":"Accepted","status":"True"}]},{"conditions":[{"type":"Accepted","status":"False"}]}]'
  run wait_route_condition ns route Accepted 1
  [ "$status" -ne 0 ]
}

@test "NO espera ResolvedRefs, que es falso negativo con kind Hostname" {
  run bash "$RECONCILE" apply
  ! grep -q 'ResolvedRefs' "$KUBECTL_CALLS_LOG"
}
