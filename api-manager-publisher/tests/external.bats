#!/usr/bin/env bats

load helpers

bats_require_minimum_version 1.5.0

setup() {
  setup_common
  HANDLER="${BATS_TEST_DIRNAME}/../entrypoint/external"
  unset API_SUBSCRIBER_URL
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(context list-apim-plans dev)
}

context() {
  printf "'%s'" "$(jq -nc --arg action "$1" --arg environment "$2" \
    '{notification: {action: $action, entity_nrn: "organization=1:account=2", service: {id: "s-1", dimensions: {environment: $environment}}, application: {id: 4}}}')"
}

plans_body() {
  echo '{"items":[{"id":"bronze","maxTps":5},{"id":"gold","maxTps":20},{"id":"no-limits"}]}'
}

run_handler() {
  run --separate-stderr bash "$HANDLER"
}

@test "devuelve los planes del subscriber del ambiente del service como opciones del desplegable" {
  queue_response 200 "$(plans_body)"
  run_handler
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"plans":[{"const":"bronze","title":"bronze (5 TPS)"},{"const":"gold","title":"gold (20 TPS)"},{"const":"no-limits","title":"no-limits (sin límite)"}]}' ]
  [ "$(cat "$CURL_CALLS_LOG")" = "GET https://api-subscriber-kuad-kuadrantorqs-dev.apps.paas-dev.bancogalicia.com.ar/v1/plans idem= auth=Bearer tok-123 timeouts=connectmax" ]
}

@test "el ambiente sale del service aunque venga con otro nombre" {
  NP_ACTION_CONTEXT=$(context list-apim-plans PRODUCTION)
  queue_response 200 "$(plans_body)"
  run_handler
  [ "$status" -eq 0 ]
  [[ "$(cat "$CURL_CALLS_LOG")" == "GET https://api-subscriber-kuad-kuadrantorqs-prd."* ]] || false
}

@test "API_SUBSCRIBER_URL reemplaza la URL del ambiente" {
  export API_SUBSCRIBER_URL="https://apisub.test"
  queue_response 200 "$(plans_body)"
  run_handler
  [ "$status" -eq 0 ]
  [[ "$(cat "$CURL_CALLS_LOG")" == "GET https://apisub.test/v1/plans "* ]] || false
}

@test "sin API_SUBSCRIBER_TOKEN no manda Authorization" {
  unset API_SUBSCRIBER_TOKEN
  queue_response 200 "$(plans_body)"
  run_handler
  [ "$status" -eq 0 ]
  [[ "$(cat "$CURL_CALLS_LOG")" == *" auth= "* ]] || false
}

@test "APIM_TLS_INSECURE en true no valida el certificado" {
  export APIM_TLS_INSECURE=true
  queue_response 200 "$(plans_body)"
  run_handler
  [ "$status" -eq 0 ]
  grep -qE -- "(^| )-k( |$)" "$CURL_ARGV_LOG"
}

@test "los logs van a stderr y stdout queda solo con el JSON" {
  queue_response 200 "$(plans_body)"
  run_handler
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -s length)" = "1" ]
}

@test "una accion desconocida falla sin llamar a APIM ni escribir en stdout" {
  NP_ACTION_CONTEXT=$(context list-otra-cosa dev)
  run_handler
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"list-otra-cosa"* ]] || false
  [ "$(curl_call_count)" = "0" ]
}

@test "un service sin ambiente valido falla sin llamar a APIM" {
  for environment in "" sandbox; do
    NP_ACTION_CONTEXT=$(context list-apim-plans "$environment")
    run_handler
    [ "$status" -ne 0 ] || false
    [ -z "$output" ] || false
  done
  [ "$(curl_call_count)" = "0" ]
}

@test "si APIM responde con error falla sin escribir en stdout" {
  queue_response 500 '{"detail":"boom"}'
  run_handler
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"HTTP 500"* ]] || false
}

@test "si APIM no responde falla sin reintentar" {
  queue_response 000 ""
  run_handler
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(curl_call_count)" = "1" ]
}

@test "una URL sin https no recibe el token" {
  export API_SUBSCRIBER_URL="http://apisub.test"
  run_handler
  [ "$status" -ne 0 ]
  [ "$(curl_call_count)" = "0" ]
}

@test "una respuesta sin planes falla en vez de dejar el desplegable vacio" {
  queue_response 200 '{"items":[]}'
  run_handler
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "no ofrece planes que el link despues rechazaria ni los repite" {
  queue_response 200 '{"items":[{"id":"gold","maxTps":20},{"id":"gold plus","maxTps":30},{"id":"gold","maxTps":20},"roto",{"maxTps":1}]}'
  run_handler
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.plans[].const]' <<<"$output")" = '["gold"]' ]
}
