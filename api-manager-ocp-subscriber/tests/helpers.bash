setup_common() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"

  export LOG_FILE="$BATS_TEST_TMPDIR/log.txt"
  : >"$LOG_FILE"
  log() {
    local level="${1:-info}" message="${2:-}"
    printf '%s: %s\n' "$level" "$message" >>"$LOG_FILE"
    printf '%s\n' "$message" >&2
  }
  export -f log

  export API_SUBSCRIBER_URL="https://apisub.test"
  export API_SUBSCRIBER_TOKEN="tok-123"
  export APIM_RETRY_DELAY=0
  unset APIM_RETRIES NP_MOCK_UPDATE_FAIL ACTION_SETTLED SUBSCRIBER_SETTLED_MARKER

  export CURL_CALLS_LOG="$BATS_TEST_TMPDIR/curl-calls.log"
  export CURL_ARGV_LOG="$BATS_TEST_TMPDIR/curl-argv.log"
  export CURL_RESPONSES="$BATS_TEST_TMPDIR/curl-responses"
  export NP_CALLS_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  : >"$CURL_CALLS_LOG"
  : >"$CURL_ARGV_LOG"
  : >"$CURL_RESPONSES"
  : >"$NP_CALLS_LOG"

  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/bodies"
  export CURL_BODIES_DIR="$BATS_TEST_TMPDIR/bodies"

  cat >"$BATS_TEST_TMPDIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
out="" method="GET" url="" data="" idem="" auth="" writeout="" prev="" config="" timeouts=""
for arg in "$@"; do
  case "$prev" in
    -o) out="$arg" ;;
    -X) method="$arg" ;;
    -w) writeout="$arg" ;;
    --config) config="$arg" ;;
    --max-time) timeouts="${timeouts}max" ;;
    --connect-timeout) timeouts="${timeouts}connect" ;;
    --data-binary) data="$arg" ;;
    --data|-d) echo "mock curl: usar --data-binary, no --data" >&2; exit 2 ;;
    -H)
      case "$arg" in
        Idempotency-Key:*) idem="${arg#Idempotency-Key: }" ;;
        Authorization:*) auth="${arg#Authorization: }" ;;
      esac
      ;;
  esac
  case "$arg" in http://*|https://*) url="$arg" ;; esac
  prev="$arg"
done
if [ "$config" = "-" ]; then
  header=$(sed -n 's/^header = "Authorization: \(.*\)"$/\1/p')
  if [ -n "$header" ]; then auth="$header"; fi
fi
printf '%s\n' "$*" >>"$CURL_ARGV_LOG"
n=$(wc -l <"$CURL_CALLS_LOG" | tr -d ' ')
printf '%s %s idem=%s auth=%s timeouts=%s\n' "$method" "$url" "$idem" "$auth" "$timeouts" >>"$CURL_CALLS_LOG"
printf '%s' "$data" >"$CURL_BODIES_DIR/$n.json"
line=$(head -n1 "$CURL_RESPONSES")
tail -n +2 "$CURL_RESPONSES" >"$CURL_RESPONSES.next"
mv "$CURL_RESPONSES.next" "$CURL_RESPONSES"
if [ -z "$line" ]; then
  echo "mock curl: no hay respuesta encolada para $method $url" >&2
  exit 3
fi
code="${line%%$'\t'*}"
body="${line#*$'\t'}"
case "$code" in
  000)
    if [ -n "$writeout" ]; then printf '000'; fi
    echo "curl: (7) Failed to connect" >&2
    exit 7
    ;;
  timeout)
    if [ -n "$writeout" ]; then printf '000'; fi
    echo "curl: (28) Operation timed out" >&2
    exit 28
    ;;
esac
if [ -n "$out" ]; then
  printf '%s' "$body" >"$out"
else
  printf '%s' "$body"
fi
if [ -n "$writeout" ]; then printf '%s' "$code"; fi
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"

  cat >"$BATS_TEST_TMPDIR/bin/np" <<'MOCK'
#!/usr/bin/env bash
jq -nc '$ARGS.positional' --args -- "$@" >>"$NP_CALLS_LOG"
if [ "${1-} ${2-} ${3-}" = "service action update" ] && [ "${NP_MOCK_UPDATE_FAIL:-0}" = "1" ]; then
  echo "np: error updating action" >&2
  exit 1
fi
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/np"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

queue_response() {
  printf '%s\t%s\n' "$1" "$2" >>"$CURL_RESPONSES"
}

run_step() {
  run bash -c "source '$STEP'; echo NEXT_STEP_RAN"
}

curl_call_count() {
  wc -l <"$CURL_CALLS_LOG" | tr -d ' '
}

np_updates() {
  jq -c 'select(.[0:3] == ["service","action","update"])' "$NP_CALLS_LOG"
}

np_update_count() {
  np_updates | wc -l | tr -d ' '
}

np_last_update_flag() {
  local flag="$1"
  np_updates | tail -n1 | jq -r --arg f "$flag" '(index($f) // empty) as $i | .[$i + 1]'
}
