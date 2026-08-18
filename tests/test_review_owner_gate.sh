#!/usr/bin/env bash
# bin/review-owner-gate.sh: tier T3 and any tier's --max are denied until Egor names one himself.
# No network, no daemon; every marker is written into a fixture store.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/bin/review-owner-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDEB_DIR="$WORK/store"
unset WORKER_STATS_DIR
GRANTS="$CLAUDEB_DIR/worker-stats/review-grants"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
contains() { grep -Fq -- "$2" <<<"$1"; }
lacks() { ! grep -Fq -- "$2" <<<"$1"; }
denied() { contains "$1" '"permissionDecision":"deny"'; }
allowed() { lacks "$1" '"permissionDecision"'; }

bash_event() {
  jq -cn --arg c "$1" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' | "$GATE" bash
}

prompt_event() {
  jq -cn --arg p "$1" '{hook_event_name: "UserPromptSubmit", session_id: "s", prompt: $p}' \
    | "$GATE" prompt
}

T3_COMMAND='review-bench review --worktree --tier T3 --foreground'
MAX_COMMAND='review-bench review HEAD --tier T2 --max --foreground'

# --- Unnamed: the two owner-only panels are refused, everything else passes through ------------
assert denied "$(bash_event "$T3_COMMAND")"
assert denied "$(bash_event "$MAX_COMMAND")"
assert denied "$(bash_event 'review-bench run HEAD --tier T3 --foreground')"
assert denied "$(bash_event 'review-bench review --worktree --tier=T3')"
for ordinary in \
  'review-bench review --worktree --tier T2 --foreground' \
  'review-bench coverage --repo .' \
  'review-bench tiers --table' \
  'review-bench run HEAD --raters oc-kimik3 --max-tokens 32000' \
  "grep -n -- '--max' bin/review-bench" \
  'rg "review-bench review --tier T3" docs' \
  "echo '--tier T3' && review-bench review --worktree --tier T2"; do
  assert allowed "$(bash_event "$ordinary")"
done

# An ordinary prompt names nothing.
assert lacks "$(prompt_event 'почини тесты и покажи диф')" 'additionalContext'
assert test ! -d "$GRANTS"

# --- Named: the block lifts, and stays lifted for the window ----------------------------------
assert contains "$(prompt_event 'прогони T3 по этому диффу')" 'additionalContext'
assert test -f "$GRANTS/t3"
assert allowed "$(bash_event "$T3_COMMAND")"
# Naming T3 is not naming --max.
assert denied "$(bash_event "$MAX_COMMAND")"
# One naming covers every run in its window: nothing is spent, so a rerun needs no new word.
assert allowed "$(bash_event "$T3_COMMAND")"
assert allowed "$(bash_event 'review-bench run HEAD --tier T3 --foreground')"
# ...and stops covering anything once it goes stale.
touch -t 202001010000 "$GRANTS/t3"
assert denied "$(bash_event "$T3_COMMAND")"
rm -rf "$GRANTS"

# A Cyrillic word ending in the keyword's letters is not the keyword: the boundary is whitespace
# or punctuation, not "anything outside A-Za-z0-9", which every Cyrillic letter satisfies.
assert lacks "$(prompt_event 'проверь планет3 и комнат3')" 'additionalContext'
assert test ! -d "$GRANTS"

for phrase in 'давай максимальное ревью' 'run a max review of the diff' 'полное ревью' \
  'ревью на макс'; do
  rm -rf "$GRANTS"
  assert contains "$(prompt_event "$phrase")" 'additionalContext'
  assert test -f "$GRANTS/max"
  assert allowed "$(bash_event "$MAX_COMMAND")"
done
rm -rf "$GRANTS"

# --- Fail-open ---------------------------------------------------------------------------------
# A malformed event, another tool's event, and an unknown mode all pass through silently rather
# than blocking ordinary work.
assert allowed "$(printf 'not json' | "$GATE" bash)"
assert allowed "$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Edit"}' | "$GATE" bash)"
assert allowed "$(jq -cn --arg c "$T3_COMMAND" \
  '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' \
  | "$GATE" nonsense)"

# --- A grant store that cannot be written says so -----------------------------------------------
# Silence here is answered minutes later by the launch gate with "he has not named it", which this
# half knows to be false.
locked="$WORK/locked"
mkdir -p "$locked"
chmod 500 "$locked"
out=$(CLAUDEB_DIR="$locked/store" prompt_event 'прогони T3 по этому диффу')
chmod 700 "$locked"
assert contains "$out" 'additionalContext'
assert contains "$out" 'could not be recorded'
assert contains "$out" 'refuse it as unnamed'

printf 'PASS: %s asserts; T3 and --max are refused until Egor names one, then unblocked for the window, an unwritable grant store is reported instead of swallowed, and every other command and event passes through\n' "$asserts"
