#!/usr/bin/env bash
set -u

# The suite reads docs/routing-contract.md as the specification: three rules (pool-toggle
# candidacy with a computable daily budget, pin-or-largest-budget selection, skipped only at
# effective 100% or on dead auth, which the output keeps apart) and nothing else may move a decision.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/worker-pick"
FIXTURES="$ROOT/tests/fixtures/worker-pick/scenarios.json"
GOLDEN="$ROOT/tests/fixtures/worker-pick/golden-output.txt"
DECISIONS="$ROOT/tests/fixtures/worker-pick/decisions.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() {
  asserts=$((asserts + 1))
  "$@" || fail "assert $asserts failed: $*"
}
contains() { grep -Fq -- "$2" <<<"$1"; }
# Vendor lines are optional — a vendor the store carries no row for prints none — so a case reads
# the line it means by its prefix rather than by an index the next absent vendor would shift.
# Section ORDER is asserted on its own, by `section_order` in the golden block.
vline() { grep -m1 -- "^$1" <<<"$output"; }
# The table is columns now, so a case asserts VALUES: every helper squeezes the padding away and
# a row reads `budget wk 5h name model·eff [↺ reset] [flags]`, the order the columns print in.
squeeze() { sed 's/  */ /g; s/^ *//; s/ *$//'; }
# One ranked NEXT row. Row 1 is the answer, and `ACCOUNT:` under it is the same value for a brief.
nrow() { grep -m1 -- "^ $1  " <<<"$output" | sed "s/^ $1  *//" | squeeze; }
acct_line() { grep -m1 -- '^ACCOUNT: ' <<<"$output"; }
# Every ranked row in order, for a case about the ORDER rather than about one row.
next_block() { grep -E -- '^ [0-9]+  ' <<<"$output" | squeeze; }
# The vendor labels in the order their sections print.
section_order() { grep -o -- '^[a-z]*:' <<<"$output" | tr -d ':' | tr '\n' ' ' | squeeze; }
# The one-line NEXT of a run that picked nothing: no ranking rows, only the reason.
next_fail() { grep -m1 -- '^NEXT: ' <<<"$output"; }
# Every row of one vendor section as its own line, the label and the continuation indent dropped.
vsection() {
  awk -v head="^$1:" '
    $0 ~ head {inside = 1; sub(head, ""); print; next}
    inside && /^         / {print; next}
    inside {inside = 0}
  ' <<<"$output" | squeeze
}
not_contains() { ! grep -Fq -- "$2" <<<"$1"; }
before() {
  local text=$1 left=$2 right=$3 suffix
  suffix=${text#*"$left"}
  [ "$suffix" != "$text" ] && [[ "$suffix" == *"$right"* ]]
}

HOME_FIXTURE="$WORK/home"
STORE="$WORK/limits.json"
CONFIG="$WORK/worker-model"
TIERS="$WORK/account-tiers"
CACHE="$WORK/cache"
CLAIMS="$WORK/claims"
mkdir -p "$HOME_FIXTURE" "$CACHE" "$CLAIMS"
printf '%s\n' 'session=100' 'worker=20' 'tie-a=100' 'tie-b=100' 'dry=100' 'walled-wk=100' \
  'walled-5h=100' 'off=100' 'dead=100' 'spent=100' 'spent5h=100' 'effective=100' 'raw=100' \
  'expired=100' 'live=100' 'soon=100' 'later=100' >"$TIERS"

# Model and effort come only from the worker-model file, so every case that is not about them
# writes the same defaults back.
write_config() {
  printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
    'gemini_model=pro' 'gemini_effort=high' "$@" >"$CONFIG"
}
write_config

run_env=(TZ=UTC "HOME=$HOME_FIXTURE" "WORKER_PICK_CONFIG_FILE=$CONFIG"
  "WORKER_PICK_TIERS_FILE=$TIERS" "WORKER_PICK_CACHE_DIR=$CACHE" WORKER_PICK_NOW=2000000000
  CLAUDE_LIMITS_ACCOUNT=session "WORKER_CLAIMS_DIR=$CLAIMS")
# Claims are per-run state, and a marker left behind would silently demote an account in every
# later case, so each case that is not about claims starts from an empty store.
clear_claims() { rm -rf "$CLAIMS"; mkdir -p "$CLAIMS"; }
run_store() {
  # Stderr to a file rather than the terminal: a human-facing run carries its notes there, and a
  # suite that let them scroll past could not tell a note that fired from one that did not.
  output=$(env "${run_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" 2>"$WORK/note.err") ||
    fail "worker-pick failed for $1"
}
run_case() {
  jq -c --arg name "$1" '.[$name]' "$FIXTURES" >"$STORE" || fail "fixture $1 missing"
  run_store "$1"
}
run_filter() {
  jq -c --arg name "$1" ".[\$name] | $2" "$FIXTURES" >"$STORE" ||
    fail "fixture $1 transform failed"
  run_store "$1"
}
# `--account` answers a caller: stdout is one bare name, stderr carries anything else.
query() {
  query_out=$(env "${run_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" "$@" 2>"$WORK/query.err")
  query_rc=$?
}
query_case() {
  jq -c --arg name "$1" '.[$name]' "$FIXTURES" >"$STORE" || fail "fixture $1 missing"
  shift
  query "$@"
}

# Unusable data has no fail-safe answer for a caller, and a human-facing run says why.
printf '%s\n' 'worker=gemini' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' 'gemini_profile=work' >"$CONFIG"
printf 'not-json\n' >"$STORE"
run_store malformed
assert contains "$(head -n1 <<<"$output")" 'NEXT: gemini work · pro · high — unavailable (limits parse failed)'
# The fable pick was a line of its own; `--fable` is the query that asks for it now.
assert not_contains "$output" 'SESSION:'
query --account claudeb
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'cannot select a claudeb account' "$WORK/query.err"
write_config

# Rule 2, ordinary work: the largest daily budget wins, and with no reset in this fixture every
# account is paced over the same neutral week, so that is the lowest weekly percentage. `dry` has
# an exhausted fable bucket and still ranks, because fable exhaustion never disqualifies
# ordinary work.
run_case claude_pool
pool_row=$(vsection claude)
assert contains "$(nrow 1)" 'claude/session* opus·high'
assert test "$(acct_line)" = 'ACCOUNT: session'
assert contains "$pool_row" '5% 20% dry opus·high'
assert not_contains "$output" 'SESSION RESERVE'
# The fable bucket is not a column: it decides nothing about ordinary work, and `--fable` is the
# query that asks about it.
assert not_contains "$output" ' fb '
# Rule 1: the session account is an ordinary candidate, so its 0% weekly wins outright.
assert contains "$pool_row" '14.3%/d ×7.0d 0% 0% session* opus·high'
assert not_contains "$(nrow 1)" 'claude/dry'
# Rule 3: only a wall skips an account, and both wall shapes are marked as such.
assert contains "$pool_row" '0.0%/d ×7.0d 100% 0% walled-wk opus·high WALLED'
assert contains "$pool_row" '13.6%/d ×7.0d 5% 100% walled-5h opus·high WALLED'
# Dead auth is not a wall (contract rule 3 reads them as two states): the row names the login it
# needs and never `WALLED`, which would send Egor after a limit nobody spent.
assert contains "$pool_row" '14.3%/d ×7.0d 0% 0% dead opus·high login needed'
assert not_contains "$pool_row" 'dead opus·high WALLED'
# A pool toggle that is off keeps the account visible: an account that silently vanished from
# the ranking is indistinguishable from a collector bug.
assert contains "$pool_row" '14.3%/d ×7.0d 0% 0% off opus·high off'
# Bands are a render order; within one, accounts keep selection order (shared-invariants g),
# so a limits file that lists tie-a first still renders the better-ranked tie-b ahead of it.
assert before "$pool_row" ' session* ' ' dry '
assert before "$pool_row" ' dry ' ' tie-a '
assert before "$pool_row" ' tie-a ' ' tie-b '
assert before "$pool_row" ' tie-b ' ' dead '
# The deferral is the first rank key even among rows nothing can select, so the 5h-walled account
# trails the weekly-walled one whatever their budgets say.
assert before "$pool_row" ' dead ' ' walled-wk '
assert before "$pool_row" ' walled-wk ' ' walled-5h '
assert before "$pool_row" ' walled-5h ' ' off '
# Nothing below a wall may block, and no deleted rung may leave a trace.
for gone in FLOOR HEADROOM runway 'R8' 'pre-reset cap' 'least-burnt' POLICY 'Fable-reserved' \
            'Fable-gap' 'STALE-REFRESH' FRESH TIGHT WARN; do
  assert not_contains "$output" "$gone"
done

# Equal budgets break by name, and nothing else — asserted through `--exclude`, which is how a
# caller that just watched an account wall asks for the next one.
query --account claudeb
assert test "$query_rc" -eq 0
assert test "$query_out" = session
assert test ! -s "$WORK/query.err"
query --account claudeb --exclude session
assert test "$query_out" = dry
query --account claudeb --exclude session,dry
assert test "$query_out" = tie-a
query --account claudeb --exclude session,dry,tie-a
assert test "$query_out" = tie-b
query --account claudeb --exclude session,dry,tie-a,tie-b
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'no selectable claudeb account' "$WORK/query.err"

# The five-hour reading is no longer a tiebreak, so an account nobody measured a five-hour window
# for no longer loses to one that has a 0% reading: equal budgets order by name.
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"tie-a",enabled:true,weekly:{used_pct:20},fable:{used_pct:0}},
  {account:"tie-b",enabled:true,weekly:{used_pct:20},five_hour:{used_pct:0},fable:{used_pct:0}}]'
assert contains "$(nrow 1)" 'claude/tie-a opus·high'
assert test "$(acct_line)" = 'ACCOUNT: tie-a'
assert before "$(vsection claude)" ' 20% ? tie-a ' ' tie-b '

