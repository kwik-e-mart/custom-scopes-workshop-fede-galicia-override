#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  source "${BATS_TEST_DIRNAME}/../shared/scripts/sigla"
  STEP="${BATS_TEST_DIRNAME}/../override/deployment/scripts/add_sigla_label"
}

@test "la sigla es el slug del namespace hasta el primer guion, en mayúsculas" {
  run resolve_sigla '{"namespace":{"slug":"ayrm-menuatenciondig"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "AYRM" ]
}

@test "un slug sin guion se usa entero" {
  run resolve_sigla '{"namespace":{"slug":"payments"}}'
  [ "$output" = "PAYMENTS" ]
}

@test "sin namespace.slug cae a tags.namespace" {
  run resolve_sigla '{"namespace":{},"tags":{"namespace":"bkpr-cuentas"}}'
  [ "$output" = "BKPR" ]
}

@test "un namespace.slug vacío también cae a tags.namespace" {
  run resolve_sigla '{"namespace":{"slug":""},"tags":{"namespace":"bkpr-cuentas"}}'
  [ "$output" = "BKPR" ]
}

@test "namespace.slug gana sobre tags.namespace" {
  run resolve_sigla '{"namespace":{"slug":"ayrm-menu"},"tags":{"namespace":"bkpr-cuentas"}}'
  [ "$output" = "AYRM" ]
}

@test "sin ninguna fuente no devuelve nada y avisa por stderr" {
  run --separate-stderr resolve_sigla '{"tags":[]}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"neither namespace.slug nor tags.namespace"* ]]
}

@test "un valor que no es label válido no se usa" {
  run --separate-stderr resolve_sigla '{"namespace":{"slug":"-menu"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not a valid Kubernetes label value"* ]]
}

@test "el step crea k8s_modifiers.global.labels cuando no existe" {
  export CONTEXT='{"namespace":{"slug":"ayrm-menuatenciondig"}}'
  run bash -c 'source "$1" >/dev/null; echo "$CONTEXT"' _ "$STEP"
  [ "$status" -eq 0 ]
  [ "$(jq -c .k8s_modifiers <<< "$output")" = '{"global":{"labels":{"sigla":"AYRM"}}}' ]
}

@test "el step conserva los modifiers que ya venían" {
  export CONTEXT='{"namespace":{"slug":"ayrm-x"},"k8s_modifiers":{"global":{"labels":{"team":"core"},"annotations":{"a":"b"}},"deployment":{"tolerations":[]}}}'
  run bash -c 'source "$1" >/dev/null; echo "$CONTEXT"' _ "$STEP"
  [ "$status" -eq 0 ]
  [ "$(jq -c .k8s_modifiers <<< "$output")" = '{"global":{"labels":{"team":"core","sigla":"AYRM"},"annotations":{"a":"b"}},"deployment":{"tolerations":[]}}' ]
}

@test "el step reemplaza un k8s_modifiers null" {
  export CONTEXT='{"namespace":{"slug":"ayrm-x"},"k8s_modifiers":null}'
  run bash -c 'source "$1" >/dev/null; echo "$CONTEXT"' _ "$STEP"
  [ "$(jq -c .k8s_modifiers <<< "$output")" = '{"global":{"labels":{"sigla":"AYRM"}}}' ]
}

@test "sin sigla el step deja el CONTEXT igual y el workflow sigue" {
  export CONTEXT='{"k8s_modifiers":{"deployment":{}}}'
  run bash -c 'source "$1" 2>/dev/null; echo "$CONTEXT"; echo NEXT_STEP_RAN' _ "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]] || false
  [ "$(head -1 <<< "$output" | jq -c .)" = '{"k8s_modifiers":{"deployment":{}}}' ]
}
