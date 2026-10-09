#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/worker-pin-gate.sh: what ~/.claude/worker-model may hold — no model, effort or light row the
# table does not list, written by Edit/Write or by a shell write alike — and the chat pins written
# only through `chat-pin`. A pin move itself passes, here and through worker_model_pin_account.
# No network, no daemon; every pin file is a fixture.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/share/test-scope.sh"
PROJECTS=$(git_projects "$ROOT")
GATE="$ROOT/bin/worker-pin-gate.sh"
WORK="$(mktemp -d)"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
trap 'rm -rf "$WORK"' EXIT
export CLAUDEB_DIR="$WORK/store"
unset WORKER_STATS_DIR

# The sandbox HOME comes FIRST, before a single assertion: both doors resolve the pin under $HOME
# and read the pin lines standing in it, so anything asserted against the real $HOME is a test whose
# outcome is Egor's live worker-model — passing here, flaking on a clean machine.
export HOME="$WORK/home"
mkdir -p "$HOME/.claude"
printf 'worker=auto\nclaudeb_model=opus\n' >"$HOME/.claude/worker-model"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }
contains() { grep -Fq -- "$2" <<<"$1"; }
lacks() { ! grep -Fq -- "$2" <<<"$1"; }
denied() { contains "$1" '"permissionDecision":"deny"'; }
allowed() { lacks "$1" '"permissionDecision"'; }

write_event() {
  jq -cn --arg p "$1" --arg c "${2-claudeb_profile=beta}" \
    '{hook_event_name: "PreToolUse", session_id: "s", tool_name: "Write",
      tool_input: {file_path: $p, content: $c}}' \
    | "$GATE" write
}

edit_event() {
  jq -cn --arg p "$1" --arg o "$2" --arg n "$3" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit",
      tool_input: {file_path: $p, old_string: $o, new_string: $n}}' \
    | "$GATE" write
}

read_event() {
  jq -cn --arg p "$1" \
    '{hook_event_name: "PreToolUse", tool_name: "Read", tool_input: {file_path: $p}}' \
    | "$GATE" write
}

bash_event() {
  jq -cn --arg c "$1" \
    '{hook_event_name: "PreToolUse", session_id: "s", tool_name: "Bash", tool_input: {command: $c}}' |
    "$GATE" bash
}

PIN_FILE="$HOME/.claude/worker-model"

literal_failures=0
literal_case() {
  local name=$1 expected=$2 command=$3
  asserts=$((asserts + 1))
  if ! "$expected" "$(bash_event "$command")"; then
    printf 'FAIL: literal %s (%s)\n' "$name" "$expected" >&2
    literal_failures=$((literal_failures + 1))
  fi
}
for literal_path in '~/.claude/worker-model' '$HOME/.claude/worker-model' "$PIN_FILE"; do
  literal_case "inplace-$literal_path" allowed "sed -i '' 's/^worker=.*/worker=codex/' $literal_path"
  literal_case "temporary-$literal_path" allowed "config_2=$literal_path; sed 's/^grok_effort=.*/grok_effort=high/' \"\$config_2\" > \"\$config_2.tmp.\$\$\" && mv -f \"\$config_2.tmp.\$\$\" \"\$config_2\""
done
literal_safe="sed -i '' 's/^worker=.*/worker=codex/' $PIN_FILE"
literal_case append allowed "f=$PIN_FILE; sed 's/^worker=.*/worker=codex/' \"\$f\" >>\"\$f.tmp.\$\$\" && mv -f \"\$f.tmp.\$\$\" \"\$f\""
literal_case suppress allowed "sed -i '' -n 's/^worker=.*/worker=codex/p' $PIN_FILE"
literal_case statement allowed "$literal_safe; echo done"
literal_case attached allowed "sed -i '' -f/tmp/script 's/^worker=.*/worker=codex/' $PIN_FILE"
literal_case suffix allowed "f=/tmp/worker-model; sed 's/^worker=.*/worker=codex/' \"\$f\" > \"\$f.tmp.\$\$\" && mv -f \"\$f.tmp.\$\$\" $PIN_FILE"
literal_case expression allowed "sed -i '' -e 's/^worker=.*/worker=codex/' $PIN_FILE"
literal_case second-expression allowed "sed -i '' -e's/^worker=.*/worker=codex/' -e'd' $PIN_FILE"
literal_case profile allowed "sed -i '' 's/^codex_profile=.*/codex_profile=alt/' $PIN_FILE"
literal_case model denied "sed -i '' 's/^codex_model=.*/codex_model=gpt-5.6-terra/' $PIN_FILE"
[ "$literal_failures" -eq 0 ] || exit 1

