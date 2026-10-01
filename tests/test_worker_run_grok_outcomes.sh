#!/usr/bin/env bash
. "$(dirname "$0")/worker_run_harness.sh"
grok_workdir=$(cd "$WORK/workdir" && pwd -P)

# A vendor switched off for workers is a decision, not a wall: the sentence handed back must be the
# one every other vendor gives, vendor word apart, or a relay reads a closed role as an outage.
clear_stub
set_config 'gemini_workers=off' 'gemini_model=flash38' 'gemini_effort=high'
export PICK_RC=0 PICK_ACCOUNT=picked
printf 'picked\n' >"$STUB_DIR/gemini_profiles"
"$RUNNER" start gemini --brief "$WORK/brief" --account picked \
  >"$WORK/off-gemini.out" 2>"$WORK/off-gemini.err" || :
set_config 'grok_workers=off' 'grok_effort=high'
"$RUNNER" start grok --brief "$WORK/brief" --account picked \
  >"$WORK/off-grok.out" 2>"$WORK/off-grok.err" || :
grok_off=$(grep 'switched off for workers' "$WORK/off-grok.err")
assert test -n "$grok_off"
assert test "${grok_off/grok/gemini}" = "$(grep 'switched off for workers' "$WORK/off-gemini.err")"
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/off-grok.out"
assert test ! -s "$CALL_LOG"
clear_stub
set_config 'grok_workers=off' 'grok_profile=picked' 'grok_effort=high'
start_ok grok --account picked
assert meta_account_is picked
assert await_done

clear_stub
set_config 'grok_effort=high'
grok_pool=$(pool_dir_for grok)
mkdir -p "$grok_pool"
printf 'benched\n' >"$grok_pool/disabled"
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --account benched >"$WORK/grok-pool.out" 2>"$WORK/grok-pool.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/grok-pool.out"
assert grep -q 'benched is out of the worker pool' "$WORK/grok-pool.err"
assert test ! -s "$CALL_LOG"
# The vendor pin is the one override, here as for every other vendor: it names an account on
# purpose, so the pool's consent wall steps aside for it.
set_config 'grok_profile=benched' 'grok_effort=high'
start_ok grok --account benched
assert meta_account_is benched
assert await_done
rm -f "$grok_pool/disabled"

# Only the PERSISTENT wording walls an account, and an unpinned run continues on the next one
# before the outcome ever reaches the caller.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=unused
printf 'gwall1\n' >"$STUB_DIR/grok_wall_accounts"
printf '%s\n' '0 gwall1' '0 grescue1' >"$STUB_DIR/pick_queue"
start_ok grok
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert meta_account_is grescue1
assert jq -e '.walled_accounts == ["gwall1"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on gwall1 → continued on grescue1' "$WORK/wait.out"
assert grep -qx -- '--account grok --claim --exclude gwall1' "$PICK_LOG"
assert test "$(grep -c '^GROK_CALL$' "$CALL_LOG")" -eq 2

# ALL WALLED is the only way the usage-limit outcome still reaches the caller.
clear_stub
printf '%s\n' gwall1 gwall2 >"$STUB_DIR/grok_wall_accounts"
printf '%s\n' '0 gwall1' '0 gwall2' '3' >"$STUB_DIR/pick_queue"
start_ok grok
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert grep -qx 'OUTCOME: GROK_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: pool exhausted (walled: gwall1, gwall2)' "$WORK/wait.out"
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 1

# A picker that already knows every grok account is walled ends `start` on the limit exit, and a pin
# is no way around a wall it never consulted.
clear_stub
set_config 'grok_effort=high' 'grok_profile=grokpin'
export PICK_RC=3 PICK_ACCOUNT=ignored
rc=0
"$RUNNER" start grok --brief "$WORK/brief" >"$WORK/grok-wall.out" 2>"$WORK/grok-wall.err" || rc=$?
assert test "$rc" -eq 3
assert grep -qx 'OUTCOME: GROK_USAGE_LIMIT' "$WORK/grok-wall.out"
assert test ! -s "$CALL_LOG"

