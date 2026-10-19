#!/usr/bin/env bats

load ../../api-manager-ocp-subscriber/tests/helpers
load publisher_helpers

setup() {
  setup_publisher
  export NP_ACTION_CONTEXT CONTEXT
  CONTEXT=$(jq -nc '{providers:{"container-orchestration":{cluster:{namespace:"ledger"}}}}')
}

link_context() {
  NP_ACTION_CONTEXT=$(jq -nc --argjson a "$1" --argjson p "$2" '{notification:{id:"act-l",type:"create",service:{id:"svc-1"},link:{id:"l-1",attributes:$a},parameters:$p}}')
}

@test "el link pide la suscripcion con el callback del link y deja la accion abierta" {
  STEP="$PUBLISHER_SCRIPTS/link_subscribe"
  link_context '{}' '{"approval_ref":"RITM0012345","plan_id":"gold"}'
  queue_response 202 '{"id":"op-1","target":"sub-api-0012345--ledger"}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q '^POST https://apisub.test/v1/subscriptions idem=act-l ' "$CURL_CALLS_LOG"
  [ "$(jq -r .callbackUrl "$CURL_BODIES_DIR/0.json")" = "https://api.nullplatform.com/link/l-1/action/act-l" ]
  [ "$(jq -r .consumerNamespace "$CURL_BODIES_DIR/0.json")" = "ledger" ]
  [ "$(np_updates | tail -n1 | jq -c '.[0:3]')" = '["link","action","update"]' ]
  [ "$(np_last_update_flag --results | jq -c .)" = '{"subscription_id":"sub-api-0012345--ledger","operation_id":"op-1","consumer_namespace":"ledger","owns_subscription":true}' ]
}

@test "un 409 cierra el link success sin ser duenio" {
  STEP="$PUBLISHER_SCRIPTS/link_subscribe"
  link_context '{}' '{"approval_ref":"RITM0012345","plan_id":"gold"}'
  queue_response 409 '{"detail":"ya existe sub-api-0012345--ledger"}'
  run_step
  [ "$(np_last_update_flag --status)" = "success" ]
  [ "$(np_last_update_flag --results | jq -r .owns_subscription)" = "false" ]
}

@test "el unlink da de baja si este link creo la suscripcion" {
  STEP="$PUBLISHER_SCRIPTS/link_unsubscribe"
  link_context '{"subscription_id":"sub-api-0012345--ledger","owns_subscription":true}' '{}'
  queue_response 200 '{"id":"sub-api-0012345--ledger","consumerNamespace":"ledger"}'
  queue_response 202 '{"id":"op-2"}'
  run_step
  [ "$status" -eq 0 ]
  grep -q '^DELETE https://apisub.test/v1/subscriptions/sub-api-0012345--ledger idem=act-l ' "$CURL_CALLS_LOG"
  [ "$(np_updates | tail -n1 | jq -c '.[0:3]')" = '["link","action","update"]' ]
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "el unlink no toca APIM si la suscripcion ya existia" {
  STEP="$PUBLISHER_SCRIPTS/link_unsubscribe"
  link_context '{"subscription_id":"sub-api-0012345--ledger","owns_subscription":false}' '{}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
}
