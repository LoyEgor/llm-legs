#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/llm-limits.sh"
WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
strip_ansi() { sed $'s/\033\[[0-9;]*m//g'; }
unset CLICOLOR_FORCE
# Unit fixtures must never discover and launch the developer's real agy binary.
export LLM_LIMITS_GEMINI_REFRESH=0
export LLM_LIMITS_CODEX_REFRESH=0
export LLM_LIMITS_GROK_REFRESH=0
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
jq -e '.schema == 1 and (.vendors | keys == ["claude","codex","gemini","grok","opencode"])' <<<"$out" >/dev/null || fail "schema mismatch"
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
# Both windows are stated ahead of now rather than on fixed dates: a reset the clock has carried
# more than a day past is dropped by the collector, so a frozen date would stop being a reset to
# pass through at all and this would assert the drop instead of the normalization it is here for.
GEMINI_FIVE_RESET=$(date -u -r "$((now + 43200))" +%Y-%m-%dT%H:%M:%SZ)
GEMINI_WEEK_RESET=$(date -u -r "$((now + 604800))" +%Y-%m-%dT%H:%M:%SZ)
export GEMINI_FIVE_RESET GEMINI_WEEK_RESET
cat >"$GEMINI_HELPER" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GEMINI_SENTINEL"
printf '{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.75,"resetTime":"%s"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.995,"resetTime":"%s"}]}]}\n' \
  "$GEMINI_WEEK_RESET" "$GEMINI_FIVE_RESET"
EOF
chmod +x "$GEMINI_HELPER"
gemini_live=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh) \
  || fail "Gemini refresh collection failed"
jq -e --arg five_reset "$GEMINI_FIVE_RESET" \
  '.vendors.gemini.available == true and .vendors.gemini.source == "agy-local-rpc" and
  .vendors.gemini.five_hour.used_pct == 1 and
  .vendors.gemini.weekly.used_pct == 25 and
  .vendors.gemini.five_hour.resets_at == $five_reset and
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
   (.vendors.gemini.refresh_error | has("needs_user_entry") | not) and
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
  .vendors.gemini.needs_user_entry == true and
  .vendors.gemini.refresh_error.cause == "login needed (not signed in)" and
  .vendors.gemini.refresh_error.needs_user_entry == true and
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
  .vendors.gemini.needs_user_entry == true and
  .vendors.gemini.refresh_error.cause == "login needed (not signed in)" and
  .vendors.gemini.refresh_error.needs_user_entry == true' <<<"$gemini_auth_passive" >/dev/null \
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

# `--gemini-remove` is the menubar's spelling of `geminib remove main`, and the two share ONE
# marker file. So it means what geminib means by it: main leaves the roster entirely — no row at
# all, not even a removed one — and deleting the marker is the whole undo. A self-clear on valid
# creds would undo a deliberate removal on the very next collect, so main never gets one.
GEMINI_MARKER="$GEMINI_CACHE.removed"
gemini_shared_marker=$(gemini_base_home="$HOME_FIXTURE" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  /bin/bash -c '. "'"$ROOT"'/share/gemini-accounts.sh" && gemini_removal_marker main')
[ "$gemini_shared_marker" = "$GEMINI_MARKER" ] \
  || fail "geminib and llm-limits.sh name different removal markers for gemini main: $gemini_shared_marker vs $GEMINI_MARKER"
LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_AUTH_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json >/dev/null
gemini_removed=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --gemini-remove --json) || true
jq -e '.vendors.gemini.available == false and
  ([.vendors.gemini.accounts[]? | select(.account == "main")] | length) == 0 and
  (.vendors.gemini | has("refresh_error") | not)' \
  <<<"$gemini_removed" >/dev/null \
  || fail "gemini-remove did not take main out of its own run, or left a stale login-needed cause behind"
[ -e "$GEMINI_MARKER" ] || fail "gemini-remove did not persist the removed marker"
gemini_still=$(LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --json) || true
jq -e '([.vendors.gemini.accounts[]? | select(.account == "main")] | length) == 0 and
  .vendors.gemini.available == false' <<<"$gemini_still" >/dev/null \
  || fail "removed gemini main came back on a passive collect"
[ -e "$GEMINI_MARKER" ] || fail "passive collect cleared the marker"
gemini_valid_creds=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json) || true
jq -e '([.vendors.gemini.accounts[]? | select(.account == "main")] | length) == 0' \
  <<<"$gemini_valid_creds" >/dev/null \
  || fail "valid gemini creds resurrected a main its owner removed on purpose"
[ -e "$GEMINI_MARKER" ] || fail "valid gemini creds cleared a deliberate removal marker"
rm -f "$GEMINI_MARKER"
gemini_healed=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json)
jq -e '.vendors.gemini.available == true and (.vendors.gemini | has("removed") | not) and
  .vendors.gemini.weekly.used_pct == 25' <<<"$gemini_healed" >/dev/null \
  || fail "deleting the marker did not bring gemini main back"
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
GEMINI_SECURITY_STUB="$WORK/fake-security"
cat >"$GEMINI_SECURITY_STUB" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != create-keychain ] || printf '%s' "$3" >"$4"
EOF
chmod +x "$GEMINI_MULTI_HELPER" "$GEMINI_MULTI_AUTH_HELPER" "$GEMINI_SECURITY_STUB"
multi_gemini=$(GEMINI_MULTI_LOG="$GEMINI_MULTI_LOG" GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MULTI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  GEMINIB_SECURITY_CMD="$GEMINI_SECURITY_STUB" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/work --json) \
  || fail "targeted Gemini profile refresh failed"
[ "$(cat "$GEMINI_MULTI_LOG")" = "$GEMINI_PROFILES/work" ] \
  || fail "targeted Gemini profile refresh used the wrong HOME"
[ -f "$GEMINI_PROFILES/work/Library/Keychains/login.keychain-db" ] \
  || fail "Gemini profile refresh left the profile HOME without a keychain (macOS blocks the probe with a modal dialog)"
[ ! -e "$HOME_FIXTURE/Library/Keychains/login.keychain-db" ] \
  || fail "Gemini profile refresh reached into the base home keychain"
jq -e '.vendors.gemini.available == true and .vendors.gemini.current_account == "main" and
  (.vendors.gemini.accounts | length) == 2 and
  .vendors.gemini.weekly.used_pct == 50 and
  .vendors.gemini.five_hour.used_pct == 40 and
  [.vendors.gemini.accounts[] | select(.account == "main")][0].weekly.used_pct == 25 and
  [.vendors.gemini.accounts[] | select(.account == "work")][0].weekly.used_pct == 50' \
  <<<"$multi_gemini" >/dev/null || fail "Gemini profile snapshots were not isolated or selected-account buckets were not hoisted"
[ -s "$GEMINI_ACCOUNTS_CACHE/work.json" ] || fail "Gemini profile cache was not created"
# macOS grows `Library/` under any HOME a process is pointed at; a directory in the profiles root
# that geminib could not have named is not an account, gets no probe and no keychain.
mkdir -p "$GEMINI_PROFILES/Library/Keychains"
: >"$GEMINI_MULTI_LOG"
stray_gemini=$(GEMINI_MULTI_LOG="$GEMINI_MULTI_LOG" GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MULTI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  GEMINIB_SECURITY_CMD="$GEMINI_SECURITY_STUB" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json) \
  || fail "vendor-wide Gemini refresh with a stray directory failed"
jq -e '[.vendors.gemini.accounts[].account] | index("Library") == null' <<<"$stray_gemini" >/dev/null \
  || fail "a stray Library directory became a Gemini account: $(jq -c '[.vendors.gemini.accounts[].account]' <<<"$stray_gemini")"
grep -q "$GEMINI_PROFILES/Library" "$GEMINI_MULTI_LOG" && fail "a stray Library directory was probed as a profile HOME"
[ ! -e "$GEMINI_PROFILES/Library/.keychain-password" ] || fail "a keychain was built for the stray directory"
[ ! -e "$GEMINI_PROFILES/.keychain-password" ] || fail "a keychain was built in the profiles root"
rm -rf "$GEMINI_PROFILES/Library"

# One failing gemini account named `main` is reported as a bare cause with no `main: ` prefix, so
# the vendor entry it becomes carries no account while the account row carries the same text. Both
# describe one failure, and the legacy cause joins whatever survives, so only one may.
GEMINI_MAIN_FAIL_HELPER="$WORK/fake-agy-main-fails"
cat >"$GEMINI_MAIN_FAIL_HELPER" <<EOF
#!/usr/bin/env bash
[ "\$HOME" != "$HOME_FIXTURE" ] || exit 1
printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.5,"resetTime":"2099-01-01T00:00:00Z"},{"window":"5h","remainingFraction":0.6,"resetTime":"2099-01-01T00:00:00Z"}]}]}'
EOF
chmod +x "$GEMINI_MAIN_FAIL_HELPER"
main_fail=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MAIN_FAIL_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  GEMINIB_SECURITY_CMD="$GEMINI_SECURITY_STUB" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json) \
  || fail "vendor-wide Gemini refresh with a failing main exited nonzero"
