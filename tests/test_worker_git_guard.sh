#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
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
printf '%s\n' 'jq() { printf "call\n" >> "$JQ_CALLS"; command jq "$@"; }' \
  'cat() { printf "call\n" >> "$JQ_CALLS"; command cat "$@"; }' > "$HOME/count-jq.sh"
: > "$HOME/jq-calls"
payload '' 'ls' | BASH_ENV="$HOME/count-jq.sh" JQ_CALLS="$HOME/jq-calls" bash "$GUARD" >/dev/null
if [ "$(wc -l < "$HOME/jq-calls" | tr -d ' ')" = 1 ]; then pass; else fail 'an empty agent_type ran more than its one jq parse'; fi
: > "$HOME/jq-calls"
payload '' 'ls' | jq -c 'del(.agent_type)' |
  BASH_ENV="$HOME/count-jq.sh" JQ_CALLS="$HOME/jq-calls" bash "$GUARD" >/dev/null
if [ ! -s "$HOME/jq-calls" ]; then pass; else fail 'a main-session call with no agent_type forked before exiting'; fi
: > "$HOME/jq-calls"
payload '' 'git stash -u' | jq -c 'del(.agent_type)' |
  CLAUDEB_WORKER=1 BASH_ENV="$HOME/count-jq.sh" JQ_CALLS="$HOME/jq-calls" bash "$GUARD" | grep -q '"deny"' &&
  pass || fail 'a headless claudeb call with no agent_type key was not guarded'
payload '' 'git stash -u' | jq -c 'del(.agent_type)' | GROK_WORKER=1 bash "$GUARD" | grep -q '"deny"' &&
  pass || fail 'a headless grok call with no agent_type key was not guarded'
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

assert_allow 'quoted heredoc brief prose' claudeb-worker $'BRIEF=$(mktemp /tmp/claudeb-brief.XXXXXX) && cat > "$BRIEF" <<\'BRIEF_EOF\'\nACCOUNT: x\n\nDo not run git clean at start.\ngit checkout -- share/a.py is forbidden\nBRIEF_EOF\nworker-run start claudeb --brief "$BRIEF"'
assert_allow 'unquoted heredoc body prose' codex-worker $'cat > notes <<EOF\ngit restore file\nEOF'
assert_allow 'dashed heredoc body prose' codex-worker $'cat > notes <<-EOF\n\tgit stash\n\tEOF\ngit status'
assert_deny 'command after heredoc' codex-worker $'cat > notes <<\'EOF\'\nhi\nEOF\ngit restore file'
assert_deny 'unquoted heredoc substitution' codex-worker $'cat > notes <<EOF\n$(git restore file)\nEOF'
assert_deny 'unquoted heredoc backtick' grok-worker $'cat > notes <<EOF\nrun `git stash`\nEOF'
assert_deny 'heredoc fed to bash' codex-worker $'bash <<\'EOF\'\ngit restore file\nEOF'
assert_deny 'heredoc piped to sh' claudeb-worker $'cat <<\'EOF\' | sh\ngit reset --hard\nEOF'
assert_deny 'quoted heredoc marker without body' codex-worker $'echo "<<X"\ngit restore file'
assert_deny 'quoted heredoc marker with a closing line' codex-worker $'echo \'<<X\'\ngit restore file\nX'
assert_deny 'heredoc body run later as a script' codex-worker $'cat > /tmp/fix.sh <<\'EOF\'\ngit reset --hard\nEOF\nbash /tmp/fix.sh'
assert_deny 'heredoc fed to sudo bash' codex-worker $'sudo -u me bash <<\'EOF\'\ngit reset --hard\nEOF'
assert_deny 'heredoc sourced from stdin' codex-worker $'source /dev/stdin <<\'EOF\'\ngit stash\nEOF'
assert_deny 'heredoc lines evaluated' codex-worker $'cat <<\'EOF\' | while read f; do eval "$f"; done\ngit stash\nEOF'
assert_deny 'heredoc fed to fish' codex-worker $'fish <<\'EOF\'\ngit stash\nEOF'
assert_deny 'heredoc body dotted in' codex-worker $'cat > /tmp/x <<\'EOF\'\ngit stash\nEOF\n. /tmp/x'
assert_allow 'heredoc body next to a .sh path' codex-worker $'cat > /tmp/fix.sh <<\'EOF\'\ngit stash\nEOF\nchmod +x /tmp/fix.sh'
assert_deny 'heredoc marker in a comment' codex-worker $'echo hi # <<X\ngit reset --hard\nX'
assert_deny 'herestring word closing a later line' codex-worker $'grep x <<<"done"\ngit reset --hard\ndone'
assert_deny 'heredoc script run by its path' codex-worker $'cat > /tmp/r.sh <<\'EOF\'\ngit reset --hard\nEOF\nchmod +x /tmp/r.sh && /tmp/r.sh'
assert_deny 'heredoc fed to at' codex-worker $'at now <<EOF\ngit stash\nEOF'
assert_deny 'heredoc fed to csh' codex-worker $'csh <<EOF\ngit stash\nEOF'
assert_deny 'multiline substitution in an unquoted heredoc' codex-worker $'cat > notes <<EOF\n$(\ngit reset --hard\n)\nEOF'
assert_deny 'heredoc script run from its directory' codex-worker $'cat > /tmp/r.sh <<\'EOF\'\ngit reset --hard\nEOF\ncd /tmp && ./r.sh'
assert_deny 'heredoc script teed then run' codex-worker $'tee /tmp/r.sh >/dev/null <<\'EOF\'\ngit stash\nEOF\nFOO=1 /tmp/r.sh'
assert_deny 'heredoc script in a variable run' codex-worker $'f=/tmp/r.sh; cat > "$f" <<\'EOF\'\ngit stash\nEOF\n"$f"'
assert_allow 'heredoc fed to a script run by path' codex-worker $'./scripts/fmt.sh <<\'EOF\'\ngit restore is mentioned\nEOF'
assert_allow 'escaped backtick in an unquoted heredoc' codex-worker $'cat > notes <<EOF\na lone \\` quote\ngit checkout -- is prose\nEOF'
assert_allow 'commit body read from stdin' codex-worker $'git commit -F - <<EOF\nKeep git reset --hard out of worker hands\nEOF'
assert_allow 'heredoc to a file naming git checkout and rm' codex-worker $'cat <<EOF > /tmp/notes.md\ngit checkout -- file drops edits\nrm -rf is denied too\nEOF'
assert_allow 'crontab listed beside a heredoc' codex-worker $'crontab -l\ncat > notes <<\'EOF\'\ngit stash is prose\nEOF'
assert_allow 'commit body prose naming source' codex-worker $'git commit -F - <<\'EOF\'\nFix the source loader\ngit checkout -- stays a worker\'s last resort.\nEOF'

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
