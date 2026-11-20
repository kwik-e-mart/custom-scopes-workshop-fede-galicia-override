#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  OVERRIDE="${BATS_TEST_DIRNAME}/../override"
  STEP="$OVERRIDE/deployment/scripts/inject_apim_credentials"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/cluster"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  export KUBECTL_CLUSTER="$BATS_TEST_TMPDIR/cluster"
  export NP_MOCK_LINKS='[]'
  export NP_MOCK_SERVICES='{"svc-1":{"attributes":{"api_id":"cz-py-312-ms--b2c"}}}'
  export APIM_SECRETS
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c payments d604afed s3cr3t)]"
  export APIM_PUBLISHER_PROVIDER APIM_CREDENTIALS_NAMESPACE
  APIM_PUBLISHER_PROVIDER=$(yq -r '.configuration.APIM_PUBLISHER_PROVIDER' "$OVERRIDE/values.yaml")
  APIM_CREDENTIALS_NAMESPACE=$(yq -r '.configuration.APIM_CREDENTIALS_NAMESPACE' "$OVERRIDE/values.yaml")
  export CONTEXT
  CONTEXT=$(jq -nc '{application:{id:4, nrn:"organization=1:account=2:namespace=3:application=4"},
    scope:{nrn:"organization=1:account=2:namespace=3:application=4:scope=5", dimensions:{environment:"qas", site:"main"}},
    providers:{"container-orchestration":{cluster:{namespace:"payments"}}}}')
  unset NP_MOCK_FAIL NP_MOCK_GARBAGE NP_MOCK_SERVICE_FAIL KUBECTL_GET_FAIL KUBECTL_APPLY_FAIL KUBECTL_DELETE_FAIL

  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
case "${1-} ${2-}" in
  "link list")
    if [ "${NP_MOCK_FAIL:-0}" = "1" ]; then echo "np: unauthorized" >&2; exit 1; fi
    if [ "${NP_MOCK_GARBAGE:-0}" = "1" ]; then echo "warning: nueva version disponible"; exit 0; fi
    jq -nc --argjson links "$NP_MOCK_LINKS" '{results: $links}'
    ;;
  "service read")
    if [ "${3-}" != "--id" ]; then echo "mock np: falta --id: $*" >&2; exit 2; fi
    if [ "${NP_MOCK_SERVICE_FAIL:-0}" = "1" ]; then echo "np: unauthorized" >&2; exit 1; fi
    echo "$NP_MOCK_SERVICES" | jq -e --arg id "$4" '.[$id] // error("not found")' 2>/dev/null \
      || { echo "np: service $4 not found" >&2; exit 1; }
    ;;
  *) echo "mock np: comando no esperado: $*" >&2; exit 2 ;;
esac
MOCK
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$KUBECTL_CALLS_LOG"
positional=() namespace="" selector="" file="" output="" previous=""
for arg in "$@"; do
  case "$previous" in
    -n) namespace="$arg" ;;
    -l) selector="$arg" ;;
    -f) file="$arg" ;;
    -o) output="$arg" ;;
  esac
  case "$arg" in
    -n|-l|-f|-o) ;;
    -*) ;;
    *) case "$previous" in -n|-l|-f|-o) ;; *) positional+=("$arg") ;; esac ;;
  esac
  previous="$arg"
done
case "${positional[0]-} ${positional[1]-}" in
  "get secret")
    if [ "${KUBECTL_GET_FAIL:-0}" = "1" ]; then echo "Error from server (Forbidden): secrets is forbidden" >&2; exit 1; fi
    if [ -n "$selector" ]; then
      [ "$output" = "json" ] || { echo "mock kubectl: get -l sin -o json" >&2; exit 2; }
      consumer_ns=$(echo "$selector" | tr ',' '\n' | sed -n 's/^consumer-ns=//p')
      api_id=$(echo "$selector" | tr ',' '\n' | sed -n 's/^api-id=//p')
      [ "$namespace" = "$APIM_CREDENTIALS_NAMESPACE" ] || { echo '{"items":[]}'; exit 0; }
      echo "$APIM_SECRETS" | jq -c --arg ns "$consumer_ns" --arg api "$api_id" \
        '{items: [.[] | select(.metadata.labels["consumer-ns"] == $ns and .metadata.labels["api-id"] == $api)]}'
      exit 0
    fi
    if [ -f "$KUBECTL_CLUSTER/$namespace.${positional[2]}" ]; then echo "secret/${positional[2]}"; exit 0; fi
    echo "Error from server (NotFound): secrets \"${positional[2]}\" not found" >&2
    exit 1
    ;;
  "apply ")
    [ "$file" = "-" ] || { echo "mock kubectl: apply sin -f -" >&2; exit 2; }
    manifest=$(cat)
    if [ "${KUBECTL_APPLY_FAIL:-0}" = "1" ]; then echo "Error from server (Forbidden): secrets is forbidden" >&2; exit 1; fi
    target_ns=$(echo "$manifest" | jq -r '.metadata.namespace')
    target_name=$(echo "$manifest" | jq -r '.metadata.name')
    echo "$manifest" >"$KUBECTL_CLUSTER/$target_ns.$target_name"
    echo "secret/$target_name serverside-applied"
    ;;
  "delete secret")
    if [ "${KUBECTL_DELETE_FAIL:-0}" = "1" ]; then echo "Error from server (Forbidden): secrets is forbidden" >&2; exit 1; fi
    rm -f "$KUBECTL_CLUSTER/$namespace.${positional[2]}"
    ;;
  *) echo "mock kubectl: comando no esperado: $*" >&2; exit 2 ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np" "$BATS_TEST_TMPDIR/bin/kubectl"

  cat >"$OUTPUT_DIR/deployment-5.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: d-5-6
  namespace: payments
