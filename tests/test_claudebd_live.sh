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

require_test_port() {
  local label=$1 port=$2
  case "$port" in
    ''|*[!0-9]*|45789) echo "FATAL: unsafe $label port '$port'"; exit 1 ;;
  esac
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
    require_test_port daemon "$DAEMON_PORT"
    CLAUDEB_DIR="$store" CLAUDEBD_PORT="$DAEMON_PORT" CLAUDEBD_UPSTREAM="$UPSTREAM" \
      CLAUDEBD_CAPACITY_RETRY_MS=10 CLAUDEBD_CAPACITY_RETRY_ATTEMPTS=1 \
      CLAUDEBD_CAPACITY_WALL_FIRST_MS="${CLAUDEBD_CAPACITY_WALL_FIRST_MS:-300000}" \
      CLAUDEBD_HOLD_MAX_MS="${CLAUDEBD_HOLD_MAX_MS:-0}" \
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
TEST_AUTH='Bearer test-token-1'

auth_header() {
  printf '%s' "${TEST_AUTH/test-token-1/$(printf '%s-%s-test' sk ant)}"
}

gpost() {
  curl -s -o "$WORK/body" -w '%{http_code}' -X POST \
    -H "authorization: $(auth_header)" -H 'content-type: application/json' \
    --data "$1" "http://127.0.0.1:$DAEMON_PORT/v1/messages"
}

MOCK_PLAN="$MOCK_PLAN" MOCK_PORT_FILE="$MOCK_PORT_FILE" MOCK_LOG="$MOCK_LOG" \
  node "$MOCK" >"$WORK/mock.out" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do [ -s "$MOCK_PORT_FILE" ] && break; sleep 0.1; done
[ -s "$MOCK_PORT_FILE" ] || { echo "FATAL: mock upstream did not start"; exit 1; }
MOCK_PORT=$(cat "$MOCK_PORT_FILE")
require_test_port "mock upstream" "$MOCK_PORT"
UPSTREAM="http://127.0.0.1:$MOCK_PORT"

echo "scenario capacity-a: one bare 429 -> same-account success without a wall"
: >"$MOCK_LOG"
write_plan <<'JSON'
{ "id": "capacity-a", "sequence": [{ "fault": "bare429" }, { "fault": "ok" }], "default": { "fault": "ok" } }
JSON
start_daemon "$(setup_store "$WORK/a" a b)"
code=$(gpost "$FAB")
eq "$code" "200" "capacity-a: client sees same-account recovery"
contains '"account":"acct-a"' "$(cat "$WORK/body")" "capacity-a: response is from account a"
eq "$(sfield current_fable)" "a" "capacity-a: account a remains current"
eq "$(sfield accounts.a.fable_walled_until)" "0" "capacity-a: no transient wall is recorded"
eq "$(grep -c '^acct-a ' "$MOCK_LOG")" "2" "capacity-a: upstream saw account a exactly twice"
contains "retry account=a scope=fable status=429 unified=none same-account attempt=1" "$(cat "$WORK/a/claudebd.log")" "capacity-a: same-account retry is logged"
stop_daemon

echo "scenario upstream-529: overload passes through without account state changes"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 529, "body": "{\"error\":\"overloaded\"}" } } }
JSON
STORE_529="$(setup_store "$WORK/upstream-529" a)"
start_daemon "$STORE_529"
code=$(gpost "$GEN")
eq "$code" "529" "upstream-529: client receives upstream status unchanged"
contains '"error":"overloaded"' "$(cat "$WORK/body")" "upstream-529: client receives upstream body unchanged"
eq "$(sfield accounts.a.walled)" "false" "upstream-529: account is not walled"
eq "$(sfield accounts.a.auth_failed_until)" "0" "upstream-529: account is not auth-rejected"
eq "$(sfield accounts.a.fable_walled_until)" "0" "upstream-529: fable scope is not walled"
eq "$(statusjson | jget walls.length)" "0" "upstream-529: no wall state is created"
eq "$(statusjson | jget pins.length)" "0" "upstream-529: no pin state is created"
eq "$(grep -c ' upstream-5xx account=a scope=general status=529 elapsed_ms=[0-9][0-9]*$' "$STORE_529/claudebd.log")" "1" "upstream-529: occurrence is logged exactly once"
stop_daemon

echo "scenario capacity-b: two bare 429s -> transient wall and account switch"
: >"$MOCK_LOG"
write_plan <<'JSON'
{ "id": "capacity-b", "sequence": [{ "fault": "bare429" }, { "fault": "bare429" }, { "fault": "ok" }], "default": { "fault": "ok" } }
JSON
start_daemon "$(setup_store "$WORK/b" a b)"
NOW=$(date +%s)
code=$(gpost "$FAB")
eq "$code" "200" "capacity-b: client sees success after switch"
contains '"account":"acct-b"' "$(cat "$WORK/body")" "capacity-b: body is from account b"
eq "$(sfield current_fable)" "b" "capacity-b: fable scope switched to b"
walled_a=$(sfield accounts.a.fable_walled_until)
in_range "$walled_a" "$((NOW + 240))" "$((NOW + 360))" "capacity-b: account a gets a short transient wall"
eq "$(sfield accounts.a.wk)" "0" "capacity-b: account a is not walled to weekly quota"
eq "$(grep -c '^acct-a ' "$MOCK_LOG")" "2" "capacity-b: account a receives one same-account retry"
eq "$(grep -c '^acct-b ' "$MOCK_LOG")" "1" "capacity-b: account b receives the switched retry"
stop_daemon

