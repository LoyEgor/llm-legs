#!/usr/bin/env bash
# A vendor launched as a bare headless CLI call from a chat's Bash is a worker nobody can see: no
# worker-run record, no statusline tag, no journal ownership, no pool refusal, no limit signature,
# no stall watch. This door denies that spelling so every headless run reaches a launcher that owns
# it — the sanctioned list is docs/routing-contract.md rule 4 and the share/worker-pool.sh header.
#
# Two lists and no judgement between them. LAUNCH_RES is a vendor binary plus the flag or
# subcommand that makes it print-and-exit; SANCTIONED_RE is the tools that own their launches. A
# chain segment running a sanctioned launcher in command position passes whatever else it spells,
# and exempts that segment only: `worker-run report x; codex exec …` is still a bare launch.
#
# The text gate reads the common spellings only. A review launch spelled past it — `eval`, a script
# file, an interpreter — carries no REVIEW_BENCH_DOOR nonce, and review-bench refuses it.
#
# Quoted text is collapsed into ONE word first, then quotes and backslashes are stripped from the
# whole string, so `'claude' -p`, `"codex" exec` and `\claude -p` are the launches they spell while
# a separator or a space inside a quote stays inside it. What survives is judged by POSITION: a
# vendor name counts only in command position — the start of a chain segment, past any env
# assignments and wrapper words — so `mkdir claude -p` and `git log dir/claude -p` are the operands
# they are. Chain separators end a segment, so a vendor name in one link cannot borrow a flag from
# the next, and a vendor name quoted inside an echo or a grep is an operand and passes.
#
# Interactive launches — no -p/--print/--prompt, no `exec`, no `run` — are the human, never a
# worker, and are not this gate's business. Fail-open on its own errors, like the sibling gates.
#
# `worker-run start|wait` belongs to the main chat, which waits on a run as a background Bash; an
# agent or a headless worker never starts or awaits one. The media scripts and the generating
# subcommands of their web engines have one door for every session, `media-run`, whose job pointer
# is what renders the account a generation spends.
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

EDGE="([[:space:]]|\$)"
# Command position. Every chain separator is turned into a newline below, so the start of a line is
# the start of a command; `^` is that whole alternation. A shell keyword or a group brace opens a
# command position without being one, env assignments and the wrapper words that hand a command
# straight to the kernel may precede the binary in any order, each wrapper with its own flags and
# the operand those flags take (`nice -n 5`, `timeout -k 10 540`), and a path prefix ending in `/`
# lets `/usr/local/bin/codex exec` read as `codex exec` while keeping `~/.claude` and
# `.claude/hooks` from reading as the `claude` binary.
KEYWORD="([{!]|if|then|else|elif|do|while|until)[[:space:]]+"
WRAPPER_NAME="(env|command|exec|builtin|nohup|nice|time|timeout|gtimeout|stdbuf|setsid|caffeinate|unbuffer|arch|sudo|xargs|npx|bunx|pnpx|(npm|pnpm|yarn|bun)[[:space:]]+(exec|dlx|x))"
WRAPPER="${WRAPPER_NAME}([[:space:]]+(-[^[:space:]]*|[0-9][^[:space:]]*))*"
# Wrappers whose operands are not flags alone — a user, a host, a path, a lock file, a session name,
# the `-a` of `exec` — so any words may stand between them and the command they run.
LOOSE_WRAPPER="(sudo|script|watch|ssh|find|tmux|screen|launchctl|xargs|flock|exec)([[:space:]]+.*)?"
# A flag may take one word (`timeout -s KILL`, `env -u FOO`). That word and the loose wrappers' `.*`
# can swallow a vendor word, so they read a launch and never a sanctioned launcher: on the exempting
# side `env -i codex exec worker-run` would exempt a codex launch.
SANCTIONED_WORD="^[[:space:]]*(${KEYWORD})*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|${WRAPPER})[[:space:]]+)*([^[:space:]/]*/)*"
VENDOR_WORD="^[[:space:]]*(${KEYWORD})*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|${WRAPPER_NAME}([[:space:]]+(-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?|[0-9][^[:space:]]*))*|${LOOSE_WRAPPER})[[:space:]]+)*([^[:space:]/]*/)*"
# The flag or subcommand that turns a vendor CLI into a headless run, reached past any number of
# other flags.
PRINT_FLAG="([[:space:]]+[^[:space:]]+)*[[:space:]]+(-p|--print|--prompt)(=[^[:space:]]*)?${EDGE}"
SUBCOMMAND="([[:space:]]+[^[:space:]]+)*[[:space:]]+"
VENDOR_BINS="claude|claudeb|claudegpt|codex|codexb|gemini|geminib|agy|opencode|grok|grokb"

