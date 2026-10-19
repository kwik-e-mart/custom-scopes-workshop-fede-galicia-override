#!/usr/bin/env bats

load ../../api-manager-ocp-subscriber/tests/helpers
load publisher_helpers

setup() {
  setup_publisher
  STEP="$PUBLISHER_SCRIPTS/publish"
  export NP_ACTION_CONTEXT CONTEXT
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main","legajo":"l0510541"}' qas
  set_context https://github.com/zosc-zosconnect/test-kuadrant
}

set_request() {
  NP_ACTION_CONTEXT=$(jq -nc --argjson a "$1" --argjson p "$2" \
    '{notification:{id:"act-1",type:"create",service:{id:"svc-1",attributes:$a},parameters:$p}}')
  export NP_MOCK_SCOPES
  NP_MOCK_SCOPES=$(jq -nc --arg env "$3" '[{slug:"main",id:1049050904,dimensions:{environment:$env}},{slug:"draft",id:555,dimensions:{environment:$env}}]')
}

set_context() {
  CONTEXT=$(jq -nc --arg repo "$1" --arg cluster "${2-gal-kuadrant-poc}" \
    '{application:{id:20,repository_url:$repo},providers:{"container-orchestration":{cluster:({namespace:"payments"} + (if $cluster == "" then {} else {name:$cluster} end))}}}')
}

pushed() {
  jq -nc --arg status "${1-pushed}" '{status:$status,message:"pusheada",apiId:"payments-test-kuadrant-b2c-1",hostname:"payments-test-kuadrant-b2c-qas.bancogalicia.com.ar",manifestPath:"clusters/gal-kuadrant-poc/apis/payments/test-kuadrant"}'
}

@test "publica con la firma de APIM y deja la accion abierta con los resultados" {
  queue_response 200 "$(pushed)"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q '^POST https://publisher.test/v1/kuadrant/manifests/publish idem= auth=Bearer pub-tok ' "$CURL_CALLS_LOG"
  [ "$(jq -cS . "$CURL_BODIES_DIR/0.json")" = "$(jq -cS . <<'JSON'
{"organization":"zosc-zosconnect","repository":"test-kuadrant","branch":"main","environment":"qas","tenant":"b2c",
 "cluster":"gal-kuadrant-poc","legajo":"l0510541","callbackUrl":"https://api.nullplatform.com/service/svc-1/action/act-1",
 "metadata":{"name":"test-kuadrant","namespace":"payments","labels":{"app":"test-kuadrant"},
   "parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"s2s-ingress","namespace":"gateways"}],
   "backend":{"kind":"Service","name":"d-1049050904-222","namespace":"payments","port":8080}}}
JSON
)" ]
  [ -z "$(np_last_update_flag --status)" ]
  [ "$(np_last_update_flag --results)" = '{"api_id":"payments-test-kuadrant-b2c-1","hostname":"payments-test-kuadrant-b2c-qas.bancogalicia.com.ar","manifest_path":"clusters/gal-kuadrant-poc/apis/payments/test-kuadrant"}' ]
}

@test "synced tambien deja la accion abierta esperando el registro" {
  queue_response 200 "$(pushed synced)"
  run_step
  [ "$(np_last_update_flag --results | jq -r .api_id)" = "payments-test-kuadrant-b2c-1" ]
  [ -z "$(np_last_update_flag --status)" ]
}

@test "registered en la respuesta cierra success" {
  queue_response 200 "$(pushed registered)"
  run_step
  [ "$(np_last_update_flag --status)" = "success" ]
}

@test "un tag o un commit viajan en su campo" {
  set_request '{}' '{"scope":"main","ref_type":"tag","ref":"v1.2.3"}' qas
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -c '{branch, tag, commit}' "$CURL_BODIES_DIR/0.json")" = '{"branch":null,"tag":"v1.2.3","commit":null}' ]
}

@test "el rate limit viaja si vienen window y hits" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main","window":"10s","hits_per_window":100}' qas
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -c '{window, hitsPerWindow}' "$CURL_BODIES_DIR/0.json")" = '{"window":"10s","hitsPerWindow":100}' ]
}

@test "window sin hits falla sin llamar a APIM" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main","window":"10s"}' qas
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "sin legajo no lo manda" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' qas
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq 'has("legajo")' "$CURL_BODIES_DIR/0.json")" = "false" ]
}

@test "un legajo con otro formato falla sin llamar a APIM" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main","legajo":"510541"}' qas
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *legajo* ]]
}

@test "canceled cierra failed con el mensaje de APIM" {
  queue_response 200 '{"status":"canceled","message":"Argo no sincronizó los manifests; la publicación fue cancelada."}'
  run_step
  [ "$status" -ne 0 ]
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"Argo no sincronizó"* ]]
}