echo "scenario capacity-c: unified-header 429 -> immediate wall and switch"
: >"$MOCK_LOG"
start_daemon "$(setup_store "$WORK/capacity-c" a b)"
RESET_AT=$(( $(date +%s) + 8 ))
write_plan <<JSON
{ "id": "capacity-c", "sequence": [{ "fault": "unified429", "resetAfter": 8 }, { "fault": "ok" }], "default": { "fault": "ok" } }
JSON
code=$(gpost "$GEN")
eq "$code" "200" "capacity-c: client sees success after switch"
eq "$(sfield current)" "b" "capacity-c: general scope switched to b"
eq "$(sfield accounts.a.walled)" "true" "capacity-c: account a is walled by header reset"
eq "$(grep -c '^acct-a ' "$MOCK_LOG")" "1" "capacity-c: account a is not retried"
case "$(cat "$WORK/capacity-c/claudebd.log")" in *same-account*) fail "capacity-c: header 429 must not use same-account retry" ;; *) pass ;; esac
sleep 9
eq "$(sfield accounts.a.walled)" "false" "capacity-c: header wall clears shortly after reset"
stop_daemon

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
eq "$(sfield accounts.a.walled)" "true" "d: account a walled after exhausting round-trip"
eq "$(sfield accounts.b.walled)" "true" "d: account b walled after exhausting round-trip"
status_body="$(statusjson)"
contains '"account":"a","scope":"general"' "$status_body" "d: status walls[] lists account a"
contains '"account":"b","scope":"general"' "$status_body" "d: status walls[] lists account b"
contains '"reason":"header"' "$status_body" "d: status walls[] carries the header reason"
all_walled=$(sfield all_walled_until.general)
in_range "$all_walled" "$((NOW + 1))" "$((NOW + 6))" "d: all_walled_until.general set to earliest wall expiry when every account is walled"
code2=$(gpost "$GEN")
eq "$code2" "503" "d: subsequent all-walled request returns synthetic 503"
body2=$(cat "$WORK/body")
contains "No available accounts" "$body2" "d: 503 body carries the error"
retry_at=$(echo "$body2" | jget retry_at)
in_range "$retry_at" "$((NOW + 1))" "$((NOW + 6))" "d: retry_at is earliest wall expiry (machine-readable)"
eq "$(echo "$body2" | jget scope)" "general" "d: 503 body carries the request scope"
eq "$(echo "$body2" | jget reason)" "wall-capacity" "d: 503 body carries a machine-readable cause"
contains "general requests blocked" "$(echo "$body2" | jget message)" "d: 503 body carries a human-readable message"
eq "$(echo "$body2" | jget hint)" "" "d: header-confirmed walls (not transient) carry no hint"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"ok\":true}" }, "acct-b": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
sleep 4
code3=$(gpost "$GEN")
eq "$code3" "200" "d: after walls expire a fresh request succeeds (wall actually clears)"
eq "$(sfield all_walled_until.general)" "null" "d: all_walled_until.general clears once an account is eligible again"
stop_daemon

echo "scenario e: streaming (SSE)"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "sse": ["event: a\ndata: 1\n\n", "data: 2\n\n", "data: 3\n\n"], "delayMs": 20 } } }
JSON
start_daemon "$(setup_store "$WORK/e" a b)"
code=$(curl -sN --max-time 10 -o "$WORK/body" -w '%{http_code}' -X POST \
  -H "authorization: $(auth_header)" -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages")
eq "$code" "200" "e1: SSE response status 200"
contains "data: 1" "$(cat "$WORK/body")" "e1: first SSE chunk streamed"
contains "data: 3" "$(cat "$WORK/body")" "e1: last SSE chunk streamed"

: >"$MOCK_LOG"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 429, "body": "{}" }, "acct-b": { "sse": ["data: ok\n\n", "data: done\n\n"], "delayMs": 20 } } }
JSON
stop_daemon; start_daemon "$(setup_store "$WORK/e2" a b)"
code=$(curl -sN --max-time 10 -o "$WORK/body" -w '%{http_code}' -X POST \
  -H "authorization: $(auth_header)" -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages")
eq "$code" "200" "e2: pre-body 429 retried transparently, client sees 200"
body=$(cat "$WORK/body")
contains "data: done" "$body" "e2: client receives the retried account's stream"
case "$body" in *429*) fail "e2: client must not see the 429" ;; *) pass ;; esac
contains "acct-b" "$(cat "$MOCK_LOG")" "e2: retried onto account b"

: >"$MOCK_LOG"
write_plan <<'JSON'
{ "id": "stream-capacity", "sequence": [{ "fault": "bare429", "early": true }, { "fault": "ok" }], "default": { "fault": "ok" } }
JSON
stop_daemon; start_daemon "$(setup_store "$WORK/e2-stream" a)"
LARGE_BODY="$WORK/large-body.json"
node -e 'const fs=require("node:fs");const size=64*1024*1024+1;const data=Buffer.alloc(size,120);const prefix=Buffer.from("{\"model\":\"claude-sonnet-4-x\",\"padding\":\"");const suffix=Buffer.from("\"}");prefix.copy(data);suffix.copy(data,size-suffix.length);fs.writeFileSync(process.argv[1],data)' "$LARGE_BODY"
code=$(curl -s --max-time 20 -o "$WORK/body" -w '%{http_code}' -X POST \
  -H "authorization: $(auth_header)" -H 'content-type: application/json' \
  --data-binary "@$LARGE_BODY" "http://127.0.0.1:$DAEMON_PORT/v1/messages")
