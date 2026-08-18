#!/usr/bin/env bash
# bin/workflow-burn-gate.sh: a Workflow fan-out spends the SESSION's own account, so the gate warns
# at 70% and denies at 95%. No network; every limits reading comes from a fixture file.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/bin/workflow-burn-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
contains() { grep -Fq -- "$2" <<<"$1"; }
lacks() { ! grep -Fq -- "$2" <<<"$1"; }
denied() { contains "$1" '"permissionDecision":"deny"'; }
warned() { contains "$1" '"additionalContext"'; }

limits() {
  jq -nc --arg a "$1" --argjson pct "$2" \
    '{vendors:{claude:{accounts:[{account:$a,five_hour:{used_pct:$pct}}]}}}' >"$WORK/limits.json"
}

HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/.claude-profiles/.claudeb"

gate() {
  jq -cn '{hook_event_name:"PreToolUse",tool_name:"Workflow",tool_input:{}}' |
    env HOME="$HOME_DIR" LLM_LIMITS_FILE="$WORK/limits.json" \
      CLAUDE_LIMITS_ACCOUNT="${ACCOUNT_ENV-}" CLAUDE_CONFIG_DIR="${CONFIG_DIR_ENV-}" \
      bash "$GATE"
}

# --- The account named in the environment ------------------------------------------------------
limits alona 40
ACCOUNT_ENV=alona
assert lacks "$(gate)" 'additionalContext'
limits alona 80
assert warned "$(gate)"
assert contains "$(gate)" 'alona'
limits alona 97
assert denied "$(gate)"

# --- Nothing in the environment: claudeb's own state file names the account --------------------
# A plain `claude` launch sets neither variable, and the gate used to skip that session entirely —
# the one shape its own header describes as the failure it exists to stop. But that file holds the
# LAST profile launched on this machine, which is routinely another chat's: it may speak, never
# close the door.
ACCOUNT_ENV=
CONFIG_DIR_ENV="$HOME_DIR/.claude"
printf 'notcom\n' >"$HOME_DIR/.claude-profiles/.claudeb/.claudeb-state"
limits notcom 97
out=$(gate)
assert lacks "$out" '"permissionDecision"'
assert warned "$out"
assert contains "$out" 'notcom'
assert contains "$out" 'last claudeb profile launched on this machine'
limits notcom 80
out=$(gate)
assert lacks "$out" '"permissionDecision"'
assert contains "$out" 'notcom'
assert contains "$out" 'may be another chat'
limits notcom 10
assert lacks "$(gate)" 'additionalContext'
# Named in the environment, the same numbers still deny: the door closes on an account this session
# actually claims, and on no other.
limits notcom 97
ACCOUNT_ENV=notcom
assert denied "$(gate)"
ACCOUNT_ENV=
CONFIG_DIR_ENV="$HOME_DIR/.claude-profiles/notcom"
assert denied "$(gate)"
CONFIG_DIR_ENV="$HOME_DIR/.claude"

# --- Nothing names it at all: the part of the warning that needs no number ----------------------
rm -f "$HOME_DIR/.claude-profiles/.claudeb/.claudeb-state"
out=$(gate)
assert warned "$out"
assert contains "$out" 'SESSION'
assert contains "$out" 'llm-limits --table --no-write'
assert lacks "$out" '"permissionDecision"'

# --- Everything else passes through untouched ---------------------------------------------------
assert lacks "$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{}}' |
  env HOME="$HOME_DIR" LLM_LIMITS_FILE="$WORK/limits.json" bash "$GATE")" 'additionalContext'

printf 'PASS: %s asserts; workflow-burn-gate warns at 70%% and denies at 95%% for the session account, naming it from the environment, the profile config dir or claudeb state, denying only on an account the session itself names while a claudeb-state guess warns that it may belong to another chat, warns without a number when nothing can name it, and stays out of every other tool call\n' "$asserts"
