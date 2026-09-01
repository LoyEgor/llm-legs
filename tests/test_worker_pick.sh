#!/usr/bin/env bash
set -u

# The suite reads docs/routing-contract.md as the specification: three rules (pool-toggle
# candidacy with a computable daily budget, pin-or-largest-budget selection, wall only at
# effective 100% or dead auth) and nothing else may move a decision.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/worker-pick"
FIXTURES="$ROOT/tests/fixtures/worker-pick/scenarios.json"
GOLDEN="$ROOT/tests/fixtures/worker-pick/golden-output.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() {
  asserts=$((asserts + 1))
  "$@" || fail "assert $asserts failed: $*"
}
contains() { grep -Fq -- "$2" <<<"$1"; }
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
pool_row=$(sed -n '4p' <<<"$output")
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb session · opus · high — ACCOUNT: session'
assert contains "$pool_row" 'dry($100) 5h 20% wk 5% fb 100%'
assert not_contains "$output" 'SESSION RESERVE'
# Rule 1: the session account is an ordinary candidate, so its 0% weekly wins outright.
assert contains "$pool_row" 'session($100)* 5h 0% wk 0%'
assert not_contains "$(head -n1 <<<"$output")" 'claudeb dry '
# Rule 3: only a wall skips an account, and both wall shapes are marked as such.
assert contains "$pool_row" 'walled-wk($100) 5h 0% wk 100% fb 100% score 0 cap 0% WALLED'
assert contains "$pool_row" 'walled-5h($100) 5h 100% wk 5% fb 5% score 95 cap 0% WALLED'
assert contains "$pool_row" 'dead($100) 5h 0% wk 0% fb 0% score 100 cap 100% WALLED auth!'
# A pool toggle that is off keeps the account visible: an account that silently vanished from
# the ranking is indistinguishable from a collector bug.
assert contains "$pool_row" 'off($100) 5h 0% wk 0% fb 0% score 100 cap 100% off'
# Bands are a render order; within one, accounts keep selection order (shared-invariants g),
# so a limits file that lists tie-a first still renders the better-ranked tie-b ahead of it.
assert before "$pool_row" 'session($100)*' 'dry($100)'
assert before "$pool_row" 'dry($100)' 'tie-a($100)'
assert before "$pool_row" 'tie-a($100)' 'tie-b($100)'
assert before "$pool_row" 'tie-b($100)' 'dead($100)'
# The deferral is the first rank key even among rows nothing can select, so the 5h-walled account
# trails the weekly-walled one whatever their budgets say.
assert before "$pool_row" 'dead($100)' 'walled-wk($100)'
assert before "$pool_row" 'walled-wk($100)' 'walled-5h($100)'
assert before "$pool_row" 'walled-5h($100)' 'off($100)'
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
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb tie-a · opus · high — ACCOUNT: tie-a'
assert before "$(sed -n '4p' <<<"$output")" 'tie-a($100) 5h ?' 'tie-b($100)'

# The budget is a pace, not a level: at the same percentage the account whose week resets sooner
# may spend faster, and that is the whole difference between this metric and a bare percentage.
run_case reset
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb soon · opus · high — ACCOUNT: soon'
assert before "$(sed -n '4p' <<<"$output")" 'soon($100)' 'later($100)'
query --account claudeb
assert test "$query_out" = soon
query --account claudeb --exclude soon
assert test "$query_out" = later
# Same reset, same answer as before the reset mattered: the name breaks the tie.
run_filter reset '.vendors.claude.accounts |= map(.weekly.resets_at = 2000432000)'
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb later · opus · high'

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
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb dry · opus · high — ACCOUNT: dry'
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
defer_row=$(sed -n '4p' <<<"$output")
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb cool · opus · high — ACCOUNT: cool'
assert contains "$defer_row" 'hot($100) 5h 85% wk 30% fb ? score 70 cap 15% 5h!'
assert not_contains "$defer_row" 'cool($100) 5h 10% wk 50% fb ? score 50 cap 50% 5h!'
assert before "$defer_row" 'cool($100)' 'hot($100)'
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
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb hot · opus · high — ACCOUNT: hot'
assert contains "$(sed -n '4p' <<<"$output")" 'hot($100) 5h 85% wk 30% fb ? score 70 cap 15% 5h!'
# One threshold, and it is a threshold: 80 defers, 79 does not.
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"hot",enabled:true,five_hour:{used_pct:79},weekly:{used_pct:30}},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb hot · opus · high — ACCOUNT: hot'
assert not_contains "$output" '5h!'
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"hot",enabled:true,five_hour:{used_pct:80},weekly:{used_pct:30}},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb cool · opus · high — ACCOUNT: cool'
assert contains "$(sed -n '4p' <<<"$output")" 'hot($100) 5h 80% wk 30% fb ? score 70 cap 20% 5h!'
# A five-hour window nobody measured is no evidence of one, so it never defers — otherwise the
# tiebreak coalescing (absent reads as 100) would quietly demote a perfectly fresh account.
run_filter claude_pool '.vendors.claude.accounts = [
  {account:"nofive",enabled:true,weekly:{used_pct:30}},
  {account:"cool",enabled:true,five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb nofive · opus · high — ACCOUNT: nofive'
assert not_contains "$output" '5h!'
# Every vendor ranks by the same keys, so the deferral and its tag reach all three.
run_filter codex_plain '.vendors.codex.accounts = [
  {account:"hot",five_hour:{used_pct:85},weekly:{used_pct:20}},
  {account:"cool",five_hour:{used_pct:10},weekly:{used_pct:50}}]'
