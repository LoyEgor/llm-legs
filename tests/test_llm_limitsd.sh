#!/usr/bin/env bash
# Hermetic tests for bin/llm-limitsd (SHADOW MODE control-plane ledger).
# Everything runs against a temp sqlite db + a child daemon on an ephemeral port. Nothing here
# touches the live daemon (45789), the real ~/.llm-limits.json, or the real .claudeb store.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$ROOT/bin/llm-limitsd"
WORK="$(mktemp -d)"
PORT=""
DPID=""
B=""

asserts=0
fail() { echo "FAIL: $*" >&2; stop_daemon; rm -rf "$WORK"; exit 1; }
ok() { asserts=$((asserts + 1)); }

stop_daemon() {
  [ -z "$DPID" ] || kill "$DPID" 2>/dev/null || true
  DPID=""
}
cleanup() { stop_daemon; rm -rf "$WORK"; }
trap cleanup EXIT

# start_daemon <db> <projection> [extra env assignments...] — boots a child on an ephemeral
# port, blocks until the listen line appears, exports B/PORT/DPID.
start_daemon() {
  local db="$1" proj="$2"; shift 2
  local errlog="$WORK/err.$$.$RANDOM.log"
  # Invoke the daemon DIRECTLY (not via `python3 …`) so a lost exec bit or broken shebang fails boot.
  env "$@" LLM_LIMITSD_PORT=0 LLM_LIMITSD_DB="$db" LLM_LIMITSD_PROJECTION="$proj" \
    "$DAEMON" 2>"$errlog" &
  DPID=$!
  local i
  for i in $(seq 1 200); do
    PORT="$(sed -n 's/.*127.0.0.1:\([0-9]*\).*/\1/p' "$errlog" 2>/dev/null | head -1)"
    [ -n "$PORT" ] && break
    kill -0 "$DPID" 2>/dev/null || { echo "daemon died on boot:" >&2; cat "$errlog" >&2; return 1; }
    perl -e 'select(undef,undef,undef,0.02)'
  done
  [ -n "$PORT" ] || { echo "daemon never announced a port" >&2; cat "$errlog" >&2; return 1; }
  [ "$PORT" = "45789" ] && { echo "refusing data-plane port 45789" >&2; return 1; }
  B="127.0.0.1:$PORT"
}

GET() { curl -s "$B$1"; }
POST() { curl -s -w '\n%{http_code}' -X POST "$B$1" -d "$2"; }
jqget() { python3 -c 'import sys,json;d=json.load(sys.stdin)
'"$1" ; }
db_count() { python3 - "$1" "$2" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("SELECT COUNT(*) FROM %s" % sys.argv[2]).fetchone()[0])
PY
}

now() { date +%s; }

echo "== daemon file is executable =="
[ -x "$DAEMON" ] || fail "bin/llm-limitsd lost its executable bit"
ok

echo "== bootstrap: db absent -> clean =="
DB="$WORK/main.sqlite"; PROJ="$WORK/main.proj.json"
[ -e "$DB" ] && fail "db pre-existed"
start_daemon "$DB" "$PROJ" || fail "daemon boot"
[ -f "$DB" ] || fail "db not bootstrapped"
GET /healthz | grep -q '"status": "ok"' || fail "healthz not ok"
ok

echo "== run lifecycle happy path =="
run="$(curl -s -X POST "$B/runs" -d '{"mode":"refresh","targets":[{"vendor":"claude","account":"alona","phase":"probe"}]}')"
rid="$(printf '%s' "$run" | jqget 'print(d["run_id"])')"
[ -n "$rid" ] || fail "no run id"
[ "$(printf '%s' "$run" | jqget 'print(d["status"])')" = "pending" ] || fail "new run not pending"
resp="$(POST "/runs/$rid/steps" '{"vendor":"claude","account":"alona","phase":"probe","status":"running"}')"
[ "$(GET "/runs/$rid" | jqget 'print(d["status"])')" = "running" ] || fail "run not running after step running"
POST "/runs/$rid/steps" '{"vendor":"claude","account":"alona","phase":"probe","status":"succeeded"}' >/dev/null
[ "$(GET "/runs/$rid" | jqget 'print(d["status"])')" = "succeeded" ] || fail "run not succeeded"
[ "$(GET "/runs/$rid" | jqget 'print(d["ended_at"] is not None)')" = "True" ] || fail "succeeded run missing ended_at"
ok

