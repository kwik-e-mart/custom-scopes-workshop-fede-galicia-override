#!/usr/bin/env bats

load helpers
load publisher_helpers

setup() {
  setup_publisher
  STEP="$PUBLISHER_SCRIPTS/publish"
  export NP_ACTION_CONTEXT CONTEXT
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main","legajo":"l0510541"}' qas
  set_context https://github.com/zosc-zosconnect/test-kuadrant
}

set_request() {
  NP_ACTION_CONTEXT=$(jq -nc --argjson a "$1" --argjson p "$2" --arg env "$3" \
    '{notification:{id:"act-1",type:"create",
      service:({id:"svc-1",attributes:$a} + (if $env == "" then {} else {dimensions:{environment:$env}} end)),parameters:$p}}')
  export NP_MOCK_SCOPES
  NP_MOCK_SCOPES='[{"slug":"main","id":1049050904,"domain":"test-kuadrant-main.ms.ws.bancogalicia.com.ar","dimensions":{"environment":"qas"}},{"slug":"draft","id":555,"domain":"test-kuadrant-draft.ms.ws.bancogalicia.com.ar","dimensions":{"environment":"qas"}}]'
}

set_context() {
  CONTEXT=$(jq -nc --arg repo "$1" --arg cluster "${2-gal-kuadrant-poc}" --arg project "${3-zosc-pagos}" \
    '{application:{id:20,repository_url:$repo},providers:{"container-orchestration":{cluster:({namespace:"payments"} + (if $cluster == "" then {} else {id:$cluster} end))}}}
     + (if $project == "" then {} else {tags:{namespace:$project}} end)')
}

pushed() {
  jq -nc --arg status "${1-commited}" '{status:$status,message:"pusheada",apiId:"payments-test-kuadrant-b2c-1",hostname:"payments-test-kuadrant-b2c-qas.bancogalicia.com.ar",manifestPath:"clusters/gal-kuadrant-poc/apis/payments/test-kuadrant"}'
}

@test "publica con la firma de APIM y deja la accion abierta con los resultados" {
  queue_response 200 "$(pushed)"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q '^POST https://publisher.test/v1/kuadrant/manifests/publish idem= auth=Bearer pub-tok ' "$CURL_CALLS_LOG"
  [ "$(jq -cS . "$CURL_BODIES_DIR/0.json")" = "$(jq -cS . <<'JSON'
{"organization":"zosc-zosconnect","repository":"test-kuadrant","branch":"main","environment":"qas","tenant":"b2c","origen":"nullplatform","sigla":"zosc","project":"zosc-pagos",
 "cluster":"gal-kuadrant-poc","legajo":"l0510541","callbackUrl":"https://api.nullplatform.com/service/svc-1/action/act-1",
 "metadata":{"name":"test-kuadrant","namespace":"payments","labels":{"app":"test-kuadrant"},
   "parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"s2s-ingress","namespace":"gateways"}],
   "backend":{"kind":"Service","name":"s2s-ingress-istio","namespace":"gateways","port":443,
              "destinationFqdn":"test-kuadrant-main.ms.ws.bancogalicia.com.ar"}}}
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

@test "el backend es el Service del ingreso local y el destino es el dominio del scope elegido" {
  set_request '{}' '{"scope":"draft","ref_type":"branch","ref":"main"}' qas
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -cS .metadata.backend "$CURL_BODIES_DIR/0.json")" = '{"destinationFqdn":"test-kuadrant-draft.ms.ws.bancogalicia.com.ar","kind":"Service","name":"s2s-ingress-istio","namespace":"gateways","port":443}' ]
}

@test "LOCAL_INGRESS_HOST define el Service y el namespace del ingreso" {
  export LOCAL_INGRESS_HOST=gateway-private-istio.istio-gateways.svc.cluster.local
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -c '.metadata.backend | [.name, .namespace]' "$CURL_BODIES_DIR/0.json")" = '["gateway-private-istio","istio-gateways"]' ]
}

@test "APIM_GATEWAY_PORT cambia el puerto del ingreso" {
  export APIM_GATEWAY_PORT=8080
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -r .metadata.backend.port "$CURL_BODIES_DIR/0.json")" = "8080" ]
}

@test "un LOCAL_INGRESS_HOST vacio o que no es service.namespace falla sin llamar a APIM" {
  for host in "" "Gateway Privado.gateways.svc" "s2s-ingress-istio"; do
    export LOCAL_INGRESS_HOST="$host"
    run_step
    [ ! -s "$CURL_CALLS_LOG" ]
    [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *LOCAL_INGRESS_HOST* ]] || false
  done
}