assert contains "$(head -n1 <<<"$output")" 'codex cool · high — 50%'
assert contains "$(sed -n '2p' <<<"$output")" 'hot 20% 5h 85% ↻0 5h!'
assert before "$(sed -n '2p' <<<"$output")" 'cool 50%' 'hot 20%'
run_case claude_pool

# Only a task that asks for Fable spends the fable bucket, and it is ranked by the same rules
# against that bucket's own percentage and reset.
query --account claudeb --fable
assert test "$query_rc" -eq 0
assert test "$query_out" = session
assert contains "$(sed -n '6p' <<<"$output")" 'SESSION: session — fb 0%, wk 0%'
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
assert contains "$(sed -n '6p' <<<"$output")" 'SESSION: fb-soon — fb 50%, wk 0%'
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
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb session · opus · high — ACCOUNT: session'
assert not_contains "$output" 'SESSION RESERVE'
assert contains "$(sed -n '4p' <<<"$output")" 'session($100)* 5h 5% wk 10% fb 10% score 90 cap 90%'
assert not_contains "$(sed -n '4p' <<<"$output")" 'RESERVE'
query --account claudeb
assert test "$query_rc" -eq 0
assert test "$query_out" = session
assert test ! -s "$WORK/query.err"
# It still needs its own pool toggle; with it off there is no candidate at all.
run_filter reserve_only '.vendors.claude.accounts |= map(
  if .account == "session" then .enabled = false else . end)'
assert contains "$(head -n1 <<<"$output")" 'NEXT: ALL WALLED, ask Egor'
query --account claudeb
assert test "$query_rc" -eq 3
assert test -z "$query_out"

# A pin overrides the pool toggle, and the session account is no exception to it either way.
write_config 'claudeb_profile=off'
run_case claude_pool
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb off · opus · high — ACCOUNT: off (PINNED)'
assert contains "$(sed -n '4p' <<<"$output")" 'off($100) 5h 0% wk 0% fb 0% score 100 cap 100% PINNED off'
write_config 'claudeb_profile=session'
run_case claude_pool
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb session · opus · high — ACCOUNT: session (PINNED)'
assert not_contains "$output" 'SESSION RESERVE'
assert not_contains "$(sed -n '4p' <<<"$output")" 'RESERVE'
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
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb tie-a · opus · high — ACCOUNT: tie-a (PINNED)'
assert contains "$(sed -n '4p' <<<"$output")" 'tie-a($100) 5h 30% wk 20% fb 40% score 80 cap 70% PINNED no-Fable blocked off'
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
  assert contains "$(head -n1 <<<"$output")" "claudeb pin $1 $3 → $4"
  assert contains "$(sed -n '4p' <<<"$output")" "claude: pin $1 $3 → $4"
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
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main'
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: main 40% 5h 91% 5h!'
assert not_contains "$(sed -n '3p' <<<"$output")" WALLED
run_filter gemini_high '.vendors.gemini.five_hour.used_pct = 100'
assert contains "$(sed -n '3p' <<<"$output")" 'main 40% 5h 100% WALLED'
assert not_contains "$(head -n1 <<<"$output")" 'ACCOUNT: main'
# Gemini is the only pool member here, so its wall is the whole pool's wall.
assert contains "$(head -n1 <<<"$output")" 'NEXT: ALL WALLED, ask Egor'

