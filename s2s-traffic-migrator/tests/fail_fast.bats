#!/usr/bin/env bats
# El 2026-08-27 el reconcile timeouteó esperando al Gateway, SIGUIÓ de largo, apuntó el Service a
# un Gateway sin pods y terminó con `status 0`. El namespace se salvó de casualidad.
#
# La causa: `set -euo pipefail` está en el script pero el runner de workflows del CLI ejecuta cada
# step en un contexto que NEUTRALIZA errexit — sourcearlo desde un `if !` o un `||` lo desactiva
# para todo el subárbol. Estos tests corren el reconcile en ESE contexto a propósito: si se
# corrieran con errexit activo, pasarían aunque no hubiera una sola guarda.

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "bats necesita bash >= 4" >&2; return 1; }
  command -v gomplate >/dev/null || { echo "bats necesita gomplate" >&2; return 1; }

  export SVC_DIR="${BATS_TEST_DIRNAME}/.."
  export NP_OUTPUT_DIR="$BATS_TEST_TMPDIR/out"; mkdir -p "$NP_OUTPUT_DIR"
  export KUBECTL_CALLS="$BATS_TEST_TMPDIR/calls.log"; : >"$KUBECTL_CALLS"
  export FALLA_WAIT=""        # substring del wait que debe fallar
  # El mock lleva ESTADO: un patch tiene que verse en la lectura siguiente, o la verificación
  # post-swap del reconcile —que relee el selector— daría un falso negativo.
  export FAKE_SELECTOR="$BATS_TEST_TMPDIR/selector"; printf '%s' '{"app":"reports"}' >"$FAKE_SELECTOR"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
if [ -n "${FALLA_WAIT:-}" ] && [[ "$*" == *wait* && "$*" == *"$FALLA_WAIT"* ]]; then
  echo "error: timed out waiting for the condition" >&2
  exit 1
fi
if [ -n "${FALLA_GET_SVC:-}" ] && [[ "$*" == *"get svc"*"-o json"* ]]; then
  echo "error: Unable to connect to the server: dial tcp: i/o timeout" >&2
  exit 1
fi
if [ -n "${SVC_INEXISTENTE:-}" ] && [[ "$*" == *"get svc reports -o json --ignore-not-found"* ]]; then
  exit 0
fi
if [ -n "${SVC_SIN_PUERTOS:-}" ] && [[ "$*" == *"get svc reports -o json --ignore-not-found"* ]]; then
  echo '{"metadata":{"name":"reports","namespace":"payments"},"spec":{"selector":{"app":"reports"},"ports":[]}}'
  exit 0
fi
if [ -n "${ANOTACION_NO_ES_OBJETO:-}" ] && [[ "$*" == *"get svc reports -o json --ignore-not-found"* ]]; then
  echo '{"metadata":{"name":"reports","namespace":"payments","annotations":{"egress-interceptor/original-selector":"[\"app\",\"reports\"]"}},"spec":{"selector":{"app":"reports"},"ports":[{"name":"http","port":8080}]}}'
  exit 0
fi
if [[ " $* " == *" apply "* ]]; then
  ARCHIVO=""
  ANTERIOR=""
  for ARG in "$@"; do
    if [ "$ANTERIOR" = "-f" ]; then ARCHIVO="$ARG"; fi
    ANTERIOR="$ARG"
  done
  if [ -n "$ARCHIVO" ] && [ "$ARCHIVO" != "-" ] && [ ! -f "$ARCHIVO" ]; then
    echo "error: the path \"$ARCHIVO\" does not exist" >&2
    exit 1
  fi
fi
case "$*" in
  *"patch svc"*)
    # Refleja el nuevo selector, igual que el API server.
    sed 's/.*"value"://; s/}]$//' <<<"$*" >"$FAKE_SELECTOR" ;;
  *"get svc reports-local"*) exit 1 ;;                     # el alias todavía no existe
  *"get svc reports -o jsonpath={.spec.selector}"*) cat "$FAKE_SELECTOR" ;;
  *"get svc reports -o jsonpath"*"annotations"*)    : ;;   # todavía sin anotar
  *"get svc reports -o json"*)
    echo '{"metadata":{"name":"reports","namespace":"payments"},"spec":{"selector":{"app":"reports"},"ports":[{"name":"http","port":8080,"targetPort":8080,"protocol":"TCP"}]}}' ;;
  *"get svc -o json"*)   echo '{"items":[]}' ;;
  *"get svc -l"*)        : ;;
  *"get svc reports"*)   : ;;                              # existe
  *"get httproute"*"-o json"*)
    echo '{"status":{"parents":[{"conditions":[{"type":"Accepted","status":"True"},{"type":"ResolvedRefs","status":"True"}]}]}}' ;;
