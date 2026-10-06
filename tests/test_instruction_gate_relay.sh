#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/instruction_gate_harness.sh"
profile_link
docs_link
alert_log_stub

echo "== relay worker: an instruction file is the orchestrator's to edit, never a worker's"
# Egor's rule: these files are edited by the model he negotiated with, after that model's audit —
# a worker proposes. The audit-then-retry protocol is honour-based, and a relay worker walked
# through it twice in one day by re-reading the file and asking again, with nobody looking for the
# cuts that would pay for the growth. So a worker is refused outright: exit 2, one message, no
# stamp to spend.
REFUSAL="Instruction files are the orchestrator's to edit (Egor's rule): do not write"
relay_rc=0
relay_err=''
relay_edit() { # path [env-assignment]
  relay_err=$(jq -cn --arg p "$1" --arg n "$big" \
    '{tool_name:"Edit",cwd:"/tmp",session_id:"relay-one",tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
    | env "${2:-CLAUDEB_WORKER=1}" bash "$BLOAT" 2>&1 >/dev/null)
  relay_rc=$?
}
for guarded in "$CLAUDE_MD" "$REAL_MD" "$HOME/.claude/agents/codex-worker.md" \
               "$HOME/.claude/commands/worker.md" "$HOME/.claude/docs/review-tiers.md" \
               "$HOME/.claude/skills/demo/SKILL.md"; do
  relay_edit "$guarded"
  assert_eq 2 "$relay_rc"
  assert_contains "$REFUSAL $guarded;" "$relay_err"
  assert_contains "under MD-PROPOSAL in your RETURN" "$relay_err"
done
# Either marker answers: `claudeb` sets the first for every headless run, `worker-run` exports the
# second into the run and into nothing else.
relay_edit "$CLAUDE_MD" "GROK_WORKER=1"
assert_eq 2 "$relay_rc"
relay_edit "$CLAUDE_MD" "CLAUDE_LAUNCHER_SESSION=some-chat"
assert_eq 2 "$relay_rc"
# Asking twice is not an audit, and there is no stamp here to spend.
relay_edit "$CLAUDE_MD"; assert_eq 2 "$relay_rc"
relay_edit "$CLAUDE_MD"; assert_eq 2 "$relay_rc"

echo "== relay worker: ordinary repository markdown and the memory files are no part of that rule"
# The rule is about what every later session re-reads. A repository's own contract docs are read
# on demand, and appending a pointer line to a project's memory index is the workflow every agent
# is told to follow: refusing those stops a worker doing the job it was sent for.
mkdir -p "$WORK/project/docs" "$HOME/.claude-profiles/com/projects/thing/memory"
printf 'a contract doc\n' > "$WORK/project/docs/DIAGNOSTICS.md"
printf 'a memory\n' > "$HOME/.claude-profiles/com/projects/thing/memory/note.md"
printf 'index\n' > "$HOME/.claude-profiles/com/projects/thing/memory/MEMORY.md"
for open_path in "$WORK/project/docs/DIAGNOSTICS.md" \
                 "$HOME/.claude-profiles/com/projects/thing/memory/note.md" \
                 "$HOME/.claude-profiles/com/projects/thing/memory/MEMORY.md" \
                 "$WORK/unrelated.py"; do
  relay_edit "$open_path"
  assert_eq 0 "$relay_rc"
  assert_eq "" "$relay_err"
done

echo "== relay worker: the chat Egor negotiated with keeps the audit protocol"
# Nothing about the ordinary session moved: it is still priced, still denied on stdout, and still
# offered the retry the audit earns.
relay_edit "$CLAUDE_MD" "INSTRUCTION_BLOAT_GATE_STAMPS=$BLOAT_STAMPS"
assert_eq 0 "$relay_rc"
assert_eq "" "$relay_err"
assert_eq deny "$(bloat_decision "$HOME/.claude/agents/codex-worker.md")"

