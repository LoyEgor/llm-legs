#!/usr/bin/env bash
set -u

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

HOME_FIXTURE="$WORK/home"
STORE="$WORK/limits.json"
CONFIG="$WORK/worker-model"
TIERS="$WORK/account-tiers"
CACHE="$WORK/cache"
mkdir -p "$HOME_FIXTURE" "$CACHE"
printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"
printf '%s\n' 'burnt=100' 'fresh=100' 'ordinary=100' 'reserved=100' 'small=20' \
  'at-floor=100' 'safe=100' 'claude-floor=100' 'soon=100' 'later=100' \
  'effective=100' 'raw=100' 'expired=100' 'live=100' 'session=100' 'worker=20' \
  'fbcap=100' 'nofb=100' 'missing-low=20' 'missing-high=100' \
  'stale-existing=100' >"$TIERS"

run_case() {
  local name=$1
  jq -c --arg name "$name" '.[$name]' "$FIXTURES" >"$STORE" || fail "fixture $name missing"
  run_store "$name"
}
run_filter() {
  local name=$1 filter=$2
  jq -c --arg name "$name" ".[\$name] | $filter" "$FIXTURES" >"$STORE" || fail "fixture $name transform failed"
  run_store "$name"
}
run_store() {
  local name=$1
  output=$(TZ=UTC HOME="$HOME_FIXTURE" LLM_LIMITS_FILE="$STORE" WORKER_PICK_CONFIG_FILE="$CONFIG" \
    WORKER_PICK_TIERS_FILE="$TIERS" WORKER_PICK_CACHE_DIR="$CACHE" WORKER_PICK_NOW=2000000000 \
    CLAUDE_LIMITS_ACCOUNT=session "$SCRIPT") || fail "worker-pick failed for $name"
}

printf '%s\n' 'worker=gemini' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' 'gemini_profile=work' >"$CONFIG"
printf 'not-json\n' >"$STORE"
run_store malformed
assert contains "$(head -n1 <<<"$output")" 'NEXT: gemini work · pro · high — unavailable (limits parse failed)'
printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"

# Run a fixture with a non-default configured model/effort, then restore the default.
run_case_cfg() {
  printf '%s\n' 'worker=auto' 'codex_effort=high' "claudeb_model=$2" "claudeb_effort=$3" \
    'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"
  run_case "$1"
  printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
    'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"
}

run_case r1
assert contains "$output" 'NEXT: claudeb burnt '
assert contains "$output" 'claude: burnt($100)'

run_case r2
assert contains "$output" 'NEXT: claudeb ordinary '
assert contains "$output" 'reserved($100)'
assert contains "$output" 'Fable-reserved'
assert contains "$output" 'SESSION: reserved — fb 5%, wk 75%'

run_case r3
assert contains "$output" 'NEXT: claudeb small '
assert contains "$output" 'small($20)'
assert contains "$output" 'no-Fable'

# Two non-session accounts, equal base headroom, neither R2-reserved: the only
# differentiator is R3, which rewards the fable-incapable account. If R3's sign
# were flipped (- instead of +), fbcap would win instead — this asserts nofb.
run_case r3_decides
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb nofb '
assert not_contains "$(head -n1 <<<"$output")" 'NEXT: claudeb fbcap '
assert contains "$output" 'nofb($100)'
assert contains "$output" 'no-Fable'

# R8: weekly-vs-fable gap on a fable-capable account modulates the claudeb
# model/effort recommendation and, past the gap threshold, drops the account.
run_case r8_no_demote
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb protected · opus · high'
assert not_contains "$output" 'R8 demote'

# Ladder rung 1: from the default opus·high a demote lands on opus·medium.
run_case r8_demote
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb demoted · opus · medium'
assert contains "$(head -n1 <<<"$output")" '[R8 demote: opus·high→opus·medium; wk>fb]'

# Ladder rung 2: from opus·medium a demote lands on sonnet·high, the weakest allowed rung.
run_case_cfg r8_demote opus medium
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb demoted · sonnet · high'
assert contains "$(head -n1 <<<"$output")" '[R8 demote: opus·medium→sonnet·high; wk>fb]'

# Bottom rung: a demote at sonnet·high cannot go weaker — clamps in place, no step.
run_case_cfg r8_demote sonnet high
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb demoted · sonnet · high'
assert not_contains "$output" 'R8 demote'

# General floor: a configured sonnet·medium is snapped up to sonnet·high with no R8 step.
run_case_cfg r8_no_demote sonnet medium
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb protected · sonnet · high'
assert not_contains "$output" 'R8 demote'