esac
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Corre el reconcile como lo corre el runner: con errexit NEUTRALIZADO.
correr() {
  ARGS=apply \
  NAMESPACE=payments SITE=aws-us-east-1 PLATFORM=eks CLUSTER_LABEL=eks-kuadrant \
  GATEWAY_CLASS=istio LISTEN_PORT=8080 TOKEN_DURATION=300 \
  WRISTBAND_SECRET=payments-wristband-key PEER_CA_SECRET=s2s-remote-ca \
  PEER_GATEWAY_HOST=peer.example LOCAL_INGRESS_HOST=li.example \
  GATEWAY_NAMESPACE=gateways INGRESS_AUTHPOLICY=s2s-validator \
  SIGNING_STRATEGY="${SIGNING_STRATEGY:-spiffe}" \
  NETWORKING_VAULT_ADDR=https://vault.example.io:8200 \
  NETWORKING_VAULT_NAMESPACE=admin/spiffe \
  NETWORKING_VAULT_SPIFFE_MOUNT=spiffe \
  NETWORKING_VAULT_TOKEN_SECRET=s2s-vault-token \
  GITOPS_REPO_URL="${GITOPS_REPO_URL:-}" \
  INTERCEPTIONS_JSON='[{"service_name":"reports","scope":"eks","scope_fqdn":"f.example","percent":50}]' \
  bash -c '
    source "'"$SVC_DIR"'/logging"
    # ESTE `if !` es lo que desactiva errexit en el script sourceado, igual que el runner del CLI.
    if ! source "'"$SVC_DIR"'/scripts/k8s/reconcile"; then exit 1; fi
  '
}

# Igual que `correr`, pero desde OpenShift: es la única rama que crea el alias `<svc>-local`.
# percent=100 para no entrar en el chequeo de endpoints del destino local, que es otro camino.
correr_openshift() {  # [interceptions-json]
  local reglas="$1"
  if [ -z "$reglas" ]; then
    reglas='[{"service_name":"reports","scope":"eks","scope_fqdn":"f.example","percent":100}]'
  fi
  ARGS=apply \
  NAMESPACE=payments SITE=openshift-crc PLATFORM=openshift CLUSTER_LABEL=crc \
  GATEWAY_CLASS=istio LISTEN_PORT=8080 TOKEN_DURATION=300 \
  WRISTBAND_SECRET=payments-wristband-key PEER_CA_SECRET=s2s-remote-ca \
  PEER_GATEWAY_HOST=peer.example LOCAL_INGRESS_HOST=li.example \
  GATEWAY_NAMESPACE=gateways INGRESS_AUTHPOLICY=s2s-validator \
  SIGNING_STRATEGY="${SIGNING_STRATEGY:-spiffe}" \
  NETWORKING_VAULT_ADDR=https://vault.example.io:8200 \
  NETWORKING_VAULT_NAMESPACE=admin/spiffe \
  NETWORKING_VAULT_SPIFFE_MOUNT=spiffe \
  NETWORKING_VAULT_TOKEN_SECRET=s2s-vault-token \
  GITOPS_REPO_URL="${GITOPS_REPO_URL:-}" \
  INTERCEPTIONS_JSON="$reglas" \
  bash -c '
    source "'"$SVC_DIR"'/logging"
    if ! source "'"$SVC_DIR"'/scripts/k8s/reconcile"; then exit 1; fi
  '
}

# Igual que `correr`, pero por la rama de delete.
correr_delete() {
  ARGS=delete \
  NAMESPACE=payments SITE=aws-us-east-1 PLATFORM=eks CLUSTER_LABEL=eks-kuadrant \
  GATEWAY_CLASS=istio LISTEN_PORT=8080 TOKEN_DURATION=300 \
  WRISTBAND_SECRET=payments-wristband-key PEER_CA_SECRET=s2s-remote-ca \
  PEER_GATEWAY_HOST=peer.example LOCAL_INGRESS_HOST=li.example \
  GATEWAY_NAMESPACE=gateways INGRESS_AUTHPOLICY=s2s-validator \
  SIGNING_STRATEGY="${SIGNING_STRATEGY:-spiffe}" \
  NETWORKING_VAULT_ADDR=https://vault.example.io:8200 \
  NETWORKING_VAULT_NAMESPACE=admin/spiffe \
  NETWORKING_VAULT_SPIFFE_MOUNT=spiffe \
  NETWORKING_VAULT_TOKEN_SECRET=s2s-vault-token \
  INTERCEPTIONS_JSON='[]' \
  bash -c '
    source "'"$SVC_DIR"'/logging"
    if ! source "'"$SVC_DIR"'/scripts/k8s/reconcile"; then exit 1; fi
  '
}

