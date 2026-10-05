#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/instruction_gate_harness.sh"
profile_link
docs_link
alert_rec_stub
chat_name_stub

echo "== coverage: the ranking already on disk brings the dearest project files into the set"
RATES="$WORK/read-rates.json"
mkdir -p "$PROJ"
printf 'project rules\n' > "$PROJ/CLAUDE.md"
jq -n --arg p "$PROJ/CLAUDE.md" --arg g "$REAL_MD" --arg m "$HOME/.claude/projects/x/memory/MEMORY.md" \
  '{paths:{entries:{($g):{monthly:{reads:9000}},($p):{monthly:{reads:5000}},
                    ($m):{monthly:{reads:8000}}}}}' > "$RATES"
TOKENMAP_RATES="$RATES"
export TOKENMAP_RATES
span_base sid-rank >/dev/null
assert_contains "$PROJ/CLAUDE.md" "$(cat "$RANKED")"
assert_eq 1 "$(grep -c '^/' "$RANKED")"
printf 'project rules and a line nobody approved\n' > "$PROJ/CLAUDE.md"
out=$(raw_check sid-rank Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "$PROJ/CLAUDE.md" "$out"
assert_contains "$PROJ/CLAUDE.md" "$(tail -1 "$J" | jq -r '.files[0]')"
echo "== coverage: a file the ranking brings in is not a file somebody added"
rm -f "$RANKED"
unset TOKENMAP_RATES
span_base sid-grow >/dev/null
TOKENMAP_RATES="$RATES"
export TOKENMAP_RATES
span_base sid-other >/dev/null
assert_contains "$PROJ/CLAUDE.md" "$(cat "$RANKED")"
out=$(raw_check sid-grow Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
case "$out" in *ADDED*) fail "the watch set growing was reported as a file somebody added: $out" ;; esac
printf 'project rules edited\n' > "$PROJ/CLAUDE.md"
out=$(raw_check sid-grow Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED" "$out"
assert_contains "$PROJ/CLAUDE.md" "$out"

echo "== coverage: a worktree's copy is not a second instruction file"
mkdir -p "$PROJ/.claude/worktrees/wt"
printf 'worktree copy\n' > "$PROJ/.claude/worktrees/wt/CLAUDE.md"
jq -n --arg p "$PROJ/CLAUDE.md" --arg w "$PROJ/.claude/worktrees/wt/CLAUDE.md" \
  '{paths:{entries:{($w):{monthly:{reads:99000}},($p):{monthly:{reads:5000}}}}}' > "$RATES"
rm -f "$RANKED"
span_base sid-wt >/dev/null
case "$(cat "$RANKED")" in
  *worktrees*) fail "a worktree copy took a slot and would report its removal as a deletion" ;;
esac
assert_contains "$PROJ/CLAUDE.md" "$(cat "$RANKED")"

echo "== coverage: a rules change re-cuts a cache the index has not moved under"
printf '#0\n%s\n' "$PROJ/.claude/worktrees/wt/CLAUDE.md" > "$RANKED"
span_base sid-ver >/dev/null
assert_eq "#1" "$(head -1 "$RANKED")"
case "$(cat "$RANKED")" in *worktrees*) fail "a stale cache outlived the rules that cut it" ;; esac
unset TOKENMAP_RATES

echo "== coverage: a file the ranking DROPS is not a file somebody deleted"
TOKENMAP_RATES="$RATES"
export TOKENMAP_RATES
mkdir -p "$WORK/proj-b"
printf 'b rules\n' > "$WORK/proj-b/CLAUDE.md"
jq -n --arg p "$PROJ/CLAUDE.md" --arg q "$WORK/proj-b/CLAUDE.md" \
  '{paths:{entries:{($p):{monthly:{reads:5000}},($q):{monthly:{reads:9000}}}}}' > "$RATES"
