#!/usr/bin/env bash
set -u

HOOK="${LIMITS_TRIAGE_NUDGE_HOOK:-$HOME/.claude/hooks/limits-triage-nudge.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$HOOK" ] || fail "limits triage nudge hook is not executable: $HOOK"

run_hook() {
  local session=$1 response=$2 tool=${3:-Bash}
  jq -cn --arg s "$session" --arg r "$response" --arg t "$tool" \
    '{hook_event_name:"PostToolUse",tool_name:$t,session_id:$s,tool_response:$r}' |
    LIMITS_TRIAGE_NUDGE_INTERVAL=900 bash "$HOOK"
}

session="limits-nudge-test-$$-match"
rm -f "/tmp/claude-limits-triage-nudge-${session}" "/tmp/claude-limits-triage-nudge-${session}.lock"
output=$(run_hook "$session" "Claude API: usage limit reached") || fail "matching fixture invocation failed"
jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and
  (.hookSpecificOutput.additionalContext | contains("Limit-shaped error detected") and
   contains("llm-limits --table --no-write") and
   contains("DIAGNOSTICS.md"))' <<<"$output" >/dev/null \
  || fail "matching fixture did not produce the expected nudge"

session_ci="limits-nudge-test-$$-case-insensitive"
rm -f "/tmp/claude-limits-triage-nudge-${session_ci}" "/tmp/claude-limits-triage-nudge-${session_ci}.lock"
output=$(run_hook "$session_ci" "ANTHROPIC API returned: API Error: 529 OVERLOADED") || fail "case-insensitive fixture invocation failed"
jq -e '.hookSpecificOutput.additionalContext | contains("Limit-shaped error detected")' <<<"$output" >/dev/null \
  || fail "case-insensitive match did not nudge"

session_429="limits-nudge-test-$$-plain-429"
rm -f "/tmp/claude-limits-triage-nudge-${session_429}" "/tmp/claude-limits-triage-nudge-${session_429}.lock"
output=$(run_hook "$session_429" "Claude API Error: 429 Too Many Requests") || fail "plain 429 fixture invocation failed"
jq -e '.hookSpecificOutput.additionalContext | contains("Limit-shaped error detected")' <<<"$output" >/dev/null \
  || fail "plain API Error 429 did not nudge"

session_no_ctx="limits-nudge-test-$$-no-context"
rm -f "/tmp/claude-limits-triage-nudge-${session_no_ctx}" "/tmp/claude-limits-triage-nudge-${session_no_ctx}.lock"
[ -z "$(run_hook "$session_no_ctx" "error: 503 service unavailable from some unrelated upstream")" ] \
  || fail "limit-shaped pattern without claudeb/anthropic/claude/fable context word fired"

session_no_pattern="limits-nudge-test-$$-no-pattern"
rm -f "/tmp/claude-limits-triage-nudge-${session_no_pattern}" "/tmp/claude-limits-triage-nudge-${session_no_pattern}.lock"
[ -z "$(run_hook "$session_no_pattern" "claudeb status: all accounts healthy")" ] \
  || fail "claudeb context without a limit-shaped pattern fired"

session_dedup="limits-nudge-test-$$-dedup"
rm -f "/tmp/claude-limits-triage-nudge-${session_dedup}" "/tmp/claude-limits-triage-nudge-${session_dedup}.lock"
first=$(run_hook "$session_dedup" "claudeb: usage limit hit, CLAUDEB_USAGE_LIMIT") || fail "first dedup fixture invocation failed"
jq -e '.hookSpecificOutput.additionalContext | contains("Limit-shaped error detected")' <<<"$first" >/dev/null \
  || fail "first dedup fixture did not nudge"
[ -z "$(run_hook "$session_dedup" "claudeb: usage limit hit, CLAUDEB_USAGE_LIMIT")" ] \
  || fail "second fire within the 15-minute dedup window was not suppressed"

session_tool="limits-nudge-test-$$-wrong-tool"
rm -f "/tmp/claude-limits-triage-nudge-${session_tool}" "/tmp/claude-limits-triage-nudge-${session_tool}.lock"
[ -z "$(run_hook "$session_tool" "claudeb: no available accounts" "Edit")" ] \
  || fail "non-Bash tool_name fired"

[ -z "$(printf 'not json at all' | LIMITS_TRIAGE_NUDGE_INTERVAL=900 bash "$HOOK")" ] \
  || fail "malformed stdin produced output"
printf 'not json at all' | LIMITS_TRIAGE_NUDGE_INTERVAL=900 bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] || fail "malformed stdin did not exit 0"

for s in match case-insensitive plain-429 no-context no-pattern dedup wrong-tool; do
  rm -f "/tmp/claude-limits-triage-nudge-limits-nudge-test-$$-${s}" \
        "/tmp/claude-limits-triage-nudge-limits-nudge-test-$$-${s}.lock"
done

echo "PASS: limits triage nudge pattern match including API Error 429, context requirement, case-insensitivity, dedup window, tool filter, and malformed-stdin safety"