echo "== bare succeeded (no prior running) is rejected 400 =="
run="$(curl -s -X POST "$B/runs" -d '{"mode":"refresh","targets":[{"vendor":"claude","account":"bare","phase":"probe"}]}')"
rid="$(printf '%s' "$run" | jqget 'print(d["run_id"])')"
code="$(POST "/runs/$rid/steps" '{"vendor":"claude","account":"bare","phase":"probe","status":"succeeded"}' | tail -1)"
[ "$code" = "400" ] || fail "bare succeeded accepted without a prior running (http $code)"
[ "$(GET "/runs/$rid" | jqget 'print(d["status"])')" != "succeeded" ] || fail "bare succeeded flipped run to succeeded"
ok

echo "== run with a skipped target never succeeds =="
run="$(curl -s -X POST "$B/runs" -d '{"mode":"refresh","targets":[{"vendor":"claude","account":"a","phase":"probe"},{"vendor":"claude","account":"b","phase":"probe"}]}')"
rid="$(printf '%s' "$run" | jqget 'print(d["run_id"])')"
POST "/runs/$rid/steps" '{"vendor":"claude","account":"a","phase":"probe","status":"running"}' >/dev/null
POST "/runs/$rid/steps" '{"vendor":"claude","account":"a","phase":"probe","status":"succeeded"}' >/dev/null
POST "/runs/$rid/steps" '{"vendor":"claude","account":"b","phase":"probe","status":"skipped"}' >/dev/null
st="$(GET "/runs/$rid" | jqget 'print(d["status"])')"
[ "$st" = "partial" ] || fail "skipped target -> expected partial, got $st"
[ "$st" != "succeeded" ] || fail "skipped target reported succeeded"
ok

echo "== run with a failed target -> failed, never succeeded =="
run="$(curl -s -X POST "$B/runs" -d '{"mode":"refresh","targets":[{"vendor":"claude","account":"a","phase":"probe"},{"vendor":"claude","account":"c","phase":"probe"}]}')"
rid="$(printf '%s' "$run" | jqget 'print(d["run_id"])')"
POST "/runs/$rid/steps" '{"vendor":"claude","account":"a","phase":"probe","status":"running"}' >/dev/null
POST "/runs/$rid/steps" '{"vendor":"claude","account":"a","phase":"probe","status":"succeeded"}' >/dev/null
POST "/runs/$rid/steps" '{"vendor":"claude","account":"c","phase":"probe","status":"failed","reason_code":2}' >/dev/null
[ "$(GET "/runs/$rid" | jqget 'print(d["status"])')" = "failed" ] || fail "failed target not -> failed"
ok

echo "== timeout is a recorded step outcome, not a silent kill =="
run="$(curl -s -X POST "$B/runs" -d '{"mode":"refresh","targets":[{"vendor":"claude","account":"t","phase":"heal"}]}')"
rid="$(printf '%s' "$run" | jqget 'print(d["run_id"])')"
POST "/runs/$rid/steps" '{"vendor":"claude","account":"t","phase":"heal","status":"failed","reason_code":124}' >/dev/null
rc="$(GET "/runs/$rid" | jqget 'print(d["steps"][0]["reason_code"])')"
[ "$rc" = "124" ] || fail "timeout reason_code not recorded (got $rc)"
[ "$(GET "/runs/$rid" | jqget 'print(d["status"])')" != "succeeded" ] || fail "timed-out run reported succeeded"
ok

echo "== start-window success requires a reconcile observation =="
run="$(curl -s -X POST "$B/runs" -d '{"mode":"start-windows","targets":[{"vendor":"claude","account":"w","phase":"start-window"}]}')"
rid="$(printf '%s' "$run" | jqget 'print(d["run_id"])')"
POST "/runs/$rid/steps" '{"vendor":"claude","account":"w","phase":"start-window","status":"running"}' >/dev/null
# 200-from-the-network alone (no reconcile obs) must NOT be accepted as success.
code="$(POST "/runs/$rid/steps" '{"vendor":"claude","account":"w","phase":"start-window","status":"succeeded"}' | tail -1)"
[ "$code" = "409" ] || fail "start-window succeeded without reconcile (http $code)"
[ "$(GET "/runs/$rid" | jqget 'print(d["steps"][0]["status"])')" = "running" ] || fail "rejected step did not stay running"
# Provide the reconcile observation (fresh resets_at, observed after the step started), retry.
future=$(( $(now) + 18000 ))
obat=$(( $(now) + 5 ))
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"w\",\"scope\":\"window\",\"observed_at\":$obat,\"payload\":{\"event\":\"reconciled\",\"resets_at\":$future,\"window\":\"five_hour\",\"used_pct\":1,\"origin\":\"usage\"}}" >/dev/null
code="$(POST "/runs/$rid/steps" '{"vendor":"claude","account":"w","phase":"start-window","status":"succeeded"}' | tail -1)"
[ "$code" = "200" ] || fail "start-window not accepted after reconcile (http $code)"
[ "$(GET "/runs/$rid" | jqget 'print(d["status"])')" = "succeeded" ] || fail "reconciled start-window run not succeeded"
ok

