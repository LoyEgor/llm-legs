#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# shards: 4
# Runs on an edit of the worker-run modules it exercises (tests/affected): share/worker-run-lifecycle.sh
# share/worker-run-pool.sh share/worker-run-watchdog.sh
. "$(dirname "$0")/worker_run_harness.sh" || exit 1

effort_refused() {
  local vendor="$1" model="$2" effort="$3" rc=0 runs_before
  shift 3
  clear_stub
  runs_before=$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --model "$model" --effort "$effort" "$@" \
    >"$WORK/effort.out" 2>"$WORK/effort.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/effort.out"
  assert grep -Fq "$vendor model $model does not allow effort $effort" "$WORK/effort.err"
  assert test ! -s "$CALL_LOG"
  assert test ! -s "$PICK_LOG"
  assert test "$runs_before" = "$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  assert test "$(tail -n1 "$WORKER_RUN_DIR/prelaunch.jsonl" | jq -r '"\(.outcome) \(.vendor) \(.ts | type)"')" = \
    "EFFORT_REFUSED $vendor number"
}

model_effort_tests() {
  local spec vendor model effort
  set_config
  export PICK_RC=0 PICK_ACCOUNT=picked
  for spec in codex:astra:low codex:sol:medium claudeb:opus:high claudeb:fable:low gemini:flash38:high grok:auto:high grok:grok-4.6:high; do
    vendor=${spec%%:*}; model=${spec#*:}; effort=${model##*:}; model=${model%:*}
    clear_stub
    start_ok "$vendor" --model "$model" --account "$([ "$vendor" = gemini ] && printf main || printf com)"
    assert await_exit
    assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = "$model"
    assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = "$effort"
  done
  assert test "$(jq -r '.model_id' "$RUN_DIR/meta.json")" = null
  clear_stub
  start_ok codex --account main
  assert await_exit
  assert grep -qx 'ARG=model_reasoning_effort=low' "$CALL_LOG"
  assert test "$(jq -r '[.model, .model_id] | join(" ")' "$RUN_DIR/meta.json")" = 'astra gpt-6.1-astra'
  assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
  assert grep -qx 'main · astra · low' "$RUN_DIR/tag"
  set_config 'codex_effort=high'
  clear_stub
  start_ok codex --account main
  assert await_exit
  assert grep -qx 'ARG=model_reasoning_effort=high' "$CALL_LOG"
  for spec in codex:astra:xhigh codex:gpt-5.6-sol:low claudeb:fable:max claudeb:opus:low; do
    vendor=${spec%%:*}; model=${spec#*:}; effort=${model##*:}; model=${model%:*}
    clear_stub
    start_ok "$vendor" --model "$model" --effort "$effort" --account com
    assert await_exit
    assert grep -qx "ARG=$([ "$model" = astra ] && printf gpt-6.1-astra || printf %s "$model")" "$CALL_LOG"
    assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = "$effort"
    if [ "$model" = gpt-5.6-sol ]; then
      assert grep -qx 'ARG=-m' "$CALL_LOG"
      assert grep -qx 'ARG=model_reasoning_effort=low' "$CALL_LOG"
      assert grep -qx 'com · sol · low' "$RUN_DIR/tag"
    fi
  done
  set_config 'claudeb_model=fable'
  clear_stub
  start_ok claudeb --account com
  assert await_exit
  assert grep -qx 'ARG=fable' "$CALL_LOG"
  assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = low
  set_config
  clear_stub
}

# Its own section: the header and refusal cases launch few runs, and model_effort_tests' launches alone fill a shard.
effort_header_tests() {
  local spec vendor model effort
  set_config 'claudeb_model=fable'
  export PICK_RC=0 PICK_ACCOUNT=picked
  # The brief's EFFORT: is the run's effort like its ACCOUNT: and MODEL:, and a flag that contradicts
  # a header line refuses: a relay's dropped `--effort` once launched a Fable `EFFORT: high` brief on low.
  cp "$WORK/brief" "$WORK/brief.noheader"
  { printf 'MODEL: fable\nEFFORT: high\n\n'; cat "$WORK/brief.noheader"; } >"$WORK/brief"
  clear_stub
  start_ok claudeb --account com
  assert await_exit
  assert test "$(jq -r '[.model, .effort] | join(" ")' "$RUN_DIR/meta.json")" = 'fable high'
  for flag in '--effort low' '--model opus'; do
    clear_stub
    rc=0
    # shellcheck disable=SC2086
    "$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir" --account com $flag >"$WORK/effort.out" 2>&1 || rc=$?
    assert test "$rc" -eq 4
    assert grep -qF -e "$flag contradicts the brief header" "$WORK/effort.out"
    assert test ! -s "$CALL_LOG"
  done
  # A research run reads the same header: it once ran an `EFFORT: high` brief on the low default.
  set_config 'codex_effort=low' 'light_paused=on'
  { printf 'EFFORT: high\n\n'; cat "$WORK/brief.noheader"; } >"$WORK/brief"
  clear_stub
  start_ok codex --account com --role research --research-timeout 5m
  assert await_exit
  assert test "$(jq -r '[.role, .effort] | join(" ")' "$RUN_DIR/meta.json")" = 'research high'
  assert grep -qx 'ARG=model_reasoning_effort=high' "$CALL_LOG"
  clear_stub
  rc=0
  "$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" --account com --role research --effort low >"$WORK/effort.out" 2>&1 || rc=$?
  assert test "$rc" -eq 4
  assert grep -qF -e "--effort low contradicts the brief header" "$WORK/effort.out"
  assert test ! -s "$CALL_LOG"
  set_config 'claudeb_model=fable'
  { printf 'STRONG: yes\n\n'; cat "$WORK/brief.noheader"; } >"$WORK/brief"
  for vendor in gemini light; do
    clear_stub
    rc=0
    "$RUNNER" start "$vendor" --brief "$WORK/brief" --workdir "$WORK/workdir" >"$WORK/effort.out" 2>&1 || rc=$?
    assert test "$rc" -eq 4
    assert grep -qF "the brief header 'STRONG: yes' takes no Light or Gemini Flash worker" "$WORK/effort.out"
    assert test ! -s "$CALL_LOG"
  done
  # With no MODEL: line the configured gemini_model is the run's model, and pro is no Flash worker.
  set_config 'gemini_model=pro'
  clear_stub
  start_ok gemini --account main
  assert await_exit
  assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = pro
  set_config 'claudeb_model=fable'
  clear_stub
  start_ok codex --account main
  assert await_exit
  mv "$WORK/brief.noheader" "$WORK/brief"
  # `gemini:flash38:ultra` and not `xhigh`: every effort the table knows is RAISED to high on a
  # Gemini leg, so only a word that is no effort at all can be refused there.
  for spec in codex:astra:max codex:gpt-5.6-sol:max claudeb:opus:ultra gemini:flash38:ultra grok:auto:low grok:grok-4.6:medium; do
    vendor=${spec%%:*}; model=${spec#*:}; effort=${model##*:}; model=${model%:*}
    effort_refused "$vendor" "$model" "$effort"
  done
  effort_refused codex astra max --account main --resume codex-resume
  effort_refused claudeb opus ultra --account com --resume claude-resume
  effort_refused gemini flash38 ultra --account main --resume gemini-resume
  effort_refused grok auto low --account com --resume grok-resume
  set_config 'codex_effort=max'
  clear_stub
  rc=0
  "$RUNNER" start codex --brief "$WORK/brief" >"$WORK/effort.out" 2>&1 || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/effort.out"
  assert test ! -s "$PICK_LOG"
  assert test ! -s "$CALL_LOG"
  clear_stub
  start_ok codex --account main --resume codex-resume
  assert await_exit
  assert_fails grep -q '^ARG=model_reasoning_effort=' "$CALL_LOG"
  effort_refused codex astra max --account main --resume codex-resume
  set_config
  clear_stub
}

report_bus_tests() {
  local CLAUDE_CODE_SESSION_ID=report-launcher CLAUDE_LAUNCHER_SESSION=report-launcher
  local WORKER_RUN_IDLE_S=0 WORKER_RUN_SILENT_S=0 WORKER_RUN_DEADLINE=600
  local PICK_RC=0 PICK_ACCOUNT=reportacct rc old_id
  export CLAUDE_CODE_SESSION_ID CLAUDE_LAUNCHER_SESSION WORKER_RUN_IDLE_S WORKER_RUN_SILENT_S WORKER_RUN_DEADLINE PICK_RC PICK_ACCOUNT
  set_config 'codex_effort=high'

  local place_repo="$WORK/place-repo" place_top
  git init -q "$place_repo"
  place_top=$(cd "$place_repo" && pwd -P)
  clear_stub
  TMPDIR=/nonexistent WORKER_TEST_WORKDIR=$place_repo start_ok codex --account reportacct
  assert await_exit
  assert test "$(cut -f2,3 "$HOME/.cache/claude-statusline/place-report-launcher" | tr '\t' ' ')" = "worker-start $place_top
worker-end $place_top"

  clear_stub
  rc=0
  PICK_RC=3 "$RUNNER" start codex --brief "$WORK/brief" >"$WORK/report-limit.out" 2>"$WORK/report-limit.err" || rc=$?
  assert test "$rc" = 3
  assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/report-limit.out"
  assert test -z "$(sed -n 's/^RUN: //p' "$WORK/report-limit.out")"

  clear_stub
  start_gated codex --account reportacct
  old_id=$RUN_ID
  rc=0
  WORKER_RUN_ALLOW_DUPLICATE=0 "$RUNNER" start codex --account reportacct --brief "$WORK/brief" >"$WORK/report-duplicate.out" 2>&1 || rc=$?
  assert test "$rc" = 4
  assert grep -qx "OUTCOME: DUPLICATE_RUN $old_id" "$WORK/report-duplicate.out"
  gate_open
  assert await_exit
  clear_stub
}
if suite_shard_owns 2 report-bus; then
  report_bus_tests
fi


# Start and wait belong to the chat that owns the run; a headless worker holds none of its own.
door_refused() { # expected-text env-assignments... -- worker-run-args...
  local expected="$1" rc=0 runs_before
  shift
  local assignments=()
  while [ "$1" != -- ]; do assignments+=("$1"); shift; done
  shift
  clear_stub
  runs_before=$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDEB_WORKER -u GROK_WORKER -u WORKER_RUN_ID "${assignments[@]}" \
    "$RUNNER" "$@" >"$WORK/door.out" 2>"$WORK/door.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -Fq -- "$expected" "$WORK/door.err"
  assert test ! -s "$CALL_LOG"
  assert test ! -s "$PICK_LOG"
  assert test "$runs_before" = "$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"
}

worker_door_tests() {
  local owner='runs from the chat that owns the run, never inside a headless worker' gate="$WORK/limit-gate"
  set_config
  export PICK_RC=0 PICK_ACCOUNT=picked
  door_refused "$owner" CLAUDEB_WORKER=1 -- start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir"
  door_refused "$owner" CLAUDEB_WORKER=1 -- wait claudeb-1-1-abcd --max 0
  door_refused "$owner" GROK_WORKER=1 -- start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir"
  door_refused "$owner" CLAUDECODE=1 WORKER_RUN_ID=codex-1-1-abcd -- start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir"
  door_refused "$owner" WORKER_RUN_ID=codex-1-1-abcd -- wait claudeb-1-1-abcd --max 0
  # Inside Claude Code the chat's start passes the limit gate on its own brief first.
  cat >"$gate" <<'GATE'
#!/bin/sh
printf '%s\n' "$*" >>"$LIMIT_GATE_LOG"
case "$LIMIT_GATE_MODE" in
  deny) printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"Blocked: claudeb is walled."}}\n' ;;
  note) printf '{"hookSpecificOutput":{"additionalContext":"Claude account picked is at 90%%."}}\n' ;;