echo "== relay worker: the shell door refuses the same writes, with no retry to spend"
relay_gate() { # command
  relay_err=$(bash_payload "$1" | env CLAUDEB_WORKER=1 bash "$WRITE_GATE" 2>&1 >/dev/null)
  relay_rc=$?
}
relay_gate "echo more >> $CLAUDE_MD"
assert_eq 2 "$relay_rc"
assert_contains "$REFUSAL $CLAUDE_MD;" "$relay_err"
assert_contains "under MD-PROPOSAL in your RETURN" "$relay_err"
relay_gate "printf x > $HOME/.claude/docs/review-tiers.md"
assert_eq 2 "$relay_rc"
# The one-shot retry belongs to the chat Egor negotiated with, in this turn or the next.
relay_gate "echo more >> $CLAUDE_MD"; assert_eq 2 "$relay_rc"
append_write_user
relay_gate "echo more >> $CLAUDE_MD"; assert_eq 2 "$relay_rc"
# And a destination no gate speaks for is as silent for a worker as for anyone.
relay_gate "echo hi > $WORK/scratch/notes.txt"
assert_eq 0 "$relay_rc"
assert_eq "" "$relay_err"

echo "== tripwire: inside a relay a worker's growth is put back with Egor in the room"
# The gates ahead of this one read a command's SHAPE and never its result, so the bytes are this
# hook's. A worker's write is refused whether or not the span stands, which is why the condition
# here is the relay and not only the span.
relay_check() { # sid tool key value [transcript]
  arm_span "$1" "${5:-$NOSPAN_T}"
  tool_payload PostToolUse "$1" "$2" "$3" "$4" "${5:-$NOSPAN_T}" \
    | env CLAUDEB_WORKER=1 bash "$WATCH" check | jq -r '.hookSpecificOutput.additionalContext // ""'
}
relay_pre() { CLAUDEB_WORKER=1 pre_call "$1" "$2" "$3" "$4" "${5:-$NOSPAN_T}"; }
printf 'tier doc\n' > "$DOC"
span_base sid-relay-revert >/dev/null
relay_pre sid-relay-revert Bash command "sed -i '' -e 's/x/y/' $DOC"
printf 'a line no worker was asked for\n' >> "$DOC"
ctx=$(relay_check sid-relay-revert Bash command "sed -i '' -e 's/x/y/' $DOC")
assert_contains "REVERTED" "$ctx"
assert_contains "orchestrator's to edit" "$ctx"
assert_contains "under MD-PROPOSAL in your RETURN" "$ctx"
assert_eq "tier doc" "$(cat "$DOC")"
# A shrink is not growth, here as much as inside the span.
span_base sid-relay-shrink >/dev/null
relay_pre sid-relay-shrink Bash command "sed -i '' -e 's/.*/tiny/' $DOC"
printf 'tiny\n' > "$DOC"
ctx=$(relay_check sid-relay-shrink Bash command "sed -i '' -e 's/.*/tiny/' $DOC")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "a relay worker's shrink was put back" ;; esac
assert_eq "tiny" "$(cat "$DOC")"
printf 'tier doc\n' > "$DOC"
# settings.json is watched and no gate speaks for it, so no worker rule reaches it either.
span_base sid-relay-settings >/dev/null
relay_pre sid-relay-settings Bash command "echo x > $HOME/.claude/settings.json"
printf '{"model":"opus","hooks":{"Stop":[],"PostToolUse":[]}}\n' > "$HOME/.claude/settings.json"
ctx=$(relay_check sid-relay-settings Bash command "echo x > $HOME/.claude/settings.json")
assert_contains "settings.json" "$ctx"
case "$ctx" in *REVERTED*) fail "a relay rule reached settings.json, which no gate speaks for" ;; esac
# A span of Egor's is not permission for a WORKER to grow the file: the rollback is the same, and
# the wording it comes back with is the worker's protocol. Told instead to leave the addition for
# his next turn, the worker is handed an instruction meant for a human — it has no next turn, and
# the proposal Egor would price never reaches him.
printf 'tier doc\n' > "$DOC"
span_base sid-relay-in-span >/dev/null
relay_pre sid-relay-in-span Bash command "sed -i '' -e 's/x/y/' $DOC" "$SPAN_T"
printf 'a line no worker was asked for\n' >> "$DOC"
ctx=$(relay_check sid-relay-in-span Bash command "sed -i '' -e 's/x/y/' $DOC" "$SPAN_T")
assert_contains "REVERTED" "$ctx"
assert_contains "orchestrator's to edit" "$ctx"
assert_contains "under MD-PROPOSAL in your RETURN" "$ctx"
case "$ctx" in *'leave it for his next turn'*) fail "a relay worker in the span was answered as if it were Egor" ;; esac
assert_eq "tier doc" "$(cat "$DOC")"

