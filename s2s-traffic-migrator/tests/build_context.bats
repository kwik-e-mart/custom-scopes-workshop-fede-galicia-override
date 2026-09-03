#!/usr/bin/env bats
# build_context lee de DOS fuentes distintas y no son intercambiables:
#   $CONTEXT            lo arma el CLI con --build-context: account, application, namespace, providers
#   $NP_ACTION_CONTEXT  la notificación cruda: .notification.service y .notification.parameters
#
# El mock de `np` modela lo verificado contra el CLI real (v2.8.0): aplica el filtro de --query a la
# respuesta, y ante un 403 sale con status 1 escribiendo el error en STDOUT, no en stderr.

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
  ATTRS='{"cluster":"crc","interceptions":[{"service_name":"reports","scope":"prod","percent":100}]}'
  PARAMS='{"cluster":"crc","interceptions":[{"service_name":"reports","scope":"dev","percent":50}]}'

  # Configuración del workflow, no del form: la dirección del ingreso del sustrato opuesto.
  export PEER_GATEWAY_HOST=kuadrant.peer.example.io

  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  export NP_MOCK_MODE=ok
  export NP_MOCK_SCOPES='[
    {"slug":"dev","domain":"gal-poc-reports-dev-cvbdn.galicia-poc.nullapps.io"},
    {"slug":"prod","domain":"gal-poc-reports-prod-xiist.galicia-poc.nullapps.io"}
  ]'
  : >"$NP_CALLS_LOG"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NP_CALLS_LOG"
if [ "$NP_MOCK_MODE" = "forbidden" ]; then
  echo '{"error":"request failed with status 403: insufficient permission"}'
  exit 1
fi
QUERY=.
while [ $# -gt 0 ]; do
  case "$1" in
    --query) QUERY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf %s "$NP_MOCK_SCOPES" | jq -c '{results: .}' | jq -c "$QUERY"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

ctx() {
  jq -nc --arg ns "$NS_PROVIDER" --argjson app "${APP_ID:-null}" \
    'if $ns == "" then {providers:{}} else {providers:{"container-orchestration":{cluster:{namespace:$ns}}}} end
     + {account:{}, namespace:{}, application: (if $app == null then {} else {id:$app} end)}'
}

notif() {  # <type> <attrs> <params>
  jq -nc --arg t "${1:-create}" --argjson a "${2:-$ATTRS}" --argjson p "${3:-$PARAMS}" \
    '{notification:{type:$t, service:{id:"svc-1", attributes:$a, dimensions:{site:"openshift-crc"}}, parameters:$p}}'
}

run_bc() { CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif "$@")" run bash "$BC"; }

run_bc_site() {  # <json de dimensions, o "" para omitirlas>
  local dims="$1" n
  if [ -z "$dims" ]; then
    n=$(jq -nc --argjson a "$ATTRS" '{notification:{type:"create", service:{id:"svc-1", attributes:$a}, parameters:{}}}')
  else
    n=$(jq -nc --argjson a "$ATTRS" --argjson d "$dims" '{notification:{type:"create", service:{id:"svc-1", attributes:$a, dimensions:$d}, parameters:{}}}')
  fi
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$n" run bash "$BC"
}

interceptions() { echo "$1" | grep '^INTERCEPTIONS_JSON=' | sed 's/^INTERCEPTIONS_JSON=//'; }

@test "el namespace sale del provider container-orchestration, no de un atributo" {
  # Es el namespace del servicio DESTINO: la instancia se cuelga de la app dueña del servicio.
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" == *"ns=payments"* ]]
}

@test "el namespace NO se busca en la notificación" {
  # Son dos fuentes distintas: si se confundieran, el reconcile tocaría el namespace equivocado.
  NS_PROVIDER=""
  CONTEXT="$(ctx)" \
  NP_ACTION_CONTEXT="$(jq -nc --argjson a "$ATTRS" '{notification:{type:"create",service:{id:"s",attributes:($a+{namespace:"desde-la-notificacion"}),dimensions:{site:"openshift-crc"}},parameters:{}}}')" \
    run bash "$BC"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ns=desde-la-notificacion"* ]]
  [[ "$output" == *"ns=nullplatform"* ]]
}

