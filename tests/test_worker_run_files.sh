#!/usr/bin/env bash
. "$(dirname "$0")/worker_run_harness.sh"

clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=effortacct
export STUB_MODEL_USAGE='{"opus":{"canonicalModel":"claude-opus-5-5"},"claude-haiku-4-5-20251001":{"outputTokens":5}}'
: >"$STUB_DIR/claudeb_drop_effort"
start_ok claudeb
assert await_done
assert test "$(grep -c '^CLAUDEB_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=--effort$' "$CALL_LOG")" -eq 1
assert jq -e '.effort_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = claude-opus-5-5

report=$("$RUNNER" report "$RUN_ID")
assert test "$(head -n1 <<<"$report")" = 'ACCOUNT: effortacct (claudeb)'
assert test "$(sed -n 2,3p <<<"$report")" = $'MODEL: opus·high\nSERVED: claude-opus-5-5'
assert grep -q '^COST: 625k tok-eq$' <<<"$report"
assert grep -q '^RESULT:$' <<<"$report"
assert grep -q '^claudeb result$' <<<"$report"

jq '.total_cost_usd = 0.0005' "$RUN_DIR/out" >"$WORK/out.small" && mv "$WORK/out.small" "$RUN_DIR/out"
assert grep -q '^COST: 250 tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"
export WORKER_RUN_S5_USD_PER_M=0
assert grep -q '^COST: 250 tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"
export WORKER_RUN_S5_USD_PER_M=not-a-number
assert grep -q '^COST: 250 tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"
unset WORKER_RUN_S5_USD_PER_M

jq '.total_cost_usd = 0.001999' "$RUN_DIR/out" >"$WORK/out.rollover" && mv "$WORK/out.rollover" "$RUN_DIR/out"
assert grep -q '^COST: 1k tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"

jq '.total_cost_usd = 0.0000005' "$RUN_DIR/out" >"$WORK/out.tiny" && mv "$WORK/out.tiny" "$RUN_DIR/out"
assert grep -q '^COST: <1 tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"



assert grep -qx 'RUN-FILES: unknown (no session transcript for claude-session)' \
  <<<"$(transcript_report "$RUN_DIR")"
mkdir -p "$CLAUDEB_PROFILES_ROOT/effortacct/projects/fixture"
run_workdir=$(jq -r '.workdir' "$RUN_DIR/meta.json")
run_started=$(jq -r '.started_at' "$RUN_DIR/meta.json")
# Milliseconds on purpose: that is what a real transcript writes, and jq's own fromdateiso8601
# refuses them — a fixture stamped to the whole second would pass over the parse this depends on.
tool_error() {
  jq -cn --arg id "$1" --arg ts "$TOOL_TS" \
    '{type: "user", timestamp: $ts, message: {content: [{type: "tool_result", tool_use_id: $id,
      is_error: true, content: "permission denied"}]}}'
}
TOOL_TS=$(iso $((run_started + 1)))
TRANSCRIPT="$CLAUDEB_PROFILES_ROOT/effortacct/projects/fixture/claude-session.jsonl"
# An edit the run was DENIED, or one that failed, is a file the run never changed: counting it puts
# somebody else's untouched file in this run's own list.
{
  tool_call Edit file_path "$run_workdir/bin/one"
  tool_call Write file_path "$run_workdir/bin/one"
  tool_call NotebookEdit notebook_path "$run_workdir/tests/two.ipynb"
  tool_call Read file_path "$run_workdir/never-written"
  tool_call Edit file_path "$WORK/outside/three"
  tool_call Write file_path "$run_workdir/bin/refused" tu_1
  tool_error tu_1
} >"$TRANSCRIPT"
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 3' <<<"$report"
assert grep -qx 'RUN-FILE: bin/one' <<<"$report"
assert grep -qx 'RUN-FILE: tests/two.ipynb' <<<"$report"
assert grep -qxF "RUN-FILE: $WORK/outside/three" <<<"$report"
# The paths are workdir-relative, and the reader that journals them for the launching chat stands
# somewhere else entirely: without this line above the count they resolve against the wrong tree.
assert grep -qxF "WORKDIR: $run_workdir" <<<"$report"
assert test "$(grep -n '^WORKDIR: ' <<<"$report" | cut -d: -f1)" \
  -lt "$(grep -n '^RUN-FILES: ' <<<"$report" | cut -d: -f1)"
