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
CLAUDEB_WARM_RETRY_DELAY=0
CLAUDEB_OAUTH_TOKEN_SPACING=0
CLAUDEB_WEATHER_RETRY_DELAY=0
export HOME CLAUDEB_DIR CLAUDEB_WARM_RETRY_DELAY CLAUDEB_OAUTH_TOKEN_SPACING CLAUDEB_WEATHER_RETRY_DELAY
mkdir -p "$HOME" "$CLAUDEB_DIR/limits" "$CLAUDEB_DIR/tokens" "$FAKE_BIN"
for command in curl security claude; do
  printf '#!/usr/bin/env bash\nexit 97\n' >"$FAKE_BIN/$command"
  chmod +x "$FAKE_BIN/$command"
done
PATH="$FAKE_BIN:$PATH"
export PATH

source "$SCRIPT"

# A bare invocation is now an error and must not launch Claude.
mkdir -p "$HOME/.claude-profiles/com" "$HOME/.claude-profiles/notcom"
touch "$CLAUDEB_DIR/tokens/com" "$CLAUDEB_DIR/tokens/notcom" "$CLAUDEB_DIR/tokens/-legacy"
printf 'notcom\n-legacy\n' >"$CLAUDEB_DIR/disabled"
NO_PROFILE_OUT="$WORK/no-profile.out"
cat >"$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
printf 'launched\n' >>"$WORK/claude-launches"
exit 0
EOF
chmod +x "$FAKE_BIN/claude"
assert_fails env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" bash "$SCRIPT" >"$NO_PROFILE_OUT" 2>&1
assert grep -q 'profile required — rotation has been removed' "$NO_PROFILE_OUT"
assert grep -q '  com (enabled)' "$NO_PROFILE_OUT"
assert grep -q '  notcom (disabled)' "$NO_PROFILE_OUT"
assert grep -q -- '  -legacy (disabled)' "$NO_PROFILE_OUT"
assert grep -q 'claudeb profile <name>' "$NO_PROFILE_OUT"
assert test ! -e "$WORK/claude-launches"
assert_fails env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" bash "$SCRIPT" --direct profile com \
  >"$WORK/direct-before.out" 2>&1
assert grep -q -- '--direct was removed' "$WORK/direct-before.out"
assert test ! -e "$WORK/claude-launches"
assert_fails env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" bash "$SCRIPT" profile com --direct \
  >"$WORK/direct-after.out" 2>&1
assert grep -q -- '--direct was removed' "$WORK/direct-after.out"
rm -f "$CLAUDEB_DIR/tokens/com" "$CLAUDEB_DIR/tokens/notcom" "$CLAUDEB_DIR/tokens/-legacy"

now=$(date +%s)
short_epoch=$((now + 3600))
week_epoch=$((now + 172800))
date_epoch=$((now + 691200))
weekdays=(Sun Mon Tue Wed Thu Fri Sat)
weekday_number=$(date -r "$week_epoch" '+%w' 2>/dev/null || date -d "@$week_epoch" '+%w')
# A within-24h reset keeps a bare clock only while it lands on today; one hour from now can
# be tomorrow, and then the formatter correctly prefixes the weekday. Expecting a bare clock
# unconditionally made this assertion fail during the last hour of every day.
short_clock=$(date -r "$short_epoch" '+%H:%M' 2>/dev/null || date -d "@$short_epoch" '+%H:%M')
if [ "$(date -r "$short_epoch" '+%F' 2>/dev/null || date -d "@$short_epoch" '+%F')" = "$(date '+%F')" ]; then
  short_expected="$short_clock"
else
  short_weekday=$(date -r "$short_epoch" '+%w' 2>/dev/null || date -d "@$short_epoch" '+%w')
  short_expected="${weekdays[$short_weekday]} $short_clock"
fi
assert test "$(format_reset_time "$short_epoch")" = "$short_expected"
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

headers="$WORK/headers.txt"
cat >"$headers" <<EOF
anthropic-ratelimit-unified-status: allowed
anthropic-ratelimit-unified-5h-utilization: 0.42
anthropic-ratelimit-unified-5h-reset: $((now + 7200))
EOF
assert merge_headers alpha "$headers"
assert jq -e --argjson as_of "$cached_as_of" \
  '.five_hour.used_percentage == 42 and .fable.used_percentage == 31 and .fable.as_of == $as_of and .fable.origin == "cached"' \
  "$snapshot" >/dev/null
export CLAUDEB_LOCK_RETRIES=1 CLAUDEB_LOCK_DELAY=0
mkdir "$snapshot.lock"
assert_fails merge_headers alpha "$headers"
assert jq -e --argjson as_of "$cached_as_of" '.fable.used_percentage == 31 and .fable.as_of == $as_of' "$snapshot" >/dev/null
rmdir "$snapshot.lock"
unset CLAUDEB_LOCK_RETRIES CLAUDEB_LOCK_DELAY

# Not even a warning or rejection naming the weekly bucket may mint one (invariant n).
snapshot_wk="$CLAUDEB_DIR/limits/wkorigin.json"
headers_wk="$WORK/headers-wk.txt"
cat >"$headers_wk" <<EOF
anthropic-ratelimit-unified-status: allowed_warning
anthropic-ratelimit-unified-representative-claim: seven_day
anthropic-ratelimit-unified-reset: $((now + 400000))
anthropic-ratelimit-unified-5h-utilization: 0.07
anthropic-ratelimit-unified-5h-reset: $((now + 7200))
EOF
cat >"$snapshot_wk" <<EOF
{"seven_day":{"used_percentage":100,"resets_at":$((now + 400000)),"as_of":$now,"origin":"headers"}}
EOF
assert merge_headers wkorigin "$headers_wk"
assert jq -e '.five_hour.used_percentage == 7 and (has("seven_day") | not)' "$snapshot_wk" >/dev/null
cat >"$snapshot_wk" <<EOF
{"seven_day":{"used_percentage":76,"resets_at":$((now + 400000)),"as_of":$now,"origin":"session"}}
EOF
assert merge_headers wkorigin "$headers_wk"
assert jq -e '.seven_day.used_percentage == 76 and .seven_day.origin == "session"' "$snapshot_wk" >/dev/null
cat >"$snapshot_wk" <<EOF
{"five_hour":{"used_percentage":3,"resets_at":$((now + 7200)),"as_of":$now,"origin":"headers"},
 "seven_day":{"used_percentage":100,"resets_at":$((now + 400000)),"as_of":$now,"origin":"headers"},
 "auth":{"status":"ok","checked_at":$now}}
EOF
wk_row=$(account_data wkorigin)
assert jq -e '.wk_raw == null and .wk == 0 and .walled == false' <<<"$wk_row" >/dev/null
rm -f "$snapshot_wk"

REAL_JQ=$(command -v jq)
jq() {
  if [ "$#" -eq 3 ] && [ "$1" = -c ] && [ "$2" = . ] && [ "$3" = "$snapshot" ]; then
    return 42
  fi
  "$REAL_JQ" "$@"
}
set +e
(
  set -e
  merge_headers alpha "$headers"
  [ ! -d "$snapshot.lock" ]
  merge_usage alpha "$usage"
  [ ! -d "$snapshot.lock" ]
  mark_auth alpha expired fixture
  [ ! -d "$snapshot.lock" ]
)
cached_jq_rc=$?
set -e
unset -f jq
assert test "$cached_jq_rc" -eq 0
assert test ! -d "$snapshot.lock"

now=$(date +%s)
printf '{"alpha":{"attempted_at":%s,"outcome":"failed","retry_after_until":0}}\n' "$now" >"$oauth_attempts_file"
until=$(oauth_backoff_until alpha)
assert test "$until" -ge "$((now + 899))"
assert test "$until" -le "$((now + 900))"
printf '{"alpha":{"attempted_at":%s,"outcome":"429","retry_after_until":%s}}\n' "$now" "$((now + 1800))" >"$oauth_attempts_file"
assert test "$(oauth_backoff_until alpha)" = "$((now + 1800))"
printf '{"legacy":{"attempted_at":%s,"outcome":"429","retry_after_until":0}}\n' "$now" >"$oauth_attempts_file"
assert test "$(oauth_backoff_until legacy)" = "$((now + 900))"
printf '{}' >"$oauth_attempts_file"
i=0
for expected_delay in 900 1800 3600 7200 14400; do
  i=$((i + 1))
  assert oauth_attempt_update alpha 429 0
  attempted_at=$(jq -r '.alpha.attempted_at' "$oauth_attempts_file")
  strikes=$(jq -r '.alpha.strikes' "$oauth_attempts_file")
  until=$(oauth_backoff_until alpha)
  assert test "$strikes" -eq "$i"
  assert test "$until" -eq "$((attempted_at + expected_delay))"
done
assert test "$(jq -r '.alpha.strikes' "$oauth_attempts_file")" -eq 5
assert oauth_attempt_update alpha 429 0
attempted_at=$(jq -r '.alpha.attempted_at' "$oauth_attempts_file")
assert test "$(jq -r '.alpha.strikes' "$oauth_attempts_file")" -eq 6
assert test "$(oauth_backoff_until alpha)" -eq "$((attempted_at + 14400))"
assert oauth_attempt_update alpha success-adopted 0
assert jq -e '.alpha.outcome == "success-adopted" and (.alpha | has("strikes") | not)' "$oauth_attempts_file" >/dev/null
assert test "$(oauth_backoff_until alpha)" = 0
assert oauth_attempt_update alpha 429 0
attempted_at=$(jq -r '.alpha.attempted_at' "$oauth_attempts_file")
assert jq -e '.alpha.strikes == 1' "$oauth_attempts_file" >/dev/null
assert test "$(oauth_backoff_until alpha)" -eq "$((attempted_at + 900))"
assert oauth_attempt_update alpha success 0
assert jq -e 'has("alpha") | not' "$oauth_attempts_file" >/dev/null
assert oauth_attempt_update alpha 429 0
assert jq -e '.alpha.strikes == 1' "$oauth_attempts_file" >/dev/null
long_retry=$((now + 20000))
assert oauth_attempt_update beta 429 "$long_retry"
assert test "$(oauth_backoff_until beta)" -eq "$long_retry"
printf '{"gamma":{"attempted_at":%s,"outcome":"429","retry_after_until":0,"strikes":3}}\n' "$now" >"$oauth_attempts_file"
assert oauth_attempt_update gamma weather 0 0 '' 503 0
attempted_at=$(jq -r '.gamma.attempted_at' "$oauth_attempts_file")
assert jq -e '.gamma.strikes == 3 and .gamma.http_status == 503' "$oauth_attempts_file" >/dev/null
assert test "$(oauth_backoff_until gamma)" -eq "$((attempted_at + 900))"
assert oauth_attempt_update gamma weather 0 0 '' 0 28
attempted_at=$(jq -r '.gamma.attempted_at' "$oauth_attempts_file")
assert jq -e '.gamma.strikes == 3 and .gamma.transport_rc == 28' "$oauth_attempts_file" >/dev/null
assert test "$(oauth_backoff_until gamma)" -eq "$((attempted_at + 900))"

printf '{"delta":{"attempted_at":%s,"outcome":"429","retry_after_until":%s,"strikes":2}}\n' "$now" "$((now + 1800))" >"$oauth_attempts_file"
CLAUDEB_OAUTH_BYPASS_BACKOFF=false
assert_fails oauth_attempt_begin delta
CLAUDEB_OAUTH_BYPASS_BACKOFF=true
assert oauth_attempt_begin delta
bypass_attempted_at=$(jq -r '.delta.bypass_attempted_at' "$oauth_attempts_file")
assert test "$bypass_attempted_at" -ge "$now"
assert jq -e '.delta.outcome == "attempting" and .delta.strikes == 2' "$oauth_attempts_file" >/dev/null
assert_fails oauth_attempt_begin delta
assert test "$(jq -r '.delta.bypass_attempted_at' "$oauth_attempts_file")" = "$bypass_attempted_at"
assert oauth_attempt_update delta 429 0
assert jq -e --argjson bypass "$bypass_attempted_at" '.delta.strikes == 3 and .delta.bypass_attempted_at == $bypass' "$oauth_attempts_file" >/dev/null
unset CLAUDEB_OAUTH_BYPASS_BACKOFF
printf '{"alpha":{"attempted_at":%s,"outcome":"warming","retry_after_until":0}}\n' "$((now - 170))" >"$oauth_attempts_file"
assert test "$(oauth_backoff_until alpha)" = 0
assert test "$(oauth_heal_backoff_until alpha)" -gt "$now"
printf '{"alpha":{"attempted_at":%s,"outcome":"warming","retry_after_until":0}}\n' "$((now - 181))" >"$oauth_attempts_file"
assert test "$(oauth_heal_backoff_until alpha)" = 0

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
for reserved in p run profile; do
  if HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" bash "$SCRIPT" add "$reserved" </dev/null >/dev/null 2>&1; then
    fail "add accepted reserved account name $reserved"
  fi
done
assert_fails env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" bash "$SCRIPT" add -h </dev/null >/dev/null 2>&1
assert test ! -e "$CLAUDEB_DIR/tokens/-h"
assert_fails env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" bash "$SCRIPT" profile -dash >/dev/null 2>&1
assert test ! -e "$HOME/.claude-profiles/-dash"

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