# The budget is a pace, not a level: at the same percentage the account whose week resets sooner
# may spend faster, and that is the whole difference between this metric and a bare percentage.
run_case reset
assert contains "$(nrow 1)" 'claude/soon opus·high'
assert test "$(acct_line)" = 'ACCOUNT: soon'
assert before "$(vsection claude)" ' soon ' ' later '
query --account claudeb
assert test "$query_out" = soon
query --account claudeb --exclude soon
assert test "$query_out" = later
# Same reset, same answer as before the reset mattered: the name breaks the tie.
run_filter reset '.vendors.claude.accounts |= map(.weekly.resets_at = 2000432000)'
assert contains "$(nrow 1)" 'claude/later opus·high'

# Claims: an account a caller took minutes ago is already carrying a run this data has not seen,
# so it ranks behind every unclaimed candidate — and no further, since a claim is a rank key and
# never a wall.
clear_claims
run_case claude_pool
query --account claudeb --claim
assert test "$query_rc" -eq 0
assert test "$query_out" = session
assert test -f "$CLAIMS/claudeb/session"
assert test "$(find "$CLAIMS" -type f | wc -l | tr -d ' ')" -eq 1
query --account claudeb
assert test "$query_out" = dry
query --account claudeb --exclude dry,tie-a,tie-b
assert test "$query_rc" -eq 0
assert test "$query_out" = session
# The table reads claims and never writes one: it reports a decision instead of taking it.
run_case claude_pool
assert contains "$(nrow 1)" 'claude/dry opus·high'
assert test "$(acct_line)" = 'ACCOUNT: dry'
assert test "$(find "$CLAIMS" -type f | wc -l | tr -d ' ')" -eq 1
# One vendor's claims say nothing about another's.
mkdir -p "$CLAIMS/codex"
touch "$CLAIMS/codex/dry"
query --account claudeb --exclude session
assert test "$query_out" = dry
# A claim older than the TTL is an ageing marker nobody renewed, not a live run.
touch -t 200001010000 "$CLAIMS/claudeb/session"
query --account claudeb
assert test "$query_out" = session
# A query that answers nothing claims nothing.
clear_claims
query --account claudeb --exclude session,dry,tie-a,tie-b --claim
assert test "$query_rc" -eq 3
assert test -z "$(find "$CLAIMS" -type f -print -quit)"
clear_claims
run_case claude_pool

# The five-hour deferral, the one soft rule in the contract: an account this deep into its
# five-hour window walls after the first task, so weekly headroom does not make it the answer.
# The `5h!` tag is what keeps that visible in the line the answer is read from.
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"hot",enabled:true,five_hour:{used_pct:85},weekly:{used_pct:30}},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:50}}]'
defer_row=$(vsection claude)
assert contains "$(nrow 1)" 'claude/cool opus·high'
assert test "$(acct_line)" = 'ACCOUNT: cool'
assert contains "$defer_row" '10.0%/d ×7.0d 30% 85% hot opus·high 5h!'
assert not_contains "$defer_row" 'cool opus·high 5h!'
assert before "$defer_row" ' cool ' ' hot '
query --account claudeb
assert test "$query_out" = cool
# Below 100% nothing is a hard wall, so a deferred account is still the answer once it is the
# only candidate left.
query --account claudeb --exclude cool
assert test "$query_rc" -eq 0
assert test "$query_out" = hot
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"hot",enabled:true,five_hour:{used_pct:85},weekly:{used_pct:30}},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:100}}]'
assert contains "$(nrow 1)" 'claude/hot opus·high'
assert test "$(acct_line)" = 'ACCOUNT: hot'
assert contains "$(vsection claude)" '10.0%/d ×7.0d 30% 85% hot opus·high 5h!'
# One threshold, and it is a threshold: 80 defers, 79 does not.
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"hot",enabled:true,five_hour:{used_pct:79},weekly:{used_pct:30}},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(nrow 1)" 'claude/hot opus·high'
assert test "$(acct_line)" = 'ACCOUNT: hot'
assert not_contains "$output" '5h!'
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"hot",enabled:true,five_hour:{used_pct:80},weekly:{used_pct:30}},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(nrow 1)" 'claude/cool opus·high'
assert test "$(acct_line)" = 'ACCOUNT: cool'
assert contains "$(vsection claude)" '10.0%/d ×7.0d 30% 80% hot opus·high 5h!'
# A five-hour window nobody measured is no evidence of one, so it never defers — otherwise the
# tiebreak coalescing (absent reads as 100) would quietly demote a perfectly fresh account.
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"nofive",enabled:true,weekly:{used_pct:30}},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(nrow 1)" 'claude/nofive opus·high'
assert test "$(acct_line)" = 'ACCOUNT: nofive'
assert not_contains "$output" '5h!'
# Every vendor ranks by the same keys, so the deferral and its tag reach all three.
run_filter codex_plain '.vendors.codex.accounts = [
  {account:"hot",five_hour:{used_pct:85},weekly:{used_pct:20}},
  {account:"cool",five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(nrow 1)" 'codex/cool sol·high'
assert contains "$(vsection codex)" '11.4%/d ×7.0d 20% 85% hot sol·high 5h!'
assert before "$(vsection codex)" ' cool ' ' hot '
run_case claude_pool

# Only a task that asks for Fable spends the fable bucket, and it is ranked by the same rules
# against that bucket's own percentage and reset.
query --account claudeb --fable
assert test "$query_rc" -eq 0
assert test "$query_out" = session
# The fable answer is the query and nothing else: no render carries a fable column or line.
assert not_contains "$output" 'SESSION:'
query --account claudeb --fable --exclude session
assert test "$query_out" = tie-a
query --account claudeb --fable --exclude session,tie-a
assert test "$query_out" = tie-b
# The fable bucket is judged on its own: `dry` is an ordinary candidate and no fable answer.
query --account claudeb --fable --exclude session,tie-a,tie-b
assert test "$query_rc" -eq 3
assert grep -q 'no fable-capable account with a fable bucket below 100%' "$WORK/query.err"
assert test 0 -eq "$(grep -c 'score' "$WORK/query.err")"
# The fable bucket is paced by the reset it carries, not the weekly one: equal fable percentages
# with equal weeks still order by which fable window rolls over sooner.
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"fb-late",enabled:true,weekly:{used_pct:0},fable:{used_pct:50,resets_at:2000432000}},
  {account:"fb-soon",enabled:true,weekly:{used_pct:0},fable:{used_pct:50,resets_at:2000010800}}]'
query --account claudeb --fable
assert test "$query_rc" -eq 0
assert test "$query_out" = fb-soon
query --account claudeb --fable --exclude fb-soon
assert test "$query_out" = fb-late
run_case claude_pool
query --account codex --fable
assert test "$query_rc" -eq 2
assert grep -q 'only means something with --account claudeb' "$WORK/query.err"

# The session account is answered like any other, with no note and no marker of its own.
run_case reserve_only
assert contains "$(nrow 1)" 'claude/session* opus·high'
assert test "$(acct_line)" = 'ACCOUNT: session'
assert not_contains "$output" 'SESSION RESERVE'
assert contains "$(vsection claude)" '12.9%/d ×7.0d 10% 5% session* opus·high'
assert not_contains "$(vsection claude)" 'RESERVE'
query --account claudeb
assert test "$query_rc" -eq 0
assert test "$query_out" = session
assert test ! -s "$WORK/query.err"
# It still needs its own pool toggle; with it off there is no candidate at all.
run_filter reserve_only '.vendors.claude.accounts |= map(
  if .account == "session" then .enabled = false else . end)'
assert test "$(next_fail)" = 'NEXT: ALL WALLED, ask Egor'
query --account claudeb
assert test "$query_rc" -eq 3
assert test -z "$query_out"

# A pin overrides the pool toggle, and the session account is no exception to it either way.
write_config 'claudeb_profile=off'
run_case claude_pool
assert contains "$(nrow 1)" 'claude/off opus·high PINNED'
assert test "$(acct_line)" = 'ACCOUNT: off'
assert contains "$(vsection claude)" '14.3%/d ×7.0d 0% 0% off opus·high PINNED off'
write_config 'claudeb_profile=session'
run_case claude_pool
assert contains "$(nrow 1)" 'claude/session* opus·high PINNED'
assert test "$(acct_line)" = 'ACCOUNT: session'
assert not_contains "$output" 'SESSION RESERVE'
assert not_contains "$(vline 'claude:')" 'RESERVE'
query --account claudeb
assert test "$query_out" = session
assert test ! -s "$WORK/query.err"
write_config 'claudeb_profile=off'
run_case claude_pool
query --account claudeb --fable
assert test "$query_out" = off
write_config 'claudeb_profile=session'
run_case claude_pool
# ... but a pin is not a way around `--exclude`: both read the same candidate set.
query --account claudeb --exclude session
assert test "$query_out" = dry

# The pin is the one override ABOVE the pool, so the whole shape an out-of-pool account has in the
# store — `enabled: false`, `blocked: true`, and the toggle folded into the usable flag by any
# cache written before that fold was undone — is answered rather than refused.
write_config 'claudeb_profile=tie-a'
run_filter claude_pool '.vendors.claude.accounts |= map(
  if .account == "tie-a" then .enabled = false | .blocked = true |
    .rotation = {usable:{general:false,fable:false}} else . end)'
assert contains "$(nrow 1)" 'claude/tie-a opus·high PINNED'
assert test "$(acct_line)" = 'ACCOUNT: tie-a'
assert contains "$(vsection claude)" '11.4%/d ×7.0d 20% 30% tie-a opus·high PINNED blocked off'
query --account claudeb
assert test "$query_out" = tie-a
# Without the pin the same account is no candidate at all: the toggle is the wall for everyone else.
write_config
run_filter claude_pool '.vendors.claude.accounts |= map(
  if .account == "tie-a" then .enabled = false | .blocked = true |
    .rotation = {usable:{general:false,fable:false}} else . end)'