assert test "$(grep -c 'never-written' <<<"$report")" -eq 0
assert test "$(grep -c 'bin/refused' <<<"$report")" -eq 0

# A trailing slash on the workdir is the same workdir: doubling the prefix stopped the stripping and
# printed every path absolute, as if the run had worked outside its own directory.
jq --arg w "$run_workdir/" '.workdir = $w' "$RUN_DIR/meta.json" >"$WORK/meta.slash" \
  && mv "$WORK/meta.slash" "$RUN_DIR/meta.json"
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 3' <<<"$report"
assert grep -qx 'RUN-FILE: bin/one' <<<"$report"
jq --arg w "$run_workdir" '.workdir = $w' "$RUN_DIR/meta.json" >"$WORK/meta.plain" \
  && mv "$WORK/meta.plain" "$RUN_DIR/meta.json"

# A --resume run appends to the SAME session transcript, so the file still holds the calls of the
# runs before it: reported unfiltered, this run claims files an earlier one edited — the shared-work
# mistake this whole list exists to avoid, one directory in. The run's own started_at is the cut, and
# a call stamped in that very second is this run's.
TOOL_TS=$(iso $((run_started - 7200)))
{
  tool_call Edit file_path "$run_workdir/bin/pre-resume"
  tool_call Write file_path "$run_workdir/tests/pre-resume.sh"
} >"$TRANSCRIPT"
TOOL_TS=$(iso "$run_started")
tool_call Edit file_path "$run_workdir/bin/at-start" >>"$TRANSCRIPT"
TOOL_TS=$(iso $((run_started + 2)))
tool_call Write file_path "$run_workdir/bin/this-run" >>"$TRANSCRIPT"
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 2' <<<"$report"
assert grep -qx 'RUN-FILE: bin/at-start' <<<"$report"
assert grep -qx 'RUN-FILE: bin/this-run' <<<"$report"
assert test "$(grep -c 'pre-resume' <<<"$report")" -eq 0

# Nothing recorded is not "nothing changed": an edit made through the shell — `sed -i`, a redirect,
# `mv` — appears in no transcript as a tool call, so the zero says what it actually counted.
: >"$TRANSCRIPT"
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"
# Nothing to resolve, so nothing to resolve it against: a bare WORKDIR line over a count that names
# no file reads as a directory this run is claiming.
assert test "$(grep -c '^WORKDIR: ' <<<"$(transcript_report "$RUN_DIR")")" -eq 0

# A transcript jq cannot parse is unknown, never 0: the pipeline used to swallow the parse failure
# and report an authoritative "changed nothing" about a run nobody could read.
printf 'not json {\n' >"$TRANSCRIPT"
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$(transcript_report "$RUN_DIR")"

# A run whose transcript cannot be found says so; a silent 0 would read as a run that changed
# nothing. Every vendor answers here now, so the reason names the missing rollout and no longer
# claims the vendor keeps no record at all.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=filesacct
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (no session transcript for codex-session)' \
  <<<"$(transcript_report "$RUN_DIR")"

# The record and launcher mapping exist even when the workdir cannot be snapshotted.
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $(jq -r '.workdir' "$RUN_DIR/meta.json")"
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert test "$(cat "$RUN_DIR/worker-session")" = codex-session
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc
mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
start_ok claudeb
assert await_done
assert test "$(cat "$RUN_DIR/launcher")" = chat-abc
assert test "$(cat "$STUB_DIR/launcher_env")" = chat-abc
# The task row's state file ends where the run ended, rounds counted by the waits.
assert jq -e '.phase == "done" and .exit_code == 0 and .session == "chat-abc" and .account == "recordacct"
  and .model == "opus" and .effort == "high" and .round >= 1 and (.started_epoch | type) == "number"' \
  "$RUN_DIR/state.json" >/dev/null
assert test "$(cat "$RUN_DIR/worker-session")" = claude-session
printf 'walled-session\n' >>"$RUN_DIR/worker-session"
"$RUNNER" _supervise "$RUN_DIR" >/dev/null 2>&1
assert test "$(grep -c . "$RUN_DIR/worker-session")" -eq 2
assert_fails grep -q '^PARTIAL: ' "$RUN_DIR/files"

