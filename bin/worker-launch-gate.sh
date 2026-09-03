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

# The image scripts are owned the same way and by ONE agent. Run from the main chat's Bash they
# spend an image account with nothing rendering the spend — no task row, no tag, no notification —
# so `image-gen` is the only hand they pass in, a relay's included: a worker generating an image is
# a launch inside a launch nobody can see.
OWNED_IMAGE_RE="${VENDOR_WORD}(codex|gemini|grok)-image${EDGE}"

SANCTIONED_RE='(^|[[:space:]])([^[:space:]/]*/)*(worker-run|review-bench|llm-limits(\.sh)?|claude-session-driver|opencode-go)([[:space:]]|$)|(^|[[:space:]])([^[:space:]/]*/)*claudeb[[:space:]]+(revive|warm)([[:space:]]|$)'

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' \
    2>/dev/null
  exit 0
}

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat) || exit 0
printf '%s' "$input" | jq -e '.hook_event_name == "PreToolUse" and .tool_name == "Bash"' \
  >/dev/null 2>&1 || exit 0
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

# Inside a relay agent this whole door behaves as it always has; everywhere else — the main chat
# above all — a worker-run that starts or awaits a run is denied, because the run would then belong
# to a Bash turn nobody can see instead of to the agent whose row shows who is spending quota.
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)
first_hit() { # regex
  grep -Eo "$1" <<<"$scan" 2>/dev/null | head -n1 |
    tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}
case "$agent_type" in
  image-gen) ;;
  *)
    image_hit=$(first_hit "$OWNED_IMAGE_RE")
    [ -z "$image_hit" ] ||
      deny "Blocked: \`${image_hit}\` generates an image from this chat's own Bash, where the account it spends renders as nothing — no tagged row, no notification when it lands. Spawn the \`image-gen\` Agent instead and put the description, the absolute destination path, the format, transparency yes/no and the size in its brief; it owns these three scripts and is the only agent type that may run them — a relay worker may not either. Quoting one inside a heredoc body is not running it."
    ;;
esac
case "$agent_type" in
  claudeb-worker | codex-worker | gemini-worker | grok-worker | image-gen) ;;
  *)
    owned_hit=$(first_hit "$OWNED_RUN_RE")
    [ -z "$owned_hit" ] ||
      deny "Blocked: \`${owned_hit}\` runs the worker from this chat's own Bash. A worker run must be owned by a relay agent for its whole life — that ownership is what renders it as a magenta tagged row in the task list and what wakes the chat when the run ends, while a Bash wait owns nothing and dies with the turn. Launch it by spawning the matching Agent (\`claudeb-worker\`, \`codex-worker\`, \`gemini-worker\`, \`grok-worker\`), which does the \`worker-run start\` itself; to re-attach to a run already in flight, spawn THE SAME agent type again with a brief starting \`ATTACH <run-id>:\` — never a background Bash wait. \`worker-run report\` (it only prints a record), \`worker-run claim\`, a bare \`worker-run\` and the test suites are not gated."
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
wait_default=$(grep -m1 -Eo 'run_id="\$1" max=[0-9]+' \
  "$HOME/.local/bin/worker-run" 2>/dev/null | grep -Eo '[0-9]+$')
[[ "$wait_default" =~ ^[0-9]+$ ]] || wait_default=100

case "$agent_type" in
  claudeb-worker | codex-worker | gemini-worker | grok-worker)
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
      wait_needed=$(((wait_max + 30) * 1000))
      call_timeout=$(printf '%s' "$input" | jq -r '.tool_input.timeout // empty' 2>/dev/null)
      [[ "$call_timeout" =~ ^[0-9]+$ ]] || call_timeout=0
      [ "$call_timeout" -ge "$wait_needed" ] ||
        deny "Blocked: ${wait_says}, but this Bash call carries a timeout of ${call_timeout}ms — the harness kills it mid-poll and the run goes on with nobody waiting on it, no checkpoint and no wake-up. Retry the identical call with \`timeout: 600000\` (at least ${wait_needed}), or spell a literal \`--max\` that fits the timeout you pass."
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