@test "un APIM_GATEWAY_PORT que no es un puerto falla sin llamar a APIM" {
  export APIM_GATEWAY_PORT=http
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *APIM_GATEWAY_PORT* ]]
}

@test "un scope que no es de la aplicacion falla sin llamar a APIM" {
  set_request '{}' '{"scope":"otro","ref_type":"branch","ref":"main"}' qas
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"otro"* ]]
}

@test "un scope sin dominio falla sin llamar a APIM" {
  NP_MOCK_SCOPES='[{"slug":"main","id":1049050904,"dimensions":{"environment":"qas"}}]'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"dominio"* ]]
}

@test "el ambiente sale de la dimension del service: development se publica como dev" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' development
  queue_response 200 "$(pushed)"
  run_step
  [ "$status" -eq 0 ]
  [ "$(jq -r .environment "$CURL_BODIES_DIR/0.json")" = "dev" ]
}

@test "production se publica como prd" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' production
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -r .environment "$CURL_BODIES_DIR/0.json")" = "prd" ]
}

@test "un service sin dimension environment falla sin llamar a APIM" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' ""
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *environment* ]]
}

@test "un ambiente desconocido falla sin llamar a APIM" {
  set_request '{}' '{"scope":"main","ref_type":"branch","ref":"main"}' sandbox
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
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

@test "la sigla es la primera parte del namespace sin pasarla a mayusculas" {
  set_context https://github.com/zosc-zosconnect/test-kuadrant gal-kuadrant-poc PLCL-PlatformOps
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -r .sigla "$CURL_BODIES_DIR/0.json")" = "PLCL" ]
  [ "$(jq -r .project "$CURL_BODIES_DIR/0.json")" = "PLCL-PlatformOps" ]
}

@test "sin namespace en el contexto falla sin llamar a APIM nombrando los overrides" {
  set_context https://github.com/zosc-zosconnect/test-kuadrant gal-kuadrant-poc ""
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *APIM_PROJECT* ]] || false
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *APIM_SIGLA* ]]
}

@test "APIM_SIGLA y APIM_PROJECT reemplazan los valores del namespace" {
  export APIM_SIGLA=arqc APIM_PROJECT=arqc-kuadrant
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -r .sigla "$CURL_BODIES_DIR/0.json")" = "arqc" ]
  [ "$(jq -r .project "$CURL_BODIES_DIR/0.json")" = "arqc-kuadrant" ]
}

@test "los overrides alcanzan aunque el contexto no traiga namespace" {
  set_context https://github.com/zosc-zosconnect/test-kuadrant gal-kuadrant-poc ""
  export APIM_SIGLA=arqc APIM_PROJECT=arqc-kuadrant
  queue_response 200 "$(pushed)"
  run_step
  [ "$status" -eq 0 ]
  [ "$(jq -r .sigla "$CURL_BODIES_DIR/0.json")" = "arqc" ]
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

@test "sin token del publisher publica sin header de autorizacion" {
  unset APIM_PUBLISHER_TOKEN
  queue_response 200 "$(pushed)"
  run_step
  [ "$status" -eq 0 ]
  grep -q '^POST https://publisher.test/v1/kuadrant/manifests/publish idem= auth= ' "$CURL_CALLS_LOG"
  [ "$(grep -c -- '--config' "$CURL_ARGV_LOG")" = "0" ]
}

@test "un status pushed no es del contrato y cierra failed" {
  queue_response 200 "$(pushed pushed)"
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
}

@test "republicar toma los atributos guardados y los parametros nuevos" {
  set_request '{"scope":"main","ref_type":"branch","ref":"main","legajo":"l0510541"}' '{"ref_type":"commit","ref":"a1b2c3d"}' qas
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -c '{branch, commit, legajo}' "$CURL_BODIES_DIR/0.json")" = '{"branch":null,"commit":"a1b2c3d","legajo":"l0510541"}' ]
}

@test "el parentRefs es el gateway de ingreso que usa el s2s" {
  export INGRESS_GATEWAY_NAME=gateway-apim GATEWAY_NAMESPACE=apim-gateways
  queue_response 200 "$(pushed)"
  run_step
  [ "$(jq -c .metadata.parentRefs "$CURL_BODIES_DIR/0.json")" = '[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"gateway-apim","namespace":"apim-gateways"}]' ]
}

@test "un INGRESS_GATEWAY_NAME que no es un nombre de Kubernetes falla sin llamar a APIM" {
  export INGRESS_GATEWAY_NAME="Gateway APIM"
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *INGRESS_GATEWAY_NAME* ]]
}