# --- The file itself, however it is spelled: an unlisted model is denied there and nowhere else ---
for spelling in "$PIN_FILE" "$HOME/.claude//worker-model" "$HOME/.claude/../.claude/worker-model" '~/.claude/worker-model'; do
  assert denied "$(write_event "$spelling" 'codex_model=gpt-5.6-terra')"
done
for other in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" "$WORK/worker-model" \
             "$HOME/.claude/worker-model.bak"; do
  assert allowed "$(write_event "$other" 'codex_model=gpt-5.6-terra')"
done

# --- A pin move passes, word or none --------------------------------------------------------------
assert allowed "$(write_event "$PIN_FILE" "$(printf 'worker=codex\ncodex_profile=someone\n')")"
assert allowed "$(edit_event "$PIN_FILE" 'worker=auto' 'worker=auto\ncodex_profile=x')"
assert allowed "$(edit_event "$PIN_FILE" 'codex_profile=main' '')"
assert allowed "$(bash_event "printf 'codex_profile=x\\n' > ~/.claude/worker-model")"

# Reading is never gated, whatever matcher the hook is registered under. A tool the gate does not
# understand falls through rather than being denied on a text match: this door judges the two tools
# it is registered for, and guesses at nothing else.
assert allowed "$(read_event "$PIN_FILE")"
assert allowed "$(jq -cn --arg p "$PIN_FILE" \
  '{hook_event_name: "PreToolUse", tool_name: "MultiEdit",
    tool_input: {file_path: $p, old_string: "codex_profile=main", new_string: "codex_profile=x"}}' \
  | "$GATE" write)"

# --- The shell door: a redirect is a write, and `cat` is not ------------------------------------
# The model check reads a shell write too, and only a write: each case carries an unlisted model on
# a comment line of its own, so a write the door sees is denied and a read passes.
written() { denied "$(bash_event "$1"$'\n''# codex_model=gpt-5.6-terra')"; }
not_written() { allowed "$(bash_event "$1"$'\n''# codex_model=gpt-5.6-terra')"; }
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

# The pre-delegation read sits in one Bash beside whatever else the turn needs, and a loop or a
# one-liner in that command is not a hand on the pin: the write has to reach the pin's own name,
# not merely stand somewhere in a command that mentions it (live 2026-09-03).
for beside in \
  'cat ~/.claude/worker-model >/dev/null; worker-pick | head -1' \
  'cat ~/.claude/worker-model >/dev/null; worker-pick | head -1; for f in a b; do echo x > /tmp/$f; done' \
  'for r in one two; do git -C /tmp/$r status --short > /tmp/$r.txt; done; cat ~/.claude/worker-model' \
  'cat ~/.claude/worker-model >/dev/null; python3 -c "print(1)"; worker-pick' \
  'cat ~/.claude/worker-model; python3 -c "open(\"/tmp/o\",\"w\").write(\"x\")"'
do
  assert not_written "$beside"
done
# A runtime that opens the PIN is still a pin move, however the payload is quoted.
assert written 'python3 -c "open(\"$HOME/.claude/worker-model\",\"w\").write(\"codex_profile=x\")"'
# A runtime editing ANOTHER file whose text quotes the pin path writes that file, not the pin
# (23 of 23 sampled denials, 2026-09): its write sites are judged by their targets.
for source_edit in \
  $'python3 - <<\'EOF\'\np=\'/tmp/other.sh\'; s=open(p).read()\ns=s.replace(\'cat "$HOME/.claude/worker-model"\',\'cat "$HOME/.claude/worker-model" 2>/dev/null\')\nopen(p,\'w\').write(s)\nEOF' \
  $'python3 - <<\'EOF\'\nfrom pathlib import Path\np=Path(\'share/worker-model.sh\')\ns=p.read_text().replace(\'~/.claude/worker-model\', \'$PIN\')\np.write_text(s)\nEOF' \
  $'python3 - <<\'EOF\'\nprint(open(\'/Users/x/.claude/worker-model\').read())\nEOF' \
  $'python3 -c \'import subprocess; print(subprocess.check_output(["cat", "/Users/x/.claude/worker-model"]).decode())\'' \
  $'python3 -c \'import os; os.system("grep claudeb_profile ~/.claude/worker-model")\''
