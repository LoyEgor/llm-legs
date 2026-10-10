#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/worker-pin-gate.sh: what ~/.claude/worker-model may hold — no model, effort or light row the
# table does not list, written by Edit/Write or by a shell write alike — and the chat pins written
# only through `chat-pin`. A pin move itself passes, here and through worker_model_pin_account.
# The shell door's parse is test_worker_pin_gate_shell.sh and _runtime.sh.
. "$(dirname "$0")/worker_pin_gate_harness.sh" || exit 1

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
