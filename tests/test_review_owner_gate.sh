#!/usr/bin/env bash
# bin/review-owner-gate.sh: tier T3 and any tier's --max run only after Egor has asked for one by
# name. No network, no daemon; every grant is written into a fixture store.
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

bash_event() {
  jq -cn --arg c "$1" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' \
    | "$GATE" bash
}

prompt_event() {
  jq -cn --arg s "${2:-session-1}" --arg p "$1" \
    '{hook_event_name: "UserPromptSubmit", session_id: $s, prompt: $p}' \
    | "$GATE" prompt
}

denied() { contains "$1" '"permissionDecision":"deny"'; }

# --- Ungranted: the two owner-only panels are refused, everything else passes through ----------
assert denied "$(bash_event 'review-bench review --worktree --tier T3 --foreground')"
assert denied "$(bash_event 'review-bench review HEAD --tier T2 --max --foreground')"
assert denied "$(bash_event 'review-bench run HEAD --tier T3 --foreground')"
assert denied "$(bash_event 'review-bench review --worktree --tier=T3')"
for allowed in \
  'review-bench review --worktree --tier T2 --foreground' \
  'review-bench suggest --repo .' \
  'review-bench tiers --table' \
  'review-bench run HEAD --raters oc-kimik3 --max-tokens 32000' \
  "grep -n -- '--max' bin/review-bench" \
  'rg "review-bench review --tier T3" docs'; do
  assert lacks "$(bash_event "$allowed")" '"permissionDecision"'
done

# A grant is written from Egor's words alone, and an ordinary prompt writes none.
assert lacks "$(prompt_event 'почини тесты и покажи диф')" 'additionalContext'
assert test ! -d "$GRANTS"

# Naming a panel is not asking for one: a refusal, a question, or a pasted diff that mentions T3
# must open nothing, or his own question comes back as the heavy command he was questioning.
for mention in \
  'не запускай T3, хватит T2' \
  'почему T3 не запускается?' \
  'объясни, чем T3 отличается от T2' \
  'do not run T3 here' \
  'в доке написано: «risky or wide diff → T3»' \
  'запусти тесты, но без максимального ревью'; do
  assert lacks "$(prompt_event "$mention" mention)" 'additionalContext'
done
assert test ! -d "$GRANTS"
# The shortest way he can ask is the keyword by itself.
assert contains "$(prompt_event 'T3' bare)" 'additionalContext'
rm -rf "$GRANTS"

# --- His word opens exactly one run ------------------------------------------------------------
granted=$(prompt_event 'прогони T3 по этому диффу')
assert contains "$granted" 'additionalContext'
assert test -f "$GRANTS/session-1.json"
assert test "$(jq -r '.scopes | join(",")' "$GRANTS/session-1.json")" = t3

t3_command='review-bench review --worktree --tier T3 --foreground'
assert lacks "$(bash_event "$t3_command")" '"permissionDecision"'
# Spent, and recorded as spent: the identical command may still be retried after a crash or a
# wall, anything else needs his word again.
assert test "$(jq -r '.used_cmd | length' "$GRANTS/session-1.json")" = 16
assert lacks "$(bash_event "$t3_command")" '"permissionDecision"'
assert denied "$(bash_event 'review-bench review --worktree --tier T3 --max --foreground')"
# A t3 grant is not a max grant.
assert denied "$(bash_event 'review-bench review --worktree --tier T2 --max --foreground')"

# --- Scopes and languages ----------------------------------------------------------------------
for phrase in 'давай максимальное ревью' 'run a max review of the diff' 'полное ревью, пожалуйста'; do
  rm -rf "$GRANTS"
  assert contains "$(prompt_event "$phrase" session-max)" 'additionalContext'
  assert test "$(jq -r '.scopes | join(",")' "$GRANTS/session-max.json")" = max
  assert lacks "$(bash_event 'review-bench review --worktree --tier T2 --max --foreground')" \
    '"permissionDecision"'
done
rm -rf "$GRANTS"
assert contains "$(prompt_event 'сделай T3, и максимальное ревью' session-both)" 'additionalContext'
assert test "$(jq -r '.scopes | sort | join(",")' "$GRANTS/session-both.json")" = max,t3

# --- Spending, retrying, racing --------------------------------------------------------------
# A grant spent at the very end of its TTL still answers for the full retry window: the run it
# allowed may have died at minute 29.
rm -rf "$GRANTS"; mkdir -p "$GRANTS"
old_ts=$(($(date +%s) - 1790))
cmd_hash=$(printf '%s' "$t3_command" | shasum -a 1 | cut -c1-16)
jq -cn --argjson ts "$old_ts" --argjson used "$(date +%s)" --arg hash "$cmd_hash" \
  '{session: "late", ts: $ts, scopes: ["t3"], used_at: $used, used_cmd: $hash}' \
  >"$GRANTS/late.json"
assert lacks "$(bash_event "$t3_command")" '"permissionDecision"'
# ...but a spent grant answers for nothing else, however fresh it is.
assert denied "$(bash_event 'review-bench run HEAD --tier T3 --foreground')"

# Quoting a gated flag earlier in a compound command must not deny the ordinary review after it.
rm -rf "$GRANTS"
assert lacks "$(bash_event "echo '--tier T3' && review-bench review --worktree --tier T2")" \
  '"permissionDecision"'

# Two hooks racing for one grant: exactly one wins, because the claim is a rename.
rm -rf "$GRANTS"
assert contains "$(prompt_event 'прогони T3' racer)" 'additionalContext'
race_out="$WORK/race"
mkdir -p "$race_out"
for n in 1 2; do
  ( bash_event "review-bench review --worktree --tier T3 --repo /race-$n" >"$race_out/$n" ) &
done
wait
assert test "$(cat "$race_out"/1 "$race_out"/2 | grep -c 'permissionDecision')" -eq 1

# A grant older than its window opens nothing, and neither does a corrupt one.
rm -rf "$GRANTS"
mkdir -p "$GRANTS"
jq -cn --argjson ts "$(($(date +%s) - 3600))" \
  '{session: "old", ts: $ts, scopes: ["t3"]}' >"$GRANTS/old.json"
assert denied "$(bash_event "$t3_command")"
printf 'not json\n' >"$GRANTS/old.json"
assert denied "$(bash_event "$t3_command")"

# A grant from another chat still counts: it is Egor's word either way, and a review is often
# launched from a session other than the one he said it in.
rm -rf "$GRANTS"
assert contains "$(prompt_event 'прогони t3' other-chat)" 'additionalContext'
assert lacks "$(bash_event "$t3_command")" '"permissionDecision"'

# --- Fail-open ----------------------------------------------------------------------------------
# A malformed event, another tool's event, and an unknown mode all pass through silently rather
# than blocking ordinary work.
assert lacks "$(printf 'not json' | "$GATE" bash)" '"permissionDecision"'
assert lacks "$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Edit"}' | "$GATE" bash)" \
  '"permissionDecision"'
assert lacks "$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "review-bench review --tier T3"}}' | "$GATE" nonsense)" \
  '"permissionDecision"'

printf 'PASS: %s asserts; T3 and --max are refused without a grant, opened by Egor'\''s own words for one run, and every other command and event passes through\n' "$asserts"