# A disabled account launched via `profile` proceeds direct and strips inherited
# routing credentials.
touch "$CLAUDEB_DIR/tokens/gamma"
printf 'gamma\n' >"$disabled_file"
ENV_DUMP="$WORK/gamma-env.txt"
cat >"$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
env > "$ENV_DUMP"
exit 0
EOF
chmod +x "$FAKE_BIN/claude"
# Subshell so profile_command's exec replaces the subshell, not the test runner.
note=$( ANTHROPIC_BASE_URL="http://proxy.invalid" CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-leak" \
  profile_command gamma 2>&1 >/dev/null )
assert grep -q 'disabled for worker selection' <<<"$note"
assert test -f "$ENV_DUMP"
assert_fails grep -q '^ANTHROPIC_BASE_URL=' "$ENV_DUMP"
assert_fails grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$ENV_DUMP"
assert grep -qx "CLAUDE_LIMITS_ACCOUNT=gamma" "$ENV_DUMP"
assert grep -qx "CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/gamma" "$ENV_DUMP"
assert grep -qx gamma "$CLAUDEB_DIR/.claudeb-state"

# A headless worker spawn must NOT restamp "current": those run on other accounts all day
# and would make the `*`/`●`/`cb:` markers name the last worker, not the user's session.
printf 'delta\n' >"$CLAUDEB_DIR/.claudeb-state"
( profile_command gamma -p 'noop' >/dev/null 2>&1 )
assert grep -qx delta "$CLAUDEB_DIR/.claudeb-state"
( profile_command gamma --print 'noop' >/dev/null 2>&1 )
assert grep -qx delta "$CLAUDEB_DIR/.claudeb-state"
( profile_command gamma >/dev/null 2>&1 )
assert grep -qx gamma "$CLAUDEB_DIR/.claudeb-state"

# An unknown name is a NEW profile now, not an error: it must launch so the login can happen,
# and say so first. The subshell is mandatory — profile_command execs, and without it the exec
# replaces this test runner and the rest of the suite silently never runs.
mkdir -p "$HOME/.claude-profiles/gateway"
rm -f "$ENV_DUMP"
# `security` exiting 44 is the only proof an account has no keychain entry.
printf '#!/usr/bin/env bash\nexit 44\n' >"$FAKE_BIN/security"
( profile_command gateway >/dev/null 2>"$WORK/unknown-profile.out" )
assert grep -q 'gateway is new' "$WORK/unknown-profile.out"
assert_fails grep -q "unknown account" "$WORK/unknown-profile.out"
assert test -f "$ENV_DUMP"
assert grep -qx "CLAUDE_LIMITS_ACCOUNT=gateway" "$ENV_DUMP"

# A near-miss on an existing account is named before the login window opens.
rm -f "$ENV_DUMP"
( profile_command gamm >/dev/null 2>"$WORK/near-profile.out" )
assert grep -q 'did you mean gamma' "$WORK/near-profile.out"

# Any other `security` outcome means "could not check", and an unverifiable keychain must
# never tell the user their established account is new.
printf '#!/usr/bin/env bash\nexit 97\n' >"$FAKE_BIN/security"
rm -f "$ENV_DUMP"
( profile_command gateway >/dev/null 2>"$WORK/unverifiable.out" )
assert_fails grep -q 'is new' "$WORK/unverifiable.out"
assert test -f "$ENV_DUMP"

# Reserved names may not become profiles: `main` is ~/.claude itself.
assert_fails profile_command main >"$WORK/reserved-profile.out" 2>&1
assert grep -q "'main' is reserved" "$WORK/reserved-profile.out"
for command in curl security claude; do
  printf '#!/usr/bin/env bash\nexit 97\n' >"$FAKE_BIN/$command"
  chmod +x "$FAKE_BIN/$command"
done

# --- headless routing and the worker pin ---
# A program calling claudeb cannot know which account is affordable, so `-p` asks worker-pick;
# an interactive run must still name a profile, which is the whole point of dropping rotation.
touch "$CLAUDEB_DIR/tokens/routed"
ROUTE_ENV="$WORK/route-env.txt"
ROUTE_PICK="$FAKE_BIN/stub-worker-pick"
cat >"$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
env > "$ROUTE_ENV"
printf 'launched\n' >>"$WORK/route-launches"
exit 0
EOF
cat >"$ROUTE_PICK" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --account ] && [ "$2" = claudeb ] || exit 9
if [ -n "${STUB_PICK_FAIL:-}" ]; then
  printf 'worker-pick: no selectable claudeb account (stub)\n' >&2
  exit 3
fi
printf '%s\n' "${STUB_PICK_ACCOUNT:-routed}"
EOF
chmod +x "$FAKE_BIN/claude" "$ROUTE_PICK"
IFS= read -r state_before_routing <"$CLAUDEB_DIR/.claudeb-state"
route_run() { env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" \
  CLAUDEB_WORKER_PICK="$1" WORKER_PICK_CONFIG_FILE="$WORK/worker-model" \
  STUB_PICK_ACCOUNT="${STUB_PICK_ACCOUNT:-}" STUB_PICK_FAIL="${STUB_PICK_FAIL:-}" \
  bash "$SCRIPT" "${@:2}"; }
assert route_run "$ROUTE_PICK" -p --model sonnet 'hi' >"$WORK/route.out" 2>"$WORK/route.err"
assert grep -q 'worker-pick selected routed' "$WORK/route.err"
assert grep -qx "CLAUDE_LIMITS_ACCOUNT=routed" "$ROUTE_ENV"
assert grep -qx "CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/routed" "$ROUTE_ENV"
# Routing is headless by definition and must not restamp "current" either.
assert grep -qx "$state_before_routing" "$CLAUDEB_DIR/.claudeb-state"

# Arguments alone do not authorize a launch: without -p there is nobody to pick for.
rm -f "$WORK/route-launches"
assert_fails route_run "$ROUTE_PICK" --model opus >"$WORK/route-interactive.out" 2>&1
assert grep -q 'profile required' "$WORK/route-interactive.out"
assert test ! -e "$WORK/route-launches"

# No selectable account is an immediate refusal — never a request held until it turns into a 503.
STUB_PICK_FAIL=1
route_rc=0
route_run "$ROUTE_PICK" -p 'hi' >"$WORK/route-fail.out" 2>&1 || route_rc=$?
STUB_PICK_FAIL=
# The query's exit 3 is passed through, not flattened into the usage error a broken install gets.
assert test "$route_rc" -eq 3
assert grep -q 'worker-pick selected no account' "$WORK/route-fail.out"
assert grep -q 'no selectable claudeb account' "$WORK/route-fail.out"
assert test ! -e "$WORK/route-launches"
route_rc=0
route_run "$WORK/absent-worker-pick" -p 'hi' >"$WORK/route-missing.out" 2>&1 || route_rc=$?
assert test "$route_rc" -eq 2
assert grep -q 'cannot route without worker-pick' "$WORK/route-missing.out"
assert test ! -e "$WORK/route-launches"

# A clean machine has no worker-model at all: the pin is optional and `use` is what creates the
# file. Reading a missing one must not take the CLI down under `pipefail` — and this must be
# asserted BEFORE any test writes the file, or the suite passes over a crash.
MISSING_PIN="$WORK/absent-worker-model"
pin_run() { env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" \
  WORKER_PICK_CONFIG_FILE="$1" bash "$SCRIPT" "${@:2}"; }
assert pin_run "$MISSING_PIN" use >"$WORK/pin-none.out" 2>&1
assert grep -q 'no pin' "$WORK/pin-none.out"
assert test ! -e "$MISSING_PIN"
assert pin_run "$MISSING_PIN" use --clear >"$WORK/pin-none-clear.out" 2>&1
assert grep -q 'no pin to clear' "$WORK/pin-none-clear.out"
assert test ! -e "$MISSING_PIN"
assert pin_run "$MISSING_PIN" use gamma >/dev/null 2>&1
assert grep -qx 'claudeb_profile=gamma' "$MISSING_PIN"

# Present but unreadable is NOT "no pin": reporting it as pinless would lie, and the write path
# would then replace every other key in the file with a single line.
UNREADABLE_PIN="$WORK/unreadable-worker-model"
printf 'worker=auto\nclaudeb_model=opus\nclaudeb_profile=gamma\n' >"$UNREADABLE_PIN"
chmod 000 "$UNREADABLE_PIN"
if [ -r "$UNREADABLE_PIN" ]; then
  printf 'SKIP: unreadable-pin case (running with read-everything privileges)\n'
else
  assert_fails pin_run "$UNREADABLE_PIN" use gamma >"$WORK/pin-unreadable.out" 2>&1
  assert grep -q 'cannot be read' "$WORK/pin-unreadable.out"
  assert_fails pin_run "$UNREADABLE_PIN" use --clear >"$WORK/pin-unreadable-clear.out" 2>&1
  assert grep -q 'cannot be read' "$WORK/pin-unreadable-clear.out"
  chmod 600 "$UNREADABLE_PIN"
  assert grep -qx 'worker=auto' "$UNREADABLE_PIN"
  assert grep -qx 'claudeb_model=opus' "$UNREADABLE_PIN"
  assert grep -qx 'claudeb_profile=gamma' "$UNREADABLE_PIN"
fi

# `use` writes the pin every consumer already reads, and touches nothing else in that file.
PIN_FILE="$WORK/worker-model"
printf 'worker=auto\nclaudeb_model=opus\n' >"$PIN_FILE"
assert env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" WORKER_PICK_CONFIG_FILE="$PIN_FILE" \
  bash "$SCRIPT" use routed >"$WORK/pin.out" 2>&1
assert grep -q 'pinned workers to routed' "$WORK/pin.out"
assert grep -qx 'claudeb_profile=routed' "$PIN_FILE"
assert grep -qx 'worker=auto' "$PIN_FILE"
assert grep -qx 'claudeb_model=opus' "$PIN_FILE"
assert env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" WORKER_PICK_CONFIG_FILE="$PIN_FILE" \
  bash "$SCRIPT" use gamma >/dev/null 2>&1
assert test "$(grep -c '^claudeb_profile=' "$PIN_FILE")" = 1
assert grep -qx 'claudeb_profile=gamma' "$PIN_FILE"
# gamma is out of the pool, and a pin worker-pick cannot honor must say so.
assert env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" WORKER_PICK_CONFIG_FILE="$PIN_FILE" \
  bash "$SCRIPT" use gamma >"$WORK/pin-disabled.out" 2>&1
assert grep -q 'out of the worker pool' "$WORK/pin-disabled.out"
assert env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" WORKER_PICK_CONFIG_FILE="$PIN_FILE" \
  bash "$SCRIPT" use >"$WORK/pin-show.out" 2>&1
assert grep -q 'pinned to gamma' "$WORK/pin-show.out"
assert env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" WORKER_PICK_CONFIG_FILE="$PIN_FILE" \
  bash "$SCRIPT" use --clear >"$WORK/pin-clear.out" 2>&1
assert grep -q 'cleared the pin' "$WORK/pin-clear.out"
assert_fails grep -q '^claudeb_profile=' "$PIN_FILE"
assert grep -qx 'worker=auto' "$PIN_FILE"
# Pinning a name that cannot be routed to is refused, not silently recorded.
assert_fails env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" WORKER_PICK_CONFIG_FILE="$PIN_FILE" \
  bash "$SCRIPT" use gamm >"$WORK/pin-unknown.out" 2>&1
assert grep -q 'unknown account: gamm' "$WORK/pin-unknown.out"
assert grep -q 'did you mean gamma' "$WORK/pin-unknown.out"
assert_fails grep -q '^claudeb_profile=' "$PIN_FILE"
# A path-shaped name reaches this from a web handler; it must not become a store lookup outside
# the token dir, nor a line other consumers read back as an account.
assert_fails env HOME="$HOME" CLAUDEB_DIR="$CLAUDEB_DIR" PATH="$PATH" WORKER_PICK_CONFIG_FILE="$PIN_FILE" \
  bash "$SCRIPT" use ../gamma >"$WORK/pin-path.out" 2>&1
assert grep -q 'unknown account' "$WORK/pin-path.out"
assert_fails grep -q '^claudeb_profile=' "$PIN_FILE"
# `use` is a subcommand now, so it can never also be a profile name.
assert reserved_name use
rm -f "$WORK/route-launches" "$CLAUDEB_DIR/tokens/routed"
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

# --- heal backoff: only warm state gates warm; direct endpoint state never does ---
now=$(date +%s)
printf '{"alpha":{"attempted_at":%s,"outcome":"revoked","retry_after_until":0}}\n' "$now" >"$oauth_attempts_file"
assert test "$(oauth_heal_backoff_until alpha)" = 0
printf '{}' >"$oauth_attempts_file"
assert oauth_attempt_update alpha warm-failed 0
assert test "$(oauth_heal_backoff_until alpha)" -gt "$now"
assert test "$(oauth_backoff_until alpha)" = 0
printf '{"alpha":{"attempted_at":%s,"outcome":"429","retry_after_until":%s}}\n' "$now" "$((now + 9999))" >"$oauth_attempts_file"
assert test "$(oauth_heal_backoff_until alpha)" = 0

# --- oauth_refresh: single-use refresh token races and revocation ---
old_expires_at=$(((now - 60) * 1000))
creds='{"claudeAiOauth":{"refreshToken":"rt-old","accessToken":"at","expiresAt":'"$old_expires_at"',"scopes":["a"]}}'
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
assert test "$(jq -r '.alpha.credentials_expires_at' "$oauth_attempts_file")" = "$old_expires_at"
assert test ! -d "$oauth_attempts_file.rl.alpha"

# newer credentials from a real re-login bypass the revoked backoff immediately.
relogin_expires_at=$(((now + 3600) * 1000))
relogin_creds='{"claudeAiOauth":{"refreshToken":"rt-login","accessToken":"at-login","expiresAt":'"$relogin_expires_at"',"scopes":["a"]}}'
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$relogin_creds'
EOF
refresh_attempted="$WORK/relogin-refresh-attempted"
cat >"$FAKE_BIN/curl" <<EOF
#!/usr/bin/env bash
touch '$refresh_attempted'
printf '{"error":"server_error"}\n500'
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/curl"
if got=$(oauth_refresh alpha svc "$relogin_creds"); then rc=0; else rc=$?; fi
assert test "$rc" -ne 0
assert test -f "$refresh_attempted"
assert test "$(oauth_backoff_outcome alpha)" = weather
assert test "$(oauth_backoff_http alpha)" = 500
assert test ! -d "$oauth_attempts_file.rl.alpha"

weather_dir="$WORK/oauth-weather"
mkdir -p "$weather_dir"
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$creds'
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"error":"overloaded"}\n529'
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/curl"
printf '{}' >"$oauth_attempts_file"
printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/alpha.json"
probe_one alpha "$weather_dir" false true
assert test "$(cat "$weather_dir/alpha.result")" = 'no-spend 255 529'
assert jq -e '.alpha.outcome == "weather" and .alpha.http_status == 529' "$oauth_attempts_file" >/dev/null
assert jq -e '.auth.status == "ok" and (.auth | has("cause") | not)' "$limits_dir/alpha.json" >/dev/null

retry_weather_dir="$WORK/oauth-retry-weather"
mkdir -p "$retry_weather_dir"
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$relogin_creds'
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'/api/oauth/usage'*) printf '401' ;;
  *'/v1/oauth/token'*) printf '{"error":"overloaded"}\n529' ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/curl"
