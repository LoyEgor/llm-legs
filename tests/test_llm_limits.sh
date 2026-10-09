#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/llm_limits_harness.sh" || exit 1

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
jq -e '.vendors.codex.five_hour.origin == "usage" and (.vendors.codex.five_hour.as_of | type) == "number" and .vendors.codex.five_hour.stale == true and .vendors.codex.stale == true' <<<"$out" >/dev/null || fail "Codex rollout freshness fields mismatch"
jq -e '.vendors.gemini.available == false and .vendors.gemini.status == "no quota snapshot" and .vendors.gemini.last_wall == "2026-07-11T08:00:00Z"' <<<"$out" >/dev/null || fail "Gemini state mismatch"
jq -e . "$CACHE" >/dev/null || fail "cache was not valid JSON"
compgen -G "$CACHE.tmp.*" >/dev/null && fail "atomic-write temporary file remains"

FAST_MODE_PROFILES="$WORK/fast-mode-profiles"
mkdir -p "$FAST_MODE_PROFILES/alpha"
printf 'service_tier = "priority"\n' >"$FAST_MODE_PROFILES/alpha/config.toml"
fast_mode_without_marker=$(/usr/bin/python3 "$ROOT/share/codex_fast_mode.py" "$FAST_MODE_PROFILES" alpha status) \
  || fail "Fast Mode marker-state read failed"
[ "$fast_mode_without_marker" = off ] \
  || fail "profile config enabled worker Fast Mode without its marker"

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

gemini_live=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh) \
  || fail "Gemini refresh collection failed"
jq -e --arg five_reset "$GEMINI_FIVE_RESET" \
  '.vendors.gemini.available == true and .vendors.gemini.source == "agy-print-usage" and
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
printf '%s\n' '{"auth_needed":true,"source":"agy-print-usage","detail":"not signed in"}'
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
printf '%s\n' '{"auth_needed":true,"source":"agy-print-usage","detail":"profile signed out"}'
exit 2
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
printf '%s\n' '{"error":"agy exited with status 1: broken pipe","source":"agy-print-usage"}' >&2
exit 1
EOF
GEMINI_NET_HELPER="$WORK/fake-agy-net"
cat >"$GEMINI_NET_HELPER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"error":"agy exited with status 1: fetch failed: connect ECONNREFUSED 127.0.0.1:52341","source":"agy-print-usage"}' >&2
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
  .vendors.gemini.refresh_error.cause == "agy exited with status 1: broken pipe"' <<<"$crash_json" >/dev/null \
  || fail "a crashed gemini helper (rc 1) collapsed into login-needed or hid its distinct cause"
jq -e '(.vendors.gemini | has("auth_needed") | not) and
  (.vendors.gemini.refresh_error.cause | contains("ECONNREFUSED"))' <<<"$net_json" >/dev/null \
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

# agy-quota.py against a fake agy: print-mode `/usage` yields the quota, and the login line on
# stderr is the logged-out verdict long before the timeout (tests/test_agy_quota.sh owns the rest).
FAKE_AGY="$WORK/fake-agy"
cat >"$FAKE_AGY" <<'EOF'
#!/usr/bin/env bash
if [ "${FAKE_AGY_MODE:-ok}" = "nologin" ]; then
  printf 'Authentication required. Please visit the URL to log in:\n' >&2
  sleep 30
  exit 0
fi
printf '%s\n' '{"conversation_id":"","status":"SUCCESS","response":"","command":{"name":"usage","data":{"description":"shared weekly limit","groups":[{"name":"Gemini Models","description":"","buckets":[{"name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.5,"reset_time":"2099-01-01T00:00:00Z"},{"name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1.0,"reset_time":"2099-01-01T00:00:00Z"}]}]}}}'
EOF
chmod +x "$FAKE_AGY"
agy_out=$(FAKE_AGY_MODE=ok AGY_BIN="$FAKE_AGY" AGY_WORKDIR="$WORK" python3 "$ROOT/agy-quota.py") \
  || fail "print-mode /usage probe failed (rc $?)"
jq -e '(.groups | type) == "array" and (has("auth_needed") | not) and
  .groups[0].displayName == "Gemini Models" and
  ([.groups[0].buckets[] | select(.window == "5h")][0].remainingFraction) == 1.0' <<<"$agy_out" >/dev/null \
  || fail "print-mode /usage probe returned no quota in the cache shape"
agy_rc=0
agy_out=$(FAKE_AGY_MODE=nologin AGY_BIN="$FAKE_AGY" AGY_WORKDIR="$WORK" \
  AGY_QUOTA_TIMEOUT=30 python3 "$ROOT/agy-quota.py") || agy_rc=$?
[ "$agy_rc" -eq 2 ] || fail "login line on stderr: expected exit 2, got $agy_rc"
jq -e '.auth_needed == true' <<<"$agy_out" >/dev/null || fail "login line on stderr: auth_needed missing"

# Regression: statusline-last.json goes stale while cache-rl keeps updating —
# the fresher cache-rl must win even though last.json is present and valid.
touch -t "$(date -r "$(( $(date +%s) - 2 ))" +%Y%m%d%H%M.%S)" "$HOME_FIXTURE/.claude/statusline-last.json"
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

# bash 5.x writes a here-string under 64 KiB into a pipe BEFORE its reader starts; a macOS pipe
# that cannot grow past 16 KiB under load then blocks forever (2026-10-04: the heartbeat hung 11 h).
heartbeat_path=("$SCRIPT" "$ROOT/bin/llm-refresh")
while IFS= read -r sourced; do heartbeat_path+=("$ROOT/share/$sourced"); done < <(
  sed -nE 's#^\. "\$(script_dir|repo_root)/share/([^"]+)"$#\2#p' "$SCRIPT" "$ROOT/bin/llm-refresh" | sort -u)
