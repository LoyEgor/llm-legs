#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/opencode-go"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -ne 127 ] || fail "assert $asserts command not found: $*"
  fi
}

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
export TMPDIR
PATH="$FAKE_BIN:$PATH"
export PATH

CURL_ARGS="$WORK/curl-args"
CURL_CONFIG="$WORK/curl-config"
CURL_BODY="$WORK/curl-body"
CURL_COUNT="$WORK/curl-count"
CURL_PLAN="$WORK/curl-plan"
SECURITY_CALLS="$WORK/security-calls"
SECURITY_STORE="$WORK/security-store"
SECURITY_ACCOUNT_ONLY="$WORK/security-account-only"
export CURL_ARGS CURL_CONFIG CURL_BODY CURL_COUNT CURL_PLAN
export SECURITY_CALLS SECURITY_STORE SECURITY_ACCOUNT_ONLY

# Plan lines, one per curl call: <http-code>|<body fixture or ->|<seconds to burn>[|<exit code>].
# <http-code> "fail" means a transport failure whose exit code is the second field, which is
# what curl does on a timeout, a reset or an HTTP/2 error. A fourth field instead exits
# non-zero while still reporting the status curl did receive before the transfer broke.
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" >"$CURL_COUNT"
out= cfg= url= reads_stdin=false
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -o) out=${args[i + 1]} ;;
    --config) cfg=${args[i + 1]} ;;
    --data-binary) reads_stdin=true ;;
    http*) url=${args[i]} ;;
  esac
done
{ printf 'CALL %d\n' "$n"; for a in "$@"; do printf 'ARG=%s\n' "$a"; done; } >>"$CURL_ARGS"
[ -z "$cfg" ] || cat "$cfg" >>"$CURL_CONFIG"
if $reads_stdin; then cat >"$CURL_BODY.$n"; fi
case $url in
  */models)
    if [ -n "$out" ]; then
      printf '{"data":[{"id":"glm-5.2"},{"id":"kimi-k3"}]}' >"$out"
      printf '200'
    else
      printf '{"data":[{"id":"glm-5.2"},{"id":"kimi-k3"}]}'
    fi
    exit 0 ;;
esac
plan=$(sed -n "${n}p" "$CURL_PLAN" 2>/dev/null)
[ -n "$plan" ] || plan='200|-|0'
code=${plan%%|*}
rest=${plan#*|}
fixture=${rest%%|*}
rest=${rest#*|}
burn=${rest%%|*}
rc=0
[ "$rest" = "$burn" ] || rc=${rest#*|}
[ "$burn" = 0 ] || /bin/sleep "$burn"
if [ "$code" = fail ]; then
  printf '000'
  exit "$fixture"
fi
[ "$fixture" = - ] || cp "$fixture" "$out"
printf '%s' "$code"
exit "$rc"
EOF

cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
{ printf 'SEC'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$SECURITY_CALLS"
case ${1:-} in
  add-generic-password)
    for ((i = 1; i <= $#; i++)); do
      if [ "${!i}" = -w ]; then j=$((i + 1)); printf '%s' "${!j}" >"$SECURITY_STORE"; fi
    done
    exit 0 ;;
  find-generic-password)
    if [ -e "$SECURITY_ACCOUNT_ONLY" ]; then
      case " $* " in *" -a "*) ;; *) exit 44 ;; esac
    fi
    [ -s "$SECURITY_STORE" ] || exit 44
    cat "$SECURITY_STORE"
    exit 0 ;;
esac
exit 1
EOF

# The retry path sleeps between attempts; the tests exercise its control flow, not
# its wall clock, so only the fake curl is allowed to burn real time.
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/sleep"
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/security" "$FAKE_BIN/sleep"

printf 'glm-5.2\nkimi-k3\n' >"$TMPDIR/opencode-go-models.$(id -u).txt"

json_answer() {
  cat >"$1" <<'EOF'
{"id":"x","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"ANSWERED"}}]}
EOF
}
json_empty() {
  cat >"$1" <<'EOF'
{"id":"x","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":""}}]}
EOF
}
sse_answer() {
  cat >"$1" <<'EOF'
data: {"id":"x","model":"glm-5.2","choices":[{"delta":{"content":"STREAMED"}}]}

data: {"id":"x","choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]
EOF
}
sse_empty() {
  cat >"$1" <<'EOF'
data: {"id":"x","model":"glm-5.2","choices":[{"delta":{"reasoning_content":"thinking"}}]}

data: {"id":"x","choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]
EOF
}
cat >"$WORK/error.sse" <<'EOF'
data: {"id":"x","model":"glm-5.2","error":{"message":"upstream failure"},"choices":[{"delta":{}}]}

data: [DONE]
EOF
json_answer "$WORK/answer.json"
json_empty "$WORK/empty.json"
sse_answer "$WORK/answer.sse"
sse_empty "$WORK/empty.sse"

reset_calls() {
  rm -f "$CURL_ARGS" "$CURL_CONFIG" "$CURL_COUNT" "$CURL_PLAN" "$CURL_BODY".*
  : >"$CURL_PLAN"
}
calls() { cat "$CURL_COUNT" 2>/dev/null || echo 0; }
call_args() { awk -v want="CALL $1" '$0 == want {grab = 1; next} /^CALL /{grab = 0} grab' "$CURL_ARGS"; }

KEY='sk-secret-canary-9182'
export OPENCODE_GO_KEY="$KEY"

# The key reaches curl only through a --config file: argv is world-readable via ps.
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello 2>"$WORK/err") || fail "run failed: $(cat "$WORK/err")"
assert test "$out" = ANSWERED
assert_fails grep -q "$KEY" "$CURL_ARGS"
assert grep -q "Authorization: Bearer $KEY" "$CURL_CONFIG"

reset_calls
"$SCRIPT" raw models >/dev/null 2>&1 || fail "raw GET failed"
assert_fails grep -q "$KEY" "$CURL_ARGS"
assert grep -q "Authorization: Bearer $KEY" "$CURL_CONFIG"

reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
"$SCRIPT" raw chat/completions '{"model":"glm-5.2"}' >/dev/null 2>&1 || fail "raw POST failed"
assert_fails grep -q "$KEY" "$CURL_ARGS"
assert grep -q "Authorization: Bearer $KEY" "$CURL_CONFIG"

# A transport failure has no HTTP status; set -e used to abort the whole script there.
reset_calls
{ printf 'fail|28|0\n'; printf '200|%s|0\n' "$WORK/answer.json"; } >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello 2>"$WORK/err") || fail "transport failure was not retried: $(cat "$WORK/err")"
assert test "$out" = ANSWERED
assert test "$(calls)" = 2
assert grep -q 'curl exit 28' "$WORK/err"

