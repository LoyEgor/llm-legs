#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-spawn-hook.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs"
unset CLAUDEB_WORKER WORKER_PICK_CONFIG_FILE CLAUDE_LIMITS_ACCOUNT CLAUDE_CONFIG_DIR
mkdir -p "$HOME" "$WORKER_RUN_DIR"
TAGS="$HOME/.cache/claude-worker-tags/s1"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }
assert_has() { asserts=$((asserts + 1)); case "$2" in *"$1"*) ;; *) fail "[$2] lacks [$1]" ;; esac; }

spawn() { # type prompt use [model]
  jq -cn --arg t "$1" --arg p "$2" --arg u "$3" --arg m "${4:-}" \
    '{hook_event_name:"PreToolUse",tool_name:"Agent",session_id:"s1",tool_use_id:$u,
      tool_input:({subagent_type:$t,description:"Do the task",prompt:$p} + (if $m == "" then {} else {model:$m} end))}' |
    bash "$HOOK" 2>/dev/null
}
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

cat >"$WORK/count-jq.sh" <<'SH'
jq() { printf 'call\n' >> "$JQ_CALLS"; command jq "$@"; }
SH
BASH_ENV="$WORK/count-jq.sh" JQ_CALLS="$WORK/jq-calls" bash "$HOOK" <<'JSON'
{"hook_event_name":"PreToolUse","tool_name":"Workflow","session_id":"s1"}
JSON
assert_eq 1 "$(wc -l <"$WORK/jq-calls" | tr -d ' ')"

# Every retired relay is refused with the chat's own protocol for its vendor, and leaves no seed.
for relay in claudeb codex gemini grok light; do
  out=$(spawn "$relay-worker" $'ACCOUNT: a1\nFix it.' "u-$relay")
  assert_eq deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  assert_has "the $relay-worker relay is retired. Delegate from this chat: write the brief to a file; Bash \`worker-run start $relay --brief <file> --workdir <dir>\`" "$(reason <<<"$out")"
  assert_has 'then Bash with run_in_background `worker-run wait <run-id>`; on its completion notification, `worker-run report <run-id>`' "$(reason <<<"$out")"
done
assert_has 'Run `light-research --prompt-file <file> --out <answer-file> --repo <abs>` as a Bash with run_in_background' \
  "$(spawn light-research 'Where is X?' u-lr | reason)"
assert_has 'Run `review-bench wait <run-id>` as a Bash with run_in_background' "$(spawn review-waiter 'WAIT r1: x' u-rw | reason)"
for native in general-purpose Explore Plan claude statusline-setup ''; do
  assert_has "native ${native:-general-purpose} is not spawned. Delegate from this chat" "$(spawn "$native" 'Look around.' "u-n$native" | reason)"
done
assert_eq '' "$(ls "$TAGS" 2>/dev/null)"

# A fork spawns, renamed to its own model and the session account, and seeds its tag for the tag hook.
out=$(spawn fork $'Map the gate.\nKeep the literal \'quote\' and $(touch '"$WORK/injected"$') text.' u-f1 claude-opus-5-5)
assert_eq allow "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
assert_eq 'fork · opus · main: Do the task' "$(jq -r '.hookSpecificOutput.updatedInput.description' <<<"$out")"
assert_eq 'fork · opus · main' "$(head -n1 "$TAGS/pending-fork-u-f1")"
assert_eq "spawn=$(printf 'Map the gate.\n' | shasum -a 256 | cut -c1-16)" "$(grep '^spawn=' "$TAGS/pending-fork-u-f1")"
asserts=$((asserts + 1))
[ ! -e "$WORK/injected" ] || fail "payload text was executed"
assert_eq 'fork · inherit · acct2: Do the task' \
  "$(CLAUDE_LIMITS_ACCOUNT=acct2 spawn fork 'Go.' u-f2 | jq -r '.hookSpecificOutput.updatedInput.description')"

printf 'PASS: %s asserts; every retired relay type (vendor relays, light-research, review-waiter) and every native type is refused with the chat'"'"'s own worker-run start / background wait / report protocol and leaves no seed, while a fork spawns renamed `fork · <model> · <account>: <title>` with a seed keyed by its first prompt line\n' "$asserts"
