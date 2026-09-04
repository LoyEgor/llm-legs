#!/usr/bin/env bash
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WRITE_GATE="$ROOT/bin/instruction-write-gate.sh"
WATCH="$ROOT/bin/instruction-watch.sh"
BLOAT="$ROOT/bin/instruction-bloat-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0

fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts failed: expected '$1', got '$2'"
}
assert_contains() {
  asserts=$((asserts + 1))
  case "$2" in *"$1"*) ;; *) fail "assert $asserts failed: '$1' not in '$2'" ;; esac
}

REAL_HOME=$HOME
HOME="$WORK/home"
TMPDIR="$WORK/tmp"
export HOME TMPDIR
# The alert is Egor's screen: never let a test reach the real Hammerspoon.
INSTRUCTION_WATCH_ALERT="$WORK/alert-stub"
INSTRUCTION_WATCH_STATE="$HOME/.cache/watch"
INSTRUCTION_WATCH_LOG="$HOME/.claude/instruction-changes.log"
INSTRUCTION_WRITE_GATE_STAMPS="$HOME/.cache/write-gate"
WRITE_TRANSCRIPT="$WORK/write-transcript.jsonl"
export INSTRUCTION_WATCH_ALERT INSTRUCTION_WATCH_STATE INSTRUCTION_WATCH_LOG \
       INSTRUCTION_WRITE_GATE_STAMPS
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
for cand in "${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/lib/review-journal.sh" \
            "$REAL_HOME/.claude/hooks/lib/review-journal.sh"; do
  [ -r "$cand" ] && { JOURNAL_LIB=$cand; break; }
done
[ -n "$JOURNAL_LIB" ] || fail "review-journal.sh not readable (set CLAUDE_SETUP_ROOT)"
ln -s "$JOURNAL_LIB" "$HOME/.claude/hooks/lib/review-journal.sh"

# Two transcripts: one whose last turn of Egor's arms the span, one whose does not. The phrase is
# his own trigger wording, quoted verbatim, which is the only reason a file here carries Cyrillic.
SPAN_T="$WORK/span-transcript.jsonl"
NOSPAN_T="$WORK/nospan-transcript.jsonl"
span_turn() {
  jq -cn --arg t "$(date -u -r "$(( $(date +%s) - 600 ))" +%Y-%m-%dT%H:%M:%SZ)" --arg c "$1" \
    '{type:"user",timestamp:$t,message:{role:"user",content:$c}}'
}
span_turn 'tidy the instruction docs, «максимально автономно»' > "$SPAN_T"
span_turn 'tidy the instruction docs' > "$NOSPAN_T"

# A transcript belongs to a session, so each span state answers under its own id — which is also
# what keeps one state's denial from handing the other the retry the gate grants on a repeat.
in_span() { GATE_SID=matrix-span GATE_TRANSCRIPT="$SPAN_T" "$@"; }
out_span() { GATE_SID=matrix-plain GATE_TRANSCRIPT="$NOSPAN_T" "$@"; }

CLAUDE_MD="$HOME/.claude/CLAUDE.md"
REAL_MD="$REPO/global/CLAUDE.md"

bash_payload() {
  jq -cn --arg c "$1" --arg s "${GATE_SID:-session-one}" --arg d "${GATE_CWD:-}" \
    --arg t "${GATE_TRANSCRIPT:-$WRITE_TRANSCRIPT}" \
    '{tool_name:"Bash",session_id:$s,cwd:$d,transcript_path:$t,tool_input:{command:$c}}'
}

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

gate() { bash_payload "$1" | bash "$WRITE_GATE"; }

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
    -exec touch -A -000010 {} + 2>/dev/null
}

echo "== write gate: denies a shell write to a protected file"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','w').write('x')\"")"
assert_eq deny "$(decision "echo hi > $CLAUDE_MD")"
assert_eq deny "$(decision "echo hi >> $CLAUDE_MD")"
assert_eq deny "$(decision "printf x | tee $CLAUDE_MD")"
assert_eq deny "$(decision "printf x | tee -a $CLAUDE_MD")"

echo "== write gate: the verbs whose destination has to be inferred are out of scope"
# Measured over a month, these accounted for a handful of writes between them and for most of
# this gate's defects. The tripwire reports them instead, and now keeps the bytes to undo them.
assert_eq pass "$(decision "sed -i '' 's/a/b/' $CLAUDE_MD")"
assert_eq pass "$(decision "cp $WORK/unrelated.py $CLAUDE_MD")"
assert_eq pass "$(decision "mv $WORK/unrelated.py $CLAUDE_MD")"
assert_eq pass "$(decision "ln -sf $WORK/unrelated.py $CLAUDE_MD")"
assert_eq pass "$(decision "rm $CLAUDE_MD")"
assert_eq pass "$(decision "truncate -s 0 $CLAUDE_MD")"
assert_eq pass "$(decision "perl -pi -e 's/a/b/' $CLAUDE_MD")"
assert_eq pass "$(decision "ed -s $CLAUDE_MD")"
assert_eq pass "$(decision "patch $CLAUDE_MD $WORK/some.diff")"
assert_eq pass "$(decision "dd if=/dev/zero of=$CLAUDE_MD bs=1024 count=1")"

echo "== write gate: a project memory index is not the gate's business"
# Appending one pointer line is the memory workflow every agent is told to follow, and a project
# index is read in that project's sessions only. Its growth is still priced by the bloat gate.
assert_eq pass "$(decision "cat >> $WORK/MEMORY.md <<'EOF'
- [note](note.md) — a pointer line
EOF")"
assert_eq pass "$(decision "echo '- [note](note.md)' >> $WORK/MEMORY.md")"

echo "== write gate: the symlink target is the same file"
assert_eq deny "$(decision "echo hi > $REAL_MD")"
assert_eq deny "$(decision "python3 - <<'EOF'
open('$REAL_MD','w').write('x')
EOF")"

echo "== write gate: the spelling of the path does not matter"
# The first live test walked through the gate on exactly this line: the expanded path was
# the only form it knew, and nobody types that.
assert_eq deny "$(decision 'echo hi >> ~/.claude/docs/review-tiers.md')"
assert_eq deny "$(decision 'echo hi > ~/.claude/CLAUDE.md')"
assert_eq deny "$(decision 'echo hi > $HOME/.claude/CLAUDE.md')"
assert_eq deny "$(decision 'echo hi > ${HOME}/.claude/CLAUDE.md')"
assert_eq deny "$(decision 'python3 -c "open(\"~/.claude/CLAUDE.md\",\"w\").write(1)"')"
assert_eq pass "$(decision 'grep rules ~/.claude/CLAUDE.md')"

echo "== write gate: every protected class"
assert_eq deny "$(decision "echo x > $HOME/.claude/docs/review-tiers.md")"
assert_eq deny "$(decision "echo x > $HOME/.claude/agents/codex-worker.md")"
assert_eq deny "$(decision "echo x > $HOME/.claude/skills/demo/SKILL.md")"

# `review-debt-ignore` is the one way a path leaves review debt, so a model that can append to it
# retires its own unreviewed work. It carries no `.md` on purpose and is typed from inside
# `.claude/` as a bare name, which is the spelling the fast path dropped before the guarded
# basenames were ever built.
assert_eq deny "$(decision "echo x >> $HOME/.claude/review-debt-ignore")"
assert_eq deny "$(decision 'echo x >> review-debt-ignore')"
assert_eq deny "$(decision 'echo x > ../.claude/review-debt-ignore')"
assert_eq pass "$(decision 'grep -c . review-debt-ignore')"

echo "== write gate: the clobber operator is a redirection too"
# `>|` is `>` with noclobber off. The operator class knew `>` and `>>` and nothing else, so this
# spelling walked through.
assert_eq deny "$(decision "echo x >| $CLAUDE_MD")"
assert_eq deny "$(decision "echo x >|$CLAUDE_MD")"

echo "== write gate: every open mode that writes, and only those"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','wt').write('x')\"")"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','at').write('x')\"")"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','x').write('x')\"")"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','r+').write('x')\"")"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','rb+').write(b'x')\"")"
# Perl's three-argument open puts the mode where a Python mode string stands.
assert_eq deny "$(decision "perl -e \"open(my \$f, '>', '$CLAUDE_MD')\"")"
assert_eq deny "$(decision "perl -e \"open(my \$f, '>>', '$CLAUDE_MD')\"")"
# A read is not a write, which is the whole reason the modes are enumerated.
assert_eq pass "$(decision "python3 -c \"open('$CLAUDE_MD','r').read()\"")"
assert_eq pass "$(decision "python3 -c \"open('$CLAUDE_MD','rb').read()\"")"

echo "== write gate: the denial quotes what THIS class of file costs"
# One blanket figure was quoted at every guarded file, so the arithmetic the denial asks the
# reader to do started from a number two orders of magnitude out for a skill.
# A command already denied once in this suite would be spending its retry here, not being
# priced, so every one of these carries its own marker.
price() { gate "echo priced-$1 > $2" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }
assert_contains "~3,000 times a week, ~15,000 times a month" "$(price a "$CLAUDE_MD")"
assert_contains "~3,000 times a week, ~15,000 times a month" "$(price b "$REAL_MD")"
assert_contains "~500 times a week, ~3,000 times a month" "$(price c "$HOME/.claude/agents/codex-worker.md")"
assert_contains "~30 times a week, ~150 times a month" "$(price d "$HOME/.claude/docs/review-tiers.md")"
assert_contains "~20 times a week, ~100 times a month" "$(price e "$HOME/.claude/skills/demo/SKILL.md")"
assert_contains "~700 times a week, ~3,000 times a month" "$(price f "$WORK/proj/CLAUDE.md")"

echo "== write gate: reads and non-targets stay silent"
assert_eq pass "$(decision "grep -n rules $CLAUDE_MD")"
assert_eq pass "$(decision "cat $CLAUDE_MD")"
assert_eq pass "$(decision "wc -c < $CLAUDE_MD")"
assert_eq pass "$(decision "cat $CLAUDE_MD > $WORK/copy.txt")"
assert_eq pass "$(decision "diff $CLAUDE_MD $WORK/unrelated.py")"
assert_eq pass "$(decision "cp $CLAUDE_MD $WORK/backup.md")"
assert_eq pass "$(decision "python3 -c \"print(open('$CLAUDE_MD').read())\"")"
assert_eq pass "$(decision "echo x > $WORK/unrelated.py")"
# Repository work restores these files all the time and must never be gated.
assert_eq pass "$(decision "git -C $REPO checkout -- global/CLAUDE.md")"
assert_eq pass "$(decision "git -C $REPO checkout -- $REAL_MD")"
assert_eq pass "$(decision "git -C $REPO stash pop")"
# `add` ends in `dd`, `column` contains `ln`: a verb needs a boundary, not a substring.
assert_eq pass "$(decision "git add $CLAUDE_MD")"
assert_eq pass "$(decision "column -t $CLAUDE_MD")"

echo "== write gate: the wider guarded set, matched by name where no list can exist"
printf 'index\n' > "$WORK/MEMORY.md"
printf 'project rules\n' > "$REPO/CLAUDE.md"
assert_eq deny "$(decision "echo x > $REPO/CLAUDE.md")"
assert_eq deny "$(decision "echo x > CLAUDE.local.md")"
assert_eq pass "$(decision "grep rules $REPO/CLAUDE.md")"
assert_eq pass "$(decision "echo x > $WORK/notes.md")"

echo "== write gate: a path relative to the working directory is the same file"
assert_eq deny "$(GATE_CWD="$REPO" decision 'echo x > global/CLAUDE.md')"
assert_eq deny "$(GATE_CWD="$REPO" decision 'echo x > ./global/CLAUDE.md')"
assert_eq deny "$(decision 'echo x > ./.claude/CLAUDE.md')"

echo "== write gate: a derived name is not the file itself"
# This repository keeps CLAUDE.md.backup-* files; denying those would be a daily nuisance.
assert_eq pass "$(decision "echo x > $CLAUDE_MD.bak")"
assert_eq pass "$(decision "echo x > ${CLAUDE_MD}.backup-20260713")"
assert_eq pass "$(decision "echo x > $WORK/dummyCLAUDE.md")"
assert_eq pass "$(decision "python3 -c \"open('${CLAUDE_MD}.tmp','w').write('x')\"")"

echo "== write gate: the destination anywhere in tee's arguments, and gnu-prefixed tools"
assert_eq deny "$(decision "printf x | tee $WORK/log.txt $CLAUDE_MD")"
assert_eq deny "$(decision "printf x | gtee $CLAUDE_MD")"
assert_eq deny "$(decision "printf x | /usr/bin/tee $CLAUDE_MD")"
assert_eq deny "$(decision "python3.11 -c \"open('$CLAUDE_MD','w').write('x')\"")"
assert_eq deny "$(decision "node -e \"fs.writeFileSync('$CLAUDE_MD','x')\"")"

echo "== write gate: a guarded name merely mentioned is not a write to it"
assert_eq pass "$(decision "sed -i '' 's/x/y/' $WORK/unrelated.py # fixes CLAUDE.md guidance")"
assert_eq pass "$(decision "git commit -m 'update CLAUDE.md wording'")"
assert_eq pass "$(decision "sed -e 's/a-int/b/' $CLAUDE_MD")"

