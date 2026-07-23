#!/usr/bin/env bash
# Cross-vendor leg: Google, via the Antigravity CLI (`agy`), SUBSCRIPTION-ONLY.
# Prompt as $1 or stdin; the model's text answer goes to stdout.
#
# agy is the only Google backend (Antigravity CLI; there is no fallback transport).
# agy >=1.0.7 headless facts (measured here):
#   - `--print` works on plain pipes (no PTY workaround needed), ~8-15 s per simple call;
#   - `--model "<label>"` pins the model per call (labels from `agy models`); the interactive
#     /model command merely writes the same label to ~/.gemini/antigravity-cli/settings.json;
#   - the served model is NOT reported back — the audit row records the PIN, unverified;
#   - quota state has no public command (the interactive quota panel uses an internal API);
#     worse, quota exhaustion in `--print` is SILENT (measured 2026-07-05: rc 0, EMPTY stdout
#     AND stderr for every model). The real error (RESOURCE_EXHAUSTED / code 429 / "Individual
#     quota reached ... Resets in <dur>") surfaces ONLY in agy's internal log, so we pass
#     `--log-file` and grep the log with a STRICT, error-shaped pattern (QUOTA_LOG_RE) — the broad
#     stderr QUOTA_RE would false-positive on the verbose debug log (timestamps like 04.429Z,
#     "rateLimiter" component names, ids). A quota hit is per-model, so we RECORD it and CONTINUE
#     to the next model in the chain; only after the whole chain is exhausted with a quota hit do
#     we exit 5 (with the reset hint) — the orchestrator then drops the leg for the day.
#
# Model chain (same Google family only — this leg must stay vendor-pure for cross-checking):
#   1) AGY_MODEL          (default "Gemini 3.1 Pro (High)")
#   2) AGY_MODEL_FALLBACK (default "Gemini 3.1 Pro (Low)" — same pro tier, lower reasoning)
# Flash/lite tiers are WEAK and never used in a judgment seat (GEMINI_ALLOW_WEAK=1 overrides).
#
# Every call logs {transport:"agy", requested, served(pinned, unverified)} to
# data/served-models.jsonl. Modes: --probe (no model call), --list-models.
set -uo pipefail

# Audit log lands in the CALLER's data/ dir by default (orchestrators invoke legs with
# cwd = project root). Override with LLM_LEGS_DATA_DIR for cron/launchd contexts.
DATA_DIR="${LLM_LEGS_DATA_DIR:-$PWD/data}"
mkdir -p "$DATA_DIR" 2>/dev/null || true
LOG="$DATA_DIR/served-models.jsonl"
AGY_MODEL="${AGY_MODEL:-Gemini 3.1 Pro (High)}"
AGY_MODEL_FALLBACK="${AGY_MODEL_FALLBACK:-Gemini 3.1 Pro (Low)}"
AGY_PRINT_TIMEOUT="${AGY_PRINT_TIMEOUT:-5m}"
WEAK_RE='(^|[^a-z])(flash|lite|nano|mini|small|tiny)([^a-z]|$)'
# Broad, for stderr only (legacy behavior): stderr is terse, so false positives are unlikely.
QUOTA_RE='quota|exhausted|capacity|rate.?limit|resource.?exhausted|429'
# Strict, for the verbose --log-file: anchored to the measured error shape
# ("RESOURCE_EXHAUSTED (code 429): Individual quota reached ...") so debug-log noise can't trip it.
QUOTA_LOG_RE='RESOURCE_EXHAUSTED|Individual quota reached|\(code 429\)'

log() { # $1 requested, $2 served, $3 weak(0/1)
  printf '{"ts":"%s","leg":"gemini","transport":"agy","requested":"%s","served":"%s","weak_tier":%s}\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "${3:-0}" >> "$LOG" 2>/dev/null || true
}
is_weak() { printf '%s' "$1" | grep -qiE "$WEAK_RE"; }

