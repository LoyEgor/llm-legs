#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-tag-hook.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs" WORKER_STATS_DIR="$WORK/stats" WORKER_TAG_WORKER_PICK=/nonexistent
unset CLAUDEB_WORKER
TAGS="$HOME/.cache/claude-worker-tags/s1"
mkdir -p "$TAGS" "$WORKER_RUN_DIR"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }

call() { # agent-type agent-id command
  jq -cn --arg t "$1" --arg a "$2" --arg c "$3" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",agent_type:$t,agent_id:$a,tool_input:{command:$c}}' |
    bash "$HOOK" >/dev/null 2>&1
}

# A relay the hold let go is live again the moment it makes a call: its `stopped=` mark goes.
printf 'acct · astra · high\nrun=r1\nstopped=1790000000\n' >"$TAGS/a1"
call codex-worker a1 'ls'
assert_eq '' "$(grep '^stopped=' "$TAGS/a1")"
assert_eq 'run=r1' "$(grep '^run=' "$TAGS/a1")"

# A light-research launch leaves a `start=` mark for worker-run to claim; an attach names its run.
printf 'light research · flash · rawi\n' >"$TAGS/a2"
call light-research a2 'light-research --question "where" --out /tmp/o'
assert_eq 1 "$(grep -c '^start=[0-9]' "$TAGS/a2")"
printf 'light research · flash · rawi\n' >"$TAGS/a3"
call light-research a3 'light-research --attach lr-20260924-ab12 --out /tmp/o'
assert_eq 'run=lr-20260924-ab12' "$(grep '^run=' "$TAGS/a3")"
assert_eq 0 "$(grep -c '^start=' "$TAGS/a3")"

# A here-string or a quoted `<<` opens no heredoc body: the launch on a later line still marks the row.
for cmd in $'jq . <<< "$payload"\nworker-run start codex --brief /tmp/b' \
    $'cat <<<"$brief" >/tmp/b\nworker-run start codex --brief /tmp/b' \
    $'echo \'<<X\'\nworker-run start codex --brief /tmp/b'; do
  printf 'acct · astra · high\n' >"$TAGS/a4"
  call codex-worker a4 "$cmd"
  assert_eq 1 "$(grep -c '^start=[0-9]' "$TAGS/a4")"
done
# A real heredoc's body is still a brief being written, not a launch.
printf 'acct · astra · high\n' >"$TAGS/a5"
call codex-worker a5 $'cat > /tmp/b <<EOF\nworker-run start codex --brief /tmp/b\nEOF'
assert_eq 0 "$(grep -c '^start=' "$TAGS/a5")"

# A seed is spent only once its tag file is written: a failed rewrite keeps it for the next call.
printf 'acct · astra · high\nspawn=0000000000000000\n' >"$TAGS/pending-codex-worker-k1"
printf 'mv() { return 1; }\n' >"$WORK/fail-mv.sh"
jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",agent_type:"codex-worker",agent_id:"a6",tool_input:{command:"ls"}}' |
  BASH_ENV="$WORK/fail-mv.sh" bash "$HOOK" >/dev/null 2>&1
assert_eq 1 "$(ls "$TAGS" | grep -c '^pending-codex-worker-k1$')"
assert_eq 0 "$(ls "$TAGS" | grep -c '^a6$')"
call codex-worker a6 'ls'
assert_eq 0 "$(ls "$TAGS" | grep -c '^pending-codex-worker-k1$')"
assert_eq 'acct · astra · high' "$(head -n1 "$TAGS/a6")"

# A claudeb launch naming its model without --effort takes that model's default effort, not opus's.
call claudeb-worker a7 'claudeb profile acct -p --model fable "do it"'
assert_eq 'acct · fable · low' "$(head -n1 "$TAGS/a7")"
call claudeb-worker a8 'claudeb profile acct -p --model sonnet "do it"'
assert_eq 'acct · sonnet · medium' "$(head -n1 "$TAGS/a8")"

# A main-session payload carries no agent_type key: it exits on builtins, before any cat or jq.
printf '%s\n' 'jq() { printf "call\n" >> "$FORKS"; command jq "$@"; }' \
  'cat() { printf "call\n" >> "$FORKS"; command cat "$@"; }' >"$WORK/count-forks.sh"
: >"$WORK/forks"
jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",tool_input:{command:"ls"}}' |
  BASH_ENV="$WORK/count-forks.sh" FORKS="$WORK/forks" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 "$(grep -c '' "$WORK/forks")"

printf 'PASS: %s asserts; a released relay'"'"'s stopped= mark clears on its next call, a light-research launch leaves start= for worker-run'"'"'s claim, and an --attach names run=<id>\n' "$asserts"
