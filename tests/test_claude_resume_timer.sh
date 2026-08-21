#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/claude-resume-timer"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

FAKE_BIN="$WORK/bin"
FIXTURE_HOME="$WORK/home"
CALLS="$WORK/calls"
mkdir -p "$FAKE_BIN" "$FIXTURE_HOME"

cat >"$FAKE_BIN/hs" <<'EOF'
#!/usr/bin/env bash
printf 'HS %s\n' "$*" >>"$CALLS"
exit 0
EOF
chmod +x "$FAKE_BIN/hs"

cat >"$FAKE_BIN/llm-limits" <<'EOF'
#!/usr/bin/env bash
printf 'LLM_LIMITS %s\n' "$*" >>"$CALLS"
exit 0
EOF
chmod +x "$FAKE_BIN/llm-limits"

write_limits() {
  local account="$1" resets_at="$2"
  cat >"$FIXTURE_HOME/.llm-limits.json" <<EOF
{"vendors":{"claude":{"accounts":[{"account":"$account","five_hour":{"resets_at":"$resets_at"}}]}}}
EOF
}

run_timer() {
  : >"$CALLS"
  PATH="$FAKE_BIN:$PATH" HOME="$FIXTURE_HOME" CALLS="$CALLS" "$@"
}

now=$(date +%s)

# --- surface auto-detection ---

write_limits notcom "$(date -u -r "$((now + 6000))" +%Y-%m-%dT%H:%M:%SZ)"

out=$(run_timer env -u TERM_PROGRAM CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" auto 10) \
  || fail "auto (no TERM_PROGRAM) exited non-zero"
grep -q 'HS -q -c ClaudeContinue.startTimerFor("app", ' "$CALLS" || fail "auto without TERM_PROGRAM should target app: $(cat "$CALLS")"

out=$(run_timer env TERM_PROGRAM=iTerm.app CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" auto 10) \
  || fail "auto (TERM_PROGRAM set) exited non-zero"
grep -q 'HS -q -c ClaudeContinue.startTimerFor("terminal", ' "$CALLS" || fail "auto with TERM_PROGRAM should target terminal: $(cat "$CALLS")"

out=$(run_timer env TERM_PROGRAM= CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" auto 10) \
  || fail "auto (TERM_PROGRAM set but empty) exited non-zero"
grep -q 'HS -q -c ClaudeContinue.startTimerFor("terminal", ' "$CALLS" || fail "auto with empty-but-set TERM_PROGRAM should still target terminal: $(cat "$CALLS")"

# --- account resolution order ---

write_limits notcom "$(date -u -r "$((now + 6000))" +%Y-%m-%dT%H:%M:%SZ)"
# +30s buffer on every fixture below: the script fetches its own "now" a few seconds
# after $now was captured here, so exact-minute assertions need slack against that drift.
write_limits_other() {
  cat >"$FIXTURE_HOME/.llm-limits.json" <<EOF
{"vendors":{"claude":{"accounts":[
  {"account":"notcom","five_hour":{"resets_at":"$(date -u -r "$((now + 1200 + 30))" +%Y-%m-%dT%H:%M:%SZ)"}},
  {"account":"alona","five_hour":{"resets_at":"$(date -u -r "$((now + 9000 + 30))" +%Y-%m-%dT%H:%M:%SZ)"}}
]}}}
EOF
}
write_limits_other

out=$(run_timer env -u CLAUDE_LIMITS_ACCOUNT "$SCRIPT" terminal 0) || fail "default-account run failed"
minutes=$(echo "$out" | grep -oE 'for [0-9]+ min' | grep -oE '[0-9]+')
[ "$minutes" = "20" ] || fail "no CLAUDE_LIMITS_ACCOUNT should default to notcom (expected 20, got $minutes): $out"

out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=alona "$SCRIPT" terminal 0) || fail "explicit-account run failed"
minutes=$(echo "$out" | grep -oE 'for [0-9]+ min' | grep -oE '[0-9]+')
[ "$minutes" = "150" ] || fail "CLAUDE_LIMITS_ACCOUNT=alona should use alona's resets_at (expected 150, got $minutes): $out"

out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=- "$SCRIPT" terminal 0) || fail "'-' sentinel run failed"
minutes=$(echo "$out" | grep -oE 'for [0-9]+ min' | grep -oE '[0-9]+')
[ "$minutes" = "20" ] || fail "CLAUDE_LIMITS_ACCOUNT=- should fall back to notcom like unset (expected 20, got $minutes): $out"

# --- expired / missing window fallback ---

write_limits notcom "1970-01-01T03:00:00+02:00"
out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app 0) || fail "expired-window run failed"
echo "$out" | grep -q "already reset" || fail "expired window should report fallback reason: $out"
echo "$out" | grep -q '+15 min' || fail "expired window should arm for +15 min: $out"
grep -q 'HS -q -c ClaudeContinue.startTimerFor("app", 15)' "$CALLS" || fail "expired window should call startTimerFor with 15: $(cat "$CALLS")"