esac
GATE
  chmod +x "$gate"
  export WORKER_RUN_LIMIT_GATE="$gate" LIMIT_GATE_LOG="$WORK/limit-gate.log"
  : >"$LIMIT_GATE_LOG"
  door_refused 'Blocked: claudeb is walled. Nothing was launched and no account was spent.' CLAUDECODE=1 LIMIT_GATE_MODE=deny -- \
    start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir"
  assert test "$(cat "$LIMIT_GATE_LOG")" = "--start claudeb $WORK/brief"
  # A Computer Use run is priced under its own role, flag or brief line alike.
  : >"$LIMIT_GATE_LOG"
  door_refused 'Blocked: claudeb is walled.' CLAUDECODE=1 LIMIT_GATE_MODE=deny -- \
    start codex --computer --brief "$WORK/brief" --workdir "$WORK/workdir"
  assert test "$(cat "$LIMIT_GATE_LOG")" = "--start computer $WORK/brief"
  # A browser run is priced under the browser role of its vendor, flag or brief line alike.
  : >"$LIMIT_GATE_LOG"
  door_refused 'Blocked: claudeb is walled.' CLAUDECODE=1 LIMIT_GATE_MODE=deny -- \
    start codex --browser --brief "$WORK/brief" --workdir "$WORK/workdir"
  assert test "$(cat "$LIMIT_GATE_LOG")" = "--start codex-browser $WORK/brief"
  printf 'BROWSER: chrome\ntest brief\n' >"$WORK/browser-brief"
  : >"$LIMIT_GATE_LOG"
  door_refused 'Blocked: claudeb is walled.' CLAUDECODE=1 LIMIT_GATE_MODE=deny -- \
    start claudeb --brief "$WORK/browser-brief" --workdir "$WORK/workdir"
  assert test "$(cat "$LIMIT_GATE_LOG")" = "--start claudeb-browser $WORK/browser-brief"
  clear_stub
  CLAUDECODE=1 LIMIT_GATE_MODE=note start_ok claudeb
  assert grep -Fqx 'worker-run: note: Claude account picked is at 90%.' "$WORK/start.err"
  local output
  # The exit code paces the poll; one `wait` through the door reads the end, not one a tick.
  await_exit || fail "the noted claudeb run never exited"
  output=$(CLAUDECODE=1 "$RUNNER" wait "$RUN_ID" --max 0)
  assert grep -q '^STATUS: done' <<<"$output"
  assert test "$(cat "$STUB_DIR/background_env")" = "__unset__ 1500000 1500000"
  assert grep -q '^CLAUDEB_CALL$' "$CALL_LOG"
  assert test "$(grep -A1 -xF 'ARG=--disallowedTools' "$CALL_LOG" | tail -n +2)" = 'ARG=WebSearch\,WebFetch\,ScheduleWakeup\,CronCreate\,Workflow\,ListAgents\,Agent'
  : >"$LIMIT_GATE_LOG"
  clear_stub
  CLAUDE_CODE_ENTRYPOINT=cli start_ok codex
  assert grep -Fqx -- "--start codex $WORK/brief" "$LIMIT_GATE_LOG"
  await_exit
  # The gate judges the account --account names, not the router's pick.
  : >"$LIMIT_GATE_LOG"
  clear_stub
  CLAUDE_CODE_ENTRYPOINT=cli start_ok codex --account main
  assert grep -Fqx -- "--start codex $WORK/brief main" "$LIMIT_GATE_LOG"
  await_exit
  # Outside Claude Code (Egor's terminal, the night's scripts) no gate is asked.
  : >"$LIMIT_GATE_LOG"
  clear_stub
  start_ok claudeb
  assert test ! -s "$LIMIT_GATE_LOG"
  await_exit
  unset WORKER_RUN_LIMIT_GATE LIMIT_GATE_LOG
}

