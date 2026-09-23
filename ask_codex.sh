#!/usr/bin/env bash
# Cross-vendor leg: OpenAI GPT via Codex CLI, BY SUBSCRIPTION, READ-ONLY.
# Prompt as $1 or stdin. Prints the model's final message to stdout.
#
# AUTONOMY MODEL POLICY (owner request 2026-06-09): do NOT hardcode a model version.
#   - CODEX_MODEL unset => the newest slug of the roster's default codex family
#     (share/worker-model.sh), so a new release arrives through the roster, no repo edit. If the
#     roster cannot answer, no -m flag => the Codex CLI default, logged as `cli-default`.
#   - The account is worker-pick's answer for role LEGS_ROLE (default `reviewers`): a report leg
#     is a judgment seat, so the workers switch does not silence it.
#   - GUARD instead of pin: the served model is extracted and tier-classified. If it looks like
#     a weak tier (mini/nano/lite/flash/...), the call FAILS (exit 3) rather than silently
#     feeding a cheap model's judgment into the pipeline (the workflow tolerates a dropped leg).
#     Override for emergencies: CODEX_ALLOW_WEAK=1. Force a specific model: CODEX_MODEL=<slug>;
#     a family word (CODEX_MODEL=<family>) runs that family's newest roster slug.
#   - Reasoning effort defaults to high. Frontier legs must not exceed high implicitly;
#     callers may explicitly pass CODEX_EFFORT for a different supported level.
#   - Every call logs {requested, served} to data/served-models.jsonl; `--probe` does a tiny
#     end-to-end call and reports the served model (used by pipeline/preflight.sh).
set -uo pipefail

# Never let a stray API key flip billing away from the subscription session.
unset OPENAI_API_KEY CODEX_API_KEY 2>/dev/null || true

EFFORT="${CODEX_EFFORT:-high}"
# Audit log lands in the CALLER's data/ dir by default (orchestrators invoke legs with
# cwd = project root). Override with LLM_LEGS_DATA_DIR for cron/launchd contexts.
DATA_DIR="${LLM_LEGS_DATA_DIR:-$PWD/data}"
mkdir -p "$DATA_DIR" 2>/dev/null || true
LOG="$DATA_DIR/served-models.jsonl"
WEAK_RE='(^|[-_.])(mini|nano|lite|flash|small|tiny|haiku|luna)([-_.0-9]|$)'

PROBE=0
if [ "${1:-}" = "--probe" ]; then PROBE=1; PROMPT="Reply with exactly: ok"; shift || true
else
  PROMPT="${1:-}"
  [ -z "$PROMPT" ] && PROMPT="$(cat)"
fi

ACCOUNT=main
CODEX_CMD=(codex)
# Missing routing tools are a cron/launchd portability case; preserve the bare-CLI contract.
if command -v worker-pick >/dev/null 2>&1; then
  pick_rc=0
  account="$(worker-pick --account codex --role "${LEGS_ROLE:-reviewers}")" || pick_rc=$?
  if [ "$pick_rc" -eq 3 ]; then
    # Falling back here would spend quota the router deliberately reserved.
    echo "ask_codex.sh: no selectable Codex account — leg unavailable" >&2
    exit 6
  elif [ "$pick_rc" -eq 2 ]; then
    echo "ask_codex.sh: worker-pick unusable (exit 2); falling back to bare codex on the main account" >&2
  elif [ "$pick_rc" -ne 0 ] || [ -z "$account" ]; then
    echo "ask_codex.sh: worker-pick failed (exit $pick_rc) — leg unavailable" >&2
    exit 6
  elif command -v codexb >/dev/null 2>&1; then
    ACCOUNT="$account"
    CODEX_CMD=(codexb profile "$ACCOUNT")
  else
    echo "ask_codex.sh: codexb not installed; falling back to bare codex on the main account" >&2
  fi
