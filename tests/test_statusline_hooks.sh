#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# shards: 3
set -u
unset WORKER_PICK_CONFIG_FILE WORKER_RUN_CONFIG_FILE CLAUDEB_WORKER

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/share/test-scope.sh"
PROJECTS=$(git_projects "$ROOT")
WORKDIR_HOOK="$ROOT/bin/statusline-workdir-hook.sh"
WORKER_HOOK="$ROOT/bin/worker-tag-hook.sh"
SPAWN_HOOK="$ROOT/bin/worker-spawn-hook.sh"
STATUSLINE="$ROOT/bin/statusline.sh"
WORK="$(mktemp -d)"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
# Renders leave detached probes writing into $WORK for a moment; a shard can end right behind them.
trap 'for _ in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$WORK" 2>/dev/null && break; sleep 0.3; done' EXIT
asserts=0

fail() { echo "FAIL: $*" >&2; exit 1; }
here_fq() { local text; IFS= read -r -d '' text; [[ $text == *"$1"* ]]; }
is_here_fq() { [ "$#" = 3 ] && [ "$1" = grep ] && [ "$2" = -Fq ] && [[ $3 != *$'\n'* ]]; }
assert() {
  asserts=$((asserts + 1))
  if is_here_fq "$@"; then here_fq "$3"; else "$@"; fi || fail "assert $asserts failed: $*"
}
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts failed: expected '$1', got '$2'"
}

if suite_shard_owns 1 cg-identity; then
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
fi

HOME="$WORK/home"
FIXTURES="$WORK/fixtures"
TMPDIR="$WORK/runtime-tmp"
CLAUDEB_FIX="$WORK/claudeb"
export HOME TMPDIR
unset HARNESS_DOCTOR_DIR SPEED_DOCTOR_DIR CLAUDEB_DIR
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
# The convention under test: worktrees live at <repo>/.claude/worktrees/<name>,
# git-excluded so they never count as untracked content of the parent repo.
printf '.claude/worktrees/\n' >> "$REPO_A/.git/info/exclude"
REPO_E="$REPO_A/.claude/worktrees/feature-y"
git -C "$REPO_A" worktree add -q -b feature-y "$REPO_E"
REPO_F="$REPO_A/.claude/worktrees/auto-slug"
REPO_J="$REPO_A/.claude/worktrees/wut-25-portal"
git -C "$REPO_A" worktree add -q -b WUT-259_feat_portal-fixes "$REPO_J"
REPO_L="$REPO_A/.claude/worktrees/WUT-12345-fix-header"
REPO_M="$REPO_A/.claude/worktrees/WUT_12345-fix"
REPO_G="$FIXTURES/repo-g"
REPO_H="$REPO_G/.claude/worktrees/sep-work"
REPO_K="$FIXTURES/repo-detached"
# Shard-local fixtures: built by the first section of a shard that reads them.
fixture_repos_cfgh() {
  [ -z "${TOP_H:-}" ] || return 0
  git -C "$REPO_A" worktree add -q --detach "$REPO_C"
  git -C "$REPO_A" worktree add -q -b claude/agitated-fixture "$REPO_F"
  # A repository whose git dir lives outside the checkout: `<common>/..` is NOT the
  # main worktree, so the canonical-location check must ask git, not strip `/.git`.
  mkdir -p "$REPO_G"
  git -C "$REPO_G" init -q --separate-git-dir "$FIXTURES/repo-g-gitdir" -b main
  printf 'sep\n' > "$REPO_G/tracked.txt"
  git -C "$REPO_G" add tracked.txt
  git -C "$REPO_G" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
  printf '.claude/worktrees/\n' >> "$FIXTURES/repo-g-gitdir/info/exclude"
  git -C "$REPO_G" worktree add -q -b sep-work "$REPO_H"
  TOP_C=$(git -C "$REPO_C" rev-parse --show-toplevel)
  TOP_F=$(git -C "$REPO_F" rev-parse --show-toplevel)
  TOP_H=$(git -C "$REPO_H" rev-parse --show-toplevel)
}
fixture_repos_klm() {
  [ -z "${SHORT_SHA:-}" ] || return 0
  git -C "$REPO_A" worktree add -q -b wut-12345-fix "$REPO_L"
  git -C "$REPO_A" worktree add -q -b wut_12345-fix "$REPO_M"
  mkdir -p "$REPO_K"
  git -C "$REPO_K" init -q -b main
  printf 'det\n' > "$REPO_K/tracked.txt"
  git -C "$REPO_K" add tracked.txt
  git -C "$REPO_K" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
  git -C "$REPO_K" checkout -q --detach
  TOP_K=$(git -C "$REPO_K" rev-parse --show-toplevel)
  SHORT_SHA=$(git -C "$REPO_K" rev-parse --short HEAD)
}
REPO_D="$FIXTURES/repo-d"
mkdir -p "$REPO_D"
git -C "$REPO_D" init -q -b main
printf 'other\n' > "$REPO_D/other.txt"
git -C "$REPO_D" add other.txt
git -C "$REPO_D" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
ln -s "$REPO_B" "$HOME/project"
TOP_A=$(git -C "$REPO_A" rev-parse --show-toplevel)
TOP_B=$(git -C "$REPO_B" rev-parse --show-toplevel)
TOP_D=$(git -C "$REPO_D" rev-parse --show-toplevel)
TOP_E=$(git -C "$REPO_E" rev-parse --show-toplevel)
TOP_J=$(git -C "$REPO_J" rev-parse --show-toplevel)

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
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
  printf '%(%s)T\t%s\t%s\t%s\n' -1 "${4:-seed}" "$2" "${3:-$2}" >> "$STATE_DIR/place-$1"
}
place_field() { # session field -> `tail -n 1 | cut -f<field>` of the place journal
  local line='' next i
  while IFS= read -r next || [ -n "$next" ]; do line=$next; done 2>/dev/null < "$STATE_DIR/place-$1"
  if [[ $line == *$'\t'* ]]; then
    for ((i = 1; i < $2; i++)); do
      [[ $line == *$'\t'* ]] || { line=; break; }
      line=${line#*$'\t'}
    done
    line=${line%%$'\t'*}
  fi
  printf '%s\n' "$line"
}
last_tree() { place_field "$1" 3; }
last_kind() { place_field "$1" 2; }
place_count() { # session -> `wc -l` of its place journal, 0 when absent
  local n=0 line
  [ ! -f "$STATE_DIR/place-$1" ] || while IFS= read -r line; do n=$((n + 1)); done < "$STATE_DIR/place-$1"
  echo "$n"
}

if suite_shard_owns 1 workdir-hook; then
fixture_repos_cfgh
# Every write the hook makes goes to the session cache under $HOME, which these
# cases redirect; a hardcoded absolute redirect (a debug probe left in) escapes
# the sandbox entirely and no behavioural case below can see it.
assert_eq "" "$(grep -nE '(^|[[:space:]])>>?[[:space:]]*/' "$WORKDIR_HOOK" | grep -v '/dev/null')"

# bash's `read` takes a pipe one byte per syscall: an 8 MB Write response cost ~8 s that way. A file
# it reads in chunks, so the same payload from a file is the baseline; CPU, since load stretches wall time.
head -c 8000000 /dev/zero | tr '\0' x > "$WORK/big-response"
workdir_payload Write session-big "$REPO_A" "$REPO_A/big.txt" \
  | jq -c --rawfile big "$WORK/big-response" '.tool_response = {content: $big}' > "$WORK/big-payload"
big_file_cpu=$("$WORKDIR_HOOK" < "$WORK/big-payload"; suite_journal_cpu_ms c "$WORK/big-times" children; echo "$c")
big_pipe_cpu=$(cat "$WORK/big-payload" | "$WORKDIR_HOOK"; suite_journal_cpu_ms c "$WORK/big-times" children; echo "$c")
[ -n "$big_file_cpu" ] && [ -n "$big_pipe_cpu" ] && [ "$big_pipe_cpu" -lt $(( 3 * big_file_cpu )) ] ||
  fail "workdir hook took ${big_pipe_cpu} CPU ms on an 8 MB payload from a pipe, ${big_file_cpu} from a file"
assert_eq "$TOP_A" "$(last_tree session-big)"

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
last_main() { place_field "$1" 4; }
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
place_case place-unknown-then-abs "cd \$NOWHERE; cd - && cd '$REPO_B' && git commit -m m"
assert_eq "$TOP_B" "$(last_tree place-unknown-then-abs)"

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

# A failed compound command does not prove which mutation, if any, ran.
place_set place-failure "$TOP_A"
run_workdir_hook "$(workdir_payload Bash place-failure "$REPO_A" \
  "git -C '$REPO_B' commit --allow-empty -m x && false" |
  jq -c '.hook_event_name = "PostToolUseFailure" | .error = "Exit code 1"')"
assert_eq "$TOP_A" "$(last_tree place-failure)"

for command in "cd '$REPO_B' && make > /tmp/build.log" "cd '$REPO_B' && mkdir -p /tmp/scratch" \
  "git -C '$REPO_B' apply /tmp/fix.patch" "git --git-dir '$REPO_B/.git' -C '$REPO_B' commit -m x" \
  "git -C '$REPO_A' commit -m \"fix #123\" && git -C '$REPO_B' push" \
  "echo \"note #1\" > '$REPO_B/out.txt'" \
  "git -C '$REPO_B' branch -r -d origin/gone" "git -C '$REPO_B' branch -v -D topic" \
  "git -C '$REPO_B' branch -m old new"; do
  place_case place-regression-write "$command"
  assert_eq "$TOP_B" "$(last_tree place-regression-write)"
done
for command in 'git branch --show-current' 'git branch --all' 'git branch' 'git tag -n' 'git tag --list' 'git fetch --dry-run' \
  "(cd '$REPO_B' && true); git add file" \
  "W='$REPO_B' true; touch \"\$W/file\""; do
  place_case place-regression-read "$command"
  assert_eq "$TOP_A" "$(last_tree place-regression-read)"
done
place_case place-tag-create "git -C '$REPO_B' tag -a release -m label"
assert_eq "$TOP_B" "$(last_tree place-tag-create)"
place_set place-skipped "$TOP_A"
run_workdir_hook "$(workdir_payload Bash place-skipped "$REPO_A" "false && git -C '$REPO_B' commit -m x" |
  jq -c '.hook_event_name = "PostToolUseFailure" | .error = "Exit code 1"')"
assert_eq "$TOP_A" "$(last_tree place-skipped)"

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

# Only a `worktree add|move` makes a PreToolUse Bash call worth a parse: any other command leaves
# before jq starts, while the worktree form and an Agent dispatch still parse.
PRE_JQ_BIN="$WORK/pre-jq-bin" PRE_JQ_LOG="$WORK/pre-jq.log"
mkdir -p "$PRE_JQ_BIN"
printf '#!/bin/sh\necho jq >> "%s"\nexec %s "$@"\n' "$PRE_JQ_LOG" "$(command -v jq)" > "$PRE_JQ_BIN/jq"
chmod +x "$PRE_JQ_BIN/jq"
pre_jq_runs() { # payload -> jq starts
  : > "$PRE_JQ_LOG"
  printf '%s' "$1" | PATH="$PRE_JQ_BIN:$PATH" "$WORKDIR_HOOK" >/dev/null 2>&1
  wc -l < "$PRE_JQ_LOG" | tr -d ' '
}
assert_eq 0 "$(pre_jq_runs "$(workdir_payload Bash session-pre-plain "$REPO_E" "git -C '$REPO_A' status" |
  jq -c '.hook_event_name = "PreToolUse"')")"
assert test ! -e "$STATE_DIR/place-session-pre-plain.snap"
assert_eq 1 "$(pre_jq_runs "$(workdir_payload Bash session-pre-wt "$REPO_E" "$VAR_CMD" |
  jq -c '.hook_event_name = "PreToolUse"')")"
assert test -f "$STATE_DIR/place-session-pre-wt.snap"
rm -f "$STATE_DIR/place-session-pre-wt.snap"
assert_eq 1 "$(pre_jq_runs "$(jq -cn --arg cwd "$REPO_A" '{hook_event_name:"PreToolUse",tool_name:"Agent",
  session_id:"session-pre-agent",cwd:$cwd,tool_input:{prompt:"run \"tool_name\": \"Bash\" there"}}')")"

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
# ownership is the family's review-anchors.json's now, so nothing may write that file back: it had no reader, and
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
fi
assert_fails() {
  asserts=$((asserts + 1))
  if is_here_fq "$@"; then ! here_fq "$3"; else ! "$@" >/dev/null 2>&1; fi || fail "assert $asserts should have failed: $*"
}
if suite_shard_owns 1 place-journal; then
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