nested_model_tests() {
  local parent="$WORK/fable-parent"
  mkdir -p "$parent"
  printf '{"vendor":"claudeb","model":"fable"}\n' >"$parent/meta.json"
  door_refused 'nested in a Fable worker and would hand its brief to claudeb opus' WORKER_RUN_RECORD="$parent" -- \
    start claudeb --model opus --account com --brief "$WORK/brief" --workdir "$WORK/workdir"
  assert grep -qx 'OUTCOME: NESTED_MODEL_REFUSED' "$WORK/door.out"
  door_refused 'nested in a Fable worker and would hand its brief to codex astra' WORKER_RUN_RECORD="$parent" -- \
    start codex --model astra --account main --brief "$WORK/brief" --workdir "$WORK/workdir"
  clear_stub
  WORKER_RUN_RECORD="$parent" start_ok claudeb --model fable --account com
  assert await_exit
  printf '{"vendor":"claudeb","model":"opus"}\n' >"$parent/meta.json"
  clear_stub
  WORKER_RUN_RECORD="$parent" start_ok claudeb --model opus --account com
  assert await_exit
}

off_roster_tests() {
  local rc=0
  roster_add gemini tronjhon
  printf 'ACCOUNT: tronjhon\n\nwork\n' >"$WORK/cross-brief"
  clear_stub
  "$RUNNER" start claudeb --brief "$WORK/cross-brief" --workdir "$WORK/workdir" >"$WORK/cross.out" 2>&1 || rc=$?
  assert test "$rc" -eq 2
  assert grep -qF 'unknown account: tronjhon (not on the claudeb roster' "$WORK/cross.out"
  assert test ! -s "$CALL_LOG"
  assert test ! -e "$HOME/.cache/worker-claims/claudeb/tronjhon"
  for vendor in codex gemini grok; do
    rc=0
    "$RUNNER" start "$vendor" --brief "$WORK/brief" --workdir "$WORK/workdir" --account nosuch >"$WORK/cross.out" 2>&1 || rc=$?
    assert test "$rc" -eq 2
    assert grep -qF "unknown account: nosuch (not on the $vendor roster" "$WORK/cross.out"
  done
  assert test ! -s "$CALL_LOG"
}

