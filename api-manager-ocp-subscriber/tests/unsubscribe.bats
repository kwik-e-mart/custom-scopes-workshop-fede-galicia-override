#!/usr/bin/env bats

load helpers

setup() {
  setup_common
  STEP="$SCRIPTS/unsubscribe"
  export NP_ACTION_CONTEXT CONTEXT
  set_attrs '{"subscription_id":"sub-greeting--sigla-x-qa","owns_subscription":true}'
  CONTEXT=$(jq -nc '{providers:{"container-orchestration":{cluster:{namespace:"sigla-x-qa"}}}}')
}

set_attrs() {
  NP_ACTION_CONTEXT=$(jq -nc --argjson a "$1" '{notification:{id:"act-3",service:{id:"svc-1",attributes:$a}}}')
}

queue_owner() {
  queue_response 200 "$(jq -nc --arg ns "$1" '{id:"sub-greeting--sigla-x-qa",consumerNamespace:$ns}')"
}

@test "202 verifica el dueño, da de baja y cierra success" {
  queue_owner sigla-x-qa
  queue_response 202 '{"id":"op-3"}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(head -n1 "$CURL_CALLS_LOG" | cut -d' ' -f1-2)" = "GET https://apisub.test/v1/subscriptions/sub-greeting--sigla-x-qa" ]
  grep -q '^DELETE https://apisub.test/v1/subscriptions/sub-greeting--sigla-x-qa idem=act-3 ' "$CURL_CALLS_LOG"
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "404 en el DELETE cierra success" {
  queue_owner sigla-x-qa
  queue_response 404 '{"title":"Not Found"}'
  run_step
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "una suscripcion que APIM ya no conoce cierra success sin DELETE" {
  queue_response 404 '{"title":"Not Found"}'
  run_step
  [ "$(head -n1 "$CURL_CALLS_LOG" | cut -d' ' -f1)" = "GET" ]
  [ "$status" -eq 0 ]
  [ "$(curl_call_count)" = "1" ]
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "una suscripcion de otro namespace falla sin DELETE" {
  queue_owner otro-ns-prd
  run_step
  [ "$status" -ne 0 ]
  [ "$(grep -c '^DELETE ' "$CURL_CALLS_LOG")" = "0" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "owns_subscription false no llama a APIM y cierra success" {
  set_attrs '{"subscription_id":"sub-greeting--sigla-x-qa","owns_subscription":false}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "sin owns_subscription no llama a APIM" {
  set_attrs '{"subscription_id":"sub-greeting--sigla-x-qa"}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "sin subscription_id no llama a APIM" {
  set_attrs '{"owns_subscription":true}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "subscription_id con formato invalido falla sin llamar a APIM" {
  set_attrs '{"subscription_id":"sub-a--b?x=1","owns_subscription":true}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "sin namespace en el provider falla sin llamar a APIM" {
  CONTEXT='{"providers":{}}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "otro codigo cierra failed con el detail" {
  queue_owner sigla-x-qa
  queue_response 422 '{"detail":"no se puede"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "sin token del agente y owns_subscription false no falla" {
  unset API_SUBSCRIBER_TOKEN
  set_attrs '{"subscription_id":"sub-greeting--sigla-x-qa","owns_subscription":false}'
  run_step
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "si cerrar success no llega a nullplatform, el trap intenta cerrar failed" {
  set_attrs '{"subscription_id":"sub-greeting--sigla-x-qa","owns_subscription":false}'
  export NP_MOCK_UPDATE_FAIL=1
  run_step
  [ "$(np_update_count)" = "2" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}
