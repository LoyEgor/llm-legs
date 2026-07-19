#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR_HOOK="$ROOT/bin/statusline-workdir-hook.sh"
WORKER_HOOK="$ROOT/bin/worker-tag-hook.sh"
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
ln -s "$REPO_B" "$HOME/project"
TOP_A=$(git -C "$REPO_A" rev-parse --show-toplevel)
TOP_B=$(git -C "$REPO_B" rev-parse --show-toplevel)
TOP_C=$(git -C "$REPO_C" rev-parse --show-toplevel)
SHORT_SHA=$(git -C "$REPO_C" rev-parse --short HEAD)

DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; MAGENTA=$'\033[35m'; RESET=$'\033[0m'
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
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg session "$1" --arg cwd "$REPO_A" --argjson extra "$extra" '
    {session_id:$session,cwd:$cwd,workspace:{current_dir:$cwd,project_dir:$cwd},
     model:{display_name:"Fixture"},effort:{level:"high"},
     context_window:{used_percentage:12,current_usage:{input_tokens:1000}},
     cost:{total_lines_added:0,total_lines_removed:0}}
    * $extra'
}

run_statusline() {
  # The ports probe reads the real process tree; neutralize it (true emits no
  # snapshot -> empty cache) so renders stay hermetic and deterministic.
  printf '%s' "$1" | CLAUDE_LIMITS_ACCOUNT="${2:--}" CLAUDEB_DIR="$CLAUDEB_FIX" \
    LLM_LIMITS_FILE="$WORK/limits.json" STATUSLINE_PS=true STATUSLINE_LSOF=true "$STATUSLINE"
}

status_payload=$(statusline_payload status-override)
control_one=$(run_statusline "$status_payload") || fail "statusline control failed"
control_two=$(run_statusline "$status_payload") || fail "statusline second control failed"
assert_eq "$control_one" "$control_two"
assert grep -Fq main <<< "$control_one"
assert test "${control_one#*»}" = "$control_one"

printf '%s\n' "$TOP_B" > "$STATE_DIR/workdir-status-override"
override_output=$(run_statusline "$status_payload") || fail "statusline override failed"
assert grep -Fq '»' <<< "$override_output"
assert grep -Fq feature-x <<< "$override_output"
assert grep -Fq "$(basename "$TOP_B")" <<< "$override_output"

same_payload=$(statusline_payload status-same)
printf '%s\n' "$TOP_A" > "$STATE_DIR/workdir-status-same"
same_output=$(run_statusline "$same_payload") || fail "statusline same-repo failed"
assert grep -Fq main <<< "$same_output"
assert test "${same_output#*»}" = "$same_output"

printf '%s\n' "$FIXTURES/vanished" > "$STATE_DIR/workdir-status-dangling"
dangling_output=$(run_statusline "$(statusline_payload status-dangling)") || fail "statusline dangling failed"
assert grep -Fq main <<< "$dangling_output"
assert test "${dangling_output#*»}" = "$dangling_output"
assert test ! -e "$STATE_DIR/workdir-status-dangling"

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

onem_output=$(run_statusline "$(statusline_payload status-1m '{"context_window":{"context_window_size":1000000}}')") || fail "statusline 1m failed"
assert grep -Fq "${DIM}1m${RESET}" <<< "$onem_output"
assert test "${with_effort#*"${DIM}1m${RESET}"}" = "$with_effort"

worker_file="$HOME/.claude/worker-model"
rm -f "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-def)")
assert grep -Fq 'w:son' <<< "$worker_out"

printf 'worker=sonnet\nsonnet_effort=high\ncodex_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-son-eff)")
assert grep -Fq "w:son${RESET}${DIM}·hi${RESET}" <<< "$worker_out"

printf 'worker=codex\ncodex_effort=medium\ncodex_profile=alt\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex)")
assert grep -Fq "w:codex${RESET} ${MAGENTA}@alt${RESET}${DIM}·med${RESET}" <<< "$worker_out"

printf 'worker=codex\ncodex_effort=xhigh\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-unres)")
assert grep -Fq "w:codex${RESET} ${MAGENTA}~?${RESET}${DIM}·xh${RESET}" <<< "$worker_out"

