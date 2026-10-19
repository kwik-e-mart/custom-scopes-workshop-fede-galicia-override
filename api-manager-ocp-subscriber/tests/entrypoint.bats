#!/usr/bin/env bats

load helpers

setup() {
  setup_common
  ENTRYPOINT="${BATS_TEST_DIRNAME}/../entrypoint/entrypoint"
  SERVICE_HANDLER="${BATS_TEST_DIRNAME}/../entrypoint/service"
  LINK_HANDLER="${BATS_TEST_DIRNAME}/../entrypoint/link"
  export NP_ACTION_CONTEXT
}

ctx() {
  jq -nc --argjson n "$1" '{notification: $n}'
}

@test "las acciones del service corren con el cierre automatico apagado" {
  NP_ACTION_CONTEXT=$(ctx '{"id":"act-1","type":"create","service":{"id":"svc-1"}}')
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  jq -e 'select(.[0:2] == ["service-action","exec"]) | (index("--disable-auto-action-update") != null) and (map(select(test("--script=.*/service$"))) | length == 1)' "$NP_CALLS_LOG"
}

@test "los links corren con el cierre automatico" {
  NP_ACTION_CONTEXT=$(ctx '{"id":"act-1","type":"create","link":{"id":"l-1"},"service":{"id":"svc-1"}}')
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  jq -e 'select(.[0:2] == ["service-action","exec"]) | (index("--disable-auto-action-update") == null) and (map(select(test("--script=.*/link$"))) | length == 1)' "$NP_CALLS_LOG"
}

@test "el handler service rutea por type al workflow" {
  for type in create update delete; do
    : >"$NP_CALLS_LOG"
    SERVICE_ACTION_TYPE=$type SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$SERVICE_HANDLER"
    [ "$status" -eq 0 ]
    jq -e --arg t "$type" 'select(.[0:3] == ["service","workflow","exec"]) | map(select(endswith("/workflows/" + $t + ".yaml"))) | length == 1' "$NP_CALLS_LOG"
  done
}

@test "si el workflow falla el handler service cierra la accion failed" {
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

@test "un type desconocido cierra la accion failed sin correr workflows" {
  SERVICE_ACTION_TYPE=custom SERVICE_ACTION=algo SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$SERVICE_HANDLER"
  [ "$status" -ne 0 ]
  [ "$(jq -c 'select(.[0:3] == ["service","workflow","exec"])' "$NP_CALLS_LOG" | wc -l | tr -d ' ')" = "0" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "el handler link no hace nada" {
  run bash "$LINK_HANDLER"
  [ "$status" -eq 0 ]
  [ ! -s "$NP_CALLS_LOG" ]
  [ ! -s "$CURL_CALLS_LOG" ]
}

@test "el handler service no pide los secretos de los providers" {
  SERVICE_ACTION_TYPE=create SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$SERVICE_HANDLER"
  [ "$(jq -c 'select(.[0:3] == ["service","workflow","exec"]) | select(index("--include-secrets") != null)' "$NP_CALLS_LOG" | wc -l | tr -d ' ')" = "0" ]
  [ "$(jq -c 'select(.[0:3] == ["service","workflow","exec"])' "$NP_CALLS_LOG" | wc -l | tr -d ' ')" = "1" ]
}

@test "si el step ya resolvio la accion y el workflow falla, el handler no la vuelve a cerrar" {
  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "$1 $2" = "service workflow" ]; then
  printf 1 >"$SUBSCRIBER_SETTLED_MARKER"
  exit 1
fi
exit 0
MOCK
  SERVICE_ACTION_TYPE=create SERVICE_PATH="${BATS_TEST_DIRNAME}/.." run bash "$SERVICE_HANDLER"
  [ "$status" -ne 0 ]
  [ "$(np_update_count)" = "0" ]
}

@test "sin NP_ACTION_CONTEXT sale con error sin llamar a np" {
  unset NP_ACTION_CONTEXT
  run bash "$ENTRYPOINT"
  [ "$status" -ne 0 ]
  [ ! -s "$NP_CALLS_LOG" ]
}

@test "una notificacion sin link ni service sale con error sin llamar a np" {
  NP_ACTION_CONTEXT=$(ctx '{"id":"act-1","type":"create","marker_key":"x"}')
  run bash "$ENTRYPOINT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"marker_key"* ]] || false
  [ ! -s "$NP_CALLS_LOG" ]
}

@test "saca las comillas simples que agrega el channel" {
  NP_ACTION_CONTEXT="'$(ctx '{"id":"act-1","type":"create","service":{"id":"svc-1"}}')'"
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  jq -e 'select(.[0:2] == ["service-action","exec"]) | map(select(test("--script=.*/service$"))) | length == 1' "$NP_CALLS_LOG"
}
