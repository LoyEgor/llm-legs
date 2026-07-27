#!/usr/bin/env bash
set -u

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
TOP_H=$(git -C "$REPO_H" rev-parse --show-toplevel)
SHORT_SHA=$(git -C "$REPO_C" rev-parse --short HEAD)

DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; MAGENTA=$'\033[35m'; RESET=$'\033[0m'
BLUE=$'\033[34m'
STATE_DIR="$HOME/.cache/claude-statusline"

workdir_payload() {
  jq -cn --arg event PostToolUse --arg tool "$1" --arg session "$2" --arg cwd "$3" \
    --arg value "$4" '
      {hook_event_name:$event,tool_name:$tool,session_id:$session,cwd:$cwd,
       tool_input:(if $tool == "Bash" then {command:$value}
                   elif $tool == "NotebookEdit" then {notebook_path:$value}
                   else {file_path:$value} end)}'
}

run_workdir_hook() {
  local payload=$1 output
  output=$(printf '%s' "$payload" | "$WORKDIR_HOOK") || fail "workdir hook exited nonzero"
  assert_eq "" "$output"
}

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

session_start_payload() {
  jq -cn --arg source "$1" --arg session "$2" --arg cwd "$REPO_A" \
    '{hook_event_name:"SessionStart",source:$source,session_id:$session,cwd:$cwd}'
}

for src in startup resume clear; do
  printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-session-ss-$src"
  run_workdir_hook "$(session_start_payload "$src" "session-ss-$src")"
  assert test ! -e "$STATE_DIR/workdir-session-ss-$src"
done

printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-session-ss-compact"
run_workdir_hook "$(session_start_payload compact session-ss-compact)"
assert_eq "$TOP_B" "$(cat "$STATE_DIR/workdir-session-ss-compact")"

printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-session-ss-agent"
payload=$(session_start_payload startup session-ss-agent | jq -c '. + {agent_type:"reviewer"}')
run_workdir_hook "$payload"
assert test ! -e "$STATE_DIR/workdir-session-ss-agent"

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
  printf '%s' "$1" | CLAUDE_LIMITS_ACCOUNT="${2:-${RUN_STATUSLINE_DEFAULT_ACCOUNT:-main}}" CLAUDEB_DIR="$CLAUDEB_FIX" \
    LLM_LIMITS_FILE="$WORK/limits.json" STATUSLINE_PS=true STATUSLINE_LSOF=true \
    STATUSLINE_STORE_MERGE_CMD="${STORE_MERGE_CMD:-/usr/bin/true}" "$STATUSLINE"
}

status_payload=$(statusline_payload status-override)
control_one=$(run_statusline "$status_payload") || fail "statusline control failed"
control_two=$(run_statusline "$status_payload") || fail "statusline second control failed"
assert_eq "$control_one" "$control_two"
assert grep -Fq main <<< "$control_one"
assert test "${control_one#*»}" = "$control_one"

# A worktree of the project is `⧉ <dir>`, never `»` — that arrow is reserved for
# a foreign repository. This one sits outside <repo>/.claude/worktrees (red) and
# its name is not carried by branch `feature-x`, so the branch is printed too.
printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-status-override"
override_output=$(run_statusline "$status_payload") || fail "statusline override failed"
assert test "${override_output#*»}" = "$override_output"
assert grep -Fq "${RED}⧉ $(basename "$TOP_B")" <<< "$override_output"
assert grep -Fq "${YELLOW}⎇ feature-x" <<< "$override_output"

# Canonical location and a branch that carries the directory's words: blue icon,
# branch folded away as redundant.
printf '%s\n' "$TOP_E" > "$STATE_DIR/workdir-status-canon"
canon_output=$(run_statusline "$(statusline_payload status-canon)") || fail "statusline canonical worktree failed"
assert grep -Fq "${BLUE}⧉ feature-y" <<< "$canon_output"
assert test "${canon_output#*⎇}" = "$canon_output"

# An auto-slug branch is the one thing the fold must never hide: harness-made
# worktrees always land on `claude/*`, and this strip is the only place the global
# CLAUDE.md rule about renaming them is visible.
printf '%s\n' "$TOP_F" > "$STATE_DIR/workdir-status-autoslug"
autoslug_output=$(run_statusline "$(statusline_payload status-autoslug)") || fail "statusline auto-slug failed"
assert grep -Fq "${BLUE}⧉ auto-slug" <<< "$autoslug_output"
assert grep -Fq "${RED}⎇ claude/agitated-fixture" <<< "$autoslug_output"

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

# A live worktree label survives a stale breadcrumb.
printf '%s\n' "$FIXTURES/vanished" > "$STATE_DIR/workdir-status-wt-live.gone"
wt_live_output=$(run_statusline "$(statusline_payload status-wt-live '' "$REPO_E")") || fail "statusline live worktree over breadcrumb failed"
assert grep -Fq "${BLUE}⧉ feature-y" <<< "$wt_live_output"
assert test "${wt_live_output#*✗}" = "$wt_live_output"

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

# A tracked directory that stopped resolving (removed worktree): the fallback to
# the project dir is announced instead of silently reporting its branch, and the
# breadcrumb survives later renders.
printf '%s\n' "$FIXTURES/vanished" > "$STATE_DIR/workdir-status-dangling"
dangling_output=$(run_statusline "$(statusline_payload status-dangling)") || fail "statusline dangling failed"
assert grep -Fq main <<< "$dangling_output"
assert test "${dangling_output#*»}" = "$dangling_output"
assert grep -Fq "${DIM}⧉ vanished ✗" <<< "$dangling_output"
assert test ! -e "$STATE_DIR/workdir-status-dangling"
assert_eq "$FIXTURES/vanished" "$(cat "$STATE_DIR/workdir-status-dangling.gone")"
dangling_again=$(run_statusline "$(statusline_payload status-dangling)") || fail "statusline dangling rerender failed"
assert grep -Fq "${DIM}⧉ vanished ✗" <<< "$dangling_again"
# Written once, not on every render, so the cache prune can age the file out.
printf '%s\n' "$FIXTURES/vanished-later" > "$STATE_DIR/workdir-status-dangling"
dangling_third=$(run_statusline "$(statusline_payload status-dangling)") || fail "statusline dangling third failed"
assert_eq "$FIXTURES/vanished" "$(cat "$STATE_DIR/workdir-status-dangling.gone")"

