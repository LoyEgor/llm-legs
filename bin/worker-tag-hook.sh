#!/usr/bin/env bash
# PreToolUse(Bash) inside relay-worker agents. Derives the
# account·model·effort tag from the ACTUAL launch command text (claudeb/codex
# CLI arguments), never from the model's description discipline,
# then prefixes the tag onto every Bash description so the UI activity line
# always names who is spending quota. Tag files are session-scoped so the
# subagent rows can surface the tag. Fail-open everywhere.
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

# A hook runs on the interactive path: it reads the model list, it never refreshes it. A cold
# or expired cache would otherwise put a 30 s bounded `grok models` in front of the keystroke,
# and every concurrent hook would start its own.
export GROKB_MODELS_NO_FETCH=1

IFS= read -r -d '' input || :
case $input in *'"agent_type"'*) ;; *) exit 0 ;; esac

fields=()
eval "fields=($(jq -rn '[inputs] | select(length == 1) | .[0]
  | [.hook_event_name, .agent_type, .agent_id, .session_id, .tool_input.command, .tool_input.description, .transcript_path]
  | select(all(.[]; type != "object" and type != "array"))
  | map(if . == null or . == false then "" elif type == "string" then . else tojson end) | @sh' <<<"$input" 2>/dev/null))"
field() {
  local i
  case $1 in
    .hook_event_name) i=0 ;; .agent_type) i=1 ;; .agent_id) i=2 ;; .session_id) i=3 ;;
    .tool_input.command) i=4 ;; .tool_input.description) i=5 ;; .transcript_path) i=6 ;;
  esac
  if [ "${#fields[@]}" = 7 ] && [ -n "${i:-}" ]; then
    printf '%s\n' "${fields[$i]}"
  else
    printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
  fi
}

[ "$(field '.hook_event_name')" = PreToolUse ] || exit 0
agent_type=$(field '.agent_type')
case "$agent_type" in
  codex-worker|claudeb-worker|gemini-worker|grok-worker|light-worker|light-research) ;;
  fork|review-waiter) ;;
  *) exit 0 ;;
