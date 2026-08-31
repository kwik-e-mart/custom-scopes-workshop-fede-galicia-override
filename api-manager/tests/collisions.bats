#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  CHECK="${BATS_TEST_DIRNAME}/../scripts/k8s/check_collisions"
  source "${BATS_TEST_DIRNAME}/../logging"
  export -f log

  export APP_TARGET=payments.reports
  export HOSTS_JSON='[]'
  export ROUTES_JSON='[]'
  unset KUBECTL_MOCK_FAIL KUBECTL_MOCK_ROUTES

  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  : >"$KUBECTL_CALLS_LOG"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS_LOG"
case "$*" in
  *httproutes*)
    [ "${KUBECTL_MOCK_FAIL:-}" = get ] && exit 1
    printf '{"items":%s}\n' "${KUBECTL_MOCK_ROUTES:-[]}"
    exit 0
    ;;
esac
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "permite el mismo host con paths distintos" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"otra","namespace":"reports","labels":{"apimgr-target":"reports.otra"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/reportes"}}]}]}}]'
  export HOSTS_JSON='["api.expuesta.com"]'
  export ROUTES_JSON='[{"path":"/pagos","methods":["GET"],"scope":"prod","backend":"b.com"}]'
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "rechaza el mismo host con el mismo path de otra app" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"otra","namespace":"reports","labels":{"apimgr-target":"reports.otra"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/pagos"}}]}]}}]'
  export HOSTS_JSON='["api.expuesta.com"]'
  export ROUTES_JSON='[{"path":"/pagos","methods":["GET"],"scope":"prod","backend":"b.com"}]'
  run bash "$CHECK"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "reports.otra"
}

@test "no colisiona consigo misma en un update" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"propia","namespace":"payments","labels":{"apimgr-target":"payments.reports"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/pagos"}}]}]}}]'
  export APP_TARGET=payments.reports
  export HOSTS_JSON='["api.expuesta.com"]'
  export ROUTES_JSON='[{"path":"/pagos","methods":["GET"],"scope":"prod","backend":"b.com"}]'
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "aborta si falla el listado de rutas en vez de dar via libre" {
  export KUBECTL_MOCK_FAIL=get
  run bash "$CHECK"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no se pudo listar las rutas existentes"
}
