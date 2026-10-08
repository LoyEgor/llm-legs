#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"

# --- Per-file lists from the gemini and codex transcripts ----------------------------------------
# Those vendors DO name the files they write, each in its own log, and a listless run claimed the
# whole workdir dirt of its time window — every path a co-tenant chat had edited in the same
# minutes read as this run's (shared-invariants row am bounds the claim, and only a real list can
# narrow it). The rule is fail-closed and whole-run: the list is exact only where every mutating
# action named its target.
clear_stub
unset CLAUDE_CODE_SESSION_ID
set_config 'gemini_model=flash38' 'gemini_effort=high'
printf 'gemfiles\n' >"$STUB_DIR/gemini_profiles"
agy_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
agy_row_status() { # created_at status name args-json
  jq -cn --arg ts "$1" --arg status "$2" --arg name "$3" --argjson args "$4" \
    '{step_index: 0, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE",
      created_at: $ts, tool_calls: [{name: $name, args: $args}]}'
  case "$3" in
    write_to_file|replace_file_content|multi_replace_file_content)
      jq -cn --arg ts "$1" --arg status "$2" \
        '{step_index: 1, source: "TOOL", type: "CODE_ACTION", created_at: $ts, status: $status}'
      ;;
  esac
}
agy_row() { agy_row_status "$1" DONE "$2" "$3"; }
agy_write() { agy_row "$AGY_TS" "$1" "$(jq -cn --arg p "$2" '{TargetFile: $p}')"; }
agy_read() { agy_row "$AGY_TS" view_file "$(jq -cn --arg p "$1" '{AbsolutePath: $p}')"; }
agy_shell() { agy_row "$AGY_TS" run_command "$(jq -cn --arg c "$1" --arg d "$2" '{CommandLine: $c, Cwd: $d}')"; }
AGY_TRANSCRIPT="$GEMINIB_PROFILES_DIR/gemfiles/.gemini/antigravity-cli/brain/gemini-conversation/.system_generated/logs/transcript_full.jsonl"
mkdir -p "$(dirname "$AGY_TRANSCRIPT")"
# The workdir as the shell resolves it: a fixture spelled through the symlink a temporary directory
# reaches strips against nothing, and every path then reads as one the run worked outside its own
# directory.
agy_workdir=$(cd "$WORK/workdir" && pwd -P)
export PICK_RC=0 PICK_ACCOUNT=gemfiles
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_write replace_file_content "$agy_workdir/bin/agy-written"
  agy_write multi_replace_file_content "$WORK/outside/agy-absolute"
  agy_read "$agy_workdir/bin/agy-only-read"
  agy_shell 'git status --short 2>/dev/null' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 2' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-written' <<<"$report"
assert grep -qxF "RUN-FILE: $WORK/outside/agy-absolute" <<<"$report"
# A file the run only READ is not a file it changed, and every listed path is one somebody will be
# asked to review.
assert test "$(grep -c 'agy-only-read' <<<"$report")" -eq 0
# A read-only shell command does not spoil the list, but any shell at all makes the list a floor —
# the same sentence claudeb's own runs carry, since it is the same fact about a transcript.
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"
assert grep -qx 'bin/agy-written' "$WORK/transcript-files"
assert test "$(grep -c '^UNKNOWN: ' "$WORK/transcript-files")" -eq 0
assert test ! -e "$RUN_DIR/workdir-escape"

# Relative tool targets are anchored to the run workdir before both rendering and escape detection.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
agy_write write_to_file 'bin/agy-relative' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-relative' <<<"$report"
assert test ! -e "$RUN_DIR/workdir-escape"

# A rejected write changed nothing and cannot make the successful call beside it review debt.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-write-succeeded"
  agy_row_status "$AGY_TS" FAILED write_to_file \
    "$(jq -cn --arg p "$agy_workdir/bin/agy-write-failed" '{TargetFile: $p}')"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert test "$(grep -c '^RUN-FILE: ' <<<"$report")" -eq 1
assert grep -qx 'RUN-FILE: bin/agy-write-succeeded' <<<"$report"
assert test "$(grep -c 'agy-write-failed' <<<"$report")" -eq 0