printf '{}' >"$oauth_attempts_file"
printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/alpha.json"
probe_one alpha "$retry_weather_dir" false true
assert test "$(cat "$retry_weather_dir/alpha.result")" = 'no-spend 0 529'
assert jq -e '.alpha.outcome == "weather" and .alpha.http_status == 529' "$oauth_attempts_file" >/dev/null
assert jq -e '.auth.status == "ok" and (.auth | has("cause") | not)' "$limits_dir/alpha.json" >/dev/null

# invalid_grant after an in-flight concurrent rotation adopts the newer keychain value.
newcreds='{"claudeAiOauth":{"refreshToken":"rt-new","accessToken":"at2","expiresAt":'"$relogin_expires_at"'}}'
security_calls="$WORK/security-calls"
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
calls=\$(cat '$security_calls' 2>/dev/null || printf '0')
calls=\$((calls + 1))
printf '%s' "\$calls" >'$security_calls'
if [ "\$calls" -eq 1 ]; then printf '%s' '$creds'; else printf '%s' '$newcreds'; fi
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"error":"invalid_grant"}\n400'
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/curl"
printf '{}' >"$oauth_attempts_file"
if got=$(oauth_refresh alpha svc "$creds"); then rc=0; else rc=$?; fi
assert test "$rc" -eq 0
assert test "$got" = "$newcreds"
assert test "$(oauth_backoff_outcome alpha)" = success-adopted
assert test "$(oauth_backoff_until alpha)" = 0
assert test ! -d "$oauth_attempts_file.rl.alpha"

# errexit inside the locked section still releases the per-account lock.
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$creds'
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"error":"rate_limited"}\n429'
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/curl"
printf '{}' >"$oauth_attempts_file"
set +e
(
  set -e
  header_value() { return 42; }
  oauth_refresh alpha svc "$creds" >/dev/null
)
rc=$?
set -e
assert test "$rc" -ne 0
assert test ! -d "$oauth_attempts_file.rl.alpha"

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
headers=''; prev=''
for arg in "$@"; do
  [ "$prev" = -D ] && headers="$arg"
  prev="$arg"
done
printf 'Retry-After: 20000\r\n' >"$headers"
printf '{"error":"rate_limited"}\n429'
EOF
chmod +x "$FAKE_BIN/curl"
printf '{}' >"$oauth_attempts_file"
retry_started=$(date +%s)
if got=$(oauth_refresh alpha svc "$creds"); then rc=0; else rc=$?; fi
assert test "$rc" -ne 0
assert jq -e '.alpha.outcome == "429" and .alpha.strikes == 1' "$oauth_attempts_file" >/dev/null
retry_until=$(jq -r '.alpha.retry_after_until' "$oauth_attempts_file")
assert test "$retry_until" -ge "$((retry_started + 20000))"
assert test "$(oauth_backoff_until alpha)" = "$retry_until"

# a concurrent holder of the per-account refresh lock: adopt their fresher token,
# never POST the already-consumed one, never release the lock we do not own.
export CLAUDEB_LOCK_RETRIES=1 CLAUDEB_LOCK_DELAY=0
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

# --- warm-first heal order and regular probe isolation ---
EVENT_LOG="$WORK/heal-order.log"
KEYCHAIN_FRESH="$WORK/keychain-fresh"
WARM_SUCCEEDS=false
export EVENT_LOG KEYCHAIN_FRESH WARM_SUCCEEDS
expired_creds='{"claudeAiOauth":{"refreshToken":"rt-order","accessToken":"at-expired","expiresAt":1,"scopes":["a"]}}'
fresh_creds='{"claudeAiOauth":{"refreshToken":"rt-fresh","accessToken":"at-fresh","expiresAt":9999999999999,"scopes":["a"]}}'
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
if [ -f '$KEYCHAIN_FRESH' ]; then printf '%s' '$fresh_creds'; else printf '%s' '$expired_creds'; fi
EOF
cat >"$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf 'warm\n' >>"$EVENT_LOG"
if [ "$WARM_SUCCEEDS" = true ]; then touch "$KEYCHAIN_FRESH"; exit 0; fi
exit 1
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'/v1/oauth/token'*)
    printf 'token\n' >>"$EVENT_LOG"
    printf '{"error":"rate_limited"}\n429'
    ;;
  *'/api/oauth/usage'*)
    printf 'usage\n' >>"$EVENT_LOG"
    output=''
    previous=''
    for argument in "$@"; do
      if [ "$previous" = -o ]; then output="$argument"; break; fi
      previous="$argument"
    done
    printf '%s' '{"five_hour":{"utilization":1,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":3,"resets_at":null}]}' >"$output"
    printf '200'
    ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/claude" "$FAKE_BIN/curl"

(
  account_names() { printf 'alpha\n'; }
  order_dir="$WORK/heal-order-success"
  mkdir -p "$order_dir"
  : >"$EVENT_LOG"
  rm -f "$KEYCHAIN_FRESH"
  printf '{}' >"$oauth_attempts_file"
  WARM_SUCCEEDS=true
  export WARM_SUCCEEDS
  probe_accounts "$order_dir" false false true
  assert test "$(cat "$order_dir/alpha.display")" = live
  assert test "$(sed -n '1p' "$EVENT_LOG")" = warm
  assert grep -qx usage "$EVENT_LOG"
  assert_fails grep -qx token "$EVENT_LOG"
  # A warm-healed account clears to auth ok in the snapshot, so the downstream
  # refresh_error never names it (bug: healed accounts reported as auth failures).
  assert test "$(jq -r '.auth.status' "$limits_dir/alpha.json")" = ok
)

(
  account_names() { printf 'alpha\n'; }
  order_dir="$WORK/heal-order-fallback"
  mkdir -p "$order_dir"
  : >"$EVENT_LOG"
  rm -f "$KEYCHAIN_FRESH"
  printf '{}' >"$oauth_attempts_file"
  WARM_SUCCEEDS=false
  export WARM_SUCCEEDS
  # A hard-expired access token with the token endpoint returning 429 is pure
  # weather: neither the refresh-deferred first pass nor the heal cycle has any
  # evidence the credentials are dead, so the prior verdict is left byte-untouched.
  printf '{"auth":{"status":"expired","checked_at":31337,"cause":"prior sentinel"}}' >"$limits_dir/alpha.json"
  probe_accounts "$order_dir" false false true
  assert test "$(sed -n '1p' "$EVENT_LOG")" = warm
  assert test "$(sed -n '2p' "$EVENT_LOG")" = warm
  assert test "$(sed -n '3p' "$EVENT_LOG")" = token
  assert test "$(wc -l < "$EVENT_LOG" | tr -d ' ')" = 3
  assert jq -e '.auth.status == "expired" and .auth.checked_at == 31337 and .auth.cause == "prior sentinel"' "$limits_dir/alpha.json" >/dev/null
)

(
  account_names() { printf 'alpha\n'; }
  order_dir="$WORK/regular-probe"
  mkdir -p "$order_dir"
  : >"$EVENT_LOG"
  rm -f "$KEYCHAIN_FRESH"
  printf '{}' >"$oauth_attempts_file"
  probe_accounts "$order_dir" false false false
  assert test "$(sed -n '1p' "$EVENT_LOG")" = token
  assert_fails grep -qx warm "$EVENT_LOG"
)

# --- weather-refresh convergence + cross-account token-endpoint serialization ---
(
  KC="$WORK/wthr-keychain"; mkdir -p "$KC"
  SERLOG="$WORK/wthr-serial.log"
  kc_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
  svc_of() { printf 'Claude Code-credentials-%s' "$(printf '%s' "$HOME/.claude-profiles/$1" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"; }
  seed_expired() { printf '{"claudeAiOauth":{"refreshToken":"%s","accessToken":"at-old","expiresAt":1,"scopes":["a"]}}' "$2" >"$KC/$(kc_key "$(svc_of "$1")")"; }
  security() {
    local prev='' svc='' a
    for a in "$@"; do [ "$prev" = -s ] && svc="$a"; prev="$a"; done
    cat "$KC/$(kc_key "$svc")" 2>/dev/null || return 44
  }
  keychain_write() { printf '%s' "$2" >"$KC/$(kc_key "$1")"; }

  (
    account_names() { printf 'wa1\nwa2\n'; }
    curl() {
      local out='' prev='' a body rt cf n
      for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
      case "$*" in
        *'/oauth/token'*)
          body=$(cat)
          rt=$(printf '%s' "$body" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')
          printf 'S:%s\n' "$rt" >>"$SERLOG"; sleep 0.1; printf 'E:%s\n' "$rt" >>"$SERLOG"
          cf="$WORK/wthr-tc-$rt"; n=$(cat "$cf" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" >"$cf"
          if [ "$n" -ge 2 ]; then printf '{"access_token":"at-%s","expires_in":3600,"refresh_token":"%s"}\n200' "$rt" "$rt"
          else printf '{"error":"rate_limited"}\n429'; fi
          ;;
        *'/api/oauth/usage'*)
          [ -z "$out" ] || printf '%s' '{"five_hour":{"utilization":7,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null},"limits":[]}' >"$out"
          printf '200'
          ;;
        *) return 97 ;;
      esac
    }
    : >"$SERLOG"; rm -f "$WORK"/wthr-tc-*
    seed_expired wa1 rt-wa1; seed_expired wa2 rt-wa2
    printf '{}' >"$oauth_attempts_file"
    wa_keep='{"five_hour":{"used_percentage":12,"resets_at":123,"as_of":99,"origin":"usage"},"auth":{"status":"ok","checked_at":1}}'
    printf '%s' "$wa_keep" >"$limits_dir/wa1.json"
    printf '%s' "$wa_keep" >"$limits_dir/wa2.json"
    wa_dir="$WORK/wthr-a"; mkdir -p "$wa_dir"
    probe_accounts "$wa_dir" false false false
    assert test "$(cat "$limits_dir/wa1.json")" = "$wa_keep"
    assert test "$(cat "$limits_dir/wa2.json")" = "$wa_keep"
    assert jq -e '.wa1.outcome == "429" and .wa1.strikes == 1 and .wa2.outcome == "429" and .wa2.strikes == 1' "$oauth_attempts_file" >/dev/null
    assert test "$(cat "$WORK/wthr-tc-rt-wa1")" = 1
    assert test "$(cat "$WORK/wthr-tc-rt-wa2")" = 1
    while read -r s && read -r e; do
      assert test "${s#S:}" = "${e#E:}"
    done <"$SERLOG"
  )

  # Holders hold the glock past the default waiter budget — under the old 10-try
  # acquire the waiters timed out and POSTed in parallel (the morning-herd 429).
  (
    export CLAUDEB_LOCK_RETRIES=10 CLAUDEB_LOCK_DELAY=0.05
    account_names() { printf 'wg1\nwg2\nwg3\nwg4\n'; }
    curl() {
      local out='' prev='' a body rt
      for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
      case "$*" in
        *'/oauth/token'*)
          body=$(cat)
          rt=$(printf '%s' "$body" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')
          printf 'S:%s\n' "$rt" >>"$SERLOG"; sleep 0.6; printf 'E:%s\n' "$rt" >>"$SERLOG"
          printf '{"access_token":"at-%s","expires_in":3600,"refresh_token":"%s"}\n200' "$rt" "$rt"
          ;;
        *'/api/oauth/usage'*)
          [ -z "$out" ] || printf '%s' '{"five_hour":{"utilization":3,"resets_at":null},"seven_day":{"utilization":1,"resets_at":null},"limits":[]}' >"$out"
          printf '200'
          ;;
        *) return 97 ;;
      esac
    }
    : >"$SERLOG"
    for a in wg1 wg2 wg3 wg4; do
      seed_expired "$a" "rt-$a"
      printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/$a.json"
    done
    printf '{}' >"$oauth_attempts_file"
    wg_dir="$WORK/wthr-g"; mkdir -p "$wg_dir"
    probe_accounts "$wg_dir" false false false
    # No two token POSTs overlapped: every S: line is immediately followed by its own E:.
    while read -r s && read -r e; do
      assert test "${s#S:}" = "${e#E:}"
    done <"$SERLOG"
    assert test "$(grep -c '^S:' "$SERLOG")" = 4
    for a in wg1 wg2 wg3 wg4; do
      assert jq -e '.five_hour.used_percentage == 3 and .auth.status == "ok"' "$limits_dir/$a.json" >/dev/null
    done
    assert jq -e '(.wg1 == null) and (.wg2 == null) and (.wg3 == null) and (.wg4 == null)' "$oauth_attempts_file" >/dev/null
  )

  (
    account_names() { printf 'wb1\n'; }
    curl() {
      local body rt cf n
      case "$*" in
        *'/oauth/token'*)
          body=$(cat)
          rt=$(printf '%s' "$body" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')
          cf="$WORK/wthr-b-tc-$rt"; n=$(cat "$cf" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" >"$cf"
          printf '{"error":"rate_limited"}\n429'
          ;;
        *) return 97 ;;
      esac
    }
    rm -f "$WORK"/wthr-b-tc-*
    seed_expired wb1 rt-wb1
    printf '{}' >"$oauth_attempts_file"
    keep='{"five_hour":{"used_percentage":55,"resets_at":123,"as_of":99,"origin":"usage"},"auth":{"status":"ok","checked_at":1}}'
    printf '%s' "$keep" >"$limits_dir/wb1.json"
    wb_dir="$WORK/wthr-b"; mkdir -p "$wb_dir"
    # A token-endpoint 429 enters a 15m cooldown immediately; convergence does not retry it.
    CLAUDEB_REFRESH_CONVERGE_S=6 probe_accounts "$wb_dir" false false false
    assert test "$(cat "$limits_dir/wb1.json")" = "$keep"
    assert jq -e '.wb1.outcome == "429" and .wb1.strikes == 1' "$oauth_attempts_file" >/dev/null
    assert test "$(cat "$WORK/wthr-b-tc-rt-wb1")" = 1
  )

  # Budget 0 disables retrying entirely: exactly one pass, no convergence retries.
  (
    account_names() { printf 'wc1\n'; }
    curl() {
      local body rt cf n
      case "$*" in
        *'/oauth/token'*)
          body=$(cat)
          rt=$(printf '%s' "$body" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')
          cf="$WORK/wthr-c-tc-$rt"; n=$(cat "$cf" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" >"$cf"
          printf '{"error":"rate_limited"}\n429'
          ;;
        *) return 97 ;;
      esac
    }
    rm -f "$WORK"/wthr-c-tc-*
    seed_expired wc1 rt-wc1
    printf '{}' >"$oauth_attempts_file"
    keep='{"five_hour":{"used_percentage":55,"resets_at":123,"as_of":99,"origin":"usage"},"auth":{"status":"ok","checked_at":1}}'
    printf '%s' "$keep" >"$limits_dir/wc1.json"
    wc_dir="$WORK/wthr-c"; mkdir -p "$wc_dir"
    CLAUDEB_REFRESH_CONVERGE_S=0 probe_accounts "$wc_dir" false false false
    assert test "$(cat "$limits_dir/wc1.json")" = "$keep"
    assert jq -e '.wc1.outcome == "429"' "$oauth_attempts_file" >/dev/null
    assert test "$(cat "$WORK/wthr-c-tc-rt-wc1")" = 1
  )

  # Even if a later call would succeed, convergence leaves a cooling account alone.
  (
    account_names() { printf 'wd1\n'; }
    curl() {
      local out='' prev='' a body rt cf n
      for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
      case "$*" in
        *'/oauth/token'*)
          body=$(cat)
          rt=$(printf '%s' "$body" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')
          cf="$WORK/wthr-d-tc-$rt"; n=$(cat "$cf" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" >"$cf"
          if [ "$n" -ge 3 ]; then printf '{"access_token":"at-%s","expires_in":3600,"refresh_token":"%s"}\n200' "$rt" "$rt"
          else printf '{"error":"rate_limited"}\n429'; fi
          ;;
        *'/api/oauth/usage'*)
          [ -z "$out" ] || printf '%s' '{"five_hour":{"utilization":42,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null},"limits":[]}' >"$out"
          printf '200'
          ;;
        *) return 97 ;;
      esac
    }
    rm -f "$WORK"/wthr-d-tc-*
    seed_expired wd1 rt-wd1
    printf '{}' >"$oauth_attempts_file"
    printf '{"five_hour":{"used_percentage":9,"resets_at":1,"as_of":1,"origin":"usage"},"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/wd1.json"
    wd_dir="$WORK/wthr-d"; mkdir -p "$wd_dir"
    CLAUDEB_REFRESH_CONVERGE_S=240 probe_accounts "$wd_dir" false false false
    assert jq -e '.five_hour.used_percentage == 9' "$limits_dir/wd1.json" >/dev/null
    assert jq -e '.auth.status == "ok" and (.auth | has("cause") | not)' "$limits_dir/wd1.json" >/dev/null
    assert jq -e '.wd1.outcome == "429" and .wd1.strikes == 1' "$oauth_attempts_file" >/dev/null
    assert test "$(cat "$WORK/wthr-d-tc-rt-wd1")" = 1
  )

  # Usage-endpoint 429 on a valid token: convergence must retry off the http field.
  seed_valid() { printf '{"claudeAiOauth":{"refreshToken":"%s","accessToken":"at-valid","expiresAt":%s,"scopes":["a"]}}' "$2" "$(( ($(date +%s) + 3600) * 1000 ))" >"$KC/$(kc_key "$(svc_of "$1")")"; }
  (
    account_names() { printf 'we1\n'; }
    curl() {
      local out='' prev='' a n cf
      for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
      case "$*" in
        *'/api/oauth/usage'*)
          cf="$WORK/wthr-e-uc"; n=$(cat "$cf" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" >"$cf"
          if [ "$n" -ge 3 ]; then
            [ -z "$out" ] || printf '%s' '{"five_hour":{"utilization":63,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null},"limits":[]}' >"$out"
            printf '200'
          else
            [ -z "$out" ] || printf '%s' '{"error":"rate_limited"}' >"$out"; printf '429'
          fi
          ;;
        *) return 97 ;;
      esac
    }
    rm -f "$WORK"/wthr-e-uc
    seed_valid we1 rt-we1
    printf '{}' >"$oauth_attempts_file"
    printf '{"five_hour":{"used_percentage":9,"resets_at":1,"as_of":1,"origin":"usage"},"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/we1.json"
    we_dir="$WORK/wthr-e"; mkdir -p "$we_dir"
    CLAUDEB_REFRESH_CONVERGE_S=240 probe_accounts "$we_dir" false false false
    assert jq -e '.five_hour.used_percentage == 63' "$limits_dir/we1.json" >/dev/null
    assert test "$(cat "$we_dir/we1.display")" = live
    assert jq -e '.we1 == null' "$oauth_attempts_file" >/dev/null
    assert jq -e '.auth.status == "ok" and (.auth | has("cause") | not)' "$limits_dir/we1.json" >/dev/null
    assert test "$(cat "$WORK/wthr-e-uc")" = 3
  )

  # Persistent usage 429, tiny budget: one retry then give up.
  (
    account_names() { printf 'wf1\n'; }
    curl() {
      local out='' prev='' a n cf
      for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
      case "$*" in
        *'/api/oauth/usage'*)
          cf="$WORK/wthr-f-uc"; n=$(cat "$cf" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" >"$cf"
          [ -z "$out" ] || printf '%s' '{"error":"rate_limited"}' >"$out"; printf '429'
          ;;
        *) return 97 ;;
      esac
    }
    rm -f "$WORK"/wthr-f-uc
    seed_valid wf1 rt-wf1
    printf '{}' >"$oauth_attempts_file"
    keep='{"five_hour":{"used_percentage":55,"resets_at":123,"as_of":99,"origin":"usage"},"auth":{"status":"ok","checked_at":1}}'
    printf '%s' "$keep" >"$limits_dir/wf1.json"
    wf_dir="$WORK/wthr-f"; mkdir -p "$wf_dir"
    CLAUDEB_REFRESH_CONVERGE_S=6 probe_accounts "$wf_dir" false false false
    assert test "$(cat "$limits_dir/wf1.json")" = "$keep"
    assert test "$(cat "$wf_dir/wf1.display")" = '!'
    assert jq -e '.wf1 == null' "$oauth_attempts_file" >/dev/null
    assert jq -e '.auth.status == "ok"' "$limits_dir/wf1.json" >/dev/null
    assert test "$(cat "$WORK/wthr-f-uc")" = 2
  )
)