# Gemini candidacy: group match, the pool toggle at account and vendor level, login needed,
# weekly-first ranking, and `main` only as a late tiebreak.
run_case gemini_wrong_group
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: no Gemini Models quota data'
assert not_contains "$(head -n1 <<<"$output")" 'ACCOUNT: main'
run_filter gemini_fresh '.vendors.gemini.group = "Google GEMINI quota"'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main'
run_filter gemini_fresh '.vendors.gemini.enabled = false'
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: main 35% 5h 15% off'
assert not_contains "$(head -n1 <<<"$output")" 'ACCOUNT: main'
run_filter gemini_fresh '.vendors.gemini = {
  available:false,auth_needed:true,status:"login needed",source:"agy-local-rpc"}'
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: login needed'
run_filter gemini_fresh '.vendors.gemini = {available:true,accounts:[
  {account:"main",group:"Gemini Models",five_hour:{used_pct:10},weekly:{used_pct:10}},
  {account:"work",group:"Gemini Models",five_hour:{used_pct:40},weekly:{used_pct:40}}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main'
# `main` is no longer a ranking key on any vendor, so equal budgets order by name alone.
run_filter gemini_fresh '.vendors.gemini = {available:true,accounts:[
  {account:"main",group:"Gemini Models",five_hour:{used_pct:10},weekly:{used_pct:10}},
  {account:"work",group:"Gemini Models",five_hour:{used_pct:10},weekly:{used_pct:10}}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main'
# ... and a nearer weekly reset outranks the name, because the budget it feeds is larger.
run_filter gemini_fresh '.vendors.gemini = {available:true,accounts:[
  {account:"main",group:"Gemini Models",weekly:{used_pct:10,resets_at:2000432000}},
  {account:"work",group:"Gemini Models",weekly:{used_pct:10,resets_at:2000010800}}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini work · pro · high — ACCOUNT: work'
# The base profile is deletable, so a roster without it routes on the accounts it does have and
# never falls back to the name that is gone.
run_filter gemini_fresh '.vendors.gemini = {available:true,current_account:"com",accounts:[
  {account:"com",group:"Gemini Models",is_current:true,five_hour:{used_pct:40},weekly:{used_pct:40}},
  {account:"work",group:"Gemini Models",five_hour:{used_pct:10},weekly:{used_pct:10}}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini work · pro · high — ACCOUNT: work'
assert not_contains "$(sed -n '3p' <<<"$output")" main
run_filter gemini_fresh '.vendors.gemini = {available:true,current_account:"com",accounts:[
  {account:"com",group:"Gemini Models",is_current:true,five_hour:{used_pct:100},weekly:{used_pct:40}}]}'
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: com 40% 5h 100% WALLED'
assert not_contains "$(head -n1 <<<"$output")" 'ACCOUNT: main'
write_config 'gemini_profile=work'
run_filter gemini_fresh '.vendors.gemini = {available:true,accounts:[
  {account:"main",group:"Gemini Models",five_hour:{used_pct:20},weekly:{used_pct:20}},
  {account:"work",group:"Gemini Models",auth_needed:true}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini pin work auth unavailable → main'
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: pin work auth unavailable → main'
write_config

# Codex candidacy: budget-first ranking, credits and tiers display-only,
# the pool toggle, and login parity with Gemini.
run_case codex_credit
assert contains "$(head -n1 <<<"$output")" 'codex plain · high — 48%'
assert contains "$(sed -n '2p' <<<"$output")" 'codex: plain 48% 5h 48% ↻0'
assert contains "$(sed -n '2p' <<<"$output")" 'with-credit 48% 5h 48% ↻1'
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
assert contains "$(head -n1 <<<"$output")" 'codex main · high'
assert before "$(sed -n '2p' <<<"$output")" 'main 20%' 'zeta 20%'
# An emptied pool is a switch Egor flipped, never a limit (rule 4), so the line says which of the
# two it is — and `worker-run` reads that same wording to report UNAVAILABLE over a usage limit.
run_filter codex_plain '.vendors.codex.accounts |= map(.enabled = false)'
assert contains "$(head -n1 <<<"$output")" 'codex unavailable · high — every account is out of the worker pool'
assert not_contains "$(head -n1 <<<"$output")" 'codex unavailable · high — WALLED'
query --account codex
assert test "$query_rc" -eq 3
assert grep -q 'every codex account is out of the worker pool' "$WORK/query.err"
assert contains "$(sed -n '2p' <<<"$output")" 'plain 48% 5h 48% ↻0 off'
run_filter codex_plain '.vendors.codex = {available:true,accounts:[
  {account:"main",auth_needed:true,status:"login needed"}]}'
assert contains "$(sed -n '2p' <<<"$output")" 'codex: login needed'
assert not_contains "$output" 'no authenticated quota data'
run_filter codex_plain '.vendors.codex = {available:true,five_hour:{used_pct:12},weekly:{used_pct:34}}'
assert contains "$(sed -n '2p' <<<"$output")" 'codex: main 34% 5h 12% ↻0'
write_config 'codex_profile=main'
run_filter codex_plain '.vendors.codex.accounts = [
  {account:"plain",five_hour:{used_pct:20},weekly:{used_pct:20}},
  {account:"main",enabled:false,five_hour:{used_pct:40},weekly:{used_pct:40}}]'
