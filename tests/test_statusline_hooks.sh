#!/usr/bin/env bash
set -u
unset WORKER_PICK_CONFIG_FILE WORKER_RUN_CONFIG_FILE

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR_HOOK="$ROOT/bin/statusline-workdir-hook.sh"
WORKER_HOOK="$ROOT/bin/worker-tag-hook.sh"
SPAWN_HOOK="$ROOT/bin/worker-spawn-hook.sh"
STATUSLINE="$ROOT/bin/statusline.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0

fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts failed: expected '$1', got '$2'"
}

cg_identity() (
  eval "$(sed -n '/^fit_cb_part() {/,/^}/p' "$STATUSLINE")"
  acct=work4; cb_show=1; fit_acct_max=0; MAGENTA=''; RESET=''
  CLAUDEGPT_ACCOUNT=$1
  fit_cb_part
  printf '%s' "$cb_part"
)
assert_eq ' main' "$(cg_identity main)"
assert_eq ' work4' "$(cg_identity work4)"
assert_eq ' work4' "$(cg_identity '')"

HOME="$WORK/home"
FIXTURES="$WORK/fixtures"
TMPDIR="$WORK/runtime-tmp"
CLAUDEB_FIX="$WORK/claudeb"
export HOME TMPDIR
mkdir -p "$HOME/.claude" "$FIXTURES" "$TMPDIR" "$CLAUDEB_FIX/limits"
CODEX_FIX="$HOME/.codex-profiles"
mkdir -p "$CODEX_FIX/work4" "$CODEX_FIX/.codexb/fast-mode"
printf '%s\n' 'service_tier = "default"' > "$CODEX_FIX/work4/config.toml"
printf '%s\n' default > "$CODEX_FIX/.codexb/fast-mode/work4"

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
CHAT_PINS_DIR="$WORK/chat-pins"
export CHAT_PINS_DIR
mkdir -p "$CHAT_PINS_DIR"
# The pin segment the ordering cases below anchor the end of the line on. A one-letter account
# pin is the shortest the slot can render (`a`), which is what keeps the width-fit fixtures honest.
PIN_MARK="${MAGENTA}a${RESET}"
write_chat_pin() { printf '%s\n' "$2" > "$CHAT_PINS_DIR/$1"; }

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

PLACE="$ROOT/bin/statusline-place"
place_set() { # session tree [main] [kind]
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "${4:-seed}" "$2" "${3:-$2}" >> "$STATE_DIR/place-$1"
}
last_tree() { tail -n 1 "$STATE_DIR/place-$1" 2>/dev/null | cut -f3; }
last_kind() { tail -n 1 "$STATE_DIR/place-$1" 2>/dev/null | cut -f2; }
place_count() { if [ -f "$STATE_DIR/place-$1" ]; then wc -l < "$STATE_DIR/place-$1" | tr -d ' '; else echo 0; fi; }

# Every write the hook makes goes to the session cache under $HOME, which these
# cases redirect; a hardcoded absolute redirect (a debug probe left in) escapes
# the sandbox entirely and no behavioural case below can see it.
assert_eq "" "$(grep -nE '(^|[[:space:]])>>?[[:space:]]*/' "$WORKDIR_HOOK" | grep -v '/dev/null')"

payload=$(workdir_payload Bash session-cd "$REPO_A" "cd '$REPO_A' && make")
run_workdir_hook "$payload"
assert test -f "$STATE_DIR/place-session-cd"
assert_eq "$TOP_A" "$(last_tree session-cd)"

payload=$(workdir_payload Bash session-cd-last "$REPO_A" "cd '$REPO_A' && cd '$REPO_B'")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-cd-last)"

payload=$(workdir_payload Bash session-cd-home "$REPO_A" 'cd "$HOME/project"')
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-cd-home)"

payload=$(workdir_payload Bash session-cd-home-braced "$REPO_A" 'cd "${HOME}/project"')
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-cd-home-braced)"

payload=$(workdir_payload Bash session-cd-tilde "$REPO_A" 'cd "~/project"')
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-cd-tilde)"

nl_cmd=$(printf "true\ncd '%s'" "$REPO_B")
payload=$(workdir_payload Bash session-cd-nl "$REPO_A" "$nl_cmd")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-cd-nl)"

payload=$(workdir_payload Bash session-cd-amp "$REPO_A" "true & cd '$REPO_B'")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-cd-amp)"

# `(cd /x && cmd)` running work is where the chat's changes go, on the first one; the unquoted
# spelling also proves the closing paren stays out of the path.
subshell_case=0
for subshell_cmd in "(cd '$REPO_B' && make)" "true && (cd '$REPO_B' && make)" "(cd $REPO_B && make)"; do
  S="session-cd-subshell-$((++subshell_case))"
  place_set "$S" "$TOP_A"
  run_workdir_hook "$(workdir_payload Bash "$S" "$REPO_A" "$subshell_cmd")"
  assert_eq "$TOP_B" "$(last_tree "$S")"
  assert_eq git "$(last_kind "$S")"
done

S="session-cd-subshell-split"
place_set "$S" "$TOP_A"
for _ in 1 2 3; do
  run_workdir_hook "$(workdir_payload Bash session-cd-subshell-split "$REPO_A" "(cd '$REPO_B' && make)")"
  run_workdir_hook "$(workdir_payload Bash session-cd-subshell-split "$REPO_A" "(cd '$REPO_D' && make)")"
done
assert_eq "$TOP_D" "$(last_tree "$S")"
assert_eq 7 "$(place_count "$S")"

# A persistent cd does move the session, so it still retargets on the first one,
# and so does a mutating `git -C`.
S="session-cd-persistent"
place_set "$S" "$TOP_A"
run_workdir_hook "$(workdir_payload Bash session-cd-persistent "$REPO_A" "cd '$REPO_B' && make")"
assert_eq "$TOP_B" "$(last_tree "$S")"

S="session-git-mut-home"
place_set "$S" "$TOP_A"
run_workdir_hook "$(workdir_payload Bash session-git-mut-home "$REPO_A" "(git -C '$REPO_B' checkout main)")"
assert_eq "$TOP_B" "$(last_tree "$S")"

# --- round 20260919T122344Z-4339d2a: what the place detector used to miss ---
last_main() { tail -n 1 "$STATE_DIR/place-$1" 2>/dev/null | cut -f4; }
place_case() { # session command [cwd] -> one event on a fresh journal seeded at TOP_A
  place_set "$1" "$TOP_A"
  run_workdir_hook "$(workdir_payload Bash "$1" "${3:-$REPO_A}" "$2")"
}

# A chat names its worktree once and works through the variable ever after: the command's own
# `NAME=value` words expand the cd, `git -C` and worktree tokens, as they already did write targets.
place_case place-var "W=$REPO_B; (cd \$W && git add f && git commit -m m)"
assert_eq "$TOP_B" "$(last_tree place-var)"
assert_eq git "$(last_kind place-var)"
assert_eq "$TOP_A" "$(last_main place-var)"
place_case place-var-unbound 'cd $NOWHERE && git commit -m m'
assert_eq "$TOP_A" "$(last_tree place-var-unbound)"

# A wrapper or a shell keyword before the cd or git opens no segment of its own.
place_case place-lead-env "env FOO=1 git -C '$REPO_B' commit -m m"
assert_eq "$TOP_B" "$(last_tree place-lead-env)"
place_case place-lead-timeout "timeout 60 git -C '$REPO_B' push"
assert_eq "$TOP_B" "$(last_tree place-lead-timeout)"
place_case place-lead-if "if true; then cd '$REPO_B' && git commit -m m; fi"
assert_eq "$TOP_B" "$(last_tree place-lead-if)"

# git's global options sit on either side of `-C`, and the mutating list is not commit alone.
place_case place-git-global "git -c commit.gpgsign=false -C '$REPO_B' --no-pager commit -m m"
assert_eq "$TOP_B" "$(last_tree place-git-global)"
place_case place-git-add "git -C '$REPO_B' add -A"
assert_eq "$TOP_B" "$(last_tree place-git-add)"
# With no `-C` at all the mutation lands where the tool ran.
place_case place-git-cwd 'git commit -m m' "$REPO_B"
assert_eq "$TOP_B" "$(last_tree place-git-cwd)"

# A non-zero exit arrives as PostToolUseFailure: the commit before the failing test still landed.
place_set place-failure "$TOP_A"
run_workdir_hook "$(workdir_payload Bash place-failure "$REPO_A" \
  "git -C '$REPO_B' commit --allow-empty -m x && false" |
  jq -c '.hook_event_name = "PostToolUseFailure" | .error = "Exit code 1"')"
assert_eq "$TOP_B" "$(last_tree place-failure)"

# A relative cd belongs to this command's own earlier cd, never to the tool's cwd; a `-` option
# token is skipped by itself and does not abort the rest of the parse.
place_case place-cd-chain "cd '$REPO_A' && cd .claude/worktrees/feature-y && git commit -m m"
assert_eq "$TOP_E" "$(last_tree place-cd-chain)"
place_case place-cd-optarg "cd -P '$REPO_B' && git commit -am m"
assert_eq "$TOP_B" "$(last_tree place-cd-optarg)"

# The strongest evidence wins its command: a commit is not undone by a read-only cd after it, a
# worktree add does not outrank a later commit elsewhere, and a later write outranks both.
place_case place-prec-subshell "git -C '$REPO_B' commit -m foo && (cd '$REPO_D' && git status)"
assert_eq "$TOP_B" "$(last_tree place-prec-subshell)"
place_case place-prec-wt "git -C '$REPO_A' worktree add /nowhere/new topic && git -C '$REPO_B' commit -m m"
assert_eq "$TOP_B" "$(last_tree place-prec-wt)"
place_case place-prec-write "cd '$REPO_A' && printf x > '$REPO_E/f'"
assert_eq "$TOP_E" "$(last_tree place-prec-write)"
assert_eq edit "$(last_kind place-prec-write)"
place_case place-prec-last-write "touch '$REPO_A/w1'; touch '$REPO_B/w2'"
assert_eq "$TOP_B" "$(last_tree place-prec-last-write)"

# More ways to write into another tree, and two more spellings of a redirect.
place_case place-write-rsync "rsync -a tracked.txt '$REPO_B/rsynced.txt'"
assert_eq "$TOP_B" "$(last_tree place-write-rsync)"
place_case place-write-install "install -m 644 tracked.txt '$REPO_B/installed'"
assert_eq "$TOP_B" "$(last_tree place-write-install)"
place_case place-write-patch "patch - -d '$REPO_B' < fix.diff"
assert_eq "$TOP_B" "$(last_tree place-write-patch)"
place_case place-write-clobber "printf x >| '$REPO_B/clobbered'"
assert_eq "$TOP_B" "$(last_tree place-write-clobber)"
place_case place-write-fd "printf x >& '$REPO_B/merged'"
assert_eq "$TOP_B" "$(last_tree place-write-fd)"
place_case place-write-tilde 'printf x > ~/project/tilded'
assert_eq "$TOP_B" "$(last_tree place-write-tilde)"

# A `#` comment is prose: its `(` and `;` must not open a segment later than the real one. An
# apostrophe inside double quotes is not a quote and pairs with nothing lines away.
place_case place-comment "git -C '$REPO_B' commit -am m # then (cd '$REPO_A' && npm i)"
assert_eq "$TOP_B" "$(last_tree place-comment)"
place_case place-apostrophe "$(printf 'echo "it'"'"'s here"\ncd %q\ngit commit -m "don'"'"'t stop"' "$REPO_B")"
assert_eq "$TOP_B" "$(last_tree place-apostrophe)"

# An Edit path is expanded like a cd token: `~` and a relative path name a tree too.
place_set place-edit-tilde "$TOP_A"
run_workdir_hook "$(workdir_payload Edit place-edit-tilde "$REPO_A" '~/project/tracked.txt')"
assert_eq "$TOP_B" "$(last_tree place-edit-tilde)"

# A `cd` inside a heredoc body or a multi-line quoted string is text a command is
# fed, not the session moving: the worktree pin, which only a persistent cd
# breaks, stays put through every spelling of the delimiter.
S="session-heredoc-bare"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-heredoc-bare "$REPO_E" \
  "$(printf "cat <<EOF\ncd '%s'\nEOF" "$REPO_D")")"
assert_eq "$TOP_E" "$(last_tree "$S")"

S="session-heredoc-quoted"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-heredoc-quoted "$REPO_E" \
  "$(printf "cat <<'EOF'\ncd '%s'\nEOF" "$REPO_D")")"
assert_eq "$TOP_E" "$(last_tree "$S")"

S="session-heredoc-dash"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-heredoc-dash "$REPO_E" \
  "$(printf "cat <<-EOF\n\tcd '%s'\n\tEOF" "$REPO_D")")"
assert_eq "$TOP_E" "$(last_tree "$S")"

# Masking may only ever LOSE a cd: the real one after the body still moves.
S="session-heredoc-then-cd"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-heredoc-then-cd "$REPO_E" \
  "$(printf "cat <<'EOF'\ncd /nowhere\nEOF\ncd '%s'" "$REPO_D")")"
assert_eq "$TOP_D" "$(last_tree "$S")"

S="session-quoted-span"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-quoted-span "$REPO_E" \
  "$(printf "echo 'first\ncd %s\nlast'" "$REPO_D")")"
assert_eq "$TOP_E" "$(last_tree "$S")"
run_workdir_hook "$(workdir_payload Bash session-quoted-span "$REPO_E" \
  "$(printf 'echo "first\ncd %s\nlast"' "$REPO_D")")"
assert_eq "$TOP_E" "$(last_tree "$S")"

# Nesting is no proof the session moved either: an inner subshell cd dies with the
# command. A brace group is not nesting — it runs in the current shell, so its cd is persistent.
S="session-cd-nested"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-cd-nested "$REPO_E" "( (cd '$REPO_D') )")"
assert_eq "$TOP_E" "$(last_tree "$S")"
run_workdir_hook "$(workdir_payload Bash session-cd-nested "$REPO_E" "{ cd '$REPO_D'; }")"
assert_eq "$TOP_D" "$(last_tree "$S")"

# No stickiness: a worktree is left on the first change elsewhere.
S="session-subshell-sticky"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-subshell-sticky "$REPO_E" "(cd '$REPO_A' && make test)")"
assert_eq "$TOP_A" "$(last_tree "$S")"

# A subshell cd whose whole chain is provably read-only writes no line, at any count.
ro_case=0
while IFS= read -r ro_cmd; do
  [ -n "$ro_cmd" ] || continue
  ro_case=$((ro_case + 1))
  S="session-ro-$ro_case"
  place_set "$S" "$TOP_A"
  for _ in 1 2 3 4 5; do
    run_workdir_hook "$(workdir_payload Bash "session-ro-$ro_case" "$REPO_A" "$ro_cmd")"
  done
  assert_eq "$TOP_A" "$(last_tree "$S")"
  assert_eq 1 "$(place_count "$S")"
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

# Anything not PROVABLY read-only is work: a surviving `>` condemns the command whatever ran it,
# the mutating traps inside reading tools (`sort -ro`, `find -fprint`, `git diff --output`) are
# read by name, and a backtick is condemned unseen.
work_case=0
while IFS= read -r work_cmd; do
  [ -n "$work_cmd" ] || continue
  work_case=$((work_case + 1))
  S="session-subshell-work-$work_case"
  place_set "$S" "$TOP_A"
  run_workdir_hook "$(workdir_payload Bash "session-subshell-work-$work_case" "$REPO_A" "$work_cmd")"
  assert_eq "$TOP_D" "$(last_tree "$S")"
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

# Nor does a lookup create a journal.
for _ in 1 2 3; do
  run_workdir_hook "$(workdir_payload Bash session-ro-fresh "$REPO_A" "(cd '$REPO_D' && git log)")"
done
assert test ! -e "$STATE_DIR/place-session-ro-fresh"

S="session-ro-sticky"
place_set "$S" "$TOP_E"
for _ in 1 2 3 4 5; do
  run_workdir_hook "$(workdir_payload Bash session-ro-sticky "$REPO_E" "(cd '$REPO_D' && git log)")"
done
assert_eq "$TOP_E" "$(last_tree "$S")"

# `cd` is the most read-only token there is, but a PERSISTENT one is the session
# itself moving, so it retargets at once with nothing else on the line.
S="session-cd-bare"
place_set "$S" "$TOP_A"
run_workdir_hook "$(workdir_payload Bash session-cd-bare "$REPO_A" "cd '$REPO_D'")"
assert_eq "$TOP_D" "$(last_tree "$S")"

payload=$(workdir_payload Bash session-pushd "$REPO_A" "pushd '$REPO_B' && make")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-pushd)"

payload=$(workdir_payload Bash session-pushd-n "$REPO_A" "pushd -n '$REPO_B'")
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/place-session-pushd-n"

place_set session-cd-dash "$TOP_A"
payload=$(workdir_payload Bash session-cd-dash "$REPO_B" "cd -")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(last_tree session-cd-dash)"

payload=$(workdir_payload Bash session-git-ro "$REPO_A" "git -C \"$REPO_B\" status")
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/place-session-git-ro"

payload=$(workdir_payload Bash session-git-mut "$REPO_A" "git -C \"$REPO_B\" checkout main")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-git-mut)"

WT_ADD_BASIC="$FIXTURES/wt-add-basic"
git -C "$REPO_A" branch hook-wt-basic
git -C "$REPO_A" worktree add -q "$WT_ADD_BASIC" hook-wt-basic
payload=$(workdir_payload Bash session-wt-add-basic "$REPO_A" \
  "git worktree add $WT_ADD_BASIC hook-wt-basic")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_BASIC" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-basic)"

WT_ADD_BEFORE="$FIXTURES/wt-add-before"
git -C "$REPO_A" worktree add -q -b hook-wt-before "$WT_ADD_BEFORE" HEAD
payload=$(workdir_payload Bash session-wt-add-before "$REPO_A" \
  "git worktree add -b hook-wt-before $WT_ADD_BEFORE HEAD")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_BEFORE" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-before)"

WT_ADD_AFTER="$FIXTURES/wt-add-after"
git -C "$REPO_A" worktree add -q "$WT_ADD_AFTER" -b hook-wt-after HEAD
payload=$(workdir_payload Bash session-wt-add-after "$REPO_A" \
  "git worktree add $WT_ADD_AFTER -b hook-wt-after HEAD")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_AFTER" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-after)"

WT_ADD_REASON="$FIXTURES/wt-add-reason"
git -C "$REPO_A" branch hook-wt-reason
git -C "$REPO_A" worktree add -q --lock --reason my-note "$WT_ADD_REASON" hook-wt-reason
payload=$(workdir_payload Bash session-wt-add-reason "$REPO_A" \
  "git worktree add --lock --reason my-note $WT_ADD_REASON hook-wt-reason")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_REASON" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-reason)"

WT_ADD_ORPHAN="$FIXTURES/wt-add-orphan"
git -C "$REPO_A" worktree add -q --orphan "$WT_ADD_ORPHAN"
payload=$(workdir_payload Bash session-wt-add-orphan "$REPO_A" \
  "git worktree add --orphan $WT_ADD_ORPHAN")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_ORPHAN" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-orphan)"

WT_ADD_SPACE="$FIXTURES/wt add space"
git -C "$REPO_A" worktree add -q -b hook-wt-space "$WT_ADD_SPACE" HEAD
payload=$(workdir_payload Bash session-wt-add-space "$REPO_A" \
  "git worktree add -b hook-wt-space '$WT_ADD_SPACE' HEAD")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_SPACE" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-space)"

WT_ADD_REL="$REPO_A/.claude/worktrees/hook-wt-relative"
git -C "$REPO_A" branch hook-wt-relative
git -C "$REPO_A" worktree add -q ".claude/worktrees/hook-wt-relative" hook-wt-relative
payload=$(workdir_payload Bash session-wt-add-relative "$REPO_D" \
  "git -C '$REPO_A' worktree add .claude/worktrees/hook-wt-relative hook-wt-relative")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_REL" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-relative)"

WT_ADD_AFTER_CD="$REPO_A/.claude/worktrees/hook-wt-after-cd"
git -C "$REPO_A" branch hook-wt-after-cd
git -C "$REPO_A" worktree add -q ".claude/worktrees/hook-wt-after-cd" hook-wt-after-cd
place_set session-wt-add-after-cd "$TOP_D"
payload=$(workdir_payload Bash session-wt-add-after-cd "$REPO_D" \
  "cd '$REPO_A' && git worktree add .claude/worktrees/hook-wt-after-cd hook-wt-after-cd")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_AFTER_CD" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-after-cd)"

# The bootstrap subshell a worktree add is followed by cds INTO the new worktree: read as the
# add's base, it resolves the relative path inside the tree that was just created.
WT_ADD_BOOTSTRAP="$REPO_A/.claude/worktrees/hook-wt-bootstrap"
git -C "$REPO_A" branch hook-wt-bootstrap
git -C "$REPO_A" worktree add -q ".claude/worktrees/hook-wt-bootstrap" hook-wt-bootstrap
place_set session-wt-add-bootstrap "$TOP_D"
payload=$(workdir_payload Bash session-wt-add-bootstrap "$REPO_D" \
  "cd '$REPO_A' && git worktree add .claude/worktrees/hook-wt-bootstrap hook-wt-bootstrap && (cd .claude/worktrees/hook-wt-bootstrap && git status)")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_BOOTSTRAP" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-bootstrap)"

WT_ADD_FAILED="$FIXTURES/wt-add-failed"
if git -C "$REPO_A" worktree add "$WT_ADD_FAILED" no-such-worktree-ref >/dev/null 2>&1; then
  fail "failed worktree-add fixture unexpectedly succeeded"
fi
assert test ! -e "$WT_ADD_FAILED"
place_set session-wt-add-failed "$TOP_A"
payload=$(workdir_payload Bash session-wt-add-failed "$REPO_A" \
  "git worktree add $WT_ADD_FAILED no-such-worktree-ref")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(last_tree session-wt-add-failed)"

WT_ADD_EXISTING="$REPO_D/existing-worktree-target"
mkdir -p "$WT_ADD_EXISTING"
printf 'occupied\n' > "$WT_ADD_EXISTING/blocker"
git -C "$REPO_A" branch hook-wt-existing
if git -C "$REPO_A" worktree add "$WT_ADD_EXISTING" hook-wt-existing >/dev/null 2>&1; then
  fail "existing-directory worktree-add fixture unexpectedly succeeded"
fi
place_set session-wt-add-existing "$TOP_E"
payload=$(workdir_payload Bash session-wt-add-existing "$REPO_A" \
  "git worktree add '$WT_ADD_EXISTING' hook-wt-existing")
run_workdir_hook "$payload"
assert_eq "$TOP_E" "$(last_tree session-wt-add-existing)"
rm -f "$WT_ADD_EXISTING/blocker"
rmdir "$WT_ADD_EXISTING"

# A persistent cd on a later line does not outrank the add above it.
WT_ADD_MULTILINE="$FIXTURES/wt-add-multiline"
git -C "$REPO_A" branch hook-wt-multiline
git -C "$REPO_A" worktree add -q "$WT_ADD_MULTILINE" hook-wt-multiline
multiline_cmd=$(printf "git worktree add %s hook-wt-multiline\ncd '%s'" "$WT_ADD_MULTILINE" "$REPO_D")
place_set session-wt-add-multiline "$TOP_A"
payload=$(workdir_payload Bash session-wt-add-multiline "$REPO_A" "$multiline_cmd")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_MULTILINE" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-multiline)"

EXCLUDED_WT_BASE="$HOME/.claude/worktree-add-base"
ln -s "$REPO_A" "$EXCLUDED_WT_BASE"
WT_ADD_ABSOLUTE="$FIXTURES/wt-add-absolute"
git -C "$REPO_A" branch hook-wt-absolute
git -C "$EXCLUDED_WT_BASE" worktree add -q "$WT_ADD_ABSOLUTE" hook-wt-absolute
place_set session-wt-add-absolute "$TOP_E"
payload=$(workdir_payload Bash session-wt-add-absolute "$REPO_E" \
  "git -C '$EXCLUDED_WT_BASE' worktree add '$WT_ADD_ABSOLUTE' hook-wt-absolute")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_ABSOLUTE" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-absolute)"
rm -f "$EXCLUDED_WT_BASE"

WT_ADD_STICKY="$REPO_A/.claude/worktrees/hook-wt-sticky"
git -C "$REPO_A" worktree add -q -b hook-wt-sticky "$WT_ADD_STICKY" HEAD
place_set session-wt-add-sticky "$TOP_E"
payload=$(workdir_payload Bash session-wt-add-sticky "$REPO_E" \
  "git worktree add -b hook-wt-sticky '$WT_ADD_STICKY' HEAD")
run_workdir_hook "$payload"
assert_eq "$(git -C "$WT_ADD_STICKY" rev-parse --show-toplevel)" \
  "$(last_tree session-wt-add-sticky)"

# The created path is read from the worktree list — snapshotted at PreToolUse,
# diffed at PostToolUse — so the form that expands in the shell, which is what a
# real dispatch writes and what no text parser can follow, retargets as well.
WT_ADD_VAR="$REPO_A/.claude/worktrees/hook-wt-var"
VAR_CMD='R="'"$REPO_A"'"; N=$R/.claude/worktrees/hook-wt-var; git -C "$R" worktree add -b hook-wt-var "$N" HEAD'
S="session-wt-add-var"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-var "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse"')"
assert test -f "$STATE_DIR/place-$S.snap"
git -C "$REPO_A" worktree add -q -b hook-wt-var "$WT_ADD_VAR" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-var "$REPO_E" "$VAR_CMD")"
assert_eq "$(git -C "$WT_ADD_VAR" rev-parse --show-toplevel)" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap"

# An add that created nothing — and one that cannot be told from a concurrent
# add — journal nothing rather than guess at a path.
S="session-wt-add-failed"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-failed "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse"')"
run_workdir_hook "$(workdir_payload Bash session-wt-add-failed "$REPO_E" "$VAR_CMD")"
assert_eq "$TOP_E" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap"

S="session-wt-add-two"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-two "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse"')"
git -C "$REPO_A" worktree add -q -b hook-wt-two-a "$REPO_A/.claude/worktrees/hook-wt-two-a" HEAD
git -C "$REPO_A" worktree add -q -b hook-wt-two-b "$REPO_A/.claude/worktrees/hook-wt-two-b" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-two "$REPO_E" "$VAR_CMD")"
assert_eq "$TOP_E" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap"

# One snapshot per CALL, keyed on the id both of its events carry: two adds whose
# Pre/Post interleave each measure their own baseline, so the first Post cannot
# adopt what the second add made and the second still finds a baseline of its own.
WT_ADD_ILA="$REPO_A/.claude/worktrees/hook-wt-il-a"
WT_ADD_ILB="$REPO_A/.claude/worktrees/hook-wt-il-b"
# A path no assignment of the command itself can spell: the snapshot is all there is to go on.
IL_CMD='N=$(mktemp -u); git -C "'"$REPO_A"'" worktree add -b hook-wt-il "$N" HEAD'
S="session-wt-add-il"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-il "$REPO_E" "$IL_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-a"')"
git -C "$REPO_A" worktree add -q -b hook-wt-il-a "$WT_ADD_ILA" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-il "$REPO_E" "$IL_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-b"')"
assert test -f "$STATE_DIR/place-$S.snap.call-a"
assert test -f "$STATE_DIR/place-$S.snap.call-b"
git -C "$REPO_A" worktree add -q -b hook-wt-il-b "$WT_ADD_ILB" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-il "$REPO_E" "$IL_CMD" |
  jq -c '.tool_use_id = "call-a"')"
assert_eq "$TOP_E" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap.call-a"
run_workdir_hook "$(workdir_payload Bash session-wt-add-il "$REPO_E" "$IL_CMD" |
  jq -c '.tool_use_id = "call-b"')"
assert_eq "$(git -C "$WT_ADD_ILB" rev-parse --show-toplevel)" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap.call-b"

# With no repository to snapshot there must be no snapshot at all: an empty one is
# a baseline that answers nothing, and the text-parsed path is then never tried.
WT_ADD_EMPTY="$FIXTURES/wt-add-empty"
S="session-wt-add-empty"
rm -f "$STATE_DIR/place-$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-empty "$NON_GIT" \
  "git worktree add $WT_ADD_EMPTY hook-wt-empty" | jq -c '.hook_event_name = "PreToolUse"')"
assert test ! -e "$STATE_DIR/place-$S.snap"
git -C "$REPO_A" branch hook-wt-empty
git -C "$REPO_A" worktree add -q "$WT_ADD_EMPTY" hook-wt-empty
run_workdir_hook "$(workdir_payload Bash session-wt-add-empty "$NON_GIT" \
  "git worktree add $WT_ADD_EMPTY hook-wt-empty")"
assert_eq "$(git -C "$WT_ADD_EMPTY" rev-parse --show-toplevel)" "$(last_tree "$S")"

# A concurrent add in the same family is a single new path too. When the command
# names a directory that exists, the worktree it made is the only one that path
# can be, so anything else is somebody else's.
WT_ADD_TAKEN="$REPO_D/wt-add-taken"
mkdir -p "$WT_ADD_TAKEN"
WT_ADD_RIVAL="$REPO_A/.claude/worktrees/hook-wt-rival"
RIVAL_CMD="git -C '$REPO_A' worktree add '$WT_ADD_TAKEN' hook-wt-rival"
S="session-wt-add-rival"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-rival "$REPO_E" "$RIVAL_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-rival"')"
git -C "$REPO_A" worktree add -q -b hook-wt-rival "$WT_ADD_RIVAL" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-rival "$REPO_E" "$RIVAL_CMD" |
  jq -c '.tool_use_id = "call-rival"')"
assert_eq "$TOP_E" "$(last_tree "$S")"

WT_ADD_NAMED="$REPO_A/.claude/worktrees/hook-wt-named"
NAMED_CMD="git -C '$REPO_A' worktree add -b hook-wt-named '$WT_ADD_NAMED' HEAD"
S="session-wt-add-named"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-named "$REPO_E" "$NAMED_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-named"')"
git -C "$REPO_A" worktree add -q -b hook-wt-named "$WT_ADD_NAMED" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-named "$REPO_E" "$NAMED_CMD" |
  jq -c '.tool_use_id = "call-named"')"
assert_eq "$(git -C "$WT_ADD_NAMED" rev-parse --show-toplevel)" "$(last_tree "$S")"

# The shape a real dispatch writes: the add, then a bootstrap subshell inside the
# worktree it made. Reading the last hit gave that cd, whose `$W` resolves
# nowhere, and the add was never heard.
WT_ADD_BOOT="$REPO_A/.claude/worktrees/hook-wt-boot"
BOOT_CMD=$(printf 'R=%s\ngit -C $R worktree add -b hook-wt-boot $R/.claude/worktrees/hook-wt-boot HEAD 2>&1 | tail -2\nW=$R/.claude/worktrees/hook-wt-boot\n(cd $W && pnpm install --frozen-lockfile 2>&1 | tail -3 && pnpm nx --version)' "$REPO_A")
S="session-wt-add-boot"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-boot "$REPO_E" "$BOOT_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-boot"')"
git -C "$REPO_A" worktree add -q -b hook-wt-boot "$WT_ADD_BOOT" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-boot "$REPO_E" "$BOOT_CMD" |
  jq -c '.tool_use_id = "call-boot"')"
assert_eq "$(git -C "$WT_ADD_BOOT" rev-parse --show-toplevel)" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap.call-boot"

WT_ADD_ELSEWHERE="$REPO_A/.claude/worktrees/hook-wt-elsewhere"
ELSEWHERE_CMD=$(printf 'R=%s\ngit -C $R worktree add -b hook-wt-elsewhere $R/.claude/worktrees/hook-wt-elsewhere HEAD\n(cd %s && ls)' "$REPO_A" "$REPO_D")
S="session-wt-add-elsewhere"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-elsewhere "$REPO_E" "$ELSEWHERE_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-elsewhere"')"
git -C "$REPO_A" worktree add -q -b hook-wt-elsewhere "$WT_ADD_ELSEWHERE" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-elsewhere "$REPO_E" "$ELSEWHERE_CMD" |
  jq -c '.tool_use_id = "call-elsewhere"')"
assert_eq "$(git -C "$WT_ADD_ELSEWHERE" rev-parse --show-toplevel)" "$(last_tree "$S")"

# A denied command fires PreToolUse and never the PostToolUse that consumes its
# snapshot, so the leaked file is swept an hour later rather than after a week.
S="session-wt-prune"
place_set "$S" "$TOP_A"
: > "$STATE_DIR/place-$S.snap.call-leaked"
: > "$STATE_DIR/place-$S.snap.call-live"
# Two hours, not eight days: the week-long `place-*` sweep must not be what takes it.
leaked_stamp=$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)
touch -t "$leaked_stamp" "$STATE_DIR/place-$S.snap.call-leaked"
touch -t 202001010000 "$STATE_DIR/.place-prune"
run_workdir_hook "$(workdir_payload Bash session-wt-prune "$REPO_A" "cd '$REPO_B'")"
assert_eq "$TOP_B" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap.call-leaked"
assert test -f "$STATE_DIR/place-$S.snap.call-live"
rm -f "$STATE_DIR/place-$S.snap.call-live"

# The live miss: one Bash call, `R=...; git -C "$R" worktree add "$R/.claude/worktrees/..." -b
# name ref 2>&1 | tail`, then a for-loop of curls. cwd is already a worktree of the same
# repo; the path token is an unexpanded `$R/...` so the list diff must name the new worktree.
WT_ADD_REAL="$REPO_A/.claude/worktrees/hook-wt-real"
REAL_CMD='R="'"$REPO_A"'"; git -C "$R" worktree add "$R/.claude/worktrees/hook-wt-real" -b hook-wt-real HEAD 2>&1 | tail -2; echo ---PROBE-STAGING; for u in "https://example.com/a?embedded=portal" "https://example.com/b"; do curl -s -o /dev/null -w "%{http_code} %{redirect_url} $u\n" -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36" -e "https://example.com/" "$u"; done'
S="session-wt-add-real"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-real "$REPO_E" "$REAL_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-real"')"
assert test -f "$STATE_DIR/place-$S.snap.call-real"
git -C "$REPO_A" worktree add -q -b hook-wt-real "$WT_ADD_REAL" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-real "$REPO_E" "$REAL_CMD" |
  jq -c '.tool_use_id = "call-real"')"
assert_eq "$(git -C "$WT_ADD_REAL" rev-parse --show-toplevel)" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap.call-real"

# Same phrasing with an empty journal: the add is still journaled.
WT_ADD_REAL0="$REPO_A/.claude/worktrees/hook-wt-real0"
REAL0_CMD='R="'"$REPO_A"'"; git -C "$R" worktree add "$R/.claude/worktrees/hook-wt-real0" -b hook-wt-real0 HEAD 2>&1 | tail -2'
S="session-wt-add-real0"
rm -f "$STATE_DIR/place-$S"
run_workdir_hook "$(workdir_payload Bash session-wt-add-real0 "$REPO_E" "$REAL0_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-real0"')"
assert test -f "$STATE_DIR/place-$S.snap.call-real0"
git -C "$REPO_A" worktree add -q -b hook-wt-real0 "$WT_ADD_REAL0" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-real0 "$REPO_E" "$REAL0_CMD" |
  jq -c '.tool_use_id = "call-real0"')"
assert_eq "$(git -C "$WT_ADD_REAL0" rev-parse --show-toplevel)" "$(last_tree "$S")"

# Unquoted `$R` in -C and the path, on a repo whose path has no spaces.
mkdir -p "$REPO_D/.claude/worktrees"
printf '.claude/worktrees/\n' >> "$REPO_D/.git/info/exclude"
WT_ADD_UQ="$REPO_D/.claude/worktrees/hook-wt-unquoted"
UQ_CMD="R=$REPO_D; git -C \$R worktree add \$R/.claude/worktrees/hook-wt-unquoted -b hook-wt-unquoted HEAD"
S="session-wt-add-uq"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-uq "$REPO_D" "$UQ_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-uq"')"
assert test -f "$STATE_DIR/place-$S.snap.call-uq"
git -C "$REPO_D" worktree add -q -b hook-wt-unquoted "$WT_ADD_UQ" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-uq "$REPO_D" "$UQ_CMD" |
  jq -c '.tool_use_id = "call-uq"')"
