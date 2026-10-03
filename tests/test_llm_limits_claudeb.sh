#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/llm_limits_harness.sh"

home_fixture_after_first_suite

seed_claudeb_store
multi=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "claudeb collection failed"
jq -e '.vendors.claude.source == "claudeb-store" and (.vendors.claude.accounts | length) == 1 and .vendors.claude.accounts[0].account == "alona" and .vendors.claude.accounts[0].is_current == true and (.vendors.claude.accounts[0] | has("weekly") | not) and .vendors.claude.five_hour == .vendors.claude.accounts[0].five_hour and (.vendors.claude | has("weekly") | not)' <<<"$multi" >/dev/null || fail "claudeb schema, uniqueness, or hoist mismatch"
jq -e '.vendors.claude.accounts[0].fable.used_pct == 33 and .vendors.claude.fable.used_pct == 33 and
  all(.vendors.claude.accounts[]; .account != "main" and .account != "-")' <<<"$multi" >/dev/null \
  || fail "claudeb fable or unique-account mismatch"
jq -e '.vendors.claude.accounts[0].rotation == {usable:{general:true,fable:true}} and
  .vendors.claude.accounts[0].blocked == false and
  (.vendors.claude | has("daemon") | not)' <<<"$multi" >/dev/null \
  || fail "local Claude rotation contract mismatch"
jq -e '.vendors.claude.accounts[0] | has("reset_credits") | not' <<<"$multi" >/dev/null \
  || fail "a Claude snapshot without a reset count grew one"
jq -e 'all(.vendors.claude.accounts[]; .account != "main")' <<<"$multi" >/dev/null || fail "duplicate main account remained in JSON"

HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CLAUDEB_CMD="$WORK/missing-claudeb" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh >/dev/null 2>&1
rc=$?
[ "$rc" -eq 4 ] || fail "missing claudeb refresh: expected exit 4, got $rc"
jq -e '.vendors.claude.refresh_error.cause == "claudeb not found" and
  .refresh_error.cause == "all vendor refreshes failed"' "$CACHE" >/dev/null \
  || fail "missing claudeb refresh did not persist refresh_error"

cat >"$WORK/slow-claudeb" <<'EOF'
#!/usr/bin/env bash
sleep 2
EOF
chmod +x "$WORK/slow-claudeb"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CLAUDEB_CMD="$WORK/slow-claudeb" \
  LLM_LIMITS_CLAUDE_REFRESH_TIMEOUT=1 LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh >/dev/null 2>&1
rc=$?
[ "$rc" -eq 4 ] || fail "timed-out claudeb refresh: expected exit 4, got $rc"
jq -e '.vendors.claude.refresh_error.cause == "timed out during free refresh + heal (1s)"' "$CACHE" >/dev/null \
  || fail "timed-out claudeb refresh did not persist its reason"

# Residual staleness surfaces as vendor refresh_error for enabled accounts only and
# self-clears; pinned to /bin/bash (system bash 3.2) like the other refresh-path tests.
STALE_STORE="$WORK/claudeb-stale-store"
mkdir -p "$STALE_STORE/limits" "$STALE_STORE/tokens"
: >"$STALE_STORE/tokens/alona"
: >"$STALE_STORE/tokens/bree"
printf 'alona\n' >"$STALE_STORE/.claudeb-state"
printf 'bree\n' >"$STALE_STORE/disabled"
stale_asof=$((now - 3600))
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$((now + 5000))" "$stale_asof" >"$STALE_STORE/limits/alona.json"
printf '{"five_hour":{"used_percentage":9,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$((now + 5000))" "$stale_asof" >"$STALE_STORE/limits/bree.json"
printf '{"alona":{"attempted_at":%s,"outcome":"429","retry_after_until":0,"strikes":2},"bree":{"attempted_at":%s,"outcome":"429","retry_after_until":0,"strikes":1}}\n' "$now" "$now" >"$STALE_STORE/oauth-attempts.json"
cat >"$WORK/claudeb-noop" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/claudeb-noop"
STALE_CACHE="$WORK/stale-cache.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$STALE_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '
  (.vendors.claude.refresh_error.cause | test("alona: not refreshed")) and
  (.vendors.claude.refresh_error.cause | contains("robot curl refresh off (manual refresh only) — revive path active")) and
  (.vendors.claude.refresh_error.cause | contains("token rate-limited") | not)' "$STALE_CACHE" >/dev/null \
  || fail "residual stale enabled account not surfaced as claude refresh_error"
jq -e '(.vendors.claude.refresh_error.cause | test("bree")) | not' "$STALE_CACHE" >/dev/null \
  || fail "disabled stale account must not trigger a refresh_error"
