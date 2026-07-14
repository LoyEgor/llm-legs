#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/claudeb"
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

HOME="$WORK/home"
CLAUDEB_DIR="$WORK/store"
FAKE_BIN="$WORK/bin"
export HOME CLAUDEB_DIR
mkdir -p "$HOME" "$CLAUDEB_DIR/limits" "$CLAUDEB_DIR/tokens" "$FAKE_BIN"
for command in curl security claude; do
  printf '#!/usr/bin/env bash\nexit 97\n' >"$FAKE_BIN/$command"
  chmod +x "$FAKE_BIN/$command"
done
PATH="$FAKE_BIN:$PATH"
export PATH

source "$SCRIPT"

now=$(date +%s)
short_epoch=$((now + 3600))
week_epoch=$((now + 172800))
date_epoch=$((now + 691200))
weekdays=(Sun Mon Tue Wed Thu Fri Sat)
weekday_number=$(date -r "$week_epoch" '+%w' 2>/dev/null || date -d "@$week_epoch" '+%w')
assert test "$(format_reset_time "$short_epoch")" = "$(date -r "$short_epoch" '+%H:%M' 2>/dev/null || date -d "@$short_epoch" '+%H:%M')"
assert test "$(format_reset_time "$week_epoch")" = "${weekdays[$weekday_number]} $(date -r "$week_epoch" '+%H:%M' 2>/dev/null || date -d "@$week_epoch" '+%H:%M')"
assert test "$(format_reset_time "$date_epoch")" = "$(date -r "$date_epoch" '+%m-%d %H:%M' 2>/dev/null || date -d "@$date_epoch" '+%m-%d %H:%M')"
assert test "$(format_reset_time null)" = unknown
assert test "$(format_reset_time '')" = unknown

