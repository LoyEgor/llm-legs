#!/usr/bin/env bash
# PreToolUse(Bash) inside relay-worker agents. Derives the
# account·model·effort tag from the ACTUAL launch command text (claudeb/codex
# CLI arguments), never from the model's description discipline,
# then prefixes the tag onto every Bash description so the UI activity line
# always names who is spending quota. Tag files are session-scoped so the
# statusline can surface the live tag. Fail-open everywhere.
set -u

input=$(cat) || exit 0

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

[ "$(field '.hook_event_name')" = PreToolUse ] || exit 0
agent_type=$(field '.agent_type')
case "$agent_type" in
  codex-worker|claudeb-worker|gemini-worker) ;;
  *) exit 0 ;;
esac
agent_id=$(field '.agent_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$agent_id" ] || exit 0
session_id=$(field '.session_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$session_id" ] || session_id=_

command=$(field '.tool_input.command')
description=$(field '.tool_input.description')
# Derivation reads the command only up to the first heredoc operator: a brief
# written through `<<EOF` quotes launch-shaped lines that launch nothing, and a
# line anchor cannot tell them apart from a real command.
launch=${command%%<<*}

cache_root="$HOME/.cache/claude-worker-tags"
cache_dir="$cache_root/$session_id"
tag_file="$cache_dir/$agent_id"

worker_conf() { sed -n "s/^$1=//p" "$HOME/.claude/worker-model" 2>/dev/null | head -n1; }
grab() { printf '%s' "$launch" | grep -oE -e "$1" 2>/dev/null | head -n1; }

# A launcher name counts only where a command word can stand: line start or
# after a shell separator, optionally path-prefixed and behind env assignments
# and wrapper words (the documented launches run under CODEX_HOME=… and
# timeout/nohup). Unanchored, prose naming "claudeb profile X" tags X.
cmd_word='(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(nohup|env|nice|timeout)([[:space:]]+(-[^[:space:]]+|[0-9]+[smhd]?))*[[:space:]]+)*([^[:space:];&|()]*/)?'

is_geminib_launch() {
  printf '%s' "$launch" | grep -qE \
    "${cmd_word}"'geminib[[:space:]]+((profile|p|run)[[:space:]]+["'\'']*[a-z0-9][a-z0-9-]*|["'\'']*[a-z0-9][a-z0-9-]*["'\'']*[[:space:]]+exec)'
}

# Derive codex model short label from ~/.codex/config.toml; fallback "sol" defined here.
codex_model_short_label() {
  local toml="${1:-$HOME/.codex/config.toml}" label=""
  [ -r "$toml" ] && label=$(grep -m1 '^model[[:space:]]*=' "$toml" 2>/dev/null \
    | sed 's/.*"\([^"]*\)".*/\1/; s/.*-//')
  [[ "$label" =~ ^[A-Za-z0-9]+$ ]] || label=sol
  printf '%s' "$label"
}

# A launch/resume command re-derives the tag every time (idempotent; a rotating
# claudeb may land on a different account between resumes).
tag=""
if printf '%s' "$launch" | grep -qE "${cmd_word}"'worker-run[[:space:]]+(wait|report)[[:space:]]'; then
  # worker-run resolves the account itself; the launch text carries only the run
  # id, so the tag comes from the run dir it wrote. `worker-run start` has no run
  # id yet and falls through to the pending seed below. A run id passed as a
  # shell variable (`worker-run wait "$RUN_ID"`) is unresolvable here — the hook
  # sees command text, not expansions — so the tag stays empty and the fallback
  # tail (previous tag file, then pending seed) must hold; a test pins that.
  run_id=$(grab 'worker-run[[:space:]]+(wait|report)[[:space:]]+["'\'']?[a-z0-9][a-z0-9-]*' |
    grep -oE '[a-z0-9][a-z0-9-]*$')
  run_tag_file="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}/$run_id/tag"
  if [ -n "$run_id" ] && [ -f "$run_tag_file" ]; then
    IFS= read -r tag < "$run_tag_file" || tag=""
  fi
elif printf '%s' "$launch" | grep -qE "${cmd_word}"'codex[[:space:]]+exec([[:space:]]|$)'; then
  acct=$(grab '\.codex-profiles/[A-Za-z0-9_.-]+' | sed 's|.*/||')
  [ -n "$acct" ] || acct=main
  effort=$(grab 'model_reasoning_effort=[a-z]+' | cut -d= -f2)
  [ -n "$effort" ] || effort=$(worker_conf codex_effort)
  [ -n "$effort" ] || effort=medium
  codex_model=$(codex_model_short_label)
  tag="$acct · $codex_model · $effort"
