# Sourced by every tests/test_instruction_gate*.sh: each suite builds its own sandbox $HOME from here.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$ROOT/share/test-scope.sh"
PROJECTS=$(git_projects "$ROOT")
WRITE_GATE="$ROOT/bin/instruction-write-gate.sh"
WATCH="$ROOT/bin/instruction-watch.sh"
BLOAT="$ROOT/bin/instruction-bloat-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0

fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts failed: succeeded: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts failed: expected '$1', got '$2'"
}
assert_contains() {
  asserts=$((asserts + 1))
  case "$2" in *"$1"*) ;; *) fail "assert $asserts failed: '$1' not in '$2'" ;; esac
}

REAL_HOME=$HOME
# Both doors now ask whether the process is a relay worker, and this suite is routinely RUN by one
# — the markers arrive in the environment of every headless run. Inherited, they would flip every
# assertion below into the worker refusal, so the fixture session is nobody's worker and the relay
# cases put one marker back, one command at a time.
unset CLAUDEB_WORKER GROK_WORKER CLAUDE_LAUNCHER_SESSION
HOME="$WORK/home"
TMPDIR="$WORK/tmp"
export HOME TMPDIR
# The alert is Egor's screen: never let a test reach the real Hammerspoon.
INSTRUCTION_WATCH_ALERT="$WORK/alert-stub"
INSTRUCTION_WATCH_STATE="$HOME/.cache/watch"
INSTRUCTION_WATCH_LOG="$HOME/.claude/instruction-changes.log"
INSTRUCTION_WRITE_GATE_STAMPS="$HOME/.cache/write-gate"
WRITE_TRANSCRIPT="$WORK/write-transcript.jsonl"
INSTRUCTION_WATCH_CHAT=all
export INSTRUCTION_WATCH_ALERT INSTRUCTION_WATCH_STATE INSTRUCTION_WATCH_LOG \
       INSTRUCTION_WRITE_GATE_STAMPS INSTRUCTION_WATCH_CHAT
mkdir -p "$HOME/.claude/docs" "$HOME/.claude/agents" "$HOME/.claude/skills/demo" \
         "$HOME/.claude/commands" "$HOME/.claude/hooks/lib" "$TMPDIR"
: > "$WRITE_TRANSCRIPT"

# The live layout: ~/.claude/CLAUDE.md is a symlink into a config repository, so a writer
# can land on either name and the gate has to know both.
REPO="$WORK/config-repo"
mkdir -p "$REPO/global"
printf 'global rules\n' > "$REPO/global/CLAUDE.md"
ln -s "$REPO/global/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
printf '{"hooks":{}}\n' > "$HOME/.claude/settings.json"
printf 'tier doc\n' > "$HOME/.claude/docs/review-tiers.md"
printf 'worker agent\n' > "$HOME/.claude/agents/codex-worker.md"
printf 'skill body\n' > "$HOME/.claude/skills/demo/SKILL.md"
printf 'command doc\n' > "$HOME/.claude/commands/worker.md"
printf 'ordinary code\n' > "$WORK/unrelated.py"

# The autonomy span has ONE definition, and this suite exercises that one: the hooks reach
# `rj_autonomous` at its deployed path, so the fixture HOME carries the real library rather than a
# copy of what it decides.
JOURNAL_LIB=''
for cand in "${CLAUDE_SETUP_ROOT:-$PROJECTS/claude-setup}/hooks/lib/review-journal.sh" \
            "$REAL_HOME/.claude/hooks/lib/review-journal.sh"; do
  [ -r "$cand" ] && { JOURNAL_LIB=$cand; break; }
done
[ -n "$JOURNAL_LIB" ] || fail "review-journal.sh not readable (set CLAUDE_SETUP_ROOT)"
# The whole library, not its head file: the span moved into `words.sh`, which review-journal.sh
# sources from its OWN directory — deployed alone, every in-span row of the matrix below silently
# answers out-span.
for part in review-journal.sh words.sh words.py word-families.json readonly-command.sh; do
  [ -r "${JOURNAL_LIB%/*}/$part" ] || fail "$part not readable beside review-journal.sh"
  ln -s "${JOURNAL_LIB%/*}/$part" "$HOME/.claude/hooks/lib/$part"
done

