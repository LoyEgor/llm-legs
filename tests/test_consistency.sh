#!/usr/bin/env bash
# Guards docs/shared-invariants.md: values duplicated across independent
# implementations (bash/jq/Lua/prose) must not drift apart. Each check
# re-extracts the live value from every site and asserts they agree with each
# other and with the doc's canonical value. No network, no daemon, no writes.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="docs/shared-invariants.md"
CLAUDEB="$ROOT/bin/claudeb"
STATUSLINE="$ROOT/bin/statusline.sh"
WORKERPICK="$ROOT/bin/worker-pick"
LLMLIMITS="$ROOT/llm-limits.sh"
HAMMER="$ROOT/hammerspoon/llm-limits.lua"

asserts=0
fail() { printf 'FAIL: %s\n  (canonical values live in %s)\n' "$*" "$DOC" >&2; exit 1; }
assert() {
  asserts=$((asserts + 1))
  "$@" || fail "assert $asserts: $*"
}
eq() { [ "$1" = "$2" ] || return 1; }

# Value the doc declares canonical, extracted from its own table so a drifted
# doc is caught too.
doc_has() { grep -Fq -- "$1" "$ROOT/$DOC"; }

# --- Row a: staleness/dim thresholds -----------------------------------------
FIVE=1800; WEEK=21600; FABLE=21600

# doc prose carries all three
assert doc_has '`1800`s'
assert doc_has '`21600`s'

# claudeb account_data jq
cb_five=$(grep -oE 'is_stale\(\.five_hour; [0-9]+\)' "$CLAUDEB" | grep -oE '[0-9]+')
cb_week=$(grep -oE 'is_stale\(\.seven_day; [0-9]+\)' "$CLAUDEB" | grep -oE '[0-9]+')
cb_fable=$(grep -oE 'is_stale\(\.fable; [0-9]+\)' "$CLAUDEB" | grep -oE '[0-9]+')
assert eq "$cb_five" "$FIVE"
assert eq "$cb_week" "$WEEK"
assert eq "$cb_fable" "$FABLE"

# statusline dim logic — anchor on the age comparison, not the arrow rounding term
sl_five=$(grep -oE 'now - h5_as_of\)\) -gt [0-9]+' "$STATUSLINE" | grep -oE '[0-9]+$')
sl_week=$(grep -oE 'now - wk_as_of\)\) -gt [0-9]+' "$STATUSLINE" | grep -oE '[0-9]+$')
sl_fable=$(grep -oE 'now - limits_mtime\)\) -gt [0-9]+' "$STATUSLINE" | grep -oE '[0-9]+$')
assert eq "$sl_five" "$FIVE"
assert eq "$sl_week" "$WEEK"
assert eq "$sl_fable" "$FABLE"

# hammerspoon must stay stale-flag-driven, not hardcode one of these thresholds
assert grep -q 'bucket.stale == true' "$HAMMER"

# --- Row b: keychain service formula -----------------------------------------
# Both sites: shasum -a 256, first 8 chars, "Claude Code-credentials-" prefix.
for site in "$CLAUDEB" "$LLMLIMITS"; do
  assert grep -q 'shasum -a 256' "$site"
  assert grep -q 'substr($1, 1, 8)' "$site"
  assert grep -q 'Claude Code-credentials-' "$site"
done
# claudeb owns the single helper the doc names (subtask 1 consolidation)
assert grep -q '^keychain_service()' "$CLAUDEB"
assert doc_has '`keychain_service`'

# --- Row c: worker-pick cache line format ------------------------------------
# Producer printf and cb prefixes.
assert grep -Fq 'cx%s%s·%s %s·%s·%s' "$WORKERPICK"
assert grep -Eq 'cb_cache="cb~\$' "$WORKERPICK"
assert grep -Eq 'cb_cache="cb@\$' "$WORKERPICK"
assert grep -Fq 'cb_cache="cb~?"' "$WORKERPICK"
# Producer and consumer must name the same cache file.
assert grep -q 'worker-pick.line' "$WORKERPICK"
assert grep -q 'worker-pick.line' "$STATUSLINE"
# Doc records the format.
assert doc_has 'cx%s%s·%s %s·%s·%s'

# --- Row d: weather HTTP classes ---------------------------------------------
# probe_weather_failed's case pattern is the canonical class list.
wf_line=$(grep -E 'case "\$http" in [0-9|[].*return 0' "$CLAUDEB" | head -n1)
[ -n "$wf_line" ] || fail "row d: probe_weather_failed weather case not found"
wf_pat=$(printf '%s' "$wf_line" | sed -E 's/.*case "\$http" in ([^)]*)\).*/\1/')
assert eq "$wf_pat" '000|429|5[0-9][0-9]'

# The oauth_refresh classifier must map every one of those classes to weather
# (never to an auth verdict). 429 has its own weather branch; 5xx/000 share one.
assert grep -Fq 'if [ "$http" = 429 ]; then' "$CLAUDEB"
assert grep -Fq '5[0-9][0-9]$ ]] || [ "$http" = 000 ]; then' "$CLAUDEB"
# and the auth-verdict branch is fenced to 401/403 only.
assert grep -Fq '[ "$http" = 401 ] || [ "$http" = 403 ]; then' "$CLAUDEB"
# None of the three weather tokens may appear on an auth-verdict line.
for tok in '000' '429' '5[0-9][0-9]'; do
  if grep -nE "$tok" "$CLAUDEB" | grep -E 'auth-failed|revoked|mark_auth "\$name" expired' | grep -Fq "$tok"; then
    fail "row d: weather class $tok appears on an auth-verdict line"
  fi
done

printf 'PASS: %s asserts; shared invariants agree across sites (staleness thresholds, keychain formula, worker-pick cache format, weather HTTP classes) and match %s\n' "$asserts" "$DOC"
