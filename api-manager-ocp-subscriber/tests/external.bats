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
  grep -q '^GET https://apisub.test/v1/plans idem= auth=Bearer tok-123 ' "$CURL_CALLS_LOG"
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

@test "no pone el token en los argumentos de curl y pasa timeouts" {
  queue_response 200 '{"items":[]}'
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'tok-123' "$CURL_ARGV_LOG")" = "0" ]
  grep -q ' auth=Bearer tok-123 timeouts=' "$CURL_CALLS_LOG"
  grep -q 'timeouts=maxconnect$\|timeouts=connectmax$' "$CURL_CALLS_LOG"
}

@test "devuelve solo id y maxTps de cada plan" {
  queue_response 200 '{"items":[{"id":"gold","maxTps":20,"owner":"apim","internal":"x"},{"id":"no-limits","notes":"y"}]}'
  run --separate-stderr bash "$EXTERNAL"
  [ "$output" = '{"plans":[{"id":"gold","maxTps":20},{"id":"no-limits"}]}' ]
}

@test "rechaza una URL que no es https sin llamar a curl" {
  API_SUBSCRIBER_URL="http://apisub.test"
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$stderr" == *https* ]]
}

@test "un error de APIM se reporta recortado" {
  queue_response 500 "$(printf 'x%.0s' $(seq 1 2000))"
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -ne 0 ]
  [ "${#stderr}" -lt 500 ]
}

@test "no usa archivos temporales" {
  queue_response 200 '{"items":[{"id":"gold","maxTps":20}]}'
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- ' -o ' "$CURL_ARGV_LOG")" = "0" ]
  [ "$output" = '{"plans":[{"id":"gold","maxTps":20}]}' ]
}

@test "una falla de red no escribe nada en stdout" {
  queue_response 000 ''
  run --separate-stderr bash "$EXTERNAL"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"HTTP 000"* ]]
}
