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
      CLAUDEGPT_ACCOUNT="${GATEWAY_ENV-}" \
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
# And it never goes quiet: silence is how a reader learns there is headroom, which is the one
# thing a guess cannot report.
limits notcom 10
out=$(gate)
assert warned "$out"
assert contains "$out" 'notcom at 10%'
assert lacks "$out" '"permissionDecision"'
# Nor when the guess has no usage reading behind it at all.
mv "$WORK/limits.json" "$WORK/limits.away"
out=$(gate)
assert warned "$out"
assert contains "$out" 'could not read'
assert lacks "$out" '"permissionDecision"'
mv "$WORK/limits.away" "$WORK/limits.json"
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

# --- A gateway chat spends its OpenAI account, and the pressure that matters is that one -------
# `claudegpt` runs Claude Code on an OpenAI subscription: the fan-out bills `vendors.codex` under
# CLAUDEGPT_ACCOUNT, so a Claude row of the same name is a number this session never spends
# (share/chat-account.sh).
jq -nc '{vendors:{
  claude:{accounts:[{account:"work4",five_hour:{used_pct:10}}]},
  codex:{accounts:[{account:"work4",five_hour:{used_pct:97}}]}}}' >"$WORK/limits.json"
ACCOUNT_ENV=
CONFIG_DIR_ENV="$HOME_DIR/.claude"
GATEWAY_ENV=work4
out=$(gate)
assert denied "$out"
assert contains "$out" 'codex/work4'
# The gateway account outranks every Claude fact the same environment carries.
ACCOUNT_ENV=work4
CONFIG_DIR_ENV="$HOME_DIR/.claude-profiles/work4"
assert denied "$(gate)"
# And a quiet codex account is quiet, whatever the Claude row of that name reads.
jq -nc '{vendors:{
  claude:{accounts:[{account:"work4",five_hour:{used_pct:97}}]},
  codex:{accounts:[{account:"work4",five_hour:{used_pct:10}}]}}}' >"$WORK/limits.json"
assert lacks "$(gate)" 'additionalContext'
GATEWAY_ENV=
ACCOUNT_ENV=
CONFIG_DIR_ENV="$HOME_DIR/.claude"

# --- Everything else passes through untouched ---------------------------------------------------
assert lacks "$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{}}' |
  env HOME="$HOME_DIR" LLM_LIMITS_FILE="$WORK/limits.json" bash "$GATE")" 'additionalContext'

# A workflow reaching a relay type or worker-run is denied whatever the pressure; one of native
# agents is not, and a script file is read like an inline script.
limits alona 10
ACCOUNT_ENV=alona
wf() { jq -cn --arg s "$1" --arg p "${2:-}" '{hook_event_name:"PreToolUse",tool_name:"Workflow",tool_input:({script:$s} + (if $p == "" then {} else {scriptPath:$p} end))}' |
  env HOME="$HOME_DIR" LLM_LIMITS_FILE="$WORK/limits.json" CLAUDE_LIMITS_ACCOUNT="$ACCOUNT_ENV" bash "$GATE"; }
assert denied "$(wf "await agent('x', {subagent_type: 'codex-worker'})")"
assert denied "$(wf "await agent('run worker-run start codex --brief b')")"
assert lacks "$(wf "await agent('grep the repo')")" 'permissionDecision'
printf "agent('y', {agentType: 'claudeb-worker'})\n" >"$WORK/wf.js"
assert denied "$(wf "" "$WORK/wf.js")"

printf 'PASS: %s asserts; workflow-burn-gate warns at 70%% and denies at 95%% for the session account, naming it from the gateway launcher, the environment, the profile config dir or claudeb state, denying only on an account the session itself names while a claudeb-state guess always speaks and warns that it may belong to another chat, warns without a number when nothing can name it, denies a workflow that reaches a relay agent type or worker-run, inline or from its script file, and stays out of every other tool call\n' "$asserts"