jq -e '(.vendors.gemini.refresh_errors | length) == 1 and
  .vendors.gemini.refresh_error.cause == .vendors.gemini.refresh_errors[0].cause' \
  <<<"$main_fail" >/dev/null \
  || fail "one failing Gemini main was reported twice: $(jq -c '.vendors.gemini | {refresh_error,refresh_errors}' <<<"$main_fail")"

# Worker-pool membership is the user's own "don't burn this one", and the collector is where
# every consumer reads it from — a hardcoded enabled:true would make the toggle decorative.
mkdir -p "$GEMINI_PROFILES/.geminib"
printf 'work\n' >"$GEMINI_PROFILES/.geminib/disabled"
pool_gemini=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --json) \
  || fail "collect with a Gemini pool exclusion failed"
jq -e '([.vendors.gemini.accounts[] | select(.account == "work")][0].enabled == false) and
  ([.vendors.gemini.accounts[] | select(.account == "main")][0].enabled == true)' \
  <<<"$pool_gemini" >/dev/null || fail "Gemini worker-pool exclusion did not reach the snapshot"
pool_table=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --plain) \
  || fail "plain render with a Gemini pool exclusion failed"
grep -q 'gemini/work.*rot off' <<<"$pool_table" \
  || fail "the table hid the Gemini pool exclusion"
rm -f "$GEMINI_PROFILES/.geminib/disabled"

# With no named profiles the vendor collapses to its one account and the hoist drops the
# account-identity keys; `enabled` must survive that collapse, or the exclusion is invisible to
# every consumer that reads the vendor object rather than the accounts array.
SOLO_PROFILES="$WORK/gemini-solo-profiles"
mkdir -p "$SOLO_PROFILES/.geminib"
printf 'main\n' >"$SOLO_PROFILES/.geminib/disabled"
solo_gemini=$(GEMINIB_PROFILES_DIR="$SOLO_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --json) \
  || fail "single-account Gemini collect with a pool exclusion failed"
# One account means the legacy shape with no accounts array at all, which is exactly why the
# hoist must keep `enabled`: worker-pick's fallback for that shape reads it off the vendor.
jq -e '(.vendors.gemini | has("accounts") | not) and .vendors.gemini.enabled == false' \
  <<<"$solo_gemini" >/dev/null \
  || fail "single-account Gemini lost its worker-pool exclusion in the vendor hoist"
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
  .needs_user_entry == true and .refresh_error.needs_user_entry == true and
  .refresh_error.cause == "login needed (profile signed out)" and
  .weekly.used_pct == 50' <<<"$multi_auth" >/dev/null \
  || fail "Gemini profile login-needed state lost its cache or cause"
multi_main_recovered=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/main --json)
jq -e '.vendors.gemini.refresh_error.cause == "work: login needed (profile signed out)" and
  .vendors.gemini.refresh_error.needs_user_entry == true and
  ([.vendors.gemini.accounts[] | select(.account == "work")][0] |
   .auth_needed == true and .status == "login needed" and .needs_user_entry == true and
   .refresh_error.cause == "login needed (profile signed out)")' \
  <<<"$multi_main_recovered" >/dev/null \
  || fail "targeted Gemini refresh dropped an untouched profile status or refresh_error"
multi_all_auth=$(GEMINIB_PROFILES_DIR="$GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_ACCOUNTS_CACHE" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_MULTI_AUTH_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh-account gemini/main --json)
jq -e '.vendors.gemini.available == false and .vendors.gemini.auth_needed == true and
  ([.vendors.gemini.accounts[] | select(.auth_needed == true and .needs_user_entry == true and
    .refresh_error.needs_user_entry == true)] | length) == 2' \
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
  ([.vendors.gemini.accounts[] | select(.account == "empty")] | length) == 0 and
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