printf 'worker=claudeb\ncodex_effort=high\nclaudeb_profile=notcom\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb)")
assert grep -Fq "w:cb${RESET} ${MAGENTA}@notcom${RESET}${DIM}·opus·hi${RESET}" <<< "$worker_out"

printf 'worker=claudeb\ncodex_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-unres)")
assert grep -Fq "w:cb${RESET} ${MAGENTA}~?${RESET}${DIM}·opus·hi${RESET}" <<< "$worker_out"

printf 'worker=frobnicate\ncodex_effort=high\ncodex_profile=alt\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-bad)")
assert grep -Fq 'w:?' <<< "$worker_out"
assert test "${worker_out#*@alt}" = "$worker_out"
rm -f "$worker_file"

NOW=$(date +%s)
bucket_json() {
  jq -cn --argjson now "$NOW" --argjson h5 "$1" --argjson wk "$2" --argjson h5_age "${3:-0}" '
    {five_hour:{used_percentage:$h5,resets_at:($now+3600),as_of:($now-$h5_age),origin:"headers"},
     seven_day:{used_percentage:$wk,resets_at:($now+86400),as_of:$now,origin:"headers"},
     auth:{status:"ok",checked_at:$now}}'
}

printf 'acctgen\n' > "$CLAUDEB_FIX/.claudeb-state"
printf 'acctfab\n' > "$CLAUDEB_FIX/.claudeb-state-fable"
bucket_json 33 11 > "$CLAUDEB_FIX/limits/acctfab.json"
bucket_json 44 22 > "$CLAUDEB_FIX/limits/acctgen.json"

fable_payload=$(statusline_payload status-rot-fable '{"model":{"id":"claude-fable-5[1m]","display_name":"Fable"}}')
fable_out=$(run_statusline "$fable_payload") || fail "statusline rotating fable failed"
assert grep -Fq '~acctfab' <<< "$fable_out"
assert grep -Fq "${GREEN}33%" <<< "$fable_out"
assert grep -Fq "${GREEN}11%" <<< "$fable_out"

general_payload=$(statusline_payload status-rot-gen \
  '{"model":{"id":"claude-sonnet-5","display_name":"Sonnet"},"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":'"$((NOW + 3600))"'}}}')
general_out=$(run_statusline "$general_payload") || fail "statusline rotating general failed"
assert grep -Fq '~acctgen' <<< "$general_out"
assert grep -Fq "${GREEN}44%" <<< "$general_out"
assert_eq "$(bucket_json 44 22)" "$(cat "$CLAUDEB_FIX/limits/acctgen.json")"

printf 'worker=claudeb\ncodex_effort=high\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-cb-rot '{"model":{"id":"claude-fable-5","display_name":"Fable"}}')" main)
assert grep -Fq "w:cb${RESET} ${MAGENTA}~acctgen${RESET}${DIM}·opus·hi${RESET}" <<< "$worker_out"
assert test "${worker_out#*acctfab}" = "$worker_out"

jq -cn --argjson now "$NOW" '{vendors:{codex:{accounts:[
  {account:"alpha",five_hour:{used_pct:90,resets_at:($now+3600|todateiso8601)},weekly:{used_pct:50,resets_at:($now+86400|todateiso8601)}},
  {account:"beta",five_hour:{used_pct:10,resets_at:($now+3600|todateiso8601)},weekly:{used_pct:20,resets_at:($now+86400|todateiso8601)}},
  {account:"mystery",five_hour:null,weekly:null},
  {account:"gone",auth_needed:true,five_hour:{used_pct:1,resets_at:($now+3600|todateiso8601)}},
  {account:"full",five_hour:{used_pct:100,resets_at:($now+3600|todateiso8601)},weekly:{used_pct:5,resets_at:($now+86400|todateiso8601)}},
  {account:"rolled",five_hour:{used_pct:99,resets_at:($now-60|todateiso8601)},weekly:{used_pct:5,resets_at:($now+86400|todateiso8601)}}
]}}}' > "$WORK/limits.json"
printf 'worker=codex\ncodex_effort=medium\n' > "$worker_file"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-rot)" main)
assert grep -Fq "w:codex${RESET} ${MAGENTA}~rolled${RESET}${DIM}·med${RESET}" <<< "$worker_out"

