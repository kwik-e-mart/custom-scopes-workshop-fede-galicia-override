#!/usr/bin/env bats
# El cliente crea una instancia del service por aplicación, así que en un mismo namespace pueden
# convivir varias. Sin un dueño por objeto, el GC de cada instancia toma los objetos de la otra
# por basura de una corrida anterior y los desarma.
#
# Pasó el 2026-11-19 en EKS: la instancia de 'vecino' encontró el Service 'reports' de la otra
# instancia, lo dio por no declarado y murió con "perdió la annotation" — que además es mentira,
# porque un Service que creó el interceptor nunca tuvo selector original que guardar.

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION})." >&2; return 1
  }
  source "${BATS_TEST_DIRNAME}/../logging"
  export -f log

  export NAMESPACE=payments
  export SERVICE_ID=svc-b
  export MANAGED_LABEL="egress-interceptor/managed"
  export ROLE_LABEL="egress-interceptor/role"
  export INSTANCE_KEY="egress-interceptor/instance"
  export ORIGINAL_SELECTOR_ANNOTATION="egress-interceptor/original-selector"
  export GATEWAY_NAME=egress-gw
  export GATEWAY_SELECTOR='{"gateway.networking.k8s.io/gateway-name":"egress-gw"}'

  export KUBECTL_CALLS="$BATS_TEST_TMPDIR/calls.log"
  export FAKE_SVC_JSON="$BATS_TEST_TMPDIR/svc.json"
  export FAKE_OWN_LIST="$BATS_TEST_TMPDIR/own.txt"
  : >"$KUBECTL_CALLS"
  : >"$FAKE_OWN_LIST"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
case "$*" in
  *"get svc -o json"*) cat "$FAKE_SVC_JSON" ;;
  *"get svc -l"*)      cat "$FAKE_OWN_LIST" ;;
esac
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  cargar owned_selector
  cargar intercepted_services
  cargar own_gateway_services
  cargar delete_own_services
  cargar converge_service
  cargar still_hijacked
  cargar revert_service
  cargar original_selector
  cargar current_selector
  cargar set_selector
  die() { log error "$@"; exit 1; }
  export -f die
}

