#!/usr/bin/env bash
# share/chat-account.sh: the one answer to which vendor and account THIS chat spends. Every surface
# that reads a usage row for its own session asks it, so the order of the facts is the contract.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT/share/chat-account.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_answer() { # expected env...
  local expected=$1 actual
  shift
  asserts=$((asserts + 1))
  actual=$(env -u CLAUDEGPT_ACCOUNT -u CLAUDE_LIMITS_ACCOUNT -u CLAUDE_CONFIG_DIR \
    "HOME=$WORK/home" "$@" bash "$RESOLVER") || fail "resolver run failed for: $*"
  [ "$actual" = "$expected" ] || fail "expected '$expected', got '$actual' for: $*"
}

# A `claudegpt` chat spends an OpenAI account, and it says so before anything else can be read:
# the launcher strips CLAUDE_LIMITS_ACCOUNT, but a chat that kept one is still the gateway's.
assert_answer 'codex notcom' CLAUDEGPT_ACCOUNT=notcom
assert_answer 'codex notcom' CLAUDEGPT_ACCOUNT=notcom CLAUDE_LIMITS_ACCOUNT=alona
assert_answer 'codex notcom' CLAUDEGPT_ACCOUNT=notcom "CLAUDE_CONFIG_DIR=$WORK/home/.claude-profiles/alona"
# The `-` sentinel every surface treats as unset, on both variables.
assert_answer 'claude alona' CLAUDEGPT_ACCOUNT=- CLAUDE_LIMITS_ACCOUNT=alona

# A claudeb chat: the variable first, then the profile config dir, then the fallback the caller
# passes — `main` unless it names its own.
assert_answer 'claude alona' CLAUDE_LIMITS_ACCOUNT=alona
assert_answer 'claude alona' "CLAUDE_CONFIG_DIR=$WORK/home/.claude-profiles/alona"
assert_answer 'claude com' CLAUDE_LIMITS_ACCOUNT=- "CLAUDE_CONFIG_DIR=$WORK/home/.claude-profiles/com"
# The shared configuration names no profile, so it is not an account.
assert_answer 'claude main' "CLAUDE_CONFIG_DIR=$WORK/home/.claude"
assert_answer 'claude main'
asserts=$((asserts + 1))
answer=$(env -u CLAUDEGPT_ACCOUNT -u CLAUDE_LIMITS_ACCOUNT -u CLAUDE_CONFIG_DIR "HOME=$WORK/home" \
  bash "$RESOLVER" notcom) || fail "fallback argument run failed"
[ "$answer" = 'claude notcom' ] || fail "the caller's own fallback was ignored: $answer"

# Sourced, the source is what lets a caller keep its own fallback apart from a resolved account:
# only `unknown` may be guessed at, and `bin/workflow-burn-gate.sh` guesses exactly there.
sourced_source() {
  env -u CLAUDEGPT_ACCOUNT -u CLAUDE_LIMITS_ACCOUNT -u CLAUDE_CONFIG_DIR "HOME=$WORK/home" "$@" \
    bash -c '. "$1"; chat_account_resolve; printf "%s %s %s\n" \
      "$CHAT_ACCOUNT_VENDOR" "${CHAT_ACCOUNT_NAME:--}" "$CHAT_ACCOUNT_SOURCE"' _ "$RESOLVER"
}
for expected_source in \
  'codex notcom gateway|CLAUDEGPT_ACCOUNT=notcom' \
  'claude alona env|CLAUDE_LIMITS_ACCOUNT=alona' \
  "claude alona config-dir|CLAUDE_CONFIG_DIR=$WORK/home/.claude-profiles/alona" \
  'claude - unknown|IGNORED=1'; do
  asserts=$((asserts + 1))
  answer=$(sourced_source "${expected_source#*|}") || fail "sourced run failed: $expected_source"
  [ "$answer" = "${expected_source%%|*}" ] ||
    fail "expected '${expected_source%%|*}', got '$answer'"
done

printf 'PASS: %s asserts; chat-account resolves the gateway account before every Claude fact, the account variable before the profile config dir, the shared configuration as no account at all, and reports the source that tells a resolved account from one a caller may guess\n' "$asserts"