# Started inside a relay agent, the run claims the tag file its launch marked in the LAUNCHER's tag
# cache — the main chat's, not the session id the worker process journals under — and every
# transition rewrites the state the task row reads.
clear_stub
export STUB_SLEEP=2
TR_TAGS="$HOME/.cache/claude-worker-tags/chat-main"
mkdir -p "$TR_TAGS"
printf 'seed · opus · high\nstart=%s\nedit=1\n' "$(date +%s)" >"$TR_TAGS/agent-x"
printf 'other · opus · high\nstart=%s\n' "$(($(date +%s) - 600))" >"$TR_TAGS/agent-stale"
CLAUDE_LAUNCHER_SESSION=chat-main start_ok claudeb
assert test "$(cat "$RUN_DIR/launcher")" = chat-main
assert jq -e --arg run "$RUN_ID" '.phase == "start" and .round == 0 and .agent_task_id == "agent-x" and .session == "chat-main"' \
  "$RUN_DIR/state.json" >/dev/null
assert test "$(head -n1 "$TR_TAGS/agent-x")" = "recordacct · opus · high"
assert test "$(grep -c '^start=' "$TR_TAGS/agent-x")" = 0
assert grep -qx "run=$RUN_ID" "$TR_TAGS/agent-x"
assert grep -qx 'edit=1' "$TR_TAGS/agent-x"
assert grep -q '^start=' "$TR_TAGS/agent-stale"
"$RUNNER" wait "$RUN_ID" --max 0 >/dev/null
assert jq -e '.phase == "wait" and .round == 1 and .agent_task_id == "agent-x"' "$RUN_DIR/state.json" >/dev/null
assert await_done
assert jq -e '.phase == "done" and .exit_code == 0 and .round >= 2' "$RUN_DIR/state.json" >/dev/null
unset STUB_SLEEP
# Two launches of one chat claiming at once take two rows, never the newest one twice; the sed shim
# widens the read-then-swap window so the race is not left to timing.
RACE_TAGS="$HOME/.cache/claude-worker-tags/chat-race"
mkdir -p "$RACE_TAGS" "$WORK/race-a" "$WORK/race-b" "$WORK/slow-sed"
printf 'a · opus · high\n' >"$WORK/race-a/tag"
printf 'b · opus · high\n' >"$WORK/race-b/tag"
printf 'a · opus · high\nstart=%s\n' "$(($(date +%s) - 5))" >"$RACE_TAGS/agent-old"
printf 'b · opus · high\nstart=%s\n' "$(date +%s)" >"$RACE_TAGS/agent-new"
printf '#!/bin/bash\nsleep 0.5\nexec /usr/bin/sed "$@"\n' >"$WORK/slow-sed/sed"
chmod +x "$WORK/slow-sed/sed"
claim_race() (
  eval "$(sed -n '/^claim_agent_tag() {/,/^}/p' "$RUNNER")"
  eval "$(sed -n '/^claim_agent_tag_locked() {/,/^}/p' "$RUNNER")"
  eval "$(sed -n '/^launch_agent_tag() {/,/^}/p' "$RUNNER")"
  eval "$(sed -n '/^with_agent_tag_lock() {/,/^}/p' "$RUNNER")"
  eval "$(sed -n '/^fresh_agent_tags() {/,/^}/p' "$RUNNER")"
  PATH="$WORK/slow-sed:$PATH"
  unset CLAUDE_AGENT_ID
  claim_agent_tag "$1" chat-race
)
claim_race "$WORK/race-a" & race_a=$!
claim_race "$WORK/race-b" & race_b=$!
wait "$race_a" "$race_b"
assert test "$(cat "$WORK/race-a/agent-task" "$WORK/race-b/agent-task" | sort | tr '\n' ,)" = 'agent-new,agent-old,'
assert test ! -e "$RACE_TAGS/.claim.lock"
# A launch that outwaits a live holder leaves that holder's lock alone; a lock a dead holder left
# more than a minute ago is cleared on the way in.
printf 'c · opus · high\nstart=%s\n' "$(date +%s)" >"$RACE_TAGS/agent-live"
mkdir "$RACE_TAGS/.claim.lock"
claim_race "$WORK/race-a"
assert test -d "$RACE_TAGS/.claim.lock"
touch -t 202001010000 "$RACE_TAGS/.claim.lock"
claim_race "$WORK/race-b"
assert test ! -e "$RACE_TAGS/.claim.lock"