# `geminib remove main` writes its marker beside main's legacy cache file — the one path the
# menubar's `--gemini-remove` writes too. The base profile then leaves the store entirely — no row
# at all, not even a removed one — and what is left carries the vendor: current_account is the
# first enabled account in the account order, and the hoisted windows come from the account that
# spends least.
GEMINI_NO_MAIN_PROFILES="$WORK/gemini-no-main-profiles"
GEMINI_NO_MAIN_CACHE="$WORK/gemini-no-main-cache"
GEMINI_NO_MAIN_STORE="$WORK/gemini-no-main-store.json"
mkdir -p "$GEMINI_NO_MAIN_PROFILES/com" "$GEMINI_NO_MAIN_PROFILES/work" "$GEMINI_NO_MAIN_CACHE"
gemini_account_snapshot() {
  printf '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":%s,"resetTime":"2099-01-01T00:00:00Z"},{"window":"weekly","remainingFraction":%s,"resetTime":"2099-01-02T00:00:00Z"}]}]}\n' \
    "$2" "$3" >"$GEMINI_NO_MAIN_CACHE/$1.json"
}
gemini_account_snapshot com 0.7 0.6
gemini_account_snapshot work 0.5 0.4
GEMINI_NO_MAIN_MARKER="$WORK/gemini-no-main-main.json.removed"
: >"$GEMINI_NO_MAIN_MARKER"
# The path geminib itself would write, resolved by the module both tools source — a marker spelled
# anywhere else is one geminib writes and llm-limits.sh never sees.
gemini_no_main_marker_shared=$(gemini_base_home="$HOME_FIXTURE" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-no-main-main.json" \
  /bin/bash -c '. "'"$ROOT"'/share/gemini-accounts.sh" && gemini_removal_marker main')
[ "$gemini_no_main_marker_shared" = "$GEMINI_NO_MAIN_MARKER" ] \
  || fail "the shared resolver names $gemini_no_main_marker_shared, the collector reads $GEMINI_NO_MAIN_MARKER"
gemini_no_main() {
  GEMINIB_PROFILES_DIR="$GEMINI_NO_MAIN_PROFILES" \
    LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_NO_MAIN_CACHE" \
    LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-no-main-main.json" \
    HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$GEMINI_NO_MAIN_STORE" /bin/bash "$SCRIPT" "$@"
}
no_main=$(gemini_no_main --json)
jq -e '.vendors.gemini |
  ([.accounts[] | select(.account == "main")] | length) == 0 and
  (. | has("removed") | not) and .available == true and
  .current_account == "com" and .accounts[0].account == "com" and
  .accounts[0].is_current == true and .accounts[1].is_current == false and
  .five_hour.used_pct == 30 and .weekly.used_pct == 40' <<<"$no_main" >/dev/null \
  || fail "removed Gemini main still shaped the vendor row"
[ -e "$GEMINI_NO_MAIN_MARKER" ] \
  || fail "a passive collect cleared the Gemini main removal marker"
no_main_table=$(gemini_no_main --table)
grep -q '^gemini/main' <<<"$no_main_table" && fail "removed Gemini main still rendered a table row"
grep -q '^gemini/com\*' <<<"$no_main_table" || fail "Gemini current account lost its table mark"
grep -q '^gemini/work ' <<<"$no_main_table" || fail "remaining Gemini account missing from the table"
no_main_plain=$(gemini_no_main --plain)
grep -q '^gemini/main' <<<"$no_main_plain" && fail "removed Gemini main still rendered a plain row"
grep -q '^gemini/com\*:' <<<"$no_main_plain" || fail "Gemini current account lost its plain mark"

# The current account is the first ENABLED one: a pool exclusion moves the mark on.
mkdir -p "$GEMINI_NO_MAIN_PROFILES/.geminib"
printf 'com\n' >"$GEMINI_NO_MAIN_PROFILES/.geminib/disabled"
no_main_off=$(gemini_no_main --json)
jq -e '.vendors.gemini | .current_account == "work" and
  ([.accounts[] | select(.is_current)] | length) == 1 and
  ([.accounts[] | select(.account == "work" and .is_current)] | length) == 1' \
  <<<"$no_main_off" >/dev/null || fail "an excluded Gemini account kept the current mark"
rm -f "$GEMINI_NO_MAIN_PROFILES/.geminib/disabled"

# One account left is still an account row, never the flat legacy shape main used to own.
GEMINI_SOLE_PROFILES="$WORK/gemini-sole-profiles"
mkdir -p "$GEMINI_SOLE_PROFILES/com"
no_main_sole=$(GEMINIB_PROFILES_DIR="$GEMINI_SOLE_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_NO_MAIN_CACHE" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-no-main-main.json" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$WORK/gemini-sole-store.json" /bin/bash "$SCRIPT" --json)
jq -e '.vendors.gemini | (.accounts | length) == 1 and .accounts[0].account == "com" and
  .current_account == "com" and .available == true and (. | has("account") | not)' \
  <<<"$no_main_sole" >/dev/null || fail "the last Gemini account collapsed into the legacy shape"

# No accounts at all because main was REMOVED is a stated verdict, not a crash and not a resurrected
# main — and the verdict is `removed`, which is what the menubar skips a vendor whole on. Emptying
# the roster without saying so left removed Gemini rendering a "no live data" row with a Refresh
# submenu, the opposite of removed (audit, 2026-08-26).
GEMINI_EMPTY_PROFILES="$WORK/gemini-empty-profiles"
GEMINI_EMPTY_CACHE="$WORK/gemini-empty-cache"
mkdir -p "$GEMINI_EMPTY_PROFILES" "$GEMINI_EMPTY_CACHE"
: >"$WORK/gemini-empty-main.json.removed"
no_main_empty=$(GEMINIB_PROFILES_DIR="$GEMINI_EMPTY_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_EMPTY_CACHE" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-empty-main.json" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$WORK/gemini-empty-store.json" /bin/bash "$SCRIPT" --json) \
  || true
jq -e '.vendors.gemini | .available == false and .removed == true and .status == "removed" and
  (. | has("accounts") | not) and (. | has("current_account") | not) and .usable_now == false' \
  <<<"$no_main_empty" >/dev/null || fail "a Gemini vendor emptied by removal did not state its verdict"
# A REMOVED vendor has nothing a refresh could have been for, so a cause carried over from before
# the removal is a verdict about an account that is gone.
printf '{"schema":1,"vendors":{"gemini":{"available":true,"refresh_error":{"cause":"login needed (not signed in)","at":1}}}}\n' \
  >"$WORK/gemini-empty-cause-store.json"
no_main_empty_cause=$(GEMINIB_PROFILES_DIR="$GEMINI_EMPTY_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_EMPTY_CACHE" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-empty-main.json" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$WORK/gemini-empty-cause-store.json" \
  /bin/bash "$SCRIPT" --json) || true
jq -e '.vendors.gemini | .removed == true and (. | has("refresh_error") | not)' \
  <<<"$no_main_empty_cause" >/dev/null \
  || fail "a removed Gemini kept a cause about an account it no longer has"

# An account that has never been refreshed emits no row either, so the roster is empty here TOO —
# and its failed refresh is a live cause about an account that very much exists. Deleted on the
# empty roster alone, a first-run Gemini showed a failed refresh with no cause on every surface,
# which is the exact symptom the removal filter was written to end (audit, 2026-08-26).
GEMINI_FIRST_RUN_PROFILES="$WORK/gemini-first-run-profiles"
GEMINI_FIRST_RUN_CACHE="$WORK/gemini-first-run-cache"
mkdir -p "$GEMINI_FIRST_RUN_PROFILES" "$GEMINI_FIRST_RUN_CACHE"
gemini_first_run=$(GEMINIB_PROFILES_DIR="$GEMINI_FIRST_RUN_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_FIRST_RUN_CACHE" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-first-run-main.json" \
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD=/usr/bin/false \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$WORK/gemini-first-run-store.json" \
  /bin/bash "$SCRIPT" --refresh-account gemini --json) || true
jq -e '.vendors.gemini | .status == "no quota snapshot" and (. | has("removed") | not) and
  ((.accounts // []) | length) == 0 and .refresh_error.cause == "live query failed"' \
  <<<"$gemini_first_run" >/dev/null \
  || fail "a never-cached Gemini account lost the cause of its own failed refresh: $(jq -c '.vendors.gemini' <<<"$gemini_first_run")"

# `no quota snapshot` is ALSO what the multi-account branch says when nothing is selectable — every
# account walled at 100, or every one of them removed — and gated on that word instead of on the
# roster a real refresh failure was deleted, so --json/--table/the menubar showed a failed refresh
# with no cause at all. The roster here is two accounts deep.
GEMINI_WALLED_CACHE="$WORK/gemini-walled-cache"
mkdir -p "$GEMINI_WALLED_CACHE"
for walled_account in com work; do
  printf '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0,"resetTime":"2099-01-01T00:00:00Z"},{"window":"weekly","remainingFraction":0,"resetTime":"2099-01-02T00:00:00Z"}]}]}\n' \
    >"$GEMINI_WALLED_CACHE/$walled_account.json"
done
printf '{"schema":1,"vendors":{"gemini":{"available":true,"refresh_error":{"cause":"live query failed","at":1}}}}\n' \
  >"$WORK/gemini-walled-store.json"
gemini_walled=$(GEMINIB_PROFILES_DIR="$GEMINI_NO_MAIN_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_WALLED_CACHE" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-no-main-main.json" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$WORK/gemini-walled-store.json" \
  /bin/bash "$SCRIPT" --json) || true
jq -e '.vendors.gemini | .available == false and .status == "no quota snapshot" and
  (.accounts | length) == 2 and .refresh_error.cause == "live query failed"' \
  <<<"$gemini_walled" >/dev/null \
  || fail "a walled Gemini roster lost its refresh cause: $(jq -c '.vendors.gemini | {status,refresh_error,accounts:(.accounts|length)}' <<<"$gemini_walled")"

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

plain_raw=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" bash "$SCRIPT" --plain) || fail "plain collection failed"
# CLICOLOR_FORCE is the whole color decision (nothing captured here is a tty), which is what
# makes strip_ansi elsewhere in this file a no-op rather than a guard against unread escapes.
grep -q $'\033\[' <<<"$plain_raw" && fail "uncolored capture carried escapes"
colored=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" \
  CLICOLOR_FORCE=1 bash "$SCRIPT" --plain) || fail "colored plain collection failed"
grep -q $'\033\[' <<<"$colored" || fail "CLICOLOR_FORCE produced no color"
grep -q $'\033\[' <<<"$(strip_ansi <<<"$colored")" && fail "strip_ansi left color behind"
plain=$(strip_ansi <<<"$plain_raw")
grep -q 'claude/main\*: 5h 19% @ .* | wk 53% @ .* | fb - @ -' <<<"$plain" || fail "plain Claude values missing"
grep -q 'codex: 5h 74%~ @ .* | wk 31%~ @ .* | fb - @ -' <<<"$plain" || fail "plain Codex values or stale markers missing"
grep 'codex:' <<<"$plain" | grep -q '| age ' || fail "plain age field missing"
grep -q '| rot - | cr - | status -' <<<"$plain" || fail "plain explicit state fields missing"

# A vendor collapsed to a single account row still has to show that account's pool state; the
# row is built from the vendor object, so it must reach into the one account it stands for.
mkdir -p "$HOME_FIXTURE/.codex-profiles/.codexb"
printf 'main\n' >"$HOME_FIXTURE/.codex-profiles/.codexb/disabled"
pool_plain=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" \
  bash "$SCRIPT" --plain) || fail "plain collection with a Codex pool exclusion failed"
grep -q '^codex: .* | rot off ' <<<"$pool_plain" \
  || fail "the single-account Codex row hid its worker-pool exclusion"
rm -f "$HOME_FIXTURE/.codex-profiles/.codexb/disabled"
grep -q '^gemini: .* | status no quota snapshot | last wall 2026-07-11T08:00:00Z$' <<<"$plain" \
  || fail "plain unavailable vendor lost its last wall"
# A vendor with no data at all is the loudest age alarm there is; the plain row must not be the
# one surface that renders it as an ordinary reading.
plain_color=$(CLICOLOR_FORCE=1 HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" \
  LLM_LIMITS_WALLS_LOG="$WALLS" bash "$SCRIPT" --plain) || fail "plain color collection failed"
grep '^gemini:' <<<"$plain_color" | grep -q "| age "$'\033\[31m' \
  || fail "an unavailable vendor rendered its age unalarmed in plain"
fallback_table=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "fallback table collection failed"
grep -q '^claude/main' <<<"$fallback_table" || fail "unique fallback main account missing from table"

CLAUDEB="$WORK/claudeb-store"
mkdir -p "$CLAUDEB/limits" "$CLAUDEB/tokens"
: >"$CLAUDEB/tokens/alona"
printf 'alona\n' >"$CLAUDEB/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' "$((now + 5000))" "$((now + 5500))" "$now" >"$CLAUDEB/limits/alona.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s},"seven_day":{"used_percentage":62,"resets_at":%s}}\n' "$((now + 6000))" "$((now + 7000))" >"$CLAUDEB/limits/main.json"
printf '{"five_hour":{"used_percentage":99,"resets_at":%s}}\n' "$((now + 6000))" >"$CLAUDEB/limits/-.json"
multi=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "claudeb collection failed"
jq -e '.vendors.claude.source == "claudeb-store" and (.vendors.claude.accounts | length) == 1 and .vendors.claude.accounts[0].account == "alona" and .vendors.claude.accounts[0].is_current == true and (.vendors.claude.accounts[0] | has("weekly") | not) and .vendors.claude.five_hour == .vendors.claude.accounts[0].five_hour and (.vendors.claude | has("weekly") | not)' <<<"$multi" >/dev/null || fail "claudeb schema, uniqueness, or hoist mismatch"
jq -e '.vendors.claude.accounts[0].fable.used_pct == 33 and .vendors.claude.fable.used_pct == 33 and
  all(.vendors.claude.accounts[]; .account != "main" and .account != "-")' <<<"$multi" >/dev/null \
  || fail "claudeb fable or unique-account mismatch"
jq -e '.vendors.claude.accounts[0].rotation == {usable:{general:true,fable:true}} and
  .vendors.claude.accounts[0].blocked == false and
  (.vendors.claude | has("daemon") | not)' <<<"$multi" >/dev/null \
  || fail "local Claude rotation contract mismatch"

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
jq -e --argjson oldest "$((now - 10800))" --argjson now "$now" '
  [.vendors.claude.accounts[] | select(.account == "divergent")][0] as $a |
  ($a.as_of | fromdateiso8601) == $oldest and
  $a.stale_seconds >= ($now - $oldest) and
  ($a.stale_seconds < ($now - $oldest + 60)) and
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

CLAUDEB_BIN="$ROOT/bin/claudeb"
OAUTH_HOME="$WORK/oauth-home"
OAUTH_STORE="$WORK/oauth-store"
OAUTH_BIN="$WORK/oauth-bin"
OAUTH_SENTINEL="$WORK/oauth-curl-called"
OAUTH_CLAUDE_SENTINEL="$WORK/oauth-claude-called"
mkdir -p "$OAUTH_HOME/.claude-profiles/stuck" "$OAUTH_STORE/tokens" "$OAUTH_STORE/limits" "$OAUTH_BIN"
printf 'fixture-token\n' >"$OAUTH_STORE/tokens/stuck"
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
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" CLAUDEB_WARM_USER_EXPLICIT=true \
  bash "$CLAUDEB_BIN" --refresh --start-windows >/dev/null 2>/dev/null || fail "start-windows auth fallback fixture failed"
grep -q 'api.anthropic.com/v1/messages' "$OAUTH_SENTINEL" || fail "start-windows did not use the messages fallback after auth failure"

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
printf '%s\n' "\$*" >>"\$CODEX_QUOTA_SENTINEL"
printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":31,"windowDurationMins":300,"resetsAt":$((now + 4000))},"secondary":{"usedPercent":64,"windowDurationMins":10080,"resetsAt":$((now + 90000))},"planType":"plus"}}'
EOF
chmod +x "$FAKE_BIN/claudeb" "$FAKE_BIN/codex" "$WORK/fake-codex-quota"
GROK_FIXTURE="$ROOT/tests/fixtures/fake-grok-quota.sh"
GROK_CACHE="$WORK/grok-quota.json"

# --refresh is zero token spend: claudeb tier-1 snapshot, codex app-server usage query
# (never codex exec), and the live snapshot outranks the stale rollout tail.
refresh_out=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh) || fail "refresh collection failed"
[ -s "$SENTINEL" ] || fail "--refresh did not invoke claudeb accounts"
grep -q 'accounts --no-spend' "$SENTINEL" || fail "Claude refresh was not tier-1-only"
grep -qx -- '--all-accounts' "$CODEX_QUOTA_SENTINEL" \
  || fail "--refresh did not ask the codex quota helper to discover all accounts"
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
weekly_only_table=$(strip_ansi <<<"$weekly_only_table")
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
  LLM_LIMITS_GROK_REFRESH=1 LLM_LIMITS_GROK_QUOTA=/usr/bin/false LLM_LIMITS_GROK_CACHE="$GROK_CACHE" \
  LLM_LIMITS_CLAUDEB_CMD=/usr/bin/false HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" \
  LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh 2>/dev/null)
rc=$?
[ "$rc" -eq 4 ] || fail "all-vendor refresh failure: expected exit 4, got $rc"
jq -e '
  .refresh_error.cause == "all vendor refreshes failed" and
  all(.vendors | del(.opencode) | .[];
      (.refresh_error.cause | type) == "string" and (.refresh_error.at | type) == "number") and
  .vendors.codex.five_hour.used_pct == 31 and .vendors.gemini.five_hour.used_pct == 1' \
  <<<"$all_failed" >/dev/null || fail "all-vendor failure lost structured errors or old buckets"

restored_after_failure=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  GEMINI_SENTINEL="$GEMINI_SENTINEL" \
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  LLM_LIMITS_GROK_REFRESH=1 LLM_LIMITS_GROK_QUOTA="$GROK_FIXTURE" LLM_LIMITS_GROK_CACHE="$GROK_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh) || fail "successful refresh did not clear standing errors"
jq -e '(. | has("refresh_error") | not) and all(.vendors[]; has("refresh_error") | not)' \
  <<<"$restored_after_failure" >/dev/null || fail "successful vendor refresh did not clear standing errors"

CODEX_ACCOUNTS_HOME="$WORK/codex-accounts-home"
CODEX_ACCOUNTS_CACHE="$WORK/codex-accounts.json"
mkdir -p "$CODEX_ACCOUNTS_HOME/.codex-profiles/work3"
five_reset_epoch=$((now + 4000))
expired_reset_epoch=$((now - 60))
week_reset_epoch=$((now + 90000))
cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"accounts":[{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"alpha"}
EOF
CODEX_DISCOVERY_SENTINEL="$WORK/codex-discovery-called"
cat >"$WORK/fake-codex-discovery" <<EOF
#!/usr/bin/env bash
printf 'args=%s timeout=%s\n' "\$*" "\${CODEX_QUOTA_TIMEOUT-}" >"$CODEX_DISCOVERY_SENTINEL"
test -d "\$HOME/.codex-profiles/work3" || exit 90
printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":11,"windowDurationMins":300,"resetsAt":$five_reset_epoch},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":$week_reset_epoch},"planType":"plus"},"accounts":[{"account":"main","plan_type":"plus","five_hour":{"used_pct":11,"resets_at":$five_reset_epoch},"weekly":{"used_pct":12,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"work3","plan_type":"plus","five_hour":{"used_pct":3,"resets_at":$five_reset_epoch},"weekly":{"used_pct":4,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"main"}'
EOF
chmod +x "$WORK/fake-codex-discovery"
HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_REFRESH=1 \
  LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-discovery" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh --no-write >/dev/null \
  || fail "Codex discovery refresh failed"
grep -qx -- 'args=--all-accounts timeout=10' "$CODEX_DISCOVERY_SENTINEL" \
  || fail "Codex discovery refresh did not use --all-accounts"
jq -e '.current == "main" and ([.accounts[] | select(.account == "work3")] | length) == 1' \
  "$CODEX_ACCOUNTS_CACHE" >/dev/null \
  || fail "Codex discovery refresh did not add the disk profile or preserve all-account current semantics"
CODEX_PARTIAL_HOME="$WORK/codex-partial-home"
CODEX_PARTIAL_CACHE="$WORK/codex-partial-cache.json"
mkdir -p "$CODEX_PARTIAL_HOME/.codex-profiles/a" "$CODEX_PARTIAL_HOME/.codex-profiles/b"
cat >"$CODEX_PARTIAL_CACHE" <<EOF
{"accounts":[{"account":"main","five_hour":{"used_pct":1,"resets_at":$five_reset_epoch},"weekly":{"used_pct":2,"resets_at":$week_reset_epoch},"as_of":$((now - 300))},{"account":"a","five_hour":{"used_pct":3,"resets_at":$five_reset_epoch},"weekly":{"used_pct":4,"resets_at":$week_reset_epoch},"as_of":$((now - 400))},{"account":"b","five_hour":{"used_pct":61,"resets_at":$five_reset_epoch},"weekly":{"used_pct":62,"resets_at":$week_reset_epoch},"as_of":$((now - 700))},{"account":"removed","five_hour":{"used_pct":81,"resets_at":$five_reset_epoch},"weekly":{"used_pct":82,"resets_at":$week_reset_epoch},"as_of":$((now - 800))}],"current":"main"}
EOF
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/codex-quota.py" "$CODEX_PARTIAL_HOME" "$CODEX_PARTIAL_CACHE" "$now" >"$WORK/codex-partial-result.json" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("codex_quota", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(sys.argv[2])
old = json.loads(Path(sys.argv[3]).read_text())
now = int(sys.argv[4])
accounts = module.profile_accounts(home)
results = []
for account, _ in accounts:
    if account == "b":
        results.append((account, None, now, "codex app-server timed out"))
    else:
        results.append((account, {
            "rateLimits": {
                "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": now + 4000},
                "secondary": {"usedPercent": 20, "windowDurationMins": 10080, "resetsAt": now + 90000},
            }
        }, now, None))
print(json.dumps(module.cache_payload(results, old, True, "main")))
PY
jq -e --argjson old_as_of "$((now - 700))" '
  ([.accounts[] | select(.account == "b")][0] |
    .five_hour.used_pct == 61 and .weekly.used_pct == 62 and
    .as_of == $old_as_of and (has("error") | not)) and
  ([.accounts[] | select(.account == "removed")] | length) == 0
' "$WORK/codex-partial-result.json" >/dev/null \
  || fail "Codex all-account partial failure lost cached buckets or retained a removed profile"
cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"schema":1,"fetched_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","plan_type":"plus","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"accounts":[{"account":"beta","plan_type":"team","reset_credits":0,"five_hour":{"used_pct":100,"resets_at":$expired_reset_epoch},"weekly":{"used_pct":100,"resets_at":$week_reset_epoch},"as_of":$((now - 22000))},{"account":"alpha","plan_type":"plus","reset_credits":2,"reset_credits_expires_at":"2099-09-21T00:16:44Z","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$((now - 1900))}],"current":"alpha"}
EOF
codex_accounts_full=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex multi-account collection failed"
jq -e '.vendors.codex.current_account == "alpha" and (.vendors.codex.accounts | length) == 2 and
  .vendors.codex.accounts[0].is_current == true and
  .vendors.codex.accounts[0].reset_credits == 2 and
  .vendors.codex.accounts[0].reset_credits_stale == false and
  .vendors.codex.accounts[0].reset_credits_expires_at == "2099-09-21T00:16:44Z" and
  (.vendors.codex.accounts[1].reset_credits_expires_at | type) == "null" and
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
CODEX_NULL_CACHE="$WORK/codex-null-window.json"
cat >"$CODEX_NULL_CACHE" <<EOF
{"accounts":[{"account":"main","reset_credits":1,"five_hour":{"used_pct":null,"resets_at":$five_reset_epoch,"as_of":$((now - 20000))},"weekly":{"used_pct":33,"resets_at":$week_reset_epoch,"as_of":$((now - 600))},"as_of":$((now - 100))}],"current":"main"}
EOF
codex_null=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_NULL_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex null-window collection failed"
jq -e --argjson data_as_of "$((now - 600))" --argjson credits_as_of "$((now - 100))" '
  .vendors.codex.accounts[0] as $a |
  $a.five_hour.used_pct == null and $a.five_hour.as_of < $data_as_of and
  ($a.as_of | fromdateiso8601) == $data_as_of and
  (.vendors.codex.as_of | fromdateiso8601) == $data_as_of and
  $a.reset_credits_as_of == $credits_as_of and $a.reset_credits_stale == false' \
  <<<"$codex_null" >/dev/null || fail "null Codex window affected data age or reset-credit freshness"