echo "== reducer auth honesty: weather never expires, affirmative does =="
DB2="$WORK/auth.sqlite"; PROJ2="$WORK/auth.proj.json"
stop_daemon; start_daemon "$DB2" "$PROJ2" || fail "auth daemon boot"
t=$(now)
# capacity weather (rc 75), even carrying verdict=expired, must be ignored for auth.
POST "/observations" "{\"source\":\"claudebd\",\"vendor\":\"claude\",\"account\":\"m\",\"scope\":\"auth\",\"observed_at\":$t,\"payload\":{\"verdict\":\"expired\",\"evidence\":\"weather\",\"reason_code\":75}}" >/dev/null
au="$(GET /state | jqget 'print([a["auth"] for a in d["accounts"] if a["account"]=="m"][0])')"
[ "$au" = "ok" ] || fail "weather observation flipped auth to $au"
# an UNKNOWN evidence tag (default-deny) must also never move the verdict.
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"m\",\"scope\":\"auth\",\"observed_at\":$((t+2)),\"payload\":{\"verdict\":\"expired\",\"evidence\":\"warm-429\"}}" >/dev/null
au="$(GET /state | jqget 'print([a["auth"] for a in d["accounts"] if a["account"]=="m"][0])')"
[ "$au" = "ok" ] || fail "unknown evidence tag flipped auth to $au"
# affirmative auth rejection (rc 2) flips it.
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"m\",\"scope\":\"auth\",\"observed_at\":$((t+10)),\"payload\":{\"verdict\":\"expired\",\"evidence\":\"affirmative\",\"reason_code\":2}}" >/dev/null
au="$(GET /state | jqget 'print([a["auth"] for a in d["accounts"] if a["account"]=="m"][0])')"
[ "$au" = "expired" ] || fail "affirmative rejection did not expire auth (got $au)"
ok

echo "== late/out-of-order observation never regresses newer state =="
t=$(now)
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"oo\",\"scope\":\"auth\",\"observed_at\":$((t+1000)),\"payload\":{\"verdict\":\"ok\",\"evidence\":\"affirmative\"}}" >/dev/null
# arrives later but describes an OLDER moment -> must not override the newer "ok"
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"oo\",\"scope\":\"auth\",\"observed_at\":$((t+10)),\"payload\":{\"verdict\":\"expired\",\"evidence\":\"affirmative\"}}" >/dev/null
au="$(GET /state | jqget 'print([a["auth"] for a in d["accounts"] if a["account"]=="oo"][0])')"
[ "$au" = "ok" ] || fail "stale observation regressed newer auth state (got $au)"
ok

echo "== projection schema equivalence (real-cache jq contract) =="
DB3="$WORK/proj3.sqlite"; PROJ3="$WORK/proj3.json"
stop_daemon; start_daemon "$DB3" "$PROJ3" || fail "proj daemon boot"
t=$(now); f5=$((t+3600)); fw=$((t+7200)); ff=$((t+9000))
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"alona\",\"scope\":\"auth\",\"observed_at\":$t,\"payload\":{\"verdict\":\"ok\",\"evidence\":\"affirmative\"}}" >/dev/null
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"alona\",\"scope\":\"window\",\"observed_at\":$t,\"payload\":{\"window\":\"five_hour\",\"used_pct\":12,\"resets_at\":$f5,\"origin\":\"usage\"}}" >/dev/null
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"alona\",\"scope\":\"window\",\"observed_at\":$t,\"payload\":{\"window\":\"weekly\",\"used_pct\":40,\"resets_at\":$fw,\"origin\":\"usage\"}}" >/dev/null
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"alona\",\"scope\":\"window\",\"observed_at\":$t,\"payload\":{\"window\":\"fable\",\"used_pct\":41,\"resets_at\":$ff,\"origin\":\"usage\"}}" >/dev/null
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"alona\",\"scope\":\"rotation\",\"observed_at\":$t,\"payload\":{\"is_current\":true,\"enabled\":true}}" >/dev/null
jq -e '.schema == 1 and (.vendors | has("claude"))' "$PROJ3" >/dev/null || fail "schema/vendors mismatch"
jq -e '(.vendors.claude.accounts | type) == "array" and (.vendors.claude.accounts | length) == 1' "$PROJ3" >/dev/null || fail "accounts array mismatch"
jq -e '.vendors.claude.five_hour.effective_pct == .vendors.claude.five_hour.used_pct and
  .vendors.claude.accounts[0].weekly.effective_pct == .vendors.claude.accounts[0].weekly.used_pct' "$PROJ3" >/dev/null || fail "live effective_pct mismatch"
