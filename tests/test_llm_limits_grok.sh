#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# shards: 2
. "$(dirname "$0")/llm_limits_harness.sh" || exit 1

home_fixture_after_first_suite
seed_gemini_cache

# --- Grok: weekly-only billing quota ------------------------------------------------------
# The vendor states one weekly pool and no 5h window, so every surface must render WK% with an
# empty 5H% and never invent a five_hour bucket for it.
GROK_HOME="$WORK/grok-home"
GROK_STORE="$WORK/grok-store.json"
GROK_PROFILES="$WORK/grok-profiles"
GROK_ROSTER_CACHE="$WORK/grok-roster.json"
GROK_SENTINEL="$WORK/grok-quota-called"
mkdir -p "$GROK_HOME" "$GROK_PROFILES/supergrok" "$GROK_PROFILES/second" "$GROK_PROFILES/.grokb"
# grokb as the collector's token touch sees it: logs the call into the same sentinel the quota
# fixture writes (so order is one file), says the CLI's misleading line, and rotates the profile's
# token to a future expiry the way the real CLI does — while exiting non-zero like it, too.
GROK_TOUCH_STUB="$WORK/fake-grokb"
cat >"$GROK_TOUCH_STUB" <<'EOF'
#!/usr/bin/env bash
set -u
[ -z "${GROK_QUOTA_SENTINEL:-}" ] || printf 'touch %s\n' "$*" >>"$GROK_QUOTA_SENTINEL"
printf 'You are not authenticated.\n' >&2
[ "${GROK_TOUCH_HANG:-0}" = 0 ] || sleep 30
auth="${GROKB_PROFILES_DIR:?}/${1:?}/auth.json"
[ ! -f "$auth" ] || printf '{"key":"k","refresh_token":"r","expires_at":"2099-01-01T00:00:00Z"}\n' >"$auth"
exit 1
EOF
chmod +x "$GROK_TOUCH_STUB"
grok_env=(HOME="$GROK_HOME" GROKB_PROFILES_DIR="$GROK_PROFILES" LLM_LIMITS_GROKB="$GROK_TOUCH_STUB"
  LLM_LIMITS_GROK_QUOTA="$ROOT/tests/fixtures/fake-grok-quota.sh"
  LLM_LIMITS_GROK_CACHE="$GROK_ROSTER_CACHE" LLM_LIMITS_GROK_REFRESH=1
  LLM_LIMITS_CACHE="$GROK_STORE" GROK_QUOTA_SENTINEL="$GROK_SENTINEL"
  FAKE_GROK_ROSTER="supergrok second")

if suite_shard_owns 1 grok-collect; then
grok_json=$(env "${grok_env[@]}" FAKE_GROK_CASE=busy FAKE_GROK_AS_OF="$now" \
  LLM_LIMITS_GROK_QUOTA_TIMEOUT=7 bash "$SCRIPT" --refresh --json 2>/dev/null) \
  || fail "grok refresh collection failed"
grep -qx -- '--profiles-dir '"$GROK_PROFILES"' --timeout 7' "$GROK_SENTINEL" \
  || fail "grok refresh did not pass the profiles dir and timeout seam: $(cat "$GROK_SENTINEL")"
jq -e --argjson now "$now" '.vendors.grok.available == true and
  .vendors.grok.source == "grok-billing" and .vendors.grok.current_account == "supergrok" and
  .vendors.grok.usable_now == true and (.vendors.grok.accounts | length) == 2 and
  .vendors.grok.plan_type == "SUBSCRIPTION_TIER_SUPERGROK" and
  (.vendors.grok | has("five_hour") | not) and
  (.vendors.grok.accounts[0] |
    .account == "supergrok" and .is_current == true and .enabled == true and
    .auth.status == "ok" and .email == "owner@example.com" and
    .period == "USAGE_PERIOD_TYPE_WEEKLY" and .build_pct == 18.5 and
    (has("five_hour") | not) and
    .weekly.used_pct == 61.2 and .weekly.effective_pct == 61.2 and
    .weekly.origin == "billing" and .weekly.stale == false and .weekly.as_of == $now and
    (.stale_seconds | type) == "number")' <<<"$grok_json" >/dev/null || fail "grok store row shape mismatch"
