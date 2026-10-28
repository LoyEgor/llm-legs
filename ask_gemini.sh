#!/usr/bin/env bash
# Cross-vendor leg: Google, via the Antigravity CLI (`agy`), SUBSCRIPTION-ONLY.
# Prompt as $1 or stdin; the model's text answer goes to stdout.
# STRIPPED: an empty cwd (no GEMINI.md/AGENTS.md) and no slash commands or skills.
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
#   1) AGY_MODEL          (no default: Flash is weak, and every other family runs on request only)
#   2) AGY_MODEL_FALLBACK (optional, tried when the first answers nothing)
# Either may name a family slug instead of a label ("argon (High)"): it becomes that row's label.
# Unset, the leg answers exit 3 "no strong Gemini is served", so a caller drops to its other legs.
# Flash/lite tiers are WEAK and never used in a judgment seat (GEMINI_ALLOW_WEAK=1 overrides).
# The account is worker-pick's answer for role LEGS_ROLE (default `reviewers`) among the accounts
# whose own list carries the family, like ask_codex.sh.
#
# Every call logs {transport:"agy", requested, served(pinned, unverified)} to
# data/served-models.jsonl. Modes: --probe (no model call), --list-models.
set -uo pipefail

# Audit log lands in the CALLER's data/ dir by default (orchestrators invoke legs with
# cwd = project root). Override with LLM_LEGS_DATA_DIR for cron/launchd contexts.
DATA_DIR="${LLM_LEGS_DATA_DIR:-$PWD/data}"
mkdir -p "$DATA_DIR" 2>/dev/null || true
LOG="$DATA_DIR/served-models.jsonl"
# Listing model labels spends no quota and must not depend on a selectable account.
if [ "${1:-}" = --list-models ]; then
  agy models; exit $?
fi
families=$("$(dirname "${BASH_SOURCE[0]}")/bin/geminib" families --union 2>/dev/null)
families=${families//$'\t'/$'\x1f'}
model_slug=''
agy_label() { # var "<families slug or label> (<tier>)" -> var = "<agy label> (<tier>)"; anything else unchanged
  local word="${2%% (*}" label='' f2 f4
  while IFS=$'\x1f' read -r _ f2 _ f4 _; do
    { [ "$f2" = "$word" ] || [ "$f4" = "$word" ]; } && { label=$f4; model_slug=${model_slug:-$f2}; break; }
  done <<<"$families"
  if [ -n "$label" ]; then printf -v "$1" '%s' "$label${2#"$word"}"; else printf -v "$1" '%s' "$2"; fi
}
[ -n "${AGY_MODEL:-}" ] && agy_label AGY_MODEL "$AGY_MODEL"
[ -n "${AGY_MODEL_FALLBACK:-}" ] && agy_label AGY_MODEL_FALLBACK "$AGY_MODEL_FALLBACK"
AGY_PRINT_TIMEOUT="${AGY_PRINT_TIMEOUT:-5m}"
WEAK_RE='(^|[^a-z])(flash|lite|nano|mini|small|tiny)([^a-z]|$)'
# Broad, for stderr only (legacy behavior): stderr is terse, so false positives are unlikely.
QUOTA_RE='quota|exhausted|capacity|credits balance is too low|rate.?limit|resource.?exhausted|429'
# Strict, for the verbose --log-file: anchored to the measured error shape
# ("RESOURCE_EXHAUSTED (code 429): Individual quota reached ...") so debug-log noise can't trip it.
QUOTA_LOG_RE='RESOURCE_EXHAUSTED|Individual quota reached|\(code 429\)'

log() { # $1 requested, $2 served, $3 weak(0/1)
  local run_id="${LLM_LEGS_RUN_ID:-}"; case "$run_id" in *[![:alnum:]._-]*) run_id="" ;; esac
  printf '{"ts":"%s","leg":"gemini","transport":"agy","requested":"%s","served":"%s","weak_tier":%s,"account":"%s","run":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "${3:-0}" "$ACCOUNT" "$run_id" >> "$LOG" 2>/dev/null || true
}
is_weak() { printf '%s' "$1" | grep -qiE "$WEAK_RE"; }

ACCOUNT=main
GEMINI_CMD=(agy)
if [ -z "${AGY_MODEL:-}" ]; then
  echo 'ask_gemini.sh: no strong Gemini is served — Flash is weak and every other family runs on request (AGY_MODEL="<slug> (High)") — leg unavailable' >&2
  exit 3
