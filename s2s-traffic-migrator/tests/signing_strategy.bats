#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v gomplate >/dev/null && command -v yq >/dev/null || {
    echo "bats necesita gomplate y yq." >&2; return 1
  }
  BC="${BATS_TEST_DIRNAME}/../scripts/k8s/build_context"
  source "${BATS_TEST_DIRNAME}/../logging"
  export -f log
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib"

  export PEER_GATEWAY_HOST=kuadrant.peer.example.io
  export NETWORKING_VAULT_ADDR=https://vault.example.io:8200
  export NETWORKING_VAULT_SPIFFE_MOUNT=spiffe

  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  export NP_MOCK_SCOPES='[{"slug":"dev","domain":"reports-dev.example.io"}]'
  : >"$NP_CALLS_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NP_CALLS_LOG"
QUERY=.
while [ $# -gt 0 ]; do
  case "$1" in
    --query) QUERY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf %s "$NP_MOCK_SCOPES" | jq -c '{results: .}' | jq -c "$QUERY"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

ctx() {
  jq -nc '{providers:{"container-orchestration":{cluster:{namespace:"payments"}}},
           account:{}, namespace:{}, application:{id:142495574}}'
}

notif() {
  jq -nc '{notification:{type:"create", service:{id:"svc-1",
    attributes:{interceptions:[{service_name:"reports",scope:"dev",percent:50}]},
    dimensions:{site:"openshift-crc"}}, parameters:{}}}'
}

run_bc() { CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" run bash "$BC"; }

render_ctx() {
  jq -n --arg strategy "$1" '{
    namespace:"payments", gateway_name:"s2s-egress", gateway_class:"istio",
    listen_port:8080, token_duration:300, wristband_secret:"payments-wristband-key",
    peer_ca_secret:"s2s-remote-ca", peer_gateway_host:"kuadrant.peer.example.io",
    local_ingress_host:"s2s-ingress-istio.gateways.svc.cluster.local",
    gateway_namespace:"gateways", cluster_label:"crc-openshift",
    authpolicy_api_version:"kuadrant.io/v1",
    managed_label:"egress-interceptor/managed",
    signing_strategy:$strategy,
    vault_addr:"https://vault.example.io:8200", vault_namespace:"admin/spiffe",
    vault_spiffe_mount:"spiffe", vault_token_secret:"s2s-vault-token",
    platform:"openshift",
    interceptions:[{service_name:"reports", scope:"dev", scope_fqdn:"reports-dev.example.io",
                    percent:50, original:{selector:{app:"reports"},ports:[{port:8080,targetPort:8080}]}}]
  }' >"$BATS_TEST_TMPDIR/render-ctx.json"
}

render() {
  render_ctx "$1"
  local out="$BATS_TEST_TMPDIR/out" f first=1
  rm -rf "$out"
  render_all_manifests "$BATS_TEST_TMPDIR/render-ctx.json" "$out" "$1" \
    >"$BATS_TEST_TMPDIR/list.txt" || return 1
  while IFS= read -r f; do
    [ "$first" = 1 ] && first=0 || printf -- '---\n'
    cat "$f"
  done <"$BATS_TEST_TMPDIR/list.txt"
}

rendered_files() {
  render_ctx "$1"
  local out="$BATS_TEST_TMPDIR/out2"
  rm -rf "$out"
  render_all_manifests "$BATS_TEST_TMPDIR/render-ctx.json" "$out" "$1" | xargs -n1 basename
}

doc() { echo "$1" | yq "select(.kind == \"$2\") | ... comments=\"\""; }

@test "sin declarar la variable, la estrategia es spiffe" {
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" == *"strategy=spiffe"* ]]
}

@test "cluster-keys explícito se respeta" {
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" \
    S2S_TRAFFIC_MIGRATOR_SIGNING_STRATEGY=cluster-keys run bash "$BC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strategy=cluster-keys"* ]]
}

@test "una estrategia que no existe ABORTA en vez de elegir una" {
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" \
    S2S_TRAFFIC_MIGRATOR_SIGNING_STRATEGY=spiffee run bash "$BC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spiffee"* ]]
  [[ "$output" == *"cluster-keys"* ]]
}

@test "la estrategia vacía ABORTA en vez de caer al default" {
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" \
    S2S_TRAFFIC_MIGRATOR_SIGNING_STRATEGY="" run bash "$BC"
  [ "$status" -ne 0 ]
}

@test "con spiffe y reglas, falta NETWORKING_VAULT_ADDR y aborta" {
  unset NETWORKING_VAULT_ADDR
  run_bc
  [ "$status" -ne 0 ]
  [[ "$output" == *"NETWORKING_VAULT_ADDR"* ]]
}

@test "con spiffe y reglas, falta NETWORKING_VAULT_SPIFFE_MOUNT y aborta" {
  unset NETWORKING_VAULT_SPIFFE_MOUNT
  run_bc
  [ "$status" -ne 0 ]
  [[ "$output" == *"NETWORKING_VAULT_SPIFFE_MOUNT"* ]]
}

