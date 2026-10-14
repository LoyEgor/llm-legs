#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/image-caps.sh, which the vendor wrappers source: the caps model and CLI checks and their journal.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VENDOR_CLI_UPDATE_STATE_DIR="$WORK/vendor-cli-update"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

# --- the caps model check: fresh, stale and unknown ---------------------------
# shellcheck source=share/image-caps.sh
. "$ROOT/share/image-caps.sh"
video_model=$(jq -r '.model.video' "$ROOT/share/image-caps/grok.json")
checks="$VENDOR_CLI_UPDATE_STATE_DIR/caps-checks.jsonl"
mkdir -p "$VENDOR_CLI_UPDATE_STATE_DIR"
: >"$checks"
assert test "$(image_caps_model_check "$ROOT" grok video "$video_model")" = "model=$video_model model_caps=fresh"
assert test "$(image_caps_model_check "$ROOT" grok video '')" = 'model=unknown model_caps=unknown'
assert test "$(image_caps_model_check "$ROOT" grok video 'other-model')" = "model=other-model model_caps=stale verified=$video_model"
assert test "$(jq -c 'select(.vendor == "grok" and .section == "model.video") | [.state, .what]' "$checks" | paste -sd' ' -)" = \
  "[\"fresh\",\"model=$video_model verified=$video_model\"] [\"stale\",\"model=other-model verified=$video_model\"]"
cli_version=$(jq -r '.cli.version' "$ROOT/share/image-caps/grok.json")
printf '#!/bin/sh\necho "grok %s"\n' "$cli_version" >"$WORK/grok-current"
printf '#!/bin/sh\necho "grok 9.9.9"\n' >"$WORK/grok-newer"
chmod +x "$WORK/grok-current" "$WORK/grok-newer"
image_caps_check "$ROOT" grok "$WORK/grok-current" >/dev/null
image_caps_check "$ROOT" grok "$WORK/grok-newer" >/dev/null
assert test "$(jq -c 'select(.vendor == "grok" and .section == "cli") | [.state, .what]' "$checks" | paste -sd' ' -)" = \
  "[\"fresh\",\"cli=$cli_version verified=$cli_version\"] [\"stale\",\"cli=9.9.9 verified=$cli_version\"]"

printf 'PASS: %s asserts\n' "$asserts"
