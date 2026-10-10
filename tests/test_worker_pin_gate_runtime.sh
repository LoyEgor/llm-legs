#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/worker-pin-gate.sh, the shell door against what EXECUTES text: language runtimes, interpreters
# and quoted prose — a runtime or interpreter writing ~/.claude/worker-model is a write, carried text is not.
. "$(dirname "$0")/worker_pin_gate_harness.sh" || exit 1

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

printf 'PASS: %s asserts; a runtime or interpreter writing ~/.claude/worker-model is a pin write however its program is quoted or veiled, while a runtime naming it in strings and quoted prose are not\n' "$asserts"