assert contains "$(head -n1 <<<"$output")" 'codex main · high — 40% PINNED'
assert contains "$(sed -n '2p' <<<"$output")" 'main 40% 5h 40% ↻0 PINNED off'
run_filter codex_plain '.vendors.codex.accounts = [
  {account:"plain",five_hour:{used_pct:20},weekly:{used_pct:20}},
  {account:"main",five_hour:{used_pct:100},weekly:{used_pct:20}}]'
assert contains "$(sed -n '2p' <<<"$output")" 'codex: pin main exhausted → plain'
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
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 6
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi'
query_case golden --account grok
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'no selectable grok account (grok: unavailable)' "$WORK/query.err"

grok_case "$GROK_PAIR"
assert contains "$(head -n1 <<<"$output")" 'grok spare · auto · high — 10%'
assert contains "$(sed -n '4p' <<<"$output")" 'grok: spare 10% (wk→?) | supergrok 40% (wk→?)'
assert test "$(sed -n '4p' <<<"$output" | cut -d: -f1)" = grok
assert test "$(sed -n '5p' <<<"$output" | cut -d: -f1)" = claude
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 7
# The cache line keeps its field order and gains a fourth field; `grok_model=auto` is a knob value,
# not a missing one, so it is printed as it stands and resolved by worker-run.
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr✓spare·auto·hi'
write_config 'grok_model=grok-4.5' 'grok_effort=medium'
grok_case "$GROK_PAIR"
assert contains "$(head -n1 <<<"$output")" 'grok spare · grok-4.5 · medium — 10%'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr✓spare·grok-4.5·med'
write_config 'grok_model=grok-4.6' 'grok_effort=xhigh'
grok_case "$GROK_PAIR"
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr✓spare·grok-4.6·xh'
write_config
# Auto orders vendors by the daily budget of the account each one selected, so grok leads here on
# its 10% week and codex trails on its 48% one — the old fixed claudeb→codex→gemini→grok order is
# gone, and no vendor has a promotion rule of its own.
next_line=$(head -n1 <<<"$output")
assert before "$next_line" 'grok spare' 'claudeb session'
assert before "$next_line" 'claudeb session' 'gemini main'
assert before "$next_line" 'gemini main' 'codex main'
# A vendor with nothing selectable has no budget to compare and takes the tail.
run_filter golden ".vendors.grok = $GROK_PAIR
  | del(.vendors.codex, .vendors.gemini)
  | .vendors.claude.accounts |= map(.enabled = false)"
assert test "${output%%$'\n'*}" = 'NEXT: grok spare · auto · high — 10%  |  claudeb unavailable — every account is out of the worker pool  |  codex unavailable · high — WALLED  |  gemini unavailable'
# The order follows the numbers, not the vendor: the same store with codex barely touched puts
# codex at the head and grok behind claudeb.
run_filter golden ".vendors.grok = $GROK_PAIR
  | .vendors.codex.accounts = [{account:\"main\",five_hour:{used_pct:2},weekly:{used_pct:2}}]
  | .vendors.grok.accounts = [{account:\"spare\",enabled:true,weekly:{used_pct:30}}]"
next_line=$(head -n1 <<<"$output")
assert contains "$next_line" 'NEXT: codex main · high — 2%'
assert before "$next_line" 'codex main' 'claudeb session'
assert before "$next_line" 'claudeb session' 'gemini main'
assert before "$next_line" 'gemini main' 'grok spare'
# A nearer reset moves a vendor up the line for the same reason it moves an account up a pool.
run_filter golden ".vendors.grok = $GROK_PAIR
  | .vendors.gemini.weekly.resets_at = 2000010800"
next_line=$(head -n1 <<<"$output")
assert contains "$next_line" 'NEXT: gemini main · pro · high — ACCOUNT: main'
assert before "$next_line" 'gemini main' 'grok spare'
# `worker=grok` is a mode arm like `worker=gemini`: the vendor leads the line whatever the pool says.
printf '%s\n' 'worker=grok' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"
grok_case "$GROK_PAIR"
assert contains "$(head -n1 <<<"$output")" 'NEXT: grok spare · auto · high — 10%'
assert before "$(head -n1 <<<"$output")" 'grok spare' 'claudeb session'
write_config

# Rule 2 for a vendor with one bucket: largest weekly budget, then name — and `--exclude` walks
# that same order until nothing is left.
grok_case '{available:true,accounts:[
  {account:"main",enabled:true,weekly:{used_pct:20}},
  {account:"zeta",enabled:true,weekly:{used_pct:20}}]}'
assert contains "$(head -n1 <<<"$output")" 'grok main · auto · high — 20%'
assert before "$(sed -n '4p' <<<"$output")" 'main 20%' 'zeta 20%'
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
assert contains "$(head -n1 <<<"$output")" 'grok fresh · auto · high — 40%'
assert contains "$(sed -n '4p' <<<"$output")" 'stale 10% auth expired'
assert not_contains "$(sed -n '4p' <<<"$output")" 'stale 10% auth expired WALLED'
assert before "$(sed -n '4p' <<<"$output")" 'fresh 40%' 'stale 10%'
grok_query '{"available":true,"accounts":[
  {"account":"fresh","enabled":true,"weekly":{"used_pct":40},"auth":{"status":"ok"}},
  {"account":"stale","enabled":true,"weekly":{"used_pct":10},"auth":{"status":"expired"}}]}' \
  --account grok --exclude fresh
