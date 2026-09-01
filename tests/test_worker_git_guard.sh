#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$ROOT/bin/worker-git-guard.sh"
SPAWN_HOOK="$ROOT/bin/worker-spawn-hook.sh"
HOME=$(mktemp -d "${TMPDIR:-/tmp}/worker-git-guard.XXXXXX") || exit 1
export HOME
trap 'rm -rf "$HOME"' EXIT

# Launched from inside a worker session, the launcher's own marks leak in through the environment
# and every allow case reads as a guarded worker: the suite states the environment it asserts about.
unset CLAUDEB_WORKER GROK_WORKER

passes=0
failures=0

pass() {
  passes=$((passes + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# The guard reads an operand's path-ness off the disk it names, so the cases below get a checkout
# of their own rather than whatever directory the suite was launched from.
GUARD_CWD="$HOME/checkout"
mkdir -p "$GUARD_CWD/bin"
: > "$GUARD_CWD/bin/worker-pick"
: > "$GUARD_CWD/Makefile"

payload() {
  local agent=$1 command=$2 session=${3:-guard-session}
  jq -cn --arg agent "$agent" --arg command "$command" --arg session "$session" \
    --arg cwd "$GUARD_CWD" '
    {hook_event_name:"PreToolUse",agent_type:$agent,session_id:$session,cwd:$cwd,
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
assert_deny 'checkout separator-free file' codex-worker 'git checkout CLAUDE.md'
mkdir -p "$GUARD_CWD/src"
assert_deny 'checkout separator-free nested' grok-worker 'git checkout src/foo.py'
assert_allow 'checkout version branch' grok-worker 'git checkout release/2.0.x'
assert_allow 'checkout dotted branch' codex-worker 'git checkout fix/api.v2'
assert_deny 'checkout relative path' claudeb-worker 'git checkout ./tracked'
assert_deny 'checkout two paths' gemini-worker 'git checkout file1 file2'
assert_deny 'restore in chain' claudeb-worker 'cd /x && git restore file'
assert_deny 'hard reset' gemini-worker 'git reset --hard HEAD~1'
assert_deny 'clean force' codex-worker 'git clean -fd'
assert_deny 'grok worker restore' grok-worker 'git restore file'
assert_deny 'stash drop' codex-worker 'git stash drop'
assert_deny 'stash bare' grok-worker 'git stash'
assert_deny 'stash push' claudeb-worker 'git stash push -m wip'
assert_deny 'stash pop' gemini-worker 'git stash pop'
assert_deny 'stash untracked' codex-worker 'git stash -u'
assert_deny 'git directory checkout' codex-worker 'git -C /repo checkout -- .'
# Every executable in this repo's own bin/ is extensionless, so a name read as a branch because it
# carries no dot is the shape that restores a live file over another agent's edits.
assert_deny 'checkout dotless nested path' codex-worker 'git checkout bin/worker-pick'
assert_deny 'checkout dotless top-level path' grok-worker 'git checkout Makefile'
assert_deny 'checkout absolute path' claudeb-worker 'git checkout /repo/bin/worker-pick'
assert_deny 'checkout force' codex-worker 'git checkout -f'
assert_deny 'checkout force long' grok-worker 'git checkout --force main'
assert_deny 'checkout patch' gemini-worker 'git checkout -p'
assert_deny 'checkout force cluster' claudeb-worker 'git checkout -fq main'

assert_allow 'main session' '' 'git checkout -- f'
assert_allow 'explore agent' Explore 'git checkout -- f'
assert_allow 'branch checkout' codex-worker 'git checkout feature-branch'
assert_allow 'new branch checkout' codex-worker 'git checkout -b new-branch'
assert_allow 'stash list' codex-worker 'git stash list'
assert_allow 'stash show' grok-worker 'git stash show'
assert_allow 'clean dry run' codex-worker 'git clean -n'
assert_allow 'read-only git chain' codex-worker 'git status && git diff'
assert_allow 'ordinary command' codex-worker 'printf hello'
assert_allow 'grok branch checkout' grok-worker 'git checkout feature-branch'
# A dot in a ref is ordinary; denying these would tell the worker its tree is unexpected when all
# it did was switch branches.
assert_allow 'version tag checkout' codex-worker 'git checkout v1.2.3'
assert_allow 'dotted branch checkout' grok-worker 'git checkout release-1.0'
assert_allow 'namespaced branch checkout' claudeb-worker 'git checkout feature/new-thing'
assert_allow 'new branch with dot' codex-worker 'git checkout -b release-2.0'
assert_allow 'attached new branch name' grok-worker 'git checkout -bfix-force-flag'

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

# The unlock the guard reads is a file in a cache dir that can be unwritable, and a brief the
# worker can read says GIT-CLEANUP is allowed while the guard still refuses: the worker cannot
# resolve that on its own, so the hook says which of the two is true in the brief itself.
blocked_session=spawn-unwritable
blocked_dir="$HOME/.cache/claude-worker-tags"
mkdir -p "$blocked_dir"
chmod 500 "$blocked_dir"
blocked_output=$(spawn_payload "$blocked_session" $'ACCOUNT: main\nEFFORT: high\nGIT-CLEANUP: allowed\nTask' |
  WORKER_SPAWN_WORKER_PICK=/nonexistent "$SPAWN_HOOK") || fail 'blocked spawn exited nonzero'
chmod 700 "$blocked_dir"
if jq -e '.hookSpecificOutput.updatedInput.prompt | test("GIT-CLEANUP NOTE")' \
  <<< "$blocked_output" >/dev/null 2>&1; then
  pass
else
  fail 'an unwritable unlock dir left the brief claiming a cleanup the guard will refuse'
fi

# A headless grok run is a worker session, not a subagent of one: its payload carries no
# agent_type, so only the launcher's mark brings it under the guard.
grok_headless=$(payload '' 'git clean -fd' grok-headless-session | GROK_WORKER=1 "$GUARD") ||
  fail 'grok headless exited nonzero'
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$grok_headless" >/dev/null 2>&1; then
  pass
else
  fail 'GROK_WORKER=1 did not bring a headless grok run under the guard'
fi
grok_unmarked=$(payload '' 'git clean -fd' grok-headless-session | "$GUARD") ||
  fail 'unmarked headless exited nonzero'
if [ -z "$grok_unmarked" ]; then pass; else fail 'an unmarked session was guarded as a worker'; fi

# The unlock is per agent kind: a cleanup permission granted to a grok worker unlocks nothing else.
grok_unlock_dir="$HOME/.cache/claude-worker-tags/grok-unlocked"
mkdir -p "$grok_unlock_dir"
: > "$grok_unlock_dir/git-unlock-grok-worker"
grok_unlocked=$(payload grok-worker 'git restore file' grok-unlocked | "$GUARD") ||
  fail 'grok unlock exited nonzero'
if [ -z "$grok_unlocked" ]; then pass; else fail 'grok unlock emitted output'; fi
grok_borrowed=$(payload codex-worker 'git restore file' grok-unlocked | "$GUARD") ||
  fail 'codex under grok unlock exited nonzero'
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$grok_borrowed" >/dev/null 2>&1; then
  pass
else
  fail "grok's unlock let a codex worker through"
fi

if [ "$failures" -eq 0 ]; then
  printf 'PASS: %d assertions\n' "$passes"
  exit 0
fi

printf 'FAIL: %d passed, %d failed\n' "$passes" "$failures"
exit 1
