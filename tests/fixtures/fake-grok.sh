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
    # own words and exit status are never what decides an account's auth state.
    printf 'You are not authenticated.\n' >&2
    printf 'grok-4-fast\n'
    ;;
  -*) exit 0 ;;
  *)
    printf 'fake-grok: unknown subcommand: %s\n' "$1" >&2
    exit 64
    ;;
esac
