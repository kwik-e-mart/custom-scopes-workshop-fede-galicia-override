#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  SPEC="${BATS_TEST_DIRNAME}/../specs/service-spec.json.tpl"
  PATTERN=$(jq -r '.attributes.schema.properties.routes.items.properties.path.pattern' "$SPEC")
}

path_matches() {
  [[ "$1" =~ $PATTERN ]]
}

@test "acepta un path plano sin comodin" {
  run path_matches "/api/v1/users"
  [ "$status" -eq 0 ]
}

@test "acepta la raiz" {
  run path_matches "/"
  [ "$status" -eq 0 ]
}

@test "acepta un path con parametros" {
  run path_matches "/items/{id}"
  [ "$status" -eq 0 ]
}

@test "acepta un comodin como ultimo caracter" {
  run path_matches "/files/*"
  [ "$status" -eq 0 ]
}

@test "rechaza un comodin en medio del path" {
  run path_matches "/files/*/edit"
  [ "$status" -ne 0 ]
}

@test "rechaza un comodin pegado a mas texto detras" {
  run path_matches "/a*b"
  [ "$status" -ne 0 ]
}