# Two transcripts: one whose last turn of Egor's arms the span, one whose does not. The phrase is
# his own trigger wording, which is the only reason a file here carries Cyrillic — and it stands
# UNQUOTED, because the reader strips «…» before looking for it: a span is an order of his, and a
# turn that merely quotes the phrase arms nothing. Wrapped in the guillemets it armed no span at
# all, which left every in-span row of the matrix below asserting the out-span answer.
SPAN_T="$WORK/span-transcript.jsonl"
NOSPAN_T="$WORK/nospan-transcript.jsonl"
span_turn() {
  jq -cn --arg t "$(date -u -r "$(( $(date +%s) - 600 ))" +%Y-%m-%dT%H:%M:%SZ)" --arg c "$1" \
    '{type:"user",timestamp:$t,message:{role:"user",content:$c}}'
}
span_turn 'tidy the instruction docs, сделай максимально автономно' > "$SPAN_T"
span_turn 'tidy the instruction docs' > "$NOSPAN_T"
# A transcript no longer arms anything by itself: the word intake reads his newest turn once and
# writes the span markers `rj_autonomous` answers from. The fixture arms through that same intake,
# so the phrase above is still what decides, and the two states are checked here rather than being
# discovered as a whole matrix answering out-span.
arm_span() { # session transcript
  bash -c '. "$1"; words_sync "$2" "$3"' _ "$JOURNAL_LIB" "$1" "$2"
}
arm_span matrix-span "$SPAN_T"
arm_span matrix-plain "$NOSPAN_T"
assert bash -c '. "$1"; rj_autonomous matrix-span' _ "$JOURNAL_LIB" >/dev/null
assert_fails bash -c '. "$1"; rj_autonomous matrix-plain' _ "$JOURNAL_LIB" >/dev/null

# A transcript belongs to a session, so each span state answers under its own id — which is also
# what keeps one state's denial from handing the other the retry the gate grants on a repeat.
in_span() { GATE_SID=matrix-span GATE_TRANSCRIPT="$SPAN_T" "$@"; }
out_span() { GATE_SID=matrix-plain GATE_TRANSCRIPT="$NOSPAN_T" "$@"; }
# Without `words_span_live` both doors keep the older span rule; a stub library supplies it.
export WORDS_LIB="$WORK/no-words.sh"
SPAN_LIB="$WORK/span-words.sh"
printf '. %q\nwords_span_live() { words_sync "${1:-}" "${2:-}"; words_span_on "${1:-}" >/dev/null; }\n' \
  "$HOME/.claude/hooks/lib/words.sh" > "$SPAN_LIB"
live_span() { WORDS_LIB=$SPAN_LIB "$@"; }

CLAUDE_MD="$HOME/.claude/CLAUDE.md"
REAL_MD="$REPO/global/CLAUDE.md"

bash_payload() {
  jq -cn --arg c "$1" --arg s "${GATE_SID:-session-one}" --arg d "${GATE_CWD:-}" \
    --arg t "${GATE_TRANSCRIPT:-$WRITE_TRANSCRIPT}" \
    '{tool_name:"Bash",session_id:$s,cwd:$d,transcript_path:$t,tool_input:{command:$c}}'
}

# A call that provably writes nothing is never marked or checked, so the calls that drive the
# tripwire's own machinery are ones that could have written.
ANY_CALL='make -s'

append_write_user() {
  jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:"user",timestamp:$t,message:{role:"user",content:"approved retry"}}' \
    >> "$WRITE_TRANSCRIPT"
}

append_write_tool_result() {
  jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:"user",timestamp:$t,message:{role:"user",content:[{type:"tool_result",content:"ok"}]}}' \
    >> "$WRITE_TRANSCRIPT"
}