esac
agent_id=$(field '.agent_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$agent_id" ] || exit 0
session_id=$(field '.session_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$session_id" ] || session_id=_
[ "$session_id" = _ ] || export CLAUDE_CODE_SESSION_ID="$session_id"

command=$(field '.tool_input.command')
description=$(field '.tool_input.description')

cache_root="$HOME/.cache/claude-worker-tags"
cache_dir="$cache_root/$session_id"
tag_file="$cache_dir/$agent_id"
WORKER_PICK="${WORKER_TAG_WORKER_PICK:-$HOME/.local/bin/worker-pick}"
runs_root="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"

worker_conf() { worker_model_pinned_account "$1" 2>/dev/null; }

self_dir() {
  local path=${BASH_SOURCE[0]} dir
  while [ -L "$path" ]; do
    dir=$(cd -P "$(dirname "$path")" && pwd) || return 1
    path=$(readlink "$path")
    [[ "$path" = /* ]] || path="$dir/$path"
  done
  cd -P "$(dirname "$path")" && pwd
}
SELF_DIR=$(self_dir) || SELF_DIR=''
_load_worker_model() {
  command -v worker_model_pin_first >/dev/null 2>&1 && return 0
  [ -n "$SELF_DIR" ] || return 1
  . "$SELF_DIR/../share/worker-model.sh" 2>/dev/null
}
_load_worker_model || true
# A heredoc body is blanked line for line, delimiter included: a brief written through `<<EOF`
# quotes launch-shaped lines that launch nothing, while the command after the delimiter is real.
# '\n' can match no single line, so no body counts as fed to a shell.
launch=$command
command -v heredoc_mask >/dev/null 2>&1 || . "$SELF_DIR/../share/heredoc-mask.sh" 2>/dev/null
! command -v heredoc_mask >/dev/null 2>&1 || launch=$(heredoc_mask '\n' '\n' <<<"$command")
# worker-run refuses start and wait inside Claude Code to anything but a relay named by this token, so
# every call of a relay carries it: the text gates never read a script's body, the environment reaches
# it. An ATTACH relay's token says so, and worker-run starts nothing for it.
relay_prefix=''
case "$agent_type" in
  codex-worker|claudeb-worker|gemini-worker|grok-worker|light-worker|light-research)
    relay_token="$agent_type:${agent_id//[^A-Za-z0-9_-]/}"
    command -v relay_first_prompt >/dev/null 2>&1 || . "$SELF_DIR/../share/relay-transcript.sh" 2>/dev/null
    case "$(relay_first_prompt "$(field '.transcript_path')" "$agent_id" 2>/dev/null | head -n1)" in
      'ATTACH '*) relay_token="$relay_token:attach" ;;
    esac
    relay_prefix="export WORKER_RUN_RELAY=$relay_token"$'\n' ;;
esac
decision=allow
case "$agent_type" in light-research|fork|review-waiter) decision='' ;; esac
emit() { # description command
  [ -n "$relay_prefix" ] || [ -n "$1" ] || exit 0
  printf '%s' "$input" | jq -c --arg description "$1" --arg decision "$decision" \
    --arg command "$relay_prefix$2" '
    {hookSpecificOutput: ({
      hookEventName: "PreToolUse",
      updatedInput: (.tool_input | if $description != "" then .description = $description else . end
        | .command = $command)
    } + (if $decision == "" then {} else {permissionDecision: $decision} end))}
  ' 2>/dev/null
  exit 0
}
done_untagged() { [ -z "$relay_prefix" ] && exit 0; emit "" "$command"; }

SEED_MAX_AGE_S=${WORKER_TAG_SEED_MAX_AGE_S:-600}
prompt_key() { shasum -a 256 2>/dev/null | cut -c1-16; }
# The spawn's first prompt line is the one fact both the seed and the agent's own transcript carry.
agent_prompt_key() {
  local first
  command -v relay_first_prompt >/dev/null 2>&1 || . "$SELF_DIR/../share/relay-transcript.sh" 2>/dev/null || return 0
  first=$(relay_first_prompt "$(field '.transcript_path')" "$agent_id" | sed -n '1s/^/k:/p')
  [ -z "$first" ] || printf '%s\n' "${first#k:}" | prompt_key
}
# An agent that knows its spawn key takes only the seed carrying that key, and a denied or cancelled
# spawn leaves its seed behind: an agent without a key takes only a fresh seed.
pick_seed() {
  local key seed seed_key mtime now
  key=$(agent_prompt_key)
  now=$(date +%s)
  while IFS= read -r seed; do
    [ -f "$seed" ] || continue
    seed_key=$(sed -n 's/^spawn=//p' "$seed" 2>/dev/null | head -n1)
    if [ -n "$key" ]; then
      [ "$key" = "$seed_key" ] && { printf '%s' "$seed"; return 0; }
      continue
    fi
    mtime=$(stat -f %m "$seed" 2>/dev/null || stat -c %Y "$seed" 2>/dev/null) || continue
    [ "$((now - mtime))" -le "$SEED_MAX_AGE_S" ] || continue
    printf '%s' "$seed"
    return 0
  done < <(ls -tr "$cache_dir/pending-$agent_type"-* 2>/dev/null)
}
tag_line() { local first; [ -f "$tag_file" ] && IFS= read -r first < "$tag_file" && printf '%s' "$first"; }
tag_value() { [ -f "$tag_file" ] && sed -n "s/^$1=//p" "$tag_file" 2>/dev/null | tail -n1; }
# The account an earlier tag of this agent already named — its own file, else its unclaimed seed.
known_account() {
  local line seed
  line=$(tag_line)
  if [ -z "$line" ]; then
    for seed in "$(pick_seed)" "$cache_dir/pending-$agent_type"; do
      [ -f "$seed" ] && IFS= read -r line < "$seed" && break
    done
  fi
  case "$line" in
    *' · '*' · '*) line=${line%% · *}; [ "$line" = '?' ] || printf '%s' "$line" ;;
  esac
}
account_fallback() { # vendor
  local acct
  acct=$(known_account)
  [ -n "$acct" ] || { [ -x "$WORKER_PICK" ] && acct=$("$WORKER_PICK" --account "$1" 2>/dev/null); }
  printf '%s' "${acct:-?}"
}
# Rewrites the tag file atomically: line one is the tag (kept when $1 is empty), every other line a
# key=value the renderer reads; each further argument sets one key, and `key=` drops it.
# One lock per session directory serializes every tag-file rewrite: this hook, the `edit=N` count in
# statusline-workdir-hook.sh and worker-run's claim_agent_tag all take `.claim.lock`.
tag_lock() {
  local tries=0 broke=0 max=${WORKER_TAG_LOCK_TRIES:-30}
  [[ $max =~ ^[0-9]+$ ]] || max=30
  until mkdir "$cache_dir/.claim.lock" 2>/dev/null; do
    if [ "$tries" -ge "$max" ]; then
      [ "$broke" = 0 ] && [ -n "$(find "$cache_dir/.claim.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
      rmdir "$cache_dir/.claim.lock" 2>/dev/null
      broke=1 tries=0
      continue
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
}
write_tag_file() { # tag [key=value]...
  mkdir -p "$cache_dir" 2>/dev/null || return 1
  tag_lock || return 1
  write_tag_file_locked "$@"
  local rc=$?
  rmdir "$cache_dir/.claim.lock" 2>/dev/null
  return "$rc"
}
write_tag_file_locked() { # tag [key=value]...
  local tag="$1" tmp kv key want
  shift
  [ -n "$tag" ] || tag=$(tag_line)
  tmp="$tag_file.tmp.$$"
  {
    printf '%s\n' "$tag"
    [ -f "$tag_file" ] && tail -n +2 "$tag_file" | while IFS= read -r kv; do
      key=${kv%%=*}
      for want in "$@"; do [ "${want%%=*}" = "$key" ] && continue 2; done
      printf '%s\n' "$kv"
    done
    for kv in "$@"; do [ -z "${kv#*=}" ] || printf '%s\n' "$kv"; done
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$tag_file" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}
grab() { printf '%s' "$launch" | grep -oE -e "$1" 2>/dev/null | head -n1; }
review_tag() { # run-id
  local doc
  doc=$(cat "${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}"/progress/*.json 2>/dev/null |
    jq -c --arg run "$1" 'select(.run_id? == $run)' 2>/dev/null | tail -n1)
  [ -n "$doc" ] || { printf 'review · %s' "${1: -7}"; return; }
  printf '%s' "$doc" | jq -r 'def word(d): (if . == null then "" else tostring | gsub("[^A-Za-z0-9_.-]"; "") end) | if . == "" then d else . end;
    (if (.kind // "") == "task" or (.hunt // false) then "task" else "review" end) as $kind
    | [(.tier | word("T?")), (.composition | word("standard")), (.lens | word($kind))] | join(" · ")' 2>/dev/null
}

# A launcher name counts only where a command word can stand: line start or
# after a shell separator, optionally path-prefixed and behind env assignments
# and wrapper words (the documented launches run under CODEX_HOME=… and
# timeout/nohup). Unanchored, prose naming "claudeb profile X" tags X.
cmd_word='(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(nohup|env|nice|timeout)([[:space:]]+(-[^[:space:]]+|[0-9]+[smhd]?))*[[:space:]]+)*([^[:space:];&|()]*/)?'

is_grokb_launch() {
  printf '%s' "$launch" | grep -qE \
    "${cmd_word}"'grokb[[:space:]]+((profile|p|run)[[:space:]]+["'\'']*[a-z0-9][a-z0-9-]*|["'\'']*[a-z0-9][a-z0-9-]*["'\'']*[[:space:]]+exec)'
}

is_geminib_launch() {
  printf '%s' "$launch" | grep -qE \
    "${cmd_word}"'geminib[[:space:]]+((profile|p|run)[[:space:]]+["'\'']*[a-z0-9][a-z0-9-]*|["'\'']*[a-z0-9][a-z0-9-]*["'\'']*[[:space:]]+exec)'
}

