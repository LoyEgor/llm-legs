#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/llm-limits.sh"
WORK="$(mktemp -d)"
daemon_pid=''
cleanup() {
  [ -z "$daemon_pid" ] || kill "$daemon_pid" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Unit fixtures must never discover and launch the developer's real agy binary.
export LLM_LIMITS_GEMINI_REFRESH=0
export LLM_LIMITS_CODEX_REFRESH=0
export CLAUDEBD_PORT=1
# Weather fixtures would otherwise spin claudeb's real convergence loop (240s of sleeps).
export CLAUDEB_REFRESH_CONVERGE_S=0
export CLAUDEB_WEATHER_RETRY_DELAY=0
export CLAUDEB_OAUTH_TOKEN_SPACING=0

HOME_FIXTURE="$WORK/home"
mkdir -p "$HOME_FIXTURE/.claude" "$HOME_FIXTURE/.codex/sessions/2026/07/10" "$HOME_FIXTURE/.codex/sessions/2026/07/11"
now=$(date +%s)
printf '{"five_hour":{"used_percentage":19,"resets_at":%s},"seven_day":{"used_percentage":53,"resets_at":%s}}\n' "$((now + 1800))" "$((now + 7200))" >"$HOME_FIXTURE/.claude/statusline-cache-rl"
printf '{"model":{"display_name":"Fable 5"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":%s},"seven_day":{"used_percentage":40,"resets_at":%s}}}\n' "$((now + 2400))" "$((now + 8400))" >"$HOME_FIXTURE/.claude/statusline-last.json"
cat >"$HOME_FIXTURE/.codex/sessions/2026/07/10/rollout-old.jsonl" <<EOF
{"timestamp":"2026-07-11T10:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":74,"window_minutes":300,"resets_at":$((now + 1000))},"secondary":{"used_percent":31,"window_minutes":10080,"resets_at":$((now + 2000))},"plan_type":"plus"}}}
{"timestamp":"2026-07-11T10:01:00Z","payload":{"type":"other"}}
EOF
sleep 1
printf '%s\n' '{"timestamp":"2026-07-11T11:00:00Z","payload":{"type":"session_meta"}}' >"$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-new.jsonl"
WALLS="$WORK/served-models.jsonl"
printf '%s\n' \
  '{"timestamp":"2026-07-11T08:00:00Z","leg":"gemini","rc":5}' \
  '{"timestamp":"2026-07-11T09:00:00Z","leg":"codex","rc":5}' >"$WALLS"

CACHE="$WORK/cache.json"
out=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" bash "$SCRIPT" --json) || fail "fixture collection failed"
jq -e '.schema == 1 and (.vendors | keys == ["claude","codex","gemini"])' <<<"$out" >/dev/null || fail "schema mismatch"
jq -e '.vendors.claude.five_hour.used_pct == 12 and .vendors.claude.weekly.used_pct == 40 and .vendors.claude.source == "statusline-last" and .vendors.claude.current_account == "main" and (.vendors.claude.accounts | length) == 1 and (.vendors.claude | has("session_model") | not)' <<<"$out" >/dev/null || fail "Claude primary snapshot mismatch"
jq -e '.vendors.codex.five_hour.used_pct == 74 and .vendors.codex.weekly.used_pct == 31 and
  .vendors.codex.plan_type == "plus" and .vendors.codex.current_account == "main" and
  (.vendors.codex.accounts | length) == 1 and .vendors.codex.accounts[0].account == "main"' \
  <<<"$out" >/dev/null || fail "Codex fallback mismatch"
jq -e '.vendors.claude.five_hour.effective_pct == .vendors.claude.five_hour.used_pct and
  .vendors.claude.accounts[0].weekly.effective_pct == .vendors.claude.accounts[0].weekly.used_pct and
  .vendors.codex.five_hour.effective_pct == .vendors.codex.five_hour.used_pct and
  .vendors.claude.usable_now == true and .vendors.codex.usable_now == true and
  .vendors.gemini.usable_now == false' <<<"$out" >/dev/null || fail "live effective percentages or usable state mismatch"
jq -e '(.vendors.claude.five_hour.as_of | type) == "number" and .vendors.claude.five_hour.stale == false and .vendors.claude.stale == false' <<<"$out" >/dev/null || fail "Claude bucket freshness fields missing"
jq -e '.vendors.codex.five_hour.origin == "headers" and (.vendors.codex.five_hour.as_of | type) == "number" and .vendors.codex.five_hour.stale == true and .vendors.codex.stale == true' <<<"$out" >/dev/null || fail "Codex rollout freshness fields mismatch"
jq -e '.vendors.gemini.available == false and .vendors.gemini.status == "no quota snapshot" and .vendors.gemini.last_wall == "2026-07-11T08:00:00Z"' <<<"$out" >/dev/null || fail "Gemini state mismatch"
jq -e . "$CACHE" >/dev/null || fail "cache was not valid JSON"
compgen -G "$CACHE.tmp.*" >/dev/null && fail "atomic-write temporary file remains"

CORRUPT_BIN="$WORK/corrupt-bin"
mkdir -p "$CORRUPT_BIN"
cat >"$CORRUPT_BIN/jq" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *'{schema:1,fetched_at:'*) printf '%s\n' '{broken'; exit 0 ;;
  esac
done
exec /usr/bin/jq "$@"
EOF
chmod +x "$CORRUPT_BIN/jq"
cache_before=$(shasum -a 256 "$CACHE" | awk '{print $1}')
PATH="$CORRUPT_BIN:$PATH" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --json >/dev/null 2>"$WORK/corrupt-result.err"
rc=$?
[ "$rc" -eq 5 ] || fail "corrupt pre-write JSON: expected exit 5, got $rc"
[ "$(shasum -a 256 "$CACHE" | awk '{print $1}')" = "$cache_before" ] \
  || fail "corrupt pre-write JSON replaced the valid cache"
grep -q 'refusing to replace cache with invalid JSON' "$WORK/corrupt-result.err" \
  || fail "corrupt pre-write JSON was not reported honestly"
compgen -G "$CACHE.tmp.*" >/dev/null && fail "corrupt pre-write JSON left a temporary file"
rm -f "$CORRUPT_BIN/jq"

cat >"$CORRUPT_BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  "$LLM_TEST_CACHE.tmp."*) exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$CORRUPT_BIN/mktemp"
cache_before=$(shasum -a 256 "$CACHE" | awk '{print $1}')
LLM_TEST_CACHE="$CACHE" PATH="$CORRUPT_BIN:$PATH" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --json >/dev/null 2>"$WORK/mktemp-failure.err"
rc=$?
[ "$rc" -eq 5 ] || fail "cache mktemp failure: expected exit 5, got $rc"
[ "$(shasum -a 256 "$CACHE" | awk '{print $1}')" = "$cache_before" ] \
  || fail "cache mktemp failure changed the valid cache"
grep -q 'cache temp creation failed' "$WORK/mktemp-failure.err" \
  || fail "cache mktemp failure was not reported honestly"
rm -f "$CORRUPT_BIN/mktemp"

# Gemini refresh: the helper's raw remainingFraction snapshot is cached and normalized to the
# same used_pct/reset schema as Claude and Codex. A normal collection reuses it without a call.
GEMINI_HELPER="$WORK/fake-agy-quota"
GEMINI_CACHE="$WORK/gemini.json"
GEMINI_SENTINEL="$WORK/gemini-called"
cat >"$GEMINI_HELPER" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GEMINI_SENTINEL"
printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.75,"resetTime":"2026-07-18T12:00:00Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.995,"resetTime":"2026-07-11T22:00:00Z"}]}]}'
EOF
chmod +x "$GEMINI_HELPER"
gemini_live=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh) \
  || fail "Gemini refresh collection failed"
jq -e '.vendors.gemini.available == true and .vendors.gemini.source == "agy-local-rpc" and
  .vendors.gemini.five_hour.used_pct == 1 and
  .vendors.gemini.weekly.used_pct == 25 and
  .vendors.gemini.five_hour.resets_at == "2026-07-11T22:00:00Z" and
  (.vendors.gemini | has("accounts") | not)' <<<"$gemini_live" >/dev/null \
  || fail "Gemini quota normalization mismatch (used_pct must be an integer)"
jq -e '.vendors.gemini.five_hour.origin == "usage" and .vendors.gemini.five_hour.stale == false and
  (.vendors.gemini.five_hour.as_of | type) == "number" and .vendors.gemini.stale == false and
  (.vendors.gemini | has("refresh_error") | not)' <<<"$gemini_live" >/dev/null \
  || fail "Gemini freshness fields mismatch"
[ -s "$GEMINI_SENTINEL" ] || fail "Gemini helper was not invoked by --refresh"
rm -f "$GEMINI_SENTINEL"
gemini_cached=$(LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Gemini cached collection failed"
jq -e '.vendors.gemini.available == true and .vendors.gemini.weekly.used_pct == 25' \
  <<<"$gemini_cached" >/dev/null || fail "Gemini cached snapshot missing"
[ ! -e "$GEMINI_SENTINEL" ] || fail "default collection invoked Gemini helper"
gemini_asof_before=$(jq -r '.vendors.gemini.as_of' <<<"$gemini_cached")
gemini_cache_saved=$(cat "$GEMINI_CACHE")
rm -f "$GEMINI_CACHE"
gemini_failed=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD=/usr/bin/false \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh-account gemini 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "failed Gemini account refresh: expected partial exit 0, got $rc"
jq -e --arg asof "$gemini_asof_before" \
  '.vendors.gemini.as_of == $asof and .vendors.gemini.refresh_error.cause == "live query failed" and
   (.vendors.gemini.refresh_error.at | type) == "number"' \
  <<<"$gemini_failed" >/dev/null || fail "failed Gemini account refresh advanced real-data as_of or hid its error"
printf '%s\n' "$gemini_cache_saved" >"$GEMINI_CACHE"

# Logged-out Gemini is a vendor STATE (login needed) that still carries an actionable cause,
# exactly like an expired Claude account: auth_needed is set, the prior snapshot's buckets stay
# in the helper cache for a clean recovery, the row renders "login needed" in table and plain,
# and the helper's reason surfaces as a vendor refresh_error (a re-login clears it). Exit stays 0.
GEMINI_AUTH_HELPER="$WORK/fake-agy-auth"
cat >"$GEMINI_AUTH_HELPER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"auth_needed":true,"source":"agy-local-rpc","detail":"not signed in"}'
exit 2
EOF
chmod +x "$GEMINI_AUTH_HELPER"
gemini_auth=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_AUTH_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json)
rc=$?
[ "$rc" -eq 0 ] || fail "logged-out Gemini refresh: expected exit 0, got $rc"
jq -e '.vendors.gemini.auth_needed == true and .vendors.gemini.available == false and
  .vendors.gemini.status == "login needed" and .vendors.gemini.usable_now == false and
  .vendors.gemini.refresh_error.cause == "login needed (not signed in)" and
  (.vendors.gemini.refresh_error.at | type) == "number"' <<<"$gemini_auth" >/dev/null \
  || fail "logged-out Gemini did not surface its login-needed cause as a refresh_error"
jq -e '.auth_needed == true and .detail == "not signed in" and (.groups[0].buckets | length) == 2' "$GEMINI_CACHE" >/dev/null \
  || fail "logged-out Gemini refresh dropped the prior snapshot buckets or its cause detail"
gemini_auth_table=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --table)
awk 'NR > 1 && $1 == "gemini"' <<<"$gemini_auth_table" | grep -q 'login needed$' \
  || fail "logged-out Gemini table STATUS missing login needed"
gemini_auth_plain=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --plain)
grep -q '^gemini: .* | status login needed' <<<"$gemini_auth_plain" \
  || fail "logged-out Gemini plain STATUS missing login needed"
# The login-needed cause persists across passive collects (no refresh), like Claude's auth cause.
gemini_auth_passive=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --json)
jq -e '.vendors.gemini.auth_needed == true and
  .vendors.gemini.refresh_error.cause == "login needed (not signed in)"' <<<"$gemini_auth_passive" >/dev/null \
  || fail "logged-out Gemini lost its login-needed cause on a passive collect"
gemini_recovered=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json)
jq -e '.vendors.gemini.available == true and (.vendors.gemini | has("auth_needed") | not) and
  (.vendors.gemini | has("refresh_error") | not) and .vendors.gemini.weekly.used_pct == 25' \
  <<<"$gemini_recovered" >/dev/null || fail "successful Gemini collection did not clear auth_needed"
rm -f "$GEMINI_SENTINEL"
printf '%s\n' "$gemini_cache_saved" >"$GEMINI_CACHE"

# auth_needed preservation must keep the old snapshot's mtime (as_of honesty).
touch -t 202601010000 "$GEMINI_CACHE"
gemini_auth_stale=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_AUTH_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json)
jq -e '.vendors.gemini.auth_needed == true and .vendors.gemini.stale_seconds > 1000000' \
  <<<"$gemini_auth_stale" >/dev/null \
  || fail "auth_needed preservation re-stamped the old snapshot's as_of as fresh"
printf '%s\n' "$gemini_cache_saved" >"$GEMINI_CACHE"

# Gemini "remove": a persistent marker hides the vendor everywhere while its creds stay
# invalid, and self-clears the moment a refresh finds valid creds again (owner re-logged
# in via agy) — self-healing, no orphan state.
GEMINI_MARKER="$GEMINI_CACHE.removed"
LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_AUTH_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json >/dev/null
gemini_removed=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --gemini-remove --json)
jq -e '.vendors.gemini.removed == true and .vendors.gemini.available == false and
  (.vendors.gemini | has("refresh_error") | not)' \
  <<<"$gemini_removed" >/dev/null \
  || fail "gemini-remove did not mark the vendor removed, or left a stale login-needed cause on a hidden row"
[ -e "$GEMINI_MARKER" ] || fail "gemini-remove did not persist the removed marker"
gemini_removed_table=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --table)
awk 'NR > 1 && $1 == "gemini"' <<<"$gemini_removed_table" | grep -q . \
  && fail "removed gemini still rendered a table row"
gemini_removed_plain=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --plain)
grep -q '^gemini:' <<<"$gemini_removed_plain" && fail "removed gemini still rendered a plain row"
gemini_still=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --json)
jq -e '.vendors.gemini.removed == true' <<<"$gemini_still" >/dev/null \
  || fail "removed gemini un-hid itself on a passive collect while still logged out"
