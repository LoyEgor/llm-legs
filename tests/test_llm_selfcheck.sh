#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
GEN_DPID=""
trap 'rm -rf "$WORK"; [ -n "$GEN_DPID" ] && kill "$GEN_DPID" 2>/dev/null; true' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  "$@" && fail "assert $asserts unexpectedly succeeded: $*"
  return 0
}
iso_from_epoch() {
  date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z'
}

FIXTURE="$WORK/repo"
HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
CALLS="$WORK/calls"
ALERTS="$WORK/alerts"
LAUNCH_CALLS="$WORK/launch-calls"
export HOME CALLS ALERTS LAUNCH_CALLS
mkdir -p "$FIXTURE/bin" "$FIXTURE/tests" "$FAKE_BIN"
cp "$ROOT/bin/llm-selfcheck" "$FIXTURE/bin/llm-selfcheck"
cp "$ROOT/bin/llm-shadow-divergence" "$FIXTURE/bin/llm-shadow-divergence"
chmod +x "$FIXTURE/bin/llm-selfcheck" "$FIXTURE/bin/llm-shadow-divergence"

for suite in e2e_surfaces.sh test_llm_limits.sh test_claudeb.sh test_claudebd.sh test_codexb.sh test_claudebd_live.sh; do
  cat >"$FIXTURE/tests/$suite" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
printf '%s\n' "$name" >>"$CALLS"
[ "${FAIL_STEP:-}" != "$name" ]
EOF
done

cat >"$FAKE_BIN/hs" <<'EOF'
#!/usr/bin/env bash
printf 'hs %s\n' "$*" >>"$ALERTS"
EOF
cat >"$FAKE_BIN/osascript" <<'EOF'
#!/usr/bin/env bash
printf 'osascript %s\n' "$*" >>"$ALERTS"
EOF
cat >"$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LAUNCH_CALLS"
[ "${1:-}" != print ] && exit 0
case "$*" in
  *com.llm-limitsd-shadow-feed*) exit "${SHADOW_FEED_JOB_LOADED_RC:-0}" ;;
esac
exit 1
EOF
chmod +x "$FAKE_BIN/hs" "$FAKE_BIN/osascript" "$FAKE_BIN/launchctl"
PATH="$FAKE_BIN:$PATH"
export PATH

SCRIPT="$FIXTURE/bin/llm-selfcheck"
LOG="$HOME/.claude-profiles/.claudeb/selfcheck.log"
REAL="$HOME/.llm-limits.json"
SHADOW="$HOME/.llm-limits-shadow.json"
NOW=$(date '+%s')
FETCHED=$(date -u -r "$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')

write_caches() {
  local real_pct="${1:-12}" shadow_pct="${2:-12}" shadow_epoch="${3:-$NOW}"
  local shadow_fetched
  shadow_fetched=$(date -u -r "$shadow_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$shadow_epoch" '+%Y-%m-%dT%H:%M:%SZ')
  mkdir -p "$HOME"
  jq -n --arg fetched "$FETCHED" --argjson pct "$real_pct" '{
    schema: 1, fetched_at: $fetched,
    vendors: {
      claude: {
        five_hour: {used_pct: $pct, resets_at: "2026-07-19T12:00:00Z"},
        accounts: [{
          account: "alona", is_current: true,
          five_hour: {used_pct: $pct, resets_at: "2026-07-19T12:00:00Z"},
          weekly: {used_pct: 40, resets_at: "2026-07-25T12:00:00Z"}
        }]
      }
    }
  }' >"$REAL"
  jq -n --arg fetched "$shadow_fetched" --argjson pct "$shadow_pct" '{
    schema: 1, fetched_at: $fetched,
    vendors: {
      claude: {
        five_hour: {used_pct: $pct, resets_at: "2026-07-19T12:00:00Z"},
        accounts: [{
          account: "alona", is_current: true,
          five_hour: {used_pct: $pct, resets_at: "2026-07-19T12:00:00Z"},
          weekly: {used_pct: 40, resets_at: "2026-07-25T12:00:00Z"}
        }]
      }
    }
  }' >"$SHADOW"
}

write_caches
bash "$SCRIPT" || fail "successful run failed"
assert test "$(paste -sd, "$CALLS")" = "e2e_surfaces.sh,test_llm_limits.sh,test_claudeb.sh,test_claudebd.sh,test_codexb.sh"
assert_fails grep -q test_claudebd_live.sh "$CALLS"
assert grep -Eq '^timestamp=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} status=PASS failed_step=-$' "$LOG"
assert grep -q 'status=PASS step=shadow-divergence detail=shadow-divergence: match' "$LOG"
assert test ! -s "$ALERTS"

