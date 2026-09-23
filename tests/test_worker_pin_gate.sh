#!/usr/bin/env bash
# The account pin is Egor's own override, and a session must not move it on its own. All three
# doors are tested here: bin/worker-pin-gate.sh (his words grant; a hand-written edit of the file
# and a shell redirect over it are both denied) and worker_model_pin_account (the command path
# refuses without a grant). No network, no daemon; every marker and every pin file is a fixture.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/bin/worker-pin-gate.sh"
WORK="$(mktemp -d)"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
trap 'rm -rf "$WORK"' EXIT
export CLAUDEB_DIR="$WORK/store"
unset WORKER_STATS_DIR
GRANT="$CLAUDEB_DIR/worker-stats/pin-grants/pin"

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
literal_case append denied "f=$PIN_FILE; sed 's/^worker=.*/worker=codex/' \"\$f\" >>\"\$f.tmp.\$\$\" && mv -f \"\$f.tmp.\$\$\" \"\$f\""
literal_case suppress denied "sed -i '' -n 's/^worker=.*/worker=codex/p' $PIN_FILE"
literal_case statement denied "$literal_safe; echo done"
literal_case attached denied "sed -i '' -f/tmp/script 's/^worker=.*/worker=codex/' $PIN_FILE"
literal_case suffix denied "f=/tmp/worker-model; sed 's/^worker=.*/worker=codex/' \"\$f\" > \"\$f.tmp.\$\$\" && mv -f \"\$f.tmp.\$\$\" $PIN_FILE"
literal_case expression denied "sed -i '' -e 's/^worker=.*/worker=codex/' $PIN_FILE"
literal_case second-expression denied "sed -i '' -e's/^worker=.*/worker=codex/' -e'd' $PIN_FILE"
literal_case profile denied "sed -i '' 's/^codex_profile=.*/codex_profile=alt/' $PIN_FILE"
literal_case model denied "sed -i '' 's/^codex_model=.*/codex_model=gpt-6-astra/' $PIN_FILE"
[ "$literal_failures" -eq 0 ] || exit 1

# --- The file itself: denied unnamed, and nothing else is ---------------------------------------
rm -f "$GRANT"
assert denied "$(write_event "$PIN_FILE")"
for other in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" "$WORK/worker-model" \
             "$HOME/.claude/worker-model.bak"; do
  assert allowed "$(write_event "$other")"
done

# The same file spelled differently is the same file: a gate that compares the path text is one a
# session opens by typing an extra slash.
assert denied "$(write_event "$HOME/.claude//worker-model")"
assert denied "$(write_event "$HOME/.claude/../.claude/worker-model")"
assert denied "$(write_event '~/.claude/worker-model')"

# --- What is gated is the pin, not the file -----------------------------------------------------
# `/worker` rewrites this same file to move worker=/model/effort, none of which is the account pin;
# a gate on the path alone blocks the documented toggle and gets itself worked around.
CURRENT_PINS=$(grep -E '^(claudeb|codex|gemini|grok)_profile=' "$PIN_FILE" 2>/dev/null | sort)
assert allowed "$(write_event "$PIN_FILE" "$(printf 'worker=codex\nclaudeb_effort=high\n%s\n' \
  "$CURRENT_PINS")")"
assert denied "$(write_event "$PIN_FILE" "$(printf 'worker=codex\ncodex_profile=someone\n')")"
assert denied "$(write_event "$PIN_FILE" "$(printf 'worker=codex\ngrok_profile=someone\n')")"
assert allowed "$(edit_event "$PIN_FILE" 'worker=auto' 'worker=codex')"
assert denied "$(edit_event "$PIN_FILE" 'worker=auto' 'worker=auto\ncodex_profile=x')"
assert denied "$(edit_event "$PIN_FILE" 'codex_profile=main' '')"
assert denied "$(edit_event "$PIN_FILE" 'grok_profile=main' '')"

# Reading is never gated, whatever matcher the hook is registered under. A tool the gate does not
# understand falls through rather than being denied on a text match: this door judges the two tools
# it is registered for, and guesses at nothing else.
assert allowed "$(read_event "$PIN_FILE")"
assert allowed "$(jq -cn --arg p "$PIN_FILE" \
  '{hook_event_name: "PreToolUse", tool_name: "MultiEdit",
    tool_input: {file_path: $p, old_string: "codex_profile=main", new_string: "codex_profile=x"}}' \
  | "$GATE" write)"