jq -e '(.vendors.claude.five_hour.as_of | type) == "number" and .vendors.claude.five_hour.stale == false and .vendors.claude.stale == false' "$PROJ3" >/dev/null || fail "freshness fields mismatch"
jq -e '.vendors.claude.usable_now == true and .vendors.claude.current_account == "alona" and .vendors.claude.auth.status == "ok"' "$PROJ3" >/dev/null || fail "vendor rollup mismatch"
jq -e '.vendors.claude.accounts[0].rotation.usable.general == true and .vendors.claude.daemon.reachable == true' "$PROJ3" >/dev/null || fail "rotation/daemon projection mismatch"
jq -e '.vendors.claude.accounts[0].five_hour.origin == "usage" and (.vendors.claude.accounts[0].auth.status == "ok")' "$PROJ3" >/dev/null || fail "account bucket/auth mismatch"
ok

echo "== projection always carries all three vendors (unobserved = unavailable) =="
jq -e '(.vendors | has("claude")) and (.vendors | has("codex")) and (.vendors | has("gemini"))' "$PROJ3" >/dev/null || fail "not all three vendor keys present"
jq -e '.vendors.codex.available == false and .vendors.gemini.available == false' "$PROJ3" >/dev/null || fail "unobserved vendor not marked unavailable"
ok

echo "== expired window projects effective_pct 0 =="
t=$(now)
POST "/observations" "{\"source\":\"claudeb\",\"vendor\":\"claude\",\"account\":\"gone\",\"scope\":\"window\",\"observed_at\":$t,\"payload\":{\"window\":\"five_hour\",\"used_pct\":88,\"resets_at\":$((t-100)),\"origin\":\"usage\"}}" >/dev/null
jq -e '.vendors.claude.accounts[] | select(.account=="gone") | .five_hour.expired == true and .five_hour.effective_pct == 0' "$PROJ3" >/dev/null || fail "expired window not projected as effective 0"
ok

echo "== byte-stable projection: identical ledger -> identical bytes across restart =="
before="$(shasum "$PROJ3" | awk '{print $1}')"
stop_daemon; start_daemon "$DB3" "$PROJ3" || fail "proj daemon restart"
after="$(shasum "$PROJ3" | awk '{print $1}')"
[ "$before" = "$after" ] || fail "projection not byte-stable across restart ($before != $after)"
ok

echo "== is_current is last-wins per vendor =="
DBc="$WORK/cur.sqlite"; PROJc="$WORK/cur.proj.json"
stop_daemon; start_daemon "$DBc" "$PROJc" || fail "current daemon boot"
t=$(now)
POST "/observations" "{\"source\":\"claudebd\",\"vendor\":\"claude\",\"account\":\"one\",\"scope\":\"rotation\",\"observed_at\":$t,\"payload\":{\"is_current\":true}}" >/dev/null
POST "/observations" "{\"source\":\"claudebd\",\"vendor\":\"claude\",\"account\":\"two\",\"scope\":\"rotation\",\"observed_at\":$((t+10)),\"payload\":{\"is_current\":true}}" >/dev/null
jq -e '.vendors.claude.current_account == "two"' "$PROJc" >/dev/null || fail "current_account not last-wins"
jq -e '[.vendors.claude.accounts[] | select(.is_current)] | length == 1 and (.[0].account == "two")' "$PROJc" >/dev/null || fail "is_current not cleared on the older account"
ok

echo "== malformed/unknown observations are rejected, not silently dropped =="
code="$(POST "/observations" "{\"source\":\"x\",\"vendor\":\"claude\",\"account\":\"z\",\"scope\":\"general\",\"observed_at\":$(now),\"payload\":{}}" | tail -1)"
[ "$code" = "400" ] || fail "unknown scope not rejected (http $code)"
code="$(POST "/observations" "{\"source\":\"x\",\"vendor\":\"claude\",\"account\":\"z\",\"scope\":\"auth\",\"observed_at\":$(now),\"payload\":{\"reason_code\":75}}" | tail -1)"
[ "$code" = "400" ] || fail "auth without verdict not rejected (http $code)"
code="$(POST "/observations" "{\"source\":\"x\",\"vendor\":\"claude\",\"account\":\"z\",\"scope\":\"window\",\"observed_at\":$(now),\"payload\":{\"origin\":\"usage\"}}" | tail -1)"
[ "$code" = "400" ] || fail "window without event/used_pct not rejected (http $code)"
[ "$(db_count "$DBc" observations)" = "2" ] || fail "a rejected observation was still persisted"
ok