clear_stub
dirt_repo_init
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor"
  tool_call Bash command 'sed -i "" s/original/rewritten/ bin/shell-edited'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'rewritten\n' >"$DIRT_REPO/bin/shell-edited"
printf 'rewritten\n' >"$DIRT_REPO/tests/tracked-by-the-editor"
printf 'brand new\n' >"$DIRT_REPO/bin/created-through-a-redirect"
mkdir -p "$DIRT_REPO/notes"
printf 'brand new\n' >"$DIRT_REPO/notes/inside-an-untracked-directory"
assert await_done
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $DIRT_TOP"
assert grep -qx 'tests/tracked-by-the-editor' "$RUN_DIR/files"
# What the shell wrote, no record of this run names: a snapshot says a file moved, never who moved
# it, and in a shared checkout the difference is another chat's live work. They are the dirt record's
# until the launching chat claims them — nobody's, rather than invented as this run's.
assert_fails grep -qx 'bin/shell-edited' "$RUN_DIR/files"
assert grep -qx 'bin/shell-edited' "$RUN_DIR/dirty"
assert grep -qx 'bin/created-through-a-redirect' "$RUN_DIR/dirty"
assert grep -qx 'notes/inside-an-untracked-directory' "$RUN_DIR/dirty"
assert_fails grep -qx 'notes/' "$RUN_DIR/dirty"
assert_fails grep -qx 'tests/tracked-by-the-editor' "$RUN_DIR/dirty"
assert_fails grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/files"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/x/y/ bin/the-co-tenant-was-already-editing-this' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'the run rewrote it\n' >>"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
assert await_done
# The floor still SEES a rewrite of a file that was already dirty at launch — that is what the
# launch-time shas are for — it just answers for it as nobody's rather than as this run's.
assert grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/dirty"
assert_fails grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/files"
assert_fails grep -qx 'bin/somebody-elses-file' "$RUN_DIR/files"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'and again\n' >"$DIRT_REPO/bin/somebody-elses-file"
assert await_done
assert test "$(grep -c '^PARTIAL: ' "$RUN_DIR/files")" -eq 0
assert test ! -e "$RUN_DIR/dirty"

# The contract in a checkout other chats are working in RIGHT NOW: the snapshot holds every path
# that moved in the run's window, and only the run's own listing says which of them the run wrote.
# Handed the rest, the launching chat inherits a co-tenant's live work as its own review debt —
# live 2026-09-11, a run that edited 2 files was charged with 8.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$DIRT_TOP/tests/edited-by-the-run" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'the run wrote this\n' >"$DIRT_REPO/tests/edited-by-the-run"
printf 'a co-tenant wrote this\n' >"$DIRT_REPO/bin/written-by-a-co-tenant"
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: tests/edited-by-the-run' <<<"$report"
assert test "$(grep -c '^RUN-FILE: ' <<<"$report")" -eq 1
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert_fails grep -q 'written-by-a-co-tenant' "$RUN_DIR/produced"
assert grep -qxF "1 path(s) changed in the checkout during the run by another writer and are not this run's: bin/written-by-a-co-tenant" \
  "$RUN_DIR/files-note"
# The snapshot did NOT stand here, and saying it did is what sent the co-tenant's paths through.
assert_fails grep -q 'snapshot attribution stands' "$RUN_DIR/files-note"

# A worker that merely RAN something — its own suite — named every file it wrote. Doubted there,
# every serious run is back to claiming the whole window.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$DIRT_TOP/tests/edited-by-the-run"
  tool_call Bash command 'bash tests/run.sh'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'the run wrote this again\n' >"$DIRT_REPO/tests/edited-by-the-run"
printf 'a co-tenant wrote this again\n' >"$DIRT_REPO/bin/written-by-a-co-tenant"
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: tests/edited-by-the-run' <<<"$report"
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert_fails grep -q 'snapshot attribution stands' "$RUN_DIR/files-note"

# And a Bash call that WRITES is the one case the listing cannot be trusted to be whole: it is a
# FLOOR, so what it names is still this run's and the rest of the window is attributed to NOBODY.
# Handed the rest, the run owns whatever a co-tenant wrote beside it (Egor, 2026-09-12: a snapshot
# detects changes, not their author), and the launching chat can only claim what it recognises.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$DIRT_TOP/tests/edited-by-the-run"
  tool_call Bash command 'sed -i "" s/a/b/ bin/written-by-a-co-tenant'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'once more\n' >"$DIRT_REPO/tests/edited-by-the-run"
