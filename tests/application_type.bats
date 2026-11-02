#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../shared/scripts/application_type"
  unset APPLICATION_TYPES_WITH_NO_AUTH_POLICY
}

app_context() {
  jq -nc --arg type "$1" '{application:{id:1,metadata:{scaffolding:{application_type:$type}}}}'
}

@test "el tipo sale de la metadata de scaffolding de la aplicación" {
  run resolve_application_type "$(app_context API)"
  [ "$status" -eq 0 ]
  [ "$output" = "API" ]
}

@test "una aplicación sin metadata no tiene tipo" {
  run resolve_application_type '{"application":{"id":1}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "un contexto vacío no tiene tipo" {
  run resolve_application_type ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "un application_type que no es string no cuenta como tipo" {
  run resolve_application_type '{"application":{"metadata":{"scaffolding":{"application_type":["BFF"]}}}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "por default BFF y SPA no llevan AuthPolicy" {
  application_type_skips_auth_policy BFF
  application_type_skips_auth_policy SPA
}

@test "por default API lleva AuthPolicy" {
  run application_type_skips_auth_policy API
  [ "$status" -eq 1 ]
}

@test "sin tipo lleva AuthPolicy" {
  run application_type_skips_auth_policy ""
  [ "$status" -eq 1 ]
}

@test "la lista configurada reemplaza al default" {
  export APPLICATION_TYPES_WITH_NO_AUTH_POLICY="API"
  application_type_skips_auth_policy API
  run application_type_skips_auth_policy BFF
  [ "$status" -eq 1 ]
}

@test "la lista vacía hace que todos los tipos lleven AuthPolicy" {
  export APPLICATION_TYPES_WITH_NO_AUTH_POLICY=""
  run application_type_skips_auth_policy BFF
  [ "$status" -eq 1 ]
}

@test "la comparación ignora mayúsculas y espacios alrededor de cada tipo" {
  export APPLICATION_TYPES_WITH_NO_AUTH_POLICY=" bff , Worker "
  application_type_skips_auth_policy BFF
  application_type_skips_auth_policy worker
}

@test "un tipo que sólo contiene a uno de la lista no matchea" {
  run application_type_skips_auth_policy BFFX
  [ "$status" -eq 1 ]
}