own_headroom_tests() (
  asserts=0
  unset CLAUDEGPT_ACCOUNT CLAUDE_CONFIG_DIR
  export CLAUDE_LIMITS_ACCOUNT=com LLM_LIMITS_FILE="$WORK/headroom.json"
  export WORKER_RUN_OWN_HEADROOM=60
  local spec pct age target override expected rc before
  set_config 'claudeb_model=opus' 'claudeb_effort=high'
  for spec in '75 0 com default allow' '85 0 com default refuse' '50 0 com 60 allow' '55 1200 com 60 refuse' '90 0 other 60 allow' '65 0 com 0 allow' '60 0 com 60 refuse' 'null 0 com 60 allow' '90 0 com 60 resume'; do
    read -r pct age target override expected <<<"$spec"
    clear_stub
    export PICK_RC=0 PICK_ACCOUNT=other WORKER_RUN_OWN_HEADROOM=$override
    [ "$override" != default ] || unset WORKER_RUN_OWN_HEADROOM
    jq -n --argjson pct "$pct" --argjson now "$(date +%s)" --argjson age "$age" '
      {vendors:{claude:{accounts:[{account:"com",five_hour:{used_pct:$pct,as_of:($now-$age),resets_at:($now+3600)}},
        {account:"other",five_hour:{used_pct:90,as_of:$now,resets_at:($now+3600)}}]}}}' >"$LLM_LIMITS_FILE"
    if [ "$expected" = refuse ]; then
      before=$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
      rc=0
      "$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir" --account "$target" >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
      assert test "$rc" -ne 0
      assert grep -qF "own-account headroom: claude/com 5h $pct%" "$WORK/start.err"
      assert grep -qF 'use claude/other' "$WORK/start.err"
      assert grep -qF 'обойди» lifts it, for one launch: WORKER_RUN_OWN_HEADROOM=0' "$WORK/start.err"
      assert test "$(wc -l <"$WORK/start.err")" -eq 1
      assert test ! -s "$CALL_LOG"
      assert test "$before" = "$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"
      assert grep -qx -- '--account claudeb --role workers --exclude com' "$PICK_LOG"
      [ "$age" = 0 ] || assert grep -qF 'age 20m, +10 points' "$WORK/start.err"
    else
      if [ "$expected" = resume ]; then start_ok claudeb --account "$target" --resume existing-session
      else start_ok claudeb --account "$target"; fi
      assert await_exit
    fi
  done
  clear_stub
  export PICK_RC=3 WORKER_RUN_OWN_HEADROOM=60
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir" --account com >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
  assert test "$rc" -ne 0
  assert grep -qE 'wait for the 5h reset at ((Sun|Mon|Tue|Wed|Thu|Fri|Sat) )?[0-9]{2}:[0-9]{2}' "$WORK/start.err"
  assert test ! -s "$CALL_LOG"
  export CLAUDEGPT_ACCOUNT=com
  start_ok claudeb --account com
  assert await_exit
  echo "PASS: $asserts asserts; own-account headroom"
)

