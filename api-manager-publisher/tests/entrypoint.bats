#!/usr/bin/env bats

load helpers
load publisher_helpers

setup() {
  setup_publisher
  ENTRYPOINT="${BATS_TEST_DIRNAME}/../entrypoint/entrypoint"
  SERVICE_HANDLER="${BATS_TEST_DIRNAME}/../entrypoint/service"
  LINK_HANDLER="${BATS_TEST_DIRNAME}/../entrypoint/link"
  export NP_ACTION_CONTEXT
}

ctx() {
  jq -nc --argjson n "$1" '{notification: $n}'
}

@test "servicio y link corren con el cierre automatico apagado" {
  NP_ACTION_CONTEXT=$(ctx '{"id":"a","type":"create","service":{"id":"s"}}')
  run bash "$ENTRYPOINT"
  NP_ACTION_CONTEXT=$(ctx '{"id":"a","type":"create","service":{"id":"s"},"link":{"id":"l"}}')
  run bash "$ENTRYPOINT"
  [ "$(jq -c 'select(.[0:2] == ["service-action","exec"]) | (index("--disable-auto-action-update") != null)' "$NP_CALLS_LOG" | tr '\n' ' ')" = "true true " ]
  [ "$(jq -r 'select(.[0:2] == ["service-action","exec"]) | map(select(startswith("--script="))) | .[0] | split("/") | last' "$NP_CALLS_LOG" | tr '\n' ' ')" = "service link " ]
}

@test "el handler service rutea por type al workflow" {
  for type in create update delete; do
    : >"$NP_CALLS_LOG"
    SERVICE_ACTION_TYPE=$type SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$SERVICE_HANDLER"
    [ "$status" -eq 0 ]
    jq -e --arg t "$type" 'select(.[0:3] == ["service","workflow","exec"]) | map(select(endswith("/workflows/" + $t + ".yaml"))) | length == 1' "$NP_CALLS_LOG"
  done
}

@test "el handler link rutea alta, cambio y baja a sus workflows" {
  for pair in create:link update:link_update delete:unlink; do
    : >"$NP_CALLS_LOG"
    SERVICE_ACTION_TYPE=${pair%%:*} SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$LINK_HANDLER"
    [ "$status" -eq 0 ]
    jq -e --arg w "${pair##*:}" 'select(.[0:3] == ["service","workflow","exec"]) | map(select(endswith("/workflows/" + $w + ".yaml"))) | length == 1' "$NP_CALLS_LOG"
  done
}

@test "un type de link desconocido cierra la accion del link failed" {
  SERVICE_ACTION_TYPE=custom SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$LINK_HANDLER"
  [ "$status" -ne 0 ]
  [ "$(np_updates | tail -n1 | jq -c '.[0:3]')" = '["link","action","update"]' ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "si el workflow falla antes de resolver la accion, el handler la cierra failed" {
  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "$1 $2" = "service workflow" ]; then exit 1; fi
exit 0
MOCK
  SERVICE_ACTION_TYPE=create SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$SERVICE_HANDLER"
  [ "$status" -ne 0 ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "si el step ya resolvio la accion, el handler no la vuelve a cerrar" {
  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "$1 $2" = "service workflow" ]; then printf 1 >"$SUBSCRIBER_SETTLED_MARKER"; exit 1; fi
exit 0
MOCK
  SERVICE_ACTION_TYPE=create SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$LINK_HANDLER"
  [ "$status" -ne 0 ]
  [ "$(jq -c 'select(.[0:3] == ["service","workflow","exec"])' "$NP_CALLS_LOG" | wc -l | tr -d ' ')" = "1" ]
  [ "$(np_update_count)" = "0" ]
}