[ -e "$GEMINI_MARKER" ] || fail "passive collect cleared the marker while still logged out"
gemini_healed=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json)
jq -e '.vendors.gemini.available == true and (.vendors.gemini | has("removed") | not) and
  .vendors.gemini.weekly.used_pct == 25' <<<"$gemini_healed" >/dev/null \
  || fail "valid gemini creds did not self-clear the removed marker"
[ ! -e "$GEMINI_MARKER" ] || fail "valid gemini creds left the removed marker in place"
rm -f "$GEMINI_SENTINEL"
printf '%s\n' "$gemini_cache_saved" >"$GEMINI_CACHE"

GEMINI_PROFILES="$WORK/gemini-profiles"
GEMINI_ACCOUNTS_CACHE="$WORK/gemini-accounts"
GEMINI_MULTI_LOG="$WORK/gemini-multi.log"
GEMINI_MULTI_HELPER="$WORK/fake-agy-multi"
mkdir -p "$GEMINI_PROFILES/work" "$GEMINI_ACCOUNTS_CACHE" "$HOME_FIXTURE/Library/Keychains"
cat >"$GEMINI_MULTI_HELPER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$HOME" >>"$GEMINI_MULTI_LOG"
printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.5,"resetTime":"2099-01-01T00:00:00Z"},{"window":"5h","remainingFraction":0.6,"resetTime":"2099-01-01T00:00:00Z"}]}]}'
EOF
GEMINI_MULTI_AUTH_HELPER="$WORK/fake-agy-multi-auth"
cat >"$GEMINI_MULTI_AUTH_HELPER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"auth_needed":true,"source":"agy-local-rpc","detail":"profile signed out"}'
exit 2
EOF
chmod +x "$GEMINI_MULTI_HELPER" "$GEMINI_MULTI_AUTH_HELPER"
multi_gemini=$(GEMINI_MULTI_LOG="$GEMINI_MULTI_LOG" GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MULTI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/work --json) \
  || fail "targeted Gemini profile refresh failed"
[ "$(cat "$GEMINI_MULTI_LOG")" = "$GEMINI_PROFILES/work" ] \
  || fail "targeted Gemini profile refresh used the wrong HOME"
[ "$(readlink "$GEMINI_PROFILES/work/Library/Keychains")" = "$HOME_FIXTURE/Library/Keychains" ] \
  || fail "Gemini profile refresh left the profile HOME without a keychain (macOS blocks the probe with a modal dialog)"
jq -e '.vendors.gemini.available == true and .vendors.gemini.current_account == "main" and
  (.vendors.gemini.accounts | length) == 2 and
  .vendors.gemini.weekly.used_pct == 50 and
  .vendors.gemini.five_hour.used_pct == 40 and
  [.vendors.gemini.accounts[] | select(.account == "main")][0].weekly.used_pct == 25 and
  [.vendors.gemini.accounts[] | select(.account == "work")][0].weekly.used_pct == 50' \
  <<<"$multi_gemini" >/dev/null || fail "Gemini profile snapshots were not isolated or selected-account buckets were not hoisted"
[ -s "$GEMINI_ACCOUNTS_CACHE/work.json" ] || fail "Gemini profile cache was not created"
if GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/missing --json >/dev/null 2>&1; then
  fail "unknown Gemini profile refresh unexpectedly succeeded"
fi

multi_auth=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MULTI_AUTH_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/work --json)
jq -e '[.vendors.gemini.accounts[] | select(.account == "work")][0] |
  .auth_needed == true and .status == "login needed" and
  .refresh_error.cause == "login needed (profile signed out)" and
  .weekly.used_pct == 50' <<<"$multi_auth" >/dev/null \
  || fail "Gemini profile login-needed state lost its cache or cause"
multi_main_recovered=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/main --json)
jq -e '.vendors.gemini.refresh_error.cause == "work: login needed (profile signed out)" and
  ([.vendors.gemini.accounts[] | select(.account == "work")][0] |
   .auth_needed == true and .status == "login needed" and
   .refresh_error.cause == "login needed (profile signed out)")' \
  <<<"$multi_main_recovered" >/dev/null \
  || fail "targeted Gemini refresh dropped an untouched profile status or refresh_error"
multi_all_auth=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MULTI_AUTH_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/main --json)
jq -e '.vendors.gemini.available == false and .vendors.gemini.auth_needed == true and
  ([.vendors.gemini.accounts[] | select(.auth_needed == true)] | length) == 2' \
  <<<"$multi_all_auth" >/dev/null || fail "all logged-out Gemini profiles were replaced by stale availability"
GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/main --json >/dev/null
multi_table=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --table)
grep -q '^gemini/main\*' <<<"$multi_table" || fail "Gemini main profile row missing"
grep '^gemini/work ' <<<"$multi_table" | grep -q 'login needed$' \
  || fail "Gemini named profile login-needed table row missing"
multi_plain=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --plain)
grep -q '^gemini/main\*:' <<<"$multi_plain" || fail "Gemini main profile plain row missing"
grep '^gemini/work:' <<<"$multi_plain" | grep -q '| status login needed$' \
  || fail "Gemini named profile login-needed plain row missing"

GEMINI_WORK_MARKER="$GEMINI_ACCOUNTS_CACHE/work.json.removed"
: >"$GEMINI_WORK_MARKER"
multi_removed=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --json)
jq -e '[.vendors.gemini.accounts[] | select(.account == "work")][0] |
  .removed == true and (. | has("refresh_error") | not)' <<<"$multi_removed" >/dev/null \
  || fail "Gemini named profile removed marker was not preserved"
multi_recovered=$(GEMINI_MULTI_LOG="$GEMINI_MULTI_LOG" GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MULTI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/work --json)
jq -e '[.vendors.gemini.accounts[] | select(.account == "work")][0] |
  .removed != true and .auth_needed != true and (. | has("refresh_error") | not)' \
  <<<"$multi_recovered" >/dev/null || fail "Gemini named profile did not recover"
[ ! -e "$GEMINI_WORK_MARKER" ] || fail "Gemini named profile recovery left its marker"

GEMINI_REMOVED_ONLY_PROFILES="$WORK/gemini-removed-only-profiles"
GEMINI_REMOVED_ONLY_CACHE="$WORK/gemini-removed-only-cache"
mkdir -p "$GEMINI_REMOVED_ONLY_PROFILES/empty" "$GEMINI_REMOVED_ONLY_CACHE"
printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0,"resetTime":"2099-01-01T00:00:00Z"},{"window":"5h","remainingFraction":0,"resetTime":"2099-01-01T00:00:00Z"}]}]}' \
  >"$WORK/gemini-exhausted-main.json"
: >"$GEMINI_REMOVED_ONLY_CACHE/gone.json.removed"
gemini_unusable=$(GEMINIB_PROFILES_DIR="$GEMINI_REMOVED_ONLY_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_REMOVED_ONLY_CACHE" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-exhausted-main.json" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --json)
jq -e '.vendors.gemini.usable_now == false and
  ([.vendors.gemini.accounts[] | select(.account == "empty" and .status == "no quota snapshot")] | length) == 1 and
  ([.vendors.gemini.accounts[] | select(.account == "gone" and .removed == true)] | length) == 1' \
  <<<"$gemini_unusable" >/dev/null \
  || fail "bucketless or removed Gemini profile made an exhausted vendor usable"
mkdir -p "$GEMINI_REMOVED_ONLY_PROFILES/gone"
gemini_removed_healed=$(GEMINI_MULTI_LOG="$GEMINI_MULTI_LOG" \
  GEMINIB_PROFILES_DIR="$GEMINI_REMOVED_ONLY_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_REMOVED_ONLY_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MULTI_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-exhausted-main.json" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/gone --json)
jq -e '[.vendors.gemini.accounts[] | select(.account == "gone")][0] |
  .removed != true and .weekly.used_pct == 50' <<<"$gemini_removed_healed" >/dev/null \
  || fail "recreated Gemini profile did not clear its persistent removed marker"
[ ! -e "$GEMINI_REMOVED_ONLY_CACHE/gone.json.removed" ] \
  || fail "recreated Gemini profile left its removed marker"

GEMINI_PARALLEL_PROFILES="$WORK/gemini-parallel-profiles"
GEMINI_PARALLEL_CACHE="$WORK/gemini-parallel-cache"
GEMINI_PARALLEL_GATE="$WORK/gemini-parallel-gate"
GEMINI_PARALLEL_HELPER="$WORK/fake-agy-parallel"
mkdir -p "$GEMINI_PARALLEL_PROFILES/work" "$GEMINI_PARALLEL_CACHE" "$GEMINI_PARALLEL_GATE"
cat >"$GEMINI_PARALLEL_HELPER" <<'EOF'
#!/usr/bin/env bash
account=main
[ "$HOME" = "$GEMINI_PARALLEL_MAIN_HOME" ] || account=$(basename "$HOME")
touch "$GEMINI_PARALLEL_GATE/started-$account"
ready=0
for attempt in $(seq 1 50); do
  set -- "$GEMINI_PARALLEL_GATE"/started-*
  if [ -e "$1" ] && [ "$#" -ge 2 ]; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" -eq 1 ] || { printf '{"error":"profiles were refreshed sequentially"}\n' >&2; exit 1; }
printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.7,"resetTime":"2099-01-01T00:00:00Z"},{"window":"5h","remainingFraction":0.8,"resetTime":"2099-01-01T00:00:00Z"}]}]}'
EOF
chmod +x "$GEMINI_PARALLEL_HELPER"
gemini_parallel=$(GEMINI_PARALLEL_MAIN_HOME="$HOME_FIXTURE" GEMINI_PARALLEL_GATE="$GEMINI_PARALLEL_GATE" \
  GEMINIB_PROFILES_DIR="$GEMINI_PARALLEL_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_PARALLEL_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_PARALLEL_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-parallel-main.json" LLM_LIMITS_CODEX_REFRESH=0 \
  LLM_LIMITS_CLAUDEB_CMD="$WORK/missing-claudeb" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh --json 2>/dev/null)
jq -e '.vendors.gemini.available == true and
  ([.vendors.gemini.accounts[] | select(.refresh_error != null)] | length) == 0 and
  ([.vendors.gemini.accounts[] | select(.weekly.used_pct == 30)] | length) == 2' \
  <<<"$gemini_parallel" >/dev/null \
  || fail "full Gemini refresh did not complete all profiles concurrently"

# The three refresh failure modes stay distinct and never collapse: only a logged-out helper
# (rc 2) is "login needed"; a crashed helper and a network failure (both rc 1) each keep their
# own cause and are never misread as auth. Each run starts from the same valid snapshot.
GEMINI_CRASH_HELPER="$WORK/fake-agy-crash"
cat >"$GEMINI_CRASH_HELPER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"error":"agy exited during startup: broken pipe","source":"agy-local-rpc"}' >&2
exit 1
EOF
GEMINI_NET_HELPER="$WORK/fake-agy-net"
cat >"$GEMINI_NET_HELPER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"error":"127.0.0.1:52341 tls=False: [Errno 61] Connection refused","source":"agy-local-rpc"}' >&2
exit 1
EOF
chmod +x "$GEMINI_CRASH_HELPER" "$GEMINI_NET_HELPER"
run_gemini_refresh() {
  printf '%s\n' "$gemini_cache_saved" >"$GEMINI_CACHE"
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$1" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
    HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh-account gemini --json 2>/dev/null
}
auth_json=$(run_gemini_refresh "$GEMINI_AUTH_HELPER")
crash_json=$(run_gemini_refresh "$GEMINI_CRASH_HELPER")
net_json=$(run_gemini_refresh "$GEMINI_NET_HELPER")
printf '%s\n' "$gemini_cache_saved" >"$GEMINI_CACHE"
jq -e '.vendors.gemini.auth_needed == true and
  .vendors.gemini.refresh_error.cause == "login needed (not signed in)"' <<<"$auth_json" >/dev/null \
  || fail "logged-out gemini (rc 2) is not classified login needed with its detail"
jq -e '(.vendors.gemini | has("auth_needed") | not) and
  .vendors.gemini.refresh_error.cause == "agy exited during startup: broken pipe"' <<<"$crash_json" >/dev/null \
  || fail "a crashed gemini helper (rc 1) collapsed into login-needed or hid its distinct cause"
jq -e '(.vendors.gemini | has("auth_needed") | not) and
  (.vendors.gemini.refresh_error.cause | contains("Connection refused"))' <<<"$net_json" >/dev/null \
  || fail "a network-weather gemini failure (rc 1) collapsed into login-needed or hid its cause"
auth_cause=$(jq -r '.vendors.gemini.refresh_error.cause' <<<"$auth_json")
crash_cause=$(jq -r '.vendors.gemini.refresh_error.cause' <<<"$crash_json")
net_cause=$(jq -r '.vendors.gemini.refresh_error.cause' <<<"$net_json")
[ "$auth_cause" != "$crash_cause" ] && [ "$crash_cause" != "$net_cause" ] && [ "$auth_cause" != "$net_cause" ] \
  || fail "gemini failure causes collapsed: auth=[$auth_cause] crash=[$crash_cause] net=[$net_cause]"

# --refresh-account bypasses the GLOBAL success gate, so a full --refresh is needed to prove the
# login-needed verdict counts as a completed refresh: with Claude and Codex both failing, Gemini
# resolving (login-needed, then healed) must NOT yield "all vendor refreshes failed", exactly
# like a healed usage poll rescuing the run.
GATE_HOME="$WORK/gate-home"; mkdir -p "$GATE_HOME/.claude"
GATE_STORE="$WORK/gate-claudeb"; mkdir -p "$GATE_STORE/limits"
printf 'gacct\n' >"$GATE_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$((now + 5000))" >"$GATE_STORE/limits/gacct.json"
GATE_CACHE="$WORK/gate-cache.json"
GATE_GEMINI_CACHE="$WORK/gate-gemini.json"
GATE_CODEX_FAIL="$WORK/gate-codex-fail"
cat >"$GATE_CODEX_FAIL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"error":"app-server unreachable","source":"codex-app-server"}' >&2
exit 1
EOF
chmod +x "$GATE_CODEX_FAIL"
run_full_refresh() { # $1 = gemini helper
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$1" LLM_LIMITS_GEMINI_CACHE="$GATE_GEMINI_CACHE" \
    LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$GATE_CODEX_FAIL" LLM_LIMITS_CODEX_CACHE="$WORK/gate-codex.json" \
    LLM_LIMITS_CLAUDEB_CMD="$WORK/missing-claudeb" \
    HOME="$GATE_HOME" CLAUDEB_DIR="$GATE_STORE" LLM_LIMITS_CACHE="$GATE_CACHE" \
    /bin/bash "$SCRIPT" --refresh --json 2>/dev/null
}
gate_login=$(run_full_refresh "$GEMINI_AUTH_HELPER"); rc=$?
[ "$rc" -eq 0 ] || fail "full refresh rescued by Gemini login-needed must exit 0 (partial), got $rc"
jq -e '.vendors.claude.refresh_error.cause == "claudeb not found"' <<<"$gate_login" >/dev/null \
  || fail "gate: Claude did not fail its refresh: $(jq -c '.vendors.claude.refresh_error' <<<"$gate_login")"