# The user-explicit surfaces do reach the endpoint, so for them the recorded 429 is live
# evidence and keeps its ETA (shared-invariants row f).
CLAUDEB_WARM_USER_EXPLICIT=true HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" LLM_LIMITS_CACHE="$STALE_CACHE" \
  /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e --arg retry "$(date -r "$((now + 1800))" '+%H:%M' 2>/dev/null || date -d "@$((now + 1800))" '+%H:%M')" '
  (.vendors.claude.refresh_error.cause | test("alona: not refreshed")) and
  (.vendors.claude.refresh_error.cause | contains("token rate-limited, retry ~" + $retry)) and
  (.vendors.claude.refresh_error.cause | contains("token endpoint 429") | not)' "$STALE_CACHE" >/dev/null \
  || fail "a user-explicit refresh lost the residual 429 ETA"
cat >"$WORK/claudeb-target-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WORK/claudeb-target-fail"
printf '{"alona":{"attempted_at":%s,"outcome":"429","retry_after_until":0}}\n' "$now" >"$STALE_STORE/oauth-attempts.json"
CLAUDEB_WARM_USER_EXPLICIT=true HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-target-fail" LLM_LIMITS_CACHE="$STALE_CACHE" \
  /bin/bash "$SCRIPT" --refresh-account claude/alona >/dev/null 2>&1 || true
jq -e --arg retry "$(date -r "$((now + 900))" '+%H:%M' 2>/dev/null || date -d "@$((now + 900))" '+%H:%M')" '
  .vendors.claude.refresh_error.cause == ("alona: not refreshed (token rate-limited, retry ~" + $retry + ")") and
  (.vendors.claude.refresh_error.cause | contains("probe failed") | not)' "$STALE_CACHE" >/dev/null \
  || fail "targeted Claude refresh did not scope the legacy-429 ETA to its account"
printf '{"alona":{"attempted_at":%s,"outcome":"weather","http_status":500,"warm_attempted_at":%s,"warm_outcome":"warm-failed","warm_cause":"usage-probe-failed"}}\n' \
  "$((now - 86400))" "$now" >"$STALE_STORE/oauth-attempts.json"
CLAUDEB_WARM_USER_EXPLICIT=true HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-target-fail" LLM_LIMITS_CACHE="$STALE_CACHE" \
  /bin/bash "$SCRIPT" --refresh-account claude/alona >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause | contains("usage probe failed")) and
  (.vendors.claude.refresh_error.cause | contains("token refresh HTTP 500") | not)' "$STALE_CACHE" >/dev/null \
  || fail "newer warm failure did not outrank older token-refresh weather"
printf '{"alona":{"attempted_at":%s,"outcome":"weather","http_status":500,"warm_attempted_at":%s,"warm_outcome":"warm-failed","warm_cause":"usage-probe-failed"}}\n' \
  "$now" "$((now - 86400))" >"$STALE_STORE/oauth-attempts.json"
CLAUDEB_WARM_USER_EXPLICIT=true HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-target-fail" LLM_LIMITS_CACHE="$STALE_CACHE" \
  /bin/bash "$SCRIPT" --refresh-account claude/alona >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause | contains("token refresh HTTP 500")) and
  (.vendors.claude.refresh_error.cause | contains("usage probe failed") | not)' "$STALE_CACHE" >/dev/null \
  || fail "newer token-refresh weather did not outrank older warm failure"
cat >"$WORK/claudeb-fresh" <<EOF
#!/usr/bin/env bash
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":9999999999,"origin":"usage"}}\n' "$((now + 5000))" >"$STALE_STORE/limits/alona.json"
printf '{}' >"$STALE_STORE/oauth-attempts.json"
exit 0
EOF
chmod +x "$WORK/claudeb-fresh"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-fresh" \
  LLM_LIMITS_CACHE="$STALE_CACHE" /bin/bash "$SCRIPT" --refresh-account claude/alona >/dev/null 2>&1 || true
jq -e '.vendors.claude | has("refresh_error") | not' "$STALE_CACHE" >/dev/null \
  || fail "healed targeted account did not clear its per-account refresh_error"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-fresh" \
  LLM_LIMITS_CACHE="$STALE_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '.vendors.claude | has("refresh_error") | not' "$STALE_CACHE" >/dev/null \
  || fail "fully fresh refresh did not clear the residual-staleness cause"

AUTH_CLASS_STORE="$WORK/claudeb-auth-class-store"
mkdir -p "$AUTH_CLASS_STORE/limits" "$AUTH_CLASS_STORE/tokens"
: >"$AUTH_CLASS_STORE/tokens/alpha"
printf 'alpha\n' >"$AUTH_CLASS_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"expired","checked_at":%s,"cause":"needs re-login"}}\n' \
  "$((now + 5000))" "$now" "$now" >"$AUTH_CLASS_STORE/limits/alpha.json"
AUTH_CLASS_CACHE="$WORK/auth-class-cache.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$AUTH_CLASS_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$AUTH_CLASS_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '.vendors.claude.refresh_error.cause == "alpha auth (needs re-login)" and
  .vendors.claude.refresh_error.needs_user_entry == true and
  ([.vendors.claude.accounts[] | select(.account == "alpha")][0].needs_user_entry == true)' \
  "$AUTH_CLASS_CACHE" >/dev/null || fail "single Claude auth fragment was not classified for user entry"