# --- The shell door: a redirect is a write, and `cat` is not ------------------------------------
# A door on Edit/Write alone is a door around itself — the deny text tells the reader not to reach
# the file another way, and `printf >>` was exactly another way.
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
  assert denied "$(bash_event "$writing")"
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
  assert allowed "$(bash_event "$reading")"
done
# A read whose OUTPUT is redirected writes the file it names, and that file is not the pin: the door
# takes a destination off the shared parse now (`instruction_write_targets`) instead of reading any
# `>` in a command that names the pin as a write to it.
assert allowed "$(bash_event 'cat ~/.claude/worker-model > /tmp/out.txt')"
assert allowed "$(bash_event 'cat ~/.claude/worker-model | tee /tmp/copy.txt')"

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
  assert allowed "$(bash_event "$read_beside_write")"
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
  assert denied "$(bash_event "$still_written")"
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
  assert allowed "$(bash_event "$copy_out")"
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
  'cp --target-directory=~/.claude/worker-model /tmp/m'
do
  assert denied "$(bash_event "$copy_in")"
done
# Trailing options/redirections are not the destination; a copy whose last *operand* is elsewhere
# still is not a pin write, even with the same tails that hid a pin dest above.
for copy_out_tail in \
  'cp /tmp/m /tmp/elsewhere >/dev/null' \
  'cp /tmp/m /tmp/elsewhere -f' \
  'cp -t /tmp/elsewhere /tmp/m'
do
  assert allowed "$(bash_event "$copy_out_tail")"
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
  assert allowed "$(bash_event "$brief")"
done
# …and a heredoc pointed AT the file is the write it looks like.
assert denied "$(bash_event 'cat > ~/.claude/worker-model <<EOF
worker=auto
claudeb_profile=beta
EOF')"
assert denied "$(bash_event "tee ~/.claude/worker-model <<EOF
claudeb_profile=beta
EOF")"

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
  assert allowed "$(bash_event "$beside")"
