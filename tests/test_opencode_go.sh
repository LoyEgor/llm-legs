#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/opencode-go"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOME="$WORK/home"
export HOME
mkdir -p "$HOME"
# Every wall this suite records lands here, never in the real store.
WORKER_STATS_DIR="$WORK/worker-stats"
export WORKER_STATS_DIR
WALLS="$WORKER_STATS_DIR/walls.jsonl"
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

# A model that answered inside its reasoning field leaves a non-empty one-line announce here,
# so emptiness alone reads it as a working strategy. The caller's contract catches it.
reset_calls
cat >"$WORK/announce.json" <<'EOF'
{"id":"x","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Checking how cmd_review emits reports.","reasoning_content":"{\"severity\":\"P2\",\"file\":\"a\",\"line\":1,\"summary\":\"s\"}"}}]}
EOF
cat >"$WORK/finding.json" <<'EOF'
{"id":"x","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"{\"severity\":\"P2\",\"file\":\"a\",\"line\":1,\"summary\":\"s\"}"}}]}
EOF
{ printf '200|%s|0\n' "$WORK/announce.json"; printf '200|%s|0\n' "$WORK/finding.json"; } >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello --no-reasoning --answer-must-match '\{|no findings' \
  2>"$WORK/err") || fail "an announce-only answer was not retried: $(cat "$WORK/err")"
assert test "$(calls)" = 2
assert grep -q 'answered nothing, falling back to enable-thinking' "$WORK/err"

# An answer in the caller's own shape ends the negotiation, and a clean review is short by
# design: matching it against the announce case is what would burn the ladder on every no-issues
# result. Both accepted shapes are tested, since only one of them looks like data.
reset_calls
printf '200|%s|0\n' "$WORK/finding.json" >"$CURL_PLAN"
"$SCRIPT" run glm-5.2 hello --no-reasoning --answer-must-match '\{|no findings' \
  >/dev/null 2>"$WORK/err" || fail "a findings answer was retried: $(cat "$WORK/err")"
assert test "$(calls)" = 1
assert_fails grep -q 'answered nothing' "$WORK/err"
reset_calls
cat >"$WORK/clean.json" <<'EOF'
{"id":"x","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"NO FINDINGS"}}]}
EOF
printf '200|%s|0\n' "$WORK/clean.json" >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello --no-reasoning --answer-must-match '\{|no findings' \
  2>"$WORK/err") || fail "a clean review was retried: $(cat "$WORK/err")"
assert test "$out" = "NO FINDINGS"
assert test "$(calls)" = 1

# A reasoning block the caller will strip is not an answer: findings living only inside it still
# carry the contract's shape, which is the very failure the flag exists to catch.
reset_calls
cat >"$WORK/thinking.json" <<'EOF'
{"id":"x","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"<think>{\"severity\":\"P2\",\"file\":\"a\"}</think>Checking the diff."}}]}
EOF
{ printf '200|%s|0\n' "$WORK/thinking.json"; printf '200|%s|0\n' "$WORK/finding.json"; } >"$CURL_PLAN"
"$SCRIPT" run glm-5.2 hello --no-reasoning --answer-must-match '"severity"|no findings' \
  >/dev/null 2>"$WORK/err" || fail "a think-only answer was not retried: $(cat "$WORK/err")"
assert test "$(calls)" = 2
assert grep -q 'answered nothing, falling back to enable-thinking' "$WORK/err"

# An uncompilable pattern is refused where it is given. Reaching answered_nothing, it would make
# grep exit 2, which reads as a miss and burns the whole ladder without ever saying why.
reset_calls
printf '200|%s|0\n' "$WORK/finding.json" >"$CURL_PLAN"
assert_fails env "$SCRIPT" run glm-5.2 hello --answer-must-match 'severity[' 2>"$WORK/err"
assert grep -q 'not a usable extended regex' "$WORK/err"
assert test "$(calls)" = 0

# The second half of that guard: should grep fail to compile a pattern anyway, its exit 2 must not
# read as a miss, or every 2xx retires a strategy and the ladder burns with nothing said. Only the
# predicate's own invocation passes -Eqi, so the stub leaves the rest of the script's greps alone.
printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ $a == -Eqi ]] && exit 2; done\nexec /usr/bin/grep "$@"\n' \
  >"$FAKE_BIN/grep"