printf 'once more\n' >"$DIRT_REPO/bin/written-by-a-co-tenant"
assert await_done
assert grep -qx 'tests/edited-by-the-run' "$RUN_DIR/files"
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert_fails grep -q 'written-by-a-co-tenant' "$RUN_DIR/produced"
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert_fails grep -q 'snapshot attribution stands' "$RUN_DIR/files-note"
assert grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/dirty"
assert_fails grep -qx 'tests/edited-by-the-run' "$RUN_DIR/dirty"
report=$("$RUNNER" report "$RUN_ID")
assert grep -q "^UNNAMED: .*worker-run claim $RUN_ID" <<<"$report"
assert grep -q 'written-by-a-co-tenant' <<<"$report"
# And the launching chat says which of them were its worker's: a claim names the path and the
# record answers for its content again.
assert "$RUNNER" claim "$RUN_ID" --paths bin/written-by-a-co-tenant >/dev/null
assert grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert grep -q 'written-by-a-co-tenant' "$RUN_DIR/produced"
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/dirty"

# An unreadable listing cannot turn the snapshot into evidence of ownership.
clear_stub
export STUB_SLEEP=1
printf 'not json at all\n' >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
printf 'unreadable\n' >"$DIRT_REPO/tests/edited-by-the-run"
printf 'unreadable\n' >"$DIRT_REPO/bin/written-by-a-co-tenant"
assert await_done
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert_fails grep -qx 'tests/edited-by-the-run' "$RUN_DIR/files"
assert grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/dirty"
assert grep -qx 'tests/edited-by-the-run' "$RUN_DIR/dirty"
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert grep -q '^transcript cross-check unavailable: ' "$RUN_DIR/files-note"
assert grep -q 'changed paths remain unnamed' "$RUN_DIR/files-note"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Bash command 'sed -i "" s/rewritten/again/ bin/shell-edited'
  tool_call Edit file_path "$DIRT_TOP/tests/named-from-a-subdirectory"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO/tests"
printf 'from a subdirectory\n' >"$DIRT_REPO/bin/edited-from-a-subdirectory"
printf 'from a subdirectory\n' >"$DIRT_REPO/tests/named-from-a-subdirectory"
assert await_done
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $DIRT_TOP/tests"
assert grep -qx 'named-from-a-subdirectory' "$RUN_DIR/files"
assert_fails grep -qx 'tests/named-from-a-subdirectory' "$RUN_DIR/files"
# The listing spells a path against the WORKDIR, the dirt record against the repository TOP, and
# the unattributed rest of the window is the difference between the two spellings of one set.
assert_fails grep -qxF "$DIRT_TOP/bin/edited-from-a-subdirectory" "$RUN_DIR/files"
assert grep -qx 'bin/edited-from-a-subdirectory' "$RUN_DIR/dirty"
assert_fails grep -qx 'tests/named-from-a-subdirectory' "$RUN_DIR/dirty"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/again/once more/ bin/shell-edited' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
assert test -e "$RUN_DIR/dirty-before"
rm -f "$RUN_DIR/dirty-before-shas"
printf 'nobody measured the floor\n' >"$DIRT_REPO/bin/without-a-floor"
assert await_done
assert test ! -e "$RUN_DIR/dirty"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ somewhere' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb
assert await_done
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"
assert test ! -e "$RUN_DIR/dirty-before"