done
# A runtime that opens the PIN is still a pin move, however the payload is quoted.
assert denied "$(bash_event 'python3 -c "open(\"$HOME/.claude/worker-model\",\"w\").write(\"codex_profile=x\")"')"

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
  assert allowed "$(bash_event "$prose")"
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
  assert denied "$(bash_event "$hidden")"
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
  assert denied "$(bash_event "$veiled")"
done

# And the same fallback must not fire on a placeholder standing among ARGUMENTS, wherever the command
# begins: that is the quoted prose this door already learned not to gate, and a separator earlier in
# the line does not move a later argument into command position.
for still_prose in \
  "$HOME/.claude/hooks/compact-auto.sh arm claude-opus-5 'prose with > and worker-model'" \
  "git log --oneline -3; git commit -m 'ladder pin > pool: worker-model'" \
  "cat ~/.claude/worker-model | grep -m1 'pin > roles'"
do
  assert allowed "$(bash_event "$still_prose")"
done

# --- His words open it --------------------------------------------------------------------------
# This sandbox HOME carries no words library, so the door reads the grant file it always read.
mkdir -p "$(dirname "$GRANT")"
touch "$GRANT"
assert allowed "$(write_event "$PIN_FILE")"
assert allowed "$(bash_event "printf 'codex_profile=x\\n' > ~/.claude/worker-model")"
touch -t 202601010000 "$GRANT"
assert denied "$(write_event "$PIN_FILE")"
rm -f "$GRANT"

# With the library, the grant is the pin grant claude-setup's word intake wrote for this chat.
export WORDS_LIB="$ROOT/../claude-setup/hooks/lib/words.sh" WORDS_DIR="$WORK/words"
[ -r "$WORDS_LIB" ] || fail "the words library is missing: $WORDS_LIB"
pin_grant() { # scope
  mkdir -p "$WORDS_DIR/s"
  jq -nc --arg s "$1" '{family: "pin", turn: 1, at: 0, excerpt: "x", lifetime: "ttl:30m",
    source: "stem", target: "codex", scope: $s}' >"$WORDS_DIR/s/grant.pin"
}
pin_grant account
assert allowed "$(write_event "$PIN_FILE")"
assert allowed "$(bash_event "printf 'codex_profile=x\\n' > ~/.claude/worker-model")"
# «воркеры на codex» is this chat's pin, never the account pin every other chat reads.
pin_grant chat
assert denied "$(write_event "$PIN_FILE")"
assert denied "$(bash_event "printf 'codex_profile=x\\n' > ~/.claude/worker-model")"
# A WORD= quote opens the word door with no grant file behind it: the account pin still needs a
# quote of his that names IT, so the chat pin quoted here moves nothing global.
rm -f "$WORDS_DIR/s/grant.pin"
printf 'воркеры на codex\n' >"$WORDS_DIR/s/last.txt"
assert denied "$(bash_event "WORD='воркеры на codex' printf 'codex_profile=x\\n' > ~/.claude/worker-model")"
quoted_event() { # call command
  jq -cn --arg u "$1" --arg c "$2" '{hook_event_name: "PreToolUse", session_id: "s", tool_use_id: $u,
    tool_name: "Bash", tool_input: {command: $c}}' | "$GATE" bash
}
assert denied "$(quoted_event toolu_pin1 "WORD='воркеры на codex' printf 'codex_profile=x\\n' > ~/.claude/worker-model")"
printf 'сделай пин аккаунта на codex\n' >"$WORDS_DIR/s/last.txt"
assert allowed "$(quoted_event toolu_pin2 "WORD='сделай пин аккаунта на codex' printf 'codex_profile=x\\n' > ~/.claude/worker-model")"
rm -f "$WORDS_DIR/s/last.txt" "$WORDS_DIR/s"/attest.* "$WORDS_DIR/s"/claim.*
pin_grant account
touch -t 202601010000 "$WORDS_DIR/s/grant.pin"
assert denied "$(write_event "$PIN_FILE")"
rm -f "$WORDS_DIR/s/grant.pin"
touch "$GRANT"
assert denied "$(write_event "$PIN_FILE")"
rm -f "$GRANT"
chmod 000 "$WORDS_DIR/s"
assert allowed "$(write_event "$PIN_FILE")"
chmod 700 "$WORDS_DIR/s"
unset WORDS_LIB WORDS_DIR

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

# No grant opens the direct write: his words unblock `chat-pin`, which checks what he named.
mkdir -p "$(dirname "$GRANT")"
touch "$GRANT"
assert denied "$(write_event "$CHAT_DIR/s" 'codex_profile=*')"
assert denied "$(bash_event "printf 'codex_profile=*\\n' > ~/.cache/claude-chat-pins/s")"
rm -f "$GRANT"

# The directory is the one the module reads, CHAT_PINS_DIR included.
export CHAT_PINS_DIR="$WORK/pins-fixture"
assert denied "$(write_event "$WORK/pins-fixture/s")"
assert denied "$(bash_event "echo codex_profile=beta > $WORK/pins-fixture/s")"
assert allowed "$(bash_event "cat $WORK/pins-fixture/s")"
unset CHAT_PINS_DIR

# --- The command path: worker_model_pin_account refuses at the same door ------------------------
# The hook cannot see `claudeb use`, and a gate that only watched the file would be walked around
# by the command it exists to gate.
. "$ROOT/share/worker-model.sh"
accounts() { printf 'alpha\nbeta\n'; }
never_disabled() { return 1; }
REAL_PIN="$PIN_FILE"
export WORKER_PICK_CONFIG_FILE="$REAL_PIN"

# A session (CLAUDECODE set) is refused, and refused for clearing too — a pin he set is not a
# session's to remove either.
export CLAUDECODE=1
printf 'claudeb_profile=alpha\n' >"$REAL_PIN"
out=$(worker_model_pin_account claudeb_profile claudeb accounts never_disabled beta 2>&1) && \
  fail "a session pinned an account with no grant"
assert contains "$out" "the pin is Egor's to move"
assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=alpha'
out=$(worker_model_pin_account claudeb_profile claudeb accounts never_disabled --clear 2>&1) && \
  fail "a session cleared the pin with no grant"
assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=alpha'

# Reading it is never gated: a session must still be able to say which account is pinned.
assert contains "$(worker_model_pin_account claudeb_profile claudeb accounts never_disabled)" \
  'workers are pinned to alpha'

