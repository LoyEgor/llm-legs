#!/usr/bin/env bash
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

printf 'PASS: %s asserts; a released relay'"'"'s stopped= mark clears on its next call, a light-research launch leaves start= for worker-run'"'"'s claim, and an --attach names run=<id>\n' "$asserts"