write_caches 12 13
: >"$ALERTS"
asserts=$((asserts + 1))
bash "$SCRIPT" run --force >/dev/null 2>&1 && fail "value drift unexpectedly passed"
assert tail -n 2 "$LOG" | grep -q 'status=FAIL step=shadow-divergence'
assert grep -q 'vendors.claude.accounts.alona.five_hour.used_pct' "$LOG"
assert grep -q 'vendors.claude.accounts.alona.five_hour.used_pct' "$ALERTS"

rm -f "$SHADOW"
: >"$ALERTS"
bash "$SCRIPT" run --force || fail "absent shadow should skip"
assert tail -n 2 "$LOG" | grep -q 'status=SKIP step=shadow-divergence.*shadow projection absent'
assert test ! -s "$ALERTS"

write_caches 12 12 "$((NOW - 901))"
: >"$ALERTS"
asserts=$((asserts + 1))
bash "$SCRIPT" run --force >/dev/null 2>&1 && fail "stalled feeder unexpectedly passed"
assert tail -n 2 "$LOG" | grep -q 'status=FAIL step=shadow-divergence.*feeder stalled'
assert grep -q 'feeder stalled' "$ALERTS"

# A stale shadow with the feeder job unloaded (trial disabled) is a silent skip, not a stall.
write_caches 12 12 "$((NOW - 901))"
: >"$ALERTS"
SHADOW_FEED_JOB_LOADED_RC=1 bash "$SCRIPT" run --force || fail "trial-disabled stall should skip, not fail"
assert tail -n 2 "$LOG" | grep -q 'status=SKIP step=shadow-divergence.*feeder job not loaded'
assert test ! -s "$ALERTS"

# A genuine llm-limitsd projection (real daemon + shadow feeder), not a hand-written twin: the
# comparator must accept it when faithful and reject it once the real cache is value-mutated.
echo "== comparator vs a genuine llm-limitsd projection =="
GEN_DB="$WORK/gen.sqlite"; GEN_PROJ="$WORK/gen.proj.json"
GEN_REAL="$WORK/gen.real.json"; GEN_STATE="$WORK/gen.feed.state"; GEN_ERR="$WORK/gen.daemon.err"
GNOW=$(date '+%s')
GFETCHED=$(date -u -r "$GNOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$GNOW" '+%Y-%m-%dT%H:%M:%SZ')
GRESET=$(date -u -r "$((GNOW + 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$((GNOW + 3600))" '+%Y-%m-%dT%H:%M:%SZ')
GWRESET=$(date -u -r "$((GNOW + 7200))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$((GNOW + 7200))" '+%Y-%m-%dT%H:%M:%SZ')
jq -n --arg fetched "$GFETCHED" --arg r5 "$GRESET" --arg rw "$GWRESET" --argjson now "$GNOW" '{
  schema: 1, fetched_at: $fetched,
  vendors: {
    gemini: {
      available: true, source: "agy-local-rpc", as_of: $fetched,
      five_hour: {used_pct: 3, resets_at: $r5, as_of: $now, origin: "usage"},
      weekly: {used_pct: 61, resets_at: $rw, as_of: $now, origin: "usage"}
    }
  }
}' >"$GEN_REAL"

env LLM_LIMITSD_PORT=0 LLM_LIMITSD_DB="$GEN_DB" LLM_LIMITSD_PROJECTION="$GEN_PROJ" \
  "$ROOT/bin/llm-limitsd" 2>"$GEN_ERR" &
GEN_DPID=$!
GEN_PORT=""
for _ in $(seq 1 200); do
  GEN_PORT="$(sed -n 's/.*127.0.0.1:\([0-9]*\).*/\1/p' "$GEN_ERR" 2>/dev/null | head -1)"
  [ -n "$GEN_PORT" ] && break
  kill -0 "$GEN_DPID" 2>/dev/null || break
  perl -e 'select(undef,undef,undef,0.02)'
done
[ -n "$GEN_PORT" ] || { cat "$GEN_ERR" >&2; fail "genuine daemon never announced a port"; }
[ "$GEN_PORT" = "45789" ] && fail "refusing data-plane port 45789"

env LLM_LIMITS_CACHE="$GEN_REAL" LLM_LIMITSD_URL="http://127.0.0.1:$GEN_PORT" LLM_SHADOW_FEED_STATE="$GEN_STATE" \
  "$ROOT/bin/llm-limitsd-shadow-feed" || fail "shadow feed into genuine daemon failed"
assert test -f "$GEN_PROJ"
assert env LLM_LIMITS_CACHE="$GEN_REAL" LLM_LIMITSD_PROJECTION="$GEN_PROJ" "$FIXTURE/bin/llm-shadow-divergence"

