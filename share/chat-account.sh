#!/usr/bin/env bash
# The one answer to "which vendor and account is THIS chat spending", for every tool that has to
# read a usage row for the session it runs in.
#
# A chat launched through `claudegpt` spends an OpenAI subscription (`vendors.codex.accounts[]`
# keyed by CLAUDEGPT_ACCOUNT) while running on the SHARED ~/.claude configuration with no
# CLAUDE_LIMITS_ACCOUNT and no claudeb state of its own — so every environment fact a claudeb
# chat is named by is absent, and a surface that skips this question reads a Claude account the
# chat never touches (docs/claudegpt.md).
#
# The answer is the environment's alone: `.claudeb-state` records the last profile LAUNCHED on
# this machine, not this chat, so a caller that wants that guess asks for it itself and says it
# guessed. `CHAT_ACCOUNT_SOURCE` is what lets it: `unknown` is the only case where the environment
# named nothing, and each caller keeps its own fallback for it (`main`, `notcom`, a guess).

# Sets CHAT_ACCOUNT_VENDOR (`claude`/`codex`, the `.vendors.<key>` of ~/.llm-limits.json),
# CHAT_ACCOUNT_NAME (empty when nothing named it) and CHAT_ACCOUNT_SOURCE
# (`gateway`/`env`/`config-dir`/`unknown`).
chat_account_resolve() {
  CHAT_ACCOUNT_VENDOR=claude
  CHAT_ACCOUNT_NAME=""
  CHAT_ACCOUNT_SOURCE=unknown
  local gateway="${CLAUDEGPT_ACCOUNT:-}" named="${CLAUDE_LIMITS_ACCOUNT:-}"
  if [ -n "$gateway" ] && [ "$gateway" != "-" ]; then
    CHAT_ACCOUNT_VENDOR=codex
    CHAT_ACCOUNT_NAME=$gateway
    CHAT_ACCOUNT_SOURCE=gateway
    return 0
  fi
  if [ -n "$named" ] && [ "$named" != "-" ]; then
    CHAT_ACCOUNT_NAME=$named
    CHAT_ACCOUNT_SOURCE=env
    return 0
  fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "${HOME:-}/.claude" ]; then
    CHAT_ACCOUNT_NAME=$(basename "$CLAUDE_CONFIG_DIR")
    CHAT_ACCOUNT_SOURCE=config-dir
    return 0
  fi
  return 0
}

# Sourced by every caller; run directly it prints `<vendor> <account>` for the current process,
# with the argument (default `main`, worker-pick's own) standing in where nothing named the chat.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  chat_account_resolve
  printf '%s %s\n' "$CHAT_ACCOUNT_VENDOR" "${CHAT_ACCOUNT_NAME:-${1:-main}}"
fi