@test "sin provider, cae al default nullplatform" {
  NS_PROVIDER=""
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" == *"ns=nullplatform"* ]]
}

@test "NAMESPACE_OVERRIDE gana sobre el provider" {
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" NAMESPACE_OVERRIDE=forzado run bash "$BC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ns=forzado"* ]]
}

@test "la regla del namespace es la MISMA para todas las acciones" {
  # Un delete que se saltee la resolución no sabe dónde borrar.
  for t in create update delete; do
    run_bc "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ns=payments"* ]]
  done
}

@test "RECHAZA un namespace inválido aunque venga del provider" {
  NS_PROVIDER="pay; rm -rf /"
  run_bc
  [ "$status" -ne 0 ]
}

@test "las interceptions salen de la notificación, no del CONTEXT del CLI" {
  run_bc
  [ "$status" -eq 0 ]
  [ "$(interceptions "$output" | jq -r 'length')" -eq 1 ]
}

@test "los parameters de la acción PISAN a los attributes guardados" {
  # Es lo que permite que un update sea una sola llamada, sin un `np service patch` previo.
  run_bc update
  [ "$status" -eq 0 ]
  local i; i=$(interceptions "$output")
  [ "$(echo "$i" | jq -r '.[0].scope')" = "dev" ]
  [ "$(echo "$i" | jq -r '.[0].percent')" -eq 50 ]
}

@test "sin parameters sobreviven los attributes guardados" {
  run_bc update "$ATTRS" '{}'
  [ "$status" -eq 0 ]
  [ "$(interceptions "$output" | jq -r '.[0].scope')" = "prod" ]
}

@test "una notificación sin interceptions no rompe: lista vacía" {
  run_bc create '{"cluster":"crc"}' '{}'
  [ "$status" -eq 0 ]
  [ "$(interceptions "$output")" = "[]" ]
}

@test "sin interceptions NO se llama a np: no hay nada que resolver" {
  run_bc create '{"cluster":"crc"}' '{}'
  [ "$status" -eq 0 ]
  [ ! -s "$NP_CALLS_LOG" ]
}

@test "el atributo cluster no lo lee ningún script: es sólo para el selector del channel" {
  # Va a morir cuando el cluster sea una dimension. Que el código lo ignore es lo que hace que
  # esa migración sea borrar un campo del form y nada más.
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" != *"cluster="* ]]
  run grep -rn "attributes.*cluster\|TARGET_CLUSTER" "${BATS_TEST_DIRNAME}/../scripts/"
  [ "$status" -ne 0 ]
}

@test "el Secret de firma se deriva del namespace: una clave por namespace" {
  # Es el invariante que sostiene la identidad en el ingreso, donde cada clave tiene su propia
  # regla. Un nombre fijo haría que todos los namespaces firmaran con la misma clave.
  run_bc
  [[ "$output" == *"key=payments-wristband-key"* ]]

  NS_PROVIDER=other
  run_bc
  [[ "$output" == *"key=other-wristband-key"* ]]
}

@test "WRISTBAND_SECRET_NAME de la configuración del workflow sustituye {namespace}" {
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" WRISTBAND_SECRET_NAME='{namespace}-firma' run bash "$BC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"key=payments-firma"* ]]
}

@test "la configuración llega por env del workflow, sin values.yaml" {
  [ ! -f "${BATS_TEST_DIRNAME}/../values.yaml" ]
  CONTEXT="$(ctx)" NP_ACTION_CONTEXT="$(notif)" \
    PEER_CA_SECRET=ca-propia LISTEN_PORT=9090 TOKEN_DURATION=60 GATEWAY_CLASS=otra run bash "$BC"
  [ "$status" -eq 0 ]
}

@test "la plataforma sale del site, no del entorno del agente" {
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" == *"site=openshift-crc"* ]]
  [[ "$output" == *"platform=openshift"* ]]
}