@test "cluster-keys NO exige ninguna variable de Vault" {
  unset NETWORKING_VAULT_ADDR NETWORKING_VAULT_SPIFFE_MOUNT
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" \
    S2S_TRAFFIC_MIGRATOR_SIGNING_STRATEGY=cluster-keys run bash "$BC"
  [ "$status" -eq 0 ]
}

@test "una NETWORKING_VAULT_ADDR que no es una URL https aborta" {
  export NETWORKING_VAULT_ADDR="vault.example.io:8200"
  run_bc
  [ "$status" -ne 0 ]
  [[ "$output" == *"NETWORKING_VAULT_ADDR"* ]]
}

@test "con spiffe, TOKEN_DURATION seteado avisa que no tiene efecto" {
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" TOKEN_DURATION=60 run bash "$BC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOKEN_DURATION"* ]]
  [[ "$output" == *"spiffe"* ]]
}

@test "con spiffe, WRISTBAND_SECRET_NAME seteado avisa que no tiene efecto" {
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" \
    WRISTBAND_SECRET_NAME=payments-wristband-key run bash "$BC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WRISTBAND_SECRET_NAME"* ]]
}

@test "con cluster-keys, las variables de Vault seteadas avisan que no tienen efecto" {
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" \
    S2S_TRAFFIC_MIGRATOR_SIGNING_STRATEGY=cluster-keys run bash "$BC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NETWORKING_VAULT_ADDR"* ]]
}

@test "con spiffe, TOKEN_DURATION en su default NO avisa nada" {
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" != *"TOKEN_DURATION"* ]]
}

@test "spiffe rinde una AuthPolicy que mintea contra el role del namespace" {
  run render spiffe
  [ "$status" -eq 0 ]
  local ap; ap=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap" | yq '.spec.rules.metadata.vault_mint.http.url')" = \
    "https://vault.example.io:8200/v1/spiffe/role/crc-openshift-payments/mintjwt" ]
  [ "$(echo "$ap" | yq '.spec.rules.metadata.vault_mint.http.method')" = "POST" ]
}

@test "el cache del mint tiene una key POR NAMESPACE, no una constante compartida" {
  run render spiffe
  [ "$status" -eq 0 ]
  local ap; ap=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap" | yq '.spec.rules.metadata.vault_mint.cache.key.expression')" = \
    '"crc-openshift-payments"' ]
}

@test "el TTL del cache queda por debajo del TTL del JWT-SVID" {
  run render spiffe
  [ "$status" -eq 0 ]
  local ap ttl; ap=$(doc "$output" AuthPolicy)
  ttl=$(echo "$ap" | yq '.spec.rules.metadata.vault_mint.cache.ttl')
  [ "$ttl" -lt 300 ]
}

@test "spiffe manda el token en x-np-token, SIN prefijo Bearer" {
  run render spiffe
  [ "$status" -eq 0 ]
  local ap; ap=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap" | yq '.spec.rules.response.success.headers.x-np-token.plain.expression')" = \
    "auth.metadata.vault_mint.data.token" ]
  [[ "$ap" != *"Bearer"* ]]
}

@test "spiffe no deja pasar el request si Vault no devolvió token" {
  run render spiffe
  [ "$status" -eq 0 ]
  local ap; ap=$(doc "$output" AuthPolicy)
  [[ "$(echo "$ap" | yq '.spec.rules.authorization.vault_mint_check.patternMatching.patterns[0].predicate')" \
     == *"has(auth.metadata.vault_mint.data.token)"* ]]
}

@test "spiffe lee el token de Vault de un Secret, no de un literal" {
  run render spiffe
  [ "$status" -eq 0 ]
  local ap; ap=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap" | yq '.spec.rules.metadata.vault_mint.http.sharedSecretRef.name')" = "s2s-vault-token" ]
  [ "$(echo "$ap" | yq '.spec.rules.metadata.vault_mint.http.credentials.customHeader.name')" = "X-Vault-Token" ]
}

@test "spiffe pide como audiencia el ingreso del peer" {
  run render spiffe
  [ "$status" -eq 0 ]
  local ap; ap=$(doc "$output" AuthPolicy)
  [[ "$(echo "$ap" | yq '.spec.rules.metadata.vault_mint.http.body.expression')" \
     == *"kuadrant.peer.example.io"* ]]
}

@test "cluster-keys sigue rindiendo el wristband firmado con la clave del namespace" {
  run render cluster-keys
  [ "$status" -eq 0 ]
  local ap; ap=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap" | yq '.spec.rules.response.success.headers.x-np-token.wristband.signingKeyRefs[0].name')" = \
    "payments-wristband-key" ]
  [ "$(echo "$ap" | yq '.spec.rules.response.success.headers.x-np-token.wristband.customClaims.ns.value')" = \
    "payments" ]
}

@test "cluster-keys no habla con Vault en ningún lado" {
  run render cluster-keys
  [ "$status" -eq 0 ]
  [[ "$output" != *"vault"* ]]
  [[ "$output" != *"Vault"* ]]
}

