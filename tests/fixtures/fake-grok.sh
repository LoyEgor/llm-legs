#!/usr/bin/env bash
set -u

{
  printf 'CALL home=%s mcps=%s skills=%s updater=%s worker=%s argc=%s\n' \
    "${GROK_HOME-<unset>}" "${GROK_CLAUDE_MCPS_ENABLED-<unset>}" \
    "${GROK_CLAUDE_SKILLS_ENABLED-<unset>}" "${GROK_DISABLE_AUTOUPDATER-<unset>}" \
    "${GROK_WORKER-<unset>}" "$#"
  for argument in "$@"; do printf 'ARG=%q\n' "$argument"; done
} >>"$GROK_CALLS"

case "${1:-}" in
  '') exit 0 ;;
  login)
    [ "$#" -eq 2 ] && [ "${2:-}" = --device-auth ] || exit 64
    printf 'Device authentication complete\n'
    ;;
  models)
    # The heartbeat's token touch: the real CLI says this and rotates the token anyway, so its
    # own words and exit status are never what decides an account's auth state. A test that needs
    # the rotation itself names the new expiry in FAKE_GROK_ROTATE_EXPIRES; leaving it unset is a
    # touch that renewed nothing. Like 1.0.41, it rotates only a session within
    # GROK_AUTH_EARLY_INVALIDATION_SECS of its expiry (or with none readable).
    left=$(jq -r --argjson now "$(date +%s)" '
      first(.. | objects | .expires_at? // empty)
      | (if type == "number" then . else (sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty) end)
      | floor - $now' "${GROK_HOME:-/nonexistent}/auth.json" 2>/dev/null)
    if [ -n "${FAKE_GROK_ROTATE_EXPIRES:-}" ] && [ -n "${GROK_HOME:-}" ] \
       && [ -f "$GROK_HOME/auth.json" ] \
       && { [ -z "$left" ] || [ "$left" -lt "${GROK_AUTH_EARLY_INVALIDATION_SECS:-300}" ]; }; then
      rotated="$GROK_HOME/auth.json.rotated"
      if jq --arg expiry "$FAKE_GROK_ROTATE_EXPIRES" '
           def rotate: .expires_at = $expiry | .key = "rotated-key-sentinel"
             | (if has("refresh_token") then .refresh_token = "rotated-refresh-sentinel" else . end);
           if (.key | type) == "string" then rotate
           else with_entries(if (.value | type) == "object" and (.value.key | type) == "string"
                             then .value |= rotate else . end)
           end' "$GROK_HOME/auth.json" >"$rotated" 2>/dev/null; then
        mv "$rotated" "$GROK_HOME/auth.json"
      else
        rm -f "$rotated"
      fi
    fi
    printf 'You are not authenticated.\n' >&2
    printf 'grok-4-fast\n'
    ;;
  -*) exit 0 ;;
  *)
    printf 'fake-grok: unknown subcommand: %s\n' "$1" >&2
    exit 64
    ;;
esac
