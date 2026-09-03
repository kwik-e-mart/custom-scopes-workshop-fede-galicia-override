#!/usr/bin/env bats
# El revert del `delete` es el único camino de vuelta: la annotation `original-selector` es el
# ÚNICO lugar donde vive el selector que tenía el Service antes de ser interceptado. Si se pierde
# con el Service todavía apuntando al Gateway —y el Gateway se borra a continuación— el namespace
# queda sin ese servicio y sin forma de arreglarlo.
#
# Pasó de verdad el 2026-08-26 en EKS: `reports` quedó con el selector del Gateway, sin annotation
# y sin endpoints. Estos tests son la red para que no vuelva a pasar en silencio.

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION})." >&2; return 1
  }
  source "${BATS_TEST_DIRNAME}/../logging"
  export -f log

  NAMESPACE=payments
  GATEWAY_SELECTOR='{"gateway.networking.k8s.io/gateway-name":"s2s-egress"}'
  ORIGINAL_SELECTOR_ANNOTATION="egress-interceptor/original-selector"

  # Estado del Service simulado, en archivos: el mock corre en otro proceso.
  export FAKE_SELECTOR_FILE="$BATS_TEST_TMPDIR/selector"
  export FAKE_ANNOTATION_FILE="$BATS_TEST_TMPDIR/annotation"
  export KUBECTL_CALLS="$BATS_TEST_TMPDIR/calls.log"
  export PATCH_IS_NOOP=""     # simula un patch que devuelve 0 pero no cambia nada
  : >"$KUBECTL_CALLS"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
case "$*" in
  *"jsonpath={.spec.selector}"*)          cat "$FAKE_SELECTOR_FILE" ;;
  *jsonpath*"original-selector"*)         cat "$FAKE_ANNOTATION_FILE" ;;
  *patch*)   [ -n "$PATCH_IS_NOOP" ] || sed 's/.*"value"://; s/}]$//' <<<"$*" >"$FAKE_SELECTOR_FILE" ;;
  *annotate*) : >"$FAKE_ANNOTATION_FILE" ;;
esac
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # Sólo las funciones: el reconcile corre de arriba a abajo y sourcearlo entero dispararía todo.
  eval "$(awk '/^set_selector\(\) \{/,/^\}/' "${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile")"
  eval "$(awk '/^current_selector\(\)/,/^\}/' "${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile")"
  eval "$(awk '/^original_selector\(\) \{/,/^\}/' "${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile")"
  eval "$(awk '/^revert_service\(\) \{/,/^\}/' "${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile")"
}

hijacked() { printf '%s' "$GATEWAY_SELECTOR" >"$FAKE_SELECTOR_FILE"; }
anotado()  { printf '%s' "$1" >"$FAKE_ANNOTATION_FILE"; }
sin_anotacion() { : >"$FAKE_ANNOTATION_FILE"; }

@test "el caso feliz: restaura el selector y recién ahí suelta la annotation" {
  hijacked; anotado '{"app":"reports"}'
  run revert_service reports
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_SELECTOR_FILE")" = '{"app":"reports"}' ]
  grep -q 'annotate' "$KUBECTL_CALLS"
}

@test "si el patch no aplica, ABORTA y NO borra la annotation" {
  # Es el invariante que sostiene todo: mientras la annotation esté, el estado es recuperable.
  hijacked; anotado '{"app":"reports"}'
  PATCH_IS_NOOP=1 run revert_service reports
  [ "$status" -ne 0 ]
  [ "$(cat "$FAKE_ANNOTATION_FILE")" = '{"app":"reports"}' ]
  run grep -c 'annotate' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "hijackeado y SIN annotation: aborta en vez de seguir como si nada" {
  # El estado que apareció en EKS. Antes esto devolvía 0 y el delete borraba el Gateway a
  # continuación, dejando el Service sin endpoints y sin dato para recuperarlo.
  hijacked; sin_anotacion
  run revert_service reports
  [ "$status" -ne 0 ]
  [[ "$output" == *"perdió la annotation"* ]]
}

@test "sin annotation pero ya con su selector propio: no hay nada que revertir" {
  printf '%s' '{"app":"reports"}' >"$FAKE_SELECTOR_FILE"; sin_anotacion
  run revert_service reports
  [ "$status" -eq 0 ]
  run grep -c 'patch' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "una annotation envenenada con el selector del propio Gateway aborta" {
  # Revertir con eso dejaría el Service igual de roto, pero con la annotation ya consumida.
  hijacked; anotado "$GATEWAY_SELECTOR"
  run revert_service reports
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROPIO Gateway"* ]]
}