jq -e '(.vendors.codex | has("refresh_error"))' <<<"$gate_login" >/dev/null \
  || fail "gate: Codex did not fail its refresh: $(jq -c '.vendors.codex' <<<"$gate_login")"
jq -e '.vendors.gemini.auth_needed == true' <<<"$gate_login" >/dev/null \
  || fail "gate: Gemini not login-needed: $(jq -c '.vendors.gemini' <<<"$gate_login")"
jq -e '((.refresh_error.cause // "") != "all vendor refreshes failed")' <<<"$gate_login" >/dev/null \
  || fail "gate: Gemini login-needed did not count as a completed refresh (global gate fired)"
gate_healed=$(run_full_refresh "$GEMINI_HELPER"); rc=$?
[ "$rc" -eq 0 ] || fail "full refresh rescued by healed Gemini must exit 0, got $rc"
jq -e '.vendors.gemini.available == true and (.vendors.gemini | has("refresh_error") | not) and
  ((.refresh_error.cause // "") != "all vendor refreshes failed")' <<<"$gate_healed" >/dev/null \
  || fail "healed Gemini did not clear its cause or feed the global success gate"
rm -f "$GEMINI_SENTINEL"

# agy-quota.py detection against a fake agy: the transient "not signed in" during
# auto-sign-in must not read as login-needed (live regression: menu stuck after re-login).
FAKE_AGY="$WORK/fake-agy"
cat >"$FAKE_AGY" <<'EOF'
#!/usr/bin/env python3
import http.server, json, os, sys, threading, time
mode = os.environ.get("FAKE_AGY_MODE", "signin")
print("Welcome to the Antigravity CLI. You are currently not signed in.")
if mode == "chooser":
    print("Select login method")
    sys.stdout.flush(); time.sleep(30); sys.exit(0)
print("Signing in...")
sys.stdout.flush()
if mode == "stuck":
    time.sleep(30); sys.exit(0)
time.sleep(0.3)
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.dumps({"response": {"groups": [{"displayName": "Gemini Models", "buckets": [
            {"window": "5h", "remainingFraction": 1.0, "resetTime": "2099-01-01T00:00:00Z"},
            {"window": "weekly", "remainingFraction": 0.5, "resetTime": "2099-01-01T00:00:00Z"}]}]}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
print("Signed in")
print("? for shortcuts")
sys.stdout.flush()
time.sleep(60)
EOF
chmod +x "$FAKE_AGY"
agy_out=$(FAKE_AGY_MODE=signin AGY_BIN="$FAKE_AGY" AGY_WORKDIR="$WORK" \
  AGY_QUOTA_STARTUP_TIMEOUT=15 python3 "$ROOT/agy-quota.py") \
  || fail "transient auto-sign-in was misread as login needed (rc $?)"
jq -e '(.groups | type) == "array" and (has("auth_needed") | not)' <<<"$agy_out" >/dev/null \
  || fail "transient auto-sign-in probe returned no quota"
agy_rc=0
agy_out=$(FAKE_AGY_MODE=chooser AGY_BIN="$FAKE_AGY" AGY_WORKDIR="$WORK" \
  AGY_QUOTA_STARTUP_TIMEOUT=15 python3 "$ROOT/agy-quota.py") || agy_rc=$?
[ "$agy_rc" -eq 2 ] || fail "login chooser: expected exit 2, got $agy_rc"
jq -e '.auth_needed == true' <<<"$agy_out" >/dev/null || fail "login chooser: auth_needed missing"
agy_rc=0
agy_out=$(FAKE_AGY_MODE=stuck AGY_BIN="$FAKE_AGY" AGY_WORKDIR="$WORK" \
  AGY_QUOTA_STARTUP_TIMEOUT=2 python3 "$ROOT/agy-quota.py") || agy_rc=$?
[ "$agy_rc" -eq 2 ] || fail "stuck sign-in: expected exit 2 on timeout, got $agy_rc"
jq -e '.auth_needed == true' <<<"$agy_out" >/dev/null || fail "stuck sign-in: auth_needed missing"

# Regression: statusline-last.json goes stale while cache-rl keeps updating —
# the fresher cache-rl must win even though last.json is present and valid.
sleep 1
touch "$HOME_FIXTURE/.claude/statusline-cache-rl"
fresher=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "freshest-wins collection failed"
jq -e '.vendors.claude.five_hour.used_pct == 19 and .vendors.claude.source == "statusline-cache" and (.vendors.claude | has("session_model") | not)' <<<"$fresher" >/dev/null || fail "stale statusline-last.json outranked a fresher cache-rl"

rm "$HOME_FIXTURE/.claude/statusline-last.json"
fallback=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude fallback collection failed"
jq -e '.vendors.claude.five_hour.used_pct == 19 and .vendors.claude.weekly.used_pct == 53 and (.vendors.claude | has("session_model") | not) and .vendors.claude.source == "statusline-cache"' <<<"$fallback" >/dev/null || fail "Claude cache fallback mismatch"

plain=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" bash "$SCRIPT" --plain) || fail "plain collection failed"
grep -q 'claude/main\*: 5h 19% @ .* | wk 53% @ .* | fb - @ -' <<<"$plain" || fail "plain Claude values missing"
grep -q 'codex: 5h 74%~ @ .* | wk 31%~ @ .* | fb - @ -' <<<"$plain" || fail "plain Codex values or stale markers missing"
grep 'codex:' <<<"$plain" | grep -q '| age ' || fail "plain age field missing"
grep -q '| rot - | cr - | status -' <<<"$plain" || fail "plain explicit state fields missing"
grep -q '^gemini: .* | status no quota snapshot | last wall 2026-07-11T08:00:00Z$' <<<"$plain" \
  || fail "plain unavailable vendor lost its last wall"
fallback_table=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "fallback table collection failed"
grep -q '^claude/main' <<<"$fallback_table" || fail "unique fallback main account missing from table"

CLAUDEB="$WORK/claudeb-store"
mkdir -p "$CLAUDEB/limits" "$CLAUDEB/tokens"
: >"$CLAUDEB/tokens/alona"
printf 'alona\n' >"$CLAUDEB/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now + 5500))" >"$CLAUDEB/limits/alona.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s},"seven_day":{"used_percentage":62,"resets_at":%s}}\n' "$((now + 6000))" "$((now + 7000))" >"$CLAUDEB/limits/main.json"
multi=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "claudeb collection failed"
jq -e '.vendors.claude.source == "claudeb-store" and (.vendors.claude.accounts | length) == 1 and .vendors.claude.accounts[0].account == "alona" and .vendors.claude.accounts[0].is_current == true and (.vendors.claude.accounts[0] | has("weekly") | not) and .vendors.claude.five_hour == .vendors.claude.accounts[0].five_hour and (.vendors.claude | has("weekly") | not)' <<<"$multi" >/dev/null || fail "claudeb schema, uniqueness, or hoist mismatch"
jq -e '.vendors.claude.accounts[0].fable.used_pct == 33 and .vendors.claude.fable.used_pct == 33 and all(.vendors.claude.accounts[]; .account != "main")' <<<"$multi" >/dev/null || fail "claudeb fable or unique-account mismatch"

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
jq -e --arg retry "$(date -r "$((now + 1800))" '+%H:%M' 2>/dev/null || date -d "@$((now + 1800))" '+%H:%M')" '
  (.vendors.claude.refresh_error.cause | test("alona: not refreshed")) and
  (.vendors.claude.refresh_error.cause | contains("token rate-limited, retry ~" + $retry)) and
  (.vendors.claude.refresh_error.cause | contains("token endpoint 429") | not)' "$STALE_CACHE" >/dev/null \
  || fail "residual stale enabled account not surfaced as claude refresh_error"
jq -e '(.vendors.claude.refresh_error.cause | test("bree")) | not' "$STALE_CACHE" >/dev/null \
  || fail "disabled stale account must not trigger a refresh_error"
cat >"$WORK/claudeb-target-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WORK/claudeb-target-fail"
printf '{"alona":{"attempted_at":%s,"outcome":"429","retry_after_until":0}}\n' "$now" >"$STALE_STORE/oauth-attempts.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-target-fail" \
  LLM_LIMITS_CACHE="$STALE_CACHE" /bin/bash "$SCRIPT" --refresh-account claude/alona >/dev/null 2>&1 || true
jq -e --arg retry "$(date -r "$((now + 900))" '+%H:%M' 2>/dev/null || date -d "@$((now + 900))" '+%H:%M')" '
  .vendors.claude.refresh_error.cause == ("alona: not refreshed (token rate-limited, retry ~" + $retry + ")") and
  (.vendors.claude.refresh_error.cause | contains("probe failed") | not)' "$STALE_CACHE" >/dev/null \
  || fail "targeted Claude refresh did not scope the legacy-429 ETA to its account"
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

# token-freeze experiment: a dark (stale) account renders the honest frozen cause,
# never a generic "probe failed"; an expired `until` reverts to the normal cause.
FREEZE_STORE="$WORK/claudeb-freeze-store"
mkdir -p "$FREEZE_STORE/limits" "$FREEZE_STORE/tokens"
: >"$FREEZE_STORE/tokens/frz"
printf 'frz\n' >"$FREEZE_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' "$((now + 5000))" "$((now - 3600))" >"$FREEZE_STORE/limits/frz.json"
printf '{}' >"$FREEZE_STORE/oauth-attempts.json"
printf '{"started_at":%s,"reason":"token-freeze experiment"}\n' "$now" >"$FREEZE_STORE/token-freeze"
FREEZE_CACHE="$WORK/freeze-cache.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$FREEZE_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$FREEZE_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '.vendors.claude.refresh_error.cause | contains("auto-refresh frozen (experiment); enter the account to refresh")' "$FREEZE_CACHE" >/dev/null \
  || fail "frozen dark account not surfaced with the honest freeze cause"
printf '{"started_at":%s,"until":%s,"reason":"x"}\n' "$((now - 7200))" "$((now - 3600))" >"$FREEZE_STORE/token-freeze"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$FREEZE_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$FREEZE_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause // "" | contains("auto-refresh frozen")) | not' "$FREEZE_CACHE" >/dev/null \
  || fail "expired token-freeze until must render as unfrozen"

# Regression: a STALE pre-freeze 429 entry must not mask the active freeze — the
# endpoint is frozen this run, so "token rate-limited" would be a lie. (This is the
# exact live incident the battery previously failed to catch.)
printf '{"started_at":%s,"reason":"token-freeze experiment"}\n' "$now" >"$FREEZE_STORE/token-freeze"
printf '{"frz":{"attempted_at":%s,"outcome":"429","retry_after_until":%s,"strikes":6}}\n' "$((now - 10800))" "$((now + 3600))" >"$FREEZE_STORE/oauth-attempts.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$FREEZE_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$FREEZE_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause | contains("auto-refresh frozen (experiment)"))
       and (.vendors.claude.refresh_error.cause | contains("token rate-limited") | not)' "$FREEZE_CACHE" >/dev/null \
  || fail "stale pre-freeze 429 masked the active freeze cause"

# Auth-shaped cause (needs re-login) is actionable and must surface even under a
# freeze — a genuinely logged-out account must not hide behind the frozen message.
printf '{"frz":{"outcome":"warm-failed","warm_outcome":"warm-failed","warm_cause":"needs re-login"}}\n' >"$FREEZE_STORE/oauth-attempts.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$FREEZE_STORE" LLM_LIMITS_CLAUDEB_CMD="$WORK/claudeb-noop" \
  LLM_LIMITS_CACHE="$FREEZE_CACHE" /bin/bash "$SCRIPT" --refresh >/dev/null 2>&1 || true
jq -e '(.vendors.claude.refresh_error.cause | contains("needs re-login"))
       and (.vendors.claude.refresh_error.cause | contains("auto-refresh frozen") | not)' "$FREEZE_CACHE" >/dev/null \
  || fail "auth-shaped cause hidden by the frozen message"

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

DAEMON_PORT_FILE="$WORK/claudebd-fixture.port"
cat >"$WORK/claudebd-fixture.py" <<'EOF'
import http.server
import json
import os

payload = {
    "pid": 123,
    "uptime_s": 60,
    "port": 45789,
    "current": "alona",
    "current_fable": "alona",
    "accounts": {
        "alona": {"h5": 50, "wk": 10, "hreset": 4102444800, "wreset": 4102440000,
                  "walled": True, "auth_failed_until": 0, "fable_walled_until": 0,
                  "usable": {"general": False, "fable": True},
                  "blocked": {"general": "wall", "fable": None}},
        "fbonly": {"h5": 10, "wk": 20, "hreset": 4102444800, "wreset": 4102440000,
                   "walled": False, "auth_failed_until": 0, "fable_walled_until": 4102445000,
                   "usable": {"general": True, "fable": False},
                   "blocked": {"general": None, "fable": "limit-fable"}},
        "proacct": {"h5": 10, "wk": 20, "hreset": 4102444800, "wreset": 4102440000,
                    "walled": False, "auth_failed_until": 0, "fable_walled_until": 0,
                    "usable": {"general": True, "fable": True},
                    "blocked": {"general": None, "fable": None}},
    },
    "scopes": {"general": None, "fable": "alona"},
    "walls": [
        {"account": "alona", "scope": "general", "until": "2100-01-01T01:00:00.000Z",
         "reason": "transient"},
    ],
    "pins": [
        {"account": "alona", "pinned_at": "2100-01-01T00:00:00.000Z"},
    ],
    "all_walled_until": {"general": 4102448400, "fable": None},
}
legacy_payload = {
    "pid": 123,
    "uptime_s": 61,
    "port": 45789,
    "current": "alona",
    "current_fable": "alona",
    "accounts": {
        "alona": {"h5": 98, "wk": 40, "hreset": 4102444800, "wreset": 4102440000,
                  "walled": True, "auth_failed_until": 0, "fable_walled_until": 4102445000},
    },
}

class Handler(http.server.BaseHTTPRequestHandler):
    requests = 0

    def do_GET(self):
        if self.path != "/claudebd/status":
            self.send_error(404)
            return
        body = json.dumps(payload if Handler.requests < 3 else legacy_payload).encode()
        Handler.requests += 1
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.environ["DAEMON_PORT_FILE"], "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
EOF
DAEMON_PORT_FILE="$DAEMON_PORT_FILE" python3 "$WORK/claudebd-fixture.py" &
daemon_pid=$!
for _ in {1..40}; do
  [ -s "$DAEMON_PORT_FILE" ] && break
  sleep 0.05
done
[ -s "$DAEMON_PORT_FILE" ] || fail "claudebd fixture server did not start"
daemon_port=$(cat "$DAEMON_PORT_FILE")
printf '{"five_hour":{"used_percentage":10,"resets_at":%s},"seven_day":{"used_percentage":20,"resets_at":%s},"fable":{"used_percentage":90,"resets_at":%s}}\n' \
  "$((now + 5000))" "$((now + 7000))" "$((now + 8000))" >"$CLAUDEB/limits/fbonly.json"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s},"seven_day":{"used_percentage":20,"resets_at":%s},"fable":{"used_percentage":10,"resets_at":%s}}\n' \
  "$((now + 5000))" "$((now + 7000))" "$((now + 8000))" >"$CLAUDEB/limits/proacct.json"
PLAN_BIN="$WORK/plan-bin"
mkdir -p "$PLAN_BIN"
pro_profile="$HOME_FIXTURE/.claude-profiles/proacct"
pro_hash=$(printf '%s' "$pro_profile" | shasum -a 256 | awk '{print substr($1, 1, 8)}')
cat >"$PLAN_BIN/security" <<EOF
#!/usr/bin/env bash
service=''
while [ \$# -gt 0 ]; do
  if [ "\$1" = -s ] && [ \$# -gt 1 ]; then service=\$2; shift; fi
  shift
done
[ "\$service" = "Claude Code-credentials-$pro_hash" ] || exit 1
printf '%s\n' '{"claudeAiOauth":{"subscriptionType":"Pro"}}'
EOF
chmod +x "$PLAN_BIN/security"
daemon_json=$(PATH="$PLAN_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" CLAUDEBD_PORT="$daemon_port" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "claudebd status collection failed"
jq -e '.vendors.claude.daemon == {
  walls:[
    {account:"alona",scope:"general",until:"2100-01-01T01:00:00.000Z",reason:"transient"}
  ],
  pins:[{account:"alona",pinned_at:"2100-01-01T00:00:00.000Z"}],
  all_walled_until:{general:4102448400,fable:null},
  reachable:true
}' <<<"$daemon_json" >/dev/null || fail "native daemon wall fields were not passed through"
jq -e '.vendors.claude.accounts[0].rotation == {
  usable:{general:false,fable:true},blocked:{general:"wall",fable:null}
}' <<<"$daemon_json" >/dev/null || fail "daemon rotation projection was not merged into the matching account"
jq -e '[.vendors.claude.accounts[] | select(.account == "proacct")][0] |
  .plan_type == "pro" and
  .rotation == {usable:{general:true,fable:false},blocked:{general:null,fable:"plan"}}' \
  <<<"$daemon_json" >/dev/null || fail "Pro subscription did not disable Fable rotation"
daemon_table=$(PATH="$PLAN_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" CLAUDEBD_PORT="$daemon_port" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "daemon rotation table failed"
head -n 1 <<<"$daemon_table" | grep -Eq 'FB% +5H RESET +WK RESET +FB RESET +AGE +ROT +CR +STATUS' \
  || fail "universal table columns missing"
head -n 1 <<<"$daemon_table" | grep -q 'NOTE' && fail "NOTE column still present"
awk '$1 == "claude/alona*" {print $(NF-2)}' <<<"$daemon_table" | grep -qx 'wall' \
  || fail "general rotation block missing from ROT"
awk '$1 == "claude/fbonly" {print $(NF-2)}' <<<"$daemon_table" | grep -qx 'fb:limit-fable' \
  || fail "fable-only rotation block missing from ROT"
awk '$1 == "claude/proacct" {print $(NF-2)}' <<<"$daemon_table" | grep -qx 'fb:plan' \
  || fail "Pro-plan Fable block missing from ROT"
daemon_plain=$(PATH="$PLAN_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" CLAUDEBD_PORT="$daemon_port" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "daemon rotation plain failed"
grep 'claude/alona\*:' <<<"$daemon_plain" | grep -q '| rot wall |' || fail "plain general rotation block missing"
grep 'claude/fbonly:' <<<"$daemon_plain" | grep -q '| rot fb:limit-fable |' || fail "plain fable rotation block missing"
grep 'claude/proacct:' <<<"$daemon_plain" | grep -q '| rot fb:plan |' || fail "plain Pro-plan Fable block missing"
daemon_legacy=$(PATH="$PLAN_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" CLAUDEBD_PORT="$daemon_port" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "legacy claudebd status collection failed"
jq -e '.vendors.claude.daemon == {
  walls:[
    {account:"alona",scope:"general",until:"2100-01-01T00:00:00Z",reason:"walled"},
    {account:"alona",scope:"fable",until:"2100-01-01T00:03:20Z",reason:"fable_walled"}
  ],
  all_walled_until:{general:"2100-01-01T00:00:00Z",fable:"2100-01-01T00:03:20Z"},
  reachable:true
}' <<<"$daemon_legacy" >/dev/null || fail "legacy daemon wall derivation mismatch"
jq -e 'all(.vendors.claude.accounts[]; has("rotation") | not)' <<<"$daemon_legacy" >/dev/null \
  || fail "legacy daemon response fabricated account rotation fields"
rm "$CLAUDEB/limits/fbonly.json"
rm "$CLAUDEB/limits/proacct.json"
kill "$daemon_pid" 2>/dev/null || true
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=''
daemon_down=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" CLAUDEBD_PORT="$daemon_port" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "daemon-down collection failed"
jq -e '.vendors.claude.daemon == {reachable:false} and
  .vendors.claude.available == true and .vendors.claude.accounts[0].account == "alona" and
  all(.vendors.claude.accounts[]; has("rotation") | not)' \
  <<<"$daemon_down" >/dev/null || fail "daemon-down state blocked or damaged Claude collection"

printf 'main\n' >"$CLAUDEB/.claudeb-state"
invalid_current=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "invalid current fallback failed"
jq -e '.vendors.claude.current_account == "alona" and all(.vendors.claude.accounts[]; .account != "main")' <<<"$invalid_current" >/dev/null || fail "invalid current did not fall back to the first real account"
printf 'alona\n' >"$CLAUDEB/.claudeb-state"
multi_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "claudeb plain collection failed"
grep -q 'claude/alona\*: 5h 7% @ .* | wk - @ - | fb 33% @ ' <<<"$multi_plain" || fail "claudeb plain window output mismatch"
grep 'claude/alona\*:' <<<"$multi_plain" | grep -q '| rot - |' || fail "daemon-absent plain ROT must be unknown"
grep -q 'claude/main' <<<"$multi_plain" && fail "main account leaked into plain output"
jq -e 'all(.vendors.claude.accounts[]; .enabled == true)' <<<"$multi" >/dev/null || fail "missing disabled file must default to enabled:true"

# Rotation membership: a name listed in $CLAUDEB_DIR/disabled flips enabled to false
# for that account only, on the token-free passive path.
CLAUDEB_DIS="$WORK/claudeb-disabled-store"
mkdir -p "$CLAUDEB_DIS/limits"
printf 'alona\n' >"$CLAUDEB_DIS/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s}}\n' "$((now + 5000))" >"$CLAUDEB_DIS/limits/alona.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s}}\n' "$((now + 6000))" >"$CLAUDEB_DIS/limits/bree.json"
printf 'bree\n' >"$CLAUDEB_DIS/disabled"
disabled_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_DIS" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "disabled-flag collection failed"
jq -e '(.vendors.claude.accounts | length) == 2 and
  ([.vendors.claude.accounts[] | select(.account == "alona")][0].enabled == true) and
  ([.vendors.claude.accounts[] | select(.account == "bree")][0].enabled == false)' <<<"$disabled_json" >/dev/null || fail "disabled file did not map to enabled flags"
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
printf '{"five_hour":{"used_percentage":17,"resets_at":%s}}\n' "$((now + 5000))" >"$CLAUDEB_FRESH/limits/legacy.json"
touch -t 202607110500 "$CLAUDEB_FRESH/limits/legacy.json"
printf '{"auth":{"status":"expired","checked_at":%s}}\n' "$now" >"$CLAUDEB_FRESH/limits/authonly.json"
fresh_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "freshness-contract collection failed"
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
  | .auth.status == "expired" and .five_hour.stale == true' <<<"$fresh_json" >/dev/null \
  || fail "expired auth must mark buckets stale and pass auth through"
jq -e '[.vendors.claude.accounts[] | select(.account == "legacy")][0]
  | (.five_hour.as_of | type) == "number" and .five_hour.stale == true' <<<"$fresh_json" >/dev/null \
  || fail "missing as_of must fall back to snapshot mtime"
jq -e '.vendors.claude.stale == true and .vendors.claude.auth.status == "ok"' <<<"$fresh_json" >/dev/null \
  || fail "vendor-level stale/auth hoist mismatch"
# Auth-only snapshot (failed probe, no five_hour): the account stays visible as unknown.
jq -e '[.vendors.claude.accounts[] | select(.account == "authonly")][0]
  | .five_hour.used_pct == null and .five_hour.effective_pct == null and .five_hour.stale == true and .auth.status == "expired"' <<<"$fresh_json" >/dev/null \
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
  .vendors.claude.accounts[0].five_hour.used_pct == null and
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
grep -Eq '^claude/aged\* +7%~ +57% ' <<<"$fresh_table" || fail "table percentages must round to integers"
grep -Eq '^claude/authonly +-~ +- +- ' <<<"$fresh_table" || fail "auth-only account missing from table"
grep '^claude/authonly ' <<<"$fresh_table" | grep -q 'login needed$' || fail "Claude non-ok auth table status missing"
fresh_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "rounding plain collection failed"
grep -q 'claude/aged\*: 5h 7%~ @ .* | wk 57% @ ' <<<"$fresh_plain" || fail "plain percentages must round to integers"
grep -q 'claude/authonly: 5h -~ @ - | wk - @ - | fb - @ -' <<<"$fresh_plain" || fail "auth-only account missing from plain output"
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

CLAUDEB_BIN="$ROOT/bin/claudeb"
OAUTH_HOME="$WORK/oauth-home"
OAUTH_STORE="$WORK/oauth-store"
OAUTH_BIN="$WORK/oauth-bin"
OAUTH_SENTINEL="$WORK/oauth-curl-called"
OAUTH_CLAUDE_SENTINEL="$WORK/oauth-claude-called"
mkdir -p "$OAUTH_HOME/.claude-profiles/stuck" "$OAUTH_STORE/tokens" "$OAUTH_STORE/limits" "$OAUTH_BIN"
printf 'fixture-daemon-token\n' >"$OAUTH_STORE/tokens/stuck"
printf 'stuck\n' >"$OAUTH_STORE/.claudeb-state"
cat >"$OAUTH_BIN/security" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -w "*) printf '{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":%s}}\n' "${OAUTH_EXPIRES_AT:-1}" ;;
  *) exit 0 ;;
