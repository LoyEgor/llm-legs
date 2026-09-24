#!/usr/bin/env bash
# A vendor launched as a bare headless CLI call from a chat's Bash is a worker nobody can see: no
# worker-run record, no statusline tag, no journal ownership, no pool refusal, no limit signature,
# no stall watch. This door denies that spelling so every headless run reaches a launcher that owns
# it — the sanctioned list is docs/routing-contract.md rule 4 and the share/worker-pool.sh header.
#
# Two lists and no judgement between them. LAUNCH_RES is a vendor binary plus the flag or
# subcommand that makes it print-and-exit; SANCTIONED_RE is the tools that own their launches. A
# command naming a sanctioned launcher anywhere passes whatever else it spells — `worker-run start
# codex` beside a brief that quotes `codex exec` is the shape that exemption exists for.
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
# The same door has a second side, the OWNED class: a launcher that is sanctioned only in the hands
# of the agent type owning it. `worker-run start|wait` belongs to the relay agents and the image
# scripts to `image-gen`. A run started or awaited from the main chat's Bash is owned by a turn
# instead of an agent — no magenta tagged row, and nothing to wake the chat when it ends — and an
# image generated there spends an account nothing renders. `report` prints a finished record and
# spends nothing, and the commit-journal and edit-conflict hooks name it to the chat itself.
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
WRAPPER="(env|command|exec|nohup|nice|time|timeout|stdbuf|setsid|sudo|xargs)([[:space:]]+(-[^[:space:]]*|[0-9][^[:space:]]*))*"
VENDOR_WORD="^[[:space:]]*(${KEYWORD})*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|${WRAPPER})[[:space:]]+)*([^[:space:]/]*/)*"
# The flag or subcommand that turns a vendor CLI into a headless run, reached past any number of
# other flags.
PRINT_FLAG="([[:space:]]+[^[:space:]]+)*[[:space:]]+(-p|--print|--prompt)${EDGE}"
SUBCOMMAND="([[:space:]]+[^[:space:]]+)*[[:space:]]+"

# Grok's own spellings, not reusable from PRINT_FLAG: folding it back in would let
# `grokb ... --prompt-file` and `grokb agent` through.
GROK_PRINT_FLAG="([[:space:]]+[^[:space:]]+)*[[:space:]]+(-p|--print|--prompt(-file|-json)?(=[^[:space:]]*)?|agent)${EDGE}"

LAUNCH_RES=(
  "${VENDOR_WORD}claudeb?${PRINT_FLAG}"
  # `claudeb?` cannot reach it: the `gpt` sits where that alternation expects a separator, and a
  # `claudegpt p <acct> -p` run is a print run spending a Codex account like any other.
  "${VENDOR_WORD}claudegpt${PRINT_FLAG}"
  "${VENDOR_WORD}codexb?${SUBCOMMAND}exec${EDGE}"
  "${VENDOR_WORD}geminib?${PRINT_FLAG}"
  "${VENDOR_WORD}agy${PRINT_FLAG}"
  "${VENDOR_WORD}opencode${SUBCOMMAND}run${EDGE}"
  "${VENDOR_WORD}grokb?${GROK_PRINT_FLAG}"
)

# The worker-run subcommands that own a run's LIFE, judged in command position like every vendor
# word above. `claim` is bookkeeping any surface may do, `report` only prints a record that already
# exists, and a bare `worker-run` prints help, so none of the three is here;
# `bash tests/test_worker_run.sh` has `bash` in command position and is not a run.
OWNED_RUN_RE="${VENDOR_WORD}worker-run[[:space:]]+(start|wait)${EDGE}"
# A variable this door could not expand, standing where worker-run would, is read as worker-run.
UNREADABLE_RUN_RE="${VENDOR_WORD}[\$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?[[:space:]]+(start|wait)${EDGE}"

# The image scripts are owned the same way and by ONE agent. Run from the main chat's Bash they
# spend an image account with nothing rendering the spend — no task row, no tag, no notification —
# so `image-gen` is the only hand they pass in, a relay's included: a worker generating an image is
# a launch inside a launch nobody can see.
OWNED_IMAGE_RE="${VENDOR_WORD}((codex|gemini|grok)-image|grok-video|image-fanout)${EDGE}"

