#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-spawn-hook.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs" WORKER_SPAWN_WORKER_PICK=/nonexistent
unset CLAUDEB_WORKER WORKER_PICK_CONFIG_FILE
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

cat >"$WORK/count-jq.sh" <<'SH'
jq() { printf 'call\n' >> "$JQ_CALLS"; command jq "$@"; }
SH
BASH_ENV="$WORK/count-jq.sh" JQ_CALLS="$WORK/jq-calls" bash "$HOOK" <<'JSON'
{"hook_event_name":"PreToolUse","tool_name":"Workflow","session_id":"s1"}
JSON
assert_eq 1 "$(wc -l <"$WORK/jq-calls" | tr -d ' ')"

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

# The prompt's ROUND: header rides the seed into the agent's tag file, where `worker-run start` adopts
# it once the relay rewrote the brief; ACCOUNT:/EFFORT: may precede it, prose seeds nothing, and
# `none` rides as the opt-out it is.
seed=$(spawn claudeb-worker $'ACCOUNT: com\nEFFORT: high\nROUND: 20260928T011240Z-c3c2395\nFix it.' u6)
assert_eq 'round=20260928T011240Z-c3c2395' "$(grep '^round=' <<<"$seed")"
assert_eq 'round=none' "$(spawn claudeb-worker $'ACCOUNT: com\nROUND: none\nFix it.' u7 | grep '^round=')"
assert_eq '' "$(spawn codex-worker $'ACCOUNT: com\nFix it.\nROUND: 20260928T011240Z-c3c2395' u8 | grep '^round=')"
rm -f "$HOME/.cache/claude-worker-tags/s1"/pending-*
spawn claudeb-worker $'ROUND: 20260928T011240Z-c3c2395\nFix it.' u9 >/dev/null
jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",agent_type:"claudeb-worker",agent_id:"agent-r",
  tool_input:{command:"worker-run start claudeb --brief /tmp/b",description:"launch"}}' |
  bash "$ROOT/bin/worker-tag-hook.sh" >/dev/null 2>&1
assert_eq 'round=20260928T011240Z-c3c2395' "$(grep '^round=' "$HOME/.cache/claude-worker-tags/s1/agent-r" 2>/dev/null)"
assert_eq 1 "$(grep -c '^start=' "$HOME/.cache/claude-worker-tags/s1/agent-r" 2>/dev/null)"

seed=$(spawn codex-worker $'ATTACH codex-1-a:\nKeep the literal \'quote\' and $(touch '"$WORK/injected"$') text.\n' u-literal)
assert_eq 'acct7 · astra · xhigh' "$(head -n1 <<<"$seed")"
assert_eq 'run=codex-1-a' "$(grep '^run=' <<<"$seed")"
asserts=$((asserts + 1))
[ ! -e "$WORK/injected" ] || fail "payload text was executed"

printf 'PASS: %s asserts; an ATTACH relay spawn takes its row from the attached run'"'"'s own tag (light relays relabelled as light rows), seeds run=<id> for the Stop backstop, a missing run or plain brief keeps the predicted row, and a prompt ROUND: header reaches the agent tag file\n' "$asserts"
