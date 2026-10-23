#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# hammerspoon/presence.lua over stubbed hs.* and a fixture SPEED_DOCTOR_DIR: line shape, alignment, nil app,
# no window API, no pruning of its own, write failures, tick cost.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/hs-bounded.sh"

command -v hs >/dev/null 2>&1 || { echo "   (skipped: Hammerspoon CLI is unavailable)"; exit 0; }

output=$(HS_BOUNDED_IPC_S=120 hs_bounded 600 -q -c "return loadfile([[$ROOT/tests/presence_harness.lua]])()"
) || fail "the Hammerspoon harness threw or timed out: $output"
result=$(printf '%s\n' "$output" | grep -v '^-- Loading extension: ' | awk '/^(PASS|FAIL)/ { found = 1 } found')
case "$result" in
  'PASS: '[0-9]*' presence checks'*) echo "OK: $result" ;;
  *) fail "${result:-$output}" ;;
esac