elif printf '%s' "$launch" | grep -qE "${cmd_word}"'claudeb["'\'']?([[:space:]]|$)' &&
     printf '%s' "$launch" | grep -qE -- '--model|--print|-p '; then
  # An account never starts with a hyphen; without that the flag of a malformed
  # `claudeb profile --resume …` becomes the tagged account.
  acct=$(grab "${cmd_word}"'claudeb["'\'' ]+profile["'\'' ]+[A-Za-z0-9][A-Za-z0-9_.-]*' |
    grep -oE '[A-Za-z0-9][A-Za-z0-9_.-]*$')
  [ -n "$acct" ] || acct=$(worker_conf claudeb_profile)
  model=$(grab '\-\-model[= ]+[A-Za-z0-9][A-Za-z0-9_.-]*' | grep -oE '[A-Za-z0-9][A-Za-z0-9_.-]*$')
  [ -n "$model" ] || model=$(worker_conf claudeb_model)
  [ -n "$model" ] || model=opus
  effort=$(grab '\-\-effort[= ]+[a-z]+' | grep -oE '[a-z]+$')
  [ -n "$effort" ] || effort=$(worker_conf claudeb_effort)
  [ -n "$effort" ] || effort=high
  if [ -n "$acct" ]; then tag="$acct · $model · $effort"; else tag="$model · $effort"; fi
elif { printf '%s' "$launch" | grep -qE "${cmd_word}"'agy([[:space:]]|$)' ||
       is_geminib_launch; } &&
     printf '%s' "$launch" | grep -q -- '--print'; then
  acct=$(grab "${cmd_word}"'geminib[[:space:]]+(profile|p|run)[[:space:]]+["'\'' ]*[a-z0-9][a-z0-9-]*' |
    grep -oE '[a-z0-9][a-z0-9-]*' | tail -n1)
  [ -n "$acct" ] || acct=$(grab "${cmd_word}"'geminib[[:space:]]+["'\'' ]*[a-z0-9][a-z0-9-]*["'\'' ]*[[:space:]]+exec' |
    grep -oE '[a-z0-9][a-z0-9-]*' | tail -n2 | head -n1)
  [ -n "$acct" ] || acct=main
  agy_model=$(grab '\-\-model(=|[[:space:]])gemini-[0-9.]+-(pro|flash)(-(high|medium|low))?')
  case "$agy_model" in
    *gemini-3.6-flash*) model=flash36 ;;
    *gemini-3.5-flash*) model=flash35 ;;
    *-pro*) model=pro ;;
    *) model='' ;;
  esac
  effort=$(grab '\-\-effort(=|[[:space:]])(high|medium|low)' | grep -oE '(high|medium|low)$')
  # Versioned Gemini ids carry effort; the pro-high label falls back to the configured high tier.
  [ -n "$effort" ] || effort=$(printf '%s' "$agy_model" | grep -oE '(high|medium|low)$')
  [ -n "$model" ] || model=$(worker_conf gemini_model)
  [ "$model" = flash ] && model=flash36
  [ -n "$model" ] || model=pro
  [ -n "$effort" ] || effort=$(worker_conf gemini_effort)
  [ -n "$effort" ] || effort=high
  tag="$acct · $model · $effort"
fi

if [ -n "$tag" ]; then
  mkdir -p "$cache_dir" || exit 0
  umask 077
  tmp_file="$tag_file.tmp.$$"
  trap 'rm -f "$tmp_file" 2>/dev/null' EXIT
  printf '%s\n' "$tag" > "$tmp_file" && mv -f "$tmp_file" "$tag_file"
elif [ -f "$tag_file" ]; then
  IFS= read -r tag < "$tag_file" || exit 0
  [ -n "$tag" ] || exit 0
  touch "$tag_file" 2>/dev/null
else
  # Pre-launch calls (brief saving etc.): adopt the tag worker-spawn-hook
  # pre-seeded for this agent type; the real launch re-derives over it.
  pending="$cache_dir/pending-$agent_type"
  [ -f "$pending" ] || exit 0
  IFS= read -r tag < "$pending" || exit 0
  [ -n "$tag" ] || exit 0
  umask 077
  tmp_file="$tag_file.tmp.$$"
  trap 'rm -f "$tmp_file" 2>/dev/null' EXIT
  printf '%s\n' "$tag" > "$tmp_file" && mv -f "$tmp_file" "$tag_file"
fi

prune() {
  marker="$cache_root/.tag-prune"
  now=$(date +%s 2>/dev/null)
  marker_mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || printf '0')
  if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$marker_mtime" =~ ^[0-9]+$ ]] && [ "$((now - marker_mtime))" -gt 3600 ]; then
    find "$cache_root" -type f ! -name '.tag-prune' -mtime +7 -delete >/dev/null 2>&1
    find "$cache_root" -mindepth 1 -type d -empty -delete >/dev/null 2>&1
    touch "$marker" 2>/dev/null
  fi
}

tag_prefix="$tag — "
if [ "${description:0:${#tag_prefix}}" = "$tag_prefix" ]; then
  prune; exit 0
fi
# Strip a stale tag-shaped prefix (account rotation mid-task, model echoing an
# old tag) so prefixes never stack.
description=$(printf '%s' "$description" | sed -E 's/^[A-Za-z0-9_.?-]+( · [A-Za-z0-9_.-]+){1,3} — //')
if [ -n "$description" ]; then
  updated_description="$tag — $description"
else
  updated_description=$tag
fi
# Worker sessions already bypass permissions; allow avoids a redundant prompt.
printf '%s' "$input" | jq -c --arg description "$updated_description" '
  {hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input | .description = $description)
  }}
' 2>/dev/null

prune
exit 0
