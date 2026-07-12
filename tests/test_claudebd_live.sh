#!/usr/bin/env bash
# Live integration test for bin/claudebd account switching: runs a REAL
# claudebd process on an ephemeral port against a scriptable local mock
# upstream (tests/claudebd_mock_upstream.js). No real network, no real
# credentials, never touches the production daemon / store / keychain.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DAEMON="$ROOT/bin/claudebd"
MOCK="$ROOT/tests/claudebd_mock_upstream.js"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/claudebd-live.XXXXXX")
MOCK_PLAN="$WORK/plan.json"
MOCK_PORT_FILE="$WORK/mock.port"
MOCK_LOG="$WORK/requests.log"

MOCK_PID=""
DAEMON_PID=""
DAEMON_PORT=""

cleanup() {
  # Kill both children even on failure; never leave a test daemon listening.
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
eq() { if [ "$1" = "$2" ]; then pass; else fail "$3 (want='$2' got='$1')"; fi; }
contains() { case "$2" in *"$1"*) pass ;; *) fail "$3 (missing '$1' in: $2)" ;; esac; }
gt() { if [ "$1" -gt "$2" ] 2>/dev/null; then pass; else fail "$3 (got='$1' not > $2)"; fi; }
in_range() {
  if [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null; then pass
  else fail "$4 (got='$1' not in [$2,$3])"; fi
}

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>process.stdout.write(String(p)))})'
}

jget() {
  node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const o=JSON.parse(d);const v=process.argv[1].split(".").reduce((a,k)=>a==null?a:a[k],o);process.stdout.write(v===undefined?"":String(v))}catch{process.stdout.write("ERR")}})' "$1"
}

statusjson() { curl -s "http://127.0.0.1:$DAEMON_PORT/claudebd/status"; }
sfield() { statusjson | jget "$1"; }

write_plan() { cat >"$MOCK_PLAN"; }

setup_store() {
  local store=$1; shift
  rm -rf "$store"
  mkdir -p "$store/tokens" "$store/limits"
  for name in "$@"; do printf 'acct-%s\n' "$name" >"$store/tokens/$name"; done
  echo "$store"
}

wait_ready() {
  for _ in $(seq 1 40); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DAEMON_PORT/claudebd/status" 2>/dev/null || true)" = "200" ] && return 0
    sleep 0.1
  done
  return 1
}

start_daemon() {
  local store=$1
  local attempt=0
  while [ $attempt -lt 3 ]; do
    DAEMON_PORT=$(free_port)
    CLAUDEB_DIR="$store" CLAUDEBD_PORT="$DAEMON_PORT" CLAUDEBD_UPSTREAM="$UPSTREAM" \
      node "$DAEMON" >"$store/daemon.out" 2>&1 &
    DAEMON_PID=$!
    wait_ready && return 0
    kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null; DAEMON_PID=""
    attempt=$((attempt + 1))
  done
  echo "FATAL: daemon failed to start"; exit 1
}

stop_daemon() {
  [ -n "$DAEMON_PID" ] || return 0
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
}

GEN='{"model":"claude-sonnet-4-x","messages":[]}'
FAB='{"model":"claude-fable-5","messages":[]}'

# POST a signed (sk-ant) request so the proxy performs account rotation.
gpost() {
  curl -s -o "$WORK/body" -w '%{http_code}' -X POST \
    -H 'authorization: Bearer sk-ant-test' -H 'content-type: application/json' \
    --data "$1" "http://127.0.0.1:$DAEMON_PORT/v1/messages"
}

MOCK_PLAN="$MOCK_PLAN" MOCK_PORT_FILE="$MOCK_PORT_FILE" MOCK_LOG="$MOCK_LOG" \
  node "$MOCK" >"$WORK/mock.out" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do [ -s "$MOCK_PORT_FILE" ] && break; sleep 0.1; done
[ -s "$MOCK_PORT_FILE" ] || { echo "FATAL: mock upstream did not start"; exit 1; }
UPSTREAM="http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"