echo "== write gate: an unrelated command never reaches the glob"
assert_eq pass "$(decision 'git status --short')"

echo "== write gate: binary and pathlib write modes"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','wb').write(b'x')\"")"
assert_eq deny "$(decision "python3 -c \"Path('$CLAUDE_MD').write_bytes(b'x')\"")"

echo "== write gate: one deny, then the identical command passes"
cmd="echo retry > $CLAUDE_MD"
assert_eq deny "$(decision "$cmd")"
# A twin arriving in the same batch is not a retry: it must neither pass nor eat the stamp the
# real retry is waiting for.
assert_eq deny "$(decision "$cmd")"
age_stamps
assert_eq deny "$(decision "$cmd")"
append_write_tool_result
assert_eq deny "$(decision "$cmd")"
append_write_user
assert_eq pass "$(decision "$cmd")"
# The claim is consumed by the retry, so the call after it is denied again.
assert_eq deny "$(decision "$cmd")"
assert_eq deny "$(decision "echo other > $CLAUDE_MD")"

echo "== write gate: another session does not inherit this one's approval"
cmd2="echo cross-session > $CLAUDE_MD"
assert_eq deny "$(decision "$cmd2")"
age_stamps
assert_eq deny "$(GATE_SID=session-two decision "$cmd2")"

echo "== write gate: a trailing redirect or comment does not move the destination"
assert_eq deny "$(decision "printf x | tee $CLAUDE_MD 2>/dev/null")"
assert_eq deny "$(decision "printf x | tee $CLAUDE_MD # harmless note")"
assert_eq deny "$(decision "echo x > $CLAUDE_MD 2>&1")"

echo "== write gate: the destination is named, not the source"
out=$(gate "printf x | tee $CLAUDE_MD < $WORK/MEMORY.md" \
      | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "writes to $CLAUDE_MD" "$out"

echo "== write gate: standing inside .claude is not an escape"
assert_eq deny "$(GATE_CWD="$HOME/.claude/skills/demo" decision 'echo x > SKILL.md')"

echo "== write gate: another project's .claude is not the global one"
assert_eq pass "$(GATE_CWD="$WORK/elsewhere" decision 'echo x > ./.claude/notes.txt')"

echo "== write gate: an unusable stamp cache denies rather than waving the write through"
assert_contains 'permissionDecision":"deny' \
  "$(INSTRUCTION_WRITE_GATE_STAMPS=/dev/null/nope bash_payload "echo blocked-cache > $CLAUDE_MD" \
     | INSTRUCTION_WRITE_GATE_STAMPS=/dev/null/nope bash "$WRITE_GATE")"

echo "== write gate: other tools are not its business"
out=$(jq -cn --arg p "$CLAUDE_MD" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' | bash "$WRITE_GATE")
assert_eq "" "$out"

echo "== write gate: a continuation is one command, not two lines"
assert_eq deny "$(decision "printf x | tee \\
$CLAUDE_MD")"

echo "== write gate: a mention beside an unrelated command is not a write"
assert_eq pass "$(decision "rm -rf $WORK/build && echo see CLAUDE.md")"
assert_eq pass "$(decision "printf x | tee $WORK/log # unrelated to CLAUDE.md")"
assert_eq pass "$(decision "perl -ne 'print' $CLAUDE_MD")"

echo "== write gate: node appends as well as writes"
assert_eq deny "$(decision "node -e \"fs.appendFileSync('$CLAUDE_MD','x')\"")"

echo "== write gate: printing a guarded file is not writing to it"
assert_eq pass "$(decision "python3 -c \"import sys; sys.stdout.write(open('$CLAUDE_MD').read())\"")"
assert_eq pass "$(decision "python3 -c \"print('a'); print('$CLAUDE_MD')\"")"
assert_eq pass "$(decision "node -e \"process.stdout.write(String('$CLAUDE_MD'))\"")"

echo "== write gate: a file that does not exist yet is still a guarded file"
assert_eq deny "$(decision "echo x > $HOME/.claude/agents/brand-new.md")"
assert_eq deny "$(decision "echo x > $HOME/.claude/docs/brand-new.md")"
assert_eq deny "$(GATE_CWD="$HOME/.claude" decision 'echo x > docs/brand-new.md')"
assert_eq deny "$(GATE_CWD="$HOME/.claude" decision 'echo x > agents/brand-new.md')"
assert_eq pass "$(decision "echo x > $WORK/brand-new.md")"

echo "== write gate: a target named only relative to a guarded directory"
assert_eq deny "$(GATE_CWD="$HOME/.claude/docs" decision 'echo x >> review-tiers.md')"
assert_eq deny "$(GATE_CWD="$HOME/.claude/agents" decision 'echo x >> codex-worker.md')"

echo "== write gate: a target standing immediately after the verb"
# The verb's space and the name's boundary are the same character; requiring both let a bare
# relative name through while an absolute one was caught only by the slash standing in for it.
assert_eq deny "$(GATE_CWD="$REPO" decision 'printf x | tee CLAUDE.md')"

echo "== write gate: a name that merely ends with a guarded one is not it"
assert_eq pass "$(decision "printf x | tee $WORK/dummyCLAUDE.md")"
assert_eq pass "$(decision "echo x > $WORK/dummyCLAUDE.md")"
assert_eq pass "$(decision "echo x > $CLAUDE_MD.bak")"

echo "== write gate: a guarded name inside a trailing comment is not the target"
assert_eq pass "$(decision "printf x | tee $WORK/copy.py # backup of CLAUDE.md")"
assert_eq pass "$(decision "echo x > $WORK/notes.txt # see CLAUDE.md")"

echo "== write gate: a mention on the far side of a pipe is a different command"
assert_eq pass "$(decision "python3 -c \"open('$WORK/u.py','w').write('x')\" | grep CLAUDE.md")"
assert_eq pass "$(decision "cat $WORK/unrelated.py | grep CLAUDE.md")"

echo "== write gate: a verb has to be the command, not a syllable of one"
assert_eq pass "$(decision "tee_func $WORK/unrelated.py CLAUDE.md")"
assert_eq pass "$(decision "echo ed CLAUDE.md")"

echo "== write gate: an open mode spelled by keyword or by method"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD', mode='w').write('x')\"")"
assert_eq deny "$(decision "python3 -c \"Path('$CLAUDE_MD').open('w')\"")"

echo "== write gate: a path containing = is still a path"
assert_eq deny "$(decision "echo x > $WORK/proj=1/CLAUDE.md")"
assert_eq deny "$(decision "printf x | tee $WORK/proj=1/CLAUDE.md")"

echo "== write gate: the denial names the destination whichever end it stands at"
out=$(gate "printf name-the-destination | tee $CLAUDE_MD" \
      | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "writes to $CLAUDE_MD" "$out"
out=$(gate "python3 -c \"open('$CLAUDE_MD','w').write(open('$WORK/MEMORY.md').read())\"" \
      | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "writes to $CLAUDE_MD" "$out"

echo "== write gate: the name reported is the one written, not one named in the arguments"
out=$(gate "printf x | tee $WORK/dummyCLAUDE.md $REPO/CLAUDE.md" \
      | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "writes to $REPO/CLAUDE.md" "$out"

echo "== write gate: a mention beside an unrelated write is still not a target"
assert_eq deny "$(decision "cat $WORK/unrelated.py | tee -a $CLAUDE_MD")"
assert_eq pass "$(decision "printf x | tee $WORK/log.txt")"

echo "== bloat gate: the measured multipliers reach the message"
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
msg=$(bloat "$CLAUDE_MD" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~15,000 times a month" "$msg"
assert_contains "tokens/week and " "$msg"
# The audit is the cheapest way out of the denial, so it stands first and is named as a step.
assert_contains "Protocol, fastest path first" "$msg"
assert_contains "(1) AUDIT" "$msg"

echo "== bloat gate: every name the global file answers to is the global file"
# Each profile directory carries its own symlink to it, and those spellings were being priced
# as a project file at a fifth of the real cost.
mkdir -p "$HOME/.claude-profiles/com"
ln -sf "$CLAUDE_MD" "$HOME/.claude-profiles/com/CLAUDE.md"
msg=$(bloat "$HOME/.claude-profiles/com/CLAUDE.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~15,000 times a month" "$msg"
msg=$(bloat "$REAL_MD" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~15,000 times a month" "$msg"

echo "== bloat gate: a project file rides in one project's sessions, not in all of them"
# The global rate quoted for a project CLAUDE.md or memory index overstated it by five times.
msg=$(bloat "$REPO/CLAUDE.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~3,000 times a month" "$msg"
msg=$(bloat "$WORK/memory/MEMORY.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~3,000 times a month" "$msg"

echo "== bloat gate: the repo path behind the symlinked directory is the same file"
# ~/.claude/docs and ~/.claude/agents are symlinks into the config repository, and the repo
# path is the one anybody editing the repo actually types.
REPO_DOCS="$REPO/global/docs"
mkdir -p "$REPO_DOCS"
rm -rf "$HOME/.claude/docs"
printf 'tier doc\n' > "$REPO_DOCS/review-tiers.md"
ln -s "$REPO_DOCS" "$HOME/.claude/docs"
assert_eq deny "$(bloat_decision "$HOME/.claude/docs/review-tiers.md")"
assert_eq deny "$(bloat_decision "$REPO_DOCS/review-tiers.md")"
assert_eq deny "$(bloat_decision "$REPO_DOCS/not-created-yet.md")"
# A Write may be creating the directory as well as the file, and a new subdirectory of docs/
# is still docs/.
assert_eq deny "$(bloat_decision "$REPO_DOCS/new-topic/doc.md")"
assert_eq pass "$(bloat_decision "$WORK/ordinary.md")"
assert_eq pass "$(bloat_decision "$WORK/no-such-dir/ordinary.md")"

echo "== bloat gate: one deny, then the identical edit passes"
rm -rf "$BLOAT_STAMPS"
assert_eq deny "$(bloat_decision "$CLAUDE_MD")"
assert_eq deny "$(bloat_decision "$CLAUDE_MD")"
age_stamps "$BLOAT_STAMPS"
assert_eq pass "$(bloat_decision "$CLAUDE_MD")"
assert_eq deny "$(bloat_decision "$CLAUDE_MD")"

echo "== bloat gate: another session does not inherit this one's approval"
rm -rf "$BLOAT_STAMPS"
bloat_sid() {
  local out
  out=$(jq -cn --arg p "$CLAUDE_MD" --arg n "$big" --arg s "$1" \
          '{tool_name:"Edit",cwd:"/tmp",session_id:$s,tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
        | bash "$BLOAT")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
assert_eq deny "$(bloat_sid session-one)"
age_stamps "$BLOAT_STAMPS"
assert_eq deny "$(bloat_sid session-two)"
assert_eq pass "$(bloat_sid session-one)"

echo "== bloat gate: an unusable stamp cache denies rather than waving the growth through"
assert_eq deny "$(INSTRUCTION_BLOAT_GATE_STAMPS=/dev/null/nope bloat_decision "$CLAUDE_MD")"

echo "== bloat gate: growth under the threshold is nobody's business"
small=$(jq -cn --arg p "$CLAUDE_MD" \
  '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:$p,old_string:"x",new_string:"xy"}}' \
  | bash "$BLOAT")
assert_eq "" "$small"

echo "== bloat gate: the retry has to follow a re-read of the file"
# The denial asks for an audit of the whole file and the stamp is what makes the retry pass, so
# the transcript past the denial is what says the audit happened.
RETRY_STAMPS="$HOME/.cache/bloat-retry"
TRANSCRIPT="$WORK/transcript.jsonl"
: > "$TRANSCRIPT"
append_read() {
  jq -cn --arg p "$1" '{type:"assistant",timestamp:"2026-08-06T12:00:00Z",
    message:{role:"assistant",content:[{type:"tool_use",name:"Read",input:{file_path:$p}}]}}' \
    >> "$TRANSCRIPT"
}
append_ranged_read() {
  jq -cn --arg p "$1" '{type:"assistant",timestamp:"2026-08-06T12:00:00Z",
    message:{role:"assistant",content:[{type:"tool_use",name:"Read",
      input:{file_path:$p,offset:1,limit:20}}]}}' >> "$TRANSCRIPT"
}
# $4 is the transcript path, empty for a payload that carries no such field at all.
retry_payload() {
  jq -cn --arg p "$1" --arg n "$big" --arg s "$2" --arg tool "$3" --arg t "$4" '
    {tool_name:$tool, cwd:"/tmp", session_id:$s,
     tool_input: (if $tool == "Write" then {file_path:$p, content:$n}
                  else {file_path:$p, old_string:"x", new_string:$n} end)}
    + (if $t == "" then {} else {transcript_path:$t} end)'
}
retry_bloat() {
  retry_payload "$@" | INSTRUCTION_BLOAT_GATE_STAMPS="$RETRY_STAMPS" bash "$BLOAT"
}
retry_decision() {
  local out
  out=$(retry_bloat "$@")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
retry_reason() {
  retry_bloat "$@" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}
count_in() { find "$RETRY_STAMPS" -mindepth 1 -maxdepth 1 "$@" | wc -l | tr -d '[:space:]'; }

rm -rf "$RETRY_STAMPS"
# A read from before the denial is not the audit it asked for.
append_read "$CLAUDE_MD"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-one Edit "$TRANSCRIPT")"
age_stamps "$RETRY_STAMPS"
assert_contains "Gate retry requires re-reading" "$(retry_reason "$CLAUDE_MD" retry-one Edit "$TRANSCRIPT")"
# The refused retry must not spend the stamp the real retry is still waiting for.
assert_eq 1 "$(count_in -type d)"
append_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-one Edit "$TRANSCRIPT")"
# The stamp and the note it was denied with are both gone, so the next identical edit starts over.
assert_eq 0 "$(count_in)"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-one Edit "$TRANSCRIPT")"

echo "== bloat gate: the read counts under either spelling of the file"
# ~/.claude/CLAUDE.md is a symlink into a config repository: the edit lands on one name and the
# read is as likely to carry the other.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$REAL_MD" retry-link Edit "$TRANSCRIPT")"
append_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$REAL_MD" retry-link Edit "$TRANSCRIPT")"
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-link-back Edit "$TRANSCRIPT")"
append_read "$REAL_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-link-back Edit "$TRANSCRIPT")"
# Reading a different file is not reading this one.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-other Edit "$TRANSCRIPT")"
append_read "$REPO_DOCS/review-tiers.md"
age_stamps "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-other Edit "$TRANSCRIPT")"

echo "== bloat gate: the tool's own spelling of the path is the one recorded"
# Read takes a tilde path and the transcript keeps it unexpanded, while realpath resolves it
# against the working directory: a real re-read was being thrown away.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-tilde Edit "$TRANSCRIPT")"
append_read '~/.claude/CLAUDE.md'
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-tilde Edit "$TRANSCRIPT")"

echo "== bloat gate: a ranged read is not the audit the denial asked for"
# The denial promises the check is mechanical, and the protocol asks for the WHOLE file; a read
# carrying an offset or a limit is recorded exactly like a full one.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-ranged Edit "$TRANSCRIPT")"
append_ranged_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-ranged Edit "$TRANSCRIPT")"
append_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-ranged Edit "$TRANSCRIPT")"

echo "== bloat gate: a file that does not exist yet has nothing to re-read"
rm -rf "$RETRY_STAMPS"
NEWDOC="$REPO_DOCS/retry-new.md"
assert_eq deny "$(retry_decision "$NEWDOC" retry-new Write "$TRANSCRIPT")"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$NEWDOC" retry-new Write "$TRANSCRIPT")"

echo "== bloat gate: a transcript it cannot read leaves the retry working"
# The gate does not own the transcript; a payload without one, or one naming a file that is not
# there, must behave exactly as it did before the read was ever required.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-blind Edit "")"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-blind Edit "")"
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-gone Edit "$WORK/no-such-transcript.jsonl")"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-gone Edit "$WORK/no-such-transcript.jsonl")"
# A transcript carrying lines that are not JSON at all is still readable for the ones that are.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-junk Edit "$TRANSCRIPT")"
printf 'not json at all\n' >> "$TRANSCRIPT"
append_read "$CLAUDE_MD"
printf '{"type":"user"}\n' >> "$TRANSCRIPT"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-junk Edit "$TRANSCRIPT")"