usage="$WORK/usage.json"
cat >"$usage" <<'EOF'
{"five_hour":{"utilization":12.4,"resets_at":null},"seven_day":{"utilization":45.6,"resets_at":null},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":78.2,"resets_at":null}]}
EOF
assert merge_usage alpha "$usage"
snapshot="$CLAUDEB_DIR/limits/alpha.json"
assert jq -e '.five_hour.resets_at == 0 and .seven_day.resets_at == 0 and .fable.resets_at == 0' "$snapshot" >/dev/null
assert jq -e '.five_hour.used_percentage == 12 and .seven_day.used_percentage == 46 and .fable.used_percentage == 78' "$snapshot" >/dev/null
assert jq -e 'all(.five_hour,.seven_day,.fable; (.as_of | type) == "number" and .origin == "usage")' "$snapshot" >/dev/null
assert jq -e '.auth.status == "ok" and (.auth.checked_at | type) == "number"' "$snapshot" >/dev/null

cached_as_of=$((now - 60))
cat >"$snapshot" <<EOF
{"fable":{"used_percentage":31,"resets_at":$((now + 3600)),"as_of":$cached_as_of,"origin":"usage"}}
EOF
cat >"$usage" <<EOF
{"five_hour":{"utilization":1,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null},"limits":[]}
EOF
assert merge_usage alpha "$usage"
assert jq -e --argjson as_of "$cached_as_of" '.fable.used_percentage == 31 and .fable.as_of == $as_of and .fable.origin == "cached"' "$snapshot" >/dev/null
assert jq -e '[.five_hour.origin,.seven_day.origin,.fable.origin] | all(. == "usage" or . == "headers" or . == "cached")' "$snapshot" >/dev/null

now=$(date +%s)
printf '{"alpha":{"attempted_at":%s,"outcome":"failed","retry_after_until":0}}\n' "$now" >"$oauth_attempts_file"
until=$(oauth_backoff_until alpha)
assert test "$until" -ge "$((now + 899))"
assert test "$until" -le "$((now + 900))"
printf '{"alpha":{"attempted_at":%s,"outcome":"429","retry_after_until":%s}}\n' "$now" "$((now + 1800))" >"$oauth_attempts_file"
assert test "$(oauth_backoff_until alpha)" = "$((now + 1800))"
printf '{"alpha":{"attempted_at":%s,"outcome":"warming","retry_after_until":0}}\n' "$((now - 179))" >"$oauth_attempts_file"
assert test "$(oauth_backoff_until alpha)" -gt "$now"
printf '{"alpha":{"attempted_at":%s,"outcome":"warming","retry_after_until":0}}\n' "$((now - 181))" >"$oauth_attempts_file"
assert test "$(oauth_backoff_until alpha)" = 0

export CLAUDEB_LOCK_RETRIES=1 CLAUDEB_LOCK_DELAY=0
printf '{"seed":{"attempted_at":1,"outcome":"failed","retry_after_until":0}}\n' >"$oauth_attempts_file"
mkdir "$oauth_attempts_file.lock"
touch -t 202001010000 "$oauth_attempts_file.lock"
assert oauth_attempt_update alpha failed 0
assert test ! -d "$oauth_attempts_file.lock"
assert jq -e '.alpha.outcome == "failed"' "$oauth_attempts_file" >/dev/null
mkdir "$oauth_attempts_file.lock"
assert oauth_attempt_update beta failed 0
assert test -d "$oauth_attempts_file.lock"
assert jq -e 'has("beta") | not' "$oauth_attempts_file" >/dev/null
rm -rf "$oauth_attempts_file.lock"
mkdir "$oauth_attempts_file.lock"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN/stat"
chmod +x "$FAKE_BIN/stat"
assert oauth_attempt_update gamma failed 0
assert test -d "$oauth_attempts_file.lock"
assert jq -e 'has("gamma") | not' "$oauth_attempts_file" >/dev/null
rm -f "$FAKE_BIN/stat"
rm -rf "$oauth_attempts_file.lock"
assert oauth_attempt_update alpha failed 0
assert test ! -d "$oauth_attempts_file.lock"
unset CLAUDEB_LOCK_RETRIES CLAUDEB_LOCK_DELAY

if HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" bash "$SCRIPT" add warm </dev/null >/dev/null 2>&1; then
  fail "add accepted reserved account name warm"
fi
assert test ! -e "$CLAUDEB_DIR/tokens/warm"

touch "$CLAUDEB_DIR/tokens/alpha" "$CLAUDEB_DIR/tokens/beta"
future=$((now + 7200))
printf '{"five_hour":{"used_percentage":80,"resets_at":%s}}\n' "$future" >"$CLAUDEB_DIR/limits/alpha.json"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$future" >"$CLAUDEB_DIR/limits/beta.json"
printf 'alpha\n' >"$state_file"
printf 'alpha\n' >"$disabled_file"
touch -t 202607120101 "$state_file"
touch -t 202607120102 "$disabled_file"
assert test "$(selection | jq -r .picked)" = beta
touch -t 202607120103 "$state_file"
assert test "$(selection | jq -r .picked)" = alpha

# An out-of-rotation (disabled) account launched via `profile` PROCEEDS direct:
# prints the informational note and execs with the profile's own creds, with the
# leaked proxy base URL and injected rotating token stripped.
touch "$CLAUDEB_DIR/tokens/gamma"
printf 'gamma\n' >"$disabled_file"
ENV_DUMP="$WORK/gamma-env.txt"
cat >"$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
env > "$ENV_DUMP"
exit 0
EOF
chmod +x "$FAKE_BIN/claude"
# Subshell so profile_command's exec replaces the subshell, not the test runner;
# proxy-session leaks are set to prove they get stripped from the direct launch.
note=$( ANTHROPIC_BASE_URL="http://127.0.0.1:45789" CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-leak" \
  profile_command gamma 2>&1 >/dev/null )
assert grep -q 'out of rotation' <<<"$note"
assert test -f "$ENV_DUMP"
assert_fails grep -q '^ANTHROPIC_BASE_URL=' "$ENV_DUMP"
assert_fails grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$ENV_DUMP"
assert grep -qx "CLAUDE_LIMITS_ACCOUNT=gamma" "$ENV_DUMP"
assert grep -qx "CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/gamma" "$ENV_DUMP"
for command in curl security claude; do
  printf '#!/usr/bin/env bash\nexit 97\n' >"$FAKE_BIN/$command"
  chmod +x "$FAKE_BIN/$command"
done

# --- generic lock: contention, release, stale retake ---
export CLAUDEB_LOCK_RETRIES=1 CLAUDEB_LOCK_DELAY=0
lockdir="$WORK/mylock"
assert lock_acquire "$lockdir"
assert test -d "$lockdir"
assert_fails lock_acquire "$lockdir"
lock_release "$lockdir"
assert test ! -d "$lockdir"
mkdir "$lockdir"
touch -t 202001010000 "$lockdir"
assert lock_acquire "$lockdir"
lock_release "$lockdir"
unset CLAUDEB_LOCK_RETRIES CLAUDEB_LOCK_DELAY

# --- heal backoff: revoked blocks ~6h, warm-failed 30m, token-endpoint 429 never gates heal ---
now=$(date +%s)
printf '{"alpha":{"attempted_at":%s,"outcome":"revoked","retry_after_until":0}}\n' "$now" >"$oauth_attempts_file"
assert test "$(oauth_heal_backoff_until alpha)" -gt "$now"
printf '{"alpha":{"attempted_at":%s,"outcome":"revoked","retry_after_until":0}}\n' "$((now - 21601))" >"$oauth_attempts_file"
assert test "$(oauth_heal_backoff_until alpha)" = 0
printf '{"alpha":{"attempted_at":%s,"outcome":"warm-failed","retry_after_until":0}}\n' "$now" >"$oauth_attempts_file"
assert test "$(oauth_heal_backoff_until alpha)" -gt "$now"
printf '{"alpha":{"attempted_at":%s,"outcome":"429","retry_after_until":%s}}\n' "$now" "$((now + 9999))" >"$oauth_attempts_file"
assert test "$(oauth_heal_backoff_until alpha)" = 0

# --- oauth_refresh: single-use refresh token races and revocation ---
creds='{"claudeAiOauth":{"refreshToken":"rt-old","accessToken":"at","scopes":["a"]}}'
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$creds'
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"error":"invalid_grant"}\n400'
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/curl"
printf '{}' >"$oauth_attempts_file"
if got=$(oauth_refresh alpha svc "$creds"); then rc=0; else rc=$?; fi
assert test "$rc" -ne 0
assert test "$(oauth_backoff_outcome alpha)" = revoked
assert test ! -d "$oauth_attempts_file.rl.alpha"

# a concurrent holder of the per-account refresh lock: adopt their fresher token,
# never POST the already-consumed one, never release the lock we do not own.
export CLAUDEB_LOCK_RETRIES=1 CLAUDEB_LOCK_DELAY=0
newcreds='{"claudeAiOauth":{"refreshToken":"rt-new","accessToken":"at2"}}'
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$newcreds'
EOF
mkdir "$oauth_attempts_file.rl.alpha"
printf '{}' >"$oauth_attempts_file"
if got=$(oauth_refresh alpha svc "$creds"); then rc=0; else rc=$?; fi
assert test "$rc" -eq 0
assert test "$got" = "$newcreds"
assert test -d "$oauth_attempts_file.rl.alpha"
rmdir "$oauth_attempts_file.rl.alpha"
unset CLAUDEB_LOCK_RETRIES CLAUDEB_LOCK_DELAY
for command in curl security claude; do
  printf '#!/usr/bin/env bash\nexit 97\n' >"$FAKE_BIN/$command"
  chmod +x "$FAKE_BIN/$command"
done

# --- heal_expired: heals disabled accounts too; per-account actionable causes ---
warm_accounts() {
  case "$1" in
    alpha) return 0 ;;
    beta) echo "beta: failed (token endpoint still 429)"; return 1 ;;
    *) echo "$1: failed (session exit 1)"; return 1 ;;
  esac
}
account_names() { printf 'alpha\nbeta\ngamma\ndelta\n'; }
heal_dir="$WORK/heal"
mkdir -p "$heal_dir"
for n in alpha beta gamma delta; do printf 'auth!\n' >"$heal_dir/$n.display"; printf '{}' >"$limits_dir/$n.json"; done
printf 'alpha\n' >"$disabled_file"
now=$(date +%s)
printf '{"delta":{"attempted_at":%s,"outcome":"revoked","retry_after_until":0}}\n' "$now" >"$oauth_attempts_file"
heal_expired "$heal_dir"
assert test "$(cat "$heal_dir/alpha.display")" = live
assert test "$(jq -r '.auth.cause' "$limits_dir/beta.json")" = 'warm 429'
assert test "$(jq -r '.auth.cause' "$limits_dir/gamma.json")" = 'warm failed'
assert test "$(jq -r '.auth.cause' "$limits_dir/delta.json")" = 'needs re-login'

echo "PASS: $asserts asserts; reset tiers and empty input, null-safe usage merges, snapshot provenance and auth, OAuth backoff and lock behavior, reserved names, disabled-account timeline, out-of-rotation profile launch proceeds direct (proxy leaks stripped), generic lock contention/stale-retake, heal backoff (revoked 6h, warm-failed 30m, token-429 never gates), oauth_refresh revocation and lock-race adoption, heal_expired covers disabled accounts with per-account causes"