fi
statusline_payload() {
  local extra="${2-}"
  local cwd="${3:-$REPO_A}"
  [ -n "$extra" ] || extra='{}'
  if [ "$extra" = '{}' ] && [[ $1$cwd != *[!\ -~]* && $1$cwd != *[\"\\]* ]]; then
    printf '{"session_id":"%s","cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"display_name":"Fixture"},"effort":{"level":"high"},"context_window":{"used_percentage":12,"current_usage":{"input_tokens":1000}}}\n' \
      "$1" "$cwd" "$cwd" "$cwd"
    return
  fi
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
    COLUMNS="${FIT_COLUMNS:-}" STATUSLINE_FIT_MARGIN="${FIT_MARGIN:-3}" \
    CHAT_PINS_DIR="$CHAT_PINS_DIR" \
    LLM_LIMITS_FILE="$WORK/limits.json" STATUSLINE_PS=true STATUSLINE_LSOF=true \
    STATUSLINE_STORE_MERGE_CMD="${STORE_MERGE_CMD:-/usr/bin/true}" \
    STATUSLINE_CODEX_REFRESH_CMD="${CODEX_REFRESH_CMD:-/usr/bin/true}" \
    STATUSLINE_REVIEW_GATE="${GATE_CMD:-}" STATUSLINE_REVIEW_DEBT="${DEBT_CMD:-}" \
    env ${NO_TIMEOUT_BIN:+STATUSLINE_TIMEOUT_BIN=} "$STATUSLINE"
}


if suite_shard_owns 1 render-limits; then
fixture_repos_cfgh
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
# `env bash` may resolve to macOS bash 3.2 (/bin before Homebrew); the render hands itself to bash 5.
printf '#!/bin/sh\nexec /bin/bash "%s"\n' "$STATUSLINE" > "$WORK/statusline-bash32"
chmod +x "$WORK/statusline-bash32"
cg32_out=$(STATUSLINE="$WORK/statusline-bash32" CLAUDEGPT_ACCOUNT=work4 run_statusline "$cg_payload")
assert grep -Fq '36%' <<< "$cg32_out"
assert grep -Fq '22%' <<< "$cg32_out"
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
cp "$WORK/limits.json" "$WORK/cg-limits-kept.json"
jq --argjson now "$cg_now" '.vendors.codex.accounts[0].as_of = ($now - 19 * 3600 - 600 | todateiso8601)' \
  "$WORK/cg-limits-kept.json" > "$WORK/limits.json"
cg_stale=$(CLAUDEGPT_ACCOUNT=work4 run_statusline "$cg_payload")
assert grep -Fq "${RED}stale 19h10m${RESET}" <<< "$(sed -n '2p' <<< "$cg_stale")"
jq --argjson now "$cg_now" '.vendors.codex.accounts[0].as_of = ($now - 600 | todateiso8601)' \
  "$WORK/cg-limits-kept.json" > "$WORK/limits.json"
cg_recent=$(CLAUDEGPT_ACCOUNT=work4 run_statusline "$cg_payload")
assert test "${cg_recent#*stale}" = "$cg_recent"
jq --argjson now "$cg_now" '.vendors.claude.accounts = [{account:"stalefab", as_of:($now - 19 * 3600 | todateiso8601),
    fable:{used_pct:5,effective_pct:5,stale:true,resets_at:($now + 86400 | todateiso8601)}}]' \
  "$WORK/cg-limits-kept.json" > "$WORK/limits.json"
fab_stale=$(run_statusline "$(statusline_payload stale-fable '{"model":{"id":"claude-fable-5","display_name":"Fable 5"}}')" stalefab)
assert grep -Fq "${RED}stale 19h${RESET}" <<< "$(sed -n '2p' <<< "$fab_stale")"
mv "$WORK/cg-limits-kept.json" "$WORK/limits.json"
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

# An unborn branch (`branch.oid (initial)`, no commit yet) is still a named branch: never a bare `@`.
UNBORN_REPO="$FIXTURES/unborn-repo"
git init -q -b fresh-start "$UNBORN_REPO"
place_set status-unborn "$(git -C "$UNBORN_REPO" rev-parse --show-toplevel)"
unborn_output=$(run_statusline "$(statusline_payload status-unborn)") || fail "statusline unborn repo failed"
assert grep -Fq '⎇ fresh-start' <<< "$unborn_output"
assert test "${unborn_output#*"${RED}@"}" = "$unborn_output"

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

fi
printf '{}' > "$WORK/limits.json"
if suite_shard_owns 2 render-branch; then
fixture_repos_klm
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
fi
worker_file="$HOME/.claude/worker-model"
if suite_shard_owns 2 render-pins; then
fixture_repos_klm
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

write_chat_pin status-pin-all 'open=all'
pin_out=$(run_statusline "$(statusline_payload status-pin-all)")
assert grep -Fq "${MAGENTA}all${RESET}" <<< "$pin_out"

# A `<vendor>_fast=on` line beside the pin marks the label and nothing else; a fast line the pin
# does not name is not this vendor's.
printf 'grok_profile=*\ngrok_fast=on\n' > "$CHAT_PINS_DIR/status-pin-fast-grok"
pin_out=$(run_statusline "$(statusline_payload status-pin-fast-grok)")
assert grep -Fq "${MAGENTA}grok⚡${RESET}" <<< "$pin_out"

printf 'codex_profile=alt\ncodex_fast=on\n' > "$CHAT_PINS_DIR/status-pin-fast-acct"
pin_out=$(run_statusline "$(statusline_payload status-pin-fast-acct)")
assert grep -Fq "${MAGENTA}alt⚡${RESET}" <<< "$pin_out"

printf 'grok_profile=*\ncodex_fast=on\n' > "$CHAT_PINS_DIR/status-pin-fast-other"
pin_out=$(run_statusline "$(statusline_payload status-pin-fast-other)")
assert grep -Fq "${MAGENTA}grok${RESET}" <<< "$pin_out"
assert test "${pin_out#*⚡}" = "$pin_out"

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
# step: cost, then the reset labels short, then gone, then separators, then the ctx percentage — the
# tokens part outlives it, since its colour is how Egor reads the cache state (Egor, 2026-10-05).
assert_eq 73 "$fit_full2_len"
fit_l2_keep=$(fit_line2 "$(fit_render fit-l2-keep 76)")
assert_eq "$fit_full2" "$fit_l2_keep"
fit_l2_step1=$(fit_line2 "$(fit_render fit-l2-step1 75)")
assert_eq "ctx 12% ? 1k │ 5h 44% $fit_h5_time │ wk 22% $fit_wk_label │ fb 55% $fit_fb_label" "$fit_l2_step1"
fit_l2_step2=$(fit_line2 "$(fit_render fit-l2-step2 67)")
assert_eq "ctx 12% ? 1k │ 5h 44% ${fit_h5_time%%:*}h │ wk 22% ${fit_wk_label%% *} │ fb 55% ${fit_fb_label%% *}" "$fit_l2_step2"
fit_l2_step3=$(fit_line2 "$(fit_render fit-l2-step3 53)")
assert_eq "ctx 12% ? 1k │ 5h 44% │ wk 22% │ fb 55%" "$fit_l2_step3"
fit_l2_step4=$(fit_line2 "$(fit_render fit-l2-step4 41)")
assert_eq "ctx 12% ? 1k 5h 44% wk 22% fb 55%" "$fit_l2_step4"
fit_l2_step5=$(fit_line2 "$(fit_render fit-l2-step5 35)")
assert_eq "ctx ? 1k 5h 44% wk 22% fb 55%" "$fit_l2_step5"
fit_l2_floor=$(fit_line2 "$(fit_render fit-l2-floor 12)")
assert_eq "ctx ? 1k 5h 44% wk 22% fb 55%" "$fit_l2_floor"

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

# Steps 6, 8, 10 and 11: the account to 4 with the initials, the pin, the directory itself, the
# account to 3 — and never shorter than 3, however narrow.
fit_step6=$(fit_render fit-step6 44)
assert grep -Fq 'FB5 xhi fita │ fbp WUT-421 3/0 │ a' <<< "$fit_step6"
fit_step8=$(fit_render fit-step8 36)
assert test "${fit_step8#*"│ a"}" = "$fit_step8"
assert grep -Fq 'fita │ fbp' <<< "$fit_step8"
fit_step10=$(fit_render fit-step10 32)
assert test "${fit_step10#*fbp}" = "$fit_step10"
assert grep -Fq 'FB5 xhi fita │ WUT-421' <<< "$fit_step10"
fit_step11=$(fit_render fit-step11 28)
assert grep -Fq 'FB5 xhi fit │ WUT-421' <<< "$fit_step11"
fit_floor=$(fit_render fit-floor 15)
assert grep -Fq 'FB5 xhi fit │ WUT-421' <<< "$fit_floor"

# Steps 9 and 10 on the `»` pair: both sides share the cut, then wear initials with the arrow's
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

# Initials longer than the 8-character cut would make step 6 GROW the line, and the directory
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

# A usage reset lowers the week without moving its resets_at, so an idle chat replaying its
# pre-reset 100 looks "higher in the same window" and re-walls the account until the week ends
# (claude/locomthebest, 2026-10-06 13:18). While llm-reset-redeem's marker stands only a reading
# that followed spend AFTER the reset is taken, whatever its percentage.
reset_week=$((NOW + 300000))
seed_reset_cache() {
  jq -cn --argjson now "$NOW" --argjson wk "$reset_week" --argjson pct "$1" '
    {five_hour:{used_percentage:0,resets_at:0,as_of:($now-30),origin:"usage"},
     seven_day:{used_percentage:$pct,resets_at:$wk,as_of:($now-30),origin:"usage"},
     auth:{status:"ok",checked_at:$now}}' > "$CLAUDEB_FIX/limits/resetacct.json"
}
reset_rl() { printf '{"seven_day":{"used_percentage":%s,"resets_at":%s}}' "$1" "$reset_week"; }
printf '%s\n' "$((NOW - 60))" > "$CLAUDEB_FIX/limits/resetacct.reset-at"
mkdir -p "$STATE_DIR"
# Spend made before the reset and never merged must not pass for liveness after it.
printf '3.0\n' > "$STATE_DIR/rl-cost-status-prereset"
touch -t "$(date -r "$((NOW - 3600))" +%Y%m%d%H%M.%S)" "$STATE_DIR/rl-cost-status-prereset"
seed_reset_cache 0
run_statusline "$(statusline_payload status-prereset "{\"cost\":{\"total_cost_usd\":3.5},\"rate_limits\":$(reset_rl 100)}")" resetacct \
  >/dev/null || fail "statusline pre-reset replay merge failed"
assert jq -e '.seven_day.used_percentage == 0 and .seven_day.origin == "usage"' \
  "$CLAUDEB_FIX/limits/resetacct.json" >/dev/null
assert_eq "3.5" "$(cat "$STATE_DIR/rl-cost-status-prereset")"
# The same chat's first call after the reset is believed.
run_statusline "$(statusline_payload status-prereset "{\"cost\":{\"total_cost_usd\":3.75},\"rate_limits\":$(reset_rl 4)}")" resetacct \
  >/dev/null || fail "statusline post-reset merge failed"
assert jq -e '.seven_day.used_percentage == 4 and .seven_day.origin == "session"' \
  "$CLAUDEB_FIX/limits/resetacct.json" >/dev/null
# A stale 100 already in the cache gives way to a live post-reset reading below it.
seed_reset_cache 100
printf '1.0\n' > "$STATE_DIR/rl-cost-status-postreset"
run_statusline "$(statusline_payload status-postreset "{\"cost\":{\"total_cost_usd\":1.2},\"rate_limits\":$(reset_rl 3)}")" resetacct \
  >/dev/null || fail "statusline live post-reset merge failed"
assert jq -e '.seven_day.used_percentage == 3' "$CLAUDEB_FIX/limits/resetacct.json" >/dev/null
# An idle replay of that chat writes nothing while the marker stands.
run_statusline "$(statusline_payload status-postreset "{\"cost\":{\"total_cost_usd\":1.2},\"rate_limits\":$(reset_rl 100)}")" resetacct \
  >/dev/null || fail "statusline idle post-reset merge failed"
assert jq -e '.seven_day.used_percentage == 3' "$CLAUDEB_FIX/limits/resetacct.json" >/dev/null
# A marker older than any week lapses: the monotone same-window rule is back.
printf '%s\n' "$((NOW - 700000))" > "$CLAUDEB_FIX/limits/resetacct.reset-at"
seed_reset_cache 0
run_statusline "$(statusline_payload status-postreset "{\"cost\":{\"total_cost_usd\":1.2},\"rate_limits\":$(reset_rl 40)}")" resetacct \
  >/dev/null || fail "statusline lapsed-marker merge failed"
assert jq -e '.seven_day.used_percentage == 40' "$CLAUDEB_FIX/limits/resetacct.json" >/dev/null

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
printf -v big_pad '%65536s' ''
yes '{"type":"attachment","timestamp":"'"$(iso_utc $((NOW - 900)))"'","uuid":"pad","pad":"'"${big_pad// /x}"'"}' \
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

# Re-stamped: under load the suite can reach here minutes after NOW was taken, and a 5m cache
# would already read as dead.
NOW=$(date +%s)

t_reset; t_assist $((NOW - 30)) fixmodel 100000 500 5m; t_stamp ctx-bk5
bk5_out=$(run_statusline "$(statusline_payload ctx-bk5 "$(warm_extra "$TRANSCRIPT" 20 100000)")")
bk5_death=$(TZ=Europe/Kyiv date -r $((NOW - 30 + 300)) +%H:%M)
assert grep -Fq "${DIM}→${bk5_death}${RESET}${YELLOW}↓5m${RESET}" <<< "$bk5_out"
assert test "${bk5_out#*100k}" = "$bk5_out"
# The death time is the tokens part and the cache warning an alarm: both outlive the ctx percentage,
# down to the line-2 floor.
bk5_fit=$(FIT_COLUMNS=45 run_statusline "$(statusline_payload ctx-bk5 "$(warm_extra "$TRANSCRIPT" 20 100000)")")
assert grep -Fq "ctx ${GREEN}20%${RESET} ${DIM}→${bk5_death}${RESET}${YELLOW}↓5m${RESET}" <<< "$bk5_fit"
for bk5_cols in 30 12; do
  bk5_fit=$(FIT_COLUMNS=$bk5_cols run_statusline "$(statusline_payload ctx-bk5 "$(warm_extra "$TRANSCRIPT" 20 100000)")")
  assert grep -Fq "ctx ${DIM}→${bk5_death}${RESET}${YELLOW}↓5m${RESET} 5h" <<< "$bk5_fit"
done

t_reset; t_assist $((NOW - 30)) fixmodel 100000 500 mixed; t_stamp ctx-mixed
mixed_out=$(run_statusline "$(statusline_payload ctx-mixed "$(warm_extra "$TRANSCRIPT" 20 100000)")")
assert grep -Fq "${DIM}→${bk5_death}${RESET}${YELLOW}↓5m${RESET}" <<< "$mixed_out"

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
rm -f "$STATE_DIR"/cache-ttl-track-*
: > "$TRANSCRIPT"
RUN_STATUSLINE_DEFAULT_ACCOUNT=

# --- store merge-kick (bin/statusline.sh) ---
KICK_STAMP="$STATE_DIR/store-merge-kick"
KICK_LOCK="$STATE_DIR/store-merge-kick.lock"
KICK_MARK="$WORK/kick-marker"
KICK_CACHE="$CLAUDEB_FIX/limits/kickacct.json"
kick_reset() { rm -f "$KICK_STAMP" "$KICK_MARK" "$KICK_CACHE"; rmdir "$KICK_LOCK" 2>/dev/null || true; }
wait_for_mark() { local i; for i in $(seq 1 60); do [ -f "$KICK_MARK" ] && return 0; sleep 0.05; done; return 1; }

FAKE_COLLECTOR="$FIXTURES/fake-collector"
printf '#!/usr/bin/env bash\nprintf ran >> "%s"\n' "$KICK_MARK" > "$FAKE_COLLECTOR"
chmod +x "$FAKE_COLLECTOR"
FAIL_COLLECTOR="$FIXTURES/fail-collector"
printf '#!/usr/bin/env bash\nprintf boom >&2\nexit 2\n' > "$FAIL_COLLECTOR"
chmod +x "$FAIL_COLLECTOR"
SLOW_COLLECTOR="$FIXTURES/slow-collector"
printf '#!/usr/bin/env bash\nsleep 10\nprintf slow >> "%s"\n' "$KICK_MARK" > "$SLOW_COLLECTOR"
chmod +x "$SLOW_COLLECTOR"

# The kick only fires in the fresh-headers write branch: a pinned account with
# rate_limits present in the render payload.
kick_payload=$(statusline_payload status-kick \
  '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":'"$((NOW + 3600))"'}}}')

# A: absent stamp -> stamp written synchronously and the collector runs.
kick_reset
kick_out=$(SPEED_DOCTOR_DIR="$WORK/speed-doctor" STORE_MERGE_CMD="$FAKE_COLLECTOR" run_statusline "$kick_payload" kickacct) \
  || fail "statusline kick render failed"
assert grep -Fq 'Fixture' <<< "$kick_out"
assert test -f "$KICK_STAMP"
assert wait_for_mark
assert_eq ran "$(cat "$KICK_MARK")"
# Each kick journals `start_us<TAB>wall_ms<TAB>cpu_ms` under ${SPEED_DOCTOR_DIR:-~/.cache/speed-doctor}/merge-kick/.
kick_journal="$WORK/speed-doctor/merge-kick/$(date +%Y-%m-%d).tsv"
for _ in $(seq 1 60); do [ -s "$kick_journal" ] && break; sleep 0.05; done
assert_eq 1 "$(wc -l < "$kick_journal" | tr -d ' ')"
assert grep -Eq $'^[0-9]{16}\t[0-9]+\t[0-9]+$' "$kick_journal"
IFS=$'\t' read -r _ _ kick_cpu < "$kick_journal"
assert test "$kick_cpu" -gt 0

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
# Slept 10 s: a render under machine load can take seconds, never the collector's ten.
assert test "$(( $(date +%s) - kick_start ))" -lt 8

# E: the collector runs as a background job, never as the chat or worker run whose render kicked it
# (share/time_budget.py charges a store-lock wait to whoever its wait row names).
kick_reset
ENV_COLLECTOR="$FIXTURES/env-collector"
printf '#!/usr/bin/env bash\nprintf "%%s|%%s" "${CLAUDE_CODE_SESSION_ID:-}" "${WORKER_RUN_ID:-}" >> "%s"\n' "$KICK_MARK" \
  > "$ENV_COLLECTOR"
chmod +x "$ENV_COLLECTOR"
CLAUDE_CODE_SESSION_ID=sess-1 WORKER_RUN_ID=run-1 STORE_MERGE_CMD="$ENV_COLLECTOR" run_statusline "$kick_payload" kickacct \
  >/dev/null || fail "statusline kick with env collector exited nonzero"
assert wait_for_mark
assert_eq "|" "$(cat "$KICK_MARK")"

# F: an idle chat re-sending its last rate_limits copy writes nothing, so it kicks nothing either —
# not even the stamp, which a kick writes before it returns.
kick_reset
STORE_MERGE_CMD="$FAKE_COLLECTOR" run_statusline "$kick_payload" kickacct >/dev/null \
  || fail "statusline first idle-replay render failed"
assert wait_for_mark
for _ in $(seq 1 60); do [ -d "$KICK_LOCK" ] || break; sleep 0.05; done
assert test ! -d "$KICK_LOCK"
rm -f "$KICK_STAMP" "$KICK_MARK"
STORE_MERGE_CMD="$FAKE_COLLECTOR" run_statusline "$kick_payload" kickacct >/dev/null \
  || fail "statusline idle-replay render failed"
assert test ! -e "$KICK_STAMP"

# G: a dead rate-limit cache lock is reclaimed by one render at a time. While another render holds
# the reclaim, this one leaves the lock and the cache alone; a reclaim left by a dead render is
# cleared, and the render after that takes the lock and writes.
kick_reset
mkdir -p "$KICK_CACHE.lock" "$KICK_CACHE.lock.reclaim"
touch -t 202001010000 "$KICK_CACHE.lock"
run_statusline "$kick_payload" kickacct >/dev/null || fail "statusline reclaim-held render failed"
assert test ! -e "$KICK_CACHE"
assert test -d "$KICK_CACHE.lock"
touch -t 202001010000 "$KICK_CACHE.lock.reclaim"
run_statusline "$kick_payload" kickacct >/dev/null || fail "statusline dead-reclaim render failed"
assert test ! -e "$KICK_CACHE.lock.reclaim"
run_statusline "$kick_payload" kickacct >/dev/null || fail "statusline reclaiming render failed"
assert test -s "$KICK_CACHE"
assert test ! -e "$KICK_CACHE.lock"
assert test ! -e "$KICK_CACHE.lock.reclaim"
kick_reset

# --- Codex quota kick (bin/statusline.sh) ---
CQ_ARGS="$WORK/codex-kick-args"
CQ_REFRESHER="$FIXTURES/codex-refresher"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$CQ_ARGS" > "$CQ_REFRESHER"
chmod +x "$CQ_REFRESHER"
CQ_FAIL="$FIXTURES/codex-refresher-fail"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nprintf boom >&2\nexit 3\n' "$CQ_ARGS" > "$CQ_FAIL"
chmod +x "$CQ_FAIL"
CQ_SLOW="$FIXTURES/codex-refresher-slow"
CQ_RELEASE="$WORK/codex-refresher-release"
printf '#!/usr/bin/env bash\nfor _ in $(seq 1 200); do [ -e "%s" ] && break; sleep 0.05; done\nprintf "%%s\\n" "$*" >> "%s"\n' \
  "$CQ_RELEASE" "$CQ_ARGS" > "$CQ_SLOW"
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

cq_reset
CQ_ENV="$FIXTURES/codex-refresher-env"
printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "${CLAUDE_CODE_SESSION_ID:-}" "${WORKER_RUN_ID:-}" >> "%s"\n' "$CQ_ARGS" > "$CQ_ENV"
chmod +x "$CQ_ENV"
CLAUDE_CODE_SESSION_ID=sess-1 WORKER_RUN_ID=run-1 CLAUDEGPT_ACCOUNT=work4 CODEX_REFRESH_CMD="$CQ_ENV" \
  run_statusline "$cq_payload" >/dev/null || fail "claudegpt quota-kick env render failed"
assert cq_wait_args
assert_eq "|" "$(cat "$CQ_ARGS")"

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
assert test "$(( $(date +%s) - cq_start ))" -lt 8
assert test ! -s "$CQ_ARGS"
: > "$CQ_RELEASE"
# Its late write must land here, not in a later case's args file.
for _ in $(seq 1 400); do [ -s "$CQ_ARGS" ] && break; sleep 0.05; done
assert_eq "--refresh-account codex/work4" "$(cat "$CQ_ARGS")"

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
  jq -cn --arg event "$1" --arg tool "$2" --arg file "$3" --arg sid "${4-}" \
    '{hook_event_name:$event,tool_name:$tool,session_id:$sid,
      tool_input:(if $tool=="NotebookEdit" then {notebook_path:$file} else {file_path:$file} end)}'
}
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/statusline.sh" | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse Write "$ROOT/bin/statusline-ports-probe.sh" | "$FRESH_GATE")
assert grep -Fq 'statusline-contract.md' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse NotebookEdit "$ROOT/bin/statusline-ports-probe.sh" | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
# Once per session: the ~430-token checklist rode on every statusline edit of a long session.
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/statusline.sh" fg-once | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/statusline-ports-probe.sh" fg-once | "$FRESH_GATE")
assert_eq "" "$fg_out"
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/statusline.sh" fg-other | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/statusline.sh" fg-once |
  jq -c '. + {agent_id:"sub1"}' | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/statusline.sh" '../fg-escape' | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