assert test "$query_rc" -eq 0
assert test "$query_out" = stale
grok_case '{available:true,accounts:[
  {account:"gone",enabled:true,weekly:{used_pct:10},auth:{status:"needs_login"}},
  {account:"fresh",enabled:true,weekly:{used_pct:40},auth:{status:"ok"}}]}'
assert contains "$(head -n1 <<<"$output")" 'grok fresh · auto · high — 40%'
assert contains "$(sed -n '4p' <<<"$output")" 'gone 10% WALLED auth!'
grok_case '{available:true,accounts:[
  {account:"gone",enabled:true,weekly:{used_pct:10},auth:{status:"needs_login"}}]}'
assert contains "$(sed -n '4p' <<<"$output")" 'grok: login needed'
assert not_contains "$(head -n1 <<<"$output")" 'grok gone'
# Rule 3: effective 100% in the one bucket it has is grok's whole wall, and there is no five-hour
# reading to defer on — 85% ranks by spend like any other number.
grok_case '{available:true,accounts:[
  {account:"spent",enabled:true,weekly:{used_pct:100}},
  {account:"hot",enabled:true,weekly:{used_pct:85}}]}'
assert contains "$(head -n1 <<<"$output")" 'grok hot · auto · high — 85%'
assert contains "$(sed -n '4p' <<<"$output")" 'spent 100% WALLED'
assert not_contains "$output" '5h!'
# An account out of the pool is out of the answer, and a vendor whose whole pool is off says so
# rather than reporting a limit.
grok_case '{available:true,accounts:[
  {account:"supergrok",enabled:false,weekly:{used_pct:40}},
  {account:"spare",enabled:false,weekly:{used_pct:10}}]}'
assert contains "$(head -n1 <<<"$output")" 'grok unavailable · auto · high — every account is out of the worker pool'
assert contains "$(sed -n '4p' <<<"$output")" 'spare 10% off'
grok_query '{"available":true,"accounts":[
  {"account":"supergrok","enabled":false,"weekly":{"used_pct":40}}]}' --account grok
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'every grok account is out of the worker pool' "$WORK/query.err"
# A vendor half-installed — a store row the collector has written no reading into yet — has no
# wall to report, and saying it has one sends Egor hunting for a limit that does not exist.
grok_case '{available:false}'
assert contains "$(head -n1 <<<"$output")" 'grok unavailable · auto · high — no quota data'
assert not_contains "$output" 'grok unavailable · auto · high — WALLED'
assert contains "$(sed -n '4p' <<<"$output")" 'grok: unavailable'
grok_case '{available:true,accounts:[{account:"supergrok",enabled:true}]}'
assert contains "$(head -n1 <<<"$output")" 'grok unavailable · auto · high — no quota data'
assert contains "$(sed -n '4p' <<<"$output")" 'grok: supergrok ? (wk→?)'

# The pin: the one override above the pool, lapsing loudly with a reason, and ended outright by a
# wall on fresh data — the same rule the other three vendors follow, with only the key differing.
write_config 'grok_profile=supergrok'
grok_case '{available:true,accounts:[
  {account:"supergrok",enabled:false,weekly:{used_pct:40}},
  {account:"spare",enabled:true,weekly:{used_pct:10}}]}'
