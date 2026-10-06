#!/bin/bash
# PostToolUse of a claudeb worker run, wired by worker-run's own `--settings`: hands the session the
# `worker-run say` messages of its run (share/worker-inbox.sh), each exactly once, as
# additionalContext. Runs after every tool call, so the path to the first exit is builtins only.
record=${WORKER_RUN_RECORD:-}
[ -n "$record" ] && [ -e "$record/inbox.new" ] || exit 0
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh

IFS= read -r -d '' input || :
# A subagent's tool call: the message is for the session the run launched, which takes it next.
case $input in *'"agent_id"'*) exit 0 ;; esac

self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) || self=${BASH_SOURCE[0]}
. "${self%/*}/../share/worker-inbox.sh" 2>/dev/null || exit 0

lock="$record/.claim.lock" tries=0
until mkdir "$lock" 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -ge 20 ]; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null && continue
    exit 0
  fi
  sleep 0.1
done
trap 'command -v hook_time_end >/dev/null && hook_time_end; rmdir "$lock" 2>/dev/null' EXIT

# Cleared before the read: a `say` landing after it raises the flag again for the next call.
rm -f "$record/inbox.new"
inbox_pending "$record" || exit 0
context=$(inbox_context "$INBOX_TAKEN") && [ -n "$context" ] || exit 0
jq -cn --arg context "$context" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}' || exit 0
inbox_record "$record" "$INBOX_END" hook
exit 0
