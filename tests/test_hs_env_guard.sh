#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v hs >/dev/null 2>&1 || fail "Hammerspoon CLI is unavailable"

printf 'Running Hammerspoon env guard harness...\n'
output=$(hs -c "return dofile([[$ROOT/tests/hs_env_guard_harness.lua]])" </dev/null 2>&1) \
  || fail "Lua harness failed: $output"
printf '%s\n' "$output" | grep -q 'All Hammerspoon env guard tests passed' \
  || fail "unexpected Lua harness output: $output"
printf '%s\n' "$output"