@test "un site con prefijo aws- resuelve a la plataforma eks" {
  run_bc_site '{"site":"aws-us-east-1"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"platform=eks"* ]]
}

@test "sin la dimension site ABORTA en vez de asumir una plataforma" {
  run_bc_site ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"no declara la dimension"* ]]
}

@test "un site con prefijo desconocido ABORTA" {
  run_bc_site '{"site":"gcp-europe"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no reconocido"* ]]
}

# ── resolución de scope → FQDN ────────────────────────────────────────────────────────────────

@test "el slug del scope se resuelve al domain y viaja como scope_fqdn" {
  # Es el corazón del cambio: el dev declara una identidad de nullplatform y la plataforma resuelve
  # la dirección. Ningún campo del form contiene un hostname.
  run_bc update
  [ "$status" -eq 0 ]
  [ "$(interceptions "$output" | jq -r '.[0].scope_fqdn')" = "gal-poc-reports-dev-cvbdn.galicia-poc.nullapps.io" ]
}

@test "el slug original CONVIVE con el FQDN resuelto" {
  # El slug es lo que el dev eligió; el FQDN es derivado. Los dos tienen que sobrevivir: sin el slug
  # un update no puede mostrar en el form lo que estaba configurado, y sin el FQDN no hay a dónde
  # rutear. Se asertan juntos para que el test no pase con un objeto al que le falte uno.
  run_bc update
  [ "$(interceptions "$output" | jq -r '.[0] | [.scope, .scope_fqdn] | @tsv')" \
    = "$(printf 'dev\tgal-poc-reports-dev-cvbdn.galicia-poc.nullapps.io')" ]
}

@test "la resolución consulta los scopes de la aplicación del CONTEXT, sólo los activos" {
  run_bc
  [ "$status" -eq 0 ]
  grep -q -- "--application-id 142495574" "$NP_CALLS_LOG"
  grep -q -- "--status active" "$NP_CALLS_LOG"
  grep -q -- "scope list" "$NP_CALLS_LOG"
}

@test "una sola llamada a np aunque haya varias reglas con el mismo scope" {
  run_bc create "$ATTRS" '{"interceptions":[
    {"service_name":"reports","scope":"dev","percent":10},
    {"service_name":"ledger","scope":"dev","percent":90}]}'
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$NP_CALLS_LOG")" -eq 1 ]
  [ "$(interceptions "$output" | jq -r '[.[].scope_fqdn] | unique | length')" -eq 1 ]
}

@test "un scope que no existe ABORTA y dice cuáles hay" {
  run_bc create "$ATTRS" '{"interceptions":[{"service_name":"reports","scope":"qa","percent":50}]}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"qa"* ]]
  [[ "$output" == *"dev, prod"* ]]
}

@test "un scope creado pero SIN desplegar aborta en vez de rendir un hostname inválido" {
  # 'To be defined' es un string, no null: pasa cualquier chequeo de vacío.
  export NP_MOCK_SCOPES='[{"slug":"dev","domain":"To be defined"}]'
  run_bc update
  [ "$status" -ne 0 ]
  [[ "$output" == *"To be defined"* ]]
}

@test "una regla sin scope aborta antes de llamar a np" {
  run_bc create "$ATTRS" '{"interceptions":[{"service_name":"reports","percent":50}]}'
  [ "$status" -ne 0 ]
  [ ! -s "$NP_CALLS_LOG" ]
}

@test "si np falla, aborta: no sigue con el objeto de error como si fuera la lista" {
  # np escribe el error en stdout y sale con 1. Sin propagar el status, `(.results? // .)` tomaría
  # el objeto {error} como lista y NINGÚN scope resolvería, con el mensaje equivocado.
  export NP_MOCK_MODE=forbidden
  run_bc
  [ "$status" -ne 0 ]
  [[ "$output" != *"no está entre los scopes activos"* ]]
}

@test "RECHAZA un domain con inyección de YAML" {
  # El FQDN se interpola en el HTTPRoute. Viene de la API, pero la API no es una frontera de
  # confianza para YAML.
  export NP_MOCK_SCOPES='[{"slug":"dev","domain":"ok.example.io\n        - name: inyectado"}]'
  run_bc update
  [ "$status" -ne 0 ]
}