echo "== bloat gate: a transcript that shrank took the evidence with it"
# Truncated or rotated under the same name: the tail past the remembered byte is empty from then
# on, which would deny the retry forever instead of once.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-cut Edit "$TRANSCRIPT")"
: > "$TRANSCRIPT"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-cut Edit "$TRANSCRIPT")"

echo "== bloat gate: each denial moves the byte the audit has to beat"
# The stamp is swept after a day and the note beside it is not: a note left from an old cycle
# would let a read from that cycle answer a denial issued today.
rm -rf "$RETRY_STAMPS"
append_read "$CLAUDE_MD"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-fresh Edit "$TRANSCRIPT")"
find "$RETRY_STAMPS" -mindepth 1 -maxdepth 1 -type d -exec rmdir {} + 2>/dev/null
assert_eq 1 "$(count_in -name '*.read')"
append_read "$CLAUDE_MD"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-fresh Edit "$TRANSCRIPT")"
age_stamps "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-fresh Edit "$TRANSCRIPT")"
append_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-fresh Edit "$TRANSCRIPT")"

echo "== note sweep: an aged note goes, a file that only borrowed its name stays"
# The stamp directory is env-overridable and a misconfigured one is somebody's real data, so the
# name alone is never enough of a reason to delete a file.
NOTE_SWEEP="$WORK/note-sweep"
mkdir -p "$NOTE_SWEEP"
printf '42\n%s\n' "$TRANSCRIPT" > "$NOTE_SWEEP/0123456789abcdef.read"
printf 'somebody real data\n' > "$NOTE_SWEEP/abcdef0123456789.read"
printf '42\nnot-an-absolute-path\n' > "$NOTE_SWEEP/deadbeefdeadbeef.read"
printf '42\n%s\nand a third line\n' "$TRANSCRIPT" > "$NOTE_SWEEP/feedfacefeedface.read"
touch -A -250000 "$NOTE_SWEEP"/*.read
# A note of the right shape that has not aged out belongs to a denial still waiting for its retry.
printf '42\n%s\n' "$TRANSCRIPT" > "$NOTE_SWEEP/8899aabbccddeeff.read"
assert_contains 'permissionDecision":"deny' \
  "$(retry_payload "$CLAUDE_MD" note-sweep Edit "$TRANSCRIPT" \
     | INSTRUCTION_BLOAT_GATE_STAMPS="$NOTE_SWEEP" bash "$BLOAT")"
assert [ ! -f "$NOTE_SWEEP/0123456789abcdef.read" ]
assert [ -f "$NOTE_SWEEP/abcdef0123456789.read" ]
assert [ -f "$NOTE_SWEEP/deadbeefdeadbeef.read" ]
assert [ -f "$NOTE_SWEEP/feedfacefeedface.read" ]
assert [ -f "$NOTE_SWEEP/8899aabbccddeeff.read" ]

echo "== bloat gate: the live rate from the local index is quoted instead of the frozen constant"
# The constants are one measured month that ages out; tokenmap exports what the last 30 days
# actually cost. The rate has to reach the arithmetic too, not only the prose, so the monthly
# figure is checked against the live number rather than against 15682.
RATES="$WORK/rates/read-rates.json"
MEM_SLUG="-Volumes-Work-Projects-token-map"
MEM_DIR="$WORK/profiles/com/projects/$MEM_SLUG/memory"
mkdir -p "$WORK/rates" "$WORK/liveproj" "$WORK/livereal" "$MEM_DIR"
export TOKENMAP_RATES="$RATES"
# The second project is keyed by the RESOLVED directory only: mktemp hands out the /var spelling
# and the export carries whichever one the sessions ran in.
LIVE_REAL=$(realpath "$WORK/livereal")
# BSD date on the machine this runs on, GNU date wherever the suite is run in CI or a container.
stamp_ago() {
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ
}
stamp_ahead() {
  date -u -v+"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "+$1 hours" +%Y-%m-%dT%H:%M:%SZ
}
write_rates() {
  # $gdir is a decoy: the global file's own repo directory measured as a project. Identity has
  # to outrank spelling, or the write gate quotes 500 for the file both gates price at 20111.
  jq -n --arg gen "$1" --arg dir "$WORK/liveproj" --arg real "$LIVE_REAL" \
        --arg gdir "$REPO/global" --arg mem /Volumes/Work/Projects/token-map '{
    generated_at: $gen, window_days: 30,
    global: {reads: 20111.0, requests: 130000, sessions: 1900},
    projects: {
      ($dir): {reads: 812.4, requests: 8000, sessions: 60},
      ($real): {reads: 407.0, requests: 4000, sessions: 30},
      ($gdir): {reads: 500.0, requests: 4600, sessions: 32},
      ($mem): {reads: 641.0, requests: 6000, sessions: 44},
      ($mem + "/sub"): {reads: 400.0, requests: 3800, sessions: 28},
      ($mem + "-other"): {reads: 9000.0, requests: 80000, sessions: 600},
      "/tmp/tiny-project": {reads: 0.4, requests: 4, sessions: 1}
    }
  }' > "$RATES"
}
# Each pricing here carries a session of its own: the same file priced twice with the same payload
# would be spending its own retry the second time and pass, quoting nothing.
price_bloat() {
  jq -cn --arg p "$2" --arg n "$big" --arg s "live-$1" \
    '{tool_name:"Edit",cwd:"/tmp",session_id:$s,tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
    | bash "$BLOAT" | jq -r '.hookSpecificOutput.permissionDecisionReason'
}
FROZEN_WORDING="times a month — every token added is paid for that many times over (measured)."
LIVE_WORDING="measured by the local read index over its last 30-day window"
# 3.2 bytes per token, rounded the way jq rounds it rather than truncated.
live_tokens=$(( ((${#big} - 1) * 10 + 16) / 32 ))
write_rates "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
msg=$(price_bloat global-fresh "$CLAUDE_MD")
assert_contains "~20,000 times a month" "$msg"
assert_contains "$LIVE_WORDING" "$msg"
# The cost is the product of the two figures printed beside it, not of the measurement behind them:
# the message orders its reader to quote all three to Egor, so 125 tokens at the ~20,000 re-reads
# it shows has to come to the 2.5M it shows, and never to the 2,513,875 the raw 20,111 would give.
assert_eq 125 "$live_tokens"
assert_contains "~2.5M/month" "$msg"
# Every name the global file answers to resolves to the one the export keys it by.
assert_contains "~20,000 times a month" "$(price_bloat global-profile "$HOME/.claude-profiles/com/CLAUDE.md")"
assert_contains "~20,000 times a month" "$(price_bloat global-repo "$REAL_MD")"

echo "== bloat gate: a project the index measured is priced at that project's own rate"
assert_contains "~700 times a month" "$(price_bloat proj-literal "$WORK/liveproj/CLAUDE.md")"
assert_contains "~700 times a month" "$(price_bloat proj-local "$WORK/liveproj/CLAUDE.local.md")"
assert_contains "~500 times a month" "$(price_bloat proj-resolved "$WORK/livereal/CLAUDE.md")"
# A project nobody measured is not free, it is the class rate — and so is a memory index filed
# under a directory the export does not carry.
msg=$(price_bloat proj-unmeasured "$WORK/unmeasured/CLAUDE.md")
assert_contains "~3,000 times a month" "$msg"
assert_contains "$FROZEN_WORDING" "$msg"
assert_contains "~3,000 times a month" "$(price_bloat proj-memory "$WORK/liveproj/memory/MEMORY.md")"
# A project rate is the price of the instruction files that ride in that project's sessions, not
# of every file that shares their directory. Left unrestricted it priced ~/.claude/settings.json
# at the rate measured from its neighbours and denied it, quoting a re-read that never happens.
printf '{}\n' > "$WORK/liveproj/settings.json"
assert_eq pass "$(bloat_decision "$WORK/liveproj/settings.json")"
printf 'x\n' > "$WORK/liveproj/notes.txt"
assert_eq pass "$(bloat_decision "$WORK/liveproj/notes.txt")"

echo "== bloat gate: a memory index is priced by the project its path encodes"
# The index never sits in the directory tokenmap recorded — its parent is the memory/ subdirectory
# of a per-project transcript directory, whose name is the cwd with the non-alphanumerics dashed.
# The slug encodes a directory, and the sessions that read the index are the ones at or below it.
# Compared as encoded STRINGS the two are indistinguishable — /x/repo-other encodes exactly as
# /x/repo/other does — so a prefix test handed a busy neighbour the rate of this index.
# 641 for the root and 400 for the subdirectory come to the ~1,000 shown; the 9,000-read
# neighbour would carry it to ~10,000 the moment it were counted.
msg=$(price_bloat mem-slug "$MEM_DIR/MEMORY.md")
assert_contains "~1,000 times a month" "$msg"
assert_contains "$LIVE_WORDING" "$msg"
# A slug the export never measured is the class rate, not a match on a neighbouring project.
assert_contains "~3,000 times a month" \
  "$(price_bloat mem-unknown "$WORK/profiles/com/projects/-nowhere-at-all/memory/MEMORY.md")"

echo "== bloat gate: a memory file is priced by its class, whatever the index says"
# The recall that loads one names no path, so the index sees only the times it was opened by hand.
# Preferring that measurement — as every other class rightly does — prices a memory nobody opened
# all month as free, which is exactly the file the class constant exists to hold down.
mem_file="$MEM_DIR/one-fact.md"
printf 'a fact\n' > "$mem_file"
assert_contains "~150 times a month" "$(price_bloat mem-file "$mem_file")"
measured_memory() {
  jq --arg p "$1" '.paths.entries[$p] = {mode: "on_demand",
    monthly: {reads: 3.6, limit_units: 3.6}, weekly: {reads: 0.8, limit_units: 0.8}}' \
    "$RATES" > "$RATES.tmp" && mv "$RATES.tmp" "$RATES"
}
measured_memory "$mem_file"
assert_contains "~150 times a month" "$(price_bloat mem-file-measured "$mem_file")"
write_rates "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The index of the set is not one of its entries: MEMORY.md is measured with the project it belongs
# to, and blinding it would throw away the one memory-shaped file the export does see.
assert_contains "~1,000 times a month" "$(price_bloat mem-index-still-live "$MEM_DIR/MEMORY.md")"

echo "== bloat gate: a slash command is a guarded class like the skill it sits beside"
CMD_DIR="$HOME/.claude/commands"
mkdir -p "$CMD_DIR"
printf 'do the thing\n' > "$CMD_DIR/spawn.md"
assert_contains "~100 times a month" "$(price_bloat command-file "$CMD_DIR/spawn.md")"

echo "== bloat gate: a rate under one read a month is not a free file"
# round() would print 0, and "~0 times a month" reads as permission rather than as a small cost.
msg=$(price_bloat tiny /tmp/tiny-project/CLAUDE.md)
assert_contains "~1 time a month" "$msg"
assert_contains "$LIVE_WORDING" "$msg"

echo "== bloat gate: a stamp from the future is a broken clock, not a fresher measurement"
write_rates "$(stamp_ahead 6)"
msg=$(price_bloat future "$CLAUDE_MD")
assert_contains "~15,000 times a month" "$msg"
assert_contains "$FROZEN_WORDING" "$msg"
# Skew of a couple of minutes is not that, and must not throw the reading away.
write_rates "$(stamp_ahead 0)"
assert_contains "~20,000 times a month" "$(price_bloat no-skew "$CLAUDE_MD")"

echo "== bloat gate: the two benign producer drifts still parse"
# fromdateiso8601 accepts one spelling; a fractional second or a +00:00 offset must degrade to the
# same reading rather than to a silent fallback nobody would notice.
jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%S.123456Z)" \
  '{generated_at:$gen,window_days:30,global:{reads:20111.0}}' > "$RATES"
assert_contains "~20,000 times a month" "$(price_bloat frac-seconds "$CLAUDE_MD")"
jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
  '{generated_at:$gen,window_days:30,global:{reads:20111.0}}' > "$RATES"
assert_contains "~20,000 times a month" "$(price_bloat utc-offset "$CLAUDE_MD")"

echo "== bloat gate: an export past its window is not a number anybody can reproduce"
write_rates "$(stamp_ago 20)"
msg=$(price_bloat stale "$CLAUDE_MD")
assert_contains "~15,000 times a month" "$msg"
assert_contains "$FROZEN_WORDING" "$msg"
assert_contains "~3,000 times a month" "$(price_bloat stale-proj "$WORK/liveproj/CLAUDE.md")"
# Just inside the window still counts.
write_rates "$(stamp_ago 13)"
assert_contains "~20,000 times a month" "$(price_bloat nearly-stale "$CLAUDE_MD")"

echo "== bloat gate: an export it cannot read leaves the constants standing"
rm -f "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat no-file "$CLAUDE_MD")"
printf 'not json at all\n' > "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat malformed "$CLAUDE_MD")"
printf '{"projects":{}}\n' > "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat no-timestamp "$CLAUDE_MD")"
jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{generated_at:$gen,projects:{}}' > "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat no-global-key "$CLAUDE_MD")"
jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{generated_at:$gen,global:{reads:"lots"}}' > "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat unusable-rate "$CLAUDE_MD")"

echo "== bloat gate: the classes the export does not cover keep their own constants"
# docs, agents, skills and instructions are not in the export yet, and a live lookup that answers
# nothing for them must fall back rather than stop pricing them.
write_rates "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
msg=$(price_bloat class-docs "$HOME/.claude/docs/review-tiers.md")
assert_contains "~150 times a month" "$msg"
assert_contains "$FROZEN_WORDING" "$msg"
assert_contains "~3,000 times a month" "$(price_bloat class-agents "$HOME/.claude/agents/codex-worker.md")"
assert_contains "~100 times a month" "$(price_bloat class-skills "$HOME/.claude/skills/demo/SKILL.md")"
assert_eq pass "$(bloat_decision "$WORK/ordinary.md")"

echo "== write gate: the denial quotes the same live figure the bloat gate does"
# Two gates quoting different numbers for one file is what teaches a reader that neither is real.
assert_contains "~5,000 times a week, ~20,000 times a month" "$(price live-a "$CLAUDE_MD")"
assert_contains "~5,000 times a week, ~20,000 times a month" "$(price live-b "$REAL_MD")"
assert_contains "~200 times a week, ~700 times a month" "$(price live-c "$WORK/liveproj/CLAUDE.md")"
# A class the export does not carry, and a project it never measured, keep the constant.
assert_contains "~30 times a week, ~150 times a month" "$(price live-d "$HOME/.claude/docs/review-tiers.md")"
assert_contains "~700 times a week, ~3,000 times a month" "$(price live-e "$WORK/unmeasured/CLAUDE.md")"

echo "== bloat gate: current path rates price every Markdown file in weekly terms"
README="$WORK/liveproj/README.md"
CHEAP_MD="$WORK/liveproj/cheap.md"
ABSENT_MD="$WORK/liveproj/absent.md"
PROJECT_MEMORY="$WORK/liveproj/MEMORY.md"
printf 'readme\n' > "$README"
printf 'cheap\n' > "$CHEAP_MD"
printf 'memory\n' > "$PROJECT_MEMORY"
write_current_rates() {
  jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg global "$CLAUDE_MD" \
    --arg project "$WORK/liveproj" --arg readme "$README" --arg cheap "$CHEAP_MD" \
    --arg memory "$PROJECT_MEMORY" --arg project_claude "$WORK/liveproj/CLAUDE.md" '{
    generated_at: $gen, window_days: 30,
    global: {reads: 20111.0, limit_units: 9800.0, requests: 130000, contexts: 1900},
    projects: {($project): {reads: 812.4, limit_units: 400.0, requests: 8000, contexts: 60}},
    weekly: {window_days: 7, basis_days: 30,
      global: {reads: 6176.0, limit_units: 3000.0, requests: 40000, contexts: 600},
      projects: {($project): {reads: 302.0, limit_units: 150.0, requests: 2000, contexts: 20}}},
    paths: {
      criteria: {extensions: [".md", ".markdown"], min_monthly_reads: 1.0, limit: 500},
      entries: {
        ($global): {mode: "always",
          monthly: {reads: 20111.0, limit_units: 9800.0},
          weekly: {reads: 6176.0, limit_units: 3000.0}},
        ($readme): {mode: "on-demand",
          monthly: {reads: 4000.0, limit_units: 2000.0},
          weekly: {reads: 1000.0, limit_units: 500.0}},
        ($cheap): {mode: "on-demand",
          monthly: {reads: 3.0, limit_units: 2.0},
          weekly: {reads: 2.0, limit_units: 1.0}},
        ($memory): {mode: "always",
          monthly: {reads: 812.4, limit_units: 400.0},
          weekly: {reads: 302.0, limit_units: 150.0}},
        ($project_claude): {mode: "always",
          monthly: {reads: 812.4, limit_units: 400.0},
          weekly: {reads: 302.0, limit_units: 150.0}}
      }
    }
  }' > "$RATES"
}
growth_output() {
  jq -cn --arg p "$1" --arg n "$2" --arg s "$3" \
    '{tool_name:"Edit",cwd:"/tmp",session_id:$s,
      tool_input:{file_path:$p,old_string:"x",new_string:$n}}' | bash "$BLOAT"
}
growth_decision() {
  local out
  out=$(growth_output "$@")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"'
}
write_current_rates
readme_growth=$(python3 -c 'print("r" * 800)')
msg=$(growth_output "$README" "$readme_growth" path-readme \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
# The limit-unit figure, not the dollar-priced `reads` beside it in the same entry: the gate
# guards the weekly usage limit, and that counter charges cache reads at about nothing.
assert_contains "~500 times a week" "$msg"
assert_contains "~2,000 times a month" "$msg"
assert_contains "tokens/week" "$msg"
assert_contains "tokenmap reads $README" "$msg"
memory_growth=$(python3 -c 'print("m" * 3000)')
msg=$(growth_output "$PROJECT_MEMORY" "$memory_growth" path-memory \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~150 times a week" "$msg"
assert_contains "~500 times a month" "$msg"

echo "== number formatting: the figures are readable before they are anything else"
# Seven bare digits are read wrong more often than right, and these numbers exist to be acted on.
fmt() { ( . "$ROOT/share/instruction-files.sh"; "$@" ); }
assert_eq "63"     "$(fmt instruction_format_tokens 63)"
assert_eq "1.5k"   "$(fmt instruction_format_tokens 1500)"
assert_eq "150k"   "$(fmt instruction_format_tokens 150000)"
assert_eq "2.5M"   "$(fmt instruction_format_tokens 2513875)"
assert_eq "12M"    "$(fmt instruction_format_tokens 12000000)"
assert_eq "515"    "$(fmt instruction_format_count 515)"
assert_eq "2,000"  "$(fmt instruction_format_count 2000)"
assert_eq "1,000,000" "$(fmt instruction_format_count 1000000)"
assert_eq "1.5"    "$(fmt instruction_format_count 1.5)"
assert_eq "1 time" "$(fmt instruction_times 1)"
assert_eq "20 times" "$(fmt instruction_times 20)"

echo "== bloat gate: a rate that drifts does not move the number Egor reads"
# The point of the ladder. Egor decides whether a file may grow from this figure, and a decision
# he cannot repeat tomorrow is no decision; the export's window slides every night, so the quoted
# price has to survive that drift without moving. It still moves when the rate really changes.
drifted_rates() {
  jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg readme "$README" --argjson w "$1" '{
    generated_at: $gen, window_days: 30,
    global: {reads: 20111.0, limit_units: 9800.0, requests: 130000, contexts: 1900},
    projects: {},
    paths: {
      criteria: {extensions: [".md", ".markdown"], min_monthly_reads: 1.0, limit: 500},
      entries: {($readme): {mode: "on-demand",
        monthly: {reads: ($w * 8), limit_units: ($w * 4)},
        weekly: {reads: ($w * 2), limit_units: $w}}}
    }
  }' > "$RATES"
}
drift_quote() {
  drifted_rates "$1"
  growth_output "$README" "$readme_growth" "drift-$1" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason' \
    | grep -o '~[0-9,.]* times\? a week'
}
assert_eq "~500 times a week" "$(drift_quote 460)"
assert_eq "~500 times a week" "$(drift_quote 540)"
assert_eq "~700 times a week" "$(drift_quote 720)"
write_current_rates

echo "== bloat gate: the weekly budget makes cheap files more permissive"
cheap_growth=$(python3 -c 'print("c" * 10000)')
assert_eq pass "$(growth_decision "$CHEAP_MD" "$cheap_growth" threshold-cheap)"

echo "== bloat gate: the weekly threshold is never stricter than 120 bytes"
exactly_120=$(python3 -c 'print("g" * 121)')
over_120=$(python3 -c 'print("g" * 122)')
assert_eq pass "$(growth_decision "$CLAUDE_MD" "$exactly_120" clamp-pass)"
assert_eq deny "$(growth_decision "$CLAUDE_MD" "$over_120" clamp-deny)"

echo "== bloat gate: a fresh export proves an absent Markdown file cheap"
# Below the cap the export holds EVERY file above min_monthly_reads, so an absent one is under
# that threshold and nothing else. Quoting the cheapest surviving entry instead is a bound the
# export does not support: with one entry left it announced a missing file at ~20,111 a month.
absent=$(growth_output "$ABSENT_MD" "$cheap_growth" absent-fresh)
assert_eq pass "$(printf '%s' "$absent" | jq -r '.hookSpecificOutput.permissionDecision // "pass"')"
notice=$(printf '%s' "$absent" | jq -r '.hookSpecificOutput.additionalContext')
assert_eq "$ABSENT_MD is below ~1 limit unit/month; not gated." "$notice"
assert_eq "" "$(growth_output "$ABSENT_MD" "$readme_growth" absent-fresh)"
ABSENT_MD_TWO="$WORK/liveproj/absent-two.md"
assert_contains "$ABSENT_MD_TWO is below ~1 limit unit/month; not gated." \
  "$(growth_output "$ABSENT_MD_TWO" "$cheap_growth" absent-fresh \
    | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ABSENT_MD is below ~1 limit unit/month; not gated." \
  "$(growth_output "$ABSENT_MD" "$cheap_growth" absent-other-session \
    | jq -r '.hookSpecificOutput.additionalContext')"
unavailable=$(jq -cn --arg p "$WORK/liveproj/unavailable.md" --arg n "$cheap_growth" \
  '{tool_name:"Edit",cwd:"/tmp",session_id:"absent-unavailable",
    tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
  | INSTRUCTION_BLOAT_GATE_STAMPS=/dev/null/nope bash "$BLOAT")
assert_eq "" "$unavailable"
assert [ "${#notice}" -lt "$(( ${#msg} / 2 ))" ]

echo "== bloat gate: at the cap the floor is the cheapest entry that survived the cut"
# Truncated by rank, the export no longer holds every file above min_monthly_reads, and that
# threshold stops bounding what is missing. Only the cheapest survivor still does.
jq --argjson n "$(jq '.paths.entries | length' "$RATES")" '.paths.criteria.limit = $n' "$RATES" \
  > "$RATES.capped" && mv "$RATES.capped" "$RATES"
assert_contains "$ABSENT_MD is below ~3 limit units/month; not gated." \
  "$(growth_output "$ABSENT_MD" "$cheap_growth" absent-capped \
    | jq -r '.hookSpecificOutput.additionalContext')"
write_current_rates

echo "== bloat gate: an always-on file the export never measured keeps its class price"
# Every instruction file is Markdown, so testing "absent Markdown is cheap" before the class
# lookup made that lookup unreachable for all of them: a project CLAUDE.md that no session ever
# Read explicitly — which is most of them, since they are auto-loaded rather than opened — was
# announced ungated at ~1 a month while its project was measured at 300 limit units.
UNMEASURED="$WORK/otherproj"
mkdir -p "$UNMEASURED/nested"
printf 'x\n' > "$UNMEASURED/CLAUDE.md"
printf 'x\n' > "$UNMEASURED/nested/CLAUDE.md"
jq --arg p "$UNMEASURED/nested" '.projects[$p] = {reads: 600.0, limit_units: 300.0}' "$RATES" \
  > "$RATES.sub" && mv "$RATES.sub" "$RATES"
msg=$(price_bloat unmeasured-project "$UNMEASURED/CLAUDE.md")
assert_contains "~300 times a month" "$msg"
# The project rate belongs to the instruction files, not to everything sharing their directory.
assert_eq "" "$(growth_output "$UNMEASURED/settings.json" "$cheap_growth" unmeasured-neighbour)"
# The sessions that pay for a CLAUDE.md are the ones at or below its directory, so a repository
# root file collects every subdirectory that ran sessions, not only the exact-key match.
jq --arg p "$UNMEASURED" '.projects[$p] = {reads: 400.0, limit_units: 200.0}' "$RATES" \
  > "$RATES.root" && mv "$RATES.root" "$RATES"
assert_contains "~500 times a month" "$(price_bloat unmeasured-sum "$UNMEASURED/CLAUDE.md")"
write_current_rates

echo "== write gate: current path rates use the same weekly-first figures"
msg=$(price current-global "$CLAUDE_MD")
assert_contains "re-read ~3,000 times a week" "$msg"
assert_contains "~10,000 times a month" "$msg"
assert_contains "tokenmap reads $CLAUDE_MD" "$msg"
msg=$(price current-project "$WORK/liveproj/CLAUDE.md")
assert_contains "re-read ~150 times a week" "$msg"
assert_contains "~500 times a month" "$msg"

write_rates "$(stamp_ago 20)"
assert_contains "~3,000 times a week, ~15,000 times a month" "$(price live-f "$CLAUDE_MD")"

# Every later section is about the constants, so the export stops being in effect here.
unset TOKENMAP_RATES

echo "== bloat gate: every guarded instruction file is English-only"
# Absorbed from the standalone global-CLAUDE.md guard, which asked this of one file. The whole
# guarded set answers to it now, and «...» stays the one way Russian is written in these files.
CYR_STAMPS="$HOME/.cache/bloat-cyr"
mkdir -p "$WORK/memproj/memory"
printf 'index\n' > "$WORK/memproj/memory/MEMORY.md"
cyr() {
  jq -cn --arg p "$1" --arg n "$2" --arg s "cyr-$3" --arg tool "${4:-Edit}" '
    {tool_name:$tool, cwd:"/tmp", session_id:$s,
     tool_input: (if $tool == "Write" then {file_path:$p, content:$n}
                  else {file_path:$p, old_string:"x", new_string:$n} end)}' \
    | INSTRUCTION_BLOAT_GATE_STAMPS="$CYR_STAMPS" bash "$BLOAT"
}
cyr_decision() {
  local out
  out=$(cyr "$@")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
RU='Правило про воркеров'
assert_contains "English-only" \
  "$(cyr "$CLAUDE_MD" "$RU" global | jq -r '.hookSpecificOutput.permissionDecisionReason')"
assert_eq deny "$(cyr_decision "$WORK/memproj/memory/MEMORY.md" "$RU" memory)"
assert_eq deny "$(cyr_decision "$REPO/CLAUDE.md" "$RU" project)"
assert_eq deny "$(cyr_decision "$REPO_DOCS/review-tiers.md" "$RU" doc)"
assert_eq deny "$(cyr_decision "$HOME/.claude/skills/demo/SKILL.md" "$RU" skill)"
assert_eq deny "$(cyr_decision "$CLAUDE_MD" "$RU" write Write)"
# The quoted trigger phrase is the documented escape, and it is the only reason one of these files
# would carry Cyrillic at all.
assert_eq pass "$(cyr_decision "$CLAUDE_MD" 'Trigger on «проверь комментарии» only' quoted)"
assert_eq pass "$(cyr_decision "$CLAUDE_MD" 'plain english line' ascii)"
assert_eq pass "$(cyr_decision "$WORK/ordinary.md" "$RU" unguarded)"
# Nothing about the language depends on a price, so a rate lookup that answers nothing must not
# switch the rule off.
assert_eq deny \
  "$(TOKENMAP_RATES=/dev/null/nope cyr_decision "$CLAUDE_MD" "$RU" no-rates)"
# It is asked before any byte arithmetic: an edit that shrinks the file is still English-only.
assert_contains "English-only" \
  "$(jq -cn --arg p "$CLAUDE_MD" --arg n "$RU" \
       '{tool_name:"Edit",cwd:"/tmp",session_id:"cyr-shrink",
         tool_input:{file_path:$p,old_string:"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",new_string:$n}}' \
     | INSTRUCTION_BLOAT_GATE_STAMPS="$CYR_STAMPS" bash "$BLOAT" \
     | jq -r '.hookSpecificOutput.permissionDecisionReason')"

echo "== bloat gate: the global file's byte ceiling stands outside the retry ritual"
# The one always-on file has a size past which growth is refused rather than priced, and the
# audit-then-retry stamp must not be a way through it.
CEIL_STAMPS="$HOME/.cache/bloat-ceiling"
ceil() {
  jq -cn --arg p "$1" --arg o "$2" --arg n "$3" --arg s "ceil-$4" --arg t "$TRANSCRIPT" \
    '{tool_name:"Edit",cwd:"/tmp",session_id:$s,transcript_path:$t,
      tool_input:{file_path:$p,old_string:$o,new_string:$n}}' \
    | INSTRUCTION_BLOAT_GATE_STAMPS="$CEIL_STAMPS" bash "$BLOAT"
}
ceil_decision() {
  local out
  out=$(ceil "$@")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
ceil_reason() { ceil "$@" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
grow200=$(python3 -c 'print("z"*201, end="")')

rm -rf "$CEIL_STAMPS"
python3 -c 'print("g"*32899)' > "$REAL_MD"
assert_eq 32900 "$(wc -c <"$REAL_MD" | tr -d '[:space:]')"
assert_contains "past its 33000-byte ceiling" "$(ceil_reason "$CLAUDE_MD" x "$grow200" hard)"
# The stamp ritual never gets a say: the identical edit is denied again after a full re-read, which
# is exactly what would have passed it for ordinary growth.
append_read "$CLAUDE_MD"
age_stamps "$CEIL_STAMPS"
assert_contains "past its 33000-byte ceiling" "$(ceil_reason "$CLAUDE_MD" x "$grow200" hard)"
append_read "$CLAUDE_MD"
age_stamps "$CEIL_STAMPS"
assert_eq deny "$(ceil_decision "$CLAUDE_MD" x "$grow200" hard)"
# Identity, not spelling: the profile symlink and the repo path are the same file.
assert_eq deny "$(ceil_decision "$HOME/.claude-profiles/com/CLAUDE.md" x "$grow200" hard-profile)"
assert_eq deny "$(ceil_decision "$REAL_MD" x "$grow200" hard-repo)"
# A Write is sized by the content it would leave behind.
assert_contains "past its 33000-byte ceiling" \
  "$(jq -cn --arg p "$CLAUDE_MD" --arg n "$(python3 -c 'print("g"*34000, end="")')" \
       '{tool_name:"Write",cwd:"/tmp",session_id:"ceil-write",tool_input:{file_path:$p,content:$n}}' \
     | INSTRUCTION_BLOAT_GATE_STAMPS="$CEIL_STAMPS" bash "$BLOAT" \
     | jq -r '.hookSpecificOutput.permissionDecisionReason')"

echo "== bloat gate: shrinking an oversized global file is the way back down, not a violation"
# The cap is direction-aware. A gate that denied 34000 -> 33500 would leave the only edit that fixes
# the problem as the one it refuses.
python3 -c 'print("g"*33999)' > "$REAL_MD"
assert_eq "" "$(ceil "$CLAUDE_MD" "$grow200" x shrink)"
assert_eq pass "$(ceil_decision "$CLAUDE_MD" "$grow200" x shrink)"

echo "== bloat gate: the ceiling is not gated by the growth threshold"
# A byte over the cap is over the cap; the threshold below which growth goes unpriced says nothing
# about the size the file would reach.
python3 -c 'print("g"*32998)' > "$REAL_MD"
assert_eq 32999 "$(wc -c <"$REAL_MD" | tr -d '[:space:]')"
assert_eq deny "$(ceil_decision "$CLAUDE_MD" x xyz tiny-over)"
# Landing exactly on the cap is not past it — it is only worth a warning.
exact_out=$(ceil "$CLAUDE_MD" x xy tiny-exact)
assert_eq "" "$(printf '%s' "$exact_out" | jq -r '.hookSpecificOutput.permissionDecision // ""')"
assert_contains "would be 33000 bytes" \
  "$(printf '%s' "$exact_out" | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "== bloat gate: between the two bounds the warning rides along with the ordinary pricing"
rm -rf "$CEIL_STAMPS"
python3 -c 'print("g"*29899)' > "$REAL_MD"
msg=$(ceil_reason "$CLAUDE_MD" x "$big" warn-flow)
assert_contains "tokens/week and " "$msg"
assert_contains "would be 30299 bytes" "$msg"
append_read "$CLAUDE_MD"
age_stamps "$CEIL_STAMPS"
warn_out=$(ceil "$CLAUDE_MD" x "$big" warn-flow)
assert_eq "" "$(printf '%s' "$warn_out" | jq -r '.hookSpecificOutput.permissionDecision // ""')"
assert_contains "would be 30299 bytes" \
  "$(printf '%s' "$warn_out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
# Under the warning bound the size is nobody's business, so the ordinary denial says nothing about it.
python3 -c 'print("g"*999)' > "$REAL_MD"
rm -rf "$CEIL_STAMPS"
case "$(ceil_reason "$CLAUDE_MD" x "$big" quiet)" in
  *"would be"*) fail "a small global file was warned about its size" ;;
esac

echo "== bloat gate: the ceiling belongs to the global file alone"
# Every other guarded file is priced, however large it is: only the global one rides in every
# session of every project.
mkdir -p "$WORK/bigproj"
python3 -c 'print("g"*39999)' > "$WORK/bigproj/CLAUDE.md"
msg=$(ceil_reason "$WORK/bigproj/CLAUDE.md" x "$big" other-file)
assert_contains "tokens/week and " "$msg"
case "$msg" in *ceiling*) fail "a project file was held to the global file's ceiling" ;; esac
printf 'global rules\n' > "$REAL_MD"

echo "== tripwire: the bytes from before the change are kept, and they restore the file"
# The original content, so the sections after this one still measure their own deltas.
printf 'global rules\n' > "$REAL_MD"
snap_sid() {
  jq -cn --arg s snap '{session_id:$s,hook_event_name:"PostToolUse"}' | bash "$WATCH" "$1"
}
snap_sid baseline >/dev/null
printf 'smuggled in without asking\n' > "$REAL_MD"
ctx=$(snap_sid check | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED" "$ctx"
assert_contains "puts them back" "$ctx"
# The report carries a real command; running it has to give the original bytes back.
undo=$(printf '%s' "$ctx" | sed -n "s/.*puts them back: \(cp '[^']*' '[^']*'\).*/\1/p")
assert "[" -n "$undo" "]"
eval "$undo"
assert_eq "global rules" "$(cat "$REAL_MD")"