@test "un 400 cierra failed con el mensaje de APIM" {
  queue_response 400 '{"status":"error","message":"El tenant de publicación es obligatorio."}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"HTTP 400"*"tenant"* ]]
}

@test "un 500 cierra failed" {
  queue_response 500 'Internal Server Error'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "el backend es el Service del despliegue activo del scope" {
  queue_response 200 "$(pushed)"
  run_step
  grep -q -- "-n payments get httproute -l nullplatform=true,scope_id=1049050904 -o json" "$KUBECTL_CALLS_LOG"
  [ "$(jq -cS .metadata.backend "$CURL_BODIES_DIR/0.json")" = '{"kind":"Service","name":"d-1049050904-222","namespace":"payments","port":8080}' ]
}

@test "un scope que no es de la aplicacion falla sin llamar a APIM" {
  set_request '{}' '{"scope":"otro","ref_type":"branch","ref":"main"}' qas
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"otro"* ]]
}

@test "un scope sin despliegue en el cluster falla sin llamar a APIM" {
  export KUBECTL_MOCK_ROUTES='{"items":[]}'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"despliegue"* ]]
}

@test "si no se pueden leer las rutas del scope falla sin llamar a APIM" {
  export KUBECTL_MOCK_FAIL=1
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"rutas"* ]]
}

@test "el ambiente sale de la dimension del scope elegido: dev no se publica" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' development
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *dev* ]]
}

@test "production se publica como prd" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' production
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -r .environment "$CURL_BODIES_DIR/0.json")" = "prd" ]
}

@test "APIM_PUBLISH_ENVIRONMENT fuerza el ambiente aunque el scope sea de dev" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' development
  export APIM_PUBLISH_ENVIRONMENT=qas
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -r .environment "$CURL_BODIES_DIR/0.json")" = "qas" ]
}

@test "APIM_PUBLISH_ENVIRONMENT invalido falla sin llamar a APIM" {
  export APIM_PUBLISH_ENVIRONMENT=dev
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *APIM_PUBLISH_ENVIRONMENT* ]]
}

@test "un ambiente desconocido falla sin llamar a APIM" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' sandbox
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "sin parentRefs configurados falla sin llamar a APIM" {
  export APIM_PUBLISH_PARENT_REFS='[]'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *APIM_PUBLISH_PARENT_REFS* ]]
}

@test "sin nombre de cluster falla sin llamar a APIM" {
  set_context https://github.com/zosc-zosconnect/test-kuadrant ""
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *APIM_CLUSTER_NAME* ]]
}

@test "APIM_CLUSTER_NAME reemplaza el nombre del cluster del provider" {
  export APIM_CLUSTER_NAME=cluster1
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -r .cluster "$CURL_BODIES_DIR/0.json")" = "cluster1" ]
}

@test "acepta la url del repo con .git" {
  set_context https://github.com/zosc-zosconnect/test-kuadrant.git
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -c '[.organization, .repository]' "$CURL_BODIES_DIR/0.json")" = '["zosc-zosconnect","test-kuadrant"]' ]
}

@test "una url de repo que no es org/repo falla sin llamar a APIM" {
  set_context https://github.com/solo-org
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "sin token del publisher falla sin llamar a APIM" {
  unset APIM_PUBLISHER_TOKEN
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *APIM_PUBLISHER_TOKEN* ]]
}

@test "republicar toma los atributos guardados y los parametros nuevos" {
  set_request '{"scope":"main","ref_type":"branch","ref":"main","legajo":"l0510541"}' '{"ref_type":"commit","ref":"a1b2c3d"}' qas
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -c '{branch, commit, legajo}' "$CURL_BODIES_DIR/0.json")" = '{"branch":null,"commit":"a1b2c3d","legajo":"l0510541"}' ]
}

@test "parentRefs como namespace/nombre:listener separados por coma" {
  export APIM_PUBLISH_PARENT_REFS="gateways/s2s-ingress:https,otro-ns/gw-b"
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -c .metadata.parentRefs "$CURL_BODIES_DIR/0.json")" = '[{"group":"gateway.networking.k8s.io","kind":"Gateway","namespace":"gateways","name":"s2s-ingress","sectionName":"https"},{"group":"gateway.networking.k8s.io","kind":"Gateway","namespace":"otro-ns","name":"gw-b"}]' ]
}

@test "parentRefs con un formato que no es namespace/nombre falla sin llamar a APIM" {
  export APIM_PUBLISH_PARENT_REFS="s2s-ingress"
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
}