assert [ ! -e "$HOME/.cache/fg-escape" ]
# The contract itself and another project's statusline file are not this repository's segments.
fg_out=$(fg_payload PostToolUse Edit "$ROOT/docs/statusline-contract.md" | "$FRESH_GATE")
assert_eq "" "$fg_out"
fg_out=$(fg_payload PostToolUse NotebookEdit "/x/statusline-ports-probe.sh" | "$FRESH_GATE")
assert_eq "" "$fg_out"
ln -s "$ROOT/bin/statusline.sh" "$WORK/statusline.sh"
fg_out=$(fg_payload PostToolUse Edit "$WORK/statusline.sh" | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
rm -f "$WORK/statusline.sh"
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/claudeb" | "$FRESH_GATE")
assert_eq "" "$fg_out"
fg_out=$(fg_payload PreToolUse Edit "$ROOT/bin/statusline.sh" | "$FRESH_GATE")
assert_eq "" "$fg_out"
fg_out=$(printf '{broken' | "$FRESH_GATE") || fail "freshness gate broken json nonzero"
assert_eq "" "$fg_out"

# --- untracked line count: per-repository content cache (share/statusline-untracked.py) ---
# The count must equal the uncached `ls-files -z | xargs -0 grep -cI ''` sum it replaced, a warm
# cache must not read content, and any size/mtime/ctime/inode change must recount.
UNTRACKED_REPO="$FIXTURES/untracked-repo"
mkdir -p "$UNTRACKED_REPO"
git -C "$UNTRACKED_REPO" init -qb main
assert python3 - "$ROOT/share/statusline-untracked.py" "$UNTRACKED_REPO" "$WORK/untracked-cache" <<'PY'
import importlib.util
import marshal
import os
from pathlib import Path
import subprocess
import sys
import time
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('untracked', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
top = Path(sys.argv[2])
cache_dir = sys.argv[3]
(top / 'text: with spaces').write_bytes(b'a\nb\n')
(top / 'binary').write_bytes(b'a\0b')
(top / 'empty').write_bytes(b'')
(top / 'no-newline').write_bytes(b'x\ny')
(top / 'sub').mkdir()
(top / 'sub/deep.txt').write_bytes(b'1\n2\n3\n4\n')


def listing():
    return subprocess.run(['git', '-C', str(top), 'ls-files', '--others', '--exclude-standard', '-z'],
                          stdout=subprocess.PIPE, check=True).stdout


def uncached():
    out = subprocess.run('git ls-files --others --exclude-standard -z | xargs -0 grep -cI "" '
                         '| awk -F: \'{ s += $NF } END { print s + 0 }\'', shell=True, cwd=top,
                         stdout=subprocess.PIPE, check=True).stdout
    return int(out)


def names():
    return [n for n in listing().split(b'\0') if n]


def count():
    return module.cached_total(os.fsencode(top), names(), cache_dir)


def cache_file():
    files = [p for p in Path(cache_dir).iterdir() if p.suffix == '.cache']
    assert len(files) == 1, files
    return files[0]


real_run = subprocess.run
greps = []


def counted(*args, **kwargs):
    if args[0][0] == b'grep':
        greps.append(args[0])
    return real_run(*args, **kwargs)


with patch.object(subprocess, 'run', counted):
    assert count() == uncached() == 8
    assert len(greps) == 1
    assert count() == 8
    assert len(greps) == 1, 'a warm cache must not read content'
    text = top / 'text: with spaces'
    st = text.stat()
    text.write_bytes(b'abc\n')
    os.utime(text, ns=(st.st_atime_ns, st.st_mtime_ns + 1))
    assert count() == uncached() == 7
    assert len(greps) == 2, 'a same-size edit with a 1ns mtime step must recount'
    st = text.stat()
    text.write_bytes(b'a\nb\nc\n')
    os.utime(text, ns=(st.st_atime_ns, st.st_mtime_ns))
    assert count() == uncached() == 9
    assert len(greps) == 3, 'a size change under a restored mtime must recount'
    st = text.stat()
    replacement = top / '.replacement'
    replacement.write_bytes(b'x\nx\nx\n')
    os.utime(replacement, ns=(st.st_atime_ns, st.st_mtime_ns))
    replacement.replace(text)
    assert count() == uncached() == 9
    assert len(greps) == 4, 'a same-size, same-mtime replacement (new inode) must recount'
    (top / 'binary').write_bytes(b'x\ny')
    assert count() == uncached() == 11
    (top / 'sub/deep.txt').unlink()
    assert count() == uncached() == 7
    assert sorted(marshal.loads(cache_file().read_bytes())) == sorted(names()), \
        'the cache holds the files listed now and nothing else'
    cache_file().write_bytes(b'\xffbroken')
    assert count() == uncached() == 7, 'a corrupt cache must recover'
    # A write racing grep: counted this render, never filed under the file's new stamp.
    (top / 'racy').write_bytes(b'1\n')
    real_grep_counts = module.grep_counts

    def racing(top_arg, batch):
        result = real_grep_counts(top_arg, batch)
        (top / 'racy').write_bytes(b'1\n2\n')
        return result
    with patch.object(module, 'grep_counts', racing):
        assert count() == 8
    assert b'racy' not in marshal.loads(cache_file().read_bytes())
    assert count() == uncached() == 9
    module.MAX_ENTRIES = 2
    assert count() == uncached() == 9
    assert len(marshal.loads(cache_file().read_bytes())) == 2, 'the cache is bounded'
    assert count() == uncached() == 9
    module.MAX_ENTRIES = 50000
    # Another repository's stale file is swept on the next write; a live one stays.
    stale = Path(cache_dir) / 'stale.cache'
    live = Path(cache_dir) / 'live.cache'
    stale.write_text('{}')
    live.write_text('{}')
    old = time.time() - module.STALE_SECS - 60
    os.utime(stale, (old, old))
    (top / 'fresh').write_bytes(b'1\n')
    assert count() == uncached() == 10
    assert not stale.exists() and live.exists()
    live.unlink()
PY
# grep reads a leading `-` as an option: that listing keeps the uncached xargs pass and its count.
printf 'opt\n' > "$UNTRACKED_REPO/-c"
untracked_line=$(git -C "$UNTRACKED_REPO" ls-files --others --exclude-standard -z |
  python3 "$ROOT/share/statusline-untracked.py" "$UNTRACKED_REPO" "$WORK/untracked-cache")
untracked_want=$( (cd "$UNTRACKED_REPO" && git ls-files --others --exclude-standard -z | xargs -0 grep -cI '' 2>/dev/null) |
  awk -F: '$NF ~ /^[0-9-]+$/ { s += $NF } END { print s + 0 }')
untracked_files=$(git -C "$UNTRACKED_REPO" ls-files --others --exclude-standard | wc -l | tr -d ' ')
assert_eq "$(printf '%s\t0\t\tU%s' "$untracked_want" "$untracked_files")" "$untracked_line"
rm -f "$UNTRACKED_REPO/-c"

# Render timing for the Harness doctor: one `start_us<TAB>end_us<TAB>session<TAB>cpu_ms` line per render under
# $HARNESS_DOCTOR_DIR (default ~/.cache/harness-doctor)/statusline/<local date>.tsv, never on stdout.
TIMING_DIR="$WORK/harness-doctor"
timing_file="$TIMING_DIR/statusline/$(date +%Y-%m-%d).tsv"
timing_plain=$(run_statusline "$(statusline_payload timing-sess)"); timing_plain_rc=$?
timing_out=$(HARNESS_DOCTOR_DIR="$TIMING_DIR" run_statusline "$(statusline_payload timing-sess)" 2>"$WORK/timing.err")
timing_rc=$?
assert_eq "$timing_plain" "$timing_out"
assert_eq "$timing_plain_rc" "$timing_rc"
assert_eq "" "$(cat "$WORK/timing.err")"
assert_eq 1 "$(wc -l < "$timing_file" | tr -d ' ')"
IFS=$'\t' read -r timing_start timing_end timing_sid timing_cpu < "$timing_file"
assert_eq timing-sess "$timing_sid"
assert grep -Eq '^[0-9]+$' <<< "$timing_cpu"
assert test "$timing_cpu" -gt 0
# A decimal-comma locale prints `times` as 0m0,019s.
LC_ALL=ru_RU.UTF-8 HARNESS_DOCTOR_DIR="$WORK/timing-ru" run_statusline "$(statusline_payload timing-sess)" \
  >/dev/null 2>"$WORK/timing-ru.err"
assert_eq "" "$(cat "$WORK/timing-ru.err")"
IFS=$'\t' read -r _ _ _ timing_ru_cpu < "$WORK/timing-ru/statusline/$(date +%Y-%m-%d).tsv"
assert test "$timing_ru_cpu" -gt 0
assert grep -Eq '^[0-9]{16}$' <<< "$timing_start"
assert test "$timing_end" -ge "$timing_start"
HARNESS_DOCTOR_DIR="$TIMING_DIR" run_statusline "$(statusline_payload timing-sess)" >/dev/null
assert_eq 2 "$(wc -l < "$timing_file" | tr -d ' ')"
# An unwritable journal changes nothing a render prints or returns.
printf 'x' > "$WORK/timing-blocker"
timing_blocked=$(HARNESS_DOCTOR_DIR="$WORK/timing-blocker" run_statusline "$(statusline_payload timing-sess)" 2>"$WORK/timing.err")
assert_eq "$timing_plain_rc" "$?"
assert_eq "$timing_plain" "$timing_blocked"
assert_eq "" "$(cat "$WORK/timing.err")"
# The default location is under HOME, which this suite points at its own tree.
assert test -s "$HOME/.cache/harness-doctor/statusline/$(date +%Y-%m-%d).tsv"

# file_mtime/file_inode/file_size through bash's stat loadable must answer what the stat(1)
# fallback does, lstat included; a BASH with no lib/bash beside it takes the fallback.
STAT_DIR="$WORK/stat-helpers"
mkdir -p "$STAT_DIR/dir"
printf 'twelve bytes' > "$STAT_DIR/file"
ln -s file "$STAT_DIR/link"
ln -s missing "$STAT_DIR/dangling"
stat_helpers=$(sed -n '/^if enable -f .*lib\/bash\/stat/,/^fi$/p' "$STATUSLINE")
assert grep -Fq 'file_size()' <<< "$stat_helpers"
stat_probe='eval "$1"; [ -e "${BASH%/bin/*}/lib/bash/stat" ] && printf "has " || printf "none "
  printf "%s " "$(type -t stat)"
  for f in file dir link dangling missing; do
    printf "%s:%s:%s:%s;" "$f" "$(file_mtime "$2/$f")" "$(file_inode "$2/$f")" "$(file_size "$2/$f")"
  done'
stat_loaded=$(bash -c "$stat_probe" _ "$stat_helpers" "$STAT_DIR")
stat_forked=$(bash -c "BASH=/nonexistent/bin/bash; $stat_probe" _ "$stat_helpers" "$STAT_DIR")
assert grep -Eq '^(has builtin|none file) ' <<< "$stat_loaded"
assert_eq "none file ${stat_loaded#* * }" "$stat_forked"
assert grep -q ';link:[0-9][0-9]*:[0-9][0-9]*:4;' <<< "$stat_forked"
assert grep -q ';dangling:[0-9][0-9]*:[0-9][0-9]*:7;missing:::;' <<< "$stat_forked"

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
fi
# The rate-limit cache render-pins leaves behind, so later renders read it in any shard.
seed_rl_cache() {
  [ ! -e "$HOME/.claude/statusline-cache-rl" ] || return 0
  mkdir -p "$HOME/.claude"
  jq -cn --argjson now "$(date +%s)" '
    {five_hour:{used_percentage:70,resets_at:($now+3600),as_of:$now,origin:"session"},
     seven_day:{used_percentage:7,resets_at:($now+86400),as_of:$now,origin:"session"},auth:{status:"ok",checked_at:$now}}' \
    >"$HOME/.claude/statusline-cache-rl"
}
seed_rl_cache

if suite_shard_owns 3 ports-probe; then
# --- statusline-ports-probe.sh ---
# Its own clock: the shard that runs this section skips render-pins, which stamps NOW.
NOW=$(date +%s)
PORTS_PROBE="$ROOT/bin/statusline-ports-probe.sh"
FAKE_PS="$FIXTURES/ports-ps"
cat > "$FAKE_PS" <<'PSEOF'
#!/usr/bin/env bash
cat <<'SNAP'
1000 1 00:01 claude
1001 1000 00:01 node /path/to/vite
1002 1000 00:01 node /Users/x/.nvm/codex mcp-server
1003 1000 00:01 python3 -m http.server 8123
1004 1000 00:01 node ./mcp/server.mjs
1005 1000 00:01 agy --model gemini
1006 1005 00:01 node /opt/agy/rpc.js
1007 1000 00:01 codex exec
1008 1007 00:01 node /srv/dev-server
1009 1000 00:01 node serve.js --dir /srv/agy
1010 1 00:01 node /proj/node_modules/.bin/next start --port 4254
1011 1 00:01 node /elsewhere/server.js
1012 1 00:01 node /projx/server.js
1015 1 00:01 node /proj/rpc.js
1016 1000 00:01 8080 --serve
1017 1000 00:01 COMMANDER --serve
1018 1000 00:01 COMMAND --serve
1019 1000 00:01 node server.js --config codex.json
1020 1000 00:01 node server.js /tmp/codex-out.json
1021 1000 00:01 node --require /x/codex/hooks.js server.js
1022 1000 00:01 node --loader ts-node/esm mcp-server.ts
1023 1000 00:01 uv run mcp-server-fetch
1024 1000 00:01 npm exec @modelcontextprotocol/server-x
1013 1000 00:01 claude
1014 1013 00:01 node /path/to/vite-worker
9999 1 00:01 claude
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
node      1020 u  39u  IPv4  0t0      TCP *:5000 (LISTEN)
node      1021 u  40u  IPv4  0t0      TCP *:5100 (LISTEN)
node      1022 u  41u  IPv4  0t0      TCP *:5200 (LISTEN)
uv        1023 u  42u  IPv4  0t0      TCP *:5300 (LISTEN)
npm       1024 u  43u  IPv4  0t0      TCP *:5400 (LISTEN)
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
# 5000 and 5100 are dev servers a denylisted name reaches only as a POSITIONAL the script carries
# and as the value of `--require`; 5200 is an MCP server behind `--loader`, whose value is not the
# program. Reading either word as argv[0] answers about the wrong file. 5300 and 5400 are MCP
# servers behind a launcher subcommand (`uv run`, `npm exec`), which is not the program either.
assert_eq "$(ports_records 5173 8123 5174 8080 4500 4600 4700 4800 4900 5000 5100)" "$(cat "$STATE_DIR/ports-pp-parse")"

# A server backgrounded from a tool call is reparented to launchd as soon as that call returns —
# the case the ancestry walk alone could never see, and the one every dev server actually hits.
# Its working directory is inside the repository being shown, so it is claimed back; the one
# elsewhere is not, and neither is /projx, whose name merely starts with the repository's. 62150 has
# the right directory and the wrong port: a directory is weaker evidence than a parent, and every
# editor RPC socket started from the repository would otherwise fill the segment.
# /proj is no repository, so the one root given is the whole project and 4254 is attributed to it;
# every other port here is one this session parents, and its own directory places none of them.
run_probe pp-orphan 1001 /proj
assert_eq "$(printf '5173\t-\n8123\t-\n5174\t-\n8080\t-\n4254\t/proj\n4500\t-\n4600\t-\n4700\t-\n4800\t-\n4900\t-\n5000\t-\n5100\t-')" \
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
  999 1 00:01 init
 1000 1 00:01 claude
 2001 1000 00:01 node /path/to/vite
 3002 1000 00:01 python3 -m http.server 8127
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
1000 1 00:01 claude
2100 1000 00:01 codex exec
2101 2100 00:01 node /srv/rpc-worker.js
2102 1000 00:01 grok --prompt-file /tmp/review
2103 2102 00:01 node /srv/grok-rpc.js
2104 2102 00:01 node /srv/dev.js
2105 1000 00:01 /Applications/Google Chrome.app/Contents/chrome_crashpad_handler
2106 1000 00:01 npx -y @modelcontextprotocol/server-filesystem
2107 1000 00:01 node --inspect ./mcp/server.js
2108 1000 00:01 python3 -m mcp.server
2109 1000 00:01 node server.js --config codex.json
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
chrome   2105 u   13u  IPv4  0t0      TCP 127.0.0.1:4322 (LISTEN)
node     2106 u   13u  IPv4  0t0      TCP 127.0.0.1:4323 (LISTEN)
node     2107 u   13u  IPv4  0t0      TCP 127.0.0.1:4324 (LISTEN)
python   2108 u   13u  IPv4  0t0      TCP 127.0.0.1:4325 (LISTEN)
node     2109 u   13u  IPv4  0t0      TCP 127.0.0.1:4326 (LISTEN)
OUT
LSEOFT
chmod +x "$FAKE_LSOF_TOOLS"
STATUSLINE_PS="$FAKE_PS_TOOLS" STATUSLINE_LSOF="$FAKE_LSOF_TOOLS" "$PORTS_PROBE" pp-tools 1000
assert_eq "$(ports_records 4321 4326)" "$(cat "$STATE_DIR/ports-pp-tools")"
rm -f "$STATE_DIR/ports-pp-tools"
STATUSLINE_PS="$FAKE_PS_TOOLS" STATUSLINE_LSOF="$FAKE_LSOF_TOOLS" /bin/bash "$PORTS_PROBE" pp-tools 1000
assert_eq "$(ports_records 4321 4326)" "$(cat "$STATE_DIR/ports-pp-tools" 2>/dev/null)"


# Each port is attributed to the WORKING TREE its process directory sits in, and the worktrees live
# INSIDE the repository, so the root cannot claim them: the render's whole colour rule rests on
# this. A sibling checkout whose name merely starts with a tree's is not inside it.
SIB_A="$FIXTURES/repo a-extra"
mkdir -p "$SIB_A"
FAKE_PS_TREES="$FIXTURES/ports-ps-trees"
cat > "$FAKE_PS_TREES" <<'PSEOFW'
#!/usr/bin/env bash
cat <<'SNAP'
1000 1 00:01 claude
1001 1000 00:01 node /path/to/vite
1010 1 00:01 node /main/server.js
1011 1 00:01 node /wt/server.js
1012 1 00:01 node /sibling/server.js
1013 1 00:01 node /gone/server.js
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

# A lock left by a killed probe is reclaimed before the render's 60s cut hides the segment.
printf '5173\n' > "$STATE_DIR/ports-pp-killed"
mkdir "$STATE_DIR/ports-pp-killed.lock"
STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$FAKE_LSOF_EMPTY" "$PORTS_PROBE" pp-killed 1001
assert_eq "5173" "$(cat "$STATE_DIR/ports-pp-killed")"
touch -t "$(date -r $(($(date +%s) - 40)) +%Y%m%d%H%M.%S)" "$STATE_DIR/ports-pp-killed.lock"
STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$FAKE_LSOF_EMPTY" "$PORTS_PROBE" pp-killed 1001
assert_eq "" "$(cat "$STATE_DIR/ports-pp-killed")"
assert test ! -e "$STATE_DIR/ports-pp-killed.lock"

# One process table and one listener walk serve every chat's probes: a second chat inside the
# snapshot's ten seconds runs neither ps nor lsof and records what its own walk would have.
SNAP_CALLS="$WORK/snapshot-calls"
SNAP_PS="$FIXTURES/snap-ps"; SNAP_LSOF="$FIXTURES/snap-lsof"
printf '#!/usr/bin/env bash\nprintf "ps\\n" >> "%s"\nexec "%s" "$@"\n' "$SNAP_CALLS" "$FAKE_PS" > "$SNAP_PS"
printf '#!/usr/bin/env bash\nprintf "lsof\\n" >> "%s"\nexec "%s" "$@"\n' "$SNAP_CALLS" "$FAKE_LSOF" > "$SNAP_LSOF"
chmod +x "$SNAP_PS" "$SNAP_LSOF"
snap_t0=$(date +%s); snap_now=$snap_t0
snap_probe() { STATUSLINE_NOW=$snap_now STATUSLINE_PS="$SNAP_PS" STATUSLINE_LSOF="$SNAP_LSOF" "$PORTS_PROBE" "$1" 1001 /proj; }
snap_calls() { grep -c "^$1\$" "$SNAP_CALLS" 2>/dev/null || :; }
snap_at() { local at; { IFS=$'\t' read -r at _; } < "$STATE_DIR/$1"; printf '%s' "$at"; }
snap_ats() { printf '%s %s' "$(($(snap_at ps-snapshot) - snap_t0))" "$(($(snap_at ports-snapshot) - snap_t0))"; }
snap_head() { # file epoch
  local rest; { IFS=$'\t' read -r _ rest; } < "$STATE_DIR/$1"
  { printf '%s\t%s\n' "$2" "$rest"; tail -n +2 "$STATE_DIR/$1"; } > "$STATE_DIR/$1.edit" && mv "$STATE_DIR/$1.edit" "$STATE_DIR/$1"
}
: > "$SNAP_CALLS"
snap_probe pp-snap-a
assert_eq "1 2" "$(snap_calls ps) $(snap_calls lsof)"
assert_eq "0 0" "$(snap_ats)"
# The work probe reads the same table inside its own three seconds.
snap_now=$((snap_t0 + 3))
STATUSLINE_NOW=$snap_now STATUSLINE_PS="$SNAP_PS" STATUSLINE_LSOF="$SNAP_LSOF" WORKER_RUN_DIR="$WORK/none" \
  "$ROOT/bin/statusline-work-probe.sh" wp-snap 1001
assert_eq "1 2" "$(snap_calls ps) $(snap_calls lsof)"
snap_now=$((snap_t0 + 10))
snap_probe pp-snap-b
assert_eq "1 2" "$(snap_calls ps) $(snap_calls lsof)"
assert_eq "$(cat "$STATE_DIR/ports-pp-orphan")" "$(cat "$STATE_DIR/ports-pp-snap-b")"
# A snapshot past its age is walked again, and a process table older than the listener walk is
# retaken: a listener it does not hold has no command to be judged by.
snap_now=$((snap_t0 + 11))
snap_probe pp-snap-c
assert_eq "2 4" "$(snap_calls ps) $(snap_calls lsof)"
assert_eq "11 11" "$(snap_ats)"
snap_head ps-snapshot "$((snap_t0 + 15))"
rm -f "$STATE_DIR/ports-snapshot"
snap_now=$((snap_t0 + 20))
snap_probe pp-snap-d
assert_eq "3 6" "$(snap_calls ps) $(snap_calls lsof)"
assert_eq "20 20" "$(snap_ats)"
assert_eq "$(cat "$STATE_DIR/ports-pp-orphan")" "$(cat "$STATE_DIR/ports-pp-snap-d")"
# A failed ps is never published as an empty machine for the other chats.
STATUSLINE_NOW=$((snap_t0 + 40)) STATUSLINE_PS=true STATUSLINE_LSOF="$SNAP_LSOF" "$PORTS_PROBE" pp-snap-empty 1001 /proj
assert_eq "" "$(cat "$STATE_DIR/ports-pp-snap-empty")"
assert test "$(head -1 "$STATE_DIR/ps-snapshot" | cut -f3)" = "$SNAP_PS"
assert_eq "20" "$(($(snap_at ps-snapshot) - snap_t0))"

# Every probe run journals its own cost for the Speed doctor, builtins only.
probe_rows="$HOME/.cache/speed-doctor/statusline-probes/$(date +%Y-%m-%d).tsv"
assert grep -Eq $'^[0-9]{16}\t[0-9]+\t([0-9]+|-)\tports$' "$probe_rows"
assert grep -Eq $'^[0-9]{16}\t[0-9]+\t([0-9]+|-)\twork$' "$probe_rows"

# The hourly sweep: a temporary an hour old was left by a killed writer, here and in the account
# store; per-session caches go after a week, the place journals never.
fi
age_path() { touch -t "$(date -r "$(($(date +%s) - $1))" +%Y%m%d%H%M.%S)" "$2"; }
if suite_shard_owns 3 sweep; then
prune_limits="$HOME/.claude-profiles/.claudeb/limits"
mkdir -p "$prune_limits" "$STATE_DIR/old-probe.lock"
for prune_file in x.tmp.1 y.tmp.2 work-old work-new scan-old rl-cost-old unpushed-old review-autonomy-old \
    repo-debt-old place-old; do : > "$STATE_DIR/$prune_file"; done
: > "$prune_limits/a.json.tmp.3"; : > "$prune_limits/b.json.tmp.4"
age_path 7200 "$STATE_DIR/x.tmp.1"; age_path 7200 "$prune_limits/a.json.tmp.3"
for prune_file in work-old scan-old rl-cost-old unpushed-old review-autonomy-old repo-debt-old place-old; do
  age_path 691200 "$STATE_DIR/$prune_file"
done
age_path 172800 "$STATE_DIR/old-probe.lock"
rm -f "$STATE_DIR/.ports-prune"
snap_probe pp-prune
assert_eq "y.tmp.2 work-new place-old b.json.tmp.4" "$(for prune_file in x.tmp.1 y.tmp.2 work-old work-new scan-old \
  rl-cost-old unpushed-old review-autonomy-old repo-debt-old place-old; do [ -e "$STATE_DIR/$prune_file" ] && printf '%s ' "$prune_file"; done
  for prune_file in a.json.tmp.3 b.json.tmp.4; do [ -e "$prune_limits/$prune_file" ] && printf '%s' "$prune_file"; done)"
assert test ! -d "$STATE_DIR/old-probe.lock"

# --- statusline-work-probe.sh ---
WORK_PROBE="$ROOT/bin/statusline-work-probe.sh"
WP_REPO="$WORK/wp repo"
git -C "$WORK" init -q "wp repo"
git -C "$WP_REPO" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q --allow-empty -m init
git -C "$WP_REPO" worktree add -q --detach "$WP_REPO/.claude/worktrees/wt-one"
mkdir -p "$WORK/wp-plain" "$WORK/wp-other/tests"
git -C "$WORK/wp-other" init -q
WP_RUNS="$WORK/wp-runs"
wp_now=$(date +%s)
# The probe's clock is pinned: the stamps below are checked against starts it derives from ps etimes.
export STATUSLINE_NOW=$wp_now
# Worker runs (bin/worker-run): one launched here and testing, one launched elsewhere that this chat
# waits on, one so new it has no supervisor pid yet;
# none for an ended run, a dead or recycled supervisor, or a pid-less start older than any start takes.
wp_run() { # run-id launcher state-json meta-json
  mkdir -p "$WP_RUNS/$1"
  printf '%s\n' "$2" > "$WP_RUNS/$1/launcher"; printf '%s\n' "$3" > "$WP_RUNS/$1/state.json"
  printf '%s\n' "$4" > "$WP_RUNS/$1/meta.json"
}
wp_run codex-7-7-live wp-sess "{\"phase\": \"wait\", \"round_id\": null, \"started_epoch\": $((wp_now - 600))}" '{}'
jq -n --argjson at "$((wp_now - 180))" '{pid: 2000, cli_pid: 2001, pid_started_at: $at, orphans_ended: [{pid: 2900, age_s: 5}]}' \
  > "$WP_RUNS/codex-7-7-live/meta.json"
printf 'acc · astra · high\n' > "$WP_RUNS/codex-7-7-live/tag"; printf 'Fix the parser\n' > "$WP_RUNS/codex-7-7-live/title"
printf '184321\n' > "$WP_RUNS/codex-7-7-live/tokens"
wp_run codex-7-7-other other-sess '{"phase": "wait"}' "{\"pid\": 2200, \"started_at\": $((wp_now - 300)), \"pid_started_at\": $((wp_now - 300))}"
printf 'com · opus · high\n' > "$WP_RUNS/codex-7-7-other/tag"; printf 'unknown\n' > "$WP_RUNS/codex-7-7-other/tokens"
printf 'Map the hooks\n' > "$WP_RUNS/codex-7-7-other/title"
# A light run's tag is recast as the light call that made it; a fix round's run is `fix:` and the round.
wp_run codex-7-7-light wp-sess "{\"phase\": \"wait\", \"started_epoch\": $((wp_now - 100))}" \
  "{\"pid\": 2400, \"pid_started_at\": $((wp_now - 100)), \"light\": \"research\"}"
printf 'rawilimo · flash38 · high\n' > "$WP_RUNS/codex-7-7-light/tag"; printf 'Find the docs\n' > "$WP_RUNS/codex-7-7-light/title"
wp_run codex-7-7-fix wp-sess "{\"phase\": \"wait\", \"round_id\": \"20261009T120000Z-1a2b3c4d5\", \"started_epoch\": $((wp_now - 50))}" \
  "{\"pid\": 2500, \"pid_started_at\": $((wp_now - 50))}"
printf 'com · opus · high\n' > "$WP_RUNS/codex-7-7-fix/tag"; printf 'Fix the findings\n' > "$WP_RUNS/codex-7-7-fix/title"
# Waiting for its worker slot, its CLI not launched, a run whose chat already waits is queued, not working.
wp_run codex-7-7-que wp-sess "{\"phase\": \"wait\", \"started_epoch\": $((wp_now - 40))}" \
  "{\"pid\": 2600, \"pid_started_at\": $((wp_now - 40)), \"slot_at\": $((wp_now - 5))}"
printf 'com · opus · high\n' > "$WP_RUNS/codex-7-7-que/tag"; printf 'Queued task\n' > "$WP_RUNS/codex-7-7-que/title"
wp_run codex-7-7-new wp-sess "{\"phase\": \"start\", \"started_epoch\": $((wp_now - 20))}" '{"pid": 0}'
printf 'New task\n' > "$WP_RUNS/codex-7-7-new/title"
wp_run codex-7-7-done wp-sess '{"phase": "done"}' '{"pid": 2100}'; printf '0\n' > "$WP_RUNS/codex-7-7-done/exit_code"
wp_run codex-7-7-foreign other-sess '{"phase": "wait"}' "{\"pid\": 2300, \"pid_started_at\": $((wp_now - 240))}"
wp_run codex-7-7-gone wp-sess '{"phase": "wait"}' '{"pid": 2900}'
wp_run codex-7-7-recyc wp-sess '{"phase": "wait"}' "{\"pid\": 2001, \"pid_started_at\": $((wp_now - 5000))}"
wp_run codex-7-7-stuck wp-sess "{\"phase\": \"start\", \"started_epoch\": $((wp_now - 4000))}" '{}'
# Review runs (review-bench progress documents): one waited on here, one this chat launched and no
# process here waits on, one waited on with no document; none for a finished run, a dead launcher's
# document (its heartbeat stopped) or another chat's.
WP_STATS="$WORK/wp-stats"
mkdir -p "$WP_STATS/progress"
wp_doc() { # file jq-object
  jq -cn --argjson now "$wp_now" "$2" > "$WP_STATS/progress/$1.json"
}
wp_doc llm-legs__w '{run_id:"20261008T100000Z-aaaaaaa",tier:"T0",composition:"double",lens:"bugs",repo:"/r/llm-legs",
  state:"running",session:"other",started_epoch:($now - 900),heartbeat_epoch:($now - 2000),
  cells:["a#1","a#2","b#1","b#2","c#1","c#2","d#1","d#2"],done:["a#1","b#1","c#1","c#2"],failed_cells:["d#1"]}'
