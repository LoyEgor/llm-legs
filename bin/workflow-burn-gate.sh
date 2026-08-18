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
own_source=env
if [ -z "$own" ] || [ "$own" = "-" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
    own=$(basename "$CLAUDE_CONFIG_DIR")
  else
    # A session on the default config dir names its account nowhere in the environment. claudeb's
    # state file records the LAST profile launched on this machine and nothing about this chat
    # (docs/statusline-contract.md refuses it as an account predictor for exactly that reason), so
    # it is read as a guess and marked as one.
    own=$(head -n 1 "${HOME:-}/.claude-profiles/.claudeb/.claudeb-state" 2>/dev/null |
      tr -d '[:space:]')
    own_source=claudeb-state
  fi
fi
# Which account it is was never the warning: that a fan-out bills the SESSION's own, and can wall
# the very account still owing the task, holds whether or not anything here can name it.
if [ -z "$own" ] || [ "$own" = "-" ]; then
  jq -cn --arg c "Heads-up: this workflow's agents will spend the SESSION's own account, never the claudeb rotation, and a large fleet can wall this session mid-task. Nothing here can name that account (no CLAUDE_LIMITS_ACCOUNT, default config dir, no claudeb state), so its pressure is unknown: read it with llm-limits --table --no-write before a big fan-out, keep the fleet small, or move implementation stages to workers (run worker-pick)." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null
  exit 0
fi
# A guessed account may never close a door and may never go quiet either: the reading belongs to
# whichever profile was launched here last, so denying a fan-out on it stops work over a number
# that was never this session's, and saying nothing about it reads as headroom nobody measured.
guessed_note() {
  jq -cn --arg c "Heads-up: this workflow's agents will spend the SESSION's own account, never the claudeb rotation, and a large fleet can wall this session mid-task. Nothing in this session's environment names that account: the closest reading is $1, which is only the last claudeb profile launched on this machine and may be another chat's. Confirm the real one with llm-limits --table --no-write before a big fan-out, keep the fleet small, or move implementation stages to workers (run worker-pick)." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null
}

if [ ! -r "$LIMITS_FILE" ]; then
  [ "$own_source" = claudeb-state ] && guessed_note "$own, whose usage this run could not read"
  exit 0
fi

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
if [ -z "$pct" ]; then
  [ "$own_source" = claudeb-state ] && guessed_note "$own, whose usage this run could not read"
  exit 0
fi
pct_int=$(printf '%.0f' "$pct" 2>/dev/null) || exit 0

if [ "$own_source" = claudeb-state ]; then
  guessed_note "$own at ${pct}%"
  exit 0
fi

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