: >"$AUTH_CLASS_STORE/tokens/beta"
printf '{"five_hour":{"used_percentage":9,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"expired","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$now" >"$AUTH_CLASS_STORE/limits/beta.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$AUTH_CLASS_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$AUTH_CLASS_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '.vendors.claude.refresh_error.cause == "alpha auth (needs re-login); beta auth" and
  .vendors.claude.refresh_error.needs_user_entry == true and
  ([.vendors.claude.accounts[] |
    select((.account == "alpha" or .account == "beta") and .needs_user_entry == true)] | length) == 2' \
  "$AUTH_CLASS_CACHE" >/dev/null || fail "multiple Claude auth fragments lost classification or separator"
: >"$AUTH_CLASS_STORE/tokens/network"
printf '{"five_hour":{"used_percentage":11,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now - 3600))" "$now" >"$AUTH_CLASS_STORE/limits/network.json"
printf '{"network":{"attempted_at":%s,"outcome":"weather","retry_after_until":0}}\n' "$now" \
  >"$AUTH_CLASS_STORE/oauth-attempts.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$AUTH_CLASS_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$AUTH_CLASS_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause |
    contains("alpha auth (needs re-login); beta auth; network: not refreshed (robot curl refresh off (manual refresh only) — revive path active)")) and
  (.vendors.claude.refresh_error | has("needs_user_entry") | not) and
  ([.vendors.claude.accounts[] |
    select((.account == "alpha" or .account == "beta") and .needs_user_entry == true)] | length) == 2 and
  ([.vendors.claude.accounts[] | select(.account == "network")][0].needs_user_entry // false) == false' \
  "$AUTH_CLASS_CACHE" >/dev/null || fail "mixed Claude entry/fault cause was globally misclassified"

# robot curl refresh off (shared-invariants row f): a dark (stale) account renders the honest
# robot cause, never a generic "probe failed"; the user-explicit path names the failing step.
ROBOT_STORE="$WORK/claudeb-robot-store"
mkdir -p "$ROBOT_STORE/limits" "$ROBOT_STORE/tokens"
: >"$ROBOT_STORE/tokens/frz"
printf 'frz\n' >"$ROBOT_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$((now + 5000))" "$((now - 3600))" >"$ROBOT_STORE/limits/frz.json"
printf '{}' >"$ROBOT_STORE/oauth-attempts.json"
ROBOT_CACHE="$WORK/robot-cache.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ROBOT_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$ROBOT_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '.vendors.claude.refresh_error.cause |
  contains("robot curl refresh off (manual refresh only) — revive path active")' "$ROBOT_CACHE" >/dev/null \
  || fail "dark account under a robot refresh not surfaced with the honest cause"
jq -e '(.vendors.claude.refresh_error.needs_user_entry // false) == false and
  (([.vendors.claude.accounts[] | select(.account == "frz")][0].needs_user_entry // false) == false) and
  (.vendors.claude.refresh_error.cause | contains("; ") | not)' "$ROBOT_CACHE" >/dev/null \
  || fail "robot stale cause asked for a manual entry or contained the join separator"

USER_CHILD_LOG="$WORK/user-claudeb-child.log"
cat >"$WORK/user-signal-claudeb" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${CLAUDEB_WARM_USER_EXPLICIT:-unset}" "$*" >>"$USER_CHILD_LOG"
if [ "${1:-}" = --help ]; then
  printf 'claudeb warm [--start-window] [names...]\nclaudeb --refresh [--start-windows]\n'
  exit 0
fi
printf '{"frz":{"warm_outcome":"warm-failed","warm_cause":"usage-probe-failed"}}\n' >"$CLAUDEB_DIR/oauth-attempts.json"
exit 1
EOF
chmod +x "$WORK/user-signal-claudeb"
export USER_CHILD_LOG
: >"$USER_CHILD_LOG"
CLAUDEB_WARM_USER_EXPLICIT=true HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ROBOT_STORE" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/user-signal-claudeb" LLM_LIMITS_CACHE="$ROBOT_CACHE" \
  /bin/bash "$SCRIPT" --refresh-account claude/frz --start-windows >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause | contains("usage probe failed")) and
  (.vendors.claude.refresh_error.cause | contains("robot curl refresh off") | not)' "$ROBOT_CACHE" >/dev/null \
  || fail "user-explicit hard refresh surfaced the robot cause instead of the failing step"
CLAUDEB_WARM_USER_EXPLICIT=true HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ROBOT_STORE" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/user-signal-claudeb" LLM_LIMITS_CACHE="$ROBOT_CACHE" \
  /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
CLAUDEB_WARM_USER_EXPLICIT=true HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ROBOT_STORE" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/user-signal-claudeb" LLM_LIMITS_CACHE="$ROBOT_CACHE" \
  /bin/bash "$SCRIPT" --refresh --start-windows >/dev/null 2>&1 || true
awk -F'|' '$1 != "true" { bad = 1 } END { exit bad }' "$USER_CHILD_LOG" \
  || fail "a user-explicit collector spawned claudeb without the signal"
grep -Fqx 'true|warm --start-window frz' "$USER_CHILD_LOG" \
  || fail "per-account Hard refresh lost the user signal"
grep -Fqx 'true|accounts --no-spend --heal' "$USER_CHILD_LOG" \
  || fail "global Refresh lost the user signal"
grep -Fqx 'true|--refresh --start-windows --heal' "$USER_CHILD_LOG" \
  || fail "Refresh + Start Windows lost the user signal"

# Regression: an OLD 429 entry must not mask the robot cause — this run never POSTed the
# endpoint, so "token rate-limited" would be a lie. (This is the exact live incident the
# battery previously failed to catch.)
printf '{"frz":{"attempted_at":%s,"outcome":"429","retry_after_until":%s,"strikes":6}}\n' "$((now - 10800))" "$((now + 3600))" >"$ROBOT_STORE/oauth-attempts.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ROBOT_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$ROBOT_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause | contains("robot curl refresh off"))
       and (.vendors.claude.refresh_error.cause | contains("token rate-limited") | not)' "$ROBOT_CACHE" >/dev/null \
  || fail "an old 429 masked the robot refresh cause"

# Auth-shaped cause (needs re-login) is actionable and must surface on a robot run too —
# a genuinely logged-out account must not hide behind the robot message.
printf '{"frz":{"outcome":"warm-failed","warm_outcome":"warm-failed","warm_cause":"needs re-login"}}\n' >"$ROBOT_STORE/oauth-attempts.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ROBOT_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$ROBOT_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause | contains("needs re-login"))
       and (.vendors.claude.refresh_error.cause | contains("robot curl refresh off") | not)' "$ROBOT_CACHE" >/dev/null \
  || fail "auth-shaped cause hidden by the robot message"
jq -e '.vendors.claude.refresh_error.needs_user_entry == true and
  ([.vendors.claude.accounts[] | select(.account == "frz")][0].needs_user_entry == true)' \
  "$ROBOT_CACHE" >/dev/null \
  || fail "needs-relogin cause was not classed for account entry"

# The robot guard covers the curl path only; revive is the sanctioned replacement, so its
# own failure cause is live evidence and the banner must not paint over it.
printf '{"frz":{"warm_outcome":"warm-failed","warm_cause":"warm-429","warm_kind":"revive","warm_attempted_at":%s}}\n' \
  "$((now - 120))" >"$ROBOT_STORE/oauth-attempts.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ROBOT_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$ROBOT_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause | contains("warm HTTP 429"))
       and (.vendors.claude.refresh_error.cause | contains("robot curl refresh off") | not)' "$ROBOT_CACHE" >/dev/null \
  || fail "a revive-recorded cause was masked by the robot banner"
# A warm-kind cause is current evidence from the free CLI session and stays visible.
printf '{"frz":{"warm_outcome":"warm-failed","warm_cause":"warm-429","warm_kind":"warm","warm_attempted_at":%s}}\n' \
  "$((now - 120))" >"$ROBOT_STORE/oauth-attempts.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ROBOT_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$ROBOT_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '.vendors.claude.refresh_error.cause | contains("warm HTTP 429")' \
  "$ROBOT_CACHE" >/dev/null || fail "a CLI warm cause was hidden by the robot banner"

# Per-account staleness causes self-clear on passive collects; other shapes never drop.
PASSIVE_STORE="$WORK/claudeb-passive-store"
mkdir -p "$PASSIVE_STORE/limits" "$PASSIVE_STORE/tokens"
: >"$PASSIVE_STORE/tokens/alona"
printf 'alona\n' >"$PASSIVE_STORE/.claudeb-state"
flag_at=$((now - 600))
passive_prev() {
  printf '{"schema":1,"fetched_at":"1970-01-01T00:00:00+0000","vendors":{"claude":{"available":false,"refresh_error":{"cause":"%s","at":%s}},"codex":{"available":false},"gemini":{"available":false}}}\n' \
    "$1" "$flag_at" >"$2"
}
passive_run() {
  HOME="$HOME_FIXTURE" CLAUDEB_DIR="$PASSIVE_STORE" LLM_LIMITS_CACHE="$1" \
    /bin/bash "$SCRIPT" --json >/dev/null 2>&1 || true
}
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$((now + 5000))" "$((now - 100))" >"$PASSIVE_STORE/limits/alona.json"
PASSIVE_CACHE="$WORK/passive-cache.json"
passive_prev "alona: not refreshed (usage weather)" "$PASSIVE_CACHE"
passive_run "$PASSIVE_CACHE"
jq -e '.vendors.claude | has("refresh_error") | not' "$PASSIVE_CACHE" >/dev/null \
  || fail "passive collect did not self-clear a healed per-account cause"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$((now + 5000))" "$((now - 900))" >"$PASSIVE_STORE/limits/alona.json"
passive_prev "alona: not refreshed (usage weather)" "$PASSIVE_CACHE"
passive_run "$PASSIVE_CACHE"
jq -e '.vendors.claude.refresh_error.cause | test("alona: not refreshed")' "$PASSIVE_CACHE" >/dev/null \
  || fail "passive collect dropped a still-stale per-account cause"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$((now + 5000))" "$((now - 100))" >"$PASSIVE_STORE/limits/alona.json"
passive_prev "probe failed" "$PASSIVE_CACHE"
passive_run "$PASSIVE_CACHE"
jq -e '.vendors.claude.refresh_error.cause == "probe failed"' "$PASSIVE_CACHE" >/dev/null \
  || fail "passive collect destroyed a non-per-account refresh_error cause"

# A logged-out claude account (auth_needed) is a vendor STATE, not a refresh failure:
# --refresh with the other account freshened still succeeds (exit 0) and emits NO
# claude refresh_error for the logged-out account, whose old buckets survive.
LOGOUT_STORE="$WORK/claudeb-logout-store"
mkdir -p "$LOGOUT_STORE/limits" "$LOGOUT_STORE/tokens"
: >"$LOGOUT_STORE/tokens/alona"
: >"$LOGOUT_STORE/tokens/logout1"
printf 'alona\n' >"$LOGOUT_STORE/.claudeb-state"
logout_old=$((now - 7200))
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$((now + 5000))" "$logout_old" >"$LOGOUT_STORE/limits/alona.json"
printf '{"auth_needed":true,"auth_checked_at":%s,"five_hour":{"used_percentage":15,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$now" "$((now + 5000))" "$logout_old" >"$LOGOUT_STORE/limits/logout1.json"
cat >"$WORK/claudeb-logout-refresh" <<EOF
#!/usr/bin/env bash
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":9999999999,"origin":"usage"}}\n' "$((now + 5000))" >"$LOGOUT_STORE/limits/alona.json"
exit 0
EOF
chmod +x "$WORK/claudeb-logout-refresh"
LOGOUT_CACHE="$WORK/logout-cache.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$LOGOUT_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-logout-refresh" \
  LLM_LIMITS_CACHE="$LOGOUT_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "refresh with a logged-out account did not exit 0 (got $rc)"
jq -e '.vendors.claude.available == true and (.vendors.claude | has("refresh_error") | not)' "$LOGOUT_CACHE" >/dev/null \
  || fail "a logged-out claude account was surfaced as a vendor refresh_error"
jq -e '.vendors.claude.accounts[] | select(.account == "logout1")
  | .auth_needed == true and .five_hour.used_pct == 15 and (has("auth") | not)' "$LOGOUT_CACHE" >/dev/null \
  || fail "logged-out claude account lost auth_needed or its preserved buckets"

# Passive collect carries auth_needed through untouched and renders login needed in the table.
logout_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$LOGOUT_STORE" LLM_LIMITS_CACHE="$LOGOUT_CACHE" \
  bash "$SCRIPT" --json) || fail "passive collect over a logged-out account failed"
jq -e '.vendors.claude.accounts[] | select(.account == "logout1")
  | .auth_needed == true and .five_hour.used_pct == 15' <<<"$logout_json" >/dev/null \
  || fail "passive collect dropped auth_needed or blanked the logged-out account's buckets"
logout_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$LOGOUT_STORE" LLM_LIMITS_CACHE="$LOGOUT_CACHE" \
  bash "$SCRIPT" --table)
awk 'NR > 1 && $1 == "claude/logout1"' <<<"$logout_table" | grep -q 'login needed' \
  || fail "logged-out claude account table STATUS missing login needed"

printf 'main\n' >"$CLAUDEB/.claudeb-state"
invalid_current=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "invalid current fallback failed"
jq -e '.vendors.claude.current_account == "alona" and all(.vendors.claude.accounts[]; .account != "main")' <<<"$invalid_current" >/dev/null || fail "invalid current did not fall back to the first real account"
printf 'alona\n' >"$CLAUDEB/.claudeb-state"
multi_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "claudeb plain collection failed"
grep -q 'claude/alona\*: 5h 7% @ .* | wk - @ - | fb 33% @ ' <<<"$multi_plain" || fail "claudeb plain window output mismatch"
grep 'claude/alona\*:' <<<"$multi_plain" | grep -q '| rot - |' || fail "unblocked local ROT must render as -"
grep -q 'claude/main' <<<"$multi_plain" && fail "main account leaked into plain output"
jq -e 'all(.vendors.claude.accounts[]; .enabled == true)' <<<"$multi" >/dev/null || fail "missing disabled file must default to enabled:true"

CLAUDEB_DIS="$WORK/claudeb-disabled-store"
mkdir -p "$CLAUDEB_DIS/limits"
printf 'alona\n' >"$CLAUDEB_DIS/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' "$((now + 5000))" "$now" >"$CLAUDEB_DIS/limits/alona.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' "$((now + 6000))" "$now" >"$CLAUDEB_DIS/limits/bree.json"
printf 'bree\n' >"$CLAUDEB_DIS/disabled"
disabled_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_DIS" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "disabled-flag collection failed"
jq -e '(.vendors.claude.accounts | length) == 2 and
  ([.vendors.claude.accounts[] | select(.account == "alona")][0] |
    .enabled == true and .blocked == false and
    .rotation == {usable:{general:true,fable:false}}) and
  # The pool toggle is consent, not capability (shared-invariants row o): bree is `blocked`, while
  # its live auth still reads `usable.general` — which is what lets a pin override the toggle.
  ([.vendors.claude.accounts[] | select(.account == "bree")][0] |
    .enabled == false and .blocked == true and
    .rotation == {usable:{general:true,fable:false}})' \
  <<<"$disabled_json" >/dev/null || fail "disabled file did not map to local rotation usability"
disabled_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_DIS" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "disabled table collection failed"
awk '$1 == "claude/bree"' <<<"$disabled_table" | grep -q 'off' || fail "disabled account not marked off in table"
awk '$1 == "claude/alona*"' <<<"$disabled_table" | grep -q 'off' && fail "enabled account wrongly marked off in table"
disabled_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_DIS" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "disabled plain collection failed"
grep 'claude/bree' <<<"$disabled_plain" | grep -q ' | rot off |' || fail "disabled account not marked off in plain output"
grep 'claude/alona' <<<"$disabled_plain" | grep -q ' | rot off |' && fail "enabled account wrongly marked off in plain output"

# Shared staleness contract: per-bucket as_of/origin pass through from the snapshot store;
# a bucket is stale on expired auth, cached origin, or age over the window threshold
# (5h: 1800s, weekly/fable: 21600s); missing as_of falls back to the snapshot mtime.
CLAUDEB_FRESH="$WORK/claudeb-freshness-store"
mkdir -p "$CLAUDEB_FRESH/limits"
printf 'aged\n' >"$CLAUDEB_FRESH/.claudeb-state"
printf '{"five_hour":{"used_percentage":7.000000000000001,"resets_at":%s,"as_of":%s,"origin":"usage"},"seven_day":{"used_percentage":56.99999999999999,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now - 3000))" "$((now + 90000))" "$((now - 3000))" "$now" >"$CLAUDEB_FRESH/limits/aged.json"
printf '{"five_hour":{"used_percentage":11,"resets_at":%s,"as_of":%s,"origin":"cached"}}\n' \
  "$((now + 5000))" "$now" >"$CLAUDEB_FRESH/limits/cachedorigin.json"
printf '{"five_hour":{"used_percentage":13,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"expired","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$now" >"$CLAUDEB_FRESH/limits/badauth.json"
printf '{"five_hour":{"used_percentage":14,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"failed","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$now" >"$CLAUDEB_FRESH/limits/failedauth.json"
printf '{"five_hour":{"used_percentage":19,"resets_at":%s,"as_of":%s,"origin":"usage"},"seven_day":{"used_percentage":23,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now - 200000))" "$((now - 200000))" "$((now - 4000))" "$((now - 200000))" "$now" \
  >"$CLAUDEB_FRESH/limits/ancientreset.json"
printf '{"five_hour":{"used_percentage":17,"resets_at":%s}}\n' "$((now + 5000))" >"$CLAUDEB_FRESH/limits/legacy.json"
touch -t 202607110500 "$CLAUDEB_FRESH/limits/legacy.json"
printf '{"auth":{"status":"expired","checked_at":%s}}\n' "$now" >"$CLAUDEB_FRESH/limits/authonly.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s,"as_of":%s,"origin":"session"},"seven_day":{"used_percentage":31,"resets_at":%s,"as_of":%s,"origin":"usage"},"fable":{"used_percentage":41,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now - 300))" "$((now + 90000))" "$((now - 600))" \
  "$((now + 90000))" "$((now - 10800))" "$now" >"$CLAUDEB_FRESH/limits/divergent.json"
printf 'divergent\n' >"$CLAUDEB_FRESH/.claudeb-state"
fresh_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "freshness-contract collection failed"
fresh_done=$(date +%s)
jq -e --argjson asof "$((now - 3000))" '
  [.vendors.claude.accounts[] | select(.account == "aged")][0] as $a |
  $a.five_hour.as_of == $asof and $a.five_hour.origin == "usage" and
  ($a.as_of | fromdateiso8601) == $asof and
  $a.five_hour.stale == true and $a.weekly.stale == false and $a.auth.status == "ok"' <<<"$fresh_json" >/dev/null \
  || fail "as_of threshold staleness mismatch"
jq -e '[.vendors.claude.accounts[] | select(.account == "cachedorigin")][0]
  | .five_hour.origin == "cached" and .five_hour.stale == true' <<<"$fresh_json" >/dev/null \
  || fail "cached origin must mark the bucket stale"
jq -e '[.vendors.claude.accounts[] | select(.account == "badauth")][0]
  | .auth.status == "expired" and .auth_needed == true and .blocked == true and
    .five_hour.stale == true' <<<"$fresh_json" >/dev/null \
  || fail "expired auth must reach the projection as auth_needed and blocked"
jq -e '[.vendors.claude.accounts[] | select(.account == "failedauth")][0]
  | .auth.status == "failed" and .auth_needed == true and .blocked == true' \
  <<<"$fresh_json" >/dev/null \
  || fail "failed auth must reach the projection as auth_needed and blocked"
jq -e '[.vendors.claude.accounts[] | select(.account == "legacy")][0]
  | (.five_hour.as_of | type) == "number" and .five_hour.stale == true' <<<"$fresh_json" >/dev/null \
  || fail "missing as_of must fall back to snapshot mtime"
# A reset over a day past is dropped, and dropping it may not cost the bucket its expiry: a
# surface reading the date as a schedule is the bug, an unexpired 19% reading beside it would
# be the worse one. A reset merely past keeps its date, since that window is still the one named.
jq -e '[.vendors.claude.accounts[] | select(.account == "ancientreset")][0]
  | .five_hour.resets_at == null and .five_hour.expired == true and
    .five_hour.effective_pct == 0 and .weekly.resets_at != null and
    .weekly.expired == true' <<<"$fresh_json" >/dev/null \
  || fail "an ancient reset must be dropped while its bucket stays expired"
# Every collection re-marks the whole merged document, cached rows included, so the row written
# above comes back through this pass with its date already gone: judged by the date alone it
# would read as a live 100%, which is the reading the drop exists to retire.
STICKY_STORE="$WORK/sticky-store"
mkdir -p "$STICKY_STORE/limits"
printf 'sticky\n' >"$STICKY_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":100,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now - 9000))" "$now" >"$STICKY_STORE/limits/sticky.json"
STICKY_CACHE="$WORK/sticky-cache.json"
printf '{"schema":1,"fetched_at":"x","vendors":{"claude":{"available":true,"source":"claudeb-store","current_account":"sticky","accounts":[{"account":"sticky","enabled":true,"five_hour":{"used_pct":100,"resets_at":null,"as_of":%s,"origin":"usage","stale":false,"expired":true,"effective_pct":0}}]}}}\n' \
  "$now" >"$STICKY_CACHE"