# --- token-upkeep: refresh only tokens at/near expiry, silent on weather, no probes ---
(
  KC="$WORK/tu-keychain"; mkdir -p "$KC"
  TOKLOG="$WORK/tu-token.log"
  kc_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
  svc_of() { printf 'Claude Code-credentials-%s' "$(printf '%s' "$HOME/.claude-profiles/$1" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"; }
  seed_tok() { printf '%s' "$2" >"$KC/$(kc_key "$(svc_of "$1")")"; }
  security() {
    local prev='' svc='' a
    for a in "$@"; do [ "$prev" = -s ] && svc="$a"; prev="$a"; done
    cat "$KC/$(kc_key "$svc")" 2>/dev/null || return 44
  }
  keychain_write() { printf '%s' "$2" >"$KC/$(kc_key "$1")"; }
  account_names() { printf 'tufresh\ntusoon\ntuexpired\ntuweather\ntucooling\n'; }
  curl() {
    local body rt
    case "$*" in
      *'/oauth/token'*)
        body=$(cat)
        rt=$(printf '%s' "$body" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')
        printf '%s\n' "$rt" >>"$TOKLOG"
        if [ "$rt" = rt-weather ]; then printf '{"error":"rate_limited"}\n429'
        else printf '{"access_token":"at-new-%s","expires_in":3600,"refresh_token":"%s"}\n200' "$rt" "$rt"; fi
        ;;
      *) return 97 ;;
    esac
  }
  now_s=$(date +%s); now_ms=$((now_s * 1000))
  fresh_at=$((now_ms + 3600 * 1000))
  soon_at=$((now_ms + 600 * 1000))
  weather_creds='{"claudeAiOauth":{"refreshToken":"rt-weather","accessToken":"at-weather","expiresAt":1,"scopes":["a"]}}'
  seed_tok tufresh   "$(printf '{"claudeAiOauth":{"refreshToken":"rt-fresh","accessToken":"at-fresh","expiresAt":%s,"scopes":["a"]}}' "$fresh_at")"
  seed_tok tusoon    "$(printf '{"claudeAiOauth":{"refreshToken":"rt-soon","accessToken":"at-soon","expiresAt":%s,"scopes":["a"]}}' "$soon_at")"
  seed_tok tuexpired '{"claudeAiOauth":{"refreshToken":"rt-expired","accessToken":"at-expired","expiresAt":1,"scopes":["a"]}}'
  seed_tok tuweather "$weather_creds"
  seed_tok tucooling '{"claudeAiOauth":{"refreshToken":"rt-cooling","accessToken":"at-cooling","expiresAt":1,"scopes":["a"]}}'
  : >"$TOKLOG"
  printf '{"tucooling":{"attempted_at":%s,"outcome":"429","retry_after_until":0,"strikes":2}}\n' "$(date +%s)" >"$oauth_attempts_file"
  tu_err="$WORK/tu.err"
  token_upkeep 2>"$tu_err"
  assert_fails grep -qx rt-fresh "$TOKLOG"
  assert_fails grep -q tufresh "$tu_err"
  assert test "$(cat "$KC/$(kc_key "$(svc_of tufresh)")")" = "$(printf '{"claudeAiOauth":{"refreshToken":"rt-fresh","accessToken":"at-fresh","expiresAt":%s,"scopes":["a"]}}' "$fresh_at")"
  assert grep -qx rt-soon "$TOKLOG"
  assert grep -qx rt-expired "$TOKLOG"
  assert grep -q 'refreshed tusoon' "$tu_err"
  assert grep -q 'refreshed tuexpired' "$tu_err"
  assert jq -e '.claudeAiOauth.accessToken == "at-new-rt-expired"' "$KC/$(kc_key "$(svc_of tuexpired)")" >/dev/null
  assert_fails grep -q 'refreshed tuweather' "$tu_err"
  assert test "$(cat "$KC/$(kc_key "$(svc_of tuweather)")")" = "$weather_creds"
  assert jq -e '.tuweather.outcome == "429"' "$oauth_attempts_file" >/dev/null
  assert_fails grep -qx rt-cooling "$TOKLOG"
  assert jq -e '.tucooling.outcome == "429" and .tucooling.strikes == 2' "$oauth_attempts_file" >/dev/null
  assert_fails test -e "$limits_dir/tuweather.json"
)

# --- token-freeze experiment: robots off the token endpoint, journal every attempt ---
(
  fz_creds='{"claudeAiOauth":{"refreshToken":"rt-fz","accessToken":"at-fz","expiresAt":1,"scopes":["a"]}}'
  cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$fz_creds'
EOF
  fz_curl="$WORK/fz-curl-calls"
  cat >"$FAKE_BIN/curl" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>'$fz_curl'
case "\$*" in
  *'/v1/oauth/token'*) printf '{"access_token":"at-new","expires_in":3600,"refresh_token":"rt-new"}\n200' ;;
  *) exit 97 ;;
esac
EOF
  fz_claude="$WORK/fz-claude-calls"
  cat >"$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
printf 'ran\n' >>'$fz_claude'
exit 0
EOF
  chmod +x "$FAKE_BIN/security" "$FAKE_BIN/curl" "$FAKE_BIN/claude"

  # 1: frozen oauth_refresh — zero curl, frozen-skip journal, no state change, no verdict.
  : >"$fz_curl"; : >"$token_attempts_file"
  printf '{"alpha":{"attempted_at":%s,"outcome":"429","retry_after_until":0,"strikes":2}}\n' "$now" >"$oauth_attempts_file"
  printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/alpha.json"
  printf '{"started_at":%s,"reason":"token-freeze experiment"}\n' "$now" >"$token_freeze_file"
  if oauth_refresh alpha svc "$fz_creds" >/dev/null 2>&1; then fz_rc=0; else fz_rc=$?; fi
  assert test "$fz_rc" -eq 76
  assert_fails test -s "$fz_curl"
  assert jq -e '.alpha.outcome == "429" and .alpha.strikes == 2' "$oauth_attempts_file" >/dev/null
  assert jq -e '.auth.status == "ok"' "$limits_dir/alpha.json" >/dev/null
  assert jq -se 'any(.[]; .kind == "curl-refresh" and .outcome == "frozen-skip" and .account == "alpha")' "$token_attempts_file" >/dev/null

  # 2: frozen token-upkeep exits 0, journals kind upkeep, touches nothing.
  : >"$fz_curl"; : >"$token_attempts_file"
  fz_tu_rc=0
  token_upkeep >/dev/null 2>&1 || fz_tu_rc=$?
  assert test "$fz_tu_rc" -eq 0
  assert_fails test -s "$fz_curl"
  assert jq -se 'any(.[]; .kind == "upkeep" and .outcome == "frozen-skip")' "$token_attempts_file" >/dev/null

  # 3: frozen non-explicit warm skips every account successfully, one journal line each, no session.
  : >"$fz_claude"; : >"$token_attempts_file"
  # The accounts have to exist: a freeze skips real accounts, and reporting a typo as skipped
  # is what the existence check ahead of the skip prevents.
  printf 'tok' >"$tokens_dir/fzA"; printf 'tok' >"$tokens_dir/fzB"
  account_names() { printf 'fzA\nfzB\n'; }
  is_disabled() { return 1; }
  fz_warm_rc=0
  warm_accounts >/dev/null 2>"$WORK/fz-warm.err" || fz_warm_rc=$?
  assert test "$fz_warm_rc" -eq 0
  assert_fails test -s "$fz_claude"
  assert jq -se '[.[] | select(.kind == "warm" and .outcome == "frozen-skip")] | length == 2' "$token_attempts_file" >/dev/null
  assert jq -se 'any(.[]; .kind == "warm" and .account == "fzA")' "$token_attempts_file" >/dev/null
  assert grep -q 'warm skipped' "$WORK/fz-warm.err"

  # 4: frozen single-explicit (menu Hard-refresh) warm still runs its CLI session.
  : >"$fz_claude"; : >"$token_attempts_file"
  account_names() { printf 'fzM\n'; }
  touch "$CLAUDEB_DIR/tokens/fzM"
  CLAUDEB_WARM_USER_EXPLICIT=true warm_accounts fzM >/dev/null 2>&1 || true
  assert test -s "$fz_claude"
  rm -f "$CLAUDEB_DIR/tokens/fzM"

  # 5: expired `until` behaves unfrozen — curl runs, rc is a real verdict not 76.
  : >"$fz_curl"; : >"$token_attempts_file"
  printf '{}' >"$oauth_attempts_file"
  printf '{"started_at":%s,"until":%s,"reason":"x"}\n' "$((now - 7200))" "$((now - 3600))" >"$token_freeze_file"
  if oauth_refresh alpha svc "$fz_creds" >/dev/null 2>&1; then fz_er=0; else fz_er=$?; fi
  assert test -s "$fz_curl"
  assert test "$fz_er" -ne 76

  # 6: normal (unfrozen) outcomes journal too — success, 429, adopt, warm; begin markers do not.
  rm -f "$token_freeze_file"
  : >"$token_attempts_file"
  printf '{}' >"$oauth_attempts_file"
  oauth_attempt_update j1 success
  oauth_attempt_update j2 429 0
  oauth_attempt_update j3 success-adopted 0
  oauth_attempt_update j4 warm-failed 0 0 timeout
  oauth_attempt_update j5 attempting 0
  oauth_attempt_update j5 warming 0
  CLAUDEB_JOURNAL_KIND=warm oauth_attempt_update jwarm success
  assert jq -se 'any(.[]; .account == "j1" and .kind == "curl-refresh" and .outcome == "success")' "$token_attempts_file" >/dev/null
  assert jq -se 'any(.[]; .account == "j2" and .kind == "curl-refresh" and .outcome == "429" and .http == "429")' "$token_attempts_file" >/dev/null
  assert jq -se 'any(.[]; .account == "j3" and .kind == "adopt" and .outcome == "success-adopted")' "$token_attempts_file" >/dev/null
  assert jq -se 'any(.[]; .account == "j4" and .kind == "warm" and .outcome == "warm-failed")' "$token_attempts_file" >/dev/null
  assert_fails jq -se 'any(.[]; .account == "j5")' "$token_attempts_file" >/dev/null
  # A CLI-warm success routes through the funnel with a caller kind hint → kind warm.
  assert jq -se 'any(.[]; .account == "jwarm" and .kind == "warm" and .outcome == "success")' "$token_attempts_file" >/dev/null
  fz_real_failure_rc=0
  warm_accounts missing-account >/dev/null 2>&1 || fz_real_failure_rc=$?
  assert test "$fz_real_failure_rc" -eq 1
) || exit 1

