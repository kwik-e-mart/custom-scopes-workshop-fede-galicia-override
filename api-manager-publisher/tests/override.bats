#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  OVERRIDE="${BATS_TEST_DIRNAME}/../override"
  STEP="$OVERRIDE/deployment/scripts/inject_apim_credentials"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/out"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  export NP_MOCK_LINKS='[]'
  export KUBECTL_SECRETS="payments/secret-apim-b2c"
  export APIM_PUBLISHER_PROVIDER
  APIM_PUBLISHER_PROVIDER=$(yq -r '.configuration.APIM_PUBLISHER_PROVIDER' "$OVERRIDE/values.yaml")
  export CONTEXT
  CONTEXT=$(jq -nc '{application:{nrn:"organization=1:account=2:namespace=3:application=4"},
    scope:{nrn:"organization=1:account=2:namespace=3:application=4:scope=5", dimensions:{environment:"qas", site:"main"}}}')
  unset NP_MOCK_FAIL NP_MOCK_GARBAGE

  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "${1-} ${2-}" != "link list" ]; then echo "mock np: comando no esperado: $*" >&2; exit 2; fi
if [ "${NP_MOCK_FAIL:-0}" = "1" ]; then echo "np: unauthorized" >&2; exit 1; fi
if [ "${NP_MOCK_GARBAGE:-0}" = "1" ]; then echo "warning: nueva version disponible"; exit 0; fi
jq -nc --argjson links "$NP_MOCK_LINKS" '{results: $links}'
MOCK
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
if [ "${1-} ${2-}" != "get secret" ] || [ "${4-}" != "-n" ]; then echo "mock kubectl: comando no esperado: $*" >&2; exit 2; fi
case ",$KUBECTL_SECRETS," in
  *",$5/$3,"*) echo "secret/$3" ;;
  *) echo "Error from server (NotFound): secrets \"$3\" not found" >&2; exit 1 ;;
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

run_step() {
  run bash -c 'set -euo pipefail; source "$1"; echo NEXT_STEP_RAN' _ "$STEP"
}

link() {
  jq -nc --arg provider "$1" --arg entity "$2" --argjson dims "${3:-null}" \
    '{id: "l-1", status: "active", entity_nrn: $entity, selectors: {provider: $provider}, dimensions: $dims}'
}

app_env() {
  yq -o=json -I=0 '.spec.template.spec.containers[] | select(.name == "application") | .env' "$OUTPUT_DIR/deployment-5.yaml"
}

APP_NRN="organization=1:account=2:namespace=3:application=4"
SCOPE_NRN="organization=1:account=2:namespace=3:application=4:scope=5"
CREDENTIAL_ENV='[{"name":"PORT","value":"8080"},{"name":"APIM_APP_ID","valueFrom":{"secretKeyRef":{"name":"secret-apim-b2c","key":"app_id"}}},{"name":"APIM_APP_KEY","valueFrom":{"secretKeyRef":{"name":"secret-apim-b2c","key":"app_key"}}}]'

@test "sin link del api manager no toca el deployment y sigue el workflow" {
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"APIM_APP_ID"* ]] || false
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = '[{"name":"PORT","value":"8080"}]' ]
}

@test "busca los links activos de la aplicacion y sus descendientes" {
  run_step
  [ "$(head -n1 "$NP_CALLS_LOG")" = "$(jq -nc --arg nrn "$APP_NRN" '["link","list","--nrn",$nrn,"--status","active","--format","json","--show_descendants"]')" ]
}

@test "con link del scope inyecta la credencial como APIM_APP_ID y APIM_APP_KEY" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = "$CREDENTIAL_ENV" ]
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
  [ "$(app_env)" = '[{"name":"PORT","value":"8080"}]' ]
}

@test "un link de otro servicio no inyecta la credencial" {
  NP_MOCK_LINKS="[$(link "Servicios POM" "$SCOPE_NRN")]"
  run_step
  [ "$status" -eq 0 ]
  [ "$(app_env)" = '[{"name":"PORT","value":"8080"}]' ]
}

@test "con link pero sin la credencial en el namespace corta el deployment" {
  NP_MOCK_LINKS="[$(link "API Manager" "$SCOPE_NRN")]"
  KUBECTL_SECRETS=""
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [[ "$output" == *"secret payments/secret-apim-b2c"* ]] || false
  [ "$(app_env)" = '[{"name":"PORT","value":"8080"}]' ]
}

@test "si no puede listar los links corta el deployment" {
  export NP_MOCK_FAIL=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [ "$(app_env)" = '[{"name":"PORT","value":"8080"}]' ]
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
  [ "$(app_env)" = '[{"name":"PORT","value":"8080"}]' ]
}
