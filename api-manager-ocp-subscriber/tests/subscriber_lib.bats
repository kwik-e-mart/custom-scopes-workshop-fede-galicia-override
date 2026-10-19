#!/usr/bin/env bats

load helpers

setup() {
  setup_common
  source "$SCRIPTS/subscriber_lib"
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-1",service:{id:"svc-1"}}}')
}

@test "callback_url arma la URL de la accion del service" {
  run callback_url svc-1 act-1
  [ "$output" = "https://api.nullplatform.com/service/svc-1/action/act-1" ]
}

@test "apim_request manda auth, idempotency y el body tal cual" {
  queue_response 202 '{"id":"op-1"}'
  apim_request POST /v1/subscriptions '{"a":"b \"c\""}' act-1
  [ "$APIM_HTTP_CODE" = "202" ]
  [ "$APIM_BODY" = '{"id":"op-1"}' ]
  grep -q '^POST https://apisub.test/v1/subscriptions idem=act-1 auth=Bearer tok-123 ' "$CURL_CALLS_LOG"
  [ "$(cat "$CURL_BODIES_DIR/0.json")" = '{"a":"b \"c\""}' ]
}

@test "apim_request no pone el token en los argumentos de curl" {
  queue_response 200 '{}'
  apim_request GET /v1/plans "" ""
  [ -s "$CURL_ARGV_LOG" ]
  ! grep -q 'tok-123' "$CURL_ARGV_LOG"
}

@test "apim_request pasa timeouts de conexion y total" {
  queue_response 200 '{}'
  apim_request GET /v1/plans "" ""
  grep -q 'timeouts=maxconnect$\|timeouts=connectmax$' "$CURL_CALLS_LOG"
}

@test "apim_request reintenta 503 y devuelve el primer codigo que no es 503" {
  queue_response 503 '{"title":"down"}'
  queue_response 503 '{"title":"down"}'
  queue_response 202 '{"id":"op-1"}'
  apim_request POST /v1/subscriptions '{}' act-1
  [ "$APIM_HTTP_CODE" = "202" ]
  [ "$(curl_call_count)" = "3" ]
}

@test "apim_request reintenta una falla de red como un 503" {
  queue_response 000 ''
  queue_response 202 '{"id":"op-1"}'
  apim_request POST /v1/subscriptions '{}' act-1
  [ "$APIM_HTTP_CODE" = "202" ]
}

@test "apim_request reintenta un timeout como un 503" {
  queue_response timeout ''
  queue_response 202 '{"id":"op-1"}'
  apim_request POST /v1/subscriptions '{}' act-1
  [ "$APIM_HTTP_CODE" = "202" ]
  [ "$(curl_call_count)" = "2" ]
}

@test "apim_request se rinde despues de 3 reintentos" {
  for _ in 1 2 3 4 5; do queue_response 503 '{"title":"down"}'; done
  apim_request POST /v1/subscriptions '{}' act-1
  [ "$APIM_HTTP_CODE" = "503" ]
  [ "$(curl_call_count)" = "4" ]
}

@test "apim_request sin body ni idempotency no los manda" {
  queue_response 200 '{}'
  apim_request GET /v1/plans "" ""
  grep -q '^GET https://apisub.test/v1/plans idem= auth=Bearer tok-123 ' "$CURL_CALLS_LOG"
}

@test "apim_problem_detail prefiere detail, despues title, despues el cuerpo" {
  [ "$(apim_problem_detail '{"title":"t","detail":"d"}')" = "d" ]
  [ "$(apim_problem_detail '{"title":"t"}')" = "t" ]
  [ "$(apim_problem_detail 'texto plano')" = "texto plano" ]
}

@test "apim_problem_detail recorta a 300 caracteres y saca caracteres de control" {
  long=$(printf 'x%.0s' $(seq 1 1000))
  [ "$(apim_problem_detail "$long" | wc -c | tr -d ' ')" = "300" ]
  [ "$(apim_problem_detail "$(printf 'a\033[31mb\nc')")" = "$(printf 'a[31mb\nc')" ]
}

@test "require_agent_config falla nombrando la variable vacia sin llamar a curl" {
  API_SUBSCRIBER_URL=""
  run require_agent_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"API_SUBSCRIBER_URL"* ]] || false
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "require_agent_config rechaza una URL que no es https" {
  API_SUBSCRIBER_URL="http://apisub.test"
  run require_agent_config
  [ "$status" -ne 0 ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"https"* ]]
}

@test "close_action manda status, mensaje y results como JSON" {
  close_action success 'listo "ya"' '{"x":1}'
  [ "$(np_last_update_flag --status)" = "success" ]
  [ "$(np_last_update_flag --messages | jq -r '.[0].message')" = 'listo "ya"' ]
  [ "$(np_last_update_flag --messages | jq -r '.[0].level')" = "info" ]
  [ "$(np_last_update_flag --results)" = '{"x":1}' ]
}

@test "close_action failed usa nivel error" {
  close_action failed "no"
  [ "$(np_last_update_flag --messages | jq -r '.[0].level')" = "error" ]
}

@test "close_action que no llega a nullplatform no da la accion por cerrada" {
  export NP_MOCK_UPDATE_FAIL=1
  run bash -c "source '$SCRIPTS/subscriber_lib'; trap close_on_unexpected_exit EXIT; close_action success listo"
  [ "$(np_update_count)" = "2" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "close_action deja la marca de accion resuelta para el handler" {
  export SUBSCRIBER_SETTLED_MARKER="$BATS_TEST_TMPDIR/settled"
  : >"$SUBSCRIBER_SETTLED_MARKER"
  close_action failed "no"
  [ -s "$SUBSCRIBER_SETTLED_MARKER" ]
}

@test "report_progress no manda status" {
  report_progress "en curso" '{"operation_id":"op-1"}'
  [ -z "$(np_last_update_flag --status)" ]
  [ "$(np_last_update_flag --results)" = '{"operation_id":"op-1"}' ]
}

@test "close_on_unexpected_exit cierra failed si nadie cerro la accion" {
  run bash -c "source '$SCRIPTS/subscriber_lib'; trap close_on_unexpected_exit EXIT; false"
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "close_on_unexpected_exit no hace nada si la accion quedo abierta a proposito" {
  run bash -c "source '$SCRIPTS/subscriber_lib'; trap close_on_unexpected_exit EXIT; report_progress 'en curso'"
  [ "$(np_update_count)" = "1" ]
  [ -z "$(np_last_update_flag --status)" ]
}

@test "require_subscription_id_format rechaza ids con caracteres de path" {
  run require_subscription_id_format "sub-a--b/../x"
  [ "$status" -ne 0 ]
  run require_subscription_id_format "sub-greeting-echo--sigla-x-qa"
  [ "$status" -eq 0 ]
}

@test "require_subscription_id_format rechaza un punto final" {
  run require_subscription_id_format "sub-greeting--sigla-x-qa."
  [ "$status" -ne 0 ]
}