esac
EOF
cat >"$OAUTH_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OAUTH_SENTINEL"
headers=''
previous=''
for arg in "$@"; do
  if [ "$previous" = -D ]; then headers=$arg; fi
  previous=$arg
done
case "$*" in
  *platform.claude.com*) printf '\n400' ;;
  *api.anthropic.com/v1/messages*)
    if [ "${OAUTH_MESSAGES_HTTP:-200}" != 200 ]; then printf '%s' "$OAUTH_MESSAGES_HTTP"; exit; fi
    printf '%s\n' 'HTTP/2 200' 'anthropic-ratelimit-unified-status: allowed' \
      'anthropic-ratelimit-unified-5h-utilization: 0.01' \
      "anthropic-ratelimit-unified-5h-reset: $(($(date +%s) + 3600))" >"$headers"
    printf '200'
    ;;
  *) printf '%s' "${OAUTH_USAGE_HTTP:-401}" ;;
esac
EOF
cat >"$OAUTH_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OAUTH_CLAUDE_SENTINEL"
printf '%s\n' '{"result":"usage"}'
EOF
chmod +x "$OAUTH_BIN/security" "$OAUTH_BIN/curl" "$OAUTH_BIN/claude"
# A "failed" record from the direct-refresh path (curl against the OAuth token
# endpoint) must never gate the zero-cost warm fallback — heal proceeds anyway,
# since warm refreshes through the `claude` CLI's own auth, not that curl call.
printf '{"stuck":{"attempted_at":%s,"outcome":"failed","retry_after_until":0}}\n' "$now" >"$OAUTH_STORE/oauth-attempts.json"
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>"$WORK/oauth-backoff.err" || true
grep -q -- '-p /usage --output-format json' "$OAUTH_CLAUDE_SENTINEL" || fail "a direct-refresh failure record blocked the zero-cost warm fallback"