query --account claudeb
assert test "$query_out" != tie-a

# A pin that cannot serve lapses loudly, naming the reason and the account that took over.
lapse_case() {
  write_config "claudeb_profile=$1"
  run_filter claude_pool "$2"
  # The lapse leads the vendor section: the pin belongs to that vendor, and a pool pick printed
  # without it reads as the pin having been honoured.
  assert contains "$(vsection claude)" "pin $1 $3 → $4"
  assert contains "$(vline 'claude:')" "claude:  pin $1 $3 → $4"
}
lapse_case ghost '.' absent session
lapse_case dead '.' 'auth unavailable' session
lapse_case walled-wk '.' exhausted session
lapse_case tie-a '.vendors.claude.accounts |= map(
  if .account == "tie-a" then del(.weekly, .five_hour) else . end)' 'no quota data' session
write_config 'claudeb_profile=dry'
run_case claude_pool
query --account claudeb --exclude dry
assert test "$query_out" = session
query --account claudeb --exclude dry,tie-b,tie-a,session
assert test "$query_rc" -eq 3
assert grep -q 'pin dry excluded → no selectable account' "$WORK/query.err"
write_config

# A wall ENDS the pin rather than pausing it: Egor pins an account to spend it, and one that is
# spent is not one he wants back when the window rolls over (Egor, 2026-08-09). Every other lapse
# is a condition that passes on its own, so those leave the pin exactly where he put it.
pinned_now() { sed -n 's/^claudeb_profile=//p' "$CONFIG"; }
cleared_case() {
  write_config "$1=$2"
  run_filter "${4:-claude_pool}" "${5:-.}"
  assert test -z "$(sed -n "s/^$1=//p" "$CONFIG")"
  assert grep -q "pin $2 hit its wall — cleared" "$WORK/note.err"
  # The run that clears still says what it did with THIS query: the pin was live when it was read.
  assert contains "$output" "pin $2 exhausted → $3"
}
kept_case() {
  write_config "claudeb_profile=$1"
  run_filter claude_pool "$2"
  assert test "$(pinned_now)" = "$1"
  assert test ! -s "$WORK/note.err"
}
cleared_case claudeb_profile walled-wk session
cleared_case claudeb_profile walled-5h session
kept_case dead '.'
kept_case ghost '.'
kept_case tie-a '.vendors.claude.accounts |= map(
  if .account == "tie-a" then del(.weekly, .five_hour) else . end)'
# A wall that was ALREADY standing when the pin was placed is one Egor pinned THROUGH — he wants
# the account for the window AFTER it — so the horizon the vendor CLI recorded beside the pin keeps
# it standing, loudly lapsed for this query but still in the file.
write_config 'claudeb_profile=walled-wk' 'claudeb_profile_wall=2000003600'
run_case claude_pool
assert test "$(pinned_now)" = walled-wk
assert test ! -s "$WORK/note.err"
assert contains "$output" 'pin walled-wk exhausted → session'
# Past that horizon the wall standing is a NEW one, which ends the pin as any wall does — and the
# companion leaves with it rather than outliving the pin it belonged to.
write_config 'claudeb_profile=walled-wk' 'claudeb_profile_wall=1999999999'
run_case claude_pool
assert test -z "$(pinned_now)"
assert test -z "$(sed -n 's/^claudeb_profile_wall=//p' "$CONFIG")"
assert grep -q 'pin walled-wk hit its wall — cleared' "$WORK/note.err"
# Stale data clears nothing: the wall it reports may have reset hours ago, and a pin is not
# something to drop on a reading this run itself calls STALE.
write_config 'claudeb_profile=walled-wk'
run_filter claude_pool '.fetched_at = 1999990000'
assert contains "$output" 'DATA: STALE'
assert test "$(pinned_now)" = walled-wk
assert test ! -s "$WORK/note.err"
# Every vendor, one rule: the pin key is the only difference.
cleared_case codex_profile main plain codex_plain '.vendors.codex.accounts = [
  {account:"plain",five_hour:{used_pct:20},weekly:{used_pct:20}},
  {account:"main",five_hour:{used_pct:100},weekly:{used_pct:20}}]'
write_config

# Rule 3 on the vendor that reports one bucket: 91% is not a wall, so it still routes.
run_case gemini_high
assert contains "$(nrow 1)" 'gemini/main pro·high'
assert test "$(acct_line)" = 'ACCOUNT: main'
assert contains "$(vsection gemini)" '40% 91% main pro·high 5h!'
assert not_contains "$(vsection gemini)" WALLED
run_filter gemini_high '.vendors.gemini.five_hour.used_pct = 100'
assert contains "$(vsection gemini)" '40% 100% main pro·high WALLED'
assert not_contains "$output" 'ACCOUNT: main'
# Gemini is the only pool member here, so its wall is the whole pool's wall.
assert test "$(next_fail)" = 'NEXT: ALL WALLED, ask Egor'

# Gemini candidacy: group match, the pool toggle at account and vendor level, login needed,
# weekly-first ranking, and `main` only as a late tiebreak.
run_case gemini_wrong_group
assert test "$(vsection gemini)" = 'no Gemini Models quota data'
assert not_contains "$output" 'ACCOUNT: main'
run_filter gemini_fresh '.vendors.gemini.group = "Google GEMINI quota"'
assert contains "$(nrow 1)" 'gemini/main pro·high'
assert test "$(acct_line)" = 'ACCOUNT: main'
run_filter gemini_fresh '.vendors.gemini.enabled = false'
assert contains "$(vsection gemini)" '35% 15% main pro·high off'
assert not_contains "$output" 'ACCOUNT: main'
run_filter gemini_fresh '.vendors.gemini = {
  available:false,auth_needed:true,status:"login needed",source:"agy-local-rpc"}'
assert test "$(vsection gemini)" = 'login needed'
run_filter gemini_fresh '.vendors.gemini = {available:true,accounts:[
  {account:"main",group:"Gemini Models",five_hour:{used_pct:10},weekly:{used_pct:10}},
  {account:"work",group:"Gemini Models",five_hour:{used_pct:40},weekly:{used_pct:40}}]}'
assert contains "$(nrow 1)" 'gemini/main pro·high'
assert test "$(acct_line)" = 'ACCOUNT: main'
# `main` is no longer a ranking key on any vendor, so equal budgets order by name alone.
run_filter gemini_fresh '.vendors.gemini = {available:true,accounts:[
  {account:"main",group:"Gemini Models",five_hour:{used_pct:10},weekly:{used_pct:10}},
  {account:"work",group:"Gemini Models",five_hour:{used_pct:10},weekly:{used_pct:10}}]}'
assert contains "$(nrow 1)" 'gemini/main pro·high'
assert test "$(acct_line)" = 'ACCOUNT: main'
# ... and a nearer weekly reset outranks the name, because the budget it feeds is larger.
run_filter gemini_fresh '.vendors.gemini = {available:true,accounts:[
  {account:"main",group:"Gemini Models",weekly:{used_pct:10,resets_at:2000432000}},
  {account:"work",group:"Gemini Models",weekly:{used_pct:10,resets_at:2000010800}}]}'
assert contains "$(nrow 1)" 'gemini/work pro·high'
assert test "$(acct_line)" = 'ACCOUNT: work'
# The base profile is deletable, so a roster without it routes on the accounts it does have and
# never falls back to the name that is gone.
run_filter gemini_fresh '.vendors.gemini = {available:true,current_account:"com",accounts:[
  {account:"com",group:"Gemini Models",is_current:true,five_hour:{used_pct:40},weekly:{used_pct:40}},
  {account:"work",group:"Gemini Models",five_hour:{used_pct:10},weekly:{used_pct:10}}]}'
assert contains "$(nrow 1)" 'gemini/work pro·high'
assert test "$(acct_line)" = 'ACCOUNT: work'
assert not_contains "$(vsection gemini)" main
run_filter gemini_fresh '.vendors.gemini = {available:true,current_account:"com",accounts:[
  {account:"com",group:"Gemini Models",is_current:true,five_hour:{used_pct:100},weekly:{used_pct:40}}]}'
assert contains "$(vsection gemini)" '40% 100% com pro·high WALLED'
assert not_contains "$output" 'ACCOUNT: main'
write_config 'gemini_profile=work'
run_filter gemini_fresh '.vendors.gemini = {available:true,accounts:[
  {account:"main",group:"Gemini Models",five_hour:{used_pct:20},weekly:{used_pct:20}},
  {account:"work",group:"Gemini Models",auth_needed:true}]}'
assert contains "$(vsection gemini)" 'pin work auth unavailable → main'
write_config

# Codex candidacy: budget-first ranking, credits and tiers display-only,
# the pool toggle, and login parity with Gemini.
run_case codex_credit
assert contains "$(nrow 1)" 'codex/plain sol·high'
assert contains "$(vsection codex)" '48% 48% plain sol·high'
assert contains "$(vsection codex)" '48% 48% with-credit sol·high'
# The reset consumable is the menu action that spends it, not a routing input: no row carries it.
assert not_contains "$output" '↻'
query_case codex_credit --account codex
assert test "$query_out" = plain
query_case codex_credit --account codex --exclude plain
assert test "$query_out" = with-credit
query_case codex_credit --account codex --exclude plain,with-credit
assert test "$query_rc" -eq 3
assert grep -q 'no selectable codex account' "$WORK/query.err"
run_filter codex_plain '.vendors.codex.accounts = [
  {account:"main",five_hour:{used_pct:20},weekly:{used_pct:20}},
  {account:"zeta",five_hour:{used_pct:20},weekly:{used_pct:20}}]'
