#!/usr/bin/env bats

load helpers
load publisher_helpers

setup() {
  setup_publisher
  STEP="$PUBLISHER_SCRIPTS/unpublish"
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-3",type:"delete",service:{id:"svc-1",attributes:{api_id:"payments-test-kuadrant-b2c-1"}}}}')
  export CONTEXT
  CONTEXT=$(jq -nc '{providers:{"container-orchestration":{cluster:{namespace:"payments"}}}}')
}

@test "sin endpoint de baja cierra success sin llamar a APIM y avisa que sigue publicada" {
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"payments-test-kuadrant-b2c-1"*"sigue publicada"* ]]
}

@test "borra las AuthPolicies que la API colgo en las routes del scope" {
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -qx -- "-n payments delete authpolicy -l app.kubernetes.io/managed-by=api-manager-publisher,api-id=payments-test-kuadrant-b2c-1 --ignore-not-found" "$KUBECTL_CALLS_LOG"
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"ya no acepta"* ]]
}

@test "sin apiId guardado no toca el cluster" {
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-3",type:"delete",service:{id:"svc-1",attributes:{}}}}')
  run_step
  [ "$status" -eq 0 ]
  [ ! -s "$KUBECTL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "si no puede borrar las AuthPolicies cierra failed para que se reintente" {
  export KUBECTL_MOCK_DELETE_FAIL=1
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"AuthPolic"* ]]
}