eq "$code" "200" "e2-stream: replayable pre-body capacity 429 recovers on the same account"
eq "$(sfield current)" "a" "e2-stream: streaming retry keeps account a current"
eq "$(sfield accounts.a.walled)" "false" "e2-stream: streaming retry records no wall"
eq "$(grep -c '^acct-a ' "$MOCK_LOG")" "2" "e2-stream: upstream sees two attempts on account a"
contains "retry account=a scope=general status=429 unified=none same-account attempt=1" "$(cat "$WORK/e2-stream/claudebd.log")" "e2-stream: same-account retry is logged"

write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 529, "body": "{\"error\":\"stream-overloaded\"}" } } }
JSON
stop_daemon; start_daemon "$(setup_store "$WORK/e2-stream-529" a)"
code=$(curl -s --max-time 20 -o "$WORK/body" -w '%{http_code}' -X POST \
  -H "authorization: $(auth_header)" -H 'content-type: application/json' \
  --data-binary "@$LARGE_BODY" "http://127.0.0.1:$DAEMON_PORT/v1/messages")
eq "$code" "529" "e2-stream-529: client receives streaming-path upstream status unchanged"
contains '"error":"stream-overloaded"' "$(cat "$WORK/body")" "e2-stream-529: client receives upstream body unchanged"
eq "$(sfield accounts.a.walled)" "false" "e2-stream-529: account is not walled"
eq "$(statusjson | jget walls.length)" "0" "e2-stream-529: no wall state is created"
eq "$(grep -c ' upstream-5xx account=a scope=general status=529 elapsed_ms=[0-9][0-9]*$' "$WORK/e2-stream-529/claudebd.log")" "1" "e2-stream-529: occurrence is logged exactly once"

write_plan <<'JSON'
{ "byToken": { "acct-a": { "sse": ["data: first\n\n", "data: second\n\n"], "abortAfter": 1, "delayMs": 20 } } }
JSON
stop_daemon; start_daemon "$(setup_store "$WORK/e3" a b)"
curl -sN --max-time 10 -o "$WORK/body" -X POST \
  -H "authorization: $(auth_header)" -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages"
rc=$?
contains "data: first" "$(cat "$WORK/body")" "e3: client received the pre-abort partial body"
if [ "$rc" -ne 0 ]; then pass; else fail "e3: mid-body abort should surface as a broken transfer (curl rc=$rc)"; fi
contains "stream-abort account=a scope=general cause=upstream-close" "$(cat "$WORK/e3/claudebd.log")" "e3: upstream close is logged"
eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DAEMON_PORT/claudebd/status")" "200" "e3: daemon survives mid-body abort"
stop_daemon

echo "scenario f: daemon restart mid-scenario -- walls and manual pins now SURVIVE restart"
write_plan <<JSON
{ "byToken": { "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$(( $(date +%s) + 600 ))" }, "body": "{}" }, "acct-b": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
STORE_F="$(setup_store "$WORK/f" a b)"
start_daemon "$STORE_F"
code=$(gpost "$GEN")
eq "$code" "200" "f: request succeeds (a walled 600s, b serves)"
eq "$(sfield accounts.a.walled)" "true" "f: account a walled before restart"
status_body="$(statusjson)"
contains '"account":"a","scope":"general"' "$status_body" "f: status walls[] lists account a before restart"
contains '"reason":"header"' "$status_body" "f: status walls[] carries the header reason before restart"
curl -s -o /dev/null -X POST -H 'content-type: application/json' --data '{"account":"b"}' "http://127.0.0.1:$DAEMON_PORT/claudebd/use"
eq "$(sfield current)" "b" "f: manual pin switches to account b"
contains '"account":"b","pinned_at"' "$(statusjson)" "f: status pins[] lists the manual pin on b"
stop_daemon
start_daemon "$STORE_F"
eq "$(sfield accounts.a.walled)" "true" "f: wall on account a SURVIVES restart"
status_body="$(statusjson)"
contains '"account":"a","scope":"general"' "$status_body" "f: status walls[] still lists account a after restart"
contains '"account":"b","pinned_at"' "$status_body" "f: status pins[] still lists the manual pin after restart"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"ok-a\":true}" }, "acct-b": { "status": 200, "body": "{\"ok-b\":true}" } } }
JSON
code=$(gpost "$GEN")
eq "$code" "200" "f: daemon fully functional after restart (routes to b while a stays walled)"
stop_daemon

echo "scenario g: abrupt client disconnect mid-flight does not crash the daemon"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "sse": ["data: 1\n\n", "data: 2\n\n", "data: 3\n\n", "data: 4\n\n"], "delayMs": 400 } } }
JSON
start_daemon "$(setup_store "$WORK/g" a b)"
curl -sN --max-time 0.5 -o /dev/null -X POST \
  -H "authorization: $(auth_header)" -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages" 2>/dev/null || true
sleep 0.3
contains "stream-abort account=a scope=general cause=client-close" "$(cat "$WORK/g/claudebd.log")" "g: client close is logged"
eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DAEMON_PORT/claudebd/status")" "200" "g: daemon alive after client abort"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
eq "$(gpost "$GEN")" "200" "g: daemon still serves requests after client abort"
stop_daemon

echo "scenario h: completed keep-alive responses clear upstream idle listeners"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
start_daemon "$(setup_store "$WORK/h" a)"
for _ in $(seq 1 12); do
  eq "$(gpost "$GEN")" "200" "h: sequential proxied request completes"
done
case "$(cat "$WORK/h/claudebd.log")" in *upstream-idle*) fail "h: completed requests must not log upstream-idle" ;; *) pass ;; esac
case "$(cat "$WORK/h/daemon.out")" in *MaxListenersExceededWarning*) fail "h: completed requests must not retain timeout listeners" ;; *) pass ;; esac
stop_daemon

