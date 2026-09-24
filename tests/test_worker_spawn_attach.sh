#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-spawn-hook.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs" WORKER_SPAWN_WORKER_PICK=/nonexistent
unset CLAUDEB_WORKER
mkdir -p "$HOME" "$WORKER_RUN_DIR"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }

spawn() { # type prompt use
  jq -cn --arg t "$1" --arg p "$2" --arg u "$3" \
    '{hook_event_name:"PreToolUse",tool_name:"Agent",session_id:"s1",tool_use_id:$u,
      tool_input:{subagent_type:$t,description:"Do the task",prompt:$p}}' | bash "$HOOK" >/dev/null 2>&1
  cat "$HOME/.cache/claude-worker-tags/s1/pending-$1-$3" 2>/dev/null
}
mkrun() { # id vendor tag [light]
  mkdir -p "$WORKER_RUN_DIR/$1"
  printf '%s\n' "$3" >"$WORKER_RUN_DIR/$1/tag"
  jq -nc --arg v "$2" --arg l "${4:-}" '{vendor:$v,role:"workers",light:$l}' >"$WORKER_RUN_DIR/$1/meta.json"
}

# An ATTACH relay's row is the attached run's own account and model, and its seed names the run.
mkrun codex-1-a codex 'acct7 · astra · xhigh'
seed=$(spawn codex-worker 'ATTACH codex-1-a:' u1)
assert_eq 'acct7 · astra · xhigh' "$(head -n1 <<<"$seed")"
assert_eq 'run=codex-1-a' "$(grep '^run=' <<<"$seed")"

mkrun grok-2-b grok 'sg2 · grok-5 · high'
assert_eq 'sg2 · grok-5 · high' "$(spawn codex-worker 'ATTACH grok-2-b: keep waiting' u2 | head -n1)"

mkrun gem-3-c codex 'acct9 · gpt-6-astra · low' edit
assert_eq 'light edit · astra · acct9' "$(spawn light-worker 'ATTACH gem-3-c:' u3 | head -n1)"

# A missing run or a plain brief keeps the predicted row and names no run.
seed=$(spawn codex-worker 'ATTACH nope-9:' u4)
assert_eq '' "$(grep '^run=' <<<"$seed")"
assert_eq 1 "$(grep -c ' · ' <<<"$seed")"
assert_eq '' "$(spawn codex-worker 'Fix codex-1-a' u5 | grep '^run=')"

printf 'PASS: %s asserts; an ATTACH relay spawn takes its row from the attached run'"'"'s own tag (light relays relabelled as light rows), seeds run=<id> for the Stop backstop, and a missing run or plain brief keeps the predicted row\n' "$asserts"
