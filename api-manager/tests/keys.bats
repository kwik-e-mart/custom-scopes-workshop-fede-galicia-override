#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  MINT="${BATS_TEST_DIRNAME}/../scripts/k8s/mint_key"
  REVOKE="${BATS_TEST_DIRNAME}/../scripts/k8s/revoke_key"

  export LOG_FILE="$BATS_TEST_TMPDIR/log.txt"
  : >"$LOG_FILE"
  log() {
    local level="${1:-info}" message="${2:-}"
    printf '%s: %s\n' "$level" "$message" >>"$LOG_FILE"
    if [ "$level" = "error" ]; then
      echo "$message" >&2
    else
      echo "$message"
    fi
  }
  export -f log

  export APP_TARGET=payments.reports
  export KEYS_NAMESPACE=kuadrant-system
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{link:{id:"777"}}}')

  unset KUBECTL_MOCK_FAIL MANAGED_LABEL TARGET_LABEL
  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  : >"$KUBECTL_CALLS_LOG"
  export KUBECTL_STDIN_LOG="$BATS_TEST_TMPDIR/kubectl-stdin.log"
  : >"$KUBECTL_STDIN_LOG"
  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  : >"$NP_CALLS_LOG"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS_LOG"
case "$*" in
  "create -f -")
    if [ "${KUBECTL_MOCK_FAIL:-}" = create ]; then
      cat >/dev/null
      exit 1
    fi
    cat >>"$KUBECTL_STDIN_LOG"
    exit 0
    ;;
  *"delete secret"*)
    [ "${KUBECTL_MOCK_FAIL:-}" = delete ] && exit 1
    exit 0
    ;;
esac
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"

  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NP_CALLS_LOG"
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "mint_key crea el secret con los tres labels" {
  run bash "$MINT"
  [ "$status" -eq 0 ]
  grep -q '"authorino.kuadrant.io/managed-by":"authorino"' "$KUBECTL_STDIN_LOG"
  grep -q '"api-manager.nullplatform.io/managed":"true"' "$KUBECTL_STDIN_LOG"
  grep -q '"apimgr-target":"payments.reports"' "$KUBECTL_STDIN_LOG"
}

@test "mint_key crea el secret con un create puro (POST), no con apply" {
  run bash "$MINT"
  [ "$status" -eq 0 ]
  grep -q "^create -f -\$" "$KUBECTL_CALLS_LOG"
  ! grep -qi "apply" "$KUBECTL_CALLS_LOG"
}

@test "mint_key genera una key distinta en cada corrida" {
  run bash "$MINT"
  [ "$status" -eq 0 ]
  local a; a=$(grep -o '"api_key":"[^"]*"' "$KUBECTL_STDIN_LOG" | tail -1)
  : >"$KUBECTL_STDIN_LOG"
  run bash "$MINT"
  [ "$status" -eq 0 ]
  local b; b=$(grep -o '"api_key":"[^"]*"' "$KUBECTL_STDIN_LOG" | tail -1)
  [ -n "$a" ]
  [ -n "$b" ]
  [ "$a" != "$b" ]
}

@test "mint_key no escribe la key en el log" {
  run bash "$MINT"
  [ "$status" -eq 0 ]
  ! grep -qi "api_key=" "$LOG_FILE"
  ! echo "$output" | grep -qE "[a-f0-9]{64}"
}

@test "mint_key aborta si falla la creacion del secret" {
  export KUBECTL_MOCK_FAIL=create
  run bash "$MINT"
  [ "$status" -ne 0 ]
}

@test "mint_key aborta si la notificacion no trae link.id y no usa un default" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{marker_test_key:"x"}}')
  run bash "$MINT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "marker_test_key"
  [ ! -s "$KUBECTL_CALLS_LOG" ]
}

@test "revoke_key borra el secret del link" {
  run bash "$REVOKE"
  [ "$status" -eq 0 ]
  grep -q "delete secret api-manager-777" "$KUBECTL_CALLS_LOG"
}

@test "revoke_key aborta si falla el borrado en vez de reportar exito" {
  export KUBECTL_MOCK_FAIL=delete
  run bash "$REVOKE"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "sigue siendo válida"
}