assert contains "$(nrow 1)" 'codex/main sol·high'
assert before "$(vsection codex)" ' main ' ' zeta '
# An emptied pool is a switch Egor flipped, never a limit (rule 4), so the line says which of the
# two it is — and `worker-run` reads that same wording to report UNAVAILABLE over a usage limit.
run_filter codex_plain '.vendors.codex.accounts |= map(.enabled = false)'
assert contains "$(next_fail)" 'codex every account is out of the worker pool'
assert not_contains "$output" WALLED
query --account codex
assert test "$query_rc" -eq 3
assert grep -q 'every codex account is out of the worker pool' "$WORK/query.err"
assert contains "$(vsection codex)" '48% 48% plain sol·high off'
run_filter codex_plain '.vendors.codex = {available:true,accounts:[
  {account:"main",auth_needed:true,status:"login needed"}]}'
assert test "$(vsection codex)" = 'login needed'
assert not_contains "$output" 'no authenticated quota data'
run_filter codex_plain '.vendors.codex = {available:true,five_hour:{used_pct:12},weekly:{used_pct:34}}'
assert contains "$(vsection codex)" '34% 12% main sol·high'
write_config 'codex_profile=main'
run_filter codex_plain '.vendors.codex.accounts = [
  {account:"plain",five_hour:{used_pct:20},weekly:{used_pct:20}},
  {account:"main",enabled:false,five_hour:{used_pct:40},weekly:{used_pct:40}}]'
assert contains "$(nrow 1)" 'codex/main sol·high PINNED'
assert contains "$(vsection codex)" '40% 40% main sol·high PINNED off'
run_filter codex_plain '.vendors.codex.accounts = [
  {account:"plain",five_hour:{used_pct:20},weekly:{used_pct:20}},
  {account:"main",five_hour:{used_pct:100},weekly:{used_pct:20}}]'
assert contains "$(vsection codex)" 'pin main exhausted → plain'
write_config

# Grok is the fourth vendor and reads the same three rules, with one bucket and one auth softening:
# weekly is all it measures, so no five-hour deferral applies, and an `expired` access token is one
# the CLI refreshes itself — a candidate that merely ranks behind a signed-in one.
grok_case() {
  run_filter golden ".vendors.grok = $1"
}
grok_query() {
  jq -c --arg name golden --argjson grok "$1" '.[$name] | .vendors.grok = $grok' "$FIXTURES" \
    >"$STORE" || fail 'grok fixture transform failed'
  shift
  query "$@"
}
GROK_PAIR='{available:true,accounts:[
  {account:"supergrok",enabled:true,weekly:{used_pct:40},auth:{status:"ok"}},
  {account:"spare",enabled:true,weekly:{used_pct:10},auth:{status:"ok"}}]}'
GROK_PAIR_JSON='{"available":true,"accounts":[
  {"account":"supergrok","enabled":true,"weekly":{"used_pct":40},"auth":{"status":"ok"}},
  {"account":"spare","enabled":true,"weekly":{"used_pct":10},"auth":{"status":"ok"}}]}'
# A store with no grok row at all is the state of every machine before the collector lands: the
# vendor is simply absent from the render, never a wall and never a failed lookup.
run_case golden
assert not_contains "$output" grok
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 11
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi'
query_case golden --account grok
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'no selectable grok account (no quota data)' "$WORK/query.err"

grok_case "$GROK_PAIR"
assert contains "$(nrow 1)" 'grok/spare grok·high'
assert contains "$(vsection grok)" '10% – spare grok·high'
assert contains "$(vsection grok)" '40% – supergrok grok·high'
assert contains "$(section_order)" 'grok claude'
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 14
# The cache line keeps its field order and gains a fourth field; `grok_model=auto` is a knob value,
# not a missing one, so it is printed as it stands and resolved by worker-run.
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr✓spare·auto·hi'
write_config 'grok_model=grok-4.5' 'grok_effort=medium'
grok_case "$GROK_PAIR"
assert contains "$(nrow 1)" 'grok/spare grok·med'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr✓spare·grok-4.5·med'
write_config 'grok_model=grok-4.6' 'grok_effort=xhigh'
grok_case "$GROK_PAIR"
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr✓spare·grok-4.6·xh'
write_config
# Auto orders vendors by the daily budget of the account each one selected, so grok leads here on
# its 10% week and codex trails on its 48% one — the old fixed claudeb→codex→gemini→grok order is
# gone, and no vendor has a promotion rule of its own.
next_line=$(next_block)
assert before "$next_line" 'grok/spare' 'claude/session'
assert before "$next_line" 'claude/session' 'gemini/main'
assert before "$next_line" 'gemini/main' 'codex/main'
# A vendor with nothing selectable has no budget to compare and takes the tail.
run_filter golden ".vendors.grok = $GROK_PAIR
  | .vendors.codex = {available:true,accounts:[{account:\"main\"}]}
  | .vendors.gemini = {available:true,group:\"Gemini Models\"}
  | .vendors.claude.accounts |= map(.enabled = false)"
# Nothing measured codex or gemini here, so neither may speak of a wall.
assert contains "$(next_block)" 'grok/spare grok·high'
assert test "$(grep -c -- '^ [0-9]  ' <<<"$output")" -eq 1
# A vendor that answers nothing says so in its own section, never as a row of the ranking: an
# emptied pool is per-account, so its rows stay and carry the switch.
assert contains "$(vsection claude)" '20% 20% session* opus·high off'
assert test "$(vsection codex)" = '- ? ? main sol·high'
assert test "$(vsection gemini)" = '- ? ? main pro·high'
# The order follows the numbers, not the vendor: the same store with codex barely touched puts
# codex at the head and grok behind claudeb.
run_filter golden ".vendors.grok = $GROK_PAIR
  | .vendors.codex.accounts = [{account:\"main\",five_hour:{used_pct:2},weekly:{used_pct:2}}]
  | .vendors.grok.accounts = [{account:\"spare\",enabled:true,weekly:{used_pct:30}}]"
next_line=$(next_block)
assert contains "$(nrow 1)" 'codex/main sol·high'
assert before "$next_line" 'codex/main' 'claude/session'
assert before "$next_line" 'claude/session' 'gemini/main'
assert before "$next_line" 'gemini/main' 'grok/spare'
# A nearer reset moves a vendor up the line for the same reason it moves an account up a pool.
run_filter golden ".vendors.grok = $GROK_PAIR
  | .vendors.gemini.weekly.resets_at = 2000010800"
next_line=$(next_block)
assert contains "$(nrow 1)" 'gemini/main pro·high'
assert test "$(acct_line)" = 'ACCOUNT: main'
assert before "$next_line" 'gemini/main' 'grok/spare'
# The pin is the top override of worker routing, so in auto the vendor a usable pin answered leads
# the line even where an unpinned vendor holds the larger budget.
AUTO_PIN_STORE=".vendors.grok = $GROK_PAIR
  | .vendors.codex.accounts = [{account:\"main\",five_hour:{used_pct:2},weekly:{used_pct:2}}]"
write_config 'claudeb_profile=session'
run_filter golden "$AUTO_PIN_STORE"
next_line=$(next_block)
assert contains "$(nrow 1)" 'claude/session* opus·high PINNED'
assert test "$(acct_line)" = 'ACCOUNT: session'
assert before "$next_line" 'claude/session' 'codex/main'
assert before "$next_line" 'codex/main' 'grok/spare'
assert before "$next_line" 'grok/spare' 'gemini/main'
# Pinned vendors rank among themselves on the same budget the unpinned ones are ranked on, so the
# larger-budget codex still trails both pins.
write_config 'claudeb_profile=session' 'grok_profile=supergrok'
run_filter golden "$AUTO_PIN_STORE"
next_line=$(next_block)
assert before "$next_line" 'claude/session' 'grok/supergrok'
assert before "$next_line" 'grok/supergrok' 'codex/main'
assert before "$next_line" 'codex/main' 'gemini/main'
# A pin that lapsed selected nothing, so its vendor is back to competing on budget like any other.
write_config 'claudeb_profile=walled-wk'
run_filter golden "$AUTO_PIN_STORE
  | .vendors.claude.accounts += [{account:\"walled-wk\",enabled:true,weekly:{used_pct:100}}]"
next_line=$(next_block)
# The lapse is loud in the vendor section the pin belongs to, above the rows it did not choose.
assert contains "$(vsection claude)" 'pin walled-wk exhausted → session'
assert before "$next_line" 'codex/main' 'grok/spare'
assert before "$next_line" 'grok/spare' 'claude/session'
assert before "$next_line" 'claude/session' 'gemini/main'
# Reviewers and chat never see the pin, so it moves neither their answer nor anything else: the
# pinned account stands in those queries as an ordinary candidate.
write_config 'claudeb_profile=worker'
query_case golden --account claudeb
assert test "$query_out" = worker
query --account claudeb --role reviewers
assert test "$query_rc" -eq 0
assert test "$query_out" = session
query --account claudeb --role chat
assert test "$query_rc" -eq 0
assert test "$query_out" = session
write_config
# `worker=grok` is a mode arm like `worker=gemini`: the vendor leads the line whatever the pool says.
printf '%s\n' 'worker=grok' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"
grok_case "$GROK_PAIR"
assert contains "$(nrow 1)" 'grok/spare grok·high'
assert before "$(next_block)" 'grok/spare' 'claude/session'
write_config

# Rule 2 for a vendor with one bucket: largest weekly budget, then name — and `--exclude` walks
# that same order until nothing is left.
grok_case '{available:true,accounts:[
  {account:"main",enabled:true,weekly:{used_pct:20}},
  {account:"zeta",enabled:true,weekly:{used_pct:20}}]}'
assert contains "$(next_block)" 'grok/main grok·high'
assert before "$(vsection grok)" ' main ' ' zeta '
grok_query "$GROK_PAIR_JSON" --account grok
assert test "$query_rc" -eq 0
assert test "$query_out" = spare
query --account grok --exclude spare
assert test "$query_out" = supergrok
query --account grok --exclude spare,supergrok
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'no selectable grok account' "$WORK/query.err"
# The claudeb side of the same store is answered independently of grok, session account included.
query --account claudeb
assert test "$query_out" = session
assert test ! -s "$WORK/query.err"
query --account claudeb --exclude session,worker2
assert test "$query_out" = worker

# Auth: `expired` is refreshable and stays a candidate behind every signed-in account, however
# much cheaper it is; `needs_login` has no refresh token and is dead auth.
grok_case '{available:true,accounts:[
  {account:"fresh",enabled:true,weekly:{used_pct:40},auth:{status:"ok"}},
  {account:"stale",enabled:true,weekly:{used_pct:10},auth:{status:"expired"}}]}'
assert contains "$(next_block)" 'grok/fresh grok·high'
assert contains "$(vsection grok)" '10% – stale grok·high auth expired'
# The tags render WALLED before the auth words, so that is the string that says `expired` was not
# read as a wall.
assert not_contains "$(vsection grok)" 'stale grok·high WALLED'
assert before "$(vsection grok)" ' fresh ' ' stale '
grok_query '{"available":true,"accounts":[
  {"account":"fresh","enabled":true,"weekly":{"used_pct":40},"auth":{"status":"ok"}},
  {"account":"stale","enabled":true,"weekly":{"used_pct":10},"auth":{"status":"expired"}}]}' \
  --account grok --exclude fresh
assert test "$query_rc" -eq 0
assert test "$query_out" = stale
grok_case '{available:true,accounts:[
  {account:"gone",enabled:true,weekly:{used_pct:10},auth:{status:"needs_login"}},
  {account:"fresh",enabled:true,weekly:{used_pct:40},auth:{status:"ok"}}]}'
assert contains "$(next_block)" 'grok/fresh grok·high'
assert contains "$(vsection grok)" '10% – gone grok·high login needed'
grok_case '{available:true,accounts:[
  {account:"gone",enabled:true,weekly:{used_pct:10},auth:{status:"needs_login"}}]}'
assert test "$(vsection grok)" = 'login needed'
assert not_contains "$(next_block)" 'grok/gone'
# Rule 3: effective 100% in the one bucket it has is grok's whole wall, and there is no five-hour
# reading to defer on — 85% ranks by spend like any other number.
grok_case '{available:true,accounts:[
  {account:"spent",enabled:true,weekly:{used_pct:100}},
  {account:"hot",enabled:true,weekly:{used_pct:85}}]}'