spec:
  template:
    spec:
      containers:
        - name: http
          image: traffic
        - name: application
          image: app
          env:
            - name: PORT
              value: "8080"
EOF
}

apim_secret() {
  jq -nc --arg api "$1" --arg ns "$2" --arg app "$3" --arg key "$(printf %s "$4" | base64)" '{
    metadata: {name: "sub-\($api)--\($ns)", namespace: "apim-credentials",
      labels: {"api-id": $api, "app-id": $app, "consumer-ns": $ns, "authorino.kuadrant.io/managed-by": "authorino"}},
    data: {api_key: $key}}'
}

run_step() {
  run bash -c 'set -euo pipefail; source "$1"; echo NEXT_STEP_RAN' _ "$STEP"
}

link() {
  jq -nc --arg provider "$1" --arg entity "$2" --argjson dims "${3:-null}" --arg service "${4:-svc-1}" \
    '{id: "l-1", status: "active", service_id: $service, entity_nrn: $entity, selectors: {provider: $provider}, dimensions: $dims}'
}

app_env() {
  yq -o=json -I=0 '.spec.template.spec.containers[] | select(.name == "application") | .env' "$OUTPUT_DIR/deployment-5.yaml"
}

app_secret() {
  cat "$KUBECTL_CLUSTER/payments.apim-credentials-4"
}

decoded() {
  app_secret | jq -r --arg k "$1" '.data[$k]' | base64 --decode
}

APP_NRN="organization=1:account=2:namespace=3:application=4"
SCOPE_NRN="organization=1:account=2:namespace=3:application=4:scope=5"
NO_CREDENTIAL_ENV='[{"name":"PORT","value":"8080"}]'
CREDENTIAL_ENV='[{"name":"PORT","value":"8080"},{"name":"APIM_APP_ID","valueFrom":{"secretKeyRef":{"name":"apim-credentials-4","key":"app_id"}}},{"name":"APIM_APP_KEY","valueFrom":{"secretKeyRef":{"name":"apim-credentials-4","key":"app_key"}}}]'

@test "sin link del api manager no toca el deployment y sigue el workflow" {
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"APIM_APP_ID"* ]] || false
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "sin link del api manager borra la credencial que la aplicacion tenia de antes" {
  echo '{}' >"$KUBECTL_CLUSTER/payments.apim-credentials-4"
  run_step
  [ "$status" -eq 0 ]
  [ ! -e "$KUBECTL_CLUSTER/payments.apim-credentials-4" ]
  grep -qF '["delete","secret","apim-credentials-4","-n","payments","--ignore-not-found"]' "$KUBECTL_CALLS_LOG"
}

@test "si no puede borrar la credencial vieja avisa y sigue el workflow" {
  export KUBECTL_DELETE_FAIL=1
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"*"apim-credentials-4"* ]] || false
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
}

@test "busca los links activos de la aplicacion y sus descendientes" {
  run_step
  [ "$(head -n1 "$NP_CALLS_LOG")" = "$(jq -nc --arg nrn "$APP_NRN" '["link","list","--nrn",$nrn,"--status","active","--format","json","--show_descendants"]')" ]
}

@test "con link del scope inyecta la credencial de la aplicacion como APIM_APP_ID y APIM_APP_KEY" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$CREDENTIAL_ENV" ]
}

@test "copia el app-id y el api_key de la suscripcion al secret de la aplicacion" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  run_step
  [ "$(decoded app_id)" = "d604afed" ]
  [ "$(decoded app_key)" = "s3cr3t" ]
  [ "$(app_secret | jq -c '{apiVersion, kind, type, metadata}')" = '{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"apim-credentials-4","namespace":"payments","labels":{"app.kubernetes.io/managed-by":"nullplatform","nullplatform.com/application-id":"4"}}}' ]
}

