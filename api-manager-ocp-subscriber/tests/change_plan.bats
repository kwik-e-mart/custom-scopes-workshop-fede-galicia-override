#!/usr/bin/env bats

load helpers

setup() {
  setup_common
  CHANGE="$SCRIPTS/change_plan"
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-2",service:{id:"svc-1",attributes:{subscription_id:"sub-greeting--sigla-x-qa",owns_subscription:false}},parameters:{plan_id:"bronze"}}}')
}

run_step() {
  run bash -c "source '$CHANGE'; echo NEXT_STEP_RAN"
}

@test "202 manda PATCH con plan y callback y deja la accion abierta" {
  queue_response 202 '{"id":"op-2","state":"Committed"}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q '^PATCH https://apisub.test/v1/subscriptions/sub-greeting--sigla-x-qa idem=act-2 ' "$CURL_CALLS_LOG"
  [ "$(jq -c . "$CURL_BODIES_DIR/0.json")" = '{"planId":"bronze","callbackUrl":"https://api.nullplatform.com/service/svc-1/action/act-2"}' ]
  [ -z "$(np_last_update_flag --status)" ]
  [ "$(np_last_update_flag --results)" = '{"operation_id":"op-2"}' ]
}

@test "funciona aunque la instancia no haya creado la suscripcion" {
  queue_response 202 '{"id":"op-2"}'
  run_step
  [ -s "$CURL_CALLS_LOG" ]
}

@test "sin subscription_id falla sin llamar a APIM" {
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-2",service:{id:"svc-1",attributes:{}},parameters:{plan_id:"bronze"}}}')
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "subscription_id con formato invalido falla sin llamar a APIM" {
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-2",service:{id:"svc-1",attributes:{subscription_id:"sub-a--b/../../admin"}},parameters:{plan_id:"bronze"}}}')
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "422 cierra failed con el detail" {
  queue_response 422 '{"detail":"Plan inválido"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"Plan inválido"* ]]
}