do
  assert not_written "$source_edit"
done
for runtime_pin in \
  $'python3 - <<\'EOF\'\nfrom pathlib import Path\nPath.home().joinpath(".claude/worker-model").write_text("claudeb_profile=x\\n")\nEOF' \
  $'python3 - <<\'EOF\'\nimport os\npin = os.path.expanduser("~/.claude/worker-model")\ntmp = pin + ".tmp"\nwith open(tmp, "w") as f:\n    f.write("claudeb_profile=b\\n")\nos.replace(tmp, pin)\nEOF' \
  $'python3 - <<\'EOF\'\nimport os\npin = os.path.expanduser("~/.claude/worker-model")\nwith open(pin, mode="a") as f:\n    f.write("claudeb_profile=b\\n")\nEOF' \
  $'python3 - <<\'EOF\'\nimport shutil, os\nshutil.copy(\'/tmp/x\', os.path.expanduser(\'~/.claude/worker-model\'))\nEOF' \
  $'python3 -c "import os;p=os.path.expanduser(\'~/.claude/worker-model\');open(p,\'w\').write(\'claudeb_profile=x\')"' \
  $'node -e "require(\'fs\').writeFileSync(process.env.HOME+\'/.claude/worker-model\', \'claudeb_profile=x\')"' \
  $'perl -e \'open(my $fh, ">", "$ENV{HOME}/.claude/worker-model"); print $fh "x"\'' \
  $'p=~/.claude/worker-model python3 - <<\'EOF\'\nimport os\nopen(os.environ["p"],"w").write("x")\nEOF' \
  $'python3 - <<\'EOF\'\nx=1\nEOF\necho claudeb_profile=b > ~/.claude/worker-model' \
  $'python3 - <<\'EOF\'\nimport fileinput, os\nfor line in fileinput.input(os.path.expanduser("~/.claude/worker-model"), inplace=True):\n    print(line.replace("a", "b"), end="")\nEOF' \
  $'python3 - <<\'EOF\'\nimport os\nfd = os.open(os.path.expanduser("~/.claude/worker-model"), os.O_WRONLY | os.O_APPEND)\nos.write(fd, b"x")\nEOF' \
  $'python3 -c \'import subprocess; subprocess.run(["sed", "-i", "", "s/a/b/", "/Users/x/.claude/worker-model"])\'' \
  $'python3 -c \'import os; os.system("echo x > ~/.claude/worker-model")\'' \
  $'python3 - <<\'EOF\'\nfrom pathlib import Path\np = Path("~/.claude/worker-model").expanduser()\np.replace("/tmp/gone")\nEOF' \
  $'python3 - <<\'EOF\'\nimport os\nfrom pathlib import Path\nPath(os.path.expanduser("~/.claude/worker-model")).rename("/tmp/x")\nEOF' \
  $'perl -e \'my $p = "$ENV{HOME}/.claude/worker-model"; open my $fh, ">", $p or die; print $fh "x"\'' \
  $'python3 - <<\'EOF\'\nimport shutil, os\nPIN = os.path.expanduser("~/.claude/worker-model")\nshutil.copy(\n    "/tmp/src",\n    PIN)\nEOF' \
  $'node -e "const fs=require(\'fs\'); fs.createWriteStream(process.env.HOME+\'/.claude/worker-model\').write(\'x\')"' \
  $'node -e "const fs=require(\'fs\'); fs.writeSync(fs.openSync(process.env.HOME+\'/.claude/worker-model\', \'w\'), \'x\')"' \
  $'python3 - <<\'EOF\'\nimport os\nfrom shutil import copy\ncopy("/tmp/x", os.path.expanduser("~/.claude/worker-model"))\nEOF' \
  $'python3 - <<\'EOF\'\nimport os\nfrom os import replace\npin = os.path.expanduser("~/.claude/worker-model")\nreplace("/tmp/t", pin)\nEOF' \
  $'node -e "const {renameSync}=require(\'fs\'); renameSync(\'/tmp/t\', process.env.HOME+\'/.claude/worker-model\')"' \
  $'python3 - <<\'EOF\'\nimport os\nfrom shutil import move as mv\nmv("/tmp/x", os.path.expanduser("~/.claude/worker-model"))\nEOF' \
  $'perl -e \'use File::Copy; move("/tmp/x", "$ENV{HOME}/.claude/worker-model")\'' \
  $'node --input-type=module -e "import {writeFileSync as w} from \'fs\'; w(process.env.HOME+\'/.claude/worker-model\', \'x\')"' \
  $'python3 - <<\'EOF\'\nfrom pathlib import Path\npin = Path("~/.claude/worker-model").expanduser()\nprint(pin.stat().st_mtime, pin.replace("/tmp/gone"))\nEOF'
