#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/hs-bounded.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v hs >/dev/null 2>&1 || { echo "   (skipped: Hammerspoon CLI is unavailable)"; exit 0; }

output=$(HS_BOUNDED_IPC_S=120 hs_bounded 600 -c "return dofile([[$ROOT/tests/token_tracking_menu_harness.lua]])"
) || fail "the Hammerspoon harness threw or timed out: $output"
# The garbage-file case makes LuaSkin log its own decode error on stdout; the verdict is the
# harness's return value, the last line.
result=$(printf '%s\n' "$output" | grep -v '^-- Loading extension: ' | awk '/^(PASS|FAIL)/ { found = 1 } found')
[ "$result" = "PASS: token-tracking menu contract" ] || fail "$result"
echo "OK: token-tracking menu contract"