# A run over several repositories writes one document per repository: the title names them all.
jq -c '.repo = "/r/claude-setup/"' "$WP_STATS/progress/llm-legs__w.json" > "$WP_STATS/progress/claude-setup__w.json"
wp_doc llm-legs__s '{run_id:"20261008T100000Z-ccccccc",tier:"T2",lens:"task",task:"\nHunt the stale rows\nsecond",repo:"/r/llm-legs",
  state:"running",session:"wp-sess",started_epoch:($now - 400),heartbeat_epoch:$now,cells:["a#1","b#1"],done:[],failed_cells:[],
  expected:{"a#1":50000}}'
wp_doc llm-legs__f '{run_id:"20261008T100000Z-ddddddd",tier:"T1",state:"done",session:"wp-sess",started_epoch:($now - 400),
  heartbeat_epoch:$now,cells:["a#1"],done:["a#1"]}'
wp_doc llm-legs__h '{run_id:"20261008T100000Z-eeeeeee",tier:"T1",state:"running",session:"wp-sess",started_epoch:($now - 4000),
  heartbeat_epoch:($now - 3600),cells:["a#1"],done:[]}'
wp_doc llm-legs__o '{run_id:"20261008T100000Z-fffffff",tier:"T1",state:"running",session:"other",started_epoch:($now - 400),
  heartbeat_epoch:$now,cells:["a#1"],done:[]}'
# The judge phase: the judge stamped (g, its report done) or not (j), and a run that died in it (h).
wp_doc llm-legs__g '{run_id:"20261008T100000Z-ggggggg",tier:"T1",state:"done",phase:"report",confirmed:3,repo:"/r/llm-legs",
  session:"other",started_epoch:($now - 700),heartbeat_epoch:$now,cells:["a#1"],done:["a#1"],
  judge:{account:"notcom",model:"opus",effort:"high",ts:($now - 120 | todate)}}'
wp_doc llm-legs__x '{run_id:"20261008T100000Z-hhhhhhh",tier:"T1",state:"failed",phase:"judge",session:"other",
  started_epoch:($now - 650),heartbeat_epoch:$now,cells:["a#1"],failed_cells:["a#1"],judge:{account:"notcom"}}'
wp_doc llm-legs__j '{run_id:"20261008T100000Z-jjjjjjj",tier:"T1",lens:"bugs",state:"running",phase:"judge",repo:"/r/llm-legs",
  session:"wp-sess",started_epoch:($now - 350),heartbeat_epoch:$now,cells:["a#1","b#1"],done:["a#1","b#1"],
  judge:{account:"notcom",model:"",effort:"high"}}'
wp_doc llm-legs__k '{run_id:"20261008T100000Z-kkkkkkk",tier:"T1",state:"dead",phase:"judge",session:"other",
  started_epoch:($now - 600),heartbeat_epoch:$now,cells:["a#1"],done:["a#1"],judge:{account:"notcom"}}'
WP_LOGS="$WORK/wp-logs"
mkdir -p "$WP_LOGS"
printf '0\t3\n' > "$WP_LOGS/test_a.sh.status"; printf '1\t2\n' > "$WP_LOGS/test_b.sh.status"
WP_STAMP=$(($(date +%s) - 240))
printf '%s\t5\t%s\t%s\n' "$WP_LOGS" "$WP_REPO" "$WP_STAMP" > "$STATE_DIR/suites-1101"
printf '%s\t4\t%s\t1000\n' "$WP_LOGS" "$WORK/wp-other" > "$STATE_DIR/suites-1321"
WP_SNAP='wrap() { printf "%s %s %s /bin/zsh -c source /h/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval %s\n" "$@"; }'
FAKE_PS_WORK="$FIXTURES/work-ps"
cat > "$FAKE_PS_WORK" <<PSEOF
#!/usr/bin/env bash
$WP_SNAP
for a in "\$@"; do
  [ "\$a" = -E ] || continue
  printf '3000 bash tests/test_orphan.sh PATH=/bin CLAUDE_PID=1000\n'
  printf '3100 bash tests/test_other.sh PATH=/bin CLAUDE_PID=4242 CLAUDE_CODE_SESSION_ID=other\n'
  printf '3200 bash tests/test_sid.sh CLAUDE_CODE_SESSION_ID=wp-sess\n'
  printf '5001 bash tests/test_cell.sh CLAUDE_CODE_SESSION_ID=wp-sess\n'
  exit 0
done
cat <<'SNAP'
1 0 10-00:00:00 /sbin/launchd
500 1 01:00:00 login -pf u
600 500 01:00:00 -zsh
1000 600 30:00 /Users/u/.local/bin/claude --resume x
SNAP
wrap 1100 1000 05:00 "'bash tests/run-all'"
cat <<'SNAP'
1101 1100 04:59 /opt/homebrew/bin/bash /r/share/run-suites.sh --repo /r
1102 1101 00:10 /opt/homebrew/bin/bash tests/test_a.sh
SNAP
wrap 1200 1000 00:30 "'sed -n 1,9p tests/test_x.sh; git push origin main'"
printf '1201 1200 00:29 git push origin main\n'
wrap 1210 1000 00:05 "'make build'"
printf '1211 1210 00:04 make build\n'
wrap 1220 1000 02:00 "'worker-run wait codex-7-7-other'"
printf '1221 1220 01:59 bash /x/bin/worker-run wait codex-7-7-other --max 540\n'
wrap 1500 1000 03:00 "'review-bench wait 20261008T100000Z-aaaaaaa'"
printf '1501 1500 02:59 /usr/bin/python3 /x/bin/review-bench wait 20261008T100000Z-aaaaaaa\n'
printf '1510 1000 00:50 /usr/bin/python3 /x/bin/review-bench wait --session wp-sess --max 60 20261008T100000Z-bbbbbbb\n'
printf '1520 1000 00:40 /usr/bin/python3 /x/bin/review-bench wait 20261008T100000Z-ggggggg\n'
printf '1530 1000 00:40 /usr/bin/python3 /x/bin/review-bench wait 20261008T100000Z-hhhhhhh\n'
printf '1540 1000 00:40 /Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python /x/bin/review-bench wait 20261008T100000Z-kkkkkkk\n'
printf '6001 4001 01:00 bash /x/bin/review-bench wait 20261008T100000Z-fffffff\n'
wrap 1230 1000 01:00 "'python3 -m pytest -q'"
printf '1231 1230 00:59 /usr/bin/python3 -m pytest -q\n'
wrap 1260 1000 00:45 "'while :; do :; done'"
wrap 1290 1000 00:40 "'timeout 600 git push'"
printf '1291 1290 00:39 timeout -s KILL 600 git push origin\n'
wrap 1300 1000 00:38 "'curl --user secretword https://x'"
printf '1301 1300 00:37 curl --user secretword https://x\n'
wrap 1330 1000 00:35 "'perl -le 1'"
printf '1331 1330 00:34 perl -le select(undef,undef,undef,secretcode)\n'
wrap 1310 1000 01:30 "'bash /abs/test_y.sh'"
printf '1311 1310 01:29 bash %s/tests/test_y.sh\n' "$WORK/wp-other"
wrap 1340 1000 01:20 "'lua -E /abs/test_z.lua'"
printf '1341 1340 01:19 lua -E %s/tests/test_z.lua\n' "$WORK/wp-other"
wrap 1320 1000 03:00 "'bash /o/tests/run-all'"
cat <<'SNAP'
1321 1320 02:59 /opt/homebrew/bin/bash /r/share/run-suites.sh --repo /o
1270 1000 00:20 node /x/node_modules/.bin/vitest run
1280 1000 00:07 bash /h/.claude/hooks/instruction-watch.sh check
1281 1000 00:02 /bin/bash /h/.claude/hooks/review-flow-gate.sh
5000 1 05:00 /usr/bin/python3 /x/bin/review-bench review --foreground
5001 5000 04:00 bash tests/test_cell.sh
1240 1000 20:00 node /mcp/server.js
1250 1000 00:40 bash /h/.claude/statusline.sh
2000 1 03:00 bash -c supervisor _ /x/bin/worker-run /runs/codex-7-7-live
2001 2000 02:59 codex exec --json
2002 2001 01:30 /bin/bash -lc pnpm test
2003 2002 01:29 node /opt/homebrew/bin/pnpm test
2100 1 03:00 bash -c supervisor _ /x/bin/worker-run /runs/codex-7-7-done
2101 2100 02:00 bash tests/test_done_run.sh
2200 1 05:00 bash -c supervisor _ /x/bin/worker-run /runs/codex-7-7-other
2300 1 04:00 bash -c supervisor _ /x/bin/worker-run /runs/codex-7-7-foreign
2400 1 01:40 bash -c supervisor _ /x/bin/worker-run /runs/codex-7-7-light
2500 1 00:50 bash -c supervisor _ /x/bin/worker-run /runs/codex-7-7-fix
2600 1 00:40 bash -c supervisor _ /x/bin/worker-run /runs/codex-7-7-que
3000 1 02:00 bash tests/test_orphan.sh
3100 1 02:00 bash tests/test_other.sh
3200 1 01:10 bash tests/test_sid.sh
4000 1 50:00 claude
SNAP
wrap 4001 4000 10:00 "'bash tests/test_b.sh'"
printf '4002 4001 09:59 bash tests/test_b.sh\n'
wrap 1400 1000 03:00 "'media-run image --vendor codex -- --prompt x'"
printf '1401 1400 02:59 /bin/bash /x/bin/codex-image --prompt x\n'
wrap 1410 1000 02:00 "'media-run image --vendors codex,grok -- --dest-dir /f'"
printf '1411 1410 01:59 /bin/bash /x/bin/image-fanout --vendors codex,grok --dest-dir /f\n'
printf '1412 1411 01:58 /bin/bash /x/bin/grok-image --dest /f/g.png\n'
printf '1420 1000 01:00 /bin/bash /x/bin/gemini-music --dest /tmp/a.wav\n'
wrap 1430 1000 01:00 "'media-run image --vendor grok -- --prompt x'"
printf '1431 1430 00:59 /bin/bash /x/bin/grok-image --prompt x\n'
wrap 1440 1000 01:00 "'media-run video --vendor grok -- --prompt x'"
printf '1441 1440 00:59 /bin/bash /x/bin/grok-video --prompt x\n'
printf '1450 1000 01:00 /bin/bash /x/bin/elevenlabs-speech --dest /tmp/a.mp3\n'
printf '1451 1450 00:59 python3 /x/share/elevenlabs_media.py speech --dest /tmp/a.mp3\n'
PSEOF
chmod +x "$FAKE_PS_WORK"
FAKE_LSOF_WORK="$FIXTURES/work-lsof"
cat > "$FAKE_LSOF_WORK" <<LSEOF
#!/usr/bin/env bash
printf 'p1101\nfcwd\nn%s\n' "$WORK/wp-plain"
printf 'p1200\nfcwd\nn%s\n' "$WP_REPO/.claude/worktrees/wt-one"
printf 'p1231\nfcwd\nn%s\n' "$WORK/wp-plain"
printf 'p1260\nfcwd\nn%s\n' "$WORK/wp-plain"
for p in 1270 1280 1290 1300 1311 1330 1341; do printf 'p%s\nfcwd\nn%s\n' "\$p" "$WORK/wp-plain"; done
printf 'p1321\nfcwd\nn%s\n' "$WP_REPO"
printf 'p3000\nfcwd\nn%s\n' "$WP_REPO"
printf 'p3200\nfcwd\nn%s\n' "$WP_REPO"
LSEOF
chmod +x "$FAKE_LSOF_WORK"
# media-run's pointers (bin/media-run): a pid whose pointer predates its process is a reused pid (1431),
# a media process with no pointer at all draws nothing (1441), a fan-out counts its cells' state.
WP_FAN="$WORK/wp-fan"
mkdir -p "$WP_FAN"
printf '{"kind":"image","cells":[{"status":"done"},{"status":"failed"},{"status":"running"},{"status":"spare-cancelled"}]}\n' > "$WP_FAN/fanout.state.json"
printf '%s\tpool · img·web\tgen\t\tj1\n' "$((wp_now - 179))" > "$STATE_DIR/media-1401"
printf '%s\tfanout · img\tall\t%s\t\n' "$((wp_now - 119))" "$WP_FAN/fanout.state.json" > "$STATE_DIR/media-1411"
printf '%s\tcom · mus·app\tedit\t\tj3\n' "$((wp_now - 59))" > "$STATE_DIR/media-1420"
printf '%s\tpool · img·grok\tgen\t\tj4\n' 1000 > "$STATE_DIR/media-1431"
printf '%s\tpool · speech·elevenlabs\tgen\t\tj5\n' "$((wp_now - 29))" > "$STATE_DIR/media-1450"
STATUSLINE_PS="$FAKE_PS_WORK" STATUSLINE_LSOF="$FAKE_LSOF_WORK" WORKER_RUN_DIR="$WP_RUNS" WORKER_STATS_DIR="$WP_STATS" \
  "$WORK_PROBE" wp-sess 1250