do
  assert written "$runtime_pin"
done
# Only the pin's own name is bound, only the pin's own receiver renames it, and only a real writer writes.
for runtime_other in \
  $'python3 - <<\'EOF\'\nfrom pathlib import Path\ncfg = {\n    "pin": "~/.claude/worker-model",\n    "out": "/tmp/report.txt",\n}\nPath(cfg["out"]).write_text("x")\nEOF' \
  $'python3 - <<\'EOF\'\nfrom datetime import datetime\nfrom pathlib import Path\npin = Path("~/.claude/worker-model").expanduser()\nprint(pin.stat().st_mtime, datetime.now().replace(microsecond=0))\nEOF' \
  $'python3 - <<\'EOF\'\nimport os\ndef move(a, b):\n    print(a, "->", b)\npin = os.path.expanduser("~/.claude/worker-model")\nmove("/tmp/a", pin)\nEOF' \
  'cp ~/.claude/worker-model /tmp/wm.bak' \
  $'cat <<EOF > /tmp/notes.md\nrm ~/.claude/worker-model resets the pin\nEOF'
do
  assert not_written "$runtime_other"
done
# A copy FROM the pin reads it: only a copy's destination is a write target.
for runtime_read in \
  $'python3 - <<\'EOF\'\nimport shutil, os\nshutil.copy(os.path.expanduser("~/.claude/worker-model"), "/tmp/wm.bak")\nEOF' \
  $'python3 - <<\'EOF\'\nimport os\nfrom shutil import copy\ncopy(os.path.expanduser("~/.claude/worker-model"), "/tmp/wm.bak")\nEOF' \
  $'node -e "console.log(require(\'fs\').readFileSync(process.env.HOME+\'/.claude/worker-model\', \'utf8\'))"'
do
  assert not_written "$runtime_read"
done
# Live 2026-10-01: a python heredoc rewriting a test whose new text writes a temp-HOME pin fixture,
# then running that test.
fixture_edit=$(cat <<'CMD'
python3 - <<'PY'
p = "tests/test_gemini_music.sh"
s = open(p).read()
s = s.replace('''assert m.rotation() == ["beta", "alpha"], m.rotation()
EOF''', '''(Path(os.environ["HOME"]) / ".claude").mkdir()
(Path(os.environ["HOME"]) / ".claude" / "worker-model").write_text("gemini_profile=beta\\n")
assert m.rotation() == ["beta", "alpha"], m.rotation()
EOF''')
open(p, "w").write(s)
PY
bash tests/test_gemini_music.sh 2>&1 | tail -5
CMD
)
assert not_written "$fixture_edit"
for content_then_move in \
  "$fixture_edit; echo claudeb_profile=b > ~/.claude/worker-model" \
  "$fixture_edit; printf codex_profile=x | tee \$HOME/.claude/worker-model" \
  "$fixture_edit; sed -i '' 's/^gemini_profile=.*/gemini_profile=b/' ~/.claude/worker-model" \
  "$fixture_edit; cp /tmp/x ~/.claude/worker-model" \
  "$fixture_edit; mv /tmp/x \"\$HOME/.claude/worker-model\"" \
  "$fixture_edit; f=~/.claude/worker-model; printf x > \"\$f\"" \
  "$fixture_edit; perl -e 'open my \$f, \">\", \"\$ENV{HOME}/.claude/worker-model\"; print \$f \"x\"'" \
  $'python3 - <<\'PY\'\nimport os\ns = \'\'\'\ngemini_profile=beta\n\'\'\'\nopen(os.path.expanduser("~/.claude/worker-model"), "w").write(s)\nPY\nbash tests/t.sh' \
  $'python3 - <<\'PY\'\nexec(\'\'\'\nimport os\nopen(os.path.expanduser("~/.claude/worker-model"), "w").write("x")\n\'\'\')\nPY' \
  $'python3 - <<\'PY\'\nimport subprocess\nsubprocess.run(["sh", "-c", """\necho x > ~/.claude/worker-model\n"""])\nPY' \
  $'bash -s <<\'EOF\'\necho x > ~/.claude/worker-model\nEOF' \
  $'bash tests/t.sh <<\'EOF\'\necho x > ~/.claude/worker-model\nEOF' \
  $'cat > /tmp/fix.sh <<\'EOF\'\necho x > ~/.claude/worker-model\nEOF\nbash /tmp/fix.sh 2>&1 | tail -5' \
  $'printf \'rm ~/.claude/worker-model\\n\' | tee fix.sh >/dev/null && sh -x ./fix.sh' \
  $'python3 - <<\'PY\'\nimport os\ns = open("x.py").read().replace(\'"""\', "\'\'\'")\nopen(os.path.expanduser("~/.claude/worker-model"), "w").write("x")\nPY' \
  $'python3 - <<\'PY\'\nimport os\nos.spawnlp(os.P_WAIT, "sh", "sh", "-c", """\necho x > ~/.claude/worker-model\n""")\nPY'