echo "== tripwire: the command is Egor's to ask for, never one the reader runs by itself"
# The writer is as often another chat or a worker as the agent reading the report, and this hook
# cannot tell which; a reader that rolls back on its own eats whatever that other session was
# doing. So the report has to say so in the same breath as it offers the command.
assert_contains "Do NOT run that command" "$ctx"
assert_contains "Restore only if he asks for it" "$ctx"
case "$ctx" in
  *"stop, put the file back"*) fail "the report still orders an unprompted rollback" ;;
esac

echo "== tripwire: a second session cannot hand out the smuggled bytes as the good ones"
# The snapshot directory is shared while the baselines are not, so the session that reports second
# finds a copy of the smuggled bytes sitting beside the good ones. Each session asks for the
# version ITS OWN baseline recorded, so what either one hands back is the good version — an undo
# that restores the change it is undoing is the failure this guards.
printf 'global rules\n' > "$REAL_MD"
two_sid() {
  jq -cn --arg s "$1" '{session_id:$s,hook_event_name:"PostToolUse"}' | bash "$WATCH" "$2"
}
undo_from() { printf '%s' "$1" | sed -n 's/.*puts them back: \(.*\) These files are re-read.*/\1/p'; }
two_sid pair-a baseline >/dev/null
two_sid pair-b baseline >/dev/null
printf 'smuggled by someone\n' > "$REAL_MD"
ctx_a=$(two_sid pair-a check | jq -r '.hookSpecificOutput.additionalContext // ""')
ctx_b=$(two_sid pair-b check | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED" "$ctx_a"
assert_contains "puts them back" "$ctx_a"
# The session that reported second saw the same original bytes, so it can undo the change too.
assert_contains "CHANGED" "$ctx_b"
assert_contains "puts them back" "$ctx_b"
# The one that reported after the snapshot already held the smuggled version is the strict case.
undo_b=$(undo_from "$ctx_b")
assert [ -n "$undo_b" ]
eval "$undo_b"
assert_eq "global rules" "$(cat "$REAL_MD")"
printf 'smuggled by someone\n' > "$REAL_MD"
undo_a=$(undo_from "$ctx_a")
eval "$undo_a"
assert_eq "global rules" "$(cat "$REAL_MD")"

echo "== tripwire: a doc filed one level down is watched too"
mkdir -p "$HOME/.claude/docs/topic"
printf 'nested doc\n' > "$HOME/.claude/docs/topic/deep.md"
watch_nested() {
  jq -cn --arg s nested '{session_id:$s,hook_event_name:"PostToolUse"}' | bash "$WATCH" "$1"
}
watch_nested baseline >/dev/null
assert_eq "" "$(watch_nested check)"
printf 'nested doc changed\n' > "$HOME/.claude/docs/topic/deep.md"
assert_contains "deep.md" \
  "$(watch_nested check | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "== tripwire: a quiet session says nothing"
watch() {
  local arg=$1 sid=${2:-sid-a}
  jq -cn --arg s "$sid" '{session_id:$s,hook_event_name:"PostToolUse"}' | bash "$WATCH" "$arg"
}
watch baseline >/dev/null
assert_eq "" "$(watch check)"

echo "== tripwire: a shell write is reported once, with the delta"
printf 'global rules and a smuggled line\n' > "$REAL_MD"
out=$(watch check | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED" "$out"
assert_contains "CLAUDE.md" "$out"
assert_contains "+20 bytes" "$out"
assert_contains "revert" "$out"
assert_eq "" "$(watch check)"
assert_contains "CHANGED" "$(cat "$INSTRUCTION_WATCH_LOG")"

echo "== tripwire: a file that appears or disappears is a change too"
printf 'new agent\n' > "$HOME/.claude/agents/smuggled.md"
out=$(watch check | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "ADDED" "$out"
assert_contains "smuggled.md" "$out"
rm "$HOME/.claude/agents/smuggled.md"
out=$(watch check | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "DELETED" "$out"

echo "== tripwire: sessions do not answer for each other"
watch baseline sid-b >/dev/null
printf 'changed again\n' > "$HOME/.claude/docs/review-tiers.md"
assert_contains "CHANGED" "$(watch check sid-a | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_contains "CHANGED" "$(watch check sid-b | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "== tripwire: no baseline yet is silent, and it builds one"
rm -f "$INSTRUCTION_WATCH_STATE"/*.tsv
assert_eq "" "$(watch check sid-c)"
assert [ -s "$INSTRUCTION_WATCH_STATE/session-sid-c.tsv" ]

echo "== tripwire: the harness switching model is not an edit to settings.json"
printf '{"model":"sonnet","permissions":{"defaultMode":"bypassPermissions"},"hooks":{}}\n' \
  > "$HOME/.claude/settings.json"
watch baseline sid-set >/dev/null
printf '{"model":"opus","permissions":{"defaultMode":"acceptEdits"},"hooks":{}}\n' \
  > "$HOME/.claude/settings.json"
assert_eq "" "$(watch check sid-set)"
# The part that matters still reports: a hook silently removed is the attack this watches for.
printf '{"model":"opus","permissions":{"defaultMode":"acceptEdits"},"hooks":{"Stop":[]}}\n' \
  > "$HOME/.claude/settings.json"
assert_contains "settings.json" "$(watch check sid-set | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "== tripwire: one missing file is not the whole set disappearing"
watch baseline sid-d >/dev/null
rm "$HOME/.claude/agents/codex-worker.md"
printf 'moved on\n' > "$HOME/.claude/docs/review-tiers.md"
out=$(watch check sid-d | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "DELETED" "$out"
assert_contains "codex-worker.md" "$out"
assert_contains "CHANGED" "$out"
# stat exits 1 on the missing entry while still printing the rest; the surviving files must
# not be swept up as deleted with it.
assert [ "$(grep -c DELETED <<<"$out")" = 1 ]
case "$out" in *"DELETED $HOME/.claude/CLAUDE.md"*) fail "a present file was reported deleted" ;; esac
printf 'worker agent\n' > "$HOME/.claude/agents/codex-worker.md"
watch baseline sid-d >/dev/null

echo "== tripwire: a hostile file name cannot escape the alert string"
ALERT_LOG="$WORK/alert.log"
cat >"$INSTRUCTION_WATCH_ALERT" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$2" >>"${ALERT_LOG:?}"
STUB
chmod +x "$INSTRUCTION_WATCH_ALERT"
export ALERT_LOG
nasty="$HOME/.claude/agents/quote\"and\\slash.md"
printf 'smuggled\n' > "$nasty"
watch check sid-d >/dev/null
# The alert is fired detached so a wedged Hammerspoon cannot hold the hook, so wait for it.
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$ALERT_LOG" ] && break; sleep 0.2; done
assert [ -s "$ALERT_LOG" ]
# Both specials arrive escaped, so the Lua literal closes where it should.
assert_contains '\"' "$(cat "$ALERT_LOG")"
assert_contains '\\' "$(cat "$ALERT_LOG")"
rm "$nasty"
watch baseline sid-d >/dev/null

echo "== tripwire: an unusable alert channel never breaks the hook"
printf x >> "$REAL_MD"
out=$(INSTRUCTION_WATCH_ALERT="$WORK/does-not-exist" watch check sid-c \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED" "$out"

echo "== tripwire: a malformed payload is survivable"
assert_eq "" "$(printf 'not json' | bash "$WATCH" check)"

echo "== tripwire: the visible name is watched, not only what it resolves to"
# Retargeting or deleting the symlink every session actually reads leaves the old target intact,
# so a watch that stats only the resolved path sees nothing at all.
printf 'global rules\n' > "$REAL_MD"
printf 'somewhere else\n' > "$REPO/global/DECOY.md"
watch baseline sid-link >/dev/null
assert_eq "" "$(watch check sid-link)"
ln -sf "$REPO/global/DECOY.md" "$CLAUDE_MD"
out=$(watch check sid-link | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "RETARGETED" "$out"
assert_contains "DECOY.md" "$out"
# The file the link used to name is untouched, so there is nothing to put back.
case "$out" in *"puts them back"*) fail "a retargeted link offered a byte restore" ;; esac
ln -sf "$REAL_MD" "$CLAUDE_MD"
watch baseline sid-link >/dev/null
rm "$CLAUDE_MD"
assert_contains "DELETED" \
  "$(watch check sid-link | jq -r '.hookSpecificOutput.additionalContext // ""')"
ln -s "$REAL_MD" "$CLAUDE_MD"

echo "== tripwire: a same-size rewrite inside the same second is still a change"
# Whole-second mtime plus size was the whole fingerprint, so a rewrite landing in the same second
# at the same length was indistinguishable from no write at all.
printf 'aaaaaaaaaaaa\n' > "$REAL_MD"
watch baseline sid-sec >/dev/null
printf 'bbbbbbbbbbbb\n' > "$REAL_MD"
assert_eq "$(stat -f %m "$REAL_MD")" "$(stat -f %m "$REAL_MD")"
assert_contains "CHANGED" \
  "$(watch check sid-sec | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "== tripwire: the wider guarded set is watched, not just the always-on files"
# These were guarded by the write gate and invisible to the tripwire, which is the one hole
# neither half of the pair could report.
mkdir -p "$HOME/.claude/instructions"
printf 'topic rules\n' > "$HOME/.claude/instructions/topic.md"
printf 'local rules\n' > "$HOME/.claude/CLAUDE.local.md"
mkdir -p "$REPO/global/docs/deep/deeper"
printf 'buried\n' > "$REPO/global/docs/deep/deeper/note.md"
# The class table answers `span` for a `.markdown` too, and a file one door speaks for while the
# other never enumerates it is the one hole neither half can report.
printf 'long extension\n' > "$HOME/.claude/docs/long.markdown"
watch baseline sid-wide >/dev/null
assert_eq "" "$(watch check sid-wide)"
printf 'topic rules changed\n' > "$HOME/.claude/instructions/topic.md"
printf 'local rules changed\n' > "$HOME/.claude/CLAUDE.local.md"
printf 'buried deeper\n' > "$REPO/global/docs/deep/deeper/note.md"
printf 'long extension changed\n' > "$HOME/.claude/docs/long.markdown"
out=$(watch check sid-wide | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "topic.md" "$out"
assert_contains "CLAUDE.local.md" "$out"
assert_contains "note.md" "$out"
assert_contains "long.markdown" "$out"
# And the door in front of it: one extension list, or the gate speaks for a file the tripwire
# never watched.
assert_eq deny "$(decision "echo x > $HOME/.claude/docs/long.markdown")"

echo "== tripwire: the price quoted is the dearest class in the report, not one blanket number"
# A skill costs a fiftieth of the global file; quoting the global rate over it made every
# number in the message untrustworthy.
printf 'skill body\n' > "$HOME/.claude/skills/demo/SKILL.md"
watch baseline sid-rate >/dev/null
printf 'skill body changed\n' > "$HOME/.claude/skills/demo/SKILL.md"
out=$(watch check sid-rate | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "up to ~90 full-read" "$out"
watch baseline sid-rate >/dev/null
printf 'agent changed\n' > "$HOME/.claude/agents/codex-worker.md"
printf 'skill body again\n' > "$HOME/.claude/skills/demo/SKILL.md"
out=$(watch check sid-rate | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "up to ~2500 full-read" "$out"

echo "== tripwire: a path with a quote in it produces a command that still runs"
QUOTED="$REPO/global/docs/it's-tricky.md"
printf 'quoted doc\n' > "$QUOTED"
watch baseline sid-quote >/dev/null
printf 'quoted doc smuggled\n' > "$QUOTED"
ctx=$(watch check sid-quote | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "puts them back" "$ctx"
undo=$(printf '%s' "$ctx" | sed -n 's/.*puts them back: \(.*\) These files are re-read.*/\1/p')
eval "$undo"
assert_eq "quoted doc" "$(cat "$QUOTED")"
rm "$QUOTED"

echo "== tripwire: settings.json is the one file git cannot give back, so its undo has to work"
# Its hash is taken through a jq filter while the snapshot's was taken raw, so the two could
# never compare equal and the guard built on that comparison never fired.
printf '{"model":"opus","hooks":{"Stop":[]}}\n' > "$HOME/.claude/settings.json"
watch baseline sid-set-a >/dev/null
watch baseline sid-set-b >/dev/null
printf '{"model":"opus","hooks":{}}\n' > "$HOME/.claude/settings.json"
ctx=$(watch check sid-set-a | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "settings.json" "$ctx"
assert_contains "puts them back" "$ctx"
ctx_b=$(watch check sid-set-b | jq -r '.hookSpecificOutput.additionalContext // ""')
undo=$(printf '%s' "$ctx_b" | sed -n 's/.*puts them back: \(.*\) These files are re-read.*/\1/p')
assert [ -n "$undo" ]
eval "$undo"
assert_contains '"Stop"' "$(cat "$HOME/.claude/settings.json")"

echo "== tripwire: a file nobody vetted is not restored over its own removal"
# An ADDED file went straight into the trusted snapshot, so deleting the smuggled thing was
# reported as the violation and the undo offered put it back.
watch baseline sid-add >/dev/null
printf 'unvetted agent\n' > "$HOME/.claude/agents/unvetted.md"
out=$(watch check sid-add | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "ADDED" "$out"
rm "$HOME/.claude/agents/unvetted.md"
out=$(watch check sid-add | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "DELETED" "$out"
case "$out" in *"puts them back"*) fail "the tripwire offered to restore a file nobody vetted" ;; esac

echo "== tripwire: a session starting mid-change does not destroy the recovery copy"
# Baselines are per-session and the snapshot directory is shared, so a session that first runs
# after the change would overwrite the one copy the session that saw the good bytes still needs.
printf 'good bytes\n' > "$REAL_MD"
watch baseline sid-keeper >/dev/null
printf 'bad bytes\n' > "$REAL_MD"
watch check sid-newcomer >/dev/null
ctx=$(watch check sid-keeper | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED" "$ctx"
undo=$(printf '%s' "$ctx" | sed -n 's/.*puts them back: \(.*\) These files are re-read.*/\1/p')
assert [ -n "$undo" ]
eval "$undo"
assert_eq "good bytes" "$(cat "$REAL_MD")"

echo "== stamp sweep: a misconfigured stamp directory is not a licence to delete"
# The sweep matched anything starting with a hex character and removed it recursively, so a
# stamp directory pointed at real data would take ~/.claude/agents with it.
SWEEP="$WORK/sweep"
mkdir -p "$SWEEP/agents" "$SWEEP/0123456789abcdef" "$SWEEP/deadbeefdeadbeef"
printf 'somebody real data\n' > "$SWEEP/agents/keep.md"
printf 'loose file\n' > "$SWEEP/abcdef0123456789"
touch -A -250000 "$SWEEP/agents" "$SWEEP/0123456789abcdef" "$SWEEP/deadbeefdeadbeef" \
      "$SWEEP/abcdef0123456789"
assert_eq deny "$(INSTRUCTION_WRITE_GATE_STAMPS="$SWEEP" decision "echo sweep > $CLAUDE_MD")"
assert [ -f "$SWEEP/agents/keep.md" ]
assert [ -f "$SWEEP/abcdef0123456789" ]
# An aged stamp is still what the sweep is for.
assert [ ! -d "$SWEEP/0123456789abcdef" ]


echo "== gate matrix: settings.json is out of the deny gate entirely"
# Not an instruction file — nothing re-reads it into a context window — and the harness rewrites
# it on every model or permission-mode switch, so a denial here cost Egor a tactical "ok" and
# caught nothing. The tripwire still watches it, which is the half that can put its bytes back.
assert_eq pass "$(decision "echo x > $HOME/.claude/settings.json")"
assert_eq pass "$(GATE_CWD="$HOME/.claude" decision 'echo x > settings.json')"
assert_eq pass "$(decision "printf x | tee $HOME/.claude/settings.json")"
assert_eq pass "$(in_span decision "echo y >> $HOME/.claude/settings.json")"
assert_eq pass "$(decision "python3 -c \"open('$HOME/.claude/settings.json','w').write('{}')\"")"

echo "== gate matrix: the every-session class is denied in the span as much as out of it"
# The global file, a project file, the local override. Growing or shrinking, span or no span:
# these ride in the prefix of every session, and no cleanup of them is a model's own call.
printf 'project rules\n' > "$REPO/CLAUDE.md"
printf 'local rules\n' > "$HOME/.claude/CLAUDE.local.md"
for state in in_span out_span; do
  assert_eq deny "$($state decision "printf tiny > $CLAUDE_MD")"
  assert_eq deny "$($state decision "echo more >> $CLAUDE_MD")"
  assert_eq deny "$($state decision "printf tiny > $REAL_MD")"
  assert_eq deny "$($state decision "printf tiny > $REPO/CLAUDE.md")"
  assert_eq deny "$($state decision "printf tiny > $HOME/.claude/CLAUDE.local.md")"
  assert_eq deny "$($state decision "printf tiny | tee $CLAUDE_MD")"
  assert_eq deny "$($state decision "python3 -c \"open('$CLAUDE_MD','w').write('x')\"")"
done

echo "== gate matrix: the span reshapes the on-demand instruction files but never grows them"
# Egor is away and the model is the only actor, so a write that REPLACES a doc's bytes is the
# cleanup he left it; an append can only add to a file every later session re-reads. Out of the
# span nothing moved: both shapes are still denied.
for f in "$HOME/.claude/docs/review-tiers.md" "$HOME/.claude/agents/codex-worker.md" \
         "$HOME/.claude/skills/demo/SKILL.md" "$HOME/.claude/commands/worker.md"; do
  assert_eq pass "$(in_span decision "printf shorter > $f")"
  assert_eq deny "$(in_span decision "echo more >> $f")"
  assert_eq deny "$(out_span decision "printf shorter > $f")"
  assert_eq deny "$(out_span decision "echo more >> $f")"
done

echo "== gate matrix: every write shape the gate reads is judged on whether it can shrink"
DOC="$HOME/.claude/docs/review-tiers.md"
assert_eq pass "$(in_span decision "printf x >| $DOC")"
assert_eq pass "$(in_span decision "printf x | tee $DOC")"
assert_eq deny "$(in_span decision "printf x | tee -a $DOC")"
assert_eq pass "$(in_span decision "python3 -c \"open('$DOC','w').write('x')\"")"
assert_eq deny "$(in_span decision "python3 -c \"open('$DOC','a').write('x')\"")"
# `r+` and `a+` write past what is already there, so neither is a replacement.
assert_eq deny "$(in_span decision "python3 -c \"open('$DOC','r+').write('x')\"")"
assert_eq pass "$(in_span decision "python3 -c \"Path('$DOC').write_text('x')\"")"
assert_eq pass "$(in_span decision "node -e \"fs.writeFileSync('$DOC','x')\"")"
assert_eq deny "$(in_span decision "node -e \"fs.appendFileSync('$DOC','x')\"")"
assert_eq pass "$(in_span decision "perl -e \"open(my \$f, '>', '$DOC')\"")"
assert_eq deny "$(in_span decision "perl -e \"open(my \$f, '>>', '$DOC')\"")"
# A doc that does not exist yet: the shape still says replacement, and what the bytes come to is
# the tripwire's to measure.
assert_eq pass "$(in_span decision "printf x > $HOME/.claude/docs/new-in-span.md")"
assert_eq deny "$(out_span decision "printf x > $HOME/.claude/docs/new-in-span.md")"