grok_table=$(env "${grok_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --table 2>/dev/null) \
  || fail "grok table failed"
[ "$(awk '$1 == "grok/supergrok*" {print $2, $3}' <<<"$grok_table")" = "- 61%" ] \
  || fail "grok table must render WK% with a blank 5H%: $grok_table"
grok_plain=$(env "${grok_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --plain 2>/dev/null) \
  || fail "grok plain failed"
grep -q '^grok/supergrok\*: 5h - @ - | wk 61% @ ' <<<"$grok_plain" \
  || fail "grok plain line mismatch: $grok_plain"

# A bare vendor name refreshes grok alone; a targeted one asks the helper for that account only
# and leaves every other row of the roster where the last read left it.
: >"$GROK_SENTINEL"
GROK_OTHER_SENTINEL="$WORK/grok-other-codex-called"
cat >"$WORK/grok-other-codex" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>"$GROK_OTHER_SENTINEL"
exit 1
EOF
chmod +x "$WORK/grok-other-codex"
env "${grok_env[@]}" FAKE_GROK_CASE=busy LLM_LIMITS_CODEX_REFRESH=1 \
  LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/grok-other-codex" bash "$SCRIPT" --refresh-account grok --json \
  >/dev/null 2>&1 || fail "vendor-scoped grok refresh failed"
[ -s "$GROK_SENTINEL" ] || fail "--refresh-account grok did not run the grok helper"
[ ! -e "$GROK_OTHER_SENTINEL" ] || fail "--refresh-account grok also probed codex"
: >"$GROK_SENTINEL"
grok_targeted=$(env "${grok_env[@]}" FAKE_GROK_CASE=walled \
  bash "$SCRIPT" --refresh-account grok/second --json 2>/dev/null) \
  || fail "targeted grok refresh failed"
grep -qx -- '--profiles-dir '"$GROK_PROFILES"' --timeout 10 --account second' "$GROK_SENTINEL" \
  || fail "targeted grok refresh did not name the single account: $(cat "$GROK_SENTINEL")"
jq -e '([.vendors.grok.accounts[] | select(.account == "second")][0] |
    .weekly.used_pct == 100 and .weekly.effective_pct == 100) and
  ([.vendors.grok.accounts[] | select(.account == "supergrok")][0] | .weekly.used_pct == 61.2) and
  .vendors.grok.current_account == "supergrok" and .vendors.grok.usable_now == true' \
  <<<"$grok_targeted" >/dev/null || fail "targeted grok refresh did not keep the untouched account"
grok_walled_table=$(env "${grok_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --table 2>/dev/null) \
  || fail "grok walled table failed"
awk '$1 == "grok/second"' <<<"$grok_walled_table" | grep -q 'limit-weekly' \
  || fail "a grok account at 100% must read limit-weekly: $grok_walled_table"
env "${grok_env[@]}" bash "$SCRIPT" --refresh-account grok/ --json >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "--refresh-account grok/ (no name): expected exit 2, got $rc"

# Out of the worker pool is spend consent, so the row keeps its percentage and reads `off`.
printf 'second\n' >"$GROK_PROFILES/.grokb/disabled"
grok_disabled=$(env "${grok_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --json 2>/dev/null) \
  || fail "grok disabled-account collection failed"
jq -e '([.vendors.grok.accounts[] | select(.account == "second")][0] |
  .enabled == false and .weekly.used_pct == 100)' <<<"$grok_disabled" >/dev/null \
  || fail "an excluded grok account did not read enabled:false"
grok_disabled_table=$(env "${grok_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --table 2>/dev/null) \
  || fail "grok disabled table failed"
awk '$1 == "grok/second"' <<<"$grok_disabled_table" | grep -q ' off ' \
  || fail "an excluded grok account must read ROT off: $grok_disabled_table"
rm -f "$GROK_PROFILES/.grokb/disabled"

# A transient failure states nothing: the last known rows stand and the cause is machine-readable.
grok_error=$(env "${grok_env[@]}" FAKE_GROK_CASE=error bash "$SCRIPT" --refresh-account grok --json 2>/dev/null) \
  || fail "grok error refresh collection failed"
jq -e '.vendors.grok.available == true and
  (.vendors.grok.accounts[0].weekly.used_pct == 61.2) and
  (.vendors.grok.refresh_error.cause | test("network error")) and
  (.vendors.grok.refresh_error.at | type) == "number"' <<<"$grok_error" >/dev/null \
  || fail "a failed grok read lost the last known rows or its cause"
jq -e '[.accounts[] | select(.account == "supergrok")][0].used_pct == 61.2' "$GROK_ROSTER_CACHE" \
  >/dev/null || fail "a failed grok read overwrote the cached row"
grok_recovered=$(env "${grok_env[@]}" FAKE_GROK_CASE=busy \
  bash "$SCRIPT" --refresh-account grok --json 2>/dev/null) || fail "grok recovery refresh failed"
jq -e '.vendors.grok | has("refresh_error") | not' <<<"$grok_recovered" >/dev/null \
  || fail "a successful grok refresh did not clear the standing error"

# The helper's own last word is the cause; without it a hard failure reads as an exit code.
grok_crash=$(env "${grok_env[@]}" FAKE_GROK_CASE=helper_crash \
  bash "$SCRIPT" --refresh-account grok --json 2>/dev/null) || fail "grok crash refresh collection failed"
jq -e '.vendors.grok.refresh_error.cause | test("the helper died before printing")' \
  <<<"$grok_crash" >/dev/null || fail "the grok helper's stderr never reached the reported cause"
env "${grok_env[@]}" FAKE_GROK_CASE=busy bash "$SCRIPT" --refresh-account grok --json >/dev/null 2>&1

# A name that is on no roster must not be read at all: the helper would answer needs_login for the
# empty directory it resolves to, and that verdict is written straight into the store and the menu.
grok_phantom_rc=0
env "${grok_env[@]}" bash "$SCRIPT" --refresh-account grok/supergrokk --json \
  >"$WORK/grok-phantom.out" 2>"$WORK/grok-phantom.err" || grok_phantom_rc=$?
[ "$grok_phantom_rc" -eq 2 ] || fail "an unknown grok account must exit 2, got $grok_phantom_rc"
grep -q 'unknown account: supergrokk (not on the grok roster' "$WORK/grok-phantom.err" \
  || fail "an unknown grok account did not say so: $(cat "$WORK/grok-phantom.err")"
jq -e 'all(.accounts[]; .account != "supergrokk")' "$GROK_ROSTER_CACHE" >/dev/null \
  || fail "an unknown grok account was written into the cache"
grok_named=$(env "${grok_env[@]}" FAKE_GROK_CASE=busy \
  bash "$SCRIPT" --refresh-account grok/second --json 2>/dev/null) \
  || fail "a rostered grok account was refused"
jq -e '[.vendors.grok.accounts[] | select(.account == "second")] | length == 1' <<<"$grok_named" \
  >/dev/null || fail "a rostered grok account did not refresh"

# A leg with no accounts read nothing because there was nothing to read: an empty vendor may not
# stand permanently red.
GROK_EMPTY_PROFILES="$WORK/grok-empty-profiles"
mkdir -p "$GROK_EMPTY_PROFILES"
grok_empty_env=("${grok_env[@]}" GROKB_PROFILES_DIR="$GROK_EMPTY_PROFILES"
  LLM_LIMITS_GROK_CACHE="$WORK/grok-empty.json" LLM_LIMITS_CACHE="$WORK/grok-empty-store.json"
  FAKE_GROK_CASE=empty_roster)
grok_empty_rc=0
grok_empty=$(env "${grok_empty_env[@]}" bash "$SCRIPT" --refresh --json 2>"$WORK/grok-empty.err") \
  || grok_empty_rc=$?
# 3 is "no vendor available at all", which this fixture is — nothing but grok is configured under
# its HOME and grok itself has no accounts. Anything else would be a failure verdict on the read.
[ "$grok_empty_rc" -eq 0 ] || [ "$grok_empty_rc" -eq 3 ] \
  || fail "grok empty-roster collection failed ($grok_empty_rc): $(cat "$WORK/grok-empty.err")"
jq -e '(.vendors.grok | type) == "object" and (.vendors.grok.accounts // []) == [] and
  (.vendors.grok | has("refresh_error") | not)' \
  <<<"$grok_empty" >/dev/null || fail "a grok leg with no accounts was reported as a failed refresh"

# --- Grok: the token touch lives in the collector, so the heartbeat's targeted re-poll and the
# menu's Hard refresh share one path. A token past its own `expires_at` earns one
# `grokb <account> exec models` before the poll; the poll alone writes the verdict.
GROK_SECOND_AUTH="$GROK_PROFILES/second/auth.json"
expired_auth() {
  printf '{"key":"k","refresh_token":"r","expires_at":"%s"}\n' \
    "$(date -u -r "$((now - 60))" '+%Y-%m-%dT%H:%M:%S.123456Z')" >"$GROK_SECOND_AUTH"
}
expired_auth
: >"$GROK_SENTINEL"
env "${grok_env[@]}" FAKE_GROK_CASE=busy bash "$SCRIPT" --refresh-account grok/second --json \
  >/dev/null 2>"$WORK/grok-touch.err" || fail "grok targeted refresh over an expired token failed: $(cat "$WORK/grok-touch.err")"
[ "$(sed -n 1p "$GROK_SENTINEL")" = 'touch second exec models' ] \
  || fail "the token touch did not precede the poll: $(cat "$GROK_SENTINEL")"
[ "$(grep -c '^touch ' "$GROK_SENTINEL")" -eq 1 ] || fail "the expired token was not touched exactly once: $(cat "$GROK_SENTINEL")"
grep -q -- '--account second' "$GROK_SENTINEL" || fail "the touch cost the account its poll: $(cat "$GROK_SENTINEL")"
grep -q 'Grok account second: token touch' "$WORK/grok-touch.err" \
  || fail "the touch left no trace on stderr: $(cat "$WORK/grok-touch.err")"
# The stub rotated the token: the same ask is now a plain poll.
: >"$GROK_SENTINEL"
env "${grok_env[@]}" FAKE_GROK_CASE=busy bash "$SCRIPT" --refresh-account grok/second --json >/dev/null 2>&1 \
  || fail "grok targeted refresh over a fresh token failed"
grep -q '^touch ' "$GROK_SENTINEL" && fail "a signed-in grok account was driven through the CLI: $(cat "$GROK_SENTINEL")"
# The CLI writes `expires_at` as a number as readily as an ISO string, and a numeric expiry in
# the past is as expired as a spelled-out one.
printf '{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"k","refresh_token":"r","expires_at":%s}}\n' \
  "$((now - 60))" >"$GROK_SECOND_AUTH"
: >"$GROK_SENTINEL"
env "${grok_env[@]}" FAKE_GROK_CASE=busy bash "$SCRIPT" --refresh-account grok/second --json >/dev/null 2>&1 \
  || fail "grok targeted refresh over a numeric expiry failed"
[ "$(grep -c '^touch second exec models$' "$GROK_SENTINEL")" -eq 1 ] \
  || fail "a numeric expires_at in the past was not read as expired: $(cat "$GROK_SENTINEL")"
# The last poll's 401 is the other reason: the cache says expired while auth.json looks fine.
jq -c '.accounts |= map(if .account == "second" then .auth = "expired" else . end)' "$GROK_ROSTER_CACHE" \
  >"$WORK/grok-roster.tmp" && mv "$WORK/grok-roster.tmp" "$GROK_ROSTER_CACHE"
: >"$GROK_SENTINEL"
env "${grok_env[@]}" FAKE_GROK_CASE=busy bash "$SCRIPT" --refresh-account grok/second --json >/dev/null 2>&1 \
  || fail "grok targeted refresh over a rejected token failed"
[ "$(grep -c '^touch second exec models$' "$GROK_SENTINEL")" -eq 1 ] \
  || fail "a token the last poll rejected was not touched: $(cat "$GROK_SENTINEL")"
# The vendor row's Hard refresh touches every expired account and no other.
expired_auth
: >"$GROK_SENTINEL"
env "${grok_env[@]}" FAKE_GROK_CASE=busy bash "$SCRIPT" --refresh-account grok --json >/dev/null 2>&1 \
  || fail "grok vendor-wide refresh failed"
[ "$(grep '^touch ' "$GROK_SENTINEL")" = 'touch second exec models' ] \
  || fail "the vendor-wide refresh touched the wrong set: $(cat "$GROK_SENTINEL")"
# The passive all-vendor collection is a plain read: no CLI, whatever the token says.
expired_auth
: >"$GROK_SENTINEL"
env "${grok_env[@]}" FAKE_GROK_CASE=busy bash "$SCRIPT" --refresh --json >/dev/null 2>&1 \
  || fail "grok passive collection failed"
grep -q '^touch ' "$GROK_SENTINEL" && fail "the passive collection ran the CLI: $(cat "$GROK_SENTINEL")"
# The touch is a live CLI launch: a wedged one is cut off and the poll still happens.
expired_auth
: >"$GROK_SENTINEL"
touch_started=$SECONDS
env "${grok_env[@]}" FAKE_GROK_CASE=busy GROK_TOUCH_HANG=1 LLM_LIMITS_GROK_TOUCH_TIMEOUT=1 \
  bash "$SCRIPT" --refresh-account grok/second --json >/dev/null 2>&1 || fail "grok refresh with a hung touch failed"
[ "$((SECONDS - touch_started))" -lt 20 ] || fail "a hung token touch stalled the refresh"
grep -q -- '--account second' "$GROK_SENTINEL" || fail "a hung touch cost the account its poll: $(cat "$GROK_SENTINEL")"
# No grokb at all: say so, and poll anyway.
expired_auth
: >"$GROK_SENTINEL"
env "${grok_env[@]}" FAKE_GROK_CASE=busy LLM_LIMITS_GROKB="$WORK/no-such-grokb" \
  bash "$SCRIPT" --refresh-account grok/second --json >/dev/null 2>"$WORK/grok-touch.err" \
  || fail "grok refresh without grokb failed"
grep -q 'no grokb at' "$WORK/grok-touch.err" || fail "a missing grokb went unreported: $(cat "$WORK/grok-touch.err")"
grep -q -- '--account second' "$GROK_SENTINEL" || fail "a missing grokb cost the account its poll"
rm -f "$GROK_SECOND_AUTH"

# needs_login is the one state no automated path can leave; expired is the CLI's own to heal.
GROK_AUTH_CACHE="$WORK/grok-auth.json"
grok_auth_env=("${grok_env[@]}")
grok_auth_env+=(LLM_LIMITS_GROK_CACHE="$GROK_AUTH_CACHE" FAKE_GROK_ROSTER="solo")
grok_login=$(env "${grok_auth_env[@]}" FAKE_GROK_CASE=needs_login bash "$SCRIPT" --refresh --json 2>/dev/null) \
  || fail "grok needs-login collection failed"
jq -e '.vendors.grok.available == true and .vendors.grok.status == "login needed" and
  .vendors.grok.usable_now == false and (.vendors.grok | has("refresh_error") | not) and
  (.vendors.grok.accounts[0] | .auth.status == "needs_login" and .auth_needed == true and
    .status == "login needed" and .needs_user_entry == true and (has("weekly") | not))' \
  <<<"$grok_login" >/dev/null || fail "grok needs-login normalization mismatch"
grok_login_table=$(env "${grok_auth_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --table 2>/dev/null) \
  || fail "grok needs-login table failed"
grep -Eq '^grok/solo\* +- +- +- +- +- +- +never +- +- +login needed$' <<<"$grok_login_table" \
  || fail "grok needs-login table row mismatch: $grok_login_table"
grok_expired_auth=$(env "${grok_auth_env[@]}" FAKE_GROK_CASE=expired bash "$SCRIPT" --refresh --json 2>/dev/null) \
  || fail "grok expired-token collection failed"
jq -e '(.vendors.grok.status != "login needed") and
  (.vendors.grok.accounts[0] | .auth.status == "expired" and (has("auth_needed") | not) and
   (has("status") | not) and .cause == "token rejected: HTTP 401" and
   (has("needs_user_entry") | not))' \
  <<<"$grok_expired_auth" >/dev/null || fail "grok expired-token normalization mismatch"
grok_expired_auth_table=$(env "${grok_auth_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --table 2>/dev/null) \
  || fail "grok expired-token table failed"
awk '$1 ~ /^grok\// && $0 ~ /login needed/' <<<"$grok_expired_auth_table" | grep -q . \
  && fail "grok expired-token table treated refreshable auth as login needed: $grok_expired_auth_table"
# An expired token that still has a measured weekly window is a candidate: the CLI refreshes it.
printf '{"accounts":[{"account":"solo","auth":"expired","used_pct":12,"resets_at":"%s","as_of":%s,"cause":"token rejected: HTTP 401"}]}\n' \
  "$(date -u -r "$((now + 86400))" '+%Y-%m-%dT%H:%M:%SZ')" "$now" >"$GROK_AUTH_CACHE"
grok_expired_usable=$(env "${grok_auth_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --json 2>/dev/null) \
  || fail "grok expired-token with weekly collection failed"
jq -e '.vendors.grok.usable_now == true and (.vendors.grok.status != "login needed") and
  (.vendors.grok.accounts[0] | .auth.status == "expired" and .weekly.effective_pct == 12 and
   (has("auth_needed") | not))' \
  <<<"$grok_expired_usable" >/dev/null || fail "grok expired-token with weekly must stay usable"

# Staleness and expiry are read off the collector's own flags, never re-derived per surface.
GROK_AGE_CACHE="$WORK/grok-age.json"
grok_age_env=("${grok_env[@]}")
grok_age_env+=(LLM_LIMITS_GROK_CACHE="$GROK_AGE_CACHE" FAKE_GROK_ROSTER="aged")
grok_stale=$(env "${grok_age_env[@]}" FAKE_GROK_CASE=busy FAKE_GROK_AS_OF="$((now - 30000))" \
  bash "$SCRIPT" --refresh --json 2>/dev/null) || fail "grok stale collection failed"
jq -e '.vendors.grok.accounts[0].weekly.stale == true and .vendors.grok.stale == true and
  .vendors.grok.accounts[0].weekly.effective_pct == 61.2' <<<"$grok_stale" >/dev/null \
  || fail "an old grok reading was not marked stale"
grok_stale_table=$(env "${grok_age_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --table 2>/dev/null) \
  || fail "grok stale table failed"
[ "$(awk '$1 == "grok/aged*" {print $3}' <<<"$grok_stale_table")" = "61%~" ] \
  || fail "a stale grok reading must carry the stale marker: $grok_stale_table"
grok_expired=$(env "${grok_age_env[@]}" FAKE_GROK_CASE=busy FAKE_GROK_AS_OF="$now" \
  FAKE_GROK_RESET="$(date -u -r "$((now - 600))" '+%Y-%m-%dT%H:%M:%SZ')" \
  bash "$SCRIPT" --refresh --json 2>/dev/null) || fail "grok expired-window collection failed"
jq -e '.vendors.grok.accounts[0].weekly.expired == true and
  .vendors.grok.accounts[0].weekly.used_pct == 61.2 and
  .vendors.grok.accounts[0].weekly.effective_pct == 0 and
  .vendors.grok.usable_now == true' <<<"$grok_expired" >/dev/null \
  || fail "an elapsed grok window was not marked expired"
grok_expired_table=$(env "${grok_age_env[@]}" LLM_LIMITS_GROK_REFRESH=0 bash "$SCRIPT" --table 2>/dev/null) \
  || fail "grok expired table failed"
[ "$(awk '$1 == "grok/aged*" {print $3}' <<<"$grok_expired_table")" = "0%!" ] \
  || fail "an expired grok window must render effective 0: $grok_expired_table"
# An unmigrated account reports a monthly period; it is carried verbatim, never hidden.
grok_monthly=$(env "${grok_age_env[@]}" FAKE_GROK_CASE=monthly FAKE_GROK_AS_OF="$now" \
  bash "$SCRIPT" --refresh --json 2>/dev/null) || fail "grok monthly-period collection failed"
jq -e '.vendors.grok.accounts[0].period == "USAGE_PERIOD_TYPE_MONTHLY" and
  .vendors.grok.accounts[0].weekly.used_pct == 12' <<<"$grok_monthly" >/dev/null \
  || fail "a monthly grok billing period was not carried through verbatim"
# A window name no surface knows is carried the same way: the reading is still a reading, and the
# menubar falls back to its `wk` label rather than dropping the row.
grok_unknown_period=$(env "${grok_age_env[@]}" FAKE_GROK_CASE=bad_period FAKE_GROK_AS_OF="$now" \
  bash "$SCRIPT" --refresh --json 2>/dev/null) || fail "grok unknown-period collection failed"
jq -e '.vendors.grok.accounts[0].period == "USAGE_PERIOD_TYPE_UNSPECIFIED" and
  .vendors.grok.accounts[0].weekly.used_pct == 33 and
  .vendors.grok.accounts[0].weekly.resets_at == null' <<<"$grok_unknown_period" >/dev/null \
  || fail "an unrecognized grok billing period was not carried through verbatim"

# The reset consumable is vendor-neutral: grok carries the same three fields codex does, plus the
# expiry the grant states, and the CR column renders it for whichever vendor published one.
grok_credits=$(env "${grok_age_env[@]}" FAKE_GROK_CASE=with_resets FAKE_GROK_AS_OF="$now" \
  bash "$SCRIPT" --refresh --json 2>/dev/null) || fail "grok reset-credit collection failed"
jq -e --argjson now "$now" '.vendors.grok.accounts[0] |
  .reset_credits == 1 and .reset_credits_stale == false and
  .reset_credits_as_of == $now and
  .reset_credits_expires_at == "2099-09-12T18:49:00Z"' <<<"$grok_credits" >/dev/null \
  || fail "grok reset credits were dropped or read as stale: $grok_credits"
grok_credits_table=$(env "${grok_age_env[@]}" LLM_LIMITS_GROK_REFRESH=0 \
  bash "$SCRIPT" --table 2>/dev/null) || fail "grok reset-credit table failed"
awk '$1 == "grok/aged*" {print $(NF-1)}' <<<"$grok_credits_table" | grep -qx '↻1' \
  || fail "the CR column did not render grok reset credits: $grok_credits_table"
grok_credits_plain=$(env "${grok_age_env[@]}" LLM_LIMITS_GROK_REFRESH=0 \
  bash "$SCRIPT" --plain 2>/dev/null) || fail "grok reset-credit plain render failed"
grep 'grok/aged\*:' <<<"$grok_credits_plain" | grep -q '| cr ↻1 |' \
  || fail "the plain render dropped grok reset credits: $grok_credits_plain"
# A count measured long enough ago is not a count a caller may spend on: worker-pick reads this
# flag and treats such a row as zero.
grok_credits_stale=$(env "${grok_age_env[@]}" FAKE_GROK_CASE=stale_resets FAKE_GROK_AS_OF="$now" \
  bash "$SCRIPT" --refresh --json 2>/dev/null) || fail "grok stale reset-credit collection failed"
jq -e '.vendors.grok.accounts[0] | .reset_credits == 2 and .reset_credits_stale == true and
  .weekly.stale == false' <<<"$grok_credits_stale" >/dev/null \
  || fail "an old grok reset-credit reading was not marked stale: $grok_credits_stale"

fi
if suite_shard_owns 2 grok-rows; then
# The real helper against a dead endpoint: the access token in auth.json may reach neither the
# store nor a log, however the read fails.
GROK_SECRET_HOME="$WORK/grok-secret-home"
GROK_SECRET_PROFILES="$WORK/grok-secret-profiles"
mkdir -p "$GROK_SECRET_HOME" "$GROK_SECRET_PROFILES/leaky"
GROK_TOKEN_SENTINEL='grok-token-sentinel-NEVER-PRINT'
cat >"$GROK_SECRET_PROFILES/leaky/auth.json" <<EOF
{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"$GROK_TOKEN_SENTINEL","refresh_token":"refresh-$GROK_TOKEN_SENTINEL","user_id":"u-1","email":"owner@example.com","expires_at":$((now + 3600))}}
EOF
grok_secret=$(env HOME="$GROK_SECRET_HOME" GROKB_PROFILES_DIR="$GROK_SECRET_PROFILES" \
  LLM_LIMITS_GROK_CACHE="$WORK/grok-secret.json" LLM_LIMITS_GROK_REFRESH=1 \
  LLM_LIMITS_CACHE="$WORK/grok-secret-store.json" \
  GROK_QUOTA_ENDPOINT='http://127.0.0.1:1/v1/billing?format=credits' \
  GROK_RESETS_ENDPOINT='http://127.0.0.1:1' \
  GROK_QUOTA_CLIENT_VERSION=1.0.13 \
  bash "$SCRIPT" --refresh-account grok --json 2>"$WORK/grok-secret.err")
grep -q "$GROK_TOKEN_SENTINEL" <<<"$grok_secret" \
  && fail "the grok access token leaked into the store"
grep -q "$GROK_TOKEN_SENTINEL" "$WORK/grok-secret.err" \
  && fail "the grok access token leaked into the log"
jq -e '.vendors.grok.refresh_error.cause | test("network error|HTTP")' <<<"$grok_secret" >/dev/null \
  || fail "an unreachable grok endpoint produced no machine-readable cause"

# A row the endpoint never answered for states no percentage, so the vendor is not usable off it:
# an unmeasured weekly bucket is exactly what "no capacity known" means for this leg.
GROK_BLANK_CACHE="$WORK/grok-blank.json"
printf '{"accounts":[{"account":"broken","error":"network error: timed out","as_of":%s}]}\n' "$now" \
  >"$GROK_BLANK_CACHE"
grok_blank=$(env HOME="$GROK_HOME" GROKB_PROFILES_DIR="$GROK_PROFILES" \
  LLM_LIMITS_GROK_CACHE="$GROK_BLANK_CACHE" LLM_LIMITS_GROK_REFRESH=0 \
  LLM_LIMITS_CACHE="$WORK/grok-blank-store.json" bash "$SCRIPT" --json 2>/dev/null) \
  || fail "grok unmeasured-row collection failed"
jq -e '.vendors.grok.available == true and .vendors.grok.usable_now == false and
  (.vendors.grok.accounts[0] | .account == "broken" and (has("weekly") | not) and
   (has("auth") | not) and (has("as_of") | not))' <<<"$grok_blank" >/dev/null \
  || fail "an unmeasured grok account must not read as usable capacity"
grok_blank_table=$(env HOME="$GROK_HOME" GROKB_PROFILES_DIR="$GROK_PROFILES" \
  LLM_LIMITS_GROK_CACHE="$GROK_BLANK_CACHE" LLM_LIMITS_GROK_REFRESH=0 \
  LLM_LIMITS_CACHE="$WORK/grok-blank-store.json" bash "$SCRIPT" --table 2>/dev/null) \
  || fail "grok unmeasured-row table failed"
grep -Eq '^grok/broken\* +- +- +- +- +- +- +never ' <<<"$grok_blank_table" \
  || fail "an unmeasured grok row must render dashes and an alarming age: $grok_blank_table"

SHIELD_HOME="$WORK/shield-home"
SHIELD_STORE="$WORK/shield-store"
SHIELD_CODEX="$WORK/shield-codex"
SHIELD_GEMINI="$WORK/shield-gemini"
SHIELD_GROK="$WORK/shield-grok"
SHIELD_CACHE="$WORK/shield-cache.json"
mkdir -p "$SHIELD_HOME" "$SHIELD_STORE/limits" "$SHIELD_STORE/tokens" \
  "$SHIELD_CODEX" "$SHIELD_GEMINI" "$SHIELD_GROK"
touch "$SHIELD_STORE/tokens/primary" "$SHIELD_STORE/tokens/worker"
printf 'manual\n' >"$SHIELD_STORE/disabled"
cp "$SHIELD_STORE/disabled" "$WORK/shield-disabled.expected"
shield_now=1900000000
shield_far=$((shield_now + 604800))
shield_near=$((shield_now + 10800))
write_shield_snapshot() {
  local account="$1" pct="$2" reset="$3"
  printf '{"five_hour":{"used_percentage":10,"resets_at":%s,"as_of":%s,"origin":"usage"},"seven_day":{"used_percentage":%s,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
    "$((shield_now + 3600))" "$shield_now" "$pct" "$reset" "$shield_now" "$shield_now" \
    >"$SHIELD_STORE/limits/$account.json"
}
collect_shield_fixture() {
  HOME="$SHIELD_HOME" CLAUDEB_DIR="$SHIELD_STORE" CODEXB_PROFILES_DIR="$SHIELD_CODEX" \
    GEMINIB_PROFILES_DIR="$SHIELD_GEMINI" GROKB_PROFILES_DIR="$SHIELD_GROK" \
    LLM_LIMITS_NOW="$shield_now" LLM_LIMITS_CACHE="$SHIELD_CACHE" bash "$SCRIPT" --json
}

printf 'primary\n' >"$SHIELD_STORE/.claudeb-state"
write_shield_snapshot primary 90 "$shield_far"
write_shield_snapshot worker 99 "$shield_far"
shield_far_json=$(collect_shield_fixture) || fail "far-reset shield collection failed"
[ "$(cat "$SHIELD_STORE/shielded/primary")" = "$shield_far" ] \
  || fail "low daily budget did not store the weekly reset epoch in the shield marker"
[ ! -e "$SHIELD_STORE/shielded/worker" ] || fail "non-main high-usage account was shielded"
jq -e '([.vendors.claude.accounts[] | select(.account == "primary")][0] |
    .shielded == true and .enabled == false) and
  ([.vendors.claude.accounts[] | select(.account == "worker")][0] |
    .shielded == false and .enabled == true)' <<<"$shield_far_json" >/dev/null \
  || fail "shielded/enabled account fields did not reflect pool reachability"
cmp -s "$SHIELD_STORE/disabled" "$WORK/shield-disabled.expected" \
  || fail "shield reconciliation changed the manual disabled file"

write_shield_snapshot primary 90 "$shield_near"
shield_near_json=$(collect_shield_fixture) || fail "near-reset shield collection failed"
[ ! -e "$SHIELD_STORE/shielded/primary" ] \
  || fail "the 0.25-day budget floor did not clear the shield near reset"
jq -e '[.vendors.claude.accounts[] | select(.account == "primary")][0] |
  .shielded == false and .enabled == true' <<<"$shield_near_json" >/dev/null \
  || fail "near-reset main remained out of the pool"

mkdir -p "$SHIELD_STORE/shielded" "$SHIELD_STORE/shield-override"
printf '%s\n' "$shield_near" >"$SHIELD_STORE/shielded/primary"
printf '%s\n' "$shield_near" >"$SHIELD_STORE/shield-override/primary"
shield_next_week=$((shield_far + 604800))
write_shield_snapshot primary 1 "$shield_next_week"
collect_shield_fixture >/dev/null || fail "week-roll shield collection failed"
[ ! -e "$SHIELD_STORE/shielded/primary" ] || fail "week roll left the old shield marker active"
[ ! -e "$SHIELD_STORE/shield-override/primary" ] || fail "week roll left the old override active"

write_shield_snapshot primary 90 "$shield_far"
write_shield_snapshot worker 10 "$shield_far"
printf 'primary\n' >"$SHIELD_STORE/.claudeb-state"
collect_shield_fixture >/dev/null || fail "main shield setup collection failed"
[ -e "$SHIELD_STORE/shielded/primary" ] || fail "main shield setup did not create a marker"
printf 'worker\n' >"$SHIELD_STORE/.claudeb-state"
shield_switched_json=$(collect_shield_fixture) || fail "main-switch shield collection failed"
[ ! -e "$SHIELD_STORE/shielded/primary" ] || fail "account that stopped being main kept its shield"
jq -e '[.vendors.claude.accounts[] | select(.account == "primary")][0].shielded == false' \
  <<<"$shield_switched_json" >/dev/null || fail "store kept the old main shielded after the switch"
cmp -s "$SHIELD_STORE/disabled" "$WORK/shield-disabled.expected" \
  || fail "shield lifecycle changed the manual disabled file"

EMPTY="$WORK/empty-home"
mkdir -p "$EMPTY"
HOME="$EMPTY" bash "$SCRIPT" --no-write >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] || fail "all-missing case: expected exit 3, got $rc"
missing_json=$(HOME="$EMPTY" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.refresh_error.cause == "no vendor data available" and
  (.refresh_error.at | type) == "number"' <<<"$missing_json" >/dev/null \
  || fail "all-missing case lacked a structured global error"

# Egor reads ONE gray in this menu: the system's own, the tone macOS already paints the disabled
# percentage rows with. A gray spelled out here is a second one beside them whatever its numbers
# say, so the renderer may hold no gray literal at all and no alpha of its own outside the alarm
# tone — the dim comes from dimColor(), which resolves the system colour per render. Runs whether
# or not Hammerspoon is available: the evidence is the source text.
gray_hits=$(awk '
  /grayColor/ { printf "line %d: %s\n", NR, $0 }
  /red *=/ && /green *=/ && /blue *=/ {
    r = $0; sub(/.*red *= */, "", r); sub(/[ ,}].*/, "", r)
    g = $0; sub(/.*green *= */, "", g); sub(/[ ,}].*/, "", g)
    b = $0; sub(/.*blue *= */, "", b); sub(/[ ,}].*/, "", b)
    if (r == g && g == b) printf "line %d: %s\n", NR, $0
  }' "$ROOT/hammerspoon/llm-limits.lua")
[ -z "$gray_hits" ] || fail "a gray of our own is a second tone beside the system-dimmed percentage rows — style dim text with dimColor() instead: $gray_hits"

alpha_hits=$(awk '/alpha *=/ && !/dimRedColor/ { printf "line %d: %s\n", NR, $0 }' \
  "$ROOT/hammerspoon/llm-limits.lua")
[ -z "$alpha_hits" ] || fail "only the alarm tone dimRedColor may carry a literal alpha; every other dim is the system colour dimColor() resolves: $alpha_hits"

# A PAUSED vendor is parked for months and must not exist for the infrastructure: no helper is
# run for it, and the store carries no entry at all — the same absence a leg this machine never
# installed leaves, so every render path already has nothing to print.
PAUSE_HOME="$WORK/pause-home"
mkdir -p "$PAUSE_HOME/.claude" "$PAUSE_HOME/.codex/sessions/2026/07/10"
printf '{"five_hour":{"used_percentage":19,"resets_at":%s},"seven_day":{"used_percentage":53,"resets_at":%s}}\n' \
  "$((now + 1800))" "$((now + 7200))" >"$PAUSE_HOME/.claude/statusline-cache-rl"
cat >"$PAUSE_HOME/.codex/sessions/2026/07/10/rollout-pause.jsonl" <<EOF
{"timestamp":"2026-07-11T10:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":74,"window_minutes":300,"resets_at":$((now + 1000))},"secondary":{"used_percent":31,"window_minutes":10080,"resets_at":$((now + 2000))},"plan_type":"plus"}}}
EOF
PAUSE_CACHE="$WORK/pause-cache.json"
PAUSE_GROK_CACHE="$WORK/pause-grok.json"
printf '{"accounts":[{"account":"supergrok","used_pct":40,"resets_at":null,"reset_credits":2}]}\n' \
  >"$PAUSE_GROK_CACHE"
