#!/usr/bin/env bash
# PreToolUse(Agent) for codex-/claudeb-worker spawns: rewrite the call's
# description to the canonical `<account> · [<model> · ]<effort>: <title>`
# form deterministically — account from the pin/daemon/codexb, model+effort
# from the brief's MODEL:/EFFORT: lines with worker-model defaults — instead
# of trusting the orchestrating model to compose it. Fail-open: on any doubt
# leave the call untouched.
set -u

input=$(cat) || exit 0

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

[ "$(field '.hook_event_name')" = PreToolUse ] || exit 0
subagent=$(field '.tool_input.subagent_type')
case "$subagent" in
  codex-worker|claudeb-worker) ;;
  *) exit 0 ;;
esac

description=$(field '.tool_input.description')
prompt=$(field '.tool_input.prompt')

worker_conf() { sed -n "s/^$1=//p" "$HOME/.claude/worker-model" 2>/dev/null | head -n1; }
brief_line() { printf '%s' "$prompt" | grep -m1 -oE "^$1:[[:space:]]*[A-Za-z0-9_.-]+" | sed -E "s/^$1:[[:space:]]*//"; }

# Derive codex model short label: from ~/.codex/config.toml model id last dash-segment, fallback 'sol'.
codex_model_short_label() {
  local toml="${1:-$HOME/.codex/config.toml}" label=""
  [ -r "$toml" ] && label=$(grep -m1 '^model[[:space:]]*=' "$toml" 2>/dev/null \
    | sed 's/.*"\([^"]*\)".*/\1/; s/.*-//')
  [[ "$label" =~ ^[A-Za-z0-9]+$ ]] || label=sol
  printf '%s' "$label"
}

if [ "$subagent" = claudeb-worker ]; then
  acct=$(worker_conf claudeb_profile)
  [ -n "$acct" ] || acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(curl -s --max-time 1 127.0.0.1:45789/claudebd/status 2>/dev/null | jq -r '.current // empty' 2>/dev/null)
  [ -n "$acct" ] || acct='?'
  model=$(brief_line MODEL)
  [ -n "$model" ] || model=$(worker_conf claudeb_model)
  [ -n "$model" ] || model=opus
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf claudeb_effort)
  [ -n "$effort" ] || effort=high
  prefix="$acct · $model · $effort"
else
  acct=$(worker_conf codex_profile)
  [ -n "$acct" ] || acct=$("$HOME/.local/bin/codexb" pick 2>/dev/null | tail -n1 | tr -cd 'A-Za-z0-9_.-')
  [ -n "$acct" ] || acct=main
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf codex_effort)
  [ -n "$effort" ] || effort=medium
  codex_model=$(codex_model_short_label)
  prefix="$acct · $codex_model · $effort"
fi

title=$(printf '%s' "$description" | sed -E 's/^[A-Za-z0-9_.?-]+( · [A-Za-z0-9_.-]+){1,3}(: | — )//')
[ -n "$title" ] || title=task

session_id=$(field '.session_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$session_id" ] || session_id=_
pending_dir="$HOME/.cache/claude-worker-tags/$session_id"
if mkdir -p "$pending_dir" 2>/dev/null; then
  umask 077
  tmp_pending="$pending_dir/pending-$subagent.tmp.$$"
  printf '%s\n' "$prefix" > "$tmp_pending" 2>/dev/null && mv -f "$tmp_pending" "$pending_dir/pending-$subagent" 2>/dev/null
  rm -f "$tmp_pending" 2>/dev/null
fi

updated="$prefix: $title"
[ "$updated" = "$description" ] && exit 0

printf '%s' "$input" | jq -c --arg description "$updated" '
  {hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input | .description = $description)
  }}
' 2>/dev/null
exit 0