# `transcript.jsonl` sits beside the one that was read and carries the same rows with the tool_call
# ARGUMENTS stripped: read instead of `transcript_full.jsonl` it can name no file ever again.
assert grep -q 'transcript_full.jsonl' "$ROOT/bin/worker-run"

# A shell command that WRITES leaves the run exactly as unanswerable as it was before any extractor
# existed: the transcript names the editor calls and nothing names the redirect beside them.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell "printf hello > $agy_workdir/bin/agy-through-a-redirect" "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"
assert grep -qx 'UNKNOWN: the run wrote through the shell, whose targets no transcript names' \
  "$WORK/transcript-files"
# And no path stands beside the UNKNOWN: half a list read as the whole of one is the claim the
# fail-closed rule exists to refuse.
assert test "$(grep -c 'agy-written' "$WORK/transcript-files")" -eq 0

# Numbered and ampersand redirects open files too, so every supported fd spelling spoils the list.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'printf one 1>one; printf two 2>two; printf three 3>three; printf all &>all' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A redirect to a file descriptor or to /dev/null writes no file. Counted as a write it made every
# `2>/dev/null` in a read-only review run unanswerable, which is most of them.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'grep pattern file >/dev/null 2>&1; git diff 2>&1 | head -20; rg -n pattern . 2>/dev/null' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 1' <<<"$(transcript_report "$RUN_DIR")"

# The /dev/null exception ends at the device name; a similarly prefixed file is still a write.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'printf hidden >/dev/null.log' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Comparison and arrow operators are not redirects; the shell still makes this exact editor list a floor.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell "printf '%s' 'a >= b' 'x => x'" "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"

# A tool this reader does not know is a tool whose targets it cannot name: agy's own image
# generation names only the image's LABEL, and a subagent it invokes edits under a transcript of
# its own. Neither may pass as a complete list, and the reason names the call so the next reader
# knows what to teach it.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_row "$AGY_TS" generate_image '{"ImageName": "asset", "AspectRatio": "1:1"}'
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: generate_image)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A write whose target the transcript leaves empty is the same refusal.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
agy_row "$AGY_TS" write_to_file '{"CodeContent": "x"}' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a write whose target it does not name)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A resumed conversation APPENDS to the same transcript, so the file holds the calls of the runs
# before it — reported unfiltered this run claims a file an earlier one edited. The run's own start
# is the cut, and a call stamped in that very second is this run's.
clear_stub
export STUB_SLEEP=0.3
start_ok gemini
run_started=$(jq -r '.started_at' "$RUN_DIR/meta.json")
AGY_TS=$(agy_iso $((run_started - 7200)))
agy_write write_to_file "$agy_workdir/bin/agy-before-the-resume" >"$AGY_TRANSCRIPT"
AGY_TS=$(agy_iso "$run_started")
AGY_TS="${AGY_TS%Z}.123Z"
agy_write write_to_file "$agy_workdir/bin/agy-at-the-start" >>"$AGY_TRANSCRIPT"
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-at-the-start' <<<"$report"
unset STUB_SLEEP

# A syntactically valid mutating row with no usable time cannot be silently excluded from the run.
clear_stub
AGY_TS=not-a-timestamp
agy_write write_to_file "$agy_workdir/bin/agy-unparseable-time" >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A transcript jq cannot parse is unknown, never 0.
clear_stub
printf 'not json {\n' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$(transcript_report "$RUN_DIR")"

# No transcript at all — an agy too old to keep one, a conversation id the log never printed, a
# profile that is not where it was looked for — is unknown too, and never the workdir.
clear_stub
mv "$AGY_TRANSCRIPT" "$AGY_TRANSCRIPT.moved"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (no session transcript for gemini-conversation)' \
  <<<"$(transcript_report "$RUN_DIR")"
rm -f "$AGY_TRANSCRIPT.moved"

