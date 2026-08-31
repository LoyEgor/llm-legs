#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR_HOOK="$ROOT/bin/statusline-workdir-hook.sh"
WORKER_HOOK="$ROOT/bin/worker-tag-hook.sh"
SPAWN_HOOK="$ROOT/bin/worker-spawn-hook.sh"
STATUSLINE="$ROOT/bin/statusline.sh"
REVIEW_ROOT="${REVIEW_ROOT:-$ROOT/../review-bench}"
BENCH_CMD="$REVIEW_ROOT/bin/review-bench"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0

fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts failed: expected '$1', got '$2'"
}

[ -x "$BENCH_CMD" ] || fail "review-bench root $REVIEW_ROOT is unreadable (set REVIEW_ROOT)"

HOME="$WORK/home"
FIXTURES="$WORK/fixtures"
TMPDIR="$WORK/runtime-tmp"
CLAUDEB_FIX="$WORK/claudeb"
export HOME TMPDIR
mkdir -p "$HOME/.claude" "$FIXTURES" "$TMPDIR" "$CLAUDEB_FIX/limits"

REPO_A="$FIXTURES/repo a"
REPO_B="$FIXTURES/repo-b"
REPO_C="$FIXTURES/repo-c"
NON_GIT="$FIXTURES/non-git"
mkdir -p "$REPO_A" "$NON_GIT"
git -C "$REPO_A" init -q -b main
printf 'fixture\n' > "$REPO_A/tracked.txt"
git -C "$REPO_A" add tracked.txt
git -C "$REPO_A" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
git -C "$REPO_A" worktree add -q -b feature-x "$REPO_B"
git -C "$REPO_A" worktree add -q --detach "$REPO_C"
# The convention under test: worktrees live at <repo>/.claude/worktrees/<name>,
# git-excluded so they never count as untracked content of the parent repo.
printf '.claude/worktrees/\n' >> "$REPO_A/.git/info/exclude"
REPO_E="$REPO_A/.claude/worktrees/feature-y"
git -C "$REPO_A" worktree add -q -b feature-y "$REPO_E"
REPO_F="$REPO_A/.claude/worktrees/auto-slug"
git -C "$REPO_A" worktree add -q -b claude/agitated-fixture "$REPO_F"
REPO_J="$REPO_A/.claude/worktrees/wut-25-portal"
git -C "$REPO_A" worktree add -q -b WUT-259_feat_portal-fixes "$REPO_J"
REPO_L="$REPO_A/.claude/worktrees/WUT-12345-fix-header"
git -C "$REPO_A" worktree add -q -b wut-12345-fix "$REPO_L"
REPO_M="$REPO_A/.claude/worktrees/WUT_12345-fix"
git -C "$REPO_A" worktree add -q -b wut_12345-fix "$REPO_M"
# A repository whose git dir lives outside the checkout: `<common>/..` is NOT the
# main worktree, so the canonical-location check must ask git, not strip `/.git`.
REPO_G="$FIXTURES/repo-g"
mkdir -p "$REPO_G"
git -C "$REPO_G" init -q --separate-git-dir "$FIXTURES/repo-g-gitdir" -b main
printf 'sep\n' > "$REPO_G/tracked.txt"
git -C "$REPO_G" add tracked.txt
git -C "$REPO_G" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
printf '.claude/worktrees/\n' >> "$FIXTURES/repo-g-gitdir/info/exclude"
REPO_H="$REPO_G/.claude/worktrees/sep-work"
git -C "$REPO_G" worktree add -q -b sep-work "$REPO_H"
REPO_K="$FIXTURES/repo-detached"
mkdir -p "$REPO_K"
git -C "$REPO_K" init -q -b main
printf 'det\n' > "$REPO_K/tracked.txt"
git -C "$REPO_K" add tracked.txt
git -C "$REPO_K" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
git -C "$REPO_K" checkout -q --detach
REPO_D="$FIXTURES/repo-d"
mkdir -p "$REPO_D"
git -C "$REPO_D" init -q -b main
printf 'other\n' > "$REPO_D/other.txt"
git -C "$REPO_D" add other.txt
git -C "$REPO_D" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
ln -s "$REPO_B" "$HOME/project"
TOP_A=$(git -C "$REPO_A" rev-parse --show-toplevel)
TOP_B=$(git -C "$REPO_B" rev-parse --show-toplevel)
TOP_C=$(git -C "$REPO_C" rev-parse --show-toplevel)
TOP_D=$(git -C "$REPO_D" rev-parse --show-toplevel)
TOP_E=$(git -C "$REPO_E" rev-parse --show-toplevel)
TOP_F=$(git -C "$REPO_F" rev-parse --show-toplevel)
TOP_J=$(git -C "$REPO_J" rev-parse --show-toplevel)
TOP_H=$(git -C "$REPO_H" rev-parse --show-toplevel)
TOP_K=$(git -C "$REPO_K" rev-parse --show-toplevel)
SHORT_SHA=$(git -C "$REPO_K" rev-parse --short HEAD)

DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; MAGENTA=$'\033[35m'; RESET=$'\033[0m'
BLUE=$'\033[34m'; CYAN=$'\033[36m'
STATE_DIR="$HOME/.cache/claude-statusline"
# The worker segment with no worker-model file at all: the default sonnet candidate, which is what
# the ordering cases below anchor the end of the line on.
WORKER_MARK="${MAGENTA}SN${RESET}"

workdir_payload() {
  jq -cn --arg event PostToolUse --arg tool "$1" --arg session "$2" --arg cwd "$3" \
    --arg value "$4" '
      {hook_event_name:$event,tool_name:$tool,session_id:$session,cwd:$cwd,
       tool_input:(if $tool == "Bash" then {command:$value}
                   elif $tool == "NotebookEdit" then {notebook_path:$value}
                   else {file_path:$value} end)}'
}

agent_payload() {
  workdir_payload "$@" | jq -c '. + {agent_id:"a1",agent_type:"claudeb-worker"}'
}

run_workdir_hook() {
  local payload=$1 output
  output=$(printf '%s' "$payload" | "$WORKDIR_HOOK") || fail "workdir hook exited nonzero"
  assert_eq "" "$output"
}

# Every write the hook makes goes to the session cache under $HOME, which these
# cases redirect; a hardcoded absolute redirect (a debug probe left in) escapes
# the sandbox entirely and no behavioural case below can see it.
assert_eq "" "$(grep -nE '(^|[[:space:]])>>?[[:space:]]*/' "$WORKDIR_HOOK" | grep -v '/dev/null')"

payload=$(workdir_payload Bash session-cd "$REPO_A" "cd '$REPO_A' && make")
run_workdir_hook "$payload"
assert test -f "$STATE_DIR/workdir-session-cd"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-cd")"

payload=$(workdir_payload Bash session-cd-last "$REPO_A" "cd '$REPO_A' && cd '$REPO_B'")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-cd-last")"

payload=$(workdir_payload Bash session-cd-home "$REPO_A" 'cd "$HOME/project"')
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-cd-home")"

payload=$(workdir_payload Bash session-cd-home-braced "$REPO_A" 'cd "${HOME}/project"')
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-cd-home-braced")"

payload=$(workdir_payload Bash session-cd-tilde "$REPO_A" 'cd "~/project"')
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-cd-tilde")"

nl_cmd=$(printf "true\ncd '%s'" "$REPO_B")
payload=$(workdir_payload Bash session-cd-nl "$REPO_A" "$nl_cmd")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-cd-nl")"

payload=$(workdir_payload Bash session-cd-amp "$REPO_A" "true & cd '$REPO_B'")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-cd-amp")"

# `(cd /x && cmd)` is the form the cd-guard hook tells sessions to use instead of
# a persistent cd, so it is the most common cd there is — and the one that never
# moves the session: it dies with the command. A subshell cd that runs WORK earns
# the home only as sustained work, three in a row, like an away write. All three
# spellings feed the same run; the unquoted one also proves the closing paren
# stays out of the path, since a swallowed `)` would resolve nowhere and break
# the run.
S="$STATE_DIR/workdir-session-cd-subshell"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(workdir_payload Bash session-cd-subshell "$REPO_A" "(cd '$REPO_B' && make)")"
assert_eq "$TOP_A" "$(cat "$S")"
run_workdir_hook "$(workdir_payload Bash session-cd-subshell "$REPO_A" "true && (cd '$REPO_B' && make)")"
assert_eq "$TOP_A" "$(cat "$S")"
run_workdir_hook "$(workdir_payload Bash session-cd-subshell "$REPO_A" "(cd $REPO_B && make)")"
assert_eq "$TOP_B" "$(cat "$S")"
assert test ! -e "$S.away"

S="$STATE_DIR/workdir-session-cd-subshell-split"
printf '%s\n' "$TOP_A" > "$S"
for _ in 1 2 3; do
  run_workdir_hook "$(workdir_payload Bash session-cd-subshell-split "$REPO_A" "(cd '$REPO_B' && make)")"
  run_workdir_hook "$(workdir_payload Bash session-cd-subshell-split "$REPO_A" "(cd '$REPO_D' && make)")"
done
assert_eq "$TOP_A" "$(cat "$S")"

# A persistent cd does move the session, so it still retargets on the first one,
# and so does a mutating `git -C`.
S="$STATE_DIR/workdir-session-cd-persistent"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(workdir_payload Bash session-cd-persistent "$REPO_A" "cd '$REPO_B' && make")"
assert_eq "$TOP_B" "$(cat "$S")"

S="$STATE_DIR/workdir-session-git-mut-home"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(workdir_payload Bash session-git-mut-home "$REPO_A" "(git -C '$REPO_B' checkout main)")"
assert_eq "$TOP_B" "$(cat "$S")"

# A `cd` inside a heredoc body or a multi-line quoted string is text a command is
# fed, not the session moving: the worktree pin, which only a persistent cd
# breaks, stays put through every spelling of the delimiter.
S="$STATE_DIR/workdir-session-heredoc-bare"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-heredoc-bare "$REPO_E" \
  "$(printf "cat <<EOF\ncd '%s'\nEOF" "$REPO_D")")"
assert_eq "$TOP_E" "$(cat "$S")"

S="$STATE_DIR/workdir-session-heredoc-quoted"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-heredoc-quoted "$REPO_E" \
  "$(printf "cat <<'EOF'\ncd '%s'\nEOF" "$REPO_D")")"
assert_eq "$TOP_E" "$(cat "$S")"

S="$STATE_DIR/workdir-session-heredoc-dash"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-heredoc-dash "$REPO_E" \
  "$(printf "cat <<-EOF\n\tcd '%s'\n\tEOF" "$REPO_D")")"
assert_eq "$TOP_E" "$(cat "$S")"

# Masking may only ever LOSE a cd: the real one after the body still moves the
# home, pin and all.
S="$STATE_DIR/workdir-session-heredoc-then-cd"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-heredoc-then-cd "$REPO_E" \
  "$(printf "cat <<'EOF'\ncd /nowhere\nEOF\ncd '%s'" "$REPO_D")")"
assert_eq "$TOP_D" "$(cat "$S")"

S="$STATE_DIR/workdir-session-quoted-span"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-quoted-span "$REPO_E" \
  "$(printf "echo 'first\ncd %s\nlast'" "$REPO_D")")"
assert_eq "$TOP_E" "$(cat "$S")"
run_workdir_hook "$(workdir_payload Bash session-quoted-span "$REPO_E" \
  "$(printf 'echo "first\ncd %s\nlast"' "$REPO_D")")"
assert_eq "$TOP_E" "$(cat "$S")"

# Nesting is no proof the session moved either: an inner subshell cd dies with the
# command, and a brace group is read as no cd at all.
S="$STATE_DIR/workdir-session-cd-nested"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-cd-nested "$REPO_E" "( (cd '$REPO_D') )")"
assert_eq "$TOP_E" "$(cat "$S")"
run_workdir_hook "$(workdir_payload Bash session-cd-nested "$REPO_E" "{ cd '$REPO_D'; }")"
assert_eq "$TOP_E" "$(cat "$S")"

# The worktree pin ignores subshell cds outright, at any count: they are the
# excursions — test runs, greps — stickiness exists to absorb.
S="$STATE_DIR/workdir-session-subshell-sticky"
printf '%s\n' "$TOP_E" > "$S"
for _ in 1 2 3 4; do
  run_workdir_hook "$(workdir_payload Bash session-subshell-sticky "$REPO_E" "(cd '$REPO_A' && make test)")"
done
assert_eq "$TOP_E" "$(cat "$S")"
assert test ! -e "$S.away"

# The incident this model exists for: a session that ran five `(cd /other && git
# log)` lookups in a row saw the strip claim the work had moved there. A subshell
# cd whose whole chain is provably read-only is read-grade — it never moves the
# home and leaves no run behind, at any count.
ro_case=0
while IFS= read -r ro_cmd; do
  [ -n "$ro_cmd" ] || continue
  ro_case=$((ro_case + 1))
  S="$STATE_DIR/workdir-session-ro-$ro_case"
  printf '%s\n' "$TOP_A" > "$S"
  for _ in 1 2 3 4 5; do
    run_workdir_hook "$(workdir_payload Bash "session-ro-$ro_case" "$REPO_A" "$ro_cmd")"
  done
  assert_eq "$TOP_A" "$(cat "$S")"
  assert test ! -e "$S.away"
done <<EOF
(cd '$REPO_D' && git log)
(cd '$REPO_D' && cat other.txt | rg other)
(cd '$REPO_D' && git log 2>/dev/null | head -3)
(cd '$REPO_D' && git log 2>&1 | wc -l)
(cd '$REPO_D' && FOO=1 git -c core.pager=cat log --oneline)
(cd '$REPO_D' && find . -name '*.txt')
(cd '$REPO_D' && sort other.txt)
(cd '$REPO_D' && git log > /dev/null)
EOF

# Anything not PROVABLY read-only stays work, and work in a subshell is still
# sustained: three in a row move the home. A surviving `>` condemns the command
# whatever ran it, the mutating traps inside reading tools (`sort -ro`,
# `find -fprint`, `git diff --output`) are read by name, and a backtick is
# condemned unseen.
work_case=0
while IFS= read -r work_cmd; do
  [ -n "$work_cmd" ] || continue
  work_case=$((work_case + 1))
  S="$STATE_DIR/workdir-session-subshell-work-$work_case"
  printf '%s\n' "$TOP_A" > "$S"
  run_workdir_hook "$(workdir_payload Bash "session-subshell-work-$work_case" "$REPO_A" "$work_cmd")"
  run_workdir_hook "$(workdir_payload Bash "session-subshell-work-$work_case" "$REPO_A" "$work_cmd")"
  assert_eq "$TOP_A" "$(cat "$S")"
  run_workdir_hook "$(workdir_payload Bash "session-subshell-work-$work_case" "$REPO_A" "$work_cmd")"
  assert_eq "$TOP_D" "$(cat "$S")"