assert contains "$(next_block)" 'grok/hot grok·high'
assert contains "$(vsection grok)" '100% – spent grok·high WALLED'
assert not_contains "$output" '5h!'
# An account out of the pool is out of the answer, and a vendor whose whole pool is off says so
# rather than reporting a limit.
grok_case '{available:true,accounts:[
  {account:"supergrok",enabled:false,weekly:{used_pct:40}},
  {account:"spare",enabled:false,weekly:{used_pct:10}}]}'
assert not_contains "$(next_block)" 'grok/'
assert contains "$(vsection grok)" '10% – spare grok·high off'
# Reset credits are display-only on grok exactly as on codex, and a count too old to act on reads
# as none rather than as runway nobody measured.
grok_case '{available:true,accounts:[
  {account:"plain",enabled:true,weekly:{used_pct:48},auth:{status:"ok"}},
  {account:"with-credit",enabled:true,weekly:{used_pct:48},auth:{status:"ok"},reset_credits:1},
  {account:"gone-stale",enabled:true,weekly:{used_pct:48},auth:{status:"ok"},
   reset_credits:3,reset_credits_stale:true}]}'
assert contains "$(vsection grok)" '48% – plain grok·high'
assert contains "$(vsection grok)" '48% – with-credit grok·high'
assert contains "$(vsection grok)" '48% – gone-stale grok·high'
assert contains "$(next_block)" 'grok/gone-stale grok·high'
grok_query '{"available":true,"accounts":[
  {"account":"supergrok","enabled":false,"weekly":{"used_pct":40}}]}' --account grok
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'every grok account is out of the worker pool' "$WORK/query.err"
# A vendor half-installed — a store row the collector has written no reading into yet — has no
# wall to report, and saying it has one sends Egor hunting for a limit that does not exist.
grok_case '{available:false}'
assert not_contains "$(next_block)" 'grok/'
assert not_contains "$output" WALLED
# Both renders of that one state say the same words, or a reader takes them for two states.
assert test "$(vsection grok)" = 'no quota data'
grok_case '{available:true,accounts:[{account:"supergrok",enabled:true}]}'
assert not_contains "$(next_block)" 'grok/'
assert contains "$(vsection grok)" '- ? – supergrok grok·high'

# The pin: the one override above the pool, lapsing loudly with a reason, and ended outright by a
# wall on fresh data — the same rule the other three vendors follow, with only the key differing.
write_config 'grok_profile=supergrok'
grok_case '{available:true,accounts:[
  {account:"supergrok",enabled:false,weekly:{used_pct:40}},
  {account:"spare",enabled:true,weekly:{used_pct:10}}]}'
assert contains "$(nrow 1)" 'grok/supergrok grok·high PINNED'
assert contains "$(vsection grok)" '40% – supergrok grok·high PINNED off'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr✓supergrok·auto·hi'
write_config 'grok_profile=ghost'
grok_case "$GROK_PAIR"
assert contains "$(nrow 1)" 'grok/spare grok·high'
assert contains "$(vsection grok)" 'pin ghost absent → spare'
write_config 'grok_profile=locked'
grok_case '{available:true,accounts:[
  {account:"locked",enabled:true,weekly:{used_pct:10},auth:{status:"needs_login"}},
  {account:"spare",enabled:true,weekly:{used_pct:40}}]}'
assert contains "$(vsection grok)" 'pin locked auth unavailable → spare'
assert test "$(sed -n 's/^grok_profile=//p' "$CONFIG")" = locked
write_config 'grok_profile=blank'
grok_case '{available:true,accounts:[
  {account:"blank",enabled:true},
  {account:"spare",enabled:true,weekly:{used_pct:40}}]}'
assert contains "$(vsection grok)" 'pin blank no quota data → spare'
assert test "$(sed -n 's/^grok_profile=//p' "$CONFIG")" = blank
cleared_case grok_profile spent spare golden '.vendors.grok = {available:true,accounts:[
  {account:"spent",enabled:true,weekly:{used_pct:100}},
  {account:"spare",enabled:true,weekly:{used_pct:10}}]}'
write_config

# A role switch is not a limit: with `grok_workers=off` the vendor states the switch instead of
# rows, holds no rank, and the statusline reads `⏸off` rather than a lookup that failed.
write_config 'grok_workers=off'
grok_case "$GROK_PAIR"
assert test "$(vsection grok)" = 'off for workers'
assert not_contains "$output" 'grok unavailable'
assert not_contains "$(next_block)" 'grok/'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr⏸off·auto·hi'
grok_query "$GROK_PAIR_JSON" --account grok
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert test "$(cat "$WORK/query.err")" = 'worker-pick: grok is switched off for workers'
query --account grok --role reviewers
assert test "$query_rc" -eq 0
assert test "$query_out" = spare
write_config 'grok_reviewers=off'
grok_query "$GROK_PAIR_JSON" --account grok --role reviewers
assert test "$query_rc" -eq 3
assert test "$(cat "$WORK/query.err")" = 'worker-pick: grok is switched off for reviewers'
query --account grok
assert test "$query_rc" -eq 0
assert test "$query_out" = spare
# The ladder is pin > roles > pool for grok too, and a pin that cannot serve leaves the wall up.
write_config 'grok_profile=supergrok' 'grok_workers=off'
grok_query "$GROK_PAIR_JSON" --account grok
assert test "$query_rc" -eq 0
assert test "$query_out" = supergrok
run_store grok-pinned-off
assert contains "$(nrow 1)" 'grok/supergrok grok·high PINNED'
assert not_contains "$output" 'off for workers'
write_config 'grok_profile=ghost' 'grok_workers=off'
grok_query "$GROK_PAIR_JSON" --account grok
assert test "$query_rc" -eq 3
assert test "$(cat "$WORK/query.err")" = 'worker-pick: grok is switched off for workers'
# A vendor switched off never speaks for the ALL WALLED verdict, and never hides one either.
write_config 'claudeb_workers=off' 'codex_workers=off' 'gemini_workers=off' 'grok_workers=off'
run_case all_walled
assert not_contains "$output" 'ALL WALLED'
write_config 'claudeb_workers=off' 'codex_workers=off' 'gemini_workers=off'
run_filter all_walled '.vendors.grok = {available:true,accounts:[
  {account:"spent",enabled:true,weekly:{used_pct:100}}]}'
assert test "$(next_fail)" = 'NEXT: ALL WALLED, ask Egor'
write_config
run_filter all_walled '.vendors.grok = {available:true,accounts:[
  {account:"spare",enabled:true,weekly:{used_pct:10}}]}'
assert not_contains "$output" 'ALL WALLED'
assert contains "$(nrow 1)" 'grok/spare grok·high'
# `--role chat` is the same pool minus the pin, for grok as for the others.
write_config 'grok_profile=supergrok'
grok_query "$GROK_PAIR_JSON" --account grok --role chat
assert test "$query_rc" -eq 0
assert test "$query_out" = spare
query --account grok
assert test "$query_out" = supergrok
write_config