# Tracking a live directory again clears the breadcrumb.
run_workdir_hook "$(workdir_payload Bash status-dangling "$REPO_A" "cd '$REPO_A'")"
assert test ! -e "$STATE_DIR/workdir-status-dangling.gone"
recovered=$(run_statusline "$(statusline_payload status-dangling)") || fail "statusline recovery failed"
assert test "${recovered#*✗}" = "$recovered"

printf 'stale\n' > "$STATE_DIR/workdir-status-gone-reset.gone"
run_workdir_hook "$(jq -cn --arg session status-gone-reset --arg cwd "$REPO_A" \
  '{hook_event_name:"SessionStart",session_id:$session,cwd:$cwd,source:"startup"}')"
assert test ! -e "$STATE_DIR/workdir-status-gone-reset.gone"

printf '%s\n' "$TOP_C" > "$STATE_DIR/workdir-status-detached"
detached_output=$(run_statusline "$(statusline_payload status-detached)") || fail "statusline detached failed"
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
assert grep -Fq 'w:son' <<< "$worker_out"

printf 'worker=sonnet\nsonnet_effort=high\ncodex_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-son-eff)")
assert grep -Fq "w:son${RESET}${DIM}·hi${RESET}" <<< "$worker_out"

printf 'worker=codex\ncodex_effort=medium\ncodex_profile=alt\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex)")
assert grep -Fq "w:codex${RESET} ${MAGENTA}@alt${RESET}${DIM}·sol·med${RESET}" <<< "$worker_out"

printf 'worker=codex\ncodex_effort=xhigh\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-unres)")
assert grep -Fq "w:codex${RESET} ${MAGENTA}~?${RESET}${DIM}·sol·xh${RESET}" <<< "$worker_out"

printf 'worker=claudeb\ncodex_effort=high\nclaudeb_profile=notcom\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb)")
assert grep -Fq "w:cb${RESET} ${MAGENTA}@notcom${RESET}${DIM}·opus·hi${RESET}" <<< "$worker_out"

printf 'worker=claudeb\ncodex_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-unres)")
assert grep -Fq "w:cb${RESET} ${MAGENTA}~?${RESET}${DIM}·opus·hi${RESET}" <<< "$worker_out"

mkdir -p "$HOME/.cache"
printf 'cx✓alt·sol·med cb~notcom·opus·hi gx✓work·flash·med\n' \
  >"$HOME/.cache/worker-pick.line.main"
printf 'worker=gemini\ngemini_model=flash\ngemini_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-gemini)")
assert grep -Fq "w:gem${RESET} ${MAGENTA}~work${RESET}${DIM}·flash·med${RESET}" <<< "$worker_out"

printf 'worker=gemini\ngemini_profile=work\ngemini_model=flash\ngemini_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-gemini-pin)")
assert grep -Fq "w:gem${RESET} ${MAGENTA}@work${RESET}${DIM}·flash·med${RESET}" <<< "$worker_out"

printf 'cx✓alt·sol·med cb~notcom·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
printf 'worker=auto\ngemini_model=pro\ngemini_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-auto)" main)
assert grep -Fq 'gx✓main·pro·hi' <<< "$worker_out"

printf 'worker=frobnicate\ncodex_effort=high\ncodex_profile=alt\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-bad)")
assert grep -Fq 'w:?' <<< "$worker_out"
assert test "${worker_out#*@alt}" = "$worker_out"
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

# The unpinned w:cb prediction must come from the worker-pick cache, never from
# .claudeb-state (the last profile launched): the two are seeded to different accounts
# here so a regression back to the state file fails instead of silently going stale.
printf 'acctgen\n' > "$CLAUDEB_FIX/.claudeb-state"
printf 'cx✓alt·sol·med cb~acctpick·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
printf 'worker=claudeb\ncodex_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-pick '{"model":{"id":"claude-fable-5","display_name":"Fable"}}')" main)
assert grep -Fq "w:cb${RESET} ${MAGENTA}~acctpick${RESET}${DIM}·opus·hi${RESET}" <<< "$worker_out"
assert test "${worker_out#*acctgen}" = "$worker_out"
assert test "${worker_out#*acctfab}" = "$worker_out"

# Profile names may hold underscores, dots and capitals (claudeb's own add rule), so the
# extractor must not be narrower than the names it can receive.
printf 'cx✓alt·sol·med cb~My_acct.2·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-oddname '{"model":{"id":"claude-fable-5","display_name":"Fable"}}')" main)
assert grep -Fq "w:cb${RESET} ${MAGENTA}~My_acct.2${RESET}${DIM}·opus·hi${RESET}" <<< "$worker_out"

# No parsable cache → honest `?`, never a stale account from the state file.
printf 'cx✓alt·sol·med gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-nocache '{"model":{"id":"claude-fable-5","display_name":"Fable"}}')" main)
assert grep -Fq "w:cb${RESET} ${MAGENTA}~?${RESET}${DIM}·opus·hi${RESET}" <<< "$worker_out"
assert test "${worker_out#*acctgen}" = "$worker_out"
printf 'cx✓alt·sol·med cb~acctpick·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"

printf 'worker=codex\ncodex_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-pick)" main)
assert grep -Fq "w:codex${RESET} ${MAGENTA}~alt${RESET}${DIM}·sol·med${RESET}" <<< "$worker_out"

# codexb only ever creates lowercase-and-hyphen names, so a line carrying anything else is a
# corrupt cache and must read as unknown rather than as a confident prediction.
printf 'cx✓My_acct.2·sol·med cb~acctpick·opus·hi gx✓main·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-oddname)" main)
assert grep -Fq "w:codex${RESET} ${MAGENTA}~?${RESET}${DIM}·sol·med${RESET}" <<< "$worker_out"

printf 'cx✗·? cb~? gx✗?·pro·hi\n' > "$HOME/.cache/worker-pick.line.main"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-nocache)" main)
assert grep -Fq "w:codex${RESET} ${MAGENTA}~?${RESET}${DIM}·sol·med${RESET}" <<< "$worker_out"
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

cost_payload=$(statusline_payload status-cost '{"cost":{"total_cost_usd":18.2007}}')
cost_out=$(printf '%s' "$cost_payload" | env -u LANG LC_ALL=ru_RU.UTF-8 \
  CLAUDE_LIMITS_ACCOUNT=main CLAUDEB_DIR="$CLAUDEB_FIX" LLM_LIMITS_FILE="$WORK/limits.json" \
  "$STATUSLINE" 2>"$WORK/cost-stderr") || fail "statusline cost locale failed"