do
  assert written "$content_then_move"
done

# Quoted text is carried, not executed: a command whose ARGUMENT happens to spell a redirect or an
# editor's name writes nothing, and denying it gated a read — live-caught on a compact focus prompt
# reading "ladder pin > roles > pool" beside the word worker-model.
for prose in \
  "$HOME/.claude/hooks/compact-auto.sh arm claude-opus-5 'phase: ladder pin > roles > pool; worker-model rows next'" \
  "$HOME/.claude/hooks/compact-auto.sh arm claude-opus-5 'we sed the worker-model rows later'" \
  "git commit -m 'worker-model: pin > pool ordering'" \
  "$HOME/.claude/hooks/compact-auto.sh arm claude-opus-5 'first > second
worker-model wording > row ae'" \
  "git commit . -m 'ladder pin > roles: worker-model'" \
  "env cat ~/.claude/worker-model | grep -m1 'pin > roles'" \
  "$HOME/.claude/hooks/compact-auto.sh arm claude-opus-5 'first > second

worker-model wording > row ae'"
do
  assert not_written "$prose"
done

# An interpreter EXECUTES its quoted argument, so for those the quotes hide syntax rather than
# carrying text: a strip that trusted them would open the widest hole in this door. An interpreter
# named by PATH is the same interpreter, a double-quoted command substitution is executed too, and a
# blank line is no reason for the scan to forget which quote it stands in.
for hidden in \
  "bash -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "sh -c 'printf codex_profile=x >> ~/.claude/worker-model'" \
  "eval \"printf 'codex_profile=x' > ~/.claude/worker-model\"" \
  "echo '~/.claude/worker-model' | xargs -I{} sh -c 'printf codex_profile=x > {}'" \
  "/bin/bash -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "/usr/bin/env sh -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  'x="$(printf codex_profile=x > ~/.claude/worker-model)"' \
  'x="`printf codex_profile=x > ~/.claude/worker-model`"' \
  "printf 'a > b'

bash -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "printf 'a > b'
printf 'codex_profile=x' > ~/.claude/worker-model" \
  "ruby -e 'system(\"printf codex_profile=x > ~/.claude/worker-model\")'" \
  "node -e 'require(\"child_process\").execSync(\"printf codex_profile=x > ~/.claude/worker-model\")'"
do
  assert written "$hidden"
done

# The interpreter itself can be QUOTED or held in a variable, and then the strip erases the one word
# this door reads it by: `"bash" -c '…'` and `$SHELL -c '…'` collapse to placeholders that match
# neither the interpreter names nor a redirect, and the write went through where the raw command was
# denied. A word in command position is an executable, so an unreadable one there falls back to raw.
for veiled in \
  "\"bash\" -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "'/bin/bash' -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "\$SHELL -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "\${SH} -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "\$(which bash) -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "x=1; \"bash\" -c 'printf codex_profile=x > ~/.claude/worker-model'" \
  "echo hi | \$SHELL -c 'printf codex_profile=x > ~/.claude/worker-model'"
do
  assert written "$veiled"
done

# And the same fallback must not fire on a placeholder standing among ARGUMENTS, wherever the command
# begins: that is the quoted prose this door already learned not to gate, and a separator earlier in
# the line does not move a later argument into command position.
for still_prose in \
  "$HOME/.claude/hooks/compact-auto.sh arm claude-opus-5 'prose with > and worker-model'" \
  "git log --oneline -3; git commit -m 'ladder pin > pool: worker-model'" \
  "cat ~/.claude/worker-model | grep -m1 'pin > roles'"