svc_name() { interceptions "$1" | jq -r '.[0].service_name'; }

rule() {  # <service_name tal cual lo escribe el dev>
  jq -nc --arg s "$1" '{interceptions:[{service_name:$s, scope:"dev", percent:50}]}'
}

@test "el nombre corto pasa tal cual" {
  run_bc create "$ATTRS" "$(rule reports)"
  [ "$status" -eq 0 ]
  [ "$(svc_name "$output")" = "reports" ]
}

@test "<svc>.<ns> normaliza al nombre corto" {
  run_bc create "$ATTRS" "$(rule reports.payments)"
  [ "$status" -eq 0 ]
  [ "$(svc_name "$output")" = "reports" ]
}

@test "<svc>.<ns>.svc normaliza al nombre corto" {
  run_bc create "$ATTRS" "$(rule reports.payments.svc)"
  [ "$status" -eq 0 ]
  [ "$(svc_name "$output")" = "reports" ]
}

@test "el FQDN completo normaliza al nombre corto" {
  run_bc create "$ATTRS" "$(rule reports.payments.svc.cluster.local)"
  [ "$status" -eq 0 ]
  [ "$(svc_name "$output")" = "reports" ]
}

@test "un FQDN absoluto -con el punto final- también normaliza" {
  run_bc create "$ATTRS" "$(rule reports.payments.svc.cluster.local.)"
  [ "$status" -eq 0 ]
  [ "$(svc_name "$output")" = "reports" ]
}

@test "el DNS es case-insensitive: las mayúsculas normalizan" {
  run_bc create "$ATTRS" "$(rule Reports.Payments.SVC.Cluster.Local)"
  [ "$status" -eq 0 ]
  [ "$(svc_name "$output")" = "reports" ]
}

@test "el nombre corto y el FQDN completo rinden el MISMO contexto de render" {
  run_bc create "$ATTRS" "$(rule reports)"
  [ "$status" -eq 0 ]
  local corto; corto=$(interceptions "$output")
  run_bc create "$ATTRS" "$(rule reports.payments.svc.cluster.local)"
  [ "$status" -eq 0 ]
  [ "$(interceptions "$output")" = "$corto" ]
}

@test "un namespace distinto al del servicio ABORTA y manda a Endpoint Exposer" {
  run_bc create "$ATTRS" "$(rule reports.otro-ns)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"otro-ns"* ]]
  [[ "$output" == *"payments"* ]]
  [[ "${output,,}" == *"intra-namespace"* ]]
  [[ "${output,,}" == *"endpoint exposer"* ]]
}

@test "un typo en cluster.local ABORTA en vez de interceptar un servicio que nadie llama" {
  run_bc create "$ATTRS" "$(rule reports.payments.svc.cluster.locl)"
  [ "$status" -ne 0 ]
}

@test "un host externo al cluster ABORTA" {
  run_bc create "$ATTRS" "$(rule reports.example.com)"
  [ "$status" -ne 0 ]
}

@test "el sufijo tiene que ser 'svc', no cualquier label" {
  run_bc create "$ATTRS" "$(rule reports.payments.pod)"
  [ "$status" -ne 0 ]
}

@test "RECHAZA un service_name con inyección de YAML" {
  run_bc create "$ATTRS" "$(rule 'reports\n  evil: si')"
  [ "$status" -ne 0 ]
}

@test "RECHAZA un service_name que no es un label DNS válido" {
  run_bc create "$ATTRS" "$(rule -reports)"
  [ "$status" -ne 0 ]
}

@test "un punto INICIAL ABORTA: el primer label vacío no es un nombre de servicio" {
  run_bc create "$ATTRS" "$(rule .reports)"
  [ "$status" -ne 0 ]
  [[ "$output" == *".reports"* ]]
}

@test "un nombre mal escrito NO menciona Endpoint Exposer: sería una pista falsa" {
  run_bc create "$ATTRS" "$(rule -reports)"
  [ "$status" -ne 0 ]
  [[ "${output,,}" != *"endpoint exposer"* ]]
}

