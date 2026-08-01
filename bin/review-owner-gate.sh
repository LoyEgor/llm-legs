#!/usr/bin/env bash
# Tier T3 and any tier's --max are Egor's to start. Two modes, and deliberately no cleverness
# between them: `prompt` (UserPromptSubmit) touches a marker when his message names a panel, and
# `bash` (PreToolUse) denies a launch of one while no fresh marker sits there. A marker only
# UNBLOCKS — `review-bench suggest` never proposes these panels either way — so a stray mention
# costs nothing and none of the machinery a one-shot permission would need has to exist.
# Fail-open on any error: a broken gate must never block ordinary reviews.
set -u

MODE="${1:-}"
GRANT_TTL_MIN=30

grant_dir() {
  local state="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}"
  printf '%s/review-grants' "$state"
}

fresh() { [ -n "$(find "$(grant_dir)/$1" -mmin "-$GRANT_TTL_MIN" 2>/dev/null)" ]; }

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat) || exit 0

case "$MODE" in
  prompt)
    printf '%s' "$input" | jq -e '.hook_event_name == "UserPromptSubmit"' >/dev/null 2>&1 || exit 0
    prompt=$(printf '%s' "$input" | jq -r '.prompt // empty') || exit 0
    named=()
    # The boundary is whitespace or punctuation rather than [^A-Za-z0-9], which counts every
    # Cyrillic letter as a boundary and would read the tail of a Russian word as «т3».
    grep -Eiq '(^|[[:space:]«"'\''(,])(t3|т3)([[:space:]»"'\'').,:;!?]|$)|--tier[= ]+t3' <<<"$prompt" && named+=(t3)
    grep -Eiq -- '(^|[[:space:]])--max([[:space:]]|$)|max[[:space:]]+review|макс[а-яё]*[[:space:]]+(ревью|review|прогон)|полн[а-яё]+[[:space:]]+ревью|ревью[[:space:]]+на[[:space:]]+макс' <<<"$prompt" && named+=(max)
    [ "${#named[@]}" -gt 0 ] || exit 0
    mkdir -p "$(grant_dir)" 2>/dev/null || exit 0
    touched=()
    for panel in "${named[@]}"; do
      touch "$(grant_dir)/$panel" 2>/dev/null && touched+=("$panel")
    done
    # Announcing a panel this hook failed to unblock would send the reader into a denial.
    [ "${#touched[@]}" -gt 0 ] || exit 0
    named=("${touched[@]}")
    jq -cn --arg c "Egor named an owner-only review panel (${named[*]}): it is unblocked for the next $GRANT_TTL_MIN minutes. Run it only if he actually asked for it — \`review-bench suggest\` prints it as an \`owner-only\` line and never as its \`command:\`." \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
    exit 0
    ;;
  bash)
    printf '%s' "$input" | jq -e '.hook_event_name == "PreToolUse" and .tool_name == "Bash"' \
      >/dev/null 2>&1 || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') || exit 0
    # The launch itself, not the whole line: a `grep` that quotes one of these flags is neither a
    # launch to deny nor a reason to deny the ordinary review next to it.
    launch=$(grep -Eo '(^|[;&|(`])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(env[[:space:]]+)?[^[:space:]]*review-bench[[:space:]]+(review|run)([[:space:]].*)?$' \
      <<<"$cmd" | head -n1)
    [ -n "$launch" ] || exit 0
    blocked=""
    if grep -Eiq -- '--tier[=[:space:]]+"?'\''?t3([^A-Za-z0-9]|$)' <<<"$launch" && ! fresh t3; then
      blocked="T3"
    fi
    # Anchored on both sides so --max-tokens is not read as --max.
    if grep -Eq -- '(^|[[:space:]])--max([[:space:]]|$)' <<<"$launch" && ! fresh max; then
      blocked="${blocked:+$blocked and }--max"
    fi
    [ -n "$blocked" ] || exit 0
    jq -cn --arg r "Blocked: $blocked is Egor's to start, and he has not named it. This gate is the rule, not a suggestion — do not rebuild the command another way. Run the tier \`review-bench suggest\` prints as its \`command:\` line; if this change looks like it deserves more, ask Egor in one line and wait." \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null
    exit 0
    ;;
esac
exit 0
