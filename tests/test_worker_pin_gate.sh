#!/usr/bin/env bash
# The account pin is Egor's own override, and a session must not move it on its own. All three
# doors are tested here: bin/worker-pin-gate.sh (his words grant; a hand-written edit of the file
# and a shell redirect over it are both denied) and worker_model_pin_account (the command path
# refuses without a grant). No network, no daemon; every marker and every pin file is a fixture.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/bin/worker-pin-gate.sh"
WORK="$(mktemp -d)"
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
granted() { [ -f "$GRANT" ]; }

write_event() {
  jq -cn --arg p "$1" --arg c "${2-claudeb_profile=beta}" \
    '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $p, content: $c}}' \
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
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' | "$GATE" bash
}

prompt_event() {
  jq -cn --arg p "$1" '{hook_event_name: "UserPromptSubmit", session_id: "s", prompt: $p}' \
    | "$GATE" prompt
}

PIN_FILE="$HOME/.claude/worker-model"

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
  "sed -i '' 's/^worker=.*/worker=codex/' ~/.claude/worker-model" \
  "tee ~/.claude/worker-model <<<'codex_profile=x'" \
  "cp /tmp/model ~/.claude/worker-model" \
  "rm ~/.claude/worker-model" \
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

# --- His words open it, in both directions ------------------------------------------------------
# Asking for a pin and asking to remove one are the same hand on the same switch; the grant only
# unblocks, so reading both costs nothing a stray mention could spend.
for naming in \
  'запинь codex на rudolfelijah' \
  'сними пин с codex' \
  'убери пин' \
  'поставь пин на main' \
  'pin the codex account' \
  'unpin it' \
  'Please "pin" codex' \
  '(unpin it)' \
  'открепи аккаунт' \
  'закрепи аккаунт main' \
  'зафиксируй аккаунт main'
do
  rm -f "$GRANT"
  out=$(prompt_event "$naming")
  assert granted
  assert contains "$out" 'unblocked for the next'
  assert allowed "$(write_event "$PIN_FILE")"
  # The shell door opens on the same word — a grant that only reaches Edit/Write would answer his
  # ask with a refusal from the other door.
  assert allowed "$(bash_event "printf 'codex_profile=x\\n' > ~/.claude/worker-model")"
done

# --- An ordinary message grants nothing ---------------------------------------------------------
# Naming an account, or asking for work on one, is not naming the pin: that conflation is the whole
# reported failure — "можешь использовать этот аккаунт" read as permission to pin it.
for ordinary in \
  'можешь использовать аккаунт rudolfelijah' \
  'запусти воркер на main' \
  'пингани сервер и покажи вывод' \
  'this is a pinout diagram' \
  'посмотри лимиты' \
  'в логе строка pinned workers to alpha, посмотри почему' \
  'в диффе видно pin-grants, объясни'
do
  rm -f "$GRANT"
  assert allowed "$(prompt_event "$ordinary")"
  assert_fails granted
  assert denied "$(write_event "$PIN_FILE")"
done

# --- The grant expires --------------------------------------------------------------------------
mkdir -p "$(dirname "$GRANT")"
touch -t 202601010000 "$GRANT"
assert denied "$(write_event "$PIN_FILE")"
rm -f "$GRANT"

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
assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=beta'
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
assert worker_model_pin_account grok_profile grokb accounts never_disabled alpha
assert contains "$(cat "$WORK/fixture-model")" 'grok_profile=alpha'
assert_fails worker_model_pin_account unknown_profile unknown accounts never_disabled alpha

# --- The one clear that is not a session's: the account walled itself ----------------------------
# The wall ends the pin, and that clear needs no grant — nobody chose it, the quota ran out. It
# still names the account it measured, so a pin Egor moved between that reading and this write
# survives: the wall belonged to the account he took the pin off.
export CLAUDECODE=1
export WORKER_PICK_CONFIG_FILE="$REAL_PIN"
rm -f "$GRANT"
printf 'worker=auto\nclaudeb_profile=alpha\n' >"$REAL_PIN"
assert_fails worker_model_clear_walled_pin claudeb_profile beta
assert contains "$(cat "$REAL_PIN")" 'claudeb_profile=alpha'
assert worker_model_clear_walled_pin claudeb_profile alpha
assert lacks "$(cat "$REAL_PIN")" 'claudeb_profile'
# The rest of his file is not collateral: only the pin line goes.
assert contains "$(cat "$REAL_PIN")" 'worker=auto'
# Nothing to clear is not a failure to report twice — a second run answers the same way.
assert_fails worker_model_clear_walled_pin claudeb_profile alpha

# --- Fail-open ----------------------------------------------------------------------------------
# A malformed event, another event kind and an unknown mode pass through rather than blocking work.
assert allowed "$(printf 'not json' | "$GATE" write)"
assert allowed "$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Write"}' | "$GATE" write)"
assert allowed "$(jq -cn --arg p "$PIN_FILE" \
  '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $p}}' \
  | "$GATE" nonsense)"

printf 'PASS: %s asserts; the account pin moves only by Egor'\''s hand — his words grant it for a window and an ordinary mention of an account does not, a session editing ~/.claude/worker-model — by Edit/Write, by shell redirect, or by `use` at the command door in either direction — is denied whatever way it spells the path, while reading the pin, his own shell and every test fixture stay untouched\n' "$asserts"