# Roles are walls layered over the pool: a vendor closed for a role may not serve that work at
# all, so the query never reaches the question of which account.
write_config 'claudeb_workers=off'
query_case claude_pool --account claudeb
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert test "$(cat "$WORK/query.err")" = 'worker-pick: claudeb is switched off for workers'
# One role closed says nothing about the other, and nothing about the other vendors.
query --account claudeb --role reviewers
assert test "$query_rc" -eq 0
assert test "$query_out" = session
write_config 'claudeb_reviewers=off'
query_case claude_pool --account claudeb --role reviewers
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert test "$(cat "$WORK/query.err")" = 'worker-pick: claudeb is switched off for reviewers'
query --account claudeb
assert test "$query_rc" -eq 0
assert test "$query_out" = session
# The ladder is pin > roles > pool: a usable pin answers over a closed role exactly as it answers
# over pool exclusion, because naming an account there is the deliberate "use this one anyway".
write_config 'claudeb_profile=off' 'claudeb_workers=off'
query_case claude_pool --account claudeb
assert test "$query_rc" -eq 0
assert test "$query_out" = off
run_case claude_pool
assert contains "$(nrow 1)" 'claude/off opus·high PINNED'
assert test "$(acct_line)" = 'ACCOUNT: off'
assert not_contains "$output" 'off for workers'
# A pin that cannot serve leaves the wall standing, and the pool's own candidate is not handed
# over in its place: the switch is not advice.
write_config 'claudeb_profile=ghost' 'claudeb_workers=off'
query_case claude_pool --account claudeb
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert test "$(cat "$WORK/query.err")" = 'worker-pick: claudeb is switched off for workers'
run_case claude_pool
# The lapse note stands above the switch: the pin was read, and it did not open the vendor.
assert test "$(vsection claude)" = 'pin ghost absent → session
off for workers'
# The pin is Egor's override for workers, so a rater neither inherits it nor is refused by it:
# the pinned account is an ordinary candidate, and out of the pool it is no candidate at all.
write_config 'claudeb_profile=off'
query_case claude_pool --account claudeb --role reviewers
assert test "$query_rc" -eq 0
assert test "$query_out" = session
query --account claudeb
assert test "$query_out" = off
# ... and no pin opens a vendor closed for reviewers.
write_config 'claudeb_profile=off' 'claudeb_reviewers=off'
query_case claude_pool --account claudeb --role reviewers
assert test "$query_rc" -eq 3
assert test "$(cat "$WORK/query.err")" = 'worker-pick: claudeb is switched off for reviewers'
# The table is the workers view: a workers-off vendor is never auto-selected and states the switch
# in place of its rows — a closed role is a setting, not a reading, and the menubar shows what
# those accounts hold in the vendor's own section.
write_config 'claudeb_workers=off'
run_case golden
assert test "$(vsection claude)" = 'off for workers'
assert not_contains "$output" 'ACCOUNT: worker'
assert not_contains "$(next_block)" 'claude/'
# A parked vendor is not an unpredictable one: the statusline reads `~?` as a lookup that failed.
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb⏸off·opus·hi gx✓main·pro·hi'
write_config 'codex_workers=off'
run_case golden
assert test "$(vsection codex)" = 'off for workers'
assert not_contains "$(next_block)" 'codex/'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx⏸off·sol·hi cb~session·opus·hi gx✓main·pro·hi'
write_config 'gemini_workers=off'
run_case golden
assert test "$(vsection gemini)" = 'off for workers'
assert not_contains "$output" 'ACCOUNT: main'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx⏸off·pro·hi'
# The switch is the answer even when the store has nothing left to rank: blaming the data for it
# would send the owner hunting a reading that no longer decides anything.
write_config 'codex_workers=off'
run_filter golden '.vendors.codex.accounts = []'
assert test "$(vsection codex)" = 'off for workers'
# A closed vendor is never the routing answer: it holds no rank at all, whatever the mode's usual
# vendor order.
write_config 'claudeb_workers=off'
run_case golden
assert contains "$(nrow 1)" 'gemini/main pro·high'
assert contains "$(next_block)" 'codex/main sol·high'
assert not_contains "$(next_block)" 'claude/'
assert test "$(vsection claude)" = 'off for workers'
# A closed vendor never speaks for a wall either: `WALLED` is quota talking, and codex here has
# 48% of its week left.
write_config 'claudeb_workers=off' 'codex_workers=off'
run_case golden
assert contains "$(nrow 1)" 'gemini/main pro·high'
assert test "$(vsection codex)" = 'off for workers'
assert not_contains "$output" WALLED
assert test "$(vsection claude)" = 'off for workers'
# A vendor held back from a role has quota it simply may not spend here, so the verdict that
# sends the owner hunting for limits is read over the vendors still open for workers.
write_config 'claudeb_workers=off' 'codex_workers=off' 'gemini_workers=off'
run_case all_walled
assert not_contains "$output" 'ALL WALLED'
assert not_contains "$(next_fail)" WALLED
assert test "$(vsection claude)" = 'off for workers'
# The pool a closed vendor holds is not evidence for a verdict about the open ones either: with
# claudeb parked, codex and gemini merely have no measured reading — nothing hit a wall.
write_config 'claudeb_workers=off'
run_filter claude_pool '.vendors.codex = {available:true,accounts:[{account:"main"}]}
  | .vendors.gemini = {available:true,group:"Gemini Models"}'
assert not_contains "$output" 'ALL WALLED'
assert test "$(vsection claude)" = 'off for workers'
# One vendor closed does not soften the verdict for the ones that are open — and the closure
# stays visible beside it.
write_config 'claudeb_workers=off'
run_case all_walled
assert test "$(next_fail)" = 'NEXT: ALL WALLED, ask Egor'
assert contains "$(vsection codex)" WALLED
assert test "$(vsection claude)" = 'off for workers'
# Only the literal `off` closes a role; anything else leaves the vendor open.
write_config 'claudeb_workers=on'
query_case claude_pool --account claudeb
assert test "$query_rc" -eq 0
assert test "$query_out" = session
write_config

# `--role chat` asks the same pool under the same walls, minus the one thing that is only about
# workers: the pin.
write_config 'claudeb_profile=off'
query_case claude_pool --account claudeb --role chat --exclude session
assert test "$query_rc" -eq 0
assert test "$query_out" = dry
query --account claudeb
assert test "$query_out" = off
# A chat query decides nothing about workers, so the pin it ignores also survives its own wall.
write_config 'claudeb_profile=walled-wk'
query_case claude_pool --account claudeb --role chat
assert test "$query_rc" -eq 0
assert test "$(sed -n 's/^claudeb_profile=//p' "$CONFIG")" = walled-wk
# The session account is the one the chat is already spending, and it stands as an ordinary
# candidate here as it does in every other role: its 0% weekly wins outright.
write_config
query_case claude_pool --account claudeb --role chat
assert test "$query_rc" -eq 0
assert test "$query_out" = session
assert test ! -s "$WORK/query.err"
# The pool toggle is the wall for chat too — `off` is out of the pool and never proposed — so
# running out of the rest is exit 3, not a quieter answer.
query --account claudeb --role chat --exclude session,dry,tie-b,tie-a
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'no selectable claudeb account' "$WORK/query.err"
# There is no `<vendor>_chat` wall to invent, and the workers/reviewers ones say nothing about it.
write_config 'claudeb_workers=off' 'claudeb_reviewers=off' 'claudeb_chat=off'
query_case claude_pool --account claudeb --role chat
assert test "$query_rc" -eq 0
assert test "$query_out" = session
# The role is vendor-agnostic: codex answers it as the pool minus the pin.
write_config 'codex_profile=with-credit'
query_case codex_credit --account codex --role chat
assert test "$query_rc" -eq 0
assert test "$query_out" = plain
query --account codex
assert test "$query_out" = with-credit
write_config

# Every candidate walled is the one state the orchestrator must not paper over.
run_case all_walled
assert test "$(next_fail)" = 'NEXT: ALL WALLED, ask Egor'
assert contains "$(vsection codex)" WALLED
query_case all_walled --account claudeb
assert test "$query_rc" -eq 3
assert test -z "$query_out"
query_case all_walled --account codex
assert test "$query_rc" -eq 3
assert grep -q 'no selectable codex account' "$WORK/query.err"

# Data hygiene (shared-invariants y): effective_pct beats a stale raw reading, a bucket past
# its reset reads 0%, and a weekly stamped `origin: headers` was never measured at all.
run_case stale
assert contains "$(nrow 1)" 'claude/effective opus·high'
assert contains "$(vsection claude)" '20% 20% effective opus·high'
assert contains "$output" 'DATA: STALE — store written 2h46m ago, no account reading behind it'
run_case expired
assert contains "$(nrow 1)" 'claude/expired opus·high'
assert contains "$(vsection claude)" '10% 0% expired opus·high'
run_filter golden '.vendors.claude.accounts |= map(
  if .account == "worker" then .weekly = {used_pct:100,origin:"headers"} else . end)'
assert contains "$(nrow 1)" 'claude/session* opus·high'
assert contains "$(vsection claude)" '? 30% worker opus·high'
# The synthetic week is dropped, not the account: with no weekly bucket it is paced over the
# neutral window on its five-hour reading and stays a candidate.
query --account claudeb --exclude session
assert test "$query_rc" -eq 0
assert test "$query_out" = worker
run_case reset
assert contains "$(vsection claude)" '50% 10% later opus·high'
# The row prints the metric that ranked it, both halves of it (shared-invariants `bl`): a nearer
# reset is a smaller divisor and a bigger rate, and a window minutes from rolling over shows the
# 0.25-day floor the budget divided by (one decimal, `×0.3d`) rather than the raw remainder
# nobody paced on.
reset_row=$(vsection claude)
assert contains "$reset_row" '200.0%/d ×0.3d 50% 10% soon opus·high ↺ 06:33'
assert contains "$reset_row" '10.0%/d ×5.0d 50% 10% later opus·high ↺ Mon 03:33'
# No decorative numbers beside it: a token that is neither input nor output of the ranking reads
# as one, so the rows carry the metric and nothing that looks like it.
assert not_contains "$output" ' score '
assert not_contains "$output" ' cap '
# An account nobody measured has no budget to print — `0%/day` there would read as a wall.
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"blank",enabled:true},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(vsection claude)" '- ? ? blank opus·high'
run_case gemini_stale
assert contains "$(vsection gemini)" '30% 20% main pro·high'
# The row is NAMED, never a verdict over the table: one old account beside four fresh ones sent
# Egor looking for a collector that had in fact answered for everything he was routing on.
assert contains "$output" 'DATA: STALE — gemini/main 2h46m'

