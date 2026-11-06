#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  OVERRIDE="${BATS_TEST_DIRNAME}/../override"
  STEP="$OVERRIDE/deployment/scripts/apim_auth_policy"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/out"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
  export SCOPE_ID=5 DEPLOYMENT_ID=6
  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  export NP_MOCK_SERVICES='[]'
  export APIM_PUBLISHER_PROVIDER
  APIM_PUBLISHER_PROVIDER=$(yq -r '.configuration.APIM_PUBLISHER_PROVIDER' "$OVERRIDE/values.yaml")
  export CONTEXT
  CONTEXT=$(jq -nc '{application:{repository_url:"https://github.com/zosc-zosconnect/test-kuadrant"},
    scope:{id:5, slug:"main", nrn:"organization=1:account=2:namespace=3:application=4:scope=5"}}')
  unset NP_MOCK_FAIL APPLICATION_TYPES_WITH_NO_AUTH_POLICY

  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "${1-} ${2-}" != "service list" ]; then echo "mock np: comando no esperado: $*" >&2; exit 2; fi
if [ "${NP_MOCK_FAIL:-0}" = "1" ]; then echo "np: unauthorized" >&2; exit 1; fi
jq -nc --argjson services "$NP_MOCK_SERVICES" '{results: $services}'
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"

  cat >"$OUTPUT_DIR/ingress-5-6.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: k-8-s-main-5-internal
  namespace: payments
  labels:
    nullplatform: "true"
    scope_id: "5"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: k-8-s-main-5-grpc
  namespace: payments
EOF
}

run_step() {
  run bash -c 'set -euo pipefail; source "$1"; echo NEXT_STEP_RAN' _ "$STEP"
}

policies() {
  yq -o=json -I=0 'select(.kind == "AuthPolicy")' "$OUTPUT_DIR/authpolicy-apim-5-6.yaml" | jq -sc 'sort_by(.metadata.name)'
}

service() {
  jq -nc --arg provider "$1" --arg scope "$2" --arg api "$3" \
    '{id: "s-1", name: "Payments API", status: "active", selectors: {provider: $provider}, attributes: ({scope: $scope} + (if $api == "" then {} else {api_id: $api} end))}'
}

set_application_type() {
  CONTEXT=$(echo "$CONTEXT" | jq -c --arg type "$1" '.application.metadata = {scaffolding: {application_type: $type}}')
}

@test "el initial genera la AuthPolicy despues de rendear los manifiestos y antes del apply" {
  [ "$(yq -o=json -I=0 '.steps[] | select(.name == "apim_auth_policy") | pick(["type", "after", "file"])' "$OVERRIDE/deployment/workflows/initial.yaml")" = '{"type":"script","after":"create deployment","file":"$OVERRIDES_PATH/deployment/scripts/apim_auth_policy"}' ]
}

@test "el blue green no toca la AuthPolicy" {
  [ -z "$(yq '.steps[] | select(.name == "apim_auth_policy")' "$OVERRIDE/deployment/workflows/blue_green.yaml")" ]
}

@test "sin API publicada cuelga en cada route una AuthPolicy con el apiId por default" {
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(policies | jq -c '[.[] | {name: .metadata.name, namespace: .metadata.namespace, route: .spec.targetRef.name}]')" = \
    '[{"name":"payments-test-kuadrant-b2c-1-k-8-s-main-5-grpc","namespace":"payments","route":"k-8-s-main-5-grpc"},{"name":"payments-test-kuadrant-b2c-1-k-8-s-main-5-internal","namespace":"payments","route":"k-8-s-main-5-internal"}]' ]
}