echo "== gate matrix: a compound is judged row by row, never one row's class against another's shape"
# The class used to come off the FIRST destination and the shrink shape off ANY of them, so a
# command whose later row could shrink a doc carried an earlier row that only grew one.
AGENT_DOC="$HOME/.claude/agents/codex-worker.md"
assert_eq deny "$(in_span decision "true; : > $CLAUDE_MD")"
assert_eq deny "$(out_span decision "true; : > $CLAUDE_MD")"
assert_eq deny "$(in_span decision "echo more >> $DOC; printf shorter > $AGENT_DOC")"
assert_eq deny "$(in_span decision "printf shorter > $DOC; echo more >> $CLAUDE_MD")"
# The denial has to name the row it refused, not the one that stood first.
msg=$(in_span gate "printf shorter > $DOC; echo more >> $CLAUDE_MD" \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$CLAUDE_MD" "$msg"
case "$msg" in *"$DOC"*) fail "the denial named a destination it let through" ;; esac
# A row the span covers is still covered when it stands beside one no gate speaks for.
assert_eq pass "$(in_span decision "printf shorter > $DOC; grep -c . $CLAUDE_MD")"
assert_eq pass "$(in_span decision "printf shorter > $DOC; printf x > $HOME/.claude/settings.json")"
# An interpreter row is judged the same way, and a permitted redirection beside it never buys it
# a pass: the redirect rows and the interpreter constructs are two lists of one command.
assert_eq deny "$(in_span decision "printf shorter > $DOC; python3 -c \"open('$CLAUDE_MD','a').write('x')\"")"
# EVERY construct, each against its own shape: the second write is not judged by the first's
# mode, and its own name is the one refused.
assert_eq deny "$(in_span decision "python3 -c \"open('$DOC','w')\"; python3 -c \"open('$CLAUDE_MD','a')\"")"
msg=$(in_span gate "python3 -c \"open('$DOC','w')\"; python3 -c \"open('$AGENT_DOC','a')\"" \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$AGENT_DOC" "$msg"
# A copy verb inside an interpreter writes its DESTINATION: reading the source instead denies a
# read out of a guarded file and lets the write into one through.
assert_eq deny "$(in_span decision "python3 -c \"import shutil; shutil.copy('/tmp/x.md','$CLAUDE_MD')\"")"
assert_eq pass "$(in_span decision "python3 -c \"import shutil; shutil.copy('$CLAUDE_MD','/tmp/x.md')\"")"