chmod +x "$FAKE_BIN/grep"
reset_calls
{ printf '200|%s|0\n' "$WORK/announce.json"; printf '200|%s|0\n' "$WORK/finding.json"; } >"$CURL_PLAN"
"$SCRIPT" run glm-5.2 hello --no-reasoning --answer-must-match '"severity"' \
  >/dev/null 2>"$WORK/err" || fail "an uncompilable pattern killed the run: $(cat "$WORK/err")"
assert test "$(calls)" = 1
rm -f "$FAKE_BIN/grep"
assert_fails grep -q 'answered nothing' "$WORK/err"

# Without the flag this script is a prose CLI: any text is the answer, and reading a contract
# into it would retire a working strategy on every ordinary reply.
reset_calls
printf '200|%s|0\n' "$WORK/announce.json" >"$CURL_PLAN"
"$SCRIPT" run glm-5.2 hello --no-reasoning >/dev/null 2>"$WORK/err" \
  || fail "a prose answer was rejected: $(cat "$WORK/err")"
assert test "$(calls)" = 1
assert_fails grep -q 'answered nothing' "$WORK/err"

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

# ...but a 2xx that died mid-body promised success and delivered a truncated one, so it goes
# back down the transport-failure path instead of being parsed as a complete answer.
reset_calls
printf '{"id":"x","choices":[{"index":0,"message":{"role":"assist' >"$WORK/truncated.json"
{ printf '200|%s|0|18\n' "$WORK/truncated.json"; printf '200|%s|0\n' "$WORK/answer.json"; } \
  >"$CURL_PLAN"
out=$("$SCRIPT" run glm-5.2 hello 2>"$WORK/err") \
  || fail "a failed 2xx was not retried: $(cat "$WORK/err")"
assert test "$out" = ANSWERED
assert test "$(calls)" = 2
assert grep -q 'HTTP 000' "$WORK/err"

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

mkdir -p "$HOME/.config/opencode-go"
printf '# Primary accounts\n# Keep this comment\n' >"$HOME/.config/opencode-go/profiles"
rm -f "$SECURITY_CALLS" "$SECURITY_STORE"
out=$(printf 'sk-team-one\n' | "$SCRIPT" profile team-one 2>"$WORK/err") \
  || fail "profile creation failed: $(cat "$WORK/err")"
assert grep -q 'SEC add-generic-password -U -a .* -s opencode-go-team-one -w sk-team-one' "$SECURITY_CALLS"
assert grep -q 'SEC find-generic-password -a .* -s opencode-go-team-one -w' "$SECURITY_CALLS"
assert grep -qx 'stored (keychain: opencode-go-team-one)' <<<"$out"
assert grep -qx 'roster: added team-one' <<<"$out"
assert grep -qx '# Primary accounts' "$HOME/.config/opencode-go/profiles"
assert grep -qx '# Keep this comment' "$HOME/.config/opencode-go/profiles"
assert grep -qx 'team-one' "$HOME/.config/opencode-go/profiles"

grep -vxF 'team-one' "$HOME/.config/opencode-go/profiles" >"$WORK/profiles-without-team-one"
mv "$WORK/profiles-without-team-one" "$HOME/.config/opencode-go/profiles"
rm -f "$SECURITY_CALLS"
out=$("$SCRIPT" p team-one </dev/null 2>"$WORK/err") \
  || fail "existing profile was not ensured: $(cat "$WORK/err")"
assert grep -qx 'profile team-one: key present' <<<"$out"
assert grep -qx 'roster: added team-one' <<<"$out"
assert_fails grep -q 'SEC add-generic-password' "$SECURITY_CALLS"
assert test "$(cat "$SECURITY_STORE")" = sk-team-one

out=$("$SCRIPT" p team-one </dev/null 2>"$WORK/err") \
  || fail "listed profile was not ensured: $(cat "$WORK/err")"
assert grep -qx 'roster: already listed' <<<"$out"
assert test "$(grep -Fxc 'team-one' "$HOME/.config/opencode-go/profiles")" = 1

# review-bench and the menubar fall back to the default account only while the roster is absent,
# so the file this command creates has to carry it: a roster opening with the new name alone
# retires the account whose key is already in the keychain.
rm -f "$HOME/.config/opencode-go/profiles"
out=$("$SCRIPT" p team-one </dev/null 2>"$WORK/err") \
  || fail "roster creation failed: $(cat "$WORK/err")"
assert grep -qx 'roster: added the default account as -' <<<"$out"
assert grep -qx 'roster: added team-one' <<<"$out"
assert test "$(cat "$HOME/.config/opencode-go/profiles")" = "$(printf -- '-\nteam-one')"