jq -cn --argjson now "$NOW" '{vendors:{codex:{accounts:[
  {account:"full",five_hour:{used_pct:100,resets_at:($now+3600|todateiso8601)}},
  {account:"gone",auth_needed:true}
]}}}' > "$WORK/limits.json"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-fallback)" main)
assert grep -Fq "w:codex${RESET} ${MAGENTA}~main${RESET}${DIM}·med${RESET}" <<< "$worker_out"

printf '{"vendors":{"claude":{}}}' > "$WORK/limits.json"
worker_out=$(run_statusline "$(statusline_payload status-w-codex-novendor)" main)
assert grep -Fq "w:codex${RESET} ${MAGENTA}~?${RESET}${DIM}·med${RESET}" <<< "$worker_out"
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
  CLAUDE_LIMITS_ACCOUNT=- CLAUDEB_DIR="$CLAUDEB_FIX" LLM_LIMITS_FILE="$WORK/limits.json" \
  "$STATUSLINE" 2>"$WORK/cost-stderr") || fail "statusline cost locale failed"
assert grep -Fq '$18.20' <<< "$cost_out"
assert_eq "" "$(cat "$WORK/cost-stderr")"

# --- ctx color (only the % is colored; token count always dim; ctx warn at 40) ---
ctx_case() { statusline_payload "$1" '{"context_window":{"used_percentage":'"$2"',"current_usage":{"input_tokens":'"$3"'}}}'; }
ctx_lo=$(run_statusline "$(ctx_case ctx-lo 39 50000)")
assert grep -Fq "ctx ${GREEN}39%${RESET}" <<< "$ctx_lo"
assert grep -Fq "${DIM}50k${RESET}" <<< "$ctx_lo"
ctx_warn=$(run_statusline "$(ctx_case ctx-warn 40 120000)")
assert grep -Fq "ctx ${YELLOW}40%${RESET}" <<< "$ctx_warn"
assert grep -Fq "${DIM}120k${RESET}" <<< "$ctx_warn"
ctx_red=$(run_statusline "$(ctx_case ctx-red 80 180000)")
assert grep -Fq "ctx ${RED}80%${RESET}" <<< "$ctx_red"
assert grep -Fq "${DIM}180k${RESET}" <<< "$ctx_red"

# --- statusline-freshness-gate.sh ---
FRESH_GATE="$ROOT/bin/statusline-freshness-gate.sh"
fg_payload() {
  jq -cn --arg event "$1" --arg tool "$2" --arg file "$3" \
    '{hook_event_name:$event,tool_name:$tool,
      tool_input:(if $tool=="NotebookEdit" then {notebook_path:$file} else {file_path:$file} end)}'
}
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/statusline.sh" | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse Write "$ROOT/bin/statusline-topic-hook.sh" | "$FRESH_GATE")
assert grep -Fq 'statusline-contract.md' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse NotebookEdit "/x/statusline-ports-probe.sh" | "$FRESH_GATE")
assert grep -Fq 'freshness contract' <<< "$fg_out"
fg_out=$(fg_payload PostToolUse Edit "$ROOT/bin/claudeb" | "$FRESH_GATE")
assert_eq "" "$fg_out"
fg_out=$(fg_payload PreToolUse Edit "$ROOT/bin/statusline.sh" | "$FRESH_GATE")
assert_eq "" "$fg_out"
fg_out=$(printf '{broken' | "$FRESH_GATE") || fail "freshness gate broken json nonzero"
assert_eq "" "$fg_out"

# --- statusline-topic-hook.sh ---
TOPIC_HOOK="$ROOT/bin/statusline-topic-hook.sh"
INTERACTIVE_PS="$FIXTURES/ps-interactive"
printf '900 1 claude\n' > "$INTERACTIVE_PS"
HEADLESS_PS="$FIXTURES/ps-headless"
printf '901 900 claude -p --model opus\n900 1 -zsh\n' > "$HEADLESS_PS"
# A benign fast claudeb so background generators from fast-path triggers finish
# instantly with an empty reply (keeps the old topic); overwritten per case below.
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/claudeb"
chmod +x "$HOME/.local/bin/claudeb"

