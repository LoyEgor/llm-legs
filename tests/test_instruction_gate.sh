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

HOME="$WORK/home"
TMPDIR="$WORK/tmp"
export HOME TMPDIR
# The alert is Egor's screen: never let a test reach the real Hammerspoon.
INSTRUCTION_WATCH_ALERT="$WORK/alert-stub"
INSTRUCTION_WATCH_STATE="$HOME/.cache/watch"
INSTRUCTION_WATCH_LOG="$HOME/.claude/instruction-changes.log"
INSTRUCTION_WRITE_GATE_STAMPS="$HOME/.cache/write-gate"
export INSTRUCTION_WATCH_ALERT INSTRUCTION_WATCH_STATE INSTRUCTION_WATCH_LOG \
       INSTRUCTION_WRITE_GATE_STAMPS
mkdir -p "$HOME/.claude/docs" "$HOME/.claude/agents" "$HOME/.claude/skills/demo" "$TMPDIR"

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
printf 'ordinary code\n' > "$WORK/unrelated.py"

CLAUDE_MD="$HOME/.claude/CLAUDE.md"
REAL_MD="$REPO/global/CLAUDE.md"

bash_payload() {
  jq -cn --arg c "$1" --arg s "${GATE_SID:-session-one}" --arg d "${GATE_CWD:-}" \
    '{tool_name:"Bash",session_id:$s,cwd:$d,tool_input:{command:$c}}'
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
assert_eq deny "$(decision "echo x > $HOME/.claude/settings.json")"
assert_eq deny "$(decision "echo x > $HOME/.claude/docs/review-tiers.md")"
assert_eq deny "$(decision "echo x > $HOME/.claude/agents/codex-worker.md")"
assert_eq deny "$(decision "echo x > $HOME/.claude/skills/demo/SKILL.md")"

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
assert_contains "~15682 full-read" "$(price a "$CLAUDE_MD")"
assert_contains "~15682 full-read" "$(price b "$REAL_MD")"
assert_contains "~2500 full-read" "$(price c "$HOME/.claude/agents/codex-worker.md")"
assert_contains "~160 full-read" "$(price d "$HOME/.claude/docs/review-tiers.md")"
assert_contains "~90 full-read" "$(price e "$HOME/.claude/skills/demo/SKILL.md")"
assert_contains "~3131 full-read" "$(price f "$WORK/proj/CLAUDE.md")"

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
assert_eq deny "$(GATE_CWD="$HOME/.claude" decision 'echo x > settings.json')"

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
assert_contains "15682" "$msg"
assert_contains "tokens/month" "$msg"

echo "== bloat gate: every name the global file answers to is the global file"
# Each profile directory carries its own symlink to it, and those spellings were being priced
# as a project file at a fifth of the real cost.
mkdir -p "$HOME/.claude-profiles/com"
ln -sf "$CLAUDE_MD" "$HOME/.claude-profiles/com/CLAUDE.md"
msg=$(bloat "$HOME/.claude-profiles/com/CLAUDE.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "15682" "$msg"
msg=$(bloat "$REAL_MD" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "15682" "$msg"

echo "== bloat gate: a project file rides in one project's sessions, not in all of them"
# The global rate quoted for a project CLAUDE.md or memory index overstated it by five times.
msg=$(bloat "$REPO/CLAUDE.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "3131" "$msg"
msg=$(bloat "$WORK/memory/MEMORY.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "3131" "$msg"

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
watch baseline sid-wide >/dev/null
assert_eq "" "$(watch check sid-wide)"
printf 'topic rules changed\n' > "$HOME/.claude/instructions/topic.md"
printf 'local rules changed\n' > "$HOME/.claude/CLAUDE.local.md"
printf 'buried deeper\n' > "$REPO/global/docs/deep/deeper/note.md"
out=$(watch check sid-wide | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "topic.md" "$out"
assert_contains "CLAUDE.local.md" "$out"
assert_contains "note.md" "$out"

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