@test "un dominio de scope que no es un hostname falla sin llamar a APIM" {
  NP_MOCK_SCOPES='[{"slug":"main","id":1049050904,"domain":"app.bancogalicia.com.ar/otra?x=1","dimensions":{"environment":"qas"}}]'
  run_step
  [ ! -s "$CURL_CALLS_LOG" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"dominio"* ]]
}

applied() {
  jq -s 'sort_by(.metadata.name)' "$KUBECTL_APPLIED_DIR"/*.json
}

@test "despues del 200 cuelga una AuthPolicy de la API en cada route del scope" {
  export KUBECTL_MOCK_ROUTES='{"items":[{"metadata":{"name":"k-8-s-main-1049050904-grpc"}},{"metadata":{"name":"k-8-s-main-1049050904-internal"}}]}'
  queue_response 200 "$(pushed)"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  grep -q -- "-n payments get httproute -l nullplatform=true,scope_id=1049050904 -o json" "$KUBECTL_CALLS_LOG"
  [ "$(applied | jq -c '[.[] | {name: .metadata.name, namespace: .metadata.namespace, route: .spec.targetRef.name}]')" = \
    '[{"name":"payments-test-kuadrant-b2c-1-k-8-s-main-1049050904-grpc","namespace":"payments","route":"k-8-s-main-1049050904-grpc"},{"name":"payments-test-kuadrant-b2c-1-k-8-s-main-1049050904-internal","namespace":"payments","route":"k-8-s-main-1049050904-internal"}]' ]
  [ -z "$(np_last_update_flag --status)" ]
}

@test "la AuthPolicy valida la credencial de esta API y se combina con el validador del s2s" {
  queue_response 200 "$(pushed)"
  run_step
  local policy
  policy=$(applied | jq -c '.[0]')
  [ "$(jq -c .metadata.labels <<<"$policy")" = '{"app.kubernetes.io/managed-by":"api-manager-publisher","api-id":"payments-test-kuadrant-b2c-1","scope_id":"1049050904"}' ]
  [ "$(jq -c .spec.targetRef <<<"$policy")" = '{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"k-8-s-main-1049050904-internal"}' ]
  [ "$(jq -r .spec.defaults.strategy <<<"$policy")" = "merge" ]
  [ "$(jq -c '.spec.defaults.rules.authentication."payments-test-kuadrant-b2c-1"' <<<"$policy")" = \
    '{"apiKey":{"selector":{"matchLabels":{"api-id":"payments-test-kuadrant-b2c-1"}},"allNamespaces":true},"credentials":{"customHeader":{"name":"app_key"}}}' ]
  [ "$(jq -c '.spec.defaults.rules.authorization."payments-test-kuadrant-b2c-1-app-id"' <<<"$policy")" = \
    '{"when":[{"predicate":"has(request.headers.app_key)"}],"patternMatching":{"patterns":[{"predicate":"auth.identity.metadata.labels['"'"'app-id'"'"'] == request.headers.app_id"}]}}' ]
}

@test "si APIM rechaza la publicacion no cuelga ninguna AuthPolicy" {
  queue_response 400 '{"status":"error","message":"firma invalida"}'
  run_step
  [ "$(find "$KUBECTL_APPLIED_DIR" -type f | wc -l | tr -d ' ')" = "0" ]
  ! grep -q "get httproute" "$KUBECTL_CALLS_LOG"
}

@test "un scope sin routes en el cluster cierra failed avisando que hay que desplegarlo" {
  export KUBECTL_MOCK_ROUTES='{"items":[]}'
  queue_response 200 "$(pushed)"
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"main"*"routes"* ]]
}

@test "si no puede leer las routes del scope cierra failed" {
  export KUBECTL_MOCK_FAIL=1
  queue_response 200 "$(pushed)"
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"routes"* ]]
}

@test "si el cluster rechaza la AuthPolicy cierra failed nombrando la route" {
  export KUBECTL_MOCK_APPLY_FAIL=1
  queue_response 200 "$(pushed)"
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"k-8-s-main-1049050904-internal"* ]]
}

@test "un apiId de APIM que no es un nombre de Kubernetes cierra failed sin tocar el cluster" {
  queue_response 200 '{"status":"pushed","apiId":"API Pagos/1","hostname":"h"}'
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [ "$(find "$KUBECTL_APPLIED_DIR" -type f | wc -l | tr -d ' ')" = "0" ]
}

@test "si APIM no responde, la accion cierra failed con el error de conexion" {
  export APIM_RETRIES=0
  queue_response 000 ''
  run_step
  [ "$(np_last_update_flag --status)" = "failed" ]
  [[ "$(np_last_update_flag --messages | jq -r '.[0].message')" == *"HTTP 000"*"Failed to connect"* ]]
}
