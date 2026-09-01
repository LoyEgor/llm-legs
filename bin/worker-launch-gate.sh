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
# The same door has a second side: `worker-run` itself is sanctioned, but only in the hands of a
# relay agent. A run started or awaited from the main chat's Bash is owned by a turn instead of an
# agent — no magenta tagged row, and nothing to wake the chat when it ends — so those two
# subcommands are denied outside the relay agent types. `report` prints a finished record and
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

SANCTIONED_RE='(^|[[:space:]])([^[:space:]/]*/)*(worker-run|review-bench|llm-limits(\.sh)?|claude-session-driver|codex-image|gemini-image|grok-image|opencode-go)([[:space:]]|$)|(^|[[:space:]])([^[:space:]/]*/)*claudeb[[:space:]]+(revive|warm)([[:space:]]|$)'

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

# Four passes, and their ORDER is the whole difference between reading a launch and inventing one.
# A heredoc body is text a command is FED, so it is blanked first, while the line structure that
# says where the body ends is still intact — `cat > brief <<EOF` quoting `worker-run wait` is a
# brief being written, not a run being awaited, and masking can only lose a command, never invent
# one. A backslash-continued line is one command, so the join comes next: splitting there would
# sever a vendor name from the flag on the next line, which is how a long brief is routinely typed.
# Then quoted text loses its separators and its spaces, which is what makes it one operand word:
# strip the quotes first and `echo "x; codex exec"` grows a command position it never had, while
# `X="a b" claude -p` loses the env assignment that keeps the vendor word out of one. The one quoted
# span that is not an operand is a `sh -c` string, whose words the shell runs: it is broken out onto
# its own line instead. Only then are the quotes themselves dropped, so `'claude' -p` is a launch.
scan=$(awk 'BEGIN { delim = ""; dash = 0 }
       {
         if (delim != "") {
           line = $0
           if (dash) sub(/^\t+/, "", line)
           if (line == delim) delim = ""
           print ""
           next
         }
         print
         probe = $0
         # A herestring is not a heredoc, and its word would read as a delimiter that never closes.
         gsub(/<<</, "@@@", probe)
         if (match(probe, /<<-?[[:space:]]*("[^"]*"|\047[^\047]*\047|[A-Za-z_][A-Za-z0-9_.-]*)/)) {
           tok = substr(probe, RSTART, RLENGTH)
           dash = (substr(tok, 3, 1) == "-")
           sub(/^<<-?[[:space:]]*/, "", tok)
           gsub(/["\047]/, "", tok)
           delim = tok
         }
       }' <<<"$cmd" |
  awk '{ if (sub(/\\[[:space:]]*$/, " ")) { printf "%s", $0; next } print }' |
  awk '{ out = ""; q = ""; body = 0
         for (i = 1; i <= length($0); i++) {
           c = substr($0, i, 1)
           if (q == "") {
             if (c == "\047" || c == "\"") {
               q = c
               if (out ~ /(^|[[:space:];|&(){}])(ba|z)?sh([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[A-Za-z]*c[[:space:]]+$/) {
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
case "$agent_type" in
  claudeb-worker | codex-worker | gemini-worker | grok-worker | image-gen) ;;
  *)
    owned_hit=$(grep -Eo "$OWNED_RUN_RE" <<<"$scan" 2>/dev/null | head -n1 |
      tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
    [ -z "$owned_hit" ] ||
      deny "Blocked: \`${owned_hit}\` runs the worker from this chat's own Bash. A worker run must be owned by a relay agent for its whole life — that ownership is what renders it as a magenta tagged row in the task list and what wakes the chat when the run ends, while a Bash wait owns nothing and dies with the turn. Launch it by spawning the matching Agent (\`claudeb-worker\`, \`codex-worker\`, \`gemini-worker\`, \`grok-worker\`), which does the \`worker-run start\` itself; to re-attach to a run already in flight, spawn THE SAME agent type again with a brief starting \`ATTACH <run-id>:\` — never a background Bash wait. \`worker-run report\` (it only prints a record), \`worker-run claim\`, a bare \`worker-run\` and the test suites are not gated."
    ;;
esac

grep -Eq "$SANCTIONED_RE" <<<"$cmd" && exit 0

for launch_re in "${LAUNCH_RES[@]}"; do
  hit=$(grep -Eo "$launch_re" <<<"$scan" 2>/dev/null | head -n1 |
    tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
  [ -n "$hit" ] || continue
  deny "Blocked: \`${hit}\` is a bare headless vendor launch — it leaves no worker-run record, no statusline tag, no journal ownership, no pool refusal, no limit signature and no stall watch. Launch it through \`worker-run start <claudeb|codex|gemini|grok> --brief <file> --workdir <dir>\`, or through the tool that owns its launches (review-bench, llm-limits, claudeb revive, claude-session-driver, codex-image, gemini-image, grok-image, opencode-go). An interactive launch — no -p/--print/--prompt, no exec, no run — is not gated. Quotes and backslashes do not hide a launch: the gate strips them, then reads the first word of every chained command."
done
exit 0