jq '.vendors.gemini.five_hour.used_pct = 99' "$GEN_REAL" >"$GEN_REAL.mut" && mv "$GEN_REAL.mut" "$GEN_REAL"
assert_fails env LLM_LIMITS_CACHE="$GEN_REAL" LLM_LIMITSD_PROJECTION="$GEN_PROJ" "$FIXTURE/bin/llm-shadow-divergence"
kill "$GEN_DPID" 2>/dev/null; GEN_DPID=""

write_caches
: >"$CALLS"
: >"$ALERTS"
FAIL_STEP=test_claudeb.sh bash "$SCRIPT" run --force >/dev/null 2>&1 && fail "failing run succeeded"
assert test "$(paste -sd, "$CALLS")" = "e2e_surfaces.sh,test_llm_limits.sh,test_claudeb.sh"
assert tail -n 1 "$LOG" | grep -Eq ' status=FAIL failed_step=test_claudeb.sh$'
assert grep -q '^hs .*hs.alert.show.*test_claudeb.sh' "$ALERTS"
assert grep -q '^osascript .*display notification .*test_claudeb.sh' "$ALERTS"

for _ in $(seq 1 65); do
  bash "$SCRIPT" run --force || fail "trimming run failed"
done
assert test "$(wc -l <"$LOG" | tr -d ' ')" = 60

printf 'timestamp=%s status=PASS failed_step=-\n' "$(iso_from_epoch $((NOW - 60)))" >"$LOG"
FRESH_LOG_CONTENT=$(cat "$LOG")
: >"$CALLS"
: >"$ALERTS"
bash "$SCRIPT" || fail "fresh-log bare invocation should exit 0"
assert test ! -s "$CALLS"
assert test ! -s "$ALERTS"
assert test "$(cat "$LOG")" = "$FRESH_LOG_CONTENT"

printf 'timestamp=%s status=PASS failed_step=-\n' "$(iso_from_epoch $((NOW - 22 * 3600)))" >"$LOG"
: >"$CALLS"
bash "$SCRIPT" || fail "catch-up bare invocation failed"
assert test "$(paste -sd, "$CALLS")" = "e2e_surfaces.sh,test_llm_limits.sh,test_claudeb.sh,test_claudebd.sh,test_codexb.sh"
assert test ! -s "$ALERTS"

printf 'timestamp=%s status=PASS failed_step=-\n' "$(iso_from_epoch $((NOW - 30 * 3600)))" >"$LOG"
: >"$CALLS"
: >"$ALERTS"
bash "$SCRIPT" || fail "stale bare invocation failed"
assert test "$(paste -sd, "$CALLS")" = "e2e_surfaces.sh,test_llm_limits.sh,test_claudeb.sh,test_claudebd.sh,test_codexb.sh"
assert grep -q 'stale since' "$ALERTS"

rm -f "$HOME/.claude-profiles/.claudeb/selfcheck.state"
(
  cd "$FIXTURE" || exit 1
  source "$SCRIPT"
  printf 'timestamp=%s status=PASS failed_step=-\n' "$(iso_from_epoch $((NOW - 40 * 3600)))" >"$LOG"
  : >"$ALERTS"
  stale_epoch=$(last_run_epoch)
  alert_stale "$stale_epoch"
  alert_stale "$stale_epoch"
)
assert test "$(grep -c 'stale since' "$ALERTS")" = 2

bash "$SCRIPT" install >/dev/null || fail "install failed"
PLIST="$HOME/Library/LaunchAgents/com.llm-legs.selfcheck.plist"
assert test -L "$HOME/.local/bin/llm-selfcheck"
assert test "$(readlink "$HOME/.local/bin/llm-selfcheck")" = "$SCRIPT"
assert grep -q '<string>com.llm-legs.selfcheck</string>' "$PLIST"
assert grep -A2 -q '<key>Hour</key>' "$PLIST"
assert grep -A1 -q '<integer>10</integer>' "$PLIST"
assert grep -A1 -q '<integer>30</integer>' "$PLIST"
assert grep -A1 -q '<key>StartInterval</key>' "$PLIST"
assert grep -A1 '<key>StartInterval</key>' "$PLIST" | grep -q '<integer>3600</integer>'
assert grep -A1 -q '<key>RunAtLoad</key>' "$PLIST"
assert grep -A1 '<key>RunAtLoad</key>' "$PLIST" | grep -q '<true/>'
assert grep -q "$HOME/.claude-profiles/.claudeb/selfcheck.stdout.log" "$PLIST"
assert grep -q '^bootout gui/' "$LAUNCH_CALLS"
assert grep -q '^bootstrap gui/' "$LAUNCH_CALLS"

bash "$SCRIPT" uninstall >/dev/null || fail "uninstall failed"
assert test ! -e "$PLIST"
assert test ! -L "$HOME/.local/bin/llm-selfcheck"

echo "PASS: $asserts asserts; shadow divergence, ordered suites and skip list, log format and trimming, failure alerts, debounce/catch-up/stale-alert dedup, install and uninstall plist"