codex_model_short_label() {
  local model
  model=$(worker_model_allowed_models codex | head -n1)
  printf '%s' "${model##*-}"
}

# A launch/resume command re-derives the tag every time (idempotent; a rotating
# claudeb may land on a different account between resumes).
tag=""
extra=()
# An agent making a call is running again, whatever SubagentStop marked on its tag before.
[ -z "$(tag_value stopped)" ] || extra+=("stopped=")
waiter_command=''
review_run=''
[ "$agent_type" != review-waiter ] || review_run=$(grab "${cmd_word}"'review-bench[[:space:]]+wait[[:space:]]+["'\'']?[0-9]{8}T[0-9]{6}Z-[0-9a-f]+(-[0-9]+)?' |
  grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9a-f]+(-[0-9]+)?$')
if [ -n "$review_run" ]; then
  tag=$(review_tag "$review_run")
  extra+=("review=$review_run")
  # review-bench records the waiter on the progress document; the agent id is the one the tag cache
  # is keyed on, so the parent can find the row that waits on its run.
  if ! printf '%s' "$command" | grep -qE -- '--waiter([[:space:]=]|$)'; then
    waiter_command=$(printf '%s' "$command" | REVIEW_RUN="$review_run" AGENT_ID="$agent_id" perl -0pe \
      's/(review-bench\s+wait\s+["\x27]?\Q$ENV{REVIEW_RUN}\E["\x27]?)/$1 --waiter $ENV{AGENT_ID}/')
  fi