# Live-reproduced 2026-08-24: handed a workdir it does not trust, agy moved into the first
# --add-dir, worked THERE, and reported success — a green run over an untouched workdir, which is
# the one failure a launcher cannot see. Not "a path outside the workdir", which is ordinary: the
# signal is that NOTHING the run named is inside it. Said in the report and marked beside the run,
# and said even where the list itself is unanswerable — the escape is the louder of the two facts.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$WORK/extra/agy-went-elsewhere"
  agy_shell "printf x > $WORK/extra/and-wrote-here" "$WORK/extra"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qxF "WORKDIR-ESCAPE: the run named no path inside its own workdir; it worked in $WORK/extra/agy-went-elsewhere" \
  <<<"$report"
assert grep -q '^RUN-FILES: unknown' <<<"$report"
assert grep -qxF "$WORK/extra/agy-went-elsewhere" "$RUN_DIR/workdir-escape"
# The same sentence in the report `wait` prints the moment the run ends, which computes no list of
# its own: read only where a report was asked for, the loudest fact about the run reaches nobody.
assert grep -q '^WORKDIR-ESCAPE: ' "$WORK/wait.out"
"$RUNNER" _supervise "$RUN_DIR" >/dev/null 2>&1
assert test "$(grep -c . "$RUN_DIR/workdir-escape")" -eq 1
# Every escaped destination accumulated across attempts reaches the report once.
printf '%s\n' "$WORK/outside/agy-second-escape" >>"$RUN_DIR/workdir-escape"
report=$(transcript_report "$RUN_DIR")
assert test "$(grep -c '^WORKDIR-ESCAPE: ' <<<"$report")" -eq 2
# A run that touched its own workdir AND wrote outside it is doing its job: a worker reads
# ~/.claude and writes /tmp, and screamed about every time this line would say nothing at all.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_write write_to_file "$WORK/extra/agy-also-here"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert test ! -e "$RUN_DIR/workdir-escape"
assert test "$(grep -c '^WORKDIR-ESCAPE: ' <<<"$(transcript_report "$RUN_DIR")")" -eq 0

# codex names its edits twice over and neither alone is complete: the patch event holds the paths of
# a patch that applied, the call itself holds the patch TEXT (both gaps live-measured over the local
# rollout corpus), so the run answers with the union.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=codexfiles
CX_ROLLOUT="$CODEX_PROFILES_DIR/codexfiles/sessions/fixture/rollout-codex-session.jsonl"
mkdir -p "$(dirname "$CX_ROLLOUT")"
cx_row() { jq -cn --arg ts "$CX_TS" --argjson p "$1" '{timestamp: $ts, type: "response_item", payload: $p}'; }
cx_patch_event() { # target move-or-empty success
  cx_row "$(jq -cn --arg t "$1" --arg m "$2" --argjson ok "$3" \
    '{type: "patch_apply_end", success: $ok,
      changes: {($t): {type: "update", move_path: (if $m == "" then null else $m end)}}}')"
}
cx_exec() { cx_row "$(jq -cn --arg s "$1" '{type: "custom_tool_call", name: "exec", input: $s}')"; }
cx_exec_id() { cx_row "$(jq -cn --arg id "$1" --arg s "$2" '{type: "custom_tool_call", name: "exec", call_id: $id, input: $s}')"; }
cx_call() { cx_row "$(jq -cn --arg n "$1" --arg a "$2" '{type: "function_call", name: $n, arguments: $a}')"; }
cx_call_id() { cx_row "$(jq -cn --arg id "$1" --arg n "$2" --arg a "$3" '{type: "function_call", name: $n, call_id: $id, arguments: $a}')"; }
cx_output() { cx_row "$(jq -cn --arg id "$1" --arg out "$2" '{type: "custom_tool_call_output", call_id: $id, output: $out}')"; }
cx_workdir=$(cd "$WORK/workdir" && pwd -P)
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_patch_event "$cx_workdir/bin/cx-moved-from" "$cx_workdir/bin/cx-moved-to" true
  # A failed event cannot contribute either its changes map or the patch text in the call before it.
  cx_exec "const patch = \"*** Begin Patch\\n*** Update File: $cx_workdir/bin/cx-patch-text-failed\\n*** End Patch\"; await tools.apply_patch({\"input\": patch});"
  cx_patch_event "$cx_workdir/bin/cx-patch-text-failed" '' false
  cx_patch_event "$cx_workdir/bin/cx-patch-failed" '' false
  # A failed apply_patch has no patch_apply_end in current rollouts; its call result is the join.
  cx_exec_id cx-no-event-failed "const patch = \"*** Begin Patch\\n*** Update File: $cx_workdir/bin/cx-no-event-failed\\n*** End Patch\"; await tools.apply_patch({\"input\": patch});"
  cx_output cx-no-event-failed 'Script failed: apply_patch verification failed'
  # The patch text alone, for the runs whose event never arrived.
  cx_exec_id cx-no-event-success "const patch = \"*** Begin Patch\\n*** Update File: $cx_workdir/bin/cx-from-the-patch-text\\n*** End Patch\"; await tools.apply_patch({\"input\": patch});"
  cx_output cx-no-event-success 'Script completed'
  cx_call exec_command "{\"cmd\":\"git status --short\",\"workdir\":\"$cx_workdir\"}"
  # An empty stdin write is codex polling a long command for more output: it writes nothing, and
  # spoiled wholesale this one call left almost every real codex run unanswerable.
  cx_call write_stdin '{"session_id":1,"chars":"","yield_time_ms":1000}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 4' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-patched' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-moved-from' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-moved-to' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-from-the-patch-text' <<<"$report"