@test "si el Gateway no llega a Programmed, ABORTA y no toca el selector" {
  FALLA_WAIT="gateway/s2s-egress" run correr
  [ "$status" -ne 0 ]
  run grep -c ' patch svc ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "si el Gateway no llega a Programmed, tampoco anota el Service" {
  # Anotar y no desviar dejaría al Service marcado como interceptado sin estarlo.
  FALLA_WAIT="gateway/s2s-egress" run correr
  run grep -c ' annotate svc ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "el mensaje de error nombra el Gateway y sugiere dónde mirar" {
  FALLA_WAIT="gateway/s2s-egress" run correr
  [[ "$output" == *"Programmed"* ]]
  [[ "$output" == *"multus"* ]]
}

@test "si el deployment del data plane no llega a Available, ABORTA" {
  FALLA_WAIT="condition=Available" run correr
  [ "$status" -ne 0 ]
  run grep -c ' patch svc ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "si la AuthPolicy de egreso no enforcea, ABORTA" {
  FALLA_WAIT="authpolicy/s2s-egress" run correr
  [ "$status" -ne 0 ]
  run grep -c ' patch svc ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "si la publicacion gitops falla, NO se aplica nada" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo"
  run correr
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo gitops"* ]]
  run grep -cE '(^| )apply ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "en OpenShift, si la publicacion gitops falla, tampoco se crea el alias" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo"
  run correr_openshift
  [ "$status" -ne 0 ]
  run grep -cE '(^| )apply ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "en OpenShift el alias es el PRIMER objeto que toca el cluster" {
  run correr_openshift
  [ "$status" -eq 0 ]
  run grep -oE '[^ /]+\.yaml' "$KUBECTL_CALLS"
  [ "${lines[0]}" = "70-service-local.yaml" ]
}

@test "en OpenShift sin ninguna regla el reconcile termina bien y no aplica ningún alias" {
  run correr_openshift '[]'
  [ "$status" -eq 0 ]
  run grep -c '70-service-local' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "si no se puede leer el Service original, ABORTA sin publicar ni aplicar" {
  export FALLA_GET_SVC=1
  run correr_openshift
  [ "$status" -ne 0 ]
  [[ "$output" == *"estado de los Services"* ]]
  run grep -cE '(^| )apply ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "en OpenShift un Service declarado que no existe ABORTA antes de tocar nada" {
  export SVC_INEXISTENTE=1
  run correr_openshift
  [ "$status" -ne 0 ]
  [[ "$output" == *"no existen"* ]]
  run grep -cE '(^| )apply ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "un Service que existe pero no declara puertos NO se reporta como inexistente" {
  export SVC_SIN_PUERTOS=1
  run correr_openshift
  [ "$status" -ne 0 ]
  [[ "$output" == *"no declaran ningún puerto"* ]]
  [[ "$output" != *"no existen"* ]]
  run grep -cE '(^| )apply ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "una annotation de selector que no es un objeto JSON ABORTA nombrando el Service" {
  export ANOTACION_NO_ES_OBJETO=1
  run correr_openshift
  [ "$status" -ne 0 ]
  [[ "$output" == *"reports"* ]]
  run grep -cE '(^| )apply ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "si la publicacion gitops falla, tampoco se toca el selector" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo"
  run correr
  run grep -c ' patch svc ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "sin repo gitops el reconcile anda igual que siempre" {
  run correr
  [ "$status" -eq 0 ]
}

@test "con todo sano SÍ anota y desvía, en ese orden" {
  # La contraparte: sin esto, un script que aborta siempre pasaría los tests de arriba.
  run correr
  [ "$status" -eq 0 ]
  local anot patch
  anot=$(grep -n ' annotate svc ' "$KUBECTL_CALLS" | head -1 | cut -d: -f1)
  patch=$(grep -n ' patch svc ' "$KUBECTL_CALLS" | head -1 | cut -d: -f1)
  [ -n "$anot" ] && [ -n "$patch" ]
  [ "$anot" -lt "$patch" ]
}

@test "si falla el listado de Services interceptados, el delete ABORTA sin borrar nada" {
  # `for svc in $(cmd)` no dispara errexit cuando cmd falla: el for itera cero veces y sigue. Con
  # el listado caído —timeout, RBAC, blip de red— ningún Service recuperaba su selector y el delete
  # igual reportaba OK, dejándolos apuntando a un Gateway que se borra a continuación.
  export FALLA_GET_SVC=1
  run correr_delete
  [ "$status" -ne 0 ]
  [[ "$output" == *"no se pudo listar los Services interceptados"* ]]
  # Y no llegó a borrar nada.
  run grep -c ' delete ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "el delete normal SÍ llega a borrar los objetos" {
  # La contraparte del de arriba: sin esto, un delete que abortara siempre pasaría aquel test.
  # Se compara contra el `delete`, no contra el `patch`: con cero Services interceptados no hay
  # nada que revertir, y eso es correcto, no un fallo.
  run correr_delete
  [ "$status" -eq 0 ]
  run grep -c ' delete ' "$KUBECTL_CALLS"
  [ "$output" -gt 0 ]
}
