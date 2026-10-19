#!/usr/bin/env bats

load helpers

setup() {
  setup_common
  STEP="$SCRIPTS/change_plan"
  export NP_ACTION_CONTEXT CONTEXT
  set_service '{"subscription_id":"sub-greeting--sigla-x-qa","owns_subscription":false}' '{"plan_id":"bronze"}'
  CONTEXT=$(jq -nc '{providers:{"container-orchestration":{cluster:{namespace:"sigla-x-qa"}}}}')
}

set_service() {
  NP_ACTION_CONTEXT=$(jq -nc --argjson a "$1" --argjson p "$2" '{notification:{id:"act-2",service:{id:"svc-1",attributes:$a},parameters:$p}}')
}

queue_owner() {
  queue_response 200 "$(jq -nc --arg ns "$1" '{id:"sub-greeting--sigla-x-qa",consumerNamespace:$ns,state:"Registered"}')"
}

@test "202 verifica el dueño, manda PATCH con plan y callback y deja la accion abierta" {
  queue_owner sigla-x-qa
  queue_response 202 '{"id":"op-2","state":"Committed"}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(head -n1 "$CURL_CALLS_LOG" | cut -d' ' -f1-2)" = "GET https://apisub.test/v1/subscriptions/sub-greeting--sigla-x-qa" ]
  grep -q '^PATCH https://apisub.test/v1/subscriptions/sub-greeting--sigla-x-qa idem=act-2 ' "$CURL_CALLS_LOG"
  [ "$(jq -c . "$CURL_BODIES_DIR/1.json")" = '{"planId":"bronze","callbackUrl":"https://api.nullplatform.com/service/svc-1/action/act-2"}' ]
  [ -z "$(np_last_update_flag --status)" ]
  [ "$(np_last_update_flag --results)" = '{"operation_id":"op-2"}' ]
}

@test "funciona aunque la instancia no haya creado la suscripcion" {
  queue_owner sigla-x-qa
  queue_response 202 '{"id":"op-2"}'
  run_step
  grep -q '^PATCH ' "$CURL_CALLS_LOG"
}

@test "una suscripcion de otro namespace falla sin PATCH" {
  queue_owner otro-ns-prd
  run_step
  [ "$status" -ne 0 ]
  [ "$(grep -c '^PATCH ' "$CURL_CALLS_LOG")" = "0" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"otro-ns-prd"* ]] || false
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "una suscripcion que APIM no conoce falla sin PATCH" {
  queue_response 404 '{"title":"Not Found"}'
  run_step
  [ "$(head -n1 "$CURL_CALLS_LOG" | cut -d' ' -f1)" = "GET" ]
  [ "$(curl_call_count)" = "1" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "sin namespace en el provider falla sin llamar a APIM" {
  CONTEXT='{"providers":{}}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "sin subscription_id falla sin llamar a APIM" {
  set_service '{}' '{"plan_id":"bronze"}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "subscription_id con formato invalido falla sin llamar a APIM" {
  set_service '{"subscription_id":"sub-a--b/../../admin"}' '{"plan_id":"bronze"}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "plan_id con caracteres invalidos falla sin llamar a APIM" {
  set_service '{"subscription_id":"sub-greeting--sigla-x-qa"}' '{"plan_id":"../x"}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "422 cierra failed con el detail" {
  queue_owner sigla-x-qa
  queue_response 422 '{"detail":"Plan inválido"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"Plan inválido"* ]]
}
