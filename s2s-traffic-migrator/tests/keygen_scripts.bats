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
    vault_secret_store:"vault-ocp", local_jwks_url:""
  }' >"$BATS_TEST_TMPDIR/ctx.json"
  gomplate -c .="$BATS_TEST_TMPDIR/ctx.json" \
    -f "$SVC/manifests/signing/cluster-keys/15-keygen-rbac.yaml.tpl" \
    -o "$BATS_TEST_TMPDIR/keygen.yaml"
  local k
  for k in init.sh rotate.sh build-jwks.py; do
    yq -N "select(.kind == \"ConfigMap\") | .data.\"$k\"" "$BATS_TEST_TMPDIR/keygen.yaml" >"$SCRIPTS_DIR/$k"
  done

  export VAULT_KV="$BATS_TEST_TMPDIR/kv"
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

  cat >"$BATS_TEST_TMPDIR/bin/vault" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VAULT_CALLS"
if [ "$1" = "write" ]; then echo "s.token-falso"; exit 0; fi
[ "$1" = "kv" ] || exit 0
op="$2"; shift 2
path=""; field=""
for a in "$@"; do
  case "$a" in
    -field=*) field="${a#-field=}" ;;
    kv/*)     path="${a#kv/}" ;;
  esac
done
case "$op" in
  put)
    mkdir -p "$VAULT_KV/$path"
    for a in "$@"; do
      case "$a" in
        kv/*|-*) continue ;;
      esac
      k="${a%%=*}"; v="${a#*=}"
      if [ "${v:0:1}" = "@" ]; then
        cp "${v:1}" "$VAULT_KV/$path/$k"
        printf '%s\t%s\t%s\n' "$path" "$k" "$(tr -d '\n' <"${v:1}")" >>"$VAULT_PUT_HISTORY"
      else
        printf '%s' "$v" >"$VAULT_KV/$path/$k"
        printf '%s\t%s\t%s\n' "$path" "$k" "$v" >>"$VAULT_PUT_HISTORY"
      fi
    done ;;
  get)
    [ -d "$VAULT_KV/$path" ] || exit 1
    if [ -n "$field" ]; then
      [ -f "$VAULT_KV/$path/$field" ] || exit 1
      cat "$VAULT_KV/$path/$field"
    fi ;;
  delete)
    find "$VAULT_KV/$path" -depth -delete 2>/dev/null || true ;;
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

  cat >"$BATS_TEST_TMPDIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
cat "$FAKE_JWKS_SERVED"
MOCK

  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

init() {
  ORIGIN_NS=payments CLUSTER=eks-kuadrant KEYS_NS=kuadrant-system VAULT_ROLE_ID=role-id \
    run bash "$SCRIPTS_DIR/init.sh"
}

rotate() {
  ORIGIN_NS=payments CLUSTER=eks-kuadrant KEYS_NS=kuadrant-system VAULT_ROLE_ID=role-id \
    AUTH_POLICY_NAME=s2s-egress TOKEN_DURATION=0 EXTRA_WAIT="${EXTRA_WAIT:-0}" \
    LOCAL_JWKS_URL="${LOCAL_JWKS_URL:-}" \
    run bash "$SCRIPTS_DIR/rotate.sh"
}

sembrar_gen1() {
  mkdir -p "$VAULT_KV/ocp/eks-kuadrant/payments/signing-key-gen1"
  openssl genrsa -traditional -out "$BATS_TEST_TMPDIR/original.pem" 2048 2>/dev/null
  cp "$BATS_TEST_TMPDIR/original.pem" "$VAULT_KV/ocp/eks-kuadrant/payments/signing-key-gen1/private_key"
}

modulo_original() {
  openssl rsa -in "$BATS_TEST_TMPDIR/original.pem" -pubout 2>/dev/null \
    | openssl rsa -pubin -noout -modulus | sed 's/^Modulus=//'
}

jwks_publicado() { cat "$VAULT_KV/ocp/eks-kuadrant/payments/jwks/jwks"; }

# El JWKS de solape es intermedio: al final de la rotación se republica sólo con la clave nueva.
jwks_de_solape() {
  grep -F 'ocp/eks-kuadrant/payments/jwks	jwks	' "$VAULT_PUT_HISTORY" | head -1 | cut -f3
}

@test "el bootstrap genera la clave en PKCS#1: es lo unico que Authorino parsea" {
  init
  [ "$status" -eq 0 ]
  head -1 "$VAULT_KV/ocp/eks-kuadrant/payments/signing-key-gen1/private_key" \
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
  run grep -c 'kv put' "$VAULT_CALLS"
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
  head -1 "$VAULT_KV/ocp/eks-kuadrant/payments/signing-key-gen2/private_key" \
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
  [ ! -f "$VAULT_KV/ocp/eks-kuadrant/payments/jwks/jwks" ]
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
  run grep -c 'kv delete' "$VAULT_CALLS"
  [ "$output" -eq 0 ]
}

@test "la limpieza de huerfanos arma la ruta de Vault con el prefijo gen" {
  sembrar_gen1
  printf 'externalsecret.external-secrets.io/payments-wristband-key-gen9\n' >"$FAKE_EXTERNALSECRETS"
  rotate
  run grep -c 'kv delete kv/ocp/eks-kuadrant/payments/signing-key-gen9' "$VAULT_CALLS"
  [ "$output" -ge 1 ]
}

@test "build-jwks.py rechaza una clave nueva sin su kid" {
  /usr/bin/python3 -c "import cryptography" 2>/dev/null || skip "falta el modulo cryptography"
  run /usr/bin/python3 "$SCRIPTS_DIR/build-jwks.py" --old /dev/null --old-kid k --new /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--new y --new-kid van juntas"* ]]
}