assert grep -Fq '$18.20' <<< "$cost_out"
assert_eq "" "$(cat "$WORK/cost-stderr")"

# --- ctx color (% colored by pct: green <40, yellow 40–79, red ≥80; token count cold cache) ---
CTX_TRUTH_TRANSCRIPT="$WORK/ctx-truth.jsonl"
printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"fixmodel","usage":{}}}\n' \
  "$(TZ=UTC date -r "$NOW" +%Y-%m-%dT%H:%M:%S.000Z)" > "$CTX_TRUTH_TRANSCRIPT"
ctx_case() {
  statusline_payload "$1" "$(jq -cn --arg tp "$CTX_TRUTH_TRANSCRIPT" --argjson pct "$2" --argjson tokens "$3" \
    '{transcript_path:$tp,context_window:{used_percentage:$pct,current_usage:{input_tokens:$tokens}}}')"
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
    '{transcript_path:$tp,context_window:{used_percentage:100,context_window_size:1000000,current_usage:{input_tokens:248000}}}')")")
assert grep -Fq "ctx ${GREEN}25%${RESET}" <<< "$ctx_1m"
assert grep -Fq "${YELLOW}248k${RESET}" <<< "$ctx_1m"
ctx_200k=$(run_statusline "$(statusline_payload ctx-200k \
  "$(jq -cn --arg tp "$CTX_TRUTH_TRANSCRIPT" \
    '{transcript_path:$tp,context_window:{used_percentage:10,context_window_size:200000,current_usage:{input_tokens:180000}}}')")")
assert grep -Fq "ctx ${RED}90%${RESET}" <<< "$ctx_200k"