# Grok's own spellings, not reusable from PRINT_FLAG: folding it back in would let
# `grokb ... --prompt-file` and `grokb agent` through.
GROK_PRINT_FLAG="([[:space:]]+[^[:space:]]+)*[[:space:]]+(-p|--print|--prompt(-file|-json)?(=[^[:space:]]*)?|agent)${EDGE}"

LAUNCH_RES=(
  "${VENDOR_WORD}claudeb?${PRINT_FLAG}"
  # `claudeb?` cannot reach it: the `gpt` sits where that alternation expects a separator, and a
  # `claudegpt p <acct> -p` run is a print run spending a Codex account like any other.
  "${VENDOR_WORD}claudegpt${PRINT_FLAG}"
  # `e` is codex's own alias for `exec`, and `review` is a headless run of its own.
  "${VENDOR_WORD}codexb?${SUBCOMMAND}(exec|e|review)${EDGE}"
  "${VENDOR_WORD}geminib?${PRINT_FLAG}"
  "${VENDOR_WORD}agy${PRINT_FLAG}"
  "${VENDOR_WORD}opencode${SUBCOMMAND}run${EDGE}"
  "${VENDOR_WORD}grokb?${GROK_PRINT_FLAG}"
)

# The worker-run subcommands that own a run's LIFE, judged in command position like every vendor
# word above, and light-research, which starts and awaits them itself. `claim` is bookkeeping any
# surface may do, `report` only prints a record that already exists, and a bare `worker-run` prints
# help, so none of the three is here; `bash tests/test_worker_run.sh` is not a run.
OWNED_RUN_RE="${VENDOR_WORD}(worker-run[[:space:]]+(start|wait)|light-research)${EDGE}"
# A variable this door could not expand, standing where worker-run would, is read as worker-run.
UNREADABLE_RUN_RE="${VENDOR_WORD}[\$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?[[:space:]]+(start|wait)${EDGE}"

# Called past media-run, a media script or a web engine's generating subcommand spends an account
# with no work line naming it, so every hand is refused, an agent's included.
OWNED_IMAGE_RE="${VENDOR_WORD}((codex|gemini|grok)-image|grok-video|gemini-(video|music|sfx|listen|speech)|elevenlabs-(sfx|music|stems|speech|revoice|isolate|transcribe|align|dub|voice)|image-fanout)${EDGE}"
MEDIA_ENGINE_RE="${VENDOR_WORD}(chatgpt-web[[:space:]]+(generate|resize|comment|remove-bg)|gemini-web[[:space:]]+generate)${EDGE}"

# A recovery relaunches review cells, so inside an agent it is a launch; a plain `review-bench wait`
# spends nothing.
WORKER_REVIEW_RE="${VENDOR_WORD}review-bench[[:space:]]+wait[[:space:]].*--(relaunch|finish-partial)"
# The legs and probes that spend an account with no launcher around them. No agent type owns them:
# `--extract-served-model` and `--help` spend nothing.
OWNED_LEGS_RE="${VENDOR_WORD}(ask_(claude|codex|gemini)\.sh|codex-fast-probe|gemini-probe)${EDGE}"
LEGS_FREE_RE='[[:space:]]--(extract-served-model|help)([[:space:]]|$)'
REVIEW_LAUNCH_RE="${VENDOR_WORD}review-bench[[:space:]]+(review|run)${EDGE}"
REVIEW_IDLE_RE='[[:space:]](--help|-h|--price)([[:space:]]|$)'
SCHEDULE_RE='^[[:space:]]*(at|batch|crontab)([[:space:]]|$)'
DIRECT_ASK="a worker run the chat starts itself: \`worker-run start <vendor> --brief <file> --workdir <dir>\` (worker-pick's START line names the vendor), then \`worker-run wait <run-id>\` as a background Bash and \`worker-run report <run-id>\` when it ends"
# The owner token review-bench checks is the hooks' to stamp; a command setting it by hand is a
# forged owner.
FORGED_TOKEN_RE="^[[:space:]]*((export|env|declare|typeset|local|readonly)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(REVIEW_BENCH_DOOR)="