elif printf '%s' "$launch" | grep -qE "${cmd_word}"'worker-run[[:space:]]+start([[:space:]]|$)'; then
  # No run id exists before the run: worker-run itself claims the tag file carrying the freshest
  # `start=` mark in this session and swaps it for `run=<id>`.
  extra+=("start=$(date +%s)")
elif printf '%s' "$launch" | grep -qE "${cmd_word}"'worker-run[[:space:]]+(wait|report)[[:space:]]'; then
  # worker-run resolves the account itself, so the tag comes from the run dir it wrote. A run id
  # behind a shell variable (`worker-run wait "$RUN_ID"`) is no text the hook sees: the run is then
  # the one this agent's tag file already names, else the one whose state names this agent.
  run_id=$(grab 'worker-run[[:space:]]+(wait|report)[[:space:]]+["'\'']?[a-z0-9][a-z0-9-]*' |
    grep -oE '[a-z0-9][a-z0-9-]*$')
  # A report only prints a record, so it never moves the row off the run this agent already owns.
  printf '%s' "$launch" | grep -qE "${cmd_word}"'worker-run[[:space:]]+wait[[:space:]]' ||
    [ -z "$(tag_value run)" ] || run_id=$(tag_value run)
  [ -n "$run_id" ] || run_id=$(tag_value run)
  if [ -z "$run_id" ]; then
    run_state=$(ls -t "$runs_root"/*/state.json 2>/dev/null | head -n 50 |
      while IFS= read -r state; do
        jq -e --arg agent "$agent_id" '.agent_task_id == $agent' "$state" >/dev/null 2>&1 && { printf '%s' "$state"; break; }
      done)
    [ -z "$run_state" ] || run_id=$(basename "$(dirname "$run_state")")
  fi
  run_tag_file="$runs_root/$run_id/tag"
  if [ -n "$run_id" ] && [ -f "$run_tag_file" ]; then
    IFS= read -r tag < "$run_tag_file" || tag=""
  fi
  [ -z "$run_id" ] || [ ! -d "$runs_root/$run_id" ] || extra+=("run=$run_id")
elif printf '%s' "$launch" | grep -qE "${cmd_word}"'codex[[:space:]]+exec([[:space:]]|$)'; then
  acct=$(grab '\.codex-profiles/[A-Za-z0-9_.-]+' | sed 's|.*/||')
  [ -n "$acct" ] || acct=main
  effort=$(grab 'model_reasoning_effort=[a-z]+' | cut -d= -f2)
  [ -n "$effort" ] || effort=$(worker_conf codex_effort)
  [ -n "$effort" ] || effort=$(worker_model_default_effort codex "$(worker_model_default_model codex)")
  codex_model=$(codex_model_short_label)
  tag="$acct · $codex_model · $effort"
elif printf '%s' "$launch" | grep -qE "${cmd_word}"'claudeb["'\'']?([[:space:]]|$)' &&
     printf '%s' "$launch" | grep -qE -- '--model|--print|-p '; then
  # An account never starts with a hyphen; without that the flag of a malformed
  # `claudeb profile --resume …` becomes the tagged account.
  acct=$(grab "${cmd_word}"'claudeb["'\'' ]+profile["'\'' ]+[A-Za-z0-9][A-Za-z0-9_.-]*' |
    grep -oE '[A-Za-z0-9][A-Za-z0-9_.-]*$')
  [ -n "$acct" ] || acct=$(worker_model_pin_first claudeb 2>/dev/null || true)
  [ -n "$acct" ] || acct=$(account_fallback claudeb)
  model=$(grab '\-\-model[= ]+[A-Za-z0-9][A-Za-z0-9_.-]*' | grep -oE '[A-Za-z0-9][A-Za-z0-9_.-]*$')
  [ -n "$model" ] || model=$(worker_conf claudeb_model)
  [ -n "$model" ] || model=opus
  effort=$(grab '\-\-effort[= ]+[a-z]+' | grep -oE '[a-z]+$')
  [ -n "$effort" ] || effort=$(worker_conf claudeb_effort)
  [ -n "$effort" ] || effort=$(worker_model_default_effort claudeb "$model")
  [ -n "$effort" ] || effort=$(worker_model_default_effort claudeb "$(worker_model_default_model claudeb)")
  tag="$acct · $model · $effort"
