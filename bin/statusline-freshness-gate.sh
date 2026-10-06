#!/usr/bin/env bash
# Always exits 0 — a nonzero exit here would block the triggering tool call.
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

input=$(cat 2>/dev/null) || exit 0

{ IFS= read -r path; IFS= read -r sid; IFS= read -r agent; } < <(printf '%s' "$input" | jq -r '
  def value: if . == null then "" else tostring end;
  (.hook_event_name | value) as $event
  | (if .tool_name == "NotebookEdit" then (.tool_input.notebook_path | value)
     else (.tool_input.file_path | value) end) as $file
  | (if $event == "PostToolUse" then $file else "" end), (.session_id | value), (.agent_id | value)
' 2>/dev/null) || exit 0

[ -n "$path" ] || exit 0

base=$(basename -- "$path")
case "$base" in
  statusline-contract.md) exit 0 ;;
  statusline*) ;;
  *) exit 0 ;;
esac

root=$(readlink -f "$0" 2>/dev/null) || exit 0
root=${root%/bin/*}
real=$(readlink -f "$path" 2>/dev/null) || real=$path
case "$real" in "$root"/*) ;; *) exit 0 ;; esac

# A subagent shares its parent's session id and never saw the parent's note.
key=$sid${agent:+.$agent}
case "$sid:$agent" in
  :*|*[!A-Za-z0-9_:-]*) ;;
  *)
    marks="$HOME/.cache/statusline-freshness-gate"
    [ -e "$marks/$key" ] && exit 0
    mkdir -p "$marks" 2>/dev/null && : > "$marks/$key" 2>/dev/null
    find "$marks" -type f -mtime +7 -delete 2>/dev/null
    ;;
esac

msg='Statusline freshness contract: every segment must declare source of truth, update trigger, staleness/dim policy, and removal condition. Adding a segment? Run the mandatory checklist in docs/statusline-contract.md first: enumerate EVERY event that can change the value (/rename, /branch, /clear, /compact, /model, account switch, cd/worktree, other sessions mutating shared state, time), name the update mechanism for each, and prove it with a test — an undetectable event means the segment dims/hides there or does not ship. Update docs/statusline-contract.md and tests/test_statusline_hooks.sh in llm-legs to match this change. Render-once-and-forget data is forbidden.'
jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}' 2>/dev/null
exit 0
exit; }