# Agent work first — workers, reviews, media, each oldest first — then tests and plain shell work,
# oldest first; the start column is checked apart from the rest. A worker is `tests` while a test
# runs under its supervisor, `start` until its first wait. Not shown as shell work: a call younger
# than 10s (1210), a call waiting on a run, which the run's own line carries (1220, 1500), processes
# that are no Bash call (the MCP server, the statusline), an orphan whose environment names another
# chat (3100), a finished run's supervisor (2100), and another chat's tests and waits (4002, 6001). A
# test file only NAMED by a command (`sed … tests/test_x.sh`) is no test. Nor a hook younger than 5s
# (1281) or a review panel's cell test, whose review line carries it (5001).
# A suite run is the repository it was handed whatever the cwd (1101); one with no pointer of its own
# (1321: older than its process) is still queued for a slot. A script under another repository is that
# repository's whatever the cwd (1311); a test that exec'd over its snapshot shell is still a test (1270); a shell label takes the
# plain word after the program only, never an option's operand (1300) nor inline code (1330).
# A worker in tests carries its test's start (field 7); a review its state, the state's short form and
# the judge's head, a cell group per vendor word: ✓ all clean, read/total passes, a late group in `{}`.
wp_view() { awk -F'\t' -v OFS='\t' '$2 == "worker" && $7 != "" { $7 = "@" } { print }' "$STATE_DIR/work-wp-sess" | cut -f1,2,4-8; }
assert_eq "$(printf '%s\n' \
  $'main\tworker\tacc · astra · high\tFix the parser\ttests\t@\t' \
  $'main\tworker\tcom · opus · high\tMap the hooks\tworking\t\t' \
  $'main\tworker\tlight research · 3.8-flash · rawilimo\tFind the docs\tworking\t\t' \
  $'main\tworker\tfix: com · opus · high\t2b3c4d5\tworking\t\t' \
  $'main\tworker\tcom · opus · high\tQueued task\tqueued\t\t' \
  $'main\tworker\tworker · 7-7-new\tNew task\tstart\t\t' \
  $'main\treview\tT0 · double · bugs\tclaude-setup, llm-legs\tall 5/8 a 1/2 b 1/2 c ✓ d 1/2 ✗1\tall 5/8\t' \
  $'main\treview\tT1 · standard · review\tllm-legs\t✓ report 3\t✓ report 3\tnotcom · opus · high' \
  $'main\treview\tT1 · standard · review\t\t✗ dead\t✗ dead\t' \
  $'main\treview\tT1 · standard · review\t\t✗ dead\t✗ dead\t' \
  $'main\treview\tT2 · standard · task\tHunt the stale rows\tall 0/2 {a 0/1} b 0/1\tall 0/2\t' \
  $'main\treview\tT1 · standard · bugs\tllm-legs\tall 2/2 a ✓ b ✓ · ✓ done\tall 2/2 · ✓ done\tnotcom · high' \
  $'main\treview\treview · bbbbbbb\t\t\t\t' \
  $'main\tmedia\tpool · img·web\tgen\t\t\t' \
  $'main\tmedia\tfanout · img\tall\t2\t1\t3' \
  $'main\tmedia\tcom · mus·app\tedit\t\t\t' \
  $'main\tmedia\tpool · speech·elevenlabs\tgen\t\t\t' \
  $'main\ttests\twp repo\tsuites\t2\t1\t5' \
  $'main\ttests\twp repo\tsuites queued\t\t\t' \
  $'main\ttests\twp repo\ttest_orphan\t\t\t' \
  $'main\ttests\twp-other\ttest_y\t\t\t' \
  $'main\ttests\twp-other\ttest_z\t\t\t' \
  $'main\ttests\twp repo\ttest_sid\t\t\t' \
  $'main\ttests\twp-plain\tpytest\t\t\t' \
  $'main\ttests\twp-plain\tvitest\t\t\t' \
  $'main\tshell\twp-plain\t\t\t\t' \
  $'main\tshell\twp-plain\tgit push\t\t\t' \
  $'main\tshell\twp-plain\tcurl\t\t\t' \
  $'main\tshell\twp-plain\tperl\t\t\t' \
  $'main\tshell\t⧉ wt-one\tgit push\t\t\t' \
  $'main\tshell\twp-plain\thook instruction-watch\t\t\t' \
  $'run\tcodex-7-7-live\tpnpm test')" "$(wp_view)"
assert_eq "$((wp_now - 179))" "$(awk -F'\t' '$4 == "pool · img·web" { print $3 }' "$STATE_DIR/work-wp-sess")"
# A worker starts at its run's start (state.json, else meta.json), a review at its document's, a
# document-less wait at the wait's own start; the worker's own token count rides in the ninth field.
assert_eq "600 300 100 50 40 20 900 700 650 600 400 350 50" "$(awk -F'\t' -v now="$wp_now" '$2 == "worker" || $2 == "review" { printf "%s%s", s, now - $3; s = " " }' \
  "$STATE_DIR/work-wp-sess" | sed -E 's/ (4[6-9]|50)$/ 50/')"
assert_eq "184321|||||" "$(awk -F'\t' '$2 == "worker" { printf "%s%s", s, $9; s = "|" }' "$STATE_DIR/work-wp-sess")"
wp_start=$(awk -F'\t' '$4 == "wp repo" && $5 == "suites" { print $3 }' "$STATE_DIR/work-wp-sess")
assert_eq "$WP_STAMP" "$wp_start"
wp_run_start=$(awk -F'\t' '$1 == "run" { print $3 }' "$STATE_DIR/work-wp-sess")
assert test "$wp_run_start" -ge "$((wp_now - 91))" -a "$wp_run_start" -le "$((wp_now - 87))"
assert_eq "$wp_run_start" "$(awk -F'\t' '$2 == "worker" && $7 != "" { print $7 }' "$STATE_DIR/work-wp-sess")"
# The judge phase runs from the judge's stamp (field 9), and the judge row names the run (field 10).
assert_eq "$((wp_now - 120)) 20261008T100000Z-ggggggg" "$(awk -F'\t' '$10 ~ /ggggggg$/ { print $9, $10 }' "$STATE_DIR/work-wp-sess")"
assert_eq "|$((wp_now - 120))||||" "$(awk -F'\t' '$2 == "review" && $10 !~ /jjjjjjj$/ { printf "%s%s", s, $9; s = "|" }' "$STATE_DIR/work-wp-sess")"
wp_judge=$(awk -F'\t' '$10 ~ /jjjjjjj$/ { print $9 }' "$STATE_DIR/work-wp-sess")
assert test "$wp_judge" -ge "$wp_now" -a "$wp_judge" -le "$((wp_now + 60))"
# A suite run counts from its pointer's stamp, the moment it took its slot.
assert_eq "$WP_LOGS" "$(awk -F'\t' '$2 == "tests" && $9 != "" { printf "%s%s", s, $9; s = " " }' "$STATE_DIR/work-wp-sess")"
wp_real=$(cd "$WP_REPO" && pwd -P)
assert_eq "$wp_real $wp_real" \
  "$(awk -F'\t' '$4 == "wp repo" && $5 == "suites" || $4 == "⧉ wt-one" { printf "%s%s", s, $10; s = " " }' "$STATE_DIR/work-wp-sess")"
wp_cols=$(wp_view)
rm -f "$STATE_DIR/work-wp-sess"
STATUSLINE_PS="$FAKE_PS_WORK" STATUSLINE_LSOF="$FAKE_LSOF_WORK" WORKER_RUN_DIR="$WP_RUNS" WORKER_STATS_DIR="$WP_STATS" \
  /bin/bash "$WORK_PROBE" wp-sess 1250
assert_eq "$wp_cols" "$(wp_view 2>/dev/null)"
# One jq formats every review document of the probe, however many there are.
printf 'jq() { local a="$*"; printf "%%s\\n" "${a//$'"'"'\\n'"'"'/ }" >>"$WP_JQ_CALLS"; command jq "$@"; }\n' >"$WORK/wp-count.sh"
: >"$WORK/wp-jq-calls"
STATUSLINE_PS="$FAKE_PS_WORK" STATUSLINE_LSOF="$FAKE_LSOF_WORK" WORKER_RUN_DIR="$WP_RUNS" WORKER_STATS_DIR="$WP_STATS" \
  BASH_ENV="$WORK/wp-count.sh" WP_JQ_CALLS="$WORK/wp-jq-calls" "$WORK_PROBE" wp-sess 1250
assert_eq "$wp_cols" "$(wp_view 2>/dev/null)"
assert_eq 1 "$(grep -cF "$WP_STATS/progress/" "$WORK/wp-jq-calls")"
# An unstamped judge phase keeps the start the last probe gave it.
perl -i -pe 's/\t[0-9]+(\t20261008T100000Z-jjjjjjj)$/\t12345$1/' "$STATE_DIR/work-wp-sess"
STATUSLINE_PS="$FAKE_PS_WORK" STATUSLINE_LSOF="$FAKE_LSOF_WORK" WORKER_RUN_DIR="$WP_RUNS" WORKER_STATS_DIR="$WP_STATS" \
  "$WORK_PROBE" wp-sess 1250
assert_eq 12345 "$(awk -F'\t' '$10 ~ /jjjjjjj$/ { print $9 }' "$STATE_DIR/work-wp-sess")"
unset STATUSLINE_NOW
# No chat above the start pid, or no process list: nothing is claimed.
STATUSLINE_PS="$FAKE_PS_WORK" STATUSLINE_LSOF="$FAKE_LSOF_WORK" WORKER_RUN_DIR="$WORK/none" "$WORK_PROBE" wp-noroot 3000
assert_eq "" "$(cat "$STATE_DIR/work-wp-noroot")"
STATUSLINE_PS=true "$WORK_PROBE" wp-sess 1250
assert_eq "" "$(cat "$STATE_DIR/work-wp-sess")"

IDLE_PS="$FIXTURES/idle-ps"
printf '#!/usr/bin/env bash\nprintf "1000 1 00:10 claude\\n1250 1000 00:01 bash statusline.sh\\n"\n' > "$IDLE_PS"
chmod +x "$IDLE_PS"
IDLE_BIN="$FIXTURES/idle-bin"
IDLE_CALLS="$WORK/idle-calls"
mkdir -p "$IDLE_BIN"
for idle_tool in git jq lsof; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 99\n' "$idle_tool" "$IDLE_CALLS" > "$IDLE_BIN/$idle_tool"
  chmod +x "$IDLE_BIN/$idle_tool"
done
PATH="$IDLE_BIN:$PATH" STATUSLINE_PS="$IDLE_PS" STATUSLINE_LSOF="$IDLE_BIN/lsof" \
  WORKER_RUN_DIR="$WORK/none" "$WORK_PROBE" wp-idle 1250
assert_eq "" "$(cat "$STATE_DIR/work-wp-idle")"
assert test ! -e "$IDLE_CALLS"
PATH="$IDLE_BIN:$PATH" STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$IDLE_BIN/lsof" \
  "$PORTS_PROBE" pp-idle-no-root 1 "$TOP_A"
assert test ! -e "$IDLE_CALLS"
PATH="$IDLE_BIN:$PATH" STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$FAKE_LSOF_EMPTY" \
  "$PORTS_PROBE" pp-idle-empty 1001 "$TOP_A"
assert_eq "" "$(cat "$STATE_DIR/ports-pp-idle-empty")"
assert test ! -e "$IDLE_CALLS"

# --- work lines ---
# The render reads the probe's cache only. Agent rows (worker, review, media) come before command rows
# (tests, shell) whatever the cache order; each row is `<head> — <title>` then three columns the
# visible rows share — state, elapsed, tokens — elapsed recomputed from the start column every render.
wl_strip() { perl -pe 's/\e\[[0-9;]*m//g'; }
# The render's clock is the fixture's: every fixture is written on wl_clock, which pins the render to it.
wl_clock() { wl_now=$(date +%s); export STATUSLINE_NOW=$wl_now; }
wl_cut() { perl -ne 'next if $. < 3; s/\e\[[0-9;]*m//g; print'; }
wl_rows() { run_statusline "$(statusline_payload "$1")" | wl_cut; }
wl_clock
# Each render gets its fixture rewritten on a fresh clock: a cache older than 4s also sends the
# render's probe to rewrite it, which empties one with no process behind it.
wl_mix() { wl_clock; {
  printf 'main\ttests\t%s\tllm-legs\ttest_statusline_hooks\t12\t1\t41\t\t\n' "$((wl_now - 245))"
  printf 'main\tshell\t%s\ttoken-map\tsleep\t\t\t\n' "$((wl_now - 45))"
  printf 'main\tworker\t%s\tlocomthebest · opus · high\tSpeed up tracking\ttests\t%s\t\t184321\n' "$((wl_now - 3725))" "$((wl_now - 65))"
  printf 'main\tworker\t%s\tcom · sonnet · medium\tSplit reviews\tworking\t\t\t900\n' "$((wl_now - 245))"
  printf 'main\treview\t%s\tT1 · standard · bugs\tllm-legs\tall 5/8 opus 2/3 ✗1 {gpt 1/3} pro ✓\tall 5/8\t\t\tx\n' "$((wl_now - 45))"
  printf 'run\tcodex-7-7-live\t%s\tpnpm test\n' "$((wl_now - 90))"
} > "$STATE_DIR/work-wl-mix"; }
wl_mix
wl_out=$(run_statusline "$(statusline_payload wl-mix)")
assert_eq "$(printf '%s\n' \
  'locomthebest · opus · high — Speed up tracking  tests 1m 05s                       1h 02m  ↓ 184k' \
  'com · sonnet · medium — Split reviews           working                            4m 05s   ↓ 900' \
  'T1 · standard · bugs — llm-legs                 all 5/8 opus 2/3 ✗1 gpt 1/3 pro ✓     45s' \
  'tests · llm-legs — test_statusline_hooks        12/41 ✗1                           4m 05s' \
  'shell · token-map — sleep                                                             45s')" "$(tail -n +3 <<< "$wl_out" | wl_strip)"
# Heads magenta on agent rows and cyan on command rows; an agent's title bright, a command's dim; ✗N red.
assert grep -Fq "${MAGENTA}locomthebest · opus · high${RESET} ${DIM}—${RESET} Speed up tracking " <<< "$wl_out"
assert grep -Fq "${MAGENTA}T1 · standard · bugs${RESET} ${DIM}—${RESET} llm-legs " <<< "$wl_out"
assert grep -Fq "${CYAN}tests · llm-legs${RESET} ${DIM}— test_statusline_hooks${RESET}" <<< "$wl_out"
assert grep -Fq "${CYAN}shell · token-map${RESET} ${DIM}— sleep${RESET}" <<< "$wl_out"
assert grep -Fq "${DIM}12/41 ${RESET}${RED}✗1${RESET}${DIM} " <<< "$wl_out"
assert_fails grep -Fq "${RED}5/8" <<< "$wl_out"
# A review's cell groups: ✓ green, ✗N red, a late group (`{…}` in the cache) wholly red.
assert grep -Fq "${DIM}all 5/8 opus 2/3 ${RESET}${RED}✗1${RESET}${DIM} ${RESET}${RED}gpt 1/3${RESET}${DIM} pro ${RESET}${GREEN}✓${RESET}${DIM}" <<< "$wl_out"
printf 'main\treview\t%s\tT0 · double · bugs\tllm-legs\tall 2/4 {a 1/2 ✗1} b ✓\tall 2/4\t\t\tx\n' "$((wl_now - 45))" > "$STATE_DIR/work-wl-late"
assert grep -Fq "${DIM}all 2/4 ${RESET}${RED}a 1/2 ✗1${RESET}${DIM} b ${RESET}${GREEN}✓" <<< "$(run_statusline "$(statusline_payload wl-late)")"
# The judge phase: the review's elapsed stops at the phase start and a magenta judge row follows,
# titled by the run's last seven characters and timed from the phase start; a dead run has none.
wl_judge() { wl_clock; {
  printf 'main\treview\t%s\tT1 · standard · bugs\tllm-legs\t✓ report 3\t✓ report 3\tnotcom\t%s\t20261009T100000Z-1234567\n' "$((wl_now - 3725))" "$((wl_now - 245))"
  printf 'main\treview\t%s\tT0 · double · bugs\tllm-legs\tall 4/4 a ✓ b ✗2 · ✓ done\tall 4/4 · ✓ done\tnotcom · opus · high\t%s\t20261009T100000Z-abcdefg\n' "$((wl_now - 245))" "$((wl_now - 45))"
  printf 'main\treview\t%s\tT1 · standard · bugs\t\t✗ dead\t✗ dead\t\t\t20261009T100000Z-7654321\n' "$((wl_now - 65))"
} > "$STATE_DIR/work-wl-judge"; }
wl_judge
wl_judged=$(run_statusline "$(statusline_payload wl-judge)")
assert_eq "$(printf '%s\n' \
  'T1 · standard · bugs — llm-legs        ✓ report 3                 58m 00s' \
  'judge: notcom — 1234567                                            4m 05s' \
  'T0 · double · bugs — llm-legs          all 4/4 a ✓ b ✗2 · ✓ done   3m 20s' \
  'judge: notcom · opus · high — abcdefg                                 45s' \
  'T1 · standard · bugs                   ✗ dead                      1m 05s')" "$(wl_cut <<< "$wl_judged")"
assert grep -Fq "${MAGENTA}judge: notcom · opus · high${RESET} ${DIM}—${RESET} abcdefg " <<< "$wl_judged"
assert grep -Fq "${DIM}${RESET}${GREEN}✓${RESET}${DIM} report 3" <<< "$wl_judged"
assert grep -Fq "${DIM}${RESET}${RED}✗${RESET}${DIM} dead" <<< "$wl_judged"
# Narrower: only titles shrink at first; then every state takes its short form, then heads lose their
# tail down to their first word. Elapsed and tokens never shrink.
assert_eq "$(printf '%s\n' \
  'T1 · standard · bugs    ✓ report 3        58m 00s' \
  'judge: notcom — 12345…                     4m 05s' \
  'T0 · double · bugs      all 4/4 · ✓ done   3m 20s' \
  'judge: notcom · opus…                         45s' \
  'T1 · standard · bugs    ✗ dead             1m 05s')" "$(wl_judge; FIT_COLUMNS=50 FIT_MARGIN=1 wl_rows wl-judge)"
assert_eq "$(printf '%s\n' \
  'locomthebest · opus · high — Spe…  tests     1h 02m  ↓ 184k' \
  'com · sonnet · medium — Split re…  working   4m 05s   ↓ 900' \
  'T1 · standard · bugs — llm-legs    all 5/8      45s' \
  'tests · llm-legs — test_statusli…  12/41 ✗1  4m 05s' \
  'shell · token-map — sleep                       45s')" "$(wl_mix; FIT_COLUMNS=63 FIT_MARGIN=4 wl_rows wl-mix)"
assert_eq "$(printf '%s\n' \
  'locomthebest…  tests     1h 02m  ↓ 184k' \
  'com · sonnet…  working   4m 05s   ↓ 900' \
  'T1 · standar…  all 5/8      45s' \
  'tests · llm-…  12/41 ✗1  4m 05s' \
  'shell · toke…               45s')" "$(wl_mix; FIT_COLUMNS=40 FIT_MARGIN=1 wl_rows wl-mix)"
# A column no visible row fills takes no space; a short row is padded so elapsed ends where the rest do.
wl_plain() { wl_clock; {
  printf 'main\tshell\t%s\tr\tsleep\t\t\t\n' "$((wl_now - 45))"
  printf 'main\tshell\t%s\trepo\tgit push\t\t\t\n' "$((wl_now - 245))"
} > "$STATE_DIR/work-wl-plain"; }
assert_eq "$(printf '%s\n' \
  'shell · r — sleep           45s' \
  'shell · repo — git push  4m 05s')" "$(wl_plain; wl_rows wl-plain)"
# Work rows keep one cell more than the shared margin: the harness pads its footer two cells a side.
assert_eq "$(printf '%s\n' \
  'shell · r — sleep     45s' \
  'shell · repo — g…  4m 05s')" "$(wl_plain; FIT_COLUMNS=26 FIT_MARGIN=1 wl_rows wl-plain)"
# A record with no repository or no label keeps its fields in place: tab is IFS whitespace to `read`.
wl_clock
printf 'main\ttests\t%s\t\tsuites\t2\t1\t5\nmain\tshell\t%s\tr\t\t\t\t\n' "$((wl_now - 45))" "$((wl_now - 45))" > "$STATE_DIR/work-wl-norepo"
assert_eq "$(printf '%s\n' 'tests — suites  2/5 ✗1  45s' 'shell · r               45s')" "$(wl_rows wl-norepo)"
# Elapsed pads its seconds or minutes to two digits; tokens read ↓ 900, ↓ 37k, ↓ 184k, ↓ 1.2M.
wl_clock
{
  printf 'main\tworker\t%s\ta · m · e\tone\tworking\t\t\t900\n' "$((wl_now - 3725))"
  printf 'main\tworker\t%s\ta · m · e\ttwo\tworking\t\t\t37400\n' "$((wl_now - 245))"
  printf 'main\tworker\t%s\ta · m · e\tthree\tworking\t\t\t184999\n' "$((wl_now - 45))"
  printf 'main\tworker\t%s\ta · m · e\tfour\tstart\t\t\t1234567\n' "$((wl_now - 7))"
  printf 'main\tworker\t%s\ta · m · e\tfive\tworking\t\t\t\n' "$((wl_now - 65))"
} > "$STATE_DIR/work-wl-tok"
assert_eq "$(printf '%s\n' \
  'a · m · e — one    working  1h 02m   ↓ 900' \
  'a · m · e — two    working  4m 05s   ↓ 37k' \
  'a · m · e — three  working     45s  ↓ 184k' \
  'a · m · e — four   start        7s  ↓ 1.2M' \
  'a · m · e — five   working  1m 05s')" "$(wl_rows wl-tok)"
