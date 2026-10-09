#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
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
    assert await_done
    assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = "$model"
    assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = "$effort"
  done
  assert test "$(jq -r '.model_id' "$RUN_DIR/meta.json")" = null
  clear_stub
  start_ok codex --account main
  assert await_done
  assert grep -qx 'ARG=model_reasoning_effort=low' "$CALL_LOG"
  assert test "$(jq -r '[.model, .model_id] | join(" ")' "$RUN_DIR/meta.json")" = 'astra gpt-6.1-astra'
  assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
  assert grep -qx 'main · astra · low' "$RUN_DIR/tag"
  set_config 'codex_effort=high'
  clear_stub
  start_ok codex --account main
  assert await_done
  assert grep -qx 'ARG=model_reasoning_effort=high' "$CALL_LOG"
  for spec in codex:astra:xhigh codex:gpt-5.6-sol:low claudeb:fable:max claudeb:opus:low; do
    vendor=${spec%%:*}; model=${spec#*:}; effort=${model##*:}; model=${model%:*}
    clear_stub
    start_ok "$vendor" --model "$model" --effort "$effort" --account com
    assert await_done
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
  assert await_done
  assert grep -qx 'ARG=fable' "$CALL_LOG"
  assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = low
  # The brief's EFFORT: is the run's effort like its ACCOUNT: and MODEL:, and a flag that contradicts
  # a header line refuses: a relay's dropped `--effort` once launched a Fable `EFFORT: high` brief on low.
  cp "$WORK/brief" "$WORK/brief.noheader"
  { printf 'MODEL: fable\nEFFORT: high\n\n'; cat "$WORK/brief.noheader"; } >"$WORK/brief"
  clear_stub
  start_ok claudeb --account com
  assert await_done
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
  assert await_done
  set_config 'claudeb_model=fable'
  clear_stub
  start_ok codex --account main
  assert await_done
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
  assert await_done
  assert_fails grep -q '^ARG=model_reasoning_effort=' "$CALL_LOG"
  effort_refused codex astra max --account main --resume codex-resume
  set_config
  clear_stub
}

report_bus_tests() {
  local CLAUDE_CODE_SESSION_ID=report-launcher CLAUDE_LAUNCHER_SESSION=report-launcher
  local WORKER_RUN_IDLE_S=0 WORKER_RUN_SILENT_S=0 WORKER_RUN_DEADLINE=600
  local PICK_RC=0 PICK_ACCOUNT=reportacct rc old_id old_dir
  export CLAUDE_CODE_SESSION_ID CLAUDE_LAUNCHER_SESSION WORKER_RUN_IDLE_S WORKER_RUN_SILENT_S WORKER_RUN_DEADLINE PICK_RC PICK_ACCOUNT
  set_config 'codex_effort=high'

  local place_repo="$WORK/place-repo" place_top
  git init -q "$place_repo"
  place_top=$(cd "$place_repo" && pwd -P)
  clear_stub
  TMPDIR=/nonexistent WORKER_TEST_WORKDIR=$place_repo start_ok codex --account reportacct
  assert await_done
  TMPDIR=/nonexistent "$RUNNER" report "$RUN_ID" >/dev/null
  "$RUNNER" wait "$RUN_ID" --max 0 >/dev/null
  assert test "$(cut -f2,3 "$HOME/.cache/claude-statusline/place-report-launcher" | tr '\t' ' ')" = "worker-start $place_top
worker-end $place_top"

  clear_stub
  rc=0
  PICK_RC=3 "$RUNNER" start codex --brief "$WORK/brief" >"$WORK/report-limit.out" 2>"$WORK/report-limit.err" || rc=$?
  assert test "$rc" = 3
  assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/report-limit.out"
  assert test -z "$(sed -n 's/^RUN: //p' "$WORK/report-limit.out")"

  clear_stub
  STUB_SLEEP=60 start_ok codex --account reportacct
  old_id=$RUN_ID old_dir=$RUN_DIR
  rc=0
  WORKER_RUN_ALLOW_DUPLICATE=0 "$RUNNER" start codex --account reportacct --brief "$WORK/brief" >"$WORK/report-duplicate.out" 2>&1 || rc=$?
  assert test "$rc" = 4
  assert grep -qx "OUTCOME: DUPLICATE_RUN $old_id" "$WORK/report-duplicate.out"
  kill -TERM "$(jq -r .pid "$old_dir/meta.json")"
  assert await_done
  "$RUNNER" report "$old_id" >/dev/null
  clear_stub
}
report_bus_tests
# A finished worker posts nothing to Egor's chat; its outcome is the chat's to read through its report.
assert test ! -s "$REPORT_BUS_LOG"


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
  clear_stub
  CLAUDECODE=1 LIMIT_GATE_MODE=note start_ok claudeb
  assert grep -Fqx 'worker-run: note: Claude account picked is at 90%.' "$WORK/start.err"
  local output index
  for index in $(seq 1 100); do
    output=$(CLAUDECODE=1 "$RUNNER" wait "$RUN_ID" --max 0)
    grep -q '^STATUS: done\|^STATUS: failed' <<<"$output" && break
    sleep 0.05
  done
  assert grep -q '^STATUS: done' <<<"$output"
  assert test "$(cat "$STUB_DIR/background_env")" = "1 1500000 1500000"
  assert grep -q '^CLAUDEB_CALL$' "$CALL_LOG"
  assert test "$(grep -A1 -xF 'ARG=--disallowedTools' "$CALL_LOG" | tail -n +2)" = 'ARG=WebSearch\,WebFetch\,ScheduleWakeup\,CronCreate'
  : >"$LIMIT_GATE_LOG"
  clear_stub
  CLAUDE_CODE_ENTRYPOINT=cli start_ok codex
  assert grep -Fqx -- "--start codex $WORK/brief" "$LIMIT_GATE_LOG"
  await_done
  # The gate judges the account --account names, not the router's pick.
  : >"$LIMIT_GATE_LOG"
  clear_stub
  CLAUDE_CODE_ENTRYPOINT=cli start_ok codex --account main
  assert grep -Fqx -- "--start codex $WORK/brief main" "$LIMIT_GATE_LOG"
  await_done
  # Outside Claude Code (Egor's terminal, the night's scripts) no gate is asked.
  : >"$LIMIT_GATE_LOG"
  clear_stub
  start_ok claudeb
  assert test ! -s "$LIMIT_GATE_LOG"
  await_done
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
  assert await_done
  printf '{"vendor":"claudeb","model":"opus"}\n' >"$parent/meta.json"
  clear_stub
  WORKER_RUN_RECORD="$parent" start_ok claudeb --model opus --account com
  assert await_done
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

model_effort_tests
worker_door_tests
nested_model_tests
off_roster_tests

echo "PASS: $asserts asserts; the report bus, effort refusals before launch, the worker door refusing a headless worker's start and wait, and the limit gate a chat's start passes (deny refuses unlaunched, a note rides on stderr, none asked outside Claude Code), an ACCOUNT off the vendor roster refused unlaunched"