echo "scenario i: disabling the current account reroutes the very next request (no restart, no nudge)"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"who\":\"a\"}" }, "acct-b": { "status": 200, "body": "{\"who\":\"b\"}" } } }
JSON
STORE_I="$(setup_store "$WORK/i" a b)"
start_daemon "$STORE_I"
eq "$(gpost "$GEN")" "200" "i: initial request ok"
eq "$(sfield current)" "a" "i: account a is current initially"
sleep 0.05
printf 'a\n' >"$STORE_I/disabled"
code=$(gpost "$GEN")
eq "$code" "200" "i: next request after disable still succeeds (no client error)"
contains '"who":"b"' "$(cat "$WORK/body")" "i: request routed to account b"
eq "$(sfield current)" "b" "i: current switched to b on the very next request"
case "$(sfield current)" in a) fail "i: disabled account a must not be current (case 6)" ;; *) pass ;; esac
stop_daemon

echo "scenario j: disabling an account mid-stream lets the in-flight SSE finish"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "sse": ["data: 1\n\n", "data: 2\n\n", "data: 3\n\n"], "delayMs": 300 } } }
JSON
STORE_J="$(setup_store "$WORK/j" a b)"
start_daemon "$STORE_J"
( sleep 0.4; printf 'a\n' >"$STORE_J/disabled" ) &
DIS_PID=$!
code=$(curl -sN --max-time 10 -o "$WORK/body" -w '%{http_code}' -X POST \
  -H "authorization: $(auth_header)" -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages")
wait "$DIS_PID" 2>/dev/null || true
eq "$code" "200" "j: in-flight stream on a completes with 200 despite mid-stream disable"
contains "data: 1" "$(cat "$WORK/body")" "j: first chunk delivered"
contains "data: 3" "$(cat "$WORK/body")" "j: final chunk delivered (stream not severed)"
stop_daemon

echo "scenario k: re-enabling an account returns it to rotation without a restart"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"who\":\"a\"}" }, "acct-b": { "status": 200, "body": "{\"who\":\"b\"}" } } }
JSON
STORE_K="$(setup_store "$WORK/k" a b)"
start_daemon "$STORE_K"
printf 'a\n' >"$STORE_K/disabled"
eq "$(gpost "$GEN")" "200" "k: request routes to b while a disabled"
eq "$(sfield current)" "b" "k: current is b"
sleep 0.05
: >"$STORE_K/disabled"
RESET_AT=$(( $(date +%s) + 600 ))
write_plan <<JSON
{ "byToken": { "acct-a": { "status": 200, "body": "{\"who\":\"a\"}" }, "acct-b": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$RESET_AT" }, "body": "{}" } } }
JSON
code=$(gpost "$GEN")
eq "$code" "200" "k: after re-enable and b walling, request succeeds"
contains '"who":"a"' "$(cat "$WORK/body")" "k: re-enabled account a serves again (back in rotation)"
eq "$(sfield current)" "a" "k: current rotated back to a"
stop_daemon

echo "scenario l: a manual pin created AFTER a disable sticks (documented override)"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"who\":\"a\"}" }, "acct-b": { "status": 200, "body": "{\"who\":\"b\"}" } } }
JSON
STORE_L="$(setup_store "$WORK/l" a b)"
start_daemon "$STORE_L"
printf 'a\n' >"$STORE_L/disabled"
eq "$(gpost "$GEN")" "200" "l: routes off disabled a to b"
eq "$(sfield current)" "b" "l: current is b after disabling a"
sleep 1.1
curl -s -o /dev/null -X POST -H 'content-type: application/json' --data '{"account":"a"}' "http://127.0.0.1:$DAEMON_PORT/claudebd/use"
eq "$(sfield current)" "a" "l: explicit use AFTER disable pins the disabled account"
code=$(gpost "$GEN")
eq "$code" "200" "l: pinned-after-disable account serves"
contains '"who":"a"' "$(cat "$WORK/body")" "l: request routed to the post-disable pin (a)"
eq "$(sfield current)" "a" "l: post-disable pin sticks across the next request"
stop_daemon

echo "scenario m: fable unified rejection stays scoped; general aggregate ignores auth-failed accounts"
STORE_M1="$(setup_store "$WORK/m1" a b)"
start_daemon "$STORE_M1"
RESET_AT=$(( $(date +%s) + 600 ))
write_plan <<JSON
{ "byToken": { "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$RESET_AT" }, "body": "{}" }, "acct-b": { "status": 200, "body": "{\"who\":\"b\"}" } } }
JSON
code=$(gpost "$FAB")
eq "$code" "200" "m1: fable request succeeds after scoped retry"
eq "$(sfield accounts.a.walled)" "false" "m1: fable unified rejection does not wall general"
eq "$(sfield accounts.a.fable_walled_until)" "$RESET_AT" "m1: fable unified rejection walls fable until header reset"
status_body="$(statusjson)"
contains '"account":"a","scope":"fable"' "$status_body" "m1: status reports only the fable wall"
case "$status_body" in *'"account":"a","scope":"general"'*) fail "m1: status must not report a general wall for account a" ;; *) pass ;; esac
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"who\":\"a\"}" }, "acct-b": { "status": 200, "body": "{\"who\":\"b\"}" } } }
JSON
code=$(gpost "$GEN")
eq "$code" "200" "m1: general request remains routable"
contains '"who":"a"' "$(cat "$WORK/body")" "m1: general request still routes to fable-walled account a"
stop_daemon