do
  assert not_written "$still_prose"
done

# A heredoc body is what `cat > pin <<EOF` stores, and an unlisted model in it is denied.
assert allowed "$(bash_event "cat > ~/.claude/worker-model <<'EOF'
codex_model=astra
EOF")"
assert denied "$(bash_event "cat > ~/.claude/worker-model <<'EOF'
codex_model=bogus
EOF")"

# --- The chat pin file is chat-pin's alone ------------------------------------------------------
CHAT_DIR="$HOME/.cache/claude-chat-pins"
for spelling in "$CHAT_DIR/s" '~/.cache/claude-chat-pins/s' "$HOME/.cache//claude-chat-pins/s" "$CHAT_DIR"; do
  assert denied "$(write_event "$spelling" 'codex_profile=*')"
done
assert denied "$(edit_event "$CHAT_DIR/s" 'codex_profile=*' 'grok_profile=*')"
assert contains "$(write_event "$CHAT_DIR/s")" 'chat-pin <vendor|account|auto>'
assert allowed "$(read_event "$CHAT_DIR/s")"
assert allowed "$(write_event "$HOME/.cache/other-pins/s")"
for chat_write in \
  "printf 'codex_profile=*\\n' > ~/.cache/claude-chat-pins/s" \
  "echo grok_profile=alpha >> \"\$HOME/.cache/claude-chat-pins/\$CLAUDE_CODE_SESSION_ID\"" \
  "echo codex_profile=beta | tee ~/.cache/claude-chat-pins/s" \
  "rm -f ~/.cache/claude-chat-pins/s" \
  "cp /tmp/pin ~/.cache/claude-chat-pins/s" \
  "mkdir -p ~/.cache/claude-chat-pins && printf 'codex_profile=*\\n' > ~/.cache/claude-chat-pins/s" \
  "f=~/.cache/claude-chat-pins/\$CLAUDE_CODE_SESSION_ID; echo codex_profile=beta > \"\$f\"" \
  "sed -i '' 's/codex/grok/' ~/.cache/claude-chat-pins/s"
do
  assert denied "$(bash_event "$chat_write")"
done
for chat_read in \
  'cat ~/.cache/claude-chat-pins/s' \
  'ls -la ~/.cache/claude-chat-pins' \
  "grep -h _profile= ~/.cache/claude-chat-pins/* > /dev/null" \
  'chat-pin codex' \
  'chat-pin auto'
do
  assert allowed "$(bash_event "$chat_read")"
done

# The directory is the one the module reads, CHAT_PINS_DIR included.
export CHAT_PINS_DIR="$WORK/pins-fixture"
assert denied "$(write_event "$WORK/pins-fixture/s")"
assert denied "$(bash_event "echo codex_profile=beta > $WORK/pins-fixture/s")"
assert allowed "$(bash_event "cat $WORK/pins-fixture/s")"
unset CHAT_PINS_DIR

# --- The command path: worker_model_pin_account moves the pin for a session too ------------------
. "$ROOT/share/worker-model.sh"
accounts() { printf 'alpha\nbeta\n'; }
never_disabled() { return 1; }
REAL_PIN="$PIN_FILE"
export WORKER_PICK_CONFIG_FILE="$REAL_PIN"
export CLAUDECODE=1
printf 'claudeb_profile=alpha\n' >"$REAL_PIN"
assert contains "$(worker_model_pin_account claudeb_profile claudeb accounts never_disabled)" \
  'workers are pinned to alpha'
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled beta
assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=alpha,beta'
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled --clear
assert lacks "$(cat "$REAL_PIN")" 'claudeb_profile='
unset CLAUDECODE
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled alpha
assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=alpha'

export CLAUDECODE=1
export WORKER_PICK_CONFIG_FILE="$WORK/fixture-model"
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled beta
assert contains "$(cat "$WORK/fixture-model")" 'claudeb_profile=beta'
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled alpha
assert contains "$(cat "$WORK/fixture-model")" 'claudeb_profile=beta,alpha'
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled --unpin beta
assert contains "$(cat "$WORK/fixture-model")" 'claudeb_profile=alpha'
assert lacks "$(cat "$WORK/fixture-model")" 'claudeb_profile=beta'
assert worker_model_pin_account grok_profile grokb accounts never_disabled alpha
assert contains "$(cat "$WORK/fixture-model")" 'grok_profile=alpha'
assert_fails worker_model_pin_account unknown_profile unknown accounts never_disabled alpha

