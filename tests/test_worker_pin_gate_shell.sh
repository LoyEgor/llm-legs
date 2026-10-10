#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/worker-pin-gate.sh, the shell door: which commands write ~/.claude/worker-model — redirects, copies,
# heredocs — and which only read it or carry its name as text.
. "$(dirname "$0")/worker_pin_gate_harness.sh" || exit 1

# --- The shell door: a redirect is a write, and `cat` is not ------------------------------------
for writing in \
  "printf 'codex_profile=x\\n' >> ~/.claude/worker-model" \
  "printf 'codex_profile=x\\n' > $HOME/.claude/worker-model" \
  "sed -i '' 's/^codex_profile=.*/codex_profile=x/' ~/.claude/worker-model" \
  "tee ~/.claude/worker-model <<<'codex_profile=x'" \
  "cp /tmp/model ~/.claude/worker-model" \
  "rm ~/.claude/worker-model" \
  "chmod 000 ~/.claude/worker-model" \
  "model=\$HOME/.claude/worker-model; printf 'codex_profile=x\\n' > \"\$model\"" \
  "f=~/.claude/worker-model
printf 'codex_profile=x\\n' >>\"\$f\""
do
  assert written "$writing"
done
for reading in \
  'cat ~/.claude/worker-model' \
  'grep profile ~/.claude/worker-model' \
  'grep profile ~/.claude/worker-model </dev/null' \
  'diff ~/.claude/worker-model <(cat /tmp/model)' \
  'cat ~/.claude/worker-model 2>&1 | head -3' \
  'bash tests/test_worker_pick.sh share/worker-model.sh' \
  'grep -n pin share/worker-model.sh > /tmp/out' \
  'worker-pick' \
  'echo worker-model'
do
  assert not_written "$reading"
done
# A read whose OUTPUT is redirected writes the file it names, and that file is not the pin: the door
# takes a destination off the shared parse now (`instruction_write_targets`) instead of reading any
# `>` in a command that names the pin as a write to it.
assert not_written 'cat ~/.claude/worker-model > /tmp/out.txt'
assert not_written 'cat ~/.claude/worker-model | tee /tmp/copy.txt'

# A read chained to a write of something ELSE is still a read: the pre-delegation chain sits in one
# Bash beside worktree setup, temp cleanup and test runs, and a write verb anywhere in the command
# denied the whole thing (live 2026-09-02). The write has to share the simple command with the name.
for read_beside_write in \
  'cat ~/.claude/worker-model; rm -rf "$W"' \
  'grep -E "^worker=" ~/.claude/worker-model; git worktree add "$W" main >/dev/null 2>&1; cp a b' \
  'cat ~/.claude/worker-model 2>/dev/null | head -3 && sed -i "" "s/x/y/" other.txt' \
  'python3 fix.py && grep profile ~/.claude/worker-model' \
  'mv a b
cat ~/.claude/worker-model'
do
  assert not_written "$read_beside_write"
done
# …and the split never lets a write reach the pin through a name that travelled out of its segment:
# a variable, a substitution, a loop — or a write standing in the file's own segment.
for still_written in \
  'echo x; printf "codex_profile=x\n" > ~/.claude/worker-model' \
  'cat ~/.claude/worker-model | tee ~/.claude/worker-model' \
  'p="$(readlink -f ~/.claude/worker-model)"; printf "codex_profile=x\n" > "$p"' \
  'for f in ~/.claude/worker-model; do printf "codex_profile=x\n" > "$f"; done' \
  'cp /tmp/x $(dirname ~/.claude/worker-model)/worker-model'
do
  assert written "$still_written"
done

# A copy is judged by its DESTINATION, and the pin standing in a SOURCE is a read: the shared parse
# also emits the name a copy INTO a directory would land in, and that guess read a backup of the pin
# as a write over it — including a `cp` of some other `worker-model` between two scratch paths.
mkdir -p "$WORK/backupdir"
for copy_out in \
  "cp $PIN_FILE $WORK/backup" \
  "cp $PIN_FILE $WORK/backupdir/" \
  "cp $PIN_FILE $WORK/backupdir" \
  'cp ~/.claude/worker-model "$BACKUP"' \
  "cp $WORK/worker-model $WORK/other" \
  'cp /tmp/model ~/.claude/'
do
  assert not_written "$copy_out"