fi
# Missing routing tools are a cron/launchd portability case; preserve the bare-CLI contract.
if command -v worker-pick >/dev/null 2>&1; then
  pick_rc=0
  account="$(worker-pick --account gemini ${model_slug:+--model "$model_slug"} --role "${LEGS_ROLE:-reviewers}")" || pick_rc=$?
  if [ "$pick_rc" -eq 3 ]; then
    # Falling back here would spend quota the router deliberately reserved.
    echo "ask_gemini.sh: no selectable Gemini account — leg unavailable" >&2
    exit 6
  elif [ "$pick_rc" -eq 2 ]; then
    echo "ask_gemini.sh: worker-pick unusable (exit 2); falling back to bare agy on the main account" >&2
  elif [ "$pick_rc" -ne 0 ] || [ -z "$account" ]; then
    echo "ask_gemini.sh: worker-pick failed (exit $pick_rc) — leg unavailable" >&2
    exit 6
  elif command -v geminib >/dev/null 2>&1; then
    ACCOUNT="$account"
    GEMINI_CMD=(geminib profile "$ACCOUNT")
  else
    echo "ask_gemini.sh: geminib not installed; falling back to bare agy on the main account" >&2
  fi
else
  echo "ask_gemini.sh: worker-pick not installed; falling back to bare agy on the main account" >&2
fi

case "${1:-}" in
  --probe)
    if [ "${GEMINI_CMD[0]}" = agy ] && ! command -v agy >/dev/null 2>&1; then
      echo "gemini leg: agy CLI not installed — leg unavailable" >&2
      exit 1
    fi
    MODELS="$("${GEMINI_CMD[@]}" models 2>/dev/null)"
    if ! printf '%s' "$MODELS" | grep -qF "$AGY_MODEL"; then
      echo "gemini leg: pinned model '$AGY_MODEL' not in 'agy models' list:" >&2
      printf '%s\n' "$MODELS" >&2
      exit 3
    fi
    echo "gemini leg alive: agy $("${GEMINI_CMD[@]}" --version 2>/dev/null | head -1), model pinned: $AGY_MODEL, account=$ACCOUNT (no probe call — quota economy)"
    exit 0 ;;
esac

PROMPT="${1:-}"
[ -z "$PROMPT" ] && PROMPT="$(cat)"

if [ "${GEMINI_CMD[0]}" = agy ] && ! command -v agy >/dev/null 2>&1; then
  echo "ask_gemini.sh: agy CLI not installed — leg unavailable" >&2
  log "$AGY_MODEL" "MISSING_CLI" 0
  exit 1
fi

# A fresh private empty cwd per call: a shared predictable one could carry planted project config.
ERRF="$(mktemp)"; OUTF="$(mktemp)"; LOGF="$(mktemp)"; STUB_DIR="$(mktemp -d)"
trap 'rm -f "$ERRF" "$OUTF" "$LOGF"; rm -rf "$STUB_DIR"' EXIT
LEGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A copy without share/ beside it still answers, only without the SIGKILL its CLI gets on a caller's TERM.
. "$LEGS_DIR/share/leg-call.sh" 2>/dev/null ||
  leg_call() { local out=$1 err=$2; shift 2; "$@" >"$out" 2>"$err" </dev/null; }
cd "$STUB_DIR" || exit 1
quota_hit=0
served_other=0
reset_hint=""
for MODEL in "$AGY_MODEL" ${AGY_MODEL_FALLBACK:+"$AGY_MODEL_FALLBACK"}; do
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
  rc=0
  leg_call "$OUTF" "$ERRF" "${GEMINI_CMD[@]}" --print "$PROMPT" --model "$MODEL" --print-timeout "$AGY_PRINT_TIMEOUT" \
    --sandbox --disable-slash-commands --log-file "$LOGF" || rc=$?
  out="$(cat "$OUTF")"
  if grep -q 'print timeout after' "$ERRF" 2>/dev/null && . "$LEGS_DIR/share/limit-hit.sh"; then
    limit_hit ask-gemini.print-timeout 300 s kill "an ask_gemini answer from $MODEL, cut at --print-timeout $AGY_PRINT_TIMEOUT" \
      'ask_gemini.sh:AGY_PRINT_TIMEOUT="${'
  fi
  answered=0
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] || answered=1
  # agy >= 1.2.10 exits nonzero when a streamed answer ends on a model error: the text is cut short.
  if [ "$answered" = 1 ] && [ "$rc" -eq 0 ]; then
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
  served_other=1
  if [ "$answered" = 1 ]; then
    log "$MODEL" "PARTIAL" 0
    echo "ask_gemini.sh: agy cut the answer short (exit $rc) on '$MODEL' — trying next model in chain" >&2
    continue
  fi
  echo "ask_gemini.sh: agy produced no output on '$MODEL' — trying next model in chain" >&2
done

if [ "$quota_hit" = 1 ] && [ "$served_other" = 0 ]; then
  . "$LEGS_DIR/share/worker-walls.sh"
  worker_walls_record gemini "$ACCOUNT" "$(worker_walls_parse_reset "$reset_hint")" '' '' "$model_slug" || true
  echo "ask_gemini.sh: Antigravity individual quota exhausted across the model chain${reset_hint:+ — $reset_hint} — account-wide, leg unavailable (quota)" >&2
  exit 5
fi
echo "ask_gemini.sh: agy produced no usable output for any model in the chain — leg unavailable" >&2
log "chain" "FAILED" 0
exit 1
