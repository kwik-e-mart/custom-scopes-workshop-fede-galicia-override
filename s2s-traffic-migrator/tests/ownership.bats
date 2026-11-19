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
