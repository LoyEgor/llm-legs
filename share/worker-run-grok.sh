# worker-run, grok launches, outcomes, transcripts and progress rows; sourced by bin/worker-run in place, so
# an edit here runs its own suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

grok_home() {
  if [ "$1" = main ]; then
    printf '%s/.grok' "$HOME"
  else
    printf '%s/%s' "${GROKB_PROFILES_DIR:-$HOME/.grok-profiles}" "$1"
  fi
}

# Where the spawned instance keeps its own transcript: claudeb files it under the profile's projects
# tree named by session id, codex under the profile's sessions tree with the id inside the filename,
# agy under the profile's brain tree named by conversation id — deterministic from the id the run's
# own log already gave up, so nothing here searches for it.
# Grok files a session under the URL-encoded cwd it ran in, so an id found by globbing can belong
# to a session from another directory entirely: the session's own summary.json names that cwd, and
# the encoded directory name answers when the summary is missing. Asked without a workdir — a
# caller that only wants the file — nothing is verified.
grok_session_dir_matches() { # session-dir workdir
  local directory="$1" workdir="$2" recorded
  [ -n "$workdir" ] && [ "$workdir" != null ] || return 0
  recorded=$(jq -r '.info.cwd // empty' "$directory/summary.json" 2>/dev/null)
  if [ -n "$recorded" ]; then
    [ "${recorded%/}" = "${workdir%/}" ]
    return
  fi
  recorded=${directory%/*}
  recorded=${recorded##*/}
  recorded=$(printf '%b' "${recorded//%/\\x}" 2>/dev/null) || return 1
  [ "${recorded%/}" = "${workdir%/}" ]
}

