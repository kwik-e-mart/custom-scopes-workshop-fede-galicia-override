setup_publisher() {
  setup_common
  PUBLISHER_SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"
  export APIM_PUBLISHER_URL="https://publisher.test"
  export APIM_PUBLISHER_TOKEN="pub-tok"
  export NP_MOCK_SCOPES='[{"slug":"main","id":1049050904,"dimensions":{"environment":"qas"}},{"slug":"draft","id":555,"dimensions":{"environment":"qas"}}]'
  export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  : >"$KUBECTL_CALLS_LOG"
  export KUBECTL_MOCK_ROUTES='{"items":[{"metadata":{"name":"k-8-s-main-1049050904-internal"},"spec":{"rules":[{"backendRefs":[{"kind":"Service","name":"d-1049050904-111","port":8080,"weight":30},{"kind":"Service","name":"d-1049050904-222","port":8080,"weight":70}]}]}}]}'
  export KUBECTL_APPLIED_DIR="$BATS_TEST_TMPDIR/applied"
  mkdir -p "$KUBECTL_APPLIED_DIR"
  export NP_MOCK_SCOPE_READ='{"id":1049050904,"slug":"main","active_deployment":789675678}'
  export NP_MOCK_DEPLOYMENT_READ='{"id":789675678,"status":"finalized","release_id":1093627349}'
  export NP_MOCK_RELEASE_READ='{"id":1093627349,"semver":"0.2.5","build_id":13464037}'
  unset NP_MOCK_READ_FAIL APIM_CLUSTER_NAME APIM_SIGLA APIM_PROJECT NP_MOCK_SCOPE_FAIL KUBECTL_MOCK_FAIL KUBECTL_MOCK_APPLY_FAIL KUBECTL_MOCK_DELETE_FAIL LOCAL_INGRESS_HOST APIM_GATEWAY_PORT INGRESS_GATEWAY_NAME GATEWAY_NAMESPACE

  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS_LOG"
if [ "${KUBECTL_MOCK_FAIL:-0}" = "1" ]; then echo "kubectl: forbidden" >&2; exit 1; fi
case "$*" in
  *"get httproute"*) printf '%s\n' "$KUBECTL_MOCK_ROUTES" ;;
  *"apply -f -"*)
    if [ "${KUBECTL_MOCK_APPLY_FAIL:-0}" = "1" ]; then cat >/dev/null; echo "kubectl: admission webhook denied" >&2; exit 1; fi
    n=$(find "$KUBECTL_APPLIED_DIR" -type f | wc -l | tr -d ' ')
    cat >"$KUBECTL_APPLIED_DIR/$n.json"
    jq -r '"\(.kind | ascii_downcase).kuadrant.io/\(.metadata.name) configured"' "$KUBECTL_APPLIED_DIR/$n.json" ;;
  *"delete authpolicy"*)
    if [ "${KUBECTL_MOCK_DELETE_FAIL:-0}" = "1" ]; then echo "kubectl: forbidden" >&2; exit 1; fi
    echo "authpolicy.kuadrant.io deleted" ;;
  *) echo "mock kubectl: comando no esperado: $*" >&2; exit 2 ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"

  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "${1-} ${2-}" = "scope list" ]; then
  if [ "${NP_MOCK_SCOPE_FAIL:-0}" = "1" ]; then echo "np: error" >&2; exit 1; fi
  printf '%s\n' "$NP_MOCK_SCOPES"
  exit 0
fi
if [ "${2-}" = "read" ]; then
  if [ "${NP_MOCK_READ_FAIL-}" = "${1-}" ]; then echo "np: error" >&2; exit 1; fi
  case "${1-}" in
    scope) printf '%s\n' "$NP_MOCK_SCOPE_READ" ;;
    deployment) printf '%s\n' "$NP_MOCK_DEPLOYMENT_READ" ;;
    release) printf '%s\n' "$NP_MOCK_RELEASE_READ" ;;
    *) echo "np: unknown entity ${1-}" >&2; exit 1 ;;
  esac
  exit 0
fi
if [ "${2-} ${3-}" = "action update" ] && [ "${NP_MOCK_UPDATE_FAIL:-0}" = "1" ]; then
  echo "np: error updating action" >&2
  exit 1
fi
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"
}