elif { printf '%s' "$launch" | grep -qE "${cmd_word}"'agy([[:space:]]|$)' ||
       is_geminib_launch; } &&
     printf '%s' "$launch" | grep -q -- '--print'; then
  acct=$(grab "${cmd_word}"'geminib[[:space:]]+(profile|p|run)[[:space:]]+["'\'' ]*[a-z0-9][a-z0-9-]*' |
    grep -oE '[a-z0-9][a-z0-9-]*' | tail -n1)
  [ -n "$acct" ] || acct=$(grab "${cmd_word}"'geminib[[:space:]]+["'\'' ]*[a-z0-9][a-z0-9-]*["'\'' ]*[[:space:]]+exec' |
    grep -oE '[a-z0-9][a-z0-9-]*' | tail -n2 | head -n1)
  [ -n "$acct" ] || acct=main
  agy_model=$(grab '\-\-model(=|[[:space:]])gemini-[0-9.]+-(pro|flash)(-(high|medium|low))?')
  model=$(worker_model_gemini_family "$(printf '%s' "$agy_model" | sed -E 's/^--model(=|[[:space:]])//')" | cut -f2)
  effort=$(grab '\-\-effort(=|[[:space:]])(high|medium|low)' | grep -oE '(high|medium|low)$')
  # Versioned Gemini ids carry effort; the pro-high label falls back to the configured high tier.
  [ -n "$effort" ] || effort=$(printf '%s' "$agy_model" | grep -oE '(high|medium|low)$')
  [ -n "$model" ] || model=$(worker_conf gemini_model)
  [ "$model" != flash ] || model=$(worker_model_gemini_family flash | cut -f2)
  [ -n "$model" ] || model=$(worker_model_default_model gemini)
  [ -n "$effort" ] || effort=$(worker_conf gemini_effort)
  [ -n "$effort" ] || effort=$(worker_model_default_effort gemini "$(worker_model_default_model gemini)")
  tag="$acct · $model · $effort"
elif is_grokb_launch &&
     printf '%s' "$launch" | grep -qE -- '--prompt-file|-p |--prompt-json'; then
  acct=$(grab "${cmd_word}"'grokb[[:space:]]+(profile|p|run)[[:space:]]+["'\'' ]*[a-z0-9][a-z0-9-]*' |
    grep -oE '[a-z0-9][a-z0-9-]*' | tail -n1)
  [ -n "$acct" ] || acct=$(grab "${cmd_word}"'grokb[[:space:]]+["'\'' ]*[a-z0-9][a-z0-9-]*["'\'' ]*[[:space:]]+exec' |
    grep -oE '[a-z0-9][a-z0-9-]*' | tail -n2 | head -n1)
  [ -n "$acct" ] || acct=$(account_fallback grok)
  model=$(grab '\-m[= ]+[A-Za-z0-9][A-Za-z0-9_.-]*' | grep -oE '[A-Za-z0-9][A-Za-z0-9_.-]*$')
  [ -n "$model" ] || model=$(worker_conf grok_model)
  [ -n "$model" ] || model=auto
  model=$(worker_model_grok_label "$model")
  effort=$(grab '\-\-reasoning-effort[= ]+[a-z]+' | grep -oE '[a-z]+$')
  [ -n "$effort" ] || effort=$(worker_conf grok_effort)
  [ -n "$effort" ] || effort=$(worker_model_default_effort grok "$(worker_model_default_model grok)")
  tag="$acct · $model · $effort"