sticky_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STICKY_STORE" LLM_LIMITS_CACHE="$STICKY_CACHE" \
  bash "$SCRIPT" --json) || fail "sticky-expiry collection failed"
jq -e '[.vendors.claude.accounts[] | select(.account == "sticky")][0].five_hour
  | .resets_at == null and .expired == true and .effective_pct == 0' <<<"$sticky_json" >/dev/null \
  || fail "a bucket whose ancient reset was already dropped must stay expired on the next pass"
jq -e --argjson oldest "$((now - 10800))" --argjson now "$now" --argjson done "$fresh_done" '
  [.vendors.claude.accounts[] | select(.account == "divergent")][0] as $a |
  ($a.as_of | fromdateiso8601) == $oldest and
  $a.stale_seconds >= ($now - $oldest) and
  $a.stale_seconds <= ($done - $oldest) and
  (.vendors.claude.as_of | fromdateiso8601) == $oldest and
  .vendors.claude.stale_seconds == $a.stale_seconds and
  .vendors.claude.stale == true and .vendors.claude.auth.status == "ok"' <<<"$fresh_json" >/dev/null \
  || fail "vendor-level stale/auth hoist mismatch"
fresh_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) \
  || fail "divergent-window table collection failed"
awk '$1 == "claude/divergent*" {print $(NF-3)}' <<<"$fresh_table" | grep -Eq '^3h([0-9]+m)?$' \
  || fail "AGE did not render the oldest data-carrying window"
