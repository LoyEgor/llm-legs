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

if [ "$subagent" = claudeb-worker ]; then
  # Same precedence as the claudeb-worker relay: Egor's pin > the brief's
  # ACCOUNT: routing line > the rotating daemon's current pick.
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
  # No `timeout` wrapper (GNU coreutils dependency): the hook's own settings.json
  # timeout bounds a hung codexb.
  [ -n "$acct" ] || acct=$("$HOME/.local/bin/codexb" pick 2>/dev/null | tail -n1 | tr -cd 'A-Za-z0-9_.-')
  [ -n "$acct" ] || acct=main
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf codex_effort)
  [ -n "$effort" ] || effort=medium
  prefix="$acct · $effort"
fi

# Title = the model's description minus any tag-shaped prefix it composed
# itself (correct or stale — this hook is now the single source of the tag).
title=$(printf '%s' "$description" | sed -E 's/^[A-Za-z0-9_.?-]+( · [A-Za-z0-9_.-]+){1,2}(: | — )//')
[ -n "$title" ] || title=task

# Pre-seed the tag for this spawn so the worker's very first Bash calls (brief
# saving, before any claudeb/codex launch command exists to parse) already
# carry it; worker-tag-hook claims it per agent_id and the real launch
# re-derives over it.
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

# "allow" is required for updatedInput to apply; a deny from the limit gates
# on the same matcher still wins (deny > allow), and the session runs
# bypassPermissions anyway.
printf '%s' "$input" | jq -c --arg description "$updated" '
  {hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input | .description = $description)
  }}
' 2>/dev/null
exit 0