done
# …and a destination that IS the pin is denied however it is spelled: the file itself, a directory
# taking the source's own name, or a spelling this door cannot resolve. A `mv` needs no destination
# of ours at all — the pin it takes away is a pin removed.
for copy_in in \
  "cp $WORK/model ~/.claude/worker-model" \
  "cp $WORK/worker-model $HOME/.claude/" \
  'cp /tmp/model "$HOME/.claude/worker-model"' \
  'install -m 644 /tmp/x ~/.claude/worker-model' \
  'ln -sf /tmp/x ~/.claude/worker-model' \
  'mv ~/.claude/worker-model /tmp/aside' \
  'cp /tmp/m ~/.claude/worker-model >/dev/null' \
  'cp /tmp/m ~/.claude/worker-model 2>&1' \
  'cp /tmp/m ~/.claude/worker-model > /tmp/log' \
  'cp /tmp/m ~/.claude/worker-model -f' \
  'mv /tmp/m ~/.claude/worker-model --force' \
  'install /tmp/m ~/.claude/worker-model -m 600' \
  'cp -t ~/.claude/worker-model /tmp/m' \
  'cp --target-directory=~/.claude/worker-model /tmp/m' \
  'rsync ~/bak/worker-model ~/.claude/worker-model' \
  'rsync -a ~/bak/worker-model ~/.claude/' \
  'git checkout -- ~/.claude/worker-model' \
  'git -C ~/.claude restore worker-model' \
  'cd ~/.claude && cp worker-model.bak worker-model' \
  '(cd ~/.claude && mv tmp worker-model)' \
  'cd ~/.claude; cp ~/bak/worker-model .' \
  'cd ~/.claude && mv worker-model /tmp/wm.bak' \
  'mv "$HOME/.claude/worker-model" /tmp/wm.bak' \
  'mv "${HOME}/.claude/worker-model" /tmp/wm.bak' \
  'mv ~/.claude/worker-model "$TMPDIR/wm.bak"' \
  'cp ~/bak/worker-model "$HOME/.claude/"'
do
  assert written "$copy_in"
done
for copy_out in \
  'rsync ~/.claude/worker-model /tmp/backup' \
  'cp "$HOME/.claude/worker-model" "$TMPDIR/"' \
  'cd /tmp && cat ~/.claude/worker-model > x.txt'
do
  assert not_written "$copy_out"
done
# Trailing options/redirections are not the destination; a copy whose last *operand* is elsewhere
# still is not a pin write, even with the same tails that hid a pin dest above.
for copy_out_tail in \
  'cp /tmp/m /tmp/elsewhere >/dev/null' \
  'cp /tmp/m /tmp/elsewhere -f' \
  'cp -t /tmp/elsewhere /tmp/m'
do
  assert not_written "$copy_out_tail"
done

# A BRIEF is data. Written into a scratch file, it names the pin, quotes `*_profile=`, spells a
# write verb in prose and carries Egor's rules in Russian with apostrophes and «» — and a door that
# read a heredoc body as syntax refused all of it as a pin move (live 2026-09-02/03).
for brief in \
  'cat > /tmp/brief <<EOF
ACCOUNT: alpha
read ~/.claude/worker-model before delegating
EOF' \
  'cat > /tmp/brief <<EOF
cp of the pin in ~/.claude/worker-model is out of scope
EOF' \
  'cat > /tmp/brief <<EOF
never sed -i the ~/.claude/worker-model file
EOF' \
  "cat > /tmp/brief <<EOF
Egor's rule for worker-model: the *_profile= lines stay
EOF" \
  'cat > /tmp/brief <<EOF
проверь ~/.claude/worker-model и не трогай «пин»
EOF' \
  'cat >> /tmp/notes.md <<EOF
worker-model holds the *_profile= lines
EOF'
do
  assert not_written "$brief"
done
# …and a heredoc pointed AT the file is the write it looks like.
assert written 'cat > ~/.claude/worker-model <<EOF
worker=auto
claudeb_profile=beta
EOF'
assert written "tee ~/.claude/worker-model <<EOF
claudeb_profile=beta
EOF"


printf 'PASS: %s asserts; a shell write reaching ~/.claude/worker-model is read as one however it is spelled, copied or heredoc-fed, and a read, a copy out or a brief naming it is not\n' "$asserts"