echo "== gate matrix: the in-span denial names growth, the standing one names Egor's rule"
msg=$(in_span gate "echo grow-a >> $DOC" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "ADDS to" "$msg"
assert_contains "waits for him" "$msg"
msg=$(out_span gate "echo grow-b >> $DOC" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "read-only without his explicit OK" "$msg"
case "$msg" in *"autonomy span"*) fail "the standing denial talks about a span that is not standing" ;; esac

echo "== gate matrix: the review-debt ignore list is denied always, with its own reason"
for state in in_span out_span; do
  assert_eq deny "$($state decision "echo path >> $HOME/.claude/review-debt-ignore")"
  assert_eq deny "$($state decision "printf path > $HOME/.claude/review-debt-ignore")"
  assert_eq deny "$($state decision 'echo path >> review-debt-ignore')"
done
msg=$(in_span gate "echo one-path >> $HOME/.claude/review-debt-ignore" \
      | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "review debt" "$msg"
assert_contains "never a model's" "$msg"
case "$msg" in *"re-read across sessions"*) fail "the debt list was priced like an always-on file" ;; esac

echo "== gate matrix: ~/.claude/commands is guarded like every other class directory"
assert_eq deny "$(decision "echo x > $HOME/.claude/commands/worker.md")"
assert_eq deny "$(decision "echo x > $HOME/.claude/commands/brand-new.md")"
assert_eq deny "$(GATE_CWD="$HOME/.claude/commands" decision 'echo x >> worker.md')"
assert_eq deny "$(GATE_CWD="$HOME/.claude" decision 'echo x > commands/brand-new.md')"

echo "== gate matrix: a command is judged by its write TARGET, never by a name it carries"
# A guarded name inside a heredoc body or a quoted run is data being passed along. Reading it as a
# destination denied ordinary work — a scratchpad note quoting a rule, a commit message — while
# saying nothing true about what the command wrote.
mkdir -p "$WORK/scratch"
assert_eq pass "$(decision "cat > $WORK/scratch/notes.md <<'EOF'
CLAUDE.md says to keep instruction files short
EOF")"
assert_eq pass "$(decision "cat >> $WORK/scratch/notes.md <<'EOF'
the shape to avoid is a redirect into CLAUDE.md
EOF")"
assert_eq pass "$(decision "cat >> $WORK/scratch/notes.md <<'EOF'
echo x > CLAUDE.md
EOF")"
assert_eq pass "$(decision "printf x | tee $WORK/scratch/notes.md <<'EOF'
CLAUDE.md
EOF")"
assert_eq pass "$(decision "echo 'the note mentions CLAUDE.md' >> $WORK/scratch/notes.md")"
assert_eq pass "$(decision "python3 -c \"open('$WORK/scratch/notes.md','w').write('see CLAUDE.md for rules')\"")"
# An indented heredoc terminator is the same body.
assert_eq pass "$(decision "cat > $WORK/scratch/notes.md <<-'IND'
	CLAUDE.md
	IND")"
