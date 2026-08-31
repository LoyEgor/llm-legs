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
set -u

EDGE="([[:space:]]|\$)"
# Command position. Every chain separator is turned into a newline below, so the start of a line is
# the start of a command; `^` is that whole alternation. Env assignments and the wrapper words that
# hand a command straight to the kernel may precede the binary in any order, each wrapper with its
# own flags, and a path prefix ending in `/` lets `/usr/local/bin/codex exec` read as `codex exec`
# while keeping `~/.claude` and `.claude/hooks` from reading as the `claude` binary.
VENDOR_WORD="^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|(env|command|exec|nohup|nice|time|xargs)([[:space:]]+-[^[:space:]]+)*)[[:space:]]+)*([^[:space:]/]*/)*"
# The flag or subcommand that turns a vendor CLI into a headless run, reached past any number of
# other flags.
PRINT_FLAG="([[:space:]]+[^[:space:]]+)*[[:space:]]+(-p|--print|--prompt)${EDGE}"
SUBCOMMAND="([[:space:]]+[^[:space:]]+)*[[:space:]]+"

# Grok's own spellings, not reusable from PRINT_FLAG: folding it back in would let
# `grokb ... --prompt-file` and `grokb agent` through.
GROK_PRINT_FLAG="([[:space:]]+[^[:space:]]+)*[[:space:]]+(-p|--print|--prompt(-file|-json)?|agent)${EDGE}"

LAUNCH_RES=(
  "${VENDOR_WORD}claudeb?${PRINT_FLAG}"
  "${VENDOR_WORD}codexb?${SUBCOMMAND}exec${EDGE}"
  "${VENDOR_WORD}geminib?${PRINT_FLAG}"
  "${VENDOR_WORD}agy${PRINT_FLAG}"
  "${VENDOR_WORD}opencode${SUBCOMMAND}run${EDGE}"
  "${VENDOR_WORD}grokb?${GROK_PRINT_FLAG}"
)

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

grep -Eq "$SANCTIONED_RE" <<<"$cmd" && exit 0

# Three passes, and their ORDER is the whole difference between reading a launch and inventing one.
# A backslash-continued line is one command, so the join happens before the backslashes are
# stripped: splitting there would sever a vendor name from the flag on the next line, which is how
# a long brief is routinely typed. Then quoted text loses its separators and its spaces, which is
# what makes it one operand word: strip the quotes first and `echo "x; codex exec"` grows a command
# position it never had, while `X="a b" claude -p` loses the env assignment that keeps the vendor
# word out of one. Only then are the quotes themselves dropped, so `'claude' -p` is still a launch.
scan=$(awk '{ if (sub(/\\[[:space:]]*$/, " ")) { printf "%s", $0; next } print }' <<<"$cmd" |
  awk '{ out = ""; q = ""
         for (i = 1; i <= length($0); i++) {
           c = substr($0, i, 1)
           if (q == "") { if (c == "\047" || c == "\"") q = c }
           else if (c == q) q = ""
           else if (c ~ /[[:space:];|&()`]/) c = ""
           out = out c
         }
         print out }' |
  sed -e "s/[\\\\'\"]//g" | tr ';|&()`' '\n') || exit 0
[ -n "$scan" ] || scan="$cmd"

for launch_re in "${LAUNCH_RES[@]}"; do
  hit=$(grep -Eo "$launch_re" <<<"$scan" 2>/dev/null | head -n1 |
    tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
  [ -n "$hit" ] || continue
  deny "Blocked: \`${hit}\` is a bare headless vendor launch — it leaves no worker-run record, no statusline tag, no journal ownership, no pool refusal, no limit signature and no stall watch. Launch it through \`worker-run start <claudeb|codex|gemini|grok> --brief <file> --workdir <dir>\`, or through the tool that owns its launches (review-bench, llm-limits, claudeb revive, claude-session-driver, codex-image, gemini-image, grok-image, opencode-go). An interactive launch — no -p/--print/--prompt, no exec, no run — is not gated. Quotes and backslashes do not hide a launch: the gate strips them, then reads the first word of every chained command."
done
exit 0