# A key `run` would accept is a key this command must not ask for again, and a default account
# with no key of its own must not be listed: the pool would hand it cells that can only fail to
# authenticate.
rm -f "$SECURITY_STORE" "$SECURITY_CALLS" "$HOME/.config/opencode-go/profiles"
printf 'sk-file-key\n' >"$HOME/.config/opencode-go/key-filekey"
out=$("$SCRIPT" p filekey </dev/null 2>"$WORK/err") \
  || fail "a file-stored key was not accepted: $(cat "$WORK/err")"
assert grep -qx 'profile filekey: key present' <<<"$out"
assert_fails grep -q 'SEC add-generic-password' "$SECURITY_CALLS"
assert test "$(cat "$HOME/.config/opencode-go/profiles")" = filekey
assert_fails grep -qx -- '-' "$HOME/.config/opencode-go/profiles"
rm -f "$HOME/.config/opencode-go/key-filekey"

# A last line that never ended must not fuse with the name appended after it: `altteam-two` is
# an account nobody has, and the listing check cannot see it on the next run either.
printf -- '-\nalt' >"$HOME/.config/opencode-go/profiles"
out=$(printf 'sk-team-two\n' | "$SCRIPT" p team-two 2>"$WORK/err") \
  || fail "profile append failed: $(cat "$WORK/err")"
assert grep -qx 'roster: added team-two' <<<"$out"
assert test "$(cat "$HOME/.config/opencode-go/profiles")" = "$(printf -- '-\nalt\nteam-two')"
assert_fails grep -q 'altteam-two' "$HOME/.config/opencode-go/profiles"

status=0
"$SCRIPT" profile Bad_Name </dev/null >"$WORK/out" 2>"$WORK/err" || status=$?
assert test "$status" = 2
assert grep -qx 'usage: opencode-go profile <name> (lowercase letters, numbers, and hyphens)' "$WORK/err"

status=0
rm -f "$SECURITY_STORE"
printf '\n' | "$SCRIPT" profile empty-key >"$WORK/out" 2>"$WORK/err" || status=$?
assert test "$status" = 1
assert grep -qx 'API key must not be empty' "$WORK/err"

status=0
"$SCRIPT" add team-one </dev/null >"$WORK/out" 2>"$WORK/err" || status=$?
assert test "$status" = 64
assert_fails grep -q 'opencode-go add' "$WORK/err"

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

# --- The plan wall is recorded where the 429 happens --------------------------
# Every caller walls the plan the same way: review-bench used to be the only writer, so a probe
# or a worker could spend the whole weekly window while the menubar showed a clean account. What
# is written here is a raw observation — whether that wall still stands is llm-limits.sh's answer.
cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/security"
export OPENCODE_GO_KEY="$KEY"
cat >"$WORK/wall.json" <<'EOF'
{"type":"error","error":{"type":"GoUsageLimitError","message":"Weekly usage limit reached. Resets in 4 days. Upgrade to Pro for more usage."},"metadata":{"workspace":"wrk_1","limitName":"weekly"}}
EOF
cat >"$WORK/wall-far.json" <<'EOF'
{"type":"error","error":{"type":"GoUsageLimitError","message":"Weekly usage limit reached. Resets in 40 days."},"metadata":{"limitName":"weekly"}}
EOF
cat >"$WORK/burst.json" <<'EOF'
{"error":{"type":"rate_limit_error","message":"provider rate limit exceeded, slow down"}}
EOF
wall_field() { jq -r "$1" <"$WALLS"; }
# A refused run prints the gateway's body; the suite reads the record, not the noise.
quiet() { "$@" >/dev/null 2>>"$WORK/wall-err"; }

rm -rf "$WORKER_STATS_DIR"
reset_calls
printf '429|%s|0\n' "$WORK/wall.json" >"$CURL_PLAN"
assert_fails quiet "$SCRIPT" run glm-5.2 hello
assert test -s "$WALLS"
assert test "$(wall_field .side)" = opencode
assert test "$(wall_field .account)" = opencode-go
assert test "$(wall_field .bucket)" = general
assert test "$(wall_field .window)" = weekly
# The horizon the gateway stated, kept as it stands: 4 days is inside the weekly ceiling.
assert test "$(wall_field '.reset_at - .detected_at | round')" = 345600
# A 429 is the plan's own answer, not weather: it must not be retried into a longer outage.
assert test "$(calls)" = 1
# A refusal is not an answer about the account being alive: stamping it as one would date the row
# by the very event that walled it, and show a walled account getting fresher the more it refuses.
assert_fails test -e "$WORKER_STATS_DIR/opencode-seen/opencode-go"