# --- token-freeze: heal writes no verdict from pre-freeze token-endpoint state ---
(
  printf '{"started_at":%s,"reason":"x"}\n' "$now" >"$token_freeze_file"
  account_names() { printf 'fzh\n'; }
  is_disabled() { return 1; }
  touch "$CLAUDEB_DIR/tokens/fzh"
  fzh_fresh='{"claudeAiOauth":{"refreshToken":"rt-h","accessToken":"at-h","expiresAt":9999999999999,"scopes":["a"]}}'
  cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$fzh_fresh'
EOF
  chmod +x "$FAKE_BIN/security"
  hd="$WORK/fz-heal"; mkdir -p "$hd"

  # (a) a stale pre-freeze `revoked` + a frozen probe (HTTP 000) writes no verdict.
  probe_one() { printf 'no-spend 255 000\n' >"$2/$1.result"; }
  printf '{"fzh":{"attempted_at":%s,"outcome":"revoked","retry_after_until":%s,"credentials_expires_at":1}}\n' "$((now - 100))" "$((now + 21600))" >"$oauth_attempts_file"
  printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/fzh.json"
  heal_one "$hd" fzh 2>"$WORK/fz-heal-a.err"
  assert jq -e '.auth.status == "ok" and (.auth | has("cause") | not)' "$limits_dir/fzh.json" >/dev/null
  assert grep -q 'frozen' "$WORK/fz-heal-a.err"

  # (b) a fresh-token 401 is endpoint-independent live evidence → still affirmative.
  probe_one() { printf 'no-spend 0 401\n' >"$2/$1.result"; }
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/fzh.json"
  heal_one "$hd" fzh 2>/dev/null
  assert jq -e '.auth.status == "expired"' "$limits_dir/fzh.json" >/dev/null
  rm -f "$token_freeze_file" "$CLAUDEB_DIR/tokens/fzh"
) || exit 1

touch "$CLAUDEB_DIR/tokens/eta"
(
  ETA_WARM_LOG="$WORK/eta-warm.log"
  ETA_TOKEN_LOG="$WORK/eta-token-post.log"
  : >"$ETA_WARM_LOG"
  : >"$ETA_TOKEN_LOG"
  export ETA_WARM_LOG ETA_TOKEN_LOG
  eta_fresh_creds='{"claudeAiOauth":{"refreshToken":"rt-eta","accessToken":"at-eta","expiresAt":9999999999999,"scopes":["a"]}}'
  cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$eta_fresh_creds'
EOF
  cat >"$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf 'warm\n' >>"$ETA_WARM_LOG"
echo 'error: 429 too many requests' >&2
exit 1
EOF
  cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'/v1/oauth/token'*)
    printf 'token\n' >>"$ETA_TOKEN_LOG"
    printf '{"error":"rate_limited"}\n429'
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$FAKE_BIN/security" "$FAKE_BIN/claude" "$FAKE_BIN/curl"
  heal_dir_eta="$WORK/heal-capacity-skip"
  mkdir -p "$heal_dir_eta"
  printf '{}' >"$oauth_attempts_file"
  eta_snapshot_before='{"marker":"untouched","five_hour":{"used_percentage":5},"auth":{"status":"expired","checked_at":1,"cause":"stale"}}'
  printf '%s' "$eta_snapshot_before" >"$limits_dir/eta.json"
  heal_one "$heal_dir_eta" eta
  assert test "$(grep -cx warm "$ETA_WARM_LOG")" = 2
  assert_fails test -s "$ETA_TOKEN_LOG"
  assert jq -e '.marker == "untouched" and .five_hour.used_percentage == 5
    and .auth.status == "ok" and (.auth | has("cause") | not)' "$limits_dir/eta.json" >/dev/null
  assert test "$(jq -r '.eta.warm_cause' "$oauth_attempts_file")" = warm-429
  assert_fails test -f "$heal_dir_eta/eta.display"
)

# --- start-windows opens a fresh 5h window and the reconcile read locks in the
# new resets_at within the same invocation (bug: cache kept the expired reset) ---
sw_past_epoch=$((now - 600))
sw_future_epoch=$((now + 18000))
sw_past_iso=$(date -u -r "$sw_past_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$sw_past_epoch" '+%Y-%m-%dT%H:%M:%SZ')
sw_creds='{"claudeAiOauth":{"refreshToken":"rt-sw","accessToken":"at-sw","expiresAt":9999999999999,"scopes":["a"]}}'
printf 'token-epsilon' >"$CLAUDEB_DIR/tokens/epsilon"
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$sw_creds'
EOF
# usage always reports the still-expiring window; only the window-opening message
# carries the fresh reset — so a truthful reconcile must keep the header value.
cat >"$FAKE_BIN/curl" <<EOF
#!/usr/bin/env bash
out=''; dfile=''; previous=''
for argument in "\$@"; do
  case "\$previous" in
    -o) out="\$argument" ;;
    -D) dfile="\$argument" ;;
  esac
  previous="\$argument"
done
case "\$*" in
  *'/v1/messages'*)
    [ -z "\$dfile" ] || printf 'anthropic-ratelimit-unified-status: allowed\r\nanthropic-ratelimit-unified-5h-utilization: 0.05\r\nanthropic-ratelimit-unified-5h-reset: $sw_future_epoch\r\n' >"\$dfile"
    printf '200'
    ;;
  *'/api/oauth/usage'*)
    [ -z "\$out" ] || printf '%s' '{"five_hour":{"utilization":5,"resets_at":"$sw_past_iso"},"seven_day":{"utilization":2,"resets_at":null},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":3,"resets_at":null}]}' >"\$out"
    printf '200'
    ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/curl"
(
  account_names() { printf 'epsilon\n'; }
  sw_dir="$WORK/start-windows"
  mkdir -p "$sw_dir"
  printf '{}' >"$limits_dir/epsilon.json"
  probe_accounts "$sw_dir" false true false
  assert test "$(jq -r '.five_hour.resets_at' "$limits_dir/epsilon.json")" = "$sw_future_epoch"
  assert jq -e --argjson now "$now" '.five_hour.resets_at > $now and .five_hour.origin == "headers" and .auth.status == "ok"' "$limits_dir/epsilon.json" >/dev/null
)

# --- start-windows: a disabled account is skipped with an explicit, non-silent
# cause instead of a bare `continue` ---
(
  account_names() { printf 'theta\n'; }
  probe_one() { printf 'usage 0 200\n' >"$2/$1.result"; printf '{}' >"$2/$1.usage"; }
  printf 'theta\n' >"$disabled_file"
  theta_dir="$WORK/start-windows-disabled"
  mkdir -p "$theta_dir"
  printf '{}' >"$limits_dir/theta.json"
  probe_accounts "$theta_dir" false true false 2>"$WORK/theta.err"
  assert grep -q 'claudeb: theta: disabled; window not started' "$WORK/theta.err"
  : >"$disabled_file"
)

# --- the paid haiku warm fallback is off unless explicitly opted in ---
PAID_LOG="$WORK/paid-warm.log"
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s' '$sw_creds'
EOF
printf 'token-zeta' >"$CLAUDEB_DIR/tokens/zeta"
printf '{}' >"$oauth_attempts_file"
(
  profile_command() { prepared_profile_dir="$WORK/zeta-profile"; mkdir -p "$prepared_profile_dir"; return 0; }
  run_warm_session() { shift 3; printf '%s\n' "$*" >>"$PAID_LOG"; return 1; }
  probe_one() { printf 'no-spend 1 500\n' >"$2/$1.result"; }
  : >"$PAID_LOG"
  warm_accounts zeta >/dev/null 2>&1 || true
  assert grep -qx /usage "$PAID_LOG"
  assert_fails grep -q haiku "$PAID_LOG"
  : >"$PAID_LOG"
  CLAUDEB_WARM_ALLOW_PAID=true warm_accounts zeta >/dev/null 2>&1 || true
  assert grep -q haiku "$PAID_LOG"
)