PAUSE_CALLS="$WORK/pause-helper-calls.log"
: >"$PAUSE_CALLS"
for pause_leg in grok codex gemini; do
  cat >"$WORK/pause-$pause_leg-helper" <<EOF
#!/usr/bin/env bash
printf '$pause_leg\n' >>"\$PAUSE_CALLS"
exit 1
EOF
  chmod +x "$WORK/pause-$pause_leg-helper"
done

pause_run() {
  env HOME="$PAUSE_HOME" LLM_LIMITS_CACHE="$PAUSE_CACHE" LLM_LIMITS_GROK_CACHE="$PAUSE_GROK_CACHE" \
    PAUSE_CALLS="$PAUSE_CALLS" \
    LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_GROK_REFRESH=1 \
    LLM_LIMITS_GEMINI_CMD="$WORK/pause-gemini-helper" \
    LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/pause-codex-helper" \
    LLM_LIMITS_GROK_QUOTA="$WORK/pause-grok-helper" \
    bash "$SCRIPT" "$@"
}

rm -f "$PAUSE_HOME/.claude/worker-model"
pause_before=$(pause_run --refresh --json 2>/dev/null || true)
jq -e '(.vendors | keys) == ["claude","codex","gemini","grok","opencode"]' <<<"$pause_before" >/dev/null \
  || fail "pause baseline did not collect every vendor"