# Auth-only snapshot (failed probe, no five_hour): the account stays visible as unknown.
jq -e '[.vendors.claude.accounts[] | select(.account == "authonly")][0]
  | .five_hour.used_pct == null and .five_hour.effective_pct == null and
    .five_hour.stale == true and .auth.status == "expired" and
    .auth_needed == true and .blocked == true and
    (has("as_of") or has("stale_seconds") | not)' <<<"$fresh_json" >/dev/null \
  || fail "auth-only snapshot must stay visible with unknown values"
printf 'authonly\n' >"$CLAUDEB_FRESH/.claudeb-state"
cat >"$WORK/success-claudeb" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/success-claudeb"
auth_current=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/success-claudeb" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh-account claude/authonly) || fail "auth-only current collection failed"
jq -e '.vendors.claude.current_account == "authonly" and
  ([.vendors.claude.accounts[] | select(.is_current)][0] |
   .account == "authonly" and .five_hour.used_pct == null) and
  (.vendors.claude.five_hour.used_pct | type) == "number"' <<<"$auth_current" >/dev/null \
  || fail "auth-only current account must hoist the first populated five-hour bucket"

# Hard refresh (--refresh-account claude/NAME --start-windows) forwards warm --start-window.
CLAUDEB_ARGS_LOG="$WORK/claudeb-args.log"
cat >"$WORK/arglog-claudeb" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --help ]; then printf 'claudeb warm [--start-window] [names...]\n'; exit 0; fi
printf '%s\n' "\$*" >>"$CLAUDEB_ARGS_LOG"
exit 0
EOF
chmod +x "$WORK/arglog-claudeb"
: >"$CLAUDEB_ARGS_LOG"
hard_sw_err=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/arglog-claudeb" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh-account claude/authonly --start-windows 2>&1 >/dev/null) \
  || fail "hard refresh with --start-windows failed"