# Grok has no read-only mode, so a research run gets the gemini research leg's write-deny sandbox.
supervise_grok() {
  local directory="$1" meta="$1/meta.json" account model effort resume cli turns rc served denied search_arg
  local research=false sandbox_exec profile
  local -a command
  if [ "$(jq -r '.role // "workers"' "$meta")" = research ]; then
    research=true
    . "$SCRIPT_DIRECTORY/../share/light-research.sh"
    research_sandbox_ready "$directory" grok || return $?
  fi
  account=$(jq -r '.account' "$meta")
  model=$(jq -r '.model' "$meta")
  effort=$(jq -r '.effort' "$meta")
  resume=$(jq -r '.resume' "$meta")
  cli=$(jq -r '.cli' "$meta")
  turns=$(jq -r '.max_turns // empty' "$meta")
  # GROK_MEMORY=0 rather than a flag: `--no-memory` was dropped in 1.0.13, and a worker inheriting
  # the profile's memory would carry another task's notes into this brief.
  command=(env GROK_MEMORY=0 "$cli" profile "$account" --prompt-file "$directory/brief.launch"
    --output-format streaming-json --always-approve --cwd "$(jq -r '.workdir' "$meta")"
    --no-subagents --reasoning-effort "$effort")
  [ -z "$turns" ] || command+=(--max-turns "$turns")
  [ "$model" = auto ] || command+=(-m "$model")
  # `-r` resumes; `-s` only ever CREATES and rejects an id that already exists (live 1.0.13).
  [ -z "$resume" ] || command+=(-r "$resume")
  while IFS= read -r search_arg; do command+=("$search_arg"); done < <(web_search_args grok "$(web_search_meta_state "$meta")")
  [ "$research" = false ] || command=("$sandbox_exec" -p "$profile" "${command[@]}")
  run_with_deadline "${command[@]}" >"$directory/out" 2>"$directory/err"
  rc=$?
  if [ "$research" = true ]; then
    if grep -Eq '^sandbox-exec:' "$directory/err"; then
      research_failure "$directory" GROK_UNAVAILABLE 4; return $?
    fi
    # The sandbox keeps the tree whole; a write tool it refused is the run ignoring its fence.
    if jq -seR '[split("\n")[] | fromjson? | objects] as $events
               | [$events[] | select(.type == "tool_call" and (.kind | IN("write", "edit"))) | .toolCallId] as $writes
               | any($events[]; .type == "tool_call_update" and .status == "failed"
                     and (.toolCallId | IN($writes[]))
                     and ([.. | strings] | any(test("Operation not permitted"))))' "$directory/out" >/dev/null; then
      printf 'research: the sandbox denied a write of this read-only grok run; web sources belong inline in the answer\n' >>"$directory/err"
      research_failure "$directory" READ_ONLY_VIOLATION 5; return $?
    fi
  fi
  served=$(grok_end_field "$directory" 'tojson' | served_model_from_envelope /dev/stdin "$model")
  [ -z "$served" ] || meta_update "$directory" '.served_model = $model' --arg model "$served" || :
  # A tool the permission policy refused is neither a wall nor a failed run — 1.0.13 ends such a run
  # normally with exit 0 — but it is the one thing a reader of a thin result needs to know about.
  # Counted off the denial EVENT, never the phrase: the CLI states a policy denial once, in the
  # failed tool_call_update, and the agent then quotes that same sentence back in its own answer
  # (live-caught) — so a grep over the stream double-counts a real denial, and reports one for a
  # brief that merely discusses them.
  denied=$(jq -rR 'fromjson?
                   | select(type == "object" and .type == "tool_call_update" and .status == "failed")
                   | select([.content[]? | .. | strings]
                            | any(test("was not executed: Denied by permission policy")))
                   | .toolCallId' "$directory/out" 2>/dev/null | wc -l | tr -d '[:space:]')
  [[ "$denied" =~ ^[0-9]+$ ]] || denied=0
  [ "$denied" -eq 0 ] || meta_update "$directory" '.denied_tools = $n' --argjson n "$denied" || :
  return "$rc"
}

# One field off the streaming run's terminal `end` event. Read with fromjson? so a truncated line
# in a killed run's stream is skipped rather than voiding the whole read.
grok_end_field() { # directory jq-expression
  jq -rR "fromjson? | select(type == \"object\" and .type == \"end\") | $2" "$1/out" 2>/dev/null |
    sed '/^$/d' | tail -n1
}

# Grok's PERSISTENT wall wording, and nothing else. The CLI folds capacity weather (429, 5xx,
# Retry-After) into the same internal `rate_limit` class as a real wall, so a bare "rate limit" here
# would report an exhausted plan every time xAI has a bad minute.
GROK_LIMIT_RE="hit the rate limit for your plan|hit the credit limit for your plan|subscription:free-usage-exhausted|run out of credits|you['’]ve reached your free Grok Build usage limit for now|(status|http)[^0-9]{0,12}402([^0-9]|$)|402 payment required"
GROK_AUTH_RE='not signed in|credentials were rejected|session has expired'
GROK_TRANSIENT_RE='(status|http)[^0-9]{0,12}(429|5[0-9][0-9])([^0-9]|$)|too many requests|gateway timeout|retry-after|service unavailable|overloaded'

# Where a grok failure states itself: stderr, plus the `error` events of the stream — the CLI puts a
# startup failure on stderr alone (the `-s` collision) and a mid-run one in an event on stdout. The
# agent's own answer text is left out on purpose: this repository's briefs discuss quotas and 429s.
grok_stream_errors() { # directory [bytes]
  if [ -n "${2:-}" ]; then tail -c "$2" "$1/out" 2>/dev/null; else cat "$1/out" 2>/dev/null; fi |
  jq -rR 'fromjson? | select(type == "object" and (.type == "error" or .type == "max_turns_reached"))
          | tostring' 2>/dev/null
}

grok_error_text() { # directory [bytes]
  if [ -n "${2:-}" ]; then tail -c "$2" "$1/err" 2>/dev/null; else cat "$1/err" 2>/dev/null; fi
  grok_stream_errors "$@"
}

# A turn cap the run hit is the vendor answering fine to the last turn. Read as GROK_UNAVAILABLE it
# joins capacity weather, and the chat reroutes a brief that will outrun the same cap wherever it
# lands next.
grok_max_turns_hit() { # directory
  grok_error_text "$1" | grep -q 'max_turns_reached'
}

# Grok refuses a NEW session under load by ending it before its first turn: the handshake events,
# then `end` with `stopReason: cancelled`, exit 0 and an empty stderr. Exit 0 alone reads as a
# finished run, so the orchestrator was handed an empty result as `STATUS: done` (live 2026-09-08,
# five runs across two accounts while their older sessions kept streaming). It is weather like a
# 503: no wall is recorded, no pin lapses, and the chat relaunches. The FIRST
# event that is a turn or the end decides — a cancel after real work is an ordinary ending.
grok_cancelled_start() { # directory
  local first
  first=$(jq -rR 'fromjson? | select(type == "object") |
    if .type == "end" then "end:" + ((.stopReason // "") | ascii_downcase)
    elif .type == "text" or .type == "thought" or .type == "assistant" or
         ((.type // "") | startswith("tool_call")) then "turn"
    else empty end' "$1/out" 2>/dev/null | head -n1)
  case "$first" in end:cancelled | end:canceled) return 0 ;; esac
  return 1
}

# Which kind of not-a-wall a grok failure was, said where the chat reads its outcome: an expired
# login needs a human, capacity weather needs nothing but another attempt.
grok_reason_line() { # directory
  local text
  text=$(grok_error_text "$1")
  if grep -q 'max_turns_reached' <<<"$text"; then
    printf 'REASON: max-turns — the brief outran --max-turns (%s); the vendor answered fine, so relaunching it whole buys nothing\n' \
      "$(jq -r '.max_turns // "?"' "$1/meta.json" 2>/dev/null)"
  elif grep -Eiq "$GROK_AUTH_RE" <<<"$text"; then
    printf 'REASON: auth — the account needs a human login (grokb add <account>)\n'
  elif grep -Eiq "$GROK_TRANSIENT_RE" <<<"$text"; then
    printf 'REASON: transient — capacity weather, not a wall; the brief may be relaunched\n'
  fi
}

# Grok's own per-session record. One update line per event, so a call's identity is spread across
# them: the `tool_call` names the tool and carries its arguments, and the `tool_call_update` lines
# that follow carry the terminal status and the directory a shell command actually ran in — folded
# back together by toolCallId here. The tool's own `x.ai/tool` metadata classifies it (`kind`,
# `read_only`), never a name whitelist: a tool added by an update reads as unknown and leaves the
# run UNKNOWN, which is the answer a reader can act on. Lines are parsed individually so the
# partial last line of a live session does not void the whole read.
grok_tool_rows() { # updates since
  jq -rRs --argjson since "$2" '
    [split("\n")[] | select(length > 0) | fromjson? | select(type == "object")] as $all
    | reduce $all[] as $row ({};
        ($row.params.update // {}) as $update
        | ($update._meta["x.ai/tool"] // {}) as $tool
        | ($update.toolCallId // "") as $id
        | if $id == "" then .
          else .[$id] = ((.[$id] // {})
            + (if $update.sessionUpdate == "tool_call" or ((.[$id].name // "") == "" and ($tool.name // "") != "") then
                 {name: ($tool.name // ""), kind: ($tool.kind // ""),
                  read_only: ($tool.read_only // false), input: ($update.rawInput // {})}
               else {} end)
            + (if (.[$id].t // null) == null then {t: ($row.timestamp // null)} else {} end)
            + (if ($update.status // null) != null then {status: ($update.status | tostring | ascii_downcase)} else {} end)
            + (if (($update.rawOutput // {}).current_dir // "") != "" then {dir: $update.rawOutput.current_dir} else {} end))
          end)
    | to_entries[]
    | .value as $call
    | ($call.name // "") as $name
    | ($call.kind // "") as $kind
    | ($call.status // "") as $status
    | ($call.input // {}) as $args
    | ($call.t) as $t
    | [if $call.read_only == true or $name == "search_tool" or $kind == "plan" then empty
       elif ($kind | IN("write", "edit")) then
         if $status == "completed" then
           "F\t" + (($args.file_path // $args.path // $args.absolute_path // "") | tostring)
         elif ($status | IN("failed", "cancelled", "canceled", "rejected", "error")) then empty
         else "X\t" + $name + " outcome" end
       elif $kind == "execute" then
         ("C\t" + (($args.command // "") | tostring | gsub("[\n\r\t]"; " "))),
         (if ($call.dir // "") != "" then "D\t" + $call.dir else empty end)
       elif $name == "use_tool" then
         (($args.tool_name // "") | tostring | ascii_downcase) as $dispatched
         | if ($dispatched | IN("bash", "run_terminal_command", "shell")) then
             ("C\t" + ((($args.tool_input // {}).command // "") | tostring | gsub("[\n\r\t]"; " "))),
             (if ($call.dir // "") != "" then "D\t" + $call.dir else empty end)
           else "X\tuse_tool " + $dispatched end
       else "X\t" + (if $name == "" then "unnamed tool" else $name end) end] as $classified
    | if $t == null then
        if ($classified | length) > 0 then "T\tunparseable" else empty end
      elif $t < $since then empty
      else $classified[]
      end' "$1" 2>/dev/null
}

# The agent's answer, reassembled out of the stream: `text` events carry it in chunks, and a raw
# NDJSON tail is the one shape no reader of a report can use. The raw tail stands in where not one
# chunk parsed, so a stream that broke early is still visible.
grok_result_text() { # directory
  local text
  text=$(jq -jR 'fromjson? | select(type == "object" and .type == "text") | (.data // .text // "")' \
    "$1/out" 2>/dev/null)
  if [ -n "$text" ]; then printf '%s\n' "$text"; else tail -n 400 "$1/out" 2>/dev/null; fi
}

# A message arrives as consecutive chunks; each call once, by its first `tool_call` line.
grok_progress_rows() { # updates since
  jq -rRs --argjson since "$2" '
    [split("\n")[] | select(length > 0) | fromjson? | select(type == "object")]
    | reduce .[] as $row ({rows: [], seen: {}};
        ($row.params.update // {}) as $u
        | ($u.toolCallId // "") as $id
        | if $u.sessionUpdate == "agent_message_chunk" then
            if (.rows[-1].open // false) then .rows[-1].text += ($u.content.text // "" | tostring)
            else .rows += [{open: true, t: $row.timestamp, text: ($u.content.text // "" | tostring)}] end
          else
            (if (.rows | length) > 0 then .rows[-1].open = false else . end)
            | if $u.sessionUpdate == "tool_call" and ($id == "" or (.seen[$id] | not)) then
                .seen[$id] = true
                | .rows += [{t: $row.timestamp, tool: ($u._meta["x.ai/tool"] // {}), in: ($u.rawInput // {})}]
              else . end
          end)
    | .rows[] | select((.t | numbers) >= $since)
    | if has("text") then ["M", .text]
      elif (.tool.kind // "" | IN("write", "edit")) then ["F", (.in.file_path // .in.path // .in.absolute_path // "")]
      elif .tool.kind == "execute" then ["C", (.in.command // "")]
      else ["X", ((.tool.name // "tool") + " " + ([.in | objects | .[] | strings] | first // ""))] end
    | .[0] + "\t" + (.[1] | tostring | gsub("[\n\r\t]+"; " ") | sub(" +$"; ""))' "$1" 2>/dev/null
}

# Grok names its session only on the terminal `end` event: until then a run's session is the one
# it resumed, else the first one created in its workdir since it started.
grok_live_session() { # account workdir started resume
  [ -z "$4" ] || { printf '%s' "$4"; return 0; }
  local summaries=("$(grok_home "$1")/sessions/"*/*/summary.json)
  [ -f "${summaries[0]}" ] || return 1
  jq -r --arg cwd "${2%/}" --argjson since "$3" '
    select((.info.cwd // "" | rtrimstr("/")) == $cwd)
    | (try ((.created_at // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) as $t
    | select($t != null and $t >= $since) | "\($t) \(.info.id)"' "${summaries[@]}" 2>/dev/null |
    sort -n | awk 'NR == 1 { print $2 }' | grep .
}