# --- Fail-open ----------------------------------------------------------------------------------
# A malformed event, another event kind and an unknown mode pass through rather than blocking work.
assert allowed "$(printf 'not json' | "$GATE" write)"
assert allowed "$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Write"}' | "$GATE" write)"
assert allowed "$(jq -cn --arg p "$PIN_FILE" \
  '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $p}}' \
  | "$GATE" nonsense)"

# The same door refuses storing a model no implementation worker may run: a cheap default here
# silently downgrades every worker after it.
for bad in claudeb_model=sonnet claudeb_model=haiku gemini_model=flash35 gemini_model=flash39 grok_model=grok-3 codex_model=gpt-5.6-terra; do
  assert denied "$(write_event "$PIN_FILE" "worker=auto
$bad
")"
  assert denied "$(edit_event "$PIN_FILE" 'worker=auto' "$bad")"
  assert denied "$(bash_event "printf '$bad\n' >> $PIN_FILE")"
done
# The deny names the offender and the allowed list, and says nothing about the pin.
model_deny=$(write_event "$PIN_FILE" 'claudeb_model=sonnet')
assert contains "$model_deny" 'claudeb=sonnet'
assert contains "$model_deny" 'claudeb opus|fable; codex astra|sol; gemini flash38|flash37|flash36|pro; grok auto|grok-4.7|grok-4.7-build-fast|grok-4.6|grok-4.5'
assert lacks "$model_deny" 'is Egor'
assert denied "$(write_event "$PIN_FILE" 'claudeb_profile=beta
claudeb_model=sonnet
')"
assert allowed "$(bash_event "printf 'claudeb_profile=beta\n' >> $PIN_FILE")"
for bad in claudeb_model=sonnet gemini_model=flash35; do
  bash_model_deny=$(bash_event "printf '$bad\n' >> $PIN_FILE")
  assert denied "$bash_model_deny"
  assert contains "$bash_model_deny" "${bad/_model=/=}"
done
# The allowed models pass, and so does an edit that REMOVES a cheap one: an Edit is judged on what
# it would leave behind.
printf 'worker=auto\nclaudeb_model=opus\n' >"$PIN_FILE"
assert allowed "$(write_event "$PIN_FILE" 'worker=auto
claudeb_model=opus
claudeb_effort=high
gemini_model=flash38
grok_model=auto
')"
assert allowed "$(edit_event "$PIN_FILE" 'claudeb_model=sonnet' 'claudeb_model=opus')"
for model_line in claudeb_model=fable codex_model=sol codex_model=gpt-5.6-sol; do
  assert allowed "$(write_event "$PIN_FILE" "$model_line")"
  assert allowed "$(edit_event "$PIN_FILE" 'worker=auto' "$model_line")"
done
for effort_line in codex_effort=max grok_effort=low; do
  effort_deny=$(write_event "$PIN_FILE" "$effort_line")
  assert denied "$effort_deny"
  assert contains "$effort_deny" 'Effort defaults belong to the table'
  assert denied "$(edit_event "$PIN_FILE" 'worker=auto' "$effort_line")"
  assert denied "$(bash_event "sed -i '' 's/^${effort_line%%=*}=.*/$effort_line/' $PIN_FILE")"
done
assert contains "$(write_event "$PIN_FILE" 'codex_effort=max')" 'low|medium|high|xhigh'
assert contains "$(write_event "$PIN_FILE" 'grok_effort=low')" 'high|xhigh'
assert allowed "$(write_event "$PIN_FILE" 'claudeb_effort=low')"
assert allowed "$(edit_event "$PIN_FILE" 'worker=auto' 'claudeb_effort=low')"
assert allowed "$(bash_event "sed -i '' 's/^claudeb_effort=.*/claudeb_effort=low/' $PIN_FILE")"
printf 'codex_model=gpt-5.6-sol\n' >>"$PIN_FILE"
assert contains "$(edit_event "$PIN_FILE" 'codex_effort=high' 'codex_effort=max')" 'medium|high|low|xhigh'
assert contains "$(write_event "$PIN_FILE" 'codex_effort=max')" 'low|medium|high|xhigh'
assert contains "$(write_event "$PIN_FILE" $'codex_model=gpt-5.6-sol\ncodex_effort=max')" 'medium|high|low|xhigh'
assert allowed "$(write_event "$PIN_FILE" $'codex_model=gpt-5.6-sol\ncodex_effort=low')"
assert denied "$(bash_event "printf 'codex_effort=max\n' >> $PIN_FILE")"
assert denied "$(write_event "$PIN_FILE" 'codex_effort=max')"
assert allowed "$(bash_event "printf 'claudeb_model=fable\ncodex_model=gpt-5.6-sol\n' >> $PIN_FILE")"
assert allowed "$(bash_event "sed -i '' 's/codex_effort=max/codex_effort=low/' $PIN_FILE")"
assert allowed "$(edit_event "$PIN_FILE" 'claudeb_effort=high' 'claudeb_effort=medium')"
assert allowed "$(bash_event "grep claudeb_model=sonnet $PIN_FILE")"