@test "un newline al final del nombre ABORTA" {
  run_bc create "$ATTRS" "$(rule 'reports
')"
  [ "$status" -ne 0 ]
}

@test "una regla sin service_name ABORTA" {
  run_bc create "$ATTRS" '{"interceptions":[{"scope":"dev","percent":50}]}'
  [ "$status" -ne 0 ]
}

@test "dos grafías del MISMO servicio ABORTAN en vez de pisarse en silencio" {
  run_bc create "$ATTRS" '{"interceptions":[
    {"service_name":"reports","scope":"dev","percent":10},
    {"service_name":"reports.payments.svc.cluster.local","scope":"dev","percent":90}]}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"reports"* ]]
}

@test "dos servicios DISTINTOS siguen conviviendo" {
  run_bc create "$ATTRS" '{"interceptions":[
    {"service_name":"reports.payments","scope":"dev","percent":10},
    {"service_name":"ledger.payments.svc","scope":"dev","percent":90}]}'
  [ "$status" -eq 0 ]
  [ "$(interceptions "$output" | jq -r '[.[].service_name] | join(",")')" = "reports,ledger" ]
}

@test "la traza dice a qué nombre corto normalizó lo que escribió el dev" {
  run_bc create "$ATTRS" "$(rule reports.payments.svc.cluster.local)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reports.payments.svc.cluster.local → service reports"* ]]
}

@test "la traza NO habla de normalización cuando el dev escribió el nombre corto" {
  run_bc create "$ATTRS" "$(rule reports)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"→ service reports"* ]]
}

@test "sin PEER_GATEWAY_HOST aborta antes de llamar a np" {
  # Es la dirección por donde sale todo lo migrado. Sin ella el render emitiría un backendRef y un
  # DestinationRule con host vacío, que Istio acepta y nunca rutea.
  unset PEER_GATEWAY_HOST
  run_bc
  [ "$status" -ne 0 ]
  [[ "$output" == *"PEER_GATEWAY_HOST"* ]]
  [ ! -s "$NP_CALLS_LOG" ]
}

@test "sin interceptions NO se exige PEER_GATEWAY_HOST: no hay a dónde salir" {
  unset PEER_GATEWAY_HOST
  run_bc create '{"cluster":"crc"}' '{}'
  [ "$status" -eq 0 ]
}

@test "RECHAZA un PEER_GATEWAY_HOST con inyección" {
  export PEER_GATEWAY_HOST='ok.example.io" evil: si'
  run_bc
  [ "$status" -ne 0 ]
}

@test "la traza dice a qué FQDN resolvió cada regla" {
  # Sin esto, diagnosticar un ruteo equivocado obliga a leer el HTTPRoute renderizado.
  run_bc update
  [[ "$output" == *"scope dev = gal-poc-reports-dev-cvbdn.galicia-poc.nullapps.io"* ]]
  [[ "$output" == *"50% al otro sustrato"* ]]
}

@test "sin repo gitops configurado no se exige nada más" {
  run_bc
  [ "$status" -eq 0 ]
}

@test "un GITOPS_PATH_PREFIX con .. ABORTA" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  export GITOPS_PATH_PREFIX=../../etc
  run_bc
  [ "$status" -ne 0 ]
}

@test "un GITOPS_PATH_PREFIX absoluto ABORTA" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  export GITOPS_PATH_PREFIX=/etc
  run_bc
  [ "$status" -ne 0 ]
  [[ "$output" == *gitops_path_prefix* ]]
}

@test "la URL del repo NUNCA se imprime" {
  export GITOPS_REPO_URL=https://ghp_secreto123@example.com/o/r.git
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" != *ghp_secreto123* ]]
}

@test "la traza dice a qué path del repo se va a publicar" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" == *"openshift-crc/payments"* ]]
}

@test "un GITOPS_BRANCH con inyección ABORTA" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  export GITOPS_BRANCH='main;whoami'
  run_bc
  [ "$status" -ne 0 ]
  [[ "$output" == *gitops_branch* ]]
}