codex_null_table=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_NULL_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "Codex null-window table failed"
codex_null_age=$(awk '$1 == "codex" {print $(NF-3)}' <<<"$codex_null_table")
codex_null_minutes=${codex_null_age%m}
codex_null_expected=$(( ($(date +%s) - (now - 600)) / 60 ))
[[ "$codex_null_minutes" =~ ^[0-9]+$ ]] &&
  [ "$codex_null_minutes" -ge "$((codex_null_expected - 1))" ] &&
  [ "$codex_null_minutes" -le "$codex_null_expected" ] \
  || fail "Codex AGE included a null window: $codex_null_table"
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
codex_auth_table=$(strip_ansi <<<"$codex_auth_table")
codex_auth_plain=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "Codex auth-needed plain failed"
grep -Eq '^codex/work\* +- +- +- +- +- +- +never +- +- +login needed$' <<<"$codex_auth_table" \
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
    .cause == "login needed: token invalidated" and .needs_user_entry == true) and
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

# A newer rollout describes the MAIN codex home only: it overlays main's numbers and must
# never collapse the multi-account roster the cache owns (the other profiles keep their own
# as_of so the heartbeat can still see them go stale).
ROSTER_CACHE="$WORK/codex-roster.json"
roster_asof=$((now - 100))
cat >"$ROSTER_CACHE" <<EOF
{"schema":1,"accounts":[{"account":"main","plan_type":"plus","five_hour":{"used_pct":10,"resets_at":$five_reset_epoch},"weekly":{"used_pct":11,"resets_at":$week_reset_epoch},"as_of":$roster_asof},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":20,"resets_at":$five_reset_epoch},"weekly":{"used_pct":21,"resets_at":$week_reset_epoch},"as_of":$roster_asof},{"account":"beta","plan_type":"team","five_hour":{"used_pct":30,"resets_at":$five_reset_epoch},"weekly":{"used_pct":31,"resets_at":$week_reset_epoch},"as_of":$roster_asof},{"account":"gamma","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":41,"resets_at":$week_reset_epoch},"as_of":$roster_asof}],"current":"main"}
EOF
touch -t 202607110500 "$ROSTER_CACHE"
roster_wins=$(LLM_LIMITS_CODEX_CACHE="$ROSTER_CACHE" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" \
  LLM_LIMITS_CACHE="$WORK/roster-store.json" bash "$SCRIPT" --no-write) || fail "rollout-over-roster collection failed"
jq -e --argjson asof "$roster_asof" '
  .vendors.codex.source == "session-rollout" and .vendors.codex.current_account == "main" and
  (.vendors.codex.accounts | length) == 4 and
  ([.vendors.codex.accounts[].account] == ["main","alpha","beta","gamma"]) and
  ([.vendors.codex.accounts[] | select(.account == "main")][0] |
    .five_hour.used_pct == 74 and .weekly.used_pct == 31 and
    .five_hour.origin == "headers") and
  .vendors.codex.five_hour.used_pct == 74 and
  ([.vendors.codex.accounts[] | select(.account != "main")] |
    ([.[].five_hour.used_pct] == [20,30,40]) and ([.[].weekly.used_pct] == [21,31,41]) and
    all(.[]; .five_hour.as_of == $asof and .weekly.as_of == $asof and
              .five_hour.origin == "usage" and .plan_type != null))' \
  <<<"$roster_wins" >/dev/null \
  || fail "a newer rollout replaced the cached codex roster instead of overlaying main"
roster_table=$(LLM_LIMITS_CODEX_CACHE="$ROSTER_CACHE" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" \
  LLM_LIMITS_CACHE="$WORK/roster-store.json" bash "$SCRIPT" --table --no-write 2>/dev/null) || fail "rollout-over-roster table failed"
for account in main alpha beta gamma; do
  grep -Eq "^codex/$account\*? " <<<"$roster_table" \
    || fail "table lost the codex/$account row under a newer rollout: $roster_table"
done
rm -f "$ROSTER_CACHE"

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
[ "$(wc -l <"$CODEX_QUOTA_SENTINEL" | tr -d ' ')" -eq 2 ] || fail "codex quota was not re-read after the window start"
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
[ "$order" = "claude/alona*,codex,gemini,grok" ] || fail "default table order mismatch: $order"
head -n 1 <<<"$table" | grep -q 'FB%' || fail "Fable percentage column missing from table"
head -n 1 <<<"$table" | grep -q 'FB RESET' || fail "Fable reset column missing from table"
head -n 1 <<<"$table" | grep -q 'NOTE' && fail "NOTE column still present"
awk '$1 == "claude/alona*" {print $4}' <<<"$table" | grep -qx '33%' || fail "Fable percentage cell missing"
awk '$1 == "codex" {print $4}' <<<"$table" | grep -qx '-' || fail "non-Fable row must render a dash"
grep -q 'Gemini Models\|plus' <<<"$table" && fail "junk labels leaked into table"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now - 1))" >"$CLAUDEB/limits/alona.json"
expired_fable=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "expired fable table failed"
# Canonical expired cell (shared-invariants row y): effective value 0 plus the
# expired marker — the same number the menu grays out, never yesterday's raw pct.
awk '$1 == "claude/alona*" {print $4}' <<<"$expired_fable" | grep -qx '0%!' \
  || fail "expired fable must render effective 0 with the expired marker"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now + 5500))" >"$CLAUDEB/limits/alona.json"