STORE_M2="$(setup_store "$WORK/m2" a b c)"
start_daemon "$STORE_M2"
EARLY=$(( $(date +%s) + 600 ))
LATE=$(( $(date +%s) + 900 ))
write_plan <<JSON
{ "byToken": {
  "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$EARLY" }, "body": "{}" },
  "acct-b": { "status": 401, "body": "{}" },
  "acct-c": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$LATE" }, "body": "{}" } } }
JSON
eq "$(gpost "$GEN")" "429" "m2: exhausting request reaches every account"
gt "$(sfield accounts.b.auth_failed_until)" "0" "m2: account b is excluded for auth failure"
eq "$(sfield all_walled_until.general)" "$EARLY" "m2: general aggregate is earliest wall among auth-ok accounts"
stop_daemon

echo "scenario chaos: seeded mixed-scope storm preserves walls, eligibility, recovery, and state"
STORE_CHAOS="$(setup_store "$WORK/chaos" a b c d)"
: >"$MOCK_LOG"
write_chaos_plan() {
  local index=$1 fault=$2 reset_after=${3:-2}
  case "$fault" in
    ok|abort) printf '{"id":"chaos-%s","sequence":[{"fault":"%s"}],"default":{"fault":"ok"}}\n' "$index" "$fault" >"$MOCK_PLAN" ;;
    unified429) printf '{"id":"chaos-%s","sequence":[{"fault":"unified429","resetAfter":%s},{"fault":"ok"}],"default":{"fault":"ok"}}\n' "$index" "$reset_after" >"$MOCK_PLAN" ;;
    bare429) printf '{"id":"chaos-%s","sequence":[{"fault":"bare429"},{"fault":"bare429"},{"fault":"ok"}],"default":{"fault":"ok"}}\n' "$index" >"$MOCK_PLAN" ;;
    *) printf '{"id":"chaos-%s","sequence":[{"fault":"%s"},{"fault":"ok"}],"default":{"fault":"ok"}}\n' "$index" "$fault" >"$MOCK_PLAN" ;;
  esac
}

wall_field() {
  local account=$1 scope=$2 field=$3
  statusjson | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const o=JSON.parse(d);const w=o.walls.find(x=>x.account===process.argv[1]&&x.scope===process.argv[2]);if(!w)return;process.stdout.write(process.argv[3]==="until"?String(Date.parse(w.until)/1000):String(w[process.argv[3]]||""))})' "$account" "$scope" "$field"
}

last_fault_account() { awk -v id="plan=chaos-$1" '$0 ~ id && $0 ~ /step=0/ { sub(/^acct-/, "", $1); found=$1 } END { print found }' "$MOCK_LOG"; }
last_fault_reset() { awk -v id="plan=chaos-$1" '$0 ~ id && $0 ~ /step=0/ { for (i=1;i<=NF;i++) if ($i ~ /^reset_at=/) { sub(/^reset_at=/, "", $i); found=$i } } END { print found }' "$MOCK_LOG"; }
last_plan_account() { awk -v id="plan=chaos-$1" '$0 ~ id { sub(/^acct-/, "", $1); found=$1 } END { print found }' "$MOCK_LOG"; }

# These fixed rows are the seed. Add a future injected request as one new row.
CHAOS_STORM=(
  'fable unified429 2'
  'general ok'
  'general unified429 6'
  'fable unified429 3'
  'general ok'
  'general ok'
  'general bare429'
  'fable ok'
  'fable bare429'
  'general ok'
  'fable ok'
  'general auth401'
  'fable auth401'
  'general ok'
  'fable ok'
  'general ok'
  'fable ok'
  'general ok'
  'fable ok'
  'general unified429 2'
  'general ok'
  'fable unified429 2'
  'fable ok'
  'general ok'
  'fable ok'
  'general auth401'
  'general ok'
  'fable auth401'
  'fable ok'
  'general unified429 2'
  'general ok'
  'fable unified429 2'
  'fable ok'
  'general ok'
  'general ok'
  'fable ok'
  'fable ok'
  'general ok'
  'general ok'
  'fable ok'
  'general unified429 2'
  'fable unified429 2'
  'general ok'
  'fable ok'
  'general abort'
  'general ok'
  'fable ok'
)

