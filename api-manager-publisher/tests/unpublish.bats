#!/usr/bin/env bats

load ../../api-manager-ocp-subscriber/tests/helpers
load publisher_helpers

setup() {
  setup_publisher
  STEP="$PUBLISHER_SCRIPTS/unpublish"
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(jq -nc '{notification:{id:"act-3",type:"delete",service:{id:"svc-1",attributes:{api_id:"payments-test-kuadrant-b2c-1"}}}}')
}

@test "sin endpoint de baja cierra success sin llamar a APIM y avisa que sigue publicada" {
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "success" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"payments-test-kuadrant-b2c-1"*"sigue publicada"* ]]
}
