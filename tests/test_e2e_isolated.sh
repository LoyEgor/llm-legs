#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

# e2e_surfaces.sh is a live suite run only by the daily llm-selfcheck, so its isolated Hammerspoon
# contracts rotted unseen for weeks. Its isolated-only mode touches no live store or singleton.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A chat hands every child the live worker-model; one with OpenCode paused must not empty the
# fixture's OpenCode rows.
printf 'worker=auto\nopencode_paused=on\n' >"$WORK/worker-model"
out=$(WORKER_PICK_CONFIG_FILE="$WORK/worker-model" LLM_LIMITS_E2E_ISOLATED_ONLY=1 \
  bash "$ROOT/tests/e2e_surfaces.sh" 2>&1) || fail "e2e_surfaces.sh isolated mode: $out"
grep -q '^PASS: e2e isolated-only mode' <<<"$out" || fail "isolated mode did not finish: $out"
echo "PASS: e2e_surfaces isolated contracts"
