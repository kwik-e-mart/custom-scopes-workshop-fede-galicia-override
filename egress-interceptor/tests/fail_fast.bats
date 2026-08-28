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
case "$*" in
  *"patch svc"*)
    # Refleja el nuevo selector, igual que el API server.
    sed 's/.*"value"://; s/}]$//' <<<"$*" >"$FAKE_SELECTOR" ;;
  *"get svc reports -o jsonpath={.spec.selector}"*) cat "$FAKE_SELECTOR" ;;
  *"get svc reports -o jsonpath"*"annotations"*)    : ;;   # todavía sin anotar
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
  NAMESPACE=payments ORIGIN=EKS CLUSTER_LABEL=eks-kuadrant \
  GATEWAY_CLASS=istio LISTEN_PORT=8080 TOKEN_DURATION=300 \
  WRISTBAND_SECRET=payments-wristband-key PEER_CA_SECRET=s2s-remote-ca \
  PEER_GATEWAY_HOST=peer.example LOCAL_INGRESS_HOST=li.example \
  GATEWAY_NAMESPACE=gateways INGRESS_AUTHPOLICY=s2s-validator \
  GITOPS_REPO_URL="${GITOPS_REPO_URL:-}" \
  INTERCEPTIONS_JSON='[{"service_name":"reports","scope":"eks","scope_fqdn":"f.example","percent":50}]' \
  bash -c '
    source "'"$SVC_DIR"'/logging"
    # ESTE `if !` es lo que desactiva errexit en el script sourceado, igual que el runner del CLI.
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
  run grep -c ' apply ' "$KUBECTL_CALLS"
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