assert test "$(grep -c 'cx-patch-failed' <<<"$report")" -eq 0
assert test "$(grep -c 'cx-patch-text-failed' <<<"$report")" -eq 0
assert test "$(grep -c 'cx-no-event-failed' <<<"$report")" -eq 0
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"
assert grep -qx 'bin/cx-patched' "$WORK/transcript-files"

# A target still carrying an unexpanded `$name` or a backtick is text, not a path anybody can
# attribute: a run editing this suite's own fixtures patches their `*** Update File: $cx_workdir/…`
# headers, and the variable reached a live run's file list as a file (2026-08-24). The run says so
# instead of naming it.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_patch_event '$cx_workdir/bin/cx-from-a-variable' '' true
  cx_patch_event '${workdir}/bin/cx-from-a-brace' '' true
  cx_patch_event '`pwd`/bin/cx-from-a-backtick' '' true
  cx_patch_event "$cx_workdir/bin/cost"'$report.txt' '' true
  cx_patch_event "$cx_workdir/bin/cost"'$.txt' '' true
  cx_patch_event "$cx_workdir/bin/cost"'`report.txt' '' true
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 4' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-patched' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost$report.txt' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost$.txt' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost`report.txt' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-variable' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-brace' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-backtick' <<<"$report"
assert test "$(grep -v '^WORKDIR: \|^UNKNOWN: \|^PARTIAL: ' "$WORK/transcript-files" | grep -c 'cx-from-a-')" -eq 0
# The text itself, so a reader can see what the transcript could not resolve.
assert grep -qx 'RUN-FILES-PARTIAL: the run named a target the transcript cannot resolve: $cx_workdir/bin/cx-from-a-variable' <<<"$report"
assert grep -qx 'PARTIAL: the run named a target the transcript cannot resolve: $cx_workdir/bin/cx-from-a-variable' "$WORK/transcript-files"
# And it never reads as the whole list being unanswerable: the paths beside it are real.
assert_fails grep -q '^RUN-FILES: unknown' <<<"$report"

# The same guard for agy, which names its targets in its own log through the same reader.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=gemfiles
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_write write_to_file '$agy_workdir/bin/agy-from-a-variable'
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-written' <<<"$report"
assert grep -qx 'RUN-FILES-PARTIAL: the run named a target the transcript cannot resolve: $agy_workdir/bin/agy-from-a-variable' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*agy-from-a-variable' <<<"$report"
export PICK_RC=0 PICK_ACCOUNT=codexfiles

# Patch headers printed by a shell command are text, not editor targets.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_call exec_command "$(jq -cn --arg d "$cx_workdir" '{cmd:"printf %s *** Update File: bin/cx-mentioned-only",workdir:$d}')"
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert test "$(grep -c 'cx-mentioned-only' <<<"$report")" -eq 0

# CRLF patch headers produce the same path bytes as LF headers.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
printf -v crlf_patch '*** Begin Patch\r\n*** Update File: %s/bin/cx-crlf\r\n*** End Patch\r\n' "$cx_workdir"
{
  cx_call_id cx-crlf apply_patch "$crlf_patch"
  cx_output cx-crlf '{"output":"Success. Updated the following files","metadata":{"exit_code":0}}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILE: bin/cx-crlf' <<<"$report"
assert test "$(printf '%s' "$report" | tr -cd '\r' | wc -c | tr -d ' ')" -eq 0

# codex's shell arrives as JSON inside the harness call, and the write list reads it the same way
# whichever wrapper carries it — the JS `exec` dispatcher included.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_exec "const r = await tools.exec_command({\"cmd\":\"sed -i '' s/a/b/ bin/cx-through-the-shell\",\"workdir\":\"$cx_workdir\"}); text(r.output);"
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Single quotes and backticks are string literals like any other, and a call spelled with them reads.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "await tools.exec_command({cmd:'git status',workdir:'$cx_workdir'}); await tools.exec_command({cmd:\`git status\`,workdir:\`$cx_workdir\`});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# An interpolated template literal names no command this reader can read, and fails closed.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const verb = 'status'; const cmd = \`git \${verb}\`; await tools.exec_command({cmd, workdir:'$cx_workdir'});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Shorthand resolves by NAME against the binding standing before the call, so an explicit value and a
# shorthand one interleaved each keep their own command; taking them in two blocks paired the second
# call with the first binding, and its `sed` spoiled a run that never wrote through the shell.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "var cmd = \"sed -i '' s/a/b/ bin/cx-not-this-one\"; await tools.exec_command({cmd: 'git status'}); var cmd = 'cat bin/cx-read-only'; await tools.exec_command({cmd});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# The same binding serves every shorthand call that follows it, however many there are.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const cmd = 'git status --short'; await tools.exec_command({cmd}); await tools.exec_command({cmd});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A shorthand name with no binding before it resolves to nothing at all.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "await tools.exec_command({cmd}); const cmd = 'git status';" >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$(transcript_report "$RUN_DIR")"

# workdir resolves per call the same way: the shorthand of the second call is the directory bound
# before IT, and reading the first binding instead put every command outside the workdir.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "var workdir = '$WORK/extra'; await tools.exec_command({cmd: 'git status', workdir: '$WORK/extra'}); var workdir = '$cx_workdir'; await tools.exec_command({cmd: 'ls', workdir});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert test ! -e "$RUN_DIR/workdir-escape"
assert test "$(grep -c '^WORKDIR-ESCAPE: ' <<<"$(transcript_report "$RUN_DIR")")" -eq 0

# Tool-looking text in strings and comments is not an executed call.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec $'await tools.view_image({path:"fixture.png"}); const note = "tools.fs_write()"; // tools.js()' \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Direct function-call arguments must be a JSON object, not prose containing field-shaped text.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_call exec_command "arbitrary text cmd: \"git status\", workdir: \"$cx_workdir\"" >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Bare JavaScript object keys are the dominant exec_command rollout form and use the same shell rule.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_exec "const r = await tools.exec_command({cmd:\"sed -i '' s/a/b/ bin/cx-bare-shell\",workdir:\"$cx_workdir\"}); text(r.output);"
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# JavaScript shorthand arguments resolve through their string bindings.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const cmd = \"git status --short\"; const workdir = \"$cx_workdir\"; await tools.exec_command({cmd, workdir, yield_time_ms:10000});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Bytes typed into a shell a previous call started are read as a command line like any other.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_call write_stdin '{"session_id":1,"chars":"cat header > bin/cx-typed-in\n"}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A tool this reader does not know: node's own REPL, a spawned subagent, an MCP server's write —
# each can put bytes on disk under no name the rollout carries.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_call js '{"code":"nodeRepl.write(1)"}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: js)' \
  <<<"$(transcript_report "$RUN_DIR")"
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_row '{"type": "mcp_tool_call_end", "invocation": {"server": "s", "tool": "fs.write"}}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: fs.write)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A resumed codex session appends to the rollout it already had, and the cut is the run's own start.
clear_stub
export STUB_SLEEP=0.3
start_ok codex
run_started=$(jq -r '.started_at' "$RUN_DIR/meta.json")
CX_TS=$(iso $((run_started - 7200)))
cx_patch_event "$cx_workdir/bin/cx-before-the-resume" '' true >"$CX_ROLLOUT"
CX_TS=$(iso "$run_started")
cx_patch_event "$cx_workdir/bin/cx-at-the-start" '' true >>"$CX_ROLLOUT"
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-at-the-start' <<<"$report"
unset STUB_SLEEP

# Codex mutating rows with unusable timestamps fail closed just like Gemini rows.
clear_stub
CX_TS=not-a-timestamp
cx_patch_event "$cx_workdir/bin/cx-unparseable-time" '' true >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$(transcript_report "$RUN_DIR")"

# An unusable timestamp on a classified read-only call remains read-only.
clear_stub
CX_TS=not-a-timestamp
cx_call view_image '{"path":"fixture.png"}' >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A walled attempt's edits stay the run's after the reroute: the rescue's transcript names only its own.
clear_stub
dirt_repo_init
CX_TS=$(iso $(($(date +%s) + 60)))
mkdir -p "$CODEX_PROFILES_DIR/wall/sessions/fixture" "$CODEX_PROFILES_DIR/rescue/sessions/fixture"
cx_patch_event "$DIRT_TOP/bin/cx-walled-attempt" '' true >"$CODEX_PROFILES_DIR/wall/sessions/fixture/rollout-wall-session.jsonl"
cx_patch_event "$DIRT_TOP/bin/cx-rescue-attempt" '' true >"$CODEX_PROFILES_DIR/rescue/sessions/fixture/rollout-codex-session.jsonl"
printf 'wall\n' >"$STUB_DIR/wall_accounts"
PICK_ACCOUNT=rescue STUB_WALL_SESSION=wall-session CLAUDE_CODE_SESSION_ID=chat-abc start_gated codex --account wall --workdir "$DIRT_REPO"
printf 'walled attempt\n' >"$DIRT_REPO/bin/cx-walled-attempt"
printf 'rescue attempt\n' >"$DIRT_REPO/bin/cx-rescue-attempt"
gate_open
assert await_done
assert grep -qx 'REROUTE: walled on wall → continued on rescue' <<<"$("$RUNNER" report "$RUN_ID")"
assert grep -qx 'bin/cx-walled-attempt' "$RUN_DIR/files"
assert grep -qx 'bin/cx-rescue-attempt' "$RUN_DIR/files"
assert_fails grep -q 'cx-walled-attempt' "$RUN_DIR/files-note"

assert grep -E '^\| am \|.*record_workdir_escape.*workdir_escape_line' "$ROOT/docs/shared-invariants.md" >/dev/null

clear_stub
printf 'not json {\n' >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$(transcript_report "$RUN_DIR")"
rm -f "$CX_ROLLOUT"
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_ACCOUNT=recordacct

# A failed run wrote whatever it wrote before it died, and that is the launching chat's work too.
clear_stub
export STUB_CODE=9 STUB_ERROR='plain failure'
start_ok claudeb
assert await_done
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $(jq -r '.workdir' "$RUN_DIR/meta.json")"
unset STUB_CODE STUB_ERROR

# A record is written even when there is nothing to put in it — here, a run that could not reach its
# own workdir. No record at all is what an unfinished run looks like, and both readers take that
# absence for "this run wrote nothing", which is the one answer that is certainly wrong.
clear_stub
start_ok claudeb
assert await_done
jq '.workdir = null' "$RUN_DIR/meta.json" >"$WORK/meta.noworkdir" &&
  mv "$WORK/meta.noworkdir" "$RUN_DIR/meta.json"
rm -f "$RUN_DIR/files"
"$RUNNER" _supervise "$RUN_DIR" >/dev/null 2>&1
assert grep -qx 'UNKNOWN: the run recorded no workdir to resolve its files against' "$RUN_DIR/files"
assert test "$(grep -c '^WORKDIR: ' "$RUN_DIR/files")" -eq 0

# No chat to answer for it, or an id that cannot be compared as one: the run is nobody's rather than
# somebody's by accident.
clear_stub
unset CLAUDE_CODE_SESSION_ID
start_ok claudeb
assert await_done
assert test ! -e "$RUN_DIR/launcher"
export CLAUDE_CODE_SESSION_ID='../elsewhere'
clear_stub
start_ok claudeb
assert await_done
assert test ! -e "$RUN_DIR/launcher"
unset CLAUDE_CODE_SESSION_ID
# An id the vendor never printed is never guessed at either: no file at all, which reads as "this
# run's own journal entries cannot be found" rather than as somebody else's session.
clear_stub
export STUB_SESSION=''
start_ok claudeb
assert await_done
assert test ! -e "$RUN_DIR/worker-session"
unset STUB_SESSION

# A RESUMED run's worker session is known before its first token — the session keeps the id it
# already had — and the gate that prices a live run's worker work reads this file while the run is
# going. Written only when the attempt ends, everything that session journals in the meantime is
# priced as nobody's, which is the hole the pair on record exists to close.
clear_stub
export STUB_SESSION=resumed-session STUB_SLEEP=0.5
RESUME_TAGS="$HOME/.cache/claude-worker-tags/chat-resume"
mkdir -p "$RESUME_TAGS"
printf 'seed · opus · high\nstart=%s\n' "$(date +%s)" >"$RESUME_TAGS/agent-resumed"
CLAUDE_LAUNCHER_SESSION=chat-resume start_ok claudeb --account resumeacct --resume resumed-session
assert test "$(cat "$RUN_DIR/worker-session")" = resumed-session
assert await_done
# And once per id, however many times the record is rewritten over it.
assert test "$(grep -c . "$RUN_DIR/worker-session")" -eq 1
# Its one attempt line is written at launch, so it names the agent the launch claimed.
assert test "$(jq -r --arg run "$RUN_ID" 'select(.run == $run) | .agent' "$CLAUDEB_DIR/worker-stats/worker-attempts.jsonl" | paste -sd, -)" = agent-resumed
unset STUB_SESSION STUB_SLEEP

# "429" only counts as a limit signature with digit boundaries: an error id that
# merely contains it stays an ordinary failure.
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9 STUB_ERROR='request failed, incident 42903'
start_ok claudeb
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_FAILED' "$WORK/wait.out"
clear_stub
export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9 STUB_ERROR='HTTP 429 too many requests'
start_ok claudeb
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_USAGE_LIMIT' "$WORK/wait.out"

# A resumed session stays on its account: the session lives there, so the WALL line says so
# rather than sending the orchestrator hunting a pool that was never consulted.
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export STUB_CODE=9 STUB_ERROR='usage limit reached'
start_ok claudeb --account pinacct --resume resumed-session
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: resumed session stays on pinacct' "$WORK/wait.out"
assert test "$(grep -c '^REROUTE:' "$WORK/wait.out")" -eq 0
assert test ! -s "$PICK_LOG"

# A pid that outlives its run (reboot reuse, supervisor killed before writing
# exit_code) must not report "running" forever once the deadline is long past.
clear_stub
STALE_DIR="$WORKER_RUN_DIR/codex-9-9-aaaa"
mkdir -p "$STALE_DIR"
: >"$STALE_DIR/out"
: >"$STALE_DIR/err"
jq -cn --argjson pid "$$" '{vendor:"codex",account:"stale",pid:$pid,started_at:1000}' >"$STALE_DIR/meta.json"
stale_wait=$("$RUNNER" wait codex-9-9-aaaa --max 0)
assert grep -q '^STATUS: failed$' <<<"$stale_wait"
assert grep -q '^EXIT: unknown$' <<<"$stale_wait"
stale_report=$("$RUNNER" report codex-9-9-aaaa)
assert grep -q '^STATUS: failed$' <<<"$stale_report"

# A pid is not a supervisor. The number is reused within a day on a busy machine, and whatever
# inherits it answers a signal probe exactly as the supervisor would — so the launch instant the
# record stamped is compared against the process's own start, the way the review hooks judge these
# same runs. A run reading "running" here while they read it as gone is a chat told to wait forever.
clear_stub
sleep 120 &
LIVE_SUPERVISOR=$!
RECYCLED_DIR="$WORKER_RUN_DIR/codex-9-9-bbbb"
mkdir -p "$RECYCLED_DIR"
: >"$RECYCLED_DIR/out"
: >"$RECYCLED_DIR/err"
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"recycled",pid:$pid,started_at:$now,pid_started_at:1000}' \
  >"$RECYCLED_DIR/meta.json"
recycled_wait=$("$RUNNER" wait codex-9-9-bbbb --max 0)
assert grep -q '^STATUS: failed$' <<<"$recycled_wait"
assert grep -q '^EXIT: unknown$' <<<"$recycled_wait"
recycled_report=$("$RUNNER" report codex-9-9-bbbb)
assert grep -q '^STATUS: failed$' <<<"$recycled_report"
# The same live pid whose start MATCHES the stamp is the supervisor itself, and it is left alone.
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"recycled",pid:$pid,started_at:$now,pid_started_at:$now}' \
  >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: running$' <<<"$("$RUNNER" report codex-9-9-bbbb)"
# A record written before the launch stamp existed has nothing to compare and keeps the old answer:
# every run started before that field went in would otherwise begin reading dead.
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"legacy",pid:$pid,started_at:$now}' >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: running$' <<<"$("$RUNNER" report codex-9-9-bbbb)"
# A night run that queued for its slot keeps its launch as started_at; its deadline runs from slot_at.
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"legacy",pid:$pid,started_at:1000,slot_at:$now}' >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: running$' <<<"$("$RUNNER" report codex-9-9-bbbb)"
# A ps that cannot answer at all — a sandbox that hides other processes, a fork that failed —
# prints exactly what "no such process" prints, and reading that as death reports a live run
# failed. The signal probe, which this otherwise never uses, answers where ps cannot.
mkdir -p "$WORK/blind-ps"
printf '#!/bin/sh\nexit 1\n' >"$WORK/blind-ps/ps"
chmod +x "$WORK/blind-ps/ps"
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"recycled",pid:$pid,started_at:$now,pid_started_at:1000}' \
  >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: running$' <<<"$(PATH="$WORK/blind-ps:$PATH" "$RUNNER" report codex-9-9-bbbb)"
# The pid that decides whether ps can answer at all cannot be our own: a sandbox that hides every
# process but this one still lists it, and that is exactly where a supervisor of another session
# reads gone.
mkdir -p "$WORK/self-ps"
printf '#!/bin/sh\ncase " $* " in *" -p 1 "*|*" -p %s "*) exit 0 ;; esac\necho "   01:00"\n' \
  "$LIVE_SUPERVISOR" >"$WORK/self-ps/ps"
chmod +x "$WORK/self-ps/ps"
assert grep -q '^STATUS: running$' <<<"$(PATH="$WORK/self-ps:$PATH" "$RUNNER" report codex-9-9-bbbb)"
# The probe still answers about the process: a pid nothing is behind reads gone, blind ps or not.
GONE_PID=$(sh -c 'echo $$')
while kill -0 "$GONE_PID" 2>/dev/null; do GONE_PID=$((GONE_PID + 1)); done
jq -cn --argjson pid "$GONE_PID" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"recycled",pid:$pid,started_at:$now,pid_started_at:$now}' \
  >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: failed$' <<<"$(PATH="$WORK/blind-ps:$PATH" "$RUNNER" report codex-9-9-bbbb)"
kill "$LIVE_SUPERVISOR" 2>/dev/null
wait "$LIVE_SUPERVISOR" 2>/dev/null
rm -rf "$RECYCLED_DIR"



echo "PASS: $asserts asserts; gemini and codex transcript file lists, launchers, stale and recycled runs"