# A headless worker can start with a PATH that misses Homebrew, and stock /bin/bash is 3.2:
# there `local -A` is not an error but a silent downgrade to an indexed array, where every
# path key evaluates as arithmetic to index 0 and the comparison reads the wrong row.
echo "== both hooks run under stock /bin/bash 3.2"
b32() { WATCH_BASH=/bin/bash watch_sid "$@"; }
b32 sid-32 baseline >/dev/null
assert_eq "" "$(b32 sid-32 check)"
printf 'moved under 3.2\n' > "$REAL_MD"
assert_contains "CHANGED" "$(b32 sid-32 check | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_eq "" "$(bash_payload "$ANY_CALL" | /bin/bash "$WRITE_GATE")"
assert_contains 'permissionDecision":"deny' \
  "$(bash_payload "echo x > $CLAUDE_MD" | /bin/bash "$WRITE_GATE")"
assert_contains 'permissionDecision":"deny' \
  "$(bash_payload "python3 -c \"open('$CLAUDE_MD','w').write('x')\"" | /bin/bash "$WRITE_GATE")"
printf "open('%s','w').write('x')\n" "$CLAUDE_MD" > "$WORK/write32.py"
assert_contains 'permissionDecision":"deny' \
  "$(bash_payload "cd /tmp && python3 $WORK/write32.py" | /bin/bash "$WRITE_GATE")"
assert_contains 'permissionDecision":"deny' \
  "$(jq -cn --arg p "$CLAUDE_MD" --arg n "$big" \
       '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
     | INSTRUCTION_BLOAT_GATE_STAMPS="$HOME/.cache/bloat-32" /bin/bash "$BLOAT")"

echo "== tripwire: by default the report reaches Egor and the log, not every unrelated chat"
unset INSTRUCTION_WATCH_CHAT
alert_rec_stub
alert_said() {
  local i=0
  while [ $i -lt 40 ]; do
    [ -s "$ALERT_REC" ] && { cat "$ALERT_REC"; return 0; }
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}
printf 'tier doc of the quiet case\n' > "$DOC"
span_base sid-quiet >/dev/null
span_base sid-quiet-twin >/dev/null
span_base sid-quiet-race >/dev/null
: > "$INSTRUCTION_WATCH_LOG"
rm -f "$ALERT_REC"
kept_before=$(find "$INSTRUCTION_WATCH_STATE/reverts" -type f 2>/dev/null | wc -l)
printf 'written by somebody else entirely\n' > "$DOC"
assert_eq "" "$(raw_check sid-quiet Bash command "$ANY_CALL" "$NOSPAN_T")"
assert_contains "CHANGED" "$(cat "$INSTRUCTION_WATCH_LOG")"
assert_contains "instruction-watch" "$(alert_said)"
assert_contains "review-tiers.md" "$(tail -1 "$INSTRUCTION_WATCH_STATE/events.jsonl" | jq -r '.files[0]')"
kept_after=$(find "$INSTRUCTION_WATCH_STATE/reverts" -type f | wc -l)
assert [ "$kept_after" -gt "$kept_before" ]
assert_eq "" "$(raw_check sid-quiet Bash command "$ANY_CALL" "$NOSPAN_T")"
# A second session reporting the same version shares the first one's copy.
: > "$INSTRUCTION_WATCH_LOG"
raw_check sid-quiet-twin Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_contains "CHANGED" "$(cat "$INSTRUCTION_WATCH_LOG")"
assert_eq "$kept_after" "$(find "$INSTRUCTION_WATCH_STATE/reverts" -type f | wc -l)"
# The week's prune deleting that shared copy between its test and its touch never leaves it empty.
mkdir -p "$WORK/prune-race"
printf '#!/bin/sh\nfor a; do last=$a; done\ncase "$last" in */reverts/*) rm -f "$last" ;; esac\nexec /usr/bin/touch "$@"\n' \
  > "$WORK/prune-race/touch"
chmod +x "$WORK/prune-race/touch"
PATH="$WORK/prune-race:$PATH" raw_check sid-quiet-race Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_eq 0 "$(find "$INSTRUCTION_WATCH_STATE/reverts" -type f -empty | wc -l | tr -d ' ')"
assert_eq "$kept_after" "$(find "$INSTRUCTION_WATCH_STATE/reverts" -type f | wc -l)"