#############################################
echo "scenario a: bare 429 (capacity) -> transient wall, switch, client sees success"
: >"$MOCK_LOG"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 429, "body": "{\"error\":\"overloaded\"}" }, "acct-b": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
start_daemon "$(setup_store "$WORK/a" a b)"
NOW=$(date +%s)
code=$(gpost "$FAB")
eq "$code" "200" "a: client sees success after switch"
contains '"ok":true' "$(cat "$WORK/body")" "a: body is from account b"
eq "$(sfield current_fable)" "b" "a: fable scope switched to b"
walled_a=$(sfield accounts.a.fable_walled_until)
in_range "$walled_a" "$((NOW + 240))" "$((NOW + 360))" "a: account a gets SHORT (~300s) transient fable wall"
eq "$(sfield accounts.a.wk)" "0" "a: account a NOT walled to weekly quota"
eq "$(sfield accounts.a.wreset)" "0" "a: account a has no weekly reset set"
contains "acct-a" "$(cat "$MOCK_LOG")" "a: upstream saw account a"
contains "acct-b" "$(cat "$MOCK_LOG")" "a: upstream saw account b (retry)"
stop_daemon

#############################################
echo "scenario b: 429 WITH unified reset header -> header wall until that time, switch"
write_plan <<JSON
{ "byToken": { "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$(( $(date +%s) + 3 ))" }, "body": "{}" }, "acct-b": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
start_daemon "$(setup_store "$WORK/b" a b)"
code=$(gpost "$GEN")
eq "$code" "200" "b: client sees success after switch"
eq "$(sfield current)" "b" "b: general scope switched to b"
eq "$(sfield accounts.a.walled)" "true" "b: account a is walled by header reset"
sleep 4
eq "$(sfield accounts.a.walled)" "false" "b: header wall cleared shortly after reset (not a 300s+ wall)"
stop_daemon

#############################################
echo "scenario c: 401 -> auth-failed, switch, does not poison other account"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 401, "body": "{\"error\":\"unauthorized\"}" }, "acct-b": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
start_daemon "$(setup_store "$WORK/c" a b)"
code=$(gpost "$GEN")
eq "$code" "200" "c: client sees success after auth-failure switch"
eq "$(sfield current)" "b" "c: switched to b"
gt "$(sfield accounts.a.auth_failed_until)" "0" "c: account a marked auth-failed"
eq "$(sfield accounts.b.auth_failed_until)" "0" "c: account b NOT poisoned"
stop_daemon

#############################################
echo "scenario d: all accounts walled -> 503 with machine-readable retry_at, then clears"
write_plan <<JSON
{ "byToken": {
  "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$(( $(date +%s) + 3 ))" }, "body": "{}" },
  "acct-b": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$(( $(date +%s) + 4 ))" }, "body": "{}" } } }
JSON
start_daemon "$(setup_store "$WORK/d" a b)"
NOW=$(date +%s)
code1=$(gpost "$GEN")
eq "$code1" "429" "d: first exhausting request forwards upstream 429 (documented)"
code2=$(gpost "$GEN")
eq "$code2" "503" "d: subsequent all-walled request returns synthetic 503"
body2=$(cat "$WORK/body")
contains "No available accounts" "$body2" "d: 503 body carries the error"
retry_at=$(echo "$body2" | jget retry_at)
in_range "$retry_at" "$((NOW + 1))" "$((NOW + 6))" "d: retry_at is earliest wall expiry (machine-readable)"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"ok\":true}" }, "acct-b": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
sleep 4
code3=$(gpost "$GEN")
eq "$code3" "200" "d: after walls expire a fresh request succeeds (wall actually clears)"
stop_daemon

