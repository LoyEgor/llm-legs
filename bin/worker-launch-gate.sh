#!/usr/bin/env bash
# A vendor launched as a bare headless CLI call from a chat's Bash is a worker nobody can see: no
# worker-run record, no statusline tag, no journal ownership, no pool refusal, no limit signature,
# no stall watch. This door denies that spelling so every headless run reaches a launcher that owns
# it — the sanctioned list is docs/routing-contract.md rule 4 and the share/worker-pool.sh header.
#
# It decides on the parsed command (claude-setup hooks/lib/argv.sh: `shfmt --to-json` walked into one
# record per simple command the shell runs), never on its text: a vendor counts only as the program
# of a record, past env assignments and the wrappers that hand a command on (`env`, `nohup`,
# `timeout 540`, `xargs -I{}`), path-qualified or quoted. Quoted text, comments and a heredoc fed to
# anything but a shell are data, so a brief quoting `claude -p` is a brief; `$(…)`, an unquoted
# heredoc's substitutions, and a `-c`, `eval` or heredoc body a shell runs are commands. A command
# shfmt cannot parse is read as its raw words, as the text gate read it. A help or version probe
# launches nothing, and neither does a media script's `--dry-run` (each honours it or refuses it).
#
# Interactive launches — no -p/--print/--prompt, no `exec`, no `run` — are the human, never a
# worker, and are not this gate's business. Fail-open on its own errors, like the sibling gates.
#
# `worker-run start|run|wait` belongs to the main chat, which waits on a run as a background Bash; an
# agent or a headless worker never starts or awaits one. The media scripts and the generating
# subcommands of their web engines have one door for every session, `media-run`, whose job pointer
# is what renders the account a generation spends. A review launch spelled past the parse — a script
# file, an interpreter — carries no REVIEW_BENCH_DOOR nonce, and review-bench refuses it.
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

VENDOR_BINS="claude|claudeb|claudegpt|codex|codexb|gemini|geminib|agy|opencode|grok|grokb"
OWNED_IMAGE="(codex|gemini|grok)-image|grok-video|gemini-(video|music|sfx|listen|speech)|suno-(music|speech)|elevenlabs-(sfx|music|stems|speech|revoice|isolate|transcribe|align|dub|voice)|image-fanout"
OWNED_LEGS="ask_(claude|codex|gemini)\.sh|codex-fast-probe|gemini-probe"
DIRECT_ASK="a worker run the chat starts itself: \`worker-run run auto --brief <file> --workdir <dir>\` as ONE background Bash, which picks, starts, waits and prints the report"

deny() {
  jq -cn --arg hook "${0##*/}" --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: ("[" + $hook + "] " + $r)}}' \
    2>/dev/null
  exit 0
}
span_live() {
  ( . "${WORDS_LIB:-$HOME/.claude/hooks/lib/words.sh}" && command -v words_span_live &&
    words_span_live "$(jq -r '.session_id // ""' <<<"$input")" "$(jq -r '.transcript_path // ""' <<<"$input")" ) >/dev/null 2>&1
}