awk 'NR > 1 && $1 == "codex"' <<<"$table" | grep -Eq '[0-9]{2}:[0-9]{2}' || fail "codex reset time not rendered"
sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$sorted" | paste -sd, -)
[ "$order" = "codex,claude/alona*,gemini,grok" ] || fail "--sort 5h order mismatch: $order"
# zoe: distant 5h reset but imminent weekly reset — --sort reset must use min(5h, weekly).
printf '{"five_hour":{"used_percentage":11,"resets_at":%s},"seven_day":{"used_percentage":97,"resets_at":%s}}\n' "$((now + 50000))" "$((now + 500))" >"$CLAUDEB/limits/zoe.json"
reset_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort reset) || fail "reset-sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$reset_sorted" | paste -sd, -)
[ "$order" = "claude/zoe,codex,claude/alona*,gemini,grok" ] || fail "--sort reset min(5h, weekly) order mismatch: $order"
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
jq -e '.schema == 1 and (.vendors | keys == ["claude","codex","gemini","grok","opencode"])' <<<"$bare" >/dev/null || fail "piped bare invocation must emit schema-1 JSON"

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
# around midnight it renders as yesterday. The cell shows the effective value (0, row y).
grep -Eq '^codex +0%! +44% +- +([A-Za-z]{3} )?[0-9]{2}:[0-9]{2}' <<<"$codex_row" || fail "expired window must render effective 0 and keep its reset time: $codex_row"
expired_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "expired plain collection failed"
grep -q 'codex: 5h 0%! @ .* | wk 44% @ ' <<<"$expired_plain" || fail "expired plain output must render effective 0 with the expired marker"
expired_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "expired sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$expired_sorted" | paste -sd, -)
[ "$order" = "claude/alona*,codex,gemini,grok" ] || fail "expired 5h sort must rank the stale 100% as 0: $order"

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
grep -Eq '^claude/honest\* +100%~ +0%! ' <<<"$honest_row" || fail "honesty table lost markers or the effective expired value"
grep -Eq ' +1h1m +limit-5h +- +-$' <<<"$honest_row" || fail "table age or limit-derived state fields missing: $honest_row"
grep -q 'claude/honest\*: 5h 100%~ @ .* | wk 0%! @ ' <<<"$honest_plain" || fail "honesty plain lost markers or the effective expired value"
grep 'claude/honest\*:' <<<"$honest_plain" | grep -q '| age 1h1m | rot limit-5h | cr - | status -' \
  || fail "plain age or explicit state fields missing"