grep -qx codex "$PAUSE_CALLS" || fail "pause baseline never ran the codex helper"
grep -qx grok "$PAUSE_CALLS" || fail "pause baseline never ran the grok helper"

: >"$PAUSE_CALLS"
printf 'codex_paused=on\ngrok_paused=on\nopencode_paused=on\n' >"$PAUSE_HOME/.claude/worker-model"
pause_out=$(pause_run --refresh --json 2>/dev/null || true)
jq -e '(.vendors | keys) == ["claude","gemini"]' <<<"$pause_out" >/dev/null \
  || fail "a paused vendor still has a store entry"
# The previous snapshot carried all five, so this is the merge step being asked to carry a parked
# vendor's numbers forward as if somebody were still measuring them.
jq -e '(.vendors | keys) == ["claude","gemini"]' "$PAUSE_CACHE" >/dev/null \
  || fail "the written store kept a paused vendor from the previous snapshot"
grep -qx gemini "$PAUSE_CALLS" || fail "the paused run refreshed nothing at all"
grep -qx codex "$PAUSE_CALLS" && fail "a paused codex still ran its quota helper"
grep -qx grok "$PAUSE_CALLS" && fail "a paused grok still ran its quota helper"

pause_table=$(pause_run --table 2>/dev/null) || true
grep -Eq '^(codex|grok|opencode)' <<<"$pause_table" && fail "--table printed a row for a paused vendor"
grep -q '^claude/' <<<"$pause_table" || fail "--table lost the vendors that are still running"
grep -Fq '↻' <<<"$pause_table" && fail "a paused grok left its reset count on the table"
pause_plain=$(pause_run --plain 2>/dev/null) || true
grep -Eq '^(codex|grok|opencode):' <<<"$pause_plain" && fail "--plain printed a line for a paused vendor"

