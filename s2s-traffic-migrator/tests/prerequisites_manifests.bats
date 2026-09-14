#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  MANIFESTS="${BATS_TEST_DIRNAME}/../specs/prerequisites/manifests"
  VALIDATOR="$MANIFESTS/45-authpolicy-validator-spiffe.yaml"
}

sustituir() {  # <archivo>
  sed -e 's|__NETWORKING_VAULT_ADDR__|https://vault.example.io:8200|g' \
      -e 's|__NETWORKING_VAULT_NAMESPACE__|admin/spiffe|g' \
      -e 's|__NETWORKING_VAULT_SPIFFE_MOUNT__|spiffe|g' \
      -e 's|__NETWORKING_VAULT_ISSUER__|https://vault.example.io:8200|g' \
      -e 's|__NETWORKING_VAULT_SPIFFE_SUB__|spiffe://td.example/s2s-egress|g' \
      "$1"
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
