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
printf '%s\n' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' >"$CONFIG"
printf '%s\n' 'burnt=100' 'fresh=100' 'ordinary=100' 'reserved=100' 'small=20' \
  'at-floor=100' 'safe=100' 'claude-floor=100' 'soon=100' 'later=100' \
  'effective=100' 'raw=100' 'expired=100' 'live=100' 'session=100' 'worker=20' \
  'fbcap=100' 'nofb=100' 'missing-low=20' 'missing-high=100' \
  'stale-existing=100' >"$TIERS"

run_case() {
  local name=$1
  jq -c --arg name "$name" '.[$name]' "$FIXTURES" >"$STORE" || fail "fixture $name missing"
  output=$(TZ=UTC HOME="$HOME_FIXTURE" LLM_LIMITS_FILE="$STORE" WORKER_PICK_CONFIG_FILE="$CONFIG" \
    WORKER_PICK_TIERS_FILE="$TIERS" WORKER_PICK_CACHE_DIR="$CACHE" WORKER_PICK_NOW=2000000000 \
    CLAUDE_LIMITS_ACCOUNT=session "$SCRIPT") || fail "worker-pick failed for $name"
}

# Run a fixture with a non-default configured model/effort, then restore the default.
run_case_cfg() {
  printf '%s\n' 'codex_effort=high' "claudeb_model=$2" "claudeb_effort=$3" >"$CONFIG"
  run_case "$1"
  printf '%s\n' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high' >"$CONFIG"
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
assert test "$(head -n1 <<<"$output")" = 'NEXT: ALL FLOORED, ask Egor  |  codex — WALLED'
assert contains "$output" 'POLICY: ALL FLOORED, ask Egor'

run_case reset
assert contains "$output" 'NEXT: claudeb soon '
assert contains "$(head -n1 <<<"$output")" 'pre-reset cap 40%'

run_case codex_credit
assert contains "$(head -n1 <<<"$output")" 'codex with-credit · high — FRESH'
assert contains "$output" 'with-credit 48% runway 152% ↻1'
assert contains "$output" 'plain 48% runway 52% ↻0'
assert contains "$output" '↻1 manual'

run_case codex_plain
assert contains "$(head -n1 <<<"$output")" 'codex plain · high — FRESH'
assert contains "$output" 'plain 48% runway 52% ↻0'

run_case codex_tight
assert contains "$(head -n1 <<<"$output")" 'codex tight · high — TIGHT'
assert contains "$output" 'tight 85% runway 15% ↻0'

run_case stale
assert contains "$output" 'NEXT: claudeb effective '
assert contains "$output" 'effective($100) 5h 20% wk 20%'
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
assert test "$(sed -n '3p' <<<"$output" | cut -d: -f1)" = claude
assert test "$(sed -n '4p' <<<"$output" | cut -d: -f1)" = POLICY
assert test "$(sed -n '5p' <<<"$output" | cut -d: -f1)" = DATA
assert test "$(sed -n '6p' <<<"$output" | cut -d: -f1)" = SESSION
assert test "$(cat "$CACHE/worker-pick.line.session")" = 'cx✓main·hi cb~worker·opus·hi'
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
assert contains "$policy" 'five of every ten'

printf 'PASS: %s assertions; R1-R9 scoring, Codex reset runway, stale data, output/cache golden contract, session and policy text\n' "$asserts"
