# A hook payload names the relay's own transcript or its parent's plus agent_id.

relay_transcript() { # transcript-path agent-id
  local id
  id=$(printf '%s' "$2" | tr -cd 'A-Za-z0-9_-')
  case "$1" in
    */subagents/*.jsonl) printf '%s\n' "$1" ;;
    *.jsonl) [ -z "$id" ] || printf '%s\n' "${1%.jsonl}/subagents/agent-$id.jsonl" ;;
  esac
}

relay_first_prompt() { # transcript-path agent-id
  local own
  own=$(relay_transcript "$1" "$2")
  [ -n "$own" ] && [ -r "$own" ] || return 0
  head -n 5 "$own" | jq -rR 'fromjson? | select(type == "object" and .type == "user") | .message.content
    | if type == "string" then . else ([.[]? | select(.type? == "text") | .text] | join("\n")) end' \
    2>/dev/null
}