# A review run's wait is owned the same way, by the `review-waiter` agent, and light-research by its
# own agent type: from the chat's Bash neither has a row nor anything that wakes the chat.
OWNED_REVIEW_WAIT_RE="${VENDOR_WORD}review-bench[[:space:]]+wait${EDGE}"
OWNED_RESEARCH_RE="${VENDOR_WORD}light-research${EDGE}"
WAIT_ASK="wait through the ATTACH relay / review-waiter agent so the run has a magenta row"

SANCTIONED_RE='(^|[[:space:]])([^[:space:]/]*/)*(worker-run|review-bench|llm-limits(\.sh)?|claude-session-driver|opencode-go|light-research)([[:space:]]|$)|(^|[[:space:]])([^[:space:]/]*/)*claudeb[[:space:]]+(revive|warm)([[:space:]]|$)'

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' \
    2>/dev/null
  exit 0
}

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat) || exit 0
tool=$(printf '%s' "$input" | jq -r 'select(.hook_event_name == "PreToolUse") | .tool_name // empty' 2>/dev/null) ||
  exit 0
case "$tool" in Bash | Monitor) ;; *) exit 0 ;; esac
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
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

# Four passes, and their ORDER is the whole difference between reading a launch and inventing one.
# A heredoc body is text a command is FED, so it is blanked first, while the line structure that
# says where the body ends is still intact — `cat > brief <<EOF` quoting `worker-run wait` is a
# brief being written, not a run being awaited, and masking can only lose a command, never invent
# one. Which is why the `<<` has to be a REAL heredoc before anything is blanked: outside quotes,
# and with its delimiter line actually present later. A `<<` inside quotes is text — `echo '<<X';
# worker-run wait id` is a run — and one whose delimiter never arrives opens no body at all, so
# blanking from it would swallow every command that follows. The one heredoc whose body is not text
# is the one fed to a SHELL, which runs those lines: `bash <<EOF` is scanned, `cat > f <<EOF` masked.
# A backslash-continued line is one command, so the join comes next: splitting there would
# sever a vendor name from the flag on the next line, which is how a long brief is routinely typed.
# Then quoted text loses its separators and its spaces, which is what makes it one operand word:
# strip the quotes first and `echo "x; codex exec"` grows a command position it never had, while
# `X="a b" claude -p` loses the env assignment that keeps the vendor word out of one. The one quoted
# span that is not an operand is a `sh -c` string, whose words the shell runs: it is broken out onto
# its own line instead. Only then are the quotes themselves dropped, so `'claude' -p` is a launch.
scan=$(awk -v shellfed="$HEREDOC_SHELL_RE" -v postshell="$HEREDOC_POST_SHELL_RE" '
       # Everything a heredoc body still EXECUTES when its delimiter is unquoted: the shell expands
       # such a body, so `$( … )` and a backtick span inside it are command lines, and masking them
       # with the text around them would blank a run the shell is about to make. Their contents are
       # kept, chained with `;`, and everything else on the line goes.
       function subst_only(s,   i, c, out, depth, buf) {
         out = ""
         i = 1
         while (i <= length(s)) {
           c = substr(s, i, 1)
           if (c == "$" && substr(s, i + 1, 1) == "(") {
             depth = 1; i += 2; buf = ""
             while (i <= length(s) && depth > 0) {
               c = substr(s, i, 1)
               if (c == "(") depth++
               else if (c == ")") { depth--; if (depth == 0) { i++; break } }
               buf = buf c
               i++
             }
             out = out buf ";"
             continue
           }
           if (c == "`") {
             i++; buf = ""
             while (i <= length(s) && substr(s, i, 1) != "`") { buf = buf substr(s, i, 1); i++ }
             i++
             out = out buf ";"
             continue
           }
           i++
         }
         return out
       }
       function find_heredoc(line,   i, c, q, rest) {
         q = ""
         for (i = 1; i <= length(line); i++) {
           c = substr(line, i, 1)
           # A backslash escapes inside DOUBLE quotes and outside them, never inside single ones.
           # Missing that, `echo "a\"b <<EOF"` closes the quote a character early and the rest of
           # the line reads as bare text, so the `<<EOF` inside the string is taken for a real
           # heredoc and blanks the commands that follow it.
           if (q != "") {
             if (q == "\"" && c == "\\") { i++; continue }
             if (c == q) q = ""
             continue
           }
           if (c == "\\") { i++; continue }
           if (c == "\047" || c == "\"") { q = c; continue }
           if (c != "<") continue
           # A herestring is not a heredoc, and its word would read as a delimiter that never closes.
           if (substr(line, i, 3) == "<<<") { i += 2; continue }
           if (substr(line, i + 1, 1) != "<") continue
           rest = substr(line, i)
           if (match(rest, /^<<-?[[:space:]]*("[^"]*"|\047[^\047]*\047|\\?[A-Za-z_][A-Za-z0-9_.-]*)/)) {
             HD_TOK = substr(rest, RSTART, RLENGTH)
             HD_PRE = substr(line, 1, i - 1)
             HD_POST = substr(line, i + RLENGTH)
             return 1
           }
           i++
         }
         return 0
       }
       { line[NR] = $0 }
       END {
         for (i = 1; i <= NR; i++) {
           if (!find_heredoc(line[i])) continue
           dash = (substr(HD_TOK, 3, 1) == "-")
           delim = HD_TOK
           sub(/^<<-?[[:space:]]*/, "", delim)
           # A quoted or backslashed delimiter is the one spelling that turns expansion OFF, so an
           # unexpanded body is inert text all the way down.
           expand = (delim !~ /^["\047\\]/)
           gsub(/["\047\\]/, "", delim)
           end = 0
           for (j = i + 1; j <= NR; j++) {
             probe = line[j]
             if (dash) sub(/^\t+/, "", probe)
             if (probe == delim) { end = j; break }
           }
           if (!end) continue
           mask[end] = 1
           if (HD_PRE !~ shellfed && HD_POST !~ postshell)
             for (k = i + 1; k < end; k++) {
               mask[k] = 1
               if (expand) keep[k] = subst_only(line[k])
             }
           i = end
         }
         for (i = 1; i <= NR; i++) print (i in mask) ? ((i in keep) ? keep[i] : "") : line[i]
       }' <<<"$cmd" |
  awk '{ if (sub(/\\[[:space:]]*$/, " ")) { printf "%s", $0; next } print }' |
  awk -v dashc="$DASH_C_RE" '{ out = ""; q = ""; body = 0
         for (i = 1; i <= length($0); i++) {
           c = substr($0, i, 1)
           if (q == "") {
             if (c == "\047" || c == "\"") {
               q = c
               if (out ~ dashc) {
                 body = 1
                 c = "\n"
               }
             }
           }
           else if (c == q) { q = ""; if (body) { body = 0; c = "\n" } }
           else if (!body && c ~ /[[:space:];|&()`]/) c = ""
           out = out c
         }
         print out }' |
  sed -e "s/[\\\\'\"]//g" | tr ';|&()`' '\n') || exit 0
[ -n "$scan" ] || scan="$cmd"

# `command` is a wrapper above because it hands its operand to the kernel — except with -v/-V, which
# only prints where a word lives and runs nothing. The whole segment goes, and after the fallback
# above, so a command that is nothing but lookups scans as empty instead of falling back to its own
# text; a lookup chained with a real launch keeps that launch on its own line. `type`, `which` and
# `hash` are commands in their own right, so their operand never reaches command position at all.
LOOKUP_RE='^[[:space:]]*command[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-[vV]([[:space:]]|$)'
scan=$(grep -Ev "$LOOKUP_RE" <<<"$scan")

# A command word held in a variable is the launch it names: `W=…/worker-run; $W start` ran two
# workers with no row (2026-09-24). Names assigned in this command are expanded in place; a value
# that itself holds a `$` is skipped, or its expansion would never end.
ASSIGN_RE='^[[:space:]]*((export|local|readonly|declare|typeset)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*=[^[:space:]$]+'
while IFS= read -r assign; do
  [ -n "$assign" ] || continue
  assign=$(sed -E 's/^[[:space:]]*((export|local|readonly|declare|typeset)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?//' <<<"$assign")
  scan=$(awk -v n="${assign%%=*}" -v v="${assign#*=}" '{
    gsub("\\$[{]" n "[}]", v)
    out = ""
    while (match($0, "\\$" n "([^A-Za-z0-9_]|$)")) {
      out = out substr($0, 1, RSTART - 1) v
      $0 = substr($0, RSTART + 1 + length(n))
    }
    print out $0 }' <<<"$scan")
done < <(grep -Eo "$ASSIGN_RE" <<<"$scan")

# Inside a relay agent this whole door behaves as it always has; everywhere else — the main chat
# above all — a worker-run that starts or awaits a run is denied, because the run would then belong
# to a Bash turn nobody can see instead of to the agent whose row shows who is spending quota.
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)
first_hit() { # regex
  grep -Eo "$1" <<<"$scan" 2>/dev/null | head -n1 |
    tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}
# A Monitor is a background command like any other, so every check below reads it too.
if [ "$tool" = Monitor ]; then
  monitor_hit=$(first_hit "${VENDOR_WORD}(worker-run|review-bench)[[:space:]]+wait${EDGE}")
  [ -z "$monitor_hit" ] || deny "Blocked: a Monitor on \`${monitor_hit}\` owns no task row — ${WAIT_ASK}."
fi
case "$agent_type" in
  image-gen) ;;
  *)
    image_hit=$(first_hit "$OWNED_IMAGE_RE")
    [ -z "$image_hit" ] ||
      deny "Blocked: \`${image_hit}\` generates an image from this chat's own Bash, where the account it spends renders as nothing — no tagged row, no notification when it lands. Spawn the \`image-gen\` Agent instead and put the description, the absolute destination path, the format, transparency yes/no and the size in its brief; it owns these five scripts and is the only agent type that may run them — a relay worker may not either. Quoting one inside a heredoc body is not running it."
    ;;
esac
case "$agent_type" in
  review-waiter) ;;
  *)
    # Inside a headless worker process no task row exists to give the wait to.
    if [ -z "$agent_type" ] && [ "${CLAUDEB_WORKER:-}" = 1 ]; then :; else
      review_wait_hit=$(first_hit "$OWNED_REVIEW_WAIT_RE")
      if [ -n "$review_wait_hit" ]; then
        recovery=$(grep -Eo -e '--(relaunch|finish-partial)' <<<"$scan" 2>/dev/null | head -n1)
        if [ -n "$recovery" ]; then
          deny "Blocked: \`${review_wait_hit} ${recovery}\` from this Bash owns no task row — ${WAIT_ASK}. Spawn \`review-waiter\` with the brief \`ATTACH <run-id>: ${recovery}\`; it runs the recovery itself and waits the run out."
        fi
        deny "Blocked: \`${review_wait_hit}\` from this Bash owns no task row — ${WAIT_ASK}. \`review-bench review\` returns at once and stays sanctioned; spawn \`review-waiter\` with a brief \`WAIT <run-id>: <what>\`, or \`ATTACH <run-id>: --relaunch\` / \`ATTACH <run-id>: --finish-partial\` for a dead or interrupted run."
      fi
    fi
    ;;
esac
case "$agent_type" in
  light-research) ;;
  *)
    research_hit=$(first_hit "$OWNED_RESEARCH_RE")
    [ -z "$research_hit" ] ||
      deny "Blocked: \`${research_hit}\` runs a research leg from this chat's own Bash, where it has no tagged row and nothing wakes the chat when it lands. Spawn the \`light-research\` Agent with the question, the absolute repository paths and the wanted answer shape; it runs the launcher itself."
    ;;
esac
case "$agent_type" in
  claudeb-worker | codex-worker | gemini-worker | grok-worker | light-worker | image-gen) ;;
  *)
    owned_hit=$(first_hit "$OWNED_RUN_RE")
    [ -n "$owned_hit" ] || owned_hit=$(first_hit "$UNREADABLE_RUN_RE")
    [ -z "$owned_hit" ] ||
      deny "Blocked: \`${owned_hit}\` runs the worker from this chat's own Bash. A worker run must be owned by a relay agent for its whole life — that ownership is what renders it as a magenta tagged row in the task list and what wakes the chat when the run ends, while a Bash wait owns nothing and dies with the turn. Launch it by spawning the matching Agent (\`claudeb-worker\`, \`codex-worker\`, \`gemini-worker\`, \`grok-worker\`, \`light-worker\`), which does the \`worker-run start\` itself; to re-attach to a run already in flight, spawn THE SAME agent type again with a brief starting \`ATTACH <run-id>:\` — never a background Bash wait. \`worker-run report\` (it only prints a record), \`worker-run claim\`, a bare \`worker-run\` and the test suites are not gated."
    ;;