topic_prompt() {
  jq -cn --arg event UserPromptSubmit --arg session "$1" --arg prompt "$2" \
    '{hook_event_name:$event,session_id:$session,prompt:$prompt}'
}
run_topic() {
  printf '%s' "$(topic_prompt "$1" "$2")" | \
    TOPIC_PS_SNAPSHOT="$3" TOPIC_ANCESTOR_START="$4" "$TOPIC_HOOK"
}

silence_out=$(run_topic t-silence 'a substantive first prompt about timers' "$INTERACTIVE_PS" 900)
assert_eq "" "$silence_out"

run_topic t-first 'work on the menu resume timer feature' "$INTERACTIVE_PS" 900
assert test -f "$STATE_DIR/topic-t-first.buf"
assert grep -Fq 'menu resume timer' "$STATE_DIR/topic-t-first.buf"
IFS=' ' read -r tf_lg tf_cnt < "$STATE_DIR/topic-t-first.meta"
assert_eq 0 "$tf_cnt"

printf 'существующая тема\n' > "$STATE_DIR/topic-t-debounce"
printf '0 0\n' > "$STATE_DIR/topic-t-debounce.meta"
for i in 1 2 3 4; do run_topic t-debounce "meaningful prompt number $i here" "$INTERACTIVE_PS" 900; done
IFS=' ' read -r td_lg td_cnt < "$STATE_DIR/topic-t-debounce.meta"
assert_eq 4 "$td_cnt"
run_topic t-debounce "meaningful prompt number 5 here" "$INTERACTIVE_PS" 900
IFS=' ' read -r td_lg td_cnt < "$STATE_DIR/topic-t-debounce.meta"
assert_eq 0 "$td_cnt"

run_topic t-trivial 'ок' "$INTERACTIVE_PS" 900
assert test ! -e "$STATE_DIR/topic-t-trivial.buf"

recguard_out=$(printf '%s' "$(topic_prompt t-recguard 'a long substantive prompt here')" | \
  CLAUDE_STATUSLINE_TOPIC_GEN=1 TOPIC_PS_SNAPSHOT="$INTERACTIVE_PS" TOPIC_ANCESTOR_START=900 "$TOPIC_HOOK")
assert_eq "" "$recguard_out"
assert test ! -e "$STATE_DIR/topic-t-recguard.buf"

run_topic t-headless 'a long substantive prompt about the timers' "$HEADLESS_PS" 901
assert test ! -e "$STATE_DIR/topic-t-headless.buf"
run_topic t-interactive 'a long substantive prompt about the timers' "$INTERACTIVE_PS" 900
assert test -f "$STATE_DIR/topic-t-interactive.buf"

printf 'тема\n' > "$STATE_DIR/topic-t-clear"
printf '1 1\n' > "$STATE_DIR/topic-t-clear.meta"
printf 'x\n' > "$STATE_DIR/topic-t-clear.buf"
printf '%s' "$(jq -cn '{hook_event_name:"SessionStart",source:"clear",session_id:"t-clear"}')" | "$TOPIC_HOOK"
assert test ! -e "$STATE_DIR/topic-t-clear"
assert test ! -e "$STATE_DIR/topic-t-clear.meta"
assert test ! -e "$STATE_DIR/topic-t-clear.buf"

printf 'тема\n' > "$STATE_DIR/topic-t-compact"
printf '%s' "$(jq -cn '{hook_event_name:"SessionStart",source:"compact",session_id:"t-compact"}')" | "$TOPIC_HOOK"
assert test -f "$STATE_DIR/topic-t-compact"

# Generator (--generate) reply validation, synchronous with a canned claudeb.
gen_cb() { printf '#!/bin/sh\n%s\n' "$1" > "$HOME/.local/bin/claudeb"; chmod +x "$HOME/.local/bin/claudeb"; }

printf 'first line about the timer work\nsecond line\n' > "$STATE_DIR/topic-t-gen-ok.buf"
gen_cb "printf 'работа с таймером меню\\n'"
"$TOPIC_HOOK" --generate t-gen-ok
assert_eq 'работа с таймером меню' "$(cat "$STATE_DIR/topic-t-gen-ok")"

printf 'buf\n' > "$STATE_DIR/topic-t-gen-long.buf"
printf 'старая тема\n' > "$STATE_DIR/topic-t-gen-long"
gen_cb "printf 'это очень длинная тема которая точно превышает шестьдесят символов лимита ответа модели\\n'"
"$TOPIC_HOOK" --generate t-gen-long
assert_eq 'старая тема' "$(cat "$STATE_DIR/topic-t-gen-long")"