# What the harness does with a denial: its reason lands in the transcript as an is_error
# tool_result behind the harness's own `PreToolUse:<tool> hook error: ` prefix, the witness a retry
# stamp is honoured beside.
harness_deny() { # transcript gate-output tool
  local r
  [ -n "$1" ] || return 0
  r=$(printf '%s' "$2" | jq -r 'select(.hookSpecificOutput.permissionDecision == "deny")
    | .hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
  [ -n "$r" ] || return 0
  jq -cn --arg r "PreToolUse:${3:-Write} hook error: $r" \
    '{type:"user",message:{role:"user",content:[{type:"tool_result",is_error:true,content:$r}]}}' >> "$1"
}

gate() {
  local out rc
  out=$(bash_payload "$1" | bash "$WRITE_GATE")
  rc=$?
  harness_deny "${GATE_TRANSCRIPT:-$WRITE_TRANSCRIPT}" "$out" Bash
  [ -z "$out" ] || printf '%s\n' "$out"
  return "$rc"
}

decision() {
  local out
  out=$(gate "$1")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}

# A stamp is only consumable once it has aged past the moment it was created, so a retry in a
# test has to look like one that crossed a turn. Ten seconds, not ten days: the claim helper
# sweeps anything older than a day before it looks.
age_stamps() {
  find "${1:-$INSTRUCTION_WRITE_GATE_STAMPS}" -mindepth 1 -maxdepth 1 \
    -exec touch -t "$(date -v-10S +%Y%m%d%H%M.%S)" {} + 2>/dev/null
}
# A twin is a call inside the stamp's 2 s window, which a gate run alone can outlast on a loaded
# machine: the stamp is dated ahead so the twin stays one.
fresh_stamps() {
  find "${1:-$INSTRUCTION_WRITE_GATE_STAMPS}" -mindepth 1 -maxdepth 1 \
    -exec touch -t "$(date -v+60S +%Y%m%d%H%M.%S)" {} + 2>/dev/null
}

price() { gate "echo priced-$1 > $2" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }

BLOAT_STAMPS="$HOME/.cache/bloat-gate"
export INSTRUCTION_BLOAT_GATE_STAMPS="$BLOAT_STAMPS"
big=$(python3 -c 'print("y"*400)')
bloat() {
  jq -cn --arg p "$1" --arg n "$big" \
    '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
    | bash "$BLOAT"
}
bloat_decision() {
  local out
  out=$(bloat "$1")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
fmt() { ( . "$ROOT/share/instruction-files.sh"; "$@" ); }
DOC="$HOME/.claude/docs/review-tiers.md"
tool_payload() { # event sid tool key value transcript
  jq -cn --arg e "$1" --arg s "$2" --arg n "$3" --arg k "$4" --arg v "$5" --arg t "$6" --arg c "$WORK" \
    --arg u "tu-$2" --arg a "${TOOL_AGENT:-}" '{session_id:$s,hook_event_name:$e,transcript_path:$t,tool_name:$n,cwd:$c,
      tool_use_id:$u,tool_input:{($k):$v}} + if $a == "" then {} else {agent_id:$a} end'
}
# The gate's own PreToolUse is what marks a call in flight, so every case that expects a revert
# runs it ahead of the bytes landing, exactly as the harness does. Earlier gate calls
# leave marks no check consumes; any of them would make this window ambiguous.
pre_call() { # sid tool key value transcript
  local gate=$BLOAT
  [ "$2" = Bash ] && gate=$WRITE_GATE
  rm -f "$INSTRUCTION_WATCH_STATE"/inflight/*
  arm_span "$1" "$5"
  tool_payload PreToolUse "$@" | bash "$gate" >/dev/null 2>&1 || true
}
span_check() { # sid tool key value transcript
  arm_span "$1" "$5"
  tool_payload PostToolUse "$@" | bash "$WATCH" check | jq -r '.hookSpecificOutput.additionalContext // ""'
}
watch_sid() { # sid arg; WATCH_BASH picks the interpreter
  jq -cn --arg s "$1" '{session_id:$s,hook_event_name:"PostToolUse"}' | "${WATCH_BASH:-bash}" "$WATCH" "$2"
}
grow_cmd="perl -pi -e 's/\$/ a line no human asked for/' $DOC"
share_call() { # snippet arg... → the shared module, sourced, answering
  bash -c '. "$1" || exit 1; shift; eval "$1"' _ "$ROOT/share/instruction-files.sh" "$@"
}
# Outside INSTRUCTION_WATCH_CHAT=all the baseline lands behind the hook, before the session's first
# writing call: a fixture's own write, standing for another process, waits for it the same way.
span_base() {
  watch_sid "$1" baseline
  share_call 'instruction_baseline_wait "$INSTRUCTION_WATCH_STATE/pending-$2"' "$1"
}
raw_check() { # sid tool key value transcript
  arm_span "$1" "$5"
  tool_payload PostToolUse "$@" | bash "$WATCH" check
}
J="$INSTRUCTION_WATCH_STATE/events.jsonl"
alert_log_stub() {
  ALERT_LOG="$WORK/alert.log"
  cat >"$INSTRUCTION_WATCH_ALERT" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$2" >>"${ALERT_LOG:?}"
STUB
  chmod +x "$INSTRUCTION_WATCH_ALERT"
  export ALERT_LOG
}
alert_rec_stub() {
  ALERT_REC="$WORK/alert-calls"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n' "$ALERT_REC" > "$WORK/alert-stub"
  chmod +x "$WORK/alert-stub"
}
chat_name_stub() {
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/chat-name" <<'STUB'
#!/bin/sh
printf 'Stub chat (abcdef12)\n'
STUB
  chmod +x "$HOME/.local/bin/chat-name"
  PATH="$HOME/.local/bin:$PATH"
  export PATH
}
profile_link() {
  mkdir -p "$HOME/.claude-profiles/com"
  ln -sf "$CLAUDE_MD" "$HOME/.claude-profiles/com/CLAUDE.md"
}
docs_link() {
  REPO_DOCS="$REPO/global/docs"
  mkdir -p "$REPO_DOCS"
  rm -rf "$HOME/.claude/docs"
  printf 'tier doc\n' > "$REPO_DOCS/review-tiers.md"
  ln -s "$REPO_DOCS" "$HOME/.claude/docs"
}
PROJ="$WORK/proj"
RANKED="$INSTRUCTION_WATCH_STATE/ranked.txt"