run_case r8_exclude
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb clean · opus · high'
assert not_contains "$(head -n1 <<<"$output")" 'claudeb gappy '
assert contains "$output" 'gappy($100)'
assert contains "$output" 'Fable-gap-excluded'

run_case r8_exempt
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb nofable · opus · high'
assert not_contains "$output" 'R8 demote'
assert contains "$output" 'no-Fable'

run_case r9_missing_low
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb missing-low '
assert contains "$output" 'missing-low($20) 5h 5% wk ? fb 87% score 28 cap 85%'

run_case r9_missing_high
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb missing-high '
assert contains "$output" 'missing-high($100) 5h 60% wk ? fb 40% score 30 cap 30%'

run_case r9_existing_stale
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb safe '
assert contains "$output" 'stale-existing($100) 5h 0% wk 95%'
assert contains "$output" 'stale-existing($100) 5h 0% wk 95% fb 40% score 0 cap 0% Fable-gap-excluded FLOOR'

run_case floor
assert contains "$output" 'NEXT: claudeb safe '
assert contains "$output" 'at-floor($100)'
assert contains "$output" 'FLOOR'
assert not_contains "$(head -n1 <<<"$output")" 'claudeb at-floor '

run_case all_floor
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb claude-floor '
assert contains "$(head -n1 <<<"$output")" 'WARN: no account below HEADROOM_PCT, using least-burnt'

run_filter all_floor '.vendors.gemini = {
  available:true,group:"Gemini Models",
  five_hour:{used_pct:20,as_of:2000000000},weekly:{used_pct:30,as_of:2000000000}}'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main'
assert not_contains "$(head -n1 <<<"$output")" 'ALL FLOORED'
assert not_contains "$(sed -n '5p' <<<"$output")" 'ALL FLOORED'

run_filter floor '.vendors.claude.accounts |= map(.five_hour.used_pct = (if .account == "at-floor" then 96 else 92 end) | .weekly.used_pct = (if .account == "at-floor" then 10 else 92 end) | .fable.used_pct = .weekly.used_pct)'
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb safe '
assert contains "$(head -n1 <<<"$output")" 'WARN: no account below HEADROOM_PCT, using least-burnt'

run_case reset
assert contains "$output" 'NEXT: claudeb soon '
assert contains "$(head -n1 <<<"$output")" 'pre-reset cap 40%'

run_case codex_credit
assert contains "$(head -n1 <<<"$output")" 'codex with-credit · high — FRESH'
assert contains "$output" 'with-credit 48% runway 152% ↻1'
assert contains "$output" 'plain 48% runway 52% ↻0'
assert contains "$output" '↻1 manual'

# Worker-pool membership is the user's own "don't burn this one", so it excludes an account from
# selection for every vendor — and stays visible in the line, because an account that silently
# vanished from the ranking is indistinguishable from a collector bug.
run_filter codex_credit '.vendors.codex.accounts |= map(if .account == "with-credit" then .enabled = false else . end)'
assert contains "$(head -n1 <<<"$output")" 'codex plain · '
assert contains "$output" 'with-credit 48% runway 152% ↻1 off'
run_filter codex_credit '.vendors.codex.accounts |= map(.enabled = false)'
assert contains "$(head -n1 <<<"$output")" 'codex unavailable'
assert contains "$output" 'with-credit 48% off'
assert contains "$output" 'plain 48% off'

run_filter gemini_fresh '.vendors.gemini.accounts = [(.vendors.gemini + {account:"main",enabled:false})]'
assert contains "$output" 'gemini: main 35% runway 65% off'
assert not_contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT'
# The legacy single-account shape carries the flag at vendor level; it must not fail open.
run_filter gemini_fresh '.vendors.gemini.enabled = false'
assert contains "$output" 'gemini: main 35% runway 65% off'

run_case codex_plain
assert contains "$(head -n1 <<<"$output")" 'codex plain · high — FRESH'
assert contains "$output" 'plain 48% runway 52% ↻0'

run_case codex_tight
assert contains "$(head -n1 <<<"$output")" 'codex tight · high — TIGHT'
assert contains "$output" 'tight 85% runway 15% ↻0'

run_case gemini_fresh
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: main 35% runway 65%'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main; pre-reset cap 55% — FRESH'
assert contains "$output" 'DATA: fresh (0 min old)'

run_case gemini_stale
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: main 30% runway 70%'
assert contains "$output" 'DATA: STALE (166 min old)'

run_case gemini_floor
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: main 91% runway 9% FLOOR'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — WALLED'