# Only the literal `on` parks, and a duplicated key is read first-line-wins like every other key.
for pause_open in 'codex_paused=yes' 'codex_paused=off' 'codex_paused' 'codex_paused=off
codex_paused=on'; do
  printf '%s\n' "$pause_open" >"$PAUSE_HOME/.claude/worker-model"
  jq -e '.vendors | has("codex")' <<<"$(pause_run --json 2>/dev/null)" >/dev/null \
    || fail "a non-on pause value parked codex: $pause_open"
done
printf 'codex_paused=on\ncodex_paused=off\n' >"$PAUSE_HOME/.claude/worker-model"
jq -e '.vendors | has("codex") | not' <<<"$(pause_run --json 2>/dev/null)" >/dev/null \
  || fail "a duplicated pause key was read last-wins, not first"

# --refresh-account NAMES a vendor, so a parked one is refused rather than silently skipped.
printf 'grok_paused=on\nclaudeb_paused=on\n' >"$PAUSE_HOME/.claude/worker-model"
for pause_target in grok/supergrok grok; do
  pause_err=$(pause_run --refresh-account "$pause_target" 2>&1 >/dev/null) && \
    fail "--refresh-account $pause_target succeeded on a paused vendor"
  [ "$pause_err" = 'grok is paused (grok_paused=on in ~/.claude/worker-model)' ] \
    || fail "--refresh-account $pause_target refusal wording: $pause_err"