[ "${#heartbeat_path[@]}" -ge 8 ] || fail "the heartbeat path guard found too few sourced files: ${heartbeat_path[*]}"
if herestring_hits=$(grep -nE '<<<[[:space:]]*"?\$' "${heartbeat_path[@]}"); then
  fail "a here-string feeds data on the heartbeat path; use < <(printf '%s\n' ...): $herestring_hits"
fi
BIG_HOME="$WORK/home-big-rollout"
big_rollout="$BIG_HOME/.codex/sessions/2026/07/12/rollout-big.jsonl"
mkdir -p "${big_rollout%/*}"
for big_i in $(seq 1 180); do
  printf '{"timestamp":"2026-07-12T10:%02d:%02dZ","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":%d,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":20,"window_minutes":10080,"resets_at":%s},"plan_type":"plus"}}}\n' \
    "$((big_i / 60))" "$((big_i % 60))" "$((big_i % 50))" "$((now + 1000))" "$((now + 2000))"
done >"$big_rollout"
[ "$(wc -c <"$big_rollout")" -gt 32768 ] && [ "$(wc -c <"$big_rollout")" -lt 65536 ] \
  || fail "the big rollout fixture left the 16-64 KiB pipe window"
big_out=$(HOME="$BIG_HOME" LLM_LIMITS_CACHE="$WORK/big-cache.json" timeout 60 bash "$SCRIPT" --json) \
  || fail "a 16-64 KiB rollout body did not collect within 60 s"
jq -e '.vendors.codex.five_hour.used_pct == 30' <<<"$big_out" >/dev/null \
  || fail "the newest event of a 16-64 KiB rollout body was not the one collected"
jq -e '.refresh_heartbeat == {last_tick_at:null, limit_s:900, stalled:false}' <<<"$big_out" >/dev/null \
  || fail "a machine with no heartbeat state read as a stalled heartbeat"
touch -t "$(date -r "$((now - 39600))" +%Y%m%d%H%M.%S)" "$WORK/refresh.state"
heartbeat_of() {
  HOME="$BIG_HOME" LLM_LIMITS_CACHE="$WORK/big-cache.json" LLM_LIMITS_REFRESH_STATE="$WORK/refresh.state" \
    LLM_LIMITS_AWAKE_SINCE="$1" bash "$SCRIPT" --json | jq -c '.refresh_heartbeat | .stalled, (.last_tick_at | type)'
}
[ "$(heartbeat_of 0 | tr '\n' ' ')" = 'true "number" ' ] \
  || fail "a heartbeat state 11 h old did not read as a stalled refresh"
[ "$(heartbeat_of "$((now - 60))" | tr '\n' ' ')" = 'false "number" ' ] \
  || fail "a Mac awake one minute read its sleep as a stalled refresh"
EL_BIN="$WORK/elevenlabs-bin"
mkdir -p "$EL_BIN"
cat >"$EL_BIN/python3" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  */elevenlabs_balance.py)
    if [ -e "\$LLM_LIMITS_CACHE.lock" ]; then echo held; else echo free; fi >>"$WORK/elevenlabs-lock"
    [ -n "\${EL_BALANCE:-}" ] || exit 1
    printf '%s\n' "\$EL_BALANCE"; exit 0 ;;
esac
exec "$(command -v python3)" "\$@"
EOF
chmod +x "$EL_BIN/python3"
el_collect() {
  PATH="$EL_BIN:$PATH" HOME="$BIG_HOME" LLM_LIMITS_CACHE="$WORK/big-cache.json" EL_BALANCE="$1" bash "$SCRIPT" --json |
    jq -c '.elevenlabs'
}
[ "$(el_collect '{"as_of":1,"accounts":[{"account":"a"}]}')" = '{"as_of":1,"accounts":[{"account":"a"}]}' ] \
  || fail "a read ElevenLabs balance did not land in the store"
[ "$(el_collect '')" = '{"as_of":1,"accounts":[{"account":"a"}]}' ] \
  || fail "a failed ElevenLabs read dropped the previous reading"
[ "$(tr '\n' ' ' <"$WORK/elevenlabs-lock")" = 'free free ' ] \
  || fail "the ElevenLabs balance was read under the store lock, holding every other writer behind its network calls"
echo "PASS: account order (priority names, profile birth time, unknowns last) and vendor-scoped --refresh-account, schema, Claude unique accounts and fallback, Codex multi-account reset credits, auth-needed accounts and legacy cache, local Claude rotation usability, enabled flags, freshness contract, reset placeholder normalization, machine effective percentages and usability, refresh failure reasons, zero-spend refresh, start-windows, small-file fallback, truncated boundary, walls, weekly bucket provenance, experiment announcements, Hammerspoon projection contract including vendor pin (*_profile=*) vs account pin, one dim tone in the renderer, plain output, table output and sorts, reset tiers, expired windows, age alarm, bare JSON default, atomic cache, per-account newest-wins merge, a removed Gemini base profile absent from every surface with the vendor hoisted from what remains, the same for a removed Codex main (menubar flag, passive collects, table and plain, the vendor stating its removal when nothing named is left, undone by deleting the marker), a paused vendor absent from the store and every render path with its collector never run, the ElevenLabs balance read outside the store lock, missing exit 3"
exit 0