if suite_shard_owns 4 own-headroom; then own_headroom_tests || exit 1; fi
if suite_shard_owns 1 model-effort; then model_effort_tests; fi
if suite_shard_owns 2 effort-header; then effort_header_tests; fi
if suite_shard_owns 3 door-nested-roster; then
  worker_door_tests
  nested_model_tests
  off_roster_tests
fi

# A start reads eight header keys: a head|grep|sed pipeline each was 24 forks before any launch.
mkdir -p "$WORK/fork-shim"
for tool in head grep sed; do
  printf '#!/bin/sh\necho %s >>"%s"\nexit 1\n' "$tool" "$WORK/forks.log" >"$WORK/fork-shim/$tool"
done
chmod +x "$WORK/fork-shim"/*
printf 'RESUME x:\nACCOUNT:\tcom\r\nEFFORT: high\n' >"$WORK/header-brief"
eval "$(sed -n '/^brief_line_value() {/,/^}/p' "$ROOT/share/worker-run-brief.sh")"
assert test "$(PATH="$WORK/fork-shim:$PATH" brief_line_value "$WORK/header-brief" ACCOUNT)" = com
assert test "$(PATH="$WORK/fork-shim:$PATH" brief_line_value "$WORK/header-brief" EFFORT)" = high
assert test ! -e "$WORK/forks.log"

suite_shard_pass "$asserts"