printf 'buf\n' > "$STATE_DIR/topic-t-gen-md.buf"
printf 'старая\n' > "$STATE_DIR/topic-t-gen-md"
gen_cb "printf '\"тема в кавычках\"\\n'"
"$TOPIC_HOOK" --generate t-gen-md
assert_eq 'старая' "$(cat "$STATE_DIR/topic-t-gen-md")"

printf 'buf\n' > "$STATE_DIR/topic-t-gen-multi.buf"
gen_cb "printf 'работа с меню\\nlishnyaya stroka\\n'"
"$TOPIC_HOOK" --generate t-gen-multi
assert_eq 'работа с меню' "$(cat "$STATE_DIR/topic-t-gen-multi")"

rm -f "$STATE_DIR/topic-t-gen-empty.buf" "$STATE_DIR/topic-t-gen-empty"
gen_cb "printf 'должно быть проигнорировано\\n'"
"$TOPIC_HOOK" --generate t-gen-empty
assert test ! -e "$STATE_DIR/topic-t-gen-empty"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/claudeb"

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
assert_eq '5173 8123' "$(cat "$STATE_DIR/ports-pp-parse")"

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
assert test "${rcap_out#*:4}" = "$rcap_out"

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

printf 'работа с таймером меню\n' > "$STATE_DIR/topic-r-topic"
rtopic_out=$(run_statusline "$(statusline_payload r-topic)")
assert grep -Fq 'работа с таймером меню' <<< "$rtopic_out"

rm -f "$STATE_DIR/topic-r-topic-absent"
rtabsent_out=$(run_statusline "$(statusline_payload r-topic-absent)")
assert test "${rtabsent_out#*работа с таймером}" = "$rtabsent_out"

printf 'абвгдежзийклмнопрстуфхцчшщъыьэюяабвгдежзийклмнопрст\n' > "$STATE_DIR/topic-r-long"
rlong_out=$(run_statusline "$(statusline_payload r-long)")
assert grep -Fq '…' <<< "$rlong_out"

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
assert jq -e '.hookSpecificOutput.updatedInput.description == "main · high — Investigate the suite"' <<< "$seed_output" >/dev/null
assert_eq 'main · high' "$(cat "$TAGDIR/workerone")"

# A later non-launch command reuses the stored tag to prefix its description.
later=$(worker_payload codex-worker worker/one 'Run focused tests' 'bash tests/focused.sh')
later_output=$(printf '%s' "$later" | "$WORKER_HOOK") || fail "worker rewrite exited nonzero"
assert jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and
  .hookSpecificOutput.permissionDecision == "allow" and
  .hookSpecificOutput.updatedInput.description == "main · high — Run focused tests" and
  .hookSpecificOutput.updatedInput.command == "bash tests/focused.sh" and
  .hookSpecificOutput.updatedInput.timeout == 42' <<< "$later_output" >/dev/null

# An already-prefixed description is left untouched (no stacking).
prefixed=$(worker_payload codex-worker worker/one 'main · high — Run focused tests' true)
prefixed_output=$(printf '%s' "$prefixed" | "$WORKER_HOOK") || fail "prefixed worker call exited nonzero"
assert_eq "" "$prefixed_output"

# A claudeb launch command derives the 3-part tag.
glob_seed=$(worker_payload claudeb-worker worker/two 'Ship it' 'claudeb profile com -p --model sonnet --effort high')
glob_seed_output=$(printf '%s' "$glob_seed" | "$WORKER_HOOK") || fail "glob-tag seed exited nonzero"
assert_eq 'com · sonnet · high' "$(cat "$TAGDIR/workertwo")"
glob_later=$(worker_payload claudeb-worker worker/two 'Run tests' true)
glob_later_output=$(printf '%s' "$glob_later" | "$WORKER_HOOK") || fail "glob-tag rewrite exited nonzero"
assert jq -e '.hookSpecificOutput.updatedInput.description == "com · sonnet · high — Run tests"' \
  <<< "$glob_later_output" >/dev/null

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

echo "PASS: $asserts asserts; workdir tracking, worktree/agent filtering, statusline segments, and worker tag propagation"