(
  profile_command() { prepared_profile_dir="$WORK/zeta-profile"; mkdir -p "$prepared_profile_dir"; return 0; }
  warm_credentials="$WORK/zeta-credentials.json"
  warm_refresh_calls="$WORK/zeta-refresh-calls"
  warm_probe_calls="$WORK/zeta-probe-calls"
  expired_warm_creds='{"claudeAiOauth":{"refreshToken":"rt-zeta","accessToken":"at-expired","expiresAt":1,"scopes":["a"]}}'
  security() { cat "$warm_credentials"; }
  keychain_write() { printf '%s' "$2" >"$warm_credentials"; }
  curl() {
    printf 'refresh\n' >>"$warm_refresh_calls"
    printf '%s\n%s' "$refresh_body" "$refresh_http"
  }
  probe_one() {
    printf 'probe\n' >>"$warm_probe_calls"
    printf 'usage 0 200\n' >"$2/$1.result"
    printf '%s\n' '{"five_hour":{"utilization":44,"resets_at":null},"seven_day":{"utilization":22,"resets_at":null},"limits":[]}' >"$2/$1.usage"
  }
  pinned_asof=$((now - 900))
  printf '{"five_hour":{"used_percentage":9,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' \
    "$((now + 3600))" "$pinned_asof" >"$limits_dir/zeta.json"

  run_warm_session() { return 7; }
  printf '{"zeta":{"attempted_at":%s,"outcome":"revoked","retry_after_until":%s,"credentials_expires_at":1}}\n' \
    "$now" "$((now + 21600))" >"$oauth_attempts_file"
  if warm_accounts zeta >/dev/null 2>"$WORK/warm-prior-revoked.err"; then fail "prior-revoked warm unexpectedly succeeded"; fi
  assert grep -qx 'claudeb: warm failed account=zeta cause=warm-failed' "$WORK/warm-prior-revoked.err"
  assert test "$(wc -l <"$WORK/warm-prior-revoked.err" | tr -d ' ')" = 1
  assert test "$(jq -r '.five_hour.as_of' "$limits_dir/zeta.json")" = "$pinned_asof"
  assert test "$(oauth_warm_cause zeta)" = warm-failed
  assert_fails test "$(oauth_warm_cause zeta)" = needs-relogin
  touch "$WORK/regression-prior-revoked-generic"

  printf '{}' >"$oauth_attempts_file"
  run_warm_session() { printf 'HTTP 429 rate limit\n' >"$3"; return 7; }
  if warm_accounts zeta >/dev/null 2>"$WORK/warm-429.err"; then fail "429 warm unexpectedly succeeded"; fi
  assert grep -qx 'claudeb: warm failed account=zeta cause=warm-429' "$WORK/warm-429.err"
  assert test "$(wc -l <"$WORK/warm-429.err" | tr -d ' ')" = 1

  run_warm_session() { return 0; }
  for refresh_http in 429 529; do
    printf '%s' "$expired_warm_creds" >"$warm_credentials"
    : >"$warm_refresh_calls"
    : >"$warm_probe_calls"
    refresh_body='{"error":"overloaded"}'
    printf '{}' >"$oauth_attempts_file"
    printf '{"marker":"untouched","auth":{"status":"ok","checked_at":1}}' >"$limits_dir/zeta.json"
    if warm_accounts zeta >/dev/null 2>"$WORK/warm-refresh-$refresh_http.err"; then fail "refresh $refresh_http warm unexpectedly succeeded"; fi
    warm_refresh_cause=$(oauth_warm_cause zeta)
    assert warm_class_is_capacity "$warm_refresh_cause"
    assert jq -e '.marker == "untouched" and .auth.status == "ok"' "$limits_dir/zeta.json" >/dev/null
    assert_fails test "$warm_refresh_cause" = needs-relogin
    assert_fails jq -e '.zeta.warm_cause == "needs-relogin"' "$oauth_attempts_file" >/dev/null
    assert test "$(wc -l <"$warm_refresh_calls" | tr -d ' ')" = 1
    assert_fails test -s "$warm_probe_calls"
    assert test "$(oauth_heal_backoff_until zeta)" -gt "$(date +%s)"
  done
  touch "$WORK/regression-refresh-capacity"

  printf '%s' "$expired_warm_creds" >"$warm_credentials"
  : >"$warm_refresh_calls"
  : >"$warm_probe_calls"
  refresh_body='{"error":"invalid_grant"}'
  refresh_http=400
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/zeta.json"
  if warm_accounts zeta >/dev/null 2>"$WORK/warm-refresh-revoked.err"; then fail "revoked refresh warm unexpectedly succeeded"; fi
  assert grep -q 'cause=needs-relogin' "$WORK/warm-refresh-revoked.err"
  assert test "$(oauth_warm_cause zeta)" = needs-relogin
  assert test "$(oauth_backoff_outcome zeta)" = revoked
  assert jq -e '.auth.status == "expired" and .auth.cause == "needs re-login"' "$limits_dir/zeta.json" >/dev/null
  assert_fails test -s "$warm_probe_calls"
  touch "$WORK/regression-refresh-revoked"

  for empty_case in login-text successful-session; do
    : >"$warm_credentials"
    : >"$warm_refresh_calls"
    : >"$warm_probe_calls"
    printf '{}' >"$oauth_attempts_file"
    printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/zeta.json"
    if [ "$empty_case" = login-text ]; then
      run_warm_session() { printf 'Please run /login\n' >"$3"; return 7; }
    else
      run_warm_session() { return 0; }
    fi
    if warm_accounts zeta >/dev/null 2>"$WORK/warm-empty-$empty_case.err"; then fail "empty-Keychain $empty_case warm unexpectedly succeeded"; fi
    assert grep -q 'cause=needs-relogin' "$WORK/warm-empty-$empty_case.err"
    assert test "$(oauth_warm_cause zeta)" = needs-relogin
    assert jq -e '.auth.status == "expired" and .auth.cause == "needs re-login"' "$limits_dir/zeta.json" >/dev/null
    assert_fails test -s "$warm_refresh_calls"
    assert_fails test -s "$warm_probe_calls"
  done
  touch "$WORK/regression-empty-keychain"

  printf '%s' "$expired_warm_creds" >"$warm_credentials"
  : >"$warm_refresh_calls"
  refresh_body='{"access_token":"at-fresh","refresh_token":"rt-fresh","expires_in":3600}'
  refresh_http=200
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"expired","checked_at":1,"cause":"stale"}}' >"$limits_dir/zeta.json"
  run_warm_session() { printf 'Please run /login\n' >"$3"; return 7; }
  if warm_accounts zeta >/dev/null 2>"$WORK/warm-login-noise.err"; then fail "login-text warm unexpectedly succeeded"; fi
  assert grep -qx 'claudeb: warm failed account=zeta cause=warm-failed' "$WORK/warm-login-noise.err"
  assert test "$(oauth_warm_cause zeta)" = warm-failed
  assert warm_class_is_capacity "$(oauth_warm_cause zeta)"
  assert_fails jq -e '.zeta.warm_cause == "needs-relogin"' "$oauth_attempts_file" >/dev/null
  assert jq -e '.auth.status == "ok" and (.auth | has("cause") | not)' "$limits_dir/zeta.json" >/dev/null
  assert test "$(wc -l <"$warm_refresh_calls" | tr -d ' ')" = 1
  touch "$WORK/regression-login-refresh-success"

  printf '%s' "$expired_warm_creds" >"$warm_credentials"
  : >"$warm_refresh_calls"
  : >"$warm_probe_calls"
  printf '{}' >"$oauth_attempts_file"
  printf '{}' >"$limits_dir/zeta.json"
  : >"$token_attempts_file"
  run_warm_session() { return 0; }
  assert warm_accounts zeta >/dev/null 2>"$WORK/warm-refresh-success.err"
  assert test "$(wc -l <"$warm_refresh_calls" | tr -d ' ')" = 1
  assert test "$(wc -l <"$warm_probe_calls" | tr -d ' ')" = 1
  assert jq -e '.five_hour.used_percentage == 44 and .auth.status == "ok"' "$limits_dir/zeta.json" >/dev/null
  assert test "$(oauth_backoff_outcome zeta)" = ''
  # The CLI-only warm success journals kind warm (the real curl refresh on this
  # path journals its own curl-refresh line separately).
  assert jq -se 'any(.[]; .account == "zeta" and .kind == "warm" and .outcome == "success")' "$token_attempts_file" >/dev/null
)

assert test -f "$WORK/regression-prior-revoked-generic"
assert test -f "$WORK/regression-refresh-capacity"
assert test -f "$WORK/regression-refresh-revoked"
assert test -f "$WORK/regression-empty-keychain"
assert test -f "$WORK/regression-login-refresh-success"

for command in curl security claude; do
  printf '#!/usr/bin/env bash\nexit 97\n' >"$FAKE_BIN/$command"
  chmod +x "$FAKE_BIN/$command"
done

# --- warm --start-window: open an expired 5h window after a good warm ---
printf 'token-swin' >"$CLAUDEB_DIR/tokens/swin"
(
  sw_warm_creds=$(printf '{"claudeAiOauth":{"refreshToken":"rt-swin","accessToken":"at-swin","expiresAt":%s,"scopes":["a"]}}' "$((($(date +%s) + 7200) * 1000))")
  security() { printf '%s' "$sw_warm_creds"; }
  profile_command() { prepared_profile_dir="$WORK/swin-profile"; mkdir -p "$prepared_profile_dir"; return 0; }
  run_warm_session() { return 0; }
  sw_probe_calls="$WORK/swin-probe-calls"
  sw_ping_calls="$WORK/swin-ping-calls"
  sw_usage_resets=null
  probe_one() {
    printf 'probe\n' >>"$sw_probe_calls"
    printf 'usage 0 200\n' >"$2/$1.result"
    printf '{"five_hour":{"utilization":0,"resets_at":%s},"seven_day":{"utilization":22,"resets_at":null},"limits":[]}\n' \
      "$sw_usage_resets" >"$2/$1.usage"
  }
  sw_now=$(date +%s)
  sw_ping_reset=$((sw_now + 18000))
  sw_ping_out='0 200'
  messages_probe() {
    printf 'ping\n' >>"$sw_ping_calls"
    printf 'anthropic-ratelimit-unified-status: allowed\nanthropic-ratelimit-unified-5h-utilization: 0.01\nanthropic-ratelimit-unified-5h-reset: %s\n' \
      "$sw_ping_reset" >"$2/$1.headers"
    printf '%s' "$sw_ping_out"
  }

  : >"$sw_probe_calls"; : >"$sw_ping_calls"
  printf '{}' >"$oauth_attempts_file"
  printf '{}' >"$limits_dir/swin.json"
  warm_accounts --start-window swin >"$WORK/swin-sw.out" 2>"$WORK/swin-sw.err" \
    || fail "start-window warm failed: $(cat "$WORK/swin-sw.out" "$WORK/swin-sw.err")"
  assert grep -qx 'swin: 5h window started' "$WORK/swin-sw.out"
  assert test "$(wc -l <"$sw_ping_calls" | tr -d ' ')" = 1
  # Initial usage read + the post-ping re-read; headers win five_hour back over the lagging usage.
  assert test "$(wc -l <"$sw_probe_calls" | tr -d ' ')" = 2
  assert jq -e --argjson reset "$sw_ping_reset" \
    '.five_hour.resets_at == $reset and .five_hour.origin == "headers" and .seven_day.used_percentage == 22 and .auth.status == "ok"' \
    "$limits_dir/swin.json" >/dev/null

  # Live window: no ping, one usage read.
  : >"$sw_probe_calls"; : >"$sw_ping_calls"
  printf '{}' >"$oauth_attempts_file"
  printf '{}' >"$limits_dir/swin.json"
  sw_live_epoch=$((sw_now + 3600))
  sw_usage_resets="\"$(date -u -r "$sw_live_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$sw_live_epoch" '+%Y-%m-%dT%H:%M:%SZ')\""
  warm_accounts --start-window swin >"$WORK/swin-live.out" 2>&1 \
    || fail "live-window warm failed: $(cat "$WORK/swin-live.out")"
  assert_fails test -s "$sw_ping_calls"
  assert test "$(wc -l <"$sw_probe_calls" | tr -d ' ')" = 1
  assert_fails grep -q 'window started' "$WORK/swin-live.out"

  # No flag: expired window is left alone.
  : >"$sw_probe_calls"; : >"$sw_ping_calls"
  printf '{}' >"$oauth_attempts_file"
  printf '{}' >"$limits_dir/swin.json"
  sw_usage_resets=null
  warm_accounts swin >"$WORK/swin-noflag.out" 2>&1 \
    || fail "flagless warm failed: $(cat "$WORK/swin-noflag.out")"
  assert_fails test -s "$sw_ping_calls"

  # Ping weather: warn on stderr, warm still succeeds, no auth verdict, snapshot kept.
  : >"$sw_probe_calls"; : >"$sw_ping_calls"
  printf '{}' >"$oauth_attempts_file"
  printf '{}' >"$limits_dir/swin.json"
  sw_ping_out='0 429'
  warm_accounts --start-window swin >"$WORK/swin-weather.out" 2>"$WORK/swin-weather.err" \
    || fail "weather-ping warm failed: $(cat "$WORK/swin-weather.out" "$WORK/swin-weather.err")"
  assert grep -q 'swin: window-open probe failed (weather); 5h window unconfirmed' "$WORK/swin-weather.err"
  assert grep -q 'swin: warmed' "$WORK/swin-weather.out"
  assert jq -e '.five_hour.resets_at == 0 and .auth.status == "ok"' "$limits_dir/swin.json" >/dev/null
)
rm -f "$CLAUDEB_DIR/tokens/swin" "$limits_dir/swin.json"

# --- heal_expired: disabled accounts and actionable fallback causes ---
WARM_CALLS="$WORK/warm-calls"
warm_accounts() {
  printf '%s\n' "$1" >>"$WARM_CALLS"
  case "$1" in
    alpha) mark_auth "$1" ok; oauth_attempt_update "$1" success 0; return 0 ;;
    *) oauth_attempt_update "$1" warm-failed 0; return 1 ;;
  esac
}
probe_one() {
  case "$1" in
    beta) oauth_attempt_update "$1" 429 "$((now + 720))" ;;
  esac
  printf 'no-spend 0 401\n' >"$2/$1.result"
}
account_names() { printf 'alpha\nbeta\ngamma\ndelta\n'; }
heal_dir="$WORK/heal"
mkdir -p "$heal_dir"
for n in alpha beta gamma delta; do
  printf 'auth!\n' >"$heal_dir/$n.display"
  printf '{"auth":{"status":"expired","checked_at":1}}' >"$limits_dir/$n.json"
done
printf 'alpha\n' >"$disabled_file"
now=$(date +%s)
printf '{"delta":{"attempted_at":%s,"outcome":"revoked","retry_after_until":0}}\n' "$now" >"$oauth_attempts_file"
: >"$WARM_CALLS"
heal_expired "$heal_dir"
assert test "$(cat "$heal_dir/alpha.display")" = live
# One concurrent heal pass: the healed account carries no expired auth (so it is
# never named in refresh_error); a genuine revocation gets an actionable cause,
# while weather-shaped failures (beta: 429 token-refresh backoff; gamma: probe 401
# with an unresolved refresh) leave the prior verdict byte-untouched — no re-stamp
# of checked_at, no invented cause on no evidence.
assert test "$(jq -r '.auth.status' "$limits_dir/alpha.json")" = ok
assert jq -e '.auth.status == "expired" and .auth.checked_at == 1 and (.auth | has("cause") | not)' "$limits_dir/beta.json" >/dev/null
assert jq -e '.auth.status == "expired" and .auth.checked_at == 1 and (.auth | has("cause") | not)' "$limits_dir/gamma.json" >/dev/null
assert test "$(jq -r '.auth.cause' "$limits_dir/delta.json")" = 'needs re-login'
assert grep -qx delta "$WARM_CALLS"

# --- heal_one auth verdicts require current-run evidence (the auth-only-on-
# evidence invariant, third live regression). Warm has failed; the fallback probe
# 401 and the pre-existing expired verdict must not, on their own, produce or
# refresh an expired auth field. ---
stale_creds='{"claudeAiOauth":{"refreshToken":"rt-heal","accessToken":"at-heal","expiresAt":1,"scopes":["a"]}}'
fresh_creds='{"claudeAiOauth":{"refreshToken":"rt-heal","accessToken":"at-heal","expiresAt":9999999999999,"scopes":["a"]}}'

# (a) stale access token + probe 401 + token endpoint 429 (weather) → NO auth write.
(
  account_names() { printf 'ha1\n'; }
  warm_accounts() { return 1; }
  oauth_warm_cause() { printf '\n'; }
  probe_one() { printf 'no-spend 0 401\n' >"$2/$1.result"; }
  security() { printf '%s' "$stale_creds"; }
  curl() { case "$*" in *'/v1/oauth/token'*) printf '{"error":"rate_limited"}\n429' ;; *) exit 97 ;; esac; }
  ha_dir="$WORK/heal-a-weather"; mkdir -p "$ha_dir"
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"expired","checked_at":424242,"cause":"friday 401"}}' >"$limits_dir/ha1.json"
  heal_one "$ha_dir" ha1 2>/dev/null
  assert jq -e '.auth.status == "expired" and .auth.checked_at == 424242 and .auth.cause == "friday 401"' "$limits_dir/ha1.json" >/dev/null
)

# (b) stale access token + probe 401 + token endpoint invalid_grant → expired IS written.
(
  account_names() { printf 'ha2\n'; }
  warm_accounts() { return 1; }
  oauth_warm_cause() { printf '\n'; }
  probe_one() { printf 'no-spend 0 401\n' >"$2/$1.result"; }
  security() { printf '%s' "$stale_creds"; }
  curl() { case "$*" in *'/v1/oauth/token'*) printf '{"error":"invalid_grant"}\n400' ;; *) exit 97 ;; esac; }
  ha_dir="$WORK/heal-a-revoked"; mkdir -p "$ha_dir"
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/ha2.json"
  heal_one "$ha_dir" ha2 2>/dev/null
  assert jq -e '.auth.status == "expired" and .auth.checked_at > 1 and .auth.cause == "warm failed, refresh token rejected"' "$limits_dir/ha2.json" >/dev/null
)

