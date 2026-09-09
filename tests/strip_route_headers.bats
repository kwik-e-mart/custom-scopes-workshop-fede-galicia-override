#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  source "${BATS_TEST_DIRNAME}/../shared/scripts/strip_route_headers"
  OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUTPUT_DIR"
  HEADERS=$'- x-np-token\n- x-np-origin\n- x-np-svc\n- x-np-scope\n- x-api-key'
}

route_without_filters() {
  cat > "$OUTPUT_DIR/ingress-1049050904-789675678.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: k-8-s-eks-1049050904-internal
  namespace: payments
spec:
  hostnames:
    - gal-poc-reports.galicia-poc.nullapps.io
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: s2s-ingress
      namespace: gateways
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: d-1049050904-789675678
          port: 8080
          weight: 1
EOF
}

removed() {
  yq -o=json -I=0 "[.spec.rules[$1].filters[] | select(.type == \"RequestHeaderModifier\")][0].requestHeaderModifier.remove" \
    "$OUTPUT_DIR/ingress-1049050904-789675678.yaml"
}

rhm_count() {
  yq "[.spec.rules[$1].filters[] | select(.type == \"RequestHeaderModifier\")] | length" \
    "$OUTPUT_DIR/ingress-1049050904-789675678.yaml"
}

@test "una route sin filtros queda con los headers en un RequestHeaderModifier" {
  route_without_filters
  run strip_route_headers "s2s headers" "$HEADERS"
  [ "$status" -eq 0 ]
  [ "$(rhm_count 0)" = "1" ]
  for h in x-np-token x-np-origin x-np-svc x-np-scope x-api-key; do
    [ "$(removed 0 | jq --arg h "$h" 'index($h) != null')" = "true" ]
  done
}

@test "correrlo dos veces no duplica el filtro ni los headers" {
  route_without_filters
  strip_route_headers "s2s headers" "$HEADERS"
  strip_route_headers "s2s headers" "$HEADERS"
  [ "$(rhm_count 0)" = "1" ]
  [ "$(removed 0 | jq 'length')" = "5" ]
}

@test "un RequestHeaderModifier preexistente se mergea, no se reemplaza" {
  cat > "$OUTPUT_DIR/ingress-1049050904-789675678.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: k-8-s-eks-1049050904-internal
spec:
  rules:
    - backendRefs: [{name: d-1, port: 8080}]
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-Custom
                value: conservame
            remove:
              - x-ya-estaba
EOF
  run strip_route_headers "s2s headers" "$HEADERS"
  [ "$status" -eq 0 ]
  [ "$(rhm_count 0)" = "1" ]
  [ "$(removed 0 | jq 'index("x-ya-estaba") != null')" = "true" ]
  [ "$(removed 0 | jq 'index("x-np-token") != null')" = "true" ]
  local f="$OUTPUT_DIR/ingress-1049050904-789675678.yaml"
  [ "$(yq '[.spec.rules[0].filters[] | select(.type == "RequestHeaderModifier")][0].requestHeaderModifier.set[0].value' "$f")" = "conservame" ]
}

@test "los filtros de otro tipo se conservan" {
  cat > "$OUTPUT_DIR/ingress-1049050904-789675678.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: k-8-s-eks-1049050904-internal
spec:
  rules:
    - backendRefs: [{name: d-1, port: 8080}]
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: destino.local
EOF
  run strip_route_headers "s2s headers" "$HEADERS"
  [ "$status" -eq 0 ]
  local f="$OUTPUT_DIR/ingress-1049050904-789675678.yaml"
  [ "$(yq '[.spec.rules[0].filters[] | select(.type == "URLRewrite")][0].urlRewrite.hostname' "$f")" = "destino.local" ]
  [ "$(rhm_count 0)" = "1" ]
}

@test "todas las rules quedan parcheadas, no sólo la primera" {
  cat > "$OUTPUT_DIR/ingress-1049050904-789675678.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: k-8-s-eks-1049050904-internal
spec:
  rules:
    - backendRefs: [{name: d-blue, port: 8080, weight: 50}]
    - backendRefs: [{name: d-green, port: 8080, weight: 50}]
EOF
  run strip_route_headers "s2s headers" "$HEADERS"
  [ "$status" -eq 0 ]
  [ "$(rhm_count 0)" = "1" ]
  [ "$(rhm_count 1)" = "1" ]
  [ "$(removed 1 | jq 'index("x-np-token") != null')" = "true" ]
}

@test "los nombres de header se normalizan a minúscula" {
  route_without_filters
  run strip_route_headers "s2s headers" $'- X-NP-Token\n- X-NP-Origin'
  [ "$status" -eq 0 ]
  [ "$(removed 0 | jq -r '.[0]')" = "x-np-token" ]
  [ "$(removed 0 | jq 'length')" = "2" ]
}

@test "una lista de headers vacía ABORTA en vez de aplicar una route sin strip" {
  route_without_filters
  run strip_route_headers "s2s headers" "[]"
  [ "$status" -eq 1 ]
  [[ "$output" == *"header list is empty"* ]]
}

@test "sin archivo de ingress no falla: un scope de CronJob no rinde route" {
  run strip_route_headers "s2s headers" "$HEADERS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to strip"* ]]
}