run_case gemini_wrong_group
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: no Gemini Models quota data'
assert not_contains "$(head -n1 <<<"$output")" 'ACCOUNT: main'

run_filter gemini_fresh '.vendors.gemini = {
  available:false,auth_needed:true,status:"login needed",source:"agy-local-rpc"}'
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: login needed'
assert not_contains "$(sed -n '3p' <<<"$output")" 'unavailable'

run_filter gemini_fresh '.vendors.gemini.group = "Google GEMINI quota"'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main'

run_filter gemini_fresh '.vendors.gemini = {
  available:true,accounts:[
    {account:"main",group:"Gemini Models",five_hour:{used_pct:10,as_of:2000000000},weekly:{used_pct:10,as_of:2000000000}},
    {account:"work",group:"Gemini Models",five_hour:{used_pct:40,as_of:2000000000},weekly:{used_pct:40,as_of:2000000000}}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini work · pro · high — ACCOUNT: work'
assert contains "$(sed -n '3p' <<<"$output")" 'gemini: work 40% runway 60%'
assert contains "$(sed -n '3p' <<<"$output")" 'main 10% runway 90%'

run_filter gemini_fresh '.vendors.gemini = {
  available:true,accounts:[
    {account:"main",group:"Gemini Models",five_hour:{used_pct:10,as_of:2000000000},weekly:{used_pct:10,as_of:2000000000}},
    {account:"work",group:"Gemini Models",auth_needed:true}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main'

run_filter gemini_fresh '
  .vendors.codex = {available:false} |
  .vendors.claude.accounts |= map(.enabled = false)'
assert contains "$(head -n1 <<<"$output")" 'NEXT: gemini main · pro · high — ACCOUNT: main'
assert contains "$(head -n1 <<<"$output")" 'claudeb unavailable'
assert contains "$(head -n1 <<<"$output")" 'codex — WALLED'

printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' 'gemini_profile=main' >"$CONFIG"
run_filter gemini_fresh '.vendors.gemini = {
  available:true,accounts:[
    {account:"main",group:"Gemini Models",five_hour:{used_pct:10,as_of:2000000000},weekly:{used_pct:10,as_of:2000000000}},
    {account:"work",group:"Gemini Models",five_hour:{used_pct:40,as_of:2000000000},weekly:{used_pct:40,as_of:2000000000}}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini main · pro · high — ACCOUNT: main'

printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' 'gemini_profile=work' >"$CONFIG"
run_filter gemini_fresh '.vendors.gemini = {
  available:true,accounts:[
    {account:"main",group:"Gemini Models",five_hour:{used_pct:10,as_of:2000000000},weekly:{used_pct:10,as_of:2000000000}},
    {account:"work",group:"Gemini Models",auth_needed:true}]}'
assert contains "$(head -n1 <<<"$output")" 'gemini pin work is not selectable, ask Egor'
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✗·sol·hi cb~?·opus·hi gx✗work·pro·hi'

printf '%s\n' 'worker=gemini' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=flash' 'gemini_effort=medium' >"$CONFIG"
run_case gemini_fresh
assert contains "$(head -n1 <<<"$output")" 'NEXT: gemini main · flash · medium — ACCOUNT: main'
printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
  'gemini_model=pro' 'gemini_effort=high' >"$CONFIG"

run_filter codex_plain '.vendors.codex.accounts = [
  {account:"main",five_hour:{used_pct:0},weekly:{used_pct:0},reset_credits:3},
  {account:"alpha",five_hour:{used_pct:40},weekly:{used_pct:40},reset_credits:0}]'
assert contains "$(head -n1 <<<"$output")" 'codex alpha · high — FRESH'
assert contains "$(sed -n '2p' <<<"$output")" 'codex: alpha 40% runway 60% ↻0'

run_filter codex_plain '.vendors.codex.accounts = [
  {account:"main",five_hour:{used_pct:48},weekly:{used_pct:48},reset_credits:0},
  {account:"alpha",five_hour:{used_pct:90},weekly:{used_pct:10},reset_credits:0}]'
assert contains "$(head -n1 <<<"$output")" 'codex main · high — FRESH'
assert contains "$output" 'alpha 90% runway 10% ↻0 FLOOR'

run_filter codex_plain '.vendors.codex.accounts = [
  {account:"main",five_hour:{used_pct:0},weekly:{used_pct:0},reset_credits:3},
  {account:"alpha",five_hour:{used_pct:89},weekly:{used_pct:20},reset_credits:0}]'
assert contains "$(head -n1 <<<"$output")" 'codex alpha · high — TIGHT'
assert contains "$(sed -n '2p' <<<"$output")" 'codex: alpha 89% runway 11% ↻0'

