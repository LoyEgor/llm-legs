#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/instruction_gate_harness.sh"
profile_link
docs_link

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
assert_contains "$(fmt instruction_standing_rule)" "$ctx"
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
undo_from() { printf '%s' "$1" | sed -n 's/.*puts them back: \(.*\) Egor.s standing rule.*/\1/p'; }
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

echo "== tripwire: a check with no baseline is an event, journaled, and it builds one"
rm -f "$INSTRUCTION_WATCH_STATE"/*.tsv
assert_contains "BASELINE-MISSING" "$(watch check sid-c | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_eq "baseline-missing" "$(tail -n 1 "$INSTRUCTION_WATCH_STATE/events.jsonl" | jq -r .kind)"
assert [ -s "$INSTRUCTION_WATCH_STATE/session-sid-c.tsv" ]
assert_eq "" "$(watch check sid-c)"
# An emptied baseline is the same event, and the newest baseline another session left stands in
# for it: what changed since is reported rather than absorbed.
watch baseline sid-other >/dev/null
: > "$INSTRUCTION_WATCH_STATE/session-sid-c.tsv"
printf 'changed while the baseline was gone\n' >> "$HOME/.claude/docs/review-tiers.md"
out=$(watch check sid-c | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "BASELINE-MISSING" "$out"
assert_contains "CHANGED $HOME/.claude/docs/review-tiers.md" "$out"
case "$out" in *REVERTED*) fail "a comparison against another session's baseline put bytes back" ;; esac
assert_eq "" "$(watch check sid-c)"

echo "== tripwire: a new session reports what changed while no session was watching"
watch baseline sid-before >/dev/null
printf 'changed between sessions\n' >> "$HOME/.claude/docs/review-tiers.md"
out=$(watch baseline sid-after | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED-BETWEEN-SESSIONS $HOME/.claude/docs/review-tiers.md" "$out"
assert_eq "changed-between-sessions" "$(tail -n 1 "$INSTRUCTION_WATCH_STATE/events.jsonl" | jq -r .kind)"
assert_eq "" "$(watch check sid-after)"
# A resumed session compares against its own baseline.
printf 'changed across a compaction\n' >> "$HOME/.claude/docs/review-tiers.md"
assert_contains "CHANGED-BETWEEN-SESSIONS" "$(watch baseline sid-after | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_eq "" "$(watch baseline sid-after)"

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

echo "== tripwire: a hostile file name never reaches the command that wakes Hammerspoon"
alert_log_stub
nasty="$HOME/.claude/agents/quote\"and\\slash.md"
printf 'smuggled\n' > "$nasty"
watch check sid-d >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$ALERT_LOG" ] && break; sleep 0.2; done
assert [ -s "$ALERT_LOG" ]
poke=$(cat "$ALERT_LOG")
assert_contains 'pcall(require, "instruction-watch")' "$poke"
assert_contains 'm.pump()' "$poke"
case "$poke" in *quote*|*slash*|*.md*) fail "a watched file name reached the Hammerspoon command" ;; esac
rm "$nasty"
watch baseline sid-d >/dev/null

echo "== tripwire: one alert per change, whichever session notices it first"
# This hook runs in every live session at once — the chat, its workers, every other window — and
# each keeps its own baseline, so one edit used to flash Egor's screen once per session that
# happened to run a tool call after it.
: > "$ALERT_LOG"
alerts() { wc -l <"$ALERT_LOG" | tr -d '[:space:]'; }
# The alert is fired detached so a wedged Hammerspoon cannot hold the hook, so a count is only
# trustworthy after it has had time to land — and a count that must STAY put needs the same wait.
alert_settle() { local n=$1 _; for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(alerts)" -ge "$n" ] && break; sleep 0.2; done; sleep 0.4; }
watch baseline alert-one >/dev/null
watch baseline alert-two >/dev/null
printf 'one change, two sessions\n' > "$HOME/.claude/docs/review-tiers.md"
watch check alert-one >/dev/null
alert_settle 1
assert_eq 1 "$(alerts)"
# The second session still tells its own model — the context is per session — and says nothing to
# Egor, who has already been shown this change.
ctx=$(watch check alert-two | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED" "$ctx"
alert_settle 1
assert_eq 1 "$(alerts)"
# A DIFFERENT change to the same file is news again.
printf 'a second change\n' > "$HOME/.claude/docs/review-tiers.md"
watch check alert-one >/dev/null
alert_settle 2
assert_eq 2 "$(alerts)"
# And the same bytes reported later by a session that had not caught up are not: the marker is
# named for the file and what it now holds, never for a delta each baseline measures differently.
ctx=$(watch check alert-two | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED" "$ctx"
alert_settle 2
assert_eq 2 "$(alerts)"
printf 'tier doc\n' > "$HOME/.claude/docs/review-tiers.md"
watch baseline alert-one >/dev/null
watch baseline alert-two >/dev/null

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
undo=$(printf '%s' "$ctx" | sed -n 's/.*puts them back: \(.*\) Egor.s standing rule.*/\1/p')
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
undo=$(printf '%s' "$ctx_b" | sed -n 's/.*puts them back: \(.*\) Egor.s standing rule.*/\1/p')
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
undo=$(printf '%s' "$ctx" | sed -n 's/.*puts them back: \(.*\) Egor.s standing rule.*/\1/p')
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

echo "OK ($asserts assertions)"