echo "== tripwire: a session whose write was put back is still told"
printf 'tier doc\n' > "$DOC"
span_base sid-quiet-revert >/dev/null
pre_call sid-quiet-revert Bash command "$grow_cmd" "$SPAN_T"
printf 'a line no human asked for\n' >> "$DOC"
ctx=$(raw_check sid-quiet-revert Bash command "$grow_cmd" "$SPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "REVERTED" "$ctx"
assert_eq "tier doc" "$(cat "$DOC")"

echo "== tripwire: off silences the chat channel entirely"
export INSTRUCTION_WATCH_CHAT=off
span_base sid-off >/dev/null
pre_call sid-off Bash command "$grow_cmd" "$SPAN_T"
printf 'another line no human asked for\n' >> "$DOC"
assert_eq "" "$(raw_check sid-off Bash command "$grow_cmd" "$SPAN_T")"
assert_eq "tier doc" "$(cat "$DOC")"
export INSTRUCTION_WATCH_CHAT=all

chat_name_stub

echo "== journal: one durable record per change, machine-wide, with what a menu needs"
rm -f "$J"
rm -rf "$INSTRUCTION_WATCH_STATE/alerts"
printf 'tier doc\n' > "$DOC"
span_base sid-j1 >/dev/null
span_base sid-j2 >/dev/null
journal_before=$(wc -c < "$DOC")
printf 'a tier line nobody approved\n' > "$DOC"
journal_delta=$(( $(wc -c < "$DOC") - journal_before ))
raw_check sid-j1 Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
raw_check sid-j2 Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_eq 1 "$(grep -c . "$J")"
rec=$(tail -1 "$J")
assert_contains "CHANGED" "$(printf '%s' "$rec" | jq -r '.summary')"
assert_contains "review-tiers.md" "$(printf '%s' "$rec" | jq -r '.files[0]')"
assert_contains "cp " "$(printf '%s' "$rec" | jq -r '.restores[0] // ""')"
assert [ -n "$(printf '%s' "$rec" | jq -r '.id')" ]
# No call of either session wrote these bytes: the record names the chat that noticed them as the
# observer, never as the writer, and carries no chat name that would blame it.
assert_eq "" "$(printf '%s' "$rec" | jq -r '.sid')"
assert_contains "sid-j" "$(printf '%s' "$rec" | jq -r '.observer')"
assert_eq null "$(printf '%s' "$rec" | jq '.chat')"
assert_eq attempted "$(printf '%s' "$rec" | jq -r '.sent')"
assert_eq true "$(printf '%s' "$rec" | jq '(.bytes | type == "array" and all(.[]; type == "number" and . == floor)) and ((.bytes | length) == (.files | length))')"
assert_eq "$journal_delta" "$(printf '%s' "$rec" | jq '.bytes[0]')"
span_base sid-jw >/dev/null
pre_call sid-jw Bash command "$ANY_CALL" "$NOSPAN_T"
printf 'a tier line this call wrote\n' >> "$DOC"
raw_check sid-jw Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
rec=$(tail -1 "$J")
assert_eq this-call "$(printf '%s' "$rec" | jq -r '.writer')"
assert_eq sid-jw "$(printf '%s' "$rec" | jq -r '.sid')"
assert_eq 'Stub chat (abcdef12)' "$(printf '%s' "$rec" | jq -r '.chat')"
assert_eq null "$(printf '%s' "$rec" | jq '.observer')"
printf '#!/bin/sh\nexit 1\n' > "$HOME/.local/bin/chat-name"

echo "== in flight: bytes no mark accounts for are reported, never put back"
printf 'tier doc\n' > "$DOC"
span_base sid-nomark >/dev/null
rm -f "$INSTRUCTION_WATCH_STATE"/inflight/*
printf 'a line nobody marked\n' >> "$DOC"
ctx=$(span_check sid-nomark Bash command "$grow_cmd" "$SPAN_T")
assert_contains "CHANGED $DOC" "$ctx"
assert_eq "" "$(printf '%s' "$ctx" | grep -o REVERTED)"
assert_contains "a line nobody marked" "$(cat "$DOC")"
assert_eq unknown "$(tail -1 "$J" | jq -r .writer)"

echo "== in flight: a mark another call of the session left is not this call's window"
printf 'tier doc\n' > "$DOC"
span_base sid-idm >/dev/null
pre_call sid-idm Bash command "$grow_cmd" "$SPAN_T"
printf 'a line under a parallel call mark\n' >> "$DOC"
ctx=$(tool_payload PostToolUse sid-idm Bash command "$grow_cmd" "$SPAN_T" \
      | jq -c '.tool_use_id = "tu-parallel"' | bash "$WATCH" check \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED $DOC" "$ctx"
assert_eq "" "$(printf '%s' "$ctx" | grep -o REVERTED)"
assert [ -s "$INSTRUCTION_WATCH_STATE/inflight/sid-idm@tu-sid-idm" ]

echo "== in flight: a parallel call of the session, denied, leaves this call's window standing"
printf 'tier doc\n' > "$DOC"
span_base sid-par >/dev/null
pre_call sid-par Bash command "$grow_cmd" "$SPAN_T"
out=$(tool_payload PreToolUse sid-par Bash command "printf x >> $CLAUDE_MD" "$SPAN_T" \
      | jq -c '.tool_use_id = "tu-par-denied"' | bash "$WRITE_GATE" 2>/dev/null)
assert_contains '"deny"' "$out"
assert [ -s "$INSTRUCTION_WATCH_STATE/inflight/sid-par@tu-sid-par" ]
printf 'a line beside a denied parallel call\n' >> "$DOC"
ctx=$(span_check sid-par Bash command "$grow_cmd" "$SPAN_T")
assert_contains "REVERTED" "$ctx"
assert_eq this-call "$(tail -1 "$J" | jq -r .writer)"
assert_eq "tier doc" "$(cat "$DOC")"

echo "== in flight: two sessions' windows over one write name both chats and put nothing back"
cat > "$HOME/.local/bin/chat-name" <<'STUB'
#!/bin/sh
printf 'Chat of %s\n' "$1"
STUB
printf 'tier doc\n' > "$DOC"
span_base sid-amb-a >/dev/null
pre_call sid-amb-a Bash command "$grow_cmd" "$SPAN_T"
tool_payload PreToolUse sid-amb-b Bash command "$ANY_CALL" "$NOSPAN_T" | bash "$WRITE_GATE" >/dev/null
assert [ -s "$INSTRUCTION_WATCH_STATE/inflight/sid-amb-b@tu-sid-amb-b" ]
printf 'a line either chat could have written\n' >> "$DOC"
ctx=$(span_check sid-amb-a Bash command "$grow_cmd" "$SPAN_T")
assert_contains "CHANGED $DOC" "$ctx"
assert_eq "" "$(printf '%s' "$ctx" | grep -o REVERTED)"
assert_contains "either chat" "$(cat "$DOC")"
rec=$(tail -1 "$J")
assert_eq ambiguous "$(printf '%s' "$rec" | jq -r .writer)"
assert_eq "sid-amb-a sid-amb-b" "$(printf '%s' "$rec" | jq -r '[.candidates[].sid] | sort | join(" ")')"
assert_eq "Chat of sid-amb-a|Chat of sid-amb-b" \
  "$(printf '%s' "$rec" | jq -r '[.candidates[].chat] | sort | join("|")')"

echo "== in flight: two files under the same two windows name each chat once"
amb_agent="$HOME/.claude/agents/codex-worker.md"
printf 'tier doc\n' > "$DOC"
printf 'agent doc\n' > "$amb_agent"
span_base sid-amb-a >/dev/null
pre_call sid-amb-a Bash command "$grow_cmd" "$SPAN_T"
tool_payload PreToolUse sid-amb-b Bash command "$ANY_CALL" "$NOSPAN_T" | bash "$WRITE_GATE" >/dev/null
printf 'a line in the doc\n' >> "$DOC"
printf 'a line in the agent\n' >> "$amb_agent"
span_check sid-amb-a Bash command "$grow_cmd" "$SPAN_T" >/dev/null
rec=$(tail -1 "$J")
assert_eq 2 "$(printf '%s' "$rec" | jq '.files | length')"
assert_eq "sid-amb-a sid-amb-b" "$(printf '%s' "$rec" | jq -r '[.candidates[].sid] | sort | join(" ")')"
printf 'agent doc\n' > "$amb_agent"
printf '#!/bin/sh\nexit 1\n' > "$HOME/.local/bin/chat-name"
rm -f "$INSTRUCTION_WATCH_STATE"/inflight/*

echo "== in flight: a denied call leaves no window behind"
arm_span sid-deny "$SPAN_T"
out=$(tool_payload PreToolUse sid-deny Bash command "printf x >> $CLAUDE_MD" "$SPAN_T" \
      | bash "$WRITE_GATE" 2>/dev/null)
assert_contains '"deny"' "$out"
assert_eq 0 "$(find "$INSTRUCTION_WATCH_STATE/inflight" -name 'sid-deny*' | wc -l | tr -d ' ')"
out=$(tool_payload PreToolUse sid-deny Edit file_path "$DOC" "$SPAN_T" \
      | jq -c --arg n "$big" '.tool_input += {old_string:"tier", new_string:$n}' | bash "$BLOAT" 2>/dev/null)
assert_contains '"deny"' "$out"
assert_eq 0 "$(find "$INSTRUCTION_WATCH_STATE/inflight" -name 'sid-deny*' | wc -l | tr -d ' ')"
printf 'tier doc\n' > "$DOC"
span_base sid-deny >/dev/null
printf 'a line after the denial\n' >> "$DOC"
ctx=$(span_check sid-deny Edit file_path "$DOC" "$SPAN_T")
assert_contains "CHANGED $DOC" "$ctx"
assert_eq "" "$(printf '%s' "$ctx" | grep -o REVERTED)"

echo "== in flight: a mark older than an hour is a dead call, swept without a word"
printf 'tier doc\n' > "$DOC"
span_base sid-live >/dev/null
pre_call sid-live Bash command "$grow_cmd" "$SPAN_T"
printf '%s tu-dead Bash - /tmp\n' "$(( $(date +%s) - 7200 ))" > "$INSTRUCTION_WATCH_STATE/inflight/sid-dead@tu-dead"
printf 'a line the live call wrote\n' >> "$DOC"
assert_contains "REVERTED" "$(span_check sid-live Bash command "$grow_cmd" "$SPAN_T")"
assert [ ! -e "$INSTRUCTION_WATCH_STATE/inflight/sid-dead@tu-dead" ]
assert_eq this-call "$(tail -1 "$J" | jq -r .writer)"
assert_eq 0 "$(grep -c sid-dead "$J")"
printf 'tier doc\n' > "$DOC"

echo "== in flight: this call's own mark counts however long the call ran"
span_base sid-long >/dev/null
pre_call sid-long Bash command "$grow_cmd" "$SPAN_T"
long_mark="$INSTRUCTION_WATCH_STATE/inflight/sid-long@tu-sid-long"
read -r _ long_rest <"$long_mark"
printf '%s %s\n' "$(( $(date +%s) - 7200 ))" "$long_rest" > "$long_mark"
printf 'a line the long call wrote\n' >> "$DOC"
assert_contains "REVERTED" "$(span_check sid-long Bash command "$grow_cmd" "$SPAN_T")"
assert [ ! -e "$long_mark" ]
assert_eq this-call "$(tail -1 "$J" | jq -r .writer)"
printf 'tier doc\n' > "$DOC"

echo "== in flight: a call older than an hour keeps another session's equally old mark as a window"
span_base sid-long >/dev/null
pre_call sid-long Bash command "$grow_cmd" "$SPAN_T"
read -r _ long_rest <"$long_mark"
printf '%s %s\n' "$(( $(date +%s) - 7200 ))" "$long_rest" > "$long_mark"
old_mark="$INSTRUCTION_WATCH_STATE/inflight/sid-old@tu-old"
printf '%s tu-old Bash - /tmp\n' "$(( $(date +%s) - 7300 ))" > "$old_mark"
printf 'a line either long call could have written\n' >> "$DOC"
assert_eq "" "$(span_check sid-long Bash command "$grow_cmd" "$SPAN_T" | grep -o REVERTED)"
assert [ -e "$old_mark" ]
assert_eq ambiguous "$(tail -1 "$J" | jq -r .writer)"
rm -f "$INSTRUCTION_WATCH_STATE"/inflight/*
printf 'tier doc\n' > "$DOC"

echo "== journal: the bound trims what Hammerspoon receipted, and says so when it must drop more"
TRIM_STATE="$WORK/trim"
trim_plant() { # unreceipted receipted
  rm -rf "$TRIM_STATE"
  mkdir -p "$TRIM_STATE/receipts"
  { [ "$2" = 0 ] || seq 1 "$2" | awk '{printf "{\"id\":\"r%d\",\"kind\":\"change\",\"summary\":\"r\"}\n", $1}'
    seq 1 "$1" | awk '{printf "{\"id\":\"u%d\",\"kind\":\"change\",\"summary\":\"u\"}\n", $1}'
  } | grep . > "$TRIM_STATE/events.jsonl"
  [ "$2" = 0 ] || (cd "$TRIM_STATE/receipts" && seq 1 "$2" | sed 's/^/r/' | xargs touch)
}
trim_append() {
  INSTRUCTION_WATCH_STATE="$TRIM_STATE" INSTRUCTION_WATCH_JOURNAL_MAX=200 \
    share_call 'instruction_journal_append "$2"' "{\"id\":\"new$1\",\"kind\":\"change\",\"summary\":\"n\"}"
}
TJ="$TRIM_STATE/events.jsonl"
trim_plant 249 0
trim_append 1
assert_eq 250 "$(grep -c . "$TJ")"
assert_eq 0 "$(grep -c '"kind":"dropped"' "$TJ")"
trim_plant 249 151
trim_append 1
assert_eq 250 "$(grep -c . "$TJ")"
assert_eq 0 "$(grep -c '"id":"r' "$TJ")"
assert_eq 0 "$(grep -c '"kind":"dropped"' "$TJ")"
trim_plant 99 301
trim_append 1
assert_eq 200 "$(grep -c . "$TJ")"
assert_eq 100 "$(grep -c '"id":"r' "$TJ")"
assert_eq '"r202"' "$(grep '"id":"r' "$TJ" | head -1 | jq .id)"
trim_plant 449 0
trim_append 1
assert_eq 400 "$(grep -c . "$TJ")"
assert_eq dropped "$(tail -1 "$TJ" | jq -r .kind)"
assert_eq 51 "$(tail -1 "$TJ" | jq -r .count)"
assert_eq '"u52"' "$(head -1 "$TJ" | jq .id)"
trim_append 2
assert_eq 400 "$(grep -c . "$TJ")"
assert_eq 1 "$(grep -c '"kind":"dropped"' "$TJ")"
assert_eq 52 "$(tail -1 "$TJ" | jq -r .count)"

echo "== baseline sweep: a quiet session that just ran a check is alive, a silent one goes"
span_base sid-alive >/dev/null
span_base sid-gone >/dev/null
touch -t 202001010000 "$INSTRUCTION_WATCH_STATE/session-sid-alive.tsv" \
  "$INSTRUCTION_WATCH_STATE/session-sid-gone.tsv"
assert_eq "" "$(raw_check sid-alive Bash command "$ANY_CALL" "$NOSPAN_T")"
span_base sid-sweeper >/dev/null
assert [ -e "$INSTRUCTION_WATCH_STATE/session-sid-alive.tsv" ]
assert [ ! -e "$INSTRUCTION_WATCH_STATE/session-sid-gone.tsv" ]

echo "== journal: a delivery that could not even be attempted says so"
saved_alert=$INSTRUCTION_WATCH_ALERT
INSTRUCTION_WATCH_ALERT="$WORK/no-such-hammerspoon"
export INSTRUCTION_WATCH_ALERT
printf 'a second tier line nobody approved\n' > "$DOC"
raw_check sid-j1 Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_eq unsent "$(tail -1 "$J" | jq -r '.sent')"
assert_eq false "$(tail -1 "$J" | jq 'has("chat")')"
INSTRUCTION_WATCH_ALERT=$saved_alert
export INSTRUCTION_WATCH_ALERT

echo "== journal: bounded, so a cache cannot grow for the life of the machine"
INSTRUCTION_WATCH_JOURNAL_MAX=2
export INSTRUCTION_WATCH_JOURNAL_MAX
i=0
while [ $i -lt 6 ]; do
  printf 'tier line %s\n' "$i" > "$DOC"
  raw_check sid-j1 Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
  i=$((i + 1))
done
assert [ "$(grep -c . "$J")" -le 4 ]
assert_contains "tier line 5" "$(tail -1 "$J" | jq -r '.summary')$(cat "$DOC")"
unset INSTRUCTION_WATCH_JOURNAL_MAX

echo "OK ($asserts assertions)"
