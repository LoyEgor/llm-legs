#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/claudebd-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/store"
OUTPUT=$(CLAUDEB_DIR="$WORK/store" node "$ROOT/tests/claudebd_harness.js")
printf '%s\n' "$OUTPUT"
[[ "$OUTPUT" == "PASS: claudebd decision logic (62 assertions)" ]]