SANCTIONED_RE="${SANCTIONED_WORD}(worker-run|review-bench|llm-limits(\.sh)?|claude-session-driver|opencode-go|light-research|claudeb[[:space:]]+(revive|warm))${EDGE}"

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

command -v jq >/dev/null 2>&1 || exit 0
IFS= read -r -d '' input || :
parsed=$(jq -rn '[inputs] as $docs | $docs[] | select(.hook_event_name == "PreToolUse")
  | [.agent_type, .agent_id, .tool_input.run_in_background, .tool_input.timeout, .transcript_path] as $more
  | [.tool_name // "", .tool_input.command // "",
     ($docs | length) == 1 and all($more[]; type != "object" and type != "array"),
     ($more | to_entries[] | .key as $k | .value
       | if . == null or . == false then (if $k == 2 then "false" else "" end)
         elif type == "string" then . else tojson end)] | @sh' \
  <<<"$input" 2>/dev/null) || exit 0
fields=()
eval "fields=($parsed)"
tool=${fields[0]-} cmd=${fields[1]-}
input_field() { # jq path -> what `jq -r '<path> // empty'` prints for it (`// false` for run_in_background)
  local i
  case $1 in
    .agent_type) i=3 ;; .agent_id) i=4 ;; .tool_input.run_in_background) i=5 ;; .tool_input.timeout) i=6 ;;
    .transcript_path) i=7 ;;
  esac
  if [ "${#fields[@]}" = 8 ] && [ "${fields[2]}" = true ]; then
    printf '%s\n' "${fields[$i]}"
  elif [ "$1" = .tool_input.run_in_background ]; then
    printf '%s' "$input" | jq -r "$1 // false" 2>/dev/null
  else
    printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
  fi
}

# Every check below needs one of these words in the text it reads: each is a check's own literal with
# its command-position prefix dropped, which can only match more; a check added below needs its
# literal here too.
MAY_LAUNCH_RES=("(${VENDOR_BINS})${EDGE}" 'worker-run|review-bench|light-research|REVIEW_BENCH_DOOR'
  "${UNREADABLE_RUN_RE#"$VENDOR_WORD"}" "${OWNED_LEGS_RE#"$VENDOR_WORD"}" "${OWNED_IMAGE_RE#"$VENDOR_WORD"}"
  "${MEDIA_ENGINE_RE#"$VENDOR_WORD"}")
# The same words read off the raw command with builtins, before any fork: quotes and backslashes go
# as the full scan drops them, separators become spaces where the scan breaks lines, and a `$` beside
# an `=` may expand into any word. Only a word the scan joins out of a quoted space reads differently,
# and the shell runs no such word.
may_launch() {
  local text=${cmd//[\'\"\\]/} re
  text=${text//[;|&()\`]/ }
  case $text in *'$'*=* | *=*'$'*) return 0 ;; esac
  re="(^|[[:space:]])${SCHEDULE_RE#^}"
  [[ $text =~ $re ]] && return 0
  for re in "${MAY_LAUNCH_RES[@]}"; do
    [[ $text =~ $re ]] && return 0
  done
  return 1
}
case "$tool" in Bash | Monitor) may_launch || exit 0 ;; esac
# A Bash call that provably writes nothing runs no program, so it launches nothing. The forged-owner
# check reads the text with its quotes gone, so a call naming the token still takes the full path.
if [ "$tool" = Bash ]; then
  case "${cmd//[\'\"\\]/}" in
    *REVIEW_BENCH_DOOR*) ;;
    *) . "${READONLY_COMMAND_LIB:-$HOME/.claude/hooks/lib/readonly-command.sh}" 2>/dev/null &&
         rc_readonly_command "$cmd" && exit 0 ;;
  esac
