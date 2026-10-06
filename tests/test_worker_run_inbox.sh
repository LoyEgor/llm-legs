#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"

HOOK="$ROOT/bin/worker-inbox-hook.sh"
export CLAUDE_CODE_SESSION_ID=inbox-chat

# A claude CLI that makes TOOL_CALLS tool calls, each released by a gate file, and runs every
# PostToolUse hook its `--settings` names after each one the way the real CLI does.
cat >"$WORK/bin/claudeb" <<'EOF'
#!/usr/bin/env bash
settings='{}' previous=''
for argument in "$@"; do
  [ "$previous" != --settings ] || settings=$argument
  previous=$argument
done
printf '%s\n' "$settings" >"$STUB_DIR/claudeb.settings"
cat >"$STUB_DIR/claudeb.stdin"
call=0
while [ "$call" -lt "${TOOL_CALLS:-0}" ]; do
  call=$((call + 1))
  until [ -e "$STUB_DIR/tool-$call" ]; do sleep 0.05; done
  : >"$STUB_DIR/context-$call"
  jq -r '.hooks.PostToolUse[]? | select(.matcher == "*") | .hooks[].command' <<<"$settings" |
    while IFS= read -r command; do
      printf '{"hook_event_name":"PostToolUse","session_id":"inbox-session","tool_name":"Bash","tool_input":{"command":"true"}}' |
        if [ -n "${STUB_NO_RECORD:-}" ]; then env -u WORKER_RUN_RECORD sh -c "$command"; else sh -c "$command"; fi | jq -r '.hookSpecificOutput.additionalContext // empty' >>"$STUB_DIR/context-$call"
    done
  : >"$STUB_DIR/tool-$call.done"
done
printf '{"type":"result","result":"inbox result","session_id":"inbox-session"}\n'
EOF
chmod +x "$WORK/bin/claudeb"

tool_call_done() { # n
  : >"$STUB_DIR/tool-$1"
  until [ -e "$STUB_DIR/tool-$1.done" ]; do sleep 0.05; done
}

# --- claudeb: delivered by the hook at the next tool call, exactly once ---------------------------
clear_stub
export PICK_ACCOUNT=picked PICK_RC=0 TOOL_CALLS=4
start_ok claudeb
until [ -s "$STUB_DIR/claudeb.settings" ]; do sleep 0.05; done
assert test "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$STUB_DIR/claudeb.settings")" = "$(realpath "$HOOK")"
assert test "$(jq -r '.hooks.PostToolUse[0].matcher' "$STUB_DIR/claudeb.settings")" = '*'
assert jq -e --arg hook "$(realpath "$HOOK")" \
  '.cmd | index("--settings") as $i | $i != null and (.[$i + 1] | fromjson | .hooks.PostToolUse[0].hooks[0].command == $hook)' \
  "$RUN_DIR/meta.json" >/dev/null
tool_call_done 1
assert test ! -s "$STUB_DIR/context-1"
said=$(WORKER_RUN_SAY_WAIT_S=0 "$RUNNER" say "$RUN_ID" 'stop editing bin/x, the chat fixed it')
assert test "$said" = 'queued: the worker reads it at its next tool call'
assert grep -qxF "MESSAGE: $(jq -r '.at + " " + .by' "$RUN_DIR/inbox")"': stop editing bin/x, the chat fixed it — queued: the worker reads it at its next tool call' \
  <<<"$("$RUNNER" report "$RUN_ID")"
tool_call_done 2
assert test "$(grep -c 'Message from the chat that launched you (.*): stop editing bin/x, the chat fixed it' "$STUB_DIR/context-2")" -eq 1
assert grep -q '— delivered at ' <<<"$("$RUNNER" report "$RUN_ID")"
assert test ! -e "$RUN_DIR/inbox.new"
assert grep -Eq "^$(wc -c <"$RUN_DIR/inbox" | tr -d ' ') [0-9T:+-]+ hook$" "$RUN_DIR/inbox.delivered"
WORKER_RUN_SAY_WAIT_S=60 "$RUNNER" say "$RUN_ID" 'second word' >"$WORK/say2.out" &
say_pid=$!
until [ -e "$RUN_DIR/inbox.new" ]; do sleep 0.05; done
tool_call_done 3
wait "$say_pid"
assert grep -Eqx 'delivered at [0-9T:+-]+' "$WORK/say2.out"
assert grep -q 'second word' "$STUB_DIR/context-3"
assert_fails grep -q 'stop editing' "$STUB_DIR/context-3"
tool_call_done 4
assert test ! -s "$STUB_DIR/context-4"
await_done
assert test "$(grep -c '— delivered at ' <<<"$("$RUNNER" report "$RUN_ID")")" -eq 2
assert grep -q '^STATUS: done$' "$WORK/wait.out"

# --- a finished run takes no message ----------------------------------------------------------------
late_rc=0
"$RUNNER" say "$RUN_ID" 'too late' >"$WORK/say-late.out" 2>"$WORK/say-late.err" || late_rc=$?
assert test "$late_rc" -eq 4
assert test ! -s "$WORK/say-late.out"
assert grep -qF "run $RUN_ID has finished" "$WORK/say-late.err"
assert grep -qF 'RESUME inbox-session:' "$WORK/say-late.err"
assert_fails grep -q 'too late' "$RUN_DIR/inbox"

# --- a worker without the run's record in its environment claims no delivery -----------------------
clear_stub
export TOOL_CALLS=1 STUB_NO_RECORD=1
start_ok claudeb
said=$(WORKER_RUN_SAY_WAIT_S=0 "$RUNNER" say "$RUN_ID" 'no record')
tool_call_done 1
assert test ! -s "$STUB_DIR/context-1"
assert test ! -e "$RUN_DIR/inbox.delivered"
await_done
unset STUB_NO_RECORD
assert grep -q '— queued for RESUME: the run ended before its next tool call$' <<<"$("$RUNNER" report "$RUN_ID")"