elif printf '%s' "$launch" | grep -qE "${cmd_word}"'light-research([[:space:]]|$)'; then
  # Model and effort are the light_research row's, the launcher's own source; `--account` is the only
  # account this text can vouch for, since without it the launcher asks worker-pick at run time.
  acct=$(grab '\-\-account[= ]+["'\'' ]*[a-z0-9][a-z0-9-]*' | grep -oE '[a-z0-9][a-z0-9-]*$')
  model=$(worker_light_model research 2>/dev/null) || model=''
  [ -z "$acct" ] || [ -z "$model" ] || tag="$acct · $model · $(worker_light_effort research)"
  # Its runs are worker-run's: `start=` lets worker-run claim this row and write the account the run
  # actually landed on, and an attach names the run it waits on.
  attach_run=$(grab '\-\-attach[= ]+["'\'' ]*[a-z0-9][a-z0-9-]*' | grep -oE '[a-z0-9][a-z0-9-]*$')
  if [ -n "$attach_run" ]; then extra+=("run=$attach_run"); else extra+=("start=$(date +%s)"); fi
fi

umask 077
if [ -n "$tag" ]; then
  write_tag_file "$tag" ${extra[@]+"${extra[@]}"} || done_untagged
elif [ -n "$(tag_line)" ]; then
  tag=$(tag_line)
  if [ "${#extra[@]}" -gt 0 ]; then write_tag_file "" "${extra[@]}"; else touch "$tag_file" 2>/dev/null; fi
else
  # Pre-launch calls (brief saving etc.): claim the oldest seed worker-spawn-hook left for this
  # agent type — one seed per spawn, moved away so a sibling spawn claims its own; the legacy
  # per-type seed is only read. The real launch re-derives over it.
  mkdir -p "$cache_dir" 2>/dev/null || done_untagged
  tag_lock || done_untagged
  seed=$(pick_seed)
  seed_lines=''
  [ -z "$seed" ] || seed_lines=$(cat "$seed" 2>/dev/null)
  [ -n "$seed_lines" ] || { seed=''; [ -f "$cache_dir/pending-$agent_type" ] && seed_lines=$(cat "$cache_dir/pending-$agent_type"); }
  tag=${seed_lines%%$'\n'*}
  seed_extra=()
  while IFS= read -r kv; do
    case "$kv" in ''|spawn=*) ;; *) seed_extra+=("$kv") ;; esac
  done < <(printf '%s\n' "$seed_lines" | tail -n +2)
  written=1
  [ -z "$tag" ] || { write_tag_file_locked "$tag" ${seed_extra[@]+"${seed_extra[@]}"} ${extra[@]+"${extra[@]}"} && written=0; }
  [ "$written" != 0 ] || [ -z "$seed" ] || rm -f "$seed" 2>/dev/null
  rmdir "$cache_dir/.claim.lock" 2>/dev/null
  [ "$written" = 0 ] || done_untagged
fi

prune() {
  marker="$cache_root/.tag-prune"
  now=$(date +%s 2>/dev/null)
  marker_mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || printf '0')
  if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$marker_mtime" =~ ^[0-9]+$ ]] && [ "$((now - marker_mtime))" -gt 3600 ]; then
    find "$cache_root" -type f ! -name '.tag-prune' -mtime +7 -delete >/dev/null 2>&1
    find "$cache_root" -mindepth 1 -type d -empty ! \( -name .claim.lock -mmin -60 \) -delete >/dev/null 2>&1
    touch "$marker" 2>/dev/null
  fi
}

tag_prefix="$tag — "
if [ "${description:0:${#tag_prefix}}" = "$tag_prefix" ] && [ -z "$waiter_command" ]; then
  prune; done_untagged
fi
# Strip a stale tag-shaped prefix (account rotation mid-task, model echoing an
# old tag) so prefixes never stack.
description=$(printf '%s' "$description" | sed -E 's/^[A-Za-z0-9_.?-]+( [a-z]+)?( · [A-Za-z0-9_.-]+){1,3} — //')
if [ -n "$description" ]; then
  updated_description="$tag — $description"
else
  updated_description=$tag
fi
prune
# Worker sessions already bypass permissions; allow avoids a redundant prompt. light-research does
# NOT: it is a native in-session agent, so an `allow` here would grant a call nobody granted it —
# the tag is a rewrite and never a permission.
emit "$updated_description" "${waiter_command:-$command}"
exit; }