# A row carrying no dated window and a row a day old are one verdict, and neither may render as an
# ordinary age. The flag is the collector's alone: every surface paints it, none re-derives it.
ALARM_STORE="$WORK/alarm-store"
ALARM_CACHE="$WORK/alarm-cache.json"
mkdir -p "$ALARM_STORE/limits"
alarm_now=$(date +%s)
printf 'recent\n' >"$ALARM_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":12,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((alarm_now + 5000))" "$((alarm_now - 120))" "$alarm_now" >"$ALARM_STORE/limits/recent.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((alarm_now + 5000))" "$((alarm_now - 172800))" "$alarm_now" >"$ALARM_STORE/limits/twodays.json"
printf '{"auth":{"status":"ok","checked_at":%s}}\n' "$alarm_now" >"$ALARM_STORE/limits/nodata.json"
alarm_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" LLM_LIMITS_CACHE="$ALARM_CACHE" \
  bash "$SCRIPT" --json) || fail "age-alarm collection failed"
jq -e '
  ([.vendors.claude.accounts[] | select(.account == "nodata")][0]
   | .age_alarm == true and (has("as_of") | not)) and
  ([.vendors.claude.accounts[] | select(.account == "twodays")][0] | .age_alarm == true) and
  ([.vendors.claude.accounts[] | select(.account == "recent")][0] | .age_alarm == false) and
  .vendors.claude.age_alarm == false' <<<"$alarm_json" >/dev/null \
  || fail "age_alarm mismatch on Claude accounts or the hoisted vendor object"
jq -e '[.vendors[] | (.accounts[]? // .) | .age_alarm] | length > 0 and all(type == "boolean")' \
  <<<"$alarm_json" >/dev/null || fail "an account or vendor object reached the projection without age_alarm"
ALARM_UNDATED_STORE="$WORK/alarm-undated-store"
mkdir -p "$ALARM_UNDATED_STORE/limits"
printf 'nodata\n' >"$ALARM_UNDATED_STORE/.claudeb-state"
printf '{"auth":{"status":"ok","checked_at":%s}}\n' "$alarm_now" >"$ALARM_UNDATED_STORE/limits/nodata.json"
alarm_undated=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_UNDATED_STORE" \
  LLM_LIMITS_CACHE="$WORK/alarm-undated-cache.json" bash "$SCRIPT" --json) \
  || fail "undated-vendor age-alarm collection failed"
jq -e '.vendors.claude | .age_alarm == true and (has("as_of") | not)' <<<"$alarm_undated" >/dev/null \
  || fail "a vendor with no dated window did not raise age_alarm"
alarm_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" LLM_LIMITS_CACHE="$ALARM_CACHE" \
  bash "$SCRIPT" --table) || fail "age-alarm table collection failed"
awk '$1 == "claude/nodata" {print $(NF-3)}' <<<"$alarm_table" | grep -qx never \
  || fail "an account with no dated window must render AGE as never: $alarm_table"
awk '$1 == "claude/twodays" {print $(NF-3)}' <<<"$alarm_table" | grep -qx 2d \
  || fail "a two-day age lost its span: $alarm_table"
printf '%s' "$alarm_table" | grep -q $'\033' && fail "the redirected table emitted color escapes"
alarm_color=$(CLICOLOR_FORCE=1 HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" \
  LLM_LIMITS_CACHE="$ALARM_CACHE" bash "$SCRIPT" --table) \
  || fail "age-alarm color table collection failed"
grep -q $'\033\[31mnever' <<<"$alarm_color" || fail "the never age did not render red"
grep -q $'\033\[31m2d' <<<"$alarm_color" || fail "a day-old age did not render red"
grep '^claude/recent' <<<"$alarm_color" | grep -q $'\033\[31m' \
  && fail "a fresh age rendered red"
alarm_plain=$(CLICOLOR_FORCE=1 HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" \
  LLM_LIMITS_CACHE="$ALARM_CACHE" bash "$SCRIPT" --plain) \
  || fail "age-alarm color plain collection failed"
grep '^claude/nodata:' <<<"$alarm_plain" | grep -q "| age "$'\033\[31m'"never" \
  || fail "the never age did not render red in plain"
grep '^claude/twodays:' <<<"$alarm_plain" | grep -q "| age "$'\033\[31m'"2d" \
  || fail "a day-old age did not render red in plain"
grep '^claude/recent' <<<"$alarm_plain" | grep -q $'\033\[31m' \
  && fail "a fresh age rendered red in plain"
alarm_plain_piped=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" \
  LLM_LIMITS_CACHE="$ALARM_CACHE" bash "$SCRIPT" --plain) || fail "age-alarm plain collection failed"
printf '%s' "$alarm_plain_piped" | grep -q $'\033' && fail "the redirected plain output emitted color escapes"

USABLE_STORE="$WORK/usable-store"
USABLE_HOME="$WORK/usable-home"
mkdir -p "$USABLE_STORE/limits" "$USABLE_HOME/.codex/sessions"
printf 'full\n' >"$USABLE_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":100,"resets_at":%s},"seven_day":{"used_percentage":100,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" "$now" >"$USABLE_STORE/limits/full.json"
claude_full=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude exhausted usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_full" >/dev/null || fail "Claude all-exhausted usability mismatch"
# The shield takes the account out of the POOL (`enabled`), which is consent; its auth is alive, so
# capability still reads true (shared-invariants row o) and a pin could still reach it.
jq -e '.vendors.claude.accounts[0] |
  .shielded == true and .enabled == false and
  .rotation == {usable:{general:true,fable:false}}' \
  <<<"$claude_full" >/dev/null || fail "exhausted main account did not enter the worker-pool shield"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" "$now" >"$USABLE_STORE/limits/free.json"
claude_free=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude free-account usability collection failed"
jq -e '.vendors.claude.usable_now == true' <<<"$claude_free" >/dev/null || fail "Claude one-free-account usability mismatch"
printf 'free\n' >"$USABLE_STORE/disabled"
claude_disabled=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude disabled-account usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_disabled" >/dev/null || fail "Disabled under-limit account must not make Claude usable"
jq -e '.vendors.claude.accounts[] | select(.account == "free") |
  .enabled == false and .blocked == true and
  .rotation == {usable:{general:true,fable:false}}' <<<"$claude_disabled" >/dev/null \
  || fail "a pool-excluded account must read blocked while its live auth still reads usable"
rm "$USABLE_STORE/disabled"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"auth":{"status":"expired"}}\n' \
  "$((now + 5000))" "$((now + 9000))" >"$USABLE_STORE/limits/free.json"
claude_expired_auth=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude expired-auth usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_expired_auth" >/dev/null || fail "Expired-auth under-limit account must not make Claude usable"
rm "$USABLE_STORE/limits/free.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"fable":{"used_percentage":100,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" "$((now + 6000))" "$now" >"$USABLE_STORE/limits/full.json"
claude_fable=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude fable usability collection failed"
jq -e '.vendors.claude.fable.effective_pct == 100 and .vendors.claude.usable_now == true' <<<"$claude_fable" >/dev/null || fail "Fable exhaustion must not block general Claude work"
jq -e '.vendors.claude.accounts[0].rotation.usable.fable == true' <<<"$claude_fable" >/dev/null \
  || fail "numeric Fable snapshot was not marked Fable-capable"

PLAN_BIN="$WORK/plan-bin"
PLAN_HOME="$WORK/plan-home"
PLAN_STORE="$WORK/plan-store"
mkdir -p "$PLAN_BIN" "$PLAN_HOME/.claude-profiles" "$PLAN_STORE/limits"
printf 'pro\n' >"$PLAN_STORE/.claudeb-state"
cat >"$PLAN_BIN/security" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -w "*) printf '{"claudeAiOauth":{"subscriptionType":"%s"}}\n' "$PLAN_TYPE" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$PLAN_BIN/security"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s},"fable":{"used_percentage":42,"resets_at":%s},"auth":{"status":"ok"}}\n' \
  "$((now + 5000))" "$((now + 6000))" >"$PLAN_STORE/limits/pro.json"