@test "busca la credencial en apim-credentials por el namespace y el api_id del servicio linkeado" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  run_step
  grep -qF '["service","read","--id","svc-1","--format","json"]' "$NP_CALLS_LOG"
  grep -qF '["get","secret","-n","apim-credentials","-l","consumer-ns=payments,api-id=cz-py-312-ms--b2c","-o","json"]' "$KUBECTL_CALLS_LOG"
}

@test "aplica el secret por server side y sin la credencial en los argumentos" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  run_step
  grep -qF '["apply","--server-side","--field-manager=nullplatform-apim-credentials","--force-conflicts","-f","-"]' "$KUBECTL_CALLS_LOG"
  ! grep -qF "$(printf s3cr3t | base64)" "$KUBECTL_CALLS_LOG" || false
  [[ "$output" != *"s3cr3t"* ]] || false
}

@test "cada deploy actualiza el mismo secret de la aplicacion" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  run_step
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c payments d604afed rotada)]"
  run_step
  [ "$(decoded app_key)" = "rotada" ]
  [ "$(ls "$KUBECTL_CLUSTER")" = "payments.apim-credentials-4" ]
}

@test "con link de la aplicacion y las dimensiones del scope inyecta la credencial" {
  NP_MOCK_LINKS="[$(link "API Manager" "$APP_NRN" '{"environment":"qas"}')]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(app_env)" = "$CREDENTIAL_ENV" ]
}

@test "un link de la aplicacion con otras dimensiones no aplica a este scope" {
  NP_MOCK_LINKS="[$(link "API Manager" "$APP_NRN" '{"environment":"prd"}')]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "el deploy de un scope sin link no borra el secret que usa otro scope de la aplicacion" {
  NP_MOCK_LINKS="[$(link "API Manager" "$APP_NRN" '{"environment":"prd"}')]"
  echo '{}' >"$KUBECTL_CLUSTER/payments.apim-credentials-4"
  run_step
  [ "$status" -eq 0 ]
  [ -e "$KUBECTL_CLUSTER/payments.apim-credentials-4" ]
  ! grep -qF '"delete"' "$KUBECTL_CALLS_LOG" || false
}

@test "las APIs linkeadas desde otros scopes de la aplicacion tambien definen la credencial" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN"),$(link "API Manager" "$APP_NRN" '{"environment":"prd"}' svc-2)]"
  NP_MOCK_SERVICES='{"svc-1":{"attributes":{"api_id":"cz-py-312-ms--b2c"}},"svc-2":{"attributes":{"api_id":"otra--b2c"}}}'
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c payments d604afed s3cr3t),$(apim_secret otra--b2c payments 0a1b2c3d s3cr3t)]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"*"otra--b2c"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "un api_id que no es un valor de label avisa y no se busca" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  NP_MOCK_SERVICES='{"svc-1":{"attributes":{"api_id":"x,consumer-ns!=payments"}}}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"*"x,consumer-ns!=payments"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
  ! grep -qF '"get","secret","-n","apim-credentials"' "$KUBECTL_CALLS_LOG" || false
}

@test "un link de otro servicio no inyecta la credencial" {
  NP_MOCK_LINKS="[$(link "Servicios POM" "$SCOPE_NRN")]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "con link pero sin credencial en apim-credentials avisa y sigue sin inyectar" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  APIM_SECRETS='[]'
  echo '{}' >"$KUBECTL_CLUSTER/payments.apim-credentials-4"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"*"cz-py-312-ms--b2c"* ]] || false
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
  [ -e "$KUBECTL_CLUSTER/payments.apim-credentials-4" ]
}

@test "la credencial de otro namespace no se usa" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c otro-ns d604afed s3cr3t)]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "un servicio linkeado que todavia no se publico avisa y sigue sin inyectar" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  NP_MOCK_SERVICES='{"svc-1":{"attributes":{}}}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
  ! grep -qF '"get","secret","-n","apim-credentials"' "$KUBECTL_CALLS_LOG" || false
}

@test "dos APIs con el mismo app-id inyectan una sola credencial" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN"),$(link "API Manager" "$SCOPE_NRN" null svc-2)]"
  NP_MOCK_SERVICES='{"svc-1":{"attributes":{"api_id":"cz-py-312-ms--b2c"}},"svc-2":{"attributes":{"api_id":"otra--b2c"}}}'
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c payments d604afed s3cr3t),$(apim_secret otra--b2c payments d604afed s3cr3t)]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(app_env)" = "$CREDENTIAL_ENV" ]
}