# A garbled horizon cannot retire an account past what its own window can reach.
rm -rf "$WORKER_STATS_DIR"
reset_calls
printf '429|%s|0\n' "$WORK/wall-far.json" >"$CURL_PLAN"
assert_fails quiet "$SCRIPT" run glm-5.2 hello
assert test "$(wall_field '.reset_at - .detected_at | round')" = 691200

# A refusal naming a reset but no window still goes on record under the unnamed ceiling: indexing
# the ceiling table with null aborts jq, and that abort used to drop the whole wall row.
cat >"$WORK/wall-unnamed.json" <<'EOF'
{"type":"error","error":{"type":"GoUsageLimitError","message":"Usage limit reached. Resets in 2 hours."}}
EOF
rm -rf "$WORKER_STATS_DIR"
reset_calls
printf '429|%s|0\n' "$WORK/wall-unnamed.json" >"$CURL_PLAN"
assert_fails quiet "$SCRIPT" run glm-5.2 hello
assert test -s "$WALLS"
assert test "$(wall_field 'has("window")')" = false
assert test "$(wall_field '.reset_at - .detected_at | round')" = 7200

# The profile is the account: a wall on one must never retire another.
rm -rf "$WORKER_STATS_DIR"
reset_calls
printf '429|%s|0\n' "$WORK/wall.json" >"$CURL_PLAN"
assert_fails quiet env OPENCODE_GO_PROFILE=evyoxqy "$SCRIPT" run glm-5.2 hello
assert test "$(wall_field .account)" = opencode-go-evyoxqy

# A burst throttle wears the same status code and is not this account's window.
rm -rf "$WORKER_STATS_DIR"
reset_calls
printf '429|%s|0\n' "$WORK/burst.json" >"$CURL_PLAN"
assert_fails quiet "$SCRIPT" run glm-5.2 hello
assert_fails test -s "$WALLS"

# A served COMPLETION is the opposite evidence, and it is recorded by stamping the account rather
# than by rewriting the record: nothing here reads the file and writes it back, so a 429 landing
# beside a served call cannot be read and then dropped. The rows stay; llm-limits.sh reads them
# against the stamp.
rm -rf "$WORKER_STATS_DIR"
reset_calls
printf '429|%s|0\n' "$WORK/wall.json" >"$CURL_PLAN"
assert_fails quiet "$SCRIPT" run glm-5.2 hello
assert test "$(grep -c . "$WALLS")" = 1
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
"$SCRIPT" run glm-5.2 hello >/dev/null 2>&1 || fail "served call failed"
assert test "$(grep -c . "$WALLS")" = 1
assert test "$(cat "$WORKER_STATS_DIR/opencode-seen/opencode-go")" -ge "$(jq -r '.detected_at | floor' <"$WALLS")"

# The plan answers /models while completions stay walled, so a 2xx from anywhere but a completion
# says nothing: taking one as an answer would open every walled account on the next model refresh.
rm -rf "$WORKER_STATS_DIR"
reset_calls
printf '429|%s|0\n' "$WORK/wall.json" >"$CURL_PLAN"
assert_fails quiet "$SCRIPT" run glm-5.2 hello
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
"$SCRIPT" raw models >/dev/null 2>&1 || fail "raw call failed"
assert_fails test -e "$WORKER_STATS_DIR/opencode-seen/opencode-go"
assert test "$(grep -c . "$WALLS")" = 1

# A store that refuses the write is not a store that says the account is open: the answer is real,
# the record of it is not, and a caller reading exit 0 would act on a wall nobody retired.
rm -rf "$WORKER_STATS_DIR"
mkdir -p "$WORKER_STATS_DIR/opencode-seen"
chmod 500 "$WORKER_STATS_DIR/opencode-seen"
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
: >"$WORK/wall-err"
assert_fails quiet "$SCRIPT" run glm-5.2 hello
assert grep -q 'served-call stamp' "$WORK/wall-err"
chmod 700 "$WORKER_STATS_DIR/opencode-seen"

# --- wall-check ---------------------------------------------------------------
# Whether a wall stands is llm-limits.sh's verdict, read here like any other surface reads it:
# a second implementation of that question would send a real completion on its own say-so.
LLM_LIMITS_CACHE="$WORK/llm-limits.json"
export LLM_LIMITS_CACHE
limits_cache() { # <profile> <walled>
  jq -cn --arg p "$1" --argjson w "$2" \
    '{schema:1,vendors:{opencode:{source:"opencode-go",
       accounts:[{account:$p,walled:$w,windows:(if $w then [{window:"wk",resets_at:null}] else [] end)}]}}}' \
    >"$LLM_LIMITS_CACHE"
}