# A disabled account is not polled, so its frozen as_of must not drive the DATA age; the same
# timestamps on an enabled account must (control), and a pinned account counts even when off.
run_filter gemini_fresh '.vendors.claude.accounts = [{account:"dormant",enabled:false,auth:"ok",
  five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: fresh (0 min old)'
run_filter gemini_fresh '.vendors.claude.accounts = [{account:"dormant",enabled:true,auth:"ok",
  five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: STALE — claude/dormant 11d13h'
run_filter gemini_fresh '.vendors.claude.accounts = [{account:"dormant",auth:"ok",
  five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: fresh (0 min old)'
run_filter gemini_fresh '.vendors.gemini.enabled = false
  | .vendors.claude.accounts = [{account:"dormant",enabled:false,auth:"ok",
    five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: STALE — claude/dormant 11d13h'
write_config 'claudeb_profile=dormant'
run_filter gemini_fresh '.vendors.claude.accounts = [{account:"dormant",enabled:false,auth:"ok",
  five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: STALE — claude/dormant 11d13h'
write_config
run_filter golden 'del(.fetched_at, .vendors.gemini.five_hour.as_of, .vendors.gemini.weekly.as_of)'
assert contains "$output" 'DATA: no timestamp'
# WHICH rows are old, each with its own age, and never a verdict over the whole reading: a table
# branded STALE over one quiet account sends Egor after a collector that answered for every
# account he is routing on. A fresh row is absent from the line by that same rule.
run_filter gemini_fresh '.vendors.claude.accounts = [
  {account:"old1",enabled:true,auth:"ok",five_hour:{used_pct:5,as_of:1999000000},
   weekly:{used_pct:5,as_of:1999000000}},
  {account:"old2",enabled:true,auth:"ok",five_hour:{used_pct:5,as_of:1999900000},
   weekly:{used_pct:5,as_of:1999900000}},
  {account:"new",enabled:true,auth:"ok",five_hour:{used_pct:5,as_of:2000000000},
   weekly:{used_pct:5,as_of:2000000000}}]'
data_row=$(vline 'DATA:')
assert contains "$data_row" 'DATA: STALE — claude/old1 11d13h, claude/old2 1d3h'
assert not_contains "$data_row" 'claude/new'
assert not_contains "$data_row" 'gemini/main'

# Model and effort are read from worker-model and printed verbatim: quota state never
# silently degrades the work.
printf '%s\n' 'worker=auto' 'codex_effort=medium' 'claudeb_model=sonnet' 'claudeb_effort=medium' \
  'gemini_model=flash' 'gemini_effort=medium' >"$CONFIG"
run_case claude_pool
assert contains "$(nrow 1)" 'claude/session* sonnet·med'
run_case golden
assert contains "$(vsection codex)" 'main sol·med'
printf '%s\n' 'worker=gemini' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=flash' 'gemini_effort=medium' >"$CONFIG"
run_case gemini_fresh
assert contains "$(nrow 1)" 'gemini/main flash·med'
assert test "$(acct_line)" = 'ACCOUNT: main'
# `worker=sonnet` is a toggle value that no longer exists — every implementation run belongs to a
# relay worker on another account — so the reader routes it as `auto` and says so once, instead of
# falling through to a mode nobody defines.
printf '%s\n' 'worker=sonnet' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"
run_case golden
sonnet_next=$(next_block)
assert grep -Fq 'worker=sonnet is no longer a worker toggle value' "$WORK/note.err"
write_config
run_case golden
assert test "$sonnet_next" = "$(next_block)"

# `sonnet·xhigh` is twelve characters of legal toggle values, and the column it sits in is the
# widest thing either row builder pads: with no gap left the reset and the flags glue onto it and
# the row reads as one token.
printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=sonnet' 'claudeb_effort=xhigh' \
  'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"
run_case reset
assert contains "$(vsection claude)" 'sonnet·xhigh ↺'
printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=sonnet' 'claudeb_effort=xhigh' \
  'gemini_model=pro' 'gemini_effort=high' 'claudeb_profile=off' >"$CONFIG"
run_case claude_pool
assert contains "$(nrow 1)" 'sonnet·xhigh PINNED'
write_config

# The golden output is the whole contract in one store: line order, the session-account footnote,
# the statusline cache line, and no POLICY prose anywhere.
run_case golden
assert test "$(acct_line)" = 'ACCOUNT: session'
assert not_contains "$(next_block)" 'claude/worker'
assert contains "$output" 'session*'
assert contains "$(vsection claude)" '* = this session account'
assert not_contains "$output" 'RESERVE'
assert test "$(sed -n '1p' <<<"$output" | cut -c1-4)" = NEXT
assert test "$(section_order)" = 'codex gemini claude'
assert test "$(grep -c -- '^DATA: ' <<<"$output")" -eq 1
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 11
assert not_contains "$output" '# Worker routing policy'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi'
assert test -z "$(find "$CACHE" -name '*.tmp.*' -print -quit)"
assert cmp -s <(printf '%s\n' "$output") "$GOLDEN"
# Display bands are render-only: an unreachable account stays visible, below the candidates.
run_filter golden '.vendors.claude.accounts += [{
  account:"blocked",enabled:true,rotation:{usable:{general:false,fable:false}},
  five_hour:{used_pct:0},weekly:{used_pct:0},fable:{used_pct:0}}]'
claude_order=$(vsection claude)
assert before "$claude_order" ' session* ' ' worker '
assert before "$claude_order" ' worker ' ' blocked '
assert contains "$claude_order" 'blocked'

# Every write sweeps day-old siblings: an account that was renamed or removed leaves a prediction
# file nobody rewrites, and the producer is the only run that can tell it from a live one.
: >"$CACHE/worker-pick.line.gone"
: >"$CACHE/worker-pick.line.live"
: >"$CACHE/statusline-cache-rl"
touch -t 202001010000 "$CACHE/worker-pick.line.gone" "$CACHE/statusline-cache-rl"
run_case golden
assert test ! -e "$CACHE/worker-pick.line.gone"
assert test -e "$CACHE/worker-pick.line.live"
assert test -e "$CACHE/statusline-cache-rl"
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi'
rm -f "$CACHE/worker-pick.line.live" "$CACHE/statusline-cache-rl"

# A paused vendor is parked for months and must leave no trace: the collector drops its
# `vendors.<key>` from the store, and every surface here has to render that absence as absence —
# no NEXT segment, no vendor line, no cache field, and no `paused` word anywhere either.
write_config 'gemini_paused=on'
run_filter golden 'del(.vendors.gemini)'
assert not_contains "$output" gemini
assert not_contains "$output" paused
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 9
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi'
# Read off the switch as well as off the store: the collector only drops the vendor on its next
# run, and a snapshot written before the switch must not keep the parked vendor on screen.
run_case golden
assert not_contains "$output" gemini
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi'
# Every vendor reads the same rule, claudeb and codex included.
write_config 'codex_paused=on'
run_case golden
assert not_contains "$output" codex
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cb~session·opus·hi gx✓main·pro·hi'
write_config 'claudeb_paused=on'
run_case golden
assert not_contains "$output" claude
assert contains "$(nrow 1)" 'gemini/main pro·high'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi gx✓main·pro·hi'
# A named vendor is refused rather than quietly rerouted: a caller that spelled it out would read
# another vendor's account as the one it asked for.
write_config 'grok_paused=on'
grok_query "$GROK_PAIR_JSON" --account grok
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert test "$(cat "$WORK/query.err")" = 'worker-pick: grok is paused (grok_paused=on in ~/.claude/worker-model)'
# Only the literal `on` parks a vendor, mirroring the literal `off` of the role keys.
write_config 'grok_paused=off'
grok_query "$GROK_PAIR_JSON" --account grok
assert test "$query_rc" -eq 0
assert test "$query_out" = spare
# Roles are left exactly as they were, and say nothing while the pause stands: `off for workers` is
# a rendered segment, and a parked vendor renders none.
write_config 'grok_paused=on' 'grok_workers=off'
grok_case "$GROK_PAIR"
assert not_contains "$output" grok
assert not_contains "$output" 'off for workers'
# `worker=<paused vendor>` falls back to auto, silently: the pause is the later of the two
# decisions, and a note on every run would be noise rather than news. Read off the whole line,
# because a mode left standing would still order the remaining vendors its own fixed way.
write_config 'grok_paused=on'
grok_case "$GROK_PAIR"
paused_auto_next=$(next_block)
printf '%s\n' 'worker=grok' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' 'grok_paused=on' >"$CONFIG"
grok_case "$GROK_PAIR"
assert not_contains "$output" grok
assert test "$(next_block)" = "$paused_auto_next"
assert test ! -s "$WORK/note.err"
# Pause beats the pin — the one place in the ladder where the pin does not win. The pinned account
# is dropped from the reckoning entirely, DATA age included: a pin normally keeps an out-of-pool
# account routable, and a parked vendor's frozen timestamp would brand the whole reading STALE.
# The pin line itself stays in the file for the day the vendor comes back.
PAUSED_PIN_STORE='{available:true,accounts:[
  {account:"parked",enabled:false,weekly:{used_pct:10,as_of:1999000000},auth:{status:"ok"}}]}'
write_config 'grok_paused=on' 'grok_profile=parked'
grok_case "$PAUSED_PIN_STORE"
assert not_contains "$output" grok
assert not_contains "$output" parked
assert contains "$output" 'DATA: fresh (0 min old)'
assert grep -Fqx 'grok_profile=parked' "$CONFIG"
# The same pin on a vendor that is running is the control: it counts.
write_config 'grok_profile=parked'
grok_case "$PAUSED_PIN_STORE"
assert contains "$output" 'DATA: STALE'
# An ordinary enabled row the collector has not dropped yet reads the same way: a parked vendor is
# not polled, so its frozen timestamp is nobody's routing data and may not age the DATA line.
PAUSED_STALE_STORE='{available:true,accounts:[
  {account:"supergrok",enabled:true,weekly:{used_pct:10,as_of:1999000000},auth:{status:"ok"}}]}'