start_daemon "$STORE_CHAOS"
CHAOS_PID=$DAEMON_PID
CHAOS_429=0
CHAOS_401=0
CHAOS_ABORT=0
for index in "${!CHAOS_STORM[@]}"; do
  read -r scope fault reset_after <<<"${CHAOS_STORM[$index]}"
  if [ "$index" -eq 3 ]; then sleep 3; fi
  if [ "$index" -eq 4 ] || [ "$index" -eq 23 ] || [ "$index" -eq 33 ]; then sleep 3; fi
  write_chaos_plan "$index" "$fault" "$reset_after"
  body=$GEN
  [ "$scope" = "fable" ] && body=$FAB
  NOW=$(date +%s)
  if [ "$fault" = "abort" ]; then
    curl -sN --max-time 10 -o "$WORK/body" -X POST \
      -H "authorization: $(auth_header)" -H 'content-type: application/json' \
      --data "$body" "http://127.0.0.1:$DAEMON_PORT/v1/messages"
    rc=$?
    contains "data: chaos-first" "$(cat "$WORK/body")" "chaos: mid-body abort delivered its first chunk"
    if [ "$rc" -ne 0 ]; then pass; else fail "chaos: mid-body abort must be non-transparent after response bytes"; fi
    CHAOS_ABORT=$((CHAOS_ABORT + 1))
  else
    code=$(gpost "$body")
    eq "$code" "200" "chaos: request $index ($scope/$fault) is absorbed while an eligible account exists"
  fi
  eq "$(sfield pid)" "$CHAOS_PID" "chaos: daemon pid is stable after request $index"
  case "$fault" in
    bare429)
      CHAOS_429=$((CHAOS_429 + 1))
      account=$(last_fault_account "$index")
      until=$(wall_field "$account" "$scope" until)
      in_range "$until" "$((NOW + 250))" "$((NOW + 900))" "chaos: bare 429 wall for $account/$scope stays within the escalation cap"
      eq "$(wall_field "$account" "$scope" reason)" "transient" "chaos: bare 429 is classified as transient"
      ;;
    unified429)
      CHAOS_429=$((CHAOS_429 + 1))
      account=$(last_fault_account "$index")
      reset_at=$(last_fault_reset "$index")
      eq "$(wall_field "$account" "$scope" until)" "$reset_at" "chaos: header wall for $account/$scope ends exactly at its reset"
      eq "$(wall_field "$account" "$scope" reason)" "header" "chaos: unified 429 is classified as a header wall"
      ;;
    auth401)
      CHAOS_401=$((CHAOS_401 + 1))
      account=$(last_fault_account "$index")
      gt "$(sfield accounts.$account.auth_failed_until)" "0" "chaos: 401 marks only its injected account auth-failed"
      sleep 0.02
      touch "$STORE_CHAOS/tokens/$account"
      statusjson >/dev/null
      eq "$(sfield accounts.$account.auth_failed_until)" "0" "chaos: rotated credentials restore auth eligibility"
      ;;
  esac
  if [ "$index" -eq 1 ]; then
    eq "$(last_plan_account "$index")" "a" "chaos: fable rejection leaves the same account eligible for general"
  fi
  if [ "$index" -eq 3 ]; then
    eq "$(last_plan_account "$index")" "a" "chaos: general rejection leaves the same account eligible for fable"
  fi
done
eq "$(grep -c ' wall account=' "$STORE_CHAOS/claudebd.log")" "$CHAOS_429" "chaos: every injected 429 has one wall log"
eq "$(grep -c ' auth failure account=' "$STORE_CHAOS/claudebd.log")" "$CHAOS_401" "chaos: every injected 401 has one auth-failure log"
eq "$(grep -c ' stream-abort account=' "$STORE_CHAOS/claudebd.log")" "$CHAOS_ABORT" "chaos: every non-transparent stream abort has one log"
eq "$(sfield pid)" "$CHAOS_PID" "chaos: storm phase ends on its original daemon pid"
stop_daemon

STORE_CHAOS_CLEAR="$(setup_store "$WORK/chaos-clear" a b c d)"
EARLY=$(( $(date +%s) + 3 ))
LATE=$((EARLY + 3))
write_plan <<JSON
{ "byToken": {
  "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$EARLY" }, "body": "{}" },
  "acct-b": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$((EARLY + 1))" }, "body": "{}" },
  "acct-c": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$((EARLY + 2))" }, "body": "{}" },
  "acct-d": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$LATE" }, "body": "{}" } } }
JSON
start_daemon "$STORE_CHAOS_CLEAR"
CLEAR_PID=$DAEMON_PID
eq "$(gpost "$GEN")" "429" "chaos: exhausting request reaches all four genuinely walled accounts"
eq "$(sfield pid)" "$CLEAR_PID" "chaos: all-wall phase keeps its daemon pid"
eq "$(sfield all_walled_until.general)" "$EARLY" "chaos: all-walled aggregate is the earliest genuine general expiry"
eq "$(sfield all_walled_until.fable)" "null" "chaos: general walls do not create a false all-walled fable scope"
eq "$(gpost "$GEN")" "503" "chaos: request during a genuine all-wall interval is synthetic 503"
eq "$(cat "$WORK/body" | jget retry_at)" "$EARLY" "chaos: 503 retry_at equals the earliest genuine expiry exactly"
write_plan <<'JSON'
{ "default": { "status": 200, "body": "{\"ok\":true}" } }
JSON
sleep 4
eq "$(gpost "$GEN")" "200" "chaos: request succeeds just after the earliest expiry without intervention"
remaining=$((LATE - $(date +%s) + 1))
if [ "$remaining" -gt 0 ]; then sleep "$remaining"; fi
status_body=$(statusjson)
for account in a b c d; do
  eq "$(echo "$status_body" | jget accounts.$account.walled)" "false" "chaos: account $account is generally eligible after all short walls clear"
  eq "$(echo "$status_body" | jget accounts.$account.fable_walled_until)" "0" "chaos: account $account is fable-eligible after all short walls clear"
done
eq "$(node -e 'const s=require(process.argv[1]);process.stdout.write(String(Object.keys(s.accounts||{}).length))' "$STORE_CHAOS_CLEAR/daemon-state.json")" "0" "chaos: daemon-state prunes every expired account entry"
eq "$(sfield pid)" "$CLEAR_PID" "chaos: recovery phase keeps its daemon pid"
stop_daemon
start_daemon "$STORE_CHAOS_CLEAR"
RESTART_PID=$DAEMON_PID
case "$RESTART_PID" in "$CLEAR_PID") fail "chaos: restart phase must use a fresh test daemon pid" ;; *) pass ;; esac
eq "$(gpost "$GEN")" "200" "chaos: clean restart does not resurrect an expired wall"
eq "$(sfield all_walled_until.general)" "null" "chaos: restart has no stale general aggregate"
eq "$(sfield all_walled_until.fable)" "null" "chaos: restart has no stale fable aggregate"
eq "$(sfield pid)" "$RESTART_PID" "chaos: restarted phase keeps its daemon pid"
stop_daemon