@test "las dos estrategias cuelgan la AuthPolicy del mismo Gateway" {
  run render spiffe
  local ap_spiffe; ap_spiffe=$(doc "$output" AuthPolicy)
  run render cluster-keys
  local ap_keys; ap_keys=$(doc "$output" AuthPolicy)
  [ "$(echo "$ap_spiffe" | yq '.spec.targetRef.kind')" = "Gateway" ]
  [ "$(echo "$ap_spiffe" | yq '.spec.targetRef.name')" = \
    "$(echo "$ap_keys" | yq '.spec.targetRef.name')" ]
}

@test "las dos estrategias emiten el mismo nombre de header" {
  run render spiffe
  [[ "$(doc "$output" AuthPolicy)" == *"x-np-token"* ]]
  run render cluster-keys
  [[ "$(doc "$output" AuthPolicy)" == *"x-np-token"* ]]
}

@test "las dos estrategias llevan la label de managed" {
  run render spiffe
  [ "$status" -eq 0 ]
  [ "$(doc "$output" AuthPolicy | yq '.metadata.labels."egress-interceptor/managed"')" = "true" ]
}

@test "la AuthPolicy de la estrategia se aplica en su orden numérico, no al final" {
  run rendered_files spiffe
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -n '20-authpolicy.yaml' | cut -d: -f1)" -lt \
    "$(echo "$output" | grep -n '50-httproute-egress.yaml' | cut -d: -f1)" ]
  [ "$(echo "$output" | grep -n '10-gateway.yaml' | cut -d: -f1)" -lt \
    "$(echo "$output" | grep -n '20-authpolicy.yaml' | cut -d: -f1)" ]
}

@test "cada estrategia rinde UNA sola AuthPolicy" {
  run render spiffe
  [ "$(echo "$output" | yq -N '.kind' | grep -cx AuthPolicy)" -eq 1 ]
  run render cluster-keys
  [ "$(echo "$output" | yq -N '.kind' | grep -cx AuthPolicy)" -eq 1 ]
}

@test "una estrategia sin directorio de manifiestos ABORTA en vez de aplicar el resto" {
  render_ctx spiffe
  run bash -c "
    source '${BATS_TEST_DIRNAME}/../logging'
    source '${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib'
    render_all_manifests '$BATS_TEST_TMPDIR/render-ctx.json' '$BATS_TEST_TMPDIR/out3' inexistente"
  [ "$status" -eq 1 ]
  [[ "$output" == *"inexistente"* ]]
}

@test "un peer_gateway_host con comillas NO inyecta claves en el body del mint" {
  render_ctx spiffe
  jq '.peer_gateway_host = "ok.example.io\", \"policies\": \"root"' \
    "$BATS_TEST_TMPDIR/render-ctx.json" >"$BATS_TEST_TMPDIR/malicioso.json"
  local out="$BATS_TEST_TMPDIR/out5"
  rm -rf "$out"
  run bash -c "
    source '${BATS_TEST_DIRNAME}/../logging'
    source '${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib'
    render_all_manifests '$BATS_TEST_TMPDIR/malicioso.json' '$out' spiffe >/dev/null
    yq '.spec.rules.metadata.vault_mint.http.body.expression' '$out/20-authpolicy.yaml'"
  [ "$status" -eq 0 ]
  [ "$(printf %s "$output" | python3 -c 'import json,sys; print(len(json.loads(json.loads(sys.stdin.read()))))')" -eq 1 ]
}

@test "un cluster_label con comillas NO rompe la key del cache" {
  render_ctx spiffe
  jq '.cluster_label = "evil\" + auth.identity.sub + \""' \
    "$BATS_TEST_TMPDIR/render-ctx.json" >"$BATS_TEST_TMPDIR/malicioso2.json"
  local out="$BATS_TEST_TMPDIR/out6"
  rm -rf "$out"
  run bash -c "
    source '${BATS_TEST_DIRNAME}/../logging'
    source '${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib'
    render_all_manifests '$BATS_TEST_TMPDIR/malicioso2.json' '$out' spiffe >/dev/null
    yq '.spec.rules.metadata.vault_mint.cache.key.expression' '$out/20-authpolicy.yaml'"
  [ "$status" -eq 0 ]
  [ "$(printf %s "$output" | python3 -c 'import json,sys; v=json.loads(sys.stdin.read()); print(type(v).__name__)')" = "str" ]
}

@test "el X-Vault-Namespace se omite cuando no se configura" {
  render_ctx spiffe
  jq '.vault_namespace = ""' "$BATS_TEST_TMPDIR/render-ctx.json" >"$BATS_TEST_TMPDIR/sin-ns.json"
  local out="$BATS_TEST_TMPDIR/out4"
  rm -rf "$out"
  run bash -c "
    source '${BATS_TEST_DIRNAME}/../logging'
    source '${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib'
    render_all_manifests '$BATS_TEST_TMPDIR/sin-ns.json' '$out' spiffe >/dev/null
    cat '$out/20-authpolicy.yaml'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"X-Vault-Namespace"* ]]
}