else
  echo "ask_codex.sh: worker-pick not installed; falling back to bare codex on the main account" >&2
fi

REQUESTED="${CODEX_MODEL:-}"
case "$REQUESTED" in
  gpt-*) ;;
  *)
    family="$REQUESTED"
    roster_account=""
    [ "${CODEX_CMD[0]}" = codexb ] && roster_account="$ACCOUNT"
    REQUESTED="$(. "$(dirname "${BASH_SOURCE[0]}")/share/worker-model.sh" 2>/dev/null \
      && worker_model_codex_slug "${family:-$(worker_model_default_model codex)}" "$roster_account" 2>/dev/null | head -1)" || REQUESTED=""
    case "$REQUESTED" in
      *[![:alnum:]._-]*) REQUESTED="" ;;
    esac
    if [ -z "$REQUESTED" ] && [ -n "$family" ]; then
      REQUESTED="$family"
    elif [ -z "$REQUESTED" ]; then
      echo "ask_codex.sh: the roster named no codex model; running the CLI default" >&2
    fi
    ;;
esac
MODEL_ARGS=()
[ -n "$REQUESTED" ] && MODEL_ARGS=(-m "$REQUESTED")

ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT
set +e
# </dev/null: codex reads stdin IN ADDITION to the argv prompt ("Reading additional input
# from stdin..."): an open pipe without EOF hangs the call, stray input pollutes the prompt.
OUT="$("${CODEX_CMD[@]}" exec --skip-git-repo-check --sandbox read-only \
        ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} -c model_reasoning_effort="$EFFORT" "$PROMPT" </dev/null 2>"$ERRF")"
RC=$?
set -e

# Best-effort served-model extraction from the startup banner (stderr first, then stdout).
served="$( { grep -m1 -ioE '(^|[[:space:]])model:?[[:space:]]+[a-z0-9._-]+' "$ERRF" 2>/dev/null \
          || printf '%s' "$OUT" | grep -m1 -ioE '(^|[[:space:]])model:?[[:space:]]+[a-z0-9._-]+'; } \
          | sed -E 's/.*[Mm]odel:?[[:space:]]+//' | head -1 )"

weak=0
if printf '%s' "${served:-}" | grep -qiE "$WEAK_RE"; then weak=1; fi
run_id="${LLM_LEGS_RUN_ID:-}"; case "$run_id" in *[![:alnum:]._-]*) run_id="" ;; esac
printf '{"ts":"%s","leg":"codex","requested":"%s","effort":"%s","served":"%s","weak_tier":%s,"rc":%d,"account":"%s","run":"%s"}\n' \
  "$(date -u +%FT%TZ)" "${REQUESTED:-cli-default}" "$EFFORT" "${served:-unknown}" "$weak" "$RC" "$ACCOUNT" "$run_id" \
  >> "$LOG" 2>/dev/null || true

if [ "$PROBE" = "1" ]; then
  echo "codex served: ${served:-unknown} (requested=${REQUESTED:-cli-default}, account=$ACCOUNT, weak_tier=$weak, rc=$RC)"
  [ $RC -ne 0 ] && exit $RC
  [ "$weak" = "1" ] && exit 3
  exit 0
fi

if [ $RC -ne 0 ]; then
  cat "$ERRF" >&2
  # Subscription usage-limit errors get a distinct exit code so the orchestrator can drop the
  # leg for the rest of the run instead of retrying into the same wall (observed 2026-06-12).
  if grep -qiE 'hit your usage limit|usage_limit|quota' "$ERRF" 2>/dev/null; then exit 5; fi
  exit $RC
fi
if [ "$weak" = "1" ] && [ "${CODEX_ALLOW_WEAK:-0}" != "1" ]; then
  echo "ask_codex.sh: REFUSING weak-tier model '${served}' in a judgment seat (set CODEX_ALLOW_WEAK=1 to override)" >&2
  exit 3
fi
printf '%s\n' "$OUT"
