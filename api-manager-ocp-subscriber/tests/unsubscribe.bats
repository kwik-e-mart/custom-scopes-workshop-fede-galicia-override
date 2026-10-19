#!/usr/bin/env bats

load helpers

setup() {
  setup_common
  UNSUB="$SCRIPTS/unsubscribe"
  export NP_ACTION_CONTEXT
  set_attrs '{"subscription_id":"sub-greeting--sigla-x-qa","owns_subscription":true}'
}

set_attrs() {
  NP_ACTION_CONTEXT=$(jq -nc --argjson a "$1" '{notification:{id:"act-3",service:{id:"svc-1",attributes:$a}}}')
}

run_step() {
  run bash -c "source '$UNSUB'; echo NEXT_STEP_RAN"
}

@test "202 da de baja y cierra success" {
  queue_response 202 '{"id":"op-3"}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q '^DELETE https://apisub.test/v1/subscriptions/sub-greeting--sigla-x-qa idem=act-3 ' "$CURL_CALLS_LOG"
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "404 cierra success" {
  queue_response 404 '{"title":"Not Found"}'
  run_step
  [ "$(np_last_update_flag --status)" = "success" ]
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

@test "otro codigo cierra failed con el detail" {
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