esac

# A relay's own side of the same ownership: the wait must outlive the poll it asks for. The Bash
# tool's default timeout is 120s, so `--max 540` is killed a fifth of the way in — the run keeps
# spending an account with nobody waiting on it, no checkpoint and no notification, which is the
# invisible run this whole door exists to prevent. The call carries its own timeout; require it.
# The default is read out of worker-run rather than restated here: the two disagreeing would deny
# one spelling of a poll and wave the identical other one through. 540 is the largest `--max` the
# harness's own 600000ms ceiling can cover, so an unreadable value has to be taken for that.
WAIT_CEILING=540
HARNESS_TIMEOUT_MAX=600000
wait_default=$(grep -m1 -Eo 'run_id="\$1" max=[0-9]+' \
  "$HOME/.local/bin/worker-run" 2>/dev/null | grep -Eo '[0-9]+$')
[[ "$wait_default" =~ ^[0-9]+$ ]] || wait_default=100

case "$agent_type" in
  claudeb-worker | codex-worker | gemini-worker | grok-worker | light-worker | image-gen)
    wait_lines=$(grep -E "${VENDOR_WORD}worker-run[[:space:]]+wait${EDGE}" <<<"$scan" 2>/dev/null)
    if [ -n "$wait_lines" ]; then
      wait_max=$(grep -Eo -- '--max[[:space:]]+[0-9]+' <<<"$wait_lines" 2>/dev/null |
        grep -Eo '[0-9]+' | sort -rn | head -n1)
      # A `--max` whose value is a variable or a substitution states no duration at all, and the
      # poll it hides is the one this guard exists for; a wait with no `--max` is not unbounded
      # either — it polls worker-run's default, and letting that spelling pass while denying the
      # identical explicit number is two verdicts for one poll.
      if grep -Eq -- '--max[[:space:]]+[^0-9[:space:]]' <<<"$wait_lines" 2>/dev/null; then
        wait_max=$WAIT_CEILING
        wait_says="\`--max\` here is spelled with a variable, so the gate has to read it as the ${WAIT_CEILING}s ceiling"
      elif [ -z "$wait_max" ]; then
        wait_max=$wait_default
        wait_says="this wait carries no \`--max\`, so worker-run polls its default ${wait_max}s"
      else
        wait_says="\`worker-run wait … --max ${wait_max}\` polls for up to ${wait_max}s"
      fi
      wait_needed=$(((10#$wait_max + 30) * 1000))
      # Above the ceiling no timeout the harness accepts can cover the poll, so asking for one
      # would be an instruction nobody can carry out: the only answer left is a shorter `--max`.
      [ "$wait_needed" -le "$HARNESS_TIMEOUT_MAX" ] ||
        deny "Blocked: ${wait_says}, and no Bash timeout can cover it — the harness caps \`timeout\` at ${HARNESS_TIMEOUT_MAX}ms, which is ${WAIT_CEILING}s of polling plus its margin. Retry with \`--max ${WAIT_CEILING}\` or lower and \`timeout: ${HARNESS_TIMEOUT_MAX}\`."
      call_timeout=$(printf '%s' "$input" | jq -r '.tool_input.timeout // empty' 2>/dev/null)
      [[ "$call_timeout" =~ ^[0-9]+$ ]] || call_timeout=0
      [ "$call_timeout" -ge "$wait_needed" ] ||
        deny "Blocked: ${wait_says}, but this Bash call carries a timeout of ${call_timeout}ms — the harness kills it mid-poll and the run goes on with nobody waiting on it, no checkpoint and no wake-up. Retry the identical call with \`timeout: 600000\` (at least ${wait_needed}), or spell a literal \`--max\` that fits the timeout you pass."
    fi
    ;;
esac

# A relay is a pipe: the brief's MODEL: line IS the launch's --model, and its ACCOUNT: line the
# --account. A relay that resolves a family word itself hands worker-run a full slug, which reads as
# a deliberate pin (live 2026-09-23: `MODEL: sol` launched as gpt-5.6-sol off a stale list). The
# brief is the relay's first prompt in its own transcript; without that transcript nothing is judged.
relay_brief() {
  local transcript own agent_id
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
  agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
  case "$transcript" in
    */subagents/*.jsonl) own=$transcript ;;
    *.jsonl) [ -n "$agent_id" ] || return 0; own="${transcript%.jsonl}/subagents/agent-$agent_id.jsonl" ;;
    *) return 0 ;;
  esac
  [ -r "$own" ] || return 0
  head -n 5 "$own" | jq -rR 'fromjson? | select(type == "object" and .type == "user") | .message.content
    | if type == "string" then . else ([.[]? | select(.type? == "text") | .text] | join("\n")) end' \
    2>/dev/null | head -n 400
}
brief_value() { grep -m1 -oE "^$1:[[:space:]]*[A-Za-z0-9_.-]+" <<<"$brief" | sed -E "s/^$1:[[:space:]]*//"; }
flag_value() {
  grep -oE -e "--$1(=|[[:space:]]+)[\"']?[A-Za-z0-9_.-]+" <<<"$start_line" | head -n 1 |
    sed -E "s/^--$1(=|[[:space:]]+)[\"']?//"
}
case "$agent_type" in
  claudeb-worker | codex-worker | gemini-worker | grok-worker | light-worker)
    start_line=$(grep -E "${VENDOR_WORD}worker-run[[:space:]]+start${EDGE}" <<<"$scan" 2>/dev/null | head -n 1)
    [ -z "$start_line" ] || brief=$(relay_brief)
    if [ -n "$start_line" ] && [ -n "${brief:-}" ]; then
      want_model=$(brief_value MODEL)
      [ "$agent_type" != light-worker ] || want_model=''
      have_model=$(flag_value model)
      if [ "$have_model" != "$want_model" ]; then
        if [ -z "$want_model" ]; then
          deny "Blocked: this launch passes \`--model ${have_model}\`, but the brief carries no MODEL: line$([ "$agent_type" != light-worker ] || printf ' (a light-worker never passes one: the light row decides)'). Drop \`--model\`; worker-run resolves the default itself."
        fi
        deny "Blocked: the brief says \`MODEL: ${want_model}\`, so the launch passes \`--model ${want_model}\` exactly as written$([ -z "$have_model" ] || printf ', not `--model %s`' "$have_model"). Never resolve a family word into a slug yourself: worker-run resolves it on the account the run lands on, and a full slug would pin that version."
      fi
      want_account=$(brief_value ACCOUNT)
      have_account=$(flag_value account)
      [ -z "$want_account" ] || [ "$have_account" = "$want_account" ] ||
        deny "Blocked: the brief says \`ACCOUNT: ${want_account}\`, so the launch passes \`--account ${want_account}\`$([ -z "$have_account" ] || printf ', not `--account %s`' "$have_account")."
    fi
    ;;
esac

grep -Eq "$SANCTIONED_RE" <<<"$cmd" && exit 0

for launch_re in "${LAUNCH_RES[@]}"; do
  hit=$(grep -Eo "$launch_re" <<<"$scan" 2>/dev/null | head -n1 |
    tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
  [ -n "$hit" ] || continue
  deny "Blocked: \`${hit}\` is a bare headless vendor launch — it leaves no worker-run record, no statusline tag, no journal ownership, no pool refusal, no limit signature and no stall watch. Launch it through \`worker-run start <claudeb|codex|gemini|grok> --brief <file> --workdir <dir>\`, or through the tool that owns its launches (review-bench, llm-limits, claudeb revive, claude-session-driver, opencode-go; the image scripts belong to the image-gen Agent). An interactive launch — no -p/--print/--prompt, no exec, no run — is not gated. Quotes and backslashes do not hide a launch: the gate strips them, then reads the first word of every chained command."
done
exit 0