#############################################
echo "scenario e: streaming (SSE)"
# e1: SSE streams through unchanged
write_plan <<'JSON'
{ "byToken": { "acct-a": { "sse": ["event: a\ndata: 1\n\n", "data: 2\n\n", "data: 3\n\n"], "delayMs": 20 } } }
JSON
start_daemon "$(setup_store "$WORK/e" a b)"
code=$(curl -sN --max-time 10 -o "$WORK/body" -w '%{http_code}' -X POST \
  -H 'authorization: Bearer sk-ant-test' -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages")
eq "$code" "200" "e1: SSE response status 200"
contains "data: 1" "$(cat "$WORK/body")" "e1: first SSE chunk streamed"
contains "data: 3" "$(cat "$WORK/body")" "e1: last SSE chunk streamed"

# e2: upstream 429s BEFORE any body -> transparent retry, client only sees the stream
: >"$MOCK_LOG"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 429, "body": "{}" }, "acct-b": { "sse": ["data: ok\n\n", "data: done\n\n"], "delayMs": 20 } } }
JSON
stop_daemon; start_daemon "$(setup_store "$WORK/e2" a b)"
code=$(curl -sN --max-time 10 -o "$WORK/body" -w '%{http_code}' -X POST \
  -H 'authorization: Bearer sk-ant-test' -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages")
eq "$code" "200" "e2: pre-body 429 retried transparently, client sees 200"
body=$(cat "$WORK/body")
contains "data: done" "$body" "e2: client receives the retried account's stream"
case "$body" in *429*) fail "e2: client must not see the 429" ;; *) pass ;; esac
contains "acct-b" "$(cat "$MOCK_LOG")" "e2: retried onto account b"

# e3: stream dies MID-BODY -> client gets partial content, connection breaks, no retry
write_plan <<'JSON'
{ "byToken": { "acct-a": { "sse": ["data: first\n\n", "data: second\n\n"], "abortAfter": 1, "delayMs": 20 } } }
JSON
stop_daemon; start_daemon "$(setup_store "$WORK/e3" a b)"
curl -sN --max-time 10 -o "$WORK/body" -X POST \
  -H 'authorization: Bearer sk-ant-test' -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages"
rc=$?
contains "data: first" "$(cat "$WORK/body")" "e3: client received the pre-abort partial body"
if [ "$rc" -ne 0 ]; then pass; else fail "e3: mid-body abort should surface as a broken transfer (curl rc=$rc)"; fi
eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DAEMON_PORT/claudebd/status")" "200" "e3: daemon survives mid-body abort"
stop_daemon

#############################################
echo "scenario f: daemon restart mid-scenario (baseline for known state-loss limitation)"
write_plan <<JSON
{ "byToken": { "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$(( $(date +%s) + 600 ))" }, "body": "{}" }, "acct-b": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
STORE_F="$(setup_store "$WORK/f" a b)"
start_daemon "$STORE_F"
code=$(gpost "$GEN")
eq "$code" "200" "f: request succeeds (a walled 600s, b serves)"
eq "$(sfield accounts.a.walled)" "true" "f: account a walled before restart"
stop_daemon
start_daemon "$STORE_F"
eq "$(sfield accounts.a.walled)" "false" "f: in-memory wall LOST after restart (documented limitation)"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"ok-a\":true}" }, "acct-b": { "status": 200, "body": "{\"ok-b\":true}" } } }
JSON
code=$(gpost "$GEN")
eq "$code" "200" "f: daemon fully functional after restart"
stop_daemon

#############################################
echo "scenario g: abrupt client disconnect mid-flight does not crash the daemon"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "sse": ["data: 1\n\n", "data: 2\n\n", "data: 3\n\n", "data: 4\n\n"], "delayMs": 400 } } }
JSON
start_daemon "$(setup_store "$WORK/g" a b)"
curl -sN --max-time 0.5 -o /dev/null -X POST \
  -H 'authorization: Bearer sk-ant-test' -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages" 2>/dev/null || true
sleep 0.3
eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DAEMON_PORT/claudebd/status")" "200" "g: daemon alive after client abort"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
eq "$(gpost "$GEN")" "200" "g: daemon still serves requests after client abort"
stop_daemon

#############################################
echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: claudebd live switching ($PASS assertions, 0 failures)"
else
  echo "FAIL: claudebd live switching ($PASS passed, $FAIL failed)"
  exit 1
fi
