#!/usr/bin/env bash
# Canned `grokb profile <account> <grok args...>`: the streaming-json shapes of the live Grok Build
# CLI 1.0.13 pre-test, driven by files in $STUB_DIR so the detached supervisor (whose env froze at
# launch) can be steered between attempts.
{
  printf 'GROK_CALL\n'
  printf 'GROK_MEMORY=%s\n' "${GROK_MEMORY-__unset__}"
  printf 'ARG=%q\n' "$@"
} >>"$CALL_LOG"

account=main
[ "${1:-}" != profile ] || account=${2:-main}

# The real CLI reads the brief off disk instead of stdin, so a lost or empty brief would otherwise
# produce a perfectly successful run — the same trap the claudeb stub guards for --print.
prompt_file=''
argument_previous=''
for argument in "$@"; do
  case "$argument" in
    --prompt-file=*) prompt_file=${argument#*=} ;;
    *) [ "$argument_previous" != --prompt-file ] || prompt_file=$argument ;;
  esac
  argument_previous=$argument
done
if [ -n "$prompt_file" ] && [ ! -s "$prompt_file" ]; then
  printf 'Error: prompt file %s is empty or missing\n' "$prompt_file" >&2
  exit 1
fi

session=${STUB_GROK_SESSION:-01a05811-7788-7d22-a9c9-c028072cbff5}
created=''
previous=''
for argument in "$@"; do
  [ "$previous" != -r ] || session="$argument"
  [ "$previous" != -s ] || created="$argument"
  previous="$argument"
done

end_event() { # session
  printf '{"type":"end","stopReason":"end_turn","sessionId":"%s","requestId":"7f6f0635-b3f9-43ea-97ba-61822ae955ca","usage":{"input_tokens":17834,"cache_read_input_tokens":11520,"cache_creation_input_tokens":0,"output_tokens":275,"reasoning_tokens":123,"total_tokens":29629},"num_turns":2,"total_cost_usd":0.00732326,"total_cost_usd_ticks":73232600,"modelUsage":{"%s":{"inputTokens":17834,"outputTokens":275,"cacheReadInputTokens":11520,"cacheCreationInputTokens":0,"modelCalls":2,"costUSD":0.00732326}}}\n' \
    "$1" "${STUB_GROK_MODEL:-grok-4.6-build}"
}

# `-s` only ever creates: the live CLI hands an existing id back on stderr with no JSON at all.
if [ -n "$created" ]; then
  printf 'Error: Error: Session ID %s is already in use.\n' "$created" >&2
  exit 1
fi

if [ -r "$STUB_DIR/grok_wall_accounts" ] && grep -qx "$account" "$STUB_DIR/grok_wall_accounts"; then
  printf 'Error: You have hit the credit limit for your plan.\n' >&2
  exit 1
fi
if [ -e "$STUB_DIR/grok_auth" ]; then
  printf 'Error: Not signed in. Run `grok login` to authenticate.\n' >&2
  exit 1
fi
if [ -e "$STUB_DIR/grok_transient" ]; then
  printf 'Error: request failed with status 503 Service Unavailable\n' >&2
  exit 1
fi

[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
[ -z "${STUB_ERROR:-}" ] || printf '%s\n' "$STUB_ERROR" >&2

if [ -e "$STUB_DIR/grok_denied" ]; then
  printf '%s\n' '{"type":"tool_call_update","toolCallId":"call-38833a75-42f4-4406-b8ea-1898b58a9f8e-0","status":"failed","content":[{"type":"content","content":{"type":"text","text":"Tool `run_terminal_command` was not executed: Denied by permission policy: deny rule on bash"}}],"rawOutput":null,"locations":[]}'
fi

if [ -e "$STUB_DIR/grok_max_turns" ]; then
  printf '{"type":"max_turns_reached","numTurns":%s}\n' "${STUB_GROK_TURNS:-60}"
  exit 1
fi

[ -z "${STUB_GROK_ERROR_EVENT:-}" ] || printf '{"type":"error","message":"%s"}\n' "$STUB_GROK_ERROR_EVENT"
[ -z "${STUB_GROK_ANSWER:-}" ] || printf '{"type":"text","data":"%s"}\n' "$STUB_GROK_ANSWER"

if [ "${STUB_CODE:-0}" -eq 0 ]; then
  printf '{"type":"thought","data":"planning"}\n'
  printf '{"type":"text","data":"grok "}\n'
  printf '{"type":"text","data":"result"}\n'
  end_event "$session"
fi
exit "${STUB_CODE:-0}"