# (c) FRESH access token + probe 401 → expired written (true positive preserved).
(
  account_names() { printf 'ha3\n'; }
  warm_accounts() { return 1; }
  oauth_warm_cause() { printf '\n'; }
  probe_one() { printf 'no-spend 0 401\n' >"$2/$1.result"; }
  security() { printf '%s' "$fresh_creds"; }
  curl() { exit 97; }
  ha_dir="$WORK/heal-a-fresh"; mkdir -p "$ha_dir"
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/ha3.json"
  heal_one "$ha_dir" ha3 2>/dev/null
  assert jq -e '.auth.status == "expired" and .auth.cause == "warm failed, fresh token rejected (401)"' "$limits_dir/ha3.json" >/dev/null
)

# (d) weather cycle (token-refresh backoff active) over a snapshot already carrying
# expired(checked_at=T0) → checked_at STILL T0 (the re-stamp regression pin).
(
  account_names() { printf 'ha4\n'; }
  warm_accounts() { return 1; }
  oauth_warm_cause() { printf '\n'; }
  token_needs_refresh() { return 0; }
  wnow=$(date +%s)
  probe_one() { oauth_attempt_update "$1" 429 "$((wnow + 600))"; printf 'no-spend 0 401\n' >"$2/$1.result"; }
  ha_dir="$WORK/heal-b-restamp"; mkdir -p "$ha_dir"
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"expired","checked_at":55555,"cause":"friday 401"}}' >"$limits_dir/ha4.json"
  heal_one "$ha_dir" ha4 2>/dev/null
  assert jq -e '.auth.status == "expired" and .auth.checked_at == 55555 and .auth.cause == "friday 401"' "$limits_dir/ha4.json" >/dev/null
)

# --- no-refresh contexts and the messages probe never write an auth verdict on
# unproven evidence: a hard-expired token with refresh disallowed is scheduled
# expiry, and a messages-probe 401 is affirmative only when the token was fresh. ---

# probe_one with allow_refresh=false + hard-expired token → auth field untouched.
(
  security() { printf '%s' "$stale_creds"; }
  nr_dir="$WORK/probe-norefresh"; mkdir -p "$nr_dir"
  printf '{"auth":{"status":"ok","checked_at":777}}' >"$limits_dir/nr1.json"
  probe_one nr1 "$nr_dir" false false
  assert jq -e '.auth.status == "ok" and .auth.checked_at == 777' "$limits_dir/nr1.json" >/dev/null
  read -r nr_s nr_r nr_h < "$nr_dir/nr1.result"
  assert test "$nr_h" = 401
)

# messages-probe 401, stale token, token endpoint 429 (weather) → NO auth write.
(
  security() { printf '%s' "$stale_creds"; }
  curl() { case "$*" in *'/v1/messages'*) printf '401' ;; *'/v1/oauth/token'*) printf '{"error":"rate_limited"}\n429' ;; *) exit 97 ;; esac; }
  printf 'tok' >"$tokens_dir/mp2"
  mp_dir="$WORK/mp-weather"; mkdir -p "$mp_dir"
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"expired","checked_at":222,"cause":"seed"}}' >"$limits_dir/mp2.json"
  messages_probe_and_mark mp2 "$mp_dir" false 2>/dev/null || true
  assert jq -e '.auth.status == "expired" and .auth.checked_at == 222 and .auth.cause == "seed"' "$limits_dir/mp2.json" >/dev/null
)

# messages-probe 401, stale token, token endpoint invalid_grant → expired written.
(
  security() { printf '%s' "$stale_creds"; }
  curl() { case "$*" in *'/v1/messages'*) printf '401' ;; *'/v1/oauth/token'*) printf '{"error":"invalid_grant"}\n400' ;; *) exit 97 ;; esac; }
  printf 'tok' >"$tokens_dir/mp3"
  mp_dir="$WORK/mp-revoked"; mkdir -p "$mp_dir"
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/mp3.json"
  messages_probe_and_mark mp3 "$mp_dir" false 2>/dev/null || true
  assert jq -e '.auth.status == "expired" and .auth.checked_at > 1 and .auth.cause == "messages probe 401, refresh token rejected"' "$limits_dir/mp3.json" >/dev/null
)

# messages-probe 401, FRESH token → expired written (true positive preserved).
(
  security() { printf '%s' "$fresh_creds"; }
  curl() { case "$*" in *'/v1/messages'*) printf '401' ;; *) exit 97 ;; esac; }
  printf 'tok' >"$tokens_dir/mp4"
  mp_dir="$WORK/mp-fresh"; mkdir -p "$mp_dir"
  printf '{}' >"$oauth_attempts_file"
  printf '{"auth":{"status":"ok","checked_at":1}}' >"$limits_dir/mp4.json"
  messages_probe_and_mark mp4 "$mp_dir" false 2>/dev/null || true
  assert jq -e '.auth.status == "expired"' "$limits_dir/mp4.json" >/dev/null
)

# Re-source probe_one and related functions for the logged-out tests
unset -f probe_one warm_accounts oauth_warm_cause account_names || true
source "$SCRIPT"

# --- logged-out detection: affirmative local evidence (an empty-token CLI wipe or
# keychain item-not-found) marks auth_needed and skips ALL token operations; any
# other keychain error is weather and never writes a verdict or blanks old buckets. ---

# readable-but-empty-token wipe → auth_needed, zero curl, no oauth-attempt, buckets kept.
(
  lo_creds='{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"scopes":[]}}'
  lo_curl="$WORK/lo-curl.log"; : >"$lo_curl"
  security() { printf '%s' "$lo_creds"; }
  curl() { printf 'curl %s\n' "$*" >>"$lo_curl"; exit 97; }
  lo_dir="$WORK/probe-loggedout"; mkdir -p "$lo_dir"
  printf '{"auth":{"status":"ok","checked_at":1},"five_hour":{"used_percentage":5,"resets_at":0,"as_of":123,"origin":"usage"}}' >"$limits_dir/lo1.json"
  printf '{}' >"$oauth_attempts_file"
  probe_one lo1 "$lo_dir" false true
  assert test "$(cat "$lo_dir/lo1.result")" = 'logged-out 0 000'
  assert jq -e '.auth_needed == true and (has("auth") | not)' "$limits_dir/lo1.json" >/dev/null
  assert jq -e '.five_hour.used_percentage == 5 and .five_hour.origin == "usage"' "$limits_dir/lo1.json" >/dev/null
  assert test ! -s "$lo_curl"
  assert jq -e '. == {}' "$oauth_attempts_file" >/dev/null
) || exit 1

# Re-login heal: a successful usage merge must clear auth_needed, or the account
# stays "login needed" forever after the user logs back in.
(
  printf '{"auth_needed":true,"auth_checked_at":1,"five_hour":{"used_percentage":5,"resets_at":0,"as_of":123,"origin":"usage"}}' >"$limits_dir/lohealed.json"
  assert merge_usage lohealed "$usage"
  assert jq -e '.auth.status == "ok" and (has("auth_needed") | not) and (has("auth_checked_at") | not)' "$limits_dir/lohealed.json" >/dev/null
) || exit 1

# keychain item-not-found (security exit 44) → identical logged-out verdict.
(
  lo_curl="$WORK/lo44-curl.log"; : >"$lo_curl"
  security() { return 44; }
  curl() { printf 'curl %s\n' "$*" >>"$lo_curl"; exit 97; }
  lo_dir="$WORK/probe-lo44"; mkdir -p "$lo_dir"
  printf '{"auth":{"status":"ok","checked_at":1},"five_hour":{"used_percentage":8,"resets_at":0,"as_of":123,"origin":"usage"}}' >"$limits_dir/lo44.json"
  printf '{}' >"$oauth_attempts_file"
  probe_one lo44 "$lo_dir" false true
  assert test "$(cat "$lo_dir/lo44.result")" = 'logged-out 0 000'
  assert jq -e '.auth_needed == true and (has("auth") | not) and .five_hour.used_percentage == 8' "$limits_dir/lo44.json" >/dev/null
  assert test ! -s "$lo_curl"
  assert jq -e '. == {}' "$oauth_attempts_file" >/dev/null
) || exit 1

# any OTHER keychain error (exit 1) is weather: NO auth verdict, old auth preserved.
(
  cat >"$FAKE_BIN/security" <<'LOEOF'
#!/usr/bin/env bash
exit 1
LOEOF
  chmod +x "$FAKE_BIN/security"
  lo_dir="$WORK/probe-lo-weather"; mkdir -p "$lo_dir"
  printf '{"auth":{"status":"ok","checked_at":999}}' >"$limits_dir/low.json"
  printf '{}' >"$oauth_attempts_file"
  probe_one low "$lo_dir" false true
  assert jq -e '.auth.status == "ok" and .auth.checked_at == 999 and (has("auth_needed") | not)' "$limits_dir/low.json" >/dev/null
  read -r low_s low_r low_h < "$lo_dir/low.result"
  assert test "$low_s" = no-spend
) || exit 1

# token-upkeep skips a logged-out account: no token endpoint call, no oauth-attempt,
# credentials untouched (empty-token wipe and item-not-found both skipped).
(
  KC="$WORK/tul-keychain"; mkdir -p "$KC"
  kc_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
  tul_curl="$WORK/tul-curl.log"; : >"$tul_curl"
  security() {
    local prev='' svc='' a
    for a in "$@"; do [ "$prev" = -s ] && svc="$a"; prev="$a"; done
    cat "$KC/$(kc_key "$svc")" 2>/dev/null || return 44
  }
  curl() { printf 'curl %s\n' "$*" >>"$tul_curl"; exit 97; }
  account_names() { printf 'tulwipe\ntulmissing\n'; }
  wipe_creds='{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}'
  printf '%s' "$wipe_creds" >"$KC/$(kc_key "$(keychain_service tulwipe)")"
  printf '{}' >"$oauth_attempts_file"
  token_upkeep 2>/dev/null
  assert test ! -s "$tul_curl"
  assert jq -e '. == {}' "$oauth_attempts_file" >/dev/null
  assert test "$(cat "$KC/$(kc_key "$(keychain_service tulwipe)")")" = "$wipe_creds"
) || exit 1

# interactive status: account-row selection navigation, Enter launch resolution,
# highlight scoping, and the non-tty path staying plain (no key loop, no launch).
ia_result=$(cat <<'EOF'
{"picked":"beta","data":[
 {"name":"gamma","h5":10,"wk":5,"fable":null,"hreset":0,"wreset":0,"age":60,"h5_raw":10,"wk_raw":5,"fable_raw":null,"h5_dim":false,"wk_dim":false,"fable_dim":false,"disabled":false},
 {"name":"alpha","h5":40,"wk":20,"fable":null,"hreset":0,"wreset":0,"age":60,"h5_raw":40,"wk_raw":20,"fable_raw":null,"h5_dim":false,"wk_dim":false,"fable_dim":false,"disabled":false},
 {"name":"beta","h5":25,"wk":15,"fable":null,"hreset":0,"wreset":0,"age":60,"h5_raw":25,"wk_raw":15,"fable_raw":null,"h5_dim":false,"wk_dim":false,"fable_dim":false,"disabled":false}]}
EOF
)
accounts_result="$ia_result"
accounts_show_fable=false
accounts_picked=beta
accounts_mode=cached

assert test "$(sorted_account_names name | tr '\n' ' ')" = "alpha beta gamma "

nav=(alpha beta gamma)
assert test "$(selection_after_move down '' "${nav[@]}")" = alpha
assert test "$(selection_after_move down alpha "${nav[@]}")" = beta
assert test "$(selection_after_move down gamma "${nav[@]}")" = gamma
assert test "$(selection_after_move up '' "${nav[@]}")" = gamma
assert test "$(selection_after_move up alpha "${nav[@]}")" = alpha
assert test "$(selection_after_move up beta "${nav[@]}")" = alpha
assert test -z "$(selection_after_move down '')"

(
  claudeb_exec() { printf '%s' "$*"; }
  accounts_launch=beta
  assert test "$(maybe_launch_profile)" = "$0 profile beta"
)
(
  claudeb_exec() { printf FIRED; }
  accounts_launch=''
  assert test -z "$(maybe_launch_profile)"
)

sel_line=$(render_interactive_accounts 0 name beta 2>/dev/null | sed -n '4p')
assert grep -qF $'\033[7m' <<<"$sel_line"
plain_line=$(render_interactive_accounts 0 name '' 2>/dev/null | sed -n '4p')
assert_fails grep -qF $'\033[7m' <<<"$plain_line"

(
  collect_accounts() { :; }
  interactive_accounts() { printf 'INTERACTIVE\n'; return 1; }
  launch_marker="$WORK/ia-launch-marker"
  rm -f "$launch_marker"
  claudeb_exec() { : >"$launch_marker"; }
  out=$(show_accounts cached false false false false)
  assert test "${out#*INTERACTIVE}" = "$out"
  assert grep -qF NAME <<<"$out"
  assert test ! -e "$launch_marker"
)

