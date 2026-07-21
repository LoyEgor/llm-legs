#!/usr/bin/env bash
# Always exits 0 — a nonzero exit here would block the triggering tool call.
set -u

input=$(cat 2>/dev/null) || exit 0

path=$(printf '%s' "$input" | jq -r '
  def value: if . == null then "" else tostring end;
  (.hook_event_name | value) as $event
  | (if .tool_name == "NotebookEdit" then (.tool_input.notebook_path | value)
     else (.tool_input.file_path | value) end) as $file
  | if $event == "PostToolUse" then $file else "" end
' 2>/dev/null) || exit 0

[ -n "$path" ] || exit 0

base=$(basename -- "$path")
case "$base" in
  statusline*) ;;
  *) exit 0 ;;
esac

msg='Statusline freshness contract: every segment must declare source of truth, update trigger, staleness/dim policy, and removal condition. Adding a segment? Run the mandatory checklist in docs/statusline-contract.md first: enumerate EVERY event that can change the value (/rename, /branch, /clear, /compact, /model, account switch, cd/worktree, other sessions mutating shared state, time), name the update mechanism for each, and prove it with a test — an undetectable event means the segment dims/hides there or does not ship. Update docs/statusline-contract.md and tests/test_statusline_hooks.sh in llm-legs to match this change. Render-once-and-forget data is forbidden.'
jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}' 2>/dev/null
exit 0