done
# The store spells Claude `claude`; the switch that parked it spells it `claudeb`.
pause_err=$(pause_run --refresh-account claude/main 2>&1 >/dev/null) && \
  fail "--refresh-account claude/main succeeded on a paused claudeb"
[ "$pause_err" = 'claudeb is paused (claudeb_paused=on in ~/.claude/worker-model)' ] \
  || fail "paused claude refusal wording: $pause_err"

# The pause is read through worker-pick's own config path, so a fixture can name its own file.
printf 'gemini_paused=on\n' >"$WORK/pause-config"
rm -f "$PAUSE_HOME/.claude/worker-model"
jq -e '(.vendors | keys) == ["claude","codex","grok","opencode"]' \
  <<<"$(WORKER_PICK_CONFIG_FILE="$WORK/pause-config" pause_run --json 2>/dev/null)" >/dev/null \
  || fail "WORKER_PICK_CONFIG_FILE was not honoured by the pause reader"
rm -f "$PAUSE_HOME/.claude/worker-model"


# The classification cases rewrite a collected document; this suite collects its own.
HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" bash "$SCRIPT" --json >/dev/null || fail "base collection for the refresh_errors cases failed"
# Structured refresh_errors: classification at write, roster-drop, one cause per HTTP blob.
blob='rateLimits/read failed: {'"'"'code'"'"': -32603, '"'"'message'"'"': '"'"'failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 402 Payment Required; content-type=text/plain; body={
  "error": {
    "message": "Payment Required",
    "type": null,
    "code": "deactivated_workspace"
  },
  "status": 402
}'"'"'}'
CLASS_CACHE="$WORK/refresh-errors-cache.json"
jq --arg cause "$blob" --argjson at "$now" \
  '.vendors.codex.refresh_error = {cause:$cause,at:$at} | del(.vendors.codex.refresh_errors)'   "$CACHE" >"$CLASS_CACHE"
class_out=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CLASS_CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" \
  /bin/bash "$SCRIPT" --json --no-write) || fail "refresh_errors migration collect failed"
jq -e --arg cause "$blob" '
  (.vendors.codex.refresh_errors | length) == 1 and
  .vendors.codex.refresh_errors[0].account == null and
  .vendors.codex.refresh_errors[0].class == "workspace deactivated" and
  .vendors.codex.refresh_errors[0].cause == $cause and
  (.vendors.codex.refresh_error.cause | contains("; content-type="))
' <<<"$class_out" >/dev/null \
  || fail "deactivated_workspace blob did not stay one vendor-wide refresh_errors entry: $(jq -c '.vendors.codex | {refresh_errors,refresh_error}' <<<"$class_out")"
jq --arg cause "$blob" --argjson at "$now" \
  '.vendors.codex.refresh_errors = [
     {account:"nexerod",class:"402 payment required",cause:$cause,at:$at}
   ] | del(.vendors.codex.refresh_error)' "$CACHE" >"$CLASS_CACHE"
drop_out=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CLASS_CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" \
  /bin/bash "$SCRIPT" --json --no-write) || fail "roster-drop collect failed"
jq -e '(.vendors.codex.refresh_errors | type) != "array" or (.vendors.codex.refresh_errors | length) == 0'   <<<"$drop_out" >/dev/null \
  || fail "deleted-account nexerod error was not dropped: $(jq -c '.vendors.codex.refresh_errors' <<<"$drop_out")"