# Every other persistent wording says the same thing, and the CLI's transient classes say something
# else entirely: xAI folds 429 and 5xx into the same internal rate-limit class as a real wall, so a
# bare "rate limit" here would report an exhausted plan on every bad minute.
for grok_spec in 'You have hit the rate limit for your plan:GROK_USAGE_LIMIT' \
  'error: subscription:free-usage-exhausted:GROK_USAGE_LIMIT' \
  'Your team has run out of credits:GROK_USAGE_LIMIT' \
  "You've reached your free Grok Build usage limit for now:GROK_USAGE_LIMIT" \
  'You’ve reached your free Grok Build usage limit for now:GROK_USAGE_LIMIT' \
  'request failed with status 402 Payment Required:GROK_USAGE_LIMIT' \
  'request failed with status 429 Too Many Requests:GROK_UNAVAILABLE' \
  'upstream returned status 503:GROK_UNAVAILABLE' \
  'rate limit exceeded, Retry-After: 30:GROK_UNAVAILABLE'; do
  grok_error=${grok_spec%:*}
  grok_outcome=${grok_spec##*:}
  clear_stub
  set_config 'grok_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=grokwording STUB_CODE=1 STUB_ERROR="$grok_error"
  start_ok grok
  assert await_done
  assert grep -qx "OUTCOME: $grok_outcome" "$WORK/wait.out"
  if [ "$grok_outcome" = GROK_UNAVAILABLE ]; then
    assert grep -qx 'REASON: transient — capacity weather, not a wall; the brief may be relaunched' \
      "$WORK/wait.out"
  fi
done

# An expired login needs a human and says so: relaunching it anywhere spends nothing but time.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokauth STUB_CODE=0
: >"$STUB_DIR/grok_auth"
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/wait.out"
assert grep -qx 'REASON: auth — the account needs a human login (grokb add <account>)' "$WORK/wait.out"
assert test "$(grep -c '^GROK_CALL$' "$CALL_LOG")" -eq 1

# A run that outran its turn budget answered nothing, but the vendor served every turn it was asked
# for: folded into GROK_UNAVAILABLE it reads as capacity weather, and the orchestrator reroutes a
# brief that will outrun the same budget wherever it lands next.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokturns
: >"$STUB_DIR/grok_max_turns"
export WORKER_RUN_GROK_MAX_TURNS=5 STUB_GROK_TURNS=5
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_MAX_TURNS' "$WORK/wait.out"
assert test "$(grep -c 'GROK_UNAVAILABLE' "$WORK/wait.out")" -eq 0
assert grep -qx 'REASON: max-turns — the brief outran --max-turns (5); the vendor answered fine, so relaunching it whole buys nothing' \
  "$WORK/wait.out"
assert test "$(grep -c '^GROK_CALL$' "$CALL_LOG")" -eq 1
assert grep -qx 'OUTCOME: GROK_MAX_TURNS' <<<"$("$RUNNER" report "$RUN_ID")"
unset WORKER_RUN_GROK_MAX_TURNS STUB_GROK_TURNS

# With no cap asked for, the cap that ended the run was the CLI's own, so the REASON names no number
# of ours — the outcome is still the vendor serving, not an outage.
clear_stub
: >"$STUB_DIR/grok_max_turns"
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_MAX_TURNS' "$WORK/wait.out"
assert grep -q '^REASON: max-turns — the brief outran --max-turns (?);' "$WORK/wait.out"

# The vendor refusing a NEW session: two handshake events, a cancelled end, exit 0 and an empty
# stderr. Exit 0 alone reported it as a finished run and handed the orchestrator an empty result
# (live 2026-09-08). It is weather, so no wall is recorded and the pin stays honorable.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokcancel STUB_CODE=0
: >"$STUB_DIR/grok_cancelled"
start_ok grok
assert await_done
assert grep -qx 'STATUS: failed' "$WORK/wait.out"
assert grep -qx "OUTCOME: GROK_CANCELLED $RUN_ID" "$WORK/wait.out"
assert grep -qx 'REASON: cancelled — grok ended the session before its first turn; capacity weather, not a wall: pause and relaunch once' \
  "$WORK/wait.out"
assert test "$(grep -c 'GROK_UNAVAILABLE\|GROK_USAGE_LIMIT' "$WORK/wait.out")" -eq 0
assert test ! -e "$WORKER_WALLS_DIR/grok-grokcancel"
assert grep -qx "OUTCOME: GROK_CANCELLED $RUN_ID" <<<"$("$RUNNER" report "$RUN_ID")"
assert grep -qx 'STATUS: failed' <<<"$("$RUNNER" report "$RUN_ID")"

# One tool call in front of the same cancelled end is an ordinary run that ended: the classifier
# reads the FIRST turn-or-end event, never the stop reason alone.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokcancel STUB_CODE=0
: >"$STUB_DIR/grok_cancelled"
: >"$STUB_DIR/grok_cancelled_worked"
start_ok grok
assert await_done
assert grep -qx 'STATUS: done' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME: ' "$WORK/wait.out")" -eq 0
clear_stub

# A wall stated mid-run arrives as an `error` event on stdout, where every other vendor puts it on
# stderr: read on stderr alone this run reports an outage while the plan is actually exhausted.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokevent STUB_CODE=1 \
  STUB_GROK_ERROR_EVENT='You have hit the rate limit for your plan'
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_USAGE_LIMIT' "$WORK/wait.out"

# A failed run whose ANSWER discusses quotas is a plain failure: this repository's own briefs are
# about walls, and the scan reads stderr and the stream's `error` events, never the agent's text.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokchatty STUB_CODE=5 \
  STUB_GROK_ANSWER='You have hit the credit limit for your plan is what the docs say'
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/wait.out"

# A tool the permission policy refused ends the run normally and is neither a wall nor a failure —
# but a thin result is unreadable without knowing something was refused.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokdenied
: >"$STUB_DIR/grok_denied"
start_ok grok
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0
assert jq -e '.denied_tools == 1' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'DENIED-TOOLS: 1' <<<"$("$RUNNER" report "$RUN_ID")"
# `wait` is what a relay worker actually reads back, so the count has to survive that path too.
assert grep -qx 'DENIED-TOOLS: 1' "$WORK/wait.out"

# The agent quotes the refusal back in its own answer — live-observed, and the whole reason the count
# is read off the failed tool_call_update: the denial is stated once however often the text repeats it.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokdenied \
  STUB_GROK_ANSWER='I could not run it: Tool `run_terminal_command` was not executed: Denied by permission policy: deny rule on bash'
: >"$STUB_DIR/grok_denied"
start_ok grok
assert await_done
assert jq -e '.denied_tools == 1' "$RUN_DIR/meta.json" >/dev/null

# A run that only DISCUSSES a refusal was refused nothing: this repository's own briefs quote the
# sentence verbatim, and a stream scanned as text reports a denial no policy ever made.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokquoting \
  STUB_GROK_ANSWER='The gate answers with `Tool `x` was not executed: Denied by permission policy` when a deny rule matches'
start_ok grok
assert await_done
assert jq -e 'has("denied_tools") | not' "$RUN_DIR/meta.json" >/dev/null
assert test "$(grep -c '^DENIED-TOOLS:' <<<"$("$RUNNER" report "$RUN_ID")")" -eq 0
assert test "$(grep -c '^DENIED-TOOLS:' "$WORK/wait.out")" -eq 0

# grok names the files it wrote in its own session record, filed under the URL-encoded cwd it ran
# in: an id found by globbing can belong to a session from another directory entirely, so the
# session's own summary.json is checked against this run's workdir before a single path is claimed.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokfiles
GROK_SESSION=01a05811-7788-7d22-a9c9-c028072cbff5
grok_encode() { printf '%s' "$1" | jq -sRr @uri; }
GROK_UPDATES="$GROKB_PROFILES_DIR/grokfiles/sessions/$(grok_encode "$grok_workdir")/$GROK_SESSION/updates.jsonl"
mkdir -p "$(dirname "$GROK_UPDATES")"
grok_summary() { jq -n --arg d "$1" '{info: {cwd: $d}}' >"$(dirname "$GROK_UPDATES")/summary.json"; }
grok_call() { # id name kind read-only input-json
  jq -cn --argjson ts "$GROK_TS" --arg id "$1" --arg name "$2" --arg kind "$3" \
    --argjson ro "$4" --argjson input "$5" \
    '{timestamp: $ts, method: "session/update", params: {sessionId: "s", update: {
       sessionUpdate: "tool_call", toolCallId: $id, status: "in_progress", rawInput: $input,
       _meta: {"x.ai/tool": {name: $name, kind: $kind, read_only: $ro}}}}}'
}
grok_update() { # id status [current-dir]
  jq -cn --argjson ts "$GROK_TS" --arg id "$1" --arg status "$2" --arg dir "${3:-}" \
    '{timestamp: $ts, method: "session/update", params: {sessionId: "s", update: {
       sessionUpdate: "tool_call_update", toolCallId: $id, status: $status,
       rawOutput: (if $dir == "" then null else {current_dir: $dir} end)}}}'
}
GROK_TS=$(($(date +%s) + 60))
grok_summary "$grok_workdir"
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-written" '{file_path: $p}')"
  grok_update w1 completed
  grok_call e1 search_replace edit false "$(jq -cn --arg p "$WORK/outside/grok-absolute" '{file_path: $p}')"
  grok_update e1 completed
  grok_call r1 read_file read true "$(jq -cn --arg p "$grok_workdir/bin/grok-only-read" '{file_path: $p}')"
  grok_update r1 completed
  grok_call c1 run_terminal_command execute false "$(jq -cn '{command: "git status --short"}')"
  grok_update c1 completed "$grok_workdir"
  grok_call p1 todo_write plan false '{"todos": []}'
  grok_update p1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 2' <<<"$report"