case "${1:-}" in
  --list-models)
    agy models; exit $? ;;
  --probe)
    if ! command -v agy >/dev/null 2>&1; then
      echo "gemini leg: agy CLI not installed — leg unavailable" >&2
      exit 1
    fi
    MODELS="$(agy models 2>/dev/null)"
    if ! printf '%s' "$MODELS" | grep -qF "$AGY_MODEL"; then
      echo "gemini leg: pinned model '$AGY_MODEL' not in 'agy models' list:" >&2
      printf '%s\n' "$MODELS" >&2
      exit 3
    fi
    echo "gemini leg alive: agy $(agy --version 2>/dev/null | head -1), model pinned: $AGY_MODEL (no probe call — quota economy)"
    exit 0 ;;
esac

PROMPT="${1:-}"
[ -z "$PROMPT" ] && PROMPT="$(cat)"

if ! command -v agy >/dev/null 2>&1; then
  echo "ask_gemini.sh: agy CLI not installed — leg unavailable" >&2
  log "$AGY_MODEL" "MISSING_CLI" 0
  exit 1
fi

ERRF="$(mktemp)"; LOGF="$(mktemp)"; trap 'rm -f "$ERRF" "$LOGF"' EXIT
quota_hit=0
reset_hint=""
for MODEL in "$AGY_MODEL" "$AGY_MODEL_FALLBACK"; do
  [ -z "$MODEL" ] && continue
  if is_weak "$MODEL" && [ "${GEMINI_ALLOW_WEAK:-0}" != "1" ]; then
    echo "ask_gemini.sh: REFUSING weak-tier model '$MODEL' in a judgment seat (GEMINI_ALLOW_WEAK=1 to override)" >&2
    continue
  fi
  # --sandbox: agy is an AGENTIC CLI — without it, print mode can use file-writing tools and
  # litter the caller's cwd (observed live 2026-06-12: scratch scrape_*.py files written into
  # the orchestrator's project root). Legs must be read-only.
  # --log-file: quota exhaustion prints NOTHING to stdout/stderr (rc 0); its only trace is
  # RESOURCE_EXHAUSTED/429 in agy's internal log, so route it to a temp file we can grep.
  : > "$LOGF"  # agy appends — truncate so we inspect only THIS model's log
  out="$(agy --print "$PROMPT" --model "$MODEL" --print-timeout "$AGY_PRINT_TIMEOUT" --sandbox --log-file "$LOGF" </dev/null 2>"$ERRF")"
  if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    log "$MODEL" "antigravity:pinned:$MODEL (unverified)" 0
    printf '%s\n' "$out"
    exit 0
  fi
  # Empty output: the real cause (if any) is quota. Broad match on stderr (terse), strict match on
  # the verbose log. "Individual quota reached" may be per-model/tier, so record it and try the next
  # model in the chain — the (Low) tier can still serve when (High) is capped.
  if grep -qiE "$QUOTA_RE" "$ERRF" 2>/dev/null || grep -qE "$QUOTA_LOG_RE" "$LOGF" 2>/dev/null; then
    quota_hit=1
    [ -z "$reset_hint" ] && reset_hint="$(grep -oh 'Resets in [^.:]*' "$LOGF" "$ERRF" 2>/dev/null | head -1)"
    log "$MODEL" "QUOTA_EXHAUSTED" 0
    echo "ask_gemini.sh: Antigravity individual quota exhausted (RESOURCE_EXHAUSTED/429) on '$MODEL'${reset_hint:+ — $reset_hint} — trying next model in chain" >&2
    continue
  fi
  head -2 "$ERRF" | sed 's/^/ask_gemini agy stderr: /' >&2
  echo "ask_gemini.sh: agy produced no output on '$MODEL' — trying next model in chain" >&2
done

if [ "$quota_hit" = 1 ]; then
  echo "ask_gemini.sh: Antigravity individual quota exhausted across the model chain${reset_hint:+ — $reset_hint} — account-wide, leg unavailable (quota)" >&2
  exit 5
fi
echo "ask_gemini.sh: agy produced no usable output for any model in the chain — leg unavailable" >&2
log "chain" "FAILED" 0
exit 1