# A recent warm-failed outcome (warm's own bookkeeping) DOES throttle repeat
# heal attempts, at most once per account per 30 minutes. The throttle is a
# capacity condition, not evidence of dead credentials, so a throttled cycle must
# leave any prior auth verdict byte-untouched — never stamping or re-stamping one
# (a capacity "backoff" cause would refresh checked_at and disguise an unproven
# verdict as freshly confirmed).
rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
printf '{"stuck":{"attempted_at":%s,"outcome":"warm-failed","retry_after_until":0}}\n' "$now" >"$OAUTH_STORE/oauth-attempts.json"
printf '{"auth":{"status":"expired","checked_at":31337,"cause":"prior sentinel"}}' >"$OAUTH_STORE/limits/stuck.json"
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>/dev/null || true
[ ! -e "$OAUTH_CLAUDE_SENTINEL" ] || fail "a recent warm-failed outcome was not throttled to once per 30 minutes"
jq -e '.auth.status == "expired" and .auth.checked_at == 31337 and .auth.cause == "prior sentinel"' "$OAUTH_STORE/limits/stuck.json" >/dev/null \
  || fail "throttled heal must leave a prior auth verdict byte-untouched"

rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
OAUTH_EXPIRES_AT="$(((now + 3600) * 1000))" OAUTH_USAGE_HTTP=403 OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend >/dev/null 2>/dev/null || fail "plain refresh routing fixture failed"
[ ! -e "$OAUTH_CLAUDE_SENTINEL" ] || fail "plain accounts triggered warm without --heal"

rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
OAUTH_EXPIRES_AT="$(((now + 3600) * 1000))" OAUTH_USAGE_HTTP=403 OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>/dev/null || true
grep -q -- '-p /usage --output-format json' "$OAUTH_CLAUDE_SENTINEL" || fail "--heal did not self-heal auth with /usage"
grep -q -- '-p ok --model haiku' "$OAUTH_CLAUDE_SENTINEL" && fail "plain refresh used the paid warm fallback"

rm -f "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
printf '{"stuck":{"attempted_at":%s,"outcome":"warming","retry_after_until":0}}\n' "$((now - 181))" >"$OAUTH_STORE/oauth-attempts.json"
OAUTH_EXPIRES_AT="$(((now + 3600) * 1000))" OAUTH_USAGE_HTTP=403 OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>/dev/null || true
grep -q -- '-p /usage --output-format json' "$OAUTH_CLAUDE_SENTINEL" || fail "stale warming state did not expire"

if HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" bash "$CLAUDEB_BIN" add warm </dev/null >/dev/null 2>&1; then
  fail "add accepted reserved account name warm"
fi

rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL"
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" --refresh --start-windows >/dev/null 2>/dev/null || fail "start-windows auth fallback fixture failed"
grep -q 'api.anthropic.com/v1/messages' "$OAUTH_SENTINEL" || fail "start-windows did not use daemon-token messages fallback after auth failure"

WARM_HOME="$WORK/warm-home"
WARM_STORE="$WORK/warm-store"
WARM_BIN="$WORK/warm-bin"
WARM_SENTINEL="$WORK/warm-called"
mkdir -p "$WARM_HOME/.claude-profiles/one" "$WARM_HOME/.claude-profiles/two" \
  "$WARM_STORE/tokens" "$WARM_STORE/limits" "$WARM_BIN"
printf 'fixture\n' >"$WARM_STORE/tokens/one"
printf 'fixture\n' >"$WARM_STORE/tokens/two"
printf 'two\n' >"$WARM_STORE/disabled"
cat >"$WARM_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$CLAUDE_LIMITS_ACCOUNT" "$CLAUDE_CONFIG_DIR" "$*" >>"$WARM_SENTINEL"
if [ "${WARM_USAGE_429:-0}" = 1 ] && [ "${2:-}" = /usage ]; then printf 'HTTP 429 rate limit\n' >&2; exit 7; fi
if [ "${WARM_FAIL_USAGE:-0}" = 1 ] && [ "${2:-}" = /usage ]; then exit 7; fi
printf '%s\n' '{"result":"ok"}'
EOF
cat >"$WARM_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":$(((now + 3600) * 1000))}}'
EOF
cat >"$WARM_BIN/curl" <<EOF
#!/usr/bin/env bash
output=''
previous=''
for arg in "\$@"; do
  if [ "\$previous" = -o ]; then output=\$arg; fi
  previous=\$arg
done
printf '%s\n' '{"five_hour":{"utilization":10,"resets_at":"2026-07-13T01:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-07-19T01:00:00Z"},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":30,"resets_at":"2026-07-19T01:00:00Z"}]}' >"\$output"
printf '200'
EOF
chmod +x "$WARM_BIN/claude" "$WARM_BIN/security" "$WARM_BIN/curl"
WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm >/dev/null || fail "default warm fixture failed"
grep -q '^one|' "$WARM_SENTINEL" || fail "default warm omitted an enabled account"
grep -q '^two|' "$WARM_SENTINEL" && fail "default warm included a disabled account"
grep -q -- "-p /usage --output-format json" "$WARM_SENTINEL" || fail "warm did not use client-side /usage first"
grep -q -- "-p ok --model haiku" "$WARM_SENTINEL" && fail "successful /usage triggered the paid fallback"
: >"$WARM_SENTINEL"
WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm two >/dev/null || fail "explicit disabled warm fixture failed"
grep -q '^two|' "$WARM_SENTINEL" || fail "explicit warm did not include a disabled account"
: >"$WARM_SENTINEL"
# By default a failed /usage warm reports and stops; it must never spend on the paid probe.
WARM_FAIL_USAGE=1 WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm one >/dev/null 2>/dev/null && fail "failed /usage warm unexpectedly succeeded by default"
[ "$(wc -l <"$WARM_SENTINEL" | tr -d ' ')" -eq 1 ] || fail "default warm spent on the paid fallback"
sed -n '1p' "$WARM_SENTINEL" | grep -q -- '-p /usage --output-format json' || fail "default warm did not try /usage first"
grep -q -- '-p ok --model haiku' "$WARM_SENTINEL" && fail "default warm must not fire the paid fallback"
: >"$WARM_SENTINEL"
# The paid probe runs only behind the explicit opt-in no automated caller sets.
WARM_FAIL_USAGE=1 CLAUDEB_WARM_ALLOW_PAID=true WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm one >/dev/null || fail "opt-in warm paid-fallback fixture failed"
[ "$(wc -l <"$WARM_SENTINEL" | tr -d ' ')" -eq 2 ] || fail "opt-in failed /usage did not produce exactly one fallback"
sed -n '2p' "$WARM_SENTINEL" | grep -q -- '-p ok --model haiku --output-format json' || fail "opt-in failed /usage did not use the minimal paid fallback"
: >"$WARM_SENTINEL"
WARM_USAGE_429=1 WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm one >/dev/null 2>/dev/null && fail "rate-limited warm unexpectedly succeeded"
[ "$(wc -l <"$WARM_SENTINEL" | tr -d ' ')" -eq 1 ] || fail "rate-limited /usage retried through the paid fallback"

FAKE_BIN="$WORK/bin"
SENTINEL="$WORK/claudeb-called"
CODEX_SENTINEL="$WORK/codex-called"
CODEX_QUOTA_SENTINEL="$WORK/codex-quota-called"
CODEX_CACHE="$WORK/codex-quota.json"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/claudeb" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  echo "  claudeb --refresh [--no-spend] [--start-windows]"
  exit 0