# --- token-count color encodes prompt-cache warmth ---
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
t_assist() { # epoch [model] [cache_read] [cache_creation] [bucket 5m|1h|-]
  local ts="$1" m="${2:-fixmodel}" cr="${3:-50000}" cc="${4:-500}" bk="${5:--}" b=""
  case "$bk" in
    5m) b=',"cache_creation":{"ephemeral_5m_input_tokens":'"$cc"',"ephemeral_1h_input_tokens":0}' ;;
    1h) b=',"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":'"$cc"'}' ;;
  esac
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"%s","usage":{"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s%s}}}\n' \
    "$(iso_utc "$ts")" "$m" "$cr" "$cc" "$b" >> "$TRANSCRIPT"
}
t_boundary() { printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s"}\n' "$(iso_utc "$1")" >> "$TRANSCRIPT"; }
t_reset() { : > "$TRANSCRIPT"; rm -f "$STATE_DIR"/cache-ttl-track-*; }
RUN_STATUSLINE_DEFAULT_ACCOUNT=acctgen

# Warm cache: count and time both dim (time presence signals cache alive);
# a fresh response inside the 120s attribution window self-stamps the account.
t_reset; t_assist $((NOW - 20))
warm_a=$(run_statusline "$(statusline_payload ctx-warm-lo "$(warm_extra "$TRANSCRIPT" 20 50000)")")
a_death=$(TZ=Europe/Kyiv date -r $((NOW - 20 + 3600)) +%H:%M)
assert grep -Fq "${DIM}50k${RESET}${DIM}→${a_death}${RESET}" <<< "$warm_a"
assert grep -q '^v2 [0-9]* acctgen ' "$STATE_DIR/cache-ttl-track-ctx-warm-lo"

# Warm cache with large token count: still dim.
warm_b=$(run_statusline "$(statusline_payload ctx-warm-hi "$(warm_extra "$TRANSCRIPT" 60 350000)")")
assert grep -Fq "${DIM}350k${RESET}" <<< "$warm_b"

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
t_reset; t_user $((NOW - 65)); t_assist $((NOW - 60))
touch -t "$(date -r $((NOW - 4000)) +%Y%m%d%H%M.%S)" "$TRANSCRIPT"
ts_warm=$(run_statusline "$(statusline_payload ctx-ts-warm "$(warm_extra "$TRANSCRIPT" 20 50000)")")
ts_death=$(TZ=Europe/Kyiv date -r $((NOW - 60 + 3600)) +%H:%M)
assert grep -Fq "${DIM}50k${RESET}${DIM}→${ts_death}${RESET}" <<< "$ts_warm"

# A partially written final entry must not hide the preceding completed response.
t_reset; t_assist $((NOW - 20))
printf '{"type":"assistant","timestamp":"' >> "$TRANSCRIPT"
streaming_out=$(run_statusline "$(statusline_payload ctx-streaming "$(warm_extra "$TRANSCRIPT" 20 50000)")")
streaming_death=$(TZ=Europe/Kyiv date -r $((NOW - 20 + 3600)) +%H:%M)
assert grep -Fq "ctx ${GREEN}20%${RESET} ${DIM}50k${RESET}${DIM}→${streaming_death}${RESET}" <<< "$streaming_out"

# Sidechain (subagent) entries hit different cache prefixes — not this chat's warmth.
t_reset; t_user $((NOW - 172800))
printf '{"type":"assistant","isSidechain":true,"timestamp":"%s","message":{"role":"assistant","model":"fixmodel","usage":{"cache_read_input_tokens":50000}}}\n' "$(iso_utc "$NOW")" >> "$TRANSCRIPT"
side_cold=$(run_statusline "$(statusline_payload ctx-sidechain "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${DIM}111k${RESET}" <<< "$side_cold"
assert test "${side_cold#*→}" = "$side_cold"

# <synthetic> assistant entries (API-error placeholders) are not responses.
t_reset; t_assist $((NOW - 172799)); t_assist "$NOW" '<synthetic>' 0 0
synth_cold=$(run_statusline "$(statusline_payload ctx-synth "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$synth_cold"

# --- account switch invalidates the cache (per-organization on Anthropic) ---
# Recorded stamp (alona) != current (acctgen), response outside the 120s
# attribution window -> cold despite being well inside the TTL.
t_reset; t_assist $((NOW - 600))
printf 'v2 %s alona 0\n' "$((NOW - 600))" > "$STATE_DIR/cache-ttl-track-ctx-swacct"
sw_out=$(run_statusline "$(statusline_payload ctx-swacct "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$sw_out"
# A NEW response under the current account re-warms and re-stamps it.
t_assist $((NOW - 5))
sw2_out=$(run_statusline "$(statusline_payload ctx-swacct "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}111k${RESET}${DIM}→" <<< "$sw2_out"
assert grep -q '^v2 [0-9]* acctgen ' "$STATE_DIR/cache-ttl-track-ctx-swacct"

# Menu-switch resume: no track at all + response outside the attribution
# window -> unattributable ("?"), cold until the first new response.
t_reset; t_assist $((NOW - 600))
noattr_out=$(run_statusline "$(statusline_payload ctx-noattr "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$noattr_out"
assert grep -q '^v2 [0-9]* ? 0' "$STATE_DIR/cache-ttl-track-ctx-noattr"

# Legacy v1 track (prompt_id-based) is treated as absent: same "?" cold path.
t_reset; t_assist $((NOW - 600))
printf 'pidsame %s alona\n' "$((NOW - 600))" > "$STATE_DIR/cache-ttl-track-ctx-legacy"
legacy_out=$(run_statusline "$(statusline_payload ctx-legacy "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$legacy_out"
assert grep -q '^v2 [0-9]* ? ' "$STATE_DIR/cache-ttl-track-ctx-legacy"

# --- model switch invalidates the cache (per-model on Anthropic) ---
t_reset; t_assist $((NOW - 20))
model_extra=$(warm_extra "$TRANSCRIPT" 55 111000 | jq -c '.model.id = "othermodel"')
model_cold=$(run_statusline "$(statusline_payload ctx-model-sw "$model_extra")")
assert grep -Fq "${YELLOW}111k${RESET}" <<< "$model_cold"
# Switching back to the model that built the cache re-warms (cache still alive).
model_warm=$(run_statusline "$(statusline_payload ctx-model-sw "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}111k${RESET}${DIM}→" <<< "$model_warm"
# A payload without model.id cannot check the model — other gates still apply.
noid_extra=$(warm_extra "$TRANSCRIPT" 20 50000 | jq -c 'del(.model)')
noid_out=$(run_statusline "$(statusline_payload ctx-model-noid "$noid_extra")")
assert grep -Fq "${DIM}50k${RESET}${DIM}→" <<< "$noid_out"

# --- /compact kills the cache until the next response ---
t_reset; t_assist $((NOW - 60)); t_boundary $((NOW - 30))
# Its injected summary (user, isCompactSummary) and unmarked continuation user
# entry must not count as warmth.
printf '{"type":"user","isCompactSummary":true,"timestamp":"%s","message":{"role":"user"}}\n' "$(iso_utc $((NOW - 29)))" >> "$TRANSCRIPT"
t_user $((NOW - 28))
compact_cold=$(run_statusline "$(statusline_payload ctx-compact "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${DIM}111k${RESET}" <<< "$compact_cold"
assert test "${compact_cold#*→}" = "$compact_cold"
# The first response after the boundary re-warms.
t_assist $((NOW - 5))
compact_warm=$(run_statusline "$(statusline_payload ctx-compact "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}111k${RESET}${DIM}→" <<< "$compact_warm"
compact_current=$(run_statusline "$(statusline_payload ctx-compact-current \
  "$(jq -cn --arg tp "$TRANSCRIPT" \
    '{transcript_path:$tp,context_window:{used_percentage:55,current_usage:{input_tokens:111000}}}')")")
assert grep -Fq "ctx ${YELLOW}55%${RESET} ${YELLOW}111k${RESET}" <<< "$compact_current"

t_reset; t_assist $((NOW - 30)); t_boundary $((NOW - 30))
compact_equal=$(run_statusline "$(statusline_payload ctx-compact-equal "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${DIM}111k${RESET}" <<< "$compact_equal"
assert test "${compact_equal#*→}" = "$compact_equal"

# --- branched (forked) chats inherit warmth from the parent's stamp ---
# Copied entries carry forkedFrom.sessionId; the anchor response was produced
# by the parent, so it must never self-stamp the current account.
t_assist_fork() { # epoch parent_sid
  printf '{"type":"assistant","timestamp":"%s","forkedFrom":{"sessionId":"%s"},"message":{"role":"assistant","model":"fixmodel","usage":{"cache_read_input_tokens":50000,"cache_creation_input_tokens":500}}}\n' \
    "$(iso_utc "$1")" "$2" >> "$TRANSCRIPT"
}
# Tail fork: parent's stamp points at the exact copied response -> inherit
# account + learning cursor, warm; own track written with the inherited stamp.
t_reset; t_assist_fork $((NOW - 600)) parent-sid
fork_only=$(run_statusline "$(statusline_payload ctx-fork-only \
  "$(jq -cn --arg tp "$TRANSCRIPT" \
    '{transcript_path:$tp,context_window:{used_percentage:55,current_usage:{input_tokens:111000}}}')")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${DIM}111k${RESET}" <<< "$fork_only"
printf 'v2 %s acctgen 7\n' "$((NOW - 600))" > "$STATE_DIR/cache-ttl-track-parent-sid"
fork_warm=$(run_statusline "$(statusline_payload ctx-fork "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}111k${RESET}${DIM}→" <<< "$fork_warm"
assert grep -q '^v2 [0-9]* acctgen 7' "$STATE_DIR/cache-ttl-track-ctx-fork"
# Parent moved past the fork point (stamp ts != copied response ts) -> "?" cold.
t_reset; t_assist_fork $((NOW - 600)) parent-sid
printf 'v2 %s acctgen 0\n' "$((NOW - 300))" > "$STATE_DIR/cache-ttl-track-parent-sid"
fork_moved=$(run_statusline "$(statusline_payload ctx-fork-moved "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${DIM}111k${RESET}" <<< "$fork_moved"
assert test "${fork_moved#*→}" = "$fork_moved"
assert grep -q '^v2 [0-9]* ? ' "$STATE_DIR/cache-ttl-track-ctx-fork-moved"
# No parent track at all -> "?" cold.
t_reset; t_assist_fork $((NOW - 600)) parent-sid
fork_orphan=$(run_statusline "$(statusline_payload ctx-fork-orphan "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${DIM}111k${RESET}" <<< "$fork_orphan"
assert test "${fork_orphan#*→}" = "$fork_orphan"
# A FRESH copied anchor (inside the 120s window) still must not self-stamp:
# without a matching parent stamp it stays "?" cold.
t_reset; t_assist_fork $((NOW - 10)) parent-sid
fork_fresh=$(run_statusline "$(statusline_payload ctx-fork-fresh "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "ctx ${DIM}55%${RESET} ${DIM}111k${RESET}" <<< "$fork_fresh"
assert test "${fork_fresh#*→}" = "$fork_fresh"
assert grep -q '^v2 [0-9]* ? ' "$STATE_DIR/cache-ttl-track-ctx-fork-fresh"
# The fork's own NEW response (no forkedFrom) resumes normal self-stamping.
t_assist $((NOW - 5))
fork_own=$(run_statusline "$(statusline_payload ctx-fork-fresh "$(warm_extra "$TRANSCRIPT" 55 111000)")")
assert grep -Fq "${DIM}111k${RESET}${DIM}→" <<< "$fork_own"
assert grep -q '^v2 [0-9]* acctgen ' "$STATE_DIR/cache-ttl-track-ctx-fork-fresh"

# Cold cache color tests: count colored by size (no cache = cache fields are 0).
cold_extra() {
  jq -cn --arg tp "$1" --argjson pct "$2" --argjson it "$3" '
    {transcript_path:$tp,
     context_window:{used_percentage:$pct,
       current_usage:{input_tokens:$it,cache_creation_input_tokens:0,cache_read_input_tokens:0}}}'
}

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
  {transcript_path:$tp,context_window:{used_percentage:20,current_usage:{input_tokens:60000}}}')
warm_d=$(run_statusline "$(statusline_payload ctx-nocache "$d_extra")")
assert grep -Fq "${DIM}60k${RESET}" <<< "$warm_d"

# (e) no transcript path -> dim (unknown is not warm).
warm_e=$(run_statusline "$(statusline_payload ctx-nopath "$(warm_extra "" 20 50000)")")
assert grep -Fq "${DIM}50k${RESET}" <<< "$warm_e"

t_reset
printf 'not-json\n' > "$TRANSCRIPT"
garbage_out=$(run_statusline "$(statusline_payload ctx-garbage \
  "$(jq -cn --arg tp "$TRANSCRIPT" \
    '{transcript_path:$tp,context_window:{used_percentage:55,current_usage:{input_tokens:111000}}}')")")
garbage_rc=$?
assert_eq 0 "$garbage_rc"
assert grep -Fq "ctx ${DIM}55%${RESET} ${DIM}111k${RESET}" <<< "$garbage_out"

# (f) TTL override file respected: response 200s ago, override TTL 100 -> cold
# (would be warm under the default 3600).
t_reset; t_assist $((NOW - 200))
printf '100\n' > "$HOME/.claude/statusline-cache-ttl"
warm_f=$(run_statusline "$(statusline_payload ctx-ttl "$(warm_extra "$TRANSCRIPT" 20 50000)")")
assert grep -Fq "${DIM}50k${RESET}" <<< "$warm_f"
assert test "${warm_f#*→}" = "$warm_f"
rm -f "$HOME/.claude/statusline-cache-ttl"

# --- effective cache TTL: API bucket > (seed clamped by learned bounds) ---
LEARNED="$STATE_DIR/cache-ttl-learned"
rm -f "$LEARNED"

# The response's own cache_creation bucket IS the TTL: 5m -> death = ts+300.
t_reset; t_assist $((NOW - 30)) fixmodel 100000 500 5m
bk5_out=$(run_statusline "$(statusline_payload ctx-bk5 "$(warm_extra "$TRANSCRIPT" 20 100000)")")
bk5_death=$(TZ=Europe/Kyiv date -r $((NOW - 30 + 300)) +%H:%M)
assert grep -Fq "${DIM}100k${RESET}${DIM}→${bk5_death}${RESET}" <<< "$bk5_out"
# ...and it beats both a learned ceiling and a seed override: 1h bucket stays 3600.
printf '{"observed_floor_s":0,"observed_ceiling_s":600,"updated_at":%s}\n' "$NOW" > "$LEARNED"
printf '900\n' > "$HOME/.claude/statusline-cache-ttl"
t_reset; t_assist $((NOW - 30)) fixmodel 100000 500 1h
bk1_out=$(run_statusline "$(statusline_payload ctx-bk1 "$(warm_extra "$TRANSCRIPT" 20 100000)")")
bk1_death=$(TZ=Europe/Kyiv date -r $((NOW - 30 + 3600)) +%H:%M)
assert grep -Fq "${DIM}100k${RESET}${DIM}→${bk1_death}${RESET}" <<< "$bk1_out"
rm -f "$HOME/.claude/statusline-cache-ttl" "$LEARNED"

# No bucket in the tail: seed override widens the death time to ts+7200.
t_reset; t_assist $((NOW - 50))
printf '7200\n' > "$HOME/.claude/statusline-cache-ttl"
ov_out=$(run_statusline "$(statusline_payload ctx-seedov "$(warm_extra "$TRANSCRIPT" 20 50000)")")
ov_death=$(TZ=Europe/Kyiv date -r $((NOW - 50 + 7200)) +%H:%M)
assert grep -Fq "${DIM}50k${RESET}${DIM}→${ov_death}${RESET}" <<< "$ov_out"
rm -f "$HOME/.claude/statusline-cache-ttl"

# A learned ceiling narrows the no-bucket TTL below the seed: ceiling 600 ->
# death = ts+600 (not ts+3600), still warm at a 50s-old response.
printf '{"observed_floor_s":0,"observed_ceiling_s":600,"updated_at":%s}\n' "$NOW" > "$LEARNED"
clamp_out=$(run_statusline "$(statusline_payload ctx-clamp "$(warm_extra "$TRANSCRIPT" 20 50000)")")
clamp_death=$(TZ=Europe/Kyiv date -r $((NOW - 50 + 600)) +%H:%M)
assert grep -Fq "${DIM}50k${RESET}${DIM}→${clamp_death}${RESET}" <<< "$clamp_out"
# And a ceiling below the response age flips warmth off (dim, no time).
printf '{"observed_floor_s":0,"observed_ceiling_s":50,"updated_at":%s}\n' "$NOW" > "$LEARNED"
clampdim_out=$(run_statusline "$(statusline_payload ctx-clampdim "$(warm_extra "$TRANSCRIPT" 20 50000)")")
assert grep -Fq "${DIM}50k${RESET} " <<< "$clampdim_out"
assert test "${clampdim_out#*→}" = "$clampdim_out"
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

# ...and a HIT after a gap longer than the believed ceiling disproves it.
printf '{"observed_floor_s":0,"observed_ceiling_s":200,"updated_at":%s}\n' "$NOW" > "$LEARNED"
learn_case learn-heal $((NOW - 500)) $((NOW - 200)) 50000 100
assert grep -Fq '"observed_ceiling_s":null' "$LEARNED"

# MISS (full rebuild) after a 600s gap lowers the ceiling to 600.
rm -f "$LEARNED"
learn_case learn-miss $((NOW - 800)) $((NOW - 200)) 0 50000
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
assert grep -Fq 'feature-x' <<< "$dwd_out"
assert grep -Fq "${GREEN}+2${RESET}/${RED}-0${RESET} ${DIM}+1f${RESET}" <<< "$dwd_out"
rm -f "$TOP_B/wt-junk.txt" "$STATE_DIR/workdir-diff-workdir"

# Detached HEAD still measures the diff (vs the detached commit).
printf 'd1\n' > "$TOP_C/det-junk.txt"
det_extra=$(jq -cn --arg d "$TOP_C" '{cwd:$d,workspace:{current_dir:$d,project_dir:$d}}')
ddet_out=$(run_statusline "$(statusline_payload diff-detached "$det_extra")")
assert grep -Fq "@$SHORT_SHA" <<< "$ddet_out"
assert grep -Fq "${GREEN}+1${RESET}/${RED}-0${RESET} ${DIM}+1f${RESET}" <<< "$ddet_out"
rm -f "$TOP_C/det-junk.txt"

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
9999 1 claude
SNAP
PSEOF
chmod +x "$FAKE_PS"
FAKE_LSOF="$FIXTURES/ports-lsof"
cat > "$FAKE_LSOF" <<'LSEOF'
#!/usr/bin/env bash
cat <<'OUT'
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
node     1001 u   20u  IPv4  0t0      TCP *:5173 (LISTEN)
node     1002 u   21u  IPv4  0t0      TCP 127.0.0.1:7000 (LISTEN)
python3  1003 u   22u  IPv4  0t0      TCP *:8123 (LISTEN)
node     1003 u   24u  IPv4  0t0      TCP *:5173 (LISTEN)
node     1004 u   23u  IPv6  0t0      TCP [::1]:9999 (LISTEN)
agy      1005 u   10u  IPv4  0t0      TCP 127.0.0.1:61609 (LISTEN)
node     1006 u   11u  IPv4  0t0      TCP 127.0.0.1:61610 (LISTEN)
OUT
LSEOF
chmod +x "$FAKE_LSOF"
FAKE_LSOF_EMPTY="$FIXTURES/ports-lsof-empty"
printf '#!/usr/bin/env bash\nprintf "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\\n"\n' > "$FAKE_LSOF_EMPTY"
chmod +x "$FAKE_LSOF_EMPTY"

run_probe() {
  STATUSLINE_PS="$FAKE_PS" STATUSLINE_LSOF="$FAKE_LSOF" "$PORTS_PROBE" "$1" "$2"
}
run_probe pp-parse 1001
# 61609/61610 are an LLM tool's own RPC — the agy process and a node it spawned — and neither
# is a place a human can go, so the probe drops both while keeping the two real servers.
assert_eq '5173 8123' "$(cat "$STATE_DIR/ports-pp-parse")"

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


# A claudeb launch command derives the 3-part tag.
glob_seed=$(worker_payload claudeb-worker worker/two 'Ship it' 'claudeb profile com -p --model sonnet --effort high')
glob_seed_output=$(printf '%s' "$glob_seed" | "$WORKER_HOOK") || fail "glob-tag seed exited nonzero"
assert_eq 'com · sonnet · high' "$(cat "$TAGDIR/workertwo")"
glob_later=$(worker_payload claudeb-worker worker/two 'Run tests' true)
glob_later_output=$(printf '%s' "$glob_later" | "$WORKER_HOOK") || fail "glob-tag rewrite exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "com · sonnet · high — Run tests"' \
  <<< "$glob_later_output" >/dev/null

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
review_dirty_payload=$(statusline_payload review-dirty "" "$REVIEW_DIRTY")
run_statusline "$review_dirty_payload" >/dev/null || fail "review dirty first render failed"
review_dirty_out=""
for _ in $(seq 1 20); do
  sleep 0.2
  review_dirty_out=$(run_statusline "$review_dirty_payload") || fail "review dirty render failed"
  grep -Fq 'review T1' <<< "$review_dirty_out" && break
done
assert grep -Fq 'review T1' <<< "$review_dirty_out"

REVIEW_CLEAN="$FIXTURES/review-clean"
git clone -q "$REPO_A" "$REVIEW_CLEAN"
review_clean_out=$(run_statusline "$(statusline_payload review-clean "" "$REVIEW_CLEAN")") \
  || fail "review clean render failed"
assert test "${review_clean_out#*review T}" = "$review_clean_out"
review_segment="review"
assert grep -Fq "$review_segment" <<< "$review_clean_out"
assert test "${review_clean_out#*⚖}" = "$review_clean_out"
review_clean_line="${review_clean_out%%$'\n'*}"
review_delimited=" ${DIM}│${RESET} review"
review_before="${review_clean_line%%"$review_delimited"*}"
review_after="${review_clean_line#*"$review_delimited"}"
assert grep -Fq "$(basename "$REVIEW_CLEAN")" <<< "$review_before"
assert test "${review_before#*"${DIM}w:"}" = "$review_before"
assert grep -Fq "${DIM}w:" <<< "$review_after"

review_clean_root=$(cd "$REVIEW_CLEAN" && pwd -P)
review_clean_hash=$(printf '%s' "$review_clean_root" | shasum -a 1 | awk '{print substr($1,1,8)}')
review_receipt_name="$(basename "$REVIEW_CLEAN")__${review_clean_hash}.json"

RECEIPT_DIR="$CLAUDEB_FIX/worker-stats/receipts"
mkdir -p "$RECEIPT_DIR"
review_clean_sha=$(git -C "$REVIEW_CLEAN" rev-parse HEAD)
review_clean_tree=$(git -C "$REVIEW_CLEAN" rev-parse HEAD^{tree})
review_clean_index_before=$(git -C "$REVIEW_CLEAN" hash-object .git/index)
review_clean_objects_before=$(find "$REVIEW_CLEAN/.git/objects" -type f | wc -l | tr -d ' ')
review_receipt_file="$RECEIPT_DIR/$review_receipt_name"
jq -cn --arg repo "$REVIEW_CLEAN" --arg tree "$review_clean_tree" \
  --arg commit "$review_clean_sha" --arg run_id receipt-match \
  '{repo:$repo,tree:$tree,commit:$commit,run_id:$run_id,ts:"2026-07-27T00:00:00+00:00",errored:0}' \
  > "$review_receipt_file"
review_clean_repo_key="$(basename "$REVIEW_CLEAN")-$(printf '%s' "$REVIEW_CLEAN" | cksum | awk '{print $1}')"
review_clean_cache="$HOME/.cache/claude-statusline/review-tier-$review_clean_repo_key"
mkdir -p "$(dirname "$review_clean_cache")"
printf 'T2\n' > "$review_clean_cache"
review_match_out=$(run_statusline "$(statusline_payload review-match "" "$REVIEW_CLEAN")") \
  || fail "review matching receipt render failed"
assert test "${review_match_out#*"$review_delimited"}" = "$review_match_out"
assert test "${review_match_out#*review T2}" = "$review_match_out"
assert_eq "$review_clean_index_before" "$(git -C "$REVIEW_CLEAN" hash-object .git/index)"
assert_eq "$review_clean_objects_before" \
  "$(find "$REVIEW_CLEAN/.git/objects" -type f | wc -l | tr -d ' ')"
rm -f "$review_clean_cache"

jq '.errored = 1' "$review_receipt_file" > "$review_receipt_file.tmp"
mv "$review_receipt_file.tmp" "$review_receipt_file"
review_partial_out=$(run_statusline "$(statusline_payload review-partial "" "$REVIEW_CLEAN")") \
  || fail "review partial receipt render failed"
assert grep -Fq "${DIM}review${RESET}" <<< "$review_partial_out"
assert test "${review_partial_out#*review T}" = "$review_partial_out"

jq '.errored = 0' "$review_receipt_file" > "$review_receipt_file.tmp"
mv "$review_receipt_file.tmp" "$review_receipt_file"
printf 'staged content\n' > "$REVIEW_CLEAN/tracked.txt"
git -C "$REVIEW_CLEAN" add tracked.txt
git -C "$REVIEW_CLEAN" show HEAD:tracked.txt > "$REVIEW_CLEAN/tracked.txt"
printf 'untracked object sentinel\n' > "$REVIEW_CLEAN/unique-untracked.txt"
assert test -n "$(git -C "$REVIEW_CLEAN" status --porcelain)"
review_dirty_objects_before=$(find "$REVIEW_CLEAN/.git/objects" -type f | wc -l | tr -d ' ')
review_dirty_match_out=$(run_statusline \
  "$(statusline_payload review-dirty-match "" "$REVIEW_CLEAN")") \
  || fail "review dirty matching-content render failed"
assert grep -Fq "$review_segment" <<< "$review_dirty_match_out"
assert_eq "$review_dirty_objects_before" \
  "$(find "$REVIEW_CLEAN/.git/objects" -type f | wc -l | tr -d ' ')"

rm -f "$review_receipt_file"
review_missing_out=$(run_statusline "$(statusline_payload review-missing "" "$REVIEW_CLEAN")") \
  || fail "review missing receipt render failed"
assert grep -Fq "$review_segment" <<< "$review_missing_out"

review_nongit_out=$(run_statusline "$(statusline_payload review-nongit "" "$NON_GIT")") \
  || fail "review non-git render failed"
assert test "${review_nongit_out#*review T}" = "$review_nongit_out"

PROGRESS_DIR="$CLAUDEB_FIX/worker-stats/progress"
mkdir -p "$PROGRESS_DIR"
progress_prefix="${review_receipt_name%.json}-"
write_progress() { # pid tier done total started [repo]
  jq -cn --arg repo "${6:-$REVIEW_CLEAN}" --argjson pid "$1" --arg tier "$2" \
    --argjson done_cells "$3" --argjson total "$4" --arg started "$5" '
    {repo:$repo, pid:$pid, run_id:"progress-fixture",
     tier:(if $tier == "" then null else $tier end), target:"abc1234",
     cells:[range($total) | "cell-\(.)"], done:[range($done_cells) | "cell-\(.)"],
     failed:0, started:$started, ts:$started}' \
    > "$PROGRESS_DIR/$progress_prefix$1.json"
}
progress_render() {
  run_statusline "$(statusline_payload "review-progress-$1" "" "$REVIEW_CLEAN")" \
    || fail "review progress render failed: $1"
}

# The live run owns the slot even when a receipt says the tree is already covered: a re-review
# in flight is what the eye needs, and the receipt verdict is one render away once it ends.
jq -cn --arg repo "$REVIEW_CLEAN" --arg tree "$review_clean_tree" \
  --arg commit "$review_clean_sha" --arg run_id receipt-match \
  '{repo:$repo,tree:$tree,commit:$commit,run_id:$run_id,ts:"2026-07-27T00:00:00+00:00",errored:0}' \
  > "$review_receipt_file"
write_progress "$$" T2 3 8 2026-07-27T22:00:00+00:00
progress_live_out=$(progress_render live)
assert grep -Fq 'review T2 3/8' <<< "$progress_live_out"
rm -f "$review_receipt_file"

# An --auto run carries no tier; the counter still renders.
write_progress "$$" "" 1 5 2026-07-27T22:00:00+00:00
progress_untiered_out=$(progress_render untiered)
assert grep -Fq 'review 1/5' <<< "$progress_untiered_out"
assert test "${progress_untiered_out#*review T}" = "$progress_untiered_out"

progress_second_pid=$( (sleep 30 >/dev/null 2>&1 & echo $!) )
write_progress "$$" T1 2 6 2026-07-27T22:00:00+00:00
write_progress "$progress_second_pid" T3 5 9 2026-07-27T23:30:00+00:00
progress_two_out=$(progress_render two-runs)
assert grep -Fq 'review T3 5/9' <<< "$progress_two_out"
assert test "${progress_two_out#*review T1}" = "$progress_two_out"
assert_eq 1 "$(grep -o 'review T3' <<< "$progress_two_out" | wc -l | tr -d ' ')"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"

# A pid the run no longer owns renders nothing: the file outlives kill -9, and the process now
# holding that pid necessarily started after the dead run's last write.
progress_recent=$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M.%S)
touch -t "$progress_recent" "$PROGRESS_DIR/$progress_prefix$progress_second_pid.json"
progress_recycled_out=$(progress_render recycled)
assert test "${progress_recycled_out#*5/9}" = "$progress_recycled_out"
assert grep -Fq "$review_segment" <<< "$progress_recycled_out"
kill "$progress_second_pid" 2>/dev/null
rm -f "$PROGRESS_DIR/$progress_prefix$progress_second_pid.json"

write_progress 99999999 T2 4 7 2026-07-27T22:00:00+00:00
progress_dead_out=$(progress_render dead-pid)
assert test "${progress_dead_out#*4/7}" = "$progress_dead_out"
rm -f "$PROGRESS_DIR/${progress_prefix}99999999.json"

write_progress "$$" T2 4 7 2026-07-27T22:00:00+00:00 "$REVIEW_DIRTY"
progress_foreign_out=$(progress_render foreign-repo)
assert test "${progress_foreign_out#*4/7}" = "$progress_foreign_out"

write_progress "$$" T2 9 7 2026-07-27T22:00:00+00:00
progress_overrun_out=$(progress_render overrun)
assert test "${progress_overrun_out#*9/7}" = "$progress_overrun_out"

printf 'not json\n' > "$PROGRESS_DIR/$progress_prefix$$.json"
progress_corrupt_out=$(progress_render corrupt)
assert grep -Fq "$review_segment" <<< "$progress_corrupt_out"
rm -f "$PROGRESS_DIR/$progress_prefix$$.json"

progress_gone_out=$(progress_render gone)
assert_eq 0 \
  "$(grep -Eco 'review (T[0-3] )?[0-9]+/[0-9]+' <<< "$progress_gone_out" | tr -d ' ')"
assert grep -Fq "$review_segment" <<< "$progress_gone_out"

REVIEW_STAMP="$FIXTURES/review-stamp"
git clone -q "$REPO_A" "$REVIEW_STAMP"
printf 'stamped dirty\n' >> "$REVIEW_STAMP/tracked.txt"
printf 'stamped untracked\n' > "$REVIEW_STAMP/untracked.txt"
stamp_output=$(CLAUDEB_DIR="$CLAUDEB_FIX" "$ROOT/bin/review-bench" reviewed \
  --repo "$REVIEW_STAMP") || fail "reviewed stamp failed"
assert grep -Fq 'stamped tree ' <<< "$stamp_output"
review_stamp_payload=$(statusline_payload review-stamp "" "$REVIEW_STAMP")
review_stamp_out=$(run_statusline "$review_stamp_payload") \
  || fail "reviewed dirty render failed"
assert test "${review_stamp_out#*"$review_delimited"}" = "$review_stamp_out"

printf 'extra edit\n' >> "$REVIEW_STAMP/tracked.txt"
review_stamp_changed_out=$(run_statusline "$review_stamp_payload") \
  || fail "reviewed changed render failed"
assert grep -Fq "$review_delimited" <<< "$review_stamp_changed_out"

printf 'fixture\nstamped dirty\n' > "$REVIEW_STAMP/tracked.txt"
git -C "$REVIEW_STAMP" add -A
git -C "$REVIEW_STAMP" -c user.name=Fixture -c user.email=fixture@example.com \
  commit -qm stamped
review_stamp_committed_out=$(run_statusline "$review_stamp_payload") \
  || fail "reviewed identical commit render failed"
assert test "${review_stamp_committed_out#*"$review_delimited"}" = "$review_stamp_committed_out"

# A cache the render may no longer trust is not shown: past the staleness window the segment
# disappears rather than repeating a tier that predates the current diff.
# The age rule is proved by the pair: the same cache renders while it is young and disappears once
# it is not, with the probe pointed at nothing so no refresh can rewrite it mid-assertion.
REVIEW_STUB="$FIXTURES/review-stub.sh"
printf '#!/usr/bin/env bash\nprintf "tier: T3\\n"\n' > "$REVIEW_STUB"
chmod +x "$REVIEW_STUB"
rm -f "$HOME/.cache/claude-statusline"/review-tier-*
review_fresh_out=""
for _ in $(seq 1 20); do
  sleep 0.2
  review_fresh_out=$(STATUSLINE_REVIEW_BENCH_BIN="$REVIEW_STUB" \
    run_statusline "$review_dirty_payload") || fail "review stub render failed"
  grep -Fq 'review T3' <<< "$review_fresh_out" && break
done
assert grep -Fq 'review T3' <<< "$review_fresh_out"
review_cache_file=$(ls "$HOME/.cache/claude-statusline"/review-tier-* 2>/dev/null | head -n1)
assert test -n "$review_cache_file"
touch -t 200001010000 "$review_cache_file"
review_stale_out=$(STATUSLINE_REVIEW_BENCH_BIN="$FIXTURES/absent-review-bench" \
  run_statusline "$review_dirty_payload") || fail "review stale render failed"
assert test "${review_stale_out#*review T}" = "$review_stale_out"

# A probe that fails or answers with something else leaves no tier behind.
REVIEW_BROKEN="$FIXTURES/review-broken.sh"
printf '#!/usr/bin/env bash\nprintf "totally unexpected\\n"\nexit 0\n' > "$REVIEW_BROKEN"
chmod +x "$REVIEW_BROKEN"
rm -f "$HOME/.cache/claude-statusline"/review-tier-*
for _ in $(seq 1 20); do
  sleep 0.2
  review_broken_out=$(STATUSLINE_REVIEW_BENCH_BIN="$REVIEW_BROKEN" \
    run_statusline "$review_dirty_payload") || fail "review broken render failed"
done
assert test "${review_broken_out#*review T}" = "$review_broken_out"

REVIEW_FAILING="$FIXTURES/review-failing.sh"
printf '#!/usr/bin/env bash\nexit 3\n' > "$REVIEW_FAILING"
chmod +x "$REVIEW_FAILING"
rm -f "$HOME/.cache/claude-statusline"/review-tier-*
for _ in $(seq 1 20); do
  sleep 0.2
  review_failing_out=$(STATUSLINE_REVIEW_BENCH_BIN="$REVIEW_FAILING" \
    run_statusline "$review_dirty_payload") || fail "review failing render failed"
done
assert test "${review_failing_out#*review T}" = "$review_failing_out"

echo "PASS: $asserts asserts; workdir tracking, worktree/agent filtering, statusline segments, the merged review lifecycle with precedence and staleness cases, main-last and Gemini account predictions, and Codex/claudeb/Gemini worker tag propagation"
