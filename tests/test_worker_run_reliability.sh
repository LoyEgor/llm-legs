#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"

reliability_cleanup() {
  local meta pid
  for meta in "$WORK/reliability-runs"/*/meta.json; do
    [ -f "$meta" ] && [ ! -e "${meta%/meta.json}/exit_code" ] || continue
    while IFS= read -r pid; do
      [ "$pid" -gt 1 ] || continue
      if [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ]; then
        kill -TERM -- "-$pid" 2>/dev/null || :
      fi
      kill -TERM "$pid" 2>/dev/null || :
    done < <(jq -r '.cli_pid // 0, .pid // 0' "$meta")
  done
}
trap 'reliability_cleanup; rm -rf "$WORK"' EXIT

reliability_case() { [ -z "${WORKER_RUN_TEST_CASE:-}" ] || [ "$WORKER_RUN_TEST_CASE" = "$1" ]; }
reliability_tests() {
  local WORKER_RUN_DIR="$WORK/reliability-runs" WORKER_RUN_IDLE_S=0 WORKER_RUN_SILENT_S=0 WORKER_RUN_WALL_SETTLE_S=0
  local WORKER_RUN_DEADLINE=10 CLAUDE_CODE_SESSION_ID=reliability-launcher
  local PICK_RC=0 PICK_ACCOUNT=rescue STUB_WALL_SLEEP=8 STUB_WALL_TEXT
  local old_id old_dir result rc started cli_pid child_pid fixture live_pid
  export WORKER_RUN_DIR WORKER_RUN_IDLE_S WORKER_RUN_SILENT_S WORKER_RUN_DEADLINE WORKER_RUN_WALL_SETTLE_S
  export CLAUDE_CODE_SESSION_ID PICK_RC PICK_ACCOUNT STUB_WALL_SLEEP
  mkdir -p "$WORKER_RUN_DIR"
  set_config 'codex_effort=high'

  if reliability_case R1; then
    clear_stub
    fixture="$WORK/live-edits"
    mkdir -p "$fixture"
    git -C "$fixture" init -q
    mkdir -p "$WORK/live-edits-gate"
    STUB_GATE="$WORK/live-edits-gate/go" STUB_SESSION=live-edits STUB_TRANSCRIPT_SESSION=live-edits \
      STUB_TRANSCRIPT_ACCOUNT=edits STUB_EDIT_PATH=owned WORKER_RUN_IDLE_S=3 WORKER_RUN_DEADLINE=120 \
      start_ok claudeb --account edits --workdir "$fixture"
    for started in 1 2 3 4 5 6; do
      printf '%s\n' "$started" >"$fixture/owned"
      assert test ! -e "$RUN_DIR/files"
      sleep 1
    done
    : >"$WORK/live-edits-gate/go"
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert test ! -e "$RUN_DIR/killed"
    assert grep -qx owned "$RUN_DIR/files"
  fi

  if reliability_case R2; then
    (
      eval "$(sed -n '/^record_run_wall() {/,/^}/p' "$RUNNER")"
      . "$ROOT/share/worker-walls.sh"
      worker_model_clear_walled_pin() { :; }
      date() { printf '%s\n' "$(cat "$WORK/wall-clock")"; }
      fixture="$WORK/wall-epoch"
      mkdir -p "$fixture"
      printf '{"account":"epoch"}\n' >"$fixture/meta.json"
      printf '1\n' >"$fixture/attempt"
      : >"$fixture/out"
      for text in 'resets in 2 hours' ''; do
        printf '%s\n' "$text" >"$fixture/err"
        printf '1000000\n' >"$WORK/wall-clock"
        record_run_wall "$fixture" codex
        epoch=$(sed -n 1p "$WORKER_WALLS_DIR/codex-epoch")
        [ "$(sed -n 2p "$WORKER_WALLS_DIR/codex-epoch")" = 1000000 ] || exit 1
        printf '1000120\n' >"$WORK/wall-clock"
        record_run_wall "$fixture" codex
        [ "$(sed -n 1p "$WORKER_WALLS_DIR/codex-epoch")" = "$epoch" ] || exit 1
        [ "$(sed -n 2p "$WORKER_WALLS_DIR/codex-epoch")" = 1000120 ] || exit 1
        printf '%s\n' "$(( $(cat "$fixture/attempt") + 1 ))" >"$fixture/attempt"
        record_run_wall "$fixture" codex
        [ "$(sed -n 1p "$WORKER_WALLS_DIR/codex-epoch")" -gt "$epoch" ] || exit 1
        printf '%s\n' "$(( $(cat "$fixture/attempt") + 1 ))" >"$fixture/attempt"
      done
    )
    assert test "$?" -eq 0
  fi

  # The watchdog's wall fires the armed redeem from inside its own tree, which is killed whole the
  # moment the CLI exits; reroute_walled's second record then reads no reset text.
  if reliability_case R2-redeem; then
    (
      eval "$(sed -n '/^record_run_wall() {/,/^}/p' "$RUNNER")"
      . "$ROOT/share/worker-walls.sh"
      . "$ROOT/share/processes.sh"
      worker_model_clear_walled_pin() { sleep 2; }
      SCRIPT_DIRECTORY="$WORK/redeem-bin" WORKER_RUN_ID=redeem-run
      export WORKER_RUN_ID
      mkdir -p "$SCRIPT_DIRECTORY" "$CLAUDEB_DIR/reset-arm" "$WORK/redeem-wall"
      printf '#!/bin/bash\nsleep 1\nprintf "%%s %%s\\n" "$*" "${WORKER_RUN_ID:-unset}" >>"%s"\n' "$WORK/redeem.log" \
        >"$SCRIPT_DIRECTORY/llm-reset-redeem"
      chmod +x "$SCRIPT_DIRECTORY/llm-reset-redeem"
      : >"$CLAUDEB_DIR/reset-arm/codex-armed"
      printf '{"account":"armed"}\n' >"$WORK/redeem-wall/meta.json"
      printf '1\n' >"$WORK/redeem-wall/attempt"
      : >"$WORK/redeem-wall/out"
      printf 'ERROR: usage limit, resets in 72 hours\n' >"$WORK/redeem-wall/err"
      ( record_run_wall "$WORK/redeem-wall" codex; sleep 30 ) & watchdog=$!
      for _ in $(seq 1 600); do [ ! -e "$WORK/redeem-wall/wall-reset.1" ] || break; sleep 0.05; done
      process_tree_end "$watchdog" 0
      wait "$watchdog" 2>/dev/null
      record_run_wall "$WORK/redeem-wall" codex
      for _ in $(seq 1 300); do [ "$(cat "$WORK/redeem.log" 2>/dev/null)" = '--fire-armed codex/armed --wall weekly unset' ] && break; sleep 0.1; done
      [ "$(cat "$WORK/redeem.log" 2>/dev/null)" = '--fire-armed codex/armed --wall weekly unset' ]
    )
    assert test "$?" -eq 0
    rm -f "$CLAUDEB_DIR/reset-arm/codex-armed"
  fi

  if reliability_case R3; then
    clear_stub
    : >"$STUB_DIR/codex_bad_model_always"
    STUB_PICK_WALL=1 start_ok codex --account model
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' <<<"$result"
    assert_fails grep -q 'REROUTE\|KILLED: wall' <<<"$result"
    assert test ! -s "$PICK_LOG"
    assert test ! -e "$WORKER_WALLS_DIR/codex-model"
  fi

  if reliability_case R3-default; then
    for resume in '' default-session; do
      clear_stub
      start_ok codex --account model --model default --resume "$resume"
      assert await_done
      assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
      assert_fails grep -qx 'ARG=default' "$CALL_LOG"
    done
  fi

  if reliability_case R3-retry; then
    clear_stub
    : >"$STUB_DIR/codex_bad_model"
    start_ok codex --account model
    assert await_done
    assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
    assert_fails grep -q '^ARG=model=' "$CALL_LOG"
    clear_stub
    : >"$STUB_DIR/codex_bad_model"
    # config.toml is Egor's interactive pick: a terra there changes nothing about the retry,
    # which takes the worker default's slug.
    printf 'model = "gpt-5.6-terra"\n' >"$WORKER_RUN_CODEX_CONFIG"
    start_ok codex --account model --model sol
    assert await_done
    assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
    assert grep -qxF 'ARG=model=\"gpt-6.1-astra\"' "$CALL_LOG"
    assert_fails grep -q 'terra' "$CALL_LOG"
    assert_fails grep -qx 'OUTCOME: CODEX_UNAVAILABLE' "$WORK/wait.out"
    printf 'model = "gpt-6-astra"\n' >"$WORKER_RUN_CODEX_CONFIG"
  fi

  if reliability_case A-mtime; then
    (
      eval "$(sed -n '/^newest_mtime() {/,/^}/p' "$RUNNER")"
      stat() {
        [ "$1" != -f ] || { printf 'filesystem info\n'; return 1; }
        case "$3" in out) printf '100\n' ;; err) printf '200\n' ;; *) return 1 ;; esac
      }
      [ "$(newest_mtime out err missing)" = 200 ]
    )
    assert test "$?" -eq 0
  fi

  if reliability_case A-heartbeat; then
    clear_stub
    cat >"$WORK/bin/heartbeat-grokb" <<'EOF'
#!/usr/bin/env bash
if [ "$2" = wall ]; then
  printf '%s\n' '{"type":"error","message":"You have hit the credit limit for your plan."}'
  while :; do printf 'heartbeat\n' >&2; sleep 0.2; done
fi
printf '%s\n' '{"type":"end","sessionId":"heartbeat-rescue","stopReason":"end_turn"}'
EOF
    chmod +x "$WORK/bin/heartbeat-grokb"
    WORKER_RUN_GROKB="$WORK/bin/heartbeat-grokb" WORKER_RUN_WALL_SETTLE_S=60 start_ok grok --account wall
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert grep -qx 'REROUTE: walled on wall → continued on rescue' <<<"$result"
    assert test "$(sed -n 1p "$WORKER_WALLS_DIR/grok-wall")" -gt "$(date +%s)"
  fi

  if reliability_case A; then
    clear_stub
    printf 'wall\n' >"$STUB_DIR/wall_accounts"
    start_ok codex --account wall
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert grep -qx 'REROUTE: walled on wall → continued on rescue' <<<"$result"
    assert test "$(sed -n 1p "$WORKER_WALLS_DIR/codex-wall")" -gt "$(date +%s)"
    assert test "$(cat "$RUN_DIR/attempt")" = 2
    assert_fails kill -0 "$(cat "$STUB_DIR/wall.pid")"
    assert_fails kill -0 "$(cat "$STUB_DIR/wall.child.pid")"
  fi

  if reliability_case A-echo; then
    clear_stub
    printf 'wall\n' >"$STUB_DIR/wall_accounts"
    STUB_WALL_ECHO=5 WORKER_RUN_WALL_SETTLE_S=3 start_ok codex --account wall
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert_fails grep -q 'REROUTE\|KILLED' <<<"$result"
    assert test ! -e "$RUN_DIR/killed"
    assert test ! -e "$WORKER_WALLS_DIR/codex-wall"
    unset STUB_WALL_ECHO
  fi

  # A limit phrase in a file the worker just read is no wall, however long the stream then stays quiet.
  if reliability_case A-quoted; then
    clear_stub
    printf 'wall\n' >"$STUB_DIR/wall_accounts"
    STUB_WALL_TEXT='| a row this worker read: rate limit reached' STUB_WALL_ECHO=3 start_ok codex --account wall
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert_fails grep -q 'REROUTE\|KILLED' <<<"$result"
    assert test ! -e "$WORKER_WALLS_DIR/codex-wall"
  fi

  if reliability_case A-resume; then
    clear_stub
    printf 'wall\n' >"$STUB_DIR/wall_accounts"
    start_ok codex --account wall --resume wall-session
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'KILLED: wall — vendor usage limit detected' <<<"$result"
    assert grep -qx 'WALL: resumed session stays on wall' <<<"$result"
    assert grep -qx wall "$RUN_DIR/killed"
    assert test ! -s "$PICK_LOG"
  fi

  if reliability_case B; then
    clear_stub
    export STUB_SLEEP=60
    WORKER_RUN_SILENT_S=2 WORKER_RUN_DEADLINE=120 start_ok codex --account silent
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'KILLED: silent — no output in 2s' <<<"$result"
    assert grep -qx 'silent 2' "$RUN_DIR/killed"
    assert test ! -s "$RUN_DIR/out"
    assert test ! -s "$RUN_DIR/err"
    assert test ! -e "$WORKER_WALLS_DIR/codex-silent"
    unset STUB_SLEEP
    start_ok codex --account silent --resume silent-session
    assert await_done
    assert grep -qx 'STATUS: done' "$WORK/wait.out"
    export STUB_SLEEP=3
    WORKER_RUN_SILENT_S=0 start_ok codex --account silent
    assert await_done
    assert grep -qx 'STATUS: done' "$WORK/wait.out"
    unset STUB_SLEEP
  fi

  if reliability_case C; then
    clear_stub
    export STUB_SLEEP=120
    WORKER_RUN_DEADLINE=600 start_ok codex --account busy --resume busy-session
    old_id=$RUN_ID old_dir=$RUN_DIR
    assert grep -qx busy-session "$old_dir/worker-session"
    rc=0
    "$RUNNER" start codex --brief "$WORK/brief" --account busy --resume busy-session >"$WORK/busy.out" 2>&1 || rc=$?
    assert test "$rc" -eq 4
    assert grep -qx "OUTCOME: RESUME_BUSY $old_id" "$WORK/busy.out"
    assert grep -qx "WAIT: worker-run wait $old_id (as a background Bash)" "$WORK/busy.out"
    kill -TERM "$(jq -r '.pid' "$old_dir/meta.json")"
    "$RUNNER" wait "$old_id" --max 60 >/dev/null
    unset STUB_SLEEP
    start_ok codex --account busy --resume busy-session
    assert await_done
    assert grep -qx 'STATUS: done' "$WORK/wait.out"
  fi

  if reliability_case D; then
    clear_stub
    # The first run must still be live at the nested check after two more whole runs; only the kill
    # below may end it, never its own sleep or the section's 10 s deadline on a loaded machine.
    export STUB_SLEEP=120
    WORKER_RUN_DEADLINE=600 start_ok codex --account duplicate
    old_id=$RUN_ID old_dir=$RUN_DIR
    rc=0
    WORKER_RUN_ALLOW_DUPLICATE=0 "$RUNNER" start codex --brief "$WORK/brief" --account duplicate >"$WORK/duplicate.out" 2>&1 || rc=$?
    assert test "$rc" -eq 4
    assert grep -qx "OUTCOME: DUPLICATE_RUN $old_id" "$WORK/duplicate.out"
    assert grep -qx "WAIT: worker-run wait $old_id (as a background Bash)" "$WORK/duplicate.out"
    jq '.light = "research"' "$old_dir/meta.json" >"$WORK/meta.research" && mv "$WORK/meta.research" "$old_dir/meta.json"
    rc=0
    WORKER_RUN_ALLOW_DUPLICATE=0 "$RUNNER" start codex --brief "$WORK/brief" --account duplicate >"$WORK/duplicate.out" 2>&1 || rc=$?
    jq 'del(.light)' "$old_dir/meta.json" >"$WORK/meta.research" && mv "$WORK/meta.research" "$old_dir/meta.json"
    assert test "$rc" -eq 4
    assert grep -qx "WAIT: light-research --attach $old_id --out <answer-file> (as a background Bash)" "$WORK/duplicate.out"
    unset STUB_SLEEP
    WORKER_RUN_ALLOW_DUPLICATE=1 start_ok codex --account duplicate
    assert await_done
    assert grep -qx 'STATUS: done' "$WORK/wait.out"
    CLAUDE_CODE_SESSION_ID=another-launcher WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate
    assert await_done
    rc=0
    CLAUDE_CODE_SESSION_ID=nested-worker CLAUDE_LAUNCHER_SESSION=reliability-launcher WORKER_RUN_ALLOW_DUPLICATE=0 \
      "$RUNNER" start codex --brief "$WORK/brief" --account duplicate >"$WORK/duplicate.out" 2>&1 || rc=$?
    assert test "$rc" -eq 4
    assert grep -qx "OUTCOME: DUPLICATE_RUN $old_id" "$WORK/duplicate.out"
    printf 'different brief\n' >"$WORK/different-brief"
    WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate --brief "$WORK/different-brief"
    assert await_done
    kill -TERM "$(jq -r '.pid' "$old_dir/meta.json")"
    "$RUNNER" wait "$old_id" --max 60 >/dev/null
    WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate
    assert await_done
    fixture="$WORKER_RUN_DIR/old-live"
    mkdir -p "$fixture"
    sleep 600 & live_pid=$!
    cp "$WORK/brief" "$fixture/brief"
    printf '%s\n' "$CLAUDE_CODE_SESSION_ID" >"$fixture/launcher"
    jq -cn --argjson pid "$live_pid" --argjson start "$(($(date +%s) - 1800))" '{pid:$pid,started_at:$start}' >"$fixture/meta.json"
    WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate
    assert await_done
    kill "$live_pid"
    wait "$live_pid" 2>/dev/null || :
    WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate
    assert await_done
    printf '0\n' >"$fixture/exit_code"
  fi

  if reliability_case E1; then
    clear_stub
    printf 'main\n' >"$STUB_DIR/wall_accounts"
    printf '2\n0 rescue\n' >"$STUB_DIR/pick_queue"
    export STUB_WALL_TEXT='worker-pick: no selectable codex account (main 0%/d ×7d WALLED)'
    start_ok codex
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert grep -qx 'REROUTE: walled on main → continued on rescue' <<<"$result"
    unset STUB_WALL_TEXT
  fi

  if reliability_case E2; then
    clear_stub
    fixture="$WORK/reliability-repo"
    mkdir -p "$fixture"
    git -C "$fixture" init -q
    export STUB_SLEEP=8
    WORKER_RUN_IDLE_S=2 WORKER_RUN_DEADLINE=120 start_ok codex --account wedged --workdir "$fixture"
    # Edited until the run ends: counted as its activity, they keep it alive past STUB_SLEEP's clean exit.
    for started in $(seq 1 40); do
      [ ! -e "$RUN_DIR/exit_code" ] || break
      printf '%s\n' "$started" >"$fixture/cotenant-edit"
      sleep 0.5
    done
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -q '^KILLED: idle watchdog' <<<"$result"
    unset STUB_SLEEP
  fi

  if reliability_case E3; then
    clear_stub
    export STUB_SLEEP=60
    WORKER_RUN_DEADLINE=120 start_ok codex --account main
    for started in $(seq 1 1200); do [ -s "$STUB_DIR/codex.child.pid" ] && break; sleep 0.05; done
    cli_pid=$(cat "$STUB_DIR/codex.pid")
    child_pid=$(cat "$STUB_DIR/codex.child.pid")
    kill -TERM "$(jq -r '.pid' "$RUN_DIR/meta.json")"
    result=$("$RUNNER" wait "$RUN_ID" --max 60)
    assert grep -qx term "$RUN_DIR/killed"
    assert grep -q '^KILLED: signal TERM' <<<"$result"
    assert_fails kill -0 "$cli_pid"
    assert_fails kill -0 "$child_pid"
    unset STUB_SLEEP
  fi

  if reliability_case E4; then
    . "$ROOT/share/worker-pool.sh"
    fixture="$WORK/reliability-pool"
    mkdir -p "$fixture/shielded"
    : >"$fixture/shielded/main"
    reliability_names() { printf 'main\nother\n'; }
    worker_pool_set_all "$fixture" fixture reliability_names on >/dev/null
    assert grep -qx main "$fixture/disabled"
    assert grep -qx other "$fixture/disabled"
    rm "$fixture/shielded/main"
    assert worker_pool_is_disabled "$fixture" main
  fi
  clear_stub
}
reliability_tests

echo "PASS: $asserts asserts; supervisor reliability: live edits, duplicates, walls, deadlines, pool shields"
