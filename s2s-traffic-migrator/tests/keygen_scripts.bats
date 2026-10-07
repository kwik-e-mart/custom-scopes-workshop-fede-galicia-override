#!/usr/bin/env bats
# Los scripts del keygen viven dentro de un ConfigMap, así que acá se rendea el manifiesto, se
# extraen y se CORREN contra mocks de vault y kubectl. openssl es el real: el formato de la clave
# es justamente lo que hay que verificar.

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "bats necesita bash >= 4" >&2; return 1; }
  command -v gomplate >/dev/null || { echo "bats necesita gomplate" >&2; return 1; }
  command -v yq >/dev/null || { echo "bats necesita yq" >&2; return 1; }

  SVC="${BATS_TEST_DIRNAME}/.."
  export SCRIPTS_DIR="$BATS_TEST_TMPDIR/scripts"
  export WORK_DIR="$BATS_TEST_TMPDIR/work"
  mkdir -p "$SCRIPTS_DIR" "$WORK_DIR" "$BATS_TEST_TMPDIR/bin"

  jq -n '{
    namespace:"payments", gateway_name:"s2s-egress", cluster_label:"eks-kuadrant",
    keys_namespace:"kuadrant-system", keygen_image:"alpine/k8s:1.30.3",
    vault_addr:"https://vault.example:8200", vault_namespace:"admin/ocp",
    vault_approle_role_id:"role-id", vault_approle_secret:"vault-approle-creds",
    vault_secret_store:"vault-ocp", local_jwks_url:"", vault_kv_mount:"kv/eks", vault_kv_cluster:"gal-poc"
  }' >"$BATS_TEST_TMPDIR/ctx.json"
  gomplate -c .="$BATS_TEST_TMPDIR/ctx.json" \
    -f "$SVC/manifests/signing/cluster-keys/15-keygen-rbac.yaml.tpl" \
    -o "$BATS_TEST_TMPDIR/keygen.yaml"
  local k
  for k in vault-lib.sh init.sh rotate.sh build-jwks.py; do
    yq -N "select(.kind == \"ConfigMap\") | .data.\"$k\"" "$BATS_TEST_TMPDIR/keygen.yaml" >"$SCRIPTS_DIR/$k"
  done

  export VAULT_KV="$BATS_TEST_TMPDIR/kv"
  export VAULT_ADDR="https://vault.example:8200"
  export KV_VERSION=2
  export JWKS_URL="http://jwks.example:8080/payments/jwks.json"
  export VAULT_CALLS="$BATS_TEST_TMPDIR/vault-calls.log"
  export VAULT_PUT_HISTORY="$BATS_TEST_TMPDIR/vault-puts.log"
  export KUBECTL_CALLS="$BATS_TEST_TMPDIR/kubectl-calls.log"
  export APPLIED_YAML="$BATS_TEST_TMPDIR/applied.yaml"
  export FAKE_CURRENT_KEY="$BATS_TEST_TMPDIR/current-key"
  export FAKE_EXTERNALSECRETS="$BATS_TEST_TMPDIR/externalsecrets"
  export FAKE_KEY_SECRETS="$BATS_TEST_TMPDIR/key-secrets"
  export FAKE_JWKS_SERVED="$BATS_TEST_TMPDIR/jwks-served"
  mkdir -p "$VAULT_KV"
  : >"$VAULT_CALLS"; : >"$VAULT_PUT_HISTORY"; : >"$KUBECTL_CALLS"; : >"$APPLIED_YAML"
  : >"$FAKE_EXTERNALSECRETS"; : >"$FAKE_KEY_SECRETS"; : >"$FAKE_JWKS_SERVED"
  printf 'payments-wristband-key-gen1' >"$FAKE_CURRENT_KEY"

  export VAULT_SECRET_ID_FILE="$BATS_TEST_TMPDIR/secret-id"
  printf 'un-secret-id' >"$VAULT_SECRET_ID_FILE"

  cat >"$BATS_TEST_TMPDIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
# Modela la HTTP API de Vault sobre un KV en disco. El cuerpo de error se imprime igual que con
# --fail-with-body, y un 404 sale con 22 como el curl real.
metodo=GET; cuerpo=""; url=""; salida=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) metodo="$2"; shift 2 ;;
    --data-binary) cuerpo="$2"; shift 2 ;;
    -o) salida="$2"; shift 2 ;;
    -H|-w) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
