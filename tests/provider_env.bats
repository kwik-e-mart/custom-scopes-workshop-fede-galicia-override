#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  provider_env_secret_exists() { [ "$1" = "secret-apim-b2c" ]; }
  source "${BATS_TEST_DIRNAME}/../shared/scripts/provider_env"
  OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUTPUT_DIR"
  cat > "$OUTPUT_DIR/deployment-1.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: d-1
  namespace: payments
spec:
  template:
    spec:
      containers:
        - name: application
          image: app
EOF
}

app_env() {
  yq -o=json -I=0 '.spec.template.spec.containers[] | select(.name == "application") | .env' "$OUTPUT_DIR/deployment-1.yaml"
}

@test "una variable secret con key toma esa key del secret" {
  inject_provider_env "APIM" '[{"name":"APIM_APP_ID","type":"secret","value":"secret-apim-b2c","key":"app_id"}]'
  [ "$(app_env)" = '[{"name":"APIM_APP_ID","valueFrom":{"secretKeyRef":{"name":"secret-apim-b2c","key":"app_id"}}}]' ]
}

@test "una variable secret sin key usa el nombre de la variable como key" {
  inject_provider_env "APIM" '[{"name":"app_key","type":"Secret","value":"secret-apim-b2c"}]'
  [ "$(app_env)" = '[{"name":"app_key","valueFrom":{"secretKeyRef":{"name":"secret-apim-b2c","key":"app_key"}}}]' ]
}

@test "un secret que no existe en el namespace corta antes de tocar el deployment" {
  run inject_provider_env "APIM" '[{"name":"APIM_APP_ID","type":"secret","value":"otro-secret","key":"app_id"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"secret payments/otro-secret"* ]] || false
  [ "$(app_env)" = "null" ]
}
