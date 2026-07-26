#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/grok-usage"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() {
  asserts=$((asserts + 1))
  "$@" || fail "assert $asserts failed: $*"
}

now=$(date +%s)
BAD_BYTE_HOME="$WORK/bad-byte"
mkdir -p "$BAD_BYTE_HOME/sessions/a/b"
printf '{"timestamp":%s,"note":"bad \377 byte","params":{"update":{"usage":{"numTurns":3,"inputTokens":5,"outputTokens":8,"totalTokens":13,"modelCalls":1}}}}\n' \
  "$((now - 1))" >"$BAD_BYTE_HOME/sessions/a/b/updates.jsonl"
bad_byte_output=$(GROK_HOME="$BAD_BYTE_HOME" "$SCRIPT" --json) || fail "bad-byte report failed"
assert jq -e '[.windows[] | .turns == 3 and .total == 13] | all' <<<"$bad_byte_output" >/dev/null

FUTURE_HOME="$WORK/future"
mkdir -p "$FUTURE_HOME/sessions/a/b"
printf '{"timestamp":%s,"params":{"update":{"usage":{"numTurns":2,"inputTokens":3,"outputTokens":4,"totalTokens":7,"modelCalls":1}}}}\n' \
  "$((now - 1))" >"$FUTURE_HOME/sessions/a/b/updates.jsonl"
printf '{"timestamp":%s,"params":{"update":{"usage":{"numTurns":9,"inputTokens":90,"outputTokens":90,"totalTokens":180,"modelCalls":9}}}}\n' \
  "$((now + 86400))" >>"$FUTURE_HOME/sessions/a/b/updates.jsonl"
future_output=$(GROK_HOME="$FUTURE_HOME" "$SCRIPT" --json) || fail "future-timestamp report failed"
assert jq -e '[.windows[] | .turns == 2 and .total == 7] | all' <<<"$future_output" >/dev/null

printf 'PASS: %s assertions; future timestamps are excluded and invalid UTF-8 bytes are replaced without losing valid usage rows\n' "$asserts"
