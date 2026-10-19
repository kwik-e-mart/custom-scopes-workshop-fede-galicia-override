#!/usr/bin/env bats

load helpers

setup() {
  bats_require_minimum_version 1.5.0
  setup_common
  EXTERNAL="${BATS_TEST_DIRNAME}/../entrypoint/external"
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT="'$(jq -nc '{notification:{action:"list-apim-plans",application:{id:1}}}')'"
}

@test "devuelve solo los planes como JSON por stdout" {
  queue_response 200 '{"items":[{"id":"bronze","maxTps":5},{"id":"no-limits"}]}'
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -eq 0 ]
  [ "$output" = '{"plans":[{"id":"bronze","maxTps":5},{"id":"no-limits"}]}' ]
  grep -q '^GET https://apisub.test/v1/plans idem= auth=Bearer tok-123$' "$CURL_CALLS_LOG"
}

@test "acepta la accion en la raiz del contexto" {
  NP_ACTION_CONTEXT=$(jq -nc '{action:"list-apim-plans"}')
  queue_response 200 '{"items":[]}'
  run --separate-stderr bash "$EXTERNAL"
  [ "$output" = '{"plans":[]}' ]
}

@test "un error de APIM no escribe nada en stdout" {
  queue_response 500 '{"title":"boom"}'
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ -s "$CURL_CALLS_LOG" ]
  [[ "$stderr" == *"HTTP 500"* ]]
}

@test "una respuesta sin items no escribe nada en stdout" {
  queue_response 200 '{"foo":1}'
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ -s "$CURL_CALLS_LOG" ]
  [[ "$stderr" == *"items"* ]]
}

@test "una accion desconocida falla sin llamar a APIM" {
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{action:"otra"}}')
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$stderr" == *"'otra'"* ]]
}

@test "sin URL del agente falla sin escribir en stdout" {
  API_SUBSCRIBER_URL=""
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *API_SUBSCRIBER_URL* ]]
}
