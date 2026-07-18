#!/usr/bin/env bash
# PreToolUse(Workflow): workflow fan-outs run on the SESSION's own account
# (never through claudeb rotation), so a big fleet can wall the very account
# that still has to finish the task — this happened live on alona 2026-07-18.
# Warn the model at 70% of the session account's usage, deny at 95%.
# Fail-open on any error.
set -u

LIMITS_FILE="${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}"
DENY_AT="${WORKFLOW_GATE_DENY_PCT:-95}"
WARN_AT="${WORKFLOW_GATE_WARN_PCT:-70}"

input=$(cat) || exit 0
printf '%s' "$input" | jq -e '.hook_event_name == "PreToolUse" and .tool_name == "Workflow"' >/dev/null 2>&1 || exit 0

own="${CLAUDE_LIMITS_ACCOUNT:-}"
if [ -z "$own" ] || [ "$own" = "-" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
    own=$(basename "$CLAUDE_CONFIG_DIR")
  else
    exit 0
  fi
fi
[ -r "$LIMITS_FILE" ] || exit 0

now=$(date +%s) || exit 0
# Pressure = max of the general 5h window and the fable bucket (workflow
# agents may inherit a Fable main loop), reset-aware.
pct=$(jq -r --arg own "$own" --argjson now "$now" '
  def epoch:
    if type == "number" then .
    elif type == "string" then
      (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})?$") // null
       | if . == null then null
         else (.d + "Z" | fromdateiso8601)
           - (if .tz == null or .tz == "Z" then 0
              else (.tz | capture("^(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")
                    | (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60))
              end)
         end)
    else null end;
  def eff(b): (b // {}) as $b | (($b.resets_at // null) | epoch) as $r |
    if (($b.used_pct // null) | type) != "number" then null
    elif $r != null and $r <= $now then 0
    else ($b.effective_pct // $b.used_pct) end;
  [.vendors.claude.accounts[]? | select(.account == $own)
   | [eff(.five_hour), eff(.fable)] | map(select(. != null)) | (if length == 0 then empty else max end)
  ] | first // empty
' "$LIMITS_FILE" 2>/dev/null) || exit 0
[ -n "$pct" ] || exit 0
pct_int=$(printf '%.0f' "$pct" 2>/dev/null) || exit 0

if [ "$pct_int" -ge "$DENY_AT" ] 2>/dev/null; then
  jq -cn --arg r "Session account $own is at ${pct}% — a workflow fan-out would burn this same account and wall the session before its own task finishes. Do not run the workflow now: shrink the work to inline/single agents, route implementation through claudeb-/codex-workers (run worker-pick), or ask Egor." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
fi

if [ "$pct_int" -ge "$WARN_AT" ] 2>/dev/null; then
  jq -cn --arg c "Heads-up: this workflow's agents will spend the SESSION account ($own), currently at ${pct}%. A large fleet can wall this session mid-task. Keep the fan-out small, run the workflow inside a claudeb-worker (bills a rotation account instead), or move implementation stages to workers (run worker-pick) — and mention the risk to Egor." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null
  exit 0
fi

exit 0