cargar() {  # <nombre de funcion>
  eval "$(awk "/^$1\(\) \{/,/^\}/" "${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile")"
}

# Un namespace con las dos instancias conviviendo: svc-a hijackeó 'reports' y creó 'huerfano-a';
# svc-b (la que corre) hijackeó 'pagos'.
namespace_compartido() {
  cat >"$FAKE_SVC_JSON" <<'JSON'
{"items":[
 {"metadata":{"name":"reports",
   "annotations":{"egress-interceptor/original-selector":"{\"app\":\"reports\"}",
                  "egress-interceptor/instance":"svc-a"}}},
 {"metadata":{"name":"pagos",
   "annotations":{"egress-interceptor/original-selector":"{\"app\":\"pagos\"}",
                  "egress-interceptor/instance":"svc-b"}}},
 {"metadata":{"name":"huerfano-a",
   "labels":{"egress-interceptor/managed":"true","egress-interceptor/role":"gateway-service",
             "egress-interceptor/instance":"svc-a"}}}
]}
JSON
}

@test "intercepted_services sólo devuelve los Services que hijackeó ESTA instancia" {
  namespace_compartido
  run intercepted_services
  [ "$status" -eq 0 ] || false
  [ "$output" = "pagos" ]
}

@test "intercepted_services ignora un Service hijackeado sin dueño" {
  # Sin label de instancia no hay forma de saber de quién es: no se toca.
  cat >"$FAKE_SVC_JSON" <<'JSON'
{"items":[{"metadata":{"name":"viejo",
  "annotations":{"egress-interceptor/original-selector":"{\"app\":\"viejo\"}"}}}]}
JSON
  run intercepted_services
  [ "$status" -eq 0 ] || false
  [ -z "$output" ]
}

@test "own_gateway_services filtra por la label de instancia" {
  run own_gateway_services
  [ "$status" -eq 0 ] || false
  grep -q "egress-interceptor/instance=svc-b" "$KUBECTL_CALLS" || false
}

@test "delete_own_services no borra los Services de otra instancia" {
  run delete_own_services gateway-service
  [ "$status" -eq 0 ] || false
  grep -q "egress-interceptor/instance=svc-b" "$KUBECTL_CALLS" || false
}

cargar_gc() {
  cargar delete_interception_objects
  cargar gc_undeclared
  # Se stubean para mirar el despacho: a quién se revierte y a quién se borra.
  revert_service() { printf 'revert %s\n' "$1" >>"$KUBECTL_CALLS"; }
  delete_interception_objects() { printf 'delete %s\n' "$1" >>"$KUBECTL_CALLS"; }
  export -f revert_service delete_interception_objects
}

@test "un Service que creó el interceptor y ya no se declara se BORRA, no se revierte" {
  # El bug reportado: revert_service sobre un Service propio entra en la rama fatal porque nunca
  # tuvo annotation. Los propios se borran y listo.
  namespace_compartido
  printf 'huerfano-b\n' >"$FAKE_OWN_LIST"
  cat >"$FAKE_SVC_JSON" <<'JSON'
{"items":[]}
JSON
  DECLARED_SERVICES="pagos"
  cargar_gc
  run gc_undeclared
  [ "$status" -eq 0 ] || false
  grep -qx "delete huerfano-b" "$KUBECTL_CALLS" || false
  ! grep -q "revert huerfano-b" "$KUBECTL_CALLS" || false
}

@test "el GC no toca nada de la otra instancia" {
  namespace_compartido
  printf '%s\n' "$(cat "$FAKE_SVC_JSON" | jq -r '.items[] | select(.metadata.labels["egress-interceptor/instance"]=="svc-b" and .metadata.labels["egress-interceptor/role"]) | .metadata.name')" >"$FAKE_OWN_LIST"
  DECLARED_SERVICES="pagos"
  cargar_gc
  run gc_undeclared
  [ "$status" -eq 0 ] || false
  ! grep -q "reports" "$KUBECTL_CALLS" || false
  ! grep -q "huerfano-a" "$KUBECTL_CALLS" || false
}

@test "un Service hijackeado por ESTA instancia que ya no se declara SÍ se revierte" {
  namespace_compartido
  DECLARED_SERVICES="otro"
  cargar_gc
  run gc_undeclared
  [ "$status" -eq 0 ] || false
  grep -qx "revert pagos" "$KUBECTL_CALLS" || false
  grep -qx "delete pagos" "$KUBECTL_CALLS" || false
}

@test "si no se puede listar, el GC FALLA en vez de dar la lista por vacía" {
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
echo 'Error from server (Forbidden)' >&2
exit 1
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  DECLARED_SERVICES="pagos"
  cargar_gc
  run gc_undeclared
  [ "$status" -ne 0 ]
}


kubectl_con_estado() {
  export FAKE_STATE="$BATS_TEST_TMPDIR/state.json"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
args=("$@")
if [ "${args[0]}" = "-n" ]; then args=("${args[@]:2}"); fi
verbo="${args[0]}"
nombre=""
if [ "${#args[@]}" -gt 2 ] && [[ "${args[2]}" != -* ]]; then nombre="${args[2]}"; fi
sobrescribe=0
selector=""
campo=""
salida=""
parche=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --overwrite) sobrescribe=1 ;;
    -l) selector="${args[$((i + 1))]}" ;;
    --field-selector) campo="${args[$((i + 1))]#metadata.name=}" ;;
    -o) salida="${args[$((i + 1))]}" ;;
    -p) parche="${args[$((i + 1))]}" ;;
  esac
