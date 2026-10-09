#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$ROOT/bin/worker-git-guard.sh"
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
  jq -cn --arg command "$1" --arg cwd "$GUARD_CWD" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_input:{command:$command}}'
}
is_deny() { jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$1" >/dev/null 2>&1; }

# A claudeb or grok case runs as that headless worker session: only its launcher's marker guards.
worker_env() { case "$1" in grok) printf GROK_WORKER=1 ;; claudeb) printf CLAUDEB_WORKER=1 ;; *) printf GUARD_TEST=1 ;; esac; }

assert_deny() {
  local name=$1 session=$2 command=$3 output
  output=$(payload "$command" | env "$(worker_env "$session")" "$GUARD") || {
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
  local name=$1 session=$2 command=$3 output
  output=$(payload "$command" | env "$(worker_env "$session")" "$GUARD") || {
    fail "$name exited nonzero"
    return
  }
  if [ -z "$output" ]; then
    pass
  else
    fail "$name emitted output"
  fi
}

assert_deny 'checkout paths' claudeb 'git checkout -- global/CLAUDE.md'
assert_deny 'checkout separator-free file' claudeb 'git checkout CLAUDE.md'
mkdir -p "$GUARD_CWD/src"
assert_deny 'checkout separator-free nested' grok 'git checkout src/foo.py'
assert_allow 'checkout version branch' grok 'git checkout release/2.0.x'
assert_allow 'checkout dotted branch' claudeb 'git checkout fix/api.v2'
assert_deny 'checkout relative path' claudeb 'git checkout ./tracked'
assert_deny 'checkout two paths' claudeb 'git checkout file1 file2'
assert_deny 'restore in chain' claudeb 'cd /x && git restore file'
assert_deny 'hard reset' claudeb 'git reset --hard HEAD~1'
assert_deny 'clean force' claudeb 'git clean -fd'
assert_deny 'grok worker restore' grok 'git restore file'
assert_deny 'stash drop' claudeb 'git stash drop'
assert_deny 'stash bare' grok 'git stash'
assert_deny 'stash push' claudeb 'git stash push -m wip'
assert_deny 'stash pop' claudeb 'git stash pop'
assert_deny 'stash untracked' claudeb 'git stash -u'
assert_deny 'git directory checkout' claudeb 'git -C /repo checkout -- .'
# Every executable in this repo's own bin/ is extensionless, so a name read as a branch because it
# carries no dot is the shape that restores a live file over another agent's edits.
assert_deny 'checkout dotless nested path' claudeb 'git checkout bin/worker-pick'
assert_deny 'checkout dotless top-level path' grok 'git checkout Makefile'
assert_deny 'checkout absolute path' claudeb 'git checkout /repo/bin/worker-pick'
assert_deny 'checkout force' claudeb 'git checkout -f'
assert_deny 'checkout force long' grok 'git checkout --force main'
assert_deny 'checkout patch' claudeb 'git checkout -p'
assert_deny 'checkout force cluster' claudeb 'git checkout -fq main'

assert_allow 'main session' chat 'git checkout -- f'
printf '%s\n' 'jq() { printf "call\n" >> "$JQ_CALLS"; command jq "$@"; }' \
  'cat() { printf "call\n" >> "$JQ_CALLS"; command cat "$@"; }' > "$HOME/count-jq.sh"
: > "$HOME/jq-calls"
payload 'ls' | BASH_ENV="$HOME/count-jq.sh" JQ_CALLS="$HOME/jq-calls" bash "$GUARD" >/dev/null
if [ ! -s "$HOME/jq-calls" ]; then pass; else fail 'an unmarked session running no git forked before exiting'; fi
printf '%s\n' 'realpath() { printf "call\n" >> "$JQ_CALLS"; command realpath "$@"; }' \
  'awk() { printf "call\n" >> "$JQ_CALLS"; command awk "$@"; }' 'tr() { printf "call\n" >> "$JQ_CALLS"; command tr "$@"; }' \
  'grep() { printf "call\n" >> "$JQ_CALLS"; command grep "$@"; }' >> "$HOME/count-jq.sh"
for command in 'make test' 'git status && git diff --stat' $'cat <<EOF\nreset the flag\nEOF'; do
  : > "$HOME/jq-calls"
  payload "$command" | CLAUDEB_WORKER=1 BASH_ENV="$HOME/count-jq.sh" JQ_CALLS="$HOME/jq-calls" bash "$GUARD" >/dev/null
  if [ ! -s "$HOME/jq-calls" ]; then pass; else fail "a worker's $command, no revert subcommand, forked"; fi
done
assert_allow 'branch checkout' claudeb 'git checkout feature-branch'
assert_allow 'new branch checkout' claudeb 'git checkout -b new-branch'
assert_allow 'stash list' claudeb 'git stash list'
assert_allow 'stash show' grok 'git stash show'
assert_allow 'clean dry run' claudeb 'git clean -n'
assert_allow 'read-only git chain' claudeb 'git status && git diff'
assert_allow 'ordinary command' claudeb 'printf hello'
assert_allow 'grok branch checkout' grok 'git checkout feature-branch'
# A dot in a ref is ordinary; denying these would tell the worker its tree is unexpected when all
# it did was switch branches.
assert_allow 'version tag checkout' claudeb 'git checkout v1.2.3'
assert_allow 'dotted branch checkout' grok 'git checkout release-1.0'
assert_allow 'namespaced branch checkout' claudeb 'git checkout feature/new-thing'
assert_allow 'new branch with dot' claudeb 'git checkout -b release-2.0'
assert_allow 'attached new branch name' grok 'git checkout -bfix-force-flag'

assert_allow 'quoted heredoc brief prose' claudeb $'BRIEF=$(mktemp /tmp/claudeb-brief.XXXXXX) && cat > "$BRIEF" <<\'BRIEF_EOF\'\nACCOUNT: x\n\nDo not run git clean at start.\ngit checkout -- share/a.py is forbidden\nBRIEF_EOF\nworker-run start claudeb --brief "$BRIEF"'
assert_allow 'unquoted heredoc body prose' claudeb $'cat > notes <<EOF\ngit restore file\nEOF'
assert_allow 'dashed heredoc body prose' claudeb $'cat > notes <<-EOF\n\tgit stash\n\tEOF\ngit status'
assert_deny 'command after heredoc' claudeb $'cat > notes <<\'EOF\'\nhi\nEOF\ngit restore file'
assert_deny 'unquoted heredoc substitution' claudeb $'cat > notes <<EOF\n$(git restore file)\nEOF'
assert_deny 'unquoted heredoc backtick' grok $'cat > notes <<EOF\nrun `git stash`\nEOF'
assert_deny 'heredoc fed to bash' claudeb $'bash <<\'EOF\'\ngit restore file\nEOF'
assert_deny 'heredoc piped to sh' claudeb $'cat <<\'EOF\' | sh\ngit reset --hard\nEOF'
assert_deny 'quoted heredoc marker without body' claudeb $'echo "<<X"\ngit restore file'
assert_deny 'quoted heredoc marker with a closing line' claudeb $'echo \'<<X\'\ngit restore file\nX'
assert_deny 'heredoc body run later as a script' claudeb $'cat > /tmp/fix.sh <<\'EOF\'\ngit reset --hard\nEOF\nbash /tmp/fix.sh'
assert_deny 'heredoc fed to sudo bash' claudeb $'sudo -u me bash <<\'EOF\'\ngit reset --hard\nEOF'
assert_deny 'heredoc sourced from stdin' claudeb $'source /dev/stdin <<\'EOF\'\ngit stash\nEOF'
assert_deny 'heredoc lines evaluated' claudeb $'cat <<\'EOF\' | while read f; do eval "$f"; done\ngit stash\nEOF'
assert_deny 'heredoc fed to fish' claudeb $'fish <<\'EOF\'\ngit stash\nEOF'
assert_deny 'heredoc body dotted in' claudeb $'cat > /tmp/x <<\'EOF\'\ngit stash\nEOF\n. /tmp/x'
assert_allow 'heredoc body next to a .sh path' claudeb $'cat > /tmp/fix.sh <<\'EOF\'\ngit stash\nEOF\nchmod +x /tmp/fix.sh'
assert_deny 'heredoc marker in a comment' claudeb $'echo hi # <<X\ngit reset --hard\nX'
assert_deny 'herestring word closing a later line' claudeb $'grep x <<<"done"\ngit reset --hard\ndone'
assert_deny 'heredoc script run by its path' claudeb $'cat > /tmp/r.sh <<\'EOF\'\ngit reset --hard\nEOF\nchmod +x /tmp/r.sh && /tmp/r.sh'
assert_deny 'heredoc fed to at' claudeb $'at now <<EOF\ngit stash\nEOF'
assert_deny 'heredoc fed to csh' claudeb $'csh <<EOF\ngit stash\nEOF'
assert_deny 'multiline substitution in an unquoted heredoc' claudeb $'cat > notes <<EOF\n$(\ngit reset --hard\n)\nEOF'
assert_deny 'heredoc script run from its directory' claudeb $'cat > /tmp/r.sh <<\'EOF\'\ngit reset --hard\nEOF\ncd /tmp && ./r.sh'
assert_deny 'heredoc script teed then run' claudeb $'tee /tmp/r.sh >/dev/null <<\'EOF\'\ngit stash\nEOF\nFOO=1 /tmp/r.sh'
assert_deny 'heredoc script in a variable run' claudeb $'f=/tmp/r.sh; cat > "$f" <<\'EOF\'\ngit stash\nEOF\n"$f"'
assert_allow 'heredoc fed to a script run by path' claudeb $'./scripts/fmt.sh <<\'EOF\'\ngit restore is mentioned\nEOF'
assert_allow 'escaped backtick in an unquoted heredoc' claudeb $'cat > notes <<EOF\na lone \\` quote\ngit checkout -- is prose\nEOF'
assert_allow 'commit body read from stdin' claudeb $'git commit -F - <<EOF\nKeep git reset --hard out of worker hands\nEOF'
assert_allow 'heredoc to a file naming git checkout and rm' claudeb $'cat <<EOF > /tmp/notes.md\ngit checkout -- file drops edits\nrm -rf is denied too\nEOF'
assert_allow 'crontab listed beside a heredoc' claudeb $'crontab -l\ncat > notes <<\'EOF\'\ngit stash is prose\nEOF'
assert_allow 'commit body prose naming source' claudeb $'git commit -F - <<\'EOF\'\nFix the source loader\ngit checkout -- stays a worker\'s last resort.\nEOF'

# The unlock is the run's own: the GIT-CLEANUP line of the brief worker-run recorded for it, read
# through the WORKER_RUN_RECORD it hands the worker, and only under the run store.
export WORKER_RUN_DIR="$HOME/runs"
record() { # id brief-text [root]
  mkdir -p "${3:-$WORKER_RUN_DIR}/$1"
  printf '%s\n' "$2" >"${3:-$WORKER_RUN_DIR}/$1/brief"
  printf '%s' "${3:-$WORKER_RUN_DIR}/$1"
}
unlocked=$(record r-open $'ACCOUNT: main\nGIT-CLEANUP: allowed\nTask')
locked=$(record r-shut $'ACCOUNT: main\nTask')
prose=$(record r-prose $'Task: say GIT-CLEANUP: allowed in prose')
outside=$(record r-out $'GIT-CLEANUP: allowed' "$HOME/elsewhere")
guarded() { # record [marker]
  payload 'git restore file' | env "${2:-CLAUDEB_WORKER=1}" WORKER_RUN_RECORD="$1" "$GUARD"
}
if [ -z "$(guarded "$unlocked")" ]; then pass; else fail 'the run whose brief allows git cleanup was refused it'; fi
if [ -z "$(guarded "$unlocked" GROK_WORKER=1)" ]; then pass; else fail 'a grok run whose brief allows git cleanup was refused it'; fi
for record_dir in "$locked" "$prose" "$outside" "$WORKER_RUN_DIR/r-missing" ''; do
  if is_deny "$(guarded "$record_dir")"; then pass; else fail "the record [$record_dir] unlocked git cleanup"; fi
done

# Only the launcher's mark brings a headless grok session under the guard.
grok_headless=$(payload 'git clean -fd' | GROK_WORKER=1 "$GUARD") ||
  fail 'grok headless exited nonzero'
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$grok_headless" >/dev/null 2>&1; then
  pass
else
  fail 'GROK_WORKER=1 did not bring a headless grok run under the guard'
fi
grok_unmarked=$(payload 'git clean -fd' | "$GUARD") ||
  fail 'unmarked headless exited nonzero'
if [ -z "$grok_unmarked" ]; then pass; else fail 'an unmarked session was guarded as a worker'; fi

if [ "$failures" -eq 0 ]; then
  printf 'PASS: %d assertions\n' "$passes"
  exit 0
fi

printf 'FAIL: %d passed, %d failed\n' "$passes" "$failures"
exit 1
