#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  MANIFESTS="${BATS_TEST_DIRNAME}/../specs/prerequisites/manifests"
  VALIDATOR="$MANIFESTS/45-authpolicy-validator-spiffe.yaml"
  VALIDATOR_KEYS="$MANIFESTS/40-authpolicy-validator.yaml"
}

sustituir_keys() {  # <archivo>
  sed -e 's|__APP_NAMESPACE__|payments|g' \
      -e 's|__LOCAL_JWKS_NAME__|s2s-eks-jwks|g' \
      -e 's|__PEER_JWKS_NAME__|s2s-crc-jwks|g' \
      "$1"
}

sustituir() {  # <archivo>
  sed -e 's|__NETWORKING_VAULT_ADDR__|https://vault.example.io:8200|g' \
      -e 's|__NETWORKING_VAULT_NAMESPACE__|admin/spiffe|g' \
      -e 's|__NETWORKING_VAULT_SPIFFE_MOUNT__|spiffe|g' \
      -e 's|__NETWORKING_VAULT_ISSUER__|https://vault.example.io:8200|g' \
      -e 's|__NETWORKING_VAULT_SPIFFE_SUB__|spiffe://td.example/s2s-egress|g' \
      -e 's|__S2S_INGRESS_AUDIENCE__|kuadrant.peer.example.io|g' \
      "$1"
}

aud_predicate() {
  sustituir "$VALIDATOR" |
    yq '.spec.rules.authorization.emisor-habilitado.patternMatching.patterns[] | select(.predicate | test("aud")) | .predicate'
}

@test "el validador exige la audiencia: Authorino no la chequea solo" {
  local p; p=$(aud_predicate)
  [[ "$p" == *'"kuadrant.peer.example.io" in'* ]]
}

@test "el chequeo de aud acepta string o lista y no rompe si falta el claim" {
  local p; p=$(aud_predicate)
  [[ "$p" == *"has(auth.identity.aud) &&"* ]]
  [[ "$p" == *"type(auth.identity.aud) == string ? [auth.identity.aud] : auth.identity.aud"* ]]
}

@test "el jwksUrl lleva el namespace de Vault en el path" {
  local url
  url=$(sustituir "$VALIDATOR" | yq '.spec.rules.authentication.vault-spiffe.jwt.jwksUrl')
  [ "$url" = "https://vault.example.io:8200/v1/admin/spiffe/spiffe/.well-known/keys" ]
}

@test "el jwksUrl no se arma sólo con el mount: sin el namespace Vault devuelve 404" {
  local linea
  linea=$(grep "jwksUrl:" "$VALIDATOR")
  [[ "$linea" == *"__NETWORKING_VAULT_NAMESPACE__"* ]]
  [[ "$linea" == *"/v1/__NETWORKING_VAULT_NAMESPACE__/__NETWORKING_VAULT_SPIFFE_MOUNT__/"* ]]
}

@test "sustituidos los placeholders, el validador es YAML válido y no queda ninguno suelto" {
  local out="$BATS_TEST_TMPDIR/45.yaml"
  sustituir "$VALIDATOR" >"$out"
  [ -z "$(grep -o '__[A-Z0-9_]*__' "$out")" ]
  [ "$(yq '.kind' "$out")" = "AuthPolicy" ]
  [ "$(yq '.metadata.name' "$out")" = "s2s-validator" ]
  [ "$(yq '.spec.rules.authentication.vault-spiffe.credentials.customHeader.name' "$out")" = "x-np-token" ]
}

@test "el validador crea el mismo objeto que el de cluster-keys, o el service espera uno que no existe" {
  local spiffe keys
  spiffe=$(yq '.metadata.name + "/" + .metadata.namespace' "$VALIDATOR")
  keys=$(yq '.metadata.name + "/" + .metadata.namespace' "$MANIFESTS/40-authpolicy-validator.yaml")
  [ "$spiffe" = "$keys" ]
}

@test "todo placeholder de los manifiestos está documentado en el README" {
  local readme="${BATS_TEST_DIRNAME}/../specs/prerequisites/README.md" p
  for p in $(grep -rho '__[A-Z0-9_]*__' "$MANIFESTS" | sort -u); do
    grep -q -- "$p" "$readme" || { echo "sin documentar: $p"; return 1; }
  done
}

@test "el validador de cluster-keys exige el token en x-np-token, igual que el de spiffe" {
  local out="$BATS_TEST_TMPDIR/40.yaml"
  sustituir_keys "$VALIDATOR_KEYS" >"$out"
  [ "$(yq '.spec.rules.authentication.local-payments.credentials.customHeader.name' "$out")" = "x-np-token" ]
  [ "$(yq '.spec.rules.authentication.peer-payments.credentials.customHeader.name' "$out")" = "x-np-token" ]
}

@test "cada método de autenticación confía en un JWKS distinto: el local y el del peer" {
  local out="$BATS_TEST_TMPDIR/40.yaml" local_url peer_url
  sustituir_keys "$VALIDATOR_KEYS" >"$out"
  local_url=$(yq '.spec.rules.authentication.local-payments.jwt.jwksUrl' "$out")
  peer_url=$(yq '.spec.rules.authentication.peer-payments.jwt.jwksUrl' "$out")
  [ "$local_url" != "$peer_url" ]
  [[ "$local_url" == *"s2s-eks-jwks.kuadrant-system"* ]]
  [[ "$peer_url" == *"s2s-crc-jwks.kuadrant-system"* ]]
}

@test "los dos jwksUrl declaran ttl: sin eso no hay ventana de rotación que razonar" {
  local out="$BATS_TEST_TMPDIR/40.yaml"
  sustituir_keys "$VALIDATOR_KEYS" >"$out"
  [ "$(yq '.spec.rules.authentication.local-payments.jwt.ttl' "$out")" != "null" ]
  [ "$(yq '.spec.rules.authentication.peer-payments.jwt.ttl' "$out")" != "null" ]
}

@test "el validador de cluster-keys distingue token ausente de emisor no habilitado" {
  local out="$BATS_TEST_TMPDIR/40.yaml" sin con
  sustituir_keys "$VALIDATOR_KEYS" >"$out"
  sin=$(yq '.spec.rules.response.unauthenticated.message.value' "$out")
  con=$(yq '.spec.rules.response.unauthorized.message.value' "$out")
  [ -n "$sin" ] && [ "$sin" != "null" ]
  [ -n "$con" ] && [ "$con" != "null" ]
  [ "$sin" != "$con" ]
}

@test "sustituidos los placeholders, el validador de cluster-keys es YAML válido y no queda ninguno suelto" {
  local out="$BATS_TEST_TMPDIR/40.yaml"
  sustituir_keys "$VALIDATOR_KEYS" >"$out"
  [ -z "$(grep -o '__[A-Z0-9_]*__' "$out")" ]
  [ "$(yq '.kind' "$out")" = "AuthPolicy" ]
  [ "$(yq '.metadata.name' "$out")" = "s2s-validator" ]
}