# The two Light rows are `<vendor>[:<model>]` over the LIGHT table, which is wider than the workers
# one: `claudeb:sonnet` is a light row and not a `claudeb_model=`. An unresolvable row refuses the
# next `worker-run start light` with MODEL_REFUSED, so it is caught here instead.
printf 'worker=auto\nclaudeb_model=opus\n' >"$PIN_FILE"
for good in light_edit=claudeb:sonnet light_research=gemini light_edit=codex light_research=grok:auto; do
  assert allowed "$(write_event "$PIN_FILE" "worker=auto
$good
")"
  assert allowed "$(edit_event "$PIN_FILE" 'worker=auto' "$good")"
done
for bad in light_edit=openai light_research=claudeb:sonnet35 light_edit=gemini:flash35 light_research=grok:grok-3; do
  assert denied "$(write_event "$PIN_FILE" "worker=auto
$bad
")"
  assert denied "$(edit_event "$PIN_FILE" 'worker=auto' "$bad")"
done
light_deny=$(write_event "$PIN_FILE" 'light_edit=claudeb:sonnet35')
assert contains "$light_deny" 'light_edit=claudeb:sonnet35'
assert contains "$light_deny" 'claudeb opus|fable|sonnet'
assert lacks "$light_deny" 'is Egor'
# The Bash door carries the same rule.
assert denied "$(bash_event "printf 'light_edit=claudeb:sonnet35\n' >> $PIN_FILE")"
assert allowed "$(bash_event "printf 'light_edit=claudeb:sonnet\n' >> $PIN_FILE")"

# A substitution NAMES the value it replaces, and that value is the one leaving the file: the shell
# door judged the presence of the text and refused a command storing an allowed model.
assert allowed "$(bash_event "sed -i '' 's/gemini_model=flash35/gemini_model=flash38/' $PIN_FILE")"
sed_model_deny=$(bash_event "sed -i '' 's/gemini_model=flash38/gemini_model=flash35/' $PIN_FILE")
assert denied "$sed_model_deny"
assert contains "$sed_model_deny" 'gemini=flash35'

# List-shaped pin lines pass; a model value beside them is still denied.
printf 'worker=auto\ncodex_profile=alpha,beta\nclaudeb_model=opus\n' >"$PIN_FILE"
assert allowed "$(write_event "$PIN_FILE" "$(printf 'worker=codex\ncodex_profile=alpha,beta\nclaudeb_model=opus\n')")"
assert denied "$(write_event "$PIN_FILE" "$(printf 'worker=auto\ncodex_profile=alpha,beta\nclaudeb_model=sonnet\n')")"
assert allowed "$(edit_event "$PIN_FILE" 'codex_profile=alpha,beta' 'codex_profile=opus')"

# Every Bash call pays this door: one naming neither the pin file nor the chat pins forks nothing.
for tool in cat jq grep sed basename dirname; do
  printf '%s() { printf "%s\\n" >>"$FORKS"; command %s "$@"; }\n' "$tool" "$tool" "$tool"
done >"$WORK/count-forks.sh"
: >"$WORK/forks"
jq -cn '{hook_event_name: "PreToolUse", session_id: "s", tool_name: "Bash", tool_input: {command: "ls -la | head -5"}}' |
  BASH_ENV="$WORK/count-forks.sh" FORKS="$WORK/forks" bash "$GATE" bash >/dev/null 2>&1
assert [ ! -s "$WORK/forks" ]

printf 'PASS: %s asserts; ~/.claude/worker-model takes no `*_model=`, effort or light row the table does not list, by Edit/Write or by any shell write the door reads as reaching it however the path is spelled, while a read passes and a pin move passes, word or none, here and at `use`; the chat pins are written only through `chat-pin`\n' "$asserts"