done <<EOF
(cd '$REPO_D' && npm test)
(cd '$REPO_D' && git log > out.txt)
(cd '$REPO_D' && find . -delete)
(cd '$REPO_D' && sort -o out.txt other.txt)
(cd '$REPO_D' && git log && make)
(cd '$REPO_D' && FOO=1 make)
(cd '$REPO_D' && sed -i '' s/a/b/ other.txt)
(cd '$REPO_D' && awk '{print > "o.txt"}' other.txt)
(cd '$REPO_D' && git diff --output=/tmp/o.diff)
(cd '$REPO_D' && sort -ro out.txt other.txt)
(cd '$REPO_D' && find . -fprint out.txt)
(cd '$REPO_D' && git log > /dev/null.out)
(cd '$REPO_D' && echo \`touch out.txt\`)
EOF

# Nor can a read-grade excursion establish a home where there is none: that is
# SessionStart's job, or a write's.
for _ in 1 2 3; do
  run_workdir_hook "$(workdir_payload Bash session-ro-fresh "$REPO_A" "(cd '$REPO_D' && git log)")"
done
assert test ! -e "$STATE_DIR/workdir-session-ro-fresh"
assert test ! -e "$STATE_DIR/workdir-session-ro-fresh.away"

# A read-grade excursion cannot break a worktree pin either.
S="$STATE_DIR/workdir-session-ro-sticky"
printf '%s\n' "$TOP_E" > "$S"
for _ in 1 2 3 4 5; do
  run_workdir_hook "$(workdir_payload Bash session-ro-sticky "$REPO_E" "(cd '$REPO_D' && git log)")"
done
assert_eq "$TOP_E" "$(cat "$S")"
assert test ! -e "$S.away"

# `cd` is the most read-only token there is, but a PERSISTENT one is the session
# itself moving, so it retargets at once with nothing else on the line.
S="$STATE_DIR/workdir-session-cd-bare"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(workdir_payload Bash session-cd-bare "$REPO_A" "cd '$REPO_D'")"
assert_eq "$TOP_D" "$(cat "$S")"

# Read-grade evidence AT home interrupts a run in progress exactly like a Read
# does — the run is consecutive evidence — and nothing more.
S="$STATE_DIR/workdir-session-ro-home"
printf '%s\n' "$TOP_D" > "$S"
run_workdir_hook "$(agent_payload Edit session-ro-home "$REPO_D" "$REPO_A/tracked.txt")"
run_workdir_hook "$(workdir_payload Bash session-ro-home "$REPO_D" "(cd $REPO_D)")"
assert_eq "$TOP_A
$TOP_D" "$(cat "$S.away")"
assert_eq "$TOP_D" "$(cat "$S")"
run_workdir_hook "$(agent_payload Edit session-ro-home "$REPO_D" "$REPO_A/tracked.txt")"
run_workdir_hook "$(agent_payload Edit session-ro-home "$REPO_D" "$REPO_A/tracked.txt")"
assert_eq "$TOP_D" "$(cat "$S")"

payload=$(workdir_payload Bash session-pushd "$REPO_A" "pushd '$REPO_B' && make")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-pushd")"

payload=$(workdir_payload Bash session-pushd-n "$REPO_A" "pushd -n '$REPO_B'")
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/workdir-session-pushd-n"

printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-session-cd-dash"
payload=$(workdir_payload Bash session-cd-dash "$REPO_B" "cd -")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-cd-dash")"

payload=$(workdir_payload Bash session-git-ro "$REPO_A" "git -C \"$REPO_B\" status")
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/workdir-session-git-ro"

payload=$(workdir_payload Bash session-git-mut "$REPO_A" "git -C \"$REPO_B\" checkout main")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-git-mut")"

WT_ADD_BASIC="$FIXTURES/wt-add-basic"
git -C "$REPO_A" branch hook-wt-basic
git -C "$REPO_A" worktree add -q "$WT_ADD_BASIC" hook-wt-basic
payload=$(workdir_payload Bash session-wt-add-basic "$REPO_A" \
  "git worktree add $WT_ADD_BASIC hook-wt-basic")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_BASIC" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-basic")"

WT_ADD_BEFORE="$FIXTURES/wt-add-before"
git -C "$REPO_A" worktree add -q -b hook-wt-before "$WT_ADD_BEFORE" HEAD
payload=$(workdir_payload Bash session-wt-add-before "$REPO_A" \
  "git worktree add -b hook-wt-before $WT_ADD_BEFORE HEAD")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_BEFORE" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-before")"

WT_ADD_AFTER="$FIXTURES/wt-add-after"
git -C "$REPO_A" worktree add -q "$WT_ADD_AFTER" -b hook-wt-after HEAD
payload=$(workdir_payload Bash session-wt-add-after "$REPO_A" \
  "git worktree add $WT_ADD_AFTER -b hook-wt-after HEAD")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_AFTER" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-after")"

WT_ADD_REASON="$FIXTURES/wt-add-reason"
git -C "$REPO_A" branch hook-wt-reason
git -C "$REPO_A" worktree add -q --lock --reason my-note "$WT_ADD_REASON" hook-wt-reason
payload=$(workdir_payload Bash session-wt-add-reason "$REPO_A" \
  "git worktree add --lock --reason my-note $WT_ADD_REASON hook-wt-reason")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_REASON" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-reason")"

WT_ADD_ORPHAN="$FIXTURES/wt-add-orphan"
git -C "$REPO_A" worktree add -q --orphan "$WT_ADD_ORPHAN"
payload=$(workdir_payload Bash session-wt-add-orphan "$REPO_A" \
  "git worktree add --orphan $WT_ADD_ORPHAN")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_ORPHAN" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-orphan")"

WT_ADD_SPACE="$FIXTURES/wt add space"
git -C "$REPO_A" worktree add -q -b hook-wt-space "$WT_ADD_SPACE" HEAD
payload=$(workdir_payload Bash session-wt-add-space "$REPO_A" \
  "git worktree add -b hook-wt-space '$WT_ADD_SPACE' HEAD")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_SPACE" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-space")"

WT_ADD_REL="$REPO_A/.claude/worktrees/hook-wt-relative"
git -C "$REPO_A" branch hook-wt-relative
git -C "$REPO_A" worktree add -q ".claude/worktrees/hook-wt-relative" hook-wt-relative
payload=$(workdir_payload Bash session-wt-add-relative "$REPO_D" \
  "git -C '$REPO_A' worktree add .claude/worktrees/hook-wt-relative hook-wt-relative")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_REL" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-relative")"

WT_ADD_AFTER_CD="$REPO_A/.claude/worktrees/hook-wt-after-cd"
git -C "$REPO_A" branch hook-wt-after-cd
git -C "$REPO_A" worktree add -q ".claude/worktrees/hook-wt-after-cd" hook-wt-after-cd
printf '%s\n' "$TOP_D" > "$STATE_DIR/workdir-session-wt-add-after-cd"
payload=$(workdir_payload Bash session-wt-add-after-cd "$REPO_D" \
  "cd '$REPO_A' && git worktree add .claude/worktrees/hook-wt-after-cd hook-wt-after-cd")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_AFTER_CD" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-after-cd")"

WT_ADD_FAILED="$FIXTURES/wt-add-failed"
if git -C "$REPO_A" worktree add "$WT_ADD_FAILED" no-such-worktree-ref >/dev/null 2>&1; then
  fail "failed worktree-add fixture unexpectedly succeeded"
fi
assert test ! -e "$WT_ADD_FAILED"
printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-session-wt-add-failed"
payload=$(workdir_payload Bash session-wt-add-failed "$REPO_A" \
  "git worktree add $WT_ADD_FAILED no-such-worktree-ref")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-wt-add-failed")"

WT_ADD_EXISTING="$REPO_D/existing-worktree-target"
mkdir -p "$WT_ADD_EXISTING"
printf 'occupied\n' > "$WT_ADD_EXISTING/blocker"
git -C "$REPO_A" branch hook-wt-existing
if git -C "$REPO_A" worktree add "$WT_ADD_EXISTING" hook-wt-existing >/dev/null 2>&1; then
  fail "existing-directory worktree-add fixture unexpectedly succeeded"
fi
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-wt-add-existing"
payload=$(workdir_payload Bash session-wt-add-existing "$REPO_A" \
  "git worktree add '$WT_ADD_EXISTING' hook-wt-existing")
run_workdir_hook "$payload"
assert_eq "$TOP_E" "$(cat "$STATE_DIR/workdir-session-wt-add-existing")"
rm -f "$WT_ADD_EXISTING/blocker"
rmdir "$WT_ADD_EXISTING"

WT_ADD_MULTILINE="$FIXTURES/wt-add-multiline"
git -C "$REPO_A" branch hook-wt-multiline
git -C "$REPO_A" worktree add -q "$WT_ADD_MULTILINE" hook-wt-multiline
multiline_cmd=$(printf "git worktree add %s hook-wt-multiline\ncd '%s'" "$WT_ADD_MULTILINE" "$REPO_D")
printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-session-wt-add-multiline"
payload=$(workdir_payload Bash session-wt-add-multiline "$REPO_A" "$multiline_cmd")
run_workdir_hook "$payload"
assert_eq "$TOP_D" "$(cat "$STATE_DIR/workdir-session-wt-add-multiline")"

EXCLUDED_WT_BASE="$HOME/.claude/worktree-add-base"
ln -s "$REPO_A" "$EXCLUDED_WT_BASE"
WT_ADD_ABSOLUTE="$FIXTURES/wt-add-absolute"
git -C "$REPO_A" branch hook-wt-absolute
git -C "$EXCLUDED_WT_BASE" worktree add -q "$WT_ADD_ABSOLUTE" hook-wt-absolute
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-wt-add-absolute"
payload=$(workdir_payload Bash session-wt-add-absolute "$REPO_E" \
  "git -C '$EXCLUDED_WT_BASE' worktree add '$WT_ADD_ABSOLUTE' hook-wt-absolute")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_ABSOLUTE" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-absolute")"
rm -f "$EXCLUDED_WT_BASE"

WT_ADD_STICKY="$REPO_A/.claude/worktrees/hook-wt-sticky"
git -C "$REPO_A" worktree add -q -b hook-wt-sticky "$WT_ADD_STICKY" HEAD
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-wt-add-sticky"
payload=$(workdir_payload Bash session-wt-add-sticky "$REPO_E" \
  "git worktree add -b hook-wt-sticky '$WT_ADD_STICKY' HEAD")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_STICKY" rev-parse --show-toplevel)" \
  "$(cat "$STATE_DIR/workdir-session-wt-add-sticky")"

# The created path is read from the worktree list — snapshotted at PreToolUse,
# diffed at PostToolUse — so the form that expands in the shell, which is what a
# real dispatch writes and what no text parser can follow, retargets as well.
WT_ADD_VAR="$REPO_A/.claude/worktrees/hook-wt-var"
VAR_CMD='R="'"$REPO_A"'"; N=$R/.claude/worktrees/hook-wt-var; git -C "$R" worktree add -b hook-wt-var "$N" HEAD'
S="$STATE_DIR/workdir-session-wt-add-var"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-var "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse"')"
assert test -f "$S.wtadd"
git -C "$REPO_A" worktree add -q -b hook-wt-var "$WT_ADD_VAR" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-var "$REPO_E" "$VAR_CMD")"
assert_eq "$(git -C "$WT_ADD_VAR" rev-parse --show-toplevel)" "$(cat "$S")"
assert test ! -e "$S.wtadd"

# An add that created nothing — and one that cannot be told from a concurrent
# add — leave the home alone rather than guess at a path.
S="$STATE_DIR/workdir-session-wt-add-failed"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-failed "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse"')"
run_workdir_hook "$(workdir_payload Bash session-wt-add-failed "$REPO_E" "$VAR_CMD")"
assert_eq "$TOP_E" "$(cat "$S")"
assert test ! -e "$S.wtadd"

S="$STATE_DIR/workdir-session-wt-add-two"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-two "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse"')"
git -C "$REPO_A" worktree add -q -b hook-wt-two-a "$REPO_A/.claude/worktrees/hook-wt-two-a" HEAD
git -C "$REPO_A" worktree add -q -b hook-wt-two-b "$REPO_A/.claude/worktrees/hook-wt-two-b" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-two "$REPO_E" "$VAR_CMD")"
assert_eq "$TOP_E" "$(cat "$S")"
assert test ! -e "$S.wtadd"

# One snapshot per CALL, keyed on the id both of its events carry: two adds whose
# Pre/Post interleave each measure their own baseline, so the first Post cannot
# adopt what the second add made and the second still finds a baseline of its own.
WT_ADD_ILA="$REPO_A/.claude/worktrees/hook-wt-il-a"
WT_ADD_ILB="$REPO_A/.claude/worktrees/hook-wt-il-b"
S="$STATE_DIR/workdir-session-wt-add-il"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-il "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-a"')"
git -C "$REPO_A" worktree add -q -b hook-wt-il-a "$WT_ADD_ILA" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-il "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-b"')"
assert test -f "$S.wtadd.call-a"
assert test -f "$S.wtadd.call-b"
git -C "$REPO_A" worktree add -q -b hook-wt-il-b "$WT_ADD_ILB" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-il "$REPO_E" "$VAR_CMD" |
  jq -c '.tool_use_id = "call-a"')"
assert_eq "$TOP_E" "$(cat "$S")"
assert test ! -e "$S.wtadd.call-a"
run_workdir_hook "$(workdir_payload Bash session-wt-add-il "$REPO_E" "$VAR_CMD" |
  jq -c '.tool_use_id = "call-b"')"
assert_eq "$(git -C "$WT_ADD_ILB" rev-parse --show-toplevel)" "$(cat "$S")"
assert test ! -e "$S.wtadd.call-b"

# With no repository to snapshot there must be no snapshot at all: an empty one is
# a baseline that answers nothing, and the text-parsed path is then never tried.
WT_ADD_EMPTY="$FIXTURES/wt-add-empty"
S="$STATE_DIR/workdir-session-wt-add-empty"
rm -f "$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-empty "$NON_GIT" \
  "git worktree add $WT_ADD_EMPTY hook-wt-empty" | jq -c '.hook_event_name = "PreToolUse"')"
assert test ! -e "$S.wtadd"
git -C "$REPO_A" branch hook-wt-empty
git -C "$REPO_A" worktree add -q "$WT_ADD_EMPTY" hook-wt-empty
run_workdir_hook "$(workdir_payload Bash session-wt-add-empty "$NON_GIT" \
  "git worktree add $WT_ADD_EMPTY hook-wt-empty")"
assert_eq "$(git -C "$WT_ADD_EMPTY" rev-parse --show-toplevel)" "$(cat "$S")"

# A concurrent add in the same family is a single new path too. When the command
# names a directory that exists, the worktree it made is the only one that path
# can be, so anything else is somebody else's.
WT_ADD_TAKEN="$REPO_D/wt-add-taken"
mkdir -p "$WT_ADD_TAKEN"
WT_ADD_RIVAL="$REPO_A/.claude/worktrees/hook-wt-rival"
RIVAL_CMD="git -C '$REPO_A' worktree add '$WT_ADD_TAKEN' hook-wt-rival"
S="$STATE_DIR/workdir-session-wt-add-rival"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-rival "$REPO_E" "$RIVAL_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-rival"')"
git -C "$REPO_A" worktree add -q -b hook-wt-rival "$WT_ADD_RIVAL" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-rival "$REPO_E" "$RIVAL_CMD" |
  jq -c '.tool_use_id = "call-rival"')"
assert_eq "$TOP_E" "$(cat "$S")"

WT_ADD_NAMED="$REPO_A/.claude/worktrees/hook-wt-named"
NAMED_CMD="git -C '$REPO_A' worktree add -b hook-wt-named '$WT_ADD_NAMED' HEAD"
S="$STATE_DIR/workdir-session-wt-add-named"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-named "$REPO_E" "$NAMED_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-named"')"
git -C "$REPO_A" worktree add -q -b hook-wt-named "$WT_ADD_NAMED" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-named "$REPO_E" "$NAMED_CMD" |
  jq -c '.tool_use_id = "call-named"')"
assert_eq "$(git -C "$WT_ADD_NAMED" rev-parse --show-toplevel)" "$(cat "$S")"

# A denied command fires PreToolUse and never the PostToolUse that consumes its
# snapshot, so the leaked file is swept an hour later rather than after a week.
S="$STATE_DIR/workdir-session-wt-prune"
printf '%s\n' "$TOP_A" > "$S"
: > "$S.wtadd.call-leaked"
: > "$S.wtadd.call-live"
# Two hours, not eight days: the week-long `workdir-*` sweep must not be what takes it.
leaked_stamp=$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)
touch -t "$leaked_stamp" "$S.wtadd.call-leaked"
touch -t 202001010000 "$STATE_DIR/.workdir-prune"
run_workdir_hook "$(workdir_payload Bash session-wt-prune "$REPO_A" "cd '$REPO_B'")"
assert_eq "$TOP_B" "$(cat "$S")"
assert test ! -e "$S.wtadd.call-leaked"
assert test -f "$S.wtadd.call-live"
rm -f "$S.wtadd.call-live"

printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-session-wt-list"
payload=$(workdir_payload Bash session-wt-list "$REPO_A" "git -C '$REPO_B' worktree list")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-wt-list")"

payload=$(workdir_payload Bash session-cd-then-ro "$REPO_A" "cd '$REPO_B' && git -C '$REPO_A' log")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-cd-then-ro")"

printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-session-plain"
payload=$(workdir_payload Bash session-plain "$REPO_A" "printf done")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-plain")"

printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-session-tmp"
payload=$(workdir_payload Bash session-tmp "$REPO_A" "cd /tmp && pwd")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-tmp")"

payload=$(workdir_payload Bash session-non-git "$REPO_A" "cd '$NON_GIT' && pwd")
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/workdir-session-non-git"

payload=$(workdir_payload Edit session-edit "$REPO_B" "$REPO_A/tracked.txt")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-edit")"

payload=$(workdir_payload Edit ../evil "$REPO_A" "$REPO_B/tracked.txt")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-evil")"
assert test ! -e "$HOME/.cache/evil"

payload=$(workdir_payload Bash session-agent "$REPO_A" "cd '$REPO_B'" | jq -c '. + {agent_id:"a1",agent_type:"claudeb-worker"}')
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/workdir-session-agent"

# A subagent's cds stay invisible however many there are: the worker runs
# wherever it was dispatched, and its shell is not the session's.
S="$STATE_DIR/workdir-session-agent-cds"
printf '%s\n' "$TOP_A" > "$S"
for _ in 1 2 3 4; do
  run_workdir_hook "$(agent_payload Bash session-agent-cds "$REPO_A" "cd '$REPO_B' && make")"
done
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# Its WRITES are heard, but only as sustained work — in orchestrator mode every
# substantive edit is a subagent's, so ignoring them left the statusline behind.
# The proof is the same three-in-a-row run as the worktree pin, and it applies to
# a plain main-checkout home too: a worker starts at a path the session never
# visited, so one write there is no evidence the work has moved.
S="$STATE_DIR/workdir-session-agent-edit"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(agent_payload Edit session-agent-edit "$REPO_A" "$REPO_D/other.txt")"
assert_eq "$TOP_A" "$(cat "$S")"
run_workdir_hook "$(agent_payload Write session-agent-edit "$REPO_A" "$REPO_D/new.txt")"
assert_eq "$TOP_A" "$(cat "$S")"
run_workdir_hook "$(agent_payload Edit session-agent-edit "$REPO_A" "$REPO_D/other.txt")"
assert_eq "$TOP_D" "$(cat "$S")"
assert test ! -e "$S.away"

S="$STATE_DIR/workdir-session-agent-split"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(agent_payload Edit session-agent-split "$REPO_A" "$REPO_D/other.txt")"
run_workdir_hook "$(agent_payload Edit session-agent-split "$REPO_A" "$REPO_B/tracked.txt")"
run_workdir_hook "$(agent_payload Edit session-agent-split "$REPO_A" "$REPO_D/other.txt")"
assert_eq "$TOP_A" "$(cat "$S")"

# Writing where the session already lives is not away work at all.
S="$STATE_DIR/workdir-session-agent-home"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(agent_payload Edit session-agent-home "$REPO_A" "$REPO_A/tracked.txt")"
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# With no home yet there is nothing to protect, so the first write adopts.
run_workdir_hook "$(agent_payload Edit session-agent-fresh "$REPO_A" "$REPO_D/other.txt")"
assert_eq "$TOP_D" "$(cat "$STATE_DIR/workdir-session-agent-fresh")"

# The standing exclusions come first for subagents too, so a worker editing hooks
# or caches never accumulates a run.
S="$STATE_DIR/workdir-session-agent-excluded"
printf '%s\n' "$TOP_A" > "$S"
for _ in 1 2 3; do
  run_workdir_hook "$(agent_payload Write session-agent-excluded "$REPO_A" "$HOME/.claude/settings.json")"
done
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# One run, whoever writes: a worktree pin sees parent and subagent writes as the
# same sustained work.
S="$STATE_DIR/workdir-session-agent-wt"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Edit session-agent-wt "$REPO_E" "$REPO_A/tracked.txt")"
run_workdir_hook "$(agent_payload Edit session-agent-wt "$REPO_E" "$REPO_A/tracked.txt")"
assert_eq "$TOP_E" "$(cat "$S")"
run_workdir_hook "$(agent_payload Write session-agent-wt "$REPO_E" "$REPO_A/new.txt")"
assert_eq "$TOP_A" "$(cat "$S")"

dispatch_payload() {
  jq -cn --arg event "${5:-PreToolUse}" --arg tool "$1" --arg session "$2" --arg cwd "$3" --arg prompt "$4" \
    '{hook_event_name:$event,tool_name:$tool,session_id:$session,cwd:$cwd,tool_input:{prompt:$prompt}}'
}

# Dispatching a worker is the only signal an orchestrator session emits: the
# edits themselves happen in another process, at a path the parent never visits.
# The brief names that path, so the dispatch counts as a write — the harness
# calls the tool Task or Agent depending on its version, and both are heard.
for tool in Task Agent; do
  S="$STATE_DIR/workdir-session-dispatch-$tool"
  printf '%s\n' "$TOP_A" > "$S"
  run_workdir_hook "$(dispatch_payload "$tool" "session-dispatch-$tool" "$REPO_A" \
    "Work in the main checkout: cd '$REPO_D' && run the suite.")"
  assert_eq "$TOP_D" "$(cat "$S")"
done

# First RESOLVABLE path, not first path: briefs open with excluded config paths,
# file names and prose before naming the workspace, and only a directory that is
# in a repository says where the worker will run.
S="$STATE_DIR/workdir-session-dispatch-skip"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(dispatch_payload Task session-dispatch-skip "$REPO_A" \
  "Read $HOME/.claude/agents/worker.md, then $REPO_B/tracked.txt and /nonexistent/place; work in $REPO_D")"
assert_eq "$TOP_D" "$(cat "$S")"

# The ten-token cap counts CANDIDATES, not raw matches: prose punctuation leaves
# tokens that are a bare slash once trailing dots are stripped, and letting those
# eat cap slots dropped the workspace named eleventh in the raw scan.
S="$STATE_DIR/workdir-session-dispatch-cap"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(dispatch_payload Task session-dispatch-cap "$REPO_A" \
  "Start at /. then /... then /nonexistent/a1 /nonexistent/a2 /nonexistent/a3 /nonexistent/a4 \
/nonexistent/a5 /nonexistent/a6 /nonexistent/a7 /nonexistent/a8 /nonexistent/a9 and work in $REPO_D")"
assert_eq "$TOP_D" "$(cat "$S")"

S="$STATE_DIR/workdir-session-dispatch-nopath"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(dispatch_payload Task session-dispatch-nopath "$REPO_A" "Summarise the review findings.")"
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# A worker dispatching its own subagent says nothing about where the SESSION
# works, and its brief would drag the parent strip along.
S="$STATE_DIR/workdir-session-dispatch-agent"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(dispatch_payload Task session-dispatch-agent "$REPO_A" "cd '$REPO_D' && fix it" \
  | jq -c '. + {agent_id:"a1",agent_type:"claudeb-worker"}')"
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# Only the launch counts: the same brief arrives again when the worker returns,
# and hearing it twice would let one dispatch fill two thirds of the run.
S="$STATE_DIR/workdir-session-dispatch-post"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(dispatch_payload Task session-dispatch-post "$REPO_A" "cd '$REPO_D' && fix it" PostToolUse)"
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# Against a sticky worktree pin a dispatch is evidence like any other write:
# sustained, three in a row into the same toplevel.
S="$STATE_DIR/workdir-session-dispatch-sticky"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(dispatch_payload Task session-dispatch-sticky "$REPO_E" "cd '$REPO_D' && build")"
assert_eq "$TOP_E" "$(cat "$S")"
run_workdir_hook "$(dispatch_payload Agent session-dispatch-sticky "$REPO_E" "work in $REPO_D")"
assert_eq "$TOP_E" "$(cat "$S")"
run_workdir_hook "$(workdir_payload Edit session-dispatch-sticky "$REPO_E" "$REPO_D/other.txt")"
assert_eq "$TOP_D" "$(cat "$S")"

# --- no ownership claims are written -------------------------------------------------------
# The hook used to answer a second question here — which changed paths are THIS chat's work — into
# `touched-<sid>`, for a review segment that has since become the gate's mouthpiece. Session-path
# ownership is the commit journal's now, so nothing may write that file back: it had no reader, and
# a claim nobody reads is a claim nobody can check.
run_workdir_hook "$(workdir_payload Edit session-touch "$REPO_A" "$REPO_A/tracked.txt")"
run_workdir_hook "$(agent_payload Edit session-touch-agent "$REPO_A" "$REPO_D/other.txt")"
run_workdir_hook "$(dispatch_payload Task session-touch-dispatch "$REPO_A" \
  "Work in $REPO_D. Change $REPO_D/other.txt and $REPO_B/tracked.txt.")"
assert_eq 0 "$(find "$STATE_DIR" -name 'touched-*' | wc -l | tr -d ' ')"

# The session's own reads are not evidence at all: a lookup elsewhere never moves
# the home, however many of them run in a row, and it leaves no run behind for a
# later write to complete.
S="$STATE_DIR/workdir-session-read-move"
printf '%s\n' "$TOP_A" > "$S"
for _ in 1 2 3 4 5; do
  run_workdir_hook "$(workdir_payload Read session-read-move "$REPO_A" "$REPO_D/other.txt")"
done
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# A read is invisible against a worktree pin too.
S="$STATE_DIR/workdir-session-read-sticky"
printf '%s\n' "$TOP_E" > "$S"
for _ in 1 2 3 4 5; do
  run_workdir_hook "$(workdir_payload Read session-read-sticky "$REPO_E" "$REPO_D/other.txt")"
done
assert_eq "$TOP_E" "$(cat "$S")"
assert test ! -e "$S.away"

# A read back home is not work either — it neither rewrites the home nor clears
# the run — but it does INTERRUPT a run someone else's writes started: the run is
# CONSECUTIVE evidence, and leaving the tail untouched let scattered away writes,
# ordinary home reads in between, walk the strip off to another repo.
S="$STATE_DIR/workdir-session-read-home"
printf '%s\n' "$TOP_A" > "$S"
run_workdir_hook "$(agent_payload Edit session-read-home "$REPO_A" "$REPO_D/other.txt")"
run_workdir_hook "$(workdir_payload Read session-read-home "$REPO_A" "$REPO_A/tracked.txt")"
run_workdir_hook "$(agent_payload Edit session-read-home "$REPO_A" "$REPO_D/other.txt")"
run_workdir_hook "$(agent_payload Edit session-read-home "$REPO_A" "$REPO_D/other.txt")"
assert_eq "$TOP_A" "$(cat "$S")"
assert_eq "$TOP_D
$TOP_A
$TOP_D
$TOP_D" "$(cat "$S.away")"
# Nothing is created for a read at home when no run is pending, and a long stay
# at home does not grow the run either.
S="$STATE_DIR/workdir-session-read-home-idle"
printf '%s\n' "$TOP_A" > "$S"
for _ in 1 2 3; do
  run_workdir_hook "$(workdir_payload Read session-read-home-idle "$REPO_A" "$REPO_A/tracked.txt")"
done
assert test ! -e "$S.away"
run_workdir_hook "$(agent_payload Edit session-read-home-idle "$REPO_A" "$REPO_D/other.txt")"
for _ in 1 2 3 4; do
  run_workdir_hook "$(workdir_payload Read session-read-home-idle "$REPO_A" "$REPO_A/tracked.txt")"
done
assert_eq "$TOP_D
$TOP_A" "$(cat "$S.away")"
# The interrupted run still resumes on three fresh writes in a row.
run_workdir_hook "$(agent_payload Edit session-read-home-idle "$REPO_A" "$REPO_D/other.txt")"
run_workdir_hook "$(agent_payload Edit session-read-home-idle "$REPO_A" "$REPO_D/other.txt")"
assert_eq "$TOP_A" "$(cat "$S")"
run_workdir_hook "$(agent_payload Edit session-read-home-idle "$REPO_A" "$REPO_D/other.txt")"
assert_eq "$TOP_D" "$(cat "$S")"

# A subagent's reads stay invisible: an Explore agent reads across every repo it
# can reach, and its sweep is not the session moving.
S="$STATE_DIR/workdir-session-read-agent"
printf '%s\n' "$TOP_A" > "$S"
for _ in 1 2 3; do
  run_workdir_hook "$(agent_payload Read session-read-agent "$REPO_A" "$REPO_D/other.txt")"
done
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# With no home at all a read establishes nothing — unlike a write, which adopts.
# The seed is SessionStart's job.
for _ in 1 2 3; do
  run_workdir_hook "$(workdir_payload Read session-read-fresh "$REPO_A" "$REPO_D/other.txt")"
done
assert test ! -e "$STATE_DIR/workdir-session-read-fresh"
assert test ! -e "$STATE_DIR/workdir-session-read-fresh.away"

payload=$(jq -cn --arg session session-wt --arg cwd "$REPO_A" --arg resp "Created worktree at $REPO_B" \
  '{hook_event_name:"PostToolUse",tool_name:"EnterWorktree",session_id:$session,cwd:$cwd,tool_input:{},tool_response:$resp}')
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-wt")"

payload=$(jq -cn --arg session session-wt-obj --arg cwd "$REPO_B" --arg text "Now working in worktree at $REPO_A
on branch main" \
  '{hook_event_name:"PostToolUse",tool_name:"EnterWorktree",session_id:$session,cwd:$cwd,tool_input:{},tool_response:{text:$text}}')
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-wt-obj")"

payload=$(jq -cn --arg session session-wt-none --arg cwd "$REPO_A" \
  '{hook_event_name:"PostToolUse",tool_name:"EnterWorktree",session_id:$session,cwd:$cwd,tool_input:{},tool_response:"no path in here"}')
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/workdir-session-wt-none"

payload=$(jq -cn --arg session session-wt --arg cwd "$REPO_B" \
  '{hook_event_name:"PostToolUse",tool_name:"ExitWorktree",session_id:$session,cwd:$cwd,tool_input:{}}')
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/workdir-session-wt"

# Sticky worktree home: an edit into a sibling worktree or the main checkout of
# the same repository must NOT retarget a session homed in .claude/worktrees. A
# PERSISTENT cd is the exception — cd-guard denies every one the session did not
# deliberately unlock, so one that reaches PostToolUse is the session moving.
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-sticky-cd"
payload=$(workdir_payload Bash session-sticky-cd "$REPO_E" "cd '$REPO_F' && git status")
run_workdir_hook "$payload"
assert_eq "$TOP_F" "$(cat "$STATE_DIR/workdir-session-sticky-cd")"

printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-sticky-main"
payload=$(workdir_payload Bash session-sticky-main "$REPO_E" "cd '$REPO_A'")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-sticky-main")"

printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-sticky-edit"
payload=$(workdir_payload Edit session-sticky-edit "$REPO_E" "$REPO_F/other.txt")
run_workdir_hook "$payload"
assert_eq "$TOP_E" "$(cat "$STATE_DIR/workdir-session-sticky-edit")"

# Another repository is the same story: a persistent cd there is a move, while
# the subshell form stays the one-off surgery (test runs, config edits) that
# following used to hand the ports segment to that repo mid-task.
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-sticky-repo"
payload=$(workdir_payload Bash session-sticky-repo "$REPO_E" "cd '$REPO_D'")
run_workdir_hook "$payload"
assert_eq "$TOP_D" "$(cat "$STATE_DIR/workdir-session-sticky-repo")"

printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-sticky-repo-sub"
payload=$(workdir_payload Bash session-sticky-repo-sub "$REPO_E" "(cd '$REPO_D' && make)")
run_workdir_hook "$payload"
assert_eq "$TOP_E" "$(cat "$STATE_DIR/workdir-session-sticky-repo-sub")"

# Sticky is not permanent. A worktree made by hand never sees an ExitWorktree,
# so a session that finishes there and works on in the main checkout used to be
# pinned for life, naming a branch and a clean tree that were not the edited
# ones. Three edits in a row into the same other toplevel move the home; the
# first two only accumulate.
S="$STATE_DIR/workdir-session-away-move"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Edit session-away-move "$REPO_E" "$REPO_A/tracked.txt")"
assert_eq "$TOP_E" "$(cat "$S")"
run_workdir_hook "$(workdir_payload Write session-away-move "$REPO_E" "$REPO_A/new.txt")"
assert_eq "$TOP_E" "$(cat "$S")"
assert_eq "$TOP_A
$TOP_A" "$(cat "$S.away")"
run_workdir_hook "$(workdir_payload Edit session-away-move "$REPO_E" "$REPO_A/tracked.txt")"
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# The run is appended and read from the tail, never incremented in place: a turn
# that edits several files issues them as ONE parallel batch, and a
# read-modify-write counter had all of those hooks read the same value and write
# 1, so the batch this rule exists to catch never reached the threshold at all.
S="$STATE_DIR/workdir-session-away-parallel"
printf '%s\n' "$TOP_E" > "$S"
for n in 1 2 3; do
  printf '%s' "$(workdir_payload Edit session-away-parallel "$REPO_E" "$REPO_A/f$n.txt")" | "$WORKDIR_HOOK" &
done
wait
assert_eq "$TOP_A" "$(cat "$S")"

# Alternating writes never reach the threshold, so the run file would otherwise
# grow for the life of the session.
S="$STATE_DIR/workdir-session-away-trim"
printf '%s\n' "$TOP_E" > "$S"
for _ in $(seq 1 70); do
  run_workdir_hook "$(workdir_payload Edit session-away-trim "$REPO_E" "$REPO_A/tracked.txt")"
  run_workdir_hook "$(workdir_payload Edit session-away-trim "$REPO_E" "$REPO_D/other.txt")"
done
assert_eq "$TOP_E" "$(cat "$S")"
assert test "$(wc -l < "$S.away")" -le 64

# The run must be consecutive AND in one place: edits alternating between two
# foreign repos are excursions, not a move.
S="$STATE_DIR/workdir-session-away-split"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Edit session-away-split "$REPO_E" "$REPO_A/tracked.txt")"
run_workdir_hook "$(workdir_payload Edit session-away-split "$REPO_E" "$REPO_D/other.txt")"
run_workdir_hook "$(workdir_payload Edit session-away-split "$REPO_E" "$REPO_A/tracked.txt")"
assert_eq "$TOP_E" "$(cat "$S")"

# Any work back home clears the run — an edit in the worktree, or a plain cd
# into it, which writes the home afresh.
S="$STATE_DIR/workdir-session-away-reset"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Edit session-away-reset "$REPO_E" "$REPO_A/tracked.txt")"
run_workdir_hook "$(workdir_payload Edit session-away-reset "$REPO_E" "$REPO_A/tracked.txt")"
run_workdir_hook "$(workdir_payload Bash session-away-reset "$REPO_A" "cd '$REPO_E'")"
assert test ! -e "$S.away"
run_workdir_hook "$(workdir_payload Edit session-away-reset "$REPO_E" "$REPO_A/tracked.txt")"
run_workdir_hook "$(workdir_payload Edit session-away-reset "$REPO_E" "$REPO_A/tracked.txt")"
assert_eq "$TOP_E" "$(cat "$S")"

# A persistent cd needs no run at all: it breaks the pin on the first one and
# takes a half-built run with it, while the subshell form it is steered into
# (cd-ing out to run tests or grep another repo) stays absorbed at any count.
S="$STATE_DIR/workdir-session-away-cds"
printf '%s\n' "$TOP_E" > "$S"
for _ in 1 2 3 4 5; do
  run_workdir_hook "$(workdir_payload Bash session-away-cds "$REPO_E" "(cd '$REPO_A' && make test)")"
done
assert_eq "$TOP_E" "$(cat "$S")"
assert test ! -e "$S.away"
run_workdir_hook "$(workdir_payload Edit session-away-cds "$REPO_E" "$REPO_A/tracked.txt")"
run_workdir_hook "$(workdir_payload Bash session-away-cds "$REPO_E" "cd '$REPO_A' && make test")"
assert_eq "$TOP_A" "$(cat "$S")"
assert test ! -e "$S.away"

# A half-finished run is session state, not history: it dies with the home.
S="$STATE_DIR/workdir-session-away-exit"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Edit session-away-exit "$REPO_E" "$REPO_A/tracked.txt")"
assert test -e "$S.away"
run_workdir_hook "$(jq -cn --arg session session-away-exit --arg cwd "$REPO_E" \
  '{hook_event_name:"PostToolUse",tool_name:"ExitWorktree",session_id:$session,cwd:$cwd,tool_input:{},tool_response:""}')"
assert test ! -e "$S.away"

S="$STATE_DIR/workdir-session-away-clear"
printf '%s\n' "$TOP_E" > "$S"
run_workdir_hook "$(workdir_payload Edit session-away-clear "$REPO_E" "$REPO_A/tracked.txt")"
assert test -e "$S.away"
run_workdir_hook "$(jq -cn --arg session session-away-clear --arg cwd "$REPO_E" \
  '{hook_event_name:"SessionStart",session_id:$session,cwd:$cwd,source:"clear"}')"
assert test ! -e "$S.away"

# EnterWorktree is the deliberate move and bypasses stickiness.
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-sticky-enter"
payload=$(jq -cn --arg session session-sticky-enter --arg cwd "$REPO_E" --arg resp "Created worktree at $REPO_F" \
  '{hook_event_name:"PostToolUse",tool_name:"EnterWorktree",session_id:$session,cwd:$cwd,tool_input:{},tool_response:$resp}')
run_workdir_hook "$payload"
assert_eq "$TOP_F" "$(cat "$STATE_DIR/workdir-session-sticky-enter")"

# A main-checkout home is not sticky: moving into a worktree adopts it.
printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-session-main-to-wt"
payload=$(workdir_payload Bash session-main-to-wt "$REPO_A" "cd '$REPO_E'")
run_workdir_hook "$payload"
assert_eq "$TOP_E" "$(cat "$STATE_DIR/workdir-session-main-to-wt")"

# ~/.claude paths are excluded on the LOGICAL path, before symlink resolution:
# ~/.claude/hooks really is a symlink into a config repo, and resolving first
# used to adopt that repo as the session home.
ln -s "$REPO_D" "$HOME/.claude/hooks"
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-claude-symlink"
payload=$(workdir_payload Write session-claude-symlink "$REPO_E" "$HOME/.claude/hooks/some-hook.sh")
run_workdir_hook "$payload"
assert_eq "$TOP_E" "$(cat "$STATE_DIR/workdir-session-claude-symlink")"
rm -f "$HOME/.claude/hooks"

# A non-worktree home still follows into any repository, including a SEPARATE
# one nested under the project dir.
NESTED="$REPO_A/vendored"
mkdir -p "$NESTED"
git -C "$NESTED" init -q -b main
printf 'nested\n' > "$NESTED/n.txt"
git -C "$NESTED" add n.txt
git -C "$NESTED" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
TOP_NESTED=$(git -C "$NESTED" rev-parse --show-toplevel)
printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-session-nested-repo"
payload=$(workdir_payload Bash session-nested-repo "$REPO_A" "cd '$NESTED'")
run_workdir_hook "$payload"
assert_eq "$TOP_NESTED" "$(cat "$STATE_DIR/workdir-session-nested-repo")"
# The nested repo is an untracked entry in repo A; later renders assert a clean tree.
rm -rf "$NESTED"

session_start_payload() {
  jq -cn --arg source "$1" --arg session "$2" --arg cwd "${3:-$REPO_A}" \
    '{hook_event_name:"SessionStart",source:$source,session_id:$session,cwd:$cwd}'
}

# startup/clear replace any surviving state with a seed from the session's own
# starting cwd — an empty home would let the first one-off cd/edit anywhere
# adopt a foreign dir before stickiness can protect anything. resume does not:
# see the live-home cases below.
for src in startup clear; do
  printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-session-ss-$src"
  run_workdir_hook "$(session_start_payload "$src" "session-ss-$src")"
  assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-$src")"
done

printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-session-ss-compact"
run_workdir_hook "$(session_start_payload compact session-ss-compact)"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-ss-compact")"

printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-session-ss-agent"
payload=$(session_start_payload startup session-ss-agent | jq -c '. + {agent_type:"reviewer"}')
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-agent")"

# Non-git cwd: state is cleared and nothing is seeded.
printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-session-ss-nogit"
run_workdir_hook "$(session_start_payload startup session-ss-nogit "$WORK")"
assert test ! -e "$STATE_DIR/workdir-session-ss-nogit"

# resume keeps ANY live home, worktree or not: the event's cwd is the launch dir
# (often the main checkout), not where the work lives — reseeding would retarget
# the strip and the ports segment on every resume of a long chat. clear still
# reseeds, and so does a resume whose home no longer exists on disk.
S="$STATE_DIR/workdir-session-ss-resume-plain"
printf '%s\n' "$TOP_D" > "$S"
printf '%s\n' "$TOP_A" > "$S.away"
run_workdir_hook "$(session_start_payload resume session-ss-resume-plain)"
assert_eq "$TOP_D" "$(cat "$S")"
assert test ! -e "$S.away"

printf '%s\n' "$FIXTURES/vanished-repo" > "$STATE_DIR/workdir-session-ss-resume-plain-dead"
run_workdir_hook "$(session_start_payload resume session-ss-resume-plain-dead)"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-resume-plain-dead")"

# A dir that survives but is no longer its own toplevel is not a live home
# either: git discovery ascends and the kept home would name the owning
# checkout's branch as the workspace.
printf '%s\n' "$REPO_A/vendored-gone" > "$STATE_DIR/workdir-session-ss-resume-subdir"
mkdir -p "$REPO_A/vendored-gone"
run_workdir_hook "$(session_start_payload resume session-ss-resume-subdir)"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-resume-subdir")"
rmdir "$REPO_A/vendored-gone"

printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-ss-resume-wt"
run_workdir_hook "$(session_start_payload resume session-ss-resume-wt)"
assert_eq "$TOP_E" "$(cat "$STATE_DIR/workdir-session-ss-resume-wt")"
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-session-ss-clear-wt"
run_workdir_hook "$(session_start_payload clear session-ss-clear-wt)"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-clear-wt")"
printf '%s\n' "$REPO_A/.claude/worktrees/vanished-wt" > "$STATE_DIR/workdir-session-ss-resume-dead"
run_workdir_hook "$(session_start_payload resume session-ss-resume-dead)"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-resume-dead")"
# A worktree directory that outlived its git link is NOT a live home: it sits
# inside the parent checkout, so git discovery ascends and keeping it would make
# the strip report the main checkout's branch — no `⧉`, nothing — as if that
# were the workspace. Reseeding at least names where the shell is.
UNLINKED="$REPO_A/.claude/worktrees/lost-link"
git -C "$REPO_A" worktree add -q -b lost-link "$UNLINKED"
rm -f "$UNLINKED/.git"
printf '%s\n' "$UNLINKED" > "$STATE_DIR/workdir-session-ss-resume-unlinked"
run_workdir_hook "$(session_start_payload resume session-ss-resume-unlinked)"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-resume-unlinked")"
rm -rf "$UNLINKED"
git -C "$REPO_A" worktree prune
git -C "$REPO_A" branch -qD lost-link
# Same for a `.claude/worktrees/` path under no repository at all.
NO_REPO="$FIXTURES/orphan-holder/.claude/worktrees/leftover"
mkdir -p "$NO_REPO"
printf '%s\n' "$NO_REPO" > "$STATE_DIR/workdir-session-ss-resume-norepo"
run_workdir_hook "$(session_start_payload resume session-ss-resume-norepo)"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-resume-norepo")"
rm -rf "$FIXTURES/orphan-holder"
# No state and empty state are the seeding paths, not keeping ones.
rm -f "$STATE_DIR/workdir-session-ss-resume-fresh"
run_workdir_hook "$(session_start_payload resume session-ss-resume-fresh)"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-resume-fresh")"
: > "$STATE_DIR/workdir-session-ss-resume-empty"
run_workdir_hook "$(session_start_payload resume session-ss-resume-empty)"
assert_eq "$TOP_A" "$(cat "$STATE_DIR/workdir-session-ss-resume-empty")"

# The live failure this seed exists for: a session born in a worktree runs a
# one-off cd into a sibling — the seeded home must hold through stickiness.
run_workdir_hook "$(session_start_payload startup session-ss-seed-sticky "$REPO_E")"
assert_eq "$TOP_E" "$(cat "$STATE_DIR/workdir-session-ss-seed-sticky")"
payload=$(workdir_payload Bash session-ss-seed-sticky "$REPO_E" "(cd '$REPO_A' && git status)")
run_workdir_hook "$payload"
assert_eq "$TOP_E" "$(cat "$STATE_DIR/workdir-session-ss-seed-sticky")"

statusline_payload() {
  local extra="${2-}"
  local cwd="${3:-$REPO_A}"
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg session "$1" --arg cwd "$cwd" --argjson extra "$extra" '
    {session_id:$session,cwd:$cwd,workspace:{current_dir:$cwd,project_dir:$cwd},
     model:{display_name:"Fixture"},effort:{level:"high"},
     context_window:{used_percentage:12,current_usage:{input_tokens:1000}}}
    * $extra'
}

run_statusline() {
  # The ports probe reads the real process tree; neutralize it (true emits no
  # snapshot -> empty cache) so renders stay hermetic and deterministic. The
  # store merge-kick would otherwise spawn the real llm-limits.sh collector;
  # point it at a no-op (overridden per-case below where the kick is exercised).
  # COLUMNS is passed explicitly and empty by default: the fit loop reads it, and a value inherited
  # from whatever terminal runs the suite would shrink lines every other case measures at full width.
  printf '%s' "$1" | CLAUDE_LIMITS_ACCOUNT="${2:-${RUN_STATUSLINE_DEFAULT_ACCOUNT:-main}}" CLAUDEB_DIR="$CLAUDEB_FIX" \
    COLUMNS="${FIT_COLUMNS:-}" \
    LLM_LIMITS_FILE="$WORK/limits.json" STATUSLINE_PS=true STATUSLINE_LSOF=true \
    STATUSLINE_STORE_MERGE_CMD="${STORE_MERGE_CMD:-/usr/bin/true}" \
    STATUSLINE_REVIEW_GATE="${GATE_CMD:-}" STATUSLINE_REVIEW_BENCH="${BENCH_CMD:-}" "$STATUSLINE"
}

status_payload=$(statusline_payload status-override)
control_one=$(run_statusline "$status_payload") || fail "statusline control failed"
control_two=$(run_statusline "$status_payload") || fail "statusline second control failed"
assert_eq "$control_one" "$control_two"
assert grep -Fq main <<< "$control_one"
assert test "${control_one#*»}" = "$control_one"

# A worktree of the project is `⧉ <dir>`, never `»` — that arrow is reserved for
# a foreign repository. This one sits outside <repo>/.claude/worktrees, which is
# the one alarm the cluster still carries.
printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-status-override"
override_output=$(run_statusline "$status_payload") || fail "statusline override failed"
assert test "${override_output#*»}" = "$override_output"
assert grep -Fq "${RED}⧉ $(basename "$TOP_B")" <<< "$override_output"
assert test "${override_output#*⎇}" = "$override_output"

# In a worktree the directory label IS the identity: no branch segment at all,
# whatever the branch is called. Canonical location, name matching the branch.
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-status-canon"
canon_output=$(run_statusline "$(statusline_payload status-canon)") || fail "statusline canonical worktree failed"
assert grep -Fq "${BLUE}⧉ feature-y" <<< "$canon_output"
assert test "${canon_output#*⎇}" = "$canon_output"

# A branch bearing no relation to the directory name is not printed either.
printf '%s\n' "$TOP_J" > "$STATE_DIR/workdir-status-ticket"
ticket_output=$(run_statusline "$(statusline_payload status-ticket)") || fail "statusline diverged branch failed"
assert grep -Fq "${BLUE}⧉ wut-25-portal" <<< "$ticket_output"
assert test "${ticket_output#*⎇}" = "$ticket_output"
assert test "${ticket_output#*WUT-259}" = "$ticket_output"

# Nor a harness auto-slug: branch names are policed nowhere on the strip.
printf '%s\n' "$TOP_F" > "$STATE_DIR/workdir-status-autoslug"
autoslug_output=$(run_statusline "$(statusline_payload status-autoslug)") || fail "statusline auto-slug failed"
assert grep -Fq "${BLUE}⧉ auto-slug" <<< "$autoslug_output"
assert test "${autoslug_output#*⎇}" = "$autoslug_output"
assert test "${autoslug_output#*claude/agitated}" = "$autoslug_output"

# Detached HEAD in a worktree is no exception — but the diff still measures.
printf 'd1\n' > "$TOP_C/wt-det-junk.txt"
printf '%s\n' "$TOP_C" > "$STATE_DIR/workdir-status-wt-detached"
wt_det_output=$(run_statusline "$(statusline_payload status-wt-detached)") || fail "statusline detached worktree failed"
assert grep -Fq "⧉ $(basename "$TOP_C")" <<< "$wt_det_output"
assert test "${wt_det_output#*⎇}" = "$wt_det_output"
assert grep -Fq "${GREEN}+1${RESET}/${RED}-0${RESET} ${DIM}+1f${RESET}" <<< "$wt_det_output"
rm -f "$TOP_C/wt-det-junk.txt"

# Same worktree, chat launched inside it: the project it belongs to stays visible.
in_wt_output=$(run_statusline "$(statusline_payload status-in-wt '' "$REPO_E")") || fail "statusline in-worktree failed"
assert grep -Fq "$(basename "$TOP_A")" <<< "$in_wt_output"
assert grep -Fq "${BLUE}⧉ feature-y" <<< "$in_wt_output"

# Separate git dir: the location check must resolve the main worktree through git,
# not by stripping `/.git` off the common dir, or an in-convention worktree reads
# as misplaced.
printf '%s\n' "$TOP_H" > "$STATE_DIR/workdir-status-sepdir"
sepdir_output=$(run_statusline "$(statusline_payload status-sepdir '' "$REPO_G")") || fail "statusline separate-git-dir failed"
assert grep -Fq "${BLUE}⧉ sep-work" <<< "$sepdir_output"

# A foreign repository keeps `»` and always shows its branch.
printf '%s\n' "$TOP_D" > "$STATE_DIR/workdir-status-foreign"
foreign_output=$(run_statusline "$(statusline_payload status-foreign)") || fail "statusline foreign repo failed"
assert grep -Fq "»" <<< "$foreign_output"
assert grep -Fq "$(basename "$TOP_D")" <<< "$foreign_output"
assert grep -Fq '⎇ main' <<< "$foreign_output"
assert test "${foreign_output#*⧉}" = "$foreign_output"

same_payload=$(statusline_payload status-same)
printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-status-same"
same_output=$(run_statusline "$same_payload") || fail "statusline same-repo failed"
assert grep -Fq main <<< "$same_output"
assert test "${same_output#*»}" = "$same_output"

# A tracked directory that stopped resolving (removed worktree): the render falls
# back to the session project silently — the stale pointer is dropped and nothing
# is left behind to render a breadcrumb from.
printf '%s\n' "$FIXTURES/vanished" > "$STATE_DIR/workdir-status-dangling"
dangling_output=$(run_statusline "$(statusline_payload status-dangling)") || fail "statusline dangling failed"
assert grep -Fq "${BLUE}⎇ main" <<< "$dangling_output"
assert test "${dangling_output#*»}" = "$dangling_output"
assert test "${dangling_output#*⧉}" = "$dangling_output"
assert test "${dangling_output#*✗}" = "$dangling_output"
assert test ! -e "$STATE_DIR/workdir-status-dangling"
assert test ! -e "$STATE_DIR/workdir-status-dangling.gone"

# Outside a worktree the branch always shows, detached HEAD as `@sha`.
detached_output=$(run_statusline "$(statusline_payload status-detached '' "$REPO_K")") || fail "statusline detached failed"
assert grep -Fq "@$SHORT_SHA" <<< "$detached_output"

with_effort=$(run_statusline "$(statusline_payload status-effort)") || fail "statusline effort failed"
assert grep -Fq 'Fixture high' <<< "$with_effort"
no_effort=$(statusline_payload status-no-effort | jq -c 'del(.effort)')
no_effort_output=$(run_statusline "$no_effort") || fail "statusline no-effort failed"
assert grep -Fq "Fixture${RESET}" <<< "$no_effort_output"
assert test "${no_effort_output#*Fixture high}" = "$no_effort_output"

fast_output=$(run_statusline "$(statusline_payload status-fast '{"fast_mode":true}')") || fail "statusline fast failed"
assert grep -Fq '⚡' <<< "$fast_output"
assert test "${with_effort#*⚡}" = "$with_effort"


worker_file="$HOME/.claude/worker-model"
rm -f "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-def)")
assert grep -Fq "${MAGENTA}SN${RESET}" <<< "$worker_out"
# The `w:<name>` label is gone at every width: one candidate needs no vendor caption.
assert test "${worker_out#*w:}" = "$worker_out"

printf 'worker=sonnet\nsonnet_effort=high\ncodex_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-son-eff)")
assert grep -Fq "${MAGENTA}SN${RESET}${DIM}·hi${RESET}" <<< "$worker_out"

printf 'worker=codex\ncodex_effort=medium\ncodex_profile=alt\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex)")
assert grep -Fq "${MAGENTA}@alt${RESET}${DIM}·SL·med${RESET}" <<< "$worker_out"

# No prediction to read: one candidate or none — never a `?` standing in for an account.
rm -f "$HOME/.cache/worker-pick.line.main"
printf 'worker=codex\ncodex_effort=xhigh\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-unres)")
assert test "${worker_out#*·SL}" = "$worker_out"
worker_line1="${worker_out%%$'\n'*}"
assert test "${worker_line1#*'?'}" = "$worker_line1"

printf 'worker=claudeb\ncodex_effort=high\nclaudeb_profile=notcom\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb)")
assert grep -Fq "${MAGENTA}@notcom${RESET}${DIM}·OP·hi${RESET}" <<< "$worker_out"

printf 'worker=claudeb\ncodex_effort=high\nclaudeb_model=haiku\nclaudeb_effort=xhigh\n' > "$worker_file"
mkdir -p "$HOME/.cache"
printf 'cx✓alt·sol·med cb~notcom·hai·xh gx✓work·flash·med\n' \
  >"$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-model)")
assert grep -Fq "${MAGENTA}notcom${RESET}${DIM}·HK·xhi${RESET}" <<< "$worker_out"

# `cb~?` names no account, so claudeb has no candidate — and the vendor beside it is not promoted:
# a fixed vendor answers for itself alone.
printf 'cx✓alt·sol·med cb~? gx✓work·flash·med\n' >"$HOME/.cache/worker-pick.line.main"
printf 'worker=claudeb\ncodex_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-unres)")
assert test "${worker_out#*·OP}" = "$worker_out"
assert test "${worker_out#*alt}" = "$worker_out"

printf 'cx✓alt·sol·med cb~notcom·opus·hi gx✓work·flash·med\n' \
  >"$HOME/.cache/worker-pick.line.main"
printf 'worker=gemini\ngemini_model=flash\ngemini_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-gemini)")
assert grep -Fq "${MAGENTA}work${RESET}${DIM}·FL·med${RESET}" <<< "$worker_out"

printf 'worker=gemini\ngemini_profile=work\ngemini_model=flash\ngemini_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-gemini-pin)")
assert grep -Fq "${MAGENTA}@work${RESET}${DIM}·FL·med${RESET}" <<< "$worker_out"

# Auto renders ONE candidate — worker-pick's own order, claudeb first — never the three-vendor line.
printf 'cx✓alt·sol·med cb~notcom·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
printf 'worker=auto\nclaudeb_model=fable\nclaudeb_effort=high\ngemini_model=pro\ngemini_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-auto)" main)
assert grep -Fq "${MAGENTA}notcom${RESET}${DIM}·FB·hi${RESET}" <<< "$worker_out"
assert test "${worker_out#*gx}" = "$worker_out"
assert test "${worker_out#*alt}" = "$worker_out"

# Claudeb walled: the next vendor in that order carries the candidate, with ITS model and effort.
printf 'cx✓alt·sol·med cb~? gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-auto-cx)" main)
assert grep -Fq "${MAGENTA}alt${RESET}${DIM}·SL·hi${RESET}" <<< "$worker_out"

# A vendor switched off for workers is skipped in auto, and gemini answers instead.
printf 'cx⏸off·sol·med cb⏸off·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-auto-off)" main)
assert grep -Fq "${MAGENTA}main${RESET}${DIM}·PR·hi${RESET}" <<< "$worker_out"

# Every vendor unusable: no candidate at all rather than a guess.
printf 'cx✗·? cb~? gx✗?·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-auto-walled)" main)
assert test "${worker_out#*·PR}" = "$worker_out"
assert test "${worker_out#*·SL}" = "$worker_out"

# The unusable fields carry `?`, so splitting the prediction must not glob against the CWD the
# render happens to run in — a file there would be read as the account of a walled vendor.
glob_bait="$WORK/glob-bait"
mkdir -p "$glob_bait"
: > "$glob_bait/cb~z"
: > "$glob_bait/cx✗·z"
worker_out=$(cd "$glob_bait" && run_statusline "$(statusline_payload status-w-auto-glob)" main)
assert test "${worker_out#*"${MAGENTA}z"}" = "$worker_out"
assert test "${worker_out#*·FB}" = "$worker_out"
assert test "${worker_out#*·SL}" = "$worker_out"

# A fixed vendor switched off keeps saying so — a parked switch is not a walled account.
printf 'cx⏸off·sol·med cb⏸off·opus·hi gx⏸off·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
printf 'worker=claudeb\nclaudeb_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-off)")
assert grep -Fq "${DIM}⏸off${RESET}" <<< "$worker_out"
# A usable pin outranks the switch.
printf 'worker=claudeb\nclaudeb_effort=high\nclaudeb_profile=notcom\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-off-pin)")
assert grep -Fq "${MAGENTA}@notcom${RESET}${DIM}·OP·hi${RESET}" <<< "$worker_out"

# A prediction older than 10 minutes: worker-pick has stopped answering and the account it names is
# no longer evidence of anything.
printf 'cx✓alt·sol·med cb~notcom·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
pick_stale_stamp=$(date -v-15M +%Y%m%d%H%M.%S 2>/dev/null || date -d '15 minutes ago' +%Y%m%d%H%M.%S)
touch -t "$pick_stale_stamp" "$HOME/.cache/worker-pick.line.main"
printf 'worker=auto\nclaudeb_model=opus\nclaudeb_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-auto-stale)" main)
assert test "${worker_out#*notcom}" = "$worker_out"
rm -f "$HOME/.cache/worker-pick.line.main"

printf 'worker=frobnicate\ncodex_effort=high\ncodex_profile=alt\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-bad)")
assert test "${worker_out#*@alt}" = "$worker_out"

# grok reads its own knobs off the same file, and `gr` is its field of worker-pick's line.
printf 'cx✓alt·sol·med cb~notcom·opus·hi gx✓work·flash·med gr✓supergrok·grok-4.6·hi\n' \
  >"$HOME/.cache/worker-pick.line.main"
printf 'worker=grok\ngrok_model=grok-4.5\ngrok_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-grok)")
assert grep -Fq "${MAGENTA}supergrok${RESET}${DIM}·GR4.5·med${RESET}" <<< "$worker_out"

# `auto` is not a model id — it is "whatever the account defaults to" — so the segment names the
# effort alone rather than printing a version the CLI never promised.
printf 'worker=grok\ngrok_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-grok-auto)")
assert grep -Fq "${MAGENTA}supergrok${RESET}${DIM}·hi${RESET}" <<< "$worker_out"
assert test "${worker_out#*AT}" = "$worker_out"

printf 'worker=grok\ngrok_profile=pinnedgrok\ngrok_model=grok-4.6\ngrok_effort=xhigh\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-grok-pin)")
assert grep -Fq "${MAGENTA}@pinnedgrok${RESET}${DIM}·GR4.6·xhi${RESET}" <<< "$worker_out"

# grok is last in worker-pick's order: it answers in auto only once every vendor above it is out.
printf 'cx⏸off·sol·med cb⏸off·opus·hi gx⏸off·pro·hi gr✓supergrok·grok-4.6·hi\n' \
  >"$HOME/.cache/worker-pick.line.main"
printf 'worker=auto\ngrok_model=grok-4.6\ngrok_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-auto-gr)" main)
assert grep -Fq "${MAGENTA}supergrok${RESET}${DIM}·GR4.6·hi${RESET}" <<< "$worker_out"
printf 'cx⏸off·sol·med cb⏸off·opus·hi gx✓main·pro·hi gr✓supergrok·grok-4.6·hi\n' \
  >"$HOME/.cache/worker-pick.line.main"
printf 'worker=auto\ngemini_model=pro\ngemini_effort=high\ngrok_model=grok-4.6\ngrok_effort=high\n' \
  > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-auto-gr-order)" main)
assert grep -Fq "${MAGENTA}main${RESET}${DIM}·PR·hi${RESET}" <<< "$worker_out"
assert test "${worker_out#*supergrok}" = "$worker_out"

# The field is optional: a prediction written before grok existed renders exactly as it did.
printf 'cx✓alt·sol·med cb⏸off·opus·hi gx⏸off·pro·hi\n' >"$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-auto-nogr)" main)
assert grep -Fq "${MAGENTA}alt${RESET}${DIM}·SL·hi${RESET}" <<< "$worker_out"

# A role switched off is a parked switch, not a walled account, for grok as for everyone.
printf 'cx✓alt·sol·med cb~notcom·opus·hi gx✓work·flash·med gr⏸off·grok-4.6·hi\n' \
  >"$HOME/.cache/worker-pick.line.main"
printf 'worker=grok\ngrok_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-grok-off)")
assert grep -Fq "${DIM}⏸off${RESET}" <<< "$worker_out"
assert test "${worker_out#*supergrok}" = "$worker_out"
rm -f "$HOME/.cache/worker-pick.line.main"

# A live grok worker's tag wears the same short forms as every other vendor's.
printf 'worker=auto\n' > "$worker_file"
mkdir -p "$HOME/.cache/claude-worker-tags/status-w-grok-live"
printf 'supergrok · grok-4.6 · xhigh\n' > "$HOME/.cache/claude-worker-tags/status-w-grok-live/1"
worker_out=$(run_statusline "$(statusline_payload status-w-grok-live)")
assert grep -Fq "${MAGENTA}▶supergrok${RESET}${DIM}·GR4.6·xhi${RESET}" <<< "$worker_out"
rm -rf "$HOME/.cache/claude-worker-tags/status-w-grok-live"

# The live tag beats the config candidate and wears the same short forms.
printf 'worker=auto\n' > "$worker_file"
mkdir -p "$HOME/.cache/claude-worker-tags/status-w-live"
printf 'notcom · sonnet · xhigh\n' > "$HOME/.cache/claude-worker-tags/status-w-live/1"
worker_out=$(run_statusline "$(statusline_payload status-w-live)")
assert grep -Fq "${MAGENTA}▶notcom${RESET}${DIM}·SN·xhi${RESET}" <<< "$worker_out"
rm -rf "$HOME/.cache/claude-worker-tags/status-w-live"
rm -f "$worker_file"

# --- Progressive width fit ----------------------------------------------------------------
# Line 1 is built to $COLUMNS by shrinking segments in a fixed order; every step is exercised on
# one fixture whose full form overflows every width below.
FIT_REPO="$FIXTURES/fit-bench-project"
FIT_FOREIGN="$FIXTURES/other-side-repo"
mkdir -p "$FIT_REPO" "$FIT_FOREIGN"
for fit_repo_dir in "$FIT_REPO" "$FIT_FOREIGN"; do
  git -C "$fit_repo_dir" init -q -b WUT-421_fit_bench_branch
  printf 'one\n' > "$fit_repo_dir/tracked.txt"
  git -C "$fit_repo_dir" add tracked.txt
  git -C "$fit_repo_dir" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
done
FIT_MANY="$FIXTURES/a-b-c-d-e-f-g-h-i-j"
mkdir -p "$FIT_MANY"
git -C "$FIT_MANY" init -q -b main
printf 'one\n' > "$FIT_MANY/tracked.txt"
git -C "$FIT_MANY" add tracked.txt
git -C "$FIT_MANY" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
printf 'two\nthree\n' >> "$FIT_REPO/tracked.txt"
printf 'fresh\n' > "$FIT_REPO/untracked.txt"
FIT_TOP=$(git -C "$FIT_REPO" rev-parse --show-toplevel)
FIT_FOREIGN_TOP=$(git -C "$FIT_FOREIGN" rev-parse --show-toplevel)
printf 'worker=sonnet\nsonnet_effort=high\n' > "$worker_file"

fit_visible() {
  local s="${1%%$'\n'*}"
  s=${s//"$RESET"/}; s=${s//"$CYAN"/}; s=${s//"$BLUE"/}; s=${s//"$DIM"/}
  s=${s//"$GREEN"/}; s=${s//"$YELLOW"/}; s=${s//"$RED"/}; s=${s//"$MAGENTA"/}
  printf '%s' "$s"
}
fit_render() { # session cols [cwd] [account]
  local out
  out=$(FIT_COLUMNS="$2" run_statusline \
    "$(statusline_payload "$1" '{"model":{"display_name":"Fable 5"},"effort":{"level":"xhigh"}}' \
       "${3:-$FIT_REPO}")" "${4:-fitaccount}") || fail "fit render failed: $1 at $2"
  fit_visible "$out"
}

fit_full=$(fit_render fit-full "")
# Nothing shrinks with no width to shrink to.
assert grep -Fq 'Fable 5 xhigh' <<< "$fit_full"
assert grep -Fq 'fit-bench-project' <<< "$fit_full"
assert grep -Fq '⎇ WUT-421_fit_bench_branch' <<< "$fit_full"
assert grep -Fq '+3/-0' <<< "$fit_full"
assert grep -Fq '+1~1f' <<< "$fit_full"
assert grep -Fq 'fitaccount' <<< "$fit_full"
fit_full_len=${#fit_full}

# Every width the line is asked to fit into, it fits into — and the step order is what gives way.
fit_prev=$fit_full_len
for fit_cols in 200 120 100 90 80 70 60 40; do
  fit_line=$(fit_render "fit-w$fit_cols" "$fit_cols")
  asserts=$((asserts + 1))
  [ "${#fit_line}" -le "$fit_cols" ] || [ "$fit_cols" -ge "$fit_full_len" ] ||
    fail "fit width $fit_cols: ${#fit_line} cells: $fit_line"
  asserts=$((asserts + 1))
  [ "${#fit_line}" -le "$fit_prev" ] ||
    fail "fit width $fit_cols grew: ${#fit_line} > $fit_prev"
  fit_prev=${#fit_line}
done

# The full form is 91 cells wide, and each width below is the first one that needs the next step.
assert_eq 91 "$fit_full_len"

# Step 1 then 2: the files counter goes before the diff signs, and the slash survives both.
fit_step1=$(fit_render fit-step1 90)
assert test "${fit_step1#*~1f}" = "$fit_step1"
assert grep -Fq '+3/-0' <<< "$fit_step1"
fit_step2=$(fit_render fit-step2 84)
assert grep -Fq '3/0' <<< "$fit_step2"
assert test "${fit_step2#*+3}" = "$fit_step2"

# Step 3 then 4: the branch glyph goes, then the branch keeps its ticket prefix alone.
fit_step3=$(fit_render fit-step3 82)
assert test "${fit_step3#*⎇}" = "$fit_step3"
assert grep -Fq 'WUT-421_fit_bench_branch' <<< "$fit_step3"
fit_step4=$(fit_render fit-step4 79)
assert grep -Fq 'WUT-421' <<< "$fit_step4"
assert test "${fit_step4#*WUT-421_}" = "$fit_step4"

# Steps 5, 6, 8, 9 and 11: directory names to eight characters, then the head model abbreviated,
# then the directory to initials, then the worker segment, then the directory itself.
fit_step5=$(fit_render fit-step5 63)
assert grep -Fq 'fit-benc' <<< "$fit_step5"
assert grep -Fq 'Fable 5 xhigh' <<< "$fit_step5"
fit_step6=$(fit_render fit-step6 51)
assert grep -Fq 'FB5 xhi' <<< "$fit_step6"
assert grep -Fq 'fit-benc' <<< "$fit_step6"
fit_step8=$(fit_render fit-step8 47)
assert grep -Fq 'fbp' <<< "$fit_step8"
assert test "${fit_step8#*fit-benc}" = "$fit_step8"
fit_step9=$(fit_render fit-step9 42)
assert test "${fit_step9#*SN}" = "$fit_step9"
assert grep -Fq 'fbp' <<< "$fit_step9"
fit_step11=$(fit_render fit-step11 34)
assert test "${fit_step11#*fbp}" = "$fit_step11"
assert grep -Fq 'WUT-421' <<< "$fit_step11"

# Steps 10 and 11 on the `»` pair: the active side alone, then no directory at all. Both sides
# wear the initials form first, and the arrow loses its spaces with them.
printf '%s\n' "$FIT_FOREIGN_TOP" > "$STATE_DIR/workdir-fit-arrow"
fit_arrow=$(fit_render fit-arrow "")
assert grep -Fq 'fit-bench-project » other-side-repo' <<< "$fit_arrow"
assert_eq 97 "${#fit_arrow}"
printf '%s\n' "$FIT_FOREIGN_TOP" > "$STATE_DIR/workdir-fit-arrow-ini"
fit_arrow_ini=$(fit_render fit-arrow-ini 51)
assert grep -Fq 'fbp»osr' <<< "$fit_arrow_ini"
printf '%s\n' "$FIT_FOREIGN_TOP" > "$STATE_DIR/workdir-fit-arrow-active"
fit_arrow_active=$(fit_render fit-arrow-active 35)
assert grep -Fq 'osr' <<< "$fit_arrow_active"
assert test "${fit_arrow_active#*fbp}" = "$fit_arrow_active"

# The worktree label shrinks with the directory names it sits beside, but a ticket-named one stops
# at its ticket: `wut-25`, never `w2p`, and the parent dir goes to initials around it.
fit_wt=$(fit_render fit-wt "" "$REPO_J")
assert_eq 57 "${#fit_wt}"
assert grep -Fq "⧉ wut-25-portal" <<< "$fit_wt"
fit_wt_short=$(fit_render fit-wt-short 56 "$REPO_J")
assert grep -Fq "⧉ wut-25 " <<< "$fit_wt_short"
assert test "${fit_wt_short#*wut-25-}" = "$fit_wt_short"
fit_wt_ini=$(fit_render fit-wt-ini 42 "$REPO_J")
assert grep -Fq "rep ⧉ wut-25" <<< "$fit_wt_ini"
assert test "${fit_wt_ini#*w2p}" = "$fit_wt_ini"

# The digits are the identity, so neither the 8-character cut nor the initials step may touch them,
# and the separator of the match is printed as written.
fit_ticket=$(fit_render fit-ticket "" "$REPO_L")
assert grep -Fq "⧉ WUT-12345-fix-header" <<< "$fit_ticket"
fit_ticket_short=$(fit_render fit-ticket-short 60 "$REPO_L")
assert grep -Fq "⧉ WUT-12345 " <<< "$fit_ticket_short"
assert test "${fit_ticket_short#*WUT-1234 }" = "$fit_ticket_short"
fit_ticket_ini=$(fit_render fit-ticket-ini 42 "$REPO_L")
assert grep -Fq "rep ⧉ WUT-12345" <<< "$fit_ticket_ini"
fit_ticket_us=$(fit_render fit-ticket-us 50 "$REPO_M")
assert grep -Fq "⧉ WUT_12345 " <<< "$fit_ticket_us"
assert test "${fit_ticket_us#*WUT_1234 }" = "$fit_ticket_us"

# A worktree with no ticket in its name keeps the old ladder: 8 characters, then initials.
fit_wt_plain=$(fit_render fit-wt-plain 50 "$REPO_E")
assert grep -Fq "⧉ feature- " <<< "$fit_wt_plain"
fit_wt_plain_ini=$(fit_render fit-wt-plain-ini 44 "$REPO_E")
assert grep -Fq "⧉ fy" <<< "$fit_wt_plain_ini"

# Step 12: the account is cut from the right and never below four characters, and the line is left
# overflowing rather than losing anything the floor protects.
fit_floor=$(fit_render fit-floor 12)
assert grep -Fq 'fita' <<< "$fit_floor"
assert test "${fit_floor#*fitac}" = "$fit_floor"

# Initials longer than the 8-character cut would make step 8 GROW the line, and the directory
# would be dropped at a width its truncated form fits.
fit_many_full=$(fit_render fit-many "" "$FIT_MANY")
assert grep -Fq 'a-b-c-d-e-f-g-h-i-j' <<< "$fit_many_full"
for many_cols in 60 55 50 44 40 34; do
  many_line=$(fit_render "fit-many-$many_cols" "$many_cols" "$FIT_MANY")
  asserts=$((asserts + 1))
  [ "${many_line#*abcdefghij}" = "$many_line" ] ||
    fail "fit width $many_cols took the dir to longer initials: $many_line"
done
fit_many_cut=$(fit_render fit-many-cut 50 "$FIT_MANY")
assert grep -Fq 'a-b-c-d- main' <<< "$fit_many_cut"

# `⚡` is two terminal cells: measured as one, a line judged to fit exactly is one cell over, wraps
# and pushes line 2 out of view.
fast_render() { # session cols
  local out
  out=$(FIT_COLUMNS="$2" run_statusline \
    "$(statusline_payload "$1" \
       '{"model":{"display_name":"Fable 5"},"effort":{"level":"xhigh"},"fast_mode":true}' \
       "$FIT_REPO")" fitaccount) || fail "fast fit render failed: $1 at $2"
  fit_visible "$out"
}
fast_full=$(fast_render fit-fast "")
assert grep -Fq '⚡' <<< "$fast_full"
fast_edge=$(fast_render fit-fast-edge 88)
assert_eq 87 "${#fast_edge}"
fast_over=$(fast_render fit-fast-over 87)
assert test "${#fast_over}" -lt 87
for fast_cols in 90 80 70 60 50 40; do
  fast_line=$(fast_render "fit-fast-$fast_cols" "$fast_cols")
  asserts=$((asserts + 1))
  [ "$(( ${#fast_line} + 1 ))" -le "$fast_cols" ] ||
    fail "fast fit width $fast_cols: $(( ${#fast_line} + 1 )) cells: $fast_line"
  asserts=$((asserts + 1))
  grep -Fq '⚡' <<< "$fast_line" || fail "fast fit width $fast_cols lost ⚡: $fast_line"
done
rm -f "$worker_file"

NOW=$(date +%s)
bucket_json() {
  jq -cn --argjson now "$NOW" --argjson h5 "$1" --argjson wk "$2" --argjson h5_age "${3:-0}" '
    {five_hour:{used_percentage:$h5,resets_at:($now+3600),as_of:($now-$h5_age),origin:"headers"},
     seven_day:{used_percentage:$wk,resets_at:($now+86400),as_of:$now,origin:"session"},
     auth:{status:"ok",checked_at:$now}}'
}

bucket_json 33 11 > "$CLAUDEB_FIX/limits/acctfab.json"
bucket_json 44 22 > "$CLAUDEB_FIX/limits/acctgen.json"

fable_payload=$(statusline_payload status-explicit-fable '{"model":{"id":"claude-fable-5[1m]","display_name":"Fable"}}')
fable_out=$(run_statusline "$fable_payload" acctfab) || fail "statusline explicit fable failed"
assert grep -Fq 'acctfab' <<< "$fable_out"
assert test "${fable_out#*~acctfab}" = "$fable_out"
assert grep -Fq "${GREEN}33%" <<< "$fable_out"
assert grep -Fq "${GREEN}11%" <<< "$fable_out"

general_payload=$(statusline_payload status-explicit-gen \
  '{"model":{"id":"claude-sonnet-5","display_name":"Sonnet"}}')
general_out=$(run_statusline "$general_payload" acctgen) || fail "statusline explicit general failed"
assert grep -Fq 'acctgen' <<< "$general_out"
assert test "${general_out#*~acctgen}" = "$general_out"
assert grep -Fq "${GREEN}44%" <<< "$general_out"
assert_eq "$(bucket_json 44 22)" "$(cat "$CLAUDEB_FIX/limits/acctgen.json")"

# Every bucket renders through share/limits-view.sh (shared-invariants y), as the menubar does:
# an expired window shows its EFFECTIVE value (0%) dimmed, a placeholder reset below the epoch
# floor is neither expired nor a date, and a reset over a day past loses its date but not its
# verdict. The fable row is the collector's own effective_pct/stale/expired, never a re-derivation.
jq -cn --argjson now "$NOW" '
  {five_hour:{used_percentage:33,resets_at:($now-10),as_of:$now,origin:"headers"},
   seven_day:{used_percentage:11,resets_at:0,as_of:$now,origin:"session"},
   auth:{status:"ok",checked_at:$now}}' > "$CLAUDEB_FIX/limits/acctgen.json"
view_out=$(run_statusline "$(statusline_payload status-view-expired)" acctgen) \
  || fail "statusline shared-view render failed"
assert grep -Fq "5h ${DIM}0%${RESET}" <<< "$view_out"
assert_eq "" "${view_out##*wk ${GREEN}11%${RESET}}"
assert test "${view_out#*33%}" = "$view_out"
jq -cn --argjson now "$NOW" '
  {five_hour:{used_percentage:33,resets_at:($now-90000),as_of:$now,origin:"headers"},
   seven_day:{used_percentage:11,resets_at:($now+86400),as_of:$now,origin:"session"},
   auth:{status:"ok",checked_at:$now}}' > "$CLAUDEB_FIX/limits/acctgen.json"
view_ancient_out=$(run_statusline "$(statusline_payload status-view-ancient)" acctgen) \
  || fail "statusline shared-view ancient render failed"
assert grep -Fq "5h ${DIM}0%${RESET} ${DIM}│" <<< "$view_ancient_out"
jq -cn --argjson now "$NOW" '
  {vendors:{claude:{accounts:[{account:"acctgen",five_hour:{stale:false},weekly:{stale:false},
    fable:{used_pct:90,effective_pct:0,expired:true,stale:false,resets_at:null}}]}}}' \
  > "$WORK/limits.json"
view_fable_out=$(run_statusline "$(statusline_payload status-view-fable)" acctgen) \
  || fail "statusline shared-view fable render failed"
assert grep -Fq "fb ${DIM}0%${RESET}" <<< "$view_fable_out"
assert test "${view_fable_out#*90%}" = "$view_fable_out"
jq -cn '{vendors:{claude:{accounts:[{account:"acctgen",five_hour:{stale:false},weekly:{stale:false},
    fable:{used_pct:90,effective_pct:90,expired:false,stale:true,resets_at:null}}]}}}' \
  > "$WORK/limits.json"
view_fable_stale_out=$(run_statusline "$(statusline_payload status-view-fable-stale)" acctgen) \
  || fail "statusline shared-view stale fable render failed"
assert grep -Fq "fb ${DIM}90%${RESET}" <<< "$view_fable_stale_out"
# A fable reset over a day past loses its date but not its verdict — the menubar's `-`, spelled
# here as no date at all.
fable_ancient_iso=$(date -u -r $((NOW - 259200)) +%Y-%m-%dT%H:%M:%SZ)
jq -cn --arg reset "$fable_ancient_iso" '{vendors:{claude:{accounts:[{account:"acctgen",
    five_hour:{stale:false},weekly:{stale:false},
    fable:{used_pct:90,effective_pct:0,expired:true,stale:false,resets_at:$reset}}]}}}' \
  > "$WORK/limits.json"
view_fable_ancient_out=$(run_statusline "$(statusline_payload status-view-fable-ancient)" acctgen) \
  || fail "statusline ancient fable render failed"
assert_eq "" "${view_fable_ancient_out##*fb ${DIM}0%${RESET}}"
rm -f "$WORK/limits.json"
bucket_json 44 22 > "$CLAUDEB_FIX/limits/acctgen.json"

# A cached header-origin week is a number nobody measured (shared-invariants n): the render
# must show `?`, and a real reading must replace it even though newer() would otherwise keep
# the higher percentage for the rest of the weekly window.
jq -cn --argjson now "$NOW" '
  {five_hour:{used_percentage:7,resets_at:($now+3600),as_of:$now,origin:"headers"},
   seven_day:{used_percentage:100,resets_at:($now+86400),as_of:$now,origin:"headers"},
   auth:{status:"ok",checked_at:$now}}' > "$CLAUDEB_FIX/limits/acctgen.json"
synth_out=$(run_statusline "$(statusline_payload status-synth-week '{"model":{"id":"claude-sonnet-5","display_name":"Sonnet"}}')") \
  || fail "statusline synthetic-week render failed"
assert grep -Fq "wk ${DIM}?" <<< "$synth_out"
assert test "${synth_out#*100%}" = "$synth_out"
measured_payload=$(statusline_payload status-synth-week-merge \
  '{"model":{"id":"claude-sonnet-5","display_name":"Sonnet"},"rate_limits":{"five_hour":{"used_percentage":7,"resets_at":'"$((NOW + 3600))"'},"seven_day":{"used_percentage":76,"resets_at":'"$((NOW + 86400))"'}}}')
run_statusline "$measured_payload" acctgen >/dev/null || fail "statusline measured-week merge failed"
assert jq -e '.seven_day.used_percentage == 76 and .seven_day.origin == "session"' "$CLAUDEB_FIX/limits/acctgen.json" >/dev/null
bucket_json 44 22 > "$CLAUDEB_FIX/limits/acctgen.json"

# The unpinned claudeb candidate must come from the worker-pick cache, never from
# .claudeb-state (the last profile launched): the two are seeded to different accounts
# here so a regression back to the state file fails instead of silently going stale.
printf 'acctgen\n' > "$CLAUDEB_FIX/.claudeb-state"
printf 'cx✓alt·sol·med cb~acctpick·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
printf 'worker=claudeb\ncodex_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-pick '{"model":{"id":"claude-fable-5","display_name":"Fable"}}')" main)
assert grep -Fq "${MAGENTA}acctpick${RESET}${DIM}·OP·hi${RESET}" <<< "$worker_out"
assert test "${worker_out#*acctgen}" = "$worker_out"
assert test "${worker_out#*acctfab}" = "$worker_out"

# Profile names may hold underscores, dots and capitals (claudeb's own add rule), so the
# extractor must not be narrower than the names it can receive.
printf 'cx✓alt·sol·med cb~My_acct.2·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-oddname '{"model":{"id":"claude-fable-5","display_name":"Fable"}}')" main)
assert grep -Fq "${MAGENTA}My_acct.2${RESET}${DIM}·OP·hi${RESET}" <<< "$worker_out"

# No parsable cache → no candidate, never a stale account from the state file.
printf 'cx✓alt·sol·med gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-nocache '{"model":{"id":"claude-fable-5","display_name":"Fable"}}')" main)
assert test "${worker_out#*·OP}" = "$worker_out"
assert test "${worker_out#*acctgen}" = "$worker_out"
printf 'cx✓alt·sol·med cb~acctpick·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"

printf 'worker=codex\ncodex_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-pick)" main)
assert grep -Fq "${MAGENTA}alt${RESET}${DIM}·SL·med${RESET}" <<< "$worker_out"

# codexb only ever creates lowercase-and-hyphen names, so a line carrying anything else is a
# corrupt cache and must read as unknown rather than as a confident prediction.
printf 'cx✓My_acct.2·sol·med cb~acctpick·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-oddname)" main)
assert test "${worker_out#*·SL}" = "$worker_out"
assert test "${worker_out#*My_acct}" = "$worker_out"

printf 'cx✗·? cb~? gx✗?·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-nocache)" main)
assert test "${worker_out#*·SL}" = "$worker_out"

# A vendor switched off for workers is parked, not spent: it arrives in the cache as its own
# `⏸off` shape and must not render as a walled vendor Egor would go chasing limits over, nor as
# an account literally named `off`.
printf 'cx⏸off·sol·med cb⏸off·opus·hi gx⏸off·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-roleoff)" main)
assert grep -Fq "${DIM}⏸off${RESET}" <<< "$worker_out"
assert test "${worker_out#*off·}" = "$worker_out"
printf 'worker=claudeb\ncodex_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-roleoff)" main)
assert grep -Fq "${DIM}⏸off${RESET}" <<< "$worker_out"
printf 'worker=gemini\ngemini_model=pro\ngemini_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-gem-roleoff)" main)
assert grep -Fq "${DIM}⏸off${RESET}" <<< "$worker_out"
# The pin outranks the switch (routing-contract Roles), so a pinned vendor still names its account.
printf 'worker=claudeb\nclaudeb_profile=notcom\ncodex_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-roleoff-pin)" main)
assert grep -Fq "${MAGENTA}@notcom${RESET}${DIM}·OP·hi${RESET}" <<< "$worker_out"
# One vendor parked leaves the others predicted as usual.
printf 'cx✓alt·sol·med cb⏸off·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
printf 'worker=codex\ncodex_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-beside-roleoff)" main)
assert grep -Fq "${MAGENTA}alt${RESET}${DIM}·SL·med${RESET}" <<< "$worker_out"

printf 'worker=codex\ncodex_effort=medium\n' > "$worker_file"
printf 'cx✓alt·sol·med cb~acctpick·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
rm -f "$WORK/limits.json" "$worker_file"

cache_rl="$HOME/.claude/statusline-cache-rl"
bucket_json 42 7 > "$cache_rl"
fresh_out=$(run_statusline "$(statusline_payload status-rl-fresh)" main) || fail "statusline fresh cache failed"
assert grep -Fq "${GREEN}42%" <<< "$fresh_out"

bucket_json 48 8 3600 > "$cache_rl"
stale_out=$(run_statusline "$(statusline_payload status-rl-stale)" main) || fail "statusline stale cache failed"
assert grep -Fq "${DIM}48%" <<< "$stale_out"
assert grep -Fq "${GREEN}8%" <<< "$stale_out"

jq -cn --argjson now "$NOW" \
  '{five_hour:{used_percentage:55,resets_at:($now+3600)},seven_day:{used_percentage:9,resets_at:($now+86400)}}' > "$cache_rl"
legacy_out=$(run_statusline "$(statusline_payload status-rl-legacy)" main) || fail "statusline legacy cache failed"
assert grep -Fq "${YELLOW}55%" <<< "$legacy_out"
assert grep -Fq "${GREEN}9%" <<< "$legacy_out"

bucket_json 42 7 > "$cache_rl"
mkdir "$cache_rl.lock"
locked_payload=$(statusline_payload status-rl-locked \
  '{"rate_limits":{"five_hour":{"used_percentage":70,"resets_at":'"$((NOW + 3600))"'}}}')
locked_out=$(run_statusline "$locked_payload" main) || fail "statusline locked cache failed"
assert grep -Fq "${YELLOW}70%" <<< "$locked_out"
assert_eq "$(bucket_json 42 7)" "$(cat "$cache_rl")"
rmdir "$cache_rl.lock"
unlocked_out=$(run_statusline "$locked_payload" main) || fail "statusline unlocked cache failed"
assert grep -Fq "${YELLOW}70%" <<< "$unlocked_out"
assert jq -e '.five_hour.used_percentage == 70' "$cache_rl" >/dev/null
assert test ! -e "$cache_rl.lock"

jq -cn --argjson now "$NOW" \
  '{seven_day:{used_percentage:21,resets_at:($now+86400),as_of:$now,origin:"usage"},auth:{status:"ok",checked_at:$now}}' \
  > "$CLAUDEB_FIX/limits/pinacct.json"
backfill_payload=$(statusline_payload status-backfill \
  '{"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":'"$((NOW + 3600))"'}}}')
backfill_out=$(run_statusline "$backfill_payload" pinacct) || fail "statusline backfill failed"
assert grep -Fq "${YELLOW}63%" <<< "$backfill_out"
assert grep -Fq "${GREEN}21%" <<< "$backfill_out"
assert jq -e '.five_hour.used_percentage == 63 and .seven_day.used_percentage == 21' \
  "$CLAUDEB_FIX/limits/pinacct.json" >/dev/null

# A session running ON the account is affirmative login evidence: the merge that accepts it
# must clear auth_needed, or every automated refresh keeps skipping the account as dead.
jq -cn --argjson now "$NOW" \
  '{five_hour:{used_percentage:10,resets_at:($now+3600),as_of:($now-600),origin:"usage"},
    auth_needed:true,auth_cause:"needs-relogin",auth_checked_at:($now-600)}' \
  > "$CLAUDEB_FIX/limits/reviveacct.json"
relogin_payload=$(statusline_payload status-relogin \
  '{"rate_limits":{"five_hour":{"used_percentage":44,"resets_at":'"$((NOW + 7200))"'}}}')
relogin_out=$(run_statusline "$relogin_payload" reviveacct) || fail "statusline relogin merge failed"
assert grep -Fq "${GREEN}44%" <<< "$relogin_out"
assert jq -e '.five_hour.used_percentage == 44 and .auth.status == "ok" and
  (has("auth_needed") or has("auth_cause") or has("auth_checked_at") | not)' \
  "$CLAUDEB_FIX/limits/reviveacct.json" >/dev/null

# An idle session replays its last readings forever: a window that opened BEFORE the account was
# marked logged out is that replay, and must not overwrite the verdict with old news.
jq -cn --argjson now "$NOW" \
  '{five_hour:{used_percentage:10,resets_at:($now-7200),as_of:($now-90000),origin:"usage"},
    auth_needed:true,auth_cause:"needs-relogin",auth_checked_at:($now-600)}' \
  > "$CLAUDEB_FIX/limits/replayacct.json"
replay_payload=$(statusline_payload status-replay \
  '{"rate_limits":{"five_hour":{"used_percentage":51,"resets_at":'"$((NOW - 3600))"'}}}')
run_statusline "$replay_payload" replayacct >/dev/null || fail "statusline replay merge failed"
assert jq -e '.five_hour.used_percentage == 51 and .auth_needed == true and
  .auth_cause == "needs-relogin"' "$CLAUDEB_FIX/limits/replayacct.json" >/dev/null

# A window that sits at the same percentage for hours is not stale data while the chat is
# working: spend since the last accepted merge is the liveness signal, and without it the row
# dims mid-session. The marker is per session because the cache is per account.
live_rl='{"five_hour":{"used_percentage":30,"resets_at":'"$((NOW + 3600))"'},"seven_day":{"used_percentage":60,"resets_at":'"$((NOW + 86400))"'}}'
seed_live_cache() {
  jq -cn --argjson now "$NOW" '
    {five_hour:{used_percentage:30,resets_at:($now+3600),as_of:($now-5000),origin:"session"},
     seven_day:{used_percentage:60,resets_at:($now+86400),as_of:($now-5000),origin:"session"},
     auth:{status:"ok",checked_at:$now}}' > "$CLAUDEB_FIX/limits/liveacct.json"
}
# The first render of a session has no remembered spend, so there is nothing the current cost
# can have grown from: an unmoved reading then is an idle replay like any other.
seed_live_cache
run_statusline "$(statusline_payload status-first "{\"cost\":{\"total_cost_usd\":1.5},\"rate_limits\":$live_rl}")" liveacct \
  >/dev/null || fail "statusline first-render merge failed"
assert jq -e --argjson now "$NOW" '.five_hour.as_of == ($now - 5000) and .seven_day.as_of == ($now - 5000)' \
  "$CLAUDEB_FIX/limits/liveacct.json" >/dev/null
assert test ! -e "$STATE_DIR/rl-cost-status-first"

# A merge accepted on its own merits (a higher reading) is what seeds the remembered spend.
jq -cn --argjson now "$NOW" '
  {five_hour:{used_percentage:29,resets_at:($now+3600),as_of:($now-5000),origin:"session"},
   seven_day:{used_percentage:59,resets_at:($now+86400),as_of:($now-5000),origin:"session"},
   auth:{status:"ok",checked_at:$now}}' > "$CLAUDEB_FIX/limits/liveacct.json"
run_statusline "$(statusline_payload status-live "{\"cost\":{\"total_cost_usd\":1.5},\"rate_limits\":$live_rl}")" liveacct \
  >/dev/null || fail "statusline live-merge seeding failed"
assert_eq "1.5" "$(cat "$STATE_DIR/rl-cost-status-live")"

# Same reading, same spend: the session sent nothing, so this IS the idle replay and the
# timestamps must stand where they were.
seed_live_cache
run_statusline "$(statusline_payload status-live "{\"cost\":{\"total_cost_usd\":1.5},\"rate_limits\":$live_rl}")" liveacct \
  >/dev/null || fail "statusline idle-cost merge failed"
assert jq -e --argjson now "$NOW" '.five_hour.as_of == ($now - 5000) and .seven_day.as_of == ($now - 5000)' \
  "$CLAUDEB_FIX/limits/liveacct.json" >/dev/null

# Same reading, more spend: both windows are re-stamped as measured now.
run_statusline "$(statusline_payload status-live "{\"cost\":{\"total_cost_usd\":2.25},\"rate_limits\":$live_rl}")" liveacct \
  >/dev/null || fail "statusline live-cost merge failed"
assert jq -e --argjson floor "$NOW" '.five_hour.as_of >= $floor and .seven_day.as_of >= $floor and
  .five_hour.used_percentage == 30 and .seven_day.used_percentage == 60 and
  .five_hour.origin == "session" and .seven_day.origin == "session"' \
  "$CLAUDEB_FIX/limits/liveacct.json" >/dev/null
assert_eq "2.25" "$(cat "$STATE_DIR/rl-cost-status-live")"

# A re-stamp is not login evidence: clearing the flag takes a five-hour window the merge
# accepted as NEWER, so an unmoved window re-stamped for liveness leaves the verdict standing
# even though it opened after it.
jq -cn --argjson now "$NOW" \
  '{five_hour:{used_percentage:30,resets_at:($now+3600),as_of:($now-5000),origin:"session"},
    auth_needed:true,auth_cause:"needs-relogin",auth_checked_at:($now-600)}' \
  > "$CLAUDEB_FIX/limits/liveauthacct.json"
# Seed the remembered spend through the weekly window alone: only a five-hour window accepted
# as newer speaks for the credentials, and this case is about what a re-stamp may NOT clear.
run_statusline "$(statusline_payload status-live-auth "{\"cost\":{\"total_cost_usd\":0.2},\"rate_limits\":{\"seven_day\":{\"used_percentage\":60,\"resets_at\":$((NOW + 86400))}}}")" liveauthacct \
  >/dev/null || fail "statusline live-auth seeding failed"
assert_eq "0.2" "$(cat "$STATE_DIR/rl-cost-status-live-auth")"
run_statusline "$(statusline_payload status-live-auth "{\"cost\":{\"total_cost_usd\":0.5},\"rate_limits\":$live_rl}")" liveauthacct \
  >/dev/null || fail "statusline live-auth merge failed"
assert jq -e --argjson floor "$NOW" '.five_hour.as_of >= $floor and .auth_needed == true and
  .auth_cause == "needs-relogin" and (has("auth") | not)' \
  "$CLAUDEB_FIX/limits/liveauthacct.json" >/dev/null

cost_payload=$(statusline_payload status-cost '{"cost":{"total_cost_usd":18.2007}}')
cost_out=$(printf '%s' "$cost_payload" | env -u LANG LC_ALL=ru_RU.UTF-8 \
  CLAUDE_LIMITS_ACCOUNT=main CLAUDEB_DIR="$CLAUDEB_FIX" LLM_LIMITS_FILE="$WORK/limits.json" \
  "$STATUSLINE" 2>"$WORK/cost-stderr") || fail "statusline cost locale failed"
assert grep -Fq '$18.20' <<< "$cost_out"
assert_eq "" "$(cat "$WORK/cost-stderr")"

# --- ctx color (% colored by pct: green <40, yellow 40–79, red ≥80; token count cold cache) ---
CTX_TRUTH_TRANSCRIPT="$WORK/ctx-truth.jsonl"
printf '{"type":"assistant","timestamp":"%s","uuid":"ctx-truth","message":{"role":"assistant","model":"fixmodel","usage":{"cache_read_input_tokens":1000,"cache_creation_input_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":1,"ephemeral_5m_input_tokens":0}}}}\n' \
  "$(TZ=UTC date -r $((NOW - 4000)) +%Y-%m-%dT%H:%M:%S.000Z)" > "$CTX_TRUTH_TRANSCRIPT"
ctx_case() {
  statusline_payload "$1" "$(jq -cn --arg tp "$CTX_TRUTH_TRANSCRIPT" --argjson pct "$2" --argjson tokens "$3" \
    '{transcript_path:$tp,model:{id:"fixmodel"},context_window:{used_percentage:$pct,current_usage:{input_tokens:$tokens}}}')"
}
ctx_lo=$(run_statusline "$(ctx_case ctx-lo 39 50000)")
assert grep -Fq "ctx ${GREEN}39%${RESET}" <<< "$ctx_lo"
assert grep -Fq "${DIM}50k${RESET}" <<< "$ctx_lo"
ctx_warn=$(run_statusline "$(ctx_case ctx-warn 40 120000)")
assert grep -Fq "ctx ${YELLOW}40%${RESET}" <<< "$ctx_warn"
assert grep -Fq "${YELLOW}120k${RESET}" <<< "$ctx_warn"
ctx_red=$(run_statusline "$(ctx_case ctx-red 80 180000)")
assert grep -Fq "ctx ${RED}80%${RESET}" <<< "$ctx_red"
assert grep -Fq "${YELLOW}180k${RESET}" <<< "$ctx_red"

# With window size present the % is computed from raw usage: the harness's
# used_percentage says 100 on a 1m session at 248k — render must show 25%.
ctx_1m=$(run_statusline "$(statusline_payload ctx-1m \
  "$(jq -cn --arg tp "$CTX_TRUTH_TRANSCRIPT" \
    '{transcript_path:$tp,model:{id:"fixmodel"},context_window:{used_percentage:100,context_window_size:1000000,current_usage:{input_tokens:248000}}}')")")
assert grep -Fq "ctx ${GREEN}25%${RESET}" <<< "$ctx_1m"
assert grep -Fq "${YELLOW}248k${RESET}" <<< "$ctx_1m"
ctx_200k=$(run_statusline "$(statusline_payload ctx-200k \
  "$(jq -cn --arg tp "$CTX_TRUTH_TRANSCRIPT" \
    '{transcript_path:$tp,model:{id:"fixmodel"},context_window:{used_percentage:10,context_window_size:200000,current_usage:{input_tokens:180000}}}')")")
assert grep -Fq "ctx ${RED}90%${RESET}" <<< "$ctx_200k"

# Warmth anchors on completed responses: non-sidechain, non-<synthetic>
# assistant entries (timestamp + message.model + message.usage). Fixture
# renders use the explicit acctgen fixture.
# cr = the cache_read tokens (input_tokens forced to 0 so ctx_tokens == cr).
warm_extra() {
  jq -cn --arg tp "$1" --argjson pct "$2" --argjson cr "$3" '
    {transcript_path:$tp, model:{id:"fixmodel"},
     context_window:{used_percentage:$pct,
       current_usage:{input_tokens:0,cache_creation_input_tokens:0,cache_read_input_tokens:$cr}}}'
}
TRANSCRIPT="$WORK/transcript.jsonl"
iso_utc() { TZ=UTC date -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
t_user() { printf '{"type":"user","timestamp":"%s","message":{"role":"user"}}\n' "$(iso_utc "$1")" >> "$TRANSCRIPT"; }
t_assist() {
  local ts="$1" m="${2:-fixmodel}" cr="${3:-50000}" cc="${4:-500}" bk="${5:-1h}"
  local uuid="${6:-a-$ts-$m-$cr-$cc-$bk}" b=""
  case "$bk" in
    5m) b=',"cache_creation":{"ephemeral_5m_input_tokens":'"$cc"',"ephemeral_1h_input_tokens":0}' ;;
    1h) b=',"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":'"$cc"'}' ;;
    mixed) b=',"cache_creation":{"ephemeral_5m_input_tokens":1,"ephemeral_1h_input_tokens":'"$cc"'}' ;;
  esac
  printf '{"type":"assistant","timestamp":"%s","uuid":"%s","message":{"role":"assistant","model":"%s","usage":{"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s%s}}}\n' \
    "$(iso_utc "$ts")" "$uuid" "$m" "$cr" "$cc" "$b" >> "$TRANSCRIPT"
  LAST_ASSIST_TS="$ts"; LAST_ASSIST_MODEL="$m"; LAST_ASSIST_UUID="$uuid"
  case "$bk" in 5m|mixed) LAST_ASSIST_TTL=300 ;; 1h) LAST_ASSIST_TTL=3600 ;; *) LAST_ASSIST_TTL=0 ;; esac
}
t_boundary() { printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s"}\n' "$(iso_utc "$1")" >> "$TRANSCRIPT"; }
t_reset() { : > "$TRANSCRIPT"; rm -f "$STATE_DIR"/cache-ttl-track-*; }
t_stamp() {
  printf 'v2 %s acctgen 0 %s %s %s 262144 %s acctgen\n' \
    "$LAST_ASSIST_TS" "$LAST_ASSIST_TTL" "$LAST_ASSIST_MODEL" "$LAST_ASSIST_UUID" \
    "$LAST_ASSIST_TS" > "$STATE_DIR/cache-ttl-track-$1"
}
RUN_STATUSLINE_DEFAULT_ACCOUNT=acctgen

t_reset; t_assist $((NOW - 20)); t_stamp ctx-warm-lo
warm_a=$(run_statusline "$(statusline_payload ctx-warm-lo "$(warm_extra "$TRANSCRIPT" 20 50000)")")
a_death=$(TZ=Europe/Kyiv date -r $((NOW - 20 + 3600)) +%H:%M)
assert grep -Fq "ctx ${GREEN}20%${RESET} ${DIM}→${a_death}${RESET}" <<< "$warm_a"
assert test "${warm_a#*50k}" = "$warm_a"
assert grep -q '^v2 [0-9]* acctgen ' "$STATE_DIR/cache-ttl-track-ctx-warm-lo"

payload_zero_extra=$(jq -cn --arg tp "$TRANSCRIPT" '
  {transcript_path:$tp,model:{id:"fixmodel"},
   context_window:{used_percentage:20,current_usage:{input_tokens:50000}}}')
t_stamp ctx-payload-zero
payload_zero=$(run_statusline "$(statusline_payload ctx-payload-zero "$payload_zero_extra")")
assert grep -Fq "${DIM}→${a_death}${RESET}" <<< "$payload_zero"

t_stamp ctx-warm-hi
warm_b=$(run_statusline "$(statusline_payload ctx-warm-hi "$(warm_extra "$TRANSCRIPT" 60 350000)")")
assert grep -Fq "ctx ${YELLOW}60%${RESET} ${DIM}→" <<< "$warm_b"
assert test "${warm_b#*350k}" = "$warm_b"

# Response older than the TTL -> cold (dim: 50k < 90k), no death time.
t_reset; t_assist $((NOW - 4000))
warm_c=$(run_statusline "$(statusline_payload ctx-stale "$(warm_extra "$TRANSCRIPT" 20 50000)")")
assert grep -Fq "${DIM}50k${RESET}" <<< "$warm_c"
assert test "${warm_c#*→}" = "$warm_c"

# Reopened dead chat: --resume touches the file (fresh mtime + a freshly
# timestamped file-history-snapshot) before any request — must stay COLD.
t_reset; t_user $((NOW - 172800)); t_assist $((NOW - 172799))
printf '{"type":"file-history-snapshot","timestamp":"%s"}\n' "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
resume_lie=$(run_statusline "$(statusline_payload ctx-resume-lie "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$resume_lie"
assert test 0 -eq "$(grep -c '→' <<< "$resume_lie")"

# Fresh real response wins over an older mtime (entries are the source of truth).
t_reset; t_user $((NOW - 65)); t_assist $((NOW - 60)); t_stamp ctx-ts-warm
touch -t "$(date -r $((NOW - 4000)) +%Y%m%d%H%M.%S)" "$TRANSCRIPT"
ts_warm=$(run_statusline "$(statusline_payload ctx-ts-warm "$(warm_extra "$TRANSCRIPT" 20 50000)")")
ts_death=$(TZ=Europe/Kyiv date -r $((NOW - 60 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${ts_death}${RESET}" <<< "$ts_warm"

# A partially written final entry must not hide the preceding completed response.
t_reset; t_assist $((NOW - 20)); t_stamp ctx-streaming
printf '{"type":"assistant","timestamp":"' >> "$TRANSCRIPT"
streaming_out=$(run_statusline "$(statusline_payload ctx-streaming "$(warm_extra "$TRANSCRIPT" 20 50000)")")
streaming_death=$(TZ=Europe/Kyiv date -r $((NOW - 20 + 3600)) +%H:%M)
assert grep -Fq "ctx ${GREEN}20%${RESET} ${DIM}→${streaming_death}${RESET}" <<< "$streaming_out"

printf '\n{"type":"system","subtype":"local_command","timestamp":"%s"}\n' "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
shell_only=$(run_statusline "$(statusline_payload ctx-streaming "$(warm_extra "$TRANSCRIPT" 20 50000)")")
assert grep -Fq "${DIM}→${streaming_death}${RESET}" <<< "$shell_only"

t_reset; t_assist $((NOW - 20)); t_stamp ctx-tool-tail
printf '{"type":"tool-result","timestamp":"%s","content":"' "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
head -c 350000 /dev/zero | tr '\0' x >> "$TRANSCRIPT"
printf '"}\n' >> "$TRANSCRIPT"
tool_tail=$(run_statusline "$(statusline_payload ctx-tool-tail "$(warm_extra "$TRANSCRIPT" 20 50000)")")
tool_tail_death=$(TZ=Europe/Kyiv date -r $((NOW - 20 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${tool_tail_death}${RESET}" <<< "$tool_tail"

# Sidechain (subagent) entries hit different cache prefixes — not this chat's warmth.
t_reset; t_user $((NOW - 172800))
printf '{"type":"assistant","isSidechain":true,"timestamp":"%s","message":{"role":"assistant","model":"fixmodel","usage":{"cache_read_input_tokens":50000}}}\n' "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
side_cold=$(run_statusline "$(statusline_payload ctx-sidechain "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${YELLOW}111k${RESET}" <<< "$side_cold"
assert test "${side_cold#*→}" = "$side_cold"

# <synthetic> assistant entries (API-error placeholders) are not responses.
t_reset; t_assist $((NOW - 172799)); t_assist "$NOW" '<synthetic>' 0 0
synth_cold=$(run_statusline "$(statusline_payload ctx-synth "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$synth_cold"

t_reset; t_assist $((NOW - 20)); t_stamp ctx-zero-error
printf '{"type":"assistant","timestamp":"%s","uuid":"zero-error","message":{"role":"assistant","model":"fixmodel","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}\n' \
  "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
zero_error=$(run_statusline "$(statusline_payload ctx-zero-error "$(warm_extra "$TRANSCRIPT" 20 50000)")")
zero_error_death=$(TZ=Europe/Kyiv date -r $((NOW - 20 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${zero_error_death}${RESET}" <<< "$zero_error"

# --- account switch invalidates the cache (per-organization on Anthropic) ---
t_reset; t_assist $((NOW - 600))
printf 'v2 %s alona 0\n' "$((NOW - 600))" > "$STATE_DIR/cache-ttl-track-ctx-swacct"
sw_out=$(run_statusline "$(statusline_payload ctx-swacct "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$sw_out"
# A NEW response under the current account re-warms and re-stamps it.
t_assist $((NOW - 5))
sw2_out=$(run_statusline "$(statusline_payload ctx-swacct "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}→" <<< "$sw2_out"
assert test "${sw2_out#*111k}" = "$sw2_out"
assert grep -q '^v2 [0-9]* acctgen ' "$STATE_DIR/cache-ttl-track-ctx-swacct"

t_reset; t_assist $((NOW - 600))
noattr_out=$(run_statusline "$(statusline_payload ctx-noattr "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$noattr_out"
assert test "${noattr_out#*→}" = "$noattr_out"
assert grep -q '^v2 [0-9]* ? 0' "$STATE_DIR/cache-ttl-track-ctx-noattr"

t_reset; t_assist $((NOW - 600))
printf 'pidsame %s alona\n' "$((NOW - 600))" > "$STATE_DIR/cache-ttl-track-ctx-legacy"
legacy_out=$(run_statusline "$(statusline_payload ctx-legacy "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$legacy_out"
assert test "${legacy_out#*→}" = "$legacy_out"
assert grep -q '^v2 [0-9]* ? ' "$STATE_DIR/cache-ttl-track-ctx-legacy"

t_reset; t_assist $((NOW - 5))
fresh_noattr=$(run_statusline "$(statusline_payload ctx-fresh-noattr "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$fresh_noattr"
assert test "${fresh_noattr#*→}" = "$fresh_noattr"
assert grep -q '^v2 [0-9]* ? ' "$STATE_DIR/cache-ttl-track-ctx-fresh-noattr"

t_reset; t_assist $((NOW - 5))
printf 'pidsame %s alona\n' "$((NOW - 5))" > "$STATE_DIR/cache-ttl-track-ctx-fresh-legacy"
fresh_legacy=$(run_statusline "$(statusline_payload ctx-fresh-legacy "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$fresh_legacy"
assert test "${fresh_legacy#*→}" = "$fresh_legacy"
assert grep -q '^v2 [0-9]* ? ' "$STATE_DIR/cache-ttl-track-ctx-fresh-legacy"

# --- a 1M-context session still matches its bare transcript model id ---
t_reset; t_assist $((NOW - 20)); t_stamp ctx-model-1m
onem_extra=$(warm_extra "$TRANSCRIPT" 55 111000 | jq -c '.model.id = "fixmodel[1m]"')
onem_out=$(run_statusline "$(statusline_payload ctx-model-1m "$onem_extra")")
onem_death=$(TZ=Europe/Kyiv date -r $((NOW - 20 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${onem_death}${RESET}" <<< "$onem_out"
assert test "${onem_out#*111k}" = "$onem_out"
onem_other=$(warm_extra "$TRANSCRIPT" 55 111000 | jq -c '.model.id = "othermodel[1m]"')
onem_cold=$(run_statusline "$(statusline_payload ctx-model-1m "$onem_other")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$onem_cold"
# Only a trailing bracketed suffix is a context-window marker: a bracket mid-id
# stays part of the name, so it must not be truncated into a false match.
onem_mid=$(warm_extra "$TRANSCRIPT" 55 111000 | jq -c '.model.id = "fixmodel[1m]-east"')
onem_mid_out=$(run_statusline "$(statusline_payload ctx-model-1m "$onem_mid")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$onem_mid_out"

# --- model switch invalidates the cache (per-model on Anthropic) ---
t_reset; t_assist $((NOW - 20)); t_stamp ctx-model-sw
model_extra=$(warm_extra "$TRANSCRIPT" 55 111000 | jq -c '.model.id = "othermodel"')
model_cold=$(run_statusline "$(statusline_payload ctx-model-sw "$model_extra")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$model_cold"
# Switching back to the model that built the cache re-warms (cache still alive).
model_warm=$(run_statusline "$(statusline_payload ctx-model-sw "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}→" <<< "$model_warm"

t_reset; t_assist $((NOW - 60)) fixmodel
fix_uuid="$LAST_ASSIST_UUID"
t_assist $((NOW - 30)) othermodel
t_stamp ctx-model-current
printf 'v1 %s acctgen 3600 %s 262144\n' "$((NOW - 60))" "$fix_uuid" \
  > "$STATE_DIR/cache-ttl-track-ctx-model-current.model-fixmodel"
current_fix=$(run_statusline "$(statusline_payload ctx-model-current "$(warm_extra "$TRANSCRIPT" 55 111000)")")
fix_death=$(TZ=Europe/Kyiv date -r $((NOW - 60 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${fix_death}${RESET}" <<< "$current_fix"
current_other_extra=$(warm_extra "$TRANSCRIPT" 55 111000 | jq -c '.model.id = "othermodel"')
current_other=$(run_statusline "$(statusline_payload ctx-model-current "$current_other_extra")")
other_death=$(TZ=Europe/Kyiv date -r $((NOW - 30 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${other_death}${RESET}" <<< "$current_other"
current_fix_again=$(run_statusline "$(statusline_payload ctx-model-current "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}→${fix_death}${RESET}" <<< "$current_fix_again"

noid_extra=$(warm_extra "$TRANSCRIPT" 20 50000 | jq -c 'del(.model)')
noid_out=$(run_statusline "$(statusline_payload ctx-model-noid "$noid_extra")")
assert grep -Fq "${DIM}? 50k${RESET}" <<< "$noid_out"
assert test "${noid_out#*→}" = "$noid_out"

# --- /compact kills the cache until the next response ---
t_reset; t_assist $((NOW - 60)); t_boundary $((NOW - 30))
# Its injected summary (user, isCompactSummary) and unmarked continuation user
# entry must not count as warmth.
printf '{"type":"user","isCompactSummary":true,"timestamp":"%s","message":{"role":"user"}}\n' "$(iso_utc $((NOW - 29)))" >> "$TRANSCRIPT"
t_user $((NOW - 28))
compact_cold=$(run_statusline "$(statusline_payload ctx-compact "$(warm_extra "$TRANSCRIPT" 55 111000)")")
# The payload still reports the pre-compact usage until the next request lands,
# so the context reads empty, not 111k.
assert grep -Fq "ctx ${DIM}0%${RESET} ${DIM}0k${RESET}" <<< "$compact_cold"
assert test "${compact_cold#*→}" = "$compact_cold"
# The first response after the boundary re-warms.
t_assist $((NOW - 5))
compact_warm=$(run_statusline "$(statusline_payload ctx-compact "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}→" <<< "$compact_warm"
compact_current=$(run_statusline "$(statusline_payload ctx-compact-current \
  "$(jq -cn --arg tp "$TRANSCRIPT" \
    '{transcript_path:$tp,context_window:{used_percentage:55,current_usage:{input_tokens:111000}}}')")")
# The post-boundary response sizes the new context; the payload's stale 111k loses.
assert grep -Fq "ctx ${DIM}?${RESET} ${DIM}? 51k${RESET}" <<< "$compact_current"

# An assistant entry written before the boundary line is pre-compact whatever its
# timestamp says, so the boundary still clears it.
t_reset; t_assist $((NOW - 30)); t_boundary $((NOW - 30))
compact_equal=$(run_statusline "$(statusline_payload ctx-compact-equal "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}0%${RESET} ${DIM}0k${RESET}" <<< "$compact_equal"
assert test "${compact_equal#*→}" = "$compact_equal"

# /branch re-emits pre-compact entries after the boundary: they keep their old
# timestamps AND their old usage totals, so they must not resurrect the old size.
t_reset; t_boundary $((NOW - 30))
printf '{"type":"assistant","timestamp":"%s","uuid":"reemit-old","message":{"role":"assistant","model":"fixmodel","usage":{"input_tokens":5,"cache_read_input_tokens":250000,"cache_creation_input_tokens":9000,"cache_creation":{"ephemeral_1h_input_tokens":9000,"ephemeral_5m_input_tokens":0}}}}\n' \
  "$(iso_utc $((NOW - 600)))" >> "$TRANSCRIPT"
branch_reemit=$(run_statusline "$(statusline_payload ctx-branch-reemit "$(warm_extra "$TRANSCRIPT" 87 260000)")")
assert grep -Fq "ctx ${DIM}0%${RESET} ${DIM}0k${RESET}" <<< "$branch_reemit"
# The first real response of the branched context sizes it.
t_assist $((NOW - 5))
branch_fresh=$(run_statusline "$(statusline_payload ctx-branch-fresh "$(warm_extra "$TRANSCRIPT" 87 260000)")")
# No context_window_size in this payload, so the discarded percentage cannot be
# recomputed and must not survive next to the corrected token count.
assert grep -Fq "ctx ${DIM}?${RESET} ${DIM}? 51k${RESET}" <<< "$branch_fresh"

# A re-emitted OLDER boundary trails the newest one; taking it as the cutoff would
# move the reset back into the past and re-admit the entries it invalidated.
t_reset; t_boundary $((NOW - 600)); t_assist $((NOW - 300)); t_boundary $((NOW - 900))
old_boundary=$(run_statusline "$(statusline_payload ctx-boundary-order "$(warm_extra "$TRANSCRIPT" 87 260000)")")
assert grep -Fq "${DIM}? 51k${RESET}" <<< "$old_boundary"

# The context-nudge hook needs the window size the render alone receives; it is
# published per session and rewritten only when it changes.
window_file="$HOME/.cache/claude-context-nudge/ctx-window.window"
window_extra=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:$tp,context_window:{context_window_size:200000,used_percentage:10,current_usage:{input_tokens:20000}}}')
run_statusline "$(statusline_payload ctx-window "$window_extra")" > /dev/null
assert_eq "200000" "$(cat "$window_file" 2>/dev/null)"
touch -t 202001010000 "$window_file"
run_statusline "$(statusline_payload ctx-window "$window_extra")" > /dev/null
assert_eq "2020" "$(date -r "$window_file" +%Y)"
window_1m=$(jq -c '.context_window.context_window_size = 1000000' <<< "$window_extra")
run_statusline "$(statusline_payload ctx-window "$window_1m")" > /dev/null
assert_eq "1000000" "$(cat "$window_file" 2>/dev/null)"

# --- the .bnd sidecar: boundary knowledge that outlives the scan window ---
NUDGE_DIR="$HOME/.cache/claude-context-nudge"
bnd_file() { printf '%s/%s.bnd' "$NUDGE_DIR" "$1"; }

t_reset; t_boundary $((NOW - 600)); t_assist $((NOW - 5))
run_statusline "$(statusline_payload ctx-bnd-new "$(warm_extra "$TRANSCRIPT" 55 111000)")" >/dev/null
bnd_new=$(cat "$(bnd_file ctx-bnd-new)")
assert_eq "$(stat -f %z "$TRANSCRIPT") $(iso_utc $((NOW - 600)))" "$bnd_new"
# A later boundary raises the remembered one; the scanned size follows the file.
t_boundary $((NOW - 400)); t_assist $((NOW - 3))
run_statusline "$(statusline_payload ctx-bnd-new "$(warm_extra "$TRANSCRIPT" 55 111000)")" >/dev/null
assert_eq "$(stat -f %z "$TRANSCRIPT") $(iso_utc $((NOW - 400)))" "$(cat "$(bnd_file ctx-bnd-new)")"
# A garbled sidecar must not be trusted and must not be permanent: the next render
# rescans the whole transcript and rewrites it.
printf 'not-a-size ??\n' > "$(bnd_file ctx-bnd-new)"
run_statusline "$(statusline_payload ctx-bnd-new "$(warm_extra "$TRANSCRIPT" 55 111000)")" >/dev/null
assert_eq "$(stat -f %z "$TRANSCRIPT") $(iso_utc $((NOW - 400)))" "$(cat "$(bnd_file ctx-bnd-new)")"
# A transcript with no boundary at all records the absence, not a stray timestamp.
t_reset; t_assist $((NOW - 5))
run_statusline "$(statusline_payload ctx-bnd-none "$(warm_extra "$TRANSCRIPT" 55 111000)")" >/dev/null
assert_eq "$(stat -f %z "$TRANSCRIPT") -" "$(cat "$(bnd_file ctx-bnd-none)")"

# The bug the sidecar exists for: /branch re-emits so much that the boundary falls
# out of the initial 262144-byte window, the scan stops at the first re-emitted
# current-model response, and the stale pre-compact payload survives untouched.
t_reset; t_boundary $((NOW - 600))
awk -v ts="$(iso_utc $((NOW - 900)))" 'BEGIN{
  for (i = 0; i < 900; i++)
    printf "{\"type\":\"assistant\",\"timestamp\":\"%s\",\"uuid\":\"reemit-%04d\",\"message\":{\"role\":\"assistant\",\"model\":\"fixmodel\",\"usage\":{\"input_tokens\":5,\"cache_read_input_tokens\":250000,\"cache_creation_input_tokens\":9000,\"cache_creation\":{\"ephemeral_1h_input_tokens\":9000,\"ephemeral_5m_input_tokens\":0}},\"filler\":\"%s\"}}\n", ts, i, sprintf("%0300d", i)
}' >> "$TRANSCRIPT"
# The fixture only proves anything while the boundary really is out of reach.
assert test "$(stat -f %z "$TRANSCRIPT")" -gt 262144
assert test "$(head -c 262144 "$TRANSCRIPT" | grep -c compact_boundary)" -eq 1
assert test "$(tail -c 262144 "$TRANSCRIPT" | grep -c compact_boundary)" -eq 0
far_boundary=$(run_statusline "$(statusline_payload ctx-bnd-far "$(warm_extra "$TRANSCRIPT" 87 260000)")")
assert grep -Fq "ctx ${DIM}0%${RESET} ${DIM}0k${RESET}" <<< "$far_boundary"
assert_eq "$(iso_utc $((NOW - 600)))" "$(awk '{print $2}' "$(bnd_file ctx-bnd-far)")"

# A response carrying only input tokens (no cache at all) is still a real size for
# the context that follows a boundary.
t_reset; t_boundary $((NOW - 30))
printf '{"type":"assistant","timestamp":"%s","uuid":"input-only","message":{"role":"assistant","model":"fixmodel","usage":{"input_tokens":40000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
  "$(iso_utc $((NOW - 5)))" >> "$TRANSCRIPT"
input_only=$(run_statusline "$(statusline_payload ctx-bnd-input-only "$(warm_extra "$TRANSCRIPT" 87 260000)")")
assert grep -Fq "40k" <<< "$input_only"
assert test "${input_only#*260k}" = "$input_only"

# Second-resolution timestamps make an auto-compact boundary tie with the last
# pre-compact response even when the response is written after it, so a tie is
# rejected: a transient empty context beats resurrecting the old total.
t_reset; t_boundary $((NOW - 30))
printf '{"type":"assistant","timestamp":"%s","uuid":"same-second","message":{"role":"assistant","model":"fixmodel","usage":{"input_tokens":5,"cache_read_input_tokens":250000,"cache_creation_input_tokens":9000}}}\n' \
  "$(iso_utc $((NOW - 30)))" >> "$TRANSCRIPT"
same_second=$(run_statusline "$(statusline_payload ctx-bnd-tie "$(warm_extra "$TRANSCRIPT" 87 260000)")")
assert grep -Fq "ctx ${DIM}0%${RESET} ${DIM}0k${RESET}" <<< "$same_second"

# The mirror of the trailing-older-boundary case: a re-emitted boundary that raises
# the maximum but is still older than a size already taken must not zero that size.
t_reset; t_boundary $((NOW - 900))
printf '{"type":"assistant","timestamp":"%s","uuid":"after-both","message":{"role":"assistant","model":"fixmodel","usage":{"input_tokens":5,"cache_read_input_tokens":51000,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":500,"ephemeral_5m_input_tokens":0}}}}\n' \
  "$(iso_utc $((NOW - 300)))" >> "$TRANSCRIPT"
t_boundary $((NOW - 600))
# Sessionless, because with a sidecar the seed is already the file-wide maximum and
# no in-window boundary can raise it; the in-scan reset only runs without one.
mid_boundary=$(run_statusline "$(statusline_payload "" "$(warm_extra "$TRANSCRIPT" 87 260000)")")
assert grep -Fq "52k" <<< "$mid_boundary"
assert test "${mid_boundary#*0k}" = "$mid_boundary"

# Sweeping this directory is context-nudge.sh's job (claude-setup); the window
# write path must leave even ancient files of other sessions alone.
t_reset; t_assist $((NOW - 5))
printf 'stale\n' > "$NUDGE_DIR/old.window"
touch -t 202001010000 "$NUDGE_DIR/old.window"
prune_extra=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:$tp,context_window:{context_window_size:200000,used_percentage:10,current_usage:{input_tokens:20000}}}')
run_statusline "$(statusline_payload ctx-bnd-prune "$prune_extra")" >/dev/null
assert test -f "$NUDGE_DIR/ctx-bnd-prune.window"
assert test -f "$NUDGE_DIR/old.window"
rm -f "$NUDGE_DIR/old.window" "$NUDGE_DIR/ctx-bnd-prune.window"

# --- a known boundary must not stop the window before it has been reached ---
# The sidecar knows the boundary from the whole file, i.e. from a position the
# current window has not read yet; stopping there hides a live response deeper
# than the window and reports cold AND an empty context at the same time.
t_far_boundary_case() {
  t_reset; t_boundary $((NOW - 7200)); t_assist $((NOW - 60)); t_stamp "$1"
  "$2"
  assert test "$(stat -f %z "$TRANSCRIPT")" -gt 262144
  assert test "$(tail -c 262144 "$TRANSCRIPT" | grep -c '"type":"assistant"')" -eq 0
  far_live=$(run_statusline "$(statusline_payload "$1" "$(warm_extra "$TRANSCRIPT" 55 111000)")")
  far_live_death=$(TZ=Europe/Kyiv date -r $((NOW - 60 + 3600)) +%H:%M)
  assert grep -Fq "${DIM}→${far_live_death}${RESET}" <<< "$far_live"
  assert test "${far_live#*0k}" = "$far_live"
}

tail_one_tool_result() {
  printf '{"type":"tool-result","timestamp":"%s","content":"' "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
  head -c 400000 /dev/zero | tr '\0' x >> "$TRANSCRIPT"
  printf '"}\n' >> "$TRANSCRIPT"
}
tail_one_user_paste() {
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"' "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
  head -c 400000 /dev/zero | tr '\0' x >> "$TRANSCRIPT"
  printf '"}}\n' >> "$TRANSCRIPT"
}
tail_many_small() {
  awk -v ts="$(iso_utc "$NOW")" 'BEGIN{
    for (i = 0; i < 900; i++)
      printf "{\"type\":\"user\",\"timestamp\":\"%s\",\"message\":{\"role\":\"user\"},\"pad\":\"%s\"}\n", ts, sprintf("%0350d", i)
  }' >> "$TRANSCRIPT"
}
t_far_boundary_case ctx-bnd-live-tool tail_one_tool_result
t_far_boundary_case ctx-bnd-live-paste tail_one_user_paste
t_far_boundary_case ctx-bnd-live-many tail_many_small

# The short-circuit itself survives: once the window has read back past the
# boundary, nothing deeper can change the verdict and the scan stops growing.
t_reset
BND_TAIL_BIN="$WORK/bnd-tail-bin"; BND_TAIL_LOG="$WORK/bnd-tail.log"
mkdir -p "$BND_TAIL_BIN"
printf '#!/usr/bin/env bash\nif [ "$1" = "-c" ]; then printf "%%s|%%s\\n" "$2" "$3" >> "$TAIL_LOG"; fi\nexec /usr/bin/tail "$@"\n' \
  > "$BND_TAIL_BIN/tail"
chmod +x "$BND_TAIL_BIN/tail"
rm -f "$BND_TAIL_LOG"
awk -v ts="$(iso_utc $((NOW - 7200)))" 'BEGIN{
  for (i = 0; i < 900; i++)
    printf "{\"type\":\"user\",\"timestamp\":\"%s\",\"message\":{\"role\":\"user\"},\"pad\":\"%s\"}\n", ts, sprintf("%01000d", i)
}' >> "$TRANSCRIPT"
t_boundary $((NOW - 3600))
awk -v ts="$(iso_utc $((NOW - 1800)))" 'BEGIN{
  for (i = 0; i < 600; i++)
    printf "{\"type\":\"user\",\"timestamp\":\"%s\",\"message\":{\"role\":\"user\"},\"pad\":\"%s\"}\n", ts, sprintf("%01000d", i)
}' >> "$TRANSCRIPT"
assert test "$(stat -f %z "$TRANSCRIPT")" -gt 1048576
assert test "$(tail -c 262144 "$TRANSCRIPT" | grep -c compact_boundary)" -eq 0
assert test "$(tail -c 1048576 "$TRANSCRIPT" | grep -c compact_boundary)" -eq 1
bnd_reached=$(PATH="$BND_TAIL_BIN:$PATH" TAIL_LOG="$BND_TAIL_LOG" \
  run_statusline "$(statusline_payload ctx-bnd-reached "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}0%${RESET} ${DIM}0k${RESET}" <<< "$bnd_reached"
assert grep -Fq "1048576|$TRANSCRIPT" "$BND_TAIL_LOG"
assert test 0 -eq "$(grep -Fc "4194304|$TRANSCRIPT" "$BND_TAIL_LOG")"

# A transcript smaller than the size the sidecar claims to have scanned is a
# different file; its remembered boundary is a phantom that zeroes a live context.
t_reset; t_user $((NOW - 120)); t_user $((NOW - 60))
printf '900000 %s\n' "$(iso_utc $((NOW - 7200)))" > "$(bnd_file ctx-bnd-shrunk)"
shrunk=$(run_statusline "$(statusline_payload ctx-bnd-shrunk "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$shrunk"
assert_eq "$(stat -f %z "$TRANSCRIPT") -" "$(cat "$(bnd_file ctx-bnd-shrunk)")"

t_reset; t_assist $((NOW - 60)); t_stamp ctx-bnd-shrunk-warm
printf '900000 %s\n' "$(iso_utc $((NOW - 7200)))" > "$(bnd_file ctx-bnd-shrunk-warm)"
shrunk_warm=$(run_statusline "$(statusline_payload ctx-bnd-shrunk-warm "$(warm_extra "$TRANSCRIPT" 55 111000)")")
shrunk_death=$(TZ=Europe/Kyiv date -r $((NOW - 60 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${shrunk_death}${RESET}" <<< "$shrunk_warm"
assert_eq "$(stat -f %z "$TRANSCRIPT") -" "$(cat "$(bnd_file ctx-bnd-shrunk-warm)")"

# --- a pure cache-read response proves warmth: the read refreshes the TTL ---
t_reset; t_assist $((NOW - 600)) fixmodel 50000 500 1h
t_assist $((NOW - 60)) fixmodel 50000 0 none; t_stamp ctx-pure-read
pure_read=$(run_statusline "$(statusline_payload ctx-pure-read "$(warm_extra "$TRANSCRIPT" 55 111000)")")
pure_read_death=$(TZ=Europe/Kyiv date -r $((NOW - 60 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${pure_read_death}${RESET}" <<< "$pure_read"
assert test "${pure_read#*111k}" = "$pure_read"

# An all-zero bucket map is the same case as no map at all.
t_reset; t_assist $((NOW - 600)) fixmodel 50000 500 5m
t_assist $((NOW - 60)) fixmodel 50000 0 5m; t_stamp ctx-pure-read-zero
pure_zero=$(run_statusline "$(statusline_payload ctx-pure-read-zero "$(warm_extra "$TRANSCRIPT" 55 111000)")")
pure_zero_death=$(TZ=Europe/Kyiv date -r $((NOW - 60 + 300)) +%H:%M)
assert grep -Fq "${DIM}→${pure_zero_death}${RESET}" <<< "$pure_zero"

# With no older bucket-bearing response in the window there is nothing to inherit.
t_reset; t_assist $((NOW - 60)) fixmodel 50000 0 none; t_stamp ctx-pure-read-alone
pure_alone=$(run_statusline "$(statusline_payload ctx-pure-read-alone "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$pure_alone"
assert test "${pure_alone#*→}" = "$pure_alone"

# A different model's bucket is a different cache entry - not inheritable.
t_reset; t_assist $((NOW - 600)) othermodel 50000 500 1h
t_assist $((NOW - 60)) fixmodel 50000 0 none; t_stamp ctx-pure-read-model
pure_model=$(run_statusline "$(statusline_payload ctx-pure-read-model "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$pure_model"
assert test "${pure_model#*→}" = "$pure_model"

PARENT_TRANSCRIPT="$WORK/parent-sid.jsonl"
t_assist_fork() {
  printf '{"type":"assistant","timestamp":"%s","uuid":"%s","forkedFrom":{"sessionId":"%s","messageUuid":"%s"},"message":{"role":"assistant","model":"fixmodel","usage":{"cache_read_input_tokens":50000,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":500,"ephemeral_5m_input_tokens":0}}}}\n' \
    "$(iso_utc "$1")" "$3" "$2" "$3" >> "$TRANSCRIPT"
}
parent_assist() {
  printf '{"type":"assistant","timestamp":"%s","uuid":"%s","message":{"role":"assistant","model":"fixmodel","usage":{"cache_read_input_tokens":50000,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":500,"ephemeral_5m_input_tokens":0}}}}\n' \
    "$(iso_utc "$1")" "$2" >> "$PARENT_TRANSCRIPT"
}

t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 600)) fork-anchor
t_assist_fork $((NOW - 600)) parent-sid fork-anchor
fork_only=$(run_statusline "$(statusline_payload ctx-fork-only \
  "$(jq -cn --arg tp "$TRANSCRIPT" \
    '{transcript_path:$tp,model:{id:"fixmodel"},context_window:{used_percentage:55,current_usage:{input_tokens:111000}}}')")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${YELLOW}? 111k${RESET}" <<< "$fork_only"
assert test "${fork_only#*→}" = "$fork_only"

# A branch of an UNCOMPACTED chat: the copied tail is all there is, and it agrees
# with the payload, so the number is measured rather than inherited and renders
# bright - dimming it read as "context lost" for a context that was fully there.
t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 600)) fork-anchor
t_assist_fork $((NOW - 600)) parent-sid fork-anchor
fork_agree=$(run_statusline "$(statusline_payload ctx-fork-agree \
  "$(jq -cn --arg tp "$TRANSCRIPT" \
    '{transcript_path:$tp,model:{id:"fixmodel"},context_window:{used_percentage:55,current_usage:{input_tokens:50500}}}')")")
assert grep -Fq "ctx ${YELLOW}55%${RESET}" <<< "$fork_agree"

# ... and a payload with no size at all corroborates nothing, so the branch keeps
# rendering its percentage dim.
t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 600)) fork-anchor
t_assist_fork $((NOW - 600)) parent-sid fork-anchor
fork_nosize=$(run_statusline "$(statusline_payload ctx-fork-nosize \
  "$(jq -cn --arg tp "$TRANSCRIPT" \
    '{transcript_path:$tp,model:{id:"fixmodel"},context_window:{used_percentage:55}}')")")
assert grep -Fq "ctx ${DIM}55%${RESET}" <<< "$fork_nosize"

t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 600)) fork-anchor
t_assist_fork $((NOW - 600)) parent-sid fork-anchor
printf '{"type":"system","subtype":"local_command","timestamp":"%s","uuid":"branch-own","parentUuid":"fork-anchor"}\n' \
  "$(iso_utc $((NOW - 500)))" >> "$TRANSCRIPT"
parent_assist $((NOW - 300)) parent-new
printf 'v2 %s acctgen 7 3600 fixmodel parent-new 262144\n' "$((NOW - 300))" > "$STATE_DIR/cache-ttl-track-parent-sid"
printf 'v1 %s acctgen 3600 parent-new\n' "$((NOW - 300))" > "$STATE_DIR/cache-ttl-track-parent-sid.model-fixmodel"
fork_warm=$(run_statusline "$(statusline_payload ctx-fork "$(warm_extra "$TRANSCRIPT" 55 111000)")")
fork_death=$(TZ=Europe/Kyiv date -r $((NOW - 300 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${fork_death}${RESET}" <<< "$fork_warm"
assert test "${fork_warm#*111k}" = "$fork_warm"
assert test "$(awk '{print NF}' "$STATE_DIR/cache-ttl-track-ctx-fork")" -ge 10

t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 600)) fork-anchor
t_assist_fork $((NOW - 600)) parent-sid fork-anchor
parent_assist $((NOW - 550)) skipped-parent-response
printf '{"type":"system","subtype":"local_command","timestamp":"%s","uuid":"branch-own","parentUuid":"fork-anchor"}\n' \
  "$(iso_utc $((NOW - 500)))" >> "$TRANSCRIPT"
printf 'v2 %s acctgen 0 3600 fixmodel skipped-parent-response 262144\n' "$((NOW - 550))" > "$STATE_DIR/cache-ttl-track-parent-sid"
printf 'v1 %s acctgen 3600 skipped-parent-response\n' "$((NOW - 550))" > "$STATE_DIR/cache-ttl-track-parent-sid.model-fixmodel"
fork_mid=$(run_statusline "$(statusline_payload ctx-fork-mid "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$fork_mid"
assert test "${fork_mid#*→}" = "$fork_mid"

t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 600)) fork-anchor
printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s"}\n' \
  "$(iso_utc $((NOW - 500)))" >> "$PARENT_TRANSCRIPT"
parent_assist $((NOW - 300)) post-compact
t_assist_fork $((NOW - 600)) parent-sid fork-anchor
printf '{"type":"system","subtype":"local_command","timestamp":"%s","uuid":"branch-own"}\n' \
  "$(iso_utc $((NOW - 400)))" >> "$TRANSCRIPT"
printf 'v1 %s acctgen 3600 post-compact\n' "$((NOW - 300))" \
  > "$STATE_DIR/cache-ttl-track-parent-sid.model-fixmodel"
fork_compact=$(run_statusline "$(statusline_payload ctx-fork-parent-compact "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$fork_compact"
assert test "${fork_compact#*→}" = "$fork_compact"

t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 10)) fork-anchor
t_assist_fork $((NOW - 10)) parent-sid fork-anchor
fork_fresh=$(run_statusline "$(statusline_payload ctx-fork-fresh "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$fork_fresh"
# The fork's own NEW response (no forkedFrom) resumes normal self-stamping.
t_assist $((NOW - 5))
fork_own=$(run_statusline "$(statusline_payload ctx-fork-fresh "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}→" <<< "$fork_own"
assert grep -q '^v2 [0-9]* acctgen ' "$STATE_DIR/cache-ttl-track-ctx-fork-fresh"

t_reset; t_assist $((NOW - 600)) fixmodel; t_assist $((NOW - 5)) othermodel
printf 'v2 %s alona 0\n' "$((NOW - 700))" > "$STATE_DIR/cache-ttl-track-ctx-model-fallback"
fallback_model=$(run_statusline "$(statusline_payload ctx-model-fallback "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$fallback_model"
assert test "${fallback_model#*→}" = "$fallback_model"

PARENT_TRANSCRIPT="$WORK/parent-cache.jsonl"
t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 300)) cache-anchor
t_assist_fork $((NOW - 300)) parent-cache cache-anchor
printf '{"type":"system","subtype":"local_command","timestamp":"%s","uuid":"branch-own"}\n' \
  "$(iso_utc $((NOW - 250)))" >> "$TRANSCRIPT"
printf 'v1 %s acctgen 3600 cache-anchor\n' "$((NOW - 300))" \
  > "$STATE_DIR/cache-ttl-track-parent-cache.model-fixmodel"
TAIL_BIN="$WORK/tail-bin"; TAIL_LOG="$WORK/tail.log"
mkdir -p "$TAIL_BIN"
printf '#!/usr/bin/env bash\nif [ "$1" = "-c" ]; then printf "%%s|%%s\\n" "$2" "$3" >> "$TAIL_LOG"; fi\nexec /usr/bin/tail "$@"\n' \
  > "$TAIL_BIN/tail"
chmod +x "$TAIL_BIN/tail"
rm -f "$TAIL_LOG"
PATH="$TAIL_BIN:$PATH" TAIL_LOG="$TAIL_LOG" \
  run_statusline "$(statusline_payload ctx-fork-cache "$(warm_extra "$TRANSCRIPT" 55 111000)")" >/dev/null
PATH="$TAIL_BIN:$PATH" TAIL_LOG="$TAIL_LOG" \
  run_statusline "$(statusline_payload ctx-fork-cache "$(warm_extra "$TRANSCRIPT" 55 111000)")" >/dev/null
assert_eq 1 "$(grep -Fc "$PARENT_TRANSCRIPT" "$TAIL_LOG")"
printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s"}\n' \
  "$(iso_utc $((NOW - 200)))" >> "$PARENT_TRANSCRIPT"
fork_cache_changed=$(PATH="$TAIL_BIN:$PATH" TAIL_LOG="$TAIL_LOG" \
  run_statusline "$(statusline_payload ctx-fork-cache "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$fork_cache_changed"
assert test "${fork_cache_changed#*→}" = "$fork_cache_changed"
assert_eq 2 "$(grep -Fc "$PARENT_TRANSCRIPT" "$TAIL_LOG")"

# A parent bigger than the 8 MiB scan window: the anchor is in the scanned tail with
# nothing after it, which settles the fork as a tail fork without reading the rest.
PARENT_TRANSCRIPT="$WORK/parent-big.jsonl"
t_reset
yes '{"type":"attachment","timestamp":"'"$(iso_utc $((NOW - 900)))"'","uuid":"pad"}' \
  | head -c 8500000 > "$PARENT_TRANSCRIPT"; printf '\n' >> "$PARENT_TRANSCRIPT"
parent_assist $((NOW - 300)) big-anchor
t_assist_fork $((NOW - 300)) parent-big big-anchor
printf '{"type":"system","subtype":"local_command","timestamp":"%s","uuid":"branch-own"}\n' \
  "$(iso_utc $((NOW - 250)))" >> "$TRANSCRIPT"
printf 'v1 %s acctgen 3600 big-anchor\n' "$((NOW - 300))" \
  > "$STATE_DIR/cache-ttl-track-parent-big.model-fixmodel"
fork_big=$(run_statusline "$(statusline_payload ctx-fork-big "$(warm_extra "$TRANSCRIPT" 55 111000)")")
fork_big_death=$(TZ=Europe/Kyiv date -r $((NOW - 300 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${fork_big_death}${RESET}" <<< "$fork_big"
assert test "${fork_big#*111k}" = "$fork_big"
assert grep -q $'^v4\x1fparent-big\x1fbig-anchor\x1f' "$STATE_DIR/cache-ttl-track-ctx-fork-big.fork"
assert grep -q $'\x1ftail\x1f' "$STATE_DIR/cache-ttl-track-ctx-fork-big.fork"
# Turn bookkeeping written after the anchor is not conversation: still a tail fork.
printf '{"type":"system","subtype":"stop_hook_summary","timestamp":"%s","uuid":"big-hooks"}\n{"type":"system","subtype":"turn_duration","timestamp":"%s","uuid":"big-turn"}\n' \
  "$(iso_utc $((NOW - 298)))" "$(iso_utc $((NOW - 298)))" >> "$PARENT_TRANSCRIPT"
fork_big_hooks=$(run_statusline "$(statusline_payload ctx-fork-big "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}→${fork_big_death}${RESET}" <<< "$fork_big_hooks"
assert grep -q $'\x1ftail\x1f' "$STATE_DIR/cache-ttl-track-ctx-fork-big.fork"
# The same oversized parent with an own entry after the anchor is a mid fork, not unknown.
printf '{"type":"user","timestamp":"%s","uuid":"big-after"}\n' "$(iso_utc $((NOW - 280)))" >> "$PARENT_TRANSCRIPT"
fork_big_mid=$(run_statusline "$(statusline_payload ctx-fork-big "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}? 111k${RESET}" <<< "$fork_big_mid"
assert grep -q $'\x1fmid\x1f' "$STATE_DIR/cache-ttl-track-ctx-fork-big.fork"

CROSS_ROOT="$WORK/projects"
CROSS_CHILD="$CROSS_ROOT/child-project"
CROSS_PARENT="$CROSS_ROOT/parent-project"
mkdir -p "$CROSS_CHILD" "$CROSS_PARENT"
TRANSCRIPT="$CROSS_CHILD/child.jsonl"
PARENT_TRANSCRIPT="$CROSS_PARENT/parent-cross.jsonl"
t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 300)) cross-anchor
t_assist_fork $((NOW - 300)) parent-cross cross-anchor
printf '{"type":"system","subtype":"local_command","timestamp":"%s","uuid":"branch-own"}\n' \
  "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
printf 'v1 %s acctgen 3600 cross-anchor\n' "$((NOW - 300))" \
  > "$STATE_DIR/cache-ttl-track-parent-cross.model-fixmodel"
cross_fork=$(run_statusline "$(statusline_payload ctx-cross-fork "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}→" <<< "$cross_fork"

TRANSCRIPT="$WORK/empty-session-child.jsonl"
PARENT_TRANSCRIPT="$WORK/empty-session-parent-sid.jsonl"
t_reset; : > "$PARENT_TRANSCRIPT"; parent_assist $((NOW - 300)) empty-anchor
t_assist_fork $((NOW - 300)) empty-session-parent-sid empty-anchor
printf '{"type":"system","subtype":"local_command","timestamp":"%s","uuid":"branch-own"}\n' \
  "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
printf 'v1 %s acctgen 3600 empty-anchor\n' "$((NOW - 300))" \
  > "$STATE_DIR/cache-ttl-track-empty-session-parent-sid.model-fixmodel"
empty_session_fork=$(run_statusline "$(statusline_payload "" "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}→" <<< "$empty_session_fork"

TRANSCRIPT="$WORK/transcript.jsonl"

TRANSCRIPT="$WORK/scan-memory.jsonl"
t_reset; t_assist $((NOW - 20)); t_stamp ctx-scan-memory
printf '{"type":"tool-result","timestamp":"%s","content":"' "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
head -c 350000 /dev/zero | tr '\0' x >> "$TRANSCRIPT"
printf '"}\n' >> "$TRANSCRIPT"
rm -f "$TAIL_LOG"
PATH="$TAIL_BIN:$PATH" TAIL_LOG="$TAIL_LOG" \
  run_statusline "$(statusline_payload ctx-scan-memory "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
assert_eq 1048576 "$(awk '{print $6}' "$STATE_DIR/cache-ttl-track-ctx-scan-memory.model-fixmodel")"
rm -f "$TAIL_LOG"
PATH="$TAIL_BIN:$PATH" TAIL_LOG="$TAIL_LOG" \
  run_statusline "$(statusline_payload ctx-scan-memory "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
assert_eq 262144 "$(head -n1 "$TAIL_LOG" | cut -d'|' -f1)"
assert_eq 1048576 "$(sed -n '2p' "$TAIL_LOG" | cut -d'|' -f1)"
t_assist $((NOW - 5))
rm -f "$TAIL_LOG"
PATH="$TAIL_BIN:$PATH" TAIL_LOG="$TAIL_LOG" \
  run_statusline "$(statusline_payload ctx-scan-memory "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
assert_eq 262144 "$(awk '{print $6}' "$STATE_DIR/cache-ttl-track-ctx-scan-memory.model-fixmodel")"
rm -f "$TAIL_LOG"
PATH="$TAIL_BIN:$PATH" TAIL_LOG="$TAIL_LOG" \
  run_statusline "$(statusline_payload ctx-scan-memory "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
assert_eq 1 "$(wc -l < "$TAIL_LOG" | tr -d ' ')"
assert_eq 262144 "$(head -n1 "$TAIL_LOG" | cut -d'|' -f1)"

# Cold cache color tests: count colored by size (no cache = cache fields are 0).
cold_extra() {
  jq -cn --arg tp "$1" --argjson pct "$2" --argjson it "$3" '
    {transcript_path:$tp,model:{id:"fixmodel"},
     context_window:{used_percentage:$pct,
       current_usage:{input_tokens:$it,cache_creation_input_tokens:0,cache_read_input_tokens:0}}}'
}

t_reset
# Cold <90k -> dim
cold_lo=$(run_statusline "$(statusline_payload ctx-cold-lo "$(cold_extra "$TRANSCRIPT" 20 50000)")")
assert grep -Fq "${DIM}50k${RESET}" <<< "$cold_lo"

# Cold 90–299k -> yellow
cold_mid=$(run_statusline "$(statusline_payload ctx-cold-mid "$(cold_extra "$TRANSCRIPT" 20 150000)")")
assert grep -Fq "${YELLOW}150k${RESET}" <<< "$cold_mid"

# Cold >=300k -> red
cold_hi=$(run_statusline "$(statusline_payload ctx-cold-hi "$(cold_extra "$TRANSCRIPT" 20 350000)")")
assert grep -Fq "${RED}350k${RESET}" <<< "$cold_hi"

# (d) cache fields 0 (only plain input tokens) -> dim.
d_extra=$(jq -cn --arg tp "$TRANSCRIPT" '
  {transcript_path:$tp,model:{id:"fixmodel"},context_window:{used_percentage:20,current_usage:{input_tokens:60000}}}')
warm_d=$(run_statusline "$(statusline_payload ctx-nocache "$d_extra")")
assert grep -Fq "${DIM}60k${RESET}" <<< "$warm_d"

warm_e=$(run_statusline "$(statusline_payload ctx-nopath "$(warm_extra "" 20 50000)")")
assert grep -Fq "${DIM}? 50k${RESET}" <<< "$warm_e"
assert test "${warm_e#*→}" = "$warm_e"

UNREADABLE_TRANSCRIPT="$WORK/unreadable.jsonl"
printf '{}\n' > "$UNREADABLE_TRANSCRIPT"
chmod 000 "$UNREADABLE_TRANSCRIPT"
unreadable_out=$(run_statusline "$(statusline_payload ctx-unreadable "$(warm_extra "$UNREADABLE_TRANSCRIPT" 20 50000)")")
assert grep -Fq "${DIM}? 50k${RESET}" <<< "$unreadable_out"
chmod 600 "$UNREADABLE_TRANSCRIPT"

t_reset
clear_out=$(run_statusline "$(statusline_payload ctx-clear "$(warm_extra "$TRANSCRIPT" 20 50000)")")
assert grep -Fq "${DIM}50k${RESET}" <<< "$clear_out"
assert test "${clear_out#*→}" = "$clear_out"

printf 'not-json\n' > "$TRANSCRIPT"
garbage_out=$(run_statusline "$(statusline_payload ctx-garbage \
  "$(jq -cn --arg tp "$TRANSCRIPT" \
    '{transcript_path:$tp,model:{id:"fixmodel"},context_window:{used_percentage:55,current_usage:{input_tokens:111000}}}')")")
garbage_rc=$?
assert_eq 0 "$garbage_rc"
assert grep -Fq "ctx ${DIM}55%${RESET} ${YELLOW}111k${RESET}" <<< "$garbage_out"

LEARNED="$STATE_DIR/cache-ttl-learned"
rm -f "$LEARNED"

t_reset; t_assist $((NOW - 30)) fixmodel 100000 500 5m; t_stamp ctx-bk5
bk5_out=$(run_statusline "$(statusline_payload ctx-bk5 "$(warm_extra "$TRANSCRIPT" 20 100000)")")
bk5_death=$(TZ=Europe/Kyiv date -r $((NOW - 30 + 300)) +%H:%M)
assert grep -Fq "${DIM}→${bk5_death}${RESET}${YELLOW}↓5m${RESET}" <<< "$bk5_out"
assert test "${bk5_out#*100k}" = "$bk5_out"

t_reset; t_assist $((NOW - 30)) fixmodel 100000 500 mixed; t_stamp ctx-mixed
mixed_out=$(run_statusline "$(statusline_payload ctx-mixed "$(warm_extra "$TRANSCRIPT" 20 100000)")")
assert grep -Fq "${DIM}→${bk5_death}${RESET}${YELLOW}↓5m${RESET}" <<< "$mixed_out"

printf '{"observed_floor_s":0,"observed_ceiling_s":600,"updated_at":%s}\n' "$NOW" > "$LEARNED"
t_reset; t_assist $((NOW - 30)) fixmodel 100000 500 1h; t_stamp ctx-bk1
bk1_out=$(run_statusline "$(statusline_payload ctx-bk1 "$(warm_extra "$TRANSCRIPT" 20 100000)")")
bk1_death=$(TZ=Europe/Kyiv date -r $((NOW - 30 + 3600)) +%H:%M)
assert grep -Fq "${DIM}→${bk1_death}${RESET}" <<< "$bk1_out"

t_reset; t_assist $((NOW - 50)) fixmodel 50000 500 -; t_stamp ctx-no-bucket
printf '7200\n' > "$HOME/.claude/statusline-cache-ttl"
no_bucket=$(run_statusline "$(statusline_payload ctx-no-bucket "$(warm_extra "$TRANSCRIPT" 20 50000)")")
assert grep -Fq "${DIM}? 50k${RESET}" <<< "$no_bucket"
assert test "${no_bucket#*→}" = "$no_bucket"
rm -f "$HOME/.claude/statusline-cache-ttl"
rm -f "$LEARNED"

# --- TTL learning from transcript evidence (newest turn's first response) ---
# The evidence pair needs a same-account stamp covering the previous response,
# so each case pre-seeds the v2 track with acctgen and the last response epoch.
learn_case() { # sid prev_assist_gap user_at ev_cr ev_cc [ev_model] [boundary_at]
  local sid="$1" prev="$2" user="$3" cr="$4" cc="$5" m="${6:-fixmodel}" bnd="${7:-}"
  t_reset; t_assist "$prev" fixmodel 60000 300
  [ -n "$bnd" ] && t_boundary "$bnd"
  t_user "$user"; t_assist $((user + 1)) "$m" "$cr" "$cc"
  printf 'v2 %s acctgen 0\n' $((user + 1)) > "$STATE_DIR/cache-ttl-track-$sid"
  run_statusline "$(statusline_payload "$sid" "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
}

# HIT after a 300s gap raises the floor to 300.
rm -f "$LEARNED"
learn_case learn-hit $((NOW - 500)) $((NOW - 200)) 50000 100
assert grep -Fq '"observed_floor_s":300' "$LEARNED"
assert_eq "$((NOW - 199))" "$(awk '{print $4}' "$STATE_DIR/cache-ttl-track-learn-hit")"

# ...and a HIT after a gap longer than the believed ceiling disproves it.
printf '{"observed_floor_s":0,"observed_ceiling_s":200,"updated_at":%s}\n' "$NOW" > "$LEARNED"
learn_case learn-heal $((NOW - 500)) $((NOW - 200)) 50000 100
assert grep -Fq '"observed_ceiling_s":null' "$LEARNED"

# MISS (full rebuild) after a 600s gap lowers the ceiling to 600.
rm -f "$LEARNED"
learn_case learn-miss $((NOW - 800)) $((NOW - 200)) 0 50000
assert grep -Fq '"observed_ceiling_s":600' "$LEARNED"

FRESH_LEARNED="$WORK/fresh-cache/deep/cache-ttl-learned"
rm -rf "$WORK/fresh-cache"
t_reset; t_assist $((NOW - 800)) fixmodel 60000 300
t_user $((NOW - 200)); t_assist $((NOW - 199)) fixmodel 0 50000
printf 'v2 %s acctgen 0\n' $((NOW - 199)) > "$STATE_DIR/cache-ttl-track-fresh-lock"
STATUSLINE_CACHE_TTL_LEARNED="$FRESH_LEARNED" \
  run_statusline "$(statusline_payload fresh-lock "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
assert test -f "$FRESH_LEARNED"

CONC_A="$WORK/learn-concurrent-a.jsonl"
CONC_B="$WORK/learn-concurrent-b.jsonl"
saved_transcript="$TRANSCRIPT"
TRANSCRIPT="$CONC_A"; : > "$TRANSCRIPT"
t_assist $((NOW - 700)) fixmodel 60000 300
t_user $((NOW - 400)); t_assist $((NOW - 399)) fixmodel 50000 100
TRANSCRIPT="$CONC_B"; : > "$TRANSCRIPT"
t_assist $((NOW - 900)) fixmodel 60000 300
t_user $((NOW - 300)); t_assist $((NOW - 299)) fixmodel 0 50000
TRANSCRIPT="$saved_transcript"
printf 'v2 %s acctgen 0\n' $((NOW - 399)) > "$STATE_DIR/cache-ttl-track-learn-concurrent-a"
printf 'v2 %s acctgen 0\n' $((NOW - 299)) > "$STATE_DIR/cache-ttl-track-learn-concurrent-b"
rm -f "$LEARNED"
run_statusline "$(statusline_payload learn-concurrent-a "$(warm_extra "$CONC_A" 20 50000)")" >/dev/null &
learn_pid_a=$!
run_statusline "$(statusline_payload learn-concurrent-b "$(warm_extra "$CONC_B" 20 50000)")" >/dev/null &
learn_pid_b=$!
wait "$learn_pid_a" "$learn_pid_b"
assert grep -Fq '"observed_floor_s":300' "$LEARNED"
assert grep -Fq '"observed_ceiling_s":600' "$LEARNED"

# Each response is consumed once (learned_upto): manually zero the floor,
# re-render the same transcript — the old evidence must not re-learn.
rm -f "$LEARNED"
learn_case learn-dedup $((NOW - 500)) $((NOW - 200)) 50000 100
assert grep -Fq '"observed_floor_s":300' "$LEARNED"
printf '{"observed_floor_s":0,"observed_ceiling_s":null,"updated_at":%s}\n' "$NOW" > "$LEARNED"
run_statusline "$(statusline_payload learn-dedup "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
assert grep -Fq '"observed_floor_s":0' "$LEARNED"

# Guards: a miss is TTL evidence only when nothing else explains it.
# (a) sub-120s gaps are prefix invalidations, never ceiling evidence;
rm -f "$LEARNED"
learn_case learn-tiny $((NOW - 260)) $((NOW - 200)) 0 50000
assert test ! -e "$LEARNED"
# (b) a model switch across the gap is not TTL evidence;
learn_case learn-modelsw $((NOW - 800)) $((NOW - 200)) 0 50000 othermodel
assert test ! -e "$LEARNED"
# (c) a compact boundary inside the gap is not TTL evidence;
learn_case learn-bnd $((NOW - 800)) $((NOW - 200)) 0 50000 fixmodel $((NOW - 400))
assert test ! -e "$LEARNED"
# (d) an account switch across the gap (stamp != current) is not TTL evidence.
t_reset; t_assist $((NOW - 800)) fixmodel 60000 300
t_user $((NOW - 200)); t_assist $((NOW - 199)) fixmodel 0 50000
printf 'v2 %s alona 0\n' $((NOW - 199)) > "$STATE_DIR/cache-ttl-track-learn-acctsw"
run_statusline "$(statusline_payload learn-acctsw "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
assert test ! -e "$LEARNED"

# Stale bounds (updated_at > 7 days old) decay to floor 0 / ceiling null.
printf '{"observed_floor_s":1234,"observed_ceiling_s":5000,"updated_at":%s}\n' $((NOW - 800000)) > "$LEARNED"
t_reset; t_assist $((NOW - 20))
run_statusline "$(statusline_payload ctx-decay "$(warm_extra "$TRANSCRIPT" 20 50000)")" >/dev/null
assert grep -Fq '"observed_floor_s":0' "$LEARNED"
assert grep -Fq '"observed_ceiling_s":null' "$LEARNED"
assert test "$(grep -oE '"updated_at":[0-9]+' "$LEARNED" | grep -oE '[0-9]+')" -ge "$NOW"
rm -f "$LEARNED" "$STATE_DIR"/cache-ttl-track-*
: > "$TRANSCRIPT"
RUN_STATUSLINE_DEFAULT_ACCOUNT=

# --- store merge-kick (bin/statusline.sh) ---
KICK_STAMP="$STATE_DIR/store-merge-kick"
KICK_LOCK="$STATE_DIR/store-merge-kick.lock"
KICK_MARK="$WORK/kick-marker"
kick_reset() { rm -f "$KICK_STAMP" "$KICK_MARK"; rmdir "$KICK_LOCK" 2>/dev/null || true; }
wait_for_mark() { local i; for i in $(seq 1 60); do [ -f "$KICK_MARK" ] && return 0; sleep 0.05; done; return 1; }

FAKE_COLLECTOR="$FIXTURES/fake-collector"
printf '#!/usr/bin/env bash\nprintf ran >> "%s"\n' "$KICK_MARK" > "$FAKE_COLLECTOR"
chmod +x "$FAKE_COLLECTOR"
FAIL_COLLECTOR="$FIXTURES/fail-collector"
printf '#!/usr/bin/env bash\nprintf boom >&2\nexit 2\n' > "$FAIL_COLLECTOR"
chmod +x "$FAIL_COLLECTOR"
SLOW_COLLECTOR="$FIXTURES/slow-collector"
printf '#!/usr/bin/env bash\nsleep 3\nprintf slow >> "%s"\n' "$KICK_MARK" > "$SLOW_COLLECTOR"
chmod +x "$SLOW_COLLECTOR"

# The kick only fires in the fresh-headers write branch: a pinned account with
# rate_limits present in the render payload.
kick_payload=$(statusline_payload status-kick \
  '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":'"$((NOW + 3600))"'}}}')

# A: absent stamp -> stamp written synchronously and the collector runs.
kick_reset
kick_out=$(STORE_MERGE_CMD="$FAKE_COLLECTOR" run_statusline "$kick_payload" kickacct) \
  || fail "statusline kick render failed"
assert grep -Fq 'Fixture' <<< "$kick_out"
assert test -f "$KICK_STAMP"
assert wait_for_mark
assert_eq ran "$(cat "$KICK_MARK")"

# B: a fresh stamp debounces — no second kick, and the stamp is not rewritten.
: > "$KICK_STAMP"
rm -f "$KICK_MARK"
kick_before=$(stat -f %m "$KICK_STAMP")
STORE_MERGE_CMD="$FAKE_COLLECTOR" run_statusline "$kick_payload" kickacct >/dev/null \
  || fail "statusline debounced render failed"
sleep 0.2
assert test ! -f "$KICK_MARK"
assert_eq "$kick_before" "$(stat -f %m "$KICK_STAMP")"

# C: a failing collector stays silent — the render still succeeds with clean
# stdout/stderr (the collector's stderr is detached to /dev/null).
kick_reset
kick_err="$WORK/kick-stderr"
fail_out=$(STORE_MERGE_CMD="$FAIL_COLLECTOR" run_statusline "$kick_payload" kickacct 2>"$kick_err") \
  || fail "statusline kick with failing collector exited nonzero"
assert grep -Fq 'Fixture' <<< "$fail_out"
assert test "${fail_out#*boom}" = "$fail_out"
assert_eq "" "$(cat "$kick_err")"

# D: a slow collector never blocks the render (detached).
kick_reset
kick_start=$(date +%s)
STORE_MERGE_CMD="$SLOW_COLLECTOR" run_statusline "$kick_payload" kickacct >/dev/null \
  || fail "statusline kick with slow collector exited nonzero"
assert test "$(( $(date +%s) - kick_start ))" -lt 2

# --- statusline-freshness-gate.sh ---
FRESH_GATE="$ROOT/bin/statusline-freshness-gate.sh"
fg_payload() {
  jq -cn --arg event "$1" --arg tool "$2" --arg file "$3" \
    '{hook_event_name:$event,tool_name:$tool,
      tool_input:(if $tool=="NotebookEdit" then {notebook_path:$file} else {file_path:$file} end)}'
}
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/statusline.sh" | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse Write "$ROOT/bin/statusline-ports-probe.sh" | "$FRESH_GATE")
assert grep -Fq 'statusline-contract.md' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse NotebookEdit "/x/statusline-ports-probe.sh" | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/claudeb" | "$FRESH_GATE")
assert_eq "" "$fg_out"
fg_out=$(fg_payload PreToolUse Edit "$ROOT/bin/statusline.sh" | "$FRESH_GATE")
assert_eq "" "$fg_out"
fg_out=$(printf '{broken' | "$FRESH_GATE") || fail "freshness gate broken json nonzero"
assert_eq "" "$fg_out"

# --- branch segment: uncommitted diff +A/-D with dim +N~M-Kf file counts ---
REPO_D="$FIXTURES/diff-repo"
mkdir -p "$REPO_D"
git -C "$REPO_D" init -qb main
printf 'l1\nl2\nl3\n' > "$REPO_D/tracked.txt"
git -C "$REPO_D" add tracked.txt
git -C "$REPO_D" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
diff_extra=$(jq -cn --arg d "$REPO_D" '{cwd:$d,workspace:{current_dir:$d,project_dir:$d}}')
dgit() { git -C "$REPO_D" -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

# Clean tree: no lines, no file counts.
dclean_out=$(run_statusline "$(statusline_payload diff-clean "$diff_extra")")
assert test "${dclean_out#*"${GREEN}+"}" = "$dclean_out"
assert test "${dclean_out#*"f${RESET}"}" = "$dclean_out"

# Modified tracked (+2/-1) and an untracked text file (+3): lines sum, files split.
printf 'l1\nL2\nl3\nl4\n' > "$REPO_D/tracked.txt"
printf 'n1\nn2\nn3\n' > "$REPO_D/new.txt"
dmix_out=$(run_statusline "$(statusline_payload diff-mixed "$diff_extra")")
assert grep -Fq "${GREEN}+5${RESET}/${RED}-1${RESET} ${DIM}+1~1f${RESET}" <<< "$dmix_out"

# Staging is still uncommitted: nothing moves.
dgit add tracked.txt
dstage_out=$(run_statusline "$(statusline_payload diff-staged "$diff_extra")")
assert grep -Fq "${GREEN}+5${RESET}/${RED}-1${RESET} ${DIM}+1~1f${RESET}" <<< "$dstage_out"

# A commit (by any session/agent) drops its part on the very next render.
dgit commit -qm second
dcommit_out=$(run_statusline "$(statusline_payload diff-committed "$diff_extra")")
assert grep -Fq "${GREEN}+3${RESET}/${RED}-0${RESET} ${DIM}+1f${RESET}" <<< "$dcommit_out"

# Deleting a tracked file: negative lines plus -1f.
dgit add new.txt
dgit commit -qm third
dgit rm -q new.txt
ddel_out=$(run_statusline "$(statusline_payload diff-deleted "$diff_extra")")
assert grep -Fq "${GREEN}+0${RESET}/${RED}-3${RESET} ${DIM}-1f${RESET}" <<< "$ddel_out"
dgit checkout -q HEAD -- new.txt

# Rename-only: zero countable lines, so the dim file counts render alone.
dgit mv new.txt moved.txt
dren_out=$(run_statusline "$(statusline_payload diff-renamed "$diff_extra")")
assert grep -Fq " ${DIM}~1f${RESET}" <<< "$dren_out"
assert test "${dren_out#*"${GREEN}+"}" = "$dren_out"
dgit mv moved.txt new.txt

# Untracked binary: 0 lines but still a file → files-only display.
printf 'BIN\0BIN' > "$REPO_D/blob.bin"
dbin_out=$(run_statusline "$(statusline_payload diff-binary "$diff_extra")")
assert grep -Fq " ${DIM}+1f${RESET}" <<< "$dbin_out"
assert test "${dbin_out#*"${GREEN}+"}" = "$dbin_out"
rm -f "$REPO_D/blob.bin"

# Branch switch: the label and the diff follow the new HEAD on the next render.
dgit checkout -qb feat
printf 'l1\nL2\nl3\nl4\nl5\n' > "$REPO_D/tracked.txt"
dgit add tracked.txt
dgit commit -qm feat-version
dfeat_out=$(run_statusline "$(statusline_payload diff-feat "$diff_extra")")
assert grep -Fq '⎇ feat' <<< "$dfeat_out"
assert test "${dfeat_out#*"${GREEN}+"}" = "$dfeat_out"

# HEAD motion under an untouched worktree (soft reset ≈ amend/rebase/switch):
# the very next render diffs against the NEW HEAD.
git -C "$REPO_D" reset -q --soft HEAD~1
dsoft_out=$(run_statusline "$(statusline_payload diff-soft "$diff_extra")")
assert grep -Fq "${GREEN}+1${RESET}/${RED}-0${RESET} ${DIM}~1f${RESET}" <<< "$dsoft_out"
dgit commit -qm feat-version-again
dgit checkout -q main

# The LLM cd's into another repo mid-session: the diff follows the ACTIVE repo.
printf 'w1\nw2\n' > "$TOP_B/wt-junk.txt"
printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-diff-workdir"
dwd_out=$(run_statusline "$(statusline_payload diff-workdir "$diff_extra")")
assert grep -Fq "⧉ $(basename "$TOP_B")" <<< "$dwd_out"
assert grep -Fq "${GREEN}+2${RESET}/${RED}-0${RESET} ${DIM}+1f${RESET}" <<< "$dwd_out"
rm -f "$TOP_B/wt-junk.txt" "$STATE_DIR/workdir-diff-workdir"

# Detached HEAD still measures the diff (vs the detached commit).
printf 'd1\n' > "$TOP_K/det-junk.txt"
det_extra=$(jq -cn --arg d "$TOP_K" '{cwd:$d,workspace:{current_dir:$d,project_dir:$d}}')
ddet_out=$(run_statusline "$(statusline_payload diff-detached "$det_extra")")
assert grep -Fq "@$SHORT_SHA" <<< "$ddet_out"
assert grep -Fq "${GREEN}+1${RESET}/${RED}-0${RESET} ${DIM}+1f${RESET}" <<< "$ddet_out"
rm -f "$TOP_K/det-junk.txt"

# Unborn HEAD (no commits yet): staged lines count via the --cached fallback.
REPO_E="$FIXTURES/diff-unborn"
mkdir -p "$REPO_E"
git -C "$REPO_E" init -qb main
printf 'x\ny\n' > "$REPO_E/f.txt"
git -C "$REPO_E" add f.txt
unborn_extra=$(jq -cn --arg d "$REPO_E" '{cwd:$d,workspace:{current_dir:$d,project_dir:$d}}')
dunborn_out=$(run_statusline "$(statusline_payload diff-unborn "$unborn_extra")")
assert grep -Fq "${GREEN}+2${RESET}/${RED}-0${RESET} ${DIM}+1f${RESET}" <<< "$dunborn_out"

# Unborn HEAD, staged file modified again in the worktree: the worktree is the
# truth — no double count of the staged intermediate.
printf 'p\nq\n' > "$REPO_E/f.txt"
dunborn2_out=$(run_statusline "$(statusline_payload diff-unborn-mod "$unborn_extra")")
assert grep -Fq "${GREEN}+2${RESET}/${RED}-0${RESET} ${DIM}+1f${RESET}" <<< "$dunborn2_out"

# --- statusline-ports-probe.sh ---
PORTS_PROBE="$ROOT/bin/statusline-ports-probe.sh"
FAKE_PS="$FIXTURES/ports-ps"
cat > "$FAKE_PS" <<'PSEOF'
#!/usr/bin/env bash
cat <<'SNAP'
1000 1 claude
1001 1000 node /path/to/vite
1002 1000 node /Users/x/.nvm/codex mcp-server
1003 1000 python3 -m http.server 8123
1004 1000 node ./mcp/server.mjs
1005 1000 agy --model gemini
1006 1005 node /opt/agy/rpc.js
1007 1000 codex exec
1008 1007 node /srv/dev-server
1009 1000 node serve.js --dir /srv/agy
1010 1 node /proj/node_modules/.bin/next start --port 4254
1011 1 node /elsewhere/server.js
1012 1 node /projx/server.js
1015 1 node /proj/rpc.js
1016 1000 8080 --serve
1017 1000 COMMANDER --serve
1018 1000 COMMAND --serve
1013 1000 claude
1014 1013 node /path/to/vite-worker
9999 1 claude
SNAP
PSEOF
chmod +x "$FAKE_PS"
FAKE_LSOF="$FIXTURES/ports-lsof"
cat > "$FAKE_LSOF" <<'LSEOF'
#!/usr/bin/env bash
# The probe asks this twice: once for the listeners, once for the working directory of each
# listening process, and the second answer is -F field output, not a table.
for arg in "$@"; do
  [ "$arg" = cwd ] || continue
  cat <<'CWD'
p1010
n/proj
p1011
n/elsewhere
p1012
n/projx
p1015
n/proj
CWD
  exit 0
done
cat <<'OUT'
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
node     1001 u   20u  IPv4  0t0      TCP *:5173 (LISTEN)
node     1002 u   21u  IPv4  0t0      TCP 127.0.0.1:7000 (LISTEN)
python3  1003 u   22u  IPv4  0t0      TCP *:8123 (LISTEN)
node     1003 u   24u  IPv4  0t0      TCP *:5173 (LISTEN)
node     1004 u   23u  IPv6  0t0      TCP [::1]:9999 (LISTEN)
agy      1005 u   10u  IPv4  0t0      TCP 127.0.0.1:61609 (LISTEN)
node     1006 u   11u  IPv4  0t0      TCP 127.0.0.1:61610 (LISTEN)
node     1008 u   12u  IPv4  0t0      TCP *:5174 (LISTEN)
node     1009 u   13u  IPv4  0t0      TCP *:8080 (LISTEN)
node     1010 u   30u  IPv4  0t0      TCP *:4254 (LISTEN)
node     1011 u   31u  IPv4  0t0      TCP *:4300 (LISTEN)
node     1012 u   32u  IPv4  0t0      TCP *:4400 (LISTEN)
node     1014 u   33u  IPv4  0t0      TCP *:4500 (LISTEN)
node     1015 u   34u  IPv4  0t0      TCP 127.0.0.1:62150 (LISTEN)
8080     1016 u   35u  IPv4  0t0      TCP *:4600 (LISTEN)
COMMANDER 1017 u  36u  IPv4  0t0      TCP *:4700 (LISTEN)
COMMAND   1018 u  37u  IPv4  0t0      TCP *:4800 (LISTEN)
OUT
LSEOF
chmod +x "$FAKE_LSOF"
FAKE_LSOF_EMPTY="$FIXTURES/ports-lsof-empty"
printf '#!/usr/bin/env bash\nprintf "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\\n"\n' > "$FAKE_LSOF_EMPTY"
chmod +x "$FAKE_LSOF_EMPTY"

run_probe() {
  STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$FAKE_LSOF" "$PORTS_PROBE" "$1" "$2" "${3:-}"
}
run_probe pp-parse 1001
# 61609 and 61610 are an LLM tool talking to itself, an agy process and a node it spawned. The
# two that stay are what the segment exists for: 5174 is a dev server a codex worker started,
# and 8080 is one whose own arguments merely mention a path ending in agy. 4500 belongs to a
# claudeb worker of this session, which is itself a claude process — passing one on the way up must
# not end the walk, or every server a worker starts reads as a sibling chat's. 1010-1012 are
# orphans and no repository was given, so nothing places them. 4600 belongs to a process whose own
# name is all digits, which the pid scan must not mistake for the pid column, and 4700 to one whose
# name merely starts with the header word. A real process exactly named COMMAND also survives
# because the listener filter makes the header check redundant.
assert_eq '5173 8123 5174 8080 4500 4600 4700 4800' "$(cat "$STATE_DIR/ports-pp-parse")"

# A server backgrounded from a tool call is reparented to launchd as soon as that call returns —
# the case the ancestry walk alone could never see, and the one every dev server actually hits.
# Its working directory is inside the repository being shown, so it is claimed back; the one
# elsewhere is not, and neither is /projx, whose name merely starts with the repository's. 62150 has
# the right directory and the wrong port: a directory is weaker evidence than a parent, and every
# editor RPC socket started from the repository would otherwise fill the segment.
run_probe pp-orphan 1001 /proj
assert_eq '5173 8123 5174 8080 4254 4500 4600 4700 4800' "$(cat "$STATE_DIR/ports-pp-orphan")"

# The repository places an orphan, never someone else's session: 1001-1009 hang off the other
# claude, and a repository argument must not turn them into this session's servers. 4500 sits under
# a worker of that other session and is just as much theirs.
run_probe pp-orphan-other 9999 /proj
assert_eq '4254' "$(cat "$STATE_DIR/ports-pp-orphan-other")"

# 4-digit PID alignment test: ps right-aligns columns, causing leading spaces.
# Verify the regex handles leading whitespace correctly.
FAKE_PS_4DIG="$FIXTURES/ports-ps-4dig"
cat > "$FAKE_PS_4DIG" <<'PSEOF4'
#!/usr/bin/env bash
cat <<'SNAP'
  999 1 init
 1000 1 claude
 2001 1000 node /path/to/vite
 3002 1000 python3 -m http.server 8127
SNAP
PSEOF4
chmod +x "$FAKE_PS_4DIG"
FAKE_LSOF_4DIG="$FIXTURES/ports-lsof-4dig"
cat > "$FAKE_LSOF_4DIG" <<'LSEOF4'
#!/usr/bin/env bash
cat <<'OUT'
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
python3  3002 u   22u  IPv4  0t0      TCP *:8127 (LISTEN)
OUT
LSEOF4
chmod +x "$FAKE_LSOF_4DIG"
run_probe_4dig() {
  STATUSLINE_PS="$FAKE_PS_4DIG" STATUSLINE_LSOF="$FAKE_LSOF_4DIG" "$PORTS_PROBE" "$1" "$2"
}
run_probe_4dig pp-4dig 2001
assert_eq '8127' "$(cat "$STATE_DIR/ports-pp-4dig")"

# The LLM-tool list is the contract's, and grok is on it again as a worker vendor: its own RPC
# socket leads nowhere a human would go, while a dev server one of its runs started IS the work.
FAKE_PS_TOOLS="$FIXTURES/ports-ps-tools"
cat > "$FAKE_PS_TOOLS" <<'PSEOFT'
#!/usr/bin/env bash
cat <<'SNAP'
1000 1 claude
2100 1000 codex exec
2101 2100 node /srv/rpc-worker.js
2102 1000 grok --prompt-file /tmp/review
2103 2102 node /srv/grok-rpc.js
2104 2102 node /srv/dev.js
SNAP
PSEOFT
chmod +x "$FAKE_PS_TOOLS"
FAKE_LSOF_TOOLS="$FIXTURES/ports-lsof-tools"
cat > "$FAKE_LSOF_TOOLS" <<'LSEOFT'
#!/usr/bin/env bash
cat <<'OUT'
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
node     2101 u   11u  IPv4  0t0      TCP 127.0.0.1:61610 (LISTEN)
node     2103 u   12u  IPv4  0t0      TCP 127.0.0.1:61611 (LISTEN)
node     2104 u   13u  IPv4  0t0      TCP 127.0.0.1:4321 (LISTEN)
OUT
LSEOFT
chmod +x "$FAKE_LSOF_TOOLS"
STATUSLINE_PS="$FAKE_PS_TOOLS" STATUSLINE_LSOF="$FAKE_LSOF_TOOLS" "$PORTS_PROBE" pp-tools 1000
assert_eq '4321' "$(cat "$STATE_DIR/ports-pp-tools")"


run_probe pp-selfroot 9999
assert test -f "$STATE_DIR/ports-pp-selfroot"
assert_eq "" "$(cat "$STATE_DIR/ports-pp-selfroot")"

run_probe pp-noroot 1
assert_eq "" "$(cat "$STATE_DIR/ports-pp-noroot")"

printf '5173\n' > "$STATE_DIR/ports-pp-death"
STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$FAKE_LSOF_EMPTY" "$PORTS_PROBE" pp-death 1001
assert_eq "" "$(cat "$STATE_DIR/ports-pp-death")"

# --- render of the two new segments ---
printf '5173 8080\n' > "$STATE_DIR/ports-r-ports"
rports_out=$(run_statusline "$(statusline_payload r-ports)")
assert grep -Fq "${GREEN}:5173${RESET}" <<< "$rports_out"
assert grep -Fq "${GREEN}:8080${RESET}" <<< "$rports_out"
assert grep -Fq '⇢' <<< "$rports_out"

printf '1 2 3 4 5\n' > "$STATE_DIR/ports-r-cap"
rcap_out=$(run_statusline "$(statusline_payload r-cap)")
assert grep -Fq "${GREEN}:3${RESET}" <<< "$rcap_out"
assert test "${rcap_out#*"${GREEN}:4"}" = "$rcap_out"

printf '' > "$STATE_DIR/ports-r-empty"
rempty_out=$(run_statusline "$(statusline_payload r-empty)")
assert test "${rempty_out#*⇢}" = "$rempty_out"

printf '5173\n' > "$STATE_DIR/ports-r-stale"
touch -t "$(date -r $((NOW - 120)) +%Y%m%d%H%M.%S)" "$STATE_DIR/ports-r-stale"
rstale_out=$(run_statusline "$(statusline_payload r-stale)")
assert test "${rstale_out#*⇢}" = "$rstale_out"

rm -f "$STATE_DIR/ports-r-absent"
rabsent_out=$(run_statusline "$(statusline_payload r-absent)")
assert test "${rabsent_out#*⇢}" = "$rabsent_out"

# End-to-end: the real probe output (written with a trailing newline) renders.
run_probe pp-render 1001
e2e_out=$(run_statusline "$(statusline_payload pp-render)")
assert grep -Fq "${GREEN}:5173${RESET}" <<< "$e2e_out"
assert grep -Fq "${GREEN}:8123${RESET}" <<< "$e2e_out"

# Regression: a newline-less cache still renders (render must not clobber on the
# read's nonzero EOF return).
printf '5173' > "$STATE_DIR/ports-r-nonl"
rnonl_out=$(run_statusline "$(statusline_payload r-nonl)")
assert grep -Fq "${GREEN}:5173${RESET}" <<< "$rnonl_out"

worker_payload() {
  jq -cn --arg type "$1" --arg id "$2" --arg description "$3" --arg command "$4" --arg session "${5:-wt}" '
    {hook_event_name:"PreToolUse",tool_name:"Bash",session_id:$session,agent_type:$type,agent_id:$id,
     tool_input:{command:$command,description:$description,timeout:42}}'
}
TAGDIR="$HOME/.cache/claude-worker-tags/wt"

# A codex launch command derives the tag (main, high), stores it, and prefixes.
seed=$(worker_payload codex-worker worker/one 'Investigate the suite' "codex exec -c model_reasoning_effort=high 'go'")
seed_output=$(printf '%s' "$seed" | "$WORKER_HOOK") || fail "worker seed exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "main · sol · high — Investigate the suite"' <<< "$seed_output" >/dev/null
assert_eq 'main · sol · high' "$(cat "$TAGDIR/workerone")"

# A later non-launch command reuses the stored tag to prefix its description.
later=$(worker_payload codex-worker worker/one 'Run focused tests' 'bash tests/focused.sh')
later_output=$(printf '%s' "$later" | "$WORKER_HOOK") || fail "worker rewrite exited nonzero"
assert jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and
  .hookSpecificOutput.permissionDecision == "allow" and
  .hookSpecificOutput.updatedInput.description == "main · sol · high — Run focused tests" and
  .hookSpecificOutput.updatedInput.command == "bash tests/focused.sh" and
  .hookSpecificOutput.updatedInput.timeout == 42' <<< "$later_output" >/dev/null

# An already-prefixed description is left untouched (no stacking).
prefixed=$(worker_payload codex-worker worker/one 'main · sol · high — Run focused tests' true)
prefixed_output=$(printf '%s' "$prefixed" | "$WORKER_HOOK") || fail "prefixed worker call exited nonzero"
assert_eq "" "$prefixed_output"

# Codex model label follows ~/.codex/config.toml, not a hardcode.
mkdir -p "$HOME/.codex"
printf 'model = "gpt-9-zenith"\n' > "$HOME/.codex/config.toml"
seed_zenith=$(worker_payload codex-worker worker/zenith 'Optimize compute' "codex exec -c model_reasoning_effort=high 'go'")
seed_zenith_out=$(printf '%s' "$seed_zenith" | "$WORKER_HOOK") || fail "zenith seed exited nonzero"
assert_eq 'main · zenith · high' "$(cat "$TAGDIR/workerzenith")"
rm -f "$HOME/.codex/config.toml"

# worker-run wait/report adopt the tag the launcher wrote into its run dir, and
# re-derive it on every call (the launcher may resolve a different account than
# the spawn-time seed predicted).
WRDIR="$HOME/.cache/claude-worker-runs/codex-1-2-abcd"
mkdir -p "$WRDIR"
printf 'work6 · sol · high\n' > "$WRDIR/tag"
wr_wait=$(worker_payload codex-worker worker/wrun 'Wait for the run' 'worker-run wait codex-1-2-abcd --max 500')
wr_out=$(printf '%s' "$wr_wait" | "$WORKER_HOOK") || fail "worker-run wait exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "work6 · sol · high — Wait for the run"' <<< "$wr_out" >/dev/null
assert_eq 'work6 · sol · high' "$(cat "$TAGDIR/workerwrun")"
printf 'work3 · sol · high\n' > "$WRDIR/tag"
wr_report=$(worker_payload codex-worker worker/wrun 'Collect the report' 'worker-run report codex-1-2-abcd')
wr_report_out=$(printf '%s' "$wr_report" | "$WORKER_HOOK") || fail "worker-run report exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "work3 · sol · high — Collect the report"' <<< "$wr_report_out" >/dev/null

# A run id hidden behind a shell variable is unresolvable from command text; the
# hook must degrade to the previously stored tag, not crash or mis-tag.
wr_var=$(worker_payload codex-worker worker/wrun 'Keep waiting' 'worker-run wait "$RUN_ID" --max 100')
wr_var_out=$(printf '%s' "$wr_var" | "$WORKER_HOOK") || fail "worker-run variable-id wait exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "work3 · sol · high — Keep waiting"' <<< "$wr_var_out" >/dev/null

# `worker-run start claudeb ...` names a vendor as an argument, not a launch:
# with no run dir, no stored tag and no pending seed the hook stays silent.
wr_start=$(worker_payload claudeb-worker worker/wrstart 'Launch the run' 'worker-run start claudeb --brief /tmp/b --workdir /x')
wr_start_out=$(printf '%s' "$wr_start" | "$WORKER_HOOK") || fail "worker-run start exited nonzero"
assert_eq "" "$wr_start_out"
assert test ! -f "$TAGDIR/workerwrstart"


# A claudeb launch command derives the 3-part tag.
glob_seed=$(worker_payload claudeb-worker worker/two 'Ship it' 'claudeb profile com -p --model sonnet --effort high')
glob_seed_output=$(printf '%s' "$glob_seed" | "$WORKER_HOOK") || fail "glob-tag seed exited nonzero"
assert_eq 'com · sonnet · high' "$(cat "$TAGDIR/workertwo")"
glob_later=$(worker_payload claudeb-worker worker/two 'Run tests' true)
glob_later_output=$(printf '%s' "$glob_later" | "$WORKER_HOOK") || fail "glob-tag rewrite exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "com · sonnet · high — Run tests"' \
  <<< "$glob_later_output" >/dev/null

# The launcher counts only as a command word, and the wrappers the real launches
# run under (path prefix, timeout, nohup, nice) sit between it and the separator.
for claudeb_launch in \
  'claudeb profile com --model sonnet --effort high -p x' \
  'cd /somewhere && claudeb profile com --model sonnet -p x' \
  '~/.local/bin/claudeb profile com --model sonnet -p x' \
  '"$HOME/.local/bin/claudeb" profile com --model sonnet -p x' \
  'cd /somewhere && timeout 540 ~/.local/bin/claudeb profile com --model sonnet -p x' \
  'nohup claudeb profile com --model sonnet -p x &' \
  'nice -n 5 env CLAUDE_X=1 claudeb profile com --model sonnet -p x' \
  'claudeb profile com --resume abc123 -p continue'; do
  claudeb_form=$(worker_payload claudeb-worker worker/forms 'Resume it' "$claudeb_launch")
  printf '%s' "$claudeb_form" | "$WORKER_HOOK" >/dev/null || fail "claudeb launch form exited nonzero"
  assert grep -q '^com · ' "$TAGDIR/workerforms"
  rm -f "$TAGDIR/workerforms"
done

# The documented codex launch carries its account in a CODEX_HOME assignment,
# which stands between the separator and the command word.
codex_env=$(worker_payload codex-worker worker/cenv 'Ship it' \
  'cd /x && env timeout 600 CODEX_HOME="$HOME/.codex-profiles/alt" codex exec -c model_reasoning_effort=low go')
printf '%s' "$codex_env" | "$WORKER_HOOK" >/dev/null || fail "codex env-prefixed launch exited nonzero"
assert_eq 'alt · sol · low' "$(cat "$TAGDIR/workercenv")"

# A profile name never starts with a hyphen: a malformed launch must fall back to
# the configured account, not tag the flag that followed.
printf 'claudeb_model=opus\nclaudeb_effort=high\n' > "$HOME/.claude/worker-model"
malformed=$(worker_payload claudeb-worker worker/malformed 'Run it' 'claudeb profile --resume abc123 -p x')
printf '%s' "$malformed" | "$WORKER_HOOK" >/dev/null || fail "malformed-profile launch exited nonzero"
assert_eq 'opus · high' "$(cat "$TAGDIR/workermalformed")"

# Heredoc bodies are quoted text, not commands: neither a launch named mid-prose
# nor one at the start of a body line may derive a tag. The pre-seeded pending
# tag stands instead of the quoted word.
PROSEDIR="$HOME/.cache/claude-worker-tags/wt-prose"
for prose_body in \
  'Avoid switching claudeb profile fake mid-switch when you pass -p to it.' \
  'claudeb profile fake --model opus -p "x"'; do
  rm -rf "$PROSEDIR"; mkdir -p "$PROSEDIR"
  printf 'pend · opus · high\n' > "$PROSEDIR/pending-claudeb-worker"
  prose=$(worker_payload claudeb-worker worker/prose 'Save the brief' \
    "cat > /tmp/brief.md <<BRIEF
$prose_body
BRIEF" wt-prose)
  prose_output=$(printf '%s' "$prose" | "$WORKER_HOOK") || fail "prose-quoting call exited nonzero"
  assert_eq 'pend · opus · high' "$(cat "$PROSEDIR/workerprose")"
  assert jq -e '.hookSpecificOutput.updatedInput.description == "pend · opus · high — Save the brief"' \
    <<< "$prose_output" >/dev/null
done

# A real launch that merely feeds itself a heredoc still tags: the cut is at the
# operator, and the launcher precedes it.
heredoc_launch=$(worker_payload claudeb-worker worker/hd 'Ship it' \
  'claudeb profile com --model sonnet -p "$(cat <<BRIEF
do the thing
BRIEF
)"')
printf '%s' "$heredoc_launch" | "$WORKER_HOOK" >/dev/null || fail "heredoc-fed launch exited nonzero"
assert_eq 'com · sonnet · high' "$(cat "$TAGDIR/workerhd")"

printf 'claudeb_model=opus\nclaudeb_effort=high\n' > "$HOME/.claude/worker-model"
unknown_spawn=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-claudeb-unknown",
  tool_input:{subagent_type:"claudeb-worker",description:"Implement fixture",
              prompt:"MODEL: opus\nEFFORT: high\nWorking directory: /tmp"}}')
unknown_spawn_out=$(printf '%s' "$unknown_spawn" | "$SPAWN_HOOK") || fail "unknown-account spawn hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "opus · high: Implement fixture"' \
  <<<"$unknown_spawn_out" >/dev/null
assert_eq 'opus · high' \
  "$(cat "$HOME/.cache/claude-worker-tags/spawn-claudeb-unknown/pending-claudeb-worker")"

unknown_tag=$(worker_payload claudeb-worker worker/unknown 'Run it' 'claudeb --model opus -p task')
unknown_tag_out=$(printf '%s' "$unknown_tag" | "$WORKER_HOOK") || fail "unknown-account tag hook exited nonzero"
assert_eq 'opus · high' "$(cat "$TAGDIR/workerunknown")"
assert jq -e '.hookSpecificOutput.updatedInput.description == "opus · high — Run it"' \
  <<<"$unknown_tag_out" >/dev/null

gemini_seed=$(worker_payload gemini-worker worker/gemini 'Implement it' \
  "$HOME/.local/bin/geminib profile work --model gemini-3.6-flash --effort medium --print-timeout 20m --dangerously-skip-permissions --print task")
gemini_seed_output=$(printf '%s' "$gemini_seed" | "$WORKER_HOOK") || fail "gemini-tag seed exited nonzero"
assert_eq 'work · flash36 · medium' "$(cat "$TAGDIR/workergemini")"
assert jq -e '.hookSpecificOutput.updatedInput.description == "work · flash36 · medium — Implement it"' \
  <<< "$gemini_seed_output" >/dev/null

for gemini_launch in \
  'geminib p short --model gemini-3.6-flash --effort medium --print task' \
  'geminib run routed --model gemini-3.6-flash --effort medium --print task' \
  'geminib direct exec --model gemini-3.6-flash --effort medium --print task'; do
  gemini_form=$(worker_payload gemini-worker worker/gemini 'Resume it' "$gemini_launch")
  gemini_form_output=$(printf '%s' "$gemini_form" | "$WORKER_HOOK") \
    || fail "gemini shorthand tag exited nonzero"
  expected_account=$(printf '%s\n' "$gemini_launch" | awk '{if ($2 == "p" || $2 == "run") print $3; else print $2}')
  assert_eq "$expected_account · flash36 · medium" "$(cat "$TAGDIR/workergemini")"
  assert jq -e --arg account "$expected_account" \
    '.hookSpecificOutput.updatedInput.description == ($account + " · flash36 · medium — Resume it")' \
    <<<"$gemini_form_output" >/dev/null
done

grok_seed=$(worker_payload grok-worker worker/grok 'Implement it' \
  "env GROK_MEMORY=0 $HOME/.local/bin/grokb profile supergrok --prompt-file /tmp/brief --output-format streaming-json -m grok-4.6 --reasoning-effort xhigh")
grok_seed_output=$(printf '%s' "$grok_seed" | "$WORKER_HOOK") || fail "grok-tag seed exited nonzero"
assert_eq 'supergrok · grok · xhigh' "$(cat "$TAGDIR/workergrok")"
assert jq -e '.hookSpecificOutput.updatedInput.description == "supergrok · grok · xhigh — Implement it"' \
  <<< "$grok_seed_output" >/dev/null

# The knobs answer for what the launch line leaves out, exactly as they do for the other vendors.
printf 'grok_model=grok-4.5\ngrok_effort=medium\n' > "$HOME/.claude/worker-model"
for grok_launch in \
  'grokb profile routed --prompt-file /tmp/brief' \
  'grokb p short --prompt-file /tmp/brief' \
  'grokb run rerouted --prompt-file /tmp/brief' \
  'grokb direct exec --prompt-file /tmp/brief'; do
  grok_form=$(worker_payload grok-worker worker/grok 'Resume it' "$grok_launch")
  grok_form_output=$(printf '%s' "$grok_form" | "$WORKER_HOOK") || fail "grok shorthand tag exited nonzero"
  expected_account=$(printf '%s\n' "$grok_launch" | awk '{if ($2 == "p" || $2 == "run" || $2 == "profile") print $3; else print $2}')
  assert_eq "$expected_account · grok-4.5 · medium" "$(cat "$TAGDIR/workergrok")"
  assert jq -e --arg account "$expected_account" \
    '.hookSpecificOutput.updatedInput.description == ($account + " · grok-4.5 · medium — Resume it")' \
    <<<"$grok_form_output" >/dev/null
done

# `auto` never reaches a tag: the vendor word stands in, like codex's `sol`.
printf 'grok_model=auto\ngrok_effort=high\n' > "$HOME/.claude/worker-model"
grok_auto_form=$(worker_payload grok-worker worker/grok 'Resume it' 'grokb profile routed --prompt-file /tmp/brief')
grok_auto_form_output=$(printf '%s' "$grok_auto_form" | "$WORKER_HOOK") || fail "grok auto tag exited nonzero"
assert_eq 'routed · grok · high' "$(cat "$TAGDIR/workergrok")"
assert jq -e '.hookSpecificOutput.updatedInput.description == "routed · grok · high — Resume it"' \
  <<<"$grok_auto_form_output" >/dev/null

# A grokb line that prints nothing headless is the human at the keyboard, and derives no tag.
rm -f "$TAGDIR/workergrokint"
grok_interactive=$(worker_payload grok-worker worker/grokint 'Look around' 'grokb profile supergrok models')
grok_interactive_output=$(printf '%s' "$grok_interactive" | "$WORKER_HOOK") \
  || fail "grok interactive tag exited nonzero"
assert test ! -e "$TAGDIR/workergrokint"
assert_eq "" "$grok_interactive_output"

printf 'grok_model=auto\ngrok_effort=high\n' > "$HOME/.claude/worker-model"
grok_spawn=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-grok",
  tool_input:{subagent_type:"grok-worker",description:"Implement fixture",
              prompt:"ACCOUNT: supergrok\nMODEL: grok-4.6\nEFFORT: high\nWorking directory: /tmp"}}')
grok_spawn_output=$(printf '%s' "$grok_spawn" | "$SPAWN_HOOK") || fail "grok spawn hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "supergrok · grok · high: Implement fixture"' \
  <<< "$grok_spawn_output" >/dev/null
assert_eq 'supergrok · grok · high' \
  "$(cat "$HOME/.cache/claude-worker-tags/spawn-grok/pending-grok-worker")"

# No MODEL: line and grok_model=auto — the row says the vendor, not the knob word.
grok_auto_spawn=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-grok-auto",
  tool_input:{subagent_type:"grok-worker",description:"Implement fixture",
              prompt:"ACCOUNT: supergrok\nEFFORT: high\nWorking directory: /tmp"}}')
grok_auto_output=$(printf '%s' "$grok_auto_spawn" | "$SPAWN_HOOK") || fail "grok auto spawn hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "supergrok · grok · high: Implement fixture"' \
  <<< "$grok_auto_output" >/dev/null
assert_eq 'supergrok · grok · high' \
  "$(cat "$HOME/.cache/claude-worker-tags/spawn-grok-auto/pending-grok-worker")"

printf 'gemini_model=pro\ngemini_effort=high\n' > "$HOME/.claude/worker-model"
spawn_payload=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-gemini",
  tool_input:{subagent_type:"gemini-worker",description:"Implement fixture",
              prompt:"ACCOUNT: second\nMODEL: flash\nEFFORT: medium\nWorking directory: /tmp"}}')
spawn_output=$(printf '%s' "$spawn_payload" | "$SPAWN_HOOK") || fail "gemini spawn hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "second · flash36 · medium: Implement fixture"' \
  <<< "$spawn_output" >/dev/null
assert_eq 'second · flash36 · medium' \
  "$(cat "$HOME/.cache/claude-worker-tags/spawn-gemini/pending-gemini-worker")"

# A stored tag carrying regex-special chars is matched literally, so an
# already-prefixed description never stacks.
mkdir -p "$TAGDIR"; printf 'com [1m] · high\n' > "$TAGDIR/workerbr"
br=$(worker_payload claudeb-worker worker/br 'com [1m] · high — Run tests' true)
br_output=$(printf '%s' "$br" | "$WORKER_HOOK") || fail "bracket-tag idempotent call exited nonzero"
assert_eq "" "$br_output"

no_agent=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_id:"workerone",tool_input:{command:"true",description:"Run"}}')
no_agent_output=$(printf '%s' "$no_agent" | "$WORKER_HOOK") || fail "no-agent call exited nonzero"
assert_eq "" "$no_agent_output"

wrong_event=$(worker_payload codex-worker worker/three 'Worker account: alt · high' true | jq -c '.hook_event_name = "PostToolUse"')
wrong_event_output=$(printf '%s' "$wrong_event" | "$WORKER_HOOK") || fail "non-PreToolUse seed exited nonzero"
assert_eq "" "$wrong_event_output"
assert test ! -e "$HOME/.cache/claude-worker-tags/workerthree"

wrong_rewrite=$(worker_payload codex-worker worker/one 'Run more tests' true | jq -c '.hook_event_name = "SessionStart"')
wrong_rewrite_output=$(printf '%s' "$wrong_rewrite" | "$WORKER_HOOK") || fail "non-PreToolUse rewrite exited nonzero"
assert_eq "" "$wrong_rewrite_output"

broken_output=$(printf '{broken' | "$WORKER_HOOK") || fail "broken JSON exited nonzero"
assert_eq "" "$broken_output"

REVIEW_DIRTY="$FIXTURES/review-dirty"
mkdir -p "$REVIEW_DIRTY"
git -C "$REVIEW_DIRTY" init -q -b main
printf 'base\n' > "$REVIEW_DIRTY/tracked.txt"
git -C "$REVIEW_DIRTY" add tracked.txt
git -C "$REVIEW_DIRTY" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
printf 'line\n%.0s' {1..21} > "$REVIEW_DIRTY/change.txt"
TOP_REVIEW_DIRTY=$(cd "$REVIEW_DIRTY" && pwd -P)
review_rev_delimited=" ${DIM}│${RESET} ${DIM}rev"
# The gate's verdict and a run's own counter wear ONE word, so a case proving the slot silent rules
# out that word in each of its three colourings; the fixture repository is itself named
# review-dirty, so a bare word cannot be searched for.
review_slot_silent() { # rendered
  # The word with its trailing space: the shown tree can be a folder whose own name starts with it
  # (`review-clean`), and that folder sits right after a separator once the block moves there.
  case "$1" in
    *" ${DIM}│${RESET} ${DIM}rev "*|*" ${DIM}│${RESET} ${RED}rev "*|*" ${DIM}│${RESET} rev "*)
      return 1 ;;
  esac
  return 0
}

# The segment is the commit gate's mouthpiece and nothing else: it runs
# `review-flow-gate.sh verdict <toplevel> <session>` and prints the line that comes back, coloured
# by the style word and truncated to fit, never re-decided here. A stub gate answers the rendering
# cases; the real hook answers the parity case at the end, so the two can be seen not to have
# drifted apart — which is the whole point of the label speaking with the gate's voice.
GATE_LOG="$WORK/gate.log"
GATE_STUB="$FIXTURES/gate-stub.sh"
cat > "$GATE_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GATE_LOG"
# The two session-wide verbs answer from their own variables. `debt-total` answers a real `0` by
# default, because the cases below are about the VERDICT alone and an unreadable total is no longer
# silent — it is the third state `?`, which would stand in every one of them.
case "$1" in
  autonomous) printf '%s\n' "${GATE_AUTONOMOUS-}"; exit "${GATE_VERB_RC:-0}" ;;
  # The rendered tree is part of the question, so a caller that drops it gets no number at all.
  debt-total) [ -n "${3:-}" ] || exit 1; printf '%s\n' "${GATE_TOTAL-}"; exit "${GATE_VERB_RC:-0}" ;;
esac
printf '%s\n' "$GATE_ANSWER"
exit "${GATE_RC:-0}"
STUB
chmod +x "$GATE_STUB"
export GATE_LOG GATE_ANSWER GATE_RC GATE_AUTONOMOUS GATE_TOTAL GATE_VERB_RC
GATE_ANSWER=off
GATE_RC=0
GATE_AUTONOMOUS=
GATE_TOTAL=0
GATE_VERB_RC=0
GATE_CMD="$GATE_STUB"

# The verdict is cached for 15s on a key that cannot see a second edit to an already-modified file
# or a stub told to answer differently; every case here drops it and asks again.
#
# Two renders per case, because the gate is never asked on the render path: the first starts the
# refresh and shows whatever stood before it, the second reads what landed. A render that returned
# the answer straight away would be one waiting a second for git on every prompt.
# Each tree the render asks about caches under its own name: the session's, plus this suffix for a
# tree the block has moved to, so the two answers cannot serve each other's key.
away_tag() { # toplevel
  local key
  key=$(printf '%s' "$1" | cksum)
  printf '%s' "${key// /-}"
}
review_await_session() { # session
  local file="$STATE_DIR/review-session-$1" i
  for i in $(seq 1 100); do
    [ -s "$file" ] && [ ! -d "$file.lock" ] && return 0
    sleep 0.05
  done
  fail "the backgrounded session answer never landed: $1"
}
review_await_verdict() { # session [away-toplevel]
  local file="$STATE_DIR/review-class-$1" i
  [ -n "${2:-}" ] && file="$file-$(away_tag "$2")"
  for i in $(seq 1 100); do
    [ -s "$file" ] && [ ! -d "$file.lock" ] && return 0
    sleep 0.05
  done
  fail "the backgrounded verdict never landed: $1"
}
review_render() { # session repo [away-toplevel]
  local payload
  rm -f "$STATE_DIR/review-class-$1"
  rmdir "$STATE_DIR/review-class-$1.lock" 2>/dev/null
  if [ -n "${3:-}" ]; then
    rm -f "$STATE_DIR/review-class-$1-$(away_tag "$3")"
    rmdir "$STATE_DIR/review-class-$1-$(away_tag "$3").lock" 2>/dev/null
  fi
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "review render failed: $1"
  review_await_verdict "$1" "${3:-}"
  run_statusline "$payload" || fail "review render failed: $1"
}
# The session-wide pair lands in its own cache, so a case that reads it has to wait for that file
# too — the second render is only allowed to be the one that shows the answer.
review_session_render() { # session repo
  local payload
  rm -f "$STATE_DIR/review-class-$1" "$STATE_DIR/review-session-$1"
  rmdir "$STATE_DIR/review-class-$1.lock" "$STATE_DIR/review-session-$1.lock" 2>/dev/null
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "review session render failed: $1"
  review_await_verdict "$1"
  review_await_session "$1"
  run_statusline "$payload" || fail "review session render failed: $1"
}

# The gate is asked about the working tree and this chat, and its answer is printed word for word.
: > "$GATE_LOG"
GATE_ANSWER='dim rev 3'
GATE_RC=0
review_none_out=$(review_render review-dirty "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} ${DIM}rev 3${RESET}" <<< "$review_none_out"
assert grep -Fqx "verdict $TOP_REVIEW_DIRTY review-dirty" "$GATE_LOG"

# Debt this chat authored reads bright — normal weight, no colour of its own — and dim is
# everyone else's. Both carry the count verbatim; the segment neither invents a number nor strips
# one, and the number is diff lines, which is the gate's business and not the render's.
GATE_ANSWER='bright rev 2'
review_mine_out=$(review_render review-mine "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} rev 2" <<< "$review_mine_out"
assert test "${review_mine_out#*"${DIM}rev"}" = "$review_mine_out"
assert test "${review_mine_out#*"${RED}rev"}" = "$review_mine_out"

# Both sides standing is ONE segment in two tones: this chat's own up to the slash at normal
# weight, everyone else's from the slash dimmed. Two labels would ask the reader to add them up.
GATE_ANSWER='split rev 12/34'
review_split_out=$(review_render review-split "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} rev 12${DIM}/34${RESET}" <<< "$review_split_out"
assert test "${review_split_out#*"${DIM}rev 12"}" = "$review_split_out"
assert test "${review_split_out#*"${RED}rev"}" = "$review_split_out"
# Truncation can eat the slash, and then the whole text stands at the near weight rather than
# being printed once per side.
GATE_ANSWER='split rev 123456789012345678/9'
review_split_long_out=$(review_render review-split-long "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} rev 123456789012345…" <<< "$review_split_long_out"
assert test "${review_split_long_out#*"${DIM}/"}" = "$review_split_long_out"

# The watchdog has no voice here at all: a killed run settles nothing, so its paths stand in the
# numbers like any others and the kill is seen through the report flow and `review-bench doctor`
# (review-bench docs/review-contract.md). No word of the gate's own vocabulary is red, and a nonzero exit is
# the gate answering rather than the gate failing.
GATE_RC=2
review_calm_n=0
for review_calm in 'off' 'dim rev 3' 'bright rev 2' 'split rev 12/34'; do
  review_calm_n=$((review_calm_n + 1))
  GATE_ANSWER="$review_calm"
  review_calm_out=$(review_render "review-calm-$review_calm_n" "$REVIEW_DIRTY")
  assert test "${review_calm_out#*"${RED}rev"}" = "$review_calm_out"
  assert test "${review_calm_out#*●}" = "$review_calm_out"
  assert test "${review_calm_out#*timeout}" = "$review_calm_out"
done
GATE_RC=0

# `off` is the gate having nothing to say, and the segment says nothing.
GATE_ANSWER=off
review_off_out=$(review_render review-off "$REVIEW_DIRTY")
assert review_slot_silent "$review_off_out"

# A style this build does not know is still an answer: shown loud and whole, never swallowed. A
# gate that grows a fifth word must not go silent in the label that speaks for it — red is left
# for exactly that, and the gate's own vocabulary never reaches it.
GATE_ANSWER='held because'
review_unknown_out=$(review_render review-unknown "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} ${RED}held because${RESET}" <<< "$review_unknown_out"

# A gate that answers nothing, and a gate that is not there at all: both silent. The segment may
# never invent a verdict where the one thing that decides it could not be reached.
GATE_ANSWER=''
GATE_RC=1
review_empty_out=$(review_render review-empty "$REVIEW_DIRTY")
assert review_slot_silent "$review_empty_out"
GATE_CMD="$FIXTURES/no-such-gate.sh"
GATE_ANSWER='dim rev 3'
GATE_RC=0
review_nogate_out=$(review_render review-nogate "$REVIEW_DIRTY")
assert review_slot_silent "$review_nogate_out"
GATE_CMD="$GATE_STUB"

# Truncation is the one thing done to the text, and it is display only.
GATE_ANSWER='dim rev 3 and a sentence nobody expected'
review_long_out=$(review_render review-long "$REVIEW_DIRTY")
assert grep -Fq "rev 3 and a sentenc…" <<< "$review_long_out"
assert test "${review_long_out#*nobody}" = "$review_long_out"

# Asked once per key, not once per render: this runs on every prompt, and the gate's verdict mode
# reads git and review-bench. A second render with nothing moved must come off the cache.
GATE_ANSWER='dim rev 3'
rm -f "$STATE_DIR/review-class-review-cache" "$STATE_DIR/review-session-review-cache"
: > "$GATE_LOG"
run_statusline "$(statusline_payload review-cache "" "$REVIEW_DIRTY")" >/dev/null ||
  fail "review cache first render failed"
review_await_verdict review-cache
review_await_session review-cache
run_statusline "$(statusline_payload review-cache "" "$REVIEW_DIRTY")" >/dev/null ||
  fail "review cache second render failed"
assert_eq 1 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
# And asked again the moment the commit journal moves: the gate reads this chat's pending paths out
# of it, so an entry appended there changes the verdict with nothing in `git status` moving at all.
review_gitdir=$(git -C "$REVIEW_DIRTY" rev-parse --absolute-git-dir)
printf 'review-cache\t1750000000\tchange.txt\0' > "$review_gitdir/claude-commit-journal"
run_statusline "$(statusline_payload review-cache "" "$REVIEW_DIRTY")" >/dev/null ||
  fail "review cache third render failed"
review_await_verdict review-cache
assert_eq 2 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
# A recorded review decision changes no Git state or commit journal, so its family clock must
# invalidate the answer immediately rather than leave the old class behind until the TTL.
review_clock="$review_gitdir/claude-review-clock"
touch -t 202001010000 "$review_clock"
run_statusline "$(statusline_payload review-cache "" "$REVIEW_DIRTY")" >/dev/null ||
  fail "review decision-clock render failed"
review_await_verdict review-cache
assert_eq 3 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
# The pair beside it is about the CHAT, so nothing a tree does moves its key: three re-asked
# verdicts later it is still the one answer the first render fetched, and its own 15s TTL is the
# only thing that will ever ask again.
assert_eq 1 "$(grep -c '^autonomous ' "$GATE_LOG" | tr -d ' ')"
assert_eq 1 "$(grep -c '^debt-total ' "$GATE_LOG" | tr -d ' ')"
# The total is asked about the chat AND the tree being rendered: the gate counts that repository
# whether or not this chat's repository list names it, which is what keeps a `0` from standing
# beside a repository row that is not 0.
assert grep -Fqx "debt-total review-cache $TOP_REVIEW_DIRTY" "$GATE_LOG"
rm -f "$review_gitdir/claude-commit-journal" "$review_clock"

# Nothing is spawned behind the label beyond that one read-only ask: a background review-bench per
# render is what the tier number used to cost, and a cache file keyed on a chat and its path set is
# that probe still running.
rm -f "$HOME/.cache/claude-statusline"/review-tier-*
review_render review-dirty "$REVIEW_DIRTY" >/dev/null
sleep 1
asserts=$((asserts + 1))
test -z "$(ls "$HOME/.cache/claude-statusline"/review-tier-* 2>/dev/null)" ||
  fail "the review segment still spawned a probe: $(ls "$HOME/.cache/claude-statusline")"

# The label sits after the repository cluster and before the workers.
GATE_ANSWER='dim rev 3'
worker_order_file="$HOME/.claude/worker-model"
worker_order_saved=$(cat "$worker_order_file" 2>/dev/null)
printf 'worker=sonnet\n' > "$worker_order_file"
review_order_line=$(review_render review-order "$REVIEW_DIRTY")
review_order_line="${review_order_line%%$'\n'*}"
review_before="${review_order_line%%"$review_rev_delimited"*}"
review_after="${review_order_line#*"$review_rev_delimited"}"
assert grep -Fq "$(basename "$REVIEW_DIRTY")" <<< "$review_before"
assert test "${review_before#*"$WORKER_MARK"}" = "$review_before"
assert grep -Fq "$WORKER_MARK" <<< "$review_after"
printf '%s' "$worker_order_saved" > "$worker_order_file"

# A port belongs to the project and its diff, not to a review of it, so it takes the slot right
# after the repository cluster and the review label follows it.
printf '5173\n' > "$STATE_DIR/ports-r-order"
rorder_out=$(review_render r-order "$REVIEW_DIRTY")
assert grep -Fq ":5173" <<< "$rorder_out"
assert grep -Fq "$review_rev_delimited" <<< "$rorder_out"
# Cut on the delimited segment, not on the bare word: this fixture repository is itself named
# review-dirty, and its own label would answer first.
assert grep -Fq ":5173" <<< "${rorder_out%%"$review_rev_delimited"*}"
rm -f "$STATE_DIR/ports-r-order"

# --- the autonomous marker and the session-wide total ---------------------------------------
# Two more answers from the same gate, about the CHAT and not the tree: `autonomous <sid>` says
# whether this chat commits on its own, and `debt-total <sid>` sums the unreviewed lines over every
# repository it touched. Both are the gate's alone — nothing here counts anything — and a gate that
# does not know the verbs leaves the segment exactly as it was.
review_seg=" ${DIM}│${RESET} "
GATE_RC=0
GATE_VERB_RC=0

# `no` is the shape everything above already renders: the word stands and no dot appears.
GATE_ANSWER='bright rev 7'
GATE_AUTONOMOUS=no
GATE_TOTAL=
review_auto_off_out=$(review_session_render review-auto-off "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}rev 7" <<< "$review_auto_off_out"
assert test "${review_auto_off_out#*●}" = "$review_auto_off_out"

# `yes` puts a bare dot where the word was — the chat that reviews itself is the one fact a reader
# needs before believing the number beside it.
GATE_AUTONOMOUS=yes
review_auto_on_out=$(review_session_render review-auto-on "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● 7" <<< "$review_auto_on_out"
assert test "${review_auto_on_out#*"${review_seg}rev"}" = "$review_auto_on_out"

# Split keeps both weights and the dot keeps none of them: it is bright beside a dimmed foreign side.
GATE_ANSWER='split rev 7/12'
review_auto_split_out=$(review_session_render review-auto-split "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● 7${DIM}/12${RESET}" <<< "$review_auto_split_out"
assert test "${review_auto_split_out#*"${DIM}●"}" = "$review_auto_split_out"

# Fit step 7 takes the space with the word: `● 7` folds to `●7`, as `rev 7` folds to `r7`.
review_auto_fit_out=$(FIT_COLUMNS=24 review_session_render review-auto-fit "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}●7${DIM}/12${RESET}" <<< "$review_auto_fit_out"

# The style the live chat that went unmarked actually shows: another chat's debt alone, dimmed. The
# dot belongs to this build and not to the gate's number, so it stays bright beside a dim one, and
# the bar between the two numbers is the separator's own grey with every colour closed around it —
# the style may reach the numbers and nothing else, and the segment must not bleed into the `│`
# after it.
GATE_ANSWER='dim rev 267'
GATE_AUTONOMOUS=yes
GATE_TOTAL=30
worker_dim_saved=$(cat "$HOME/.claude/worker-model" 2>/dev/null)
printf 'worker=sonnet\n' > "$HOME/.claude/worker-model"
review_dim_auto_out=$(review_session_render review-dim-auto "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● ${DIM}267${RESET} ${DIM}|${RESET} 30 ${DIM}│${RESET} " <<< "$review_dim_auto_out"
assert test "${review_dim_auto_out#*"${DIM}●"}" = "$review_dim_auto_out"
printf '%s' "$worker_dim_saved" > "$HOME/.claude/worker-model"

# The total follows the repository's own number at the same weight, behind a bar.
GATE_ANSWER='bright rev 7'
GATE_AUTONOMOUS=no
GATE_TOTAL=648
review_total_out=$(review_session_render review-total "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}rev 7 ${DIM}|${RESET} 648" <<< "$review_total_out"
review_total_fit_out=$(FIT_COLUMNS=24 review_session_render review-total-fit "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}r7${DIM}|${RESET}648" <<< "$review_total_fit_out"

# A one-sided `dim` verdict is somebody else's number: this chat's own share of the repository is 0,
# so a total of 0 beside it adds nothing and `rev 60 | 0` is the comparison reading a foreign count
# as this chat's. A total above that 0 is lines owed in other repositories and does show.
GATE_ANSWER='dim rev 60'
GATE_AUTONOMOUS=no
GATE_TOTAL=0
review_dim_zero_out=$(review_session_render review-dim-zero "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}rev 60${RESET}" <<< "$review_dim_zero_out"
assert test "${review_dim_zero_out#*"${DIM}rev 60${RESET} ${DIM}|"}" = "$review_dim_zero_out"
GATE_TOTAL=5
review_dim_more_out=$(review_session_render review-dim-more "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}rev 60${RESET} ${DIM}|${RESET} 5" <<< "$review_dim_more_out"

# A total equal to what this chat owes here is that number said twice, and the segment says it once:
# the repository the reader is looking at is then the only one this chat owes anything in. Compared
# against the OWN side, so a split whose own number is the whole total loses the bar too.
GATE_ANSWER='bright rev 7'
GATE_TOTAL=7
review_same_out=$(review_session_render review-total-same "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}rev 7" <<< "$review_same_out"
assert test "${review_same_out#*"${review_seg}rev 7 ${DIM}|"}" = "$review_same_out"
# Below it says even less: a total that does not reach what this chat owes here names no other
# repository, so the bar is the strict `greater than` and not a difference.
GATE_TOTAL=3
review_below_out=$(review_session_render review-total-below "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}rev 7" <<< "$review_below_out"
assert test "${review_below_out#*"${review_seg}rev 7 ${DIM}|"}" = "$review_below_out"
GATE_TOTAL=7
GATE_ANSWER='split rev 7/12'
review_same_split_out=$(review_session_render review-total-same-split "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}rev 7${DIM}/12${RESET}" <<< "$review_same_split_out"
assert test "${review_same_split_out#*"${DIM}/12${RESET} ${DIM}|"}" = "$review_same_split_out"
GATE_TOTAL=648

# Both additions at once, dimming only what the gate dimmed.
GATE_ANSWER='split rev 7/12'
GATE_AUTONOMOUS=yes
review_both_out=$(review_session_render review-both "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● 7${DIM}/12${RESET} ${DIM}|${RESET} 648" <<< "$review_both_out"
review_both_fit_out=$(FIT_COLUMNS=24 review_session_render review-both-fit "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}●7${DIM}/12${RESET}${DIM}|${RESET}648" <<< "$review_both_fit_out"

# Nothing owed in THIS repository is not nothing owed by this chat: the word carries the total alone.
GATE_ANSWER=off
GATE_AUTONOMOUS=no
review_off_total_out=$(review_session_render review-off-total "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}rev ${DIM}|${RESET} 648" <<< "$review_off_total_out"
review_off_total_fit_out=$(FIT_COLUMNS=24 review_session_render review-off-total-fit "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}r${DIM}|${RESET}648" <<< "$review_off_total_fit_out"

# Owing nothing anywhere is the empty slot it has always been.
GATE_TOTAL=0
review_zero_out=$(review_session_render review-zero "$REVIEW_DIRTY")
assert review_slot_silent "$review_zero_out"

# Only a bare non-negative integer is a total. Anything else — the gate's own `unknown`, a word, a
# negative, an empty line, a `timeout` kill — is nobody having answered, which is neither a number
# this segment may invent nor the `0` that would read as a clean bill. It stands as `?`.
GATE_ANSWER='bright rev 7'
review_junk_n=0
for review_total_junk in '648 lines' '-3' 'none' 'unknown' ''; do
  GATE_TOTAL="$review_total_junk"
  review_junk_out=$(review_session_render "review-total-junk-$((++review_junk_n))" "$REVIEW_DIRTY")
  assert grep -Fq "${review_seg}rev 7 ${DIM}|${RESET} ?" <<< "$review_junk_out"
done

# A gate that is THERE and cannot answer the verbs — nothing on stdout, nonzero exit — is
# indistinguishable from one whose `debt-total` timed out, so it is an outage and says so: the
# repository's own numbers stand and the total beside them is `?`. Only a gate that is not
# installed at all leaves the slot as it was before either verb (the `no-such-gate` case above).
# The dot still needs a `yes` nobody gave, so no marker appears.
GATE_ANSWER='split rev 12/34'
GATE_AUTONOMOUS=
GATE_TOTAL=
GATE_VERB_RC=1
review_stub_out=$(review_session_render review-stub-verbs "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}rev 12${DIM}/34${RESET} ${DIM}|${RESET} ?" <<< "$review_stub_out"
assert test "${review_stub_out#*●}" = "$review_stub_out"
GATE_VERB_RC=0
GATE_ANSWER=off

# --- the third state: a number, `off`, and `rev ?` --------------------------------------------
# `off` is the gate answering "nothing is owed"; `?` is nobody having answered — its library down, a
# member repository that failed, a `timeout` kill, an answer that outlived the 120s sweep. Rendered
# as `off`, or as no segment at all, an outage reaches Egor as a clean bill.

# The gate's own outage word, where the repository itself owes nothing: the segment is a state, not
# a gap. Proves R5's `unknown` reaches the render instead of stopping at the gate.
GATE_ANSWER=off
GATE_AUTONOMOUS=no
GATE_TOTAL=unknown
review_unknown_out=$(review_session_render review-unknown-total "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}rev ?${RESET}" <<< "$review_unknown_out"
# And a chat that commits on its own keeps its marker in front of it, as it does before a number.
GATE_AUTONOMOUS=yes
review_unknown_auto_out=$(review_session_render review-unknown-auto "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● ${DIM}?${RESET}" <<< "$review_unknown_auto_out"

# A gate answering `0` says nothing is owed anywhere, which is the empty slot and never a `?`.
# Proves the two states did not collapse into one the moment the third was added.
GATE_AUTONOMOUS=no
GATE_TOTAL=0
review_zero_state_out=$(review_session_render review-zero-state "$REVIEW_DIRTY")
assert review_slot_silent "$review_zero_state_out"
assert test "${review_zero_state_out#*"rev ?"}" = "$review_zero_state_out"

# A verdict cached before the 120s sweep is an answer about a tree two minutes ago, which for a
# number Egor acts on is no answer at all. Backdated with the session pair left fresh, so the `?`
# can only have come from the verdict's own staleness. Proves a stale answer is not a clean bill.
GATE_ANSWER='bright rev 7'
GATE_TOTAL=0
review_stale_payload=$(statusline_payload review-stale "" "$REVIEW_DIRTY")
rm -f "$STATE_DIR/review-class-review-stale" "$STATE_DIR/review-session-review-stale"
run_statusline "$review_stale_payload" >/dev/null || fail "stale verdict first render failed"
review_await_verdict review-stale
review_await_session review-stale
touch -t 202001010000 "$STATE_DIR/review-class-review-stale"
review_stale_out=$(run_statusline "$review_stale_payload") || fail "stale verdict render failed"
assert grep -Fq "${review_seg}${DIM}rev ?${RESET}" <<< "$review_stale_out"
assert test "${review_stale_out#*"${review_seg}rev 7"}" = "$review_stale_out"
GATE_ANSWER=off

# --- the real gate, so the two answers cannot drift apart -----------------------------------
# The stub above proves the rendering; this proves the wiring against the hook that actually
# answers for a commit. An unreadable neighbour is a FAIL naming CLAUDE_SETUP_ROOT, never a skip:
# a silent green here is the drift this block exists to catch.
REAL_GATE="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/review-flow-gate.sh"
if [ -x "$REAL_GATE" ]; then
  GATE_CMD="$REAL_GATE"
  GATE_BIN="$FIXTURES/gate-bin"
  mkdir -p "$GATE_BIN"
  cat > "$GATE_BIN/review-bench" <<'RB'
#!/bin/bash
# The verdict asks the split question and nothing else; the classic line is what every other
# caller of this reader gets, and answering it here would hide the gate asking the wrong one.
for rb_arg in "$@"; do
  [ "$rb_arg" = --split ] && { printf '%s\n' "${SESSION_REVIEW_ANSWER:-split 0 0 0}"; exit 0; }
done
printf 'none\n'
RB
  chmod +x "$GATE_BIN/review-bench"
  # The gate answers for the chat's own uncommitted work, which it reads out of the commit journal
  # this render's cache key watches; a chat that owns nothing there gets `off` from the same run.
  review_real_render() ( # session debt-answer
    export SESSION_REVIEW_ANSWER="$2" PATH="$GATE_BIN:$PATH"
    printf '%s\t1750000000\tchange.txt\0' "$1" > "$review_gitdir/claude-commit-journal"
    review_render "$1" "$REVIEW_DIRTY"
  )
  real_objects_before=$(find "$REVIEW_DIRTY/.git/objects" -type f | wc -l | tr -d ' ')
  review_real_other_out=$(review_real_render review-real 'split 0 4 0')
  assert grep -Fq " ${DIM}│${RESET} ${DIM}rev 4${RESET}" <<< "$review_real_other_out"
  review_real_mine_out=$(review_real_render review-real-mine 'split 1 0 0')
  assert grep -Fq " ${DIM}│${RESET} rev 1" <<< "$review_real_mine_out"
  # Both sides survive the whole chain in the two weights, and debt nobody recorded rides with the
  # foreign number rather than reading as this chat's.
  review_real_split_out=$(review_real_render review-real-split 'split 2 3 0')
  assert grep -Fq " ${DIM}│${RESET} rev 2${DIM}/3${RESET}" <<< "$review_real_split_out"
  review_real_orphan_out=$(review_real_render review-real-orphan 'split 2 0 3')
  assert grep -Fq " ${DIM}│${RESET} rev 2${DIM}/3${RESET}" <<< "$review_real_orphan_out"
  review_real_nobody_out=$(review_real_render review-real-nobody 'split 0 0 5')
  assert grep -Fq " ${DIM}│${RESET} ${DIM}rev 5${RESET}" <<< "$review_real_nobody_out"
  # A repository owing lines nowhere says nothing, whatever its paths.
  review_real_zero_out=$(review_real_render review-real-zero 'split 0 0 0')
  assert review_slot_silent "$review_real_zero_out"
  # Nothing is in debt, so the gate has nothing to say about it.
  rm -f "$review_gitdir/claude-commit-journal"
  review_real_off_out=$(PATH="$GATE_BIN:$PATH" review_render review-real-off "$REVIEW_DIRTY")
  assert review_slot_silent "$review_real_off_out"
  # Asking is read-only: no object is written into the repository, and the commit notice this chat
  # never triggered leaves no marker behind.
  assert_eq "$real_objects_before" \
    "$(find "$REVIEW_DIRTY/.git/objects" -type f | wc -l | tr -d ' ')"
  assert test ! -f "$review_gitdir/review-note-review-real"
else
  fail "review label against the real review gate: $REAL_GATE is not executable (set CLAUDE_SETUP_ROOT)"
fi
GATE_CMD="$GATE_STUB"
GATE_ANSWER=off
GATE_RC=0

# --- a commit of this chat its upstream does not hold ----------------------------------------
# The marker is the gate's `unpushed` answer and nothing else: the Stop ask that tells the chat to
# push reads that same subcommand, so a marker deriving ownership on its own would stand over
# commits that ask disowns. A stub answers it apart from the verdict, which shares this gate.
UNPUSHED_STUB="$FIXTURES/unpushed-gate-stub.sh"
cat > "$UNPUSHED_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GATE_LOG"
case "$1" in
  unpushed) printf '%s\n' "$UNPUSHED_ANSWER" ;;
  *) printf '%s\n' "$GATE_ANSWER" ;;
esac
STUB
chmod +x "$UNPUSHED_STUB"
UNPUSHED_TIMEOUT_BIN="$FIXTURES/unpushed-timeout-bin"
UNPUSHED_TIMEOUT_LOG="$FIXTURES/unpushed-timeout.log"
mkdir -p "$UNPUSHED_TIMEOUT_BIN"
cat > "$UNPUSHED_TIMEOUT_BIN/timeout" <<'TIMEOUT'
#!/bin/bash
printf '%s\n' "$*" >> "$UNPUSHED_TIMEOUT_LOG"
shift
exec "$@"
TIMEOUT
chmod +x "$UNPUSHED_TIMEOUT_BIN/timeout"
export UNPUSHED_TIMEOUT_LOG
export UNPUSHED_ANSWER=""
GATE_CMD="$UNPUSHED_STUB"
# Named for nothing in the marker's own vocabulary: the directory label prints the repository name,
# and a fixture called `unpushed` would answer every search for the word.
AHEAD_REPO="$FIXTURES/ahead-repo"
git clone -q "$REPO_A" "$AHEAD_REPO"
git -C "$AHEAD_REPO" config user.email t@example.test
git -C "$AHEAD_REPO" config user.name t
AHEAD_TOP=$(git -C "$AHEAD_REPO" rev-parse --show-toplevel)
ahead_gitdir=$(git -C "$AHEAD_REPO" rev-parse --path-format=absolute --git-common-dir)
UNPUSHED_MARK=" ${DIM}│${RESET} unpushed"
# Absence is asked of the WORD: a dim marker differs from UNPUSHED_MARK only in the escapes, so a
# negative case matching the bright spelling would pass while the marker is on the line.
unpushed_silent() { # rendered-line
  ! grep -Fq unpushed <<< "$1"
}
unpushed_calls() { grep -c '^unpushed ' "$GATE_LOG" 2>/dev/null | tr -d ' '; }
unpushed_await() { # session calls
  local i
  for i in $(seq 1 100); do
    [ "$(unpushed_calls)" = "$2" ] && [ ! -d "$STATE_DIR/unpushed-$1.lock" ] && return 0
    sleep 0.05
  done
  fail "the backgrounded unpushed answer never landed: $1 ($(unpushed_calls) asks)"
}
unpushed_render() { # session repo calls
  local payload
  rm -f "$STATE_DIR/unpushed-$1"
  rmdir "$STATE_DIR/unpushed-$1.lock" 2>/dev/null
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "unpushed render failed: $1"
  unpushed_await "$1" "${3:-1}"
  run_statusline "$payload" || fail "unpushed render failed: $1"
}

# A branch level with its upstream is answered without the gate at all, which is what keeps this
# off the render path in every repository it never marks.
: > "$GATE_LOG"
: > "$UNPUSHED_TIMEOUT_LOG"
UNPUSHED_ANSWER=deadbee
unpushed_level_out=$(run_statusline "$(statusline_payload unpushed-level "" "$AHEAD_REPO")") ||
  fail "unpushed level render failed"
assert unpushed_silent "$unpushed_level_out"
assert_eq 0 "$(unpushed_calls)"

printf 'ahead\n' > "$AHEAD_REPO/ahead.txt"
git -C "$AHEAD_REPO" add ahead.txt
git -C "$AHEAD_REPO" commit -q -m "ahead of the upstream"
: > "$GATE_LOG"
worker_order_saved=$(cat "$worker_order_file" 2>/dev/null)
printf 'worker=sonnet\n' > "$worker_order_file"
unpushed_ahead_out=$(PATH="$UNPUSHED_TIMEOUT_BIN:$PATH" \
  unpushed_render unpushed-ahead "$AHEAD_REPO")
assert grep -Fq "$UNPUSHED_MARK" <<< "$unpushed_ahead_out"
assert_eq "unpushed $AHEAD_TOP unpushed-ahead" "$(grep -m1 '^unpushed ' "$GATE_LOG")"
assert_eq "10 $UNPUSHED_STUB unpushed $AHEAD_TOP unpushed-ahead" \
  "$(grep -m1 -F "$UNPUSHED_STUB unpushed " "$UNPUSHED_TIMEOUT_LOG")"
# Never dimmed: the commit is this chat's own to act on.
assert test "${unpushed_ahead_out#*"${DIM}unpushed"}" = "$unpushed_ahead_out"
# After the verdict and before the workers, where the rest of the repository cluster ends.
unpushed_order_line="${unpushed_ahead_out%%$'\n'*}"
assert grep -Fq "$WORKER_MARK" <<< "${unpushed_order_line#*"$UNPUSHED_MARK"}"
assert test "${unpushed_order_line%%"$UNPUSHED_MARK"*}" != "$unpushed_order_line"
# Fit step 9: the marker shortens to a red `↑!` rather than leaving the line, whatever the width.
: > "$GATE_LOG"
unpushed_fit_out=$(FIT_COLUMNS=20 PATH="$UNPUSHED_TIMEOUT_BIN:$PATH" \
  unpushed_render unpushed-fit "$AHEAD_REPO")
assert grep -Fq "${RED}↑!${RESET}" <<< "$unpushed_fit_out"
printf '%s' "$worker_order_saved" > "$worker_order_file"

# A gate naming no commit is a branch ahead of its upstream by nobody's work here — a co-tenant's
# commits are theirs — and the marker says nothing rather than pointing at the count.
: > "$GATE_LOG"
UNPUSHED_ANSWER=""
unpushed_theirs_out=$(unpushed_render unpushed-theirs "$AHEAD_REPO")
assert unpushed_silent "$unpushed_theirs_out"
# And a gate that is not there marks nothing: the marker may not invent an answer where the one
# thing that decides it could not be reached.
UNPUSHED_ANSWER=deadbee
# Over a cache the gate itself filled a moment ago, so the silence is the missing gate and not the
# render having nothing to say: asked with the cache cleared, this passes on the pending state
# whatever the gate does.
: > "$GATE_LOG"
unpushed_warm_out=$(unpushed_render unpushed-nogate "$AHEAD_REPO")
assert grep -Fq "$UNPUSHED_MARK" <<< "$unpushed_warm_out"
GATE_CMD="$FIXTURES/no-such-gate.sh"
unpushed_nogate_out=$(run_statusline "$(statusline_payload unpushed-nogate "" "$AHEAD_REPO")") ||
  fail "unpushed no-gate render failed"
assert unpushed_silent "$unpushed_nogate_out"
GATE_CMD="$UNPUSHED_STUB"

# Asked once per key, not once per render: the gate forks git per candidate commit, which is not a
# cost this may pay on every prompt.
: > "$GATE_LOG"
unpushed_render unpushed-cache "$AHEAD_REPO" >/dev/null
run_statusline "$(statusline_payload unpushed-cache "" "$AHEAD_REPO")" >/dev/null ||
  fail "unpushed cache render failed"
assert_eq 1 "$(unpushed_calls)"
# And asked again the moment the debt journal moves: whose the commit is is read out of it, so a
# row appended there changes the answer with no commit made and nothing in `git status` moving. The
# journal is the git FAMILY's, under the common dir (shared-invariants row `bd`), which is the one
# file every checkout of the project writes to.
printf 'unpushed-cache\t1750000000\tchange.txt\0' > "$ahead_gitdir/claude-review-debt"
run_statusline "$(statusline_payload unpushed-cache "" "$AHEAD_REPO")" >/dev/null ||
  fail "unpushed cache third render failed"
unpushed_await unpushed-cache 2
assert_eq 2 "$(unpushed_calls)"
rm -f "$ahead_gitdir/claude-review-debt"

# And the answer under that key is the only one the fallback may serve. The cache is the session's,
# so a chat that moved to another tree has a cached `unpushed` about the tree it left — rendered
# there, it marks a repository nobody has asked the gate about yet.
MOVED_REPO="$FIXTURES/moved-repo"
git clone -q "$REPO_A" "$MOVED_REPO"
git -C "$MOVED_REPO" config user.email t@example.test
git -C "$MOVED_REPO" config user.name t
printf 'moved\n' > "$MOVED_REPO/moved.txt"
git -C "$MOVED_REPO" add moved.txt
git -C "$MOVED_REPO" commit -q -m "ahead over there too"
: > "$GATE_LOG"
unpushed_moved_warm=$(unpushed_render unpushed-moved "$AHEAD_REPO")
assert grep -Fq "$UNPUSHED_MARK" <<< "$unpushed_moved_warm"
unpushed_moved_out=$(run_statusline "$(statusline_payload unpushed-moved "" "$MOVED_REPO")") ||
  fail "unpushed moved render failed"
assert unpushed_silent "$unpushed_moved_out"

GATE_CMD="$GATE_STUB"
GATE_ANSWER=off
GATE_RC=0

REVIEW_CLEAN="$FIXTURES/review-clean"
git clone -q "$REPO_A" "$REVIEW_CLEAN"
review_clean_root=$(cd "$REVIEW_CLEAN" && pwd -P)
review_clean_hash=$(printf '%s' "$review_clean_root" | shasum -a 1 | awk '{print substr($1,1,8)}')
# review-bench names a progress file after the repository the same way it names a receipt, which is
# the only thing left of that convention here: nothing in the render reads a receipt any more.
review_progress_stem="$(basename "$REVIEW_CLEAN")__${review_clean_hash}"

# A review this chat did not run leaves nothing behind that the strip speaks for: the slot is the
# gate's verdict about THIS chat plus a run in flight, and a finished panel of any shape — whole,
# partly silent, over a tree that still matches — is silent in a repository the gate says `off` of.
REVIEW_RECEIPT_DIR="$CLAUDEB_FIX/worker-stats/receipts"
mkdir -p "$REVIEW_RECEIPT_DIR"
review_clean_sha=$(git -C "$REVIEW_CLEAN" rev-parse HEAD)
review_clean_tree=$(git -C "$REVIEW_CLEAN" rev-parse HEAD^{tree})
review_stale_receipt="$REVIEW_RECEIPT_DIR/${review_progress_stem}.json"
for review_receipt_case in 0 1 4; do
  jq -cn --arg repo "$REVIEW_CLEAN" --arg tree "$review_clean_tree" \
    --arg commit "$review_clean_sha" --arg run_id receipt-match \
    --argjson errored "$review_receipt_case" \
    '{repo:$repo,tree:$tree,commit:$commit,run_id:$run_id,
      ts:"2026-07-27T00:00:00+00:00",errored:$errored,panel:9}' \
    > "$review_stale_receipt"
  review_receipt_out=$(review_render "review-receipt-$review_receipt_case" "$REVIEW_CLEAN")
  assert review_slot_silent "$review_receipt_out"
done
rm -f "$review_stale_receipt"

review_nongit_out=$(run_statusline "$(statusline_payload review-nongit "" "$NON_GIT")") \
  || fail "review non-git render failed"
assert test "${review_nongit_out#*rev T}" = "$review_nongit_out"

PROGRESS_DIR="$CLAUDEB_FIX/worker-stats/progress"
mkdir -p "$PROGRESS_DIR"
progress_prefix="${review_progress_stem}-"
write_progress() { # pid tier done total started [repo] [max]
  jq -cn --arg repo "${6:-$REVIEW_CLEAN}" --argjson pid "$1" --arg tier "$2" \
    --argjson done_cells "$3" --argjson total "$4" --arg started "$5" \
    --argjson max "${7:-false}" '
    {repo:$repo, pid:$pid, run_id:"progress-fixture",
     tier:(if $tier == "" then null else $tier end), max:$max, target:"abc1234",
     cells:[range($total) | "cell-\(.)"], done:[range($done_cells) | "cell-\(.)"],
     failed:0, started:$started, ts:$started}' \
    > "$PROGRESS_DIR/$progress_prefix$1.json"
}
progress_render() {
  run_statusline "$(statusline_payload "review-progress-$1" "" "$REVIEW_CLEAN")" \
    || fail "review progress render failed: $1"
}
# Lateness is measured against the render's own clock, so these stamps are taken now: the suite's
# global NOW is minutes old by the time this section runs and would eat the freshness budget.
progress_started() { printf '%s' "$(( $(date +%s) - ${1:-0} ))"; }

# A run in flight is the whole story the slot tells about a tree: the panel and its counter.
write_progress "$$" T2 3 8 2026-07-27T22:00:00+00:00
progress_live_out=$(progress_render live)
assert grep -Fq 'rev T2 3/8' <<< "$progress_live_out"
assert test "${progress_live_out#*rev T2 max}" = "$progress_live_out"

# Fit step 7: the counter's word shortens to `r`, and the counter itself is never dropped.
progress_fit_out=$(FIT_COLUMNS=24 progress_render fit)
assert grep -Fq 'rT2 3/8' <<< "$progress_fit_out"
assert test "${progress_fit_out#*rev T2}" = "$progress_fit_out"

write_progress "$$" T2 0 1 2026-07-27T22:00:00+00:00
jq --argjson started_epoch "$(progress_started 121)" \
  '. + {started_epoch:$started_epoch,expected:{"cell-0":1000}}' \
  "$PROGRESS_DIR/$progress_prefix$$.json" \
  > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_late_out=$(progress_render late)
assert grep -Fq " ${DIM}│${RESET} ${RED}rev T2 0/1${RESET}" <<< "$progress_late_out"

jq --argjson started_epoch "$(progress_started)" '.started_epoch = $started_epoch' \
  "$PROGRESS_DIR/$progress_prefix$$.json" \
  > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_fresh_out=$(progress_render fresh)
assert grep -Fq " ${DIM}│${RESET} rev T2 0/1" <<< "$progress_fresh_out"
assert test "${progress_fresh_out#*"${RED}rev"}" = "$progress_fresh_out"

jq --argjson started_epoch "$(progress_started 121)" \
  '.started_epoch = $started_epoch | .done = ["cell-0"]' \
  "$PROGRESS_DIR/$progress_prefix$$.json" \
  > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_done_late_out=$(progress_render done-late)
assert grep -Fq " ${DIM}│${RESET} rev T2 1/1" <<< "$progress_done_late_out"
assert test "${progress_done_late_out#*"${RED}rev"}" = "$progress_done_late_out"

write_progress "$$" T2 0 1 2026-07-27T22:00:00+00:00
jq --argjson started_epoch "$(progress_started 121)" '.started_epoch = $started_epoch' \
  "$PROGRESS_DIR/$progress_prefix$$.json" \
  > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_no_expected_out=$(progress_render no-expected)
assert grep -Fq " ${DIM}│${RESET} rev T2 0/1" <<< "$progress_no_expected_out"
assert test "${progress_no_expected_out#*"${RED}rev"}" = "$progress_no_expected_out"

write_progress "$$" T2 0 1 2026-07-27T22:00:00+00:00
progress_legacy_out=$(progress_render legacy)
assert grep -Fq " ${DIM}│${RESET} rev T2 0/1" <<< "$progress_legacy_out"
assert test "${progress_legacy_out#*"${RED}rev"}" = "$progress_legacy_out"

# The max panel is a variant of the same tier at the same time budget, so a T2 max run must not
# read as the T2 it is not: it buys a wider panel, and the label is where that is visible.
write_progress "$$" T2 5 16 2026-07-27T22:00:00+00:00 "" true
progress_max_out=$(progress_render max)
assert grep -Fq 'rev T2 max 5/16' <<< "$progress_max_out"

# --max is refused without --tier, so a file claiming the variant without the tier is corrupt in
# that field; the counter still renders and no bare variant name takes the tier's place.
write_progress "$$" "" 2 4 2026-07-27T22:00:00+00:00 "" true
progress_max_untiered_out=$(progress_render max-untiered)
assert grep -Fq 'rev 2/4' <<< "$progress_max_untiered_out"
assert test "${progress_max_untiered_out#*rev max}" = "$progress_max_untiered_out"

# review-bench keys the file name on the path it was handed, so a run started from a
# subdirectory lands under a name no render can predict — and a repository whose directory name
# begins with a dot hides from a bare glob. The repository recorded inside the file is the match.
mkdir -p "$REVIEW_CLEAN/sub"
progress_alias="$PROGRESS_DIR/.sub__0badc0de-$$.json"
jq -cn --arg repo "$REVIEW_CLEAN/sub" --argjson pid "$$" \
  '{repo:$repo,pid:$pid,run_id:"alias",tier:"T3",target:"x",cells:["a","b","c"],done:["a"],
    failed:0,started:"2026-07-28T00:00:00+00:00",ts:"2026-07-28T00:00:00+00:00"}' \
  > "$progress_alias"
progress_alias_out=$(progress_render alias)
assert grep -Fq 'rev T3 1/3' <<< "$progress_alias_out"
rm -f "$progress_alias"

# An --auto run carries no tier; the counter still renders.
write_progress "$$" "" 1 5 2026-07-27T22:00:00+00:00
progress_untiered_out=$(progress_render untiered)
assert grep -Fq 'rev 1/5' <<< "$progress_untiered_out"
assert test "${progress_untiered_out#*rev T}" = "$progress_untiered_out"

progress_second_pid=$( (sleep 30 >/dev/null 2>&1 & echo $!) )
write_progress "$$" T1 2 6 2026-07-27T22:00:00+00:00
write_progress "$progress_second_pid" T3 5 9 2026-07-27T23:30:00+00:00
progress_two_out=$(progress_render two-runs)
assert grep -Fq 'rev T3 5/9' <<< "$progress_two_out"
assert test "${progress_two_out#*rev T1}" = "$progress_two_out"
assert_eq 1 "$(grep -o 'rev T3' <<< "$progress_two_out" | wc -l | tr -d ' ')"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"

# A pid the run no longer owns renders nothing: the file outlives kill -9, and the process now
# holding that pid necessarily started after the dead run's last write.
progress_recent=$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M.%S)
touch -t "$progress_recent" "$PROGRESS_DIR/$progress_prefix$progress_second_pid.json"
progress_recycled_out=$(progress_render recycled)
assert test "${progress_recycled_out#*5/9}" = "$progress_recycled_out"
assert review_slot_silent "$progress_recycled_out"
kill "$progress_second_pid" 2>/dev/null
rm -f "$PROGRESS_DIR/$progress_prefix$progress_second_pid.json"

write_progress 99999999 T2 4 7 2026-07-27T22:00:00+00:00
progress_dead_out=$(progress_render dead-pid)
assert test "${progress_dead_out#*4/7}" = "$progress_dead_out"
rm -f "$PROGRESS_DIR/${progress_prefix}99999999.json"

# The whole middle block is about ONE tree — the shown tree — and a review elsewhere is reported by
# MOVING it there, never by naming a repository in the counter slot (Egor, 2026-08-27, superseding
# the 2026-08-26 rule that the folder never moves).
progress_home_dir="${BLUE}$(basename "$REVIEW_CLEAN")${RESET}"
progress_away_dirs="${DIM}$(basename "$REVIEW_CLEAN")${RESET} ${MAGENTA}»${RESET} ${BLUE}$(basename "$REVIEW_DIRTY")${RESET}"
rev_unnamed() { # rendered
  case "$1" in
    *"rev $(basename "$REVIEW_DIRTY")"*|*"rev $(basename "$REVIEW_CLEAN")"*|*"rev repo-"*)
      return 1 ;;
  esac
  return 0
}

write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00 "$REVIEW_DIRTY"
progress_foreign_out=$(progress_render foreign-repo)
assert test "${progress_foreign_out#*4/7}" = "$progress_foreign_out"
assert grep -Fq "$progress_home_dir" <<< "$progress_foreign_out"

# A run over another tree belongs to the chat that started it and to no other, and a live one of
# this chat's takes the block with it: the folder, the branch, the counters and the counter beside
# them are that tree's, so the number is read as belonging to the folder it is actually about.
progress_set_session() { # session
  jq --arg session "$1" '.session = $session' \
    "$PROGRESS_DIR/$progress_prefix$$.json" > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
  mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
}
progress_set_session review-progress-foreign-mine
progress_foreign_mine_out=$(progress_render foreign-mine)
assert grep -Fq "$progress_away_dirs" <<< "$progress_foreign_mine_out"
assert grep -Fq " ${DIM}│${RESET} rev T2 4/7" <<< "$progress_foreign_mine_out"
assert rev_unnamed "$progress_foreign_mine_out"
# The branch and the diff counters move with it: review-dirty's own untracked 21 lines, never the
# clean home tree's nothing.
assert grep -Fq "${BLUE}⎇ main${RESET} ${GREEN}+21${RESET}/${RED}-0${RESET}" \
  <<< "$progress_foreign_mine_out"

progress_set_session review-progress-another-chat
progress_foreign_other_out=$(progress_render foreign-other)
assert test "${progress_foreign_other_out#*4/7}" = "$progress_foreign_other_out"
assert grep -Fq "$progress_home_dir" <<< "$progress_foreign_other_out"

# Without a recorded session the walk still answers, for documents written before review-bench
# recorded one — and where it cannot, a run elsewhere moves nothing and shows nothing.
mkdir -p "$HOME/.claude/sessions"
printf '{"sessionId":"review-progress-foreign-walk"}\n' > "$HOME/.claude/sessions/$$.json"
write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00 "$REVIEW_DIRTY"
progress_foreign_walk_out=$(progress_render foreign-walk)
assert grep -Fq "$progress_away_dirs" <<< "$progress_foreign_walk_out"
assert grep -Fq " ${DIM}│${RESET} rev T2 4/7" <<< "$progress_foreign_walk_out"
progress_foreign_walk_other_out=$(progress_render foreign-walk-other)
assert test "${progress_foreign_walk_other_out#*4/7}" = "$progress_foreign_walk_other_out"
assert grep -Fq "$progress_home_dir" <<< "$progress_foreign_walk_other_out"
rm -f "$HOME/.claude/sessions/$$.json"

# The recorded session decides how loudly a run on THIS tree renders, and nothing about whether it
# renders at all: another chat's run here is still this tree's news, and it moves nothing.
write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00
progress_set_session review-progress-another-chat
progress_own_tree_other_out=$(progress_render own-tree-other)
assert grep -Fq " ${DIM}│${RESET} ${DIM}rev T2 4/7${RESET}" <<< "$progress_own_tree_other_out"
assert grep -Fq "$progress_home_dir" <<< "$progress_own_tree_other_out"

# Identity is the WORKING TREE and not the repository: `--git-common-dir` is one path for every
# worktree of a project, so matching on it rendered a sibling's review here as if it were this
# tree's. A sibling nobody here owns is still invisible; a sibling of THIS chat's own is an away
# tree like any other, and takes the block to the worktree it actually runs in — `⧉` and all.
# A subdirectory of this tree (the case that forced content matching in the first place, since its
# file name is unpredictable) still resolves to home and renders there.
PROGRESS_WT="$FIXTURES/review-clean-wt"
git -C "$REVIEW_CLEAN" worktree add -q "$PROGRESS_WT" -b progress-sibling
write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00 "$PROGRESS_WT"
progress_sibling_out=$(progress_render sibling-worktree)
assert test "${progress_sibling_out#*4/7}" = "$progress_sibling_out"
assert test "${progress_sibling_out#*⧉}" = "$progress_sibling_out"

progress_set_session review-progress-sibling-mine
progress_sibling_mine_out=$(progress_render sibling-mine)
assert grep -Fq "$progress_home_dir ${RED}⧉ $(basename "$PROGRESS_WT")${RESET}" \
  <<< "$progress_sibling_mine_out"
assert grep -Fq " ${DIM}│${RESET} rev T2 4/7" <<< "$progress_sibling_mine_out"
assert test "${progress_sibling_mine_out#*»}" = "$progress_sibling_mine_out"

mkdir -p "$REVIEW_CLEAN/nested/deeper"
write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00 "$REVIEW_CLEAN/nested/deeper"
progress_subdir_out=$(progress_render subdirectory)
assert grep -Fq 'rev T2 4/7' <<< "$progress_subdir_out"

write_progress "$$" T2 9 7 2026-07-27T22:00:00+00:00
progress_overrun_out=$(progress_render overrun)
assert test "${progress_overrun_out#*9/7}" = "$progress_overrun_out"

printf 'not json\n' > "$PROGRESS_DIR/$progress_prefix$$.json"
progress_corrupt_out=$(progress_render corrupt)
assert review_slot_silent "$progress_corrupt_out"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"

progress_gone_out=$(progress_render gone)
assert_eq 0 \
  "$(grep -Eco 'rev (T[0-3] )?[0-9]+/[0-9]+' <<< "$progress_gone_out" | tr -d ' ')"
assert review_slot_silent "$progress_gone_out"

# The debt never disappears behind a review. Both stand on the line over ONE tree — the counter
# with the word, the verdict with its numbers alone — where a run in flight used to blank the
# verdict outright, so any review over this tree, this chat's or another chat's, hid the number the
# reader acts on (Egor, 2026-08-24).
GATE_ANSWER='split rev 54/10'
# Alone, the verdict keeps the word: nothing beside it says what the numbers are about.
progress_alone_out=$(review_render review-progress-alone "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} rev 54${DIM}/10${RESET}" <<< "$progress_alone_out"
assert test "${progress_alone_out#*rev T}" = "$progress_alone_out"
# This chat's own run: its own segment bright, the verdict's own split weighting untouched beside
# it, and the word carried once.
write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00
progress_own_debt_out=$(review_render review-progress-own-debt "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} rev T0 3/9 ${DIM}│${RESET} 54${DIM}/10${RESET}" \
  <<< "$progress_own_debt_out"
assert test "${progress_own_debt_out#*rev 54}" = "$progress_own_debt_out"
# Another chat's run over this tree dims its own segment and colours nothing of the verdict: the
# two weights are decided by two rules and neither paints the other.
progress_set_session review-progress-elsewhere
progress_other_debt_out=$(review_render review-progress-other-debt "$REVIEW_CLEAN")
assert grep -Fq \
  " ${DIM}│${RESET} ${DIM}rev T0 3/9${RESET} ${DIM}│${RESET} 54${DIM}/10${RESET}" \
  <<< "$progress_other_debt_out"
# A one-sided verdict loses the word the same way, and the trim takes that word and nothing else.
GATE_ANSWER='bright rev 7'
progress_one_sided_out=$(review_render review-progress-one-sided "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} ${DIM}rev T0 3/9${RESET} ${DIM}│${RESET} 7" \
  <<< "$progress_one_sided_out"
# A run this chat started over ANOTHER tree takes the whole block there, verdict included: the gate
# is asked about the tree the reader is looking at and about no other, and the counter beside its
# answer carries the word for both of them.
: > "$GATE_LOG"
GATE_ANSWER='split rev 54/10'
write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00 "$REVIEW_DIRTY"
progress_set_session review-progress-foreign-named
progress_foreign_named_out=$(review_render review-progress-foreign-named "$REVIEW_CLEAN" \
  "$TOP_REVIEW_DIRTY")
assert grep -Fq \
  " ${DIM}│${RESET} rev T0 3/9 ${DIM}│${RESET} 54${DIM}/10${RESET}" \
  <<< "$progress_foreign_named_out"
assert grep -Fq "$progress_away_dirs" <<< "$progress_foreign_named_out"
assert rev_unnamed "$progress_foreign_named_out"
assert_eq "verdict $TOP_REVIEW_DIRTY review-progress-foreign-named" \
  "$(grep -F verdict "$GATE_LOG" | tail -1)"
assert_eq 0 "$(grep -Fc -- "verdict $review_clean_root " "$GATE_LOG" | tr -d ' ')"

# A run in a linked worktree of a foreign repository moves the block to THAT WORKTREE: `»` names
# the repository, exactly as it would if the chat stood there, and `⧉` the worktree it is a review
# of — which the repository's name alone could not tell from any of its siblings.
TOP_PROGRESS_WT=$(cd "$PROGRESS_WT" && pwd -P)
write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00 "$PROGRESS_WT"
progress_set_session review-progress-foreign-wt
progress_foreign_wt_out=$(review_render review-progress-foreign-wt "$REPO_A" "$TOP_PROGRESS_WT")
assert grep -Fq \
  "${DIM}$(basename "$REPO_A")${RESET} ${MAGENTA}»${RESET} ${BLUE}$(basename "$REVIEW_CLEAN")${RESET} ${RED}⧉ $(basename "$PROGRESS_WT")${RESET}" \
  <<< "$progress_foreign_wt_out"
assert grep -Fq " ${DIM}│${RESET} rev T0 3/9 " <<< "$progress_foreign_wt_out"
assert rev_unnamed "$progress_foreign_wt_out"

# A run whose recorded repository no longer resolves has no tree to render at all, and the block is
# one tree's rendering: the run is dropped whole rather than moving the block to a path or leaving
# a count beside the session's own folder. Rendered from INSIDE the session's checkout, the way the
# harness launches the statusline, since asking git about an empty path answers for the process's
# own directory.
write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00 /nonexistent/repo-vanished
progress_set_session review-progress-repo-vanished
progress_vanished_out=$(cd "$REPO_A" && review_render review-progress-repo-vanished "$REPO_A")
assert test "${progress_vanished_out#*3/9}" = "$progress_vanished_out"
assert rev_unnamed "$progress_vanished_out"
assert grep -Fq "${BLUE}$(basename "$REPO_A")${RESET}" <<< "$progress_vanished_out"
assert grep -Fq " ${DIM}│${RESET} rev 54${DIM}/10${RESET}" <<< "$progress_vanished_out"

write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00

# A style word this build cannot classify is the gate speaking and reaches the reader whole, even
# where its sentence opens with the word the counter beside it already carries.
GATE_ANSWER='rev 7 held for review'
progress_loud_debt_out=$(review_render review-progress-loud-debt "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} ${RED}rev 7 held for revi…${RESET}" <<< "$progress_loud_debt_out"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"
GATE_ANSWER=off

# The block MOVES to the tree a review of this chat's is about, and comes back when that review is
# answered (Egor, 2026-08-27, superseding the 2026-08-26 rule that it never moves): a folder that
# stayed put while the numbers beside it were about another place named neither of them. In order:
# a live run over home holds the block at home, whoever started it; else this chat's newest live
# run elsewhere takes it; else home keeps it while it is working or owes a review; else an
# unanswered round of this chat's elsewhere holds it. Only this chat's own runs and rounds move
# anything.
ANCHOR_BENCHES="$CLAUDEB_FIX/worker-stats/benches"
write_anchor_run() { # run-id session repo [member-repo...]
  local run_id="$1" session="$2" repo="$3"
  shift 3
  mkdir -p "$ANCHOR_BENCHES/$run_id"
  jq -cn --arg run_id "$run_id" --arg session "$session" --arg repo "$repo" \
    --args '{run_id:$run_id, session:$session, repo:$repo, worktree:true, commit:"abc1234",
             started:"2026-07-27T22:00:00+00:00"}
            + (if ($ARGS.positional | length) > 0
               then {repos: [$ARGS.positional[] | {repo: .}]} else {} end)' "$@" \
    > "$ANCHOR_BENCHES/$run_id/meta.json"
  jq -cn --arg run_id "$run_id" --arg session "$session" --arg repo "$repo" --argjson pid "$$" \
    '{repo:$repo, pid:$pid, run_id:$run_id, session:$session, tier:"T2", max:false,
      target:"worktree", cells:["a","b"], done:["a"], failed:0,
      started:"2026-07-27T22:00:00+00:00", ts:"2026-07-27T22:00:00+00:00"}' \
    > "$PROGRESS_DIR/anchor-$run_id.json"
}
anchor_await() { # session
  local i
  for i in $(seq 1 100); do
    [ -f "$STATE_DIR/review-anchor-$1" ] && [ ! -d "$STATE_DIR/review-anchor-$1.lock" ] && return 0
    sleep 0.05
  done
  fail "the backgrounded anchor never landed: $1"
}
anchor_render() { # session cwd [away-toplevel]
  local payload
  rm -f "$STATE_DIR/review-anchor-$1" "$STATE_DIR/review-class-$1"
  rmdir "$STATE_DIR/review-anchor-$1.lock" "$STATE_DIR/review-class-$1.lock" 2>/dev/null
  [ -n "${3:-}" ] && rm -f "$STATE_DIR/review-class-$1-$(away_tag "$3")"
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "anchor render failed: $1"
  anchor_await "$1"
  run_statusline "$payload" >/dev/null || fail "anchor render failed: $1"
  review_await_verdict "$1" "${3:-}"
  run_statusline "$payload" || fail "anchor render failed: $1"
}
anchor_own_dir="${BLUE}$(basename "$REPO_A")${RESET}"
anchor_clean_name="$(basename "$REVIEW_CLEAN")"
anchor_clean_dir="${BLUE}$anchor_clean_name${RESET}"
rm -f "$PROGRESS_DIR"/anchor-*.json "$PROGRESS_DIR/$progress_prefix$$.json"

# (a) A live review of this chat's over repository B while the shell sits in A: the whole block is
# B's — its folder after the `»`, its branch, its counters, its counter — and the gate is asked
# about B and about nothing else, because the verdict is the number beside all of them.
: > "$GATE_LOG"
GATE_ANSWER='bright rev 2'
write_anchor_run 20260727T220000Z-aaaaaaa anchor-live "$REVIEW_CLEAN"
anchor_live_out=$(review_render anchor-live "$REPO_A" "$review_clean_root")
assert grep -Fq "${DIM}$(basename "$REPO_A")${RESET} ${MAGENTA}»${RESET} $anchor_clean_dir" \
  <<< "$anchor_live_out"
assert grep -Fq " ${DIM}│${RESET} rev T2 1/2 ${DIM}│${RESET} 2" <<< "$anchor_live_out"
assert rev_unnamed "$anchor_live_out"
assert_eq "verdict $review_clean_root anchor-live" "$(grep -F verdict "$GATE_LOG" | tail -1)"
assert_eq 0 "$(grep -Fc -- "verdict $TOP_A anchor-live" "$GATE_LOG" | tr -d ' ')"

# (b) Two live runs with one of them over home: home wins, and another chat's run here is the dim
# counter it always was — never a mover, in either direction.
write_progress "$$" T3 4 7 2026-07-27T23:00:00+00:00 "$REPO_A"
progress_set_session anchor-other-chat
anchor_home_wins_out=$(review_render anchor-live "$REPO_A")
assert grep -Fq "$anchor_own_dir" <<< "$anchor_home_wins_out"
assert test "${anchor_home_wins_out#*»}" = "$anchor_home_wins_out"
assert grep -Fq " ${DIM}│${RESET} ${DIM}rev T3 4/7${RESET} ${DIM}│${RESET} 2" \
  <<< "$anchor_home_wins_out"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"

# (c) A live run ANOTHER chat started elsewhere stays invisible and moves nothing.
GATE_ANSWER=off
write_anchor_run 20260727T221000Z-bbbbbbb anchor-someone-else "$REVIEW_CLEAN"
anchor_not_mine_out=$(anchor_render anchor-notmine "$REPO_A")
assert grep -Fq "$anchor_own_dir" <<< "$anchor_not_mine_out"
assert test "${anchor_not_mine_out#*»}" = "$anchor_not_mine_out"
assert review_slot_silent "$anchor_not_mine_out"
rm -f "$PROGRESS_DIR"/anchor-*.json
rm -rf "$ANCHOR_BENCHES/20260727T221000Z-bbbbbbb" "$ANCHOR_BENCHES/20260727T220000Z-aaaaaaa"

# (d) No live run and an unanswered round of this chat's elsewhere: a home that is clean, idle and
# owing nothing lets that round hold the block, branch and diff counters included — review-dirty's
# own untracked 21 lines, not the clean home tree's nothing.
: > "$GATE_LOG"
printf '%s' "$REVIEW_DIRTY" > "$STATE_DIR/review-anchor-anchor-debt"
rm -f "$STATE_DIR/review-class-anchor-debt" \
  "$STATE_DIR/review-class-anchor-debt-$(away_tag "$TOP_REVIEW_DIRTY")"
anchor_debt_payload=$(statusline_payload anchor-debt "" "$REVIEW_CLEAN")
run_statusline "$anchor_debt_payload" >/dev/null || fail "anchor debt render failed"
review_await_verdict anchor-debt
review_await_verdict anchor-debt "$TOP_REVIEW_DIRTY"
anchor_debt_out=$(run_statusline "$anchor_debt_payload") || fail "anchor debt render failed"
assert grep -Fq "$progress_away_dirs" <<< "$anchor_debt_out"
assert grep -Fq "${GREEN}+21${RESET}/${RED}-0${RESET}" <<< "$anchor_debt_out"
assert review_slot_silent "$anchor_debt_out"
# Both trees are asked, each under its own cache name, or one answer would serve the other's key.
assert_eq 1 "$(grep -Fc -- "verdict $TOP_REVIEW_DIRTY anchor-debt" "$GATE_LOG" | tr -d ' ')"
assert_eq 1 "$(grep -Fc -- "verdict $review_clean_root anchor-debt" "$GATE_LOG" | tr -d ' ')"

# The round being answered is what hands the block back: nothing else about the chat changes.
rm -f "$STATE_DIR/review-anchor-anchor-debt"
anchor_closed_out=$(run_statusline "$anchor_debt_payload") || fail "anchor closed render failed"
assert grep -Fq "$anchor_clean_dir" <<< "$anchor_closed_out"
assert test "${anchor_closed_out#*»}" = "$anchor_closed_out"

# (e) Work at home outranks a finished round elsewhere, both ways round: an uncommitted line here
# holds the block, and so does a review this tree owes.
printf '%s' "$REVIEW_CLEAN" > "$STATE_DIR/review-anchor-anchor-home-dirty"
anchor_home_dirty_payload=$(statusline_payload anchor-home-dirty "" "$REVIEW_DIRTY")
run_statusline "$anchor_home_dirty_payload" >/dev/null || fail "anchor home-dirty render failed"
review_await_verdict anchor-home-dirty
anchor_home_dirty_out=$(run_statusline "$anchor_home_dirty_payload") \
  || fail "anchor home-dirty render failed"
assert grep -Fq "${BLUE}$(basename "$REVIEW_DIRTY")${RESET}" <<< "$anchor_home_dirty_out"
assert test "${anchor_home_dirty_out#*»}" = "$anchor_home_dirty_out"
rm -f "$STATE_DIR/review-anchor-anchor-home-dirty"

GATE_ANSWER='bright rev 2'
printf '%s' "$REVIEW_DIRTY" > "$STATE_DIR/review-anchor-anchor-home-debt"
anchor_home_debt_payload=$(statusline_payload anchor-home-debt "" "$REVIEW_CLEAN")
run_statusline "$anchor_home_debt_payload" >/dev/null || fail "anchor home-debt render failed"
review_await_verdict anchor-home-debt
anchor_home_debt_out=$(run_statusline "$anchor_home_debt_payload") \
  || fail "anchor home-debt render failed"
assert grep -Fq "$anchor_clean_dir" <<< "$anchor_home_debt_out"
assert test "${anchor_home_debt_out#*»}" = "$anchor_home_debt_out"
assert grep -Fq " ${DIM}│${RESET} rev 2" <<< "$anchor_home_debt_out"
rm -f "$STATE_DIR/review-anchor-anchor-home-debt"
GATE_ANSWER=off

# (f) Identity is the WORKING TREE: a round in a sibling worktree of home's own repository is an
# away tree like any other, and the block renders that worktree — same family, so no `»`, and the
# `⧉` label is what says which of the siblings the review is about.
printf '%s' "$PROGRESS_WT" > "$STATE_DIR/review-anchor-anchor-sibling"
rm -f "$STATE_DIR/review-class-anchor-sibling" \
  "$STATE_DIR/review-class-anchor-sibling-$(away_tag "$TOP_PROGRESS_WT")"
anchor_sibling_payload=$(statusline_payload anchor-sibling "" "$REVIEW_CLEAN")
run_statusline "$anchor_sibling_payload" >/dev/null || fail "anchor sibling render failed"
review_await_verdict anchor-sibling "$TOP_PROGRESS_WT"
anchor_sibling_out=$(run_statusline "$anchor_sibling_payload") || fail "anchor sibling render failed"
assert grep -Fq "$anchor_clean_dir ${RED}⧉ $(basename "$PROGRESS_WT")${RESET}" \
  <<< "$anchor_sibling_out"
assert test "${anchor_sibling_out#*»}" = "$anchor_sibling_out"
rm -f "$STATE_DIR/review-anchor-anchor-sibling"

# (g) A merged panel holds the block over the member equal to the shell's own repository — which
# moves nothing — and over the first member otherwise.
write_anchor_run 20260727T222000Z-ccccccc anchor-merged-member "$FIXTURES/merged-workspace-gone" \
  "$REVIEW_CLEAN" "$REPO_A"
anchor_member_out=$(anchor_render anchor-merged-member "$REVIEW_CLEAN")
assert grep -Fq "$anchor_clean_dir" <<< "$anchor_member_out"
assert test "${anchor_member_out#*»}" = "$anchor_member_out"
rm -f "$PROGRESS_DIR"/anchor-*.json
rm -rf "$ANCHOR_BENCHES/20260727T222000Z-ccccccc"
write_anchor_run 20260727T223000Z-ddddddd anchor-merged-first "$FIXTURES/merged-workspace-gone" \
  "$REVIEW_DIRTY" "$REPO_A"
anchor_first_out=$(anchor_render anchor-merged-first "$REVIEW_CLEAN" "$TOP_REVIEW_DIRTY")
assert grep -Fq "$progress_away_dirs" <<< "$anchor_first_out"
rm -f "$PROGRESS_DIR"/anchor-*.json
rm -rf "$ANCHOR_BENCHES"

# (h) No review in front of the chat at all: byte-identical to a chat that never had one.
anchor_none_out=$(anchor_render anchor-none "$REVIEW_CLEAN")
anchor_control_out=$(anchor_render anchor-control "$REVIEW_CLEAN")
assert_eq "$anchor_control_out" "$anchor_none_out"
assert grep -Fq "$anchor_clean_dir" <<< "$anchor_none_out"
assert test "${anchor_none_out#*»}" = "$anchor_none_out"
assert_eq "" "$(cat "$STATE_DIR/review-anchor-anchor-none")"

# (i) A round whose tree no longer resolves is ignored WHOLE: the session's own folder, and no
# leftover member count from the dead panel.
printf '%s' "/nonexistent/repo-gone +2" > "$STATE_DIR/review-anchor-anchor-gone"
anchor_gone_out=$(run_statusline "$(statusline_payload anchor-gone "" "$REVIEW_CLEAN")") \
  || fail "anchor missing-repo render failed"
assert grep -Fq "$anchor_clean_dir" <<< "$anchor_gone_out"
assert test "${anchor_gone_out#*+2}" = "$anchor_gone_out"
assert test "${anchor_gone_out#*repo-gone}" = "$anchor_gone_out"
assert test "${anchor_gone_out#*»}" = "$anchor_gone_out"
rm -f "$STATE_DIR/review-anchor-anchor-gone"

# (j) The verdict's cache key reads the commit journal of the checkout FAMILY — one file under the
# common dir, which is where the gate reads this chat's pending paths from. A key watching the
# worktree's own git dir would serve a stale verdict for as long as the TTL allows after an edit
# recorded from a sibling checkout.
gate_calls_await() { # count
  local i
  for i in $(seq 1 100); do
    [ "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')" -ge "$1" ] && return 0
    sleep 0.05
  done
  fail "the gate was never asked $1 times: $(cat "$GATE_LOG")"
}
journal_wt_gitdir=$(git -C "$PROGRESS_WT" rev-parse --absolute-git-dir)
journal_wt_common=$(git -C "$PROGRESS_WT" rev-parse --path-format=absolute --git-common-dir)
# The two journals are given different mtimes, so the key names which of them it read.
printf 'journal-wt\t1750000000\ttracked.txt\0' > "$journal_wt_gitdir/claude-commit-journal"
touch -t 202001010000 "$journal_wt_gitdir/claude-commit-journal"
printf 'journal-wt\t1750000000\ttracked.txt\0' > "$journal_wt_common/claude-commit-journal"
: > "$GATE_LOG"
rm -f "$STATE_DIR/review-class-journal-wt"
journal_wt_payload=$(statusline_payload journal-wt "" "$PROGRESS_WT")
run_statusline "$journal_wt_payload" >/dev/null || fail "journal worktree first render failed"
review_await_verdict journal-wt
run_statusline "$journal_wt_payload" >/dev/null || fail "journal worktree second render failed"
journal_wt_key=$(head -1 "$STATE_DIR/review-class-journal-wt")
journal_wt_without_clock=${journal_wt_key%|*}
assert_eq "$(stat -f %m "$journal_wt_common/claude-commit-journal")" \
  "${journal_wt_without_clock##*|}"
assert_eq 0 "${journal_wt_key##*|}"
assert_eq 1 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
# And the family's journal moving is what asks the gate again, with nothing in `git status` and
# nothing in this worktree's own git dir having moved at all.
touch -t 202001020000 "$journal_wt_common/claude-commit-journal"
run_statusline "$journal_wt_payload" >/dev/null || fail "journal worktree common-dir render failed"
gate_calls_await 2
assert_eq 2 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
rm -f "$journal_wt_gitdir/claude-commit-journal" "$journal_wt_common/claude-commit-journal"
GATE_ANSWER=off

# (k) Nothing in the environment names the bench and no copy sits beside the statusline: the
# resolution chain falls through to PATH, and the round it answers with moves the block like any
# other. Rendered from a copy of the statusline with no sibling, because the repository's own copy
# would answer before PATH is ever reached.
NOSIB_DIR="$WORK/nosib"
mkdir -p "$NOSIB_DIR/bin"
cp "$STATUSLINE" "$NOSIB_DIR/bin/statusline.sh"
ln -sfn "$ROOT/share" "$NOSIB_DIR/share"
PATH_BENCH_DIR="$FIXTURES/path-bench"
mkdir -p "$PATH_BENCH_DIR"
cat > "$PATH_BENCH_DIR/review-bench" <<STUB
#!/bin/bash
[ "\$1" = review-anchor ] || exit 0
printf '%s\n' "$REVIEW_DIRTY"
STUB
chmod +x "$PATH_BENCH_DIR/review-bench"
anchor_saved_statusline="$STATUSLINE"
anchor_saved_bench="$BENCH_CMD"
anchor_saved_path="$PATH"
STATUSLINE="$NOSIB_DIR/bin/statusline.sh"
BENCH_CMD=""
PATH="$PATH_BENCH_DIR:$PATH"
rm -f "$STATE_DIR/review-anchor-anchor-path" "$STATE_DIR/review-class-anchor-path" \
  "$STATE_DIR/review-class-anchor-path-$(away_tag "$TOP_REVIEW_DIRTY")"
anchor_path_payload=$(statusline_payload anchor-path "" "$REVIEW_CLEAN")
run_statusline "$anchor_path_payload" >/dev/null || fail "anchor PATH render failed"
anchor_await anchor-path
run_statusline "$anchor_path_payload" >/dev/null || fail "anchor PATH render failed"
review_await_verdict anchor-path
review_await_verdict anchor-path "$TOP_REVIEW_DIRTY"
anchor_path_out=$(run_statusline "$anchor_path_payload") || fail "anchor PATH render failed"
assert_eq "$REVIEW_DIRTY" "$(cat "$STATE_DIR/review-anchor-anchor-path")"
assert grep -Fq "$progress_away_dirs" <<< "$anchor_path_out"
STATUSLINE="$anchor_saved_statusline"
BENCH_CMD="$anchor_saved_bench"
PATH="$anchor_saved_path"
rm -f "$STATE_DIR/review-anchor-anchor-path"

# --- worker-launch-gate.sh: grok ------------------------------------------------------------------
# A vendor launched as a bare headless CLI from a chat's Bash is a worker nobody can see. grok
# spells that four ways, and the profile wrapper is denied beside the bare binary exactly as the
# other vendors' wrappers are: `grokb` isolates a profile, it records nothing about the run, so
# `worker-run` is the only sanctioned way in. Interactive launches and read-only subcommands stay
# ungated.
LAUNCH_GATE_BIN="$ROOT/bin/worker-launch-gate.sh"
gate_payload() {
  jq -cn --arg command "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$command}}'
}
for gate_denied in \
  'grok -p "do the thing"' \
  'grok --print "do the thing"' \
  'grok --prompt-file /tmp/brief' \
  'grok --prompt-json /tmp/brief.json' \
  'grok agent --output-format streaming-json' \
  'env GROK_MEMORY=0 /opt/homebrew/bin/grok --prompt-file /tmp/brief' \
  'grokb profile supergrok --prompt-file /tmp/brief --output-format streaming-json' \
  'grokb supergrok exec --prompt-file /tmp/brief' \
  'grokb p supergrok -p "do the thing"'; do
  gate_out=$(gate_payload "$gate_denied" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$gate_out" >/dev/null
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | test("worker-run start <claudeb\\|codex\\|gemini\\|grok>")' \
    <<<"$gate_out" >/dev/null
done
for gate_allowed in \
  'worker-run start grok --brief /tmp/brief --workdir /tmp' \
  'worker-run start grok --brief /tmp/brief ; grokb profile supergrok --prompt-file /tmp/brief' \
  'grokb profile supergrok' \
  'grok models' \
  'grokb list' \
  'echo "grok -p is the spelling the gate denies"' \
  'python3 grok-quota.py'; do
  gate_out=$(gate_payload "$gate_allowed" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done

# --- statusline-ports-probe.sh: grok is on the tool list -------------------------------------------
assert grep -Fq 'opencode-go|codex|grok' "$ROOT/bin/statusline-ports-probe.sh"


echo "PASS: $asserts asserts; workdir tracking, worktree/agent filtering, statusline segments, a review slot that carries a run in flight — over this tree or over another one this chat launched — and nothing else once it ends, an ATOMIC middle block computed from ONE shown tree that MOVES to the tree of this chat's own live run or unanswered round and comes home when home works, owes a review or that round is answered, with no repository name inside the counter slot and one word carried once between counter and verdict, the gate's verdict vocabulary rendered with only same-repository rev-label deduplication, the verdict asked about the shown tree, cached per tree and keyed on the checkout family's commit journal and review decision clock, both debt sides in one two-toned segment and red kept for a word this build does not know, keyed on the commit journal and asked once per key with nothing else probed behind it, an unpushed marker that is the same gate's \`unpushed\` answer word for word — never dimmed, never shown for a branch level with its upstream or for commits the gate names none of, silent with no gate to ask, and re-asked the moment the FAMILY's debt journal that decides whose the commit is moves — main-last and Gemini account predictions, and Codex/claudeb/Gemini/grok worker tag propagation with the bare-launch gate that denies the spellings they replace"