# With his grant, the same call goes through.
mkdir -p "$(dirname "$GRANT")"
touch "$GRANT"
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled beta
assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=alpha,beta'
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled --clear
assert lacks "$(cat "$REAL_PIN")" 'claudeb_profile='

# And it goes stale on the same clock the hook uses: a grant that outlived his ask is a door left
# open, and the next session through it would read a months-old marker as permission.
touch -t 202601010000 "$GRANT"
assert_fails worker_model_pin_account claudeb_profile claudeb accounts never_disabled beta
assert lacks "$(cat "$REAL_PIN")" 'claudeb_profile='
rm -f "$GRANT"

# The same file spelled differently is still his file: keying the fixture exemption on the path
# TEXT hands a session the pin for the price of an extra slash.
for spelling in "$WORK/home/.claude//worker-model" "$WORK/home/.claude/../.claude/worker-model"; do
  export WORKER_PICK_CONFIG_FILE="$spelling"
  printf 'claudeb_profile=alpha\n' >"$REAL_PIN"
  assert_fails worker_model_pin_account claudeb_profile claudeb accounts never_disabled beta
  assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=alpha'
done
export WORKER_PICK_CONFIG_FILE="$REAL_PIN"

# His own shell is not a session: the menubar shells out from Hammerspoon with no CLAUDECODE, and
# gating that would take the pin away from the one hand it belongs to.
unset CLAUDECODE
assert worker_model_pin_account claudeb_profile claudeb accounts never_disabled alpha
assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=alpha'

# A fixture named through WORKER_PICK_CONFIG_FILE is a test's own file — every other suite pins
# freely against one, and gating those would make this change a test rewrite instead of a rule.
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

# The same door refuses storing a model no implementation worker may run. Unlike the pin this one
# takes no grant: a cheap default here silently downgrades every worker after it.
rm -f "$GRANT"
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
# A grant unblocks the pin and never the model.
mkdir -p "$(dirname "$GRANT")" && touch "$GRANT"
assert denied "$(write_event "$PIN_FILE" 'claudeb_profile=beta
claudeb_model=sonnet
')"
# The Bash door's own model refusal, proved on an OPEN door: with no grant the pin rule denies
# every write here, so the shell cases above stay green even if the model check never ran.
assert allowed "$(bash_event "printf 'claudeb_profile=beta\n' >> $PIN_FILE")"
for bad in claudeb_model=sonnet gemini_model=flash35; do
  bash_model_deny=$(bash_event "printf '$bad\n' >> $PIN_FILE")
  assert denied "$bash_model_deny"
  assert contains "$bash_model_deny" "${bad/_model=/=}"
done
rm -f "$GRANT"
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
mkdir -p "$(dirname "$GRANT")" && touch "$GRANT"
assert denied "$(bash_event "printf 'codex_effort=max\n' >> $PIN_FILE")"
assert denied "$(write_event "$PIN_FILE" 'codex_effort=max')"
assert allowed "$(bash_event "printf 'claudeb_model=fable\ncodex_model=gpt-5.6-sol\n' >> $PIN_FILE")"
assert allowed "$(bash_event "sed -i '' 's/codex_effort=max/codex_effort=low/' $PIN_FILE")"
rm -f "$GRANT"
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
for bad in light_edit=openai light_research=claudeb:haiku light_edit=gemini:flash35 light_research=grok:grok-3; do
  assert denied "$(write_event "$PIN_FILE" "worker=auto
$bad
")"
  assert denied "$(edit_event "$PIN_FILE" 'worker=auto' "$bad")"
done
light_deny=$(write_event "$PIN_FILE" 'light_edit=claudeb:haiku')
assert contains "$light_deny" 'light_edit=claudeb:haiku'
assert contains "$light_deny" 'claudeb opus|fable|sonnet'
assert lacks "$light_deny" 'is Egor'
# The Bash door carries the same rule, and no grant unlocks it.
mkdir -p "$(dirname "$GRANT")" && touch "$GRANT"
assert denied "$(bash_event "printf 'light_edit=claudeb:haiku\n' >> $PIN_FILE")"
assert allowed "$(bash_event "printf 'light_edit=claudeb:sonnet\n' >> $PIN_FILE")"
rm -f "$GRANT"