# Codex login-needed parity with Gemini: an all-auth-needed vendor reports "login needed",
# not "no authenticated quota data", and never selects the account.
run_filter codex_plain '.vendors.codex = {available:true,accounts:[
  {account:"main",auth_needed:true,status:"login needed"}]}'
assert contains "$output" 'codex: login needed'
assert not_contains "$output" 'codex: no authenticated quota data'
assert contains "$output" 'codex unavailable · high — WALLED'

run_case stale
assert contains "$output" 'NEXT: claudeb effective '
assert contains "$output" 'effective($100) 5h 20% wk 20%'
assert contains "$output" 'DATA: STALE (166 min old)'

run_filter golden 'del(.fetched_at, .vendors.gemini.five_hour.as_of, .vendors.gemini.weekly.as_of)'
assert contains "$(head -n1 <<<"$output")" 'NEXT: claudeb worker '
assert contains "$output" 'DATA: no timestamp'

run_filter golden '.fetched_at = 2000000000 | .vendors.claude.accounts[] |= (if .account == "worker" then .five_hour.used_pct = 5 | .weekly.used_pct = 5 | .five_hour.as_of = 1999990000 | .weekly.as_of = 1999990000 | .fable.as_of = 1999990000 else . end)'
assert contains "$(head -n1 <<<"$output")" 'STALE-REFRESH'
assert contains "$output" 'DATA: STALE (166 min old)'

run_case expired
assert contains "$output" 'NEXT: claudeb expired '
assert contains "$output" 'expired($100) 5h 0%'

run_case golden
assert contains "$(head -n1 <<<"$output")" 'ACCOUNT: worker'
assert not_contains "$(head -n1 <<<"$output")" 'claudeb session '
assert contains "$output" 'session($100)*'
assert contains "$output" 'SESSION: session — fb 10%, wk 20%'
assert test "$(sed -n '1p' <<<"$output" | cut -d: -f1)" = NEXT
assert test "$(sed -n '2p' <<<"$output" | cut -d: -f1)" = codex
assert test "$(sed -n '3p' <<<"$output" | cut -d: -f1)" = gemini
assert test "$(sed -n '4p' <<<"$output" | cut -d: -f1)" = claude
assert test "$(sed -n '5p' <<<"$output" | cut -d: -f1)" = POLICY
assert contains "$(sed -n '5p' <<<"$output")" 'Codex main is last-resort'
assert test "$(sed -n '6p' <<<"$output" | cut -d: -f1)" = DATA
assert test "$(sed -n '7p' <<<"$output" | cut -d: -f1)" = SESSION
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·sol·hi cb~worker·opus·hi gx✓main·pro·hi'
assert test -z "$(find "$CACHE" -name '*.tmp.*' -print -quit)"
assert cmp -s <(printf '%s\n' "$output") "$GOLDEN"

policy=$(sed -n '/^# Worker routing policy/,$p' <<<"$output")
assert contains "$policy" 'design'
assert contains "$policy" 'speed matters'
assert contains "$policy" 'Do not route animation work to Codex'
assert contains "$policy" 'effort `medium`'
assert contains "$policy" '`high` for genuinely complex work'
assert contains "$policy" 'long or multi-step tasks'
assert contains "$policy" 'repository conventions'
assert contains "$policy" 'full implementation worker'
assert contains "$policy" 'conservatively'
assert contains "$policy" 'five of every ten'
assert contains "$policy" 'every usable non-main account of the same vendor ranks ahead'

# `--account claudeb` is the machine-readable face of the same selection: exactly one bare
# account name, so a caller routing a headless run cannot drift from what a worker would get.
QUERY_CACHE="$WORK/query-cache"
mkdir -p "$QUERY_CACHE"
query_env=(TZ=UTC "HOME=$HOME_FIXTURE" "WORKER_PICK_CONFIG_FILE=$CONFIG"
  "WORKER_PICK_TIERS_FILE=$TIERS" "WORKER_PICK_CACHE_DIR=$QUERY_CACHE" WORKER_PICK_NOW=2000000000
  CLAUDE_LIMITS_ACCOUNT=session)
query_account() {
  jq -c --arg name "$1" '.[$name]' "$FIXTURES" >"$STORE" || fail "fixture $1 missing"
  query_out=$(env "${query_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" --account claudeb \
    2>"$WORK/query.err")
  query_rc=$?
}
write_config() {
  printf '%s\n' 'worker=auto' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' \
    'gemini_model=pro' 'gemini_effort=high' ${1:+"claudeb_profile=$1"} >"$CONFIG"
}