class_case() {
  local cause=$1 class=$2
  jq --arg cause "$cause" --argjson at "$now" \
    '.vendors.codex.refresh_error = {cause:$cause,at:$at} | del(.vendors.codex.refresh_errors)' \
    "$CACHE" >"$CLASS_CACHE"
  local got
  got=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CLASS_CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" \
    /bin/bash "$SCRIPT" --json --no-write) || fail "class collect failed for $class"
  jq -e --arg class "$class" --arg cause "$cause" '
    .vendors.codex.refresh_errors[0].class == $class and
    .vendors.codex.refresh_errors[0].cause == $cause and
    .vendors.codex.refresh_error.cause == $cause
  ' <<<"$got" >/dev/null \
    || fail "class $class from $(jq -c '.vendors.codex.refresh_errors' <<<"$got")"
}
class_case "helper not executable" "helper missing"
class_case "refresh disabled" "refresh disabled"
class_case "timed out during free refresh + heal (1s)" "timeout"
class_case "login needed (not signed in)" "login needed"
class_case "HTTP 429 rate limit" "429 rate limit"
class_case "token refresh HTTP 500" "5xx server error"
class_case "garbled upstream blob {{{" "refresh failed"
class_case "HTTP 402 Payment Required" "402 payment required"
class_case 'HTTP 402 {"error":{"code":"deactivated_workspace","message":"Payment Required"}}' "workspace deactivated"

dead_cause='main: failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 402 Payment Required; body={"error":{"code":"deactivated_workspace","message":"Payment Required"}}'
jq --arg cause "$dead_cause" --argjson at "$now"   '.vendors.codex.refresh_error = {cause:$cause,at:$at} | del(.vendors.codex.refresh_errors)'   "$CACHE" >"$CLASS_CACHE"
dead_out=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CLASS_CACHE" LLM_LIMITS_WALLS_LOG="$WALLS"   /bin/bash "$SCRIPT" --json --no-write) || fail "deactivated_workspace collect failed"
jq -e --arg cause "$dead_cause" '
  any(.vendors.codex.refresh_errors[];
    .account == "main" and .class == "workspace deactivated" and .cause == $cause) and
  any(.vendors.codex.accounts[]; .account == "main" and .auth_needed == true) and
  (.vendors.codex.refresh_error.needs_user_entry == true)
' <<<"$dead_out" >/dev/null   || fail "deactivated workspace was not dead auth: $(jq -c '.vendors.codex | {refresh_errors,accounts:[.accounts[]|{account,auth_needed}]}' <<<"$dead_out")"

CLAUDE_ERR_STORE="$WORK/claude-refresh-errors-store"
mkdir -p "$CLAUDE_ERR_STORE/limits" "$CLAUDE_ERR_STORE/tokens"
: >"$CLAUDE_ERR_STORE/tokens/olx"
: >"$CLAUDE_ERR_STORE/tokens/notcom"
printf 'olx\n' >"$CLAUDE_ERR_STORE/.claudeb-state"
err_at=$(date +%s)
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' \
  "$((now + 5000))" "$err_at" >"$CLAUDE_ERR_STORE/limits/olx.json"
printf '{"five_hour":{"used_percentage":8,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' \
  "$((now + 5000))" "$err_at" >"$CLAUDE_ERR_STORE/limits/notcom.json"
jq --arg cause "olx: not refreshed (usage weather); notcom: not refreshed (token endpoint 429)" \
  --argjson at "$err_at" \
  '.vendors.claude.refresh_error = {cause:$cause,at:$at} | del(.vendors.claude.refresh_errors)' \
  "$CACHE" >"$CLASS_CACHE"
claude_err=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDE_ERR_STORE" LLM_LIMITS_CACHE="$CLASS_CACHE" \
  LLM_LIMITS_WALLS_LOG="$WALLS" /bin/bash "$SCRIPT" --json --no-write) \
  || fail "claude split collect failed"
jq -e '
  (.vendors.claude.refresh_errors | length) == 2 and
  any(.vendors.claude.refresh_errors[]; .account == "olx" and .class == "not refreshed (usage weather)") and
  any(.vendors.claude.refresh_errors[]; .account == "notcom" and .class == "429 rate limit") and
  (.vendors.claude.refresh_error.cause | test("olx: not refreshed")) and
  (.vendors.claude.refresh_error.cause | test("notcom: not refreshed"))
' <<<"$claude_err" >/dev/null \
  || fail "claude joined causes did not become two attributed refresh_errors: $(jq -c '.vendors.claude.refresh_errors' <<<"$claude_err")"

jq --arg cause "olx: not refreshed (usage weather); notcom: not refreshed (token endpoint 429)" \
  --argjson at "$err_at" \
  '.vendors.claude.refresh_errors = [
     {account:"olx",class:"not refreshed (usage weather)",cause:$cause,at:$at}
   ] | del(.vendors.claude.refresh_error)' \
  "$CACHE" >"$CLASS_CACHE"
claude_arr=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDE_ERR_STORE" LLM_LIMITS_CACHE="$CLASS_CACHE" \
  LLM_LIMITS_WALLS_LOG="$WALLS" /bin/bash "$SCRIPT" --json --no-write) \
  || fail "claude array re-split collect failed"
jq -e '
  (.vendors.claude.refresh_errors | length) == 2 and
  any(.vendors.claude.refresh_errors[]; .account == "olx" and .class == "not refreshed (usage weather)") and
  any(.vendors.claude.refresh_errors[]; .account == "notcom" and .class == "429 rate limit")
' <<<"$claude_arr" >/dev/null \
  || fail "stored joined refresh_errors were not re-split: $(jq -c '.vendors.claude.refresh_errors' <<<"$claude_arr")"

# A leading word is an account only when the roster holds it: `curl:` and `jq:` are the shape of a
# cause, and read as a name they invented an account the roster-drop then discarded the cause with.
jq --arg cause "curl: (7) failed to connect to host" --argjson at "$err_at" \
  '.vendors.claude.refresh_error = {cause:$cause,at:$at} | del(.vendors.claude.refresh_errors)' \
  "$CACHE" >"$CLASS_CACHE"
unattributed=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDE_ERR_STORE" LLM_LIMITS_CACHE="$CLASS_CACHE" \
  LLM_LIMITS_WALLS_LOG="$WALLS" /bin/bash "$SCRIPT" --json --no-write) \
  || fail "unattributed cause collect failed"
jq -e --arg cause "curl: (7) failed to connect to host" '
  (.vendors.claude.refresh_errors | length) == 1 and
  .vendors.claude.refresh_errors[0].account == null and
  .vendors.claude.refresh_errors[0].cause == $cause
' <<<"$unattributed" >/dev/null \
  || fail "a curl: prefix was read as an account: $(jq -c '.vendors.claude.refresh_errors' <<<"$unattributed")"

jq --arg cause "notcom: curl: (7) failed to connect to host" --argjson at "$err_at" \
  '.vendors.claude.refresh_error = {cause:$cause,at:$at} | del(.vendors.claude.refresh_errors)' \
  "$CACHE" >"$CLASS_CACHE"
attributed=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDE_ERR_STORE" LLM_LIMITS_CACHE="$CLASS_CACHE" \
  LLM_LIMITS_WALLS_LOG="$WALLS" /bin/bash "$SCRIPT" --json --no-write) \
  || fail "attributed cause collect failed"
jq -e --arg cause "notcom: curl: (7) failed to connect to host" '
  (.vendors.claude.refresh_errors | length) == 1 and
  .vendors.claude.refresh_errors[0].account == "notcom" and
  .vendors.claude.refresh_errors[0].cause == $cause
' <<<"$attributed" >/dev/null \
  || fail "a roster account prefix was not read as one: $(jq -c '.vendors.claude.refresh_errors' <<<"$attributed")"

hs_bounded() {
  python3 - "$@" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        ["/usr/bin/lockf", "-k", "-t", sys.argv[1], "/tmp/hs-cli.lock", "hs", "-t", "30", *sys.argv[2:]],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=int(sys.argv[1]) + 40,
    )
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
PY
}

if command -v hs >/dev/null 2>&1 && [ "$(hs_bounded 3 -c 'return "ok"' 2>/dev/null)" = ok ]; then
  renderer_output=$(hs_bounded 600 -c "_G.HS_ROOT = [[${HS_ROOT:-$HOME/.hammerspoon}]]; return dofile([[$ROOT/tests/llm_limits_renderer_harness.lua]])" 2>/dev/null) \
    || fail "Hammerspoon renderer contract checks threw"
  [ "$renderer_output" = "PASS: Hammerspoon projection contract" ] \
    || fail "Hammerspoon renderer contract checks: $renderer_output"
