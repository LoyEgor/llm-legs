#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# hammerspoon/presence.lua over stubbed hs.* and a fixture SPEED_DOCTOR_DIR: line shape, alignment, nil app,
# no window API, no pruning of its own, write failures, tick cost.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v hs >/dev/null 2>&1 || { echo "   (skipped: Hammerspoon CLI is unavailable)"; exit 0; }

output=$(python3 - "$ROOT/tests/presence_harness.lua" <<'HSPY'
import subprocess
import sys

try:
    result = subprocess.run(["hs", "-c", f"return loadfile([[{sys.argv[1]}]])()"],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
HSPY
) || fail "the Hammerspoon harness threw or timed out: $output"
result=$(printf '%s\n' "$output" | grep -v '^-- Loading extension: ' | awk '/^(PASS|FAIL)/ { found = 1 } found')
case "$result" in
  PASS:*) echo "OK: $result" ;;
  *) fail "${result:-$output}" ;;
esac