fi
case "$tool" in
  Bash | Monitor) ;;
  mcp__codex__*)
    deny "Blocked: \`${tool}\` runs codex headless on this session's own codex login — no worker-run record, no task row naming the account, no workers switch. Work for a model is ${DIRECT_ASK}; Computer Use is a codex brief carrying \`COMPUTER: yes\`." ;;
  *) exit 0 ;;
esac
[ -n "$cmd" ] || exit 0

# A shell word, in command position, whose whole job is to interpret what it is fed: what stands
# around a `<<` decides whether the body is text or a program. Used by both passes below — the
# heredoc one asks it about the words on EITHER side of the `<<`, since `cat <<EOF | bash` and
# `<<EOF bash` feed a shell as squarely as `bash <<EOF` does; the `-c` one about the words before
# the quote.
SHELL_WORD="(^|[[:space:];|&(){}])([^[:space:]/]*/)*(ba|z|da|k)?sh"
HEREDOC_SHELL_RE="${SHELL_WORD}([[:space:]]+-[^[:space:]]+)*[[:space:]]*\$"
# On the far side, command position is the start of what follows the token or the other end of a
# chain link, so `cat <<EOF | grep sh` keeps its body as the text it is.
HEREDOC_POST_SHELL_RE="(^[[:space:]]*|[|;&][[:space:]]*)((${WRAPPER})[[:space:]]+)*([^[:space:]/]*/)*(ba|z|da|k)?sh([[:space:]]|\$)"
DASH_C_RE="${SHELL_WORD}([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[A-Za-z]*c[[:space:]]+\$"
# The other commands whose quoted operand is a program: `eval "…"`, `ssh host "…"`, `tmux new "…"`,
# `screen … "…"`, `watch "…"`, `su -c "…"` and `env -S "…"`.
PROGRAM_STRING_RE="${DASH_C_RE}|(^|[;|&(){}])[[:space:]]*(eval|ssh|tmux|screen|watch|su|env([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[A-Za-z]*S)([[:space:]]+[^[:space:]]+)*[[:space:]]+\$"

# Four passes, and their ORDER is the whole difference between reading a launch and inventing one.
# A heredoc body is text a command is FED, so it is blanked first (share/heredoc-mask.sh), while the
# line structure that says where the body ends is still intact — `cat > brief <<EOF` quoting
# `worker-run wait` is a brief being written, not a run being awaited, and masking can only lose a
# command, never invent one: `bash <<EOF` is scanned, `cat > f <<EOF` masked. Unloadable, nothing
# is masked, which can only deny more.
# A backslash-continued line is one command, so the join comes next: splitting there would
# sever a vendor name from the flag on the next line, which is how a long brief is routinely typed.
# Then quoted text loses its separators and its spaces, which is what makes it one operand word:
# strip the quotes first and `echo "x; codex exec"` grows a command position it never had, while
# `X="a b" claude -p` loses the env assignment that keeps the vendor word out of one. The one quoted
# span that is not an operand is a `sh -c` string, whose words the shell runs: it is broken out onto
# its own line instead. Only then are the quotes themselves dropped, so `'claude' -p` is a launch.
self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) && . "${self%/*}/../share/heredoc-mask.sh" 2>/dev/null ||
  heredoc_mask() { cat; }
