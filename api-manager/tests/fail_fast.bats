#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  RECONCILE="${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile"
  RECONCILE_LIB="${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile_lib"
  CHECK="${BATS_TEST_DIRNAME}/../scripts/k8s/check_collisions"
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
  export WRISTBAND_SECRET=payments-wristband-key
  export TOKEN_DURATION=300

  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  : >"$KUBECTL_CALLS_LOG"
  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  : >"$NP_CALLS_LOG"
  export NP_MOCK_LINKS='[{"id":"1"}]'
  unset KUBECTL_MOCK_FAIL KUBECTL_MOCK_ROUTE_COND KUBECTL_MOCK_PARENTS KUBECTL_MOCK_ROUTES MANIFESTS_DIR NP_MOCK_MODE

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NP_CALLS_LOG"
if [ "${NP_MOCK_MODE:-ok}" = "fail" ]; then
  echo '{"error":"failed"}'
  exit 1
fi
SUBCMD="$1 $2"
QUERY=.
while [ $# -gt 0 ]; do
  case "$1" in
    --query) QUERY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$SUBCMD" in
  "link list")
    printf %s "${NP_MOCK_LINKS:-[]}" | jq -c '{results: .}' | jq -c "$QUERY" ;;
  *)
    echo '{}' ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"

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
  *"delete secret"*)
    [ "${KUBECTL_MOCK_FAIL:-}" = delete-secret ] && exit 1
    exit 0
    ;;
  *"delete authpolicy"*)
    [ "${KUBECTL_MOCK_FAIL:-}" = delete-authpolicy ] && exit 1
    exit 0
    ;;
  *"delete httproute "*)
    [ "${KUBECTL_MOCK_FAIL:-}" = delete-httproute ] && exit 1
    exit 0
    ;;
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
    printf '{"items":%s}\n' "${KUBECTL_MOCK_ROUTES:-[]}"
    exit 0
    ;;
esac

exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

run_reconcile() {
  local action="$1"
  bash -c '
    set -euo pipefail
    if ! source "$1" "$2"; then
      exit 1
    fi
  ' _ "$RECONCILE" "$action"
}

@test "aborta si falla el apply de un manifiesto" {
  export KUBECTL_MOCK_FAIL=apply
  run run_reconcile apply
  [ "$status" -ne 0 ]
}

@test "aborta si la route nunca queda Accepted" {
  export KUBECTL_MOCK_ROUTE_COND=False
  export WAIT_TIMEOUT=1
  run run_reconcile apply
  [ "$status" -ne 0 ]
}

@test "aborta si falla el render de los manifiestos" {
  export MANIFESTS_DIR="$BATS_TEST_TMPDIR/manifiestos-vacios"
  mkdir -p "$MANIFESTS_DIR"
  run run_reconcile apply
  [ "$status" -ne 0 ]
}

@test "aborta si render_manifests devuelve error aunque haya impreso algo antes de fallar" {
  render_manifests() {
    printf '%s\n' "$2/algo.yaml"
    printf 'fake\n' >"$2/algo.yaml"
    return 1
  }
  export -f render_manifests
  run run_reconcile apply
  [ "$status" -ne 0 ]
}

@test "no borra nada si falla el listado de rutas propias" {
  export KUBECTL_MOCK_FAIL=get-httproutes
  run run_reconcile delete
  [ "$status" -ne 0 ]
  ! grep -q 'delete' "$KUBECTL_CALLS_LOG"
}

@test "el delete borra tambien las keys de la app" {
  run run_reconcile delete
  [ "$status" -eq 0 ]
  grep -q "delete secret" "$KUBECTL_CALLS_LOG"
}

@test "el delete borra las keys por link id, no por selector de label" {
  export NP_MOCK_LINKS='[{"id":"1"},{"id":"2"}]'
  run run_reconcile delete
  [ "$status" -eq 0 ]
  grep -q "delete secret api-manager-1 " "$KUBECTL_CALLS_LOG"
  grep -q "delete secret api-manager-2 " "$KUBECTL_CALLS_LOG"
  ! grep -q -- "-l apimgr-target=" "$KUBECTL_CALLS_LOG"
}