echo "scenario capacity-first-wall: first bare 429 gets the short first-tier wall, not the long tier"
: >"$MOCK_LOG"
write_plan <<'JSON'
{ "id": "capacity-first-wall", "sequence": [{ "fault": "bare429" }, { "fault": "bare429" }, { "fault": "ok" }], "default": { "fault": "ok" } }
JSON
export CLAUDEBD_CAPACITY_WALL_FIRST_MS=3000
start_daemon "$(setup_store "$WORK/capacity-first-wall" a b)"
NOW=$(date +%s)
code=$(gpost "$GEN")
eq "$code" "200" "capacity-first-wall: client sees success after switch"
eq "$(sfield current)" "b" "capacity-first-wall: general scope switched to b"
until=$(wall_field a general until)
in_range "$until" "$NOW" "$((NOW + 6))" "capacity-first-wall: account a gets the short first-tier wall (~3s), not 300s"
eq "$(wall_field a general reason)" "transient" "capacity-first-wall: wall is classified as transient"
stop_daemon
unset CLAUDEBD_CAPACITY_WALL_FIRST_MS

echo "scenario capacity-escalation: a repeat bare 429 within the sliding window escalates to the next tier"
: >"$MOCK_LOG"
write_plan <<'JSON'
{ "id": "capacity-escalation-1", "sequence": [{ "fault": "bare429" }, { "fault": "bare429" }, { "fault": "ok" }], "default": { "fault": "ok" } }
JSON
export CLAUDEBD_CAPACITY_WALL_FIRST_MS=3000
STORE_ESC="$(setup_store "$WORK/capacity-escalation" a b)"
start_daemon "$STORE_ESC"
NOW=$(date +%s)
code=$(gpost "$GEN")
eq "$code" "200" "capacity-escalation: first switch succeeds"
until1=$(wall_field a general until)
in_range "$until1" "$NOW" "$((NOW + 6))" "capacity-escalation: first wall on a is the short first tier"
sleep 3.5
curl -s -o /dev/null -X POST -H 'content-type: application/json' --data '{"account":"a"}' "http://127.0.0.1:$DAEMON_PORT/claudebd/use"
eq "$(sfield current)" "a" "capacity-escalation: manual pin returns to account a once its wall clears"
write_plan <<'JSON'
{ "id": "capacity-escalation-2", "sequence": [{ "fault": "bare429" }, { "fault": "bare429" }, { "fault": "ok" }], "default": { "fault": "ok" } }
JSON
NOW2=$(date +%s)
code=$(gpost "$GEN")
eq "$code" "200" "capacity-escalation: second switch succeeds"
until2=$(wall_field a general until)
in_range "$until2" "$((NOW2 + 250))" "$((NOW2 + 900))" "capacity-escalation: repeat bare 429 on a escalates past the short tier"
stop_daemon
unset CLAUDEBD_CAPACITY_WALL_FIRST_MS

echo "scenario rotation-size: /claudebd/status reports rotation_size as the enabled-account count"
write_plan <<'JSON'
{ "default": { "status": 200, "body": "{\"ok\":true}" } }
JSON
STORE_ROT="$(setup_store "$WORK/rotation-size" a b c)"
start_daemon "$STORE_ROT"
eq "$(sfield rotation_size)" "3" "rotation-size: three enabled accounts are reported"
printf 'a\n' >"$STORE_ROT/disabled"
eq "$(sfield rotation_size)" "2" "rotation-size: disabling an account drops the reported rotation size"
stop_daemon

echo "scenario hold-a: request held while all accounts are walled, served once the wall clears within the cap"
STORE_HOLD_A="$(setup_store "$WORK/hold-a" a)"
RESET_HOLD_A=$(( $(date +%s) + 4 ))
write_plan <<JSON
{ "byToken": { "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$RESET_HOLD_A" }, "body": "{}" } } }
JSON
export CLAUDEBD_HOLD_MAX_MS=8000
start_daemon "$STORE_HOLD_A"
code1=$(gpost "$GEN")
eq "$code1" "429" "hold-a: first exhausting request forwards the upstream 429 (documented, not held)"
eq "$(sfield accounts.a.walled)" "true" "hold-a: account a is walled after the first rejection"
write_plan <<'JSON'
{ "byToken": { "acct-a": { "status": 200, "body": "{\"ok\":true}" } } }
JSON
START_HOLD=$(date +%s)
code2=$(gpost "$GEN")
ELAPSED_HOLD=$(( $(date +%s) - START_HOLD ))
eq "$code2" "200" "hold-a: held request is served once the wall clears"
gt "$ELAPSED_HOLD" "1" "hold-a: the held request actually waited (not an instant 503)"
waited_ms=$(awk -F'waited_ms=' '/hold account-scope=general/ && /outcome=served/ { split($2,a," "); print a[1] }' "$STORE_HOLD_A/claudebd.log" | tail -1)
gt "$waited_ms" "0" "hold-a: the served hold's logged waited_ms is greater than zero"
stop_daemon
unset CLAUDEBD_HOLD_MAX_MS

