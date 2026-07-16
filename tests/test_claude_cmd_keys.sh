#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v hs >/dev/null 2>&1 || fail "Hammerspoon CLI is unavailable"
output=$(hs -c "return dofile([[$ROOT/tests/claude_cmd_keys_harness.lua]])" 2>&1) \
  || fail "Lua harness failed: $output"
printf '%s\n' "$output" | grep -q 'PASS: Claude Cmd key decisions' \
  || fail "unexpected Lua harness output: $output"
printf '%s\n' "$output"