pro_plan=$(PLAN_TYPE=pro PATH="$PLAN_BIN:$PATH" HOME="$PLAN_HOME" CLAUDE_PROFILES_DIR="$PLAN_HOME/.claude-profiles" \
  CLAUDEB_DIR="$PLAN_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) \
  || fail "Pro-plan Fable fixture collection failed"
jq -e '.vendors.claude.accounts[] | select(.account == "pro") |
  .plan_type == "pro" and .rotation.usable.fable == false' <<<"$pro_plan" >/dev/null \
  || fail "Pro-plan account with numeric Fable snapshot remained Fable-capable"
rm -f "$PLAN_STORE/limits/pro.json"
printf 'team\n' >"$PLAN_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s},"fable":{"used_percentage":42,"resets_at":%s},"auth":{"status":"ok"}}\n' \
  "$((now + 5000))" "$((now + 6000))" >"$PLAN_STORE/limits/team.json"
team_plan=$(PLAN_TYPE=team PATH="$PLAN_BIN:$PATH" HOME="$PLAN_HOME" CLAUDE_PROFILES_DIR="$PLAN_HOME/.claude-profiles" \
  CLAUDEB_DIR="$PLAN_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) \
  || fail "non-Pro-plan Fable fixture collection failed"
jq -e '.vendors.claude.accounts[] | select(.account == "team") |
  .plan_type == "team" and .rotation.usable.fable == true' <<<"$team_plan" >/dev/null \
  || fail "non-Pro account with numeric Fable snapshot was not Fable-capable"

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
jq -e '.experiments == []' <<<"$exp_json" >/dev/null \
  || fail "an in-date experiment must stay off the banner"
exp_table=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --table --no-write 2>/dev/null)
! grep -Fq 'EXPERIMENT trial-x' <<<"$exp_table" || fail "--table announced an in-date experiment"
printf '[{"id":"undated","what":"fixture experiment with no review date","started":"2026-01-01","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
exp_undated=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.experiments == ["EXPERIMENT undated until  — temporary, see EXPERIMENTS.json"]' <<<"$exp_undated" >/dev/null \
  || fail "an experiment without review_by must keep announcing (it can never go OVERDUE)"
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

# Account order in the cache is the order every surface renders: the hardcoded primaries first,
# then oldest profile directory first, and an account with no directory (hence no birth time) last
# by name. `current` no longer buys a place in that order — it is carried by is_current instead.
ORDER_HOME="$WORK/order-home"
ORDER_STORE="$WORK/order-claudeb-store"
mkdir -p "$ORDER_HOME/.claude" "$ORDER_HOME/.claude-profiles" "$ORDER_STORE/limits"
# Created youngest-name-first so a passing order cannot also be the alphabet.
for order_profile in zed mid abe com notcom; do
  mkdir -p "$ORDER_HOME/.claude-profiles/$order_profile"
  sleep 1
done
for order_account in zed mid abe com notcom ghosta ghostb; do
  order_pct=5
  # The current account is neither first in render order nor the only one with data, so a
  # vendor-level five_hour of 42 can only have come from the current account itself.
  [ "$order_account" != mid ] || order_pct=42
  printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' \
    "$order_pct" "$((now + 5000))" "$now" >"$ORDER_STORE/limits/$order_account.json"
done
printf 'mid\n' >"$ORDER_STORE/.claudeb-state"
order_claude=$(HOME="$ORDER_HOME" CLAUDEB_DIR="$ORDER_STORE" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --json) || fail "claude account-order collection failed"
jq -e '[.vendors.claude.accounts[].account] ==
  ["notcom","com","zed","mid","abe","ghosta","ghostb"]' <<<"$order_claude" >/dev/null \
  || fail "claude accounts are not ordered priority-first, then by profile birth time, unknowns last"
jq -e '.vendors.claude.current_account == "mid" and
  ([.vendors.claude.accounts[] | select(.is_current)] | length) == 1 and
  [.vendors.claude.accounts[] | select(.is_current)][0].account == "mid"' <<<"$order_claude" >/dev/null \
  || fail "claude current account was not decoupled from the array order"
jq -e '.vendors.claude.five_hour ==
  ([.vendors.claude.accounts[] | select(.is_current)][0].five_hour) and
  .vendors.claude.five_hour.used_pct == 42' <<<"$order_claude" >/dev/null \
  || fail "the vendor five_hour hoist took the first ordered account instead of the current one"
order_claude_table=$(HOME="$ORDER_HOME" CLAUDEB_DIR="$ORDER_STORE" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --table) || fail "claude account-order table failed"
[ "$(awk 'NR > 1 && $1 ~ /^claude\// {sub(/\*$/, "", $1); print $1}' <<<"$order_claude_table" | paste -sd, -)" \
  = "claude/notcom,claude/com,claude/zed,claude/mid,claude/abe,claude/ghosta,claude/ghostb" ] \
  || fail "the table did not render claude accounts in cache order"

ORDER_CODEX_HOME="$WORK/order-codex-home"
ORDER_CODEX_CACHE="$WORK/order-codex-cache.json"
mkdir -p "$ORDER_CODEX_HOME/.codex"
for order_profile in zed abe; do
  mkdir -p "$ORDER_CODEX_HOME/.codex-profiles/$order_profile"
  sleep 1
done
cat >"$ORDER_CODEX_CACHE" <<EOF
{"accounts":[{"account":"abe","five_hour":{"used_pct":3,"resets_at":$((now + 5000))},"weekly":{"used_pct":4,"resets_at":$((now + 90000))},"as_of":$now},{"account":"ghost","five_hour":{"used_pct":5,"resets_at":$((now + 5000))},"weekly":{"used_pct":6,"resets_at":$((now + 90000))},"as_of":$now},{"account":"zed","five_hour":{"used_pct":7,"resets_at":$((now + 5000))},"weekly":{"used_pct":8,"resets_at":$((now + 90000))},"as_of":$now},{"account":"main","five_hour":{"used_pct":9,"resets_at":$((now + 5000))},"weekly":{"used_pct":10,"resets_at":$((now + 90000))},"as_of":$now}],"current":"abe"}
EOF
order_codex=$(HOME="$ORDER_CODEX_HOME" LLM_LIMITS_CODEX_CACHE="$ORDER_CODEX_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "codex account-order collection failed"
jq -e '[.vendors.codex.accounts[].account] == ["main","zed","abe","ghost"] and
  .vendors.codex.current_account == "abe"' <<<"$order_codex" >/dev/null \
  || fail "codex accounts are not ordered main-first, then by profile birth time, unknowns last"

ORDER_GEMINI_PROFILES="$WORK/order-gemini-profiles"
ORDER_GEMINI_CACHE_DIR="$WORK/order-gemini-cache"
mkdir -p "$ORDER_GEMINI_CACHE_DIR"
for order_profile in zed abe com; do
  mkdir -p "$ORDER_GEMINI_PROFILES/$order_profile"
  sleep 1
done
order_gemini_snapshot='{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.5,"resetTime":"2099-01-01T00:00:00Z"},{"window":"5h","remainingFraction":0.6,"resetTime":"2099-01-01T00:00:00Z"}]}]}'
for order_account in zed abe com; do
  printf '%s\n' "$order_gemini_snapshot" >"$ORDER_GEMINI_CACHE_DIR/$order_account.json"
done
printf '%s\n' "$order_gemini_snapshot" >"$WORK/order-gemini-main.json"
order_gemini=$(GEMINIB_PROFILES_DIR="$ORDER_GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$ORDER_GEMINI_CACHE_DIR" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/order-gemini-main.json" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) \
  || fail "gemini account-order collection failed"
jq -e '[.vendors.gemini.accounts[].account] == ["main","com","zed","abe"]' <<<"$order_gemini" >/dev/null \
  || fail "gemini accounts are not ordered priority-first, then by profile birth time"

# The final merge sees vendor data read before the store lock, so a racing writer's newer row has
# to survive it per account — while the local state this run read stays authoritative.
MERGE_PROFILES="$WORK/merge-gemini-profiles"
MERGE_CACHE_DIR="$WORK/merge-gemini-cache"
MERGE_CACHE="$WORK/merge-cache.json"
mkdir -p "$MERGE_PROFILES/alpha" "$MERGE_PROFILES/beta" "$MERGE_PROFILES/gamma" "$MERGE_CACHE_DIR"
for merge_account in alpha beta gamma; do
  printf '%s\n' "$order_gemini_snapshot" >"$MERGE_CACHE_DIR/$merge_account.json"
done
printf '%s\n' "$order_gemini_snapshot" >"$WORK/merge-gemini-main.json"
merge_env=(GEMINIB_PROFILES_DIR="$MERGE_PROFILES"
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$MERGE_CACHE_DIR"
  LLM_LIMITS_GEMINI_CACHE="$WORK/merge-gemini-main.json"
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$MERGE_CACHE")
env "${merge_env[@]}" bash "$SCRIPT" --json >/dev/null || fail "merge fixture collection failed"
jq --argjson future "$((now + 5000))" '.vendors.gemini.accounts |= map(
  if .account == "beta" then
    .race_marker = "older" | .five_hour.as_of = 1 | .weekly.as_of = 1 |
    .as_of = "2000-01-01T00:00:00Z" | del(.as_of_epoch)
  elif .account == "alpha" or .account == "gamma" then
    .race_marker = "newer" | .five_hour.as_of = $future | .weekly.as_of = $future |
    (if .account == "alpha" then .blocked = true | .is_current = true else . end)
  else . end)' "$MERGE_CACHE" >"$WORK/merge-cache.tmp" || fail "merge fixture edit failed"
mv "$WORK/merge-cache.tmp" "$MERGE_CACHE"
# gamma logs out between the two collects: its newer stored row is kept, its auth verdict is not.
printf '{"auth_needed":true}\n' >"$MERGE_CACHE_DIR/gamma.json"
env "${merge_env[@]}" bash "$SCRIPT" --json >/dev/null || fail "merge collection failed"
jq -e '([.vendors.gemini.accounts[].account] | sort) == ["alpha","beta","gamma","main"]' \
  "$MERGE_CACHE" >/dev/null || fail "the merge changed the account set"
jq -e 'first(.vendors.gemini.accounts[] | select(.account == "alpha")) | .race_marker == "newer"' \
  "$MERGE_CACHE" >/dev/null || fail "a strictly newer stored row was overwritten with older data"
jq -e 'first(.vendors.gemini.accounts[] | select(.account == "alpha")) |
  (has("blocked") | not) and .is_current == false' "$MERGE_CACHE" >/dev/null || \
  fail "a kept stored row carried stale local pool state past this collect's fresh verdicts"
jq -e 'first(.vendors.gemini.accounts[] | select(.account == "beta")) | has("race_marker") | not' \
  "$MERGE_CACHE" >/dev/null || fail "an older stored row survived the merge"
jq -e 'first(.vendors.gemini.accounts[] | select(.account == "gamma")) |
  .race_marker == "newer" and .auth_needed == true' "$MERGE_CACHE" >/dev/null || \
  fail "a kept stored row buried the login-needed verdict of this collect"

# A bare vendor name means "every account of this vendor, free" and must leave the other vendors
# untouched: their probes never run and their cached data survives the run.
VENDOR_SCOPE_LOG="$WORK/vendor-scope-gemini.log"
cat >"$WORK/vendor-scope-agy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$HOME" >>"$VENDOR_SCOPE_LOG"
printf '%s\n' '$order_gemini_snapshot'
EOF
CODEX_SCOPE_SENTINEL="$WORK/codex-scope-called"
cat >"$WORK/vendor-scope-codex" <<EOF
#!/usr/bin/env bash
printf 'called %s\n' "\$*" >>"$CODEX_SCOPE_SENTINEL"
printf '%s\n' '{"accounts":[{"account":"main","five_hour":{"used_pct":9,"resets_at":$((now + 5000))},"weekly":{"used_pct":10,"resets_at":$((now + 90000))},"as_of":$now}],"current":"main"}'
EOF
CLAUDEB_SCOPE_SENTINEL="$WORK/claudeb-scope-called"
cat >"$WORK/vendor-scope-claudeb" <<EOF
#!/usr/bin/env bash
printf 'called %s\n' "\$*" >>"$CLAUDEB_SCOPE_SENTINEL"
exit 0
EOF
chmod +x "$WORK/vendor-scope-agy" "$WORK/vendor-scope-codex" "$WORK/vendor-scope-claudeb"
vendor_scope_env=(GEMINIB_PROFILES_DIR="$ORDER_GEMINI_PROFILES"
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$ORDER_GEMINI_CACHE_DIR"
  LLM_LIMITS_GEMINI_CACHE="$WORK/order-gemini-main.json"
  LLM_LIMITS_GEMINI_CMD="$WORK/vendor-scope-agy"
  LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/vendor-scope-codex"
  LLM_LIMITS_CODEX_CACHE="$WORK/vendor-scope-codex-cache.json"
  LLM_LIMITS_CLAUDEB_CMD="$WORK/vendor-scope-claudeb"
  GEMINIB_SECURITY_CMD="$GEMINI_SECURITY_STUB"
  CLAUDEB_DIR="$ORDER_STORE" HOME="$ORDER_HOME" LLM_LIMITS_CACHE="$CACHE")
env "${vendor_scope_env[@]}" LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_CODEX_REFRESH=1 \
  bash "$SCRIPT" --refresh-account gemini --json >/dev/null 2>&1 \
  || fail "vendor-scoped gemini refresh failed"
[ "$(sort "$VENDOR_SCOPE_LOG" | paste -sd, -)" \
  = "$ORDER_GEMINI_PROFILES/abe,$ORDER_GEMINI_PROFILES/com,$ORDER_GEMINI_PROFILES/zed,$ORDER_HOME" ] \
  || fail "--refresh-account gemini did not refresh every gemini account: $(cat "$VENDOR_SCOPE_LOG")"
[ ! -e "$CODEX_SCOPE_SENTINEL" ] || fail "--refresh-account gemini also probed codex"
[ ! -e "$CLAUDEB_SCOPE_SENTINEL" ] || fail "--refresh-account gemini also probed claude"
: >"$VENDOR_SCOPE_LOG"
env "${vendor_scope_env[@]}" LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_CODEX_REFRESH=1 \
  bash "$SCRIPT" --refresh-account codex --json >/dev/null 2>&1 \
  || fail "vendor-scoped codex refresh failed"
grep -q -- '--all-accounts' "$CODEX_SCOPE_SENTINEL" \
  || fail "--refresh-account codex did not run the all-accounts helper path"
[ ! -s "$VENDOR_SCOPE_LOG" ] || fail "--refresh-account codex also probed gemini"
[ ! -e "$CLAUDEB_SCOPE_SENTINEL" ] || fail "--refresh-account codex also probed claude"
rm -f "$CODEX_SCOPE_SENTINEL"
env "${vendor_scope_env[@]}" LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_CODEX_REFRESH=1 \
  bash "$SCRIPT" --refresh-account claude --json >/dev/null 2>&1 \
  || fail "vendor-scoped claude refresh failed"
grep -q 'called accounts --no-spend' "$CLAUDEB_SCOPE_SENTINEL" \
  || fail "--refresh-account claude did not run the free all-account claudeb path"
[ ! -e "$CODEX_SCOPE_SENTINEL" ] || fail "--refresh-account claude also probed codex"
[ ! -s "$VENDOR_SCOPE_LOG" ] || fail "--refresh-account claude also probed gemini"
# A vendor-scoped refresh with no store to refresh from is a reason, never a silent no-op.
NO_STORE="$WORK/vendor-scope-no-store"
mkdir -p "$NO_STORE"
no_store_err=$(env "${vendor_scope_env[@]}" CLAUDEB_DIR="$NO_STORE" LLM_LIMITS_CACHE="$WORK/no-store-cache.json" \
  bash "$SCRIPT" --refresh-account claude --json 2>&1 >/dev/null)
grep -q 'no claudeb store' <<<"$no_store_err" \
  || fail "--refresh-account claude without a claudeb store said nothing"
jq -e '.vendors.claude.refresh_error.cause == "no claudeb store"' "$WORK/no-store-cache.json" >/dev/null \
  || fail "--refresh-account claude without a claudeb store recorded no refresh_error"
# The paid window-opening path stays a single-account request.
if env "${vendor_scope_env[@]}" bash "$SCRIPT" --refresh-account claude --start-windows \
  >/dev/null 2>&1; then
  fail "a bare vendor accepted --start-windows"
fi

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
grep -q 'unknown Grok account: supergrokk' "$WORK/grok-phantom.err" \
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

# An opaque gray is legible in exactly one appearance, and the menu is drawn in both: every dim in
# the renderer must come from dimColor(), which derives the tone per render. Runs whether or not
# Hammerspoon is available — the evidence is the source text.
gray_hits=$(awk '
  /grayColor/ { printf "line %d: %s\n", NR, $0 }
  /red *=/ && /green *=/ && /blue *=/ && !/alpha/ {
    r = $0; sub(/.*red *= */, "", r); sub(/[ ,}].*/, "", r)
    g = $0; sub(/.*green *= */, "", g); sub(/[ ,}].*/, "", g)
    b = $0; sub(/.*blue *= */, "", b); sub(/[ ,}].*/, "", b)
    if (r == g && g == b) printf "line %d: %s\n", NR, $0
  }' "$ROOT/hammerspoon/llm-limits.lua")
[ -z "$gray_hits" ] || fail "opaque gray is unreadable in one appearance — style dim text with dimColor() instead: $gray_hits"

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
        ["hs", *sys.argv[1:]],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=3,
    )
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
PY
}