write_config 'grok_paused=on'
grok_case "$PAUSED_STALE_STORE"
assert contains "$output" 'DATA: fresh (0 min old)'
write_config
grok_case "$PAUSED_STALE_STORE"
assert contains "$output" 'DATA: STALE'
# That same undropped row may not vote on the ALL WALLED verdict either: its quota is nobody's to
# spend, and one such ghost would report the open vendors' empty pool as a limit Egor must fix.
PARKED_GHOST_FILTER='.vendors.codex = {available:true,accounts:[{account:"main"}]}
  | .vendors.gemini = {available:true,group:"Gemini Models"}
  | .vendors.claude.accounts |= map(.enabled = false)'
write_config 'grok_paused=on'
run_filter golden "$PARKED_GHOST_FILTER | .vendors.grok = $PAUSED_STALE_STORE"
assert contains "$output" 'DATA: fresh (0 min old)'
assert not_contains "$output" 'ALL WALLED'
assert contains "$(next_fail)" 'claude every account is out of the worker pool'
parked_ghost_next=$(next_fail)
# The same store with grok never collected at all is the control: a parked vendor reads as absent.
write_config
run_filter golden "$PARKED_GHOST_FILTER"
assert test "$(next_fail)" = "$parked_ghost_next"

# Every vendor parked is the one degenerate case that names the pause: nothing is routable, and an
# empty NEXT without the reason reads as a router that broke. Nothing else appears — no vendor
# line, no cache field — and the run still answers 0, as the ALL WALLED verdict does.
ALL_PAUSED=('claudeb_paused=on' 'codex_paused=on' 'gemini_paused=on' 'grok_paused=on')
write_config "${ALL_PAUSED[@]}"
run_case golden
assert test "$(next_fail)" = 'NEXT: nothing routable — every vendor is paused'
assert test "$(sed -n '2p' <<<"$output" | cut -d: -f1)" = DATA
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 2
assert test -z "$(cat "$CACHE/worker-pick.line.session")"
# The fail-safe is built without the store and needs the same answer, or the one run that has no
# data to check itself against would name a parked vendor as the fallback.
printf 'not-json\n' >"$STORE"
run_store all-paused-fail-safe
assert test "$(next_fail)" = 'NEXT: nothing routable — every vendor is paused'
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 2
assert test -z "$(cat "$CACHE/worker-pick.line.session")"
# With one vendor still running the fail-safe names it rather than the parked claudeb it defaults
# to: a caller sent at a leg Egor parked has nowhere to land.
write_config 'claudeb_paused=on' 'gemini_paused=on' 'grok_paused=on'
run_store paused-fail-safe
assert test "$(next_fail)" = 'NEXT: codex unavailable (limits parse failed)'
assert not_contains "$output" claudeb
assert not_contains "$(cat "$CACHE/worker-pick.line.session")" cb
write_config
# A duplicate hand-edited line resolves first-wins, as every other key in this file does.
printf '%s\n' 'worker=auto' 'grok_paused=on' 'grok_paused=off' >"$CONFIG"
grok_query "$GROK_PAIR_JSON" --account grok
assert test "$query_rc" -eq 3
printf '%s\n' 'worker=auto' 'grok_paused=off' 'grok_paused=on' >"$CONFIG"
grok_query "$GROK_PAIR_JSON" --account grok
assert test "$query_rc" -eq 0
write_config

# The writer is share/worker-model.sh: `on` writes the line, `off` deletes it rather than spelling
# an `=off`, and neither touches the role lines beside it.
PAUSE_MODEL="$WORK/pause-model"
set_paused() {
  env -u CLAUDECODE "WORKER_PICK_CONFIG_FILE=$PAUSE_MODEL" \
    bash -c '. "$1"; worker_model_set_paused "$2" "$3"' _ "$ROOT/share/worker-model.sh" "$1" "$2"
}
printf '%s\n' 'grok_workers=off' 'grok_profile=supergrok' >"$PAUSE_MODEL"
assert set_paused grok on
assert grep -Fqx 'grok_paused=on' "$PAUSE_MODEL"
assert grep -Fqx 'grok_workers=off' "$PAUSE_MODEL"
assert grep -Fqx 'grok_profile=supergrok' "$PAUSE_MODEL"
assert set_paused grok off
assert test -z "$(grep grok_paused "$PAUSE_MODEL")"
assert grep -Fqx 'grok_workers=off' "$PAUSE_MODEL"
# OpenCode has no roles and no leg here, and is parkable all the same: review-bench staffs it.
assert set_paused opencode on
assert grep -Fqx 'opencode_paused=on' "$PAUSE_MODEL"
set_paused nosuchvendor on 2>/dev/null && fail 'worker_model_set_paused accepted an unknown vendor'
set_paused grok sometimes 2>/dev/null && fail 'worker_model_set_paused accepted an unknown state'
# Parking a vendor takes it out of every router at once, so a session may not do it.
env "CLAUDECODE=1" "WORKER_PICK_CONFIG_FILE=$PAUSE_MODEL" \
  bash -c '. "$1"; worker_model_set_paused grok on' _ "$ROOT/share/worker-model.sh" 2>/dev/null &&
  fail 'worker_model_set_paused let a session park a vendor'

# A query answers a caller; it does not announce a routing decision, so the statusline's
# prediction stays owned by the real invocation.
QUERY_CACHE="$WORK/query-cache"
mkdir -p "$QUERY_CACHE"
run_env=("${run_env[@]/WORKER_PICK_CACHE_DIR=$CACHE/WORKER_PICK_CACHE_DIR=$QUERY_CACHE}")
query_case golden --account claudeb
assert test "$query_rc" -eq 0
assert test "$query_out" = session
assert test ! -s "$WORK/query.err"
assert test -z "$(find "$QUERY_CACHE" -type f -print -quit)"
# Exclusion is by name, not by substring: `com` and `notcom` coexist in the real store, so a
# containment test would drop the wrong account.
query_case golden --account claudeb --exclude session,worker2
assert test "$query_rc" -eq 0
assert test "$query_out" = worker

# An argument that is silently ignored lets a caller believe it constrained the answer.
# A value naming nothing would widen the query instead of narrowing it, so it is refused too.
for bad in "--account nosuchvendor" "--exclude com" "--account" "--account claudeb --bogus x" "stray" \
           "--account claudeb --exclude" "--exclude" "--fable" "--claim" \
           "--role reviewers" "--role chat" "--role" "--account claudeb --role" \
           "--account claudeb --role rater"; do
  bad_out=$(env "${run_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" $bad 2>"$WORK/query-bad.err")
  bad_rc=$?
  assert test "$bad_rc" -eq 2
  assert test -z "$bad_out"
  assert grep -q '^usage: worker-pick' "$WORK/query-bad.err"
done
bad_out=$(env "${run_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" --role reviewers \
  2>"$WORK/query-bad.err")
bad_rc=$?
assert test "$bad_rc" -eq 2
assert test -z "$bad_out"
assert grep -q -- '--role only means something with --account' "$WORK/query-bad.err"
for empty_exclude in "" ",,"; do
  bad_out=$(env "${run_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" --account claudeb \
    --exclude "$empty_exclude" 2>"$WORK/query-bad.err")
  bad_rc=$?
  assert test "$bad_rc" -eq 2
  assert test -z "$bad_out"
  assert grep -q 'needs at least one account name' "$WORK/query-bad.err"
done

# What the rows SAY is display; what they DECIDE is this table. Every fixture runs under the
# default config and is pinned by the answer it produces — the `NEXT:` line plus the four machine
# queries, `-` where none is selectable — so an edit to the wording of a row, a tag or the DATA
# line that also moves a routing decision fails here instead of reaching a statusline weeks later.
write_config
clear_claims
decisions_now() {
  local name vendor next_rows
  for name in $(jq -r 'keys[]' "$FIXTURES"); do
    run_case "$name"
    next_rows=$(next_block | tr '\n' ';' | sed 's/;$//')
    printf '%s\tNEXT\t%s\n' "$name" "${next_rows:-$(next_fail)}"
    for vendor in claudeb codex gemini grok; do
      query --account "$vendor"
      printf '%s\t%s\t%s\t%s\n' "$name" "$vendor" "$query_rc" "${query_out:--}"
    done
  done
}
assert diff -u "$DECISIONS" <(decisions_now)

printf 'PASS: %s assertions; the routing-contract rules (pool-toggle candidacy with a computable daily budget, pin-or-largest-budget selection where a nearer reset outranks an equal percentage and equal budgets order by name, walls only at effective 100%% with dead auth its own state), the five-hour deferral at 80%% with its `5h!` tag, claims as the second soft key (fresh demotes, TTL-expired does not, per-vendor, table never writes one, a refused query records nothing), the session account as an ordinary candidate in every role with no reserve anywhere, the three roles including a chat that sees no pin, loud pin lapses, the fable bucket on explicit ask, --exclude re-queries and ALL WALLED exit 3, an emptied pool named as the switch it is rather than a limit, auto vendor order following the selected accounts budgets rather than a fixed vendor list, grok as the fourth vendor (weekly-only ranking, refreshable `expired` auth behind `ok`, mode arm, `gr` cache field, and absence that renders as absence), data hygiene and DATA age sourcing that a parked vendor contributes nothing to, the all-paused run naming the pause once and nothing else in the render and in the fail-safe alike, model/effort straight from worker-model, account rows that print the daily budget that ranked them with WALLED kept to the usage wall, a DATA line that names the stale rows instead of branding the table, and the output/cache/decision golden contract with no routing prose\n' "$asserts"