# A herestring declares no body, so nothing after it may be swallowed.
assert_eq deny "$(decision "grep -f - $WORK/unrelated.py <<<'pattern' > $CLAUDE_MD")"
# The target itself is still the target, however it is spelled.
assert_eq deny "$(decision "cat > $HOME/.claude/docs/heredoc-target.md <<'EOF'
a new doc nobody asked for
EOF")"
assert_eq deny "$(decision "echo x > \"$CLAUDE_MD\"")"
assert_eq deny "$(decision "echo x > '$CLAUDE_MD'")"
# An interpreter handed a quoted program is handed a program: there the quoted runs are syntax
# again, so the scan falls back to the raw command.
assert_eq deny "$(decision "bash -c 'echo x > $CLAUDE_MD'")"
assert_eq deny "$(decision "sh -c \"printf x > $CLAUDE_MD\"")"
# An interpreter writes a guarded file when it NAMES it in the call that writes, and not when the
# name is merely an argument somewhere in the same payload.
assert_eq pass "$(decision "python3 -c \"open('$WORK/scratch/o.md','w').write('$CLAUDE_MD')\"")"
assert_eq pass "$(decision "node -e \"fs.writeFileSync('$WORK/scratch/o.md', 'see $CLAUDE_MD')\"")"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','w').write('$WORK/scratch/o.md')\"")"

echo "== tripwire: growth this session's own call produced is put back inside the span"
# The gate ahead of this one can read a command's shape but never its result, so the bytes are
# this hook's to measure. Inside the span growth goes back rather than being reported: Egor is
# away, and the span's rule is the only arbiter left in the room.
span_check() { # sid tool key value transcript
  jq -cn --arg s "$1" --arg n "$2" --arg k "$3" --arg v "$4" --arg t "$5" --arg c "$WORK" \
    '{session_id:$s,hook_event_name:"PostToolUse",transcript_path:$t,tool_name:$n,cwd:$c,
      tool_input:{($k):$v}}' | bash "$WATCH" check | jq -r '.hookSpecificOutput.additionalContext // ""'
}
span_base() { jq -cn --arg s "$1" '{session_id:$s,hook_event_name:"PostToolUse"}' | bash "$WATCH" baseline; }
printf 'tier doc\n' > "$DOC"
span_base sid-revert >/dev/null
printf 'a line no human asked for\n' >> "$DOC"
ctx=$(span_check sid-revert Bash command "echo a line no human asked for >> $DOC" "$SPAN_T")
assert_contains "REVERTED" "$ctx"
assert_contains "PUT BACK" "$ctx"
assert_eq "tier doc" "$(cat "$DOC")"
# Nothing this hook does may be unrecoverable: what it overwrote is parked, and the report says
# where.
parked=$(printf '%s' "$ctx" | sed -n 's/.*parked at \([^ )]*\).*/\1/p')
assert [ -s "$parked" ]
assert_contains "no human asked for" "$(cat "$parked")"
# One report, and the baseline moved on with it.
assert_eq "" "$(span_check sid-revert Bash command "echo x >> $DOC" "$SPAN_T")"

echo "== tripwire: an Edit says which file it wrote in its own payload"
AGENT_MD="$HOME/.claude/agents/codex-worker.md"
span_base sid-revert-edit >/dev/null
before=$(cat "$AGENT_MD")
printf 'a brief nobody approved\n' >> "$AGENT_MD"
ctx=$(span_check sid-revert-edit Edit file_path "$AGENT_MD" "$SPAN_T")
assert_contains "REVERTED" "$ctx"
assert_eq "$before" "$(cat "$AGENT_MD")"