# El vault_curl real escribe el cuerpo al archivo de -o e imprime SOLO el codigo HTTP.
emitir() {  # <codigo> [cuerpo]
  if [ -n "$salida" ]; then printf '%s' "${2:-}" >"$salida"; else printf '%s' "${2:-}"; fi
  [ -n "$salida" ] && printf '%s' "$1"
  exit 0
}
printf '%s %s\n' "$metodo" "$url" >>"$VAULT_CALLS"

case "$url" in
  "$JWKS_URL") cat "$FAKE_JWKS_SERVED"; exit 0 ;;
esac

ruta="${url#*/v1/}"
MOUNT="${VAULT_KV_MOUNT:-kv}"
case "$ruta" in
  auth/approle/login)
    emitir 200 '{"auth":{"client_token":"s.token-falso"}}' ;;
  sys/internal/ui/mounts/*)
    emitir 200 "$(printf '{"data":{"options":{"version":"%s"}}}' "${KV_VERSION:-2}")" ;;
esac

if [ "${KV_VERSION:-2}" = "2" ]; then
  interna="${ruta#$MOUNT/data/}"
  meta="${ruta#$MOUNT/metadata/}"
else
  interna="${ruta#$MOUNT/}"
  meta="$interna"
fi

case "$metodo" in
  GET)
    if [ ! -d "$VAULT_KV/$interna" ]; then
      emitir 404 '{"errors":[]}'
    fi
    datos=$(for f in "$VAULT_KV/$interna"/*; do
              [ -f "$f" ] || continue
              jq -nc --arg k "$(basename "$f")" --rawfile v "$f" '{($k): $v}'
            done | jq -sc 'add // {}')
    if [ "${KV_VERSION:-2}" = "2" ]; then
      emitir 200 "$(jq -nc --argjson d "$datos" '{data:{data:$d}}')"
    else
      emitir 200 "$(jq -nc --argjson d "$datos" '{data:$d}')"
    fi ;;
  POST)
    mkdir -p "$VAULT_KV/$interna"
    if [ "${KV_VERSION:-2}" = "2" ]; then datos=$(printf '%s' "$cuerpo" | jq -c '.data'); else datos="$cuerpo"; fi
    printf '%s\t%s\n' "$interna" "$(printf '%s' "$datos" | jq -c .)" >>"$VAULT_PUT_HISTORY"
    for k in $(printf '%s' "$datos" | jq -r 'keys[]'); do
      printf '%s' "$datos" | jq -r --arg k "$k" '.[$k]' >"$VAULT_KV/$interna/$k"
    done
    emitir 200 '{}' ;;
  DELETE)
    find "$VAULT_KV/$meta" -depth -delete 2>/dev/null || true
    emitir 200 '{}' ;;
esac
exit 0
MOCK

  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
case "$*" in
  *"get authpolicy"*)     cat "$FAKE_CURRENT_KEY" ;;
  *"get externalsecret"*) cat "$FAKE_EXTERNALSECRETS" ;;
  *"get secret"*)         cat "$FAKE_KEY_SECRETS" ;;
  *"apply -f -"*)         cat >>"$APPLIED_YAML" ;;
  *"patch authpolicy"*)   printf '%s' "$*" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | tr -d '\n' >"$FAKE_CURRENT_KEY" ;;
esac
exit 0
MOCK

  cat >"$BATS_TEST_TMPDIR/bin/python3" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  *build-jwks.py) ;;
  *) exec /usr/bin/python3 "$@" ;;
esac
shift
old=""; oldkid=""; new=""; newkid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --old)     old="$2"; shift 2 ;;
    --old-kid) oldkid="$2"; shift 2 ;;
    --new)     new="$2"; shift 2 ;;
    --new-kid) newkid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mod() { openssl rsa -pubin -in "$1" -noout -modulus | sed 's/^Modulus=//'; }
printf '{"keys":[{"kid":"%s","n":"%s"}' "$oldkid" "$(mod "$old")"
if [ -n "$new" ]; then printf ',{"kid":"%s","n":"%s"}' "$newkid" "$(mod "$new")"; fi
printf ']}\n'
MOCK

  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

init() {
  ORIGIN_NS=payments CLUSTER=eks-kuadrant KEYS_NS=kuadrant-system VAULT_ROLE_ID=role-id \
    VAULT_KV_MOUNT=kv/eks VAULT_KV_CLUSTER=gal-poc \
    run bash "$SCRIPTS_DIR/init.sh"
}

rotate() {
  ORIGIN_NS=payments CLUSTER=eks-kuadrant KEYS_NS=kuadrant-system VAULT_ROLE_ID=role-id \
    VAULT_KV_MOUNT=kv/eks VAULT_KV_CLUSTER=gal-poc \
    AUTH_POLICY_NAME=s2s-egress TOKEN_DURATION=0 EXTRA_WAIT="${EXTRA_WAIT:-0}" \
    LOCAL_JWKS_URL="${LOCAL_JWKS_URL:-}" \
    run bash "$SCRIPTS_DIR/rotate.sh"
}

sembrar_gen1() {
  mkdir -p "$VAULT_KV/gal-poc/payments/key-1"
  openssl genrsa -traditional -out "$BATS_TEST_TMPDIR/original.pem" 2048 2>/dev/null
  cp "$BATS_TEST_TMPDIR/original.pem" "$VAULT_KV/gal-poc/payments/key-1/private_key"
}

modulo_original() {
  openssl rsa -in "$BATS_TEST_TMPDIR/original.pem" -pubout 2>/dev/null \
    | openssl rsa -pubin -noout -modulus | sed 's/^Modulus=//'
}

jwks_publicado() { cat "$VAULT_KV/gal-poc/payments/jwks/jwks"; }

# El JWKS de solape es intermedio: al final de la rotación se republica sólo con la clave nueva.
jwks_de_solape() {
  grep -F 'gal-poc/payments/jwks	' "$VAULT_PUT_HISTORY" | head -1 | cut -f2 | jq -r '.jwks'
}

@test "el bootstrap genera la clave en PKCS#1: es lo unico que Authorino parsea" {
  init
  [ "$status" -eq 0 ]
  head -1 "$VAULT_KV/gal-poc/payments/key-1/private_key" \
    | grep -q "BEGIN RSA PRIVATE KEY"
}

@test "el bootstrap crea el ExternalSecret en el namespace de las claves" {
  init
  [ "$(yq -N '.kind' "$APPLIED_YAML")" = "ExternalSecret" ]
  [ "$(yq -N '.metadata.name' "$APPLIED_YAML")" = "payments-wristband-key-gen1" ]
  [ "$(yq -N '.metadata.namespace' "$APPLIED_YAML")" = "kuadrant-system" ]
}

@test "el Secret que materializa lleva los labels con los que lo busca el service" {
  init
  local labels
  labels=$(yq -N '.spec.target.template.metadata.labels' "$APPLIED_YAML")
  [[ "$labels" == *'egress-interceptor/wristband-key: "true"'* ]]
  [[ "$labels" == *'egress-interceptor/origin-namespace: payments'* ]]
  [[ "$labels" == *'egress-interceptor/key-generation: "1"'* ]]
  [[ "$labels" == *'nullplatform: "true"'* ]]
}

@test "si el namespace ya tiene clave, el bootstrap no toca Vault" {
  printf 'secret/payments-wristband-key-gen3\n' >"$FAKE_KEY_SECRETS"
  init
  [ "$status" -eq 0 ]
  run grep -c 'POST' "$VAULT_CALLS"
  [ "$output" -eq 0 ]
}

@test "la rotacion publica en el JWKS la clave vieja REAL, no una recien generada" {
  sembrar_gen1
  rotate
  [ "$status" -eq 0 ]
  local esperado
  esperado=$(modulo_original)
  [ -n "$esperado" ]
  [ "$(jwks_de_solape | jq -r '.keys[] | select(.kid == "payments-wristband-key-gen1") | .n')" = "$esperado" ]
}

@test "el JWKS de solape lleva las dos generaciones, y el final solo la nueva" {
  sembrar_gen1
  rotate
  [ "$(jwks_de_solape | jq -r '.keys | length')" -eq 2 ]
  [ "$(jwks_de_solape | jq -r '[.keys[].kid] | sort | join(",")')" = "payments-wristband-key-gen1,payments-wristband-key-gen2" ]
  [ "$(jwks_publicado | jq -r '[.keys[].kid] | join(",")')" = "payments-wristband-key-gen2" ]
}

@test "la clave nueva tambien sale en PKCS#1" {
  sembrar_gen1
  rotate
  head -1 "$VAULT_KV/gal-poc/payments/key-2/private_key" \
    | grep -q "BEGIN RSA PRIVATE KEY"
}

@test "la rotacion apunta la AuthPolicy a la generacion siguiente" {
  sembrar_gen1
  rotate
  [ "$(cat "$FAKE_CURRENT_KEY")" = "payments-wristband-key-gen2" ]
}

@test "con EXTRA_WAIT=0 la rotacion llega hasta el final" {
  sembrar_gen1
  EXTRA_WAIT=0 rotate
  [ "$status" -eq 0 ]
  [[ "$output" == *"completa"* ]]
}

@test "si no se puede recuperar la clave vieja de Vault, ABORTA sin publicar un JWKS falso" {
  rotate
  [ "$status" -ne 0 ]
  [[ "$output" == *"no se pudo recuperar gen1"* ]]
  [ ! -f "$VAULT_KV/gal-poc/payments/jwks/jwks" ]
}

@test "si la AuthPolicy no declara clave, ABORTA en vez de rotar a gen1" {
  : >"$FAKE_CURRENT_KEY"
  rotate
  [ "$status" -ne 0 ]
  [[ "$output" == *"no declara ninguna clave de firma"* ]]
}

@test "si la clave vigente no sigue el patron de generaciones, ABORTA" {
  printf 'payments-wristband-key' >"$FAKE_CURRENT_KEY"
  rotate
  [ "$status" -ne 0 ]
  [[ "$output" == *"no se rota a ciegas"* ]]
  run grep -c 'DELETE' "$VAULT_CALLS"
  [ "$output" -eq 0 ]
}

@test "la limpieza de huerfanos borra por metadata, en el mount del sustrato" {
  sembrar_gen1
  printf 'externalsecret.external-secrets.io/payments-wristband-key-gen9\n' >"$FAKE_EXTERNALSECRETS"
  rotate
  run grep -c 'DELETE .*/v1/kv/eks/metadata/gal-poc/payments/key-9' "$VAULT_CALLS"
  [ "$output" -ge 1 ]
}

