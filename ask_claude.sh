#!/usr/bin/env bash
# Cross-vendor leg: Anthropic Claude, BY SUBSCRIPTION, headless. Callable from ANY environment
# (terminal, cron, another orchestrator) — does not require running inside Claude Code.
# Prompt as $1 or stdin. Prints the model's final text to stdout.
#
# ROLE: this leg serves BOTH judgment seats (decompose / judge / adjudicate / final synthesis)
# AND bounded web search/verification for the orchestrator. `claude -p` draws from a capped
# subscription credit pool, so keep fan-out through this leg bounded; the Gemini/GPT legs still
# do the heavy search lifting.
#
# WEB-TOOL TRAP: headless `claude -p` is non-interactive, so any permission-gated tool
# (WebSearch, WebFetch) is silently DENIED unless it is on --allowedTools — the model then
# answers "denied permission" and returns empty findings. That is WHY ALLOWED_TOOLS and the
# --allowedTools flag below exist. Disable with CLAUDE_ALLOW_WEB=0 (restores judgment-only).
#
# Model policy mirrors ask_codex.sh: no hardcoded version. Default is the `opus` alias (the CLI
# resolves it to the current Opus flagship); judgment seats need a strong tier. The served model
# is extracted from the CLI JSON (.modelUsage keys) and tier-classified — a weak tier (haiku/...)
# FAILS the call (exit 3) instead of silently judging. Overrides: CLAUDE_MODEL=<name|alias>,
# CLAUDE_ALLOW_WEAK=1.
#
# Billing guard: a stray ANTHROPIC_API_KEY silently flips `claude` to per-call API billing —
# always unset it (and ANTHROPIC_AUTH_TOKEN) so the OAuth subscription session is used.
# Read/write guard: mutating tools stay disallowed (this leg must never write to the machine);
# only the read-only web tools (WebSearch, WebFetch) are allow-listed.
#
# Every call logs {requested, served, weak_tier} to data/served-models.jsonl.
# Modes: --probe (tiny end-to-end call), --extract-served-model (parse CLI JSON from stdin).
set -uo pipefail

unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN 2>/dev/null || true

# Audit log lands in the CALLER's data/ dir by default (orchestrators invoke legs with
# cwd = project root). Override with LLM_LEGS_DATA_DIR for cron/launchd contexts.
DATA_DIR="${LLM_LEGS_DATA_DIR:-$PWD/data}"
mkdir -p "$DATA_DIR" 2>/dev/null || true
LOG="$DATA_DIR/served-models.jsonl"
MODEL="${CLAUDE_MODEL:-opus}"
WEAK_RE='(^|[-_.])(haiku|mini|nano|lite|flash|small|tiny)([-_.0-9]|$)'
# COST CEILING (owner decision 2026-06-11): Opus is the most expensive tier this leg may use.
# Mythos-class models (fable/mythos) cost far more per call — block them outright, no override.
BLOCKED_RE='(^|[-_.])(fable|mythos)([-_.0-9]|$)'
LIMIT_RE='hit your (session|weekly|Opus|usage) limit|usage_limit|rate.?limit|quota'
# NOTE: only CURRENT tool names — the CLI rejects unknown names in permission rules
# (MultiEdit no longer exists; listing it broke review calls on 2026-06-12).
DISALLOWED_TOOLS='Write,Edit,NotebookEdit,Bash,KillShell'
# Read-only web tools. Headless -p denies permission-gated tools unless allow-listed (see
# WEB-TOOL TRAP above); the orchestrator relies on this leg reaching the web. CLAUDE_ALLOW_WEB=0
# drops the allow flag and restores judgment-only behavior.
ALLOWED_TOOLS='WebSearch,WebFetch'

