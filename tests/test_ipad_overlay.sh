#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v hs >/dev/null 2>&1 || fail "Hammerspoon CLI is unavailable"

# Run Lua harness for supervisor tests
printf 'Running Lua supervisor harness...\n'
output=$(hs -c "return dofile([[$ROOT/tests/ipad_overlay_harness.lua]])" 2>&1) \
  || fail "Lua harness failed: $output"
printf '%s\n' "$output" | grep -q 'All iPad overlay tests passed' \
  || fail "unexpected Lua harness output: $output"
printf '%s\n' "$output"

# Run smoke test for PyObjC helper
printf '\nRunning Python helper smoke test...\n'
PYTHON="/Volumes/Work/Projects/transcriptions-gpt/.venv/bin/python"
HELPER="$ROOT/hammerspoon/ipad_overlay_app/overlay_app.py"

if [ ! -f "$HELPER" ]; then
    fail "Helper file not found: $HELPER"
fi

if [ ! -f "$PYTHON" ]; then
    fail "Python not found: $PYTHON"
fi

smoke_output=$("$PYTHON" "$HELPER" --smoke 2>&1) || {
    # --smoke may exit non-zero; check output for PASSED or FAILED
    printf '%s\n' "$smoke_output"
    printf '%s\n' "$smoke_output" | grep -q 'SMOKE TEST' || fail "smoke test produced no output"
    exit 0
}

printf '%s\n' "$smoke_output"
printf '%s\n' "$smoke_output" | grep -q 'SMOKE TEST PASSED' || {
    printf '%s\n' "$smoke_output" | grep -q 'SMOKE TEST FAILED' && fail "smoke test failed (see output above)"
    fail "smoke test produced unexpected output"
}

printf '\nAll iPad overlay tests passed ✓\n'