@test "build-jwks.py rechaza una clave nueva sin su kid" {
  /usr/bin/python3 -c "import cryptography" 2>/dev/null || skip "falta el modulo cryptography"
  run /usr/bin/python3 "$SCRIPTS_DIR/build-jwks.py" --old /dev/null --old-kid k --new /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--new y --new-kid van juntas"* ]]
}

@test "con KV v2 las rutas de datos llevan /data" {
  sembrar_gen1
  rotate
  [ "$status" -eq 0 ]
  run grep -c '/v1/kv/eks/data/gal-poc/payments/key-2' "$VAULT_CALLS"
  [ "$output" -ge 1 ]
}

@test "no se consulta sys/internal/ui/mounts: su policy es aparte de la del KV" {
  sembrar_gen1
  rotate
  [ "$status" -eq 0 ]
  run grep -c 'sys/internal/ui/mounts' "$VAULT_CALLS"
  [ "$output" -eq 0 ]
}

@test "el borrado va por metadata y la lectura por data" {
  sembrar_gen1
  printf 'externalsecret.external-secrets.io/payments-wristband-key-gen9\n' >"$FAKE_EXTERNALSECRETS"
  rotate
  run grep -c 'GET .*/v1/kv/eks/data/gal-poc/payments/key-1' "$VAULT_CALLS"
  [ "$output" -ge 1 ]
  run grep -c 'DELETE .*/v1/kv/eks/metadata/' "$VAULT_CALLS"
  [ "$output" -ge 1 ]
}

@test "el login manda role_id y secret_id al endpoint de AppRole" {
  sembrar_gen1
  rotate
  run grep -c 'POST .*/v1/auth/approle/login' "$VAULT_CALLS"
  [ "$output" -ge 1 ]
}

@test "con la clave ya presente el bootstrap termina bien SIN VAULT_ADDR" {
  # La lib se sourcea despues del early exit: si valida al sourcearse, el Job explota en un
  # cluster sin Vault aunque no tenga nada que pedirle.
  printf 'secret/payments-wristband-key-gen1\n' >"$FAKE_KEY_SECRETS"
  VAULT_ADDR="" init
  [ "$status" -eq 0 ]
  [[ "$output" == *"ya tiene clave de firma"* ]]
}

@test "si hay que ir a Vault y falta VAULT_ADDR, el error lo dice" {
  VAULT_ADDR="" init
  [ "$status" -ne 0 ]
  [[ "$output" == *"VAULT_ADDR"* ]]
}