@test "dos APIs con app-id distintos avisan y no inyectan ninguna" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN"),$(link "API Manager" "$SCOPE_NRN" null svc-2)]"
  NP_MOCK_SERVICES='{"svc-1":{"attributes":{"api_id":"cz-py-312-ms--b2c"}},"svc-2":{"attributes":{"api_id":"otra--b2c"}}}'
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c payments d604afed s3cr3t),$(apim_secret otra--b2c payments 0a1b2c3d s3cr3t)]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"*"cz-py-312-ms--b2c"*"otra--b2c"* ]] || false
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
  ! grep -qF '"apply"' "$KUBECTL_CALLS_LOG" || false
}

@test "si no puede leer el servicio linkeado corta el deployment" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  export NP_MOCK_SERVICE_FAIL=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [[ "$output" == *"svc-1"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "si no puede leer apim-credentials corta el deployment" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  export KUBECTL_GET_FAIL=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [[ "$output" == *"apim-credentials"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "si no puede guardar el secret de la aplicacion corta el deployment" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  export KUBECTL_APPLY_FAIL=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [[ "$output" == *"apim-credentials-4"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "un secret de suscripcion sin app-id no cuenta como credencial" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c payments d604afed s3cr3t | jq -c 'del(.metadata.labels["app-id"])')]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "sin namespace del provider en el contexto corta el deployment" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.providers)')
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "si una de las APIs linkeadas no tiene credencial avisa cual falta e inyecta la del namespace" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN"),$(link "API Manager" "$SCOPE_NRN" null svc-2)]"
  NP_MOCK_SERVICES='{"svc-1":{"attributes":{"api_id":"cz-py-312-ms--b2c"}},"svc-2":{"attributes":{"api_id":"otra--b2c"}}}'
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"*"otra--b2c"* ]] || false
  [ "$(app_env)" = "$CREDENTIAL_ENV" ]
}

@test "dos APIs con el mismo app-id y distinta api_key avisan y no inyectan ninguna" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN"),$(link "API Manager" "$SCOPE_NRN" null svc-2)]"
  NP_MOCK_SERVICES='{"svc-1":{"attributes":{"api_id":"cz-py-312-ms--b2c"}},"svc-2":{"attributes":{"api_id":"otra--b2c"}}}'
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c payments d604afed s3cr3t),$(apim_secret otra--b2c payments d604afed otra-clave)]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"*"cz-py-312-ms--b2c"*"otra--b2c"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
  ! grep -qF '"apply"' "$KUBECTL_CALLS_LOG" || false
}

@test "un link sin service_id avisa y sigue sin inyectar" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN" | jq -c 'del(.service_id)')]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"*"the linked APIs"* ]] || false
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
  ! grep -qF '"get","secret","-n","apim-credentials"' "$KUBECTL_CALLS_LOG" || false
}

@test "dos links al mismo servicio leen el servicio y la credencial una sola vez" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN"),$(link "API Manager" "$APP_NRN" '{"environment":"qas"}')]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(app_env)" = "$CREDENTIAL_ENV" ]
  [ "$(grep -cF '"service","read"' "$NP_CALLS_LOG")" -eq 1 ]
  [ "$(grep -cF '"get","secret","-n","apim-credentials"' "$KUBECTL_CALLS_LOG")" -eq 1 ]
}

@test "el secret y la referencia usan el id de la aplicacion del contexto" {
  CONTEXT=$(echo "$CONTEXT" | jq -c '.application.id = 7')
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metadata.name, .metadata.labels["nullplatform.com/application-id"]' "$KUBECTL_CLUSTER/payments.apim-credentials-7" | paste -sd, -)" = "apim-credentials-7,7" ]
  [[ "$(app_env)" == *'"name":"apim-credentials-7"'* ]] || false
}

@test "un secret de suscripcion sin api_key no cuenta como credencial" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  APIM_SECRETS="[$(apim_secret cz-py-312-ms--b2c payments d604afed s3cr3t | jq -c 'del(.data.api_key)')]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
  ! grep -qF '"apply"' "$KUBECTL_CALLS_LOG" || false
}

@test "si no puede listar los links corta el deployment" {
  export NP_MOCK_FAIL=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}

@test "los workflows del override corren el paso despues de crear el deployment" {
  for workflow in initial blue_green; do
    [ "$(yq -o=json -I=0 '.steps[] | select(.name == "inject_apim_credentials") | pick(["type", "after", "file"])' "$OVERRIDE/deployment/workflows/$workflow.yaml")" = '{"type":"script","after":"create deployment","file":"$OVERRIDES_PATH/deployment/scripts/inject_apim_credentials"}' ]
  done
}

@test "si la respuesta de los links no se puede leer corta el deployment" {
  export NP_MOCK_GARBAGE=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$NO_CREDENTIAL_ENV" ]
}
