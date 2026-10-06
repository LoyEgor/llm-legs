# A worker run's mid-run messages, one path for every vendor. Sourced by bin/worker-run (`say`,
# report, the RESUME carry) and bin/worker-inbox-hook.sh (the in-session delivery).
#   <run>/inbox            one {at,by,text} JSON line per `worker-run say`
#   <run>/inbox.new        exists while a line may be untaken: the hook's whole empty-inbox cost is
#                          one stat of it
#   <run>/inbox.delivered  one "<end byte offset> <time> <via>" line per take, via = hook | resume:<run>
# Writers and takers hold `<run>/.claim.lock` (the mkdir lock worker-run and the tag hooks share).

inbox_now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# The claudeb launch's own `--settings`: the hook loads in worker sessions alone, never in a chat.
inbox_hook_settings() {
  local hook
  hook=$(realpath "${BASH_SOURCE[0]%/*}/../bin/worker-inbox-hook.sh") || return 1
  jq -cn --arg command "$(printf '%q' "$hook")" \
    '{hooks: {PostToolUse: [{matcher: "*", hooks: [{type: "command", command: $command}]}]}}'
}

# hook only where the run's own launch carried it; grok has no per-launch settings flag.
inbox_mode() { # directory
  if jq -e '.vendor == "claudeb" and (.inbox_settings // "") != ""' "$1/meta.json" >/dev/null 2>&1; then
    printf 'hook\n'
  else
    printf 'resume\n'
  fi
}

inbox_queued_text() { # vendor mode live(true|false)
  if [ "$3" = true ] && [ "$2" = hook ]; then
    printf 'queued: the worker reads it at its next tool call\n'
  elif [ "$2" = hook ]; then
    printf 'queued for RESUME: the run ended before its next tool call\n'
  else
    printf 'queued for RESUME: %s takes no message mid-run\n' "$1"
  fi
}

# Sets INBOX_TAKEN (the complete lines past the last take) and INBOX_END (their end offset); returns
# 1 when there are none. A line still being appended has no newline yet and waits for the next take.
inbox_pending() { # directory
  local LC_ALL=C directory="$1" last offset size chunk
  INBOX_TAKEN='' INBOX_END=0
  [ -s "$directory/inbox" ] || return 1
  last=$(tail -n1 "$directory/inbox.delivered" 2>/dev/null)
  offset=${last%% *}
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  size=$(wc -c <"$directory/inbox" | tr -d '[:space:]')
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$offset" ] || return 1
  chunk=$(tail -c +"$((offset + 1))" "$directory/inbox" | head -c "$((size - offset))"; printf x)
  chunk=${chunk%x}
  case "$chunk" in *$'\n'*) ;; *) return 1 ;; esac
  INBOX_TAKEN=${chunk%$'\n'*}$'\n'
  INBOX_END=$((offset + ${#INBOX_TAKEN}))
}

inbox_append() { # directory json-line — sets INBOX_APPENDED_END
  local LC_ALL=C size
  printf '%s\n' "$2" >>"$1/inbox" && : >"$1/inbox.new" || return 1
  size=$(wc -c <"$1/inbox" | tr -d '[:space:]')
  INBOX_APPENDED_END=$size
}

inbox_record() { # directory end via
  printf '%s %s %s\n' "$2" "$(inbox_now)" "$3" >>"$1/inbox.delivered"
}

inbox_context() { # taken-lines
  jq -Rrs 'split("\n") | map(select(length > 0) | (fromjson? // {at: "?", text: .})
    | "Message from the chat that launched you (\(.at)): \(.text)") | join("\n\n")' <<<"$1"
}

inbox_states() { # directory queued-text
  [ -s "$1/inbox" ] || return 0
  jq -rn --rawfile inbox "$1/inbox" --arg delivered "$(cat "$1/inbox.delivered" 2>/dev/null)" --arg queued "$2" '
    ($delivered | split("\n") | map(select(length > 0) | split(" ")
      | {end: (.[0] | tonumber? // 0), at: (.[1] // "?"), via: (.[2] // "hook")})) as $takes
    | foreach ($inbox | split("\n") | .[:-1][]) as $line ({end: 0};
        .end += ($line | utf8bytelength) + 1 | .line = $line)
    | .end as $end
    | (.line | fromjson? // {at: "?", by: "?", text: .}) as $m
    | ([$takes[] | select(.end >= $end)] | first) as $take
    | "MESSAGE: \($m.at) \($m.by // "?"): \($m.text | gsub("\n"; " ")) — "
      + if $take == null then $queued
        elif ($take.via | startswith("resume:")) then "delivered at \($take.at) via RESUME \($take.via[7:])"
        else "delivered at \($take.at)" end'
}

inbox_delivered_at() { # directory end
  awk -v end="$2" '$1 + 0 >= end + 0 { print $2; exit }' "$1/inbox.delivered" 2>/dev/null
}