echo "scenario hold-b: client disconnect while held aborts the hold without leaking"
STORE_HOLD_B="$(setup_store "$WORK/hold-b" a)"
RESET_HOLD_B=$(( $(date +%s) + 30 ))
write_plan <<JSON
{ "byToken": { "acct-a": { "status": 429, "headers": { "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "$RESET_HOLD_B" }, "body": "{}" } } }
JSON
export CLAUDEBD_HOLD_MAX_MS=20000
start_daemon "$STORE_HOLD_B"
code1=$(gpost "$GEN")
eq "$code1" "429" "hold-b: first exhausting request forwards the upstream 429 (documented, not held)"
curl -s --max-time 1 -o /dev/null -X POST \
  -H "authorization: $(auth_header)" -H 'content-type: application/json' \
  --data "$GEN" "http://127.0.0.1:$DAEMON_PORT/v1/messages" 2>/dev/null || true
sleep 0.3
contains "hold account-scope=general waited_ms=" "$(cat "$STORE_HOLD_B/claudebd.log")" "hold-b: a hold log line is recorded for the aborted hold"
contains "outcome=client-close" "$(cat "$STORE_HOLD_B/claudebd.log")" "hold-b: the aborted hold logs outcome=client-close"
eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DAEMON_PORT/claudebd/status")" "200" "hold-b: daemon survives the aborted hold"
hold_lines=$(grep -c 'hold account-scope=general' "$STORE_HOLD_B/claudebd.log")
eq "$hold_lines" "1" "hold-b: exactly one hold outcome is logged (no leaked/duplicate resolution)"
stop_daemon
unset CLAUDEBD_HOLD_MAX_MS

echo "scenario hold-c: 3 usable + 1 blocked account -> served instantly, no hold path engaged at all"
STORE_HOLD_C="$(setup_store "$WORK/hold-c" a b c d)"
BLOCKED_UNTIL=$(( $(date +%s) + 300 ))
cat >"$STORE_HOLD_C/daemon-state.json" <<JSON
{ "accounts": { "a": { "forcedUntil": $BLOCKED_UNTIL, "forcedReason": "transient", "forcedScope": "general" } }, "pinnedAt": {} }
JSON
write_plan <<'JSON'
{ "default": { "status": 200, "body": "{\"ok\":true}" } }
JSON
export CLAUDEBD_HOLD_MAX_MS=8000
start_daemon "$STORE_HOLD_C"
eq "$(sfield accounts.a.walled)" "true" "hold-c: account a is walled from a pre-seeded forcedUntil"
START_NOHOLD=$(date +%s)
code=$(gpost "$GEN")
ELAPSED_NOHOLD=$(( $(date +%s) - START_NOHOLD ))
eq "$code" "200" "hold-c: request is served despite one blocked account"
in_range "$ELAPSED_NOHOLD" "0" "1" "hold-c: request is served instantly, not held"
hold_count_c=$(grep -c 'hold account-scope=' "$STORE_HOLD_C/claudebd.log" 2>/dev/null)
eq "${hold_count_c:-0}" "0" "hold-c: no hold log line is ever emitted"
stop_daemon
unset CLAUDEBD_HOLD_MAX_MS

echo "scenario current-null-fable-sibling: general current=null must not falsely 503 a fable request a sibling can serve"
STORE_NULLCUR="$(setup_store "$WORK/current-null-fable-sibling" a b)"
FUTURE_WALL=$(( $(date +%s) + 300 ))
cat >"$STORE_NULLCUR/daemon-state.json" <<JSON
{ "accounts": { "a": { "forcedUntil": $FUTURE_WALL, "forcedReason": "transient" }, "b": { "forcedUntil": $FUTURE_WALL, "forcedReason": "transient", "forcedScope": "general" } }, "pinnedAt": {} }
JSON
write_plan <<'JSON'
{ "default": { "fault": "ok" } }
JSON
start_daemon "$STORE_NULLCUR"
eq "$(sfield current)" "null" "current-null-fable-sibling: general current is null (both accounts blocked for general)"
eq "$(sfield current_fable)" "b" "current-null-fable-sibling: fable current is the general-only-walled sibling b"
code=$(gpost "$FAB")
eq "$code" "200" "current-null-fable-sibling: fable request is served by the eligible sibling, not falsely 503'd"
contains '"account":"acct-b"' "$(cat "$WORK/body")" "current-null-fable-sibling: response comes from account b"
stop_daemon

echo "scenario cause-explicit: a fable-only transient wall carries scope/reason/hint and notes general still works"
STORE_CAUSE="$(setup_store "$WORK/cause-explicit" a)"
write_plan <<'JSON'
{ "id": "cause-explicit", "sequence": [{ "fault": "bare429" }, { "fault": "bare429" }], "default": { "fault": "ok" } }
JSON
start_daemon "$STORE_CAUSE"
code1=$(gpost "$FAB")
eq "$code1" "429" "cause-explicit: first fable request forwards the upstream bare 429 (documented)"
eq "$(sfield accounts.a.usable.fable)" "false" "cause-explicit: account a is no longer fable-usable"
eq "$(sfield accounts.a.usable.general)" "true" "cause-explicit: account a is still general-usable (scoped wall only)"
code2=$(gpost "$FAB")
eq "$code2" "503" "cause-explicit: second fable request hits the synthetic 503 (only account, no hold configured)"
body2=$(cat "$WORK/body")
eq "$(echo "$body2" | jget scope)" "fable" "cause-explicit: 503 body names the blocked scope"
eq "$(echo "$body2" | jget reason)" "wall-capacity" "cause-explicit: 503 body classifies the cause as a capacity wall"
contains "likely to clear soon" "$(echo "$body2" | jget hint)" "cause-explicit: transient wall carries a hint"
contains "general models still available" "$(echo "$body2" | jget message)" "cause-explicit: message notes the unaffected scope"
code3=$(gpost "$GEN")
eq "$code3" "200" "cause-explicit: a general request on the same account still succeeds"
stop_daemon

echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: claudebd live switching ($PASS assertions, 0 failures)"
else
  echo "FAIL: claudebd live switching ($PASS passed, $FAIL failed)"
  exit 1
fi