# A screen before any fork: every rule below needs one of these words as a program, and a program word
# is spelled in the text with at most quotes and backslashes inside it, so a text naming none of them
# — nearly every call — launches nothing. A program word in a `$X` must be followed by its subcommand
# to start, wait or run anything; a `$X` beside the `X=` that assigns it may hold any word, so that
# pair takes the full path.
SCREEN_RE="(${VENDOR_BINS})([[:space:]]|\$)|worker-run|review-bench|light-research|REVIEW_BENCH_DOOR|${OWNED_LEGS}|${OWNED_IMAGE}|chatgpt-web|gemini-web|(^|[[:space:]])(at|batch|crontab)([[:space:]]|\$)|[\$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?[[:space:]]+(start|run|wait)([[:space:]]|\$)"
# Quotes and backslashes go, and separators become blanks (in the payload, `\\` pairs first, an escaped
# quote goes, a bare one is a string's edge and the whitespace escapes are blanks). Bash 3.2's ${x//…/}
# is cubic — a 7 KB payload took 128 s — so past 256 bytes one sed or tr does it.
unquote() { # text [json] -> UNQUOTED
  if [ "${#1}" -lt 256 ]; then
    UNQUOTED=$1
    if [ -n "${2:-}" ]; then
      UNQUOTED=${UNQUOTED//'\\'/} UNQUOTED=${UNQUOTED//'\"'/} UNQUOTED=${UNQUOTED//'"'/ }
      UNQUOTED=${UNQUOTED//\\[ntrbf]/ }
    fi
    UNQUOTED=${UNQUOTED//[\'\"\\]/} UNQUOTED=${UNQUOTED//[;|&()\`]/ }
  elif [ -n "${2:-}" ]; then
    UNQUOTED=$(LC_ALL=C sed -e 's/\\\\//g' -e 's/\\"//g' -e 's/"/ /g' -e 's/\\[ntrbf]/ /g' -e "s/['\\\\]//g" -e 's/[;|&()`]/ /g' <<<"$1")
  else UNQUOTED=$(LC_ALL=C tr -d "'\"\\\\" <<<"$1" | LC_ALL=C tr ';|&()`' '      '); fi
}
may_launch() { # text [json]
  unquote "$@"
  if [[ $UNQUOTED == *'$'* && $UNQUOTED == *=* ]]; then
    [ "${#UNQUOTED}" -lt 4096 ] || return 0
    local rest=$UNQUOTED re='([A-Za-z_][A-Za-z0-9_]*)='
    while [[ $rest =~ $re ]]; do
      [[ $UNQUOTED == *'$'"${BASH_REMATCH[1]}"* || $UNQUOTED == *'${'"${BASH_REMATCH[1]}"* ]] && return 0
      rest=${rest#*"${BASH_REMATCH[0]}"}
    done
  fi
  [[ $UNQUOTED =~ $SCREEN_RE ]]
}
# The payload is screened before jq reads it. A `\u` escape may spell any letter, so it takes the full path.
input=''
IFS= read -r -d '' input || :
case $input in *mcp__codex__* | *'\u'*) ;; *) may_launch "$input" json || exit 0 ;; esac

command -v jq >/dev/null 2>&1 || exit 0
parsed=$(jq -r 'select(.hook_event_name == "PreToolUse")
  | [.tool_name // "", .tool_input.command // "", (.agent_id // "" | tostring),
     (.tool_input.run_in_background == true | tostring), .cwd // ""] | @sh' <<<"$input" 2>/dev/null) || exit 0
[ -n "$parsed" ] || exit 0
eval "fields=($parsed)"
tool=${fields[0]} cmd=${fields[1]} agent_id=${fields[2]} background=${fields[3]} cwd=${fields[4]}
case "$tool" in
  Bash | Monitor) ;;
  mcp__codex__*)
    deny "Blocked: \`${tool}\` runs codex headless on this session's own codex login — no worker-run record, no task row naming the account, no workers switch. Work for a model is ${DIRECT_ASK}; Computer Use is a codex brief carrying \`COMPUTER: yes\`." ;;
  *) exit 0 ;;
esac
[ -n "$cmd" ] || exit 0
# `[[:blank:]]`, never `[[:space:]]`: a newline is a chain separator.
SAFE_RUN_RE='^[[:blank:]]*worker-run[[:blank:]]+(report|say|claim|stop)([[:blank:]]+[A-Za-z0-9._/@%+=:,-]+)+[[:blank:]]*$'
[[ ! $cmd =~ $SAFE_RUN_RE ]] && may_launch "$cmd" || exit 0
. "${ARGV_LIB:-$HOME/.claude/hooks/lib/argv.sh}" 2>/dev/null || exit 0
argv_parse "$cmd" "$cwd"
owner=false
[ -z "$agent_id" ] && [ "${CLAUDEB_WORKER:-}" != 1 ] || owner=true

# Every record the call runs, judged at once: each hit is `rank<TAB>kind<TAB>shown words`, and the
# lowest rank decides — the order the checks have always run in.
hits=$(argv_select --arg tool "$tool" --argjson owner "$owner" --argjson bg "$background" \
  --arg vendors "^(${VENDOR_BINS})\$" --arg media "^(${OWNED_IMAGE})\$" --arg legs "^(${OWNED_LEGS})\$" '
  . as $r | cmdv as $c | $c.prog as $p | $c.args as $a
  | ($r.lit[($r.argv | length) - ($a | length) - 1] != false) as $plit
  | ([$c.path] + $a[:1] | join(" ")) as $two
  | (if ($p | test($vendors)) then
       ([$a | to_entries[] | select(.value | test("^(-p|--print|--prompt)(=.*)?$")) | .key] | first) as $pf
       | ([$a | to_entries[] | select(.value | test("^(-p|--print|--prompt(-file|-json)?)(=.*)?$|^agent$")) | .key] | first) as $gf
       | ([$a | to_entries[] | select(.value | test("^(exec|e|review)$")) | .key] | first) as $xf
       | ([$a | to_entries[] | select(.value == "run") | .key] | first) as $rf
       | (if ($p | test("^(claude|claudeb|claudegpt|gemini|geminib|agy)$")) then $pf
          elif ($p | test("^codexb?$")) then $xf elif $p == "opencode" then $rf else $gf end) as $at
       # A pipe from sleep or true feeds no prompt: a stdin-driven server mode run that way is a probe.
       | ($r.stdin.from.argv[0] // "" | base | test("^(sleep|true|:)$")) as $fed_nothing
       | ($p == "claudeb" and (($a[0] // "") | test("^(revive|warm)$"))) as $sanctioned
       | (if ($sanctioned or probe) then empty
          elif $r.stdin.kind == "pipe" and ($fed_nothing | not) then [7, "piped", $two]
          elif $at != null and (($fed_nothing and $a[$at] == "agent") | not) then [9, "launch", ([$c.path] + $a[:$at + 1] | join(" "))]
          else empty end)
     else empty end),
    (if ((.env + .assigns) | any(.name == "REVIEW_BENCH_DOOR"))
        or (($r.argv[0] // "" | base) == "env" or .crude) and ($r.argv | any(startswith("REVIEW_BENCH_DOOR=")))
     then [0, "forged", "REVIEW_BENCH_DOOR"] else empty end),
    (if probe then empty else
       ($p == "worker-run" and (($a[0] // "") | test("^(start|run|wait)$"))) as $owned
       | (($p == "review-bench") and (($a[0] // "") | test("^(review|run)$")) and ($a | any(test("^(--help|-h|--price)$")) | not)) as $review
       | ($p == "review-bench" and $a[0] == "wait") as $rwait
       | (if $tool == "Monitor" and (($p == "worker-run" and (($a[0] // "") | test("^(wait|run)$"))) or $rwait) then [1, "monitor", $two] else empty end),
         (if $tool == "Monitor" and $review then [1, "monitor-review", $two] else empty end),
         (if $owner and ($review or ($rwait and ($a | any(test("^--(relaunch|finish-partial)")))))
          then [2, "owner-review", $two] else empty end),
         (if $owner and ($owned or $p == "light-research" or (($plit | not) and (($a[0] // "") | test("^(start|run|wait)$"))))
          then [3, "owner-run", (if $p == "light-research" then $c.path else $two end)] else empty end),
         (if $tool == "Bash" and ($bg | not) and (($p == "worker-run" and ($a[0] == "run" or ($a[0] == "wait" and ($a | any(test("^--max(=|$)")) | not))))
               or $p == "light-research")
          then [4, "foreground", (if $p == "light-research" then $c.path else $two end)] else empty end),
         (if ($p | test($legs)) and ($a | any(. == "--extract-served-model" or . == "--help") | not) then [5, "legs", $c.path] else empty end),
         (if ($p | test("^(at|batch|crontab)$")) and (($p == "crontab" and ($a | if .[0] == "-u" then .[2:] else . end) == ["-l"]) | not)
          then [8, "schedule", ([$c.path] + $a | join(" "))] else empty end)
     end),
    # Media help is exempt only as typed: past a wrapper (`xargs -J --help`), a `$H` or
    # another flag, it runs with other words.
    (if (($p | test($media)) and ((($r.argv | length) == ($a | length) + 1 and ($r.lit | all) and ($a == ["--help"] or $a == ["-h"]))
                                  or ($a | flag_in(["--dry-run"])) | not))
        or ($p == "chatgpt-web" and (($a[0] // "") | test("^(generate|resize|comment|remove-bg)$")) and (probe | not))
        or ($p == "gemini-web" and $a[0] == "generate" and (probe_dry | not))
     then [6, "media", (if ($p | test($media)) then $c.path else $two end)] else empty end)
  | @tsv' | sort -t $'\t' -k1,1n)

while IFS=$'\t' read -r _ kind hit; do
  case $kind in
    forged) deny "Blocked: \`REVIEW_BENCH_DOOR\` is stamped by the hooks alone — it names the review Egor's word opened — and a command setting it by hand forges that owner. A review is launched plainly from the chat's own shell on his word." ;;
    # The review door is registered for Bash alone, so a Monitor launching a panel would skip his word.
    monitor) deny "Blocked: a Monitor polling \`${hit}\` re-reads the run every round. Run \`${hit} <run-id>\` once as a Bash call with \`run_in_background: true\`: it blocks until the run ends, streams its progress to /tasks, and its completion notification wakes this chat." ;;
    monitor-review) deny "Blocked: a Monitor running \`${hit}\` launches a review panel past the door that holds it for Egor's word. Launch it with a plain Bash call from this chat on his word, then run \`review-bench wait <run-id>\` as a background Bash." ;;
    # A review panel spends the chat's grant and a pool of accounts, and only the chat's own shell
    # holds that grant; a worker run likewise belongs to the chat that waits on it.
    owner-review) deny "Blocked: \`${hit}\` inside an agent or a headless worker launches review cells on a grant that is the chat's alone, spending a pool of accounts nobody granted. An agent never runs a review: report that one is due, and the chat launches it from its own shell on Egor's word." ;;
    owner-run) deny "Blocked: \`${hit}\` inside an agent or a headless worker starts or awaits a worker run that belongs to the chat: the chat starts it, waits on it as a background Bash and reads its report. Report what should be delegated in your RETURN instead. \`worker-run report\`, \`worker-run claim\` and the test suites are not gated." ;;
    # An unbounded wait in a foreground call dies at the Bash timeout while the run keeps spending.
    foreground) deny "Blocked: \`${hit}\` blocks until the run ends, and a foreground Bash call is killed at its timeout (600 s at most) while the run keeps spending and nothing wakes this chat. Run the identical call with \`run_in_background: true\`: its completion notification wakes this chat." ;;
    legs) span_live || deny "Blocked: \`${hit}\` spends a Claude, Codex or Gemini account from Claude Code's Bash with no worker-run record naming the account. A question for a model is ${DIRECT_ASK}; a live probe is Egor's to run — hand him the paste-ready command for his own terminal." ;;
    media) deny "Blocked: \`${hit}\` runs media past \`media-run\`, the one door that renders the account it spends: load the media skill, write the prompt yourself and run \`media-run <kind> --vendor <v> -- <the script's own args>\` (\`media-run --help\` lists the kinds) (several vendors, \`--takes\` or \`--jobs\` fan out). Quoting one inside a heredoc body is not running it." ;;
    # A vendor CLI fed on stdin runs headless with no print flag.
    piped) deny "Blocked: a pipe into \`${hit}\` runs it headless on its stdin — a bare vendor launch. A worker is ${DIRECT_ASK}." ;;
    # A scheduler runs its command later, where no gate reads it.
    schedule) span_live || deny "Blocked: \`${hit}\` schedules a command to run later, outside every gate and every task row. Run the work now through its owner; a scheduled job is Egor's to set up — hand him the paste-ready command." ;;
    launch) deny "Blocked: \`${hit}\` is a bare headless vendor launch — it leaves no worker-run record, no statusline tag, no journal ownership, no pool refusal, no limit signature and no stall watch. A worker is ${DIRECT_ASK}; the other tools own their launches (review-bench, llm-limits, claudeb revive, claude-session-driver, opencode-go; the media scripts are reached through media-run). An interactive launch — no -p/--print/--prompt, no exec, no run — is not gated. The gate reads the parsed command: quotes, wrappers and \`sh -c\` strings do not hide a launch, and quoted text is not one." ;;
  esac
done <<<"$hits"
exit 0
exit; }