snapshot_shell_tests() {
  local vendor path frozen variant note
  for vendor in claudeb codex gemini grok; do
    clear_stub
    set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=high' 'gemini_model=flash38' 'gemini_effort=high' 'grok_effort=high'
    printf 'recordacct\n' >"$STUB_DIR/gemini_profiles"
    export SNAPSHOT_DELETED="$DIRT_REPO/bin/shell-deleted-$vendor"
    export SNAPSHOT_TOUCHED="$DIRT_REPO/bin/shell-touched-$vendor"
    printf 'delete this\n' >"$SNAPSHOT_DELETED"
    printf 'keep this\n' >"$SNAPSHOT_TOUCHED"
    git -C "$DIRT_REPO" add "bin/shell-deleted-$vendor" "bin/shell-touched-$vendor"
    git -C "$DIRT_REPO" -c user.name=fixture -c user.email=fixture@example.test commit -qm 'shell attribution fixture'
    cat >"$STUB_DIR/relay_hook" <<'EOF'
#!/usr/bin/env bash
printf 'shell content\n' >"$SNAPSHOT_TARGET"
rm "$SNAPSHOT_DELETED"
touch "$SNAPSHOT_TOUCHED"
EOF
    chmod +x "$STUB_DIR/relay_hook"
    export SNAPSHOT_TARGET="$DIRT_REPO/bin/shell-only-$vendor"
    # The hook above writes through the SHELL, and claudeb is the one vendor here whose transcript
    # this suite writes: without the Bash call that did it, its listing reads as complete and the
    # snapshot narrows to nothing — which is the whole point of the shell floor.
    if [ "$vendor" = claudeb ]; then
      TOOL_TS=$(iso $(($(date +%s) + 600)))
      tool_call Bash command 'printf "shell content\n" >bin/shell-only-claudeb; rm bin/shell-deleted-claudeb' \
        >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
    fi
    start_ok "$vendor" --workdir "$DIRT_REPO"
    assert await_done
    path="bin/shell-only-$vendor"
    assert_fails grep -qx "$path" "$RUN_DIR/files"
    assert grep -qx "$path" "$RUN_DIR/dirty"
    assert grep -qx "bin/shell-deleted-$vendor" "$RUN_DIR/dirty"
    assert_fails grep -q "bin/shell-touched-$vendor" "$RUN_DIR/dirty"
    assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
    assert "$RUNNER" claim "$RUN_ID" --paths "$path" "bin/shell-deleted-$vendor" >/dev/null
    assert grep -qx "$path" "$RUN_DIR/files"
    assert grep -q "$path" "$RUN_DIR/produced"
    assert grep -qx "bin/shell-deleted-$vendor" "$RUN_DIR/files"
    assert grep -q $'\t-\t'"bin/shell-deleted-$vendor"'$' "$RUN_DIR/produced"
    assert_fails grep -q "bin/shell-touched-$vendor" "$RUN_DIR/files"
    assert_fails grep -q "bin/shell-touched-$vendor" "$RUN_DIR/produced"
    assert_fails grep -q '^UNKNOWN: ' "$RUN_DIR/files"
    assert test ! -e "$RUN_DIR/dirty"
    frozen=$(cat "$RUN_DIR/produced")
    printf 'later content\n' >"$SNAPSHOT_TARGET"
    assert grep -qx "RUN-FILE: $path" <<<"$("$RUNNER" report "$RUN_ID")"
    assert "$RUNNER" claim "$RUN_ID" --paths "$path" >/dev/null
    assert test "$(cat "$RUN_DIR/produced")" = "$frozen"
    assert_fails "$RUNNER" claim "$RUN_ID" --paths "bin/shell-touched-$vendor" >"$WORK/snapshot-claim.out" 2>&1
    assert grep -q "not in this run's snapshot diff" "$WORK/snapshot-claim.out"
    rm -f "$STUB_DIR/relay_hook"
  done
  unset SNAPSHOT_TARGET SNAPSHOT_DELETED SNAPSHOT_TOUCHED
  for variant in cotenant unnamed; do
    clear_stub
    set_config 'claudeb_model=opus' 'claudeb_effort=high'
    export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc STUB_SLEEP=1
    mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
    printf 'co-tenant dirty\n' >"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
    TOOL_TS=$(iso $(($(date +%s) + 60)))
    {
      tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor"
      [ "$variant" = cotenant ] ||
        tool_call Bash command 'sed -i "" s/a/b/ bin/shell-edited'
    } >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
    start_ok claudeb --workdir "$DIRT_REPO"
    git -C "$DIRT_REPO" show HEAD:bin/the-co-tenant-was-already-editing-this \
      >"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
    assert await_done
    assert bash -c '! grep -qx "$1" "$2"' \
      'rule change: restoring a co-tenant path does not establish ownership' \
      'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/files"
    assert_fails grep -q 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/produced"
    if [ "$variant" = cotenant ]; then
      note="1 path(s) changed in the checkout during the run by another writer and are not this run's: bin/the-co-tenant-was-already-editing-this"
      assert test ! -e "$RUN_DIR/dirty"
    else
      note="1 path(s) changed in the run's window that its own listing does not name and nobody answers for (the run also ran shell commands, whose edits no transcript records): bin/the-co-tenant-was-already-editing-this"
      assert grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/dirty"
    fi
    assert grep -qxF "$note" "$RUN_DIR/files-note"
    assert grep -qxF "RUN-FILES-NOTE: $note" <<<"$("$RUNNER" report "$RUN_ID")"
  done
  clear_stub
}
snapshot_shell_tests

