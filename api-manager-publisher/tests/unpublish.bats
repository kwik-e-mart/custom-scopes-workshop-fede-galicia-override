#!/usr/bin/env bats

load helpers
load publisher_helpers

setup() {
  setup_publisher
  STEP="$PUBLISHER_SCRIPTS/unpublish"
  export NP_ACTION_CONTEXT CONTEXT
  set_request '{"api_id":"payments-test-kuadrant-b2c-1","scope":"main","legajo":"l0510541"}'
  CONTEXT=$(jq -nc '{application:{id:20,repository_url:"https://github.com/zosc-zosconnect/test-kuadrant"},providers:{"container-orchestration":{cluster:{namespace:"payments",id:"gal-kuadrant-poc"}}}}')
}

set_request() {
  NP_ACTION_CONTEXT=$(jq -nc --argjson a "$1" \
    '{notification:{id:"act-3",type:"delete",tags:{namespace:"zosc-pagos"},service:{id:"svc-1",attributes:$a,dimensions:{environment:"qas"}}}}')
}

deleting() {
  jq -nc '{deletionId:"del-1",status:"Commited",apiId:"payments-test-kuadrant-b2c-1",final:false}'
}

@test "pide la baja a APIM con los datos de la publicacion y deja la accion abierta hasta el callback" {
  queue_response 202 "$(deleting)"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q '^POST https://publisher.test/v1/kuadrant/manifests/delete idem= auth=Bearer pub-tok ' "$CURL_CALLS_LOG"
  [ "$(jq -cS . "$CURL_BODIES_DIR/0.json")" = "$(jq -cS . <<'JSON'
{"sigla":"zosc","proyecto":"zosc-pagos","environment":"qas","tenant":"b2c","cluster":"gal-kuadrant-poc",
 "name":"test-kuadrant","namespace":"payments","legajo":"l0510541","origen":"nullplatform",
 "callbackUrl":"https://api.nullplatform.com/service/svc-1/action/act-3"}
JSON
)" ]
  [ "$(np_last_update_flag --status)" != "success" ]
  [ "$(np_last_update_flag --results | jq -c .)" = '{"deletion_id":"del-1"}' ]
}

@test "con la baja aceptada borra las AuthPolicies que la API colgo en las routes del scope" {
  queue_response 202 "$(deleting)"
  run_step
  [ "$status" -eq 0 ]
  grep -qx -- "-n payments delete authpolicy -l app.kubernetes.io/managed-by=api-manager-publisher,api-id=payments-test-kuadrant-b2c-1 --ignore-not-found" "$KUBECTL_CALLS_LOG"
}

@test "si la API no tiene manifests publicados cierra success y borra las AuthPolicies" {
  queue_response 404 '{}'
  run_step
  [ "$status" -eq 0 ]
  [ "$(np_last_update_flag --status)" = "success" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"no tiene manifests publicados"* ]] || false
  grep -q "delete authpolicy" "$KUBECTL_CALLS_LOG"
}

@test "si APIM rechaza la baja falla con su detalle y no toca las AuthPolicies" {
  queue_response 400 '{"status":"error","message":"baja en curso"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"HTTP 400"*"baja en curso"* ]] || false
  [ ! -s "$KUBECTL_CALLS_LOG" ]
}

@test "sin legajo falla sin llamar a APIM" {
  set_request '{"api_id":"payments-test-kuadrant-b2c-1","scope":"main"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"legajo"* ]] || false
  [ ! -s "$CURL_CALLS_LOG" ]
  [ ! -s "$KUBECTL_CALLS_LOG" ]
}

@test "sin apiId guardado pide la baja igual y no toca el cluster" {
  set_request '{"scope":"main","legajo":"l0510541"}'
  queue_response 404 '{}'
  run_step
  [ "$status" -eq 0 ]
  grep -q '^POST https://publisher.test/v1/kuadrant/manifests/delete ' "$CURL_CALLS_LOG"
  [ ! -s "$KUBECTL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "si no puede borrar las AuthPolicies cierra failed para que se reintente" {
  export KUBECTL_MOCK_DELETE_FAIL=1
  queue_response 202 "$(deleting)"
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"AuthPolic"* ]] || false
}