rm -f "$RANKED"
span_base sid-drop >/dev/null
assert_contains "proj-b" "$(cat "$RANKED")"
jq -n --arg p "$PROJ/CLAUDE.md" '{paths:{entries:{($p):{monthly:{reads:5000}}}}}' > "$RATES"
rm -f "$RANKED"
span_base sid-recut >/dev/null
case "$(cat "$RANKED")" in *proj-b*) fail "the re-cut cache still names the dropped project" ;; esac
out=$(raw_check sid-drop Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
case "$out" in *DELETED*) fail "a file the ranking dropped was reported as deleted: $out" ;; esac
# The ranked cache is a file any session can rewrite, so dropping a path from it does not stop the
# watch on a file this session already watches.
printf 'b rules edited after demotion\n' > "$WORK/proj-b/CLAUDE.md"
out=$(raw_check sid-drop Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED $WORK/proj-b/CLAUDE.md" "$out"
rm -f "$PROJ/CLAUDE.md"
out=$(raw_check sid-drop Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "DELETED" "$out"
assert_contains "$PROJ/CLAUDE.md" "$out"
printf 'project rules\n' > "$PROJ/CLAUDE.md"
unset TOKENMAP_RATES


echo "== tripwire: a marked first file does not drop the rest of a multi-file check"
AGENTF="$HOME/.claude/agents/codex-worker.md"
span_base sid-mf1 >/dev/null
span_base sid-mf2 >/dev/null
printf 'mf-A\n' > "$DOC"
printf 'mf-B\n' > "$AGENTF"
first=
while IFS=$'\t' read -r _ _ _ _ _ _ vis _; do
  case "$vis" in
    "$DOC"|"$AGENTF") first=$vis; break ;;
  esac
done < "$INSTRUCTION_WATCH_STATE/session-sid-mf2.tsv"
[ -n "$first" ] || fail "multi-file baseline did not name either changed path"
write_mark() { # path: the alert key of the write that left its current bytes
  printf '%s\n%s\n' "$1" "$(shasum -a 256 "$1" | cut -d' ' -f1)@$(stat -L -f %Fm "$1")" | shasum -a 256 |
    cut -c1-16 | sed 's/$/w/'
}
mkdir -p "$INSTRUCTION_WATCH_STATE/alerts/$(write_mark "$first")"
raw_check sid-mf2 Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
other=$AGENTF
[ "$first" = "$AGENTF" ] && other=$DOC
mf_files=$(tail -1 "$J" | jq -r '.files[]' | tr '\n' ' ')
assert_contains "$(basename "$other")" "$mf_files"
echo "== tripwire: a file another session already journaled stays out of this record"
case "$mf_files" in *"$first"*) fail "an already-claimed change was journaled again: $mf_files" ;; esac
assert_eq 1 "$(tail -1 "$J" | jq '.bytes | length')"
case "$(tail -1 "$J" | jq -r '.summary')" in *"$first"*) fail "an already-claimed change stayed in the summary" ;; esac

echo "== tripwire: a nine-day-old claim still keeps a ten-day-old baseline's re-report out of the journal"
span_base sid-stale >/dev/null
touch -t "$(date -v-10d +%Y%m%d%H%M.%S)" "$INSTRUCTION_WATCH_STATE/session-sid-stale.tsv"
printf 'stale-A\n' > "$DOC"
raw_check sid-mf1 Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
find "$INSTRUCTION_WATCH_STATE/alerts" -mindepth 1 -maxdepth 1 -type d -exec touch -t "$(date -v-9d +%Y%m%d%H%M.%S)" {} +
state_mark=0123456789abcdef
mkdir -p "$INSTRUCTION_WATCH_STATE/alerts/$state_mark"
touch -A -480000 "$INSTRUCTION_WATCH_STATE/alerts/$state_mark"
lines=$(wc -l < "$J")
printf 'unrelated\n' > "$AGENTF"
raw_check sid-mf1 Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
raw_check sid-stale Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
stale_files=$(tail -n +"$((lines + 1))" "$J" | jq -r '.files[]' | tr '\n' ' ')
assert_contains "$(basename "$AGENTF")" "$stale_files"
case "$stale_files" in *"$DOC"*) fail "a claim aged past a day let the same write be journaled again: $stale_files" ;; esac

echo "== tripwire: a state marker such as absent still goes at a day, whatever baseline is older"
assert [ ! -d "$INSTRUCTION_WATCH_STATE/alerts/$state_mark" ]

echo "== tripwire: a write marker goes once no baseline predates it"
old_write=0123456789abcdefw
mkdir -p "$INSTRUCTION_WATCH_STATE/alerts/$old_write"
touch -A -480000 "$INSTRUCTION_WATCH_STATE/alerts/$old_write"
printf 'sweep trigger\n' > "$AGENTF"
raw_check sid-mf1 Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert [ ! -d "$INSTRUCTION_WATCH_STATE/alerts/$old_write" ]

