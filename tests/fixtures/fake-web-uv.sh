#!/usr/bin/env bash
# Stands in for `uv run -q --script <engine>.py ...` behind bin/gemini-web and bin/chatgpt-web (set as
# GEMINI_WEB_UV / CHATGPT_WEB_UV): logs "<engine> <args>" to $WEB_CALLS and opens no Chrome. accounts
# prints $WEB_ACCOUNTS; status reads a bound account, or with $WEB_STATUS_FAIL that reason and exit 4.
shift 3
engine=$(basename "$1" .py)
shift
printf '%s %s\n' "$engine" "$*" >>"$WEB_CALLS"
empty='{"ok": true, "accounts": []}'
case "$1" in
  accounts) printf '%s\n' "${WEB_ACCOUNTS:-$empty}" ;;
  login) jq -cn --arg account "${*: -1}" '{ok: true, account: $account, login: true}' ;;
  status)
    if [ -n "${WEB_STATUS_FAIL:-}" ]; then
      jq -cn --arg reason "$WEB_STATUS_FAIL" '{ok: false, code: 4, reason: $reason}'
      exit 4
    fi
    if [ "$engine" = gemini_web ]; then
      jq -cn --arg account "$2" '{ok: true, account: $account, email: "fi…@example.com", bound_to: "fi…@example.com", credits: 1000}'
    else
      jq -cn --arg account "$2" '{ok: true, account: $account, signed_in: true, email: "fi…@example.com", bound_to: "fi…@example.com", plan: "plus"}'
    fi
    ;;
esac