assert contains "$(head -n1 <<<"$output")" 'grok supergrok · auto · high — 40% PINNED'
assert contains "$(sed -n '4p' <<<"$output")" 'supergrok 40% PINNED off'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi gr✓supergrok·auto·hi'
write_config 'grok_profile=ghost'
grok_case "$GROK_PAIR"
assert contains "$(head -n1 <<<"$output")" 'grok pin ghost absent → spare · auto · high — 10%'
assert contains "$(sed -n '4p' <<<"$output")" 'grok: pin ghost absent → spare'
write_config 'grok_profile=locked'
grok_case '{available:true,accounts:[
  {account:"locked",enabled:true,weekly:{used_pct:10},auth:{status:"needs_login"}},
  {account:"spare",enabled:true,weekly:{used_pct:40}}]}'
assert contains "$(head -n1 <<<"$output")" 'grok pin locked auth unavailable → spare'
assert test "$(sed -n 's/^grok_profile=//p' "$CONFIG")" = locked
write_config 'grok_profile=blank'
grok_case '{available:true,accounts:[
  {account:"blank",enabled:true},
  {account:"spare",enabled:true,weekly:{used_pct:40}}]}'
assert contains "$(head -n1 <<<"$output")" 'grok pin blank no quota data → spare'
assert test "$(sed -n 's/^grok_profile=//p' "$CONFIG")" = blank
cleared_case grok_profile spent spare golden '.vendors.grok = {available:true,accounts:[
  {account:"spent",enabled:true,weekly:{used_pct:100}},
  {account:"spare",enabled:true,weekly:{used_pct:10}}]}'
write_config

# A role switch is not a limit: with `grok_workers=off` every surface says off, the account
# listing stays intact, and the statusline reads `⏸off` rather than a lookup that failed.
write_config 'grok_workers=off'
grok_case "$GROK_PAIR"
next_line=$(head -n1 <<<"$output")
assert contains "$next_line" 'grok — off for workers'
assert not_contains "$next_line" 'grok unavailable'
assert not_contains "$next_line" 'grok spare'
assert test "${next_line##*  |  }" = 'grok — off for workers'
assert contains "$(sed -n '4p' <<<"$output")" 'grok: spare 10% (wk→?) | supergrok 40% (wk→?)'
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
assert contains "$(head -n1 <<<"$output")" 'grok supergrok · auto · high — 40% PINNED'
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
assert contains "$(head -n1 <<<"$output")" 'NEXT: ALL WALLED, ask Egor'
write_config
run_filter all_walled '.vendors.grok = {available:true,accounts:[
  {account:"spare",enabled:true,weekly:{used_pct:10}}]}'
assert not_contains "$output" 'ALL WALLED'
assert contains "$(head -n1 <<<"$output")" 'grok spare · auto · high — 10%'
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
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb off · opus · high — ACCOUNT: off (PINNED)'
assert not_contains "$output" 'off for workers'
# A pin that cannot serve leaves the wall standing, and the pool's own candidate is not handed
# over in its place: the switch is not advice.
write_config 'claudeb_profile=ghost' 'claudeb_workers=off'
query_case claude_pool --account claudeb
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert test "$(cat "$WORK/query.err")" = 'worker-pick: claudeb is switched off for workers'
run_case claude_pool
assert contains "$(head -n1 <<<"$output")" 'claudeb — off for workers'
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
# The table is the workers view: a workers-off vendor is never auto-selected, says so where the
# routing decision is read, and keeps its account listing — a closed role is not a limit, and the
# menubar still shows what those accounts hold.
write_config 'claudeb_workers=off'
run_case golden
assert contains "$(head -n1 <<<"$output")" 'claudeb — off for workers'
assert not_contains "$(head -n1 <<<"$output")" 'ACCOUNT: worker'
assert contains "$(sed -n '4p' <<<"$output")" 'claude: session($100)* 5h 20% wk 20%'
assert contains "$(sed -n '4p' <<<"$output")" 'worker($20) 5h 30% wk 40%'
# A parked vendor is not an unpredictable one: the statusline reads `~?` as a lookup that failed.
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb⏸off·opus·hi gx✓main·pro·hi'
write_config 'codex_workers=off'
run_case golden
assert contains "$(head -n1 <<<"$output")" 'codex — off for workers'
assert not_contains "$(head -n1 <<<"$output")" 'codex main · high'
assert contains "$(sed -n '2p' <<<"$output")" 'codex: main 48% 5h 48% ↻1 (5h→?, wk→?)'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx⏸off·sol·hi cb~session·opus·hi gx✓main·pro·hi'
write_config 'gemini_workers=off'
run_case golden
assert contains "$(head -n1 <<<"$output")" 'gemini — off for workers'
assert not_contains "$(head -n1 <<<"$output")" 'ACCOUNT: main'
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: main 25% 5h 12% (5h→?, wk→?)'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx⏸off·pro·hi'
# A closed vendor is never the routing answer, and the first segment is what the answer is read
# from, so it trails the line however the mode usually orders the vendors.
write_config 'claudeb_workers=off'
run_case golden
next_line=$(head -n1 <<<"$output")
assert contains "$next_line" 'NEXT: gemini main · pro · high — ACCOUNT: main'
assert contains "$next_line" 'codex main · high — 48%'
assert test "${next_line##*  |  }" = 'claudeb — off for workers'
# A closed vendor never speaks for a wall either: the shortened `codex — WALLED` segment the
# gemini-first shape prints is quota talking, and codex here has 48% of its week left.
write_config 'claudeb_workers=off' 'codex_workers=off'
run_case golden
next_line=$(head -n1 <<<"$output")
assert contains "$next_line" 'NEXT: gemini main · pro · high — ACCOUNT: main'
assert contains "$next_line" 'codex — off for workers'
assert not_contains "$next_line" 'codex — WALLED'
assert contains "$next_line" 'claudeb — off for workers'
# A vendor held back from a role has quota it simply may not spend here, so the verdict that
# sends the owner hunting for limits is read over the vendors still open for workers.
write_config 'claudeb_workers=off' 'codex_workers=off' 'gemini_workers=off'
run_case all_walled
assert not_contains "$output" 'ALL WALLED'
assert not_contains "$(head -n1 <<<"$output")" 'codex — WALLED'
assert contains "$(head -n1 <<<"$output")" 'claudeb — off for workers'
# The pool a closed vendor holds is not evidence for a verdict about the open ones either: with
# claudeb parked, codex and gemini merely have no measured reading — nothing hit a wall.
write_config 'claudeb_workers=off'
run_filter claude_pool '.vendors.codex = {available:true,accounts:[{account:"main"}]}
  | .vendors.gemini = {available:true,group:"Gemini Models"}'