grep -qx 'warm --start-window authonly' "$CLAUDEB_ARGS_LOG" \
  || fail "hard refresh must forward warm --start-window"
if grep -q 'window state unknown\|window start skipped' <<<"$hard_sw_err"; then
  fail "claude-targeted hard refresh must not reach gemini/codex window-start: $hard_sw_err"
fi
# An older claudeb without warm --start-window degrades to a free warm, loudly.
cat >"$WORK/oldhelp-claudeb" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --help ]; then printf 'claudeb --refresh [--spend] [--start-windows] [--heal]\n'; exit 0; fi
printf '%s\n' "\$*" >>"$CLAUDEB_ARGS_LOG"
exit 0
EOF
chmod +x "$WORK/oldhelp-claudeb"
: >"$CLAUDEB_ARGS_LOG"
old_warm_err=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/oldhelp-claudeb" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh-account claude/authonly --start-windows 2>&1 >/dev/null) \
  || fail "hard refresh against old claudeb failed"
grep -qx 'warm authonly' "$CLAUDEB_ARGS_LOG" || fail "old claudeb must still get a free warm"
grep -q 'lacks --start-window' <<<"$old_warm_err" || fail "old-claudeb degradation must be loud"
# Window-start stays a claude-only concept on the per-account path.
for rejected_target in codex/beta gemini; do
  if HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" \
    bash "$SCRIPT" --refresh-account "$rejected_target" --start-windows >/dev/null 2>&1; then
    fail "$rejected_target with --start-windows must be rejected"
  fi