# A gateway that hangs instead of 5xx-ing must still reach the stream escalation.
reset_calls
{ printf 'fail|28|0\n'; printf '200|%s|0\n' "$WORK/answer.sse"; } >"$CURL_PLAN"
out=$(OPENCODE_GO_SLOW_SWITCH_S=0 "$SCRIPT" run glm-5.2 hello 2>"$WORK/err") \
  || fail "hang did not escalate: $(cat "$WORK/err")"
assert test "$out" = STREAMED
assert grep -q 'streaming instead' "$WORK/err"
assert grep -qx 'ARG=-N' <(call_args 2)
assert grep -q '"stream":true' "$CURL_BODY.2"

# The escalated stream carries no wall-clock cap: that cap is what it escapes.
assert_fails grep -qx 'ARG=-m' <(call_args 2)
assert grep -qx 'ARG=-m' <(call_args 1)

# Same escalation from a plain slow 5xx, and again with no cap on the stream.
reset_calls
{ printf '500|-|0\n'; printf '200|%s|0\n' "$WORK/answer.sse"; } >"$CURL_PLAN"
out=$(OPENCODE_GO_SLOW_SWITCH_S=0 "$SCRIPT" run glm-5.2 hello 2>"$WORK/err") \
  || fail "slow 5xx did not escalate: $(cat "$WORK/err")"
assert test "$out" = STREAMED
assert grep -qx 'ARG=-N' <(call_args 2)
assert_fails grep -qx 'ARG=-m' <(call_args 2)

# The escalation is a different transport, not another go at the same one, so the retry
# budget must not veto it — at --retries 1 every attempt is the last one.
reset_calls
{ printf '500|-|0\n'; printf '200|%s|0\n' "$WORK/answer.sse"; } >"$CURL_PLAN"
out=$(OPENCODE_GO_SLOW_SWITCH_S=0 "$SCRIPT" run glm-5.2 hello --retries 1 2>"$WORK/err") \
  || fail "escalation was vetoed by the retry budget: $(cat "$WORK/err")"
assert test "$out" = STREAMED
assert test "$(calls)" = 2
# ...and it is sent at once: the buffered attempt already paid the wait.
assert_fails grep -q 'retrying in' "$WORK/err"