echo "== tripwire: a record's writer and restores come from the files it names alone"
printf 'tier doc\n' > "$DOC"
printf 'worker agent\n' > "$AGENTF"
span_base sid-won >/dev/null
printf 'agent changed before the call\n' > "$AGENTF"
mkdir -p "$INSTRUCTION_WATCH_STATE/alerts/$(write_mark "$AGENTF")"
pre_call sid-won Bash command "$ANY_CALL" "$NOSPAN_T"
printf 'tier doc grew inside the call\n' > "$DOC"
raw_check sid-won Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
rec=$(tail -1 "$J")
assert_eq "$DOC" "$(printf '%s' "$rec" | jq -r '.files | join(" ")')"
assert_eq this-call "$(printf '%s' "$rec" | jq -r .writer)"
assert_eq sid-won "$(printf '%s' "$rec" | jq -r .sid)"
assert_eq 1 "$(printf '%s' "$rec" | jq '.restores | length')"
case "$(printf '%s' "$rec" | jq -r '.restores[]')" in *codex-worker.md*) fail "a restore for a file the record does not name" ;; esac
printf 'tier doc\n' > "$DOC"
printf 'worker agent\n' > "$AGENTF"

echo "== tripwire: creating a ranked path that was absent from the baseline is ADDED"
unset TOKENMAP_RATES
mkdir -p "$PROJ"
printf '#1\n%s\n' "$PROJ/CLAUDE.local.md" > "$RANKED"
span_base sid-add-ranked >/dev/null
printf 'created local\n' > "$PROJ/CLAUDE.local.md"
out=$(raw_check sid-add-ranked Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "ADDED" "$out"
assert_contains "CLAUDE.local.md" "$out"

echo "== tripwire: another session's re-cut naming an old file mid-session is not an ADDED"
mkdir -p "$WORK/proj-old"
printf 'old rules\n' > "$WORK/proj-old/CLAUDE.md"
touch -t "$(date -v-1d +%Y%m%d%H%M.%S)" "$WORK/proj-old/CLAUDE.md"
printf '#1\n' > "$RANKED"
span_base sid-recut-live >/dev/null
printf '#1\n%s\n' "$WORK/proj-old/CLAUDE.md" > "$RANKED"
out=$(raw_check sid-recut-live Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
case "$out" in *ADDED*) fail "a file another session's re-cut brought in was reported added: $out" ;; esac
printf 'old rules edited\n' > "$WORK/proj-old/CLAUDE.md"
out=$(raw_check sid-recut-live Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED $WORK/proj-old/CLAUDE.md" "$out"

echo "== tripwire: a ranked name put back with an old mtime after a later check is still ADDED"
mkdir -p "$WORK/proj-back"
printf '#1\n%s\n' "$WORK/proj-back/CLAUDE.md" > "$RANKED"
span_base sid-put-back >/dev/null
raw_check sid-put-back Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
printf 'restored rules\n' > "$WORK/proj-back/CLAUDE.md"
touch -t "$(date -v-1d +%Y%m%d%H%M.%S)" "$WORK/proj-back/CLAUDE.md"
out=$(raw_check sid-put-back Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "ADDED $WORK/proj-back/CLAUDE.md" "$out"

echo "== tripwire: a ranked file written before the baseline's last touch but unseen is ADDED"
rm -f "$WORK/proj-back/CLAUDE.md"
span_base sid-mid-check >/dev/null
printf 'written mid-check\n' > "$WORK/proj-back/CLAUDE.md"
touch -A 01 "$INSTRUCTION_WATCH_STATE/session-sid-mid-check.tsv"
out=$(raw_check sid-mid-check Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "ADDED $WORK/proj-back/CLAUDE.md" "$out"

echo "== tripwire: a ranked arrival deferred past the budget is ADDED on the next call"
rm -f "$WORK/proj-back/CLAUDE.md"
mkdir -p "$WORK/proj-back2"
printf '#1\n%s\n%s\n' "$WORK/proj-back/CLAUDE.md" "$WORK/proj-back2/CLAUDE.md" > "$RANKED"
span_base sid-defer >/dev/null
printf 'one\n' > "$WORK/proj-back/CLAUDE.md"
printf 'two\n' > "$WORK/proj-back2/CLAUDE.md"
out=$(INSTRUCTION_WATCH_BUDGET=0 raw_check sid-defer Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
out="$out $(raw_check sid-defer Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_contains "ADDED $WORK/proj-back/CLAUDE.md" "$out"
assert_contains "ADDED $WORK/proj-back2/CLAUDE.md" "$out"
rm -rf "$WORK/proj-back" "$WORK/proj-back2"
printf '#1\n' > "$RANKED"

echo "== tripwire: a same-path delete after restore is journaled again"
printf 'del-restore\n' > "$DOC"
span_base sid-delrep >/dev/null
rm -f "$DOC"
raw_check sid-delrep Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_contains "DELETED" "$(tail -1 "$J" | jq -r '.summary')"
assert_eq true "$(tail -1 "$J" | jq '.bytes[0] < 0')"
dels_before=$(grep -c '"DELETED' "$J" || true)
printf 'del-restore\n' > "$DOC"
raw_check sid-delrep Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_contains "ADDED" "$(tail -1 "$J" | jq -r '.summary')"
assert_eq true "$(tail -1 "$J" | jq '.bytes[0] > 0')"
rm -f "$DOC"
raw_check sid-delrep Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_contains "DELETED" "$(tail -1 "$J" | jq -r '.summary')"
dels_after=$(grep -c '"DELETED' "$J" || true)
assert [ "$dels_after" -gt "$dels_before" ]
printf 'tier doc\n' > "$DOC"

echo "== tripwire: deleting a ranked file is reported even after a recut drops it"
TOKENMAP_RATES="$RATES"
export TOKENMAP_RATES
mkdir -p "$PROJ"
printf 'project rules\n' > "$PROJ/CLAUDE.md"
jq -n --arg p "$PROJ/CLAUDE.md" '{paths:{entries:{($p):{monthly:{reads:5000}}}}}' > "$RATES"
rm -f "$RANKED"
span_base sid-del-after-recut >/dev/null
assert_contains "$PROJ/CLAUDE.md" "$(cat "$RANKED")"
rm -f "$PROJ/CLAUDE.md"
touch "$RATES"
rm -f "$RANKED"
span_base sid-del-recut-other >/dev/null
case "$(cat "$RANKED")" in *"$PROJ/CLAUDE.md"*) fail "recut still names the deleted ranked file" ;; esac
out=$(raw_check sid-del-after-recut Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "DELETED" "$out"
assert_contains "$PROJ/CLAUDE.md" "$out"
printf 'project rules\n' > "$PROJ/CLAUDE.md"
unset TOKENMAP_RATES

echo "== journal: a failed append releases the marker so a later check can record"
span_base sid-jfail-a >/dev/null
span_base sid-jfail-b >/dev/null
printf 'jfail-body\n' > "$DOC"
rm -f "$J"
mkdir "$J"
raw_check sid-jfail-a Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null 2>/dev/null
rmdir "$J" 2>/dev/null || rm -rf "$J"
raw_check sid-jfail-b Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_contains "CHANGED" "$(cat "$J")"
assert_contains "review-tiers.md" "$(cat "$J")"

echo "== journal: a same-bytes repeat after the marker dies gets a new id"
printf 'rep-v1\n' > "$DOC"
span_base sid-rep >/dev/null
printf 'rep-v2\n' > "$DOC"
raw_check sid-rep Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
id1=$(tail -1 "$J" | jq -r .id)
rm -rf "$INSTRUCTION_WATCH_STATE/alerts"
printf 'rep-v1\n' > "$DOC"
raw_check sid-rep Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
printf 'rep-v2\n' > "$DOC"
raw_check sid-rep Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
id2=$(tail -1 "$J" | jq -r .id)
assert [ -n "$id1" ]
assert [ -n "$id2" ]
assert [ "$id1" != "$id2" ]
assert [ "$(grep -c '"observer":"sid-rep"' "$J")" -ge 2 ]

echo "== journal: concurrent appends during a trim both survive"
span_base sid-trim-a >/dev/null
printf 'trim-race-B\n' > "$HOME/.claude/agents/codex-worker.md"
span_base sid-trim-b >/dev/null
# sid-trim-b's start already journaled the change between the two baselines; the race below is
# about two checks each carrying a record of its own, so that marker is let go.
rm -rf "$INSTRUCTION_WATCH_STATE/alerts"
INSTRUCTION_WATCH_JOURNAL_MAX=2
export INSTRUCTION_WATCH_JOURNAL_MAX
i=1
while [ $i -le 5 ]; do
  printf '{"id":"trim%d","at":"2026-01-01T00:00:0%dZ","sid":"p","summary":"plant","sent":"unsent","files":[],"restores":[],"reverted":[]}\n' "$i" "$i" >> "$J"
  i=$((i + 1))
done
printf 'trim-race-A\n' > "$DOC"
raw_check sid-trim-a Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null &
p1=$!
raw_check sid-trim-b Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null &
p2=$!
wait "$p1" "$p2"
assert_contains "review-tiers.md" "$(cat "$J")"
assert_contains "codex-worker.md" "$(cat "$J")"
unset INSTRUCTION_WATCH_JOURNAL_MAX

echo "OK ($asserts assertions)"