assert_eq "$(git -C "$WT_ADD_UQ" rev-parse --show-toplevel)" "$(last_tree "$S")"

# `$W` holds the new path.
WT_ADD_WVAR="$REPO_A/.claude/worktrees/hook-wt-wvar"
WVAR_CMD='R="'"$REPO_A"'"; W=$R/.claude/worktrees/hook-wt-wvar; git -C "$R" worktree add "$W" -b hook-wt-wvar HEAD'
S="session-wt-add-wvar"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-wvar "$REPO_E" "$WVAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-wvar"')"
git -C "$REPO_A" worktree add -q -b hook-wt-wvar "$WT_ADD_WVAR" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-wvar "$REPO_E" "$WVAR_CMD" |
  jq -c '.tool_use_id = "call-wvar"')"
assert_eq "$(git -C "$WT_ADD_WVAR" rev-parse --show-toplevel)" "$(last_tree "$S")"

# `-B` after a concatenated `$R/...` path.
WT_ADD_BB="$REPO_A/.claude/worktrees/hook-wt-bb"
BB_CMD='R="'"$REPO_A"'"; git -C "$R" worktree add "$R/.claude/worktrees/hook-wt-bb" -B hook-wt-bb HEAD'
S="session-wt-add-bb"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-bb "$REPO_E" "$BB_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-bb"')"
git -C "$REPO_A" worktree add -q -B hook-wt-bb "$WT_ADD_BB" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-bb "$REPO_E" "$BB_CMD" |
  jq -c '.tool_use_id = "call-bb"')"
assert_eq "$(git -C "$WT_ADD_BB" rev-parse --show-toplevel)" "$(last_tree "$S")"

# Relative path with variable `-C`.
WT_ADD_RELVAR="$REPO_A/.claude/worktrees/hook-wt-relvar"
RELVAR_CMD='R="'"$REPO_A"'"; git -C "$R" worktree add .claude/worktrees/hook-wt-relvar -b hook-wt-relvar HEAD'
S="session-wt-add-relvar"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-relvar "$REPO_E" "$RELVAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-relvar"')"
git -C "$REPO_A" worktree add -q -b hook-wt-relvar "$WT_ADD_RELVAR" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-relvar "$REPO_E" "$RELVAR_CMD" |
  jq -c '.tool_use_id = "call-relvar"')"
assert_eq "$(git -C "$WT_ADD_RELVAR" rev-parse --show-toplevel)" "$(last_tree "$S")"

# A relative path is named against `-C`, never the session cwd, even where the cwd holds a
# directory of the same name.
WT_ADD_RELBASE="$REPO_A/.claude/worktrees/hook-wt-relbase"
mkdir -p "$REPO_E/.claude/worktrees/hook-wt-relbase"
S="session-wt-add-relbase"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash "$S" "$REPO_E" \
  "git -C '$REPO_A' worktree add .claude/worktrees/hook-wt-relbase -b hook-wt-relbase HEAD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-relbase"')"
git -C "$REPO_A" worktree add -q -b hook-wt-relbase "$WT_ADD_RELBASE" HEAD
run_workdir_hook "$(workdir_payload Bash "$S" "$REPO_E" \
  "git -C '$REPO_A' worktree add .claude/worktrees/hook-wt-relbase -b hook-wt-relbase HEAD" |
  jq -c '.tool_use_id = "call-relbase"')"
assert_eq "$(git -C "$WT_ADD_RELBASE" rev-parse --show-toplevel)" "$(last_tree "$S")"
rmdir "$REPO_E/.claude/worktrees/hook-wt-relbase"

# Add then a bootstrap subshell whose `$W` resolves nowhere — add still wins.
WT_ADD_BOOTR="$REPO_A/.claude/worktrees/hook-wt-bootr"
BOOTR_CMD='R="'"$REPO_A"'"; git -C "$R" worktree add "$R/.claude/worktrees/hook-wt-bootr" -b hook-wt-bootr HEAD && W=$R/.claude/worktrees/hook-wt-bootr && (cd "$W" && true)'
S="session-wt-add-bootr"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-add-bootr "$REPO_E" "$BOOTR_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-bootr"')"
git -C "$REPO_A" worktree add -q -b hook-wt-bootr "$WT_ADD_BOOTR" HEAD
run_workdir_hook "$(workdir_payload Bash session-wt-add-bootr "$REPO_E" "$BOOTR_CMD" |
  jq -c '.tool_use_id = "call-bootr"')"
assert_eq "$(git -C "$WT_ADD_BOOTR" rev-parse --show-toplevel)" "$(last_tree "$S")"

# `git worktree move` journals the destination.
WT_MOVE_SRC="$REPO_A/.claude/worktrees/hook-wt-move-src"
WT_MOVE_DST="$REPO_A/.claude/worktrees/hook-wt-move-dst"
git -C "$REPO_A" worktree add -q -b hook-wt-move-src "$WT_MOVE_SRC" HEAD
MOVE_CMD='R="'"$REPO_A"'"; git -C "$R" worktree move "$R/.claude/worktrees/hook-wt-move-src" "$R/.claude/worktrees/hook-wt-move-dst"'
S="session-wt-move"
place_set "$S" "$(git -C "$WT_MOVE_SRC" rev-parse --show-toplevel)"
run_workdir_hook "$(workdir_payload Bash session-wt-move "$REPO_E" "$MOVE_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-move"')"
assert test -f "$STATE_DIR/place-$S.snap.call-move"
git -C "$REPO_A" worktree move "$WT_MOVE_SRC" "$WT_MOVE_DST"
run_workdir_hook "$(workdir_payload Bash session-wt-move "$REPO_E" "$MOVE_CMD" |
  jq -c '.tool_use_id = "call-move"')"
assert_eq "$(git -C "$WT_MOVE_DST" rev-parse --show-toplevel)" "$(last_tree "$S")"
assert test ! -e "$STATE_DIR/place-$S.snap.call-move"

# A journal tree under the moved-from path does not confuse the diff.
WT_MOVE_SRC2="$REPO_A/.claude/worktrees/hook-wt-move-src2"
WT_MOVE_DST2="$REPO_A/.claude/worktrees/hook-wt-move-dst2"
git -C "$REPO_A" worktree add -q -b hook-wt-move-src2 "$WT_MOVE_SRC2" HEAD
mkdir -p "$WT_MOVE_SRC2/embed-skin"
MOVE2_CMD='R="'"$REPO_A"'"; git -C "$R" worktree move "$R/.claude/worktrees/hook-wt-move-src2" "$R/.claude/worktrees/hook-wt-move-dst2"'
S="session-wt-move-under"
place_set "$S" "$WT_MOVE_SRC2/embed-skin"
run_workdir_hook "$(workdir_payload Bash session-wt-move-under "$REPO_E" "$MOVE2_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-move2"')"
git -C "$REPO_A" worktree move "$WT_MOVE_SRC2" "$WT_MOVE_DST2"
run_workdir_hook "$(workdir_payload Bash session-wt-move-under "$REPO_E" "$MOVE2_CMD" |
  jq -c '.tool_use_id = "call-move2"')"
assert_eq "$(git -C "$WT_MOVE_DST2" rev-parse --show-toplevel)" "$(last_tree "$S")"

# A move of any worktree is where the chat's changes go next.
WT_MOVE_SRC3="$REPO_A/.claude/worktrees/hook-wt-move-src3"
WT_MOVE_DST3="$REPO_A/.claude/worktrees/hook-wt-move-dst3"
git -C "$REPO_A" worktree add -q -b hook-wt-move-src3 "$WT_MOVE_SRC3" HEAD
MOVE3_CMD='R="'"$REPO_A"'"; git -C "$R" worktree move "$R/.claude/worktrees/hook-wt-move-src3" "$R/.claude/worktrees/hook-wt-move-dst3"'
S="session-wt-move-other"
place_set "$S" "$TOP_E"
run_workdir_hook "$(workdir_payload Bash session-wt-move-other "$REPO_E" "$MOVE3_CMD" |
  jq -c '.hook_event_name = "PreToolUse" | .tool_use_id = "call-move3"')"
git -C "$REPO_A" worktree move "$WT_MOVE_SRC3" "$WT_MOVE_DST3"
run_workdir_hook "$(workdir_payload Bash session-wt-move-other "$REPO_E" "$MOVE3_CMD" |
  jq -c '.tool_use_id = "call-move3"')"
assert_eq "$(git -C "$WT_MOVE_DST3" rev-parse --show-toplevel)" "$(last_tree "$S")"

# With no baseline the parsed destination is taken, being its own toplevel.
WT_MOVE_SRC4="$REPO_A/.claude/worktrees/hook-wt-move-src4"
WT_MOVE_DST4="$REPO_A/.claude/worktrees/hook-wt-move-dst4"
git -C "$REPO_A" worktree add -q -b hook-wt-move-src4 "$WT_MOVE_SRC4" HEAD
MOVE4_CMD="git -C '$REPO_A' worktree move '$WT_MOVE_SRC4' '$WT_MOVE_DST4'"
S="session-wt-move-nosnap"
place_set "$S" "$TOP_E"
git -C "$REPO_A" worktree move "$WT_MOVE_SRC4" "$WT_MOVE_DST4"
run_workdir_hook "$(workdir_payload Bash session-wt-move-nosnap "$REPO_E" "$MOVE4_CMD" |
  jq -c '.tool_use_id = "call-move4"')"
assert_eq "$(git -C "$WT_MOVE_DST4" rev-parse --show-toplevel)" "$(last_tree "$S")"

# `worktree` is mutating only for the subcommands that write one: a lookup writes no line.
place_set session-wt-list "$TOP_A"
payload=$(workdir_payload Bash session-wt-list "$REPO_A" "git -C '$REPO_B' worktree list")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(last_tree session-wt-list)"

place_set session-wt-bare "$TOP_A"
payload=$(workdir_payload Bash session-wt-bare "$REPO_A" "git -C '$REPO_B' worktree")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(last_tree session-wt-bare)"

# A subcommand is read on the `git -C` line only: reaching across the line break
# would eat the next line's `cd` as the subcommand and lose the move entirely.
place_set session-wt-nl "$TOP_A"
payload=$(workdir_payload Bash session-wt-nl "$REPO_A" \
  "$(printf "git -C '%s' worktree\ncd '%s'" "$REPO_B" "$REPO_D")")
run_workdir_hook "$payload"
assert_eq "$TOP_D" "$(last_tree session-wt-nl)"

place_set session-wt-prune-sub "$TOP_A"
payload=$(workdir_payload Bash session-wt-prune-sub "$REPO_A" "git -C '$REPO_B' worktree prune")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-wt-prune-sub)"

payload=$(workdir_payload Bash session-cd-then-ro "$REPO_A" "cd '$REPO_B' && git -C '$REPO_A' log")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-cd-then-ro)"

place_set session-plain "$TOP_B"
payload=$(workdir_payload Bash session-plain "$REPO_A" "printf done")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree session-plain)"

place_set session-tmp "$TOP_A"
payload=$(workdir_payload Bash session-tmp "$REPO_A" "cd /tmp && pwd")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(last_tree session-tmp)"

payload=$(workdir_payload Bash session-non-git "$REPO_A" "cd '$NON_GIT' && pwd")
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/place-session-non-git"

payload=$(workdir_payload Edit session-edit "$REPO_B" "$REPO_A/tracked.txt")
run_workdir_hook "$payload"
assert_eq "$TOP_A" "$(last_tree session-edit)"

payload=$(workdir_payload Edit ../evil "$REPO_A" "$REPO_B/tracked.txt")
run_workdir_hook "$payload"
assert_eq "$TOP_B" "$(last_tree evil)"
assert test ! -e "$HOME/.cache/evil"

payload=$(workdir_payload Bash session-agent "$REPO_A" "cd '$REPO_B'" | jq -c '. + {agent_id:"a1",agent_type:"claudeb-worker"}')
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/place-session-agent"

# A subagent's shell is not the chat's: its cds write nothing.
S="session-agent-cds"
place_set "$S" "$TOP_A"
run_workdir_hook "$(agent_payload Bash "$S" "$REPO_A" "cd '$REPO_D' && make")"
run_workdir_hook "$(agent_payload Bash "$S" "$REPO_A" "(cd '$REPO_D' && make)")"
assert_eq 1 "$(place_count "$S")"

# Its edits are the chat's changes like any other, on the first one.
S="session-agent-edit"
place_set "$S" "$TOP_E"
run_workdir_hook "$(agent_payload Edit "$S" "$REPO_E" "$REPO_D/other.txt")"
assert_eq "$TOP_D" "$(last_tree "$S")"
assert_eq edit "$(last_kind "$S")"
run_workdir_hook "$(agent_payload Write "$S" "$REPO_E" "$HOME/.cache/x/file.txt")"
run_workdir_hook "$(agent_payload Read "$S" "$REPO_E" "$REPO_A/tracked.txt")"
assert_eq 2 "$(place_count "$S")"

dispatch_payload() {
  jq -cn --arg event "${5:-PreToolUse}" --arg tool "$1" --arg session "$2" --arg cwd "$3" --arg prompt "$4" \
    '{hook_event_name:$event,tool_name:$tool,session_id:$session,cwd:$cwd,tool_input:{prompt:$prompt}}'
}

# Dispatching a worker is the only signal an orchestrator session emits: the
# edits themselves happen in another process, at a path the parent never visits.
# The brief names that path, so the dispatch counts as a write — the harness
# calls the tool Task or Agent depending on its version, and both are heard.
for tool in Task Agent; do
  S="session-dispatch-$tool"
  place_set "$S" "$TOP_A"
  run_workdir_hook "$(dispatch_payload "$tool" "session-dispatch-$tool" "$REPO_A" \
    "Work in the main checkout: cd '$REPO_D' && run the suite.")"
  assert_eq "$TOP_D" "$(last_tree "$S")"
done

# First RESOLVABLE path, not first path: briefs open with excluded config paths,
# file names and prose before naming the workspace, and only a directory that is
# in a repository says where the worker will run.
S="session-dispatch-skip"
place_set "$S" "$TOP_A"
run_workdir_hook "$(dispatch_payload Task session-dispatch-skip "$REPO_A" \
  "Read $HOME/.claude/agents/worker.md, then $REPO_B/tracked.txt and /nonexistent/place; work in $REPO_D")"
assert_eq "$TOP_D" "$(last_tree "$S")"

# The ten-token cap counts CANDIDATES, not raw matches: prose punctuation leaves
# tokens that are a bare slash once trailing dots are stripped, and letting those
# eat cap slots dropped the workspace named eleventh in the raw scan.
S="session-dispatch-cap"
place_set "$S" "$TOP_A"
run_workdir_hook "$(dispatch_payload Task session-dispatch-cap "$REPO_A" \
  "Start at /. then /... then /nonexistent/a1 /nonexistent/a2 /nonexistent/a3 /nonexistent/a4 \
/nonexistent/a5 /nonexistent/a6 /nonexistent/a7 /nonexistent/a8 /nonexistent/a9 and work in $REPO_D")"
assert_eq "$TOP_D" "$(last_tree "$S")"

S="session-dispatch-nopath"
place_set "$S" "$TOP_A"
run_workdir_hook "$(dispatch_payload Task session-dispatch-nopath "$REPO_A" "Summarise the review findings.")"
assert_eq "$TOP_A" "$(last_tree "$S")"

# A worker dispatching its own subagent says nothing about where the SESSION
# works, and its brief would drag the parent strip along.
S="session-dispatch-agent"
place_set "$S" "$TOP_A"
run_workdir_hook "$(dispatch_payload Task session-dispatch-agent "$REPO_A" "cd '$REPO_D' && fix it" \
  | jq -c '. + {agent_id:"a1",agent_type:"claudeb-worker"}')"
assert_eq "$TOP_A" "$(last_tree "$S")"

# Only the launch counts: the same brief arrives again when the worker returns,
# and hearing it twice would let one dispatch fill two thirds of the run.
S="session-dispatch-post"
place_set "$S" "$TOP_A"
run_workdir_hook "$(dispatch_payload Task session-dispatch-post "$REPO_A" "cd '$REPO_D' && fix it" PostToolUse)"
assert_eq "$TOP_A" "$(last_tree "$S")"

S="session-dispatch-wt"
place_set "$S" "$TOP_E"
run_workdir_hook "$(dispatch_payload Task "$S" "$REPO_E" "cd '$REPO_D' && build")"
assert_eq "$TOP_D" "$(last_tree "$S")"
assert_eq dispatch "$(last_kind "$S")"

# A repository the journal excludes writes nothing, so the next candidate is still tried.
DISPATCH_EXCLUDED="$HOME/.cache/dispatch-excluded"
git init -q "$DISPATCH_EXCLUDED"
S="session-dispatch-excluded"
place_set "$S" "$TOP_A"
run_workdir_hook "$(dispatch_payload Task "$S" "$REPO_A" "Scratch in $DISPATCH_EXCLUDED, then work in $REPO_D")"
assert_eq "$TOP_D" "$(last_tree "$S")"

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

# The chat's own reads are no change at all, in any quantity.
S="session-read"
place_set "$S" "$TOP_A"
for _ in 1 2 3; do
  run_workdir_hook "$(workdir_payload Read "$S" "$REPO_A" "$REPO_D/other.txt")"
done
assert_eq 1 "$(place_count "$S")"
run_workdir_hook "$(workdir_payload Read session-read-fresh "$REPO_A" "$REPO_D/other.txt")"
assert test ! -e "$STATE_DIR/place-session-read-fresh"

S="session-notebook"
run_workdir_hook "$(workdir_payload NotebookEdit "$S" "$REPO_A" "$REPO_D/nb.ipynb")"
assert_eq "$TOP_D" "$(last_tree "$S")"

enter_payload() { # session cwd tool_response-json
  jq -cn --arg session "$1" --arg cwd "$2" --argjson resp "$3" \
    '{hook_event_name:"PostToolUse",tool_name:"EnterWorktree",session_id:$session,cwd:$cwd,tool_input:{},tool_response:$resp}'
}
S="session-enter"
place_set "$S" "$TOP_A"
run_workdir_hook "$(enter_payload "$S" "$REPO_A" "$(jq -cn --arg p "$REPO_E" '"Created worktree at \($p) on branch feature-y"')")"
assert_eq "$TOP_E" "$(last_tree "$S")"
assert_eq enter-worktree "$(last_kind "$S")"
run_workdir_hook "$(enter_payload "$S" "$REPO_A" "$(jq -cn --arg p "$REPO_B" '{text:"Switched to worktree at \($p)"}')")"
assert_eq "$TOP_B" "$(last_tree "$S")"
run_workdir_hook "$(enter_payload "$S" "$REPO_A" '"no path in here"')"
assert_eq 3 "$(place_count "$S")"
run_workdir_hook "$(jq -cn --arg session "$S" --arg cwd "$REPO_E" \
  '{hook_event_name:"PostToolUse",tool_name:"ExitWorktree",session_id:$session,cwd:$cwd,tool_input:{}}')"
assert_eq "$TOP_E" "$(last_tree "$S")"
assert_eq exit-worktree "$(last_kind "$S")"
CLAUDE_PROJECT_DIR="$REPO_A" run_workdir_hook "$(jq -cn --arg session "$S" --arg cwd "$REPO_E" \
  '{hook_event_name:"PostToolUse",tool_name:"ExitWorktree",session_id:$session,cwd:$cwd,tool_input:{}}')"
assert_eq "$TOP_A" "$(last_tree "$S")"

# ~/.claude is not excluded: the file's own symlink, or the directory's, lands on the repository
# that physically holds it.
ln -s "$REPO_D" "$HOME/.claude/hooks"
S="session-claude-dir-symlink"
place_set "$S" "$TOP_A"
run_workdir_hook "$(workdir_payload Write "$S" "$REPO_A" "$HOME/.claude/hooks/some-hook.sh")"
assert_eq "$TOP_D" "$(last_tree "$S")"
rm -f "$HOME/.claude/hooks"
mkdir -p "$HOME/.claude/hooks" "$REPO_B/hooks"
printf 'x\n' > "$REPO_B/hooks/foo.sh"
ln -s "$REPO_B/hooks/foo.sh" "$HOME/.claude/hooks/foo.sh"
S="session-claude-file-symlink"
place_set "$S" "$TOP_A"
run_workdir_hook "$(workdir_payload Edit "$S" "$REPO_A" "$HOME/.claude/hooks/foo.sh")"
assert_eq "$TOP_B" "$(last_tree "$S")"
rm -rf "$HOME/.claude/hooks" "$REPO_B/hooks"

# The standing exclusions: temp dirs, caches, node_modules, and anything outside git.
mkdir -p "$REPO_A/node_modules/pkg" "$TMPDIR/tmp-repo" "$HOME/.cache/cache-repo"
git -C "$TMPDIR/tmp-repo" init -q
git -C "$HOME/.cache/cache-repo" init -q
S="session-excluded"
place_set "$S" "$TOP_A"
for excluded_path in "$REPO_A/node_modules/pkg/index.js" "$TMPDIR/tmp-repo/f" \
  "$HOME/.cache/cache-repo/f" "$NON_GIT/f" "/tmp/f"; do
  run_workdir_hook "$(workdir_payload Write "$S" "$REPO_A" "$excluded_path")"
done
assert_eq 1 "$(place_count "$S")"
rm -rf "$REPO_A/node_modules"

# SessionStart seeds only a missing or empty journal, whatever its source; a subagent-typed
# SessionStart is a top-level `claude --agent` session and seeds too.
session_start_payload() {
  jq -cn --arg source "$1" --arg session "$2" --arg cwd "${3:-$REPO_A}" \
    '{hook_event_name:"SessionStart",source:$source,session_id:$session,cwd:$cwd}'
}
for src in startup resume clear compact; do
  run_workdir_hook "$(session_start_payload "$src" "session-ss-$src")"
  assert_eq "$TOP_A" "$(last_tree "session-ss-$src")"
  assert_eq seed "$(last_kind "session-ss-$src")"
  place_set "session-ss-$src" "$TOP_D" "$TOP_D" edit
  run_workdir_hook "$(session_start_payload "$src" "session-ss-$src" "$REPO_B")"
  assert_eq "$TOP_D" "$(last_tree "session-ss-$src")"
done
run_workdir_hook "$(session_start_payload startup session-ss-agent | jq -c '. + {agent_type:"reviewer"}')"
assert_eq "$TOP_A" "$(last_tree session-ss-agent)"
: > "$STATE_DIR/place-session-ss-empty"
run_workdir_hook "$(session_start_payload resume session-ss-empty "$REPO_E")"
assert_eq "$TOP_E" "$(last_tree session-ss-empty)"
run_workdir_hook "$(session_start_payload startup session-ss-nogit "$NON_GIT")"
assert test ! -e "$STATE_DIR/place-session-ss-nogit"

# A /branch fork inherits its parent's journal whole; without a parent journal it seeds.
fork_transcript="$WORK/fork-transcript.jsonl"
printf '%s\n' '{"type":"system","forkedFrom":{"sessionId":"session-fork-parent","messageUuid":"m1"}}' \
  '{"type":"user"}' > "$fork_transcript"
place_set session-fork-parent "$TOP_A"
place_set session-fork-parent "$TOP_E" "$TOP_A" edit
run_workdir_hook "$(session_start_payload startup session-fork-child "$REPO_D" |
  jq -c --arg t "$fork_transcript" '. + {transcript_path:$t}')"
assert_eq "$(cat "$STATE_DIR/place-session-fork-parent")" "$(cat "$STATE_DIR/place-session-fork-child")"
assert_eq 600 "$(stat -f %Lp "$STATE_DIR/place-session-fork-child" 2>/dev/null || stat -c %a "$STATE_DIR/place-session-fork-child")"
rm -f "$STATE_DIR/place-session-fork-parent"
run_workdir_hook "$(session_start_payload startup session-fork-orphan "$REPO_D" |
  jq -c --arg t "$fork_transcript" '. + {transcript_path:$t}')"
assert_eq "1 seed $TOP_D" "$(place_count session-fork-orphan) $(last_kind session-fork-orphan) $(last_tree session-fork-orphan)"
run_workdir_hook "$(session_start_payload startup session-fork-notranscript "$REPO_D" |
  jq -c '. + {transcript_path:"/nonexistent/t.jsonl"}')"
assert_eq "seed $TOP_D" "$(last_kind session-fork-notranscript) $(last_tree session-fork-notranscript)"

# Bash writes move the folder like an Edit: `sed -i`, `tee`, `cp`… and `>`/`>>` targets, through the
# command's own leading assignments; reads and discard-only redirects move nothing.
S="session-bash-writes"
place_set "$S" "$TOP_A"
run_workdir_hook "$(workdir_payload Bash "$S" "$REPO_A" "W=$REPO_D; sed -i '' 's/other/x/' \$W/other.txt")"
assert_eq "edit $TOP_D" "$(last_kind "$S") $(last_tree "$S")"
for read_cmd in "grep -rn fixture \"$REPO_E\"" "sed -n 1p \"$REPO_E/tracked.txt\"" \
  "cat \"$REPO_E/tracked.txt\" >/dev/null 2>&1"; do
  run_workdir_hook "$(workdir_payload Bash "$S" "$REPO_A" "$read_cmd")"
  assert_eq "2 $TOP_D" "$(place_count "$S") $(last_tree "$S")"
done
run_workdir_hook "$(workdir_payload Bash "$S" "$REPO_A" "E=\"$REPO_E\" && printf x > \"\${E}/new-file.txt\"")"
assert_eq "edit $TOP_E" "$(last_kind "$S") $(last_tree "$S")"
bash_write_moves() { # expected-tree command
  run_workdir_hook "$(workdir_payload Bash "$S" "$REPO_A" "$2")"
  assert_eq "edit $1" "$(last_kind "$S") $(last_tree "$S")"
}
bash_write_still() { # command
  local before
  before=$(place_count "$S")
  run_workdir_hook "$(workdir_payload Bash "$S" "$REPO_A" "$1")"
  assert_eq "$before" "$(place_count "$S")"
}
# cp/mv/ln write their LAST operand; a moved-away source is never walked up from.
bash_write_moves "$TOP_B" "cp $REPO_D/other.txt $REPO_B/copied.txt"
bash_write_moves "$TOP_C" "mv -f $REPO_D/gone.txt $REPO_C/moved.txt"
bash_write_moves "$TOP_D" "if true; then mkdir -p $REPO_D/newdir/sub; fi"
bash_write_moves "$TOP_B" "for f in a b; do rm $REPO_B/\$f; done"
bash_write_still "W=$REPO_C; W=\$(pwd); echo x > \$W/f"
bash_write_moves "$TOP_D" "echo x 1> $REPO_D/one.txt"
bash_write_still "echo x 2> $REPO_C/err.txt"
bash_write_moves "$TOP_A" "touch ${REPO_A// /\\ }/tracked.txt"

# `main` is the checkout owning the worktree, and a main checkout is its own.
S="session-main-field"
run_workdir_hook "$(workdir_payload Edit "$S" "$REPO_A" "$REPO_E/f.txt")"
run_workdir_hook "$(workdir_payload Edit "$S" "$REPO_A" "$REPO_D/other.txt")"
assert_eq "$TOP_E	$TOP_A
$TOP_D	$TOP_D" "$(cut -f3,4 "$STATE_DIR/place-$S")"

# Three parallel edits are three lines: one printf per append, no read-modify-write.
S="session-parallel"
for parallel_file in tracked.txt a.txt b.txt; do
  printf '%s' "$(workdir_payload Edit "$S" "$REPO_A" "$REPO_A/$parallel_file")" | "$WORKDIR_HOOK" &
done
wait
assert_eq 3 "$(place_count "$S")"
assert_eq 3 "$(grep -c "	edit	$TOP_A	$TOP_A\$" "$STATE_DIR/place-$S")"

# Past 400 lines the writer keeps the last 200.
S="session-trim"
for trim_i in $(seq 1 400); do place_set "$S" "$TOP_A"; done
"$PLACE" add --session "$S" --kind edit --path "$REPO_D/other.txt"
assert_eq 200 "$(place_count "$S")"
assert_eq "$TOP_D" "$(last_tree "$S")"
assert_fails() { asserts=$((asserts + 1)); ! "$@" >/dev/null 2>&1 || fail "assert $asserts should have failed: $*"; }
assert_fails "$PLACE" add --session "$S" --kind wander --path "$REPO_D"
assert_fails "$PLACE" why
assert_eq 200 "$(place_count "$S")"

# From 399 lines, twenty parallel adds trim once and lose none of theirs: 200 kept, 18 after.
S="session-trim-race"
for trim_i in $(seq 1 399); do place_set "$S" "$TOP_A"; done
for trim_i in $(seq 1 20); do "$PLACE" add --session "$S" --kind edit --path "$REPO_D/other.txt" & done
wait
assert_eq 218 "$(place_count "$S")"
assert_eq 20 "$(grep -c "	edit	$TOP_D	" "$STATE_DIR/place-$S")"
assert test ! -e "$STATE_DIR/place-$S.lock"

"$PLACE" add --session session-exit --kind edit --path "$REPO_D/other.txt"
assert_eq 0 "$?"
assert_eq 600 "$(stat -f %Lp "$STATE_DIR/place-session-exit")"
place_rc=0
"$PLACE" add --session session-exit --kind edit --path "$NON_GIT" || place_rc=$?
assert_eq 3 "$place_rc"
assert_eq 1 "$(place_count session-exit)"

# Journals older than a week go with the hourly prune, and so does a snapshot no PostToolUse took.
place_set session-prune-old "$TOP_A"
place_set session-prune-new "$TOP_A"
touch -t 202001010000 "$STATE_DIR/place-session-prune-old" "$STATE_DIR/.place-prune"
run_workdir_hook "$(workdir_payload Edit session-prune-new "$REPO_A" "$REPO_A/tracked.txt")"
assert test ! -e "$STATE_DIR/place-session-prune-old"
assert_eq 2 "$(place_count session-prune-new)"

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
  # The Codex quota kick fires on every CLAUDEGPT_ACCOUNT render and would otherwise
  # run a real --refresh-account against the user's own store — same neutralization.
  # COLUMNS is passed explicitly and empty by default: the fit loop reads it, and a value inherited
  # from whatever terminal runs the suite would shrink lines every other case measures at full width.
  printf '%s' "$1" | CLAUDE_LIMITS_ACCOUNT="${2:-${RUN_STATUSLINE_DEFAULT_ACCOUNT:-main}}" CLAUDEB_DIR="$CLAUDEB_FIX" \
    CODEXB_PROFILES_DIR="$CODEX_FIX" \
    COLUMNS="${FIT_COLUMNS:-}" STATUSLINE_FIT_MARGIN="${FIT_MARGIN:-}" \
    CHAT_PINS_DIR="$CHAT_PINS_DIR" \
    LLM_LIMITS_FILE="$WORK/limits.json" STATUSLINE_PS=true STATUSLINE_LSOF=true \
    STATUSLINE_STORE_MERGE_CMD="${STORE_MERGE_CMD:-/usr/bin/true}" \
    STATUSLINE_CODEX_REFRESH_CMD="${CODEX_REFRESH_CMD:-/usr/bin/true}" \
    STATUSLINE_REVIEW_GATE="${GATE_CMD:-}" STATUSLINE_REVIEW_DEBT="${DEBT_CMD:-}" \
    env ${NO_TIMEOUT_BIN:+STATUSLINE_TIMEOUT_BIN=} "$STATUSLINE"
}


cg_now=$(date +%s)
jq -cn --argjson now "$cg_now" '{vendors:{codex:{accounts:[
  {account:"work4",five_hour:{used_pct:36,effective_pct:36,as_of:$now,resets_at:($now+3600)},
   weekly:{used_pct:22,effective_pct:22,as_of:$now,resets_at:($now+86400)}},
  {account:"main",five_hour:{used_pct:9,effective_pct:9,as_of:$now,resets_at:($now+3600)}}
]}}}' > "$WORK/limits.json"
cg_usage=$(jq -cn '{
  context_window:{context_window_size:872000,current_usage:{input_tokens:72000,cache_read_input_tokens:200000}},
  rate_limits:{five_hour:{used_percentage:99},seven_day:{used_percentage:99}}}')
cg_payload=$(statusline_payload cg-limits "$(jq -cn --argjson extra "$cg_usage" '{model:{id:"anthropic.ccr.sol",display_name:"Sol"}} * $extra')")
cg_before=$(cat "$HOME/.claude/statusline-cache-rl" 2>/dev/null || :)
cg_out=$(CLAUDEGPT_ACCOUNT=work4 run_statusline "$cg_payload")
assert grep -Fq "${CYAN}Sol high${RESET}" <<< "$cg_out"
assert grep -Fq "ctx ${DIM}31%${RESET} ${YELLOW}? 272k${RESET}" <<< "$cg_out"
assert test "${cg_out#*cached}" = "$cg_out"
assert test "${cg_out#*272k/872k}" = "$cg_out"
assert grep -Fq '36%' <<< "$cg_out"
assert grep -Fq '22%' <<< "$cg_out"
assert test "${cg_out#*OpenAI/}" = "$cg_out"
assert test "${cg_out#*fb }" = "$cg_out"
assert_eq "$cg_before" "$(cat "$HOME/.claude/statusline-cache-rl" 2>/dev/null || :)"
assert test ! -e "$CLAUDEB_FIX/limits/work4.json"
cg_astra=$(CLAUDEGPT_ACCOUNT=work4 run_statusline "$(statusline_payload cg-astra "$(jq -cn --argjson extra "$cg_usage" '{model:{id:"anthropic.ccr.astra",display_name:"Sol"}} * $extra')")")
assert grep -Fq "${CYAN}Astra high${RESET}" <<< "$cg_astra"
assert test "${cg_astra#*Sol}" = "$cg_astra"
assert grep -Fq "ctx ${DIM}31%${RESET} ${YELLOW}? 272k${RESET}" <<< "$cg_astra"
claude_same=$(run_statusline "$(statusline_payload cg-claude "$(jq -cn '{model:{id:"claude-fable-5",display_name:"Fable 5"},context_window:{context_window_size:872000,current_usage:{input_tokens:72000,cache_read_input_tokens:200000}}}')")")
assert grep -Fq "${CYAN}Fable 5 high${RESET}" <<< "$claude_same"
assert grep -Fq "ctx ${DIM}31%${RESET} ${YELLOW}? 272k${RESET}" <<< "$claude_same"
cg_nocache=$(CLAUDEGPT_ACCOUNT=work4 run_statusline "$(statusline_payload cg-nocache "$(jq -cn '{model:{id:"anthropic.ccr.astra",display_name:"Sol"},context_window:{context_window_size:872000,current_usage:{input_tokens:46000}}}')")")
assert grep -Fq "${CYAN}Astra high${RESET}" <<< "$cg_nocache"
assert test "${cg_nocache#*cached}" = "$cg_nocache"
assert test "${cg_nocache#*0k}" = "$cg_nocache"
cg_nousage=$(CLAUDEGPT_ACCOUNT=work4 run_statusline "$(statusline_payload cg-nousage "$(jq -cn '{model:{id:"anthropic.ccr.astra",display_name:"Astra"},context_window:{used_percentage:5,context_window_size:872000,current_usage:null}}')")")
assert grep -Fq "ctx ${DIM}5%${RESET} ${DIM}?${RESET}" <<< "$cg_nousage"
assert test "${cg_nousage#*0k}" = "$cg_nousage"
assert test "${cg_nousage#*cached}" = "$cg_nousage"
cg_main=$(CLAUDEGPT_ACCOUNT=main run_statusline "$cg_payload")
assert grep -Fq '9%' <<< "$cg_main"
cg_missing=$(CLAUDEGPT_ACCOUNT=missing run_statusline "$cg_payload")
assert test "${cg_missing#*36%}" = "$cg_missing"
assert test "${cg_missing#*99%}" = "$cg_missing"
assert grep -Fq '?' <<< "$cg_missing"
jq --argjson now "$cg_now" '.vendors.codex.accounts[0].five_hour.resets_at = ($now-1)
  | .vendors.codex.accounts[0].weekly.as_of = ($now-22000)' "$WORK/limits.json" > "$WORK/cg-limits.json"
