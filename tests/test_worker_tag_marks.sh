#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-tag-hook.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs" WORKER_STATS_DIR="$WORK/stats"
unset CLAUDEB_WORKER
TAGS="$HOME/.cache/claude-worker-tags/s1"
mkdir -p "$TAGS" "$WORKER_RUN_DIR"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }

call() { # agent-type agent-id command [description]
  jq -cn --arg t "$1" --arg a "$2" --arg c "$3" --arg d "${4:-}" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",agent_type:$t,agent_id:$a,tool_input:{command:$c,description:$d}}' |
    bash "$HOOK" 2>/dev/null
}

# A tagged fork's row prefixes its call, once.
printf 'fork · opus · com\n' >"$TAGS/f1"
out=$(call fork f1 'ls' 'List files')
assert_eq 'fork · opus · com — List files' "$(jq -r '.hookSpecificOutput.updatedInput.description' <<<"$out")"
assert_eq '' "$(call fork f1 'ls' 'fork · opus · com — List files')"

# A retired relay type, or any other agent, has no tag of its own here: nothing written, nothing said.
for type in codex-worker claudeb-worker light-research review-waiter general-purpose; do
  assert_eq '' "$(call "$type" a2 'worker-run start codex --brief /tmp/b' 'Launch')"
done
assert_eq '' "$(ls "$TAGS" | grep -vx f1)"

# A seed is spent only once its tag file is written: a failed rewrite keeps it for the next call.
printf 'fork · sonnet · com\nspawn=0000000000000000\n' >"$TAGS/pending-fork-k1"
printf 'mv() { return 1; }\n' >"$WORK/fail-mv.sh"
jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",agent_type:"fork",agent_id:"f6",tool_input:{command:"ls"}}' |
  BASH_ENV="$WORK/fail-mv.sh" bash "$HOOK" >/dev/null 2>&1
assert_eq 1 "$(ls "$TAGS" | grep -c '^pending-fork-k1$')"
assert_eq 0 "$(ls "$TAGS" | grep -c '^f6$')"
call fork f6 'ls' >/dev/null
assert_eq 0 "$(ls "$TAGS" | grep -c '^pending-fork-k1$')"
assert_eq 'fork · sonnet · com' "$(head -n1 "$TAGS/f6")"

# A main-session payload carries no agent_type key: it exits on builtins, before any cat or jq.
printf '%s\n' 'jq() { printf "call\n" >> "$FORKS"; command jq "$@"; }' \
  'cat() { printf "call\n" >> "$FORKS"; command cat "$@"; }' >"$WORK/count-forks.sh"
: >"$WORK/forks"
jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",tool_input:{command:"ls"}}' |
  BASH_ENV="$WORK/count-forks.sh" FORKS="$WORK/forks" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 "$(grep -c '' "$WORK/forks")"
# So does any other subagent's payload: only a fork's carries the literal "fork".
jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",agent_type:"general-purpose",agent_id:"g1",tool_input:{command:"ls"}}' |
  BASH_ENV="$WORK/count-forks.sh" FORKS="$WORK/forks" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 "$(grep -c '' "$WORK/forks")"
# A fork's ids are cleaned in-process, never by a tr per id.
printf '%s\n' 'tr() { printf "call\n" >> "$FORKS"; command tr "$@"; }' >"$WORK/count-tr.sh"
: >"$WORK/tr-calls"
jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1.",agent_type:"fork",agent_id:"f1;",tool_input:{command:"ls",description:"List"}}' |
  BASH_ENV="$WORK/count-tr.sh" FORKS="$WORK/tr-calls" bash "$HOOK" >"$WORK/tr-out" 2>&1
assert_eq 0 "$(grep -c '' "$WORK/tr-calls")"
assert_eq 'fork · opus · com — List' "$(jq -r '.hookSpecificOutput.updatedInput.description' "$WORK/tr-out")"

printf 'PASS: %s asserts; a fork'"'"'s tag prefixes its call once, no other agent type gets a tag, a seed is spent only once its tag file is written, and a main-session or non-fork subagent call exits on builtins\n' "$asserts"
