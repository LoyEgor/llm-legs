#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/image-leg.sh, which the vendor wrappers source: the route fallback and the exit-3 cause.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
asserts=0

# --- busy and limit are left to the scheduler; the next route is the last resort --------------------
(
  . "$ROOT/share/image-leg.sh"
  IMAGE_LEG_ROUTE=web IMAGE_LEG_FALLBACK_FROM='' IMAGE_LEG_SCHEDULER=''
  ! image_leg_fallback 3 '{}' cli 2>/dev/null || exit 1
  IMAGE_LEG_CLI_OK=1
  for code in 3 5; do
    IMAGE_LEG_FALLBACK_FROM='' IMAGE_LEG_SCHEDULER=''
    image_leg_fallback "$code" '{}' cli 2>/dev/null || exit 1
    IMAGE_LEG_FALLBACK_FROM='' IMAGE_LEG_SCHEDULER=1
    ! image_leg_fallback "$code" '{}' cli 2>/dev/null || exit 1
  done
  IMAGE_LEG_FALLBACK_FROM='' IMAGE_LEG_SCHEDULER=1
  image_leg_fallback 4 '{}' cli 2>/dev/null
)
assert test "$?" -eq 0

# --- a flagged account (the engine's `flagged`) is exit 3 but never reported as a usage limit ------
flag_err=$( (. "$ROOT/share/image-leg.sh"; image_leg_limit GEMINI '{"ok":false,"code":3,"flagged":true}') 2>&1 )
assert test "$?:$flag_err" = '3:GEMINI_ACCOUNT_FLAGGED'
flag_err=$( (. "$ROOT/share/image-leg.sh"; image_leg_limit GEMINI '{"ok":false,"code":3}') 2>&1 )
assert test "$?:$flag_err" = '3:GEMINI_USAGE_LIMIT'
flag_err=$( (. "$ROOT/share/image-leg.sh"; IMAGE_LEG_ROUTE=flow; image_leg_fallback 3 '{"flagged":true}' cli) 2>&1 )
assert grep -Fq 'failed (flagged)' <<<"$flag_err"

printf 'PASS: %s asserts\n' "$asserts"
