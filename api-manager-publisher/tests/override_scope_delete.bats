#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  OVERRIDE="${BATS_TEST_DIRNAME}/../override"
  STEP="$OVERRIDE/scope/scripts/require_no_published_api"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  export NP_MOCK_SERVICES='[]'
  export APIM_PUBLISHER_PROVIDER
  APIM_PUBLISHER_PROVIDER=$(yq -r '.configuration.APIM_PUBLISHER_PROVIDER' "$OVERRIDE/values.yaml")
  export CONTEXT
  CONTEXT=$(jq -nc '{scope:{id:5, slug:"eks", nrn:"organization=1:account=2:namespace=3:application=4:scope=5"}}')
  unset NP_MOCK_FAIL

  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "${1-} ${2-}" != "service list" ]; then echo "mock np: comando no esperado: $*" >&2; exit 2; fi
if [ "${NP_MOCK_FAIL:-0}" = "1" ]; then echo "np: unauthorized" >&2; exit 1; fi
jq -nc --argjson services "$NP_MOCK_SERVICES" '{results: $services}'
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"
}

run_step() {
  run bash -c 'set -euo pipefail; source "$1"; echo NEXT_STEP_RAN' _ "$STEP"
}

service() {
  jq -nc --arg name "$1" --arg provider "$2" --arg scope "$3" \
    '{id: "s-1", name: $name, status: "active", selectors: {provider: $provider}, attributes: {scope: $scope}}'
}

@test "el workflow de borrado del scope corre el chequeo despues de armar el contexto" {
  [ "$(yq -o=json -I=0 '.steps[] | select(.name == "require_no_published_api") | pick(["type", "after", "file"])' "$OVERRIDE/scope/workflows/delete.yaml")" = '{"type":"script","after":"build context","file":"$OVERRIDES_PATH/scope/scripts/require_no_published_api"}' ]
}

@test "sin APIs publicadas sobre el scope sigue el workflow" {
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]]
}

@test "con una API publicada sobre el scope frena el borrado pidiendo despublicarla" {
  NP_MOCK_SERVICES="[$(service "Payments API" "$APIM_PUBLISHER_PROVIDER" eks)]"
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]] || false
  [[ "$output" == *"eks"*"Payments API"* ]] || false
  [[ "$output" == *"despublicar"* ]]
}

@test "busca los services de la aplicacion del scope sin los archivados" {
  run_step
  [ "$(jq -c 'select(.[0:2] == ["service","list"]) | [.[2:][]] | (index("--nrn") as $i | .[$i + 1]), (index("--status:ne") as $i | .[$i + 1]), (index("--all") != null)' "$NP_CALLS_LOG" | paste -sd, -)" = '"organization=1:account=2:namespace=3:application=4","archived",true' ]
}

@test "una API publicada sobre otro scope no frena el borrado" {
  NP_MOCK_SERVICES="[$(service "Payments API" "$APIM_PUBLISHER_PROVIDER" otro)]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]]
}

@test "un service de otro provider con el mismo scope no frena el borrado" {
  NP_MOCK_SERVICES="[$(service "Postgres" "AWS" eks)]"
  run_step
  [ "$status" -eq 0 ]
  [[ "$output" == *NEXT_STEP_RAN* ]]
}

@test "si no puede listar los services frena el borrado" {
  export NP_MOCK_FAIL=1
  run_step
  [ "$status" -ne 0 ]
  [[ "$output" != *NEXT_STEP_RAN* ]]
}