# Escalating on the last buffered attempt must still send the stream.
reset_calls
{ printf '500|-|0\n'; printf '500|-|3\n'; printf '200|%s|0\n' "$WORK/answer.sse"; } >"$CURL_PLAN"
out=$(OPENCODE_GO_SLOW_SWITCH_S=2 "$SCRIPT" run glm-5.2 hello --retries 2 2>"$WORK/err") \
  || fail "escalation on the last attempt never streamed: $(cat "$WORK/err")"
assert test "$out" = STREAMED
assert test "$(calls)" = 3

# An empty answer retires the reasoning-off strategy in streaming mode too.
reset_calls
{ printf '200|%s|0\n' "$WORK/empty.sse"; printf '200|%s|0\n' "$WORK/answer.sse"; } >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello --no-reasoning --stream 2>"$WORK/err") \
  || fail "streamed empty answer was not retried: $(cat "$WORK/err")"
assert test "$out" = STREAMED
assert test "$(calls)" = 2
assert grep -q 'answered nothing, falling back to enable-thinking' "$WORK/err"

# The buffered form of the same negotiation still works.
reset_calls
{ printf '200|%s|0\n' "$WORK/empty.json"; printf '200|%s|0\n' "$WORK/answer.json"; } >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello --no-reasoning 2>"$WORK/err") \
  || fail "buffered empty answer was not retried: $(cat "$WORK/err")"
assert test "$out" = ANSWERED
assert test "$(calls)" = 2

# A non-empty answer is never mistaken for an exhausted strategy.
reset_calls
printf '200|%s|0\n' "$WORK/answer.sse" >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello --no-reasoning --stream 2>"$WORK/err") \
  || fail "streamed answer rejected: $(cat "$WORK/err")"
assert test "$out" = STREAMED
assert test "$(calls)" = 1

# A status curl received before the transfer broke is the status: overwritten with 000, a
# usage wall becomes transient weather and gets retried into a deeper wall.
reset_calls
printf '429|-|0|18\n' >"$CURL_PLAN"
assert_fails env "$SCRIPT" run glm-5.2 hello 2>"$WORK/err"
assert test "$(calls)" = 1
assert grep -q 'HTTP 429' "$WORK/err"

# A provider error inside a stream carries no content either; retiring a reasoning-off
# strategy for it burns the negotiation on an outage and hides the error.
reset_calls
{ printf '200|%s|0\n' "$WORK/error.sse"; printf '200|%s|0\n' "$WORK/answer.sse"; } >"$CURL_PLAN"
assert_fails env "$SCRIPT" run glm-5.2 hello --no-reasoning --stream 2>"$WORK/err"
assert test "$(calls)" = 1
assert grep -q 'provider error inside stream' "$WORK/err"
assert_fails grep -q 'answered nothing' "$WORK/err"

# Every launchd context runs without USER, and set -u turns that into an instant death.
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
out=$(env -u USER "$SCRIPT" run glm-5.2 hello 2>"$WORK/err") \
  || fail "unset USER killed the script: $(cat "$WORK/err")"
assert test "$out" = ANSWERED

# A 429 is a real usage wall and must surface at once, never be retried.
reset_calls
printf '429|-|0\n' >"$CURL_PLAN"
assert_fails env "$SCRIPT" run glm-5.2 hello 2>/dev/null
assert test "$(calls)" = 1

# The keychain readback must name the account it just wrote, or a second item
# matching the same service can answer for it.
unset OPENCODE_GO_KEY
rm -f "$SECURITY_CALLS" "$SECURITY_STORE"
printf 'sk-stored-1\n' | "$SCRIPT" key >/dev/null || fail "key storage failed"
assert grep -q 'SEC find-generic-password -a .* -s opencode-go -w' "$SECURITY_CALLS"

# A key written by hand without an account is still found.
rm -f "$SECURITY_CALLS"
: >"$SECURITY_ACCOUNT_ONLY"
printf 'sk-stored-2' >"$SECURITY_STORE"
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello 2>"$WORK/err") || fail "account-scoped lookup failed: $(cat "$WORK/err")"
assert grep -q 'Authorization: Bearer sk-stored-2' "$CURL_CONFIG"
rm -f "$SECURITY_ACCOUNT_ONLY"
rm -f "$SECURITY_CALLS"
: >"$WORK/legacy-only"
cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
{ printf 'SEC'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$SECURITY_CALLS"
case ${1:-} in
  find-generic-password)
    case " $* " in *" -a "*) exit 44 ;; esac
    printf 'sk-legacy-item'
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$FAKE_BIN/security"
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
"$SCRIPT" run glm-5.2 hello >/dev/null 2>&1 || fail "legacy keychain item not found"
assert grep -q 'Authorization: Bearer sk-legacy-item' "$CURL_CONFIG"

echo "ok ($asserts asserts)"
