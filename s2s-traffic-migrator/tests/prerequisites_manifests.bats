#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  MANIFESTS="${BATS_TEST_DIRNAME}/../specs/prerequisites/manifests"
  VALIDATOR_KEYS="$MANIFESTS/40-authpolicy-validator.yaml"
}

sustituir_keys() {  # <archivo>
  sed -e 's|__APP_NAMESPACE__|payments|g' \
      -e 's|__LOCAL_JWKS_NAME__|s2s-eks-jwks|g' \
      -e 's|__PEER_JWKS_NAME__|s2s-crc-jwks|g' \
      -e 's|__EGRESS_ISSUER__|https://egress.payments.s2s.local|g' \
      "$1"
}

@test "todo placeholder de los manifiestos está documentado en el README" {
  local readme="${BATS_TEST_DIRNAME}/../specs/prerequisites/README.md" p
  for p in $(grep -rho '__[A-Z0-9_]*__' "$MANIFESTS" | sort -u); do
    grep -q -- "$p" "$readme" || { echo "sin documentar: $p"; return 1; }
  done
}

@test "el README no documenta placeholders que ya no existen" {
  local readme="${BATS_TEST_DIRNAME}/../specs/prerequisites/README.md" p
  for p in $(grep -o '__[A-Z0-9_]*__' "$readme" | sort -u); do
    grep -rq -- "$p" "$MANIFESTS" || { echo "documentado y sin usar: $p"; return 1; }
  done
}

@test "el validador de cluster-keys exige el token en x-egress-token" {
  local out="$BATS_TEST_TMPDIR/40.yaml"
  sustituir_keys "$VALIDATOR_KEYS" >"$out"
  [ "$(yq '.spec.rules.authentication.local-payments.credentials.customHeader.name' "$out")" = "x-egress-token" ]
  [ "$(yq '.spec.rules.authentication.peer-payments.credentials.customHeader.name' "$out")" = "x-egress-token" ]
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

@test "el validador de cluster-keys autoriza por claims explícitos, no por el JWKS que validó" {
  local out="$BATS_TEST_TMPDIR/40.yaml" preds
  sustituir_keys "$VALIDATOR_KEYS" >"$out"
  preds=$(yq -o=json -I=0 '[.spec.rules.authorization.claims-esperados.patternMatching.patterns[].predicate]' "$out")
  [[ "$preds" == *'auth.identity.iss == \"https://egress.payments.s2s.local\"'* ]]
  [[ "$preds" == *'auth.identity.src_namespace == \"payments\"'* ]]
  [ "$(yq '.spec.rules.authentication.local-payments.overrides' "$out")" = "null" ]
}