assert not_contains "$output" 'ALL WALLED'
assert contains "$(head -n1 <<<"$output")" 'claudeb — off for workers'
# One vendor closed does not soften the verdict for the ones that are open — and the closure
# stays visible beside it.
write_config 'claudeb_workers=off'
run_case all_walled
assert contains "$(head -n1 <<<"$output")" 'NEXT: ALL WALLED, ask Egor'
assert contains "$(head -n1 <<<"$output")" 'codex — WALLED'
assert test "${output%%$'\n'*}" = 'NEXT: ALL WALLED, ask Egor  |  codex — WALLED  |  claudeb — off for workers'
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
assert contains "$(head -n1 <<<"$output")" 'NEXT: ALL WALLED, ask Egor'
assert contains "$(head -n1 <<<"$output")" 'codex — WALLED'
query_case all_walled --account claudeb
assert test "$query_rc" -eq 3
assert test -z "$query_out"
query_case all_walled --account codex
assert test "$query_rc" -eq 3
assert grep -q 'no selectable codex account' "$WORK/query.err"

# Data hygiene (shared-invariants y): effective_pct beats a stale raw reading, a bucket past
# its reset reads 0%, and a weekly stamped `origin: headers` was never measured at all.
run_case stale
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb effective · opus · high'
assert contains "$output" 'effective($100) 5h 20% wk 20%'
assert contains "$output" 'DATA: STALE (166 min old)'
run_case expired
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb expired · opus · high'
assert contains "$output" 'expired($100) 5h 0% wk 10%'
run_filter golden '.vendors.claude.accounts |= map(
  if .account == "worker" then .weekly = {used_pct:100,origin:"headers"} else . end)'
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb session · opus · high'
assert contains "$(sed -n '4p' <<<"$output")" 'worker($20) 5h 30% wk ?'
# The synthetic week is dropped, not the account: with no weekly bucket it is paced over the
# neutral window on its five-hour reading and stays a candidate.
query --account claudeb --exclude session
assert test "$query_rc" -eq 0
assert test "$query_out" = worker
run_case reset
assert contains "$output" 'later($100) 5h 10% wk 50% fb 50%'
run_case gemini_stale
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: main 30% 5h 20%'
assert contains "$output" 'DATA: STALE (166 min old)'

# A disabled account is not polled, so its frozen as_of must not drive the DATA age; the same
# timestamps on an enabled account must (control), and a pinned account counts even when off.
run_filter gemini_fresh '.vendors.claude.accounts = [{account:"dormant",enabled:false,auth:"ok",
  five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: fresh (0 min old)'
run_filter gemini_fresh '.vendors.claude.accounts = [{account:"dormant",enabled:true,auth:"ok",
  five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: STALE (16666 min old)'
run_filter gemini_fresh '.vendors.claude.accounts = [{account:"dormant",auth:"ok",
  five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: fresh (0 min old)'