@test "sin links del service no intenta borrar ninguna key" {
  export NP_MOCK_LINKS='[]'
  run run_reconcile delete
  [ "$status" -eq 0 ]
  ! grep -q "delete secret" "$KUBECTL_CALLS_LOG"
}

@test "aborta si falla el listado de links de nullplatform y no borra ninguna key" {
  export NP_MOCK_MODE=fail
  run run_reconcile delete
  [ "$status" -ne 0 ]
  ! grep -q "delete secret" "$KUBECTL_CALLS_LOG"
}

@test "aborta si falla el borrado del Secret de api keys" {
  export KUBECTL_MOCK_FAIL=delete-secret
  run run_reconcile delete
  [ "$status" -ne 0 ]
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
  run run_reconcile apply
  ! grep -q 'ResolvedRefs' "$KUBECTL_CALLS_LOG"
}

@test "detecta una carrera si aparece un rival entre el check previo y el post-apply, y revierte" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]

  : >"$KUBECTL_CALLS_LOG"
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"api-manager-rival","namespace":"other","labels":{"apimgr-target":"other.app"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/r1"}}]}]}}]'
  run run_reconcile apply
  [ "$status" -ne 0 ]
  grep -q "delete authpolicy api-manager-svc-1" "$KUBECTL_CALLS_LOG"
  grep -q "delete httproute api-manager-svc-1" "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "other.app"
}

@test "camino feliz: sin conflicto en el re-chequeo post-apply, no borra nada" {
  run run_reconcile apply
  [ "$status" -eq 0 ]
  ! grep -q "delete authpolicy" "$KUBECTL_CALLS_LOG"
  ! grep -q "delete httproute" "$KUBECTL_CALLS_LOG"
}

@test "si falla el borrado de rollback de la carrera, lo dice en vez de dejar la ruta colgada en silencio" {
  export KUBECTL_MOCK_ROUTES='[{"metadata":{"name":"api-manager-rival","namespace":"other","labels":{"apimgr-target":"other.app"}},"spec":{"hostnames":["api.expuesta.com"],"rules":[{"matches":[{"path":{"value":"/r1"}}]}]}}]'
  export KUBECTL_MOCK_FAIL=delete-authpolicy
  run run_reconcile apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "falló el rollback"
}

@test "rollback por carrera confirmada: publica el borrado ANTES de borrar del cluster" {
  find_route_conflicts() { printf '  conflicto de prueba\n'; return 1; }
  export -f find_route_conflicts
  gitops_publish_removal() { echo "GITOPS_REMOVAL_CALLED" >>"$KUBECTL_CALLS_LOG"; return 0; }
  export -f gitops_publish_removal
  run run_reconcile apply
  [ "$status" -ne 0 ]
  local removal_line delete_line
  removal_line=$(grep -n "GITOPS_REMOVAL_CALLED" "$KUBECTL_CALLS_LOG" | head -1 | cut -d: -f1)
  delete_line=$(grep -n "delete authpolicy api-manager-svc-1" "$KUBECTL_CALLS_LOG" | head -1 | cut -d: -f1)
  [ -n "$removal_line" ]
  [ -n "$delete_line" ]
  [ "$removal_line" -lt "$delete_line" ]
  grep -q "delete httproute api-manager-svc-1" "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "se detectó una carrera"
}

@test "rollback por RACE_STATUS 2 (no se pudo re-verificar): publica el borrado ANTES de borrar del cluster" {
  find_route_conflicts() { return 2; }
  export -f find_route_conflicts
  gitops_publish_removal() { echo "GITOPS_REMOVAL_CALLED" >>"$KUBECTL_CALLS_LOG"; return 0; }
  export -f gitops_publish_removal
  run run_reconcile apply
  [ "$status" -ne 0 ]
  local removal_line delete_line
  removal_line=$(grep -n "GITOPS_REMOVAL_CALLED" "$KUBECTL_CALLS_LOG" | head -1 | cut -d: -f1)
  delete_line=$(grep -n "delete authpolicy api-manager-svc-1" "$KUBECTL_CALLS_LOG" | head -1 | cut -d: -f1)
  [ -n "$removal_line" ]
  [ -n "$delete_line" ]
  [ "$removal_line" -lt "$delete_line" ]
  grep -q "delete httproute api-manager-svc-1" "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "no se pudo re-verificar colisiones"
}

