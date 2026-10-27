#!/usr/bin/env bats

load helpers
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
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"APIM_APP_ID y APIM_APP_KEY"*"próximo deploy"* ]] || false
}

@test "el link manda el ticket tal cual lo cargaron, sin validar su formato" {
  STEP="$PUBLISHER_SCRIPTS/link_subscribe"
  link_context '{}' '{"approval_ref":"UR0866152","plan_id":"gold"}'
  queue_response 202 '{"id":"op-1","target":"sub-api-0866152--ledger"}'
  run_step
  [ "$status" -eq 0 ]
  [ "$(jq -r .approvalRef "$CURL_BODIES_DIR/0.json")" = "UR0866152" ]
}

@test "el link sin ticket falla sin llamar al API Subscriber" {
  STEP="$PUBLISHER_SCRIPTS/link_subscribe"
  link_context '{}' '{"plan_id":"gold"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [ ! -s "$CURL_CALLS_LOG" ]
}

@test "APIM_CONSUMER_NAMESPACE reemplaza el namespace que se suscribe" {
  STEP="$PUBLISHER_SCRIPTS/link_subscribe"
  export APIM_CONSUMER_NAMESPACE="zosc-pruebas"
  link_context '{}' '{"approval_ref":"UR0866152","plan_id":"gold"}'
  queue_response 202 '{"id":"op-1","target":"sub-api-0866152--zosc-pruebas"}'
  run_step
  [ "$status" -eq 0 ]
  [ "$(jq -r .consumerNamespace "$CURL_BODIES_DIR/0.json")" = "zosc-pruebas" ]
  [ "$(np_last_update_flag --results | jq -r .consumer_namespace)" = "zosc-pruebas" ]
}

@test "un 409 cierra el link success sin ser duenio" {
  STEP="$PUBLISHER_SCRIPTS/link_subscribe"
  link_context '{}' '{"approval_ref":"RITM0012345","plan_id":"gold"}'
  queue_response 409 '{"detail":"ya existe sub-api-0012345--ledger"}'
  run_step
  [ "$(np_last_update_flag --status)" = "success" ]
  [ "$(np_last_update_flag --results | jq -r .owns_subscription)" = "false" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"APIM_APP_ID y APIM_APP_KEY"*"próximo deploy"* ]]
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

@test "el unlink con APIM_CONSUMER_NAMESPACE da de baja la suscripcion de ese namespace" {
  STEP="$PUBLISHER_SCRIPTS/link_unsubscribe"
  export APIM_CONSUMER_NAMESPACE="zosc-pruebas"
  link_context '{"subscription_id":"sub-api-0866152--zosc-pruebas","owns_subscription":true}' '{}'
  queue_response 200 '{"id":"sub-api-0866152--zosc-pruebas","consumerNamespace":"zosc-pruebas"}'
  queue_response 202 '{"id":"op-2"}'
  run_step
  [ "$status" -eq 0 ]
  grep -q '^DELETE https://apisub.test/v1/subscriptions/sub-api-0866152--zosc-pruebas idem=act-l ' "$CURL_CALLS_LOG"
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "el unlink no toca APIM si la suscripcion ya existia" {
  STEP="$PUBLISHER_SCRIPTS/link_unsubscribe"
  link_context '{"subscription_id":"sub-api-0012345--ledger","owns_subscription":false}' '{}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
}

update_context() {
  link_context "{\"subscription_id\":\"sub-api-0866152--ledger\",\"owns_subscription\":$1,\"approval_ref\":\"UR0866152\",\"plan_id\":\"bronze\"}" "$2"
}

@test "el update cambia el plan con el ticket y deja la accion abierta hasta el callback" {
  STEP="$PUBLISHER_SCRIPTS/link_update"
  update_context true '{"approval_ref":"UR0900001","plan_id":"gold"}'
  queue_response 200 '{"id":"sub-api-0866152--ledger","consumerNamespace":"ledger"}'
  queue_response 202 '{"id":"op-3"}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q '^GET https://apisub.test/v1/subscriptions/sub-api-0866152--ledger ' "$CURL_CALLS_LOG"
  grep -q '^PATCH https://apisub.test/v1/subscriptions/sub-api-0866152--ledger idem=act-l auth=Bearer tok-123 ' "$CURL_CALLS_LOG"
  [ "$(jq -cS . "$CURL_BODIES_DIR/1.json")" = '{"approvalRef":"UR0900001","callbackUrl":"https://api.nullplatform.com/link/l-1/action/act-l","planId":"gold"}' ]
  [ "$(np_updates | tail -n1 | jq -c '.[0:3]')" = '["link","action","update"]' ]
  [ "$(np_last_update_flag --results | jq -c .)" = '{"operation_id":"op-3"}' ]
}

@test "el update cambia el plan aunque el link no haya creado la suscripcion" {
  STEP="$PUBLISHER_SCRIPTS/link_update"
  update_context false '{"approval_ref":"UR0900001","plan_id":"gold"}'
  queue_response 200 '{"id":"sub-api-0866152--ledger","consumerNamespace":"ledger"}'
  queue_response 202 '{"id":"op-3"}'
  run_step
  [ "$status" -eq 0 ]
  grep -q '^PATCH https://apisub.test/v1/subscriptions/sub-api-0866152--ledger ' "$CURL_CALLS_LOG"
}

@test "el update sin suscripcion falla sin llamar al API Subscriber" {
  STEP="$PUBLISHER_SCRIPTS/link_update"
  link_context '{"owns_subscription":false}' '{"approval_ref":"UR0900001","plan_id":"gold"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"no tiene una suscripción"* ]] || false
  [ ! -s "$CURL_CALLS_LOG" ]
}

@test "el update sin ticket falla sin llamar al API Subscriber" {
  STEP="$PUBLISHER_SCRIPTS/link_update"
  link_context '{"subscription_id":"sub-api-0866152--ledger"}' '{"plan_id":"gold"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [ ! -s "$CURL_CALLS_LOG" ]
}

@test "el update no toca una suscripcion de otro namespace" {
  STEP="$PUBLISHER_SCRIPTS/link_update"
  update_context true '{"approval_ref":"UR0900001","plan_id":"gold"}'
  queue_response 200 '{"id":"sub-api-0866152--ledger","consumerNamespace":"otro"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  ! grep -q '^PATCH ' "$CURL_CALLS_LOG"
}

@test "el update de una suscripcion que ya no existe falla" {
  STEP="$PUBLISHER_SCRIPTS/link_update"
  update_context true '{"approval_ref":"UR0900001","plan_id":"gold"}'
  queue_response 404 '{"detail":"not found"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"ya no existe"* ]] || false
  ! grep -q '^PATCH ' "$CURL_CALLS_LOG"
}

@test "si APIM rechaza el cambio de plan el update falla con su detalle" {
  STEP="$PUBLISHER_SCRIPTS/link_update"
  update_context true '{"approval_ref":"UR0900001","plan_id":"gold"}'
  queue_response 200 '{"id":"sub-api-0866152--ledger","consumerNamespace":"ledger"}'
  queue_response 422 '{"detail":"ticket no aprobado"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"HTTP 422"*"ticket no aprobado"* ]] || false
}