# A substitution NAMES the value it replaces, and that value is the one leaving the file: the shell
# door judged the presence of the text and refused a command storing an allowed model. Proved on an
# OPEN pin door, since with no grant the pin rule denies every write here whatever it carries.
mkdir -p "$(dirname "$GRANT")" && touch "$GRANT"
assert allowed "$(bash_event "sed -i '' 's/gemini_model=flash35/gemini_model=flash38/' $PIN_FILE")"
sed_model_deny=$(bash_event "sed -i '' 's/gemini_model=flash38/gemini_model=flash35/' $PIN_FILE")
assert denied "$sed_model_deny"
assert contains "$sed_model_deny" 'gemini=flash35'
# The pin lines stay the pin's: the same shape over a `*_profile=` line is refused by its own rule.
rm -f "$GRANT"
profile_sed_deny=$(bash_event "sed -i '' 's/claudeb_profile=alpha/claudeb_profile=beta/' $PIN_FILE")
assert denied "$profile_sed_deny"
assert contains "$profile_sed_deny" "is Egor's to move"

# An ungated key rewritten in place leaves every `*_profile=` line exactly as it found it, which is
# what this door judges — and both spellings of that write were refused live on 2026-09-05, with no
# grant standing. The temp-file spelling is the same write: the `mv` takes back what this very
# command just produced out of the pin itself.
assert allowed "$(bash_event "sed -i '' 's/^codex_effort=.*/codex_effort=low/' $PIN_FILE")"
assert allowed "$(bash_event "f=$PIN_FILE; sed 's/^codex_effort=.*/codex_effort=low/' \"\$f\" > \"\$f.tmp.\$\$\" && mv -f \"\$f.tmp.\$\$\" \"\$f\"")"
assert denied "$(bash_event "sed -i '' -e 's/^worker=.*/worker=codex/' $PIN_FILE")"
# Every shape that could leave a DIFFERENT pin behind stays refused. A `d` script and an unanchored
# pattern reach the pin lines; a replacement may not spell one; a redirect onto the file truncates
# it before sed reads a byte; and a `mv` of anything this command did not itself produce out of the
# pin — a foreign file, or a sed over one — is a pin of unknown content.
for pin_move in \
  "sed -i '' 's/^codex_profile=.*/codex_profile=alt/' $PIN_FILE" \
  "sed -i '' '/^codex_profile=/d' $PIN_FILE" \
  "sed -i '' 's/.*/worker=codex/' $PIN_FILE" \
  "sed -i '' 's/^codex_effort=.*/codex_profile=alt/' $PIN_FILE" \
  "sed 's/^codex_effort=.*/codex_effort=low/' $PIN_FILE > $PIN_FILE" \
  "sed 's/^codex_effort=.*/codex_effort=low/' other > $WORK/t && mv $WORK/t $PIN_FILE" \
  "mv $WORK/other $PIN_FILE" \
  "cp $WORK/other $PIN_FILE"; do
  assert denied "$(bash_event "$pin_move")"
done

# (vi) list-shaped pin lines are pin lines: preserving them is allowed; a model value is still denied.
printf 'worker=auto\ncodex_profile=alpha,beta\nclaudeb_model=opus\n' >"$PIN_FILE"
assert allowed "$(write_event "$PIN_FILE" "$(printf 'worker=codex\ncodex_profile=alpha,beta\nclaudeb_model=opus\n')")"
assert denied "$(write_event "$PIN_FILE" "$(printf 'worker=auto\ncodex_profile=alpha,beta\nclaudeb_model=sonnet\n')")"
assert denied "$(edit_event "$PIN_FILE" 'codex_profile=alpha,beta' 'codex_profile=opus')"

printf 'PASS: %s asserts; the account pin moves only by Egor'\''s hand — a pin grant of his words opens it for a window and a grant for this chat'\''s own pin does not, a session editing ~/.claude/worker-model — by Edit/Write, by shell redirect, or by `use` at the command door in either direction — is denied whatever way it spells the path, while reading the pin, his own shell and every test fixture stay untouched; the same door refuses storing a `*_model=` value no implementation worker may run or a light row naming a vendor or model the light table does not hold, and no grant unlocks either\n' "$asserts"