run_filter gemini_fresh '.vendors.gemini.enabled = false
  | .vendors.claude.accounts = [{account:"dormant",enabled:false,auth:"ok",
    five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: STALE (16666 min old)'
write_config 'claudeb_profile=dormant'
run_filter gemini_fresh '.vendors.claude.accounts = [{account:"dormant",enabled:false,auth:"ok",
  five_hour:{used_pct:5,as_of:1999000000},weekly:{used_pct:5,as_of:1999000000}}]'
assert contains "$output" 'DATA: STALE (16666 min old)'
write_config
run_filter golden 'del(.fetched_at, .vendors.gemini.five_hour.as_of, .vendors.gemini.weekly.as_of)'
assert contains "$output" 'DATA: no timestamp'

# Model and effort are read from worker-model and printed verbatim: quota state never
# silently degrades the work.
printf '%s\n' 'worker=auto' 'codex_effort=medium' 'claudeb_model=sonnet' 'claudeb_effort=medium' \
  'gemini_model=flash' 'gemini_effort=medium' >"$CONFIG"
run_case claude_pool
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb session · sonnet · medium'
assert contains "$(head -n1 <<<"$output")" 'codex unavailable · medium'
printf '%s\n' 'worker=gemini' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=flash' 'gemini_effort=medium' >"$CONFIG"
run_case gemini_fresh
assert contains "$(head -n1 <<<"$output")" 'NEXT: gemini main · flash · medium — ACCOUNT: main'
printf '%s\n' 'worker=sonnet' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"
run_case golden
assert test "$(awk -F'  \\|  ' '{print NF}' <<<"$(head -n1 <<<"$output")")" -eq 2
write_config

# The golden output is the whole contract in one store: line order, the session-account footnote,
# the statusline cache line, and no POLICY prose anywhere.
run_case golden
assert contains "$(head -n1 <<<"$output")" 'ACCOUNT: session'
assert not_contains "$(head -n1 <<<"$output")" 'claudeb worker '
assert contains "$output" 'session($100)*'
assert contains "$(sed -n '4p' <<<"$output")" '(* = this session account)'
assert not_contains "$output" 'RESERVE'
assert contains "$output" 'SESSION: session — fb 10%, wk 20%'
assert test "$(sed -n '1p' <<<"$output" | cut -d: -f1)" = NEXT
assert test "$(sed -n '2p' <<<"$output" | cut -d: -f1)" = codex
assert test "$(sed -n '3p' <<<"$output" | cut -d: -f1)" = gemini
assert test "$(sed -n '4p' <<<"$output" | cut -d: -f1)" = claude
assert test "$(sed -n '5p' <<<"$output" | cut -d: -f1)" = DATA
assert test "$(sed -n '6p' <<<"$output" | cut -d: -f1)" = SESSION
assert test "$(wc -l <<<"$output" | tr -d ' ')" -eq 6
assert not_contains "$output" '# Worker routing policy'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~session·opus·hi gx✓main·pro·hi'
assert test -z "$(find "$CACHE" -name '*.tmp.*' -print -quit)"
assert cmp -s <(printf '%s\n' "$output") "$GOLDEN"
# Display bands are render-only: an unreachable account stays visible, below the candidates.
run_filter golden '.vendors.claude.accounts += [{
  account:"blocked",enabled:true,rotation:{usable:{general:false,fable:false}},
  five_hour:{used_pct:0},weekly:{used_pct:0},fable:{used_pct:0}}]'
claude_order=$(sed -n '4p' <<<"$output")
assert before "$claude_order" 'session($100)*' 'worker($20)'
assert before "$claude_order" 'worker($20)' 'blocked($100)'
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

printf 'PASS: %s assertions; the routing-contract rules (pool-toggle candidacy with a computable daily budget, pin-or-largest-budget selection where a nearer reset outranks an equal percentage and equal budgets order by name, walls only at effective 100%% or dead auth), the five-hour deferral at 80%% with its `5h!` tag, claims as the second soft key (fresh demotes, TTL-expired does not, per-vendor, table never writes one, a refused query records nothing), the session account as an ordinary candidate in every role with no reserve anywhere, the three roles including a chat that sees no pin, loud pin lapses, the fable bucket on explicit ask, --exclude re-queries and ALL WALLED exit 3, an emptied pool named as the switch it is rather than a limit, auto vendor order following the selected accounts budgets rather than a fixed vendor list, grok as the fourth vendor (weekly-only ranking, refreshable `expired` auth behind `ok`, mode arm, `gr` cache field, and absence that renders as absence), data hygiene and DATA age sourcing, model/effort straight from worker-model, and the output/cache golden contract with no routing prose\n' "$asserts"
