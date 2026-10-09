#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v hs >/dev/null 2>&1 || { echo "   (skipped: Hammerspoon CLI is unavailable)"; exit 0; }

output=$(python3 - "$ROOT/tests/token_tracking_menu_harness.lua" <<'HSPY'
import subprocess
import sys

try:
    result = subprocess.run(["/usr/bin/lockf", "-k", "-t", "600", "/tmp/hs-cli.lock", "hs", "-t", "120", "-c", f"return dofile([[{sys.argv[1]}]])"],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=730)
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
HSPY
) || fail "the Hammerspoon harness threw or timed out: $output"
# The garbage-file case makes LuaSkin log its own decode error on stdout; the verdict is the
# harness's return value, the last line.
result=$(printf '%s\n' "$output" | grep -v '^-- Loading extension: ' | awk '/^(PASS|FAIL)/ { found = 1 } found')
[ "$result" = "PASS: token-tracking menu contract" ] || fail "$result"
echo "OK: token-tracking menu contract"