done
escribir() { jq -c "$@" "$FAKE_STATE" >"$FAKE_STATE.tmp" && mv "$FAKE_STATE.tmp" "$FAKE_STATE"; }
existe() { jq -e --arg n "$nombre" '.items[] | select(.metadata.name == $n)' "$FAKE_STATE" >/dev/null; }
no_encontrado() { echo "Error from server (NotFound): services \"$nombre\" not found" >&2; exit 1; }
case "$verbo" in
  get)
    if [ -z "$nombre" ]; then cat "$FAKE_STATE"; exit 0; fi
    existe || no_encontrado
    case "$salida" in
      json) jq -c --arg n "$nombre" '.items[] | select(.metadata.name == $n)' "$FAKE_STATE" ;;
      *spec.selector*) jq -c --arg n "$nombre" '.items[] | select(.metadata.name == $n) | .spec.selector // {}' "$FAKE_STATE" ;;
      *original-selector*) jq -r --arg n "$nombre" '.items[] | select(.metadata.name == $n) | (.metadata.annotations // {})["egress-interceptor/original-selector"] // ""' "$FAKE_STATE" ;;
    esac ;;
  label|annotate)
    existe || no_encontrado
    campo_mapa=labels
    [ "$verbo" = annotate ] && campo_mapa=annotations
    for arg in "${args[@]:3}"; do
      case "$arg" in
        --*) ;;
        *-) escribir --arg n "$nombre" --arg m "$campo_mapa" --arg k "${arg%-}" '(.items[] | select(.metadata.name == $n) | .metadata[$m]) |= del(.[$k])' ;;
        *=*)
          clave="${arg%%=*}"
          valor="${arg#*=}"
          previo=$(jq -r --arg n "$nombre" --arg m "$campo_mapa" --arg k "$clave" '.items[] | select(.metadata.name == $n) | .metadata[$m][$k] // empty' "$FAKE_STATE")
          if [ -n "$previo" ] && [ "$previo" != "$valor" ] && [ "$sobrescribe" -eq 0 ]; then
            echo "error: '$clave' already has a value ($previo), and --overwrite is false" >&2
            exit 1
          fi
          escribir --arg n "$nombre" --arg m "$campo_mapa" --arg k "$clave" --arg v "$valor" '(.items[] | select(.metadata.name == $n) | .metadata[$m]) |= ((. // {}) + {($k): $v})' ;;
      esac
    done ;;
  patch)
    existe || no_encontrado
    nuevo=$(printf '%s' "$parche" | jq -c '.[0].value')
    escribir --arg n "$nombre" --argjson v "$nuevo" '(.items[] | select(.metadata.name == $n) | .spec.selector) = $v' ;;
  delete)
    terminos=$(printf '%s' "$selector" | tr ',' '\n' | jq -R . | jq -s .)
    escribir --argjson t "$terminos" --arg nombre "$campo" '
      def coincide: . as $o | all($t[];
        if startswith("!") then (($o.metadata.labels // {})[.[1:]] == null)
        else (split("=") as $p | ($o.metadata.labels // {})[$p[0]] == $p[1]) end);
      .items |= map(select((coincide and ($nombre == "" or .metadata.name == $nombre)) | not))' ;;
esac
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
}

servicio() {  # <nombre> <labels json> <annotations json> <selector json>
  jq -nc --arg n "$1" --argjson l "$2" --argjson a "$3" --argjson s "$4" \
    '{metadata: {name: $n, labels: $l, annotations: $a}, spec: {selector: $s}}'
}

estado() {  # <servicio json>...
  printf '%s\n' "$@" | jq -sc '{items: .}' >"$FAKE_STATE"
}

selector_de() {
  jq -c --arg n "$1" '.items[] | select(.metadata.name == $n) | .spec.selector' "$FAKE_STATE"
}

dueno_de() {
  jq -r --arg n "$1" '.items[] | select(.metadata.name == $n) | ((.metadata.annotations // {})["egress-interceptor/instance"] // (.metadata.labels // {})["egress-interceptor/instance"] // "")' "$FAKE_STATE"
}

existe_servicio() {
  jq -e --arg n "$1" '.items[] | select(.metadata.name == $n)' "$FAKE_STATE" >/dev/null
}

captura_sin_marcar() {
  servicio "$1" '{"egress-interceptor/managed":"true","egress-interceptor/role":"gateway-service"}' '{}' "$GATEWAY_SELECTOR"
}

@test "un Service de captura sin marcar se adopta en el apply y el delete termina limpio" {
  kubectl_con_estado
  estado "$(captura_sin_marcar reports)"
  DECLARED_SERVICES="reports"

  converge_service reports
  [ "$(dueno_de reports)" = "svc-b" ] || false
  [ "$(selector_de reports)" = "$GATEWAY_SELECTOR" ] || false

  delete_own_services gateway-service
  ! existe_servicio reports || false
  [ -z "$(still_hijacked "$(cat "$FAKE_STATE")")" ]
}

@test "delete_own_services borra el declarado sin marca de instancia" {
  kubectl_con_estado
  estado "$(captura_sin_marcar reports)"
  DECLARED_SERVICES="reports"
  delete_own_services gateway-service
  ! existe_servicio reports || false
}

@test "delete_own_services NO borra el declarado con marca de otra instancia" {
  kubectl_con_estado
  estado "$(servicio reports '{"egress-interceptor/managed":"true","egress-interceptor/role":"gateway-service","egress-interceptor/instance":"svc-a"}' '{}' "$GATEWAY_SELECTOR")"
  DECLARED_SERVICES="reports"
  delete_own_services gateway-service
  existe_servicio reports || false
}

@test "un Service hijackeado sin marcar adopta la marca sin re-swapear el selector" {
  kubectl_con_estado
  estado "$(servicio pagos '{}' '{"egress-interceptor/original-selector":"{\"app\":\"pagos\"}"}' '{"app":"otro"}')"
  converge_service pagos
  [ "$(dueno_de pagos)" = "svc-b" ] || false
  [ "$(selector_de pagos)" = '{"app":"otro"}' ]
  ! grep -q "patch" "$KUBECTL_CALLS" || false
}

@test "un Service marcado por otra instancia hace fallar el apply y nombra al dueño" {
  kubectl_con_estado
  estado "$(servicio pagos '{"egress-interceptor/instance":"svc-a"}' '{}' "$GATEWAY_SELECTOR")"
  run converge_service pagos
  [ "$status" -ne 0 ]
  [[ "$output" == *"instancia svc-a"* ]] || false
}

@test "un Service marcado por esta instancia converge el selector y las labels" {
  kubectl_con_estado
  estado "$(servicio reports '{"egress-interceptor/instance":"svc-b","egress-interceptor/role":"gateway-service"}' '{}' '{"app":"viejo"}')"
  converge_service reports
  [ "$(selector_de reports)" = "$GATEWAY_SELECTOR" ] || false
  [ "$(jq -r '.items[0].metadata.labels["egress-interceptor/managed"]' "$FAKE_STATE")" = "true" ]
}

@test "intercepted_services incluye al hijackeado sin dueño que esta instancia declara" {
  kubectl_con_estado
  estado "$(servicio viejo '{}' '{"egress-interceptor/original-selector":"{\"app\":\"viejo\"}"}' "$GATEWAY_SELECTOR")" \
         "$(servicio ajeno '{}' '{"egress-interceptor/original-selector":"{\"app\":\"a\"}"}' "$GATEWAY_SELECTOR")"
  DECLARED_SERVICES="viejo"
  run intercepted_services
  [ "$status" -eq 0 ] || false
  [ "$output" = "viejo" ]
}

@test "still_hijacked no cuenta los Services de captura pero sí los hijackeados" {
  kubectl_con_estado
  estado "$(captura_sin_marcar reports)" \
         "$(servicio pagos '{}' '{"egress-interceptor/original-selector":"{\"app\":\"pagos\"}"}' "$GATEWAY_SELECTOR")"
  [ "$(still_hijacked "$(cat "$FAKE_STATE")")" = "pagos" ]
}
