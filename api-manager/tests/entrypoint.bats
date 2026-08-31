#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  ENTRYPOINT="${BATS_TEST_DIRNAME}/../entrypoint/entrypoint"

  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  : >"$NP_CALLS_LOG"
  unset NP_API_KEY NULLPLATFORM_API_KEY

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NP_CALLS_LOG"
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

ctx() {
  jq -nc --argjson n "$1" '{notification: $n}'
}

@test "notificacion con .link objeto rutea al handler link" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(ctx '{"slug":"connect","type":"create","action":"whatever","link":{"id":"777"}}')
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  grep -q -- "--script=.*/link$" "$NP_CALLS_LOG"
}

@test "notificacion con .service objeto y sin .link rutea al handler service" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(ctx '{"slug":"expose","type":"create","action":"whatever","service":{"id":"svc-1"}}')
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  grep -q -- "--script=.*/service$" "$NP_CALLS_LOG"
  ! grep -q -- "--script=.*/link$" "$NP_CALLS_LOG"
}

@test "notificacion sin .link ni .service aborta sin defaultear a service" {
  export NP_ACTION_CONTEXT
  NP_ACTION_CONTEXT=$(ctx '{"slug":"mystery","type":"create","action":"mystery","marker_test_key":"x"}')
  run bash "$ENTRYPOINT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "marker_test_key"
  [ ! -s "$NP_CALLS_LOG" ]
}