else
  echo "SKIP (hs unavailable): Hammerspoon projection contract"
fi

# agy's keychain read times out under parallel probes and answers "Authentication required" for a
# healthy token, so one auth_needed answer is never the verdict: it is re-asked once, alone under
# the shared probe lock, and only a second one records "login needed". Kept last and on its own
# HOME and store: the lock waits here must not age the fixtures the clock-bound checks above read.
GEMINI_FLAKY_HELPER="$WORK/fake-agy-flaky"
GEMINI_FLAKY_COUNT="$WORK/fake-agy-flaky.count"
GEMINI_FLAKY_DIR="$WORK/gemini-flaky-accounts"
GEMINI_FLAKY_HOME="$WORK/gemini-flaky-home"
GEMINI_FLAKY_CACHE="$WORK/gemini-flaky.json"
GEMINI_FLAKY_STORE="$WORK/gemini-flaky-store.json"
cat >"$GEMINI_FLAKY_HELPER" <<'EOF'
#!/usr/bin/env bash
calls=$(( $(cat "$GEMINI_FLAKY_COUNT" 2>/dev/null || printf 0) + 1 ))
printf '%s\n' "$calls" >"$GEMINI_FLAKY_COUNT"
if /usr/bin/lockf -k -t 0 "$GEMINI_FLAKY_DIR/.auth-probe.lock" true 2>/dev/null; then
  printf 'free\n' >>"$GEMINI_FLAKY_COUNT.lock"
else
  printf 'held\n' >>"$GEMINI_FLAKY_COUNT.lock"
fi
if [ "$calls" -le "$GEMINI_FLAKY_AUTH_CALLS" ]; then
  printf '%s\n' '{"auth_needed":true,"source":"agy-print-usage","detail":"Authentication required"}'
  exit 2
fi
printf '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.75,"resetTime":"%s"},{"window":"5h","remainingFraction":0.995,"resetTime":"%s"}]}]}\n' \
  "$GEMINI_WEEK_RESET" "$GEMINI_FIVE_RESET"
EOF
chmod +x "$GEMINI_FLAKY_HELPER"
mkdir -p "$GEMINI_FLAKY_DIR" "$GEMINI_FLAKY_HOME"
printf '%s\n' "$gemini_cache_saved" >"$GEMINI_FLAKY_CACHE"
run_gemini_flaky() {
  rm -f "$GEMINI_FLAKY_COUNT" "$GEMINI_FLAKY_COUNT.lock"
  GEMINI_FLAKY_COUNT="$GEMINI_FLAKY_COUNT" GEMINI_FLAKY_DIR="$GEMINI_FLAKY_DIR" \
    GEMINI_FLAKY_AUTH_CALLS="$1" LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_FLAKY_DIR" \
    LLM_LIMITS_GEMINI_AUTH_LOCK_WAIT="${2:-60}" \
    LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_FLAKY_HELPER" \
    LLM_LIMITS_GEMINI_CACHE="$GEMINI_FLAKY_CACHE" HOME="$GEMINI_FLAKY_HOME" \
    LLM_LIMITS_CACHE="$GEMINI_FLAKY_STORE" \
    /bin/bash "$SCRIPT" --refresh-account gemini --json 2>/dev/null
}
gemini_flaky=$(run_gemini_flaky 1) || fail "Gemini refresh with a contended first probe failed"
[ "$(cat "$GEMINI_FLAKY_COUNT")" = 2 ] || fail "a first auth_needed answer was not re-asked exactly once"
[ "$(tr '\n' ' ' <"$GEMINI_FLAKY_COUNT.lock")" = "free held " ] \
  || fail "the confirming Gemini probe did not run under the shared probe lock"
jq -e '.vendors.gemini.available == true and (.vendors.gemini | has("auth_needed") | not) and
  .vendors.gemini.status != "login needed" and (.vendors.gemini | has("refresh_error") | not) and
  .vendors.gemini.weekly.used_pct == 25' <<<"$gemini_flaky" >/dev/null \
  || fail "one contended Gemini probe still produced a login-needed verdict"
jq -e 'has("auth_needed") or has("auth_checked_at") | not' "$GEMINI_FLAKY_CACHE" >/dev/null \
  || fail "the Gemini cache kept an auth verdict the confirming probe overturned"
# This HOME holds no other vendor, so a Gemini with no usable account is the documented exit 3.
gemini_confirmed=$(run_gemini_flaky 2) || [ $? -eq 3 ] || fail "Gemini refresh with a confirmed logout failed"
[ "$(cat "$GEMINI_FLAKY_COUNT")" = 2 ] || fail "a confirmed Gemini logout took other than two probes"
jq -e '.vendors.gemini.auth_needed == true and .vendors.gemini.status == "login needed" and
  (.vendors.gemini.auth_checked_at | type) == "number"' <<<"$gemini_confirmed" >/dev/null \
  || fail "two auth_needed answers did not record login needed with its verdict time"
jq -e '.auth_needed == true and (.auth_checked_at | type) == "number" and
  (.groups[0].buckets | length) == 2' "$GEMINI_FLAKY_CACHE" >/dev/null \
  || fail "the confirmed Gemini logout lost its verdict time or the prior buckets"
printf '%s\n' "$gemini_cache_saved" >"$GEMINI_FLAKY_CACHE"
/usr/bin/lockf -k "$GEMINI_FLAKY_DIR/.auth-probe.lock" sleep 5 &
gemini_lock_holder=$!
sleep 0.5
gemini_busy=$(run_gemini_flaky 2 1) || [ $? -eq 3 ] || fail "Gemini refresh with a busy probe lock failed"
kill "$gemini_lock_holder" 2>/dev/null; wait "$gemini_lock_holder" 2>/dev/null
[ "$(cat "$GEMINI_FLAKY_COUNT")" = 1 ] || fail "a busy probe lock did not stop the confirming probe"
jq -e '(.vendors.gemini | has("auth_needed") | not) and
  .vendors.gemini.refresh_error.cause == "login unconfirmed (auth probe lock busy)"' \
  <<<"$gemini_busy" >/dev/null || fail "an unconfirmed Gemini logout became a verdict: $gemini_busy"

CLAUDEB_CREDITS="$WORK/claudeb-credits-store"
CLAUDEB_CREDITS_CACHE="$WORK/claudeb-credits-cache.json"
mkdir -p "$CLAUDEB_CREDITS/limits" "$CLAUDEB_CREDITS/tokens"
: >"$CLAUDEB_CREDITS/tokens/alona"
printf 'alona\n' >"$CLAUDEB_CREDITS/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"auth":{"status":"ok","checked_at":%s},"reset_credits":1,"reset_credits_as_of":%s,"reset_credits_expires_at":"2099-10-22T16:00:00Z"}\n' \
  "$((now + 5000))" "$now" "$now" >"$CLAUDEB_CREDITS/limits/alona.json"
claude_credits=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_CREDITS" LLM_LIMITS_CACHE="$CLAUDEB_CREDITS_CACHE" \
  bash "$SCRIPT" --json) || fail "claudeb collection with reset credits failed"
jq -e --argjson now "$now" '.vendors.claude.accounts[0] | .reset_credits == 1 and
  .reset_credits_as_of == $now and .reset_credits_stale == false and
  .reset_credits_expires_at == "2099-10-22T16:00:00Z"' <<<"$claude_credits" >/dev/null \
  || fail "the Claude projection dropped the reset consumable"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_CREDITS" LLM_LIMITS_CACHE="$CLAUDEB_CREDITS_CACHE" bash "$SCRIPT" --table \
  | awk '$1 == "claude/alona*" {print $(NF-1)}' | grep -qx '↻1' \
  || fail "Claude reset credits missing from CR"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_CREDITS" LLM_LIMITS_CACHE="$CLAUDEB_CREDITS_CACHE" bash "$SCRIPT" --plain \
  | grep -q '^claude/alona\*: .* | cr ↻1 | ' || fail "Claude reset credits missing from plain"
fi
echo "PASS: Grok weekly quota, shield, paused vendors, structured refresh_errors, flaky Gemini login verdicts, Claude reset credits"