log() { # $1 requested, $2 served, $3 weak(0/1), $4 rc
  printf '{"ts":"%s","leg":"claude","requested":"%s","served":"%s","weak_tier":%s,"rc":%d,"account":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "${3:-0}" "${4:-0}" "$ACCOUNT" >> "$LOG" 2>/dev/null || true
}
is_weak() { printf '%s' "$1" | grep -qiE "$WEAK_RE"; }
extract_served_model() { # $1 (optional): requested model name/alias to prefer
  # CLI JSON: .modelUsage maps EVERY model that ran, including auxiliary/service models (a
  # haiku entry shows up next to opus on a plain probe) — same trap as Gemini's flash stats
  # poisoning. The response model is the key matching the requested alias; if none matches,
  # the dominant model by outputTokens. Fail closed when modelUsage is absent.
  jq -er --arg req "${1:-}" '
    (.modelUsage // {}) | to_entries
    | if length == 0 then empty else
        ([.[] | select($req != "" and (.key | ascii_downcase | contains($req | ascii_downcase)))]) as $match
        | (if ($match | length) > 0 then $match else . end)
        | sort_by(-(.value.outputTokens // 0))
        | .[0].key
      end
  ' 2>/dev/null
}

case "${1:-}" in
  --extract-served-model)
    extract_served_model "${2:-}"; exit $? ;;
esac

PROBE=0
if [ "${1:-}" = "--probe" ]; then PROBE=1; PROMPT="Reply with exactly: ok"; shift || true
else
  PROMPT="${1:-}"
  [ -z "$PROMPT" ] && PROMPT="$(cat)"
fi

ACCOUNT=main
CLAUDE_CMD=(claude)
CLAUDE_ROUTED=0
# Missing routing tools are a cron/launchd portability case; preserve the bare-CLI contract.
if command -v worker-pick >/dev/null 2>&1 && command -v claudeb >/dev/null 2>&1; then
  CLAUDE_CMD=(claudeb)
  CLAUDE_ROUTED=1
elif ! command -v worker-pick >/dev/null 2>&1; then
  echo "ask_claude.sh: worker-pick not installed; falling back to bare claude on the main account" >&2
else
  echo "ask_claude.sh: claudeb not installed; falling back to bare claude on the main account" >&2
fi

if [ "$CLAUDE_ROUTED" = 0 ] && ! command -v claude >/dev/null 2>&1; then
  echo "ask_claude.sh: claude CLI not installed — leg unavailable" >&2
  log "$MODEL" "MISSING_CLI" 0 1
  exit 1
fi

if printf '%s' "$MODEL" | grep -qiE "$BLOCKED_RE"; then
  echo "ask_claude.sh: REFUSING model '$MODEL' — above the Opus cost ceiling (no override)" >&2
  log "$MODEL" "BLOCKED_TIER" 0 4
  exit 4
fi

ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT
# Pass --allowedTools only when web is enabled. Built as an array so the empty case adds no
# flag at all; the ${ARR[@]+...} expansion is the set -u-safe form (bare "${ARR[@]}" on an
# empty array aborts under nounset in bash < 4.4, e.g. /bin/bash 3.2 in a bare cron PATH).
ALLOW_ARGS=()
if [ "${CLAUDE_ALLOW_WEB:-1}" != "0" ]; then ALLOW_ARGS=(--allowedTools "$ALLOWED_TOOLS"); fi
set +e
# --setting-sources project: skip user-level settings/CLAUDE.md so personal preferences
# (language, hooks) never leak into a judgment call. --strict-mcp-config: no MCP servers.
OUT="$(WORKER_PICK_CACHE_DIR=/dev/null "${CLAUDE_CMD[@]}" -p "$PROMPT" --output-format json --model "$MODEL" \
        --strict-mcp-config --setting-sources project \
        --disallowedTools "$DISALLOWED_TOOLS" \
        ${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"} </dev/null 2>"$ERRF")"
RC=$?
set -e

if [ "$CLAUDE_ROUTED" = 1 ] && [ "$RC" -eq 3 ]; then
  cat "$ERRF" >&2
  # Falling back here would spend quota the router deliberately reserved.
  echo "ask_claude.sh: no selectable Claude account — leg unavailable" >&2
  exit 6
fi
if [ "$CLAUDE_ROUTED" = 1 ] && [ "$RC" -eq 2 ] \
   && grep -qE '^claudeb: (cannot route without worker-pick|worker-pick failed \(exit 2\))' "$ERRF"; then
  echo "ask_claude.sh: worker-pick unusable (exit 2); falling back to bare claude on the main account" >&2
  : >"$ERRF"
  set +e
  OUT="$(claude -p "$PROMPT" --output-format json --model "$MODEL" \
          --strict-mcp-config --setting-sources project \
          --disallowedTools "$DISALLOWED_TOOLS" \
          ${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"} </dev/null 2>"$ERRF")"
  RC=$?
  set -e
  CLAUDE_ROUTED=0
fi
if [ "$CLAUDE_ROUTED" = 1 ]; then
  ACCOUNT="$(sed -n 's/^claudeb: worker-pick selected \([^[:space:]]*\)$/\1/p' "$ERRF" | tail -1)"
  [ -n "$ACCOUNT" ] || ACCOUNT=main
fi

served="$(printf '%s' "$OUT" | extract_served_model "$MODEL" || true)"
weak=0
if printf '%s' "${served:-}" | grep -qiE "$WEAK_RE"; then weak=1; fi
if [ "$RC" -ne 0 ] && { printf '%s' "$OUT"; cat "$ERRF"; } | grep -qiE "$LIMIT_RE"; then
  RC=5
  served="QUOTA_EXHAUSTED"
fi
log "$MODEL" "${served:-unknown}" "$weak" "$RC"

if [ "$PROBE" = "1" ]; then
  echo "claude served: ${served:-unknown} (weak_tier=$weak, rc=$RC)"
  [ $RC -ne 0 ] && { head -3 "$ERRF" >&2; exit $RC; }
  [ "$weak" = "1" ] && exit 3
  exit 0
fi

if [ $RC -ne 0 ]; then cat "$ERRF" >&2; exit $RC; fi
if printf '%s' "${served:-}" | grep -qiE "$BLOCKED_RE"; then
  echo "ask_claude.sh: REFUSING served model '$served' — above the Opus cost ceiling (no override)" >&2
  log "$MODEL" "$served" 0 4
  exit 4
fi
if [ -z "$served" ]; then
  echo "ask_claude.sh: response has no modelUsage served model — rejecting (no audit trail)" >&2
  exit 3
fi
if [ "$weak" = "1" ] && [ "${CLAUDE_ALLOW_WEAK:-0}" != "1" ]; then
  echo "ask_claude.sh: REFUSING weak-tier model '${served}' in a judgment seat (set CLAUDE_ALLOW_WEAK=1 to override)" >&2
  exit 3
fi
if printf '%s' "$OUT" | jq -e '.is_error == true' >/dev/null 2>&1; then
  printf '%s' "$OUT" | jq -r '.result // empty' >&2
  echo "ask_claude.sh: CLI reported is_error=true" >&2
  exit 1
fi
printf '%s' "$OUT" | jq -r '.result // empty'