@test "la AuthPolicy acepta solo las credenciales de la API y se combina con el validador del s2s" {
  run_step
  local policy
  policy=$(policies | jq -c '.[1]')
  [ "$(jq -c .metadata.labels <<<"$policy")" = '{"app.kubernetes.io/managed-by":"api-manager-publisher","api-id":"payments-test-kuadrant-b2c-1","scope_id":"5"}' ]
  [ "$(jq -c .spec.targetRef <<<"$policy")" = '{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"k-8-s-main-5-internal"}' ]
  [ "$(jq -r .spec.defaults.strategy <<<"$policy")" = "merge" ]
  [ "$(jq -c '.spec.defaults.rules.authentication."payments-test-kuadrant-b2c-1"' <<<"$policy")" = \
    '{"apiKey":{"selector":{"matchLabels":{"api-id":"payments-test-kuadrant-b2c-1"}},"allNamespaces":true},"credentials":{"customHeader":{"name":"app_key"}}}' ]
}

@test "con la API ya publicada sobre el scope usa el apiId de APIM" {
  NP_MOCK_SERVICES="[$(service "$APIM_PUBLISHER_PROVIDER" main apim-otro-id)]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(policies | jq -r '[.[].metadata.labels."api-id"] | unique | join(",")')" = "apim-otro-id" ]
}

@test "busca la API entre los services de la aplicacion del scope sin los archivados" {
  run_step
  [ "$(jq -c 'select(.[0:2] == ["service","list"]) | [.[2:][]] | (index("--nrn") as $i | .[$i + 1]), (index("--status:ne") as $i | .[$i + 1]), (index("--all") != null)' "$NP_CALLS_LOG" | paste -sd, -)" = '"organization=1:account=2:namespace=3:application=4","archived",true' ]
}

@test "una API de otro scope, de otro provider o sin apiId no cambia el default" {
  NP_MOCK_SERVICES="[$(service "$APIM_PUBLISHER_PROVIDER" otro apim-otro-scope),$(service AWS main apim-otro-provider),$(service "$APIM_PUBLISHER_PROVIDER" main "")]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(policies | jq -r '[.[].metadata.labels."api-id"] | unique | join(",")')" = "payments-test-kuadrant-b2c-1" ]
}

@test "el nombre del repo va en minuscula y sin .git en el apiId por default" {
  CONTEXT=$(echo "$CONTEXT" | jq -c '.application.repository_url = "https://github.com/zosc/Test-Kuadrant.git"')
  run_step
  [ "$status" -eq 0 ]
  [ "$(policies | jq -r '.[0].metadata.labels."api-id"')" = "payments-test-kuadrant-b2c-1" ]
}

@test "si no puede listar los services frena el deploy sin generar la AuthPolicy" {
  export NP_MOCK_FAIL=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [ ! -e "$OUTPUT_DIR/authpolicy-apim-5-6.yaml" ]
}

@test "sin repository_url ni API publicada frena el deploy" {
  CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.application.repository_url)')
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"repository_url"* ]] || false
  [ ! -e "$OUTPUT_DIR/authpolicy-apim-5-6.yaml" ]
}

@test "un apiId que no sirve como nombre de Kubernetes frena el deploy" {
  NP_MOCK_SERVICES="[$(service "$APIM_PUBLISHER_PROVIDER" main "API_Invalida")]"
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"API_Invalida"* ]] || false
  [ ! -e "$OUTPUT_DIR/authpolicy-apim-5-6.yaml" ]
}

@test "una aplicacion BFF o SPA queda sin AuthPolicy" {
  for type in BFF SPA; do
    set_application_type "$type"
    run_step
    [ "$status" -eq 0 ] || false
    [[ "$output" == *NEXT_STEP_RAN* ]] || false
    [ ! -e "$OUTPUT_DIR/authpolicy-apim-5-6.yaml" ] || false
  done
  [ ! -s "$NP_CALLS_LOG" ]
}

@test "APPLICATION_TYPES_WITH_NO_AUTH_POLICY elige que tipos quedan sin AuthPolicy" {
  export APPLICATION_TYPES_WITH_NO_AUTH_POLICY=API
  set_application_type API
  run_step
  [ "$status" -eq 0 ]
  [ ! -e "$OUTPUT_DIR/authpolicy-apim-5-6.yaml" ]
}

@test "sin routes rendeadas sigue el deploy sin generar la AuthPolicy" {
  rm "$OUTPUT_DIR/ingress-5-6.yaml"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ ! -e "$OUTPUT_DIR/authpolicy-apim-5-6.yaml" ]
}
