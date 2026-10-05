#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/instruction_gate_harness.sh"

echo "== write gate: denies a shell write to a protected file"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','w').write('x')\"")"
assert_eq deny "$(decision "echo hi > $CLAUDE_MD")"
assert_eq deny "$(decision "echo hi >> $CLAUDE_MD")"
assert_eq deny "$(decision "printf x | tee $CLAUDE_MD")"
assert_eq deny "$(decision "printf x | tee -a $CLAUDE_MD")"

echo "== write gate: a copy verb landing whole bytes on a guarded file is denied"
assert_eq deny "$(decision "cp $WORK/unrelated.py $CLAUDE_MD")"
assert_eq deny "$(decision "mv $WORK/unrelated.py $CLAUDE_MD")"
assert_eq deny "$(decision "ln -sf $WORK/unrelated.py $CLAUDE_MD")"
assert_eq deny "$(decision "install -m 644 $WORK/unrelated.py $CLAUDE_MD")"
assert_eq deny "$(decision "rsync -a $WORK/unrelated.py $CLAUDE_MD")"
assert_eq deny "$(decision "patch $CLAUDE_MD $WORK/some.diff")"
assert_eq deny "$(decision "dd if=/dev/zero of=$CLAUDE_MD bs=1024 count=1")"
assert_eq pass "$(decision "cp $CLAUDE_MD $WORK/backup.md")"
assert_eq pass "$(decision "cp $WORK/unrelated.py $WORK/notes.txt")"

echo "== write gate: the in-place editors stay the tripwire's"
assert_eq pass "$(decision "sed -i '' 's/a/b/' $CLAUDE_MD")"
assert_eq pass "$(decision "rm $CLAUDE_MD")"
assert_eq pass "$(decision "truncate -s 0 $CLAUDE_MD")"
assert_eq pass "$(decision "perl -pi -e 's/a/b/' $CLAUDE_MD")"
assert_eq pass "$(decision "ed -s $CLAUDE_MD")"

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

echo "== write gate: an interpreter writing through a variable that holds a guarded name"
assert_eq deny "$(decision "python3 - <<'EOF'
p='$CLAUDE_MD'
open(p,'w').write('x')
EOF")"
assert_eq deny "$(decision "python3 -c \"from pathlib import Path; p=Path('$CLAUDE_MD'); p.write_text('x')\"")"
assert_eq deny "$(decision "python3 -c \"from pathlib import Path; p='$CLAUDE_MD'; Path(p).write_text('x')\"")"
assert_eq deny "$(decision "node -e \"const p='$CLAUDE_MD'; require('fs').writeFileSync(p, 'x')\"")"
assert_eq pass "$(decision "python3 -c \"p='$CLAUDE_MD'; print(open(p).read())\"")"
assert_eq pass "$(decision "python3 -c \"p='$CLAUDE_MD'; open(p,'r').read()\"")"
assert_eq pass "$(decision "python3 -c \"p='${CLAUDE_MD}.tmp'; open(p,'w').write('x')\"")"
assert_eq pass "$(decision "echo \"p='$CLAUDE_MD'; open(p,'w')\" > $WORK/notes.txt")"
assert_eq deny "$(decision "python3 -c \"p='$CLAUDE_MD'; open(file=p, mode='a').write('x')\"")"
assert_eq deny "$(decision "python3 -c \"p='$CLAUDE_MD'; open(p, encoding='utf-8', mode='a').write('x')\"")"
assert_eq deny "$(decision "perl -e \"my \$p='$CLAUDE_MD'; open(my \$f,'>>',\$p)\"")"
assert_eq deny "$(decision "ruby -e \"p='$CLAUDE_MD'; File.write(p,'x')\"")"
assert_eq pass "$(decision "CLAUDEB_WORKER=1 python3 -c \"names=['$CLAUDE_MD']; out='/tmp/s'; open(out,'w')\"")"
assert_eq pass "$(decision "grep x '$CLAUDE_MD'
python3 -c \"out='/tmp/s'; open(out,'w').write('x')\"")"
assert_eq pass "$(decision "python3 -c \"f='$CLAUDE_MD';print(open(f).read())\" && python3 -c \"f='/tmp/o.json';open(f,'w')\"")"
assert_eq 0 "$(CLAUDEB_WORKER=1 gate "python3 -c \"f='$CLAUDE_MD';print(open(f).read())\" && python3 -c \"f='/tmp/o.json';open(f,'w')\"" >/dev/null 2>&1; echo $?)"
assert_eq pass "$(decision "python3 -c \"f='$CLAUDE_MD'\" && python3 -c \"open(f,'w')\"")"
assert_eq pass "$(decision "python3 - <<'EOF'
path='$CLAUDE_MD'
print(open(path).read())
path='/tmp/o.json'
open(path,'w').write('x')
EOF")"
assert_eq deny "$(decision "python3 - <<'EOF'
path='/tmp/o.json'
path='$CLAUDE_MD'
open(path,'w').write('x')
path='/tmp/o.json'
EOF")"
assert_eq deny "$(decision "python3 -c \"f='/tmp/o.json';open(f,'w')\" && python3 -c \"f='$CLAUDE_MD';open(f,'a')\"")"

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
assert_eq deny "$(decision "git -C $REPO checkout -- global/CLAUDE.md")"
assert_eq deny "$(decision "git -C $REPO checkout -- $REAL_MD")"
assert_eq deny "$(decision "git -C $REPO restore global/CLAUDE.md")"
assert_eq pass "$(decision "git -C $REPO checkout -- src/app.py")"
assert_eq pass "$(decision "git -C $REPO checkout main")"
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