# Nothing to check is nothing to send: a successful call would spend the subscription to be told
# what the row already says.
rm -rf "$WORKER_STATS_DIR"
reset_calls
limits_cache - false
out=$("$SCRIPT" wall-check 2>"$WORK/err") || fail "wall-check failed: $(cat "$WORK/err")"
assert test "$(calls)" = 0
assert grep -q '^dormant' <<<"$out"

# No row at all is not the same as a clear one: an account the collector never described must not
# be probed on a guess.
reset_calls
limits_cache evyoxqy true
status=0
out=$("$SCRIPT" wall-check 2>"$WORK/err") || status=$?
assert test "$status" = 1
assert test "$(calls)" = 0
assert grep -q '^inconclusive' "$WORK/err"

reset_calls
limits_cache - true
printf '429|%s|0\n' "$WORK/wall.json" >"$CURL_PLAN"
out=$("$SCRIPT" wall-check 2>"$WORK/err") || fail "wall-check on a standing wall failed: $(cat "$WORK/err")"
assert test "$(calls)" = 1
assert grep -q '^walled — weekly' <<<"$out"
# The wall was re-dated rather than re-guessed: a 429 costs no quota, so the record is refreshed.
assert test "$(tail -n 1 "$WALLS" | jq -r '.window')" = weekly

# A provider outage answers nothing: a row that stood before the probe is not a refusal the
# gateway just repeated, and reading it back as one would report a wall nobody re-confirmed.
reset_calls
printf '503|-|0\n' >"$CURL_PLAN"
status=0
out=$("$SCRIPT" wall-check 2>"$WORK/err") || status=$?
assert test "$status" = 1
assert grep -q '^inconclusive' "$WORK/err"
assert test -z "$out"

# The wall lifted: the plan served the probe. `served` and `dormant` are not the same answer —
# one is a completion the plan answered, the other is a request nobody sent — and a probe that
# reported the second as the first would retire a wall on the strength of nothing.
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
out=$("$SCRIPT" wall-check 2>"$WORK/err") || fail "wall-check after the lift failed: $(cat "$WORK/err")"
assert grep -q '^served' <<<"$out"
assert test -s "$WORKER_STATS_DIR/opencode-seen/opencode-go"

# One of the files a probe makes is the curl config carrying the bearer token, and a `( … )`
# subshell starts with the parent's EXIT trap reset: the refusal the probe goes looking for is
# exactly the path that used to leave both behind.
probe_leftovers() { find "$TMPDIR" -maxdepth 1 -name 'opencode-go.*' | wc -l | tr -d ' '; }
reset_calls
limits_cache - true
printf '429|%s|0\n' "$WORK/wall.json" >"$CURL_PLAN"
"$SCRIPT" wall-check >/dev/null 2>&1
assert test "$(probe_leftovers)" = 0
reset_calls
printf '200|%s|0\n' "$WORK/answer.json" >"$CURL_PLAN"
"$SCRIPT" wall-check >/dev/null 2>&1
assert test "$(probe_leftovers)" = 0

# --- wall-check --all ---------------------------------------------------------
# The leg's one refresh action asks the collector which accounts are walled, so it sends one
# request per standing wall and none at all for the rest of the roster.
jq -cn '{schema:1,vendors:{opencode:{source:"opencode-go",accounts:[
  {account:"-",walled:false,windows:[]},
  {account:"evyoxqy",walled:true,windows:[{window:"wk",resets_at:null}]}]}}}' >"$LLM_LIMITS_CACHE"
reset_calls
printf '429|%s|0\n' "$WORK/wall.json" >"$CURL_PLAN"
out=$("$SCRIPT" wall-check --all 2>&1) || fail "wall-check --all failed: $out"
assert test "$(calls)" = 1
assert grep -q '^evyoxqy: walled' <<<"$out"
assert_fails grep -q '^-:' <<<"$out"
assert test "$(tail -n 1 "$WALLS" | jq -r .account)" = opencode-go-evyoxqy

jq -cn '{schema:1,vendors:{opencode:{source:"opencode-go",accounts:[
  {account:"-",walled:false,windows:[]}]}}}' >"$LLM_LIMITS_CACHE"
reset_calls
out=$("$SCRIPT" wall-check --all 2>&1) || fail "wall-check --all on an open leg failed: $out"
assert test "$(calls)" = 0
assert grep -q '^dormant' <<<"$out"

echo "ok ($asserts asserts)"