# worker-edit-guard lets a shell write through by recording it in the run's `shell-writes`, spelled
# against the physical top; the run folds it into its listing with no claim, a recorded directory
# answering for the changed files under it, and a recorded path the run left unchanged naming nothing.
guard_recorded_tests() {
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc STUB_SLEEP=1
  mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
  cat >"$STUB_DIR/relay_hook" <<'EOF'
#!/usr/bin/env bash
top=$(cd "$GUARD_REPO" && pwd -P)
mkdir -p "$GUARD_REPO/bin/guard-tree"
printf 'copied\n' >"$GUARD_REPO/bin/guard-recorded"
printf 'copied\n' >"$GUARD_REPO/bin/guard-tree/one"
printf 'unrecorded\n' >"$GUARD_REPO/bin/guard-unrecorded"
printf '%s\n' "$top/bin/guard-recorded" "$top/bin/guard-tree" "$top/bin/guard-restored" \
  >>"$WORKER_RUN_RECORD/shell-writes"
EOF
  chmod +x "$STUB_DIR/relay_hook"
  export GUARD_REPO=$DIRT_REPO
  TOOL_TS=$(iso $(($(date +%s) + 600)))
  tool_call Bash command 'cp -R /tmp/tree bin/guard-tree; cp /tmp/x bin/guard-recorded' \
    >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
  start_ok claudeb --workdir "$DIRT_REPO"
  assert await_done
  assert grep -qx 'bin/guard-recorded' "$RUN_DIR/files"
  assert grep -qx 'bin/guard-tree/one' "$RUN_DIR/files"
  assert_fails grep -qx 'bin/guard-tree' "$RUN_DIR/files"
  assert_fails grep -q 'guard-restored' "$RUN_DIR/files"
  assert_fails grep -qx 'bin/guard-unrecorded' "$RUN_DIR/files"
  assert grep -qx 'bin/guard-unrecorded' "$RUN_DIR/dirty"
  assert_fails grep -q 'bin/guard-recorded\|bin/guard-tree' "$RUN_DIR/dirty"
  assert grep -q 'bin/guard-recorded' "$RUN_DIR/produced"
  assert grep -qx 'RUN-FILE: bin/guard-recorded' <<<"$("$RUNNER" report "$RUN_ID")"
  rm -f "$STUB_DIR/relay_hook"
  rm -rf "$DIRT_REPO/bin/guard-tree" "$DIRT_REPO/bin/guard-recorded" "$DIRT_REPO/bin/guard-unrecorded"
  unset GUARD_REPO
  clear_stub
}
guard_recorded_tests

# A contents copy into the top (`rsync -a src/ .`) is recorded as the top itself, answering for every
# changed file under it; it is no write outside the repository.
guard_top_recorded_tests() {
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc STUB_SLEEP=1
  mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
  cat >"$STUB_DIR/relay_hook" <<'EOF'
#!/usr/bin/env bash
top=$(cd "$GUARD_REPO" && pwd -P)
printf 'copied\n' >"$GUARD_REPO/bin/guard-top-copied"
printf '%s\n' "$top" >>"$WORKER_RUN_RECORD/shell-writes"
EOF
  chmod +x "$STUB_DIR/relay_hook"
  export GUARD_REPO=$DIRT_REPO
  TOOL_TS=$(iso $(($(date +%s) + 600)))
  tool_call Bash command 'rsync -a /tmp/src/ .' \
    >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
  start_ok claudeb --workdir "$DIRT_REPO"
  assert await_done
  assert grep -qx 'bin/guard-top-copied' "$RUN_DIR/files"
  assert_fails grep -q 'guard-top-copied' "$RUN_DIR/dirty"
  assert_fails grep -qxF "$(cd "$DIRT_REPO" && pwd -P)" "$RUN_DIR/files-external"
  rm -f "$STUB_DIR/relay_hook" "$DIRT_REPO/bin/guard-top-copied"
  unset GUARD_REPO
  clear_stub
}
guard_top_recorded_tests


echo "PASS: $asserts asserts; served model and cost, transcript file lists, snapshot and guard attribution"