done

printf 'aged\n' >"$CLAUDEB_FRESH/.claudeb-state"
fresh_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "rounding table collection failed"
fresh_table=$(strip_ansi <<<"$fresh_table")
grep -Eq '^claude/aged\* +7%~ +57% ' <<<"$fresh_table" || fail "table percentages must round to integers"
# Unmeasured buckets render a bare dash (row y): markers qualify numbers only.
grep -Eq '^claude/authonly +- +- +- ' <<<"$fresh_table" || fail "auth-only account missing from table"
grep '^claude/authonly ' <<<"$fresh_table" | grep -q 'login needed$' || fail "Claude non-ok auth table status missing"
fresh_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "rounding plain collection failed"
fresh_plain=$(strip_ansi <<<"$fresh_plain")
grep -q 'claude/aged\*: 5h 7%~ @ .* | wk 57% @ ' <<<"$fresh_plain" || fail "plain percentages must round to integers"
grep -q 'claude/authonly: 5h - @ - | wk - @ - | fb - @ -' <<<"$fresh_plain" || fail "auth-only account missing from plain output"
grep '^claude/authonly:' <<<"$fresh_plain" | grep -q '| status login needed$' || fail "Claude non-ok auth plain status missing"
jq -e '(.vendors.claude.refresh_error.cause | contains("authonly") and endswith(" auth")) and
  (.vendors.claude.refresh_error.at | type) == "number"' <<<"$auth_current" >/dev/null \
  || fail "Claude auth failure was not exposed as vendor refresh_error"
