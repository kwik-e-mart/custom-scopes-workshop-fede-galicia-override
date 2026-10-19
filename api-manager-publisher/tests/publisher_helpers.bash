setup_publisher() {
  setup_common
  PUBLISHER_SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"
  export APIM_PUBLISHER_URL="https://publisher.test"
  export APIM_PUBLISHER_TOKEN="pub-tok"
  export APIM_PUBLISH_PARENT_REFS='[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"s2s-ingress","namespace":"gateways"}]'
  export NP_MOCK_SCOPES='[{"slug":"main","domain":"main.payments.example.io"},{"slug":"draft","domain":"To be defined"}]'
  unset APIM_CLUSTER_NAME NP_MOCK_SCOPE_FAIL

  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "${1-} ${2-}" = "scope list" ]; then
  if [ "${NP_MOCK_SCOPE_FAIL:-0}" = "1" ]; then echo "np: error" >&2; exit 1; fi
  printf '%s\n' "$NP_MOCK_SCOPES"
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
