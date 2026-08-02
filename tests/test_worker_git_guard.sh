#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$ROOT/bin/worker-git-guard.sh"
SPAWN_HOOK="$ROOT/bin/worker-spawn-hook.sh"
HOME=$(mktemp -d "${TMPDIR:-/tmp}/worker-git-guard.XXXXXX") || exit 1
export HOME
trap 'rm -rf "$HOME"' EXIT

passes=0
failures=0

pass() {
  passes=$((passes + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

payload() {
  local agent=$1 command=$2 session=${3:-guard-session}
  jq -cn --arg agent "$agent" --arg command "$command" --arg session "$session" '
    {hook_event_name:"PreToolUse",agent_type:$agent,session_id:$session,
     tool_input:{command:$command}}'
}

assert_deny() {
  local name=$1 agent=$2 command=$3 output
  output=$(payload "$agent" "$command" | "$GUARD") || {
    fail "$name exited nonzero"
    return
  }
  if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$output" >/dev/null 2>&1; then
    pass
  else
    fail "$name did not emit valid deny JSON"
  fi
}

assert_allow() {
  local name=$1 agent=$2 command=$3 output
  output=$(payload "$agent" "$command" | "$GUARD") || {
    fail "$name exited nonzero"
    return
  }
  if [ -z "$output" ]; then
    pass
  else
    fail "$name emitted output"
  fi
}

assert_deny 'checkout paths' codex-worker 'git checkout -- global/CLAUDE.md'
assert_deny 'restore in chain' claudeb-worker 'cd /x && git restore file'
assert_deny 'hard reset' gemini-worker 'git reset --hard HEAD~1'
assert_deny 'clean force' codex-worker 'git clean -fd'
assert_deny 'stash drop' codex-worker 'git stash drop'
assert_deny 'git directory checkout' codex-worker 'git -C /repo checkout -- .'

assert_allow 'main session' '' 'git checkout -- f'
assert_allow 'explore agent' Explore 'git checkout -- f'
assert_allow 'branch checkout' codex-worker 'git checkout feature-branch'
assert_allow 'new branch checkout' codex-worker 'git checkout -b new-branch'
assert_allow 'clean dry run' codex-worker 'git clean -n'
assert_allow 'read-only git chain' codex-worker 'git status && git diff'
assert_allow 'ordinary command' codex-worker 'printf hello'

unlock_session=unlocked-session
unlock_dir="$HOME/.cache/claude-worker-tags/$unlock_session"
mkdir -p "$unlock_dir"
: > "$unlock_dir/git-unlock-codex-worker"
unlock_output=$(payload codex-worker 'git restore file' "$unlock_session" | "$GUARD") || fail 'unlock exited nonzero'
if [ -z "$unlock_output" ]; then pass; else fail 'unlock emitted output'; fi

spawn_payload() {
  jq -cn --arg session "$1" --arg prompt "$2" '
    {hook_event_name:"PreToolUse",session_id:$session,
     tool_input:{subagent_type:"codex-worker",description:"Implement guard",prompt:$prompt}}'
}

spawn_session=spawn-unlocked
spawn_output=$(spawn_payload "$spawn_session" $'ACCOUNT: main\nEFFORT: high\nGIT-CLEANUP: allowed\nTask' |
  WORKER_SPAWN_WORKER_PICK=/nonexistent "$SPAWN_HOOK") || fail 'unlocked spawn exited nonzero'
if [ -e "$HOME/.cache/claude-worker-tags/$spawn_session/git-unlock-codex-worker" ]; then
  pass
else
  fail 'spawn hook did not create unlock flag'
fi

locked_session=spawn-locked
locked_output=$(spawn_payload "$locked_session" $'ACCOUNT: main\nEFFORT: high\nTask' |
  WORKER_SPAWN_WORKER_PICK=/nonexistent "$SPAWN_HOOK") || fail 'locked spawn exited nonzero'
if [ ! -e "$HOME/.cache/claude-worker-tags/$locked_session/git-unlock-codex-worker" ]; then
  pass
else
  fail 'spawn hook created an unlock flag without permission'
fi

if [ "$failures" -eq 0 ]; then
  printf 'PASS: %d assertions\n' "$passes"
  exit 0
fi

printf 'FAIL: %d passed, %d failed\n' "$passes" "$failures"
exit 1
