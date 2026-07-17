#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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
chmod +x "$FIXTURE/bin/llm-selfcheck"

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
[ "${1:-}" != print ]
EOF
chmod +x "$FAKE_BIN/hs" "$FAKE_BIN/osascript" "$FAKE_BIN/launchctl"
PATH="$FAKE_BIN:$PATH"
export PATH

SCRIPT="$FIXTURE/bin/llm-selfcheck"
LOG="$HOME/.claude-profiles/.claudeb/selfcheck.log"

bash "$SCRIPT" || fail "successful run failed"
assert test "$(paste -sd, "$CALLS")" = "e2e_surfaces.sh,test_llm_limits.sh,test_claudeb.sh,test_claudebd.sh,test_codexb.sh"
assert_fails grep -q test_claudebd_live.sh "$CALLS"
assert grep -Eq '^timestamp=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} status=PASS failed_step=-$' "$LOG"
assert test ! -s "$ALERTS"

: >"$CALLS"
FAIL_STEP=test_claudeb.sh bash "$SCRIPT" run --force >/dev/null 2>&1 && fail "failing run succeeded"
assert test "$(paste -sd, "$CALLS")" = "e2e_surfaces.sh,test_llm_limits.sh,test_claudeb.sh"
assert tail -n 1 "$LOG" | grep -Eq ' status=FAIL failed_step=test_claudeb.sh$'
assert grep -q '^hs .*hs.alert.show.*test_claudeb.sh' "$ALERTS"
assert grep -q '^osascript .*display notification .*test_claudeb.sh' "$ALERTS"

for _ in $(seq 1 65); do
  bash "$SCRIPT" run --force || fail "trimming run failed"
done
assert test "$(wc -l <"$LOG" | tr -d ' ')" = 60

NOW=$(date '+%s')
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

echo "PASS: $asserts asserts; ordered suites and skip list, log format and trimming, failure alerts, debounce/catch-up/stale-alert dedup, install and uninstall plist"