if command -v hs >/dev/null 2>&1 && [ "$(hs_bounded -c 'return "ok"' 2>/dev/null)" = ok ]; then
  renderer_output=$(hs_bounded -c "_G.HS_ROOT = [[${HS_ROOT:-$HOME/.hammerspoon}]]; return dofile([[$ROOT/tests/llm_limits_renderer_harness.lua]])" 2>/dev/null) \
    || fail "Hammerspoon renderer contract checks threw"
  [ "$renderer_output" = "PASS: Hammerspoon projection contract" ] \
    || fail "Hammerspoon renderer contract checks: $renderer_output"
else
  echo "SKIP (hs unavailable): Hammerspoon projection contract"
fi

echo "PASS: account order (priority names, profile birth time, unknowns last) and vendor-scoped --refresh-account, schema, Claude unique accounts and fallback, Codex multi-account reset credits, auth-needed accounts and legacy cache, local Claude rotation usability, enabled flags, freshness contract, reset placeholder normalization, machine effective percentages and usability, refresh failure reasons, zero-spend refresh, start-windows, small-file fallback, truncated boundary, walls, weekly bucket provenance, experiment announcements, Hammerspoon projection contract, no opaque gray in the renderer, plain output, table output and sorts, reset tiers, expired windows, age alarm, bare JSON default, atomic cache, per-account newest-wins merge, a removed Gemini base profile absent from every surface with the vendor hoisted from what remains, a paused vendor absent from the store and every render path with its collector never run, missing exit 3"
exit 0
