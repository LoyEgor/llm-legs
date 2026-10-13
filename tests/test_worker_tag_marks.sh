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

payload() { # agent-type agent-id command [description] [session]: a hand-built PreToolUse payload, no jq per call
  local agent=''
  [ -z "$1" ] || agent=$(printf '"agent_type":"%s","agent_id":"%s",' "$1" "$2")
  printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"%s",%s"tool_input":{"command":"%s","description":"%s"}}\n' \
    "${5:-s1}" "$agent" "$3" "${4:-}"
}
call() { # agent-type agent-id command [description]
  payload "$@" | bash "$HOOK" 2>/dev/null
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
payload fork f6 ls |
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
payload '' '' ls |
  BASH_ENV="$WORK/count-forks.sh" FORKS="$WORK/forks" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 "$(grep -c '' "$WORK/forks")"
# So does any other subagent's payload: only a fork's carries the literal "fork".
payload general-purpose g1 ls |
  BASH_ENV="$WORK/count-forks.sh" FORKS="$WORK/forks" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 "$(grep -c '' "$WORK/forks")"
# A fork's ids are cleaned in-process, never by a tr per id.
printf '%s\n' 'tr() { printf "call\n" >> "$FORKS"; command tr "$@"; }' >"$WORK/count-tr.sh"
: >"$WORK/tr-calls"
payload fork 'f1;' ls List 's1.' |
  BASH_ENV="$WORK/count-tr.sh" FORKS="$WORK/tr-calls" bash "$HOOK" >"$WORK/tr-out" 2>&1
assert_eq 0 "$(grep -c '' "$WORK/tr-calls")"
assert_eq 'fork · opus · com — List' "$(jq -r '.hookSpecificOutput.updatedInput.description' "$WORK/tr-out")"

# The hourly prune reads its marker's content, never a stat: an old marker prunes and is restamped, a fresh one leaves files alone.
: >"$HOME/.cache/claude-worker-tags/.tag-prune"
touch -t 202001010000 "$TAGS/old-a"
call fork f1 ls x >/dev/null
assert_eq 0 "$(ls "$TAGS" | grep -c '^old-a$')"
assert_eq 1 "$(grep -c '^[0-9]*$' "$HOME/.cache/claude-worker-tags/.tag-prune")"
touch -t 202001010000 "$TAGS/old-b"
call fork f1 ls x >/dev/null
assert_eq 1 "$(ls "$TAGS" | grep -c '^old-b$')"
# A stale tag-shaped prefix is stripped in-process, whatever the shape, so prefixes never stack.
assert_eq 'fork · opus · com — List' "$(jq -r '.hookSpecificOutput.updatedInput.description' <<<"$(call fork f1 ls 'old · acct — List')")"

printf 'PASS: %s asserts; a fork'"'"'s tag prefixes its call once, no other agent type gets a tag, a seed is spent only once its tag file is written, and a main-session or non-fork subagent call exits on builtins\n' "$asserts"