mv "$WORK/cg-limits.json" "$WORK/limits.json"
cg_expired=$(CLAUDEGPT_ACCOUNT=work4 run_statusline "$cg_payload")
assert grep -Fq '0%' <<< "$cg_expired"
assert test "${cg_expired#*36%}" = "$cg_expired"
assert grep -Fq $'\033[2m' <<< "$cg_expired"
for cg_bucket in 'null' '{used_pct:null,resets_at:null,as_of:$now,origin:"usage",stale:false,effective_pct:null}' '{}'; do
  jq -cn --argjson now "$cg_now" "{vendors:{codex:{accounts:[{account:\"desktop-pro\",
    five_hour:$cg_bucket,weekly:{used_pct:22,as_of:\$now,resets_at:(\$now+2592000)}}]}}}" > "$WORK/limits.json"
  cg_absent=$(CLAUDEGPT_ACCOUNT=desktop-pro run_statusline "$cg_payload")
  cg_line2=$(printf '%s\n' "$cg_absent" | sed -n '2p' | sed $'s/\033\[[0-9;]*m//g')
  assert test "${cg_line2#*5h}" = "$cg_line2"
  assert grep -Eq '^ctx [^│]+ │ wk 22%' <<< "$cg_line2"
  assert test "${cg_line2#*│ │}" = "$cg_line2"
done
jq '.vendors.codex.accounts[0].five_hour = {used_pct:null,resets_at:null,stale:true}' \
  "$WORK/limits.json" > "$WORK/cg-limits.json"
mv "$WORK/cg-limits.json" "$WORK/limits.json"
cg_unknown=$(CLAUDEGPT_ACCOUNT=desktop-pro run_statusline "$cg_payload")
assert grep -Fq "5h ${DIM}?${RESET}" <<< "$cg_unknown"
printf '{}' > "$WORK/limits.json"

status_payload=$(statusline_payload status-override)
control_one=$(run_statusline "$status_payload") || fail "statusline control failed"
control_two=$(run_statusline "$status_payload") || fail "statusline second control failed"
assert_eq "$control_one" "$control_two"
assert grep -Fq main <<< "$control_one"
assert test "${control_one#*»}" = "$control_one"

# A worktree of the project is `⧉ <dir>`, never `»` — that arrow is reserved for
# a foreign repository. This one sits outside <repo>/.claude/worktrees, which is
# the one alarm the cluster still carries.
place_set status-override "$TOP_B"
override_output=$(run_statusline "$status_payload") || fail "statusline override failed"
assert test "${override_output#*»}" = "$override_output"
assert grep -Fq "${RED}⧉ $(basename "$TOP_B")" <<< "$override_output"
assert test "${override_output#*⎇}" = "$override_output"

# In a worktree the directory label IS the identity: no branch segment at all,
# whatever the branch is called. Canonical location, name matching the branch.
place_set status-canon "$TOP_E"
canon_output=$(run_statusline "$(statusline_payload status-canon)") || fail "statusline canonical worktree failed"
assert grep -Fq "${BLUE}⧉ feature-y" <<< "$canon_output"
assert test "${canon_output#*⎇}" = "$canon_output"

# A branch bearing no relation to the directory name is not printed either.
place_set status-ticket "$TOP_J"
ticket_output=$(run_statusline "$(statusline_payload status-ticket)") || fail "statusline diverged branch failed"
assert grep -Fq "${BLUE}⧉ wut-25-portal" <<< "$ticket_output"
assert test "${ticket_output#*⎇}" = "$ticket_output"
assert test "${ticket_output#*WUT-259}" = "$ticket_output"

# Nor a harness auto-slug: branch names are policed nowhere on the strip.
place_set status-autoslug "$TOP_F"
autoslug_output=$(run_statusline "$(statusline_payload status-autoslug)") || fail "statusline auto-slug failed"
assert grep -Fq "${BLUE}⧉ auto-slug" <<< "$autoslug_output"
assert test "${autoslug_output#*⎇}" = "$autoslug_output"
assert test "${autoslug_output#*claude/agitated}" = "$autoslug_output"

# Detached HEAD in a worktree is no exception — but the diff still measures.
printf 'd1\n' > "$TOP_C/wt-det-junk.txt"
place_set status-wt-detached "$TOP_C"
wt_det_output=$(run_statusline "$(statusline_payload status-wt-detached)") || fail "statusline detached worktree failed"
assert grep -Fq "⧉ $(basename "$TOP_C")" <<< "$wt_det_output"
assert test "${wt_det_output#*⎇}" = "$wt_det_output"
assert grep -Fq "${GREEN}+1${RESET}/${RED}-0${RESET}" <<< "$wt_det_output"
rm -f "$TOP_C/wt-det-junk.txt"

# Same worktree, chat launched inside it: the project it belongs to stays visible.
in_wt_output=$(run_statusline "$(statusline_payload status-in-wt '' "$REPO_E")") || fail "statusline in-worktree failed"
assert grep -Fq "$(basename "$TOP_A")" <<< "$in_wt_output"
assert grep -Fq "${BLUE}⧉ feature-y" <<< "$in_wt_output"

# Separate git dir: the location check must resolve the main worktree through git,
# not by stripping `/.git` off the common dir, or an in-convention worktree reads
# as misplaced.
place_set status-sepdir "$TOP_H"
sepdir_output=$(run_statusline "$(statusline_payload status-sepdir '' "$REPO_G")") || fail "statusline separate-git-dir failed"
assert grep -Fq "${BLUE}⧉ sep-work" <<< "$sepdir_output"

# A foreign repository keeps `»` and always shows its branch.
place_set status-foreign "$TOP_D"
foreign_output=$(run_statusline "$(statusline_payload status-foreign)") || fail "statusline foreign repo failed"
assert grep -Fq "»" <<< "$foreign_output"
assert grep -Fq "$(basename "$TOP_D")" <<< "$foreign_output"
assert grep -Fq '⎇ main' <<< "$foreign_output"
assert test "${foreign_output#*⧉}" = "$foreign_output"

same_payload=$(statusline_payload status-same)
place_set status-same "$TOP_A"
same_output=$(run_statusline "$same_payload") || fail "statusline same-repo failed"
assert grep -Fq main <<< "$same_output"
assert test "${same_output#*»}" = "$same_output"

# Example 5: a journal naming only vanished trees falls back to the project dir, silently.
place_set status-dangling "$FIXTURES/vanished"
dangling_output=$(run_statusline "$(statusline_payload status-dangling)") || fail "statusline dangling failed"
assert grep -Fq "${BLUE}⎇ main" <<< "$dangling_output"
assert test "${dangling_output#*»}" = "$dangling_output"
assert test "${dangling_output#*⧉}" = "$dangling_output"
assert test "${dangling_output#*✗}" = "$dangling_output"
assert_eq 1 "$(place_count status-dangling)"
# The newest line that still resolves wins over the vanished last line's main checkout, and with
# none resolving that main checkout is shown.
place_set status-gone-older "$TOP_B"
place_set status-gone-older "$FIXTURES/vanished-wt" "$TOP_D"
gone_output=$(run_statusline "$(statusline_payload status-gone-older)") || fail "statusline vanished tree failed"
assert grep -Fq "⧉ $(basename "$TOP_B")" <<< "$gone_output"
assert grep -Fq "fallback: the 1 newer line(s) name vanished trees" <<< "$("$PLACE" why --session status-gone-older)"
place_set status-gone-main "$FIXTURES/vanished-wt" "$TOP_D"
gone_output=$(run_statusline "$(statusline_payload status-gone-main)") || fail "statusline vanished main failed"
assert grep -Fq "»${RESET} ${BLUE}$(basename "$TOP_D")${RESET}" <<< "$gone_output"
assert grep -Fq "shown: $TOP_D" <<< "$("$PLACE" why --session status-gone-main)"
assert grep -Fq "shown: the project dir (no journal at" <<< "$("$PLACE" why --session status-none)"

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
assert test "${fast_output#*⚡}" = "$fast_output"
assert test "${fast_output#*Fast Mode}" = "$fast_output"


