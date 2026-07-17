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
export HOME CLAUDEB_DIR CLAUDEB_WARM_RETRY_DELAY
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
printf '{"alpha":{"attempted_at":%s,"outcome":"warming","retry_after_until":0}}\n' "$((now - 179))" >"$oauth_attempts_file"
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
assert test "$(cat "$weather_dir/alpha.result")" = 'no-spend 1 529'
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
  probe_accounts "$order_dir" false false true
  assert test "$(sed -n '1p' "$EVENT_LOG")" = warm
  assert test "$(sed -n '2p' "$EVENT_LOG")" = warm
  assert test "$(sed -n '3p' "$EVENT_LOG")" = token
  assert test "$(wc -l < "$EVENT_LOG" | tr -d ' ')" = 3
  assert test "$(jq -r '.auth.cause' "$limits_dir/alpha.json")" = 'warm failed, token refresh backoff 15m'
  # A genuinely-unhealable account stays expired post-heal; only then may it surface.
  assert test "$(jq -r '.auth.status' "$limits_dir/alpha.json")" = expired
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
  run_warm_session() { return 0; }
  assert warm_accounts zeta >/dev/null 2>"$WORK/warm-refresh-success.err"
  assert test "$(wc -l <"$warm_refresh_calls" | tr -d ' ')" = 1
  assert test "$(wc -l <"$warm_probe_calls" | tr -d ' ')" = 1
  assert jq -e '.five_hour.used_percentage == 44 and .auth.status == "ok"' "$limits_dir/zeta.json" >/dev/null
  assert test "$(oauth_backoff_outcome zeta)" = ''
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
# never named in refresh_error), while the unhealable ones keep actionable causes.
assert test "$(jq -r '.auth.status' "$limits_dir/alpha.json")" = ok
assert test "$(jq -r '.auth.cause' "$limits_dir/beta.json")" = 'warm failed, token refresh backoff 12m'
assert test "$(jq -r '.auth.cause' "$limits_dir/gamma.json")" = 'warm failed, token refresh failed'
assert test "$(jq -r '.auth.cause' "$limits_dir/delta.json")" = 'needs re-login'
assert grep -qx delta "$WARM_CALLS"

echo "PASS: $asserts asserts; reset tiers and empty input, null-safe usage merges, snapshot provenance and auth, OAuth weather/backoff and lock behavior, reserved names, disabled-account timeline, out-of-rotation profile launch proceeds direct (proxy leaks stripped), generic lock contention/stale-retake, heal backoff isolates warm from token-endpoint state, oauth_refresh lock release, revocation escape, concurrent-rotation adoption, capacity weather clears stale expired auth for valid tokens, warm-first heal ordering and fallback, warm auth verdicts require current-run refresh evidence, start-windows opens a fresh window and reconcile locks the new resets_at without regressing it, start-windows skips a disabled account with an explicit cause, the paid haiku warm fallback stays off unless opted in, regular probes never warm, and heal_expired covers disabled accounts with actionable causes"