assert grep -qx 'RUN-FILE: bin/grok-written' <<<"$report"
assert grep -qxF "RUN-FILE: $WORK/outside/grok-absolute" <<<"$report"
assert test "$(grep -c 'grok-only-read' <<<"$report")" -eq 0
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"
assert test ! -e "$RUN_DIR/workdir-escape"

# A refused write changed nothing and cannot make the successful call beside it review debt.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-kept" '{file_path: $p}')"
  grok_update w1 completed
  grok_call w2 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-refused" '{file_path: $p}')"
  grok_update w2 failed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/grok-kept' <<<"$report"
assert test "$(grep -c 'grok-refused' <<<"$report")" -eq 0

# A tool this reader cannot classify leaves the run unanswerable rather than short by one file, and
# an unknown tool is the ordinary case: the vendor keeps adding them.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-written" '{file_path: $p}')"
  grok_update w1 completed
  grok_call i1 image_gen other false '{}'
  grok_update i1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: image_gen)' \
  <<<"$(transcript_report "$RUN_DIR")"

# The dispatcher tool answers for what it dispatched: a shell through it is a shell.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call u1 use_tool other false \
    "$(jq -cn '{tool_name: "bash", tool_input: {command: "printf x > out.txt"}}')"
  grok_update u1 completed "$grok_workdir"
} >"$GROK_UPDATES"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A mutating row with no usable time cannot be silently dropped out of the run's window.
clear_stub
GROK_TS=null
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-timeless" '{file_path: $p}')"
  grok_update w1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A session record filed under another directory is not this run's, however well the id matches.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-elsewhere" '{file_path: $p}')"
  grok_update w1 completed
} >"$GROK_UPDATES"
grok_summary "$WORK/extra"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx "RUN-FILES: unknown (no session transcript for $GROK_SESSION)" <<<"$(transcript_report "$RUN_DIR")"
# With no summary.json at all the encoded directory name is what answers, and it answers for this
# run: a record whose own cwd cannot be read is not a licence to claim it.
rm -f "$(dirname "$GROK_UPDATES")/summary.json"
clear_stub
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILE: bin/grok-elsewhere' <<<"$(transcript_report "$RUN_DIR")"

# No record at all is unknown too, and never the workdir.
clear_stub
mv "$GROK_UPDATES" "$GROK_UPDATES.moved"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx "RUN-FILES: unknown (no session transcript for $GROK_SESSION)" <<<"$(transcript_report "$RUN_DIR")"
mv "$GROK_UPDATES.moved" "$GROK_UPDATES"

# Nothing inside the workdir at all is the one failure a launcher cannot see: a green run over an
# untouched directory.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call w1 write write false "$(jq -cn --arg p "$WORK/extra/grok-went-elsewhere" '{file_path: $p}')"
  grok_update w1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qxF "WORKDIR-ESCAPE: the run named no path inside its own workdir; it worked in $WORK/extra/grok-went-elsewhere" \
  <<<"$report"
assert grep -qxF "$WORK/extra/grok-went-elsewhere" "$RUN_DIR/workdir-escape"
rm -rf "$GROKB_PROFILES_DIR/grokfiles"


echo "PASS: $asserts asserts; grok switched off, pools, outcomes, denials and its own file lists"