# A media-run job: `media · <tag>` is the head, its label the title, a fan-out's cells the state.
wl_media() { wl_clock; printf 'main\tmedia\t%s\tnotcom · img·web\tedit\t\t\t\t\nmain\tmedia\t%s\tfanout · img\tall\t2\t1\t3\t\n' \
  "$((wl_now - 65))" "$((wl_now - 30))" > "$STATE_DIR/work-wl-media"; }
wl_media
wl_media_out=$(run_statusline "$(statusline_payload wl-media)")
assert_eq "$(printf '%s\n' \
  'media · notcom · img·web — edit          1m 05s' \
  'media · fanout · img — all       2/3 ✗1     30s')" "$(wl_cut <<< "$wl_media_out")"
assert grep -Fq "${MAGENTA}media · notcom · img·web${RESET}" <<< "$wl_media_out"
# At most five rows; the rest is one dim line of hidden counts by kind, agents first, singular for one.
wl_cap() { # session workers reviews media commands
  local i
  for ((i = 0; i < $2; i++)); do printf 'main\tworker\t%s\ta · m · e\tw%s\tworking\t\t\t\n' "$((wl_now - 100 + i))" "$i"; done
  for ((i = 0; i < $3; i++)); do printf 'main\treview\t%s\tT0 · double · bugs\tr%s\t\t\t\t\n' "$((wl_now - 100 + i))" "$i"; done
  for ((i = 0; i < $4; i++)); do printf 'main\tmedia\t%s\tpool · img·web\tgen\t\t\t\t\n' "$((wl_now - 100 + i))"; done
  for ((i = 0; i < $5; i++)); do printf 'main\tshell\t%s\tr\tjob%s\t\t\t\n' "$((wl_now - 100 + i))" "$i"; done
}
wl_cap wl-cap 8 2 1 3 > "$STATE_DIR/work-wl-cap"
wl_capped=$(run_statusline "$(statusline_payload wl-cap)")
assert_eq 8 "$(printf '%s\n' "$wl_capped" | wc -l | tr -d ' ')"
assert_eq "${DIM}+3 workers, 2 reviews, 1 media, 3 commands${RESET}" "$(tail -n1 <<< "$wl_capped")"
assert_eq 'w0 w1 w2 w3 w4' "$(sed -n 3,7p <<< "$wl_capped" | wl_strip | awk '{ print $7 }' | paste -sd' ' -)"
wl_cap wl-cap1 6 1 0 1 > "$STATE_DIR/work-wl-cap1"
assert_eq '+1 worker, 1 review, 1 command' "$(wl_rows wl-cap1 | tail -n1)"
wl_cap wl-cap5 5 0 0 0 > "$STATE_DIR/work-wl-cap5"
assert_eq 5 "$(wl_rows wl-cap5 | grep -c .)"
# A judge row takes a slot of its own and never shows without its review: a pair that no longer fits
# hides whole, as one review, and so does everything after it.
wl_pair() { # session workers
  local i
  for ((i = 0; i < $2; i++)); do printf 'main\tworker\t%s\ta · m · e\tw%s\tworking\t\t\t\n' "$((wl_now - 100 + i))" "$i"; done
  printf 'main\treview\t%s\tT0 · double · bugs\tr\tall 1/1 a ✓ · ✓ done\tall 1/1 · ✓ done\tacc\t%s\t20261009T100000Z-abcdefg\n' "$((wl_now - 50))" "$((wl_now - 10))"
  printf 'main\tshell\t%s\tr\tjob\t\t\t\n' "$((wl_now - 40))"
}
wl_pair wl-pair3 3 > "$STATE_DIR/work-wl-pair3"
assert_eq 'w0 w1 w2 r abcdefg +1 command' "$(wl_rows wl-pair3 | awk '{ print ($1 == "judge:") ? $4 : ($1 ~ /^\+/) ? $0 : $7 }' | paste -sd' ' -)"
wl_pair wl-pair4 4 > "$STATE_DIR/work-wl-pair4"
wl_pair4=$(wl_rows wl-pair4)
assert_eq '+1 review, 1 command' "$(tail -n1 <<< "$wl_pair4")"
assert_eq 4 "$(grep -c ' — w' <<< "$wl_pair4")"
# Every width, UTF-8 or not: a row never outgrows COLUMNS − STATUSLINE_FIT_MARGIN while its floor
# (first head word, short states, elapsed, tokens) fits; past that it is exactly that floor. Elapsed and
# tokens stay whole and the right columns line up across rows.
{
  printf 'main\tworker\t%s\tcom · opus · high\t%s\ttests\t%s\t\t184321\n' "$((wl_now - 756))" \
    "$(printf 'Speed up tracking of the review rows %.0s' 1 2 3 4 5 6 | cut -c1-200)" "$((wl_now - 95))"
  printf 'main\treview\t%s\tT1 · standard · bugs\tllm-legs\tall 5/7 opus ✓ gpt 2/4 verify pro ✗2 {grok 0/1}\tall 5/7\t\t\tx\n' "$((wl_now - 994))"
  printf 'main\tmedia\t%s\tpool · img·web\tgen\t\t\t\t\n' "$((wl_now - 414))"
  printf 'main\tshell\t%s\tegorloy\tsleep\t\t\t\n' "$((wl_now - 45))"
  printf 'main\tshell\t%s\tegorloy\tzsh\t\t\t\n' "$((wl_now - 3725))"
} > "$STATE_DIR/work-wl-wide"
mkdir -p "$WORK/wl-wide"
# A cache older than 4s sends the render's probe to rewrite it, and this one has no process behind it:
# dated ahead, it stays fresh for the whole sweep. The rows read no git state, so the cwd is no repository.
perl -e 'utime time, time + 600, $ARGV[0]' "$STATE_DIR/work-wl-wide"
wl_payload=$(statusline_payload wl-wide '' "$WORK/wl-wide")
wl_jobs=0
for wl_locale in UTF-8 C; do
  for ((wl_cols = 30; wl_cols <= 200; wl_cols++)); do
    if [ "$wl_locale" = C ]; then
      LC_ALL=C FIT_COLUMNS=$wl_cols FIT_MARGIN=4 run_statusline "$wl_payload" > "$WORK/wl-wide/$wl_locale-$wl_cols" &
    else
      FIT_COLUMNS=$wl_cols FIT_MARGIN=4 run_statusline "$wl_payload" > "$WORK/wl-wide/$wl_locale-$wl_cols" &
    fi
    wl_jobs=$((wl_jobs + 1))
    [ "$wl_jobs" -ge 16 ] || continue
    if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
      wait -n; wl_jobs=$((wl_jobs - 1))
    else
      wait; wl_jobs=0
    fi
  done