# Pin segment: this session's chat file only. No file → nothing; * → vendor word; else account.
# Global worker-model pin is never shown. claudeb_profile=* renders `claude`, not `claudeb`.
worker_file="$HOME/.claude/worker-model"
rm -f "$worker_file"
rm -f "$CHAT_PINS_DIR"/*

pin_out=$(run_statusline "$(statusline_payload status-pin-none)")
assert test "${pin_out#*codex}" = "$pin_out"
assert test "${pin_out#*claude}" = "$pin_out"
assert test "${pin_out#*⏸off}" = "$pin_out"

printf 'claudeb_profile=globpin\nworker=claudeb\n' > "$worker_file"
pin_out=$(run_statusline "$(statusline_payload status-pin-global)")
assert test "${pin_out#*globpin}" = "$pin_out"
assert test "${pin_out#*claude}" = "$pin_out"
rm -f "$worker_file"

write_chat_pin status-pin-star-codex 'codex_profile=*'
pin_out=$(run_statusline "$(statusline_payload status-pin-star-codex)")
assert grep -Fq "${MAGENTA}codex${RESET}" <<< "$pin_out"

write_chat_pin status-pin-star-claude 'claudeb_profile=*'
pin_out=$(run_statusline "$(statusline_payload status-pin-star-claude)")
assert grep -Fq "${MAGENTA}claude${RESET}" <<< "$pin_out"
assert test "${pin_out#*claudeb}" = "$pin_out"

write_chat_pin status-pin-star-gemini 'gemini_profile=*'
pin_out=$(run_statusline "$(statusline_payload status-pin-star-gemini)")
assert grep -Fq "${MAGENTA}gemini${RESET}" <<< "$pin_out"

write_chat_pin status-pin-star-grok 'grok_profile=*'
pin_out=$(run_statusline "$(statusline_payload status-pin-star-grok)")
assert grep -Fq "${MAGENTA}grok${RESET}" <<< "$pin_out"

write_chat_pin status-pin-acct 'codex_profile=alt'
pin_out=$(run_statusline "$(statusline_payload status-pin-acct)")
assert grep -Fq "${MAGENTA}alt${RESET}" <<< "$pin_out"

: > "$CHAT_PINS_DIR/status-pin-empty"
pin_out=$(run_statusline "$(statusline_payload status-pin-empty)")
assert test "${pin_out#*codex}" = "$pin_out"
assert test "${pin_out#*alt}" = "$pin_out"

write_chat_pin other-session 'grok_profile=*'
pin_out=$(run_statusline "$(statusline_payload status-pin-other)")
assert test "${pin_out#*grok}" = "$pin_out"

# The live-worker tag (`▶ running`) stays gone.
tag_out=$(run_statusline "$(statusline_payload status-no-tag)")
assert test "${tag_out#*▶}" = "$tag_out"
assert test "${tag_out#*running}" = "$tag_out"

# --- Progressive width fit ----------------------------------------------------------------
# Both lines are built to $COLUMNS minus the margin by shrinking segments in a fixed order; every
# step is exercised on one fixture whose full form overflows every width below.
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
fit_visible() {
  local s=$1
  s=${s//"$RESET"/}; s=${s//"$CYAN"/}; s=${s//"$BLUE"/}; s=${s//"$DIM"/}
  s=${s//"$GREEN"/}; s=${s//"$YELLOW"/}; s=${s//"$RED"/}; s=${s//"$MAGENTA"/}
  printf '%s' "$s"
}
fit_render() { # session cols [cwd] [account]
  local out
  write_chat_pin "$1" 'grok_profile=a'
  out=$(FIT_COLUMNS="$2" run_statusline \
    "$(statusline_payload "$1" '{"model":{"display_name":"Fable 5"},"effort":{"level":"xhigh"},"cost":{"total_cost_usd":1.5}}' \
       "${3:-$FIT_REPO}")" "${4:-fitaccount}") || fail "fit render failed: $1 at $2"
  fit_visible "$out"
}

FIT_NOW=$(date +%s)
jq -cn --argjson now "$FIT_NOW" '
  {five_hour:{used_percentage:44,resets_at:($now+3600),as_of:$now,origin:"session"},
   seven_day:{used_percentage:22,resets_at:($now+259200),as_of:$now,origin:"session"},
   auth:{status:"ok",checked_at:$now}}' > "$CLAUDEB_FIX/limits/fitaccount.json"
jq -cn --arg reset "$(date -u -r $((FIT_NOW + 172800)) +%Y-%m-%dT%H:%M:%SZ)" '
  {vendors:{claude:{accounts:[{account:"fitaccount",five_hour:{stale:false},weekly:{stale:false},
    fable:{used_pct:55,effective_pct:55,expired:false,stale:false,resets_at:$reset}}]}}}' \
  > "$WORK/limits.json"
fit_h5_time=$(TZ=Europe/Kyiv date -r $((FIT_NOW + 3600)) +%H:%M)
fit_wk_label=$(LC_ALL=C TZ=Europe/Kyiv date -r $((FIT_NOW + 259200)) '+%a %H:%M')
fit_fb_label=$(LC_ALL=C TZ=Europe/Kyiv date -r $((FIT_NOW + 172800)) '+%a %H:%M')

fit_both=$(fit_render fit-full "")
fit_line2() { printf '%s' "${1#*$'\n'}"; }

fit_both=$(fit_render fit-full "")
fit_full=${fit_both%%$'\n'*}
fit_full2=$(fit_line2 "$fit_both")
# Nothing shrinks with no width to shrink to.
assert grep -Fq 'Fable 5 xhigh' <<< "$fit_full"
assert grep -Fq 'fit-bench-project' <<< "$fit_full"
assert grep -Fq '⎇ WUT-421_fit_bench_branch' <<< "$fit_full"
assert grep -Fq '+3/-0' <<< "$fit_full"
# No dim `+N~M-Kf` block beside the numbers at any width (Egor, 2026-09-18): file counts render
# only for a tree with no countable line diff, and then alone.
assert test "${fit_full#*~1f}" = "$fit_full"
assert grep -Fq 'fitaccount' <<< "$fit_full"
assert_eq "ctx 12% ? 1k │ 5h 44% $fit_h5_time │ wk 22% $fit_wk_label │ fb 55% $fit_fb_label │ \$1.50" "$fit_full2"
fit_full_len=${#fit_full}
fit_full2_len=${#fit_full2}

# Every width either line is asked to fit into, it fits into, three cells inside COLUMNS where the
# harness cuts the row — and neither line grows as the width falls.
fit_prev=$fit_full_len
fit_prev2=$fit_full2_len
for fit_cols in 200 120 100 90 80 70 60 40; do
  fit_both=$(fit_render "fit-w$fit_cols" "$fit_cols")
  fit_line=${fit_both%%$'\n'*}
  fit_line2=$(fit_line2 "$fit_both")
  asserts=$((asserts + 1))
  [ "${#fit_line}" -le $((fit_cols - 3)) ] || [ $((fit_cols - 3)) -ge "$fit_full_len" ] ||
    fail "fit width $fit_cols: ${#fit_line} cells: $fit_line"
  asserts=$((asserts + 1))
  [ "${#fit_line2}" -le $((fit_cols - 3)) ] || [ $((fit_cols - 3)) -ge "$fit_full2_len" ] ||
    fail "fit width $fit_cols line 2: ${#fit_line2} cells: $fit_line2"
  asserts=$((asserts + 1))
  [ "${#fit_line}" -le "$fit_prev" ] ||
    fail "fit width $fit_cols grew: ${#fit_line} > $fit_prev"
  asserts=$((asserts + 1))
  case "$fit_line" in
    *fit-bench-project*) [[ "$fit_line" == *fitacco* ]] ;;
    *fit-benc*) [[ "$fit_line" == *fitacco\ * ]] ;;
    *fbp*) [[ "$fit_line" == *fita\ * ]] ;;
  esac || fail "fit width $fit_cols: account shorter than the directory stage: $fit_line"
  asserts=$((asserts + 1))
  [ "${#fit_line2}" -le "$fit_prev2" ] ||
    fail "fit width $fit_cols line 2 grew: ${#fit_line2} > $fit_prev2"
  fit_prev=${#fit_line}
  fit_prev2=${#fit_line2}
done

# The margin is an environment override: at 0 both lines may use every column, and no more.
for fit_cols in 80 74 70; do
  fit_both=$(FIT_MARGIN=0 fit_render "fit-margin0-$fit_cols" "$fit_cols")
  fit_line=${fit_both%%$'\n'*}
  fit_line2=$(fit_line2 "$fit_both")
  assert test "${#fit_line}" -le "$fit_cols"
  assert test "${#fit_line2}" -le "$fit_cols"
done
assert_eq "$fit_full2" "$(fit_line2 "$(FIT_MARGIN=0 fit_render fit-margin0-full 74)")"
fit_both=$(FIT_MARGIN=08 fit_render fit-margin08 60 2> "$WORK/fit-margin08.err")
fit_line=${fit_both%%$'\n'*}
assert test "${#fit_line}" -le 52
assert grep -Fq 'fit-bench-pr ' <<< "$fit_line"
assert test ! -s "$WORK/fit-margin08.err"

# Line 2 is 73 cells wide; each width below, less the margin, is the first one that needs the next
# step: cost, then the ctx tokens part, then the reset labels short, then gone, then separators.
assert_eq 73 "$fit_full2_len"
fit_l2_keep=$(fit_line2 "$(fit_render fit-l2-keep 76)")
assert_eq "$fit_full2" "$fit_l2_keep"
fit_l2_step1=$(fit_line2 "$(fit_render fit-l2-step1 75)")
assert_eq "ctx 12% ? 1k │ 5h 44% $fit_h5_time │ wk 22% $fit_wk_label │ fb 55% $fit_fb_label" "$fit_l2_step1"
fit_l2_step2=$(fit_line2 "$(fit_render fit-l2-step2 67)")
assert_eq "ctx 12% │ 5h 44% $fit_h5_time │ wk 22% $fit_wk_label │ fb 55% $fit_fb_label" "$fit_l2_step2"
fit_l2_step3=$(fit_line2 "$(fit_render fit-l2-step3 62)")
assert_eq "ctx 12% │ 5h 44% ${fit_h5_time%%:*}h │ wk 22% ${fit_wk_label%% *} │ fb 55% ${fit_fb_label%% *}" "$fit_l2_step3"
fit_l2_step4=$(fit_line2 "$(fit_render fit-l2-step4 48)")
assert_eq "ctx 12% │ 5h 44% │ wk 22% │ fb 55%" "$fit_l2_step4"
fit_l2_step5=$(fit_line2 "$(fit_render fit-l2-step5 36)")
assert_eq "ctx 12% 5h 44% wk 22% fb 55%" "$fit_l2_step5"
fit_l2_floor=$(fit_line2 "$(fit_render fit-l2-floor 12)")
assert_eq "ctx 12% 5h 44% wk 22% fb 55%" "$fit_l2_floor"

# The full form of line 1 is 81 cells wide, and each width below, less the margin, is the first one
# that needs the next step.
assert_eq 81 "$fit_full_len"

# Step 1: the diff signs go first, and the slash survives.
fit_step1=$(fit_render fit-step1 83)
assert grep -Fq '3/0' <<< "$fit_step1"
assert test "${fit_step1#*+3}" = "$fit_step1"

# Step 2 then 3: the branch glyph goes, then the branch keeps its ticket prefix alone.
fit_step2=$(fit_render fit-step2 81)
assert test "${fit_step2#*⎇}" = "$fit_step2"
assert grep -Fq 'WUT-421_fit_bench_branch' <<< "$fit_step2"
fit_step3=$(fit_render fit-step3 78)
assert grep -Fq 'WUT-421' <<< "$fit_step3"
assert test "${fit_step3#*WUT-421_}" = "$fit_step3"

# Step 4 takes the account to 7 characters and cuts every directory name to one shared length, one
# character at a time from the longest name down to 8, stopping at the first that fits; the model is
# untouched meanwhile, and the account stays whole while the directory is.
fit_step3=$(fit_render fit-step4-whole 65)
assert grep -Fq 'Fable 5 xhigh fitaccount │ fit-bench-project WUT-421' <<< "$fit_step3"
fit_step4=$(fit_render fit-step4 62)
assert grep -Fq 'Fable 5 xhigh fitacco │ fit-bench-project WUT-421' <<< "$fit_step4"
fit_step4=$(fit_render fit-step4-cut 57)
assert grep -Fq 'Fable 5 xhigh fitacco │ fit-bench-proj WUT-421' <<< "$fit_step4"
fit_step4=$(fit_render fit-step4-last 52)
assert grep -Fq 'Fable 5 xhigh fitacco │ fit-bench WUT-421' <<< "$fit_step4"

# Step 5: the cut has reached 8 before the head model is abbreviated, and the account holds at 7
# until the directories go to initials.
fit_step5=$(fit_render fit-step5 50)
assert grep -Fq 'FB5 xhi fitacco │ fit-benc ' <<< "$fit_step5"
fit_step5=$(fit_render fit-step5-hold 46)
assert grep -Fq 'FB5 xhi fitacco │ fit-benc ' <<< "$fit_step5"

# Steps 7, 9, 11 and 12: the account to 4 with the initials, the pin, the directory itself, the
# account to 3 — and never shorter than 3, however narrow.
fit_step7=$(fit_render fit-step7 44)
assert grep -Fq 'FB5 xhi fita │ fbp WUT-421 3/0 │ a' <<< "$fit_step7"
fit_step9=$(fit_render fit-step9 36)
assert test "${fit_step9#*"│ a"}" = "$fit_step9"
assert grep -Fq 'fita │ fbp' <<< "$fit_step9"
fit_step11=$(fit_render fit-step11 32)
assert test "${fit_step11#*fbp}" = "$fit_step11"
assert grep -Fq 'FB5 xhi fita │ WUT-421' <<< "$fit_step11"
fit_step12=$(fit_render fit-step12 28)
assert grep -Fq 'FB5 xhi fit │ WUT-421' <<< "$fit_step12"
fit_floor=$(fit_render fit-floor 15)
assert grep -Fq 'FB5 xhi fit │ WUT-421' <<< "$fit_floor"

# Steps 10 and 11 on the `»` pair: both sides share the cut, then wear initials with the arrow's
# spaces gone, then the active side alone, then no directory at all.
place_set fit-arrow "$FIT_FOREIGN_TOP"
fit_arrow=$(fit_render fit-arrow "")
assert grep -Fq 'fit-bench-project » other-side-repo' <<< "$fit_arrow"
fit_arrow=${fit_arrow%%$'\n'*}
assert_eq 93 "${#fit_arrow}"
place_set fit-arrow-cut "$FIT_FOREIGN_TOP"
fit_arrow_cut=$(fit_render fit-arrow-cut 70)
assert grep -Fq 'fitacco │ fit-bench-proj » other-side-rep ' <<< "$fit_arrow_cut"
place_set fit-arrow-ini "$FIT_FOREIGN_TOP"
fit_arrow_ini=$(fit_render fit-arrow-ini 50)
assert grep -Fq 'fita │ fbp»osr' <<< "$fit_arrow_ini"
place_set fit-arrow-active "$FIT_FOREIGN_TOP"
fit_arrow_active=$(fit_render fit-arrow-active 30)
assert grep -Fq 'fita │ osr' <<< "$fit_arrow_active"
assert test "${fit_arrow_active#*fbp}" = "$fit_arrow_active"

# The worktree label shares the cut with the directory names beside it, but a ticket-named one stops
# at its ticket: `wut-25`, never `w2p`, and the parent dir goes to initials around it.
fit_wt=$(fit_render fit-wt "" "$REPO_J")
fit_wt=${fit_wt%%$'\n'*}
assert_eq 53 "${#fit_wt}"
assert grep -Fq "⧉ wut-25-portal" <<< "$fit_wt"
fit_wt_short=$(fit_render fit-wt-short 55 "$REPO_J")
assert grep -Fq "fitacco │ repo a ⧉ wut-25-portal " <<< "$fit_wt_short"
fit_wt_short=$(fit_render fit-wt-short-cut 52 "$REPO_J")
assert grep -Fq "fitacco │ repo a ⧉ wut-25-porta " <<< "$fit_wt_short"
fit_wt_eight=$(fit_render fit-wt-eight 48 "$REPO_J")
assert grep -Fq "⧉ wut-25-p " <<< "$fit_wt_eight"
fit_wt_ini=$(fit_render fit-wt-ini 41 "$REPO_J")
assert grep -Fq "fita │ rep ⧉ wut-25 " <<< "$fit_wt_ini"
assert test "${fit_wt_ini#*w2p}" = "$fit_wt_ini"

# The digits are the identity, so neither the shared cut nor the initials step may touch them, and
# the separator of the match is printed as written.
fit_ticket=$(fit_render fit-ticket "" "$REPO_L")
assert grep -Fq "⧉ WUT-12345-fix-header" <<< "$fit_ticket"
fit_ticket_cut=$(fit_render fit-ticket-cut 54 "$REPO_L")
assert grep -Fq "⧉ WUT-12345-fix- " <<< "$fit_ticket_cut"
fit_ticket_short=$(fit_render fit-ticket-short 48 "$REPO_L")
assert grep -Fq "FB5 xhi fitacco │ repo a ⧉ WUT-12345 " <<< "$fit_ticket_short"
fit_ticket_ini=$(fit_render fit-ticket-ini 41 "$REPO_L")
assert grep -Fq "rep ⧉ WUT-12345" <<< "$fit_ticket_ini"
fit_ticket_us=$(fit_render fit-ticket-us 46 "$REPO_M")
assert grep -Fq "⧉ WUT_12345 " <<< "$fit_ticket_us"

# A worktree with no ticket in its name keeps the plain ladder: the cut down to 8, then initials.
fit_wt_plain=$(fit_render fit-wt-plain 48 "$REPO_E")
assert grep -Fq "⧉ feature- " <<< "$fit_wt_plain"
fit_wt_plain_ini=$(fit_render fit-wt-plain-ini 40 "$REPO_E")
assert grep -Fq "⧉ fy" <<< "$fit_wt_plain_ini"

# Initials longer than the 8-character cut would make step 7 GROW the line, and the directory
# would be dropped at a width its truncated form fits.
fit_many_full=$(fit_render fit-many "" "$FIT_MANY")
assert grep -Fq 'a-b-c-d-e-f-g-h-i-j' <<< "$fit_many_full"
for many_cols in 59 54 49 43 39 33; do
  many_line=$(fit_render "fit-many-$many_cols" "$many_cols" "$FIT_MANY")
  asserts=$((asserts + 1))
  [ "${many_line#*abcdefghij}" = "$many_line" ] ||
    fail "fit width $many_cols took the dir to longer initials: $many_line"
done
fit_many_cut=$(fit_render fit-many-cut 43 "$FIT_MANY")
assert grep -Fq 'a-b-c-d- main' <<< "$fit_many_cut"
printf '{}' > "$WORK/limits.json"

# Fast Mode is a worker launch setting and is intentionally absent from the shared statusline.

NOW=$(date +%s)
bucket_json() {
  jq -cn --argjson now "$NOW" --argjson h5 "$1" --argjson wk "$2" --argjson h5_age "${3:-0}" '
    {five_hour:{used_percentage:$h5,resets_at:($now+3600),as_of:($now-$h5_age),origin:"headers"},
     seven_day:{used_percentage:$wk,resets_at:($now+86400),as_of:$now,origin:"session"},
     auth:{status:"ok",checked_at:$now}}'
}

jq -cn '{auth:{status:"failed"}}' > "$CLAUDEB_FIX/limits/window-fixture.json"
claude_unknown=$(run_statusline "$(statusline_payload status-window-unknown)" window-fixture)
assert grep -Fq "5h ${DIM}?${RESET}" <<< "$claude_unknown"
bucket_json 33 11 | jq '.five_hour = {used_percentage:null,resets_at:null,origin:"usage",stale:false}' \
  > "$CLAUDEB_FIX/limits/window-fixture.json"
claude_absent=$(run_statusline "$(statusline_payload status-window-absent)" window-fixture)
assert test "${claude_absent#*5h }" = "$claude_absent"

bucket_json 33 11 > "$CLAUDEB_FIX/limits/acctfab.json"
bucket_json 44 22 > "$CLAUDEB_FIX/limits/acctgen.json"

fable_payload=$(statusline_payload status-explicit-fable '{"model":{"id":"claude-fable-5[1m]","display_name":"Fable"}}')
fable_out=$(run_statusline "$fable_payload" acctfab) || fail "statusline explicit fable failed"
assert grep -Fq 'acctfab' <<< "$fable_out"
assert test "${fable_out#*~acctfab}" = "$fable_out"
assert grep -Fq "${GREEN}33%" <<< "$fable_out"
assert grep -Fq "5h ${GREEN}33%${RESET} ${DIM}" <<< "$(sed -n '2p' <<< "$fable_out")"
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
# A gateway chat's reply went through the Codex account CLAUDEGPT_ACCOUNT names, not the claudeb
# profile the session also carries: the picker reads field 2 as the account holding the cache.
gw_render() {
  CLAUDEGPT_ACCOUNT=gwacct run_statusline "$(statusline_payload ctx-gateway "$(jq -cn --arg tp "$TRANSCRIPT" '
    {transcript_path:$tp,model:{id:"anthropic.ccr.astra"},
     context_window:{used_percentage:20,current_usage:{input_tokens:0,cache_read_input_tokens:50000}}}')")" >/dev/null
}
t_reset; t_assist $((NOW - 60)) anthropic.ccr.astra 50000 500 none; gw_render
t_assist $((NOW - 20)) anthropic.ccr.astra 50000 500 none; gw_render
assert grep -q '^v2 [0-9]* gwacct .* gwacct$' "$STATE_DIR/cache-ttl-track-ctx-gateway"

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
# The cache warning is an alarm: it outlives the death time it rides on, down to the line-2 floor.
for bk5_cols in 45 30 12; do
  bk5_fit=$(FIT_COLUMNS=$bk5_cols run_statusline "$(statusline_payload ctx-bk5 "$(warm_extra "$TRANSCRIPT" 20 100000)")")
  assert grep -Fq "ctx ${GREEN}20%${RESET} ${YELLOW}↓5m${RESET}" <<< "$bk5_fit"
  assert test "${bk5_fit#*→}" = "$bk5_fit"
done

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

# --- Codex quota kick (bin/statusline.sh) ---
CQ_ARGS="$WORK/codex-kick-args"
CQ_REFRESHER="$FIXTURES/codex-refresher"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$CQ_ARGS" > "$CQ_REFRESHER"
chmod +x "$CQ_REFRESHER"
CQ_FAIL="$FIXTURES/codex-refresher-fail"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nprintf boom >&2\nexit 3\n' "$CQ_ARGS" > "$CQ_FAIL"
chmod +x "$CQ_FAIL"
CQ_SLOW="$FIXTURES/codex-refresher-slow"
printf '#!/usr/bin/env bash\nsleep 3\nprintf "%%s\\n" "$*" >> "%s"\n' "$CQ_ARGS" > "$CQ_SLOW"
chmod +x "$CQ_SLOW"
cq_stamp() { printf '%s' "$STATE_DIR/codex-quota-kick-$1"; }
cq_reset() {
  # Earlier claudegpt render cases leave stamps of their own accounts behind, and the
  # "nothing was stamped" assertions below read the whole directory.
  rmdir "$STATE_DIR"/codex-quota-kick-*.lock 2>/dev/null || true
  rm -f "$CQ_ARGS" "$STATE_DIR"/codex-quota-kick-* 2>/dev/null || true
}
cq_wait_args() { local i; for i in $(seq 1 60); do [ -s "$CQ_ARGS" ] && return 0; sleep 0.05; done; return 1; }

# The kick refuses an account with no Codex home, so the fixture needs the profile it probes.
mkdir -p "$HOME/.codex-profiles/work4"
cq_now=$(date +%s)
jq -cn --argjson now "$cq_now" '{vendors:{codex:{accounts:[
  {account:"work4",five_hour:{used_pct:36,effective_pct:36,as_of:$now,resets_at:($now+3600)},
   weekly:{used_pct:22,effective_pct:22,as_of:$now,resets_at:($now+86400)}}
]}}}' > "$WORK/limits.json"
cq_payload=$(statusline_payload cq-kick "$(jq -cn '{model:{id:"anthropic.ccr.sol",display_name:"Sol"}}')")

# A: no stamp -> the existing per-account verb runs and the next-probe deadline is stamped.
cq_reset
cq_start=$(date +%s)
cq_out=$(CLAUDEGPT_ACCOUNT=work4 CODEX_REFRESH_CMD="$CQ_REFRESHER" run_statusline "$cq_payload") \
  || fail "claudegpt quota-kick render failed"
assert grep -Fq '36%' <<< "$cq_out"
assert cq_wait_args
assert_eq "--refresh-account codex/work4" "$(cat "$CQ_ARGS")"
cq_deadline=$(cat "$(cq_stamp work4)")
assert test "$cq_deadline" -ge "$((cq_start + 600))"
assert test "$cq_deadline" -le "$(( $(date +%s) + 600 ))"

# B: a deadline in the future debounces every session on that account, stamp untouched.
printf '%s\n' "$(( $(date +%s) + 600 ))" > "$(cq_stamp work4)"
rm -f "$CQ_ARGS"
cq_before=$(cat "$(cq_stamp work4)")
CLAUDEGPT_ACCOUNT=work4 CODEX_REFRESH_CMD="$CQ_REFRESHER" run_statusline "$cq_payload" >/dev/null \
  || fail "claudegpt debounced render failed"
sleep 0.2
assert test ! -s "$CQ_ARGS"
assert_eq "$cq_before" "$(cat "$(cq_stamp work4)")"

# C: an elapsed deadline probes again.
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$(cq_stamp work4)"
rm -f "$CQ_ARGS"
CLAUDEGPT_ACCOUNT=work4 CODEX_REFRESH_CMD="$CQ_REFRESHER" run_statusline "$cq_payload" >/dev/null \
  || fail "claudegpt elapsed-deadline render failed"
assert cq_wait_args
assert_eq "--refresh-account codex/work4" "$(cat "$CQ_ARGS")"

# D: pushback thins the cadence — a refuser pushes its own deadline out to the backoff, and its
# stderr never reaches the render.
cq_reset
cq_err="$WORK/codex-kick-stderr"
cq_start=$(date +%s)
cq_fail_out=$(CLAUDEGPT_ACCOUNT=work4 CODEX_REFRESH_CMD="$CQ_FAIL" run_statusline "$cq_payload" 2>"$cq_err") \
  || fail "claudegpt kick with failing refresher exited nonzero"
assert grep -Fq '36%' <<< "$cq_fail_out"
assert test "${cq_fail_out#*boom}" = "$cq_fail_out"
assert_eq "" "$(cat "$cq_err")"
assert cq_wait_args
cq_backoff=""
for _ in $(seq 1 60); do
  cq_backoff=$(cat "$(cq_stamp work4)" 2>/dev/null)
  [ "${cq_backoff:-0}" -ge "$((cq_start + 1800))" ] && break
  sleep 0.05
done
assert test "${cq_backoff:-0}" -ge "$((cq_start + 1800))"

# E: a slow refresher never blocks the render.
cq_reset
cq_start=$(date +%s)
CLAUDEGPT_ACCOUNT=work4 CODEX_REFRESH_CMD="$CQ_SLOW" run_statusline "$cq_payload" >/dev/null \
  || fail "claudegpt kick with slow refresher exited nonzero"
assert test "$(( $(date +%s) - cq_start ))" -lt 2

# F: the account label is an environment variable this process does not own — a name that is not
# a launcher account name probes nothing and writes no stamp anywhere.
cq_reset
CLAUDEGPT_ACCOUNT='../escape' CODEX_REFRESH_CMD="$CQ_REFRESHER" run_statusline "$cq_payload" >/dev/null \
  || fail "claudegpt kick with a rejected account name exited nonzero"
sleep 0.2
assert test ! -s "$CQ_ARGS"
assert test -z "$(find "$STATE_DIR" -name 'codex-quota-kick-*' 2>/dev/null)"
assert test ! -e "$HOME/.cache/codex-quota-kick-escape"

# G: an Anthropic-model render never probes Codex quota.
cq_reset
CODEX_REFRESH_CMD="$CQ_REFRESHER" run_statusline "$(statusline_payload cq-claude)" >/dev/null \
  || fail "claude render with the codex refresher configured failed"
sleep 0.2
assert test ! -s "$CQ_ARGS"
assert test -z "$(find "$STATE_DIR" -name 'codex-quota-kick-*' 2>/dev/null)"

# H: a gateway label naming no Codex profile probes nothing and stamps nothing — the collector
# warns about a missing home and still exits 0, so a fired deadline would never back off.
cq_reset
assert test ! -d "$HOME/.codex-profiles/nocodexhome"
CLAUDEGPT_ACCOUNT=nocodexhome CODEX_REFRESH_CMD="$CQ_REFRESHER" run_statusline "$cq_payload" >/dev/null \
  || fail "claudegpt render for an account with no codex profile failed"
sleep 0.2
assert test ! -s "$CQ_ARGS"
assert test -z "$(find "$STATE_DIR" -name 'codex-quota-kick-*' 2>/dev/null)"
mkdir -p "$HOME/.codex-profiles/nocodexhome"
CLAUDEGPT_ACCOUNT=nocodexhome CODEX_REFRESH_CMD="$CQ_REFRESHER" run_statusline "$cq_payload" >/dev/null \
  || fail "claudegpt render after creating the codex profile failed"
assert cq_wait_args
assert_eq "--refresh-account codex/nocodexhome" "$(cat "$CQ_ARGS")"
rmdir "$HOME/.codex-profiles/nocodexhome"
cq_reset
printf '{}' > "$WORK/limits.json"

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
assert grep -Fq "${GREEN}+5${RESET}/${RED}-1${RESET}" <<< "$dmix_out"
assert test "${dmix_out#*"f${RESET}"}" = "$dmix_out"

# Staging is still uncommitted: nothing moves.
dgit add tracked.txt
dstage_out=$(run_statusline "$(statusline_payload diff-staged "$diff_extra")")
assert grep -Fq "${GREEN}+5${RESET}/${RED}-1${RESET}" <<< "$dstage_out"
assert test "${dstage_out#*"f${RESET}"}" = "$dstage_out"

# A commit (by any session/agent) drops its part on the very next render.
dgit commit -qm second
dcommit_out=$(run_statusline "$(statusline_payload diff-committed "$diff_extra")")
assert grep -Fq "${GREEN}+3${RESET}/${RED}-0${RESET}" <<< "$dcommit_out"
assert test "${dcommit_out#*"f${RESET}"}" = "$dcommit_out"

# Deleting a tracked file: negative lines, and no file count beside them.
dgit add new.txt
dgit commit -qm third
dgit rm -q new.txt
ddel_out=$(run_statusline "$(statusline_payload diff-deleted "$diff_extra")")
assert grep -Fq "${GREEN}+0${RESET}/${RED}-3${RESET}" <<< "$ddel_out"
assert test "${ddel_out#*"f${RESET}"}" = "$ddel_out"
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
assert grep -Fq "${GREEN}+1${RESET}/${RED}-0${RESET}" <<< "$dsoft_out"
assert test "${dsoft_out#*"f${RESET}"}" = "$dsoft_out"
dgit commit -qm feat-version-again
dgit checkout -q main

# The LLM cd's into another repo mid-session: the diff follows the ACTIVE repo.
printf 'w1\nw2\n' > "$TOP_B/wt-junk.txt"
place_set diff-workdir "$TOP_B"
dwd_out=$(run_statusline "$(statusline_payload diff-workdir "$diff_extra")")
assert grep -Fq "⧉ $(basename "$TOP_B")" <<< "$dwd_out"
assert grep -Fq "${GREEN}+2${RESET}/${RED}-0${RESET}" <<< "$dwd_out"
rm -f "$TOP_B/wt-junk.txt" "$STATE_DIR/place-diff-workdir"

# Detached HEAD still measures the diff (vs the detached commit).
printf 'd1\n' > "$TOP_K/det-junk.txt"
det_extra=$(jq -cn --arg d "$TOP_K" '{cwd:$d,workspace:{current_dir:$d,project_dir:$d}}')
ddet_out=$(run_statusline "$(statusline_payload diff-detached "$det_extra")")
assert grep -Fq "@$SHORT_SHA" <<< "$ddet_out"
assert grep -Fq "${GREEN}+1${RESET}/${RED}-0${RESET}" <<< "$ddet_out"
rm -f "$TOP_K/det-junk.txt"

# Unborn HEAD (no commits yet): staged lines count via the --cached fallback.
REPO_E="$FIXTURES/diff-unborn"
mkdir -p "$REPO_E"
git -C "$REPO_E" init -qb main
printf 'x\ny\n' > "$REPO_E/f.txt"
git -C "$REPO_E" add f.txt
unborn_extra=$(jq -cn --arg d "$REPO_E" '{cwd:$d,workspace:{current_dir:$d,project_dir:$d}}')
dunborn_out=$(run_statusline "$(statusline_payload diff-unborn "$unborn_extra")")
assert grep -Fq "${GREEN}+2${RESET}/${RED}-0${RESET}" <<< "$dunborn_out"

# Unborn HEAD, staged file modified again in the worktree: the worktree is the
# truth — no double count of the staged intermediate.
printf 'p\nq\n' > "$REPO_E/f.txt"
dunborn2_out=$(run_statusline "$(statusline_payload diff-unborn-mod "$unborn_extra")")
assert grep -Fq "${GREEN}+2${RESET}/${RED}-0${RESET}" <<< "$dunborn2_out"

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
1019 1000 node server.js --config codex.json
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
node      1019 u  38u  IPv4  0t0      TCP *:4900 (LISTEN)
OUT
LSEOF
chmod +x "$FAKE_LSOF"
FAKE_LSOF_EMPTY="$FIXTURES/ports-lsof-empty"
printf '#!/usr/bin/env bash\nprintf "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\\n"\n' > "$FAKE_LSOF_EMPTY"
chmod +x "$FAKE_LSOF_EMPTY"

run_probe() {
  STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$FAKE_LSOF" "$PORTS_PROBE" "$1" "$2" "${3:-}"
}
# The cache carries one record per line, `<port>\t<tree>`, and `-` is the tree of a port that no
# working tree of the project holds — which is every port of a probe given no root at all.
ports_records() {
  local p out=""
  for p in "$@"; do out="${out}${p}"$'\t'"-"$'\n'; done
  printf '%s' "$out"
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
# because the listener filter makes the header check redundant. 4900 is a dev server whose FLAG
# VALUE names an LLM tool (`--config codex.json`): only argv[0] and the script it runs are read.
assert_eq "$(ports_records 5173 8123 5174 8080 4500 4600 4700 4800 4900)" "$(cat "$STATE_DIR/ports-pp-parse")"

# A server backgrounded from a tool call is reparented to launchd as soon as that call returns —
# the case the ancestry walk alone could never see, and the one every dev server actually hits.
# Its working directory is inside the repository being shown, so it is claimed back; the one
# elsewhere is not, and neither is /projx, whose name merely starts with the repository's. 62150 has
# the right directory and the wrong port: a directory is weaker evidence than a parent, and every
# editor RPC socket started from the repository would otherwise fill the segment.
# /proj is no repository, so the one root given is the whole project and 4254 is attributed to it;
# every other port here is one this session parents, and its own directory places none of them.
run_probe pp-orphan 1001 /proj
assert_eq "$(printf '5173\t-\n8123\t-\n5174\t-\n8080\t-\n4254\t/proj\n4500\t-\n4600\t-\n4700\t-\n4800\t-\n4900\t-')" \
  "$(cat "$STATE_DIR/ports-pp-orphan")"

# The repository places an orphan, never someone else's session: 1001-1009 hang off the other
# claude, and a repository argument must not turn them into this session's servers. 4500 sits under
# a worker of that other session and is just as much theirs.
run_probe pp-orphan-other 9999 /proj
assert_eq "$(printf '4254\t/proj')" "$(cat "$STATE_DIR/ports-pp-orphan-other")"

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
assert_eq "$(ports_records 8127)" "$(cat "$STATE_DIR/ports-pp-4dig")"

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
assert_eq "$(ports_records 4321)" "$(cat "$STATE_DIR/ports-pp-tools")"


# Each port is attributed to the WORKING TREE its process directory sits in, and the worktrees live
# INSIDE the repository, so the root cannot claim them: the render's whole colour rule rests on
# this. A sibling checkout whose name merely starts with a tree's is not inside it.
SIB_A="$FIXTURES/repo a-extra"
mkdir -p "$SIB_A"
FAKE_PS_TREES="$FIXTURES/ports-ps-trees"
cat > "$FAKE_PS_TREES" <<'PSEOFW'
#!/usr/bin/env bash
cat <<'SNAP'
1000 1 claude
1001 1000 node /path/to/vite
1010 1 node /main/server.js
1011 1 node /wt/server.js
1012 1 node /sibling/server.js
1013 1 node /gone/server.js
SNAP
PSEOFW
chmod +x "$FAKE_PS_TREES"
FAKE_LSOF_TREES="$FIXTURES/ports-lsof-trees"
cat > "$FAKE_LSOF_TREES" <<LSEOFW
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = cwd ] || continue
  cat <<CWD
p1001
n$TOP_A
p1010
n$TOP_A
p1011
n$TOP_E/deep/inside
p1012
n$SIB_A
p1013
n$TOP_A/.claude/worktrees/gone-wt/apps/portal
CWD
  exit 0
done
cat <<'OUT'
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
node     1001 u   20u  IPv4  0t0      TCP *:5173 (LISTEN)
node     1010 u   30u  IPv4  0t0      TCP *:4001 (LISTEN)
node     1011 u   31u  IPv4  0t0      TCP *:4002 (LISTEN)
node     1012 u   32u  IPv4  0t0      TCP *:4003 (LISTEN)
node     1013 u   33u  IPv4  0t0      TCP *:4004 (LISTEN)
OUT
LSEOFW
chmod +x "$FAKE_LSOF_TREES"
run_probe_trees() {
  STATUSLINE_PS="$FAKE_PS_TREES" STATUSLINE_LSOF="$FAKE_LSOF_TREES" "$PORTS_PROBE" "$1" 1001 "$2"
}
# A server started in a worktree that was later removed keeps the gone worktree's path, not the root.
trees_expected=$(printf '5173\t%s\n4001\t%s\n4002\t%s\n4004\t%s' "$TOP_A" "$TOP_A" "$TOP_E" \
  "$TOP_A/.claude/worktrees/gone-wt")
run_probe_trees pp-trees "$TOP_A"
assert_eq "$trees_expected" "$(cat "$STATE_DIR/ports-pp-trees")"
# The tree list is the whole project whichever of its trees the probe was given, so the records do
# not change when the session sits in a worktree — only the render's reading of them does.
run_probe_trees pp-trees-wt "$TOP_E"
assert_eq "$trees_expected" "$(cat "$STATE_DIR/ports-pp-trees-wt")"

run_probe pp-selfroot 9999
assert test -f "$STATE_DIR/ports-pp-selfroot"
assert_eq "" "$(cat "$STATE_DIR/ports-pp-selfroot")"

run_probe pp-noroot 1
assert_eq "" "$(cat "$STATE_DIR/ports-pp-noroot")"

printf '5173\n' > "$STATE_DIR/ports-pp-death"
STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$FAKE_LSOF_EMPTY" "$PORTS_PROBE" pp-death 1001
assert_eq "" "$(cat "$STATE_DIR/ports-pp-death")"

# --- render of the two new segments ---
# One record per line now, so these two fixtures carry the tab format; `-` is a port this session
# parents whose directory no tree of the project holds, and it is bright wherever the block sits.
ports_records 5173 8080 > "$STATE_DIR/ports-r-ports"
rports_out=$(run_statusline "$(statusline_payload r-ports)")
assert grep -Fq "${GREEN}:5173${RESET}" <<< "$rports_out"
assert grep -Fq "${GREEN}:8080${RESET}" <<< "$rports_out"
assert grep -Fq '⇢' <<< "$rports_out"

ports_records 1 2 3 4 5 > "$STATE_DIR/ports-r-cap"
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

# The colour says whose tree a port is, and the SHOWN tree decides (Egor, 2026-09-04). From the
# main checkout everything the project has up is on the strip: its own ports bright, every
# worktree's dim — and own-tree ports come first, so the three-port cap cannot spend itself on
# siblings and hide the one Egor is here to open.
# The tops and not `$REPO_A`/`$REPO_E`: a case above rebinds `REPO_E` to another fixture.
tree_cache=$(printf '4002\t%s\n5173\t%s\n6001\t-\n' "$TOP_E" "$TOP_A")
printf '%s' "$tree_cache" > "$STATE_DIR/ports-r-tree-main"
rtmain_out=$(run_statusline "$(statusline_payload r-tree-main '' "$TOP_A")")
assert grep -Fq "${DIM}⇢${RESET} ${GREEN}:5173${RESET} ${GREEN}:6001${RESET} ${DIM}:4002${RESET}" \
  <<< "$rtmain_out"

# Shown a worktree, only that worktree's ports are on the strip at all — a sibling tree's are not
# dimmed, they are absent, because from here they are somebody else's work.
printf '%s' "$tree_cache" > "$STATE_DIR/ports-r-tree-wt"
rtwt_out=$(run_statusline "$(statusline_payload r-tree-wt '' "$TOP_E")")
assert grep -Fq "${DIM}⇢${RESET} ${GREEN}:4002${RESET} ${GREEN}:6001${RESET}" <<< "$rtwt_out"
assert test "${rtwt_out#*:5173}" = "$rtwt_out"

# End-to-end over the real probe: the same records read one way from the root and another from the
# worktree, which is the whole point of writing the tree into the cache.
run_probe_trees r-tree-e2e "$TOP_A"
rte2e_out=$(run_statusline "$(statusline_payload r-tree-e2e '' "$TOP_A")")
assert grep -Fq "${GREEN}:5173${RESET} ${GREEN}:4001${RESET} ${DIM}:4002${RESET}" <<< "$rte2e_out"
cp "$STATE_DIR/ports-r-tree-e2e" "$STATE_DIR/ports-r-tree-e2e-wt"
rte2ewt_out=$(run_statusline "$(statusline_payload r-tree-e2e-wt '' "$TOP_E")")
assert grep -Fq "${DIM}⇢${RESET} ${GREEN}:4002${RESET}" <<< "$rte2ewt_out"
assert test "${rte2ewt_out#*:4001}" = "$rte2ewt_out"

printf '%s' "$tree_cache" > "$STATE_DIR/ports-r-tree-foreign"
place_set r-tree-foreign "$TOP_D"
rtforeign_out=$(run_statusline "$(statusline_payload r-tree-foreign '' "$TOP_A")")
assert test "${rtforeign_out#*⇢}" = "$rtforeign_out"

# One seed per spawn: the newest `pending-<type>-<key>` file the spawn hook left in that session.
seed_of() { # session agent-type
  local seed
  seed=$(ls -t "$HOME/.cache/claude-worker-tags/$1/pending-$2"-* 2>/dev/null | head -n1)
  [ -n "$seed" ] && head -n1 "$seed"
}

worker_payload() {
  jq -cn --arg type "$1" --arg id "$2" --arg description "$3" --arg command "$4" --arg session "${5:-wt}" '
    {hook_event_name:"PreToolUse",tool_name:"Bash",session_id:$session,agent_type:$type,agent_id:$id,
     tool_input:{command:$command,description:$description,timeout:42}}'
}
TAGDIR="$HOME/.cache/claude-worker-tags/wt"

# A codex launch command derives the tag (main, high), stores it, and prefixes.
seed=$(worker_payload codex-worker worker/one 'Investigate the suite' "codex exec -c model_reasoning_effort=high 'go'")
seed_output=$(printf '%s' "$seed" | "$WORKER_HOOK") || fail "worker seed exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "main · astra · high — Investigate the suite"' <<< "$seed_output" >/dev/null
assert_eq 'main · astra · high' "$(cat "$TAGDIR/workerone")"

rm -f "$HOME/.claude/worker-model"
default_effort_seed=$(worker_payload codex-worker worker/default-effort 'Use table defaults' "codex exec 'go'")
printf '%s' "$default_effort_seed" | "$WORKER_HOOK" >/dev/null || fail "default-effort codex tag exited nonzero"
assert_eq 'main · astra · low' "$(cat "$TAGDIR/workerdefault-effort")"
default_effort_claudeb=$(worker_payload claudeb-worker worker/default-effort-claudeb 'Use table defaults' 'claudeb --model opus -p task')
printf '%s' "$default_effort_claudeb" | "$WORKER_HOOK" >/dev/null || fail "default-effort claudeb tag exited nonzero"
assert_eq '? · opus · high' "$(cat "$TAGDIR/workerdefault-effort-claudeb")"

# A later non-launch command reuses the stored tag to prefix its description.
later=$(worker_payload codex-worker worker/one 'Run focused tests' 'bash tests/focused.sh')
later_output=$(printf '%s' "$later" | "$WORKER_HOOK") || fail "worker rewrite exited nonzero"
assert jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and
  .hookSpecificOutput.permissionDecision == "allow" and
  .hookSpecificOutput.updatedInput.description == "main · astra · high — Run focused tests" and
  .hookSpecificOutput.updatedInput.command == "bash tests/focused.sh" and
  .hookSpecificOutput.updatedInput.timeout == 42' <<< "$later_output" >/dev/null

# An already-prefixed description is left untouched (no stacking).
prefixed=$(worker_payload codex-worker worker/one 'main · astra · high — Run focused tests' true)
prefixed_output=$(printf '%s' "$prefixed" | "$WORKER_HOOK") || fail "prefixed worker call exited nonzero"
assert_eq "" "$prefixed_output"

mkdir -p "$HOME/.codex"
for config_model in gpt-9-zenith gpt-5.6-terra; do
  printf 'model = "%s"\n' "$config_model" > "$HOME/.codex/config.toml"
  seed_default=$(worker_payload codex-worker worker/default 'Optimize compute' "codex exec -c model_reasoning_effort=high 'go'")
  seed_default_out=$(printf '%s' "$seed_default" | "$WORKER_HOOK") || fail "default model seed exited nonzero"
  assert_eq 'main · astra · high' "$(cat "$TAGDIR/workerdefault")"
  for label_script in "$WORKER_HOOK" "$SPAWN_HOOK"; do
    label=$(
      . "$ROOT/share/worker-model.sh"
      eval "$(sed -n '/^codex_model_short_label() {/,/^}/p' "$label_script")"
      codex_model_short_label
    )
    assert_eq astra "$label"
  done
done
rm -f "$HOME/.codex/config.toml"

# worker-run wait/report adopt the tag the launcher wrote into its run dir, and
# re-derive it on every call (the launcher may resolve a different account than
# the spawn-time seed predicted).
WRDIR="$HOME/.cache/claude-worker-runs/codex-1-2-abcd"
mkdir -p "$WRDIR"
printf 'work6 · astra · high\n' > "$WRDIR/tag"
wr_wait=$(worker_payload codex-worker worker/wrun 'Wait for the run' 'worker-run wait codex-1-2-abcd --max 500')
wr_out=$(printf '%s' "$wr_wait" | "$WORKER_HOOK") || fail "worker-run wait exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "work6 · astra · high — Wait for the run"' <<< "$wr_out" >/dev/null
assert_eq 'work6 · astra · high' "$(head -n1 "$TAGDIR/workerwrun")"
assert_eq 'run=codex-1-2-abcd' "$(sed -n 2p "$TAGDIR/workerwrun")"
printf 'work3 · astra · high\n' > "$WRDIR/tag"
wr_report=$(worker_payload codex-worker worker/wrun 'Collect the report' 'worker-run report codex-1-2-abcd')
wr_report_out=$(printf '%s' "$wr_report" | "$WORKER_HOOK") || fail "worker-run report exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "work3 · astra · high — Collect the report"' <<< "$wr_report_out" >/dev/null

# A run id hidden behind a shell variable is unresolvable from command text; the
# hook must degrade to the previously stored tag, not crash or mis-tag.
wr_var=$(worker_payload codex-worker worker/wrun 'Keep waiting' 'worker-run wait "$RUN_ID" --max 100')
wr_var_out=$(printf '%s' "$wr_var" | "$WORKER_HOOK") || fail "worker-run variable-id wait exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "work3 · astra · high — Keep waiting"' <<< "$wr_var_out" >/dev/null

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
assert_eq 'alt · astra · low' "$(cat "$TAGDIR/workercenv")"

# A profile name never starts with a hyphen: a malformed launch must fall back to
# the configured account, not tag the flag that followed.
printf 'claudeb_model=opus\nclaudeb_effort=high\n' > "$HOME/.claude/worker-model"
malformed=$(worker_payload claudeb-worker worker/malformed 'Run it' 'claudeb profile --resume abc123 -p x')
printf '%s' "$malformed" | "$WORKER_HOOK" >/dev/null || fail "malformed-profile launch exited nonzero"
assert_eq '? · opus · high' "$(cat "$TAGDIR/workermalformed")"

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
assert jq -e '.hookSpecificOutput.updatedInput.description == "? · opus · high: Implement fixture"' \
  <<<"$unknown_spawn_out" >/dev/null
assert_eq '? · opus · high' \
  "$(seed_of spawn-claudeb-unknown claudeb-worker)"

rm -f "$HOME/.claude/worker-model"
default_effort_spawn=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-codex-default-effort",
  tool_input:{subagent_type:"codex-worker",description:"Implement fixture",prompt:"Working directory: /tmp"}}')
default_effort_spawn_out=$(printf '%s' "$default_effort_spawn" | WORKER_SPAWN_WORKER_PICK=/nonexistent "$SPAWN_HOOK") || fail "default-effort codex spawn exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "main · astra · low: Implement fixture"' \
  <<<"$default_effort_spawn_out" >/dev/null
assert_eq 'main · astra · low' \
  "$(seed_of spawn-codex-default-effort codex-worker)"
default_effort_claudeb_spawn=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-claudeb-default-effort",
  tool_input:{subagent_type:"claudeb-worker",description:"Implement fixture",prompt:"Working directory: /tmp"}}')
printf '%s' "$default_effort_claudeb_spawn" | WORKER_SPAWN_WORKER_PICK=/nonexistent "$SPAWN_HOOK" >/dev/null || fail "default-effort claudeb spawn exited nonzero"
assert_eq '? · opus · high' \
  "$(seed_of spawn-claudeb-default-effort claudeb-worker)"

unknown_tag=$(worker_payload claudeb-worker worker/unknown 'Run it' 'claudeb --model opus -p task')
unknown_tag_out=$(printf '%s' "$unknown_tag" | "$WORKER_HOOK") || fail "unknown-account tag hook exited nonzero"
assert_eq '? · opus · high' "$(cat "$TAGDIR/workerunknown")"
assert jq -e '.hookSpecificOutput.updatedInput.description == "? · opus · high — Run it"' \
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

# The launch line's own model has to be the one that shows: `grok-4.6` collapses to the vendor word
# and would render the same as the knob fallback, so the seed names a model neither path produces.
printf 'grok_model=auto\ngrok_effort=high\n' > "$HOME/.claude/worker-model"
grok_seed=$(worker_payload grok-worker worker/grok 'Implement it' \
  "env GROK_MEMORY=0 $HOME/.local/bin/grokb profile supergrok --prompt-file /tmp/brief --output-format streaming-json -m grok-4.5 --reasoning-effort xhigh")
grok_seed_output=$(printf '%s' "$grok_seed" | "$WORKER_HOOK") || fail "grok-tag seed exited nonzero"
assert_eq 'supergrok · grok-4.5 · xhigh' "$(cat "$TAGDIR/workergrok")"
assert jq -e '.hookSpecificOutput.updatedInput.description == "supergrok · grok-4.5 · xhigh — Implement it"' \
  <<< "$grok_seed_output" >/dev/null
# `grok-4.6` is the one launch-line model that does collapse to the vendor word.
grok_collapse=$(worker_payload grok-worker worker/grokcollapse 'Implement it' \
  "grokb profile supergrok --prompt-file /tmp/brief -m grok-4.6 --reasoning-effort xhigh")
printf '%s' "$grok_collapse" | "$WORKER_HOOK" >/dev/null || fail "grok collapse tag exited nonzero"
assert_eq 'supergrok · grok · xhigh' "$(cat "$TAGDIR/workergrokcollapse")"

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

# `auto` never reaches a tag: the vendor word stands in, like codex's `astra`.
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
# The brief's MODEL: line has to reach the row, so it names a model the knob fallback and the
# `grok-4.6` collapse both cannot produce.
grok_spawn=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-grok",
  tool_input:{subagent_type:"grok-worker",description:"Implement fixture",
              prompt:"ACCOUNT: supergrok\nMODEL: grok-4.5\nEFFORT: high\nWorking directory: /tmp"}}')
grok_spawn_output=$(printf '%s' "$grok_spawn" | "$SPAWN_HOOK") || fail "grok spawn hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "supergrok · grok-4.5 · high: Implement fixture"' \
  <<< "$grok_spawn_output" >/dev/null
assert_eq 'supergrok · grok-4.5 · high' \
  "$(seed_of spawn-grok grok-worker)"

# No MODEL: line and grok_model=auto — the row says the vendor, not the knob word.
grok_auto_spawn=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-grok-auto",
  tool_input:{subagent_type:"grok-worker",description:"Implement fixture",
              prompt:"ACCOUNT: supergrok\nEFFORT: high\nWorking directory: /tmp"}}')
grok_auto_output=$(printf '%s' "$grok_auto_spawn" | "$SPAWN_HOOK") || fail "grok auto spawn hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "supergrok · grok · high: Implement fixture"' \
  <<< "$grok_auto_output" >/dev/null
assert_eq 'supergrok · grok · high' \
  "$(seed_of spawn-grok-auto grok-worker)"

printf 'gemini_model=flash38\ngemini_effort=high\n' > "$HOME/.claude/worker-model"
spawn_payload=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-gemini",
  tool_input:{subagent_type:"gemini-worker",description:"Implement fixture",
              prompt:"ACCOUNT: second\nMODEL: flash\nEFFORT: medium\nWorking directory: /tmp"}}')
spawn_output=$(printf '%s' "$spawn_payload" | "$SPAWN_HOOK") || fail "gemini spawn hook exited nonzero"
# `EFFORT: medium` in the brief is not what will be spent: worker-run raises every Gemini run to
# high, and the row names the launch rather than the ask.
assert jq -e '.hookSpecificOutput.updatedInput.description == "second · 3.8-flash · high: Implement fixture"' \
  <<< "$spawn_output" >/dev/null
assert_eq 'second · 3.8-flash · high' \
  "$(seed_of spawn-gemini gemini-worker)"
assert test "$(cat "$HOME/.cache/claude-worker-tags/spawn-gemini"/pending-gemini-worker-* | grep -c '^light=')" -eq 0

# `geminib families` is a hook-time call, and the hook runs where geminib may be missing: the row
# still names the model, read off the slug's own shape rather than a family literal (those live in
# geminib alone, tests/test_consistency.sh).
NO_GEMINIB="$WORK/no-geminib"
mkdir -p "$NO_GEMINIB/bin"
cp -R "$ROOT/share" "$NO_GEMINIB/share"
cp "$SPAWN_HOOK" "$NO_GEMINIB/bin/"
assert test ! -e "$NO_GEMINIB/bin/geminib"
offline_spawn=$(jq -cn '{
  hook_event_name:"PreToolUse",session_id:"spawn-gemini-offline",
  tool_input:{subagent_type:"gemini-worker",description:"Implement fixture",
              prompt:"ACCOUNT: second\nMODEL: flash38\nEFFORT: high\nWorking directory: /tmp"}}')
offline_output=$(printf '%s' "$offline_spawn" | "$NO_GEMINIB/bin/worker-spawn-hook.sh") \
  || fail "offline gemini spawn hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "second · 3.8-flash · high: Implement fixture"' \
  <<< "$offline_output" >/dev/null
assert_eq 'second · 3.8-flash · high' \
  "$(seed_of spawn-gemini-offline gemini-worker)"

# light-research is not a worker: its row is `light research · <model>`, the model the light_research
# row's and never the worker-model knobs. The account IS predicted — a
# pin first, then the router under `--role research`, the role this leg spends under, so a gemini
# parked for workers alone still answers — and `?` only where nothing answers at all.
research_spawn() { # session prompt [worker-pick]
  jq -cn --arg session "$1" --arg prompt "$2" '{
    hook_event_name:"PreToolUse",session_id:$session,
    tool_input:{subagent_type:"light-research",description:"Map the hooks",prompt:$prompt}}' |
    WORKER_SPAWN_WORKER_PICK="${3:-$HOME/.local/bin/worker-pick}" "$SPAWN_HOOK"
}
RESEARCH_PICK="$WORK/research-worker-pick"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\necho routedaccount\n' \
  "$WORK/research-pick.log" > "$RESEARCH_PICK"
chmod +x "$RESEARCH_PICK"
: > "$WORK/research-pick.log"
# A knob that must not reach this row: worker-model says flash36/medium, the launcher says otherwise.
printf 'gemini_model=flash36\ngemini_effort=medium\n' > "$HOME/.claude/worker-model"
research_routed=$(research_spawn spawn-research 'Where is the tag written?' "$RESEARCH_PICK")
assert jq -e '.hookSpecificOutput.updatedInput.description == "light research · 3.8-flash · routedaccount: Map the hooks"' \
  <<< "$research_routed" >/dev/null
assert_eq 'light research · 3.8-flash · routedaccount' \
  "$(seed_of spawn-research light-research)"
# The role travels with the query: the plain `--account gemini` reads the workers switch and
# answers `off` for a vendor open to research.
assert_eq '--account gemini --role research' "$(cat "$WORK/research-pick.log")"

: > "$WORK/research-pick.log"
research_pinned=$(research_spawn spawn-research-pin $'ACCOUNT: pinned\nWhere is the tag written?' "$RESEARCH_PICK")
assert_eq 'light research · 3.8-flash · pinned' \
  "$(seed_of spawn-research-pin light-research)"

# An `--account` the brief spells on the launch line is the same pin by another spelling.
research_flag=$(research_spawn spawn-research-flag \
  $'Run light-research --account flagged --prompt-file /tmp/q --out /tmp/a --repo /tmp/r' "$RESEARCH_PICK")
assert_eq 'light research · 3.8-flash · flagged' \
  "$(seed_of spawn-research-flag light-research)"

quoted_failures=0
for quoted_account in '"quoted"' "'quoted'"; do
  research_quoted=$(research_spawn spawn-research-quoted \
    "Run light-research --account $quoted_account --prompt-file /tmp/q" "$RESEARCH_PICK")
  asserts=$((asserts + 1))
  if [ "$(seed_of spawn-research-quoted light-research)" != 'light research · 3.8-flash · quoted' ]; then
    printf 'FAIL: quoted research account %s\n' "$quoted_account" >&2
    quoted_failures=$((quoted_failures + 1))
  fi
done
[ "$quoted_failures" -eq 0 ] || exit 1

# A pin outranks the router, which is not asked at all where the brief already named the account.
assert test ! -s "$WORK/research-pick.log"

# `?` is the answer to silence alone: a picker that names nobody leaves the row saying so.
SILENT_PICK="$WORK/silent-worker-pick"
printf '#!/usr/bin/env bash\nexit 3\n' > "$SILENT_PICK"
chmod +x "$SILENT_PICK"
research_silent=$(research_spawn spawn-research-none 'Where is the tag written?' "$SILENT_PICK")
assert_eq 'light research · 3.8-flash · ?' \
  "$(seed_of spawn-research-none light-research)"
printf 'gemini_model=flash38\ngemini_effort=high\n' > "$HOME/.claude/worker-model"

# The light_research row moves the vendor, the model and the router query together.
printf 'light_research=claudeb:sonnet\n' > "$HOME/.claude/worker-model"
: > "$WORK/research-pick.log"
research_spawn spawn-research-claudeb 'Where is the tag written?' "$RESEARCH_PICK" >/dev/null
assert_eq 'light research · sonnet · routedaccount' "$(seed_of spawn-research-claudeb light-research)"
assert_eq '--account claudeb --role research' "$(cat "$WORK/research-pick.log")"
research_tag=$(worker_payload light-research worker/researchsonnet 'Search the tree' \
  'light-research --prompt-file /tmp/q --out /tmp/a --repo /tmp/r --account worker')
research_tag_out=$(printf '%s' "$research_tag" | "$WORKER_HOOK") || fail "research tag hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "worker · sonnet · medium — Search the tree"' \
  <<< "$research_tag_out" >/dev/null

# light-worker is a relay whose vendor, model and effort are the light_edit row's.
light_worker_spawn() { # session prompt [worker-pick]
  jq -cn --arg session "$1" --arg prompt "$2" '{
    hook_event_name:"PreToolUse",session_id:$session,
    tool_input:{subagent_type:"light-worker",description:"Fix typo",prompt:$prompt}}' |
    WORKER_SPAWN_WORKER_PICK="${3:-$HOME/.local/bin/worker-pick}" "$SPAWN_HOOK"
}
printf 'light_edit=codex\n' > "$HOME/.claude/worker-model"
: > "$WORK/research-pick.log"
light_edit_out=$(light_worker_spawn spawn-light-edit 'Fix the typo' "$RESEARCH_PICK")
assert jq -e '.hookSpecificOutput.updatedInput.description == "light edit · astra · routedaccount: Fix typo"' \
  <<< "$light_edit_out" >/dev/null
assert_eq '--account codex --role light' "$(cat "$WORK/research-pick.log")"
assert grep -qx 'light=edit' "$(ls -t "$HOME/.cache/claude-worker-tags/spawn-light-edit"/pending-light-worker-* | head -n1)"
: > "$HOME/.claude/worker-model"
light_worker_spawn spawn-light-default $'ACCOUNT: pinned\nFix the typo' "$RESEARCH_PICK" >/dev/null
assert_eq 'light edit · 3.8-flash · pinned' "$(seed_of spawn-light-default light-worker)"
# `<vendor>_workers=off` closes neither Light role, so the row names the account the run will land
# on; asked as a workers query it would fall through to `?` and predict an account nobody spends.
ROLE_PICK="$WORK/role-worker-pick"
cat >"$ROLE_PICK" <<'ROLEPICK'
#!/usr/bin/env bash
case "$*" in
  *'--role light'*) printf 'lightaccount\n' ;;
  *) exit 3 ;;
esac
ROLEPICK
chmod +x "$ROLE_PICK"
printf 'light_edit=gemini\ngemini_workers=off\n' > "$HOME/.claude/worker-model"
light_worker_spawn spawn-light-off 'Fix the typo' "$ROLE_PICK" >/dev/null
assert_eq 'light edit · 3.8-flash · lightaccount' "$(seed_of spawn-light-off light-worker)"
printf 'gemini_model=flash38\ngemini_effort=high\n' > "$HOME/.claude/worker-model"

# In flight, `--account` on the launch line is the account being spent.
research_tag=$(worker_payload light-research worker/research 'Search the tree' \
  'light-research --prompt-file /tmp/q --out /tmp/a --repo /tmp/r --account rawilimo')
research_tag_out=$(printf '%s' "$research_tag" | "$WORKER_HOOK") || fail "research tag hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "rawilimo · flash38 · high — Search the tree"' \
  <<< "$research_tag_out" >/dev/null
assert_eq 'rawilimo · flash38 · high' "$(cat "$TAGDIR/workerresearch")"
# A relay worker already bypasses permissions, so `allow` there only spares it a second prompt;
# light-research runs INSIDE this session, where the same word would grant a call nobody granted.
assert jq -e '.hookSpecificOutput | has("permissionDecision") | not' <<< "$research_tag_out" >/dev/null
assert jq -e '.hookSpecificOutput.permissionDecision == "allow"' <<< "$seed_output" >/dev/null

# Without one the script asks worker-pick at run time, so the spawn seed is the better answer.
printf 'seeded · flash38 · high\n' > "$TAGDIR/pending-light-research"
research_seeded=$(worker_payload light-research worker/researchseed 'Search the tree' \
  'light-research --prompt-file /tmp/q --out /tmp/a --repo /tmp/r')
research_seeded_out=$(printf '%s' "$research_seeded" | "$WORKER_HOOK") \
  || fail "seeded research tag hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "seeded · flash38 · high — Search the tree"' \
  <<< "$research_seeded_out" >/dev/null

# image-gen is a relay too: `<account> · <short model>`, the short name from the vendor's caps
# manifest (VENDOR: line, codex by default), account from a pin in the brief — an `ACCOUNT:` line or
# an `--account` on the launch line — else the router's `--role image` answer, else the word `pool`;
# never `?`. A FANOUT: brief is `fanout · image`.
image_spawn() { # session prompt [worker-pick]
  jq -cn --arg session "$1" --arg prompt "$2" '{
    hook_event_name:"PreToolUse",session_id:$session,
    tool_input:{subagent_type:"image-gen",description:"Draw the icon",prompt:$prompt}}' |
    WORKER_SPAWN_WORKER_PICK="${3:-$HOME/.local/bin/worker-pick}" "$SPAWN_HOOK"
}
IMAGE_PICK="$WORK/image-worker-pick"
printf '#!/usr/bin/env bash\n[ "$1" = --account ] || exit 1\ncase "$2" in codex) echo cxroute ;; gemini) echo gmroute ;; *) exit 3 ;; esac\n' \
  > "$IMAGE_PICK"
chmod +x "$IMAGE_PICK"

# Unpinned: the router's `--role image` answer is the prediction, and the tag keeps its shape so
# the renderer still colours the row.
image_routed=$(image_spawn img-routed $'Draw a cat.\nsize: model\'s choice' "$IMAGE_PICK")
assert jq -e '.hookSpecificOutput.updatedInput.description == "cxroute · gpt-image-2: Draw the icon"' \
  <<< "$image_routed" >/dev/null
assert_eq 'cxroute · gpt-image-2' "$(seed_of img-routed image-gen)"

image_vendor=$(image_spawn img-vendor $'VENDOR: gemini\nDraw a cat.' "$IMAGE_PICK")
assert jq -e '.hookSpecificOutput.updatedInput.description == "gmroute · flash-image-3.1: Draw the icon"' \
  <<< "$image_vendor" >/dev/null
assert_eq 'gmroute · flash-image-3.1' "$(seed_of img-vendor image-gen)"

image_fanout=$(image_spawn img-fanout $'FANOUT: all\nACCOUNTS: all\nDraw a cat.' "$IMAGE_PICK")
assert_eq 'fanout · image' "$(seed_of img-fanout image-gen)"
image_fanout_pick=$(image_spawn img-fanout-pick $'FANOUT: codex|grok\nACCOUNTS: pick\nDraw a cat.' "$IMAGE_PICK")
assert_eq 'fanout · image' "$(seed_of img-fanout-pick image-gen)"

# The brief's own ACCOUNT: line is the pin the script will be given, so it is the one prediction
# this hook may make — and `--account` on the launch line spelled in the brief is the same pin.
image_acct=$(image_spawn img-acct $'ACCOUNT: pinned\nVENDOR: grok\nDraw a cat.' "$IMAGE_PICK")
assert jq -e '.hookSpecificOutput.updatedInput.description == "pinned · imagine-image-2.0: Draw the icon"' \
  <<< "$image_acct" >/dev/null
assert_eq 'pinned · imagine-image-2.0' "$(seed_of img-acct image-gen)"

image_flag=$(image_spawn img-flag \
  $'VENDOR: codex\nRun codex-image --account alt2 --dest /tmp/a.png --prompt "a cat"' "$IMAGE_PICK")
assert_eq 'alt2 · gpt-image-2' "$(seed_of img-flag image-gen)"

# Router silent (exit 3 for grok in the fake) or absent: `pool` — the script will pick from it.
image_unknown=$(image_spawn img-unknown $'VENDOR: grok\nDraw a cat.' "$IMAGE_PICK")
assert_eq 'pool · imagine-image-2.0' "$(seed_of img-unknown image-gen)"
image_nopick=$(image_spawn img-nopick $'VENDOR: grok\nDraw a cat.')
assert_eq 'pool · imagine-image-2.0' "$(seed_of img-nopick image-gen)"

# An image brief edits no instruction file, so the MD guard is not injected into it.
assert jq -e '(.hookSpecificOutput.updatedInput.prompt | test("MD-GUARD")) | not' \
  <<< "$image_unknown" >/dev/null

# In-flight, `--account` on the launch line is the account being spent, whatever the seed guessed.
image_tag=$(worker_payload image-gen worker/img 'Generate the icon' \
  'codex-image --dest /tmp/icon.png --prompt "an icon" --account alt')
image_tag_out=$(printf '%s' "$image_tag" | "$WORKER_HOOK") || fail "image tag hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "alt · gpt-image-2 — Generate the icon"' \
  <<< "$image_tag_out" >/dev/null
assert_eq $'alt · gpt-image-2\nmedia=gen' "$(cat "$TAGDIR/workerimg")"

image_grok_tag=$(worker_payload image-gen worker/imggrok 'Generate the icon' \
  '/usr/local/bin/grok-image --account sg1 --dest /tmp/icon.png --prompt "an icon"')
image_grok_out=$(printf '%s' "$image_grok_tag" | "$WORKER_HOOK") || fail "grok image tag hook exited nonzero"
assert_eq 'sg1 · imagine-image-2.0' "$(head -n1 "$TAGDIR/workerimggrok")"

# The image scripts are called with every argument quoted, so a quoted account is the ORDINARY
# spelling here, not an edge case — read past the quote as the vendor branches above do.
for image_quoted in '--account "alt2"' "--account 'alt2'" '--account="alt2"'; do
  image_quoted_tag=$(worker_payload image-gen worker/imgq 'Generate the icon' \
    "codex-image ${image_quoted} --dest /tmp/icon.png --prompt \"an icon\"")
  printf '%s' "$image_quoted_tag" | "$WORKER_HOOK" >/dev/null || fail "quoted image tag hook exited nonzero"
  assert_eq 'alt2 · gpt-image-2' "$(head -n1 "$TAGDIR/workerimgq")"
  rm -f "$TAGDIR/workerimgq"
done

# No `--account`: the script routes itself at run time, so the seed the spawn hook wrote stands.
printf 'gmroute · flash-image-3.1\n' > "$TAGDIR/pending-image-gen"
image_seeded=$(worker_payload image-gen worker/imgseed 'Generate the icon' \
  'gemini-image --dest /tmp/icon.png --prompt "an icon"')
image_seeded_out=$(printf '%s' "$image_seeded" | "$WORKER_HOOK") || fail "seeded image tag hook exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "gmroute · flash-image-3.1 — Generate the icon"' \
  <<< "$image_seeded_out" >/dev/null

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
review_verdict_delimited=" ${DIM}│${RESET} 3"
# Neither slot carries a word any more, so silence is the absence of every shape the two can take:
# the run's counter in its colourings, and the verdict's number, `~`, `fix` or `?`. Asked of
# line 1 alone, because line 2 opens segments with digits (`5h`).
review_slot_silent() { # rendered
  case "${1%%$'\n'*}" in
    *" ${DIM}│${RESET} "[0-9~]*|*" ${DIM}│${RESET} T"[0-3]*|*" ${DIM}│${RESET} ● "*) return 1 ;;
    *" ${DIM}│${RESET} ${DIM}"[0-9~?]*|*" ${DIM}│${RESET} ${DIM}T"[0-3]*) return 1 ;;
    *" ${DIM}│${RESET} ${DIM}fix "*) return 1 ;;
    *" ${DIM}│${RESET} ${RED}"[0-9]*|*" ${DIM}│${RESET} ${RED}T"[0-3]*) return 1 ;;
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
# default, because the cases below are about the VERDICT alone and an unreadable total is no longer
# silent — it is the third state `?`, which would stand in every one of them.
case "$1" in
  autonomous) printf '%s\n' "${GATE_AUTONOMOUS-}"; exit "${GATE_VERB_RC:-0}" ;;
  # The rendered tree is part of the question, so a caller that drops it gets no number at all.
esac
printf '%s\n' "$GATE_ANSWER"
exit "${GATE_RC:-0}"
STUB
chmod +x "$GATE_STUB"
export GATE_LOG GATE_ANSWER GATE_RC GATE_AUTONOMOUS GATE_VERB_RC
GATE_ANSWER=off
GATE_RC=0
GATE_AUTONOMOUS=
GATE_VERB_RC=0
GATE_CMD="$GATE_STUB"

# The verdict is cached for 15s on a key that cannot see a second edit to an already-modified file
# or a stub told to answer differently; every case here drops it and asks again.
#
# Two renders per case, because the gate is never asked on the render path: the first starts the
# refresh and shows whatever stood before it, the second reads what landed. A render that returned
# the answer straight away would be one waiting a second for git on every prompt.
review_await_session() { # session
  local file="$STATE_DIR/review-autonomy-$1" i
  for i in $(seq 1 100); do
    [ -s "$file" ] && [ ! -d "$file.lock" ] && return 0
    sleep 0.05
  done
  fail "the backgrounded session answer never landed: $1"
}
review_await_verdict() { # session
  local file="$STATE_DIR/review-class-$1" i
  for i in $(seq 1 100); do
    [ -s "$file" ] && [ ! -d "$file.lock" ] && return 0
    sleep 0.05
  done
  fail "the backgrounded verdict never landed: $1"
}
review_render() { # session repo
  local payload
  rm -f "$STATE_DIR/review-class-$1"
  rmdir "$STATE_DIR/review-class-$1.lock" 2>/dev/null
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "review render failed: $1"
  review_await_verdict "$1"
  run_statusline "$payload" || fail "review render failed: $1"
}
# too — the second render is only allowed to be the one that shows the answer.
review_session_render() { # session repo
  local payload
  rm -f "$STATE_DIR/review-class-$1" "$STATE_DIR/review-autonomy-$1"
  rmdir "$STATE_DIR/review-class-$1.lock" "$STATE_DIR/review-autonomy-$1.lock" 2>/dev/null
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "review session render failed: $1"
  review_await_verdict "$1"
  review_await_session "$1"
  run_statusline "$payload" || fail "review session render failed: $1"
}

# The gate is asked about the working tree and this chat, and its answer is printed word for word.
: > "$GATE_LOG"
GATE_ANSWER='STATUS=open LINES=3 FILES=1 FIX=0 WHY=none'
GATE_RC=0
review_none_out=$(review_render review-dirty "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} 3" <<< "$review_none_out"
assert test "${review_none_out#*rev 3}" = "$review_none_out"
assert grep -Fqx "verdict $TOP_REVIEW_DIRTY review-dirty" "$GATE_LOG"

# Debt this chat authored reads bright — normal weight, no colour of its own — and dim is
# everyone else's. Both carry the count verbatim; the segment neither invents a number nor strips
# one, and the number is diff lines, which is the gate's business and not the render's.
GATE_ANSWER='STATUS=open LINES=2 FILES=1 FIX=0 WHY=none'
review_mine_out=$(review_render review-mine "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} 2" <<< "$review_mine_out"
assert test "${review_mine_out#*"│${RESET} ${DIM}2"}" = "$review_mine_out"
assert test "${review_mine_out#*"│${RESET} ${RED}2"}" = "$review_mine_out"

# The watchdog has no voice here at all: a killed run settles nothing, so its paths stand in the
# numbers like any others and the kill is seen through the report flow and `review-bench doctor`
# (review-bench docs/review-contract.md). No word of the gate's own vocabulary is red, and a nonzero exit is
# the gate answering rather than the gate failing.
GATE_RC=2
review_calm_n=0
for review_calm in 'off' 'STATUS=open LINES=3 FILES=1 FIX=0 WHY=none' 'STATUS=open LINES=2 FILES=1 FIX=0 WHY=none'; do
  review_calm_n=$((review_calm_n + 1))
  GATE_ANSWER="$review_calm"
  review_calm_out=$(review_render "review-calm-$review_calm_n" "$REVIEW_DIRTY")
  assert test "${review_calm_out#*"${RESET} ${RED}"}" = "$review_calm_out"
  assert test "${review_calm_out#*●}" = "$review_calm_out"
  assert test "${review_calm_out#*timeout}" = "$review_calm_out"
done
GATE_RC=0

# `off` is the gate having nothing to say, and the segment says nothing.
GATE_ANSWER=off
review_off_out=$(review_render review-off "$REVIEW_DIRTY")
assert review_slot_silent "$review_off_out"

# A line this build cannot read is an unknown like any other, `?err`: the
# one thing the segment may never do is stand a number over an answer nobody could parse, and a
# sentence shown whole in red was that same guess wearing a colour.
GATE_ANSWER='held because'
review_unreadable_out=$(review_render review-unreadable "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} ${DIM}?err${RESET}" <<< "$review_unreadable_out"
assert test "${review_unreadable_out#*held}" = "$review_unreadable_out"
# A protocol line short of one of its fields is unreadable too: reading the fields that are there
# and filling in the rest is exactly how a silent zero reaches the strip.
GATE_ANSWER='STATUS=open LINES=4 FILES=1 WHY=none'
review_partial_out=$(review_render review-partial "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} ${DIM}?err${RESET}" <<< "$review_partial_out"
assert test "${review_partial_out#*"${RESET} 4"}" = "$review_partial_out"

# A gate that answers nothing, and a gate that is not there at all: both silent. The segment may
# never invent a verdict where the one thing that decides it could not be reached.
GATE_ANSWER=''
GATE_RC=1
review_empty_out=$(review_render review-empty "$REVIEW_DIRTY")
assert review_slot_silent "$review_empty_out"
GATE_CMD="$FIXTURES/no-such-gate.sh"
GATE_ANSWER='STATUS=open LINES=3 FILES=1 FIX=0 WHY=none'
GATE_RC=0
review_nogate_out=$(review_render review-nogate "$REVIEW_DIRTY")
assert review_slot_silent "$review_nogate_out"
GATE_CMD="$GATE_STUB"

# Words the protocol does not name ride along without changing the answer: the fields decide, and
# a gate that grows a seventh of them must not turn this build silent.
GATE_ANSWER='STATUS=open LINES=3 FILES=1 FIX=0 WHY=none NOTE=whatever-comes-next'
review_extra_out=$(review_render review-extra "$REVIEW_DIRTY")
assert grep -Fq " ${DIM}│${RESET} 3" <<< "$review_extra_out"
assert test "${review_extra_out#*NOTE}" = "$review_extra_out"

# Truncation is the one thing done to the text, and it is display only. Nothing the protocol can
# say is long, so the cut is reachable only through an answer a previous build left in the cache —
# which is rendered as it stands, the style word included.
review_long_cache="$STATE_DIR/review-class-review-long"
printf '%s\n%s' "$TOP_REVIEW_DIRTY|0-0|0|0" 'loud 3 and a sentence nobody expected' \
  > "$review_long_cache"
review_long_out=$(run_statusline "$(statusline_payload review-long "" "$REVIEW_DIRTY")") ||
  fail "cached verdict render failed"
assert grep -Fq "${DIM}│${RESET} ${RED}3 and a sentence no…${RESET}" <<< "$review_long_out"
assert test "${review_long_out#*nobody}" = "$review_long_out"

# Asked once per key, not once per render: this runs on every prompt, and the gate's verdict mode
# reads git and review-bench. A second render with nothing moved must come off the cache.
GATE_ANSWER='STATUS=open LINES=3 FILES=1 FIX=0 WHY=none'
rm -f "$STATE_DIR/review-class-review-cache" "$STATE_DIR/review-autonomy-review-cache"
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
printf 'review-cache\t1750000000\tchange.txt\0' > "$review_gitdir/review-anchors.json"
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
assert_eq 0 "$(grep -c '^debt-total ' "$GATE_LOG" | tr -d ' ')"
# The verdict is the session's sum over every repository its .repos list names, so a journal or
# clock moving in one the block does not show re-asks it as well; the list alone moves nothing.
review_side="$FIXTURES/review-side"
mkdir -p "$review_side"
git -C "$review_side" init -q
review_side_gitdir=$(git -C "$review_side" rev-parse --absolute-git-dir)
review_repos="$HOME/.cache/claude/review-journal/review-cache.repos"
mkdir -p "${review_repos%/*}"
printf '%s\n' "$review_side" > "$review_repos"
run_statusline "$(statusline_payload review-cache "" "$REVIEW_DIRTY")" >/dev/null ||
  fail "review side-list render failed"
review_await_verdict review-cache
assert_eq 3 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
printf 'review-cache\t1750000000\tside.txt\0' > "$review_side_gitdir/review-anchors.json"
run_statusline "$(statusline_payload review-cache "" "$REVIEW_DIRTY")" >/dev/null ||
  fail "review side-journal render failed"
review_await_verdict review-cache
assert_eq 4 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
touch -t 202001010000 "$review_side_gitdir/claude-review-clock"
run_statusline "$(statusline_payload review-cache "" "$REVIEW_DIRTY")" >/dev/null ||
  fail "review side-clock render failed"
review_await_verdict review-cache
assert_eq 5 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
rm -f "$review_repos"
rm -f "$review_gitdir/review-anchors.json" "$review_clock"

# Nothing is spawned behind the label beyond that one read-only ask: a background review-bench per
# render is what the tier number used to cost, and a cache file keyed on a chat and its path set is
# that probe still running.
rm -f "$HOME/.cache/claude-statusline"/review-tier-*
review_render review-dirty "$REVIEW_DIRTY" >/dev/null
sleep 1
asserts=$((asserts + 1))
test -z "$(ls "$HOME/.cache/claude-statusline"/review-tier-* 2>/dev/null)" ||
  fail "the review segment still spawned a probe: $(ls "$HOME/.cache/claude-statusline")"

# The label sits after the repository cluster and before the pin.
GATE_ANSWER='STATUS=open LINES=3 FILES=1 FIX=0 WHY=none'
write_chat_pin review-order 'grok_profile=a'
review_order_line=$(review_render review-order "$REVIEW_DIRTY")
review_order_line="${review_order_line%%$'\n'*}"
review_before="${review_order_line%%"$review_verdict_delimited"*}"
review_after="${review_order_line#*"$review_verdict_delimited"}"
assert grep -Fq "$(basename "$REVIEW_DIRTY")" <<< "$review_before"
assert test "${review_before#*"$PIN_MARK"}" = "$review_before"
assert grep -Fq "$PIN_MARK" <<< "$review_after"

# A port belongs to the project and its diff, not to a review of it, so it takes the slot right
# after the repository cluster and the review label follows it.
printf '5173\n' > "$STATE_DIR/ports-r-order"
rorder_out=$(review_render r-order "$REVIEW_DIRTY")
assert grep -Fq ":5173" <<< "$rorder_out"
assert grep -Fq "$review_verdict_delimited" <<< "$rorder_out"
assert grep -Fq ":5173" <<< "${rorder_out%%"$review_verdict_delimited"*}"
rm -f "$STATE_DIR/ports-r-order"

# Two more answers from the same gate, about the CHAT and not the tree: `autonomous <sid>` says
# repository it touched. Both are the gate's alone — nothing here counts anything — and a gate that
# does not know the verbs leaves the segment exactly as it was.
review_seg=" ${DIM}│${RESET} "
GATE_RC=0
GATE_VERB_RC=0

# `no` is the shape everything above already renders: the bare number and no dot.
GATE_ANSWER='STATUS=open LINES=7 FILES=1 FIX=0 WHY=none'
GATE_AUTONOMOUS=no
review_auto_off_out=$(review_session_render review-auto-off "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}7" <<< "$review_auto_off_out"
assert test "${review_auto_off_out#*rev 7}" = "$review_auto_off_out"
assert test "${review_auto_off_out#*●}" = "$review_auto_off_out"

# `yes` puts a dot before the number — the chat that reviews itself is the one fact a reader
# needs before believing the number beside it.
GATE_AUTONOMOUS=yes
review_auto_on_out=$(review_session_render review-auto-on "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● 7" <<< "$review_auto_on_out"
assert test "${review_auto_on_out#*"${review_seg}rev"}" = "$review_auto_on_out"

review_auto_fit_out=$(FIT_COLUMNS=24 review_session_render review-auto-fit "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}●7" <<< "$review_auto_fit_out"
assert test "${review_auto_fit_out#*${DIM}/}" = "$review_auto_fit_out"
GATE_AUTONOMOUS=no
review_own_fit_out=$(FIT_COLUMNS=24 review_session_render review-own-fit "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}7" <<< "$review_own_fit_out"
assert test "${review_own_fit_out#*r7}" = "$review_own_fit_out"
assert test "${review_own_fit_out#*${DIM}|}" = "$review_own_fit_out"
GATE_AUTONOMOUS=
GATE_VERB_RC=1
review_stub_out=$(review_session_render review-stub-verbs "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}7" <<< "$review_stub_out"
assert test "${review_stub_out#*●}" = "$review_stub_out"
assert test "${review_stub_out#*${DIM}|}" = "$review_stub_out"
GATE_VERB_RC=0
GATE_ANSWER='STATUS=open LINES=29 FILES=1 FIX=0 WHY=none'
GATE_AUTONOMOUS=no
review_bare_out=$(review_session_render review-bare-29 "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}29" <<< "$review_bare_out"
assert test "${review_bare_out#*rev 29}" = "$review_bare_out"
GATE_AUTONOMOUS=yes
review_bare_auto_out=$(review_session_render review-bare-auto-29 "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● 29" <<< "$review_bare_auto_out"
GATE_ANSWER='STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=gap'
GATE_AUTONOMOUS=no
review_bare_unknown_out=$(review_session_render review-bare-unknown "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}?gap${RESET}" <<< "$review_bare_unknown_out"
assert test "${review_bare_unknown_out#*"rev ?"}" = "$review_bare_unknown_out"
GATE_AUTONOMOUS=
GATE_ANSWER=off

# --- the third state: a number, `off`, and `?` ------------------------------------------------
# `closed` is the gate answering "nothing is owed"; an unknown is nobody having answered — its
# library down, a member repository that failed, a `timeout` kill, an answer that outlived the 120s
# sweep. Rendered as `off`, or as no segment at all, an outage reaches Egor as a clean bill, so
# every unknown is shown as `?<why>`, the word Egor brings to that chat.
GATE_ANSWER='STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=gap'
GATE_AUTONOMOUS=no
review_unknown_out=$(review_session_render review-unknown-total "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}?gap${RESET}" <<< "$review_unknown_out"
assert test "${review_unknown_out#*rev ?}" = "$review_unknown_out"
# And a chat that commits on its own keeps its marker in front of it, as it does before a number.
GATE_AUTONOMOUS=yes
review_unknown_auto_out=$(review_session_render review-unknown-auto "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● ${DIM}?gap${RESET}" <<< "$review_unknown_auto_out"

# The mark is independent of the verdict: `off` still shows it, and a loud sentence wears it
# outside the red colouring.
GATE_ANSWER=off
GATE_AUTONOMOUS=yes
review_auto_off_alone_out=$(review_session_render review-auto-off-alone "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}●" <<< "$review_auto_off_alone_out"
assert test "${review_auto_off_alone_out#*auto}" = "$review_auto_off_alone_out"
GATE_AUTONOMOUS=no
review_auto_off_none_out=$(review_session_render review-auto-off-none "$REVIEW_DIRTY")
assert test "${review_auto_off_none_out#*●}" = "$review_auto_off_none_out"
assert test "${review_auto_off_none_out#*auto}" = "$review_auto_off_none_out"
GATE_AUTONOMOUS=yes
review_auto_off_narrow_out=$(FIT_COLUMNS=24 review_session_render review-auto-off-narrow "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}●" <<< "$review_auto_off_narrow_out"
assert test "${review_auto_off_narrow_out#*auto}" = "$review_auto_off_narrow_out"
GATE_ANSWER='held because'
GATE_AUTONOMOUS=yes
review_auto_loud_out=$(review_session_render review-auto-loud "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● ${DIM}?err${RESET}" <<< "$review_auto_loud_out"
assert test "${review_auto_loud_out#*auto}" = "$review_auto_loud_out"
GATE_AUTONOMOUS=no
review_auto_loud_none_out=$(review_session_render review-auto-loud-none "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}?err${RESET}" <<< "$review_auto_loud_none_out"
assert test "${review_auto_loud_none_out#*●}" = "$review_auto_loud_none_out"

# A gate answering `0` says nothing is owed anywhere, which is the empty slot and never a `?`.
# Proves the two states did not collapse into one the moment the third was added.
GATE_AUTONOMOUS=no
GATE_ANSWER=off
review_zero_state_out=$(review_session_render review-zero-state "$REVIEW_DIRTY")
assert review_slot_silent "$review_zero_state_out"
assert test "${review_zero_state_out#*"${review_seg}${DIM}?"}" = "$review_zero_state_out"

# A verdict cached before the 120s sweep is an answer about a tree two minutes ago, which for a
# number Egor acts on is no answer at all. Backdated with the session pair left fresh, so the `?`
# can only have come from the verdict's own staleness. Proves a stale answer is not a clean bill.
GATE_ANSWER='STATUS=open LINES=7 FILES=1 FIX=0 WHY=none'
review_stale_payload=$(statusline_payload review-stale "" "$REVIEW_DIRTY")
rm -f "$STATE_DIR/review-class-review-stale" "$STATE_DIR/review-autonomy-review-stale"
run_statusline "$review_stale_payload" >/dev/null || fail "stale verdict first render failed"
review_await_verdict review-stale
review_await_session review-stale
touch -t 202001010000 "$STATE_DIR/review-class-review-stale"
review_stale_out=$(run_statusline "$review_stale_payload") || fail "stale verdict render failed"
assert grep -Fq "${review_seg}${DIM}?${RESET}" <<< "$review_stale_out"
assert test "${review_stale_out#*"${review_seg}7"}" = "$review_stale_out"
GATE_ANSWER=off

# --- one form per answer the protocol can give -------------------------------------------------
# The gate's line is a state with a reason, and each state has exactly one shape here. Every one of
# them is a fixture through the same stub, so a state that stops rendering is a failing assert and
# never a quietly empty slot.
GATE_AUTONOMOUS=no

# Owed lines are what Egor acts on and outrank everything else the line carries.
GATE_ANSWER='STATUS=open LINES=29 FILES=2 FIX=3 WHY=none'
form_lines_out=$(review_session_render review-form-lines "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}29" <<< "$form_lines_out"
assert test "${form_lines_out#*fix}" = "$form_lines_out"
GATE_AUTONOMOUS=yes
form_lines_auto_out=$(review_session_render review-form-lines-auto "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● 29" <<< "$form_lines_auto_out"
GATE_AUTONOMOUS=no

# Nothing owed in lines with findings still open is work to do rather than debt to settle: it is
# already inside the tree it would be fixed in, so it is shown dim and with its own word.
GATE_ANSWER='STATUS=open LINES=0 FILES=0 FIX=3 WHY=none'
form_fix_out=$(review_session_render review-form-fix "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}fix 3${RESET}" <<< "$form_fix_out"

# Open with nothing to show for it is the silent zero this protocol exists to make visible.
GATE_ANSWER='STATUS=open LINES=0 FILES=0 FIX=0 WHY=none'
form_open_empty_out=$(review_session_render review-form-open-empty "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}?err${RESET}" <<< "$form_open_empty_out"

# Settled: the slot is empty, and the autonomy mark stands in it alone, being a chat fact.
GATE_ANSWER='STATUS=closed LINES=0 FILES=0 FIX=0 WHY=none'
form_closed_out=$(review_session_render review-form-closed "$REVIEW_DIRTY")
assert review_slot_silent "$form_closed_out"
GATE_AUTONOMOUS=yes
form_closed_auto_out=$(review_session_render review-form-closed-auto "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}●" <<< "$form_closed_auto_out"
GATE_AUTONOMOUS=no

# The ledger is behind: the number is a BOUND on what may be owed, and `~` is the whole difference
# between it and a count — a bound rendered bare would be a number Egor acts on; the `?` in front
# says the store is broken.
GATE_ANSWER='STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=ledger BOUND=120'
form_bound_out=$(review_session_render review-form-bound "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}~120 ${DIM}?ledger${RESET}" <<< "$form_bound_out"
GATE_AUTONOMOUS=yes
form_bound_auto_out=$(review_session_render review-form-bound-auto "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● ~120 ${DIM}?ledger${RESET}" <<< "$form_bound_auto_out"
GATE_AUTONOMOUS=no
# A ledger unknown with no bound is `?ledger` alone.
GATE_ANSWER='STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=ledger'
form_bound_missing_out=$(review_session_render review-form-bound-missing "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}?ledger${RESET}" <<< "$form_bound_missing_out"

# Every other unknown carries its reason word, which Egor brings to the chat.
for form_why in gap run err nobase; do
  GATE_ANSWER="STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=$form_why"
  form_why_out=$(review_session_render "review-form-why-$form_why" "$REVIEW_DIRTY")
  assert grep -Fq "${review_seg}${DIM}?${form_why}${RESET}" <<< "$form_why_out"
done
# An unknown is a number with a flag, never a replacement of it.
GATE_ANSWER='STATUS=unknown LINES=29 FILES=2 FIX=3 WHY=gap'
form_lines_flag_out=$(review_session_render review-form-lines-flag "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}29 ${DIM}?gap${RESET}" <<< "$form_lines_flag_out"
GATE_AUTONOMOUS=yes
form_lines_flag_auto_out=$(review_session_render review-form-lines-flag-auto "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}● 29 ${DIM}?gap${RESET}" <<< "$form_lines_flag_auto_out"
GATE_AUTONOMOUS=no
GATE_ANSWER='STATUS=unknown LINES=0 FILES=0 FIX=3 WHY=gap'
form_fix_flag_out=$(review_session_render review-form-fix-flag "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}fix 3 ?gap${RESET}" <<< "$form_fix_flag_out"
GATE_ANSWER='STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=run'
form_run_alone_out=$(review_session_render review-form-run-alone "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}${DIM}?run${RESET}" <<< "$form_run_alone_out"
GATE_ANSWER=off

# --- the FOLDER's debt beside the folder's diff ------------------------------------------------
# A second number about the same tree and a different question: what the whole repository owes,
# whoever wrote it. It follows the folder, never the chat, and renders nothing it cannot read.
DEBT_STUB="$FIXTURES/repo-debt-stub.sh"
cat > "$DEBT_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$DEBT_LOG"
[ -n "${DEBT_SLEEP:-}" ] && sleep "$DEBT_SLEEP"
printf '%s\n' "$DEBT_ANSWER"
STUB
chmod +x "$DEBT_STUB"
DEBT_LOG="$WORK/repo-debt.log"
export DEBT_LOG DEBT_ANSWER DEBT_SLEEP
DEBT_ANSWER='LINES=0 FILES=0'
DEBT_SLEEP=
REVIEW_OTHER="$FIXTURES/review-other-folder"
mkdir -p "$REVIEW_OTHER"
git -C "$REVIEW_OTHER" init -q -b main
printf 'other\n' > "$REVIEW_OTHER/tracked.txt"
git -C "$REVIEW_OTHER" add tracked.txt
git -C "$REVIEW_OTHER" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
TOP_REVIEW_OTHER=$(cd "$REVIEW_OTHER" && pwd -P)
# Both renders of a case go through the same background-then-read shape the verdict uses.
debt_render() { # session repo
  local payload cache i
  cache="$STATE_DIR/repo-debt-$(printf '%s' "$2" | cksum | tr ' ' -)"
  rm -f "$STATE_DIR/repo-debt-"* 2>/dev/null
  rmdir "$STATE_DIR/repo-debt-"*.lock 2>/dev/null
  rm -f "$STATE_DIR/review-class-$1"
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "repo debt render failed: $1"
  for i in $(seq 1 100); do
    compgen -G "$STATE_DIR/repo-debt-*" >/dev/null 2>&1 &&
      ! compgen -G "$STATE_DIR/repo-debt-*.lock" >/dev/null 2>&1 && break
    sleep 0.05
  done
  run_statusline "$payload" || fail "repo debt render failed: $1"
}
DEBT_CMD="$DEBT_STUB"
: > "$DEBT_LOG"
DEBT_ANSWER='LINES=153 FILES=16'
debt_mark_out=$(debt_render repo-debt-shown "$REVIEW_DIRTY")
assert grep -Fq "${DIM}∑153${RESET}" <<< "$debt_mark_out"
assert grep -Fqx -e "--repo $TOP_REVIEW_DIRTY" "$DEBT_LOG"
# It follows the FOLDER: a render of another tree asks about that tree and shows its number.
DEBT_ANSWER='LINES=4 FILES=2'
debt_other_out=$(debt_render repo-debt-shown "$REVIEW_OTHER")
assert grep -Fq "${DIM}∑4${RESET}" <<< "$debt_other_out"
assert test "${debt_other_out#*∑153}" = "$debt_other_out"
assert grep -Fqx -e "--repo $TOP_REVIEW_OTHER" "$DEBT_LOG"
# The folder debt outlives every name abbreviation: it is still there while the model, the account
# and the directory are already being cut (steps 5-7), and only step 8 takes it off the line.
DEBT_ANSWER='LINES=153 FILES=16'
debt_render repo-debt-narrow "$REVIEW_DIRTY" >/dev/null
debt_narrow_out=$(FIT_COLUMNS=24 run_statusline "$(statusline_payload repo-debt-narrow "" "$REVIEW_DIRTY")")
assert test "${debt_narrow_out#*153}" = "$debt_narrow_out"
debt_fit() { FIT_COLUMNS="$1" run_statusline "$(statusline_payload repo-debt-narrow "" "$REVIEW_DIRTY")"; }
# Step 1 takes the mark off with the diff signs: the debt is then the only dim number on the strip.
debt_short_out=$(debt_fit 48)
assert grep -Fq "${GREEN}21${RESET}/${RED}0${RESET}" <<< "$debt_short_out"
assert grep -Fq "${DIM}153${RESET}" <<< "$debt_short_out"
assert test "${debt_short_out#*∑}" = "$debt_short_out"
debt_model_out=$(debt_fit 39)
assert grep -Fq 'FX hi' <<< "$debt_model_out"
assert grep -Fq "${DIM}153${RESET}" <<< "$debt_model_out"
debt_initials_out=$(debt_fit 32)
assert grep -Fq 'rd' <<< "$debt_initials_out"
assert test "${debt_initials_out#*review-d}" = "$debt_initials_out"
assert grep -Fq "${DIM}153${RESET}" <<< "$debt_initials_out"
debt_step8_out=$(debt_fit 26)
assert grep -Fq 'rd' <<< "$debt_step8_out"
assert test "${debt_step8_out#*153}" = "$debt_step8_out"
# Nothing owed is nothing rendered, and so is every answer this build cannot read.
for debt_quiet in 'LINES=0 FILES=0' 'LINES=0 FILES=0 WHY=err' 'LINES=153 FILES=16 WHY=err' 'off' '' \
    'LINES=x FILES=1'; do
  DEBT_ANSWER="$debt_quiet"
  debt_quiet_out=$(debt_render repo-debt-quiet "$REVIEW_DIRTY")
  assert test "${debt_quiet_out#*∑}" = "$debt_quiet_out"
done
# A binary that is gone, and one too slow to answer, are both silence in the line — never an error
# in it and never a number left over from the tree before.
DEBT_ANSWER='LINES=9 FILES=1'
DEBT_CMD="$FIXTURES/no-such-review-debt"
debt_gone_out=$(debt_render repo-debt-gone "$REVIEW_DIRTY")
assert test "${debt_gone_out#*∑}" = "$debt_gone_out"
DEBT_CMD="$DEBT_STUB"
DEBT_SLEEP=0.4
debt_slow_out=$(run_statusline "$(statusline_payload repo-debt-slow "" "$REVIEW_DIRTY")")
assert test "${debt_slow_out#*∑}" = "$debt_slow_out"
DEBT_SLEEP=
# A machine with neither `timeout` nor `gtimeout` bounds the walk itself: the render is as silent as
# with one, and the probe still frees its lock, so the next render is never blocked by a dead one.
DEBT_CMD="$DEBT_STUB"
DEBT_ANSWER='LINES=21 FILES=5'
DEBT_SLEEP=0.4
debt_cache="$STATE_DIR/repo-debt-$(printf '%s' "$TOP_REVIEW_DIRTY" | cksum | tr ' ' -)"
debt_lock="$debt_cache.lock"
rm -f "$STATE_DIR/repo-debt-"* 2>/dev/null
rmdir "$STATE_DIR/repo-debt-"*.lock 2>/dev/null
debt_nt_out=$(NO_TIMEOUT_BIN=1 run_statusline \
  "$(statusline_payload repo-debt-no-timeout "" "$REVIEW_DIRTY")")
assert test "${debt_nt_out#*∑}" = "$debt_nt_out"
for debt_wait in $(seq 1 100); do
  [ -d "$debt_lock" ] || break
  sleep 0.05
done
assert test ! -d "$debt_lock"
assert grep -Fq "∑21" <<< "$(NO_TIMEOUT_BIN=1 run_statusline \
  "$(statusline_payload repo-debt-no-timeout "" "$REVIEW_DIRTY")")"
# The lock a probe removes is the one it made. A walk still running when its lock is swept as dead
# leaves the sweeper's own lock standing, or two full walks run over the same tree at once.
rm -f "$STATE_DIR/repo-debt-"* 2>/dev/null
DEBT_SLEEP=0.8
NO_TIMEOUT_BIN=1 run_statusline \
  "$(statusline_payload repo-debt-lock-owner "" "$REVIEW_DIRTY")" >/dev/null
for debt_wait in $(seq 1 100); do
  [ -d "$debt_lock" ] && break
  sleep 0.05
done
assert test -d "$debt_lock"
rmdir "$debt_lock" && mkdir "$debt_lock"
for debt_wait in $(seq 1 100); do
  [ -s "$debt_cache" ] && break
  sleep 0.05
done
sleep 0.2
assert test -d "$debt_lock"
rmdir "$debt_lock" 2>/dev/null
DEBT_SLEEP=
DEBT_ANSWER='LINES=0 FILES=0'
DEBT_CMD=
rm -f "$STATE_DIR/repo-debt-"* 2>/dev/null

# --- the real gate, so the two answers cannot drift apart -----------------------------------
# The stub above proves the rendering; this proves the wiring against the hook that actually
# answers for a commit. An unreadable neighbour is a FAIL naming CLAUDE_SETUP_ROOT, never a skip:
# a silent green here is the drift this block exists to catch.
REAL_GATE="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/review-flow-gate.sh"
if [ -x "$REAL_GATE" ]; then
  GATE_CMD="$REAL_GATE"
  GATE_BIN="$FIXTURES/gate-bin"
  mkdir -p "$GATE_BIN"
  # The gate prices nothing itself: it relays `review-debt <session>`'s one line, so this is the
  # whole of what it has to say and the render's parser is the only thing under test here.
  cat > "$GATE_BIN/review-debt" <<'RD'
#!/bin/bash
printf '%s\n' "${SESSION_REVIEW_ANSWER:-STATUS=closed LINES=0 FILES=0 FIX=0 WHY=none}"
exit "${SESSION_REVIEW_RC:-0}"
RD
  chmod +x "$GATE_BIN/review-debt"
  # The journal is written because the render's cache key watches it, not because the gate reads
  # it: a second case under the same session would otherwise be served the first one's answer.
  review_real_render() ( # session debt-line [rc]
    export SESSION_REVIEW_ANSWER="$2" SESSION_REVIEW_RC="${3:-0}" PATH="$GATE_BIN:$PATH"
    printf '%s\t1750000000\tchange.txt\0' "$1" > "$review_gitdir/review-anchors.json"
    review_render "$1" "$REVIEW_DIRTY"
  )
  real_objects_before=$(find "$REVIEW_DIRTY/.git/objects" -type f | wc -l | tr -d ' ')
  review_real_closed_out=$(review_real_render review-real \
    'STATUS=closed LINES=0 FILES=0 FIX=0 WHY=none')
  assert review_slot_silent "$review_real_closed_out"
  review_real_mine_out=$(review_real_render review-real-mine \
    'STATUS=open LINES=1 FILES=1 FIX=0 WHY=none')
  assert grep -Fq " ${DIM}│${RESET} 1" <<< "$review_real_mine_out"
  # Each state survives the whole chain, relay included: the gate rewrites none of it and the
  # render reads it in one place.
  review_real_fix_out=$(review_real_render review-real-fix \
    'STATUS=open LINES=0 FILES=0 FIX=3 WHY=none')
  assert grep -Fq " ${DIM}│${RESET} ${DIM}fix 3${RESET}" <<< "$review_real_fix_out"
  review_real_bound_out=$(review_real_render review-real-bound \
    'STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=ledger BOUND=90')
  assert grep -Fq " ${DIM}│${RESET} ~90 ${DIM}?ledger${RESET}" <<< "$review_real_bound_out"
  review_real_gap_out=$(review_real_render review-real-gap \
    'STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=gap')
  assert grep -Fq " ${DIM}│${RESET} ${DIM}?gap${RESET}" <<< "$review_real_gap_out"
  # A reader that fails is the gate's own unknown, and it reaches the strip as one: the outage the
  # render may never show as a clean bill.
  review_real_err_out=$(review_real_render review-real-err \
    'STATUS=open LINES=9 FILES=1 FIX=0 WHY=none' 1)
  assert grep -Fq " ${DIM}│${RESET} ${DIM}?err${RESET}" <<< "$review_real_err_out"
  assert test "${review_real_err_out#*"${RESET} 9"}" = "$review_real_err_out"
  # Nothing is in debt, so the gate has nothing to say about it.
  rm -f "$review_gitdir/review-anchors.json"
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
write_chat_pin unpushed-ahead 'grok_profile=a'
write_chat_pin unpushed-fit 'grok_profile=a'
unpushed_ahead_out=$(PATH="$UNPUSHED_TIMEOUT_BIN:$PATH" \
  unpushed_render unpushed-ahead "$AHEAD_REPO")
assert grep -Fq "$UNPUSHED_MARK" <<< "$unpushed_ahead_out"
assert_eq "unpushed $AHEAD_TOP unpushed-ahead" "$(grep -m1 '^unpushed ' "$GATE_LOG")"
assert_eq "10 $UNPUSHED_STUB unpushed $AHEAD_TOP unpushed-ahead" \
  "$(grep -m1 -F "$UNPUSHED_STUB unpushed " "$UNPUSHED_TIMEOUT_LOG")"
# Never dimmed: the commit is this chat's own to act on.
assert test "${unpushed_ahead_out#*"${DIM}unpushed"}" = "$unpushed_ahead_out"
# After the verdict and before the pin, where the rest of the repository cluster ends.
unpushed_order_line="${unpushed_ahead_out%%$'\n'*}"
assert grep -Fq "$PIN_MARK" <<< "${unpushed_order_line#*"$UNPUSHED_MARK"}"
assert test "${unpushed_order_line%%"$UNPUSHED_MARK"*}" != "$unpushed_order_line"
# Fit step 9: the marker shortens to a red `↑!` rather than leaving the line, whatever the width.
: > "$GATE_LOG"
unpushed_fit_out=$(FIT_COLUMNS=20 PATH="$UNPUSHED_TIMEOUT_BIN:$PATH" \
  unpushed_render unpushed-fit "$AHEAD_REPO")
assert grep -Fq "${RED}↑!${RESET}" <<< "$unpushed_fit_out"

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
printf 'unpushed-cache\t1750000000\tchange.txt\0' > "$ahead_gitdir/review-anchors.json"
run_statusline "$(statusline_payload unpushed-cache "" "$AHEAD_REPO")" >/dev/null ||
  fail "unpushed cache third render failed"
unpushed_await unpushed-cache 2
assert_eq 2 "$(unpushed_calls)"
rm -f "$ahead_gitdir/review-anchors.json"

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
assert review_slot_silent "$review_nongit_out"

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
assert grep -Fq " ${DIM}│${RESET} T2 3/8" <<< "$progress_live_out"
assert test "${progress_live_out#*"T2 max"}" = "$progress_live_out"

# Fit step 6 has nothing to take from the counter: it carries no word any more, and its tier and
# numbers are the whole of what it says.
progress_fit_out=$(FIT_COLUMNS=24 progress_render fit)
assert grep -Fq 'T2 3/8' <<< "$progress_fit_out"
assert test "${progress_fit_out#*rT2}" = "$progress_fit_out"

write_progress "$$" T2 0 1 2026-07-27T22:00:00+00:00
jq --argjson started_epoch "$(progress_started 121)" \
  '. + {started_epoch:$started_epoch,expected:{"cell-0":1000}}' \
  "$PROGRESS_DIR/$progress_prefix$$.json" \
  > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_late_out=$(progress_render late)
assert grep -Fq " ${DIM}│${RESET} ${RED}T2 0/1${RESET}" <<< "$progress_late_out"

jq --argjson started_epoch "$(progress_started)" '.started_epoch = $started_epoch' \
  "$PROGRESS_DIR/$progress_prefix$$.json" \
  > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_fresh_out=$(progress_render fresh)
assert grep -Fq " ${DIM}│${RESET} T2 0/1" <<< "$progress_fresh_out"
assert test "${progress_fresh_out#*"${RED}T2"}" = "$progress_fresh_out"

jq --argjson started_epoch "$(progress_started 121)" \
  '.started_epoch = $started_epoch | .done = ["cell-0"]' \
  "$PROGRESS_DIR/$progress_prefix$$.json" \
  > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_done_late_out=$(progress_render done-late)
assert grep -Fq " ${DIM}│${RESET} T2 1/1" <<< "$progress_done_late_out"
assert test "${progress_done_late_out#*"${RED}T2"}" = "$progress_done_late_out"

write_progress "$$" T2 0 1 2026-07-27T22:00:00+00:00
jq --argjson started_epoch "$(progress_started 121)" '.started_epoch = $started_epoch' \
  "$PROGRESS_DIR/$progress_prefix$$.json" \
  > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_no_expected_out=$(progress_render no-expected)
assert grep -Fq " ${DIM}│${RESET} T2 0/1" <<< "$progress_no_expected_out"
assert test "${progress_no_expected_out#*"${RED}T2"}" = "$progress_no_expected_out"

write_progress "$$" T2 0 1 2026-07-27T22:00:00+00:00
progress_legacy_out=$(progress_render legacy)
assert grep -Fq " ${DIM}│${RESET} T2 0/1" <<< "$progress_legacy_out"
assert test "${progress_legacy_out#*"${RED}T2"}" = "$progress_legacy_out"

# The max panel is a variant of the same tier at the same time budget, so a T2 max run must not
# read as the T2 it is not: it buys a wider panel, and the label is where that is visible.
write_progress "$$" T2 5 16 2026-07-27T22:00:00+00:00 "" true
progress_max_out=$(progress_render max)
assert grep -Fq " ${DIM}│${RESET} T2 max 5/16" <<< "$progress_max_out"

# --max is refused without --tier, so a file claiming the variant without the tier is corrupt in
# that field; the counter still renders and no bare variant name takes the tier's place.
write_progress "$$" "" 2 4 2026-07-27T22:00:00+00:00 "" true
progress_max_untiered_out=$(progress_render max-untiered)
assert grep -Fq " ${DIM}│${RESET} 2/4" <<< "$progress_max_untiered_out"
assert test "${progress_max_untiered_out#*max}" = "$progress_max_untiered_out"

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
assert grep -Fq " ${DIM}│${RESET} T3 1/3" <<< "$progress_alias_out"
rm -f "$progress_alias"

# An --auto run carries no tier; the counter still renders.
write_progress "$$" "" 1 5 2026-07-27T22:00:00+00:00
progress_untiered_out=$(progress_render untiered)
assert grep -Fq " ${DIM}│${RESET} 1/5" <<< "$progress_untiered_out"
assert test "${progress_untiered_out#*"${RESET} T"}" = "$progress_untiered_out"

progress_second_pid=$( (sleep 30 >/dev/null 2>&1 & echo $!) )
write_progress "$$" T1 2 6 2026-07-27T22:00:00+00:00
write_progress "$progress_second_pid" T3 5 9 2026-07-27T23:30:00+00:00
progress_two_out=$(progress_render two-runs)
assert grep -Fq " ${DIM}│${RESET} T3 5/9" <<< "$progress_two_out"
assert test "${progress_two_out#*T1}" = "$progress_two_out"
assert_eq 1 "$(grep -o 'T3 5/9' <<< "$progress_two_out" | wc -l | tr -d ' ')"
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

progress_home_dir="${BLUE}$(basename "$REVIEW_CLEAN")${RESET}"
progress_away_dirs="${DIM}$(basename "$REVIEW_CLEAN")${RESET} ${MAGENTA}»${RESET} ${BLUE}$(basename "$REVIEW_DIRTY")${RESET}"

write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00 "$REVIEW_DIRTY"
progress_foreign_out=$(progress_render foreign-repo)
assert test "${progress_foreign_out#*4/7}" = "$progress_foreign_out"
assert grep -Fq "$progress_home_dir" <<< "$progress_foreign_out"

progress_set_session() { # session
  jq --arg session "$1" '.session = $session' \
    "$PROGRESS_DIR/$progress_prefix$$.json" > "$PROGRESS_DIR/$progress_prefix$$.json.tmp"
  mv "$PROGRESS_DIR/$progress_prefix$$.json.tmp" "$PROGRESS_DIR/$progress_prefix$$.json"
}
# This chat's own run elsewhere moves nothing by itself: only the journal line review-bench writes
# at its start does, and then the whole block is that tree's.
progress_set_session review-progress-foreign-mine
progress_foreign_unjournaled_out=$(progress_render foreign-mine)
assert test "${progress_foreign_unjournaled_out#*4/7}" = "$progress_foreign_unjournaled_out"
assert grep -Fq "$progress_home_dir" <<< "$progress_foreign_unjournaled_out"
place_set review-progress-foreign-mine "$TOP_REVIEW_DIRTY" "$TOP_REVIEW_DIRTY" review-start
progress_foreign_mine_out=$(progress_render foreign-mine)
assert grep -Fq "$progress_away_dirs" <<< "$progress_foreign_mine_out"
assert grep -Fq " ${DIM}│${RESET} T2 4/7" <<< "$progress_foreign_mine_out"
assert grep -Fq "${BLUE}⎇ main${RESET} ${GREEN}+21${RESET}/${RED}-0${RESET}" \
  <<< "$progress_foreign_mine_out"

progress_set_session review-progress-another-chat
progress_foreign_other_out=$(progress_render foreign-other)
assert test "${progress_foreign_other_out#*4/7}" = "$progress_foreign_other_out"
assert grep -Fq "$progress_home_dir" <<< "$progress_foreign_other_out"

# Another chat's run over this very tree is not this chat's news: it is not shown, not dimmed and
# not counted (Egor, 2026-09-16). The folder is untouched by it either way.
write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00
progress_set_session review-progress-another-chat
progress_own_tree_other_out=$(progress_render own-tree-other)
assert review_slot_silent "$progress_own_tree_other_out"
assert grep -Fq "$progress_home_dir" <<< "$progress_own_tree_other_out"

# Identity is the working tree, not `--git-common-dir`, which every worktree of a project shares.
PROGRESS_WT="$FIXTURES/review-clean-wt"
git -C "$REVIEW_CLEAN" worktree add -q "$PROGRESS_WT" -b progress-sibling
TOP_PROGRESS_WT=$(cd "$PROGRESS_WT" && pwd -P)
write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00 "$PROGRESS_WT"
progress_sibling_out=$(progress_render sibling-worktree)
assert test "${progress_sibling_out#*4/7}" = "$progress_sibling_out"
assert test "${progress_sibling_out#*⧉}" = "$progress_sibling_out"

progress_set_session review-progress-sibling-mine
place_set review-progress-sibling-mine "$TOP_PROGRESS_WT" "$review_clean_root" review-start
progress_sibling_mine_out=$(progress_render sibling-mine)
assert grep -Fq "$progress_home_dir ${RED}⧉ $(basename "$PROGRESS_WT")${RESET}" \
  <<< "$progress_sibling_mine_out"
assert grep -Fq " ${DIM}│${RESET} T2 4/7" <<< "$progress_sibling_mine_out"
assert test "${progress_sibling_mine_out#*»}" = "$progress_sibling_mine_out"

mkdir -p "$REVIEW_CLEAN/nested/deeper"
write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00 "$REVIEW_CLEAN/nested/deeper"
progress_subdir_out=$(progress_render subdirectory)
assert grep -Fq " ${DIM}│${RESET} T2 4/7" <<< "$progress_subdir_out"

write_progress "$$" T2 9 7 2026-07-27T22:00:00+00:00
progress_overrun_out=$(progress_render overrun)
assert test "${progress_overrun_out#*9/7}" = "$progress_overrun_out"

printf 'not json\n' > "$PROGRESS_DIR/$progress_prefix$$.json"
progress_corrupt_out=$(progress_render corrupt)
assert review_slot_silent "$progress_corrupt_out"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"

progress_gone_out=$(progress_render gone)
assert_eq 0 \
  "$(grep -Eco '(T[0-3] )?[0-9]+/[0-9]+' <<< "${progress_gone_out%%$'\n'*}" | tr -d ' ')"
assert review_slot_silent "$progress_gone_out"

# The debt never disappears behind a review: counter and verdict stand side by side over one tree.
GATE_ANSWER='STATUS=open LINES=54 FILES=1 FIX=0 WHY=none'
progress_alone_out=$(review_render review-progress-alone "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} 54" <<< "$progress_alone_out"
assert test "${progress_alone_out#*"${RESET} T"}" = "$progress_alone_out"
write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00
progress_own_debt_out=$(review_render review-progress-own-debt "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} T0 3/9 ${DIM}│${RESET} 54" \
  <<< "$progress_own_debt_out"
assert test "${progress_own_debt_out#*"rev "}" = "$progress_own_debt_out"
# The verdict stands alone where the only run of this tree is another chat's: this chat's debt is
# still this chat's, and the run beside it was never its to read.
progress_set_session review-progress-elsewhere
progress_other_debt_out=$(review_render review-progress-other-debt "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} 54" <<< "$progress_other_debt_out"
assert test "${progress_other_debt_out#*3/9}" = "$progress_other_debt_out"
# The gate is asked about the shown tree and no other.
: > "$GATE_LOG"
GATE_ANSWER='STATUS=open LINES=54 FILES=1 FIX=0 WHY=none'
write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00 "$REVIEW_DIRTY"
progress_set_session review-progress-foreign-named
place_set review-progress-foreign-named "$TOP_REVIEW_DIRTY" "$TOP_REVIEW_DIRTY" review-start
progress_foreign_named_out=$(review_render review-progress-foreign-named "$REVIEW_CLEAN")
assert grep -Fq \
  " ${DIM}│${RESET} T0 3/9 ${DIM}│${RESET} 54" \
  <<< "$progress_foreign_named_out"
assert grep -Fq "$progress_away_dirs" <<< "$progress_foreign_named_out"
assert_eq "verdict $TOP_REVIEW_DIRTY review-progress-foreign-named" \
  "$(grep -F verdict "$GATE_LOG" | tail -1)"
assert_eq 0 "$(grep -Fc -- "verdict $review_clean_root " "$GATE_LOG" | tr -d ' ')"

write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00 "$PROGRESS_WT"
progress_set_session review-progress-foreign-wt
place_set review-progress-foreign-wt "$TOP_PROGRESS_WT" "$review_clean_root" review-start
progress_foreign_wt_out=$(review_render review-progress-foreign-wt "$REPO_A")
assert grep -Fq \
  "${DIM}$(basename "$REPO_A")${RESET} ${MAGENTA}»${RESET} ${BLUE}$(basename "$REVIEW_CLEAN")${RESET} ${RED}⧉ $(basename "$PROGRESS_WT")${RESET}" \
  <<< "$progress_foreign_wt_out"
assert grep -Fq " ${DIM}│${RESET} T0 3/9 " <<< "$progress_foreign_wt_out"

# A run whose recorded repository no longer resolves has no tree to render at all, and the block is
# one tree's rendering: the run is dropped whole rather than moving the block to a path or leaving
# a count beside the session's own folder. Rendered from INSIDE the session's checkout, the way the
# harness launches the statusline, since asking git about an empty path answers for the process's
# own directory.
write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00 /nonexistent/repo-vanished
progress_set_session review-progress-repo-vanished
progress_vanished_out=$(cd "$REPO_A" && review_render review-progress-repo-vanished "$REPO_A")
assert test "${progress_vanished_out#*3/9}" = "$progress_vanished_out"
assert grep -Fq "${BLUE}$(basename "$REPO_A")${RESET}" <<< "$progress_vanished_out"
assert grep -Fq " ${DIM}│${RESET} 54" <<< "$progress_vanished_out"

write_progress "$$" T0 3 9 2026-07-27T22:00:00+00:00

# An answer this build cannot read stands beside a counter it can, and neither borrows anything
# from the other: two slots, two states.
GATE_ANSWER='held for review'
progress_unreadable_debt_out=$(review_render review-progress-unreadable-debt "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} T0 3/9 ${DIM}│${RESET} ${DIM}?err${RESET}" <<< "$progress_unreadable_debt_out"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"
GATE_ANSWER=off

# --- review progress: declared state, heartbeat, and other chats' runs -------------------------
# review-bench no longer unlinks the document when a run ends: it stays until the chat consumes the
# result, so outliving its process is the normal case now and not the kill -9 leftover it used to
# mean. What the run looks like on the line is its DECLARED state crossed with what this render can
# still verify — the pid, and the heartbeat that is the only thing separating a slow cell from a
# wedge. A document with neither is one an older review-bench wrote and keeps the rule it shipped
# with, unchanged.
progress_doc() { # name pid tier done total state heartbeat-age [repo] [session] [started] [failed]
  jq -cn --arg repo "${8:-$REVIEW_CLEAN}" --argjson pid "$2" --arg tier "$3" \
    --argjson done_cells "$4" --argjson total "$5" --arg state "$6" \
    --argjson heartbeat "$(progress_started "$7")" --arg session "${9:-}" \
    --arg started "${10:-2026-07-27T22:00:00+00:00}" --argjson failed "${11:-0}" '
    {repo:$repo, pid:$pid, run_id:"progress-state-fixture",
     tier:(if $tier == "" then null else $tier end), max:false, target:"abc1234",
     cells:[range($total) | "cell-\(.)"], done:[range($done_cells) | "cell-\(.)"],
     failed:$failed, started:$started, ts:$started, state:$state, heartbeat_epoch:$heartbeat}
    + (if $session == "" then {} else {session:$session} end)
    + (if $state == "done" or $state == "dead" then {finished_epoch:$heartbeat} else {} end)' \
    > "$PROGRESS_DIR/${progress_prefix}state-$1.json"
}
progress_doc_clear() { rm -f "$PROGRESS_DIR/${progress_prefix}state-"*.json; }
progress_stale_stamp=$(date -v-3H +%Y%m%d%H%M.%S 2>/dev/null ||
  date -d '3 hours ago' +%Y%m%d%H%M.%S)

progress_doc running-fresh "$$" T2 3 8 running 0
progress_state_live_out=$(progress_render state-running-fresh)
assert grep -Fq " ${DIM}│${RESET} T2 3/8" <<< "$progress_state_live_out"
assert test "${progress_state_live_out#*"${DIM}T2"}" = "$progress_state_live_out"
assert test "${progress_state_live_out#*"${RED}T2"}" = "$progress_state_live_out"
progress_doc_clear

# A pid that still holds and a run that has not spoken for two minutes: the counter is the last
# thing the run said, and the mark says nobody should read it as news.
progress_doc running-wedged "$$" T2 3 8 running 300
progress_state_wedged_out=$(progress_render state-running-wedged)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 3/8${RESET}" <<< "$progress_state_wedged_out"
# The wedge wears no mark of its own (Egor, 2026-09-16): dim is the whole of what is left to say
# about a run that stopped speaking, and the `?` beside a counter read as a number nobody knew.
assert test "${progress_state_wedged_out#*"3/8?"}" = "$progress_state_wedged_out"
progress_doc_clear

progress_doc running-killed 99999999 T2 3 8 running 0 "" review-progress-state-running-killed
progress_state_killed_out=$(progress_render state-running-killed)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 ✗ 3/8${RESET}" <<< "$progress_state_killed_out"
progress_doc_clear

# `dead` is the reaper's own word about a run whose pid is gone, and it outranks a live pid: the
# document names the run, and a pid handed to something else says nothing about it.
progress_doc dead "$$" T2 3 8 dead 0 "" review-progress-state-dead
progress_state_dead_out=$(progress_render state-dead)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 ✗ 3/8${RESET}" <<< "$progress_state_dead_out"
progress_doc_clear
progress_state_consumed_out=$(progress_render state-dead)
assert review_slot_silent "$progress_state_consumed_out"

progress_doc dead-unowned "$$" T2 3 8 dead 0
progress_state_unowned_out=$(progress_render state-dead-unowned)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 ✗ 3/8${RESET}" <<< "$progress_state_unowned_out"
progress_doc_clear

progress_doc done "$$" T2 8 8 done 0
progress_state_done_out=$(progress_render state-done)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 ✓ 8/8${RESET}" <<< "$progress_state_done_out"
# The 2h wall is the compatibility path's wedge guard and nothing else: a finished run writes
# nothing more, and the result it is holding is unconsumed however old the file is.
touch -t "$progress_stale_stamp" "$PROGRESS_DIR/${progress_prefix}state-done.json"
progress_state_done_old_out=$(progress_render state-done-old)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 ✓ 8/8${RESET}" <<< "$progress_state_done_old_out"
progress_doc_clear

progress_doc done-failed-cells 99999999 T0 5 9 done 0 "" "" "" 2
progress_state_done_failed_out=$(progress_render state-done-failed-cells)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T0 ✓ 5/9${RESET}" <<< "$progress_state_done_failed_out"
progress_doc_clear

progress_doc legacy-failed 99999999 T2 3 8 failed 0 "" review-progress-state-legacy-failed
progress_state_legacy_failed_out=$(progress_render state-legacy-failed)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 ✗ 3/8${RESET}" <<< "$progress_state_legacy_failed_out"
progress_doc_clear

# The compatibility path, unchanged: a live pid renders bright, and the 2h wall still takes the
# segment away, since a document with no heartbeat has nothing else to tell a wedge from a run.
write_progress "$$" T2 2 6 2026-07-27T22:00:00+00:00
progress_legacy_alive_out=$(progress_render state-legacy-alive)
assert grep -Fq " ${DIM}│${RESET} T2 2/6" <<< "$progress_legacy_alive_out"
touch -t "$progress_stale_stamp" "$PROGRESS_DIR/$progress_prefix$$.json"
progress_legacy_stale_out=$(progress_render state-legacy-stale)
assert review_slot_silent "$progress_legacy_stale_out"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"

# Other chats' unconsumed runs are not this block's news at all (Egor, 2026-09-16): neither in
# the slot nor as a count beside it, wherever in this repository they are running.
progress_doc foreign-sibling "$$" T2 1 4 running 0 "$PROGRESS_WT" review-progress-another-chat
progress_state_foreign_out=$(progress_render state-foreign-alone)
assert review_slot_silent "$progress_state_foreign_out"

# This chat's own run takes the segment, and a stranger's beside it adds nothing to the line.
progress_doc own-home "$$" T2 3 8 running 0 "" "" 2026-07-27T23:00:00+00:00
progress_state_own_foreign_out=$(progress_render state-own-plus-foreign)
assert grep -Fq " ${DIM}│${RESET} T2 3/8" <<< "$progress_state_own_foreign_out"
assert test "${progress_state_own_foreign_out#*+1}" = "$progress_state_own_foreign_out"
# And it keeps the segment against a stranger's NEWER document over the same tree: a finished
# foreign run now survives for a day, so the newest-started rule alone handed the one slot to news
# that is already over and rendered this chat's live run nowhere at all.
progress_doc foreign-newer "$$" T2 4 4 done 0 "" review-progress-another-chat \
  2026-07-28T02:00:00+00:00
progress_state_own_older_out=$(progress_render state-own-older)
assert grep -Fq " ${DIM}│${RESET} T2 3/8" <<< "$progress_state_own_older_out"
assert test "${progress_state_own_older_out#*4/4}" = "$progress_state_own_older_out"
progress_doc_clear

# This chat's OWN other unconsumed runs of the same repository do ride behind the rendered one as
# a count: a second review of its own would otherwise be invisible until its result arrived, and a
# sibling worktree's run is this repository's news without being this tree's.
progress_doc own-count-home "$$" T2 3 8 running 0 "" "" 2026-07-27T23:00:00+00:00
progress_doc own-count-sibling "$$" T1 1 4 running 0 "$PROGRESS_WT"
progress_state_own_count_out=$(progress_render state-own-count)
assert grep -Fq " ${DIM}│${RESET} T2 3/8 ${DIM}+1${RESET}" <<< "$progress_state_own_count_out"
progress_doc own-count-second "$$" T1 0 4 running 0 "$PROGRESS_WT"
progress_state_own_count2_out=$(progress_render state-own-count)
assert grep -Fq " ${DIM}│${RESET} T2 3/8 ${DIM}+2${RESET}" <<< "$progress_state_own_count2_out"
progress_doc_clear

# `review-bench cancel` is Egor's decision that the run is over and answers for nothing: the
# document stops speaking the moment it says so, and it is not one of this chat's other runs
# either — a cancelled review leaves no counter behind to be acted on.
progress_doc cancelled "$$" T2 3 8 cancelled 0
progress_state_cancelled_out=$(progress_render state-cancelled)
assert review_slot_silent "$progress_state_cancelled_out"
progress_doc cancelled-beside "$$" T1 5 8 running 0 "" "" 2026-07-27T21:00:00+00:00
progress_state_cancelled_beside_out=$(progress_render state-cancelled)
assert grep -Fq " ${DIM}│${RESET} T1 5/8" <<< "$progress_state_cancelled_beside_out"
assert test "${progress_state_cancelled_beside_out#*+1}" = "$progress_state_cancelled_beside_out"
progress_doc_clear

# And it keeps the segment against its OWN newer leftover: a document is no longer unlinked when
# the run ends, so `started` alone handed the one slot to a result that is already over while a
# review of the same tree was still working. Working outranks over; newest only inside a class.
progress_doc own-live "$$" T2 3 8 running 0 "" "" 2026-07-27T23:00:00+00:00
progress_doc own-done-newer "$$" T2 9 9 done 0 "" "" 2026-07-28T02:00:00+00:00
progress_state_class_out=$(progress_render state-class-order)
assert grep -Fq " ${DIM}│${RESET} T2 3/8" <<< "$progress_state_class_out"
assert test "${progress_state_class_out#*9/9}" = "$progress_state_class_out"
# A run that stopped speaking still outranks one that stopped altogether.
progress_doc own-wedged "$$" T2 5 8 running 300 "" "" 2026-07-27T22:00:00+00:00
rm -f "$PROGRESS_DIR/${progress_prefix}state-own-live.json"
progress_state_wedged_over_done_out=$(progress_render state-class-wedged)
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 5/8${RESET}" <<< "$progress_state_wedged_over_done_out"
progress_doc_clear

# A stranger's run is dropped in every state it can be in, not only while it works.
progress_doc foreign-killed 99999999 T2 3 8 running 0 "" review-progress-another-chat
progress_state_foreign_killed_out=$(progress_render state-foreign-killed)
assert review_slot_silent "$progress_state_foreign_killed_out"
progress_doc_clear
progress_doc foreign-dead "$$" T2 3 8 dead 0 "" review-progress-another-chat
progress_state_foreign_dead_out=$(progress_render state-foreign-dead)
assert review_slot_silent "$progress_state_foreign_dead_out"
progress_doc_clear

progress_doc foreign-dead-sibling "$$" T2 3 8 dead 0 "$PROGRESS_WT" review-progress-another-chat
progress_state_foreign_dead_sibling_out=$(progress_render state-foreign-dead-sibling)
assert review_slot_silent "$progress_state_foreign_dead_sibling_out"
progress_doc own-beside-dead "$$" T2 2 8 running 0
progress_state_beside_dead_out=$(progress_render state-beside-dead)
assert grep -Fq " ${DIM}│${RESET} T2 2/8" <<< "$progress_state_beside_dead_out"
assert test "${progress_state_beside_dead_out#*+1}" = "$progress_state_beside_dead_out"
progress_doc_clear

# Another chat's run over the shown tree itself: the one case where the slot would have been its,
# and it is still not shown — the rule is whose run it is, never which tree it is over.
progress_doc foreign-home "$$" T2 1 4 running 0 "" review-progress-another-chat
progress_state_foreign_home_out=$(progress_render state-foreign-home)
assert review_slot_silent "$progress_state_foreign_home_out"
progress_doc_clear

# The render budgets ONE git call per progress document and no more: a document's tree and the
# repository that tree belongs to come back from the same rev-parse, and the shown tree's own
# identity is long since known — asking again per counted run put N forks in the hot path for N
# other chats. Measured as a DELTA so the rest of the render's calls cancel out.
GIT_SHIM_DIR="$FIXTURES/git-shim"
mkdir -p "$GIT_SHIM_DIR"
GIT_CALL_LOG="$WORK/git-calls.log"
printf '#!/bin/bash\nprintf "x\\n" >> "$GIT_CALL_LOG"\nexec %s "$@"\n' "$(command -v git)" \
  > "$GIT_SHIM_DIR/git"
chmod +x "$GIT_SHIM_DIR/git"
RUN_TREE_CACHE="$HOME/.cache/claude-statusline/run-trees"
git_calls_for_render() { # payload-name
  progress_render "$1" >/dev/null
  : > "$GIT_CALL_LOG"
  ( export PATH="$GIT_SHIM_DIR:$PATH" GIT_CALL_LOG; progress_render "$1" >/dev/null )
  grep -c . "$GIT_CALL_LOG" | tr -d '[:space:]'
}
# The same measurement with nothing remembered: what a first sight of these trees costs.
git_calls_cold() { # payload-name
  rm -f "$RUN_TREE_CACHE"
  : > "$GIT_CALL_LOG"
  ( export PATH="$GIT_SHIM_DIR:$PATH" GIT_CALL_LOG; progress_render "$1" >/dev/null )
  grep -c . "$GIT_CALL_LOG" | tr -d '[:space:]'
}
progress_doc budget-own "$$" T2 3 8 running 0
progress_doc budget-1 "$$" T2 1 4 running 0 "$PROGRESS_WT" review-progress-other-1
progress_budget_cold_two=$(git_calls_cold budget)
progress_doc budget-2 "$$" T2 1 4 running 0 "$PROGRESS_WT" review-progress-other-2
progress_doc budget-3 "$$" T2 1 4 running 0 "$PROGRESS_WT" review-progress-other-3
progress_budget_cold_four=$(git_calls_cold budget)
assert_eq "$progress_budget_cold_two" "$progress_budget_cold_four"
# Warm, which is every render but the first: the trees are remembered by PATH, so the documents
# cost no fork at all — and a finished one added to the pile costs nothing either, which is the
# whole point now that a day of them survives across every repository.
progress_budget_warm=$(git_calls_for_render budget)
assert test "$progress_budget_warm" -lt "$progress_budget_cold_four"
progress_doc budget-4 "$$" T2 4 4 done 0 "$PROGRESS_WT" review-progress-other-4
progress_budget_warm_more=$(git_calls_for_render budget)
assert_eq "$progress_budget_warm" "$progress_budget_warm_more"
progress_doc_clear
# A remembered tree that is gone is not an answer: the entry is skipped and the path resolved again.
mkdir -p "$(dirname "$RUN_TREE_CACHE")"
printf '%s\t%s\t%s\n' "$REVIEW_CLEAN" "$WORK/vanished-top" "$WORK/vanished-common" \
  >> "$RUN_TREE_CACHE"
progress_doc stale-cache "$$" T2 3 8 running 0
progress_stale_cache_out=$(progress_render state-stale-cache)
assert grep -Fq " ${DIM}│${RESET} T2 3/8" <<< "$progress_stale_cache_out"
progress_doc_clear
rm -f "$RUN_TREE_CACHE"

# --- the contract's worked examples ("Shown tree") ------------------------------------------------
example_render() { # session cwd
  run_statusline "$(statusline_payload "$1" "" "$2")" || fail "example render failed: $1"
}
example_home() { # rendered
  grep -Fq "$progress_home_dir" <<< "$1" && [ "${1#*»}" = "$1" ] && [ "${1#*⧉}" = "$1" ]
}

# 1. worker-start elsewhere moves at once, worker-end moves nothing, the next edit here moves back.
"$PLACE" add --session example-1 --kind worker-start --path "$REVIEW_DIRTY"
assert grep -Fq "$progress_away_dirs" <<< "$(example_render example-1 "$REVIEW_CLEAN")"
"$PLACE" add --session example-1 --kind worker-end --path "$REVIEW_DIRTY"
assert grep -Fq "$progress_away_dirs" <<< "$(example_render example-1 "$REVIEW_CLEAN")"
run_workdir_hook "$(workdir_payload Edit example-1 "$REVIEW_CLEAN" "$REVIEW_CLEAN/tracked.txt")"
assert example_home "$(example_render example-1 "$REVIEW_CLEAN")"
assert_eq "worker-start worker-end edit" "$(cut -f2 "$STATE_DIR/place-example-1" | tr '\n' ' ' | sed 's/ $//')"

# 2. Two workers: A starts, B starts, A ends, B ends.
for example_step in "worker-start $REVIEW_CLEAN" "worker-start $REVIEW_DIRTY" \
  "worker-end $REVIEW_CLEAN" "worker-end $REVIEW_DIRTY"; do
  "$PLACE" add --session example-2 --kind "${example_step%% *}" --path "${example_step#* }"
done
assert_eq "$review_clean_root $TOP_REVIEW_DIRTY $review_clean_root $TOP_REVIEW_DIRTY" \
  "$(cut -f3 "$STATE_DIR/place-example-2" | tr '\n' ' ' | sed 's/ $//')"
assert grep -Fq "$progress_away_dirs" <<< "$(example_render example-2 "$REVIEW_CLEAN")"

# 3. Reading another tree moves nothing.
place_set example-3 "$review_clean_root"
run_workdir_hook "$(workdir_payload Read example-3 "$REVIEW_CLEAN" "$REVIEW_DIRTY/tracked.txt")"
run_workdir_hook "$(workdir_payload Bash example-3 "$REVIEW_CLEAN" "(cd '$REVIEW_DIRTY' && git status)")"
run_workdir_hook "$(workdir_payload Bash example-3 "$REVIEW_CLEAN" "git -C '$REVIEW_DIRTY' log")"
assert_eq 1 "$(place_count example-3)"
assert example_home "$(example_render example-3 "$REVIEW_CLEAN")"

# 6. Another chat's reviews over the shown tree's repository: nothing in the slot, and the folder
# stays where this chat's own journal put it.
place_set review-progress-example-6 "$review_clean_root"
progress_doc example-6-home "$$" T2 1 4 running 0 "" review-progress-another-chat
progress_doc example-6-sibling "$$" T2 2 4 running 0 "$PROGRESS_WT" review-progress-another-chat
progress_doc example-6-elsewhere "$$" T2 3 4 running 0 "$REVIEW_DIRTY" review-progress-another-chat
example_6_out=$(progress_render example-6)
assert review_slot_silent "$example_6_out"
assert example_home "$example_6_out"
assert_eq 1 "$(place_count review-progress-example-6)"
progress_doc_clear

# The verdict cache is one file per session and the shown tree moves: while the refresh runs, an
# answer cached for another tree is never shown, and one for this tree still is.
verdict_landed() { # cache
  local i
  for i in $(seq 1 100); do
    [ "$(tail -n +2 "$1")" = off ] && [ ! -d "$1.lock" ] && return 0
    sleep 0.05
  done
  fail "the verdict refresh never landed: $1"
}
verdict_moved_cache="$STATE_DIR/review-class-verdict-moved"
place_set verdict-moved "$review_clean_root"
printf '%s\n%s' "$TOP_REVIEW_DIRTY|0-0|0|0" 'bright 99' > "$verdict_moved_cache"
verdict_moved_out=$(example_render verdict-moved "$REVIEW_CLEAN")
assert test "${verdict_moved_out#*"${DIM}│${RESET} 99"}" = "$verdict_moved_out"
verdict_landed "$verdict_moved_cache"
printf '%s\n%s' "$review_clean_root|0-0|0|0" 'bright 99' > "$verdict_moved_cache"
verdict_same_out=$(example_render verdict-moved "$REVIEW_CLEAN")
assert grep -Fq " ${DIM}│${RESET} 99" <<< "$verdict_same_out"
verdict_landed "$verdict_moved_cache"

# The verdict's cache key reads the commit journal of the checkout FAMILY — one file under the
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
printf 'journal-wt\t1750000000\ttracked.txt\0' > "$journal_wt_gitdir/review-anchors.json"
touch -t 202001010000 "$journal_wt_gitdir/review-anchors.json"
printf 'journal-wt\t1750000000\ttracked.txt\0' > "$journal_wt_common/review-anchors.json"
: > "$GATE_LOG"
rm -f "$STATE_DIR/review-class-journal-wt"
journal_wt_payload=$(statusline_payload journal-wt "" "$PROGRESS_WT")
run_statusline "$journal_wt_payload" >/dev/null || fail "journal worktree first render failed"
review_await_verdict journal-wt
run_statusline "$journal_wt_payload" >/dev/null || fail "journal worktree second render failed"
journal_wt_key=$(head -1 "$STATE_DIR/review-class-journal-wt")
journal_wt_without_clock=${journal_wt_key%|*}
assert_eq "$(stat -f %m "$journal_wt_common/review-anchors.json")" \
  "${journal_wt_without_clock##*|}"
assert_eq 0 "${journal_wt_key##*|}"
assert_eq 1 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
# And the family's journal moving is what asks the gate again, with nothing in `git status` and
# nothing in this worktree's own git dir having moved at all.
touch -t 202001020000 "$journal_wt_common/review-anchors.json"
run_statusline "$journal_wt_payload" >/dev/null || fail "journal worktree common-dir render failed"
gate_calls_await 2
assert_eq 2 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
rm -f "$journal_wt_gitdir/review-anchors.json" "$journal_wt_common/review-anchors.json"
GATE_ANSWER=off

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
gate_agent_payload() {
  jq -cn --arg agent "$1" --arg command "$2" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:$agent,tool_input:{command:$command}}'
}
gate_decision() { jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null; }
for gate_denied in \
  'grok -p "do the thing"' \
  'grok --print "do the thing"' \
  'grok --prompt-file /tmp/brief' \
  'grok --prompt-json /tmp/brief.json' \
  'grok agent --output-format streaming-json' \
  'env GROK_MEMORY=0 /opt/homebrew/bin/grok --prompt-file /tmp/brief' \
  'grokb profile supergrok --prompt-file /tmp/brief --output-format streaming-json' \
  'grokb supergrok exec --prompt-file /tmp/brief' \
  'grokb p supergrok -p "do the thing"' \
  'grokb profile supergrok --prompt-file=/tmp/brief' \
  'grok --prompt=do-the-thing' \
  'claudeb profile com -p --browser' \
  'claudeb profile com -p --chrome' \
  'grok --prompt-json=/tmp/brief.json'; do
  gate_out=$(gate_payload "$gate_denied" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$gate_out" >/dev/null
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | test("worker-run start <claudeb\\|codex\\|gemini\\|grok>")' \
    <<<"$gate_out" >/dev/null
done
for gate_relayed in \
  'worker-run start grok --brief /tmp/brief --workdir /tmp' \
  'worker-run start grok --brief /tmp/brief ; grokb profile supergrok --prompt-file /tmp/brief'; do
  gate_out=$(gate_agent_payload grok-worker "$gate_relayed" | "$LAUNCH_GATE_BIN") ||
    fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done
for gate_allowed in \
  'grokb profile supergrok' \
  'grok models' \
  'grokb list' \
  'echo "grok -p is the spelling the gate denies"' \
  'python3 grok-quota.py'; do
  gate_out=$(gate_payload "$gate_allowed" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done


# --- worker-launch-gate.sh: a run belongs to a relay agent ------------------------------------
# `worker-run` is a sanctioned launcher, but only in the hands of the agent whose row shows who is
# spending quota. Started or awaited from the chat's own Bash the run is owned by a turn: no
# magenta tagged row, and nothing to wake the chat when it ends.
for owned_denied in \
  'worker-run wait cb-20260901-abcdef' \
  'worker-run wait cb-20260901-abcdef --max 540' \
  'worker-run start claudeb --brief /tmp/brief --workdir /tmp' \
  'worker-run start codex --brief /tmp/brief --workdir /tmp' \
  'nohup worker-run wait cb-20260901-abcdef' \
  'timeout 540 worker-run wait cb-20260901-abcdef' \
  'nice -n 5 worker-run wait cb-20260901-abcdef' \
  'sudo worker-run start codex --brief /tmp/brief --workdir /tmp' \
  'if worker-run wait cb-20260901-abcdef; then echo ok; fi' \
  '{ worker-run wait cb-20260901-abcdef; }' \
  'while worker-run wait cb-20260901-abcdef; do sleep 1; done' \
  "bash -c 'worker-run wait cb-20260901-abcdef --max 540'" \
  "/bin/bash -c 'worker-run wait cb-20260901-abcdef'" \
  'bash <<EOF
worker-run wait cb-20260901-abcdef --max 540
EOF' \
  "sh -s <<'EOF'
worker-run start codex --brief /tmp/brief --workdir /tmp
EOF" \
  "echo '<<X'; worker-run wait cb-20260901-abcdef" \
  'echo "a\"b <<EOF"
worker-run wait cb-20260901-abcdef
EOF' \
  'cat <<EOF
$(worker-run wait cb-20260901-abcdef)
EOF' \
  'cat <<EOF | bash
worker-run wait cb-20260901-abcdef
EOF' \
  'echo start <<EOF
worker-run wait cb-20260901-abcdef'; do
  gate_out=$(gate_payload "$owned_denied" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | test("ATTACH <run-id>:")' \
    <<<"$gate_out" >/dev/null
done
# Bookkeeping, help, a finished record and the suite that exercises the launcher are not a run: the
# command WORD is what is judged, never the substring, and a REAL heredoc body — one whose
# delimiter arrives, fed to something that is not a shell — is text a command is written into.
# `ssh host <<EOF` is neither, and it stands here so its verdict is on record rather than assumed:
# that body DOES reach a shell, the remote one, and this door reads it as text anyway because
# nothing in it runs on THIS machine — no local quota is spent, no row could show the run, and an
# `ATTACH` would have nothing to attach to. The local shapes are the rule; this one is the exception
# that names itself.
for owned_allowed in \
  'worker-run claim codex alt' \
  'worker-run' \
  'worker-run report cb-20260901-abcdef' \
  'timeout 20 worker-run report cb-20260901-abcdef' \
  'bash tests/test_worker_run.sh' \
  'cat > /tmp/brief <<EOF
worker-run wait cb-20260901-abcdef --max 540
EOF' \
  'cat <<EOF > /tmp/brief
worker-run wait cb-20260901-abcdef --max 540
EOF' \
  'ssh host <<EOF
worker-run wait cb-20260901-abcdef
EOF' \
  'grep -rn "<<EOF" bin/' \
  'grep -n "worker-run start" bin/worker-run'; do
  gate_out=$(gate_payload "$owned_allowed" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done
# Inside a relay agent the door is exactly what it was before this rule existed — with one clause
# of its own: a `wait` polls for `--max` seconds and the Bash call dies at its own timeout, so the
# harness's 120s default would kill the wait a fifth of the way in and leave the run unwatched.
gate_timeout_payload() { # agent command timeout-ms|null
  jq -cn --arg agent "$1" --arg command "$2" --argjson timeout "$3" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:$agent,
      tool_input:({command:$command} + (if $timeout == null then {} else {timeout:$timeout} end))}'
}
for gate_agent in claudeb-worker codex-worker gemini-worker grok-worker; do
  for owned_relayed in \
    'worker-run start claudeb --brief /tmp/brief --workdir /tmp' \
    'worker-run report cb-20260901-abcdef'; do
    gate_out=$(gate_agent_payload "$gate_agent" "$owned_relayed" | "$LAUNCH_GATE_BIN") ||
      fail "launch gate exited nonzero"
    assert_eq "" "$gate_out"
  done
  for gate_timeout_denied in null 120000 400000; do
    gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max 540' \
      "$gate_timeout_denied" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
    assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
    assert jq -e '.hookSpecificOutput.permissionDecisionReason | test("timeout: 600000")' \
      <<<"$gate_out" >/dev/null
  done
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max 540' \
    600000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max 100' \
    130000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
  # A wait with no `--max` polls worker-run's own default, and a `--max` spelled with a variable
  # states no duration at all: neither may buy a pass the same poll spelled out would be denied.
  # The default is READ OUT of worker-run, so the fixture states one of its own: with the gate
  # falling back to its hardcoded number instead, a default that moved in bin/worker-run would
  # change production denials with this case still green.
  mkdir -p "$HOME/.local/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'wait_run() { local run_id="$1" max=200 tries; }' \
    >"$HOME/.local/bin/worker-run"
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef' \
    220000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef' \
    230000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
  rm -f "$HOME/.local/bin/worker-run"
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef' \
    120000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef' \
    130000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
  # An `--max` no timeout the harness allows could cover is refused for the duration itself: an
  # answer of "pass a bigger timeout" would be an instruction nobody can carry out.
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max 600' \
    600000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | test("--max 540")' \
    <<<"$gate_out" >/dev/null
  # A leading zero is a decimal number to everyone but the shell that reads it as octal: read as
  # octal the arithmetic dies and the door falls open on the poll it was there to judge.
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max 08' \
    1000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max 08' \
    40000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max "$secs"' \
    130000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max "$secs"' \
    570000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
  gate_out=$(gate_agent_payload "$gate_agent" 'claudeb notcom -p go' | "$LAUNCH_GATE_BIN")
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done
gate_out=$(gate_agent_payload image-gen 'codex-image --dest /tmp/a.png --prompt cat' | "$LAUNCH_GATE_BIN")
assert_eq "" "$gate_out"
# image-gen owns runs of its own, so the timeout guard covers its waits too: a poll the harness
# kills leaves the same unwatched run whichever agent type started it.
gate_out=$(gate_timeout_payload image-gen 'worker-run wait cb-20260901-abcdef --max 540' \
  5000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
# An agent type nobody sanctioned owns no run either.
gate_out=$(gate_agent_payload Explore 'worker-run wait cb-20260901-abcdef' | "$LAUNCH_GATE_BIN")
assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"

# A lookup executes nothing: `command -v` / `-V`, and `type` / `which` / `hash -t`, ask where a word
# lives, and asking that about an owned launcher is routine diagnostics. `command` without one of
# those two flags is the transparent wrapper it always was.
for gate_lookup in \
  'command -v light-research' \
  'command -V light-research' \
  'command -v codex-image' \
  'command -v grok-video' \
  'command -v image-fanout' \
  'command -v claudeb' \
  'command -v worker-run' \
  'type light-research' \
  'which codex-image' \
  'hash -t light-research'; do
  gate_out=$(gate_payload "$gate_lookup" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done
for gate_lookup_denied in \
  'command light-research --prompt-file /tmp/q' \
  'command -p light-research' \
  'env light-research' \
  'exec light-research' \
  'command codex-image --dest /tmp/a.png --prompt cat' \
  'command claudeb notcom -p go' \
  'command -v light-research && light-research --prompt-file /tmp/q' \
  'command -v claudeb; claudeb notcom -p go'; do
  gate_out=$(gate_payload "$gate_lookup_denied" | "$LAUNCH_GATE_BIN") ||
    fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done

# --- Task rows: spawn gate, per-spawn seeds, run/review/light state, the renderer's fit -----------
TR_HOME_CACHE="$HOME/.cache/claude-worker-tags"
tr_spawn() { # session type prompt [tool_use_id] [model]
  jq -cn --arg session "$1" --arg type "$2" --arg prompt "$3" --arg use "${4:-}" --arg model "${5:-}" '
    {hook_event_name:"PreToolUse",tool_name:"Agent",session_id:$session,
     tool_input:({subagent_type:$type,description:"Do the task",prompt:$prompt}
       + (if $model == "" then {} else {model:$model} end))}
    + (if $use == "" then {} else {tool_use_id:$use} end)' |
    WORKER_SPAWN_WORKER_PICK=/nonexistent "$SPAWN_HOOK"
}

# Every native type off the allowlist is refused with the limit gate's deny shape; the relay path is named in it.
for tr_native in Explore Plan general-purpose claude-code-guide statusline-setup some-new-type ''; do
  tr_out=$(tr_spawn tr-native "$tr_native" 'look around') || fail "native spawn exited nonzero"
  assert_eq deny "$(printf '%s' "$tr_out" | gate_decision)"
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | test("use a relay worker [(]worker-run[)] instead")' <<<"$tr_out" >/dev/null
done
assert test ! -e "$TR_HOME_CACHE/tr-native"
tr_wf=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Workflow",session_id:"tr-wf",tool_input:{script:"x"}}' |
  "$SPAWN_HOOK") || fail "Workflow spawn exited nonzero"
assert_eq "" "$tr_wf"

# fork is tagged `fork · <model> · <session account>`, and gets no MD guard: it is his word, not a worker.
tr_fork=$(CLAUDE_LIMITS_ACCOUNT=forkacct tr_spawn tr-fork fork 'Refactor the parser' '' claude-opus-5) || fail "fork spawn exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "fork · opus · forkacct: Do the task"' <<<"$tr_fork" >/dev/null
assert jq -e '(.hookSpecificOutput.updatedInput.prompt | test("MD-GUARD")) | not' <<<"$tr_fork" >/dev/null
assert_eq 'fork · opus · forkacct' "$(seed_of tr-fork fork)"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-fable-5-1"}}' > "$WORK/tr-fork.jsonl"
tr_fork_inherit=$(jq -cn --arg t "$WORK/tr-fork.jsonl" '{hook_event_name:"PreToolUse",tool_name:"Agent",session_id:"tr-fork2",
  transcript_path:$t,tool_input:{subagent_type:"fork",description:"Look",prompt:"x"}}' |
  CLAUDE_LIMITS_ACCOUNT=forkacct "$SPAWN_HOOK") || fail "fork spawn exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "fork · fable · forkacct: Look"' <<<"$tr_fork_inherit" >/dev/null

# The codex row names the brief's MODEL: line.
tr_codex=$(tr_spawn tr-codex codex-worker $'ACCOUNT: alt\nMODEL: gpt-5.6-terra\nEFFORT: high\nx') || fail "codex spawn exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "alt · terra · high: Do the task"' <<<"$tr_codex" >/dev/null

# A review-waiter row reads tier, composition and lens off the run's progress document and seeds `review=`.
TR_STATS="$WORK/tr-stats"
mkdir -p "$TR_STATS/progress"
TR_REVIEW=20260916T223010Z-e66f8e6
jq -cn --arg run "$TR_REVIEW" '{run_id:$run,tier:"T2",composition:"double",kind:"task",state:"running",phase:"review",
  cells:["claude-opus-high","codex-sol-high","agy-flash38-high","grok-grok-high"],
  done:["agy-flash38-high","grok-grok-high"],failed_cells:["grok-grok-high"],
  accounts:{"claude-opus-high":"locomthebest"}}' > "$TR_STATS/progress/llm-legs__x-1.json"
tr_waiter=$(WORKER_STATS_DIR="$TR_STATS" tr_spawn tr-rev review-waiter "WAIT $TR_REVIEW: task hunt") ||
  fail "review-waiter spawn exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "T2 · double · task: Do the task"' <<<"$tr_waiter" >/dev/null
tr_rev_seed=$(ls "$TR_HOME_CACHE/tr-rev"/pending-review-waiter-*)
assert_eq "review=$TR_REVIEW" "$(grep '^review=' "$tr_rev_seed")"
tr_waiter_nodoc=$(WORKER_STATS_DIR="$TR_STATS" tr_spawn tr-rev-nodoc review-waiter "WAIT 20260101T000000Z-abcdef1: gone") ||
  fail "review-waiter spawn exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "review · abcdef1: Do the task"' <<<"$tr_waiter_nodoc" >/dev/null

# Two spawns of one type in one turn each keep a seed, and the agents claim them oldest first.
tr_spawn tr-pair claudeb-worker $'ACCOUNT: first\nx' toolu_first >/dev/null
tr_spawn tr-pair claudeb-worker $'ACCOUNT: second\nx' toolu_second >/dev/null
touch -t "$(date -v-5S +%Y%m%d%H%M.%S)" "$TR_HOME_CACHE/tr-pair/pending-claudeb-worker-toolu_first"
assert_eq 2 "$(ls "$TR_HOME_CACHE/tr-pair" | grep -c '^pending-claudeb-worker-')"
printf '%s' "$(worker_payload claudeb-worker agentA 'Save brief' 'true' tr-pair)" | "$WORKER_HOOK" >/dev/null
printf '%s' "$(worker_payload claudeb-worker agentB 'Save brief' 'true' tr-pair)" | "$WORKER_HOOK" >/dev/null
assert_eq 'first · opus · high' "$(head -n1 "$TR_HOME_CACHE/tr-pair/agentA")"
assert_eq 'second · opus · high' "$(head -n1 "$TR_HOME_CACHE/tr-pair/agentB")"
assert_eq 0 "$(ls "$TR_HOME_CACHE/tr-pair" | grep -c '^pending-')"
assert_fails grep -q '^spawn=' "$TR_HOME_CACHE/tr-pair/agentA"

# A denied spawn's seed is never another spawn's: the agent's transcript names its prompt, and
# without one a seed past the age limit is left alone.
tr_spawn tr-stale claudeb-worker $'ACCOUNT: denied\nx' toolu_denied >/dev/null
touch -t 202601010000 "$TR_HOME_CACHE/tr-stale/pending-claudeb-worker-toolu_denied"
tr_spawn tr-stale claudeb-worker $'ACCOUNT: live\nx' toolu_live >/dev/null
touch -t "$(date -v-5S +%Y%m%d%H%M.%S)" "$TR_HOME_CACHE/tr-stale/pending-claudeb-worker-toolu_live"
tr_stale_transcript="$WORK/tr-stale-parent.jsonl"
mkdir -p "$WORK/tr-stale-parent/subagents"
jq -cn '{type:"user",message:{role:"user",content:"ACCOUNT: live\nx"}}' > "$WORK/tr-stale-parent/subagents/agent-agentL.jsonl"
printf '%s' "$(worker_payload claudeb-worker agentL 'Save brief' 'true' tr-stale | jq -c --arg t "$tr_stale_transcript" '.transcript_path = $t')" |
  WORKER_TAG_SEED_MAX_AGE_S=999999999 "$WORKER_HOOK" >/dev/null
assert_eq 'live · opus · high' "$(head -n1 "$TR_HOME_CACHE/tr-stale/agentL")"
assert test -f "$TR_HOME_CACHE/tr-stale/pending-claudeb-worker-toolu_denied"
printf '%s' "$(worker_payload claudeb-worker agentN 'Save brief' 'true' tr-stale)" | "$WORKER_HOOK" >/dev/null
assert test ! -e "$TR_HOME_CACHE/tr-stale/agentN"
assert test -f "$TR_HOME_CACHE/tr-stale/pending-claudeb-worker-toolu_denied"

# Every seed carries a spawn key, an empty first line included, and an agent that knows its key never
# takes a keyless seed.
tr_spawn tr-keyless claudeb-worker $'\nACCOUNT: blank' toolu_blank >/dev/null
assert grep -q '^spawn=[0-9a-f]\{16\}$' "$TR_HOME_CACHE/tr-keyless/pending-claudeb-worker-toolu_blank"
printf 'other · opus · high\n' > "$TR_HOME_CACHE/tr-keyless/pending-claudeb-worker-legacy"
mkdir -p "$WORK/tr-keyless-parent/subagents"
jq -cn '{type:"user",message:{role:"user",content:"ACCOUNT: mine\nx"}}' > "$WORK/tr-keyless-parent/subagents/agent-agentK.jsonl"
printf '%s' "$(worker_payload claudeb-worker agentK 'Save brief' 'true' tr-keyless | jq -c --arg t "$WORK/tr-keyless-parent.jsonl" '.transcript_path = $t')" |
  "$WORKER_HOOK" >/dev/null
assert test ! -e "$TR_HOME_CACHE/tr-keyless/agentK" -a -f "$TR_HOME_CACHE/tr-keyless/pending-claudeb-worker-legacy"

# A seed claim that cannot take `.claim.lock` leaves the seed in place for the next call.
tr_spawn tr-locked claudeb-worker $'ACCOUNT: kept\nx' toolu_kept >/dev/null
mkdir "$TR_HOME_CACHE/tr-locked/.claim.lock"
printf '%s' "$(worker_payload claudeb-worker agentS 'Save brief' 'true' tr-locked)" | "$WORKER_HOOK" >/dev/null
assert test ! -e "$TR_HOME_CACHE/tr-locked/agentS" -a -f "$TR_HOME_CACHE/tr-locked/pending-claudeb-worker-toolu_kept"
rmdir "$TR_HOME_CACHE/tr-locked/.claim.lock"

# review-waiter, light-research and image-gen run on their own frontmatter model: a tool-call model is
# stripped; a fork keeps it.
for tr_pinned in review-waiter light-research image-gen; do
  tr_spawn tr-pinned "$tr_pinned" 'WAIT 20260101T000000Z-abcdef1: x' '' opus > "$WORK/tr-pinned-$tr_pinned.json"
done
assert jq -se 'length == 3 and all(.[]; .hookSpecificOutput.updatedInput | has("model") | not)' \
  "$WORK/tr-pinned-review-waiter.json" "$WORK/tr-pinned-light-research.json" "$WORK/tr-pinned-image-gen.json" >/dev/null

# The review-waiter's wait writes the run's tag and `review=`, names itself to review-bench through
# `--waiter <agent id>`, and is granted nothing.
tr_rev_out=$(printf '%s' "$(worker_payload review-waiter waiter1 'Wait' "review-bench wait $TR_REVIEW --max 540 | tail -n 3" tr-rev)" |
  WORKER_STATS_DIR="$TR_STATS" "$WORKER_HOOK") || fail "review-waiter tag exited nonzero"
assert_eq 'T2 · double · task' "$(head -n1 "$TR_HOME_CACHE/tr-rev/waiter1")"
assert_eq "review=$TR_REVIEW" "$(sed -n 2p "$TR_HOME_CACHE/tr-rev/waiter1")"
assert jq -e --arg c "review-bench wait $TR_REVIEW --waiter waiter1 --max 540 | tail -n 3" '.hookSpecificOutput.updatedInput.command == $c' <<<"$tr_rev_out" >/dev/null
assert jq -e '.hookSpecificOutput | has("permissionDecision") | not' <<<"$tr_rev_out" >/dev/null
tr_rev_again=$(printf '%s' "$(worker_payload review-waiter waiter1 'Wait' "review-bench wait $TR_REVIEW --waiter waiter1 --max 540" tr-rev)" |
  WORKER_STATS_DIR="$TR_STATS" "$WORKER_HOOK") || fail "review-waiter tag exited nonzero"
assert jq -e --arg c "review-bench wait $TR_REVIEW --waiter waiter1 --max 540" '(.hookSpecificOutput.updatedInput.command // $c) == $c' <<<"$tr_rev_again" >/dev/null
printf '%s' "$(worker_payload review-waiter waiter2 'Wait' 'review-bench wait 20260101T000000Z-abcdef1 --max 540' tr-rev)" |
  WORKER_STATS_DIR="$TR_STATS" "$WORKER_HOOK" >/dev/null
assert_eq 'review · abcdef1' "$(head -n1 "$TR_HOME_CACHE/tr-rev/waiter2")"

# A launch after a heredoc is still the launch; the heredoc body is not.
tr_after=$(worker_payload claudeb-worker traft 'Ship it' $'cat > /tmp/brief <<EOF\nclaudeb profile fake --model opus -p x\nEOF\nclaudeb profile real --model sonnet -p "$(cat /tmp/brief)"' tr-after)
printf '%s' "$tr_after" | "$WORKER_HOOK" >/dev/null || fail "after-heredoc launch exited nonzero"
assert_eq 'real · sonnet · high' "$(head -n1 "$TR_HOME_CACHE/tr-after/traft")"

# No account in the launch text: the agent's own earlier tag, then worker-pick, then `?`.
TR_PICK="$WORK/tr-worker-pick"
printf '#!/usr/bin/env bash\necho pickedacct\n' > "$TR_PICK"; chmod +x "$TR_PICK"
printf '%s' "$(worker_payload claudeb-worker trpick 'Go' 'claudeb --model opus -p x' tr-pick)" |
  WORKER_TAG_WORKER_PICK="$TR_PICK" "$WORKER_HOOK" >/dev/null
assert_eq 'pickedacct · opus · high' "$(head -n1 "$TR_HOME_CACHE/tr-pick/trpick")"
printf '%s' "$(worker_payload claudeb-worker trpick 'Go' 'claudeb --model opus -p x' tr-pick)" |
  WORKER_TAG_WORKER_PICK=/nonexistent "$WORKER_HOOK" >/dev/null
assert_eq 'pickedacct · opus · high' "$(head -n1 "$TR_HOME_CACHE/tr-pick/trpick")"

# grok-video and image-fanout are launches too. A launch with `--ref` or `--resume` is an edit and
# clears the last launch's `exit=`; a fan-out names its dest dir unless it is a dry run.
mkdir -p "$TR_HOME_CACHE/tr-media"
printf 'old · x\nexit=3\n' > "$TR_HOME_CACHE/tr-media/trvid"
printf '%s' "$(worker_payload image-gen trvid 'Clip' 'grok-video --account sg2 --dest /tmp/a.mp4 --ref /tmp/a.png' tr-media)" | "$WORKER_HOOK" >/dev/null
assert_eq $'sg2 · imagine-video-1.5\nmedia=edit' "$(cat "$TR_HOME_CACHE/tr-media/trvid")"
printf '%s' "$(worker_payload image-gen trvid 'Clip' 'grok-image --dest /tmp/a.png --prompt x' tr-media)" | "$WORKER_HOOK" >/dev/null
assert_eq $'sg2 · imagine-video-1.5\nmedia=gen' "$(cat "$TR_HOME_CACHE/tr-media/trvid")"
printf '%s' "$(worker_payload image-gen trfan 'Fan' 'image-fanout --dest-dir "/tmp/fan out" --prompt x' tr-media)" | "$WORKER_HOOK" >/dev/null
assert_eq $'fanout · image\nimage=/tmp/fan out' "$(cat "$TR_HOME_CACHE/tr-media/trfan")"
printf '%s' "$(worker_payload image-gen trfan 'Fan' 'image-fanout --dest-dir /tmp/v --video --ref /tmp/a.png --prompt x --dry-run' tr-media)" | "$WORKER_HOOK" >/dev/null
assert_eq 'fanout · video' "$(cat "$TR_HOME_CACHE/tr-media/trfan")"

# worker-run start marks the agent's tag file; wait names the run, by literal id or through the state
# file that names this agent when the id is a shell variable.
tr_runs="$HOME/.cache/claude-worker-runs"
mkdir -p "$TR_HOME_CACHE/tr-run"
printf 'seed · opus · high\n' > "$TR_HOME_CACHE/tr-run/pending-claudeb-worker-a"
printf '%s' "$(worker_payload claudeb-worker trrun 'Launch' 'worker-run start claudeb --brief /tmp/b --workdir /tmp' tr-run)" | "$WORKER_HOOK" >/dev/null
assert grep -Eq '^start=[0-9]+$' "$TR_HOME_CACHE/tr-run/trrun"
mkdir -p "$tr_runs/claudeb-1-2-lit" "$tr_runs/claudeb-1-3-var"
printf 'runacct · opus · high\n' > "$tr_runs/claudeb-1-2-lit/tag"
printf '%s' "$(worker_payload claudeb-worker trrun 'Wait' 'worker-run wait claudeb-1-2-lit --max 540' tr-run)" | "$WORKER_HOOK" >/dev/null
assert_eq 'runacct · opus · high' "$(head -n1 "$TR_HOME_CACHE/tr-run/trrun")"
assert_eq 'run=claudeb-1-2-lit' "$(grep '^run=' "$TR_HOME_CACHE/tr-run/trrun")"
printf 'varacct · opus · high\n' > "$tr_runs/claudeb-1-3-var/tag"
printf '{"phase":"wait","round":1,"agent_task_id":"trvar"}\n' > "$tr_runs/claudeb-1-3-var/state.json"
printf '%s' "$(worker_payload claudeb-worker trvar 'Wait' 'worker-run wait "$RUN_ID" --max 540' tr-run)" | "$WORKER_HOOK" >/dev/null
assert_eq 'varacct · opus · high' "$(head -n1 "$TR_HOME_CACHE/tr-run/trvar")"
assert_eq 'run=claudeb-1-3-var' "$(grep '^run=' "$TR_HOME_CACHE/tr-run/trvar")"

# A subagent's edit is counted into its own tag file, the tag line kept.
mkdir -p "$TR_HOME_CACHE/tr-edit"
printf 'fork · opus · acct\n' > "$TR_HOME_CACHE/tr-edit/a1"
run_workdir_hook "$(agent_payload Edit tr-edit "$REPO_A" "$REPO_A/one.txt")"
run_workdir_hook "$(agent_payload Write tr-edit "$REPO_A" "$REPO_A/two.txt")"
assert_eq 'fork · opus · acct' "$(head -n1 "$TR_HOME_CACHE/tr-edit/a1")"
assert_eq 'edit=2' "$(grep '^edit=' "$TR_HOME_CACHE/tr-edit/a1")"
run_workdir_hook "$(agent_payload Read tr-edit "$REPO_A" "$REPO_A/one.txt")"
assert_eq 'edit=2' "$(grep '^edit=' "$TR_HOME_CACHE/tr-edit/a1")"
# Two writers racing on one tag file serialize through the directory's `.claim.lock`: no count is
# lost and the other writer's key survives.
tr_edit_payload=$(agent_payload Write tr-edit "$REPO_A" "$REPO_A/two.txt")
tr_start_payload=$(worker_payload claudeb-worker a1 'Launch' 'worker-run start codex --brief /tmp/b --workdir /tmp' tr-edit)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  printf '%s' "$tr_edit_payload" | "$WORKDIR_HOOK" >/dev/null 2>&1 &
  printf '%s' "$tr_start_payload" | "$WORKER_HOOK" >/dev/null 2>&1 &
done
wait
assert_eq 'edit=12' "$(grep '^edit=' "$TR_HOME_CACHE/tr-edit/a1")"
assert grep -q '^start=[0-9]*$' "$TR_HOME_CACHE/tr-edit/a1"
assert test ! -e "$TR_HOME_CACHE/tr-edit/.claim.lock"
# An image script's Bash call stamps `exit=N`: PostToolUse means 0, PostToolUseFailure carries it.
media_payload() { # event command [extra-json]
  local extra=${3:-'{}'}
  jq -cn --arg event "$1" --arg command "$2" --argjson extra "$extra" '{hook_event_name:$event,tool_name:"Bash",
    session_id:"tr-exit",agent_id:"m1",agent_type:"image-gen",cwd:"/tmp",tool_input:{command:$command}} + $extra'
}
mkdir -p "$TR_HOME_CACHE/tr-exit"
printf 'notcom · gpt-image-2\nmedia=gen\n' > "$TR_HOME_CACHE/tr-exit/m1"
run_workdir_hook "$(media_payload PostToolUse 'ls /tmp')"
run_workdir_hook "$(media_payload PostToolUse 'codex-image --dest /tmp/a.png --prompt x' '{"tool_input":{"command":"codex-image --dest /tmp/a.png","run_in_background":true}}')"
assert_eq $'notcom · gpt-image-2\nmedia=gen' "$(cat "$TR_HOME_CACHE/tr-exit/m1")"
run_workdir_hook "$(media_payload PostToolUse '/opt/bin/codex-image --dest /tmp/a.png --prompt x')"
assert_eq $'notcom · gpt-image-2\nmedia=gen\nexit=0' "$(cat "$TR_HOME_CACHE/tr-exit/m1")"
run_workdir_hook "$(media_payload PostToolUseFailure 'grok-video --dest /tmp/a.mp4' '{"error":"Exit code 3\nUSAGE_LIMIT"}')"
assert_eq $'notcom · gpt-image-2\nmedia=gen\nexit=3' "$(cat "$TR_HOME_CACHE/tr-exit/m1")"
printf 'acct · opus · high\n' > "$TR_HOME_CACHE/tr-exit/m1"
run_workdir_hook "$(media_payload PostToolUse 'codex-image --dest /tmp/a.png --prompt x')"
assert_eq 'acct · opus · high' "$(cat "$TR_HOME_CACHE/tr-exit/m1")"

# The gate: a Monitor on a wait is refused, and so is a review wait from the chat's own Bash.
monitor_payload() { jq -cn --arg command "$1" '{hook_event_name:"PreToolUse",tool_name:"Monitor",tool_input:{command:$command}}'; }
for tr_monitored in 'worker-run wait cb-1-2-abc --max 540' "review-bench wait $TR_REVIEW" 'until review-bench  wait x; do sleep 5; done'; do
  gate_out=$(monitor_payload "$tr_monitored" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | test("ATTACH relay / review-waiter agent so the run has a magenta row")' <<<"$gate_out" >/dev/null
done
gate_out=$(monitor_payload 'tail -f /tmp/server.log' | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
# The Monitor branch reads the masked scan: a quoted mention is an operand, and every owned spelling behind it is judged.
gate_out=$(monitor_payload "grep -n 'review-bench wait' /tmp/notes.txt" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
for tr_monitor_owned in 'worker-run start codex --brief /tmp/b --workdir /tmp' 'codex-image --dest /tmp/a.png --prompt cat' \
  'light-research --prompt-file /tmp/q --out /tmp/a'; do
  gate_out=$(monitor_payload "$tr_monitor_owned" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done
# Recovery of a dead review run goes through the review-waiter too, and the denial names the brief.
for tr_recovery in --relaunch --finish-partial; do
  gate_out=$(gate_payload "review-bench wait $TR_REVIEW $tr_recovery" | env -u CLAUDEB_WORKER "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  assert jq -e --arg want "Spawn \`review-waiter\` with the brief \`ATTACH <run-id>: $tr_recovery\`" \
    '.hookSpecificOutput.permissionDecisionReason | contains($want)' <<<"$gate_out" >/dev/null
done
gate_out=$(gate_payload "review-bench wait $TR_REVIEW --max 540" | env -u CLAUDEB_WORKER "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
assert jq -e '.hookSpecificOutput.permissionDecisionReason | test("review-waiter")' <<<"$gate_out" >/dev/null
# A headless worker process has no task list to give the wait to.
gate_out=$(gate_payload "review-bench wait $TR_REVIEW --max 540" | CLAUDEB_WORKER=1 "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
for tr_review_ok in 'review-bench review --tier T2' "review-bench report $TR_REVIEW" 'review-bench findings'; do
  gate_out=$(gate_payload "$tr_review_ok" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done
gate_out=$(gate_agent_payload review-waiter "review-bench wait $TR_REVIEW --max 540" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
gate_out=$(gate_payload 'light-research --prompt-file /tmp/q --out /tmp/a --repo /tmp/r' | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
gate_out=$(gate_agent_payload light-research '~/.local/bin/light-research --prompt-file /tmp/q --out /tmp/a' | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
gate_out=$(gate_agent_payload light-research 'light-research --attach gemini-1-2-abcd --out /tmp/a' | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
gate_out=$(gate_payload 'light-research --attach gemini-1-2-abcd --out /tmp/a' | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
gate_out=$(gate_agent_payload light-worker 'worker-run start light --brief /tmp/b --workdir /tmp' | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
gate_out=$(gate_payload 'worker-run start light --brief /tmp/b --workdir /tmp' | env -u CLAUDEB_WORKER "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"

# The renderer paints every running local_agent task, state from the run's files, and fits `columns`.
RENDER_BIN="$ROOT/bin/subagent-statusline.sh"
TR_RSESS=tr-render
mkdir -p "$TR_HOME_CACHE/$TR_RSESS" "$tr_runs/codex-9-9-wait" "$tr_runs/codex-9-9-done" "$tr_runs/codex-9-9-live" \
  "$tr_runs/codex-9-9-fix" "$tr_runs/gemini-9-9-res"
printf 'acc · astra · high\nrun=codex-9-9-wait\n' > "$TR_HOME_CACHE/$TR_RSESS/w1"
printf '{"phase":"wait","round":3}\n' > "$tr_runs/codex-9-9-wait/state.json"
printf 'acc · astra · high\nrun=codex-9-9-done\n' > "$TR_HOME_CACHE/$TR_RSESS/w2"
printf '{"phase":"done","round":4,"exit_code":0}\n' > "$tr_runs/codex-9-9-done/state.json"; printf '0\n' > "$tr_runs/codex-9-9-done/exit_code"
printf 'acc · astra · high\nrun=codex-9-9-live\n' > "$TR_HOME_CACHE/$TR_RSESS/w3"
printf 'acc · astra · high\nrun=codex-9-9-live\n' > "$TR_HOME_CACHE/$TR_RSESS/w4"
printf '{"phase":"wait","round":6}\n' > "$tr_runs/codex-9-9-live/state.json"
printf 'T2 · double · task\nreview=%s\n' "$TR_REVIEW" > "$TR_HOME_CACHE/$TR_RSESS/r1"
printf 'fork · inherit · acc\nedit=3\n' > "$TR_HOME_CACHE/$TR_RSESS/l1"
printf 'acc · astra · high\nrun=codex-9-9-fix\n' > "$TR_HOME_CACHE/$TR_RSESS/f1"
printf 'acc · astra · high\nrun=codex-9-9-fix\n' > "$TR_HOME_CACHE/$TR_RSESS/f2"
printf '{"phase":"wait","round":1,"round_id":"%s"}\n' "$TR_REVIEW" > "$tr_runs/codex-9-9-fix/state.json"
printf 'rawilimo · flash38 · high\nlight=research\nrun=gemini-9-9-res\n' > "$TR_HOME_CACHE/$TR_RSESS/g1"
printf '{"phase":"wait","round":2}\n' > "$tr_runs/gemini-9-9-res/state.json"
mkdir -p "$WORK/tr fan"
printf 'fanout · image\nimage=%s\n' "$WORK/tr fan" > "$TR_HOME_CACHE/$TR_RSESS/i1"
jq -cn '{kind:"image",cells:[{vendor:"codex",account:"notcom",status:"done",exit:0},{vendor:"gemini",account:"a",status:"running"},
  {vendor:"gemini",account:"b",status:"done",exit:0},{vendor:"grok",account:"c",status:"failed",exit:1}]}' > "$WORK/tr fan/fanout.state.json"
printf 'notcom · gpt-image-2\nmedia=gen\n' > "$TR_HOME_CACHE/$TR_RSESS/i2"
printf 'notcom · gpt-image-2\nmedia=edit\n' > "$TR_HOME_CACHE/$TR_RSESS/i3"
printf 'notcom · gpt-image-2\nmedia=gen\nexit=0\n' > "$TR_HOME_CACHE/$TR_RSESS/i4"
printf 'rawilimo · imagine-video-1.5\nmedia=edit\nexit=3\n' > "$TR_HOME_CACHE/$TR_RSESS/i5"
tr_render() { # columns
  local start=$(( ($(date +%s) - 65) * 1000 ))
  jq -cn --argjson cols "$1" --argjson start "$start" --arg sess "$TR_RSESS" --arg rev "$TR_REVIEW" '{session_id:$sess,columns:$cols,tasks:[
    {id:"w1",type:"local_agent",status:"running",description:"acc · astra · high: Implement the parser fix",label:"Running suites",startTime:$start,tokenCount:12345,model:"claude-sonnet-5"},
    {id:"w2",type:"local_agent",status:"running",description:"Done run",label:"Done",startTime:$start},
    {id:"w3",type:"local_agent",status:"completed",description:"Finished run",startTime:$start},
    {id:"w4",type:"local_agent",status:"killed",description:"Killed run",startTime:$start},
    {id:"r1",type:"local_agent",status:"running",description:("T2 · double · task: WAIT " + $rev + ": hunt over the task rows"),startTime:$start,tokenCount:500},
    {id:"l1",type:"local_agent",status:"running",description:"Refactor",startTime:$start,model:"claude-fable-5-1"},
    {id:"n1",type:"local_agent",status:"running",description:"Look around",startTime:$start,model:"claude-haiku-4-5-20251001"},
    {id:"f1",type:"local_agent",status:"running",description:"acc · astra · high — Patch the gate",label:"Reading files",startTime:$start,tokenCount:900},
    {id:"f2",type:"local_agent",status:"running",description:"fix: e66f8e6 Patch again",startTime:$start},
    {id:"g1",type:"local_agent",status:"running",description:"light research · 3.8-flash · rawilimo: Map the hooks",startTime:$start,model:"claude-sonnet-5"},
    {id:"i1",type:"local_agent",status:"running",description:"fanout · image: Draw the menubar icon",startTime:$start},
    {id:"i2",type:"local_agent",status:"running",description:"Draw one icon",startTime:$start},
    {id:"i3",type:"local_agent",status:"running",description:"Edit one icon",startTime:$start},
    {id:"i4",type:"local_agent",status:"running",description:"Draw one icon",startTime:$start},
    {id:"i5",type:"local_agent",status:"completed",description:"Animate one icon",startTime:$start},
    {id:"b1",type:"local_bash",status:"running",label:"sleep"}]}' |
    WORKER_STATS_DIR="$TR_STATS" SUBAGENT_ROW_RESERVE=0 CLAUDE_LIMITS_ACCOUNT=rowacct "$RENDER_BIN"
}
# A second may tick between the fixture's clock and the renderer's; both spell the same width.
tr_row() { jq -r --arg id "$2" 'select(.id == $id) | .content' <<<"$1" | perl -pe 's/\e\[[0-9;]*m//g; s/1m [5-9]s/1m 5s/'; }
tr_wide=$(tr_render 300) || fail "renderer exited nonzero"
assert_eq 12 "$(grep -c . <<<"$tr_wide")"
assert_eq 'acc · astra · high — Implement the parser fix · wait 3 · 1m 5s · ↓ 12.3k tok' "$(tr_row "$tr_wide" w1)"
# Only running tasks have rows; a run that ended under a running agent shows no state.
assert_eq 'acc · astra · high — Done run · 1m 5s' "$(tr_row "$tr_wide" w2)"
assert_eq '' "$(tr_row "$tr_wide" w3)$(tr_row "$tr_wide" w4)$(tr_row "$tr_wide" i5)"
assert_eq 'T2 · double · task — hunt over the task rows · all 2/4 opus 0/1 sol 0/1 agy ✓ grok ✗1 · 1m 5s · ↓ 500 tok' "$(tr_row "$tr_wide" r1)"
assert_eq 'fork · fable · acc — Refactor · edit 3 · 1m 5s' "$(tr_row "$tr_wide" l1)"
assert_eq 'agent · haiku · rowacct — Look around · 1m 5s' "$(tr_row "$tr_wide" n1)"
assert_fails grep -Fq 'Running suites' <<<"$tr_wide"
# Review, fix and image rows carry no title; worker and light rows keep theirs. A fix row is
# `fix: <tag> · <round hash> · <state>`.
assert_eq 'fix: acc · astra · high · e66f8e6 · wait 1 · 1m 5s · ↓ 900 tok' "$(tr_row "$tr_wide" f1)"
assert_eq 'fix: acc · astra · high · e66f8e6 · wait 1 · 1m 5s' "$(tr_row "$tr_wide" f2)"
assert grep -Fq "${MAGENTA}fix: acc · astra · high${RESET} ${DIM}· e66f8e6${RESET}" <<<"$(jq -r 'select(.id == "f1") | .content' <<<"$tr_wide")"
assert_fails grep -Fq 'Patch again' <<<"$(tr_row "$tr_wide" f2)"
assert_eq 'fanout · image · all 3/4 codex ✓ gemini 1/2 grok ✗1 · 1m 5s' "$(tr_row "$tr_wide" i1)"
assert_eq 'notcom · gpt-image-2 · gen · 1m 5s' "$(tr_row "$tr_wide" i2)"
assert_eq 'notcom · gpt-image-2 · edit · 1m 5s' "$(tr_row "$tr_wide" i3)"
assert_eq 'notcom · gpt-image-2 · 1m 5s' "$(tr_row "$tr_wide" i4)"
assert_fails grep -Fq 'one icon' <<<"$(tr_row "$tr_wide" i2)$(tr_row "$tr_wide" i4)"
assert_fails grep -Fq 'WAIT' <<<"$(tr_row "$tr_wide" r1)"
assert_fails grep -Fq 'Patch the gate' <<<"$(tr_row "$tr_wide" f1)"
assert_fails grep -Fq 'menubar icon' <<<"$(tr_row "$tr_wide" i1)"
assert grep -Fq 'Implement the parser fix' <<<"$(tr_row "$tr_wide" w1)"
# The light leg names the model doing the work and never the relay agent's shell model.
assert_eq 'light research · 3.8-flash · rawilimo — Map the hooks · wait 2 · 1m 5s' "$(tr_row "$tr_wide" g1)"
assert grep -Fq "${MAGENTA}T2 · double · task${RESET}" <<<"$(jq -r 'select(.id == "r1") | .content' <<<"$tr_wide")"
assert grep -Fq "${GREEN}✓${RESET}" <<<"$(jq -r 'select(.id == "i1") | .content' <<<"$tr_wide")"
assert grep -Fq "${RED}✗${RESET}" <<<"$(jq -r 'select(.id == "i1") | .content' <<<"$tr_wide")"
assert_fails grep -Fq 'done' <<<"$(tr_row "$tr_wide" w2)$(tr_row "$tr_wide" i4)"
# Narrower: the title goes first, then tok, elapsed, a fix row's hash, and the cell detail last (counts stay); the state never.
assert_eq 'T2 · double · task — hunt ov… · all 2/4 opus 0/1 sol 0/1 agy ✓ grok ✗1 · 1m 5s · ↓ 500 tok' "$(tr_row "$(tr_render 90)" r1)"
assert_eq 'T2 · double · task · all 2/4 opus 0/1 sol 0/1 agy ✓ grok ✗1 · 1m 5s' "$(tr_row "$(tr_render 78)" r1)"
assert_eq 'T2 · double · task · all 2/4 opus 0/1 sol 0/1 agy ✓ grok ✗1 · 1m 5s' "$(tr_row "$(tr_render 67)" r1)"
assert_eq 'T2 · double · task · all 2/4 opus 0/1 sol 0/1 agy ✓ grok ✗1' "$(tr_row "$(tr_render 66)" r1)"
assert_eq 'T2 · double · task · all 2/4 opus 0/1 sol 0/1 agy ✓ grok ✗1' "$(tr_row "$(tr_render 59)" r1)"
assert_eq 'T2 · double · task · all 2/4' "$(tr_row "$(tr_render 58)" r1)"
assert_eq 'T2 · double · task · all 2/4' "$(tr_row "$(tr_render 30)" r1)"
assert_eq 'fanout · image · all 3/4 codex ✓ gemini 1/2 grok ✗1' "$(tr_row "$(tr_render 51)" i1)"
assert_eq 'fanout · image · all 3/4' "$(tr_row "$(tr_render 40)" i1)"
tr_60=$(tr_render 60) tr_40=$(tr_render 40) tr_30=$(tr_render 30)
assert_eq 'acc · astra · high — Impleme… · wait 3 · 1m 5s · ↓ 12.3k tok' "$(tr_row "$tr_60" w1)"
assert_eq 'acc · astra · high · wait 3 · 1m 5s' "$(tr_row "$tr_40" w1)"
assert_eq 'acc · astra · high · wait 3' "$(tr_row "$tr_30" w1)"
assert_eq 'fix: acc · astra · high · e66f8e6 · wait 1 · 1m 5s · ↓ 900 tok' "$(tr_row "$(tr_render 62)" f1)"
assert_eq 'fix: acc · astra · high · e66f8e6 · wait 1 · 1m 5s' "$(tr_row "$tr_60" f1)"
assert_eq 'fix: acc · astra · high · e66f8e6 · wait 1' "$(tr_row "$(tr_render 45)" f1)"
assert_eq 'fix: acc · astra · high · wait 1' "$(tr_row "$tr_40" f1)"
assert_eq 'fix: acc · astra · high · wait 1' "$(tr_row "$tr_30" f1)"
assert_eq 'light research · 3.8-flash · rawilimo · wait 2' "$(tr_row "$tr_40" g1)"
# A chunked panel's fraction counts chunk passes; the row total stays cells.
jq '.chunks = {"claude-opus-high":[2,5],"codex-sol-high":[1,5],"agy-flash38-high":[5,5]}' "$TR_STATS/progress/llm-legs__x-1.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-1.json"
assert_eq 'T2 · double · task · all 2/4 opus 2/5 sol 1/5 agy ✓ grok ✗1 · 1m 5s' "$(tr_row "$(tr_render 67)" r1)"
assert_eq 'T2 · double · task · all 2/4' "$(tr_row "$(tr_render 58)" r1)"
jq 'del(.chunks)' "$TR_STATS/progress/llm-legs__x-1.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-1.json"
# Cells group by label, so a panel of eight keeps them at an ordinary width.
TR_REVIEW8=20260917T010000Z-a8c3d21
jq -cn --arg run "$TR_REVIEW8" '{run_id:$run,tier:"T0",composition:"double",lens:"bugs",state:"running",phase:"review",
  cells:["agy-flash37-high#1","agy-flash37-high#2","agy-flash37-high#3","agy-flash37-high#4",
         "claude-opus-low#1","claude-opus-low#2","codex-sol-low#1","codex-sol-low#2"],
  done:["agy-flash37-high#1","agy-flash37-high#4","claude-opus-low#1","codex-sol-low#1","codex-sol-low#2"],
  failed_cells:["agy-flash37-high#4"]}' \
  > "$TR_STATS/progress/llm-legs__x-8.json"
printf 'T0 · double · bugs\nreview=%s\n' "$TR_REVIEW8" > "$TR_HOME_CACHE/$TR_RSESS/r8"
tr8_row() { # columns
  jq -cn --argjson cols "$1" --argjson start "$(( ($(date +%s) - 300) * 1000 ))" --arg sess "$TR_RSESS" '{session_id:$sess,columns:$cols,
    tasks:[{id:"r8",type:"local_agent",status:"running",description:"T0 debt review of chunk rows and the post-round delta",startTime:$start}]}' |
    WORKER_STATS_DIR="$TR_STATS" "$RENDER_BIN" | jq -r '.content' | perl -pe 's/\e\[[0-9;]*m//g; s/5m [0-9]s/5m 0s/'
}
assert_eq 'T0 · double · bugs · all 5/8 agy 2/4 ✗1 opus 1/2 sol ✓ · 5m 0s' "$(tr8_row 200)"
# The default reserve is the top statusline's fit margin, 3: 62 cells fit in 65 columns.
assert_eq "$(sed -nE 's/^STATUSLINE_FIT_MARGIN=\$\{STATUSLINE_FIT_MARGIN:-([0-9]+)\}$/\1/p' "$ROOT/bin/statusline.sh")" \
  "$(sed -nE 's/^reserve=\$\{SUBAGENT_ROW_RESERVE:-([0-9]+)\}$/\1/p' "$RENDER_BIN")"
assert_eq 3 "$(sed -nE 's/^reserve=\$\{SUBAGENT_ROW_RESERVE:-([0-9]+)\}$/\1/p' "$RENDER_BIN")"
assert_eq 'T0 · double · bugs · all 5/8 agy 2/4 ✗1 opus 1/2 sol ✓ · 5m 0s' "$(tr8_row 65)"
assert_eq 'T0 · double · bugs · all 5/8 agy 2/4 ✗1 opus 1/2 sol ✓' "$(tr8_row 64)"
# Claude Code hands an ~80-column chat `columns: 67`: this row renders whole, and elapsed goes before any group.
TR_REVIEWMC=20260917T120000Z-b1c2d3e
jq -cn --arg run "$TR_REVIEWMC" '{run_id:$run,tier:"T1",composition:"standard",lens:"md-compact",state:"running",phase:"review",
  cells:["agy-flash37-high#1","agy-flash37-high#2","claude-opus-high#1","claude-opus-high#2"],
  done:["agy-flash37-high#1","claude-opus-high#1"],failed_cells:[]}' > "$TR_STATS/progress/llm-legs__x-mc.json"
printf 'T1 · standard · md-compact\nreview=%s\n' "$TR_REVIEWMC" > "$TR_HOME_CACHE/$TR_RSESS/mc"
trmc_row() { # columns
  jq -cn --argjson cols "$1" --argjson start "$(( ($(date +%s) - 54) * 1000 ))" --arg sess "$TR_RSESS" '{session_id:$sess,columns:$cols,
    tasks:[{id:"mc",type:"local_agent",status:"running",description:"x",startTime:$start}]}' |
    WORKER_STATS_DIR="$TR_STATS" "$RENDER_BIN" | jq -r '.content' | perl -pe 's/\e\[[0-9;]*m//g; s/5[4-9]s$/54s/'
}
for trmc_cols in 67 62; do
  assert_eq 'T1 · standard · md-compact · all 2/4 agy 1/2 opus 1/2 · 54s' "$(trmc_row "$trmc_cols")"
done
for trmc_cols in 61 60 56; do
  assert_eq 'T1 · standard · md-compact · all 2/4 agy 1/2 opus 1/2' "$(trmc_row "$trmc_cols")"
done
for trmc_cols in 55 50; do
  assert_eq 'T1 · standard · md-compact · all 2/4' "$(trmc_row "$trmc_cols")"
done
rm -f "$TR_STATS/progress/llm-legs__x-mc.json"
# The judge phase freezes the panel row at `✓ done` and puts the judge in a second row of the same
# content: `judge: <account> · <model> · <effort> · <hash> · <elapsed>`, shedding hash, effort, model,
# elapsed in that order; `SUBAGENT_JUDGE_ROW=inline` folds it back into the single row.
TR_REVIEWJ=20260917T130000Z-c0ffee1
TRJ_NOW=$(date +%s)
trj_doc() { # jq filter
  jq -cn --arg run "$TR_REVIEWJ" --argjson at "$((TRJ_NOW - 65))" '{run_id:$run,tier:"T0",composition:"double",lens:"bugs",state:"running",phase:"judge",
    cells:["agy-flash37-high#1","claude-opus-high#1"],done:["agy-flash37-high#1","claude-opus-high#1"],
    phase_at:$at,judge:{model:"opus",effort:"high",account:"locomthebest"}}' |
    jq -c "$1" > "$TR_STATS/progress/llm-legs__x-j.json"
}
trj_row() { # columns
  jq -cn --argjson cols "$1" --argjson start "$(( (TRJ_NOW - 245) * 1000 ))" --arg sess "$TR_RSESS" '{session_id:$sess,columns:$cols,
    tasks:[{id:"j1",type:"local_agent",status:"running",description:"x",startTime:$start,tokenCount:2400}]}' |
    WORKER_STATS_DIR="$TR_STATS" SUBAGENT_JUDGE_ROW="${TRJ_MODE:-}" "$RENDER_BIN" | jq -r '.content' |
    perl -pe 's/\e\[[0-9;]*m//g; s/1m [0-9]+s/1m 5s/; s/4m [4-9]s/4m 5s/'
}
printf 'T0 · double · bugs\nreview=%s\n' "$TR_REVIEWJ" > "$TR_HOME_CACHE/$TR_RSESS/j1"
trj_doc .
assert_eq 'T0 · double · bugs · all 2/2 agy ✓ opus ✓ · ✓ done · 3m 0s · ↓ 2.4k tok
judge: locomthebest · opus · high · c0ffee1 · 1m 5s' "$(trj_row 100)"
assert_eq 'T0 · double · bugs · all 2/2 agy ✓ opus ✓ · ✓ done
judge: locomthebest · opus · high · c0ffee1 · 1m 5s' "$(trj_row 54)"
assert_eq 'T0 · double · bugs · all 2/2 agy ✓ opus ✓ · ✓ done
judge: locomthebest · opus · high · 1m 5s' "$(trj_row 53)"
assert_eq 'T0 · double · bugs · all 2/2 · ✓ done
judge: locomthebest · opus · 1m 5s' "$(trj_row 43)"
assert_eq 'T0 · double · bugs · all 2/2 · ✓ done
judge: locomthebest · 1m 5s' "$(trj_row 35)"
assert_eq 'T0 · double · bugs · all 2/2 · ✓ done
judge: locomthebest' "$(trj_row 28)"
TRJ_MODE=inline
assert_eq 'T0 · double · bugs · judge: locomthebest · opus · high · c0ffee1 · 1m 5s · ↓ 2.4k tok' "$(trj_row 100)"
TRJ_MODE=
trj_doc 'del(.judge)'
assert_eq 'T0 · double · bugs · all 2/2 agy ✓ opus ✓ · ✓ done · 3m 0s · ↓ 2.4k tok
judge: c0ffee1 · 1m 5s' "$(trj_row 100)"
trj_doc '.judge = {account:"rawilimo"}'
assert_eq 'T0 · double · bugs · all 2/2 agy ✓ opus ✓ · ✓ done · 3m 0s · ↓ 2.4k tok
judge: rawilimo · c0ffee1 · 1m 5s' "$(trj_row 100)"
# No timestamp in the document: the first sighting of the phase is cached next to the tag.
rm -f "$TR_HOME_CACHE/$TR_RSESS/j1.judge"
trj_doc 'del(.phase_at)'
assert_eq 'T0 · double · bugs · all 2/2 agy ✓ opus ✓ · ✓ done · 4m 5s · ↓ 2.4k tok
judge: locomthebest · opus · high · c0ffee1 · 0s' "$(trj_row 100)"
assert test -s "$TR_HOME_CACHE/$TR_RSESS/j1.judge"
rm -f "$TR_HOME_CACHE/$TR_RSESS/j1.judge"
# Rows appear in sequence: no judge row before the judge phase, and it stays through the report.
trj_doc '.phase = "review" | .done = ["agy-flash37-high#1"]'
assert_eq 'T0 · double · bugs · all 1/2 agy ✓ opus 0/1 · 4m 5s · ↓ 2.4k tok' "$(trj_row 100)"
trj_doc '.state = "done" | .phase = "report" | .confirmed = 17'
assert_eq 'T0 · double · bugs · ✓ report 17 · 3m 0s · ↓ 2.4k tok
judge: locomthebest · opus · high · c0ffee1 · 1m 5s' "$(trj_row 100)"
rm -f "$TR_STATS/progress/llm-legs__x-j.json"
tr8_narrow=$(tr8_row 120)
assert grep -Fq ' · all 5/8 agy 2/4 ✗1 opus 1/2 sol ✓ · 5m 0s' <<<"$tr8_narrow"
assert_fails grep -Fq 'post-round delta' <<<"$tr8_narrow"
jq '.done += ["agy-flash37-high#2","agy-flash37-high#3"]' "$TR_STATS/progress/llm-legs__x-8.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-8.json"
assert grep -Fq ' · all 7/8 agy 4/4 ✗1 opus 1/2 sol ✓ · ' <<<"$(tr8_row 200)"
jq '.done = ["agy-flash37-high#1","claude-opus-low#1","claude-opus-low#2"] | .failed_cells = [] |
  .chunks = {"agy-flash37-high#1":[5,5],"agy-flash37-high#2":[2,5],"agy-flash37-high#3":[0,5],"agy-flash37-high#4":[0,5],
             "codex-sol-low#1":[3,5],"codex-sol-low#2":[0,5]}' "$TR_STATS/progress/llm-legs__x-8.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-8.json"
assert grep -Fq ' · all 3/8 agy 7/20 opus ✓ sol 3/10 · 5m 0s' <<<"$(tr8_row 200)"
# A group holding a late pending cell (the top statusline's rule) is red for the launching chat alone.
jq --arg sess "$TR_RSESS" --argjson began "$(( $(date +%s) - 400 ))" '.done = ["agy-flash37-high#1","claude-opus-low#1"] |
  .failed_cells = [] | del(.chunks) | .session = $sess | .started_epoch = $began |
  .expected = {"agy-flash37-high#2":50000,"claude-opus-low#2":200000}' "$TR_STATS/progress/llm-legs__x-8.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-8.json"
tr8_raw() { # session
  mkdir -p "$TR_HOME_CACHE/$1" && cp "$TR_HOME_CACHE/$TR_RSESS/r8" "$TR_HOME_CACHE/$1/r8"
  jq -cn --arg sess "$1" '{session_id:$sess,columns:200,tasks:[{id:"r8",type:"local_agent",status:"running",description:"x"}]}' |
    WORKER_STATS_DIR="$TR_STATS" "$RENDER_BIN" | jq -r '.content'
}
tr8_own=$(tr8_raw "$TR_RSESS")
assert grep -Fq "${RED}agy 1/4${RESET}" <<<"$tr8_own"
assert_eq 'T0 · double · bugs · all 2/8 agy 1/4 opus 1/2 sol 0/2' "$(perl -pe 's/\e\[[0-9;]*m//g' <<<"$tr8_own")"
assert_fails grep -Fq "${RED}opus" <<<"$tr8_own"
assert_fails grep -Fq "${RED}sol" <<<"$tr8_own"
assert_fails grep -Fq "$RED" <<<"$(tr8_raw tr-other)"
jq '.session = "tr-launcher" | .waiter = {session:"tr-other",task_id:"r8"}' "$TR_STATS/progress/llm-legs__x-8.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-8.json"
assert grep -Fq "${RED}agy 1/4${RESET}" <<<"$(tr8_raw tr-other)"
assert_fails grep -Fq "$RED" <<<"$(tr8_raw "$TR_RSESS")"
jq '.expected = {} | .started_epoch = 1' "$TR_STATS/progress/llm-legs__x-8.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-8.json"
assert_fails grep -Fq "$RED" <<<"$(tr8_raw tr-other)"
# A group whose cell's verifier runs says `verify` after its fraction and earns `✓` only once it is collected.
jq '.done = .cells | .failed_cells = [] | .phase = "verify" |
  .verifying = {"agy-flash37-high#1":"done","agy-flash37-high#2":"running","claude-opus-low#1":"done"}' \
  "$TR_STATS/progress/llm-legs__x-8.json" > "$TR_STATS/progress/tmp" && mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-8.json"
assert_eq 'T0 · double · bugs · all 8/8 agy 4/4 verify opus ✓ sol ✓ · 5m 0s' "$(tr8_row 200)"
jq '.verifying["agy-flash37-high#2"] = "done"' "$TR_STATS/progress/llm-legs__x-8.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-8.json"
assert_eq 'T0 · double · bugs · all 8/8 agy ✓ opus ✓ sol ✓ · 5m 0s' "$(tr8_row 200)"
jq 'del(.verifying)' "$TR_STATS/progress/llm-legs__x-8.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-8.json"
assert_eq 'T0 · double · bugs · all 8/8 agy ✓ opus ✓ sol ✓ · 5m 0s' "$(tr8_row 200)"
rm -f "$TR_STATS/progress/llm-legs__x-8.json"
# Review end states.
jq '.state = "done" | .confirmed = 17' "$TR_STATS/progress/llm-legs__x-1.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-1.json"
assert grep -Fq '· ✓ report 17 ·' <<<"$(tr_row "$(tr_render 300)" r1)"
jq '.state = "running" | .phase = "judge"' "$TR_STATS/progress/llm-legs__x-1.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-1.json"
tr_judge=$(tr_row "$(tr_render 300)" r1)
assert grep -Fq '· ✓ done ·' <<<"$tr_judge"
assert grep -q '^judge: ' <<<"$(sed -n 2p <<<"$tr_judge")"
jq '.state = "dead"' "$TR_STATS/progress/llm-legs__x-1.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-1.json"
assert grep -Fq '· ✗ dead ·' <<<"$(tr_row "$(tr_render 300)" r1)"
jq '.state = "cancelled"' "$TR_STATS/progress/llm-legs__x-1.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-1.json"
assert_eq 'T2 · double · task — hunt over the task rows · 1m 5s · ↓ 500 tok' "$(tr_row "$(tr_render 300)" r1)"
jq '.state = "dead"' "$TR_STATS/progress/llm-legs__x-1.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-1.json"
# A document with no tier keeps the `T?` default through the sanitizer.
jq '.tier = null' "$TR_STATS/progress/llm-legs__x-1.json" > "$TR_STATS/progress/tmp" &&
  mv "$TR_STATS/progress/tmp" "$TR_STATS/progress/llm-legs__x-1.json"
assert grep -Fq 'T? · double · task — hunt over the task rows · ' <<<"$(tr_row "$(tr_render 300)" r1)"
printf '%s' "$(worker_payload review-waiter waiterT 'Wait' "review-bench wait $TR_REVIEW --max 540" tr-rev)" |
  WORKER_STATS_DIR="$TR_STATS" "$WORKER_HOOK" >/dev/null
assert_eq 'T? · double · task' "$(head -n1 "$TR_HOME_CACHE/tr-rev/waiterT")"
tr_waiter_tierless=$(WORKER_STATS_DIR="$TR_STATS" tr_spawn tr-rev-tierless review-waiter "WAIT $TR_REVIEW: hunt") ||
  fail "review-waiter spawn exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description | startswith("T? · double · task: ")' <<<"$tr_waiter_tierless" >/dev/null
# A review whose progress document is gone keeps the tag it had.
rm -f "$TR_STATS/progress/llm-legs__x-1.json"
assert_eq 'T2 · double · task — hunt over the task rows · 1m 5s · ↓ 500 tok' "$(tr_row "$(tr_render 300)" r1)"

# A finished review whose report was taken is consumed: the line-1 review segment lets it go even
# though review-bench keeps the document (phase report, its write lock beside it) for the task row.
progress_doc done-reported "$$" T2 8 8 done 0
jq '.phase = "report" | .confirmed = 3' "$PROGRESS_DIR/${progress_prefix}state-done-reported.json" > "$WORK/tr-reported.json" &&
  mv "$WORK/tr-reported.json" "$PROGRESS_DIR/${progress_prefix}state-done-reported.json"
: > "$PROGRESS_DIR/${progress_prefix}state-done-reported.json.lock"
assert grep -Fq " ${DIM}│${RESET} ${DIM}T2 ✓ 8/8${RESET}" <<< "$(progress_render state-done-unreported)"
mkdir -p "$CLAUDEB_FIX/worker-stats/benches/progress-state-fixture"
printf '{"reported_at":"2026-09-16T23:49:16+00:00"}\n' > "$CLAUDEB_FIX/worker-stats/benches/progress-state-fixture/reported.json"
assert review_slot_silent "$(progress_render state-done-reported)"
rm -rf "$CLAUDEB_FIX/worker-stats/benches/progress-state-fixture" "$PROGRESS_DIR/${progress_prefix}state-done-reported.json.lock"
progress_doc_clear

# A payload whose tasks carry no status field is a running list (the harness omits the field on older builds).
no_status=$(printf '{"session_id":"x","columns":80,"tasks":[{"id":"ns1","type":"local_agent","description":"acc · astra · high: No status","startTime":1789600000000}]}' | bash "$RENDER_BIN")
assert grep -q 'acc · astra · high' <<<"$no_status"
echo "PASS: $asserts asserts; workdir tracking, worktree/agent filtering, statusline segments, a review slot that carries a run over the shown tree, an ATOMIC middle block computed from ONE shown tree — the tree of the last line of this chat's place journal — a counter that is this chat's own run alone — its tier, its state as a mark and its cells — and one rendered form for every state the gate's debt line can name, the verdict asked about the shown tree, keyed on the checkout family's commit journal and review decision clock, this chat's own unread lines and nobody else's, with every unknown the known number followed by its dim \`?<why>\`, keyed on the commit journal and asked once per key with nothing else probed behind it, an unpushed marker that is the same gate's \`unpushed\` answer word for word — never dimmed, never shown for a branch level with its upstream or for commits the gate names none of, silent with no gate to ask, and re-asked the moment the FAMILY's debt journal that decides whose the commit is moves — main-last and Gemini account predictions, and Codex/claudeb/Gemini/grok worker tag propagation with the bare-launch gate that denies the spellings they replace, image-gen rows tagged account·short-model from the launch line with gen/edit/exit states and fan-out cells, task rows painted for every agent with run/review/light state fitted to the columns, native agent spawns refused but fork, Monitor and chat-Bash waits refused, an explicit-vendor pin hidden only by that vendor's ABSENCE from a loaded pick line and never by a field that is merely unusable, and a run's start/wait reserved to the relay agent that owns it through every wrapper, keyword and sh -c string that spells one, while a read-only report and a heredoc body quoting the spelling are not gated"