fi
printf '%s\n' "$*" >>"$CLAUDEB_SENTINEL"
# A real free refresh restamps as_of; model it or the staleness check sees a stuck run.
if [ -n "${CLAUDEB_DIR:-}" ]; then
  for f in "$CLAUDEB_DIR"/limits/*.json; do [ -e "$f" ] && touch "$f"; done
fi
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >>"$CODEX_SENTINEL"\n' >"$FAKE_BIN/codex"
cat >"$WORK/fake-codex-quota" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>"\$CODEX_QUOTA_SENTINEL"
printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":31,"windowDurationMins":300,"resetsAt":$((now + 4000))},"secondary":{"usedPercent":64,"windowDurationMins":10080,"resetsAt":$((now + 90000))},"planType":"plus"}}'
EOF
chmod +x "$FAKE_BIN/claudeb" "$FAKE_BIN/codex" "$WORK/fake-codex-quota"

# --refresh is zero token spend: claudeb tier-1 snapshot, codex app-server usage query
# (never codex exec), and the live snapshot outranks the stale rollout tail.
refresh_out=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh) || fail "refresh collection failed"
# /bin/bash (3.2) is deliberate here and above: the menu's hs.task PATH resolves `env bash`
# to the system bash, where an empty-array expansion under set -u is fatal — every menu
# Refresh exited 1 on the no-target codex path for two days while suites ran on bash 5.
[ -s "$SENTINEL" ] || fail "--refresh did not invoke claudeb accounts"
grep -q 'accounts --no-spend' "$SENTINEL" || fail "Claude refresh was not tier-1-only"
[ -s "$CODEX_QUOTA_SENTINEL" ] || fail "--refresh did not invoke the codex quota helper"
[ ! -e "$CODEX_SENTINEL" ] || fail "--refresh must be zero-spend but codex exec was invoked"
jq -e '.vendors.codex.five_hour.used_pct == 31 and .vendors.codex.weekly.used_pct == 64 and
  .vendors.codex.five_hour.origin == "usage" and .vendors.codex.source == "codex-app-server" and
  .vendors.codex.five_hour.stale == false and .vendors.codex.plan_type == "plus" and
  (.vendors.codex | has("refresh_error") | not)' <<<"$refresh_out" >/dev/null \
  || fail "live codex quota did not outrank stale rollouts"

cat >"$WORK/fake-codex-quota-weekly" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":$((now + 90000))},"secondary":null,"planType":"plus"}}'
EOF
chmod +x "$WORK/fake-codex-quota-weekly"
weekly_only=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota-weekly" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  bash "$SCRIPT" --refresh --no-write 2>/dev/null) || fail "weekly-only codex refresh failed"
jq -e '.vendors.codex.available == true and .vendors.codex.five_hour.used_pct == null and
  .vendors.codex.weekly.used_pct == 0 and .vendors.codex.source == "codex-app-server" and
  (.vendors.codex | has("refresh_error") | not)' <<<"$weekly_only" >/dev/null \
  || fail "weekly-only codex payload was not normalized as an available vendor"
weekly_only_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" bash "$SCRIPT" --table 2>/dev/null) || fail "weekly-only codex table failed"
awk '$1 == "codex" {print}' <<<"$weekly_only_table" | grep -Eq '^codex +- +0%' \
  || fail "weekly-only codex table did not render unknown 5h and weekly percentage"
codex_restored=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  bash "$SCRIPT" --refresh --no-write 2>/dev/null) || fail "codex fixture restore failed"
refresh_failed=$(CLAUDEB_SENTINEL="$SENTINEL" LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD=/usr/bin/false LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "refresh with one vendor failure: expected partial exit 0, got $rc"
jq -e --arg asof "$(jq -r '.vendors.codex.as_of' <<<"$codex_restored")" \
  '.vendors.codex.refresh_error.cause == "live query failed" and
   (.vendors.codex.refresh_error.at | type) == "number" and
   .vendors.codex.five_hour.used_pct == 31 and .vendors.codex.as_of == $asof and
   (.refresh_error | not)' \
  <<<"$refresh_failed" >/dev/null || fail "Codex refresh failure was not machine-readable or stale data was lost"
rm -f "$SENTINEL" "$CODEX_QUOTA_SENTINEL"
cached_codex=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "default gated collection failed"
[ ! -e "$SENTINEL" ] || fail "default collection invoked claudeb"
[ ! -e "$CODEX_SENTINEL" ] || fail "default collection invoked codex"
[ ! -e "$CODEX_QUOTA_SENTINEL" ] || fail "default collection invoked the codex quota helper"
jq -e '.vendors.codex.five_hour.used_pct == 31 and .vendors.codex.five_hour.origin == "usage"' <<<"$cached_codex" >/dev/null \
  || fail "passive run did not reuse the codex quota cache"
jq -e '.vendors.codex.refresh_error.cause == "live query failed"' <<<"$cached_codex" >/dev/null \
  || fail "passive run cleared a standing vendor refresh error"

all_failed=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD=/usr/bin/false \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" LLM_LIMITS_CODEX_REFRESH=1 \
  LLM_LIMITS_CODEX_QUOTA_CMD=/usr/bin/false LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  LLM_LIMITS_CLAUDEB_CMD=/usr/bin/false HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" \
  LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh 2>/dev/null)
rc=$?
[ "$rc" -eq 4 ] || fail "all-vendor refresh failure: expected exit 4, got $rc"
jq -e '
  .refresh_error.cause == "all vendor refreshes failed" and
  all(.vendors[]; (.refresh_error.cause | type) == "string" and (.refresh_error.at | type) == "number") and
  .vendors.codex.five_hour.used_pct == 31 and .vendors.gemini.five_hour.used_pct == 1' \
  <<<"$all_failed" >/dev/null || fail "all-vendor failure lost structured errors or old buckets"

restored_after_failure=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  GEMINI_SENTINEL="$GEMINI_SENTINEL" \
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh) || fail "successful refresh did not clear standing errors"
jq -e '(. | has("refresh_error") | not) and all(.vendors[]; has("refresh_error") | not)' \
  <<<"$restored_after_failure" >/dev/null || fail "successful vendor refresh did not clear standing errors"

CODEX_ACCOUNTS_HOME="$WORK/codex-accounts-home"
CODEX_ACCOUNTS_CACHE="$WORK/codex-accounts.json"
mkdir -p "$CODEX_ACCOUNTS_HOME"
five_reset_epoch=$((now + 4000))
expired_reset_epoch=$((now - 60))
week_reset_epoch=$((now + 90000))
cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"schema":1,"fetched_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","plan_type":"plus","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"accounts":[{"account":"beta","plan_type":"team","reset_credits":0,"five_hour":{"used_pct":100,"resets_at":$expired_reset_epoch},"weekly":{"used_pct":100,"resets_at":$week_reset_epoch},"as_of":$((now - 22000))},{"account":"alpha","plan_type":"plus","reset_credits":2,"five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$((now - 1900))}],"current":"alpha"}
EOF
codex_accounts_full=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex multi-account collection failed"
jq -e '.vendors.codex.current_account == "alpha" and (.vendors.codex.accounts | length) == 2 and
  .vendors.codex.accounts[0].is_current == true and
  .vendors.codex.accounts[0].reset_credits == 2 and
  .vendors.codex.accounts[0].reset_credits_stale == false and
  (.vendors.codex.accounts[0].reset_credits_as_of | type) == "number" and
  .vendors.codex.accounts[0].five_hour.effective_pct == 100 and
  .vendors.codex.accounts[0].five_hour.stale == true and
  .vendors.codex.accounts[0].weekly.stale == false and
  .vendors.codex.accounts[1].five_hour.effective_pct == 0 and
  .vendors.codex.accounts[1].reset_credits == 0 and
  .vendors.codex.accounts[1].reset_credits_stale == true and
  .vendors.codex.accounts[1].five_hour.expired == true and
  (.vendors.codex.accounts[1].five_hour.resets_at | type) == "string" and
  .vendors.codex.accounts[1].weekly.effective_pct == 100 and
  .vendors.codex.accounts[1].weekly.stale == true and
  .vendors.codex.five_hour == .vendors.codex.accounts[0].five_hour and
  .vendors.codex.weekly == .vendors.codex.accounts[0].weekly and
  .vendors.codex.usable_now == false' <<<"$codex_accounts_full" >/dev/null \
  || fail "Codex multi-account normalization mismatch"
codex_accounts_table=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "Codex multi-account table failed"
[ "$(grep -c '^codex/' <<<"$codex_accounts_table")" -eq 2 ] || fail "Codex table did not render both accounts"
grep -q '^codex/alpha\*' <<<"$codex_accounts_table" || fail "Codex table current account marker missing"
grep -q '^codex/beta' <<<"$codex_accounts_table" || fail "Codex table secondary account missing"
awk '$1 == "codex/alpha*" {print $(NF-1)}' <<<"$codex_accounts_table" | grep -qx '↻2' \
  || fail "Codex reset credits missing from CR"
awk '$1 == "codex/beta" {print $(NF-1)}' <<<"$codex_accounts_table" | grep -qx '↻0' \
  || fail "zero Codex reset credits missing from CR"
grep -q 'plus\|team' <<<"$codex_accounts_table" && fail "Codex plan tag leaked into table"
codex_accounts_plain=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "Codex multi-account plain failed"
grep 'codex/alpha\*:' <<<"$codex_accounts_plain" | grep -q '| cr ↻2 |' || fail "plain Codex credits missing"
grep 'codex/beta:' <<<"$codex_accounts_plain" | grep -q '| cr ↻0 |' || fail "plain zero Codex credits missing"
CODEX_TARGET_SENTINEL="$WORK/codex-target-called"
cat >"$WORK/fake-codex-target" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$CODEX_TARGET_SENTINEL"
printf '%s\n' '{"accounts":[{"account":"beta","plan_type":"team","five_hour":{"used_pct":22,"resets_at":$five_reset_epoch},"weekly":{"used_pct":33,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$((now - 1900))}],"current":"beta"}'
EOF
chmod +x "$WORK/fake-codex-target"
codex_targeted=$(CODEX_TARGET_SENTINEL="$CODEX_TARGET_SENTINEL" HOME="$CODEX_ACCOUNTS_HOME" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-target" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh-account codex/beta) \
  || fail "Codex targeted account refresh failed"
grep -qx -- '--profile beta --no-cache' "$CODEX_TARGET_SENTINEL" \
  || fail "Codex targeted refresh did not use the existing single-profile RPC"
jq -e --argjson now "$now" '.vendors.codex.current_account == "alpha" and
  ([.vendors.codex.accounts[] | select(.account == "beta")][0] |
    .as_of == ($now | todateiso8601) and .five_hour.used_pct == 22)' \
  <<<"$codex_targeted" >/dev/null || fail "Codex targeted refresh changed current account or failed to advance only real target data"
jq '(.accounts[] | select(.account == "beta") | .five_hour.used_pct) = 25 |
    (.accounts[] | select(.account == "beta") | .weekly.used_pct) = 30' \
  "$CODEX_ACCOUNTS_CACHE" >"$CODEX_ACCOUNTS_CACHE.tmp"
mv "$CODEX_ACCOUNTS_CACHE.tmp" "$CODEX_ACCOUNTS_CACHE"
codex_accounts_free=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex free-account collection failed"
jq -e '.vendors.codex.usable_now == true and .vendors.codex.five_hour.effective_pct == 100' \
  <<<"$codex_accounts_free" >/dev/null || fail "Codex one-free-account usability mismatch"

cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"accounts":[{"account":"work","auth_needed":true,"as_of":$now,"error":"codex account authentication required to read rate limits"}],"current":"work"}
EOF
codex_auth_needed=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex auth-needed collection failed"
jq -e '.vendors.codex.available == true and .vendors.codex.current_account == "work" and
  .vendors.codex.usable_now == false and (.vendors.codex.accounts | length) == 1 and
  .vendors.codex.accounts[0].account == "work" and .vendors.codex.accounts[0].auth_needed == true and
  (.vendors.codex.accounts[0] | has("five_hour") or has("weekly") or has("as_of") or has("stale_seconds") | not)' \
  <<<"$codex_auth_needed" >/dev/null || fail "Codex auth-needed account normalization mismatch"
codex_auth_table=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "Codex auth-needed table failed"
codex_auth_plain=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "Codex auth-needed plain failed"
grep -Eq '^codex/work\* +- +- +- +- +- +- +- +- +- +login needed$' <<<"$codex_auth_table" \
  || fail "Codex auth-needed table status missing: $codex_auth_table"
grep -q '^codex/work\*: .* | status login needed$' <<<"$codex_auth_plain" \
  || fail "Codex auth-needed plain status missing: $codex_auth_plain"

# --refresh-account with an invalidated token: the helper reports auth (rc 2) with a SHORT
# cause and no raw RPC blob; llm-limits.sh must persist the per-account auth-needed marker,
# render login-needed, preserve the current account, and keep the raw 401 text out of every
# user-visible cause.
cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"schema":1,"fetched_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","accounts":[{"account":"beta","plan_type":"team","five_hour":{"used_pct":22,"resets_at":$five_reset_epoch},"weekly":{"used_pct":33,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"alpha"}
EOF
cat >"$WORK/fake-codex-auth" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"error":"rateLimits/read failed: 401 Unauthorized; token_invalidated","source":"codex-app-server","account":"beta"}' >&2
printf '%s\n' '{"auth_needed":true,"cause":"login needed: token invalidated","accounts":[{"account":"beta","auth_needed":true,"as_of":$now,"cause":"login needed: token invalidated"},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"beta"}'
exit 2
EOF
chmod +x "$WORK/fake-codex-auth"
CODEX_AUTH_LOG="$WORK/codex-auth.log"
codex_target_auth=$(HOME="$CODEX_ACCOUNTS_HOME" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-auth" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh-account codex/beta 2>"$CODEX_AUTH_LOG") \
  || fail "Codex targeted auth refresh failed"
# The raw RPC error survives in the log (HTTP/RPC context) even though the cache/UI keep only
# the short cause.
grep -q 'token_invalidated' "$CODEX_AUTH_LOG" \
  || fail "targeted auth refresh dropped the raw RPC error from the log: $(cat "$CODEX_AUTH_LOG")"
grep -q 'login needed: token invalidated' "$CODEX_AUTH_LOG" \
  || fail "targeted auth refresh did not log the short cause"
jq -e '.current == "alpha" and ([.accounts[] | select(.account == "beta")][0] |
  .auth_needed == true and .cause == "login needed: token invalidated" and (has("error") | not))' \
  "$CODEX_ACCOUNTS_CACHE" >/dev/null \
  || fail "targeted auth refresh did not persist the codex auth marker or leaked a raw error"
jq -e '.vendors.codex.available == true and .vendors.codex.current_account == "alpha" and
  ([.vendors.codex.accounts[] | select(.account == "beta")][0] |
    .auth_needed == true and .status == "login needed" and
    .cause == "login needed: token invalidated") and
  (.vendors.codex | has("refresh_error") | not)' <<<"$codex_target_auth" >/dev/null \
  || fail "targeted auth refresh did not surface login-needed without a vendor error"
[ -z "$(jq -r '.. | strings | select(test("token_invalidated|Unauthorized|rateLimits/read"))' <<<"$codex_target_auth")" ] \
  || fail "raw RPC blob leaked into the unified codex cache"

CODEX_LEGACY_CACHE="$WORK/codex-legacy.json"
cat >"$CODEX_LEGACY_CACHE" <<EOF
{"schema":1,"fetched_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","plan_type":"plus","five_hour":{"used_pct":31,"resets_at":$five_reset_epoch},"weekly":{"used_pct":64,"resets_at":$week_reset_epoch}}
EOF
codex_legacy=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_LEGACY_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex legacy cache collection failed"
jq -e '.vendors.codex.available == true and .vendors.codex.source == "codex-app-server" and
  .vendors.codex.plan_type == "plus" and .vendors.codex.current_account == "main" and
  .vendors.codex.five_hour.used_pct == 31 and .vendors.codex.weekly.used_pct == 64 and
  (.vendors.codex.accounts | length) == 1 and .vendors.codex.accounts[0].account == "main" and
  .vendors.codex.accounts[0].is_current == true and
  (.vendors.codex.accounts[0] | has("reset_credits") | not) and
  .vendors.codex.five_hour == .vendors.codex.accounts[0].five_hour and
  .vendors.codex.weekly == .vendors.codex.accounts[0].weekly' <<<"$codex_legacy" >/dev/null \
  || fail "Codex legacy cache compatibility mismatch"
# Rollout events newer than the cached RPC snapshot must win (fixture rollout is 2026-07-11T10:00Z).
touch -t 202607110500 "$CODEX_CACHE"
rollout_wins=$(LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "rollout-preference collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 74 and .vendors.codex.five_hour.origin == "headers" and .vendors.codex.source == "session-rollout"' <<<"$rollout_wins" >/dev/null \
  || fail "newer rollout event did not outrank an older quota cache"
rm -f "$CODEX_CACHE"

HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --start-windows >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "--start-windows without --refresh: expected exit 2, got $rc"

# --refresh --start-windows with a fresh codex 5h window: claudeb gets the window-start
# request (its help advertises the flag) and codex exec stays untouched.
rm -f "$SENTINEL" "$CODEX_SENTINEL" "$CODEX_QUOTA_SENTINEL"
CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows >/dev/null 2>"$WORK/start-fresh.err" || fail "start-windows (fresh) collection failed"
grep -qx -- '--refresh --start-windows --heal' "$SENTINEL" || fail "claudeb window start was not requested"
[ ! -e "$CODEX_SENTINEL" ] || fail "fresh codex window must not trigger a spend"
grep -q 'gemini window start skipped' "$WORK/start-fresh.err" || fail "disabled gemini start must be reported, not silent"

# Expired codex 5h window: one micro-spend via codex exec, then the quota is re-read.
cat >"$WORK/fake-codex-quota-expired" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>"\$CODEX_QUOTA_SENTINEL"
if [ -e "\$CODEX_QUOTA_STATE" ]; then
  printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":12,"resetsAt":$((now + 4000))},"secondary":{"usedPercent":34,"resetsAt":$((now + 90000))},"planType":"plus"}}'
else
  : >"\$CODEX_QUOTA_STATE"
  printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":99,"resetsAt":$((now - 60))},"secondary":{"usedPercent":34,"resetsAt":$((now + 90000))},"planType":"plus"}}'
fi
EOF
chmod +x "$WORK/fake-codex-quota-expired"
rm -f "$SENTINEL" "$CODEX_SENTINEL" "$CODEX_QUOTA_SENTINEL" "$CODEX_CACHE"
spend_out=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  CODEX_QUOTA_STATE="$WORK/codex-quota-state" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota-expired" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  LLM_LIMITS_CODEX_MODEL="fixture model" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows 2>/dev/null) || fail "start-windows (expired) collection failed"
[ -s "$CODEX_SENTINEL" ] || fail "expired codex window did not trigger the window-start spend"
grep -qx -- '--sandbox' "$CODEX_SENTINEL" && grep -qx 'read-only' "$CODEX_SENTINEL" || fail "codex window start did not use the read-only sandbox"
grep -qx 'model_reasoning_effort="low"' "$CODEX_SENTINEL" || fail "codex window start did not request low reasoning effort"
grep -qx -- '-m' "$CODEX_SENTINEL" || fail "codex model override flag was not passed"
grep -qx 'fixture model' "$CODEX_SENTINEL" || fail "codex model override was not passed as one argument"
[ "$(grep -c called "$CODEX_QUOTA_SENTINEL")" -eq 2 ] || fail "codex quota was not re-read after the window start"
jq -e '.vendors.codex.five_hour.used_pct == 12' <<<"$spend_out" >/dev/null || fail "post-spend codex snapshot was not picked up"
rm -f "$CODEX_CACHE" "$WORK/codex-quota-state"

# claudeb builds that predate --start-windows: explicit notice, free refresh fallback.
FAKE_BIN_OLD="$WORK/bin-old"
mkdir -p "$FAKE_BIN_OLD"
cat >"$FAKE_BIN_OLD/claudeb" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  echo "  claudeb --refresh [--no-spend]"
  exit 0
fi
printf '%s\n' "$*" >>"$CLAUDEB_SENTINEL"
EOF
cp "$FAKE_BIN/codex" "$FAKE_BIN_OLD/codex"
chmod +x "$FAKE_BIN_OLD/claudeb" "$FAKE_BIN_OLD/codex"
rm -f "$SENTINEL" "$CODEX_SENTINEL" "$CODEX_QUOTA_SENTINEL"
CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN_OLD:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows >/dev/null 2>"$WORK/start-old.err" || fail "start-windows (old claudeb) collection failed"
grep -q 'claudeb lacks --start-windows' "$WORK/start-old.err" || fail "unsupported claudeb flag was skipped silently"
grep -q 'accounts --no-spend' "$SENTINEL" || fail "old claudeb did not fall back to the free refresh"
grep -q -- '--refresh --start-windows' "$SENTINEL" && fail "unsupported flag was passed to old claudeb"
rm -f "$SENTINEL" "$CODEX_SENTINEL" "$CODEX_QUOTA_SENTINEL" "$CODEX_CACHE"

# Undeterminable codex freshness (fresh event, null resets_at) must neither crash the run
# under set -u nor trigger the window-start spend; the unknown state must be reported.
NULLRESET_HOME="$WORK/nullreset-codex-home"
mkdir -p "$NULLRESET_HOME/.codex/sessions"
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":41,"resets_at":null},"secondary":{"used_percent":22,"resets_at":null}}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$NULLRESET_HOME/.codex/sessions/rollout-nullreset.jsonl"
CODEX_SENTINEL="$CODEX_SENTINEL" LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/nonexistent-quota" \
  PATH="$FAKE_BIN:$PATH" HOME="$NULLRESET_HOME" CLAUDEB_DIR="$WORK/no-claudeb-store" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows >/dev/null 2>"$WORK/null.err"
rc=$?
# The run must not crash (e.g. an unset-variable abort), but a genuinely missing codex
# quota helper is a real refresh error and must exit non-zero, never a silent/clean 0.
[ "$rc" -eq 4 ] || fail "null resets_at refresh: expected exit 4 (codex refresh_error), got $rc"
[ ! -e "$CODEX_SENTINEL" ] || fail "unknown codex window state triggered a spend"
grep -q 'codex 5h window state unknown' "$WORK/null.err" || fail "unknown codex window state was skipped silently"
null_reset=$(HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "null resets_at collection failed"
jq -e '.vendors.codex.available == true and .vendors.codex.five_hour.used_pct == 41 and .vendors.codex.five_hour.resets_at == null' <<<"$null_reset" >/dev/null || fail "null resets_at not normalized"
HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain | grep -q 'codex: 5h 41% @ - | wk 22% @ -' || fail "null resets_at plain render failed"
HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table | grep -q '^codex' || fail "null resets_at table render failed"

PLACEHOLDER_HOME="$WORK/placeholder-home"
PLACEHOLDER_STORE="$WORK/placeholder-store"
mkdir -p "$PLACEHOLDER_HOME" "$PLACEHOLDER_STORE/limits"
printf 'zero\n' >"$PLACEHOLDER_STORE/.claudeb-state"
printf '%s\n' '{"five_hour":{"used_percentage":10,"resets_at":0}}' >"$PLACEHOLDER_STORE/limits/zero.json"
printf '%s\n' '{"five_hour":{"used_percentage":20,"resets_at":12345}}' >"$PLACEHOLDER_STORE/limits/epoch-1970.json"
printf '%s\n' '{"five_hour":{"used_percentage":30,"resets_at":""}}' >"$PLACEHOLDER_STORE/limits/empty.json"
printf '{"five_hour":{"used_percentage":40,"resets_at":%s}}\n' "$((now - 1800))" >"$PLACEHOLDER_STORE/limits/recent-past.json"
placeholder_json=$(HOME="$PLACEHOLDER_HOME" CLAUDEB_DIR="$PLACEHOLDER_STORE" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --json) || fail "placeholder reset collection failed"
jq -e 'all(.vendors.claude.accounts[] | select(.account == "zero" or .account == "epoch-1970" or .account == "empty");
    .five_hour.resets_at == null) and
  ([.vendors.claude.accounts[] | select(.account == "recent-past")][0].five_hour |
    (.resets_at | type) == "string" and .expired == true)' <<<"$placeholder_json" >/dev/null \
  || fail "placeholder or real past resets_at normalization mismatch"

# Gemini window start: an expired 5h bucket in the refreshed quota triggers one bounded
# agy --print call, then the quota helper runs again.
GEMINI_START_SENTINEL="$WORK/agy-called"
GEMINI_STATE="$WORK/gemini-quota-state"
GEMINI_CACHE2="$WORK/gemini-start.json"
FAKE_AGY="$WORK/fake-agy"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$GEMINI_START_SENTINEL"\n' >"$FAKE_AGY"
cat >"$WORK/fake-gemini-quota" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>"\$GEMINI_SENTINEL"
if [ -e "\$GEMINI_STATE" ]; then
  printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.6,"resetTime":"$(date -u -r $((now + 500000)) '+%Y-%m-%dT%H:%M:%SZ')"},{"window":"5h","remainingFraction":0.9,"resetTime":"$(date -u -r $((now + 7200)) '+%Y-%m-%dT%H:%M:%SZ')"}]}]}'
else
  : >"\$GEMINI_STATE"
  printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.75,"resetTime":"$(date -u -r $((now + 500000)) '+%Y-%m-%dT%H:%M:%SZ')"},{"window":"5h","remainingFraction":0.995,"resetTime":"2026-07-11T00:00:00Z"}]}]}'
fi
EOF
chmod +x "$FAKE_AGY" "$WORK/fake-gemini-quota"
rm -f "$GEMINI_SENTINEL"
gemini_start=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" GEMINI_STATE="$GEMINI_STATE" GEMINI_START_SENTINEL="$GEMINI_START_SENTINEL" \
  CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" \
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$WORK/fake-gemini-quota" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE2" \
  AGY_BIN="$FAKE_AGY" AGY_WORKDIR="$WORK" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows 2>/dev/null) || fail "gemini start-windows collection failed"
grep -q -- '--print' "$GEMINI_START_SENTINEL" || fail "expired gemini window did not trigger agy --print"
[ "$(grep -c called "$GEMINI_SENTINEL")" -eq 2 ] || fail "gemini quota was not re-read after the window start"
jq -e '.vendors.gemini.weekly.used_pct == 40' <<<"$gemini_start" >/dev/null || fail "post-start gemini snapshot was not picked up"
rm -f "$GEMINI_SENTINEL" "$GEMINI_START_SENTINEL" "$GEMINI_STATE" "$GEMINI_CACHE2"

table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "table collection failed"
grep -q $'\x1b' <<<"$table" && fail "piped table output contains ANSI escapes"
head -n 1 <<<"$table" | grep -q '^SOURCE ' || fail "table header missing"
grep -q '^claude/main' <<<"$table" && fail "main account must be hidden from the table"
jq -e 'all(.vendors.claude.accounts[]; .account != "main")' <<<"$multi" >/dev/null || fail "duplicate main account remained in JSON"
[ "$(grep -c '^claude/' <<<"$table")" -eq 1 ] || fail "table must render one row per non-main claude account"
order=$(awk 'NR > 1 {print $1}' <<<"$table" | paste -sd, -)
[ "$order" = "claude/alona*,codex,gemini" ] || fail "default table order mismatch: $order"
head -n 1 <<<"$table" | grep -q 'FB%' || fail "Fable percentage column missing from table"
head -n 1 <<<"$table" | grep -q 'FB RESET' || fail "Fable reset column missing from table"
head -n 1 <<<"$table" | grep -q 'NOTE' && fail "NOTE column still present"
awk '$1 == "claude/alona*" {print $4}' <<<"$table" | grep -qx '33%' || fail "Fable percentage cell missing"
awk '$1 == "codex" {print $4}' <<<"$table" | grep -qx '-' || fail "non-Fable row must render a dash"
grep -q 'Gemini Models\|plus' <<<"$table" && fail "junk labels leaked into table"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now - 1))" >"$CLAUDEB/limits/alona.json"
expired_fable=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "expired fable table failed"
awk '$1 == "claude/alona*" {print $4}' <<<"$expired_fable" | grep -qx '33%!' \
  || fail "expired fable must keep its raw value with an explicit marker"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now + 5500))" >"$CLAUDEB/limits/alona.json"
awk 'NR > 1 && $1 == "codex"' <<<"$table" | grep -Eq '[0-9]{2}:[0-9]{2}' || fail "codex reset time not rendered"
sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$sorted" | paste -sd, -)
[ "$order" = "codex,claude/alona*,gemini" ] || fail "--sort 5h order mismatch: $order"
# zoe: distant 5h reset but imminent weekly reset — --sort reset must use min(5h, weekly).
printf '{"five_hour":{"used_percentage":11,"resets_at":%s},"seven_day":{"used_percentage":97,"resets_at":%s}}\n' "$((now + 50000))" "$((now + 500))" >"$CLAUDEB/limits/zoe.json"
reset_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort reset) || fail "reset-sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$reset_sorted" | paste -sd, -)
[ "$order" = "claude/zoe,codex,claude/alona*,gemini" ] || fail "--sort reset min(5h, weekly) order mismatch: $order"
rm "$CLAUDEB/limits/zoe.json"
SORT_RESET_STORE="$WORK/sort-reset-store"
EMPTY_SORT_HOME="$WORK/sort-reset-home"
mkdir -p "$SORT_RESET_STORE/limits" "$EMPTY_SORT_HOME"
printf 'future-a\n' >"$SORT_RESET_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$((now + 1000))" >"$SORT_RESET_STORE/limits/future-a.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"fable":{"used_percentage":40,"resets_at":%s}}\n' \
  "$((now + 2000))" "$((now + 500))" >"$SORT_RESET_STORE/limits/future-b.json"
printf '{"five_hour":{"used_percentage":30,"resets_at":%s}}\n' "$((now - 18000))" >"$SORT_RESET_STORE/limits/expired.json"
reset_expired=$(HOME="$EMPTY_SORT_HOME" CLAUDEB_DIR="$SORT_RESET_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort reset) || fail "expired reset-sort collection failed"
order=$(awk 'NR > 1 && $1 ~ /^claude\// {print $1}' <<<"$reset_expired" | paste -sd, -)
[ "$order" = "claude/future-b,claude/future-a*,claude/expired" ] \
  || fail "--sort reset must include Fable and place expired windows last: $order"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort bogus >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "unknown --sort value: expected exit 2, got $rc"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort= >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "empty --sort=: expected exit 2, got $rc"
bare=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "bare piped collection failed"
jq -e '.schema == 1 and (.vendors | keys == ["claude","codex","gemini"])' <<<"$bare" >/dev/null || fail "piped bare invocation must emit schema-1 JSON"

sleep 1
TRUNCATED="$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-truncated.jsonl"
printf '{"padding":"%0700d"}\n' 0 >"$TRUNCATED"
printf '{"timestamp":"2026-07-11T12:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":88,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":%s},"plan_type":"plus"}}}\n' "$((now + 3000))" "$((now + 4000))" >>"$TRUNCATED"
truncated=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_CHUNK_BYTES=512 bash "$SCRIPT" --json) || fail "truncated-chunk collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 88 and .vendors.codex.weekly.used_pct == 44' <<<"$truncated" >/dev/null || fail "valid event after truncated boundary was lost"

CROSS_HOME="$WORK/cross-home"
mkdir -p "$CROSS_HOME/.codex/sessions"
printf '{"timestamp":"2026-07-12T03:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":37,"resets_at":%s},"secondary":{"used_percent":23,"resets_at":%s}}}}\n' "$((now + 5000))" "$((now + 9000))" >"$CROSS_HOME/.codex/sessions/rollout-numeric.jsonl"
printf '%s\n' '{"timestamp":"2026-07-12T04:00:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":{"used_percent":99}}}}' >"$CROSS_HOME/.codex/sessions/rollout-null.jsonl"
touch -t 202607120100 "$CROSS_HOME/.codex/sessions/rollout-numeric.jsonl"
touch -t 202607120200 "$CROSS_HOME/.codex/sessions/rollout-null.jsonl"
cross_null=$(HOME="$CROSS_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "cross-file null-primary collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 37 and .vendors.codex.weekly.used_pct == 23' <<<"$cross_null" >/dev/null || fail "null-primary file hid a valid cross-file event"

printf '{"timestamp":"2026-07-12T02:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":61,"resets_at":%s},"secondary":{"used_percent":41,"resets_at":%s}}}}\n' "$((now + 6000))" "$((now + 10000))" >"$CROSS_HOME/.codex/sessions/rollout-mtime-newest.jsonl"
printf '{"timestamp":"2026-07-12T08:00:00+03:00","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":17,"resets_at":%s},"secondary":{"used_percent":11,"resets_at":%s}}}}\n' "$((now + 7000))" "$((now + 11000))" >"$CROSS_HOME/.codex/sessions/rollout-timestamp-latest.jsonl"
touch -t 202607120400 "$CROSS_HOME/.codex/sessions/rollout-timestamp-latest.jsonl"
touch -t 202607120500 "$CROSS_HOME/.codex/sessions/rollout-mtime-newest.jsonl"
cross_latest=$(HOME="$CROSS_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "cross-file timestamp collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 17 and .vendors.codex.weekly.used_pct == 11' <<<"$cross_latest" >/dev/null || fail "mtime order outranked the latest event timestamp"

# Passive snapshot whose 5h reset already passed: flagged expired, table keeps the last
# known value and reset time (dimmed only on a TTY, so piped output stays escape-free),
# sort treats the stale 100% as 0. The fresh weekly window stays unflagged.
sleep 1
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":%s},"plan_type":"plus"}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((now - 600))" "$((now + 4000))" \
  >"$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-expired.jsonl"
expired_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "expired-window collection failed"
jq -e '.vendors.codex.five_hour.expired == true and .vendors.codex.five_hour.used_pct == 100 and
  .vendors.codex.five_hour.effective_pct == 0 and .vendors.codex.usable_now == true and
  (.vendors.codex.weekly | has("expired") | not) and
  (.vendors.claude.accounts[0].five_hour | has("expired") | not)' <<<"$expired_json" >/dev/null || fail "expired flag mismatch"
expired_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "expired table collection failed"
codex_row=$(awk 'NR > 1 && $1 == "codex"' <<<"$expired_table")
# The kept reset time may carry a weekday prefix: an expired window lies in the past, so
# around midnight it renders as yesterday.
grep -Eq '^codex +100%! +44% +- +([A-Za-z]{3} )?[0-9]{2}:[0-9]{2}' <<<"$codex_row" || fail "expired window must keep its last known value and reset time: $codex_row"
expired_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "expired plain collection failed"
grep -q 'codex: 5h 100%! @ .* | wk 44% @ ' <<<"$expired_plain" || fail "expired plain output must keep the raw value with a marker"
expired_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "expired sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$expired_sorted" | paste -sd, -)
[ "$order" = "claude/alona*,codex,gemini" ] || fail "expired 5h sort must rank the stale 100% as 0: $order"

HONEST_STORE="$WORK/honest-store"
HONEST_HOME="$WORK/honest-home"
mkdir -p "$HONEST_STORE/limits" "$HONEST_HOME"
printf 'honest\n' >"$HONEST_STORE/.claudeb-state"
# as_of is relative to a fresh capture, not the script-start `now`: the displayed age is
# (collect time - as_of), so a script-start base would silently add all elapsed test seconds
# and drift 1h1m -> 1h2m as the suite grows.
honest_now=$(date +%s)
printf '{"five_hour":{"used_percentage":100,"resets_at":%s,"as_of":%s,"origin":"usage"},"seven_day":{"used_percentage":44,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' \
  "$((honest_now + 5000))" "$((honest_now - 3660))" "$((honest_now - 60))" "$((honest_now - 120))" >"$HONEST_STORE/limits/honest.json"
honest_table=$(HOME="$HONEST_HOME" CLAUDEB_DIR="$HONEST_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) \
  || fail "honesty table fixture failed"
honest_plain=$(HOME="$HONEST_HOME" CLAUDEB_DIR="$HONEST_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) \
  || fail "honesty plain fixture failed"
head -n 1 <<<"$honest_table" | grep -Eq 'FB RESET +AGE +ROT +CR +STATUS' || fail "table universal state columns missing"
head -n 1 <<<"$honest_table" | grep -q 'NOTE' && fail "table NOTE column was not abolished"
honest_row=$(awk '$1 == "claude/honest*"' <<<"$honest_table")
grep -Eq '^claude/honest\* +100%~ +44%! ' <<<"$honest_row" || fail "honesty table rewrote raw used_pct or lost markers"
grep -Eq ' +1h1m +- +- +-$' <<<"$honest_row" || fail "table age or explicit state fields missing: $honest_row"
grep -q 'claude/honest\*: 5h 100%~ @ .* | wk 44%! @ ' <<<"$honest_plain" || fail "honesty plain rewrote raw used_pct or lost markers"
grep 'claude/honest\*:' <<<"$honest_plain" | grep -q '| age 1h1m | rot - | cr - | status -' \
  || fail "plain age or explicit state fields missing"

USABLE_STORE="$WORK/usable-store"
USABLE_HOME="$WORK/usable-home"
mkdir -p "$USABLE_STORE/limits" "$USABLE_HOME/.codex/sessions"
printf 'full\n' >"$USABLE_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":100,"resets_at":%s},"seven_day":{"used_percentage":100,"resets_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" >"$USABLE_STORE/limits/full.json"
claude_full=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude exhausted usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_full" >/dev/null || fail "Claude all-exhausted usability mismatch"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" >"$USABLE_STORE/limits/free.json"
claude_free=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude free-account usability collection failed"
jq -e '.vendors.claude.usable_now == true' <<<"$claude_free" >/dev/null || fail "Claude one-free-account usability mismatch"
printf 'free\n' >"$USABLE_STORE/disabled"
claude_disabled=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude disabled-account usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_disabled" >/dev/null || fail "Disabled under-limit account must not make Claude usable"
rm "$USABLE_STORE/disabled"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"auth":{"status":"expired"}}\n' \
  "$((now + 5000))" "$((now + 9000))" >"$USABLE_STORE/limits/free.json"
claude_expired_auth=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude expired-auth usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_expired_auth" >/dev/null || fail "Expired-auth under-limit account must not make Claude usable"
rm "$USABLE_STORE/limits/free.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"fable":{"used_percentage":100,"resets_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" "$((now + 6000))" >"$USABLE_STORE/limits/full.json"
claude_fable=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude fable usability collection failed"
jq -e '.vendors.claude.fable.effective_pct == 100 and .vendors.claude.usable_now == true' <<<"$claude_fable" >/dev/null || fail "Fable exhaustion must not block general Claude work"

printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"resets_at":%s},"secondary":{"used_percent":40,"resets_at":%s}}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((now + 5000))" "$((now + 9000))" >"$USABLE_HOME/.codex/sessions/rollout-full.jsonl"
codex_full=$(HOME="$USABLE_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex exhausted usability collection failed"
jq -e '.vendors.codex.five_hour.effective_pct == 100 and .vendors.codex.usable_now == false' <<<"$codex_full" >/dev/null || fail "Codex exhausted usability mismatch"

FORMAT_STORE="$WORK/reset-format-store"
FORMAT_HOME="$WORK/reset-format-home"
mkdir -p "$FORMAT_STORE/limits" "$FORMAT_STORE/tokens" "$FORMAT_HOME"
printf 'clock\n' >"$FORMAT_STORE/.claudeb-state"
clock_epoch=$(( $(date +%s) + 3600 ))
weekday_epoch=$(( clock_epoch + 172800 ))
date_epoch=$(( clock_epoch + 691200 ))
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$clock_epoch" >"$FORMAT_STORE/limits/clock.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s}}\n' "$weekday_epoch" >"$FORMAT_STORE/limits/weekday.json"
printf '{"five_hour":{"used_percentage":30,"resets_at":%s}}\n' "$date_epoch" >"$FORMAT_STORE/limits/date.json"
touch "$FORMAT_STORE/tokens/clock" "$FORMAT_STORE/tokens/weekday" "$FORMAT_STORE/tokens/date"
clock_text=$(date -r "$clock_epoch" '+%H:%M')
weekday_num=$(date -r "$weekday_epoch" '+%w')
weekdays=(Sun Mon Tue Wed Thu Fri Sat)
weekday_text="${weekdays[$weekday_num]} $(date -r "$weekday_epoch" '+%H:%M')"
date_text=$(date -r "$date_epoch" '+%m-%d %H:%M')
format_table=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "reset-format table fixture failed"
format_plain=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "reset-format plain fixture failed"
claudeb_plain=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" bash "$ROOT/bin/claudeb" status --cached --plain) || fail "claudeb reset-format fixture failed"
for rendered in "$clock_text" "$weekday_text" "$date_text"; do
  grep -Fq "$rendered" <<<"$format_table" || fail "table reset tier missing: $rendered"
  grep -Fq "$rendered" <<<"$format_plain" || fail "plain reset tier missing: $rendered"
  grep -Fq "$rendered" <<<"$claudeb_plain" || fail "claudeb reset tier missing: $rendered"
done

XMID_STORE="$WORK/xmid-store"
XMID_HOME="$WORK/xmid-home"
mkdir -p "$XMID_STORE/limits" "$XMID_STORE/tokens" "$XMID_HOME"
printf 'sameday\n' >"$XMID_STORE/.claudeb-state"
pinned_now=$(date -j -f '%Y-%m-%d %H:%M:%S' '2027-01-15 12:00:00' '+%s')
sameday_epoch=$(( pinned_now + 14400 ))
crossmid_epoch=$(( pinned_now + 72000 ))
farweek_epoch=$(( pinned_now + 259200 ))
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$sameday_epoch" >"$XMID_STORE/limits/sameday.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s}}\n' "$crossmid_epoch" >"$XMID_STORE/limits/crossmid.json"
printf '{"five_hour":{"used_percentage":30,"resets_at":%s}}\n' "$farweek_epoch" >"$XMID_STORE/limits/farweek.json"
touch "$XMID_STORE/tokens/sameday" "$XMID_STORE/tokens/crossmid" "$XMID_STORE/tokens/farweek"
sameday_bare=$(date -r "$sameday_epoch" '+%H:%M')
sameday_daytext="${weekdays[$(date -r "$sameday_epoch" '+%w')]} $sameday_bare"
crossmid_text="${weekdays[$(date -r "$crossmid_epoch" '+%w')]} $(date -r "$crossmid_epoch" '+%H:%M')"
farweek_text="${weekdays[$(date -r "$farweek_epoch" '+%w')]} $(date -r "$farweek_epoch" '+%H:%M')"
xmid_table=$(HOME="$XMID_HOME" CLAUDEB_DIR="$XMID_STORE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_NOW="$pinned_now" bash "$SCRIPT" --table) || fail "cross-midnight table fixture failed"
xmid_plain=$(HOME="$XMID_HOME" CLAUDEB_DIR="$XMID_STORE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_NOW="$pinned_now" bash "$SCRIPT" --plain) || fail "cross-midnight plain fixture failed"
xmid_claudeb=$(HOME="$XMID_HOME" CLAUDEB_DIR="$XMID_STORE" CLAUDEB_NOW="$pinned_now" bash "$ROOT/bin/claudeb" status --cached --plain) || fail "cross-midnight claudeb fixture failed"
for surface_name in table plain claudeb; do
  case "$surface_name" in
    table) surface="$xmid_table" ;;
    plain) surface="$xmid_plain" ;;
    claudeb) surface="$xmid_claudeb" ;;
  esac
  grep -Fq "$crossmid_text" <<<"$surface" || fail "$surface_name: within-24h cross-midnight reset lacks the day marker ($crossmid_text)"
  grep -Fq "$sameday_bare" <<<"$surface" || fail "$surface_name: same-day reset lost its bare clock time ($sameday_bare)"
  grep -Fq "$sameday_daytext" <<<"$surface" && fail "$surface_name: same-day reset wrongly gained a day marker ($sameday_daytext)"
  grep -Fq "$farweek_text" <<<"$surface" || fail "$surface_name: >24h reset tier changed ($farweek_text)"
done

# Header-origin week must render unknown, not as a number that walls the account.
PROV_STORE="$WORK/prov-store"
mkdir -p "$PROV_STORE/limits" "$PROV_STORE/tokens"
printf 'prov\n' >"$PROV_STORE/.claudeb-state"
: >"$PROV_STORE/tokens/prov"
printf '{"five_hour":{"used_percentage":5,"resets_at":%s,"as_of":%s,"origin":"headers"},"seven_day":{"used_percentage":100,"resets_at":%s,"as_of":%s,"origin":"headers"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$((now + 300000))" "$now" "$now" >"$PROV_STORE/limits/prov.json"
prov_json=$(CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null) \
  || fail "header-origin weekly fixture failed"
jq -e '.vendors.claude.accounts[0] | (.weekly == null) and .five_hour.used_pct == 5' <<<"$prov_json" >/dev/null \
  || fail "a header-origin weekly bucket was reported instead of being dropped"
printf '{"five_hour":{"used_percentage":5,"resets_at":%s,"as_of":%s,"origin":"headers"},"seven_day":{"used_percentage":76,"resets_at":%s,"as_of":%s,"origin":"session"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$((now + 300000))" "$now" "$now" >"$PROV_STORE/limits/prov.json"
prov_measured=$(CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null) \
  || fail "session-origin weekly fixture failed"
jq -e '.vendors.claude.accounts[0].weekly.used_pct == 76' <<<"$prov_measured" >/dev/null \
  || fail "a measured weekly reading was dropped"

EXP_REG="$WORK/experiments.json"
EXP_MARKER="$WORK/experiment-marker"
printf '{"until":9999999999,"reason":"fixture"}\n' >"$EXP_MARKER"
printf '[{"id":"trial-x","what":"fixture experiment for the banner contract","started":"2026-01-01","review_by":"2999-01-01","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
exp_json=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null) \
  || fail "experiment-registry fixture failed"
jq -e '.experiments == ["EXPERIMENT trial-x until 2999-01-01 — temporary, see EXPERIMENTS.json"]' <<<"$exp_json" >/dev/null \
  || fail "an active experiment is missing from the collector output"
exp_table=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --table --no-write 2>/dev/null)
grep -Fq 'EXPERIMENT trial-x until 2999-01-01' <<<"$exp_table" || fail "--table did not announce the active experiment"
printf '[{"id":"spent","what":"fixture experiment whose review date has passed","started":"2026-01-01","review_by":"2026-01-02","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
exp_past=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.experiments == ["EXPERIMENT spent OVERDUE since 2026-01-02 — decide: remove or extend (EXPERIMENTS.json)"]' <<<"$exp_past" >/dev/null \
  || fail "an overdue-but-live experiment is not announced as OVERDUE"

printf '[{"id":"broken",,}]\n' >"$EXP_REG"
exp_broken=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.experiments | length == 1 and (.[0] | startswith("EXPERIMENT registry unreadable"))' <<<"$exp_broken" >/dev/null \
  || fail "an unreadable experiment registry was silently reported as no experiments"

printf '[{"id":"trial-x","what":"fixture experiment for the banner contract","started":"2026-01-01","review_by":"2999-01-01","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
for spent_until in -1 1.5; do
  printf '{"until":%s,"reason":"fixture"}\n' "$spent_until" >"$EXP_MARKER"
  exp_numeric=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
  jq -e '.experiments == []' <<<"$exp_numeric" >/dev/null \
    || fail "a marker with until=$spent_until is spent but still announced"
done

printf '{"until":1,"reason":"fixture"}\n' >"$EXP_MARKER"
printf '[{"id":"resumed","what":"fixture experiment whose marker has expired","started":"2026-01-01","review_by":"2999-01-01","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
exp_spent_marker=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.experiments == []' <<<"$exp_spent_marker" >/dev/null || fail "an expired marker is still being announced"

EMPTY="$WORK/empty-home"
mkdir -p "$EMPTY"
HOME="$EMPTY" bash "$SCRIPT" --no-write >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] || fail "all-missing case: expected exit 3, got $rc"
missing_json=$(HOME="$EMPTY" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.refresh_error.cause == "no vendor data available" and
  (.refresh_error.at | type) == "number"' <<<"$missing_json" >/dev/null \
  || fail "all-missing case lacked a structured global error"

hs_bounded() {
  python3 - "$@" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(["hs", *sys.argv[1:]], capture_output=True, text=True, timeout=3)
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
PY
}

if command -v hs >/dev/null 2>&1 && [ "$(hs_bounded -c 'return "ok"' 2>/dev/null)" = ok ]; then
  renderer_output=$(hs_bounded -c "return dofile([[$ROOT/tests/llm_limits_renderer_harness.lua]])" 2>/dev/null) \
    || fail "Hammerspoon renderer contract checks threw"
  [ "$renderer_output" = "PASS: Hammerspoon projection contract" ] \
    || fail "Hammerspoon renderer contract checks: $renderer_output"
else
  echo "SKIP (hs unavailable): Hammerspoon projection contract"
fi

echo "PASS: schema, Claude unique accounts and fallback, Codex multi-account reset credits, auth-needed accounts and legacy cache, Claude daemon status and rotation passthrough, enabled flags, freshness contract, reset placeholder normalization, machine effective percentages and usability, refresh failure reasons, zero-spend refresh, start-windows, small-file fallback, truncated boundary, walls, weekly bucket provenance, experiment announcements, Hammerspoon projection contract, plain output, table output and sorts, reset tiers, expired windows, bare JSON default, atomic cache, missing exit 3"
exit 0