query_account golden
assert test "$query_rc" -eq 0
assert test "$query_out" = worker
assert test ! -s "$WORK/query.err"
# A query answers a caller; it does not announce a routing decision, so the statusline's
# prediction stays owned by the real invocation.
assert test -z "$(find "$QUERY_CACHE" -type f -print -quit)"

# The pin is the caller's own choice, so a query honors it...
write_config worker
query_account golden
assert test "$query_rc" -eq 0
assert test "$query_out" = worker
# ...and a pin it cannot honor fails, never quietly resolving to a different account — routing
# around the pin is exactly what the removed proxy used to do.
write_config session
query_account golden
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'no selectable claudeb account' "$WORK/query.err"
write_config

# Unusable data has no fail-safe here: a guessed account would send a caller at an account this
# data cannot vouch for.
missing_out=$(env "${query_env[@]}" "LLM_LIMITS_FILE=$WORK/absent.json" "$SCRIPT" \
  --account claudeb 2>"$WORK/query-missing.err")
missing_rc=$?
assert test "$missing_rc" -eq 3
assert test -z "$missing_out"
assert grep -q 'cannot select a claudeb account' "$WORK/query-missing.err"

# Every vendor answers the same way, and an unknown one is refused by name rather than
# answered with an account nobody asked about.
query_vendor_account() {
  jq -c --arg name "$1" '.[$name]' "$FIXTURES" >"$STORE" || fail "fixture $1 missing"
  shift
  query_out=$(env "${query_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" "$@" \
    2>"$WORK/query.err")
  query_rc=$?
}
query_vendor_account codex_credit --account codex
assert test "$query_rc" -eq 0
assert test "$query_out" = with-credit
# `--exclude` is how a caller that just watched an account wall asks for the next one.
query_vendor_account codex_credit --account codex --exclude with-credit
assert test "$query_rc" -eq 0
assert test "$query_out" = plain
query_vendor_account codex_credit --account codex --exclude with-credit,plain
assert test "$query_rc" -eq 3
assert test -z "$query_out"
assert grep -q 'no selectable codex account' "$WORK/query.err"
query_vendor_account gemini_fresh --account gemini
assert test "$query_rc" -eq 0
assert test "$query_out" = main
query_vendor_account gemini_fresh --account gemini --exclude main
assert test "$query_rc" -eq 3
assert grep -q 'no selectable gemini account' "$WORK/query.err"
query_vendor_account golden --account claudeb --exclude worker
assert test "$query_rc" -eq 3
assert grep -q 'no selectable claudeb account' "$WORK/query.err"

# Exclusion is by name, not by substring: `com` and `notcom` coexist in the real store, so a
# containment test would drop the wrong account.
query_vendor_account golden --account claudeb --exclude worker2
assert test "$query_rc" -eq 0
assert test "$query_out" = worker
# The pin is not a way around the exclusion — it reads from the same filtered candidate set.
write_config worker
query_vendor_account golden --account claudeb --exclude worker
assert test "$query_rc" -eq 3
assert test -z "$query_out"
write_config

# An argument that is silently ignored lets a caller believe it constrained the answer.
# A value naming nothing would widen the query instead of narrowing it, so it is refused too.
for bad in "--account nosuchvendor" "--exclude com" "--account" "--account claudeb --bogus x" "stray" \
           "--account claudeb --exclude" "--exclude"; do
  bad_out=$(env "${query_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" $bad 2>"$WORK/query-bad.err")
  bad_rc=$?
  assert test "$bad_rc" -eq 2
  assert test -z "$bad_out"
  assert grep -q '^usage: worker-pick' "$WORK/query-bad.err"
done
for empty_exclude in "" ",,"; do
  bad_out=$(env "${query_env[@]}" "LLM_LIMITS_FILE=$STORE" "$SCRIPT" --account claudeb \
    --exclude "$empty_exclude" 2>"$WORK/query-bad.err")
  bad_rc=$?
  assert test "$bad_rc" -eq 2
  assert test -z "$bad_out"
  assert grep -q 'needs at least one account name' "$WORK/query-bad.err"
done

printf 'PASS: %s assertions; R1-R9 scoring, Codex and Gemini worker-pool exclusion still visible as `off`, Codex reset runway and main-last priority, Gemini multi-account selection/pin/login exclusion/freshness/floor/toggle routing, output/cache golden contract, session and policy text, and the --account query contract (bare name per vendor, --exclude for the next-after-a-wall case, pin honored or failed loudly, no cache write, no fail-safe guess, unknown arguments refused)\n' "$asserts"
