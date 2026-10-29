# worker-run, run file lists read from the vendors' transcripts; sourced by bin/worker-run in place, so an
# edit here runs its own suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

# agy's own per-conversation log, the only place it names the files it wrote. `transcript.jsonl`
# beside it carries the same rows with the tool_call ARGUMENTS stripped, so it can never answer
# this question — read the `_full` one or nothing.
GEMINI_WRITE_TOOLS='^(write_to_file|replace_file_content|multi_replace_file_content)$'

# Claude Code kills a foreground Bash call at BASH_MAX_TIMEOUT_MS; the worker sees exit 143 and may
# read it as a failing suite. bash-caps keeps the calls already journaled across persist passes.
record_bash_caps() { # directory
  local directory="$1" transcript started cap id command
  [ "$(jq -r '.vendor // empty' "$directory/meta.json" 2>/dev/null)" = claudeb ] || return 0
  { IFS= read -r transcript <"$directory/session-file"; } 2>/dev/null && [ -f "$transcript" ] || return 0
  grep -q 'Command timed out after' "$transcript" 2>/dev/null || return 0
  started=$(jq -r '.started_at // 0' "$directory/meta.json" 2>/dev/null)
  cap=$((IDLE > 900 ? IDLE - 300 : 600))
  while IFS=$'\t' read -r id command; do
    [ -n "$id" ] && ! grep -qxF -- "$id" "$directory/bash-caps" 2>/dev/null || continue
    printf '%s\n' "$id" >>"$directory/bash-caps" 2>/dev/null || :
    limit_hit worker-run.bash-cap "$cap" s kill "run ${directory##*/}: a foreground Bash call killed at the cap, its output and verdict: ${command:0:300}" \
      'bin/worker-run:BASH_MAX_TIMEOUT_MS=' "$cap"
  done < <(jq -rn --argjson since "${started:-0}" '[inputs | objects
      | select((((.timestamp? // "") | tostring | sub("\\.[0-9]+"; "")) | fromdateiso8601? // 0) >= $since)] as $rows
    | ([$rows[] | .. | objects | select(.type? == "tool_use" and .name? == "Bash")
        | {key: (.id // ""), value: ((.input.command? // "") | tostring)}] | from_entries) as $cmd
    | $rows[] | .. | objects | select(.type? == "tool_result")
    | select((.content? // "" | if type == "array" then map(.text? // "") | join(" ") else tostring end)
        | test("Command timed out after"))
    | [(.tool_use_id // ""), (($cmd[.tool_use_id // ""] // "") | gsub("[\t\n]"; " "))] | @tsv' "$transcript" 2>/dev/null)
  return 0
}

# The allowlist below treats test entry points as read-only; unclassified shell programs are a floor.
SHELL_FLOOR_PARTIAL='the run also ran shell commands, whose edits no transcript records'

writes_through_shell() { # the JSON-encoded command lines on fd 3: 0 once any writes, 1 none, 2 unparsable
  # WRITES_FIRST_RAW=1: raw command lines on fd 3; prints the 1-based index of the first that writes, 0 for none.
  python3 - <<'PY'
import json
import os
import re
import shlex
import sys


def writes(command):
    # Empty is a poll (codex write_stdin chars:""), not an unclassified write.
    if command == "":
        return False
    # A command substitution runs a program the words around it never show, and a heredoc feeds one; a variable
    # in an argument is read as the word it names (a flag smuggled in through one is not how a worker writes).
    # Taken as writes, `$` and `\` made codex's opening CLAUDE.md lookup loop a write in 99 of 295 runs, each
    # losing its whole file list (30 days to 2026-10-29).
    if not command.strip() or any(token in command for token in ("$(", "`", "<<")):
        return True
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>\n()")
        lexer.whitespace = " \t\r"
        # shlex's comment reader consumes the newline that separates the next command.
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        return True

    # The words that frame a compound command run nothing: the commands between them are judged one by one,
    # wherever they stand, since a transcript row arrives with its newlines turned into spaces.
    frame = {"do", "done", "then", "else", "elif", "fi", "if", "while", "until", "!", "{", "}"}

    def readonly(words):
        segment = []
        for word in words + ["done"]:
            if word not in frame:
                segment.append(word)
            elif not simple(segment):
                return False
            else:
                segment = []
        return True

    def simple(words):
        if not words:
            return True
        name, *args = words
        if not args and re.fullmatch(r"[A-Za-z_]\w*=.*", name):
            # A bare assignment sets a shell variable; one prefixed to a command (GIT_EXTERNAL_DIFF=...) is no read.
            return True
        name = re.sub(r"^/(?:usr/)?bin/", "", name)
        if name == "command":
            return bool(args) and args[0] in {"-v", "-V"}
        if name == "for":
            # `for NAME [in WORDS]` only sets the loop variable; its body is the next segment.
            return bool(args) and re.fullmatch(r"[A-Za-z_]\w*", args[0]) is not None and (len(args) == 1 or args[1] == "in")
        if name in {"bash", "sh", "python3"}:
            return len(args) == 1 and ".." not in args[0].split("/") and re.fullmatch(r"(?:\./)?tests/[\w./-]+\.(?:sh|py)", args[0]) is not None
        if name == "git":
            while args and args[0] in {"-C", "--no-pager"}:
                args = args[2:] if args[0] == "-C" else args[1:]
            return bool(args) and args[0] in {"diff", "status", "show", "log", "ls-files", "rev-parse", "grep", "ls-tree",
                                              "cat-file", "blame", "rev-list", "merge-base", "show-ref", "describe"} and not any(
                arg.startswith(("--output", "--ext-diff", "--textconv", "--filters", "-O", "--open-files-in-pager")) for arg in args)
        if name == "sed":
            return len(args) >= 2 and args[0] == "-n" and re.fullmatch(r"[0-9]+(?:,[0-9]+)?p", args[1]) is not None and not any(arg.startswith("-") for arg in args[2:])
        if name in {"grep", "egrep", "fgrep", "rg"}:
            return not any(arg.startswith(("--pre", "--hostname-bin")) for arg in args)
        if name == "find":
            return not any(arg in {"-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"} for arg in args)
        if name == "sort":
            return not any(arg.startswith(("--output", "--compress-program")) or re.fullmatch(r"-[A-Za-z]*o.*", arg) for arg in args)
        if name == "uniq":
            # `uniq IN OUT` writes OUT.
            return len([arg for arg in args if not arg.startswith("-")]) <= 1
        return name in {"cat", "head", "tail", "wc", "pwd", "ls", "stat", "readlink", "basename", "dirname", "echo", "printf",
                        "true", "false", "test", "[", "[[", "cd", "nl", "cut", "tr", "jq", "diff", "cmp", "comm", "du", "df",
                        "which", "type", "date", "shasum", "md5", "realpath", "uname", "whoami", "id", "read", "sleep"}

    words = []
    tokens = iter(tokens + [";"])
    for token in tokens:
        if token in {">", ">>", ">&"}:
            target = next(tokens, "")
            if (token in {">", ">>"} and target == "/dev/null") or (token == ">&" and target in {"1", "2"}):
                if words and words[-1].isdigit():
                    words.pop()
                continue
            return True
        if token == "<":
            # An input redirect only reads its file.
            next(tokens, "")
            continue
        if token in {";", "&&", "||", "|", "\n"}:
            if not readonly(words):
                return True
            words = []
        elif set(token) <= set(";&|<>()\n"):
            return True
        else:
            words.append(token)
    return False


if os.environ.get("WRITES_FIRST_RAW"):
    with open(3, encoding="utf-8", errors="surrogateescape", newline="\n") as lines:
        print(next((index for index, line in enumerate(lines, 1) if writes(line.rstrip("\n"))), 0))
    sys.exit(0)
try:
    with open(3, encoding="utf-8", errors="replace") as lines:
        found = any(writes(json.loads(line).replace("\0", "").rstrip("\n")) for line in lines if line.strip())
except ValueError:
    sys.exit(2)
sys.exit(0 if found else 1)
PY
}

resolve_tool_path() { # path workdir
  local value="$1" workdir="$2" part joined='' index
  local -a parts resolved
  if [[ "$value" != /* ]]; then
    [ -n "$workdir" ] && [ "$workdir" != null ] || { printf '%s\n' "$value"; return 0; }
    value="${workdir%/}/$value"
  fi
  IFS='/' read -ra parts <<<"${value#/}"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        if [ "${#resolved[@]}" -gt 0 ]; then
          index=$((${#resolved[@]} - 1))
          unset "resolved[$index]"
        fi
        ;;
      *) resolved+=("$part") ;;
    esac
  done
  for part in "${resolved[@]}"; do joined+="/$part"; done
  printf '%s\n' "${joined:-/}"
}

classify_tool_rows() { # rows workdir
  local rows="$1" workdir="$2" line tag value paths='' places='' inside=0 outside='' dir='' commands='' first
  local unexpanded_target_re='(^|/)(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\}|`[^`]+`)(/|$)'
  [ -z "$workdir" ] || [ "$workdir" = null ] || dir="${workdir%/}/"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tag=${line:0:1}
    value=${line:2}
    case "$tag" in
      F)
        if [ -z "$value" ]; then
          [ -n "$RUN_FILES_REASON" ] ||
            RUN_FILES_REASON='the transcript records a write whose target it does not name'
          continue
        fi
        if [[ "$value" =~ $unexpanded_target_re ]]; then
          [ -n "$RUN_FILES_PARTIAL" ] ||
            RUN_FILES_PARTIAL="the run named a target the transcript cannot resolve: $value"
          continue
        fi
        value=$(resolve_tool_path "$value" "$workdir")
        paths+="$value"$'\n'
        places+="$value"$'\n'
        ;;
      C)
        [ -n "$value" ] || continue
        # Classified once after the loop, one python3 for the window: each comes before any reason set so far.
        [ -n "$RUN_FILES_REASON" ] || commands+="$value"$'\n'
        ;;
      D)
        [ -z "$value" ] || places+="$(resolve_tool_path "$value" "$workdir")"$'\n'
        ;;
      X)
        [ -n "$RUN_FILES_REASON" ] ||
          RUN_FILES_REASON="the transcript records a call whose file targets it does not name: $value"
        ;;
      T)
        [ -n "$RUN_FILES_REASON" ] ||
          RUN_FILES_REASON='the transcript records a mutating context with an unparseable timestamp'
        ;;
    esac
  done <<<"$rows"
  # A shell write makes the list a floor, as it does a claudeb run's: the editor calls it names are the run's
  # for certain, and what the shell wrote is left to the UNNAMED claim beside them. Read as an UNKNOWN it threw
  # those away too (19 codex runs in 30 days to 2026-10-29). A failed classifier is a write.
  if [ -n "$commands" ]; then
    first=$(WRITES_FIRST_RAW=1 writes_through_shell 3<<<"${commands%$'\n'}") && [[ $first =~ ^[0-9]+$ ]] || first=1
    [ "$first" = 0 ] || [ -n "$RUN_FILES_PARTIAL" ] || RUN_FILES_PARTIAL="$SHELL_FLOOR_PARTIAL"
  fi
  # Live-reproduced 2026-08-24: handed a workdir agy does not trust, agy worked in the first
  # --add-dir instead and said nothing — every path it touched was somewhere else entirely. Not
  # "a path outside the workdir", which is ordinary (a worker reads ~/.claude, writes /tmp): the
  # signal is that NOTHING it named is inside, which no run doing its actual job ever looks like.
  if [ -n "$dir" ] && [ -n "$places" ]; then
    while IFS= read -r value; do
      [ -n "$value" ] || continue
      case "$value" in
        "$dir"*|"${dir%/}") inside=$((inside + 1)) ;;
        *) [ -n "$outside" ] || outside="$value" ;;
      esac
    done <<<"$places"
    [ "$inside" -ne 0 ] || [ -z "$outside" ] || { RUN_FILES_ESCAPE="$outside"; RUN_FILES_OUTSIDE=$places; }
  fi
  [ -z "$RUN_FILES_REASON" ] || return 0
  RUN_FILES_LIST=$(AWK_DIR=$dir awk \
    'BEGIN { dir = ENVIRON["AWK_DIR"] }
     { if (dir != "" && index($0, dir) == 1) $0 = substr($0, length(dir) + 1) } NF' \
    <<<"$paths" | sort -u)
  return 0
}

gemini_tool_rows() { # transcript since
  jq -rs --argjson since "$2" --arg writes "$GEMINI_WRITE_TOOLS" '
    def epoch(value):
      try ((value | tostring | sub("\\.[0-9]+(?=Z$)"; "")) | fromdateiso8601) catch null;
    def write_tool: test($writes);
    def read_tool: test("^(read_file|view_file|list_dir|find_by_name|grep_search|search_web|read_url_content|manage_task|schedule|send_message|ask_question|list_permissions)$");
    def succeeded: tostring | ascii_upcase | test("^(DONE|SUCCESS|SUCCEEDED)$");
    def failed: tostring | ascii_upcase | test("^(FAILED|FAILURE|ERROR|CANCELLED|CANCELED|REJECTED)$");
    . as $rows
    | to_entries[]
    | .key as $index
    | .value as $row
    | ($rows[$index + 1] // {}) as $execution
    | epoch($row.created_at? // "") as $t
    | [$row.tool_calls[]?
        | (.name? // "") as $name
        | (.args? // {}) as $args
        | if ($name | write_tool) then
            if ($execution.type? == "CODE_ACTION" and ($execution.status? | succeeded)) then
              "F\t" + (($args.TargetFile? // "") | tostring)
            elif ($execution.type? == "CODE_ACTION" and ($execution.status? | failed)) then empty
            else "X\t" + $name + " outcome" end
          elif $name == "run_command" then
            ("C\t" + (($args.CommandLine? // "") | tostring | gsub("[\n\r\t]"; " "))),
            ("D\t" + (($args.Cwd? // "") | tostring))
          elif ($name | read_tool) then empty
          else "X\t" + $name
          end
      ] as $classified
    | if $t == null then
        if ($classified | length) > 0 then "T\tunparseable" else empty end
      elif $t < $since then empty
      else $classified[]
      end' "$1" 2>/dev/null
}

# codex names its edits twice over and neither alone is complete: the `patch_apply_end` event holds
# the changed paths of a patch that applied, and the call itself holds the patch TEXT, whose
# `*** ... File:` headers name targets for the runs whose events are missing (both gaps live-measured
# over the local rollout corpus). The union is what the run answers with. Its shell arrives as JSON
# inside the harness call — one `"cmd"` field per command, whatever wrapper carries it — and the JS
# `exec` tool is a dispatcher, so what it dispatched TO is the tool that must be classified.
codex_tool_rows() { # rollout since
  jq -rs --argjson since "$2" '
    def epoch(value):
      try ((value | tostring | sub("\\.[0-9]+(?=Z$)"; "")) | fromdateiso8601) catch null;
    def targets(text):
      ([text | scan("\\*\\*\\* (?:Update|Add|Delete) File: [^\"\\\\\r\n]+")
             | sub("^\\*\\*\\* (?:Update|Add|Delete) File: "; "")]
       + [text | scan("\\*\\*\\* Move to: [^\"\\\\\r\n]+")
              | sub("^\\*\\*\\* Move to: "; "")])
      | map(gsub("\\r$"; ""));
    def js_mask:
      gsub("(?<m>\"(?:\\\\.|[^\"\\\\])*\"|\\x27(?:\\\\.|[^\\x27\\\\])*\\x27|`(?:\\\\.|[^`\\\\])*`|//[^\\r\\n]*|/\\*(?:[^*]|\\*+[^*/])*\\*+/)"; " " * (.m | length));
    def exec_tools(text):
      [text | js_mask | scan("\\btools\\.[A-Za-z_][A-Za-z_0-9]*\\s*\\(")
            | sub("^tools\\."; "") | sub("\\s*\\($"; "")];
    def js_literal(text; pos):
      (text[pos:] | sub("^\\s+"; "")) as $rest
      | ($rest[0:1]) as $quote
      | (if $quote == "`" then "`(?:\\\\.|[^`\\\\])*`"
         elif $quote == "\u0027" then "\\x27(?:\\\\.|[^\\x27\\\\])*\\x27"
         elif $quote == "\"" then "\"(?:\\\\.|[^\"\\\\])*\""
         else null end) as $shape
      | if $shape == null then null
        else ([$rest | match("^" + $shape)] | first | .string) as $literal
          | if $literal == null or ($quote == "`" and ($literal | test("\\$\\{"))) then null
            else $literal[1:-1] end
        end;
    # One state per call, in source order, so a value never pairs with another call. js_mask keeps the
    # masked text the same LENGTH as the raw text, so every offset below indexes both: a match found
    # in the mask (where no string or comment can fake one) reads its value out of the raw text.
    def key_states(text; tools; key):
      (text | js_mask) as $mask
      | [$mask | match("\\b(?:const|let|var)\\s+" + key + "\\s*="; "g")
             | (.offset + .length) as $at
             | {at: $at, value: js_literal(text; $at)}] as $bindings
      | [$mask | match("\\btools\\.(?:" + tools + ")\\s*\\(\\s*\\{[^{}]*\\}"; "g")
             | {start: .offset, end: (.offset + .length)}]
      | map(. as $call
          | [text[$call.start:$call.end]
             | match("(?:\"" + key + "\"|\\b" + key + "\\b)\\s*(?<colon>:)\\s*"; "g")
             | select($mask[($call.start + .captures[0].offset):($call.start + .captures[0].offset + 1)] == ":")
             | ($call.start + .offset + .length)] as $explicit
          | if ($explicit | length) > 0 then
              ([$explicit[] | js_literal(text; .)] | map(select(. != null))) as $values
              | if ($values | length) > 0 then {state: "value", value: $values[0]}
                else {state: "unresolved"} end
            elif ($mask[$call.start:$call.end] | test("(?:\\{|,)\\s*" + key + "\\s*(?:,|\\})")) then
              ([$bindings[] | select(.at < $call.start)] | last) as $binding
              | if ($binding.value? // null) == null then {state: "unresolved"}
                else {state: "value", value: $binding.value} end
            else {state: "absent"} end);
    def result_for(rows; payload):
      [rows[] | .payload? // {}
       | select((.type? == "custom_tool_call_output" or .type? == "function_call_output")
                and (.call_id? // "") != "" and .call_id? == (payload.call_id? // ""))] | last? // {};
    def result_state(result):
      (result.output? // result.result? // "" | tostring) as $output
      | if result.success? == true then "success"
        elif result.success? == false then "failed"
        elif ($output | test("Script failed|apply_patch verification failed|\\\"exit_code\\\"\\s*:\\s*[1-9]"; "i")) then "failed"
        elif ($output | test("Script completed|Success\\.|Done!|\\\"exit_code\\\"\\s*:\\s*0"; "i")) then "success"
        else "unknown"
        end;
    def direct_args(blob): try (blob | fromjson | select(type == "object")) catch null;
    . as $rows
    | to_entries[]
    | .key as $index
    | .value as $row
    | ($row.payload? // {}) as $payload
    | ($rows[$index + 1].payload? // {}) as $next
    | epoch($row.timestamp? // "") as $t
    | [if ($payload.type? == "patch_apply_end") then
         if ($payload.success? == true) then
           (($payload.changes? // {}) | to_entries | .[]
            | ("F\t" + .key), ("F\t" + (.value.move_path? | select(type == "string" and . != ""))))
         else empty end
       elif ($payload.type? == "custom_tool_call" or $payload.type? == "function_call") then
         (($payload.input? // $payload.arguments? // "") | tostring) as $blob
         | (if ($payload.name? == "exec") then
              (exec_tools($blob) | if length == 0 then ["exec (naming no tool)"] else . end)
            else [($payload.name? // "")] end)
         | .[] as $name
         | if $name == "apply_patch" then
              (if ($next.type? == "patch_apply_end") then
                (if $next.success? == true then "success" else "failed" end)
              else result_state(result_for($rows; $payload)) end) as $state
             | if $state == "success" then (targets($blob) | .[] | "F\t" + .)
               elif $state == "failed" then empty
               else "X\tapply_patch outcome" end
           elif ($name | test("^(exec_command|run|shell)$")) then
             if $payload.name? == "exec" then
               key_states($blob; "exec_command|run|shell"; "cmd") as $commands
               | key_states($blob; "exec_command|run|shell"; "workdir") as $directories
               | (exec_tools($blob) | map(select(test("^(exec_command|run|shell)$"))) | length) as $calls
               | if ($commands | length) != $calls or any($commands[]; .state != "value")
                    or any($directories[]; .state == "unresolved") then
                   "X\t" + $name + " arguments"
                 else ($commands[] | .value | "C\t" + gsub("[\n\r\t]"; " ")),
                      ($directories[] | select(.state == "value") | .value | "D\t" + .)
                 end
             else (direct_args($blob)) as $args
               | if $args == null or ($args.cmd? | type) != "string" then "X\t" + $name + " arguments"
                 else ("C\t" + ($args.cmd | gsub("[\n\r\t]"; " "))),
                      (if ($args.workdir? | type) == "string" then "D\t" + $args.workdir else empty end)
                 end
             end
           elif $name == "write_stdin" then
             if $payload.name? == "exec" then
               key_states($blob; "write_stdin"; "chars") as $commands
               | (exec_tools($blob) | map(select(. == "write_stdin")) | length) as $calls
               | if ($commands | length) != $calls or any($commands[]; .state != "value") then
                   "X\twrite_stdin arguments"
                 else ($commands[] | .value | "C\t" + gsub("[\n\r\t]"; " ")) end
             else (direct_args($blob)) as $args
               | if $args == null or ($args.chars? | type) != "string" then "X\twrite_stdin arguments"
                 else "C\t" + ($args.chars | gsub("[\n\r\t]"; " ")) end
             end
           elif ($name | test("^(view_image|update_plan|wait|web_search|web__run|tool_search|get_goal|update_goal|create_goal|get_app_state|list_apps|getTabContext|request_user_input)$")) then
             empty
           else "X\t" + $name end
       elif ($payload.type? == "mcp_tool_call_end") then
         "X\t" + (($payload.invocation?.tool? // "mcp tool") | tostring)
       else empty end] as $classified
    | if $t == null then
        if ($classified | length) > 0 then "T\tunparseable" else empty end
      elif $t < $since then empty
      else $classified[]
      end' "$1" 2>/dev/null
}

transcript_files() {
  # Only the file-writing tool calls, read by recursive descent so a wrapper key around the message
  # (assistant turn, sidechain entry) does not hide the call. NotebookEdit names its target
  # notebook_path; every other editor names file_path. A call whose tool_result came back is_error
  # changed nothing — a denied or failed edit listed as this run's work is a file it never touched.
  # Nonzero says UNREADABLE, never empty: jq's own status is what the caller needs, so the pass is
  # an assignment of its own rather than one pipeline whose status belongs to `sort`. One pass reads
  # both the failed ids and the hits: a failed tool_result lands after its tool_use, so the hits are
  # filtered only at the end (a non-string id spelled as `-r` would print it, an empty one dropped).
  #
  # `since` is the run's own start: a --resume run APPENDS to the session's existing transcript, so
  # the file also holds the calls of the runs before it, and listing those as this run's work is the
  # shared-checkout mistake one directory in. Each LINE carries its own timestamp and governs its own
  # calls, so the cut is a per-line select ahead of the descent, not a filter on the paths it yields.
  # `fromdateiso8601` refuses the milliseconds every real transcript writes, hence the sub() — parsed
  # without it, every line reads as epoch 0 and a resumed run reports nothing at all.
  local transcript="$1" workdir="$2" since="${3:-0}" paths
  local -a more=("${@:4}")
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  paths=$(jq -nr --argjson since "$since" '
           reduce (inputs
                   | ((((.timestamp? // "") | tostring | sub("\\.[0-9]+"; "")) | fromdateiso8601? // 0) >= $since) as $in
                   | .. | objects
                   | if (.type? == "tool_result") and (.is_error? == true) then
                       (.tool_use_id? // empty) | (if type == "string" then . else tojson end)
                       | select(length > 0) | ["bad", .]
                     elif $in and (.type? == "tool_use")
                          and ((.name? // "") | test("^(Write|Edit|MultiEdit|NotebookEdit)$")) then
                       (.input.file_path? // .input.notebook_path? // empty) as $path | ["hit", (.id? // ""), $path]
                     else empty end) as $row
             ({bad: [], hits: []}; if $row[0] == "bad" then .bad += [$row[1]] else .hits += [$row[1:]] end)
           | .bad as $bad | .hits[] | select((.[0] as $id | $bad | index($id)) == null) | .[1]' \
           "$transcript" ${more[@]+"${more[@]}"} 2>/dev/null) || return 1
  # Piped, never a here-string: bash writes a short one whole into a pipe only it reads, and a
  # transcript's path list past the 16K buffer a macOS pipe was left at blocked that write forever
  # (live 2026-10-04: four watchdog chains outlived their runs by 31 h).
  printf '%s\n' "$paths" | listing_spelling "$workdir"
}

listing_spelling() { # workdir; paths on stdin
  local workdir="$1" path dir=''
  # A trailing slash makes the prefix double-slashed and silently stops matching; an absent workdir
  # would strip the leading `/` off every absolute path, so it strips nothing at all.
  [ -z "$workdir" ] || [ "$workdir" = null ] || dir="${workdir%/}/"
  while IFS= read -r path; do
    [ -z "$path" ] || resolve_tool_path "$path" "$workdir"
  done | AWK_DIR=$dir awk \
    'BEGIN { dir = ENVIRON["AWK_DIR"] }
     { if (dir != "" && index($0, dir) == 1) $0 = substr($0, length(dir) + 1) } NF' \
    | sort -u
}

# The shell writes worker-edit-guard recorded instead of refusing, spelled as the Edit/Write rows
# are so they fold through the same snapshot intersection. The hook spells them against the PHYSICAL
# top, and a directory it recorded (`cp -R`) answers for the snapshot rows under it.
shell_write_rows() { # directory workdir snapshot
  local physical
  [ -s "$1/shell-writes" ] || return 0
  physical=$(cd "$2" 2>/dev/null && pwd -P) || physical=${2%/}
  AWK_FROM=${physical%/}/ AWK_TO=${2%/}/ awk \
    'BEGIN { from = ENVIRON["AWK_FROM"]; to = ENVIRON["AWK_TO"] }
     { if (from != to && index($0, from) == 1) $0 = to substr($0, length(from) + 1); print }' \
    "$1/shell-writes" | listing_spelling "$2" |
    AWK_TOP=${2%/} AWK_PTOP=${physical%/} awk 'NR == FNR { if ($0 != "") snap[++n] = $0; next }
      $0 == ENVIRON["AWK_TOP"] || $0 == ENVIRON["AWK_PTOP"] { for (i = 1; i <= n; i++) print snap[i]; next }
      { print; for (i = 1; i <= n; i++) if (index(snap[i], $0 "/") == 1) print snap[i] }' <(printf '%s\n' "$3") - |
    sort -u
}

# `list`: only RUN_FILES_LIST and RUN_FILES_REASON are read (the watchdog's hop), so the shell
# classifier, a second transcript pass and a python3 start per hop, is skipped.
compute_transcript_files() { # directory [list]
  local directory="$1" mode="${2:-}" vendor account workdir session transcript started rows
  RUN_FILES_LIST=''
  RUN_FILES_REASON=''
  RUN_FILES_PARTIAL=''
  RUN_FILES_ESCAPE=''
  RUN_FILES_OUTSIDE=''
  RUN_SHELL_COMMANDS=''
  if meta_unchanged "$directory" TRANSCRIPT_META_KEY; then
    vendor=$TRANSCRIPT_META_VENDOR account=$TRANSCRIPT_META_ACCOUNT workdir=$TRANSCRIPT_META_WORKDIR started=$TRANSCRIPT_META_STARTED
  else
    {
      IFS= read -r vendor || true
      IFS= read -r account || true
      IFS= read -r workdir || true
      IFS= read -r started || true
    } < <(jq -r '.vendor, .account, .workdir, (.started_at // 0)' "$directory/meta.json" 2>/dev/null)
    TRANSCRIPT_META_VENDOR=$vendor TRANSCRIPT_META_ACCOUNT=$account TRANSCRIPT_META_WORKDIR=$workdir TRANSCRIPT_META_STARTED=$started
  fi
  session=$(session_id "$directory" "$vendor")
  if ! transcript=$(session_transcript "$vendor" "$account" "$session" "$workdir"); then
    RUN_FILES_REASON="no session transcript for $session"
    return 0
  fi
  # A Task subagent's calls are in transcripts of their own beside the session's.
  local sub key=''
  local -a subagents=()
  if [ "$vendor" = claudeb ]; then
    for sub in "${transcript%.jsonl}"/subagents/*.jsonl; do [ ! -f "$sub" ] || subagents+=("$sub"); done
  fi
  if [ -n "${TRANSCRIPT_MEMO+x}" ]; then
    printf -v key '%s\x1f' "$vendor" "$account" "$workdir" "$started" "$session" "$mode"
    for sub in "$transcript" ${subagents[@]+"${subagents[@]}"}; do
      file_lstat "$sub" || { key=''; break; }
      key+="$sub $FILE_SIZE $FILE_MTIME $FILE_INODE"$'\n'
    done
    if [ -n "$key" ] && [ "$key" = "$TRANSCRIPT_MEMO" ]; then
      RUN_FILES_LIST=$TRANSCRIPT_MEMO_LIST RUN_FILES_REASON=$TRANSCRIPT_MEMO_REASON
      RUN_FILES_PARTIAL=$TRANSCRIPT_MEMO_PARTIAL RUN_FILES_ESCAPE=$TRANSCRIPT_MEMO_ESCAPE RUN_FILES_OUTSIDE=$TRANSCRIPT_MEMO_OUTSIDE
      RUN_SHELL_COMMANDS=$TRANSCRIPT_MEMO_COMMANDS
      return 0
    fi
  fi
  compute_transcript_rows "$directory" "$vendor" "$transcript" "$workdir" "$started" "$mode" ${subagents[@]+"${subagents[@]}"} ||
    return 0
  [ -z "$key" ] || {
    TRANSCRIPT_MEMO=$key TRANSCRIPT_MEMO_LIST=$RUN_FILES_LIST TRANSCRIPT_MEMO_REASON=$RUN_FILES_REASON
    TRANSCRIPT_MEMO_PARTIAL=$RUN_FILES_PARTIAL TRANSCRIPT_MEMO_ESCAPE=$RUN_FILES_ESCAPE TRANSCRIPT_MEMO_OUTSIDE=$RUN_FILES_OUTSIDE
    TRANSCRIPT_MEMO_COMMANDS=$RUN_SHELL_COMMANDS
  }
  return 0
}

# Nonzero where the transcript was unreadable, which no memo may stand for.
compute_transcript_rows() { # directory vendor transcript workdir started mode [subagent...]
  local directory="$1" vendor="$2" transcript="$3" workdir="$4" started="$5" mode="$6" rows
  local -a subagents=("${@:7}")
  case "$vendor" in
    claudeb)
      if ! RUN_FILES_LIST=$(transcript_files "$transcript" "$workdir" "$started" ${subagents[@]+"${subagents[@]}"}); then
        RUN_FILES_LIST=''
        RUN_FILES_REASON='transcript unreadable'
        return 1
      fi
      # A list of editor calls answers for editor calls: a run that also WROTE through the shell —
      # `sed -i`, a redirect, `mv` — changed files no transcript records as a tool call, and the list
      # is a floor rather than the whole of it. Said per run, because a run whose shell only READ
      # (its own test suite, `git status`) has a complete list and must not be doubted.
      [ "$mode" != list ] || return 0
      transcript_wrote_through_shell "$transcript" "$started" ${subagents[@]+"${subagents[@]}"}
      case $? in
        0) RUN_FILES_PARTIAL="$SHELL_FLOOR_PARTIAL" ;;
        2) RUN_FILES_LIST=''; RUN_FILES_REASON='transcript unreadable'; return 1 ;;
      esac
      ;;
    gemini)
      rows=$(gemini_tool_rows "$transcript" "$started") || {
        RUN_FILES_REASON='transcript unreadable'
        return 1
      }
      classify_tool_rows "$rows" "$workdir"
      RUN_SHELL_COMMANDS=$(printf '%s\n' "$rows" | sed -n $'s/^C\t//p')
      ;;
    codex)
      rows=$(codex_tool_rows "$transcript" "$started") || {
        RUN_FILES_REASON='transcript unreadable'
        return 1
      }
      classify_tool_rows "$rows" "$workdir"
      RUN_SHELL_COMMANDS=$(printf '%s\n' "$rows" | sed -n $'s/^C\t//p')
      ;;
    grok)
      rows=$(grok_tool_rows "$transcript" "$started") || {
        RUN_FILES_REASON='transcript unreadable'
        return 1
      }
      classify_tool_rows "$rows" "$workdir"
      RUN_SHELL_COMMANDS=$(printf '%s\n' "$rows" | sed -n $'s/^C\t//p')
      ;;
    # Fail-closed for a vendor added without an extractor: an empty list is a claim about the run,
    # and it is the one claim certainly wrong about a run nobody can read.
    *) RUN_FILES_REASON="no per-file extractor for $vendor" ;;
  esac
  return 0
}

cotenant_note() { # paths
  local paths="$1" count listed
  count=$(grep -c '' <<<"$paths")
  listed=$paths
  [ "$count" -le "$UNNAMED_INLINE_MAX" ] || listed=$(head -n "$UNNAMED_INLINE_MAX" <<<"$paths")
  listed=$(tr '\n' ' ' <<<"$listed")
  listed=${listed% }
  if [ "$count" -gt "$UNNAMED_INLINE_MAX" ]; then
    printf '%s path(s) changed in the checkout during the run by another writer and are not this run'"'"'s; the first %s: %s\n' \
      "$count" "$UNNAMED_INLINE_MAX" "$listed"
    return 0
  fi
  printf '%s path(s) changed in the checkout during the run by another writer and are not this run'"'"'s: %s\n' \
    "$count" "$listed"
}

# The same for the paths NOBODY answers for: the run's own listing is a floor or unreadable, so the
# window holds changes it may or may not have made, and neither answer may be invented. They are in
# the dirt record, which is what the UNNAMED line offers the launching chat to claim.
unattributed_note() { # paths reason
  local paths="$1" count listed
  count=$(grep -c '' <<<"$paths")
  listed=$paths
  [ "$count" -le "$UNNAMED_INLINE_MAX" ] || listed=$(head -n "$UNNAMED_INLINE_MAX" <<<"$paths")
  listed=$(tr '\n' ' ' <<<"$listed")
  listed=${listed% }
  if [ "$count" -gt "$UNNAMED_INLINE_MAX" ]; then
    printf '%s path(s) changed in the run'"'"'s window that its own listing does not name and nobody answers for (%s); the first %s: %s\n' \
      "$count" "$2" "$UNNAMED_INLINE_MAX" "$listed"
    return 0
  fi
  printf '%s path(s) changed in the run'"'"'s window that its own listing does not name and nobody answers for (%s): %s\n' \
    "$count" "$2" "$listed"
}

# The caveat the launching chat reads beside the file list, from what `persist_run_files` already
# resolved: what the run does NOT answer for. A listing that answered for the whole run names a
# co-tenant's paths as a co-tenant's; one that could not leaves them owned by nobody, which is a
# different sentence — and never "the snapshot stands", which is the claim that handed a run eight
# files for the two it wrote (live 2026-09-11).
transcript_crosscheck() ( # directory
  local directory="$1" path
  {
    if [ -n "${RUN_FILES_COTENANT:-}" ]; then
      cotenant_note "$RUN_FILES_COTENANT"
    fi
    if [ -n "${RUN_FILES_UNNAMED:-}" ]; then
      unattributed_note "$RUN_FILES_UNNAMED" "${RUN_LISTING_REASON:-${RUN_LISTING_PARTIAL:-the listing is incomplete}}"
    fi
    while IFS= read -r path; do
      [ -z "$path" ] || printf 'UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: %s\n' "$path"
    done <<<"${RUN_FILES_EXTERNAL:-}"
    if [ -n "${RUN_LISTING_REASON:-}" ]; then
      printf 'transcript cross-check unavailable: %s; changed paths remain unnamed\n' \
        "$RUN_LISTING_REASON"
    fi
  } >"$directory/files-note"
  if [ -n "${RUN_FOREIGN_NOTE:-}" ]; then
    printf '%s\n' "$RUN_FOREIGN_NOTE" >>"$directory/files-note" 2>/dev/null || :
  fi
)

compute_run_files() {
  local directory="$1" workdir
  RUN_FILES_LIST=''
  RUN_FILES_REASON=''
  RUN_FILES_PARTIAL=''
  RUN_FILES_ESCAPE=''
  if [ -f "$directory/files" ]; then
    RUN_FILES_LIST=$(grep -v '^WORKDIR: \|^UNKNOWN: \|^PARTIAL: ' "$directory/files" 2>/dev/null)
    RUN_FILES_REASON=$(sed -n 's/^UNKNOWN: //p' "$directory/files" | head -n1)
    return 0
  fi
  workdir=$(jq -r '.workdir' "$directory/meta.json" 2>/dev/null)
  compute_snapshot_files "$directory" "$workdir"
}

# 1 requires every Bash call in the window to be classified read-only; 0 is a floor, 2 unreadable.
transcript_wrote_through_shell() { # transcript since [transcript...]
  local transcript="$1" since="${2:-0}" commands
  local -a more=("${@:3}")
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  commands=$(jq -c --argjson since "$since" '
           (((.timestamp? // "") | tostring | sub("\\.[0-9]+"; ""))
             | fromdateiso8601? // null) as $stamp
           | .. | objects
           | select((.type? == "tool_use") and ((.name? // "") == "Bash"))
           | if $stamp == null then "__unclassified_shell_call__"
             elif $stamp < $since then empty
             else (.input.command? // "") | tostring
               | if length == 0 then "__unclassified_shell_call__" else . end
             end' "$transcript" ${more[@]+"${more[@]}"} 2>/dev/null) || return 2
  RUN_SHELL_COMMANDS=$commands
  [ -n "$commands" ] || return 1
  writes_through_shell 3<<<"$commands"
}

run_files() {
  local directory="$1" workdir count value named reason
  workdir=$(jq -r '.workdir' "$directory/meta.json" 2>/dev/null)
  compute_run_files "$directory"
  workdir_escape_line "$directory"
  [ ! -s "$directory/files-note" ] || sed 's/^/RUN-FILES-NOTE: /' "$directory/files-note"
  # Git sees no edit to an ignored path, a committed one or one in another checkout: an empty
  # intersection beside the run's own named writes, or beside a listing that is only a floor, is no 0.
  reason=$RUN_FILES_REASON
  if [ -z "$reason" ] && [ -z "$RUN_FILES_LIST" ]; then
    named=$(sed '/^$/d' "$directory/listed" 2>/dev/null)
    if [ -n "$named" ]; then
      reason="the run's own calls name $(grep -c '' <<<"$named") path(s) git shows no change for here: $(head -n 3 <<<"$named" | paste -sd' ' -)"
    else
      reason=$(sed -n 's/^PARTIAL: //p' "$directory/files" 2>/dev/null | head -n1)
    fi
  fi
  if [ -n "$reason" ]; then
    printf 'RUN-FILES: unknown (%s)\n' "$reason"
    printf 'RUN-FILES-RULE: claim only the files the result names; any other dirty file may be another chat'"'"'s\n'
    return 0
  fi
  if [ -z "$RUN_FILES_LIST" ]; then
    printf 'RUN-FILES: 0\n'
    return 0
  fi
  count=$(grep -c '' <<<"$RUN_FILES_LIST")
  # The paths below are workdir-relative (absolute only when they fall outside it), so a consumer
  # standing anywhere else — the launching chat's journal hook — can resolve them only with this.
  [ -z "$workdir" ] || [ "$workdir" = null ] || printf 'WORKDIR: %s\n' "$workdir"
  printf 'RUN-FILES: %s\n' "$count"
  while IFS= read -r value; do
    printf 'RUN-FILE: %s\n' "$value"
  done <<<"$RUN_FILES_LIST"
}

readonly_report_hint() {
  local directory="$1" workdir gained marker root month started marker_month count=0 code listing paths shas
  [ -f "$directory/exit_code" ] || return 0
  code=$(tr -d '[:space:]' <"$directory/exit_code")
  [ "$(terminal_status "$directory" "$(jq -r '.vendor' "$directory/meta.json" 2>/dev/null)" "$code")" = done ] ||
    return 0
  head -n1 "$directory/brief" 2>/dev/null | grep -Eiq '(^|[[:space:]])(READ-ONLY|RESEARCH):' && return 0
  # A Light run IS the cheaper leg the hint asks for, and a research run edits nothing by design:
  # told to route itself somewhere cheaper, either one is being asked to stop existing.
  jq -e '.role == "research" or has("light")' "$directory/meta.json" >/dev/null 2>&1 && return 0
  compute_run_files "$directory"
  [ -z "$RUN_FILES_REASON" ] && [ -z "$RUN_FILES_LIST" ] || return 0
  [ -f "$directory/dirty-before" ] || return 0
  workdir=$(jq -r '.workdir' "$directory/meta.json" 2>/dev/null)
  listing=$(mktemp "${TMPDIR:-/tmp}/worker-run-dirty.XXXXXX") || return 0
  shas=$(workdir_dirty_shas "$workdir" "" "$listing" 2>/dev/null) && [ -f "$listing" ] || { rm -f "$listing"; return 0; }
  paths=$(<"$listing")
  rm -f "$listing"
  gained=$(workdir_gained_paths "$directory" "$workdir" "$paths" "$shas")
  [ -z "$gained" ] || return 0
  # Git sees no edit to an ignored path (a bench whose tracers/ and results/ are .gitignored), so the
  # run's own editor and shell calls get the last word before it is called read-only.
  compute_transcript_files "$directory"
  if [ -n "$RUN_FILES_LIST" ] || [ -n "$RUN_FILES_PARTIAL" ] || [ -n "$RUN_FILES_REASON" ]; then
    rm -f "$directory/report-readonly"
    return 0
  fi
  marker="$directory/report-readonly"
  [ -e "$marker" ] || : >"$marker"
  root=${directory%/*}
  month=$(date +%Y-%m)
  for marker in "$root"/*/report-readonly; do
    [ -e "$marker" ] || continue
    started=$(jq -r '.started_at // empty' "${marker%/*}/meta.json" 2>/dev/null)
    [[ "$started" =~ ^[0-9]+$ ]] || continue
    marker_month=$(date -r "$started" +%Y-%m 2>/dev/null || date -d "@$started" +%Y-%m 2>/dev/null) || continue
    [ "$marker_month" != "$month" ] || count=$((count + 1))
  done
  printf 'HINT: this run edited nothing — a read-only lookup is cheaper as a light research run (a background Bash `light-research --prompt-file <f> --out <answer> --repo <abs>`); read-only worker runs this month: %s\n' "$count"
}
