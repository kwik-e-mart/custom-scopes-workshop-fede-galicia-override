#!/usr/bin/env bats

load helpers

setup() {
  setup_common
  STEP="$SCRIPTS/subscribe"
  export NP_ACTION_CONTEXT CONTEXT
  set_params '{"api_name":"greeting","approval_ref":"RITM0012345","plan_id":"gold"}'
  CONTEXT=$(jq -nc '{providers:{"container-orchestration":{cluster:{namespace:"sigla-x-qa"}}}}')
}

set_params() {
  NP_ACTION_CONTEXT=$(jq -nc --argjson p "$1" '{notification:{id:"act-1",service:{id:"svc-1",attributes:{}},parameters:$p}}')
}

@test "202 manda el pedido esperado, guarda los results y deja la accion abierta" {
  queue_response 202 '{"id":"op-1","kind":"subscription","state":"Committed","target":"sub-greeting--sigla-x-qa"}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q '^POST https://apisub.test/v1/subscriptions idem=act-1 ' "$CURL_CALLS_LOG"
  [ "$(jq -c . "$CURL_BODIES_DIR/0.json")" = '{"approvalRef":"RITM0012345","consumerNamespace":"sigla-x-qa","planId":"gold","callbackUrl":"https://api.nullplatform.com/service/svc-1/action/act-1"}' ]
  [ -z "$(np_last_update_flag --status)" ]
  [ "$(np_last_update_flag --results)" = '{"subscription_id":"sub-greeting--sigla-x-qa","operation_id":"op-1","consumer_namespace":"sigla-x-qa","owns_subscription":true}' ]
}

@test "202 sin target valido deja la accion abierta sin subscription_id" {
  queue_response 202 '{"id":"op-1","state":"Committed"}'
  run_step
  [ "$status" -eq 0 ]
  [ -z "$(np_last_update_flag --status)" ]
  [ "$(np_last_update_flag --results)" = '{"operation_id":"op-1","consumer_namespace":"sigla-x-qa","owns_subscription":false}' ]
}

@test "409 cierra success con el subscription_id del detail y owns_subscription false" {
  queue_response 409 '{"title":"Conflict","detail":"El namespace ya está suscripto: sub-greeting--sigla-x-qa"}'
  run_step
  [ "$status" -eq 0 ]
  [ "$(np_last_update_flag --status)" = "success" ]
  [ "$(np_last_update_flag --messages | jq -r '.[0].message')" = "Tu namespace ya tiene acceso a esta API." ]
  [ "$(np_last_update_flag --results)" = '{"consumer_namespace":"sigla-x-qa","owns_subscription":false,"subscription_id":"sub-greeting--sigla-x-qa"}' ]
}

@test "409 con el id al final de una oracion no guarda el punto" {
  queue_response 409 '{"detail":"Ya existe sub-greeting--sigla-x-qa."}'
  run_step
  [ "$(np_last_update_flag --results | jq -r .subscription_id)" = "sub-greeting--sigla-x-qa" ]
}

@test "409 sin id en el detail cierra success sin subscription_id" {
  queue_response 409 '{"title":"Conflict","detail":"ya existe"}'
  run_step
  [ "$(np_last_update_flag --status)" = "success" ]
  [ "$(np_last_update_flag --results)" = '{"consumer_namespace":"sigla-x-qa","owns_subscription":false}' ]
}

@test "422 cierra failed una sola vez con el detail de APIM" {
  queue_response 422 '{"title":"Unprocessable","detail":"Tu solicitud no está aprobada en ServiceNow"}'
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"HTTP 422"*"no está aprobada en ServiceNow"* ]] || false
  [ "$(np_update_count)" = "1" ]
}

@test "un detail con comillas y saltos de linea llega intacto" {
  queue_response 422 "$(jq -nc '{detail:"línea \"uno\"\nlínea dos \\ fin"}')"
  run_step
  msg=$(np_last_update_flag --messages | jq -r '.[0].message')
  [[ "$msg" == *'línea "uno"'* ]] || false
  [[ "$msg" == *'línea dos \ fin'* ]]
}

@test "503 persistente reintenta y cierra failed" {
  for _ in 1 2 3 4; do queue_response 503 '{"title":"ServiceNow no responde"}'; done
  run_step
  [ "$(curl_call_count)" = "4" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "red caida reintenta y cierra failed" {
  for _ in 1 2 3 4; do queue_response 000 ''; done
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "sin namespace en el provider falla sin llamar a APIM" {
  CONTEXT='{"providers":{}}'
  run_step
  [ "$status" -ne 0 ]
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"cluster.namespace"* ]]
}

@test "sin approval_ref falla sin llamar a APIM" {
  set_params '{"plan_id":"gold"}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "approval_ref que no es un RITM falla sin llamar a APIM" {
  set_params '{"approval_ref":"INC0012345","plan_id":"gold"}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"approval_ref"* ]]
}

@test "plan_id con caracteres invalidos falla sin llamar a APIM" {
  set_params '{"approval_ref":"RITM0012345","plan_id":"gold plan;x"}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"plan_id"* ]]
}

@test "sin token del agente falla sin llamar a APIM" {
  unset API_SUBSCRIBER_TOKEN
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"API_SUBSCRIBER_TOKEN"* ]]
}

@test "un contexto invalido cierra failed una sola vez con el motivo" {
  NP_ACTION_CONTEXT='no es json'
  run_step
  [ "$(np_update_count)" = "1" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"NP_ACTION_CONTEXT"* ]]
}

@test "si falla guardar el avance despues del 202, la accion no se cierra failed" {
  queue_response 202 '{"id":"op-1","target":"sub-greeting--sigla-x-qa"}'
  export NP_MOCK_UPDATE_FAIL=1
  run_step
  [ "$(np_update_count)" = "1" ]
  [ "$(np_updates | jq -s 'map(select(index("--status") != null)) | length')" = "0" ]
}

@test "un 202 con cuerpo que no es JSON cierra failed por el trap" {
  queue_response 202 'not json'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
}