rm -f "$FIXTURE_HOME/.llm-limits.json"
out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app 0) || fail "missing-cache run failed"
echo "$out" | grep -q "no five_hour.resets_at" || fail "missing cache file should report fallback reason: $out"
grep -q 'HS -q -c ClaudeContinue.startTimerFor("app", 15)' "$CALLS" || fail "missing cache should arm for 15: $(cat "$CALLS")"

write_limits unknown-account "$(date -u -r "$((now + 6000))" +%Y-%m-%dT%H:%M:%SZ)"
out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app 0) || fail "account-not-in-fixture run failed"
echo "$out" | grep -q "no five_hour.resets_at" || fail "account absent from fixture should report fallback reason: $out"

# --- minutes math, including +extra and the 1-minute floor ---
# +30s buffer on the reset fixtures below guards the exact-minute assertions against
# drift between capturing $now here and the script fetching its own "now" moments later.

write_limits notcom "$(date -u -r "$((now + 3600 + 30))" +%Y-%m-%dT%H:%M:%SZ)"
out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app 0) || fail "60min-window run failed"
minutes=$(echo "$out" | grep -oE 'for [0-9]+ min' | grep -oE '[0-9]+')
[ "$minutes" = "60" ] || fail "60 minutes to reset + 0 extra should be 60 (got $minutes): $out"

out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app 25) || fail "60min-window+extra run failed"
minutes=$(echo "$out" | grep -oE 'for [0-9]+ min' | grep -oE '[0-9]+')
[ "$minutes" = "85" ] || fail "60 minutes to reset + 25 extra should be 85 (got $minutes): $out"

write_limits notcom "$(date -u -r "$((now + 300))" +%Y-%m-%dT%H:%M:%SZ)"
out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app -310) || fail "floor-clamped run failed"
minutes=$(echo "$out" | grep -oE 'for [0-9]+ min' | grep -oE '[0-9]+')
[ "$minutes" = "1" ] || fail "a negative net result should floor at 1 minute (got $minutes): $out"

# --- default extra-minutes is +10 ---

write_limits notcom "$(date -u -r "$((now + 1200 + 30))" +%Y-%m-%dT%H:%M:%SZ)"
out=$(run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app) || fail "default-extra run failed"
minutes=$(echo "$out" | grep -oE 'for [0-9]+ min' | grep -oE '[0-9]+')
[ "$minutes" = "30" ] || fail "default extra should be +10 (20 to reset + 10 = 30, got $minutes): $out"

# --- refresh gate: the collector's own staleness verdict, not this script's arithmetic ---

write_limits_bucket() { # stale age-seconds
  cat >"$FIXTURE_HOME/.llm-limits.json" <<EOF
{"vendors":{"claude":{"accounts":[{"account":"notcom","five_hour":{
  "resets_at":"$(date -u -r "$((now + 1200 + 30))" +%Y-%m-%dT%H:%M:%SZ)",
  "as_of":$((now - $2)),"stale":$1}}]}}}
EOF
}

write_limits_bucket false 60
run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app 0 >/dev/null || fail "fresh-row run failed"
grep -q 'LLM_LIMITS --refresh' "$CALLS" && fail "a row the collector calls fresh must not be refreshed: $(cat "$CALLS")"

write_limits_bucket false 3600
run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app 0 >/dev/null || fail "aged-row run failed"
grep -q 'LLM_LIMITS --refresh' "$CALLS" || fail "a row past the five-hour threshold must be refreshed: $(cat "$CALLS")"

# The flag is written at collection time and cannot age, so it is asked as well as the clock: a
# minutes-old row the collector marked stale (expired auth, cached origin) is not one to arm off.
write_limits_bucket true 60
run_timer env CLAUDE_LIMITS_ACCOUNT=notcom "$SCRIPT" app 0 >/dev/null || fail "stale-marked-row run failed"
grep -q 'LLM_LIMITS --refresh' "$CALLS" || fail "a row the collector marked stale must be refreshed: $(cat "$CALLS")"

# --- hs unreachable ---

out=$(PATH="/usr/bin:/bin" HOME="$FIXTURE_HOME" "$SCRIPT" app 0 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "should exit non-zero when hs is not on PATH"
echo "$out" | grep -qi "hs" || fail "should mention hs in the error: $out"

# --- bad surface argument ---

run_timer "$SCRIPT" spaceship 0 >/dev/null 2>&1
status=$?
[ "$status" -eq 2 ] || fail "invalid surface should exit 2 (got $status)"

echo "PASS: all claude-resume-timer checks passed"