prestrip=$(heredoc_mask "$HEREDOC_SHELL_RE" "$HEREDOC_POST_SHELL_RE" <<<"$cmd" |
  LC_ALL=C awk '{ if (sub(/\\[[:space:]]*$/, " ")) { printf "%s", $0; next } print }' |
  LC_ALL=C awk -v dashc="$PROGRAM_STRING_RE" 'BEGIN { out = ""; q = ""; body = 0 }
       {
         for (i = 1; i <= length($0); i++) {
           c = substr($0, i, 1)
           if (q == "") {
             if (c == "\\") { out = out c substr($0, i + 1, 1); i++; continue }
             if (c == "#" && (out == "" || out ~ /[[:space:];|&()]$/)) break
             if (c == "\047" || c == "\"") {
               q = c
               if (out ~ dashc) {
                 body = 1
                 c = "\n"
               }
             }
           }
           else if (q == "\"" && c == "\\") {
             c = substr($0, i + 1, 1)
             out = out "\\" ((!body && c ~ /[[:space:];|&()`]/) ? "" : c); i++; continue
           }
           else if (c == q) { q = ""; if (body) { body = 0; c = "\n" } }
           else if (!body && c ~ /[[:space:];|&()`]/) c = ""
           out = out c
         }
         # A quoted operand spanning lines (a commit message, a PR body) is still one word.
         if (q != "" && !body) next
         print out
         out = ""
       }
       END { if (out != "") print out }') || exit 0
scan=$(sed -e "s/[\\\\'\"]//g" <<<"$prestrip") || exit 0
# The pipe check reads the text before this split, the one form that still holds the pipes.
unsplit=$scan
scan=$(tr ';|&()`' '\n' <<<"$unsplit")
[ -n "$scan" ] || scan="$cmd"
[ -n "$unsplit" ] || unsplit="$cmd"

# `command` is a wrapper above because it hands its operand to the kernel — except with -v/-V, which
# only prints where a word lives and runs nothing. The whole segment goes, and after the fallback
# above, so a command that is nothing but lookups scans as empty instead of falling back to its own
# text; a lookup chained with a real launch keeps that launch on its own line. `type`, `which` and
# `hash` are commands in their own right, so their operand never reaches command position at all.
LOOKUP_RE='^[[:space:]]*command[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-[vV]([[:space:]]|$)'
scan=$(grep -Ev "$LOOKUP_RE" <<<"$scan")
scan_literal=$scan

# A command word held in a variable is the launch it names: `W=…/worker-run; $W start` ran two
# workers with no row (2026-09-24). Names assigned in this command are expanded in place; a value
# that itself holds a `$` is skipped, or its expansion would never end.
ASSIGN_RE='^[[:space:]]*((export|local|readonly|declare|typeset)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*=[^[:space:]$]+'
# The scan has joined a quoted value's words, and an unquoted `$C` splits them again (`C="codex
# exec"; $C hi`), so a quoted value is read off the raw command first, its spaces kept.
QUOTED_ASSIGN_RE="(^|[;&|({[:space:]])[A-Za-z_][A-Za-z0-9_]*=(\"[^\"\$\`\\\\&]*\"|'[^'\$\\\\&]*')"
assigned=()
while IFS= read -r assign; do
  [ -n "$assign" ] || continue
  assign=$(sed -E -e 's/^[[:space:]]*((export|local|readonly|declare|typeset)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?//' \
    -e "s/^[;&|({[:space:]]//; s/=[\"']/=/; s/[\"']\$//" <<<"$assign")
  assigned+=("$assign")
  scan=$(LC_ALL=C awk -v n="${assign%%=*}" -v v="${assign#*=}" '{
    gsub("\\$[{]" n "[}]", v)
    out = ""
    while (match($0, "\\$" n "([^A-Za-z0-9_]|$)")) {
      out = out substr($0, 1, RSTART - 1) v
      $0 = substr($0, RSTART + 1 + length(n))
    }
    print out $0 }' <<<"$scan")
done < <(grep -Eo "$QUOTED_ASSIGN_RE" <<<"$cmd"; grep -Eo "$ASSIGN_RE" <<<"$scan")

may_launch_args=(-e "$SCHEDULE_RE")
for re in "${MAY_LAUNCH_RES[@]}"; do may_launch_args+=(-e "$re"); done
grep -Eq "${may_launch_args[@]}" <<<"$unsplit"$'\n'"$scan" 2>/dev/null
[ $? -ne 1 ] || exit 0

agent_type=$(input_field .agent_type)
first_hit() { # regex
  local hit
  hit=$(grep -Eo "$1" <<<"$scan" 2>/dev/null) || return 0
  printf '%s\n' "${hit%%$'\n'*}" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}
forged=$(grep -Eo "$FORGED_TOKEN_RE" <<<"$scan" 2>/dev/null | head -n1 | grep -Eo '(REVIEW_BENCH_DOOR)=$')
[ -z "$forged" ] ||
  deny "Blocked: \`${forged%=}\` is stamped by the hooks alone — it names the review Egor's word opened — and a command setting it by hand forges that owner. A review is launched plainly from the chat's own shell on his word."
# A Monitor is a background command like any other, so every check below reads it too. The review
# door is registered for Bash alone, so a Monitor launching a panel would skip his word.
if [ "$tool" = Monitor ]; then
  monitor_hit=$(first_hit "${VENDOR_WORD}(worker-run|review-bench)[[:space:]]+wait${EDGE}")
  [ -z "$monitor_hit" ] ||
    deny "Blocked: a Monitor polling \`${monitor_hit}\` re-reads the run every round. Run \`${monitor_hit} <run-id>\` once as a Bash call with \`run_in_background: true\`: it blocks until the run ends, streams its progress to /tasks, and its completion notification wakes this chat."
  monitor_review=$(grep -Ev -e "$REVIEW_IDLE_RE" <<<"$scan" 2>/dev/null | grep -Eo "$REVIEW_LAUNCH_RE" | head -n1)
  [ -z "$monitor_review" ] ||
    deny "Blocked: a Monitor running \`$(tr -s '[:space:]' ' ' <<<"$monitor_review" | sed -e 's/^ //' -e 's/ $//')\` launches a review panel past the door that holds it for Egor's word. Launch it with a plain Bash call from this chat on his word, then run \`review-bench wait <run-id>\` as a background Bash."
fi
# A review panel spends the chat's grant and a pool of accounts, and only the chat's own shell holds
# that grant; a worker run likewise belongs to the chat that waits on it. An agent of any type or a
# headless worker launching either is a run nobody granted and nobody waits on.
agent_id=$(input_field .agent_id)
if [ -n "$agent_id" ] || [ "${CLAUDEB_WORKER:-}" = 1 ]; then
  worker_review_hit=$(grep -Ev -e "$REVIEW_IDLE_RE" <<<"$scan" 2>/dev/null | grep -Eo "$REVIEW_LAUNCH_RE" | head -n1 |
    tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
  [ -n "$worker_review_hit" ] || worker_review_hit=$(first_hit "$WORKER_REVIEW_RE")
  [ -z "$worker_review_hit" ] ||
    deny "Blocked: \`${worker_review_hit}\` inside an agent or a headless worker launches review cells on a grant that is the chat's alone, spending a pool of accounts nobody granted. An agent never runs a review: report that one is due, and the chat launches it from its own shell on Egor's word."
  owned_hit=$(first_hit "$OWNED_RUN_RE")
  [ -n "$owned_hit" ] || owned_hit=$(first_hit "$UNREADABLE_RUN_RE")
  [ -z "$owned_hit" ] ||
    deny "Blocked: \`${owned_hit}\` inside an agent or a headless worker starts or awaits a worker run that belongs to the chat: the chat starts it, waits on it as a background Bash and reads its report. Report what should be delegated in your RETURN instead. \`worker-run report\`, \`worker-run claim\` and the test suites are not gated."
fi
legs_hit=$(grep -E "$OWNED_LEGS_RE" <<<"$scan" 2>/dev/null | grep -Ev -e "$LEGS_FREE_RE" | head -n1 |
  grep -Eo "$OWNED_LEGS_RE" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
[ -z "$legs_hit" ] || span_live ||
  deny "Blocked: \`${legs_hit}\` spends a Claude, Codex or Gemini account from Claude Code's Bash with no worker-run record naming the account. A question for a model is ${DIRECT_ASK}; a live probe is Egor's to run — hand him the paste-ready command for his own terminal."
HELP_TAIL='([[:space:]]+[0-9]*[<>]+[[:space:]]*[^[:space:]]*)*[[:space:]]*$'
# Exempt by line and only as typed: a wrapper (`xargs -J --help`) or an expanded `$VAR` makes a line
# that reads as help yet runs the script with other arguments.
image_help_re="^[[:space:]]*([^[:space:]/]*/)*${OWNED_IMAGE_RE#"$VENDOR_WORD"}"
image_help_re="${image_help_re%"$EDGE"}[[:space:]]+(-h|--help)${HELP_TAIL}"
typed=$(tr ';|&()`' '\n' <<<"$prestrip" | grep -v "[\\\\'\"]")
literal=()
while IFS= read -r line; do literal+=("$line"); done <<<"$scan_literal"
image_scan=$(i=0
  while IFS= read -r line; do
    [ "$line" = "${literal[i]-}" ] && [[ $line =~ $image_help_re ]] && grep -Fxq -- "$line" <<<"$typed" ||
      printf '%s\n' "$line"
    i=$((i + 1))
  done <<<"$scan")
image_hit=$(scan=$image_scan; first_hit "$OWNED_IMAGE_RE")
[ -n "$image_hit" ] || image_hit=$(first_hit "$MEDIA_ENGINE_RE")
[ -z "$image_hit" ] ||
  deny "Blocked: \`${image_hit}\` runs media past \`media-run\`, the one door that renders the account it spends: load the media skill, write the prompt yourself and run \`media-run <kind> --vendor <v> -- <the script's own args>\` (\`media-run --help\` lists the kinds) (several vendors, \`--takes\` or \`--jobs\` fan out). Quoting one inside a heredoc body is not running it."

unsanctioned=$(grep -Ev "$SANCTIONED_RE" <<<"$scan")
launch_ask="A worker is ${DIRECT_ASK}"
# A vendor CLI fed on stdin runs headless with no print flag, and a scheduler runs its command later,
# where no gate reads it.
piped=$(grep -Eo "(^|[^|])[|][[:space:]]*((${WRAPPER})[[:space:]]+)*([^[:space:]/|;&]*/)*(${VENDOR_BINS})([[:space:]]+[^[:space:]|;&]+)?([[:space:]]|\$)" <<<"$unsplit" 2>/dev/null |
  grep -Ev "[|][[:space:]]*claudeb[[:space:]]+(revive|warm)[[:space:]]*\$" | head -n1 | sed -E 's/^[^|]*[|][[:space:]]*//' | tr -s '[:space:]' ' ' | sed -e 's/ $//')
[ -z "$piped" ] || deny "Blocked: a pipe into \`${piped}\` runs it headless on its stdin — a bare vendor launch. ${launch_ask}."
scheduled=$(grep -E "$SCHEDULE_RE" <<<"$scan" 2>/dev/null |
  grep -Ev '^[[:space:]]*crontab([[:space:]]+-u[[:space:]]+[^[:space:]]+)?[[:space:]]+-l[[:space:]]*$' | head -n1 |
  tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
[ -z "$scheduled" ] || span_live || deny "Blocked: \`${scheduled}\` schedules a command to run later, outside every gate and every task row. Run the work now through its owner; a scheduled job is Egor's to set up — hand him the paste-ready command."
# `help` is a subcommand only to some CLIs; to gemini and claude it is a positional prompt, so a flag
# after it (`gemini help -p "fix x"`) is a headless launch. A help line is exempt only as a segment
# that held no quote or backslash before stripping: `sh -c "claude -p 'ls -h'"` strips to a help line.
HELP_RE="${VENDOR_WORD}(${VENDOR_BINS})(${SUBCOMMAND}(-h|--help)${HELP_TAIL}|[[:space:]]+help([[:space:]]+[^[:space:]-][^[:space:]]*)*${HELP_TAIL})"
help_lines=$(grep -E "$HELP_RE" <<<"$unsanctioned" |
  grep -Fx -f <(printf '%s\n' "$typed"))
[ -z "$help_lines" ] || unsanctioned=$(grep -Fxv -f <(printf '%s\n' "$help_lines") <<<"$unsanctioned")
launch_any=()
for launch_re in "${LAUNCH_RES[@]}"; do launch_any+=(-e "$launch_re"); done
grep -Eq "${launch_any[@]}" <<<"$unsanctioned" 2>/dev/null || LAUNCH_RES=()
for launch_re in ${LAUNCH_RES[@]+"${LAUNCH_RES[@]}"}; do
  hit=$(grep -Eo "$launch_re" <<<"$unsanctioned" 2>/dev/null) || continue
  hit=$(printf '%s\n' "${hit%%$'\n'*}" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
  [ -n "$hit" ] || continue
  deny "Blocked: \`${hit}\` is a bare headless vendor launch — it leaves no worker-run record, no statusline tag, no journal ownership, no pool refusal, no limit signature and no stall watch. ${launch_ask}; the other tools own their launches (review-bench, llm-limits, claudeb revive, claude-session-driver, opencode-go; the media scripts are reached through media-run). An interactive launch — no -p/--print/--prompt, no exec, no run — is not gated. Quotes and backslashes do not hide a launch: the gate strips them, then reads the first word of every chained command, and a sanctioned tool exempts only its own segment."
done
exit 0
exit; }