echo "== write gate: a retry stamp no denial of this session minted is refused and recorded"
# The name is learnt from a denial in a scratch cache, so the planted directory is exactly the one
# a real denial of that session would have made.
learn_stamp() { # command [session]
  local scratch="$WORK/learn-$RANDOM$RANDOM"
  GATE_SID=${2:-session-one} INSTRUCTION_WRITE_GATE_STAMPS="$scratch/stamps" \
    INSTRUCTION_WATCH_STATE="$scratch/state" GATE_TRANSCRIPT="$scratch/transcript.jsonl" \
    decision "$1" >/dev/null
  ls "$scratch/stamps"
}
JW="$INSTRUCTION_WATCH_STATE/events.jsonl"
forged_count() { cat "$JW" 2>/dev/null | grep -c '"kind":"stamp-forged"' || true; }
cmd3="echo forged > $CLAUDE_MD"
h3=$(learn_stamp "$cmd3")
mkdir -p "$INSTRUCTION_WRITE_GATE_STAMPS/$h3"
age_stamps
append_write_user
n0=$(forged_count)
out=$(gate "$cmd3" 2>&1; echo "rc=$?")
assert_contains "rc=2" "$out"
assert_contains "retry stamp" "$out"
assert_eq $((n0 + 1)) "$(forged_count)"
assert_eq session-one "$(grep '"kind":"stamp-forged"' "$JW" | tail -1 | jq -r .sid)"
assert_eq "$CLAUDE_MD" "$(grep '"kind":"stamp-forged"' "$JW" | tail -1 | jq -r '.files[0]')"
assert [ ! -d "$INSTRUCTION_WRITE_GATE_STAMPS/$h3" ]
assert_eq deny "$(decision "$cmd3")"
age_stamps
append_write_user
assert_eq pass "$(decision "$cmd3")"
cmd4="echo borrowed > $CLAUDE_MD"
assert_eq deny "$(decision "$cmd4")"
h4a=$(learn_stamp "$cmd4")
h4b=$(learn_stamp "$cmd4" session-two)
mkdir -p "$INSTRUCTION_WRITE_GATE_STAMPS/$h4b"
cp "$INSTRUCTION_WATCH_STATE/denied/$h4a" "$INSTRUCTION_WATCH_STATE/denied/$h4b"
age_stamps
append_write_user
out=$(GATE_SID=session-two gate "$cmd4" 2>&1; echo "rc=$?")
assert_contains "rc=2" "$out"
assert_eq session-two "$(grep '"kind":"stamp-forged"' "$JW" | tail -1 | jq -r .sid)"

# The record and the stamp are both computable from the session, the path and the command; the
# denial the harness wrote into this session's transcript is not.
cmd5="echo recorded > $CLAUDE_MD"
h5=$(learn_stamp "$cmd5")
mkdir -p "$INSTRUCTION_WRITE_GATE_STAMPS/$h5" "$INSTRUCTION_WATCH_STATE/denied"
printf 'session-one %s\n' "$(date +%s)" > "$INSTRUCTION_WATCH_STATE/denied/$h5"
age_stamps
append_write_user
n0=$(forged_count)
out=$(gate "$cmd5" 2>&1; echo "rc=$?")
assert_contains "rc=2" "$out"
assert_eq $((n0 + 1)) "$(forged_count)"
assert [ ! -d "$INSTRUCTION_WRITE_GATE_STAMPS/$h5" ]
# The tag echoed by a command of the model's own, even spelled as the harness spells a denial,
# starts with the command's exit line and witnesses nothing.
cmd6="echo echoed > $CLAUDE_MD"
h6=$(learn_stamp "$cmd6")
mkdir -p "$INSTRUCTION_WRITE_GATE_STAMPS/$h6"
printf 'session-one %s\n' "$(date +%s)" > "$INSTRUCTION_WATCH_STATE/denied/$h6"
jq -cn --arg r "Exit code 1
PreToolUse:Bash hook error: Instruction gate: (denial $h6)" \
  '{type:"user",message:{role:"user",content:[{type:"tool_result",is_error:true,content:$r}]}}' \
  >> "$WRITE_TRANSCRIPT"
age_stamps
append_write_user
out=$(gate "$cmd6" 2>&1; echo "rc=$?")
assert_contains "rc=2" "$out"
assert [ ! -d "$INSTRUCTION_WRITE_GATE_STAMPS/$h6" ]

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

echo "OK ($asserts assertions)"