@test "si falla el publish del borrado en el rollback por carrera confirmada, aborta sin tocar el cluster y avisa de la divergencia" {
  find_route_conflicts() { printf '  conflicto de prueba\n'; return 1; }
  export -f find_route_conflicts
  gitops_publish_removal() { return 1; }
  export -f gitops_publish_removal
  run run_reconcile apply
  [ "$status" -ne 0 ]
  ! grep -q "delete authpolicy" "$KUBECTL_CALLS_LOG"
  ! grep -q "delete httproute" "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "divergentes"
}

@test "si falla el publish del borrado en el rollback por RACE_STATUS 2, aborta sin tocar el cluster y avisa de la divergencia" {
  find_route_conflicts() { return 2; }
  export -f find_route_conflicts
  gitops_publish_removal() { return 1; }
  export -f gitops_publish_removal
  run run_reconcile apply
  [ "$status" -ne 0 ]
  ! grep -q "delete authpolicy" "$KUBECTL_CALLS_LOG"
  ! grep -q "delete httproute" "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "divergentes"
}

@test "gitops se publica ANTES del apply" {
  gitops_publish() { echo "GITOPS_PUBLISH_CALLED" >>"$KUBECTL_CALLS_LOG"; return 0; }
  export -f gitops_publish
  run run_reconcile apply
  [ "$status" -eq 0 ]
  local publish_line apply_line
  publish_line=$(grep -n "GITOPS_PUBLISH_CALLED" "$KUBECTL_CALLS_LOG" | head -1 | cut -d: -f1)
  apply_line=$(grep -n "apply -f" "$KUBECTL_CALLS_LOG" | head -1 | cut -d: -f1)
  [ -n "$publish_line" ]
  [ -n "$apply_line" ]
  [ "$publish_line" -lt "$apply_line" ]
}

@test "si falla la publicación gitops del apply, no se aplica nada" {
  gitops_publish() { echo "GITOPS_PUBLISH_CALLED" >>"$KUBECTL_CALLS_LOG"; return 1; }
  export -f gitops_publish
  run run_reconcile apply
  [ "$status" -ne 0 ]
  ! grep -q "apply -f" "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "falló la publicación de los manifiestos al repo gitops"
}

@test "gitops se publica ANTES del delete, y si falla no se borra nada" {
  gitops_publish_removal() { echo "GITOPS_REMOVAL_CALLED" >>"$KUBECTL_CALLS_LOG"; return 1; }
  export -f gitops_publish_removal
  run run_reconcile delete
  [ "$status" -ne 0 ]
  ! grep -q 'delete' "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "falló la publicación del borrado al repo gitops"
}

@test "sin GITOPS_REPO_URL el apply sigue andando igual que siempre" {
  unset GITOPS_REPO_URL
  run run_reconcile apply
  [ "$status" -eq 0 ]
  grep -q "apply -f" "$KUBECTL_CALLS_LOG"
}

@test "sin GITOPS_REPO_URL el delete sigue andando igual que siempre" {
  unset GITOPS_REPO_URL
  run run_reconcile delete
  [ "$status" -eq 0 ]
}

@test "con gitops habilitado y sin GITOPS_SUBSTRATE, el apply aborta nombrando la variable y no aplica nada" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo-aca"
  unset GITOPS_SUBSTRATE
  run run_reconcile apply
  [ "$status" -ne 0 ]
  ! grep -q "apply -f" "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "GITOPS_SUBSTRATE"
}

@test "con gitops habilitado y sin GITOPS_SUBSTRATE, el delete aborta nombrando la variable y no borra nada" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo-aca"
  unset GITOPS_SUBSTRATE
  run run_reconcile delete
  [ "$status" -ne 0 ]
  ! grep -q 'delete' "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "GITOPS_SUBSTRATE"
}