done
wait
assert_eq "" "$(perl -CSD -Mutf8 -e '
  for my $f (@ARGV) {
    my ($cols) = $f =~ /-(\d+)$/; my $budget = $cols - 4; my (%end, $n);
    open my $h, "<", $f or die; my ($tag) = $f =~ m{([^/]+)$};
    while (<$h>) {
      next if $. < 3;
      chomp; s/\e\[[0-9;]*m//g; $n++;
      if (!/(\d+[hms](?: \d\d[ms])?)(  ↓ \d+k)?$/ || ($n == 1 && !$2)) { print "$tag row $n: elapsed or tokens cut\n"; next }
      $end{length($`) + length($1)}++;
      print "$tag row $n: ", length($_), " cells\n" if length($_) > $budget && !/^[^ …]+…? {2,}\S/;
    }
    print "$tag: columns differ or rows lost\n" if keys(%end) != 1 || $n != 5;
  }' "$WORK"/wl-wide/*)"
# A cache the probe stopped refreshing is hidden, and an absent one sends the probe to write it.
touch -t 202001010000 "$STATE_DIR/work-wl-mix"
assert_eq 2 "$(printf '%s\n' "$(run_statusline "$(statusline_payload wl-mix)")" | wc -l | tr -d ' ')"
rm -f "$STATE_DIR/work-wl-fire"
run_statusline "$(statusline_payload wl-fire)" >/dev/null
for wl_i in $(seq 1 60); do [ -e "$STATE_DIR/work-wl-fire" ] && break; sleep 0.05; done
assert test -e "$STATE_DIR/work-wl-fire"
unset STATUSLINE_NOW

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

fi
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
# The limits state render-pins leaves behind, so the worker-tag renders read it in any shard.
printf '{}' > "$WORK/limits.json"
RUN_STATUSLINE_DEFAULT_ACCOUNT=
seed_rl_cache

if suite_shard_owns 3 worker-tags; then
# A fork's first call claims the seed its spawn left and prefixes the tag; later calls reuse it, a
# prefixed description never stacks, and no relay token rides any call.
mkdir -p "$TAGDIR"
printf 'fork · opus · com\nspawn=0000000000000000\n' > "$TAGDIR/pending-fork-u1"
fork_first=$(worker_payload fork worker/one 'Investigate the suite' 'ls' | "$WORKER_HOOK") || fail "fork seed exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput == {command:"ls",description:"fork · opus · com — Investigate the suite",timeout:42}' <<< "$fork_first" >/dev/null
assert_eq 'fork · opus · com' "$(head -n1 "$TAGDIR/workerone")"
assert test ! -e "$TAGDIR/pending-fork-u1"
fork_later=$(worker_payload fork worker/one 'Run focused tests' 'worker-run report codex-1-2-abcd' | "$WORKER_HOOK") || fail "fork rewrite exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "fork · opus · com — Run focused tests" and
  .hookSpecificOutput.updatedInput.command == "worker-run report codex-1-2-abcd"' <<< "$fork_later" >/dev/null
assert_eq "" "$(worker_payload fork worker/one 'fork · opus · com — Run focused tests' true | "$WORKER_HOOK")"
# A retired relay type gets no tag and no token, launch line or not.
for retired in codex-worker claudeb-worker light-research review-waiter; do
  assert_eq "" "$(worker_payload "$retired" worker/retired 'Launch the run' "codex exec -c model_reasoning_effort=high 'go'" | "$WORKER_HOOK")"
done
assert test ! -e "$TAGDIR/workerretired"

# A stored tag carrying regex-special chars is matched literally, so an
# already-prefixed description never stacks.
printf 'com [1m] · high\n' > "$TAGDIR/workerbr"
br_output=$(worker_payload fork worker/br 'com [1m] · high — Run tests' true | "$WORKER_HOOK") || fail "bracket-tag idempotent call exited nonzero"
assert_eq "" "$br_output"

no_agent=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_id:"workerone",tool_input:{command:"true",description:"Run"}}')
no_agent_output=$(printf '%s' "$no_agent" | "$WORKER_HOOK") || fail "no-agent call exited nonzero"
assert_eq "" "$no_agent_output"

wrong_event=$(worker_payload fork worker/three 'Worker account: alt · high' true | jq -c '.hook_event_name = "PostToolUse"')
wrong_event_output=$(printf '%s' "$wrong_event" | "$WORKER_HOOK") || fail "non-PreToolUse seed exited nonzero"
assert_eq "" "$wrong_event_output"
assert test ! -e "$TAGDIR/workerthree"

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
# Neither slot carries a word, so silence is the absence of every shape the run's counter and the
# autonomy dot can take. Asked of line 1 alone, because line 2 opens segments with digits (`5h`).
review_slot_silent() { # rendered
  case "${1%%$'\n'*}" in
    *" ${DIM}│${RESET} "[0-9~]*|*" ${DIM}│${RESET} T"[0-3]*|*" ${DIM}│${RESET} ● "*) return 1 ;;
    *" ${DIM}│${RESET} ${DIM}"[0-9~?]*|*" ${DIM}│${RESET} ${DIM}T"[0-3]*) return 1 ;;
    *" ${DIM}│${RESET} ${DIM}fix "*) return 1 ;;
    *" ${DIM}│${RESET} ${RED}"[0-9]*|*" ${DIM}│${RESET} ${RED}T"[0-3]*) return 1 ;;
  esac
  return 0
}

# The gate supplies one chat fact here, `autonomous <sid>`; any other verb it is asked gets
# GATE_ANSWER, so a render that still asked for a per-chat verdict would show it.
GATE_LOG="$WORK/gate.log"
GATE_STUB="$FIXTURES/gate-stub.sh"
cat > "$GATE_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GATE_LOG"
case "$1" in
  autonomous) printf '%s\n' "${GATE_AUTONOMOUS-}"; exit "${GATE_VERB_RC:-0}" ;;
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

# Two renders per case, because the gate is never asked on the render path: the first starts the
# refresh, the second reads what landed.
review_await_session() { # session
  local file="$STATE_DIR/review-autonomy-$1" i
  for i in $(seq 1 100); do
    [ -s "$file" ] && [ ! -d "$file.lock" ] && return 0
    sleep 0.05
  done
  fail "the backgrounded session answer never landed: $1"
}
review_render() { # session repo
  run_statusline "$(statusline_payload "$1" "" "$2")" || fail "review render failed: $1"
}
review_session_render() { # session repo
  local payload
  rm -f "$STATE_DIR/review-autonomy-$1"
  rmdir "$STATE_DIR/review-autonomy-$1.lock" 2>/dev/null
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "review session render failed: $1"
  review_await_session "$1"
  run_statusline "$payload" || fail "review session render failed: $1"
}
review_seg=" ${DIM}│${RESET} "

# Debt is per repository (a dim `N`, below): no per-chat number reaches the strip, whatever the gate
# would answer, and the gate is never asked for one.
: > "$GATE_LOG"
GATE_AUTONOMOUS=no
for review_gone in 'STATUS=open LINES=3 FILES=1 FIX=0 WHY=none' 'STATUS=open LINES=0 FILES=0 FIX=3 WHY=none' \
    'STATUS=unknown LINES=0 FILES=0 FIX=0 WHY=gap' 'held because'; do
  GATE_ANSWER="$review_gone"
  review_gone_out=$(review_session_render review-gone "$REVIEW_DIRTY")
  assert review_slot_silent "$review_gone_out"
  assert test "${review_gone_out#*"${review_seg}${DIM}?"}" = "$review_gone_out"
done
assert_eq 0 "$(grep -c '^verdict ' "$GATE_LOG" | tr -d ' ')"
GATE_ANSWER=off

# Nothing is spawned behind the label beyond the read-only autonomy ask: a background review-bench
# per render is what the tier number used to cost.
rm -f "$HOME/.cache/claude-statusline"/review-tier-*
review_render review-dirty "$REVIEW_DIRTY" >/dev/null
review_tier_us=${EPOCHREALTIME//[!0-9]/}

# `autonomous <sid>` is the gate's alone, and a gate that does not know the verb leaves no mark.
GATE_AUTONOMOUS=yes
review_auto_on_out=$(review_session_render review-auto-on "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}●" <<< "$review_auto_on_out"
assert test "${review_auto_on_out#*auto}" = "$review_auto_on_out"
review_auto_narrow_out=$(FIT_COLUMNS=24 review_session_render review-auto-narrow "$REVIEW_DIRTY")
assert grep -Fq "${review_seg}●" <<< "$review_auto_narrow_out"
GATE_AUTONOMOUS=no
review_auto_off_out=$(review_session_render review-auto-off "$REVIEW_DIRTY")
assert test "${review_auto_off_out#*●}" = "$review_auto_off_out"
GATE_AUTONOMOUS=
GATE_VERB_RC=1
review_stub_out=$(review_session_render review-stub-verbs "$REVIEW_DIRTY")
assert test "${review_stub_out#*●}" = "$review_stub_out"
GATE_VERB_RC=0
# Asked once per TTL, not once per render: a second render with nothing moved comes off the cache.
GATE_AUTONOMOUS=yes
: > "$GATE_LOG"
review_session_render review-cache "$REVIEW_DIRTY" >/dev/null
review_render review-cache "$REVIEW_DIRTY" >/dev/null
assert_eq 1 "$(grep -c '^autonomous ' "$GATE_LOG" | tr -d ' ')"

# The mark sits after the repository cluster and its ports, and before the pin.
review_mark_delimited="${review_seg}●"
write_chat_pin review-order 'grok_profile=a'
printf '5173\n' > "$STATE_DIR/ports-review-order"
review_order_line=$(review_session_render review-order "$REVIEW_DIRTY")
review_order_line="${review_order_line%%$'\n'*}"
review_before="${review_order_line%%"$review_mark_delimited"*}"
review_after="${review_order_line#*"$review_mark_delimited"}"
assert grep -Fq "$(basename "$REVIEW_DIRTY")" <<< "$review_before"
assert grep -Fq ":5173" <<< "$review_before"
assert test "${review_before#*"$PIN_MARK"}" = "$review_before"
assert grep -Fq "$PIN_MARK" <<< "$review_after"
rm -f "$STATE_DIR/ports-review-order"
GATE_AUTONOMOUS=

# A probe the review-dirty render spawned has had a full second to land by now.
review_tier_us=$((1000000 - ${EPOCHREALTIME//[!0-9]/} + review_tier_us))
[ "$review_tier_us" -le 0 ] || sleep "$((review_tier_us / 1000000)).$(printf '%06d' $((review_tier_us % 1000000)))"
asserts=$((asserts + 1))
test -z "$(ls "$HOME/.cache/claude-statusline"/review-tier-* 2>/dev/null)" ||
  fail "the review segment still spawned a probe: $(ls "$HOME/.cache/claude-statusline")"

# --- the FOLDER's debt beside the folder's diff ------------------------------------------------
# A second number about the same tree and a different question: what the whole repository owes,
# whoever wrote it. It follows the folder, never the chat, and renders nothing it cannot read.
DEBT_STUB="$FIXTURES/repo-debt-stub.sh"
cat > "$DEBT_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$DEBT_LOG"
[ -n "${DEBT_SLEEP:-}" ] && sleep "$DEBT_SLEEP"
[ -z "${DEBT_HOLD:-}" ] || for _ in $(seq 1 160); do [ -e "$DEBT_HOLD" ] && break; sleep 0.05; done
printf '%s\n' "$DEBT_ANSWER"
STUB
chmod +x "$DEBT_STUB"
DEBT_LOG="$WORK/repo-debt.log"
export DEBT_LOG DEBT_ANSWER DEBT_SLEEP DEBT_HOLD
DEBT_ANSWER='LINES=0 FILES=0'
DEBT_SLEEP=
DEBT_HOLD=
REVIEW_OTHER="$FIXTURES/review-other-folder"
mkdir -p "$REVIEW_OTHER"
git -C "$REVIEW_OTHER" init -q -b main
printf 'other\n' > "$REVIEW_OTHER/tracked.txt"
git -C "$REVIEW_OTHER" add tracked.txt
git -C "$REVIEW_OTHER" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
TOP_REVIEW_OTHER=$(cd "$REVIEW_OTHER" && pwd -P)
# Two renders per case: the first starts the background walk, the second reads what landed.
debt_render() { # session repo
  local payload cache i
  cache="$2"; cache=${cache//%/%25}; cache="$STATE_DIR/repo-debt-${cache//\//%2F}"
  rm -f "$STATE_DIR/repo-debt-"* 2>/dev/null
  rmdir "$STATE_DIR/repo-debt-"*.lock 2>/dev/null
  payload=$(statusline_payload "$1" "" "$2")
  run_statusline "$payload" >/dev/null || fail "repo debt render failed: $1"
  [ -x "${DEBT_CMD:-}" ] && for i in $(seq 1 100); do
    compgen -G "$STATE_DIR/repo-debt-*" >/dev/null 2>&1 &&
      ! compgen -G "$STATE_DIR/repo-debt-*.lock" >/dev/null 2>&1 && break
    sleep 0.05
  done
  run_statusline "$payload" || fail "repo debt render failed: $1"
}
debt_settle() {
  local i
  for i in $(seq 1 200); do
    compgen -G "$STATE_DIR/repo-debt-*" >/dev/null 2>&1 &&
      ! compgen -G "$STATE_DIR/repo-debt-*.lock" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
}
DEBT_CMD="$DEBT_STUB"
: > "$DEBT_LOG"
DEBT_ANSWER='LINES=153 FILES=16'
debt_mark_out=$(debt_render repo-debt-shown "$REVIEW_DIRTY")
assert grep -Fq "${DIM}153${RESET}" <<< "$debt_mark_out"
assert test "${debt_mark_out#*∑}" = "$debt_mark_out"
assert grep -Fqx -e "--repo $TOP_REVIEW_DIRTY" "$DEBT_LOG"
# It follows the FOLDER: a render of another tree asks about that tree and shows its number.
DEBT_ANSWER='LINES=4 FILES=2'
debt_other_out=$(debt_render repo-debt-shown "$REVIEW_OTHER")
assert grep -Fq "${DIM}4${RESET}" <<< "$debt_other_out"
assert test "${debt_other_out#*${DIM}153}" = "$debt_other_out"
assert grep -Fqx -e "--repo $TOP_REVIEW_OTHER" "$DEBT_LOG"
# The folder debt outlives every name abbreviation: it is still there while the model, the account
# and the directory are already being cut (steps 5-6), and only step 7 takes it off the line.
DEBT_ANSWER='LINES=153 FILES=16'
debt_render repo-debt-narrow "$REVIEW_DIRTY" >/dev/null
debt_narrow_out=$(FIT_COLUMNS=24 run_statusline "$(statusline_payload repo-debt-narrow "" "$REVIEW_DIRTY")")
assert test "${debt_narrow_out#*153}" = "$debt_narrow_out"
debt_fit() { FIT_COLUMNS="$1" run_statusline "$(statusline_payload repo-debt-narrow "" "$REVIEW_DIRTY")"; }
# Step 1 takes the diff signs off; the debt was a bare dim number all along.
debt_short_out=$(debt_fit 47)
assert grep -Fq "${GREEN}21${RESET}/${RED}0${RESET}" <<< "$debt_short_out"
assert grep -Fq "${DIM}153${RESET}" <<< "$debt_short_out"
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
  assert test "${debt_quiet_out#*${DIM}153${RESET}}" = "$debt_quiet_out"
  assert test "${debt_quiet_out#*${DIM}0${RESET}}" = "$debt_quiet_out"
done
# A binary that is gone, and one too slow to answer, are both silence in the line — never an error
# in it and never a number left over from the tree before.
DEBT_ANSWER='LINES=9 FILES=1'
DEBT_CMD="$FIXTURES/no-such-review-debt"
debt_gone_out=$(debt_render repo-debt-gone "$REVIEW_DIRTY")
assert test "${debt_gone_out#*${DIM}9${RESET}}" = "$debt_gone_out"
DEBT_CMD="$DEBT_STUB"
DEBT_SLEEP=0.4
debt_slow_out=$(run_statusline "$(statusline_payload repo-debt-slow "" "$REVIEW_DIRTY")")
assert test "${debt_slow_out#*${DIM}9${RESET}}" = "$debt_slow_out"
# The slow probe still lands after its render; under load it would land inside the next case.
debt_settle
DEBT_SLEEP=
# A machine with neither `timeout` nor `gtimeout` bounds the walk itself: the render is as silent as
# with one, and the probe still frees its lock, so the next render is never blocked by a dead one.
DEBT_CMD="$DEBT_STUB"
DEBT_ANSWER='LINES=21 FILES=5'
DEBT_SLEEP=0.4
debt_cache=${TOP_REVIEW_DIRTY//%/%25}; debt_cache="$STATE_DIR/repo-debt-${debt_cache//\//%2F}"
debt_lock="$debt_cache.lock"
rm -f "$STATE_DIR/repo-debt-"* 2>/dev/null
rmdir "$STATE_DIR/repo-debt-"*.lock 2>/dev/null
debt_nt_out=$(NO_TIMEOUT_BIN=1 run_statusline \
  "$(statusline_payload repo-debt-no-timeout "" "$REVIEW_DIRTY")")
assert test "${debt_nt_out#*${DIM}21${RESET}}" = "$debt_nt_out"
debt_settle
assert test ! -d "$debt_lock"
assert grep -Fq "${DIM}21${RESET}" <<< "$(NO_TIMEOUT_BIN=1 run_statusline \
  "$(statusline_payload repo-debt-no-timeout "" "$REVIEW_DIRTY")")"
# The lock a probe removes is the one it made. A walk still running when its lock is swept as dead
# leaves the sweeper's own lock standing, or two full walks run over the same tree at once.
rm -f "$STATE_DIR/repo-debt-"* 2>/dev/null
DEBT_SLEEP=
DEBT_HOLD="$WORK/debt-hold-lock-owner"
NO_TIMEOUT_BIN=1 run_statusline \
  "$(statusline_payload repo-debt-lock-owner "" "$REVIEW_DIRTY")" >/dev/null
for debt_wait in $(seq 1 100); do
  [ -d "$debt_lock" ] && break
  sleep 0.05
done
assert test -d "$debt_lock"
rmdir "$debt_lock" && mkdir "$debt_lock"
touch "$DEBT_HOLD"
for debt_wait in $(seq 1 100); do
  [ -s "$debt_cache" ] && break
  sleep 0.05
done
sleep 0.2
assert test -d "$debt_lock"
rmdir "$debt_lock" 2>/dev/null
# The walk prices the whole family, so an answer whose key still holds is asked again only past
# 300s, and stands that long. The shown tree's HEAD and diff counters are in the key: moving them
# asks again once the answer is 15s old, and the old number stands its 120s meanwhile.
DEBT_HOLD=
DEBT_ANSWER='LINES=33 FILES=3'
debt_render repo-debt-key "$REVIEW_DIRTY" >/dev/null
debt_settle
debt_payload=$(statusline_payload repo-debt-key "" "$REVIEW_DIRTY")
debt_age() { age_path "$1" "$debt_cache"; }
debt_asked() {
  local i
  for i in $(seq 1 40); do [ -s "$DEBT_LOG" ] && break; sleep 0.05; done
  debt_settle
  [ -s "$DEBT_LOG" ]
}
debt_unasked() { sleep 0.3; debt_settle; [ ! -s "$DEBT_LOG" ]; }
: > "$DEBT_LOG"; debt_age 200
debt_held_out=$(run_statusline "$debt_payload")
assert grep -Fq "${DIM}33${RESET}" <<< "$debt_held_out"
assert debt_unasked
: > "$DEBT_LOG"; debt_age 301
run_statusline "$debt_payload" >/dev/null
assert debt_asked
debt_settle
printf 'line\n' >> "$REVIEW_DIRTY/change.txt"
DEBT_ANSWER='LINES=34 FILES=3'
: > "$DEBT_LOG"; debt_age 10
assert grep -Fq "${DIM}33${RESET}" <<< "$(run_statusline "$debt_payload")"
assert debt_unasked
debt_age 20
assert grep -Fq "${DIM}33${RESET}" <<< "$(run_statusline "$debt_payload")"
assert debt_asked
assert grep -Fq "${DIM}34${RESET}" <<< "$(run_statusline "$debt_payload")"
printf 'line\n%.0s' {1..21} > "$REVIEW_DIRTY/change.txt"
: > "$DEBT_LOG"; debt_age 200
DEBT_HOLD="$WORK/debt-hold-moved"
debt_moved_out=$(run_statusline "$debt_payload")
assert test "${debt_moved_out#*${DIM}34${RESET}}" = "$debt_moved_out"
touch "$DEBT_HOLD"
debt_settle
DEBT_HOLD=
DEBT_ANSWER='LINES=0 FILES=0'
DEBT_CMD=
rm -f "$STATE_DIR/repo-debt-"* 2>/dev/null

# --- the real gate --------------------------------------------------------------------------
# The stub above proves the rendering; this proves the wiring against the hook that actually answers.
# An unreadable neighbour is a FAIL naming CLAUDE_SETUP_ROOT, never a skip.
REAL_GATE="${CLAUDE_SETUP_ROOT:-$PROJECTS/claude-setup}/hooks/review-flow-gate.sh"
if [ -x "$REAL_GATE" ]; then
  GATE_CMD="$REAL_GATE"
  real_objects_before=$(find "$REVIEW_DIRTY/.git/objects" -type f | wc -l | tr -d ' ')
  review_real_out=$(review_session_render review-real "$REVIEW_DIRTY")
  assert review_slot_silent "$review_real_out"
  assert test "${review_real_out#*●}" = "$review_real_out"
  assert_eq "$real_objects_before" \
    "$(find "$REVIEW_DIRTY/.git/objects" -type f | wc -l | tr -d ' ')"
else
  fail "review label against the real review gate: $REAL_GATE is not executable (set CLAUDE_SETUP_ROOT)"
fi
GATE_CMD="$GATE_STUB"
GATE_ANSWER=off
GATE_RC=0

# --- a commit of this chat its upstream does not hold ----------------------------------------
# The marker is the gate's `unpushed` answer and nothing else: the Stop ask that tells the chat to
# push reads that same subcommand, so a marker deriving ownership on its own would stand over
# commits that ask disowns. A stub answers it apart from the gate's other verbs.
UNPUSHED_STUB="$FIXTURES/unpushed-gate-stub.sh"
cat > "$UNPUSHED_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GATE_LOG"
[ -z "${GATE_HOLD:-}" ] || for _ in $(seq 1 160); do [ -e "$GATE_HOLD" ] && break; sleep 0.05; done
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
export UNPUSHED_TIMEOUT_LOG GATE_HOLD
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
# After the repository cluster and before the pin.
unpushed_order_line="${unpushed_ahead_out%%$'\n'*}"
assert grep -Fq "$PIN_MARK" <<< "${unpushed_order_line#*"$UNPUSHED_MARK"}"
assert test "${unpushed_order_line%%"$UNPUSHED_MARK"*}" != "$unpushed_order_line"
# Fit step 8: the marker shortens to a red `↑!` rather than leaving the line, whatever the width.
: > "$GATE_LOG"
unpushed_fit_out=$(FIT_COLUMNS=20 PATH="$UNPUSHED_TIMEOUT_BIN:$PATH" \
  unpushed_render unpushed-fit "$AHEAD_REPO")
assert grep -Fq "${RED}↑!${RESET}" <<< "$unpushed_fit_out"

# Both gate asks are bounded by run_bounded, the deadline every probe shares: STATUSLINE_TIMEOUT_BIN
# is the one they run under, and with none installed its watchdog bounds them.
: > "$GATE_LOG"
: > "$UNPUSHED_TIMEOUT_LOG"
STATUSLINE_TIMEOUT_BIN="$UNPUSHED_TIMEOUT_BIN/timeout" unpushed_render unpushed-bounded "$AHEAD_REPO" >/dev/null
assert_eq "10 $UNPUSHED_STUB unpushed $AHEAD_TOP unpushed-bounded" \
  "$(grep -m1 -F "$UNPUSHED_STUB unpushed " "$UNPUSHED_TIMEOUT_LOG")"
STATUSLINE_TIMEOUT_BIN="$UNPUSHED_TIMEOUT_BIN/timeout" review_session_render autonomy-bounded "$AHEAD_REPO" >/dev/null
assert_eq "10 $UNPUSHED_STUB autonomous autonomy-bounded" \
  "$(grep -m1 -F "$UNPUSHED_STUB autonomous autonomy-" "$UNPUSHED_TIMEOUT_LOG")"
# The lock a gate ask removes is the one it made: one swept as dead while the ask ran belongs to the
# render that swept it, and removing it would let a third ask start beside the second.
for gate_owner in unpushed review-autonomy; do
  GATE_HOLD="$WORK/gate-hold-$gate_owner"
  gate_owner_cache="$STATE_DIR/$gate_owner-gate-lock-owner"
  rm -f "$gate_owner_cache"
  rmdir "$gate_owner_cache.lock" 2>/dev/null
  run_statusline "$(statusline_payload gate-lock-owner "" "$AHEAD_REPO")" >/dev/null ||
    fail "gate lock-owner render failed"
  for gate_wait in $(seq 1 100); do
    [ -d "$gate_owner_cache.lock" ] && break
    sleep 0.05
  done
  assert test -d "$gate_owner_cache.lock"
  rmdir "$gate_owner_cache.lock" && mkdir "$gate_owner_cache.lock"
  touch "$GATE_HOLD"
  for gate_wait in $(seq 1 100); do
    [ -s "$gate_owner_cache" ] && break
    sleep 0.05
  done
  sleep 0.2
  assert test -d "$gate_owner_cache.lock"
  rmdir "$gate_owner_cache.lock" 2>/dev/null
done
GATE_HOLD=

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
# And asked again the moment review-anchors.json moves: whose the commit is is read out of it, so a
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
progress_home_dir="${BLUE}$(basename "$REVIEW_CLEAN")${RESET}"
progress_away_dirs="${DIM}$(basename "$REVIEW_CLEAN")${RESET} ${MAGENTA}»${RESET} ${BLUE}$(basename "$REVIEW_DIRTY")${RESET}"

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


fi
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
    '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:$agent,agent_id:"a1",tool_input:{command:$command}}'
}
gate_decision() { jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null; }
if suite_shard_owns 2 launch-gate-grok; then
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
  # Chat and agent alike are pointed at the chat's own worker-run start.
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | contains("worker-run start <vendor> --brief <file> --workdir <dir>")' \
    <<<"$gate_out" >/dev/null
  gate_out=$(gate_agent_payload fork "$gate_denied" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$gate_out" >/dev/null
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | contains("worker-run start <vendor> --brief <file> --workdir <dir>")' \
    <<<"$gate_out" >/dev/null
done
gate_out=$(gate_payload 'worker-run start grok --brief /tmp/brief --workdir /tmp' | "$LAUNCH_GATE_BIN") ||
  fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
# worker-run exempts its own segment only: a bare launch chained after it is still a bare launch.
gate_out=$(gate_payload 'worker-run start grok --brief /tmp/brief ; grokb profile supergrok --prompt-file /tmp/brief' |
  "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$gate_out" >/dev/null
for gate_allowed in \
  'grokb profile supergrok' \
  'grok models' \
  'grokb list' \
  'echo "grok -p is the spelling the gate denies"' \
  'python3 grok-quota.py'; do
  gate_out=$(gate_payload "$gate_allowed" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done


fi
if suite_shard_owns 3 launch-gate-relay; then
# --- worker-launch-gate.sh: a run belongs to the chat --------------------------------------------
# The chat starts a run and waits on it as a background Bash; an agent spelling either through any
# wrapper, keyword or shell string starts a run nobody waits on.
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
worker-run wait cb-20260901-abcdef' \
  'W=/Volumes/Work/Projects/llm-legs/bin/worker-run; $W start claudeb --brief /tmp/brief --workdir /tmp' \
  'W=/x/bin/worker-run; $W wait cb-20260901-abcdef --max 3000; $W report cb-20260901-abcdef' \
  'export W=worker-run && "${W}" wait cb-20260901-abcdef' \
  '$RUNNER start claudeb --brief /tmp/brief --workdir /tmp'; do
  gate_out=$(gate_agent_payload fork "$owned_denied" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | contains("starts or awaits a worker run that belongs to the chat")' \
    <<<"$gate_out" >/dev/null
  gate_out=$(gate_payload "$owned_denied" | jq -c '.tool_input.run_in_background = true' | "$LAUNCH_GATE_BIN") ||
    fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done
# Bookkeeping, help, a finished record and the suite that exercises the launcher are not a run: the
# command WORD is what is judged, never the substring, and a REAL heredoc body — one whose
# delimiter arrives, fed to something that is not a shell — is text a command is written into.
# `ssh host <<EOF` is neither, and it stands here so its verdict is on record rather than assumed:
# that body DOES reach a shell, the remote one, and this door reads it as text anyway because
# nothing in it runs on THIS machine — no local quota is spent and no local wait could watch the run.
# The local shapes are the rule; this one is the exception that names itself.
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
  'grep -n "worker-run start" bin/worker-run' \
  'W=/x/bin/worker-run; $W report cb-20260901-abcdef' \
  'WORK=/tmp; ls $WORK; W=/x/bin/worker-run; echo $W start'; do
  gate_out=$(gate_agent_payload fork "$owned_allowed" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done
fi
gate_timeout_payload() { # agent command timeout-ms|null
  jq -cn --arg agent "$1" --arg command "$2" --argjson timeout "$3" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:$agent,agent_id:"a1",
      tool_input:({command:$command} + (if $timeout == null then {} else {timeout:$timeout} end))}'
}
if suite_shard_owns 1 launch-gate-wait; then
# An agent of any type owns no run, whatever timeout its call carries, and a headless worker owns
# none either.
for gate_agent in fork Explore claudeb-worker; do
  for gate_timeout in null 600000; do
    gate_out=$(gate_timeout_payload "$gate_agent" 'worker-run wait cb-20260901-abcdef --max 540' \
      "$gate_timeout" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
    assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  done
  gate_out=$(gate_agent_payload "$gate_agent" 'worker-run report cb-20260901-abcdef' | "$LAUNCH_GATE_BIN")
  assert_eq "" "$gate_out"
  gate_out=$(gate_agent_payload "$gate_agent" 'claudeb notcom -p go' | "$LAUNCH_GATE_BIN")
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done
gate_out=$(gate_payload 'worker-run wait cb-20260901-abcdef' | CLAUDEB_WORKER=1 "$LAUNCH_GATE_BIN")
assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
# A media script has one door, media-run, in every hand: a fork's call past it is refused.
gate_out=$(gate_agent_payload fork 'codex-image --dest /tmp/a.png --prompt cat' | "$LAUNCH_GATE_BIN")
assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
gate_out=$(gate_agent_payload fork 'media-run image --vendor codex -- --dest /tmp/a.png --prompt cat' | "$LAUNCH_GATE_BIN")
assert_eq "" "$gate_out"

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
  'gemini-music --help 2>&1 | head -20' \
  '/Volumes/Work/Projects/llm-legs/bin/gemini-listen -h' \
  'gemini-music --help </dev/null' \
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
  'gemini-music --dest /tmp/a.mp3 --prompt x --help' \
  'sh -c "gemini-music --dest /tmp/a.mp3 --prompt x"' \
  'gemini-sfx --help; gemini-sfx --dest /tmp/a.wav --prompt x' \
  'echo --dest /tmp/a.mp3 --prompt hi | xargs -J --help gemini-music --help' \
  "true; gemini-music --help; H=--help; H='--dest /tmp/a.mp3 --prompt hi'; gemini-music \$H" \
  'command claudeb notcom -p go' \
  'command -v light-research && light-research --prompt-file /tmp/q' \
  'command -v claudeb; claudeb notcom -p go'; do
  gate_out=$(gate_agent_payload fork "$gate_lookup_denied" | "$LAUNCH_GATE_BIN") ||
    fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done



fi
if suite_shard_owns 3 task-rows; then
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

# Every native type is refused with the chat's own worker-run protocol, and leaves no seed.
for tr_native in Explore Plan general-purpose claude-code-guide statusline-setup some-new-type ''; do
  tr_out=$(tr_spawn tr-native "$tr_native" 'look around') || fail "native spawn exited nonzero"
  assert_eq deny "$(printf '%s' "$tr_out" | gate_decision)"
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | contains("is not spawned. Delegate from this chat")' <<<"$tr_out" >/dev/null
done
assert test ! -e "$TR_HOME_CACHE/tr-native"

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

# The review run the rendered rows below read off its progress document.
TR_STATS="$WORK/tr-stats"
mkdir -p "$TR_STATS/progress"
TR_REVIEW=20260916T223010Z-e66f8e6
jq -cn --arg run "$TR_REVIEW" '{run_id:$run,tier:"T2",composition:"double",kind:"task",state:"running",phase:"review",
  cells:["claude-opus-high","codex-sol-high","agy-flash38-high","grok-grok-high"],
  done:["agy-flash38-high","grok-grok-high"],failed_cells:["grok-grok-high"],
  accounts:{"claude-opus-high":"locomthebest"}}' > "$TR_STATS/progress/llm-legs__x-1.json"
# Two forks spawned in one turn each keep a seed, and the forks claim them oldest first.
CLAUDE_LIMITS_ACCOUNT=first tr_spawn tr-pair fork $'ACCOUNT: first\nx' toolu_first >/dev/null
CLAUDE_LIMITS_ACCOUNT=second tr_spawn tr-pair fork $'ACCOUNT: second\nx' toolu_second >/dev/null
touch -t "$(date -v-5S +%Y%m%d%H%M.%S)" "$TR_HOME_CACHE/tr-pair/pending-fork-toolu_first"
assert_eq 2 "$(ls "$TR_HOME_CACHE/tr-pair" | grep -c '^pending-fork-')"
printf '%s' "$(worker_payload fork agentA 'Save brief' 'true' tr-pair)" | "$WORKER_HOOK" >/dev/null
printf '%s' "$(worker_payload fork agentB 'Save brief' 'true' tr-pair)" | "$WORKER_HOOK" >/dev/null
assert_eq 'fork · inherit · first' "$(head -n1 "$TR_HOME_CACHE/tr-pair/agentA")"
assert_eq 'fork · inherit · second' "$(head -n1 "$TR_HOME_CACHE/tr-pair/agentB")"
assert_eq 0 "$(ls "$TR_HOME_CACHE/tr-pair" | grep -c '^pending-')"
assert_fails grep -q '^spawn=' "$TR_HOME_CACHE/tr-pair/agentA"

# A cancelled spawn's seed is never another spawn's: the fork's transcript names its prompt, and
# without one a seed past the age limit is left alone.
CLAUDE_LIMITS_ACCOUNT=denied tr_spawn tr-stale fork $'ACCOUNT: denied\nx' toolu_denied >/dev/null
touch -t 202601010000 "$TR_HOME_CACHE/tr-stale/pending-fork-toolu_denied"
CLAUDE_LIMITS_ACCOUNT=live tr_spawn tr-stale fork $'ACCOUNT: live\nx' toolu_live >/dev/null
touch -t "$(date -v-5S +%Y%m%d%H%M.%S)" "$TR_HOME_CACHE/tr-stale/pending-fork-toolu_live"
tr_stale_transcript="$WORK/tr-stale-parent.jsonl"
mkdir -p "$WORK/tr-stale-parent/subagents"
jq -cn '{type:"user",message:{role:"user",content:"ACCOUNT: live\nx"}}' > "$WORK/tr-stale-parent/subagents/agent-agentL.jsonl"
printf '%s' "$(worker_payload fork agentL 'Save brief' 'true' tr-stale | jq -c --arg t "$tr_stale_transcript" '.transcript_path = $t')" |
  WORKER_TAG_SEED_MAX_AGE_S=999999999 "$WORKER_HOOK" >/dev/null
assert_eq 'fork · inherit · live' "$(head -n1 "$TR_HOME_CACHE/tr-stale/agentL")"
assert test -f "$TR_HOME_CACHE/tr-stale/pending-fork-toolu_denied"
printf '%s' "$(worker_payload fork agentN 'Save brief' 'true' tr-stale)" | "$WORKER_HOOK" >/dev/null
assert test ! -e "$TR_HOME_CACHE/tr-stale/agentN"
assert test -f "$TR_HOME_CACHE/tr-stale/pending-fork-toolu_denied"

# Every seed carries a spawn key, an empty first line included, and a fork that knows its key never
# takes a keyless seed.
tr_spawn tr-keyless fork $'\nACCOUNT: blank' toolu_blank >/dev/null
assert grep -q '^spawn=[0-9a-f]\{16\}$' "$TR_HOME_CACHE/tr-keyless/pending-fork-toolu_blank"
printf 'fork · opus · other\n' > "$TR_HOME_CACHE/tr-keyless/pending-fork-legacy"
mkdir -p "$WORK/tr-keyless-parent/subagents"
jq -cn '{type:"user",message:{role:"user",content:"ACCOUNT: mine\nx"}}' > "$WORK/tr-keyless-parent/subagents/agent-agentK.jsonl"
printf '%s' "$(worker_payload fork agentK 'Save brief' 'true' tr-keyless | jq -c --arg t "$WORK/tr-keyless-parent.jsonl" '.transcript_path = $t')" |
  "$WORKER_HOOK" >/dev/null
assert test ! -e "$TR_HOME_CACHE/tr-keyless/agentK" -a -f "$TR_HOME_CACHE/tr-keyless/pending-fork-legacy"

# A seed claim that cannot take `.claim.lock` leaves the seed in place for the next call.
tr_spawn tr-locked fork $'ACCOUNT: kept\nx' toolu_kept >/dev/null
mkdir "$TR_HOME_CACHE/tr-locked/.claim.lock"
printf '%s' "$(worker_payload fork agentS 'Save brief' 'true' tr-locked)" | WORKER_TAG_LOCK_TRIES=0 "$WORKER_HOOK" >/dev/null
assert test ! -e "$TR_HOME_CACHE/tr-locked/agentS" -a -f "$TR_HOME_CACHE/tr-locked/pending-fork-toolu_kept"
rmdir "$TR_HOME_CACHE/tr-locked/.claim.lock"

# The media tag of a media-run job says what runs where, off the launch's own flags: the route for
# codex images (the manifest's first route when none is named) and music, the model for Flow video.
media_tag_of() { ( . "$ROOT/share/worker-model.sh" && worker_media_tag "$@" ); }
assert_eq "img·$(jq -r '.routes[0]' "$ROOT/share/image-caps/codex.json")" "$(media_tag_of codex image '--dest /tmp/a.png --prompt x')"
assert_eq 'img·cli' "$(media_tag_of codex image '--route cli --dest /tmp/a.png --prompt x')"
assert_eq 'img·web' "$(media_tag_of codex image '--route web --dest /tmp/a.png --prompt x')"
assert_eq 'vid·veo' "$(media_tag_of gemini video '--dest /tmp/a.mp4 --prompt x')"
assert_eq 'vid·omni' "$(media_tag_of gemini video '--model omni --dest /tmp/a.mp4 --prompt x')"
assert_eq 'mus·app' "$(media_tag_of gemini music '--dest /tmp/a.mp3 --prompt x')"
assert_eq 'mus·flow' "$(media_tag_of gemini music '--route flow --dest /tmp/a.mp3 --prompt x')"
assert_eq 'mus·flow' "$(media_tag_of gemini music '--model lyria-3-pro --dest /tmp/a.mp3 --prompt x')"
assert_eq 'sfx' "$(media_tag_of gemini sfx '--dest /tmp/a.wav --prompt x')"
assert_eq 'img·gem' "$(media_tag_of gemini image '--dest /tmp/a.png --prompt x')"
assert_eq 'vid·grok' "$(media_tag_of grok video '--dest /tmp/a.mp4 --prompt x')"

tr_runs="$HOME/.cache/claude-worker-runs"

# A subagent's edit is counted into its own tag file, the tag line kept.
mkdir -p "$TR_HOME_CACHE/tr-edit"
printf 'fork · opus · acct\n' > "$TR_HOME_CACHE/tr-edit/a1"
run_workdir_hook "$(agent_payload Edit tr-edit "$REPO_A" "$REPO_A/one.txt")"
run_workdir_hook "$(agent_payload Write tr-edit "$REPO_A" "$REPO_A/two.txt")"
assert_eq 'fork · opus · acct' "$(head -n1 "$TR_HOME_CACHE/tr-edit/a1")"
assert_eq 'edit=2' "$(grep '^edit=' "$TR_HOME_CACHE/tr-edit/a1")"
run_workdir_hook "$(agent_payload Read tr-edit "$REPO_A" "$REPO_A/one.txt")"
assert_eq 'edit=2' "$(grep '^edit=' "$TR_HOME_CACHE/tr-edit/a1")"
# Edit counts racing the fork's own calls on one tag file serialize through `.claim.lock`: no count
# is lost and the tag line survives.
tr_edit_payload=$(agent_payload Write tr-edit "$REPO_A" "$REPO_A/two.txt")
tr_fork_payload=$(worker_payload fork a1 'List' 'ls' tr-edit)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  printf '%s' "$tr_edit_payload" | "$WORKDIR_HOOK" >/dev/null 2>&1 &
  printf '%s' "$tr_fork_payload" | "$WORKER_HOOK" >/dev/null 2>&1 &
done
wait
assert_eq 'edit=12' "$(grep '^edit=' "$TR_HOME_CACHE/tr-edit/a1")"
assert_eq 'fork · opus · acct' "$(head -n1 "$TR_HOME_CACHE/tr-edit/a1")"
assert test ! -e "$TR_HOME_CACHE/tr-edit/.claim.lock"
# The gate: a Monitor on a wait is refused; the chat's own Bash waits.
monitor_payload() { jq -cn --arg command "$1" '{hook_event_name:"PreToolUse",tool_name:"Monitor",tool_input:{command:$command}}'; }
for tr_monitored in 'worker-run wait cb-1-2-abc --max 540' "review-bench wait $TR_REVIEW" 'until review-bench  wait x; do sleep 5; done'; do
  gate_out=$(monitor_payload "$tr_monitored" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
  assert jq -e '.hookSpecificOutput.permissionDecisionReason | contains("once as a Bash call with `run_in_background: true`")' <<<"$gate_out" >/dev/null
done
gate_out=$(monitor_payload 'tail -f /tmp/server.log' | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
# The Monitor branch reads the masked scan: a quoted mention is an operand, and every owned spelling behind it is judged.
gate_out=$(monitor_payload "grep -n 'review-bench wait' /tmp/notes.txt" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
for tr_monitor_owned in 'codex-image --dest /tmp/a.png --prompt cat' 'review-bench review --tier T2'; do
  gate_out=$(monitor_payload "$tr_monitor_owned" | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done
# The chat's own Bash runs every review wait, its recoveries and light-research; an agent or a
# headless worker recovers no review and runs no light-research.
for tr_chat_ok in "review-bench wait $TR_REVIEW --max 540" "review-bench wait $TR_REVIEW --relaunch" \
  "review-bench wait $TR_REVIEW --finish-partial" 'review-bench review --tier T2' "review-bench report $TR_REVIEW" \
  'review-bench findings' 'worker-run start light --brief /tmp/b --workdir /tmp'; do
  gate_out=$(gate_payload "$tr_chat_ok" | env -u CLAUDEB_WORKER "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
done
for tr_chat_bg in 'light-research --prompt-file /tmp/q --out /tmp/a --repo /tmp/r' 'light-research --attach gemini-1-2-abcd --out /tmp/a'; do
  gate_out=$(gate_payload "$tr_chat_bg" | jq -c '.tool_input.run_in_background = true' | env -u CLAUDEB_WORKER "$LAUNCH_GATE_BIN") ||
    fail "launch gate exited nonzero"
  assert_eq "" "$gate_out"
  gate_out=$(gate_payload "$tr_chat_bg" | env -u CLAUDEB_WORKER "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done
for tr_recovery in --relaunch --finish-partial; do
  gate_out=$(gate_payload "review-bench wait $TR_REVIEW $tr_recovery" | CLAUDEB_WORKER=1 "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done
gate_out=$(gate_payload "review-bench wait $TR_REVIEW --max 540" | CLAUDEB_WORKER=1 "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
assert_eq "" "$gate_out"
for tr_agent_owned in '~/.local/bin/light-research --prompt-file /tmp/q --out /tmp/a' 'light-research --attach gemini-1-2-abcd --out /tmp/a' \
  'worker-run start light --brief /tmp/b --workdir /tmp'; do
  gate_out=$(gate_timeout_payload fork "$tr_agent_owned" 600000 | "$LAUNCH_GATE_BIN") || fail "launch gate exited nonzero"
  assert_eq deny "$(printf '%s' "$gate_out" | gate_decision)"
done

# The renderer paints every running local_agent task — fork and native agents — and fits `columns`.
# Workers and reviews have no rows of their own any more (their work lines carry them), so a leftover
# relay tag file paints its tag line and the description's title, never a run's or a review's state.
RENDER_BIN="$ROOT/bin/subagent-statusline.sh"
TR_RSESS=tr-render
mkdir -p "$TR_HOME_CACHE/$TR_RSESS"
printf 'acc · astra · high\nrun=codex-9-9-wait\n' > "$TR_HOME_CACHE/$TR_RSESS/w1"
printf 'T2 · double · task\nreview=%s\n' "$TR_REVIEW" > "$TR_HOME_CACHE/$TR_RSESS/r1"
printf 'fork · inherit · acc\nedit=3\n' > "$TR_HOME_CACHE/$TR_RSESS/l1"
printf 'fork · inherit · acc\n' > "$TR_HOME_CACHE/$TR_RSESS/l2"
printf 'rawilimo · flash38 · high\nlight=research\nrun=gemini-9-9-res\n' > "$TR_HOME_CACHE/$TR_RSESS/g1"
printf 'agent · inherit · acc\nedit=2\n' > "$TR_HOME_CACHE/$TR_RSESS/a1"
tr_render() { # columns [the one task id to render]
  local start=$(( ($(date +%s) - 65) * 1000 ))
  jq -cn --argjson cols "$1" --argjson start "$start" --arg sess "$TR_RSESS" --arg rev "$TR_REVIEW" --arg only "${2-}" '{session_id:$sess,columns:$cols,tasks:[
    {id:"w1",type:"local_agent",status:"running",description:"acc · astra · high: Implement the parser fix",label:"Running suites",startTime:$start,tokenCount:12345,model:"claude-sonnet-5"},
    {id:"w3",type:"local_agent",status:"completed",description:"Finished run",startTime:$start},
    {id:"w4",type:"local_agent",status:"killed",description:"Killed run",startTime:$start},
    {id:"r1",type:"local_agent",status:"running",description:("T2 · double · task: WAIT " + $rev + ": hunt"),startTime:$start,tokenCount:500},
    {id:"l1",type:"local_agent",status:"running",description:"Refactor",startTime:$start,model:"claude-fable-5-1"},
    {id:"l2",type:"local_agent",status:"running",description:"Look",startTime:$start,model:"claude-fable-5-1"},
    {id:"n1",type:"local_agent",status:"running",description:"Look around",startTime:$start,model:"claude-sonnet-5-5"},
    {id:"a1",type:"local_agent",status:"running",description:"Teammate",startTime:$start,model:"claude-opus-5-5"},
    {id:"g1",type:"local_agent",status:"running",description:"light research · 3.8-flash · rawilimo: Map the hooks",startTime:$start,model:"claude-sonnet-5"},
    {id:"b1",type:"local_bash",status:"running",label:"sleep"}]} | if $only == "" then . else .tasks |= map(select(.id == $only)) end' |
    WORKER_STATS_DIR="$TR_STATS" SUBAGENT_ROW_RESERVE=0 CLAUDE_LIMITS_ACCOUNT=rowacct "$RENDER_BIN"
}
# A second may tick between the fixture's clock and the renderer's; both spell the same width.
tr_norm() { perl -pe 's/\e\[[0-9;]*m//g; s/1m [0-9]+s/1m 5s/'; }
tr_row() { jq -r --arg id "$2" 'select(.id == $id) | .content' <<<"$1" | tr_norm; }
# A run record in the work cache is the worker's work line now, never a state on a task row.
printf 'run\tcodex-9-9-wait\t%s\tpnpm test\n' "$(( $(date +%s) - 75 ))" > "$STATE_DIR/work-$TR_RSESS"
tr_wide=$(tr_render 300) || fail "renderer exited nonzero"
rm -f "$STATE_DIR/work-$TR_RSESS"
assert_eq 9 "$(grep -c . <<<"$tr_wide")"
assert_eq 'acc · astra · high — Implement the parser fix · 1m 5s · ↓ 12.3k tok' "$(tr_row "$tr_wide" w1)"
assert_fails grep -Fq 'Running suites' <<<"$tr_wide"
# A paint starts one jq to parse the payload and one to encode every row, and no sed or grep per row.
printf '%s() { printf "%s\\n" >>"$TR_CALLS"; command %s "$@"; }\n' jq jq jq sed sed sed grep grep grep cat cat cat \
  >"$WORK/tr-count.sh"
: >"$WORK/tr-calls"
(export BASH_ENV="$WORK/tr-count.sh" TR_CALLS="$WORK/tr-calls"; tr_render 300 >/dev/null)
assert_eq 'jq jq' "$(tr '\n' ' ' <"$WORK/tr-calls" | sed 's/ $//')"
# A finished task is answered with an empty content, never left out: the harness draws its own
# native row for a listed id the renderer is silent about, and only "" removes the row.
assert_eq '{"id":"w3","content":""}{"id":"w4","content":""}' \
  "$(jq -c 'select(.id == "w3" or .id == "w4")' <<<"$tr_wide" | tr -d '\n')"
assert_eq "T2 · double · task — WAIT $TR_REVIEW: hunt · 1m 5s · ↓ 500 tok" "$(tr_row "$tr_wide" r1)"
assert_eq 'rawilimo · flash38 · high — Map the hooks · 1m 5s' "$(tr_row "$tr_wide" g1)"
# Native rows name the harness model: a fork explores until its first edit, then counts them.
assert_eq 'fork · fable · acc — Refactor · edit 3 · 1m 5s' "$(tr_row "$tr_wide" l1)"
assert_eq 'fork · fable · acc — Look · explore · 1m 5s' "$(tr_row "$tr_wide" l2)"
assert_eq 'agent · sonnet · rowacct — Look around · 1m 5s' "$(tr_row "$tr_wide" n1)"
assert_eq 'agent · opus · acc — Teammate · edit 2 · 1m 5s' "$(tr_row "$tr_wide" a1)"
assert grep -Fq "${MAGENTA}fork · fable · acc${RESET} ${DIM}—${RESET} Refactor ${DIM}· edit 3${RESET}" <<<"$(jq -r 'select(.id == "l1") | .content' <<<"$tr_wide")"
# Narrower: the title goes first, then tok, then elapsed; the tag and the state never.
assert_eq 'acc · astra · high — Implement the pa… · 1m 5s · ↓ 12.3k tok' "$(tr_row "$(tr_render 60 w1)" w1)"
assert_eq 'acc · astra · high · 1m 5s · ↓ 12.3k tok' "$(tr_row "$(tr_render 40 w1)" w1)"
assert_eq 'acc · astra · high · 1m 5s' "$(tr_row "$(tr_render 30 w1)" w1)"
assert_eq 'fork · fable · acc · edit 3' "$(tr_row "$(tr_render 20 l1)" l1)"
# The default reserve is the top statusline's fit margin, 3.
assert_eq "$(sed -nE 's/^STATUSLINE_FIT_MARGIN=\$\{STATUSLINE_FIT_MARGIN:-([0-9]+)\}$/\1/p' "$ROOT/bin/statusline.sh")" \
  "$(sed -nE 's/^reserve=\$\{SUBAGENT_ROW_RESERVE:-([0-9]+)\}$/\1/p' "$RENDER_BIN")"
assert_eq 4 "$(sed -nE 's/^reserve=\$\{SUBAGENT_ROW_RESERVE:-([0-9]+)\}$/\1/p' "$RENDER_BIN")"

# A payload whose tasks carry no status field is a running list (the harness omits the field on older builds).
no_status=$(printf '{"session_id":"x","columns":80,"tasks":[{"id":"ns1","type":"local_agent","description":"acc · astra · high: No status","startTime":1789600000000}]}' | bash "$RENDER_BIN")
assert grep -Fq 'acc · astra · high' <<<"$no_status"
fi
echo "PASS: $asserts asserts; workdir tracking, worktree/agent filtering, statusline segments, an ATOMIC middle block computed from ONE shown tree — the tree of the last line of this chat's place journal — no per-chat review debt number whatever the gate would answer, the gate's autonomy dot asked once per TTL with nothing else probed behind it, an unpushed marker that is the same gate's \`unpushed\` answer word for word — never dimmed, never shown for a branch level with its upstream or for commits the gate names none of, silent with no gate to ask, and re-asked the moment the FAMILY's review-anchors.json that decides whose the commit is moves — main-last and Gemini account predictions, fork tag propagation with the bare-launch gate that denies the spellings they replace, media-run work lines tagged account·kind·route from the job pointer with gen/edit states and fan-out cells, task rows painted for every agent with run/review/light state fitted to the columns, native agent spawns refused but fork, Monitor waits refused, an explicit-vendor pin hidden only by that vendor's ABSENCE from a loaded pick line and never by a field that is merely unusable, and a run's start/wait reserved to the chat, refused to an agent through every wrapper, keyword and sh -c string that spells one, while a read-only report and a heredoc body quoting the spelling are not gated"
