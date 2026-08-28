#!/usr/bin/env bats
# `wait_route_condition` decide si el service desvía o no el tráfico. Se equivocó dos veces contra
# el cluster real antes de quedar bien, y las dos fallaban en verde:
#
#   1. `kubectl wait --for=condition=X` NO ve las condiciones de un HTTPRoute: viven en
#      `.status.parents[].conditions[]` y kubectl mira `.status.conditions`, vacío en este kind.
#      Timeouteaba sobre routes perfectamente sanas.
#   2. Exigir la condición en TODOS los parents está mal: hay una entrada POR CONTROLLER, y
#      Kuadrant escribe la suya con sólo `kuadrant.io/AuthPolicyAffected`. Como la escribe unos
#      segundos después que Istio, el chequeo pasaba o fallaba según cuándo se mirara.
#
# Los fixtures son capturas del cluster (CRC, 2026-08-26), no invenciones.

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "bats necesita bash >= 4" >&2; return 1; }
  source "${BATS_TEST_DIRNAME}/../logging"
  export FAKE_ROUTE="$BATS_TEST_TMPDIR/route.json"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Sólo responde al get -o json de la route; cualquier otra cosa es un error del test.
case "$*" in
  *"get httproute/no-existe"*) exit 1 ;;
  *"-o json"*) [ -s "$FAKE_ROUTE" ] || exit 1; cat "$FAKE_ROUTE" ;;
  *) exit 1 ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  eval "$(awk '/^wait_route_condition\(\) \{/,/^\}/' "${BATS_TEST_DIRNAME}/../scripts/k8s/reconcile")"
}

# Captura real: Istio reporta Accepted/ResolvedRefs, Kuadrant sólo lo suyo.
dos_controllers() {  # <accepted> <resolvedrefs>
  jq -n --arg a "$1" --arg r "$2" '{status:{parents:[
    {controllerName:"istio.io/gateway-controller", conditions:[
      {type:"Accepted",status:$a,reason:"Accepted",message:"Route was valid"},
      {type:"ResolvedRefs",status:$r,reason:"ResolvedRefs",message:"All references resolved"}]},
    {controllerName:"kuadrant.io/policy-controller", conditions:[
      {type:"kuadrant.io/AuthPolicyAffected",status:"True",reason:"Accepted",message:"affected"}]}
  ]}}' > "$FAKE_ROUTE"
}

@test "una route sana pasa aunque Kuadrant NO reporte Accepted en su propia entrada" {
  # El bug #2: exigirla en todos los parents hacía fallar esto, que es el estado normal.
  dos_controllers True True
  run wait_route_condition ns ruta Accepted 5
  [ "$status" -eq 0 ]
}

@test "ResolvedRefs=False NO pasa, aunque Accepted esté en True" {
  # Es el caso que importa: un backendRef que no resuelve —alias faltante, ReferenceGrant
  # faltante— deja Accepted en True. Mirar sólo Accepted lo dejaría pasar.
  dos_controllers True False
  run wait_route_condition ns ruta ResolvedRefs 5
  [ "$status" -ne 0 ]
}

@test "sólo Istio todavía, sin la entrada de Kuadrant: también pasa" {
  # El estado de los primeros segundos. El chequeo no puede depender de cuándo se mire.
  jq -n '{status:{parents:[{controllerName:"istio.io/gateway-controller",
    conditions:[{type:"Accepted",status:"True"},{type:"ResolvedRefs",status:"True"}]}]}}' > "$FAKE_ROUTE"
  run wait_route_condition ns ruta Accepted 5
  [ "$status" -eq 0 ]
}

@test "una condición que nadie reporta NO se da por buena" {
  # Si se diera por buena, un cambio de nombre de condición en Gateway API haría que el service
  # deje de validar sin que nadie se entere.
  dos_controllers True True
  run wait_route_condition ns ruta CondicionInventada 5
  [ "$status" -ne 0 ]
}

@test "status vacío —la route recién creada— no pasa" {
  echo '{"status":{}}' > "$FAKE_ROUTE"
  run wait_route_condition ns ruta Accepted 5
  [ "$status" -ne 0 ]
}

@test "una route que no existe no pasa" {
  dos_controllers True True
  run wait_route_condition ns no-existe Accepted 5
  [ "$status" -ne 0 ]
}

@test "un parent en False y otro en True NO pasa" {
  # Con varios parentRef reales, que un camino acepte no alcanza: el otro no existiría.
  jq -n '{status:{parents:[
    {controllerName:"a", conditions:[{type:"Accepted",status:"True"}]},
    {controllerName:"b", conditions:[{type:"Accepted",status:"False",reason:"NotAllowedByListeners"}]}]}}' > "$FAKE_ROUTE"
  run wait_route_condition ns ruta Accepted 5
  [ "$status" -ne 0 ]
}