# status defaults to cached: the plain render must make ZERO network calls; --live
# still probes (reaches the keychain/curl). Runs the real dispatch as a subprocess
# against an isolated store with curl/security stubs that record any invocation.
(
  st_store="$WORK/st-store"; st_bin="$WORK/st-bin"; st_home="$WORK/st-home"
  net_log="$WORK/st-net.log"
  mkdir -p "$st_store/limits" "$st_store/tokens" "$st_bin" "$st_home"
  cat >"$st_bin/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"$net_log"
exit 0
EOF
  cat >"$st_bin/security" <<EOF
#!/usr/bin/env bash
printf 'security %s\n' "\$*" >>"$net_log"
exit 1
EOF
  chmod +x "$st_bin/curl" "$st_bin/security"
  st_now=$(date +%s)
  for a in aa bb; do
    printf 'tok-%s\n' "$a" >"$st_store/tokens/$a"
    printf '{"five_hour":{"used_percentage":%s,"resets_at":%s,"as_of":%s,"origin":"usage"},"seven_day":{"used_percentage":10,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
      "$([ "$a" = aa ] && echo 12 || echo 40)" "$((st_now + 3600))" "$st_now" "$((st_now + 7200))" "$st_now" "$st_now" \
      >"$st_store/limits/$a.json"
  done

  rm -f "$net_log"
  out=$(PATH="$st_bin:$PATH" HOME="$st_home" CLAUDEB_DIR="$st_store" bash "$SCRIPT" status --plain) \
    || fail "status --plain (cached default) failed"
  assert test ! -e "$net_log"
  assert grep -qF NAME <<<"$out"
  assert grep -q '^aa ' <<<"$out"
  assert grep -q '^bb ' <<<"$out"

  rm -f "$net_log"
  PATH="$st_bin:$PATH" HOME="$st_home" CLAUDEB_DIR="$st_store" bash "$SCRIPT" status --plain --cached >/dev/null \
    || fail "status --plain --cached failed"
  assert test ! -e "$net_log"

  rm -f "$net_log"
  PATH="$st_bin:$PATH" HOME="$st_home" CLAUDEB_DIR="$st_store" bash "$SCRIPT" status --plain --live >/dev/null 2>&1 || true
  assert test -s "$net_log"
) || exit 1

# async interactive refresh: outcome summary is ✓ only when every enabled account
# came back live/live*; otherwise it names the stale accounts with their cause and
# excludes disabled ones.
(
  d="$WORK/ref-ok"; mkdir -p "$d"
  account_names() { printf '%s\n' aa bb; }
  is_disabled() { return 1; }
  printf 'live\n' >"$d/aa.display"; printf 'live*\n' >"$d/bb.display"
  out=$(accounts_refresh_outcome "$d")
  assert test "${out#✓ refreshed }" != "$out"
) || exit 1
(
  d="$WORK/ref-mixed"; mkdir -p "$d"
  account_names() { printf '%s\n' aa bb cc dd; }
  is_disabled() { [ "$1" = dd ]; }
  oauth_backoff_outcome() { case "$1" in bb) printf 429 ;; *) printf '' ;; esac; }
  printf 'live\n' >"$d/aa.display"; printf '!\n' >"$d/bb.display"
  printf 'auth!\n' >"$d/cc.display"; printf '!\n' >"$d/dd.display"
  out=$(accounts_refresh_outcome "$d")
  assert grep -qF 'not refreshed' <<<"$out"
  assert grep -qF 'bb (token 429)' <<<"$out"
  assert grep -qF 'cc (auth)' <<<"$out"
  assert_fails grep -qE '(^| )aa ' <<<"$out"
  assert_fails grep -qF dd <<<"$out"
) || exit 1

# The background probe's raw stderr (per-attempt 429 lines) must land in the log
# file, never on the terminal; the .done sentinel drives running→finish.
(
  probe_accounts() { printf 'claudeb: aa: OAuth token endpoint returned 429\n' >&2; printf 'live\n' >"$1/aa.display"; }
  account_names() { printf '%s\n' aa; }
  is_disabled() { return 1; }
  accounts_reselect() { :; }
  accounts_allow_spend=false; accounts_start_windows=false; accounts_heal=false
  accounts_probe_dir=''; accounts_refresh_pid=''; accounts_refresh_dir=''; accounts_status_line=''
  term_out="$WORK/ref-term.out"
  accounts_refresh_start >"$term_out" 2>&1
  assert test -n "$accounts_refresh_pid"
  for _ in $(seq 1 100); do accounts_refresh_running || break; sleep 0.05; done
  assert_fails accounts_refresh_running
  assert grep -qF 429 "$accounts_refresh_dir/probe.log"
  assert_fails grep -qF 429 "$term_out"
  accounts_refresh_finish
  assert test -z "$accounts_refresh_pid"
  assert test "${accounts_status_line#✓ refreshed }" != "$accounts_status_line"
  [ -z "${accounts_probe_dir:-}" ] || rm -rf "$accounts_probe_dir"
) || exit 1

# Cancelling a running background refresh must take down the probe children with
# the wrapper (process-group kill), not orphan them mid-request.
(
  probe_accounts() { sleep 30 & printf '%s\n' "$!" >"$1/child.pid"; wait; }
  account_names() { printf '%s\n' aa; }
  accounts_allow_spend=false; accounts_start_windows=false; accounts_heal=false
  accounts_probe_dir=''; accounts_refresh_pid=''; accounts_refresh_dir=''; accounts_status_line=''
  accounts_refresh_start >/dev/null 2>&1
  for _ in $(seq 1 60); do [ -s "$accounts_refresh_dir/child.pid" ] && break; sleep 0.05; done
  child=$(cat "$accounts_refresh_dir/child.pid")
  assert test -n "$child"
  assert sh -c "kill -0 $child 2>/dev/null"
  accounts_refresh_kill
  sleep 0.3
  assert_fails sh -c "kill -0 $child 2>/dev/null"
) || exit 1

# First-pass probe results publish in completion order: a fast account is processed
# while a slow sibling is still probing, not behind a wait-all barrier.
(
  export CLAUDEB_REFRESH_CONVERGE_S=0
  olog="$WORK/order.log"; : >"$olog"
  probe_one() { case "$1" in bb) sleep 2 ;; esac; printf 'usage 0 200\n' >"$2/$1.result"; printf '%s done %s\n' "$1" "$(date +%s)" >>"$olog"; }
  process_probe_result() { printf '%s processed %s\n' "$1" "$(date +%s)" >>"$olog"; }
  account_names() { printf '%s\n' aa bb; }
  d="$WORK/order-dir"; mkdir -p "$d"
  probe_accounts "$d" false false false
  aa_p=$(awk '$1=="aa" && $2=="processed" {print $3}' "$olog")
  bb_d=$(awk '$1=="bb" && $2=="done" {print $3}' "$olog")
  assert test -n "$aa_p"
  assert test -n "$bb_d"
  assert test "$aa_p" -lt "$bb_d"
) || exit 1

# remove: full-inventory cleanup, alive-creds guard + --force, account-state reset.
(
  RMKC="$WORK/rm-keychain"; mkdir -p "$RMKC"
  svc_of() { printf 'Claude Code-credentials-%s' "$(printf '%s' "$HOME/.claude-profiles/$1" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"; }
  cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
KC='$RMKC'
op="\$1"; shift
svc=""
while [ \$# -gt 0 ]; do case "\$1" in -s) shift; svc="\$1" ;; esac; shift; done
case "\$op" in
  find-generic-password) [ -r "\$KC/\$svc" ] || exit 44; cat "\$KC/\$svc" ;;
  delete-generic-password) rm -f "\$KC/\$svc" ;;
esac
EOF
  chmod +x "$FAKE_BIN/security"

  # A fully wired logged-out account touching every store location the audit lists.
  printf 'tok-rmv' >"$CLAUDEB_DIR/tokens/rmv"
  touch "$CLAUDEB_DIR/tokens/keep"
  printf '{}' >"$CLAUDEB_DIR/limits/rmv.json"
  mkdir -p "$HOME/.claude-profiles/rmv/nested"; printf x >"$HOME/.claude-profiles/rmv/nested/f"
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}' >"$RMKC/$(svc_of rmv)"
  printf '{"rmv":{"warm_outcome":"ok"},"keep":{"warm_outcome":"ok"}}' >"$CLAUDEB_DIR/oauth-attempts.json"
  printf 'rmv=1\nkeep=2\n' >"$CLAUDEB_DIR/account-tiers"
  printf 'rmv\n' >"$CLAUDEB_DIR/disabled"
  printf 'rmv\n' >"$CLAUDEB_DIR/.claudeb-state"
  printf 'rmv\n' >"$CLAUDEB_DIR/.claudeb-state-fable"

  assert "$SCRIPT" remove rmv
  assert test ! -e "$CLAUDEB_DIR/tokens/rmv"
  assert test ! -e "$CLAUDEB_DIR/limits/rmv.json"
  assert test ! -e "$RMKC/$(svc_of rmv)"
  assert test ! -e "$HOME/.claude-profiles/rmv"
  assert test -e "$CLAUDEB_DIR/tokens/keep"
  assert jq -e '.rmv == null and .keep != null' "$CLAUDEB_DIR/oauth-attempts.json"
  assert grep -qx 'keep=2' "$CLAUDEB_DIR/account-tiers"
  assert_fails grep -q '^rmv=' "$CLAUDEB_DIR/account-tiers"
  assert_fails grep -qx rmv "$CLAUDEB_DIR/disabled"
  assert test ! -e "$CLAUDEB_DIR/.claudeb-state"
  assert test ! -e "$CLAUDEB_DIR/.claudeb-state-fable"

  # State pointing at a surviving account is left intact when a different one is removed.
  printf 'tok-other' >"$CLAUDEB_DIR/tokens/other"
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}' >"$RMKC/$(svc_of other)"
  printf 'keep\n' >"$CLAUDEB_DIR/.claudeb-state"
  assert "$SCRIPT" remove other
  assert test ! -e "$CLAUDEB_DIR/tokens/other"
  assert grep -qx keep "$CLAUDEB_DIR/.claudeb-state"

  # Alive credentials are protected until --force.
  printf 'tok-alive' >"$CLAUDEB_DIR/tokens/alive"
  mkdir -p "$HOME/.claude-profiles/alive"
  printf '{"claudeAiOauth":{"accessToken":"live-at","refreshToken":"live-rt","expiresAt":9999999999999}}' >"$RMKC/$(svc_of alive)"
  assert_fails "$SCRIPT" remove alive
  assert test -e "$CLAUDEB_DIR/tokens/alive"
  assert test -e "$HOME/.claude-profiles/alive"
  assert test -e "$RMKC/$(svc_of alive)"
  assert "$SCRIPT" remove alive --force
  assert test ! -e "$CLAUDEB_DIR/tokens/alive"
  assert test ! -e "$HOME/.claude-profiles/alive"
  assert test ! -e "$RMKC/$(svc_of alive)"

  for reserved in p run; do
    printf 'tok-%s' "$reserved" >"$CLAUDEB_DIR/tokens/$reserved"
    mkdir -p "$HOME/.claude-profiles/$reserved"
    printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}' >"$RMKC/$(svc_of "$reserved")"
    assert "$SCRIPT" remove "$reserved"
    assert test ! -e "$CLAUDEB_DIR/tokens/$reserved"
    assert test ! -e "$HOME/.claude-profiles/$reserved"
    assert test ! -e "$RMKC/$(svc_of "$reserved")"
  done

  # Setup-token account: no keychain item, the live token is tokens/<name>. The old
  # keychain-only guard missed it; it must be protected until --force.
  printf 'sk-ant-oat01-live' >"$CLAUDEB_DIR/tokens/setuptok"
  assert_fails "$SCRIPT" remove setuptok
  assert test -e "$CLAUDEB_DIR/tokens/setuptok"
  assert "$SCRIPT" remove setuptok --force
  assert test ! -e "$CLAUDEB_DIR/tokens/setuptok"

  # Metadata-only orphans (a stale oauth-attempts entry / account-tiers line and
  # nothing else) are prunable, not "unknown account".
  printf '{"orphan":{"outcome":"429","strikes":2}}' >"$CLAUDEB_DIR/oauth-attempts.json"
  assert "$SCRIPT" remove orphan
  assert jq -e '.orphan == null' "$CLAUDEB_DIR/oauth-attempts.json"
  printf 'tierorphan=3\nkeep=2\n' >"$CLAUDEB_DIR/account-tiers"
  printf '{}' >"$CLAUDEB_DIR/oauth-attempts.json"
  assert "$SCRIPT" remove tierorphan
  assert_fails grep -q '^tierorphan=' "$CLAUDEB_DIR/account-tiers"

  # The bypass lock is a DIRECTORY (mkdir-based lock); remove must rm -rf it —
  # rm -f left an orphan dir behind.
  printf 'tok-blk' >"$CLAUDEB_DIR/tokens/blk"
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}' >"$RMKC/$(svc_of blk)"
  mkdir -p "$CLAUDEB_DIR/oauth-attempts.json.bypass.blk"
  assert "$SCRIPT" remove blk
  assert test ! -e "$CLAUDEB_DIR/oauth-attempts.json.bypass.blk"

  assert_fails "$SCRIPT" remove main
  assert_fails "$SCRIPT" remove ghost-account
) || exit 1

echo "PASS: $asserts asserts; profile-required launch guard, reset tiers and empty input, null-safe usage merges, snapshot provenance and auth, OAuth weather/backoff and lock behavior, creation-only reserved names and leading-hyphen rejection, disabled-account timeline, disabled profile launch proceeds direct with inherited routing stripped, generic lock contention/stale-retake, heal backoff isolates warm from token-endpoint state, oauth_refresh lock release, revocation escape, concurrent token adoption, capacity weather clears stale expired auth for valid tokens, warm-first heal ordering and fallback, warm auth verdicts require current-run refresh evidence, start-windows opens a fresh window and reconcile locks the new resets_at without regressing it, start-windows skips a disabled account with an explicit cause, warm --start-window opens only an expired window for the explicit account (live window and flagless runs never ping; ping weather warns without an auth verdict), the paid haiku warm fallback stays off unless opted in, regular probes never warm, heal_expired covers disabled accounts with actionable causes, and heal_one writes expired only on current-run evidence (stale-token 401 defers to the token endpoint's verdict, fresh-token 401 is affirmative, weather never re-stamps a prior expired), and no-refresh probes plus messages-probe 401s defer to the refresh outcome (stale token → weather no-write / invalid_grant expired, fresh token → affirmative), and interactive status account-row selection (bounded up/down navigation, name-stable across re-sort), Enter resolving to a \`claudeb profile <name>\` exec, row-scoped reverse-video highlight, and the non-tty path staying plain with no key loop or launch, status defaulting to cached (zero network; --live still probes), and the async refresh outcome summary (✓ when all enabled accounts are live/live*, else names stale accounts with a cause and excludes disabled ones, raw probe stderr confined to the log), refresh cancellation killing the probe process group, first-pass results publishing in completion order, unknown profiles rejected, and reserved legacy profiles removable, headless runs routed through worker-pick without restamping current (arguments alone still demand a profile; an unselectable pool or a missing worker-pick refuses instead of launching), and \`use\` writing the worker pin in place with an out-of-pool warning, a clear, and a refusal on an unroutable name"
