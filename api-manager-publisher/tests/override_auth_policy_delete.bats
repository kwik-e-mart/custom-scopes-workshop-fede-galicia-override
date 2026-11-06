#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  OVERRIDE="${BATS_TEST_DIRNAME}/../override"
  STEP="$OVERRIDE/deployment/scripts/remove_apim_auth_policy"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/out"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
  export SCOPE_ID=5 DEPLOYMENT_ID=6
  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  : >"$KUBECTL_CALLS_LOG"
  export KUBECTL_MOCK_POLICIES='{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"kuadrant.io/v1","kind":"AuthPolicy","metadata":{"name":"payments-test-kuadrant-b2c-1-k-8-s-main-5-internal","namespace":"payments"}}]}'
  unset KUBECTL_MOCK_FAIL

  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS_LOG"
if [ "${1-} ${2-}" != "get authpolicy" ]; then echo "mock kubectl: comando no esperado: $*" >&2; exit 2; fi
if [ "${KUBECTL_MOCK_FAIL:-0}" = "1" ]; then echo "kubectl: forbidden" >&2; exit 1; fi
printf '%s\n' "$KUBECTL_MOCK_POLICIES"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
}

run_step() {
  run bash -c 'set -euo pipefail; source "$1"; echo NEXT_STEP_RAN' _ "$STEP"
}

@test "el borrado del deployment saca la AuthPolicy despues de chequear que no haya API publicada" {
  [ "$(yq -o=json -I=0 '[.steps[] | pick(["name", "after", "file"])]' "$OVERRIDE/deployment/workflows/delete.yaml")" = \
    '[{"name":"require_no_published_api","after":"build context","file":"$OVERRIDES_PATH/deployment/scripts/require_no_published_api"},{"name":"remove_apim_auth_policy","after":"build context","file":"$OVERRIDES_PATH/deployment/scripts/remove_apim_auth_policy"}]' ]
}

@test "deja las AuthPolicies del scope para que el borrado del scope base las saque junto con la route" {
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -qx -- "get authpolicy -A -l app.kubernetes.io/managed-by=api-manager-publisher,scope_id=5 -o json" "$KUBECTL_CALLS_LOG"
  [ "$(yq -o=json -I=0 '.items[] | [.kind, .metadata.namespace, .metadata.name] | join("/")' "$OUTPUT_DIR/authpolicy-apim-5-6.yaml")" = '"AuthPolicy/payments/payments-test-kuadrant-b2c-1-k-8-s-main-5-internal"' ]
}

@test "sin AuthPolicies del scope no deja archivo" {
  export KUBECTL_MOCK_POLICIES='{"apiVersion":"v1","kind":"List","items":[]}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ ! -e "$OUTPUT_DIR/authpolicy-apim-5-6.yaml" ]
}

@test "si no puede leer las AuthPolicies frena el borrado" {
  export KUBECTL_MOCK_FAIL=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [[ "$output" == *"AuthPolic"* ]]
}
