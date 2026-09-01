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

  export KEYS_NAMESPACE=kuadrant-system
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-1",link:{id:"777"},service:{id:"svc-1"}}}')

  unset KUBECTL_MOCK_FAIL MANAGED_LABEL TARGET_LABEL APP_TARGET
  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  : >"$KUBECTL_CALLS_LOG"
  export KUBECTL_STDIN_LOG="$BATS_TEST_TMPDIR/kubectl-stdin.log"
  : >"$KUBECTL_STDIN_LOG"
  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  : >"$NP_CALLS_LOG"

  export NP_MOCK_SERVICE='{"entity_nrn":"organization=1:account=1:namespace=10:application=20"}'
  export NP_MOCK_NAMESPACE='{"slug":"payments"}'
  export NP_MOCK_APPLICATION='{"slug":"reports"}'

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
SUBCMD="$1 $2"
case "$SUBCMD" in
  "service action")
    echo '{"statusCode":400,"code":"FST_ERR_VALIDATION","error":"Bad Request","message":"Action does not belong to the service"}' >&2
    exit 1 ;;
  "link action")
    [ "${NP_MOCK_LINK_ACTION_FALLA:-}" = "1" ] && exit 1
    case " $* " in
      *" --link-id "*) ;;
      *) echo "missing required flags: link-id, link-action-id" >&2; exit 1 ;;
    esac
    case " $* " in
      *" --link-action-id "*) ;;
      *) echo "missing required flags: link-id, link-action-id" >&2; exit 1 ;;
    esac
    echo '{}' ;;
  "service read")
    printf %s "$NP_MOCK_SERVICE" ;;
  "namespace read")
    printf %s "$NP_MOCK_NAMESPACE" ;;
  "application read")
    printf %s "$NP_MOCK_APPLICATION" ;;
  *)
    echo '{}' ;;
esac
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

@test "el target del secret sale del service, no de un APP_TARGET heredado del contexto" {
  export APP_TARGET="consumidor-ns.consumidor-app"
  run bash "$MINT"
  [ "$status" -eq 0 ]
  grep -q '"apimgr-target":"payments.reports"' "$KUBECTL_STDIN_LOG"
  ! grep -q "consumidor" "$KUBECTL_STDIN_LOG"
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

@test "mint_key aborta si la notificacion no trae service.id" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-1",link:{id:"777"}}}')
  run bash "$MINT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "service.id"
  [ ! -s "$KUBECTL_CALLS_LOG" ]
}

@test "mint_key aborta si el link.id tiene mayusculas" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-1",link:{id:"ABC123"},service:{id:"svc-1"}}}')
  run bash "$MINT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "link.id inválido"
  [ ! -s "$KUBECTL_CALLS_LOG" ]
}

@test "mint_key aborta si el link.id empieza o termina con guion" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-1",link:{id:"-abc123"},service:{id:"svc-1"}}}')
  run bash "$MINT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "link.id inválido"

  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-1",link:{id:"abc123-"},service:{id:"svc-1"}}}')
  run bash "$MINT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "link.id inválido"
}

@test "mint_key acepta un link.id en minusculas con guion interno" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-1",link:{id:"abc-123"},service:{id:"svc-1"}}}')
  run bash "$MINT"
  [ "$status" -eq 0 ]
}

@test "mint_key aborta si no puede resolver la aplicacion duena del service" {
  export NP_MOCK_SERVICE='{}'
  run bash "$MINT"
  [ "$status" -ne 0 ]
  [ ! -s "$KUBECTL_CALLS_LOG" ]
}

@test "mint_key aborta si el target del service excede los 63 caracteres del label" {
  export NP_MOCK_NAMESPACE='{"slug":"namespace-con-un-nombre-bastante-largo-de-verdad"}'
  export NP_MOCK_APPLICATION='{"slug":"aplicacion-con-un-nombre-tambien-bastante-largo"}'
  run bash "$MINT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "63 caracteres"
  [ ! -s "$KUBECTL_CALLS_LOG" ]
}

@test "mint_key escribe los resultados con np link action update, no con service action update" {
  run bash "$MINT"
  [ "$status" -eq 0 ]
  grep -q "^link action update " "$NP_CALLS_LOG"
  ! grep -q "^service action update " "$NP_CALLS_LOG"
}

@test "mint_key le pasa a np los ids del link y de su accion" {
  run bash "$MINT"
  [ "$status" -eq 0 ]
  grep -q -- "--link-id 777" "$NP_CALLS_LOG"
  grep -q -- "--link-action-id act-1" "$NP_CALLS_LOG"
}

@test "mint_key aborta si la notificacion no trae el id de la accion del link" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{link:{id:"777"},service:{id:"svc-1"}}}')
  run bash "$MINT"
  [ "$status" -ne 0 ]
  ! grep -q "create -f -" "$KUBECTL_CALLS_LOG"
}

@test "si falla la escritura de los resultados, mint_key retira el Secret para que el reintento no choque" {
  export NP_MOCK_LINK_ACTION_FALLA=1
  run bash "$MINT"
  [ "$status" -ne 0 ]
  grep -q "^delete secret api-manager-.* -n kuadrant-system --ignore-not-found\$" "$KUBECTL_CALLS_LOG"
  echo "$output" | grep -q "Reintentar el link es seguro"
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
