#!/usr/bin/env bash
# Regression test for ask_gemini.sh silent-quota detection.
#
# Context (measured live 2026-07-05): when the Antigravity individual quota is exhausted,
# `agy --print ... --sandbox` returns rc 0 with EMPTY stdout AND stderr; the RESOURCE_EXHAUSTED
# (429) error appears only in agy's internal log. ask_gemini.sh now routes that log via
# `--log-file` and greps it, so it can exit 5 (orchestrator drops the leg) instead of falling
# through as a generic failure and exit 1.
#
# This test uses a STUB `agy` (no real model call — quota is exhausted) prepended to PATH:
#   - `models`  -> prints a list containing "Gemini 3.1 Pro (High)" and "(Low)"
#   - `--print` -> writes nothing to stdout/stderr, exits 0, and (in quota mode) appends the
#                  RESOURCE_EXHAUSTED line to the path passed after `--log-file`.
# STUB_MODE selects behavior:
#   quota            -> every model silent-quota-fails (log line, empty stdout)
#   empty            -> every model produces plain-empty output (no quota markers)
#   high_quota_low_ok-> (High) silent-quota-fails, (Low) answers on stdout (per-model quota)
#
# Self-contained; exits 0 on pass, non-zero on failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/ask_gemini.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUBDIR="$WORK/bin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/agy" <<'STUB'
#!/usr/bin/env bash
# Test stub for `agy` — mimics the headless surface ask_gemini.sh uses; never calls a model.
case "${1:-}" in
  models)
    printf '%s\n' "Gemini 3.1 Pro (High)" "Gemini 3.1 Pro (Low)" "Gemini 3.1 Flash"
    exit 0 ;;
  --version)
    echo "agy version 1.0.7 (test stub)"; exit 0 ;;
esac
# --print mode: locate --log-file <path> and --model <label>
logf=""; model=""; prev=""
for a in "$@"; do
  case "$prev" in
    --log-file) logf="$a" ;;
    --model)    model="$a" ;;
  esac
  prev="$a"
done
QLINE="2026-07-05T00:00:00Z ERROR agy/api: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 106h19m5s."
case "${STUB_MODE:-quota}" in
  quota)
    # Silent quota on every model: rc 0, empty stdout+stderr; error lives ONLY in the log file.
    [ -n "$logf" ] && printf '%s\n' "$QLINE" >> "$logf" ;;
  high_quota_low_ok)
    # Per-model quota: (High) is capped (log line, empty stdout), (Low) still answers.
    case "$model" in
      *"(Low)"*) printf '%s\n' "FALLBACK ANSWER FROM LOW TIER" ;;
      *) [ -n "$logf" ] && printf '%s\n' "$QLINE" >> "$logf" ;;
    esac ;;
  empty) : ;;  # plain generic empty output; log untouched
esac
exit 0
STUB
chmod +x "$STUBDIR/agy"

export PATH="$STUBDIR:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Case 1: quota on BOTH models -> chain exhausted -> exit 5, reset hint, both models attempted ---
DATA1="$WORK/data-quota"
err1="$WORK/err1.txt"
STUB_MODE=quota LLM_LEGS_DATA_DIR="$DATA1" \
  bash "$SCRIPT" "test prompt" >/dev/null 2>"$err1"
rc=$?
[ "$rc" -eq 5 ] || fail "quota case: expected exit 5, got $rc; stderr: $(cat "$err1")"
grep -qi 'quota' "$err1" || fail "quota case: stderr missing quota message: $(cat "$err1")"
grep -q 'Resets in 106h19m5s' "$err1" || fail "quota case: stderr missing reset hint: $(cat "$err1")"
grep -q '(High)' "$err1" || fail "quota case: stderr should name the first (High) model"
grep -q '(Low)' "$err1" || fail "quota case: fallback (Low) must ALSO be attempted before exit 5"
grep -q 'QUOTA_EXHAUSTED' "$DATA1/served-models.jsonl" \
  || fail "quota case: audit row QUOTA_EXHAUSTED not logged"

# --- Case 1b: (High) quota but (Low) answers -> exit 0 with the fallback answer ---
DATA1b="$WORK/data-quota-low-ok"
out1b="$WORK/out1b.txt"; err1b="$WORK/err1b.txt"
STUB_MODE=high_quota_low_ok LLM_LEGS_DATA_DIR="$DATA1b" \
  bash "$SCRIPT" "test prompt" >"$out1b" 2>"$err1b"
rc=$?
[ "$rc" -eq 0 ] || fail "high_quota_low_ok case: expected exit 0, got $rc; stderr: $(cat "$err1b")"
grep -q 'FALLBACK ANSWER FROM LOW TIER' "$out1b" \
  || fail "high_quota_low_ok case: fallback (Low) answer missing from stdout: $(cat "$out1b")"
grep -q '(High)' "$err1b" || fail "high_quota_low_ok case: stderr should note the (High) quota hit"

# --- Case 2: plain empty (no quota markers) -> tries both models, exit 1 ---
DATA2="$WORK/data-empty"
err2="$WORK/err2.txt"
STUB_MODE=empty LLM_LEGS_DATA_DIR="$DATA2" \
  bash "$SCRIPT" "test prompt" >/dev/null 2>"$err2"
rc=$?
[ "$rc" -eq 1 ] || fail "empty case: expected exit 1, got $rc; stderr: $(cat "$err2")"
grep -q '(High)' "$err2" || fail "empty case: first model (High) not attempted"
grep -q '(Low)' "$err2"  || fail "empty case: fallback (Low) not attempted before giving up"
grep -q 'no usable output for any model' "$err2" \
  || fail "empty case: missing final give-up message"
grep -q 'FAILED' "$DATA2/served-models.jsonl" || fail "empty case: audit row FAILED not logged"

# --- Case 3: --probe stays quota-economical (models + version only, no --print) -> exit 0 ---
out3="$WORK/probe.out"; err3="$WORK/probe.err"
LLM_LEGS_DATA_DIR="$WORK/data-probe" \
  bash "$SCRIPT" --probe >"$out3" 2>"$err3"
rc=$?
[ "$rc" -eq 0 ] || fail "probe case: expected exit 0, got $rc; stderr: $(cat "$err3")"
grep -q 'gemini leg alive' "$out3" || fail "probe case: missing alive line: $(cat "$out3")"

echo "PASS: quota-chain->5, quota-fallback-ok->0, empty->1, probe->0"
exit 0