auth_partial=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/success-claudeb" LLM_LIMITS_CODEX_REFRESH=0 \
  LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh) || fail "partial Claude account failure failed the whole run"
jq -e '(. | has("refresh_error") | not) and
  (.vendors.claude.refresh_error.cause | contains("authonly"))' <<<"$auth_partial" >/dev/null \
  || fail "partial Claude account failure lacked vendor-only error semantics"

# refresh_error is assembled from post-heal snapshot auth: a still-broken account is
# named with its cause; a healthy (successfully healed) account never appears.
CLAUDEB_HEAL="$WORK/claudeb-heal-store"
mkdir -p "$CLAUDEB_HEAL/limits"
printf 'healed\n' >"$CLAUDEB_HEAL/.claudeb-state"
printf '{"five_hour":{"used_percentage":4,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$now" >"$CLAUDEB_HEAL/limits/healed.json"
printf '{"five_hour":{"used_percentage":9,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"expired","checked_at":%s,"cause":"warm failed, token refresh backoff 15m"}}\n' \
  "$((now + 5000))" "$now" "$now" >"$CLAUDEB_HEAL/limits/stuck.json"
heal_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_HEAL" \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/success-claudeb" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh-account claude/healed) || fail "heal-contract collection failed"
jq -e '.vendors.claude.refresh_error.cause == "stuck auth (warm failed, token refresh backoff 15m)"' <<<"$heal_json" >/dev/null \
  || fail "refresh_error must name only the still-broken account and carry its cause"

echo "PASS: the claudeb store: unique accounts, hoist, rotation, current fallback, heal and refresh_error contract"