# --- a run whose launch carried no hook says so -----------------------------------------------------
clear_stub
start_ok claudeb
jq 'del(.inbox_settings)' "$RUN_DIR/meta.json" >"$WORK/meta.unwired" && cp "$WORK/meta.unwired" "$RUN_DIR/meta.json"
said=$(WORKER_RUN_SAY_WAIT_S=0 "$RUNNER" say "$RUN_ID" 'unwired')
assert test "$said" = 'queued for RESUME: claudeb takes no message mid-run'
tool_call_done 1
await_done

# --- the hook: a subagent's tool call leaves the message for the session ----------------------------
printf '{"at":"2026-10-06T10:00:00+0000","by":"t","text":"for the session"}\n' >"$RUN_DIR/inbox"
: >"$RUN_DIR/inbox.new"
rm -f "$RUN_DIR/inbox.delivered"
subagent_out=$(printf '{"hook_event_name":"PostToolUse","agent_id":"a1"}' | WORKER_RUN_RECORD="$RUN_DIR" "$HOOK")
assert test -z "$subagent_out"
assert test -e "$RUN_DIR/inbox.new"
assert test ! -e "$RUN_DIR/inbox.delivered"

# --- an empty inbox costs no fork --------------------------------------------------------------------
mkdir -p "$WORK/forkspy"
for name in jq realpath find mkdir rmdir rm tail head wc tr date awk cat grep sed sleep touch stat; do
  printf '#!/bin/sh\necho %s >>"%s/forks"\n' "$name" "$WORK" >"$WORK/forkspy/$name"
  chmod +x "$WORK/forkspy/$name"
done
rm -f "$RUN_DIR/inbox.new"
: >"$WORK/forks"
assert test -z "$(printf '{}' | PATH="$WORK/forkspy" WORKER_RUN_RECORD="$RUN_DIR" "$HOOK" 2>&1)"
assert test -z "$(printf '{}' | env -u WORKER_RUN_RECORD PATH="$WORK/forkspy" "$HOOK" 2>&1)"
assert test ! -s "$WORK/forks"
: >"$RUN_DIR/inbox.new"
printf '{}' | PATH="$WORK/forkspy" WORKER_RUN_RECORD="$RUN_DIR" "$HOOK" >/dev/null 2>&1
assert test -s "$WORK/forks"

# --- codex: no mid-run channel, so the message rides the session's next RESUME ----------------------
clear_stub
unset TOOL_CALLS
start_gated codex
said=$("$RUNNER" say "$RUN_ID" 'also cover the empty case')
assert test "$said" = 'queued for RESUME: codex takes no message mid-run'
gate_open
await_done
first_run=$RUN_ID
assert grep -q '— queued for RESUME: codex takes no message mid-run$' <<<"$("$RUNNER" report "$first_run")"
late_rc=0
"$RUNNER" say "$first_run" 'after the end' >/dev/null 2>&1 || late_rc=$?
assert test "$late_rc" -eq 4
printf 'RESUME codex-session: continue\n' >"$WORK/resume-brief"
"$RUNNER" start codex --brief "$WORK/resume-brief" --workdir "$WORK/workdir" --account fast \
  >"$WORK/start.out" 2>"$WORK/start.err" || fail "resume start failed: $(<"$WORK/start.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
await_done
assert test "$(grep -c 'Message from the chat that launched you (.*): also cover the empty case' "$STUB_DIR/codex.stdin")" -eq 1
assert grep -q '^RESUME codex-session: continue$' "$STUB_DIR/codex.stdin"
assert grep -qF "— delivered at " <<<"$("$RUNNER" report "$first_run")"
assert grep -qF " via RESUME $RUN_ID" <<<"$("$RUNNER" report "$first_run")"
"$RUNNER" start codex --brief "$WORK/resume-brief" --workdir "$WORK/workdir" --account fast \
  >"$WORK/start.out" 2>"$WORK/start.err" || fail "second resume start failed: $(<"$WORK/start.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
await_done
assert_fails grep -q 'also cover the empty case' "$STUB_DIR/codex.stdin"

# --- `say <text>` reaches the one live run of this chat ---------------------------------------------
clear_stub
none_rc=0
CLAUDE_CODE_SESSION_ID=chat-without-runs "$RUNNER" say 'nobody' >/dev/null 2>"$WORK/say-none.err" || none_rc=$?
assert test "$none_rc" -eq 4
assert grep -qF 'no live worker run of this chat' "$WORK/say-none.err"
start_gated codex
one_run=$RUN_ID
said=$("$RUNNER" say 'only you')
assert test "$said" = 'queued for RESUME: codex takes no message mid-run'
assert grep -qF '"text":"only you"' "$WORKER_RUN_DIR/$one_run/inbox"
start_ok codex
two_run=$RUN_ID
several_rc=0
"$RUNNER" say 'which one' >/dev/null 2>"$WORK/say-several.err" || several_rc=$?
assert test "$several_rc" -eq 4
assert grep -qF '2 live worker runs of this chat' "$WORK/say-several.err"
assert grep -q "^$one_run  " "$WORK/say-several.err"
assert grep -q "^$two_run  " "$WORK/say-several.err"
assert_fails grep -q 'which one' "$WORKER_RUN_DIR/$one_run/inbox"
assert test ! -e "$WORKER_RUN_DIR/$two_run/inbox"
gate_open
await_done
RUN_ID=$one_run
await_done

echo "PASS: $asserts asserts; worker-run say: hook wired per claudeb launch, delivery once at the next tool call, RESUME carry, finished-run refusal, chat-scoped say, no fork on an empty inbox"