echo "== oversized request body -> 413 =="
python3 -c 'open("'"$WORK"'/big.json","w").write("{\"scope\":\"auth\",\"blob\":\""+"x"*1100000+"\"}")'
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/observations" --data-binary @"$WORK/big.json")"
[ "$code" = "413" ] || fail "oversized body not rejected 413 (http $code)"
ok

echo "== daemon restart mid-run: run never vanishes, running step -> interrupted =="
DB4="$WORK/restart.sqlite"; PROJ4="$WORK/restart.proj.json"
stop_daemon; start_daemon "$DB4" "$PROJ4" || fail "restart daemon boot"
run="$(curl -s -X POST "$B/runs" -d '{"mode":"refresh","targets":[{"vendor":"claude","account":"r","phase":"probe"}]}')"
rid="$(printf '%s' "$run" | jqget 'print(d["run_id"])')"
POST "/runs/$rid/steps" '{"vendor":"claude","account":"r","phase":"probe","status":"running"}' >/dev/null
stop_daemon
start_daemon "$DB4" "$PROJ4" || fail "restart daemon reboot"
got="$(GET "/runs/$rid")"
[ "$(printf '%s' "$got" | jqget 'print(d.get("run_id"))')" = "$rid" ] || fail "run vanished across restart"
[ "$(printf '%s' "$got" | jqget 'print(d["steps"][0]["status"])')" = "interrupted" ] || fail "orphaned running step not interrupted"
[ "$(printf '%s' "$got" | jqget 'print(d["steps"][0]["reason_code"])')" = "87" ] || fail "interrupt reason_code not recorded"
[ "$(printf '%s' "$got" | jqget 'print(d["status"])')" = "interrupted" ] || fail "run not resolved to interrupted"
ok

echo "== concurrent POST /observations: count in == rows in db =="
DB5="$WORK/conc.sqlite"; PROJ5="$WORK/conc.proj.json"
stop_daemon; start_daemon "$DB5" "$PROJ5" || fail "conc daemon boot"
N=60; t=$(now)
pids=""
for i in $(seq 1 "$N"); do
  curl -s -X POST "$B/observations" \
    -d "{\"source\":\"load\",\"vendor\":\"claude\",\"account\":\"acc$((i % 5))\",\"scope\":\"window\",\"observed_at\":$((t+i)),\"payload\":{\"window\":\"five_hour\",\"used_pct\":$((i % 100)),\"origin\":\"usage\"}}" >/dev/null &
  pids="$pids $!"
done
for p in $pids; do wait "$p"; done
rows="$(db_count "$DB5" observations)"
[ "$rows" = "$N" ] || fail "lost observations under concurrency (in=$N rows=$rows)"
ok

echo "== db corrupt -> honest failure, no silent recreate =="
DB6="$WORK/corrupt.sqlite"; PROJ6="$WORK/corrupt.proj.json"
printf 'this is not a sqlite database at all, do not eat it\n' >"$DB6"
sig_before="$(shasum "$DB6" | awk '{print $1}')"
set +e
env LLM_LIMITSD_PORT=0 LLM_LIMITSD_DB="$DB6" LLM_LIMITSD_PROJECTION="$PROJ6" \
  "$DAEMON" >"$WORK/corrupt.out" 2>"$WORK/corrupt.err"
rc=$?
set -e 2>/dev/null || true
[ "$rc" = "78" ] || fail "corrupt db exit code not 78 (EXIT_DB_UNRECOVERABLE), got $rc"
grep -qi 'integrity' "$WORK/corrupt.err" || fail "corrupt db failure not reported honestly"
sig_after="$(shasum "$DB6" | awk '{print $1}')"
[ "$sig_before" = "$sig_after" ] || fail "corrupt db was silently rewritten"
ok

echo "== unknown run -> 404 =="
DB7="$WORK/x.sqlite"; PROJ7="$WORK/x.proj.json"
stop_daemon; start_daemon "$DB7" "$PROJ7" || fail "x daemon boot"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/runs/does-not-exist")" = "404" ] || fail "unknown run not 404"
ok

stop_daemon
echo "PASS: $asserts assertions"