echo "== tripwire: outside the span nothing is rolled back"
# Egor is here to arbiter, and the writer may be another chat sharing the checkout.
span_base sid-nospan >/dev/null
printf 'grown out of the span\n' >> "$DOC"
ctx=$(span_check sid-nospan Bash command "echo grown out of the span >> $DOC" "$NOSPAN_T")
assert_contains "CHANGED" "$ctx"
assert_contains "puts them back" "$ctx"
case "$ctx" in *REVERTED*) fail "the tripwire rolled back a change with Egor in the room" ;; esac
assert_contains "grown out of the span" "$(cat "$DOC")"
printf 'tier doc\n' > "$DOC"

echo "== tripwire: a call that only NAMES the file claims nothing"
# In a shared checkout the writer is as often another chat as this session, and a rollback decided
# on a guess eats that chat's live work.
span_base sid-foreign >/dev/null
printf 'grown by somebody else\n' >> "$DOC"
ctx=$(span_check sid-foreign Bash command "grep -c . $DOC" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "the tripwire rolled back a change it could not attribute" ;; esac
assert_contains "grown by somebody else" "$(cat "$DOC")"
printf 'tier doc\n' > "$DOC"

echo "== tripwire: a write verb aimed elsewhere is not this call's write"
# The bytes have to LAND in the file: `sed -n` reads it, and a redirect names the file it writes.
# Blaming either for growth another chat in the same checkout produced puts that chat's work back.
# An interpreter row is the parse reporting a name it found inside a payload it cannot read, so it
# is evidence of a mention and never of a write: reading a file must not roll back the growth
# another chat in the same checkout produced.
aimed_case=0
for read_cmd in "sed -n '1,5p' $DOC" "cat $DOC > $WORK/scratch/copy.md" \
                "python3 -c 'open(\"$DOC\").read()'" \
                "node -e 'fs.readFileSync(\"$DOC\")'"; do
  aimed_case=$((aimed_case + 1))
  span_base "sid-aimed-$aimed_case" >/dev/null
  printf 'grown by somebody else\n' >> "$DOC"
  ctx=$(span_check "sid-aimed-$aimed_case" Bash command "$read_cmd" "$SPAN_T")
  assert_contains "CHANGED" "$ctx"
  case "$ctx" in *REVERTED*) fail "a command that only read the file was blamed for its growth: $read_cmd" ;; esac
  assert_contains "grown by somebody else" "$(cat "$DOC")"
  printf 'tier doc\n' > "$DOC"
done

echo "== tripwire: an interpreter READING the every-session file is not a write to it"
span_base sid-read-always >/dev/null
printf 'a line no human asked for\n' >> "$CLAUDE_MD"
ctx=$(span_check sid-read-always Bash command "python3 -c 'open(\"$CLAUDE_MD\").read()'" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "a python read of the global file was blamed for its growth" ;; esac
assert_contains "no human asked for" "$(cat "$CLAUDE_MD")"
printf 'global rules\n' > "$CLAUDE_MD"

echo "== one parse: both doors read the same destinations off a command"
# Two parses of one line was the defect these hooks were built with: the gate located a
# destination strictly while the tripwire re-derived it from a looser expression of its own, so a
# `.bak` sibling of a guarded name was a write to one half and not to the other, and a `mv` whose
# segment ended in whitespace was attributed to nobody. Four shapes, asked of the ONE parse both
# doors now call.
mkdir -p "$WORK/stage"
share_call() { # snippet arg... → the shared module, sourced, answering
  bash -c '. "$1" || exit 1; shift; eval "$1"' _ "$ROOT/share/instruction-files.sh" "$@"
}
targets() { # command names-alternation → the destination names the parse finds
  share_call 'instruction_write_targets "$2" "$3" | cut -f4' "$1" "$2"
}
DOC_ERE=$(share_call 'instruction_ere_escape "$2"' "$DOC")
# A name a destination merely ENDS with is not that name.
assert_eq "" "$(targets "echo x > $DOC.bak" "$DOC_ERE")"
# Nor is it that name to the interpreter shapes: every branch closes the quote after the path, or
# a `.bak` sibling reads as the guarded file itself and the tripwire reverts a write it never made.
interp_writes() { # command → how many interpreter write constructs the shared shapes find
  share_call 'printf "%s" "$2" | grep -Eo "$(instruction_interp_write_re "$3")" | wc -l | tr -d " "' "$1" "$DOC_ERE"
}
for sibling in \
  "perl -e \"open(FH, '>', '$DOC.bak')\"" \
  "node -e \"fs.writeFileSync('$DOC.bak','x')\"" \
  "ruby -e \"File.write('$DOC.bak','x')\"" \
  "python3 -c \"import shutil; shutil.copy('/tmp/x','$DOC.bak')\"" \
  "python3 -c \"open('$DOC.bak','w')\""; do
  assert_eq 0 "$(interp_writes "$sibling")"
done
for real in \
  "perl -e \"open(FH, '>', '$DOC')\"" \
  "node -e \"fs.writeFileSync('$DOC','x')\"" \
  "ruby -e \"File.write('$DOC','x')\"" \
  "python3 -c \"import shutil; shutil.copy('/tmp/x','$DOC')\"" \
  "python3 -c \"open('$DOC','w')\""; do
  assert_eq 1 "$(interp_writes "$real")"
done
# The destination of a copy verb is its last operand, whatever stands after the command.
assert_eq "$DOC" "$(targets "mv $WORK/stage/tmp.md $DOC && true" "$DOC_ERE")"
# What a `<` names is what the command READS.
assert_eq "" "$(targets "cat < $DOC" "$DOC_ERE")"
# A copy into a DIRECTORY leaves its bytes in a file the operand never spells.
assert_eq "$DOC" "$(targets "cp $WORK/stage/review-tiers.md $HOME/.claude/docs" "$DOC_ERE")"
assert_contains "./review-tiers.md" \
  "$(targets 'cp /tmp/stage/review-tiers.md .' 'review-tiers\.md|\./review-tiers\.md')"
# A continuation is one command to the shell, and the tripwire hands over the RAW command: the
# join belongs to the parse, not to whichever caller remembers it.
assert_eq "$DOC" "$(targets "$(printf 'cp %s/stage/tmp.md \\\n%s\n' "$WORK" "$DOC")" "$DOC_ERE")"
# An in-place editor writes the file it is pointed at however the flag is spelled, GNU included.
assert_eq "$DOC" "$(targets "sed --in-place=.bak s/x/y/ $DOC" "$DOC_ERE")"
assert_eq "$DOC" "$(targets "gsed -i s/x/y/ $DOC" "$DOC_ERE")"
# `dd` names its destination in an operand of its own, and the by-name spelling the gate matches
# with is what makes the difference visible: emitted verbatim, `of=<path>` matches whole and the
# denial names a file that does not exist, while `if=` reports what dd READS as a write.
BY_NAME_ERE="([^[:space:];|&'\"]*/)?review-tiers\.md"
assert_eq "$DOC" "$(targets "dd if=$WORK/stage/tmp.md of=$DOC" "$BY_NAME_ERE")"
assert_eq "" "$(targets "dd if=$DOC of=$WORK/stage/tmp.md" "$BY_NAME_ERE")"
# `<<\EOF` quotes a heredoc the way `<<"EOF"` does: unrecognised, the body it holds is read as
# commands, and a rule it merely quotes reads as a write to the file the rule is about — a false
# denial at this door and, at the tripwire, a rollback of somebody else's growth.
assert_eq "" "$(targets "$(printf 'cat > %s/stage/scratch <<\\EOF\nsee > %s for the rule\nEOF\n' "$WORK" "$DOC")" "$DOC_ERE")"
assert_eq pass "$(in_span decision "$(printf 'cat > %s/stage/scratch <<\\EOF\nsee > %s for the rule\nEOF\n' "$WORK" "$DOC")")"
# Asked of the scan too, which is the pass that exists to take a body out: the raw fallback beside
# it can hide a body the scan kept, and then only one of the two doors reads that command right.
assert_eq 0 "$(share_call 'printf "%s" "$2" | instruction_shell_scan | grep -c review-tiers' \
  "$(printf 'cat > %s/stage/scratch <<\\EOF\nsee > %s for the rule\nEOF\n' "$WORK" "$DOC")")"
# `<<-` strips tabs and no spaces, so a space-indented word is not the terminator and the body
# after it is still the body.
assert_eq "" "$(targets "$(printf 'cat > %s/stage/scratch <<-EOF\n  EOF\nsee > %s for the rule\nEOF\n' "$WORK" "$DOC")" "$DOC_ERE")"

echo "== one parse: the tripwire attributes exactly what that parse finds"
parse_case=0
while IFS='|' read -r owns cmd; do
  [ -n "$cmd" ] || continue
  parse_case=$((parse_case + 1))
  printf 'tier doc\n' > "$DOC"
  printf 'staged\n' > "$WORK/stage/review-tiers.md"
  span_base "sid-parse-$parse_case" >/dev/null
  printf 'a line no human asked for\n' >> "$DOC"
  ctx=$(span_check "sid-parse-$parse_case" Bash command "$cmd" "$SPAN_T")
  if [ "$owns" = yes ]; then
    assert_contains "REVERTED" "$ctx"
    assert_eq "tier doc" "$(cat "$DOC")"
  else
    assert_contains "CHANGED" "$ctx"
    case "$ctx" in *REVERTED*) fail "a command that wrote elsewhere was blamed for the growth: $cmd" ;; esac
  fi
  # Neither shape is the gate's: a derived name and a read are not writes at all, and locating a
  # copy verb's destination in an argument list is the tripwire's job by design.
  assert_eq pass "$(decision "$cmd")"
done <<CASES
no|echo x > $DOC.bak
yes|mv $WORK/stage/tmp.md $DOC && true
no|cat < $DOC
yes|cp $WORK/stage/review-tiers.md home/.claude/docs
CASES
printf 'tier doc\n' > "$DOC"

echo "== tripwire: a write that SHRANK the file is what the span exists for"
span_base sid-shrink >/dev/null
printf 'tiny\n' > "$DOC"
ctx=$(span_check sid-shrink Bash command "printf tiny > $DOC" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "the tripwire put back a shrink the span exists to allow" ;; esac
assert_eq "tiny" "$(cat "$DOC")"
printf 'tier doc\n' > "$DOC"
# The shape the bug arrived in: an Edit that cut 129 bytes out of ~/.claude/commands/worker.md
# inside the span, rolled back by a hook that measured that a file had changed and not which way.
CMD_MD="$HOME/.claude/commands/worker.md"
printf '%129s\n' | tr ' ' x > "$CMD_MD"
span_base sid-shrink-edit >/dev/null
printf 'x\n' > "$CMD_MD"
ctx=$(span_check sid-shrink-edit Edit file_path "$CMD_MD" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "an in-span Edit that CUT bytes was put back" ;; esac
assert_eq "x" "$(cat "$CMD_MD")"
printf 'command doc\n' > "$CMD_MD"

echo "== tripwire: settings.json is watched and never reverted"
# No gate speaks for it, in the span or out of it.
span_base sid-set-span >/dev/null
printf '{"model":"opus","hooks":{"Stop":[],"PreToolUse":[]}}\n' > "$HOME/.claude/settings.json"
ctx=$(span_check sid-set-span Bash command "echo x > $HOME/.claude/settings.json" "$SPAN_T")
assert_contains "settings.json" "$ctx"
case "$ctx" in *REVERTED*) fail "the tripwire rolled back settings.json, which no gate speaks for" ;; esac

echo "== tripwire: growth through a path the gate cannot see is still put back"
# A heredoc fed to an interpreter, which is why the attribution reads the RAW command: the target
# is named inside the body the gate drops.
span_base sid-heredoc >/dev/null
printf 'a line through a heredoc\n' >> "$DOC"
ctx=$(span_check sid-heredoc Bash command "python3 - <<'EOF'
open('$DOC','a').write('a line through a heredoc')
EOF" "$SPAN_T")
assert_contains "REVERTED" "$ctx"
assert_eq "tier doc" "$(cat "$DOC")"

# A headless worker can start with a PATH that misses Homebrew, and stock /bin/bash is 3.2:
# there `local -A` is not an error but a silent downgrade to an indexed array, where every
# path key evaluates as arithmetic to index 0 and the comparison reads the wrong row.
echo "== both hooks run under stock /bin/bash 3.2"
b32() { jq -cn --arg s "$1" '{session_id:$s,hook_event_name:"PostToolUse"}' | /bin/bash "$WATCH" "$2"; }
b32 sid-32 baseline >/dev/null
assert_eq "" "$(b32 sid-32 check)"
printf 'moved under 3.2\n' > "$REAL_MD"
assert_contains "CHANGED" "$(b32 sid-32 check | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_eq "" "$(bash_payload 'git status --short' | /bin/bash "$WRITE_GATE")"
assert_contains 'permissionDecision":"deny' \
  "$(bash_payload "echo x > $CLAUDE_MD" | /bin/bash "$WRITE_GATE")"
assert_contains 'permissionDecision":"deny' \
  "$(jq -cn --arg p "$CLAUDE_MD" --arg n "$big" \
       '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
     | INSTRUCTION_BLOAT_GATE_STAMPS="$HOME/.cache/bloat-32" /bin/bash "$BLOAT")"

echo "OK ($asserts assertions)"
