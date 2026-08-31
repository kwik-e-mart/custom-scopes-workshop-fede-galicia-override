#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  BC="${BATS_TEST_DIRNAME}/../scripts/k8s/build_context"
  source "${BATS_TEST_DIRNAME}/../logging"
  export -f log
  NS_PROVIDER=payments
  APP_ID=142495574
  APP_SLUG=reports
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'

  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  export NP_MOCK_MODE=ok
  export NP_MOCK_SCOPES='[
    {"slug":"dev","domain":"gal-poc-reports-dev-cvbdn.galicia-poc.nullapps.io"},
    {"slug":"prod","domain":"gal-poc-reports-prod-xiist.galicia-poc.nullapps.io"}
  ]'
  export NP_MOCK_APP='{"slug":"reports"}'
  export NP_MOCK_SERVICE='{"entity_nrn":"organization=1:account=1:namespace=5001:application=142495574"}'
  export NP_MOCK_NAMESPACE='{"slug":"payments"}'
  : >"$NP_CALLS_LOG"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NP_CALLS_LOG"
if [ "$NP_MOCK_MODE" = "forbidden" ]; then
  echo '{"error":"request failed with status 403: insufficient permission"}'
  exit 1
fi
SUBCMD="$1 $2"
QUERY=.
while [ $# -gt 0 ]; do
  case "$1" in
    --query) QUERY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$SUBCMD" in
  "scope list")
    printf %s "$NP_MOCK_SCOPES" | jq -c '{results: .}' | jq -c "$QUERY" ;;
  "application read")
    printf %s "$NP_MOCK_APP" | jq -c "$QUERY" ;;
  "service read")
    printf %s "$NP_MOCK_SERVICE" | jq -c "$QUERY" ;;
  "namespace read")
    printf %s "$NP_MOCK_NAMESPACE" | jq -c "$QUERY" ;;
  *)
    echo '{}' ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

ctx() {
  jq -nc --arg ns "$NS_PROVIDER" --argjson app "${APP_ID:-null}" --arg slug "${APP_SLUG:-}" \
    'if $ns == "" then {providers:{}} else {providers:{"container-orchestration":{cluster:{namespace:$ns}}}} end
     + {account:{}, namespace:{},
        application: ( (if $app == null then {} else {id:$app} end)
                     + (if $slug == "" then {} else {slug:$slug} end) )}'
}

run_build_context() {
  bash -c '
    set -euo pipefail
    if ! source "$1"; then
      exit 1
    fi
  ' _ "$BC"
}

notif() {
  jq -nc --argjson a "${1:-$ATTRS}" \
    '{notification:{type:"create", service:{id:"svc-1", attributes:$a}, parameters:{}}}'
}

@test "resuelve el backend de cada ruta desde el dominio del scope" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'gal-poc-reports-prod-xiist.galicia-poc.nullapps.io'
}

@test "falla si el scope no esta entre los activos de la aplicacion" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"inexistente"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "inexistente"
}

@test "falla si el scope existe pero no esta desplegado" {
  export NP_MOCK_SCOPES='[{"slug":"prod","domain":"To be defined"}]'
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "todavía no está desplegado"
}

@test "falla si np devuelve 403 en vez de seguir con cero scopes" {
  export NP_MOCK_MODE=forbidden
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
}

@test "falla si un host no tiene forma de FQDN" {
  ATTRS='{"hosts":["no un host"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
}

@test "arma APP_TARGET como namespace.application" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'APP_TARGET=payments.reports'
}

@test "sin application.slug en el CONTEXT, lo resuelve con np application read" {
  APP_SLUG=""
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'APP_TARGET=payments.reports'
  grep -q -- "application read --id 142495574" "$NP_CALLS_LOG"
}

@test "sin application.slug ni application.id resolubles, aborta listando las keys del CONTEXT" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  CUSTOM_CONTEXT=$(jq -nc '{account:{}, namespace:{}, providers:{}, marker_test_key:"x"}')
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$CUSTOM_CONTEXT" bash "$BC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "marker_test_key"
}

@test "un NP_ACTION_CONTEXT mal formado aborta hablando del contexto, no de dominios" {
  run env NP_ACTION_CONTEXT='{esto no es json' CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "NP_ACTION_CONTEXT"
  ! echo "$output" | grep -q "dominios"
}

@test "sin service.id en la notificacion, aborta: es obligatorio para el nombre de la route" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  NOTIF_SIN_SERVICE_ID=$(jq -nc --argjson a "$ATTRS" \
    '{notification:{type:"create", service:{attributes:$a}, parameters:{}}}')
  run env NP_ACTION_CONTEXT="$NOTIF_SIN_SERVICE_ID" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "service.id"
}

@test "falla si BACKEND_PORT no es un puerto valido" {
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env BACKEND_PORT=70000 NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "backend port"
}

@test "el APP_TARGET sale del namespace de nullplatform del service, no del namespace de Kubernetes" {
  NS_PROVIDER="k8s-namespace-distinto"
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  run env NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'APP_TARGET=payments.reports'
  ! echo "$output" | grep -q 'k8s-namespace-distinto'
}

@test "aborta si no se puede resolver el target del service en vez de seguir con uno adivinado" {
  export NP_MOCK_SERVICE='{"entity_nrn":"organization=1:account=1:application=142495574"}'
  ATTRS='{"hosts":["api.expuesta.com"],"routes":[{"path":"/r1","methods":["GET"],"scope":"prod"}]}'
  export NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)"
  run run_build_context
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no se pudo resolver el target"
}

@test "en delete tambien resuelve el target por el service y aborta si eso falla" {
  export NP_MOCK_SERVICE='{}'
  ATTRS='{"hosts":[],"routes":[]}'
  export ARGS=delete NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)"
  run run_build_context
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no se pudo resolver el target"
}

@test "en delete no valida hosts, rutas ni scopes: alcanza con namespace, app_target y service_id" {
  export NP_MOCK_SCOPES='[]'
  ATTRS='{"hosts":[],"routes":[]}'
  run env ARGS=delete NP_ACTION_CONTEXT="$(notif)" CONTEXT="$(ctx)" bash "$BC"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'APP_TARGET=payments.reports'
}
