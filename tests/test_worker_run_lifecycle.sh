#!/usr/bin/env bash
. "$(dirname "$0")/worker_run_harness.sh"

clear_stub
set_config 'codex_effort=high'
export PICK_ACCOUNT=fast PICK_RC=0 STUB_GATE="$WORK/start-gate"
# Not wall time, which load inflates: a start that waits on its worker returns only once the timer
# opens the gate, and the running asserts below fail; the budget is the start's own CPU.
(sleep 60; : >"$STUB_GATE") &
gate_timer=$!
TIMEFORMAT='%U %S'
{ time start_ok codex 2>&3; } 3>&2 2>"$WORK/start.cpu"
assert test "$(awk '{ printf "%d", ($1 + $2) * 1000 }' "$WORK/start.cpu")" -lt 2000
assert test "$(wc -l <"$WORK/start.out" | tr -d ' ')" -eq 4
assert grep -Eq '^RUN: codex-[0-9]+-[0-9]+-[0-9a-f]{4}$' "$WORK/start.out"
assert grep -qx 'TAG: fast · astra · high' "$WORK/start.out"
assert grep -qx 'WEB: off' "$WORK/start.out"
assert grep -qx "DIR: $RUN_DIR" "$WORK/start.out"
pid=$(jq -r '.pid' "$RUN_DIR/meta.json")
assert kill -0 "$pid"
first_wait=$("$RUNNER" wait "$RUN_ID" --max 1)
assert grep -q '^STATUS: running$' <<<"$first_wait"
assert grep -q '^SESSION: -$' <<<"$first_wait"
assert kill -0 "$pid"
assert test ! -e "$RUN_DIR/exit_code"
kill "$gate_timer"
: >"$STUB_GATE"
second_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: done$' <<<"$second_wait"
assert grep -q '^SESSION: codex-session$' <<<"$second_wait"
# A terminal wait names the answer and never quotes it: the relay reads `report` next in any case,
# and a tail here handed the orchestrator the same result twice.
assert grep -qxF "RESULT: run \`worker-run report $RUN_ID\`" <<<"$second_wait"
assert test "$(grep -c 'codex result' <<<"$second_wait")" -eq 0
assert grep -qx 'codex result' <<<"$("$RUNNER" report "$RUN_ID")"
assert grep -q 'test brief' "$STUB_DIR/codex.stdin"
assert grep -q 'second line' "$STUB_DIR/codex.stdin"
unset STUB_GATE

clear_stub
set_config 'codex_effort=high'
export PICK_ACCOUNT=fast PICK_RC=0
start_ok codex --model default
assert grep -qx 'TAG: fast · astra · high' "$WORK/start.out"
assert grep -qx 'fast · astra · high' "$RUN_DIR/tag"
assert await_done

# A running run whose vendor has already surfaced its id reports it mid-flight,
# so a budget-spent relay can still hand back a resumable session.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=high'
printf 'fast\n' >"$STUB_DIR/gemini_profiles"
export PICK_ACCOUNT=fast PICK_RC=0 STUB_SLEEP=2
start_ok gemini
running_wait=$("$RUNNER" wait "$RUN_ID" --max 1)
assert grep -q '^STATUS: running$' <<<"$running_wait"
assert grep -q '^SESSION: gemini-conversation$' <<<"$running_wait"
running_report=$("$RUNNER" report "$RUN_ID")
assert grep -q '^STATUS: running$' <<<"$running_report"
assert grep -q '^SESSION: gemini-conversation$' <<<"$running_report"
assert await_done
unset STUB_SLEEP
printf 'server.go:1017] Created conversation relaunched-conversation\n' >>"$RUN_DIR/log"
assert grep -q '^SESSION: relaunched-conversation$' <<<"$("$RUNNER" report "$RUN_ID")"
printf 'printmode.go:174] Print mode: starting (conversationID="resumed-conversation")\n' >>"$RUN_DIR/log"
assert grep -q '^SESSION: resumed-conversation$' <<<"$("$RUNNER" report "$RUN_ID")"

for vendor in claudeb codex gemini; do
  clear_stub
  set_config "${vendor}_profile=pinned" 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' 'gemini_model=flash38' 'gemini_effort=high'
  printf 'explicit\npicked\npinned\n' >"$STUB_DIR/gemini_profiles"
  export PICK_ACCOUNT=picked PICK_RC=0
  start_ok "$vendor" --account explicit
  assert meta_account_is explicit
  assert test ! -s "$PICK_LOG"
  assert await_done

  clear_stub
  export PICK_ACCOUNT=picked PICK_RC=0
  start_ok "$vendor"
  assert meta_account_is picked
  # Claims own cross-run spreading, so every automatic launch makes one claimed query and does
  # not derive a second exclusion layer from worker-run's live-run registry.
  assert grep -qx -- "--account $vendor --claim" "$PICK_LOG"
  assert jq -e 'has("pinned") | not' "$RUN_DIR/meta.json" >/dev/null
  assert await_done

  clear_stub
  export PICK_ACCOUNT=ignored PICK_RC=2
  start_ok "$vendor"
  assert meta_account_is pinned
  assert jq -e 'has("pinned") | not' "$RUN_DIR/meta.json" >/dev/null
  assert await_done
done

# A light edit asks the picker under the `light` role, so `<vendor>_workers=off` closes neither
# door it passes: not the picker's, and not worker-run's own wall over the resolved vendor.
clear_stub
set_config 'light_edit=claudeb:sonnet' 'claudeb_workers=off' 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_ACCOUNT=picked PICK_RC=0
# A Light edit launches under the SCOPE/VERIFY contract and inside a worktree off the workdir's
# HEAD, so it needs a repository with a commit; tests/test_light_edit.sh owns that contract.
light_workdir="$WORK/light-workdir"
mkdir -p "$light_workdir"
git -C "$light_workdir" init -q
printf 'base\n' >"$light_workdir/file"
git -C "$light_workdir" add file
git -C "$light_workdir" -c user.name=fixture -c user.email=fixture@example.test commit -qm base
printf 'SCOPE: file\ntest brief\nsecond line\n' >"$WORK/brief"
WORKER_TEST_WORKDIR="$light_workdir" start_ok light
printf 'test brief\nsecond line\n' >"$WORK/brief"
assert meta_account_is picked
assert grep -qx -- '--account claudeb --role light --claim' "$PICK_LOG"
assert jq -e '.model == "sonnet" and .light == "edit"' "$RUN_DIR/meta.json" >/dev/null
assert await_done

# With Light off (Egor's menu) there is no light leg: `start light` is refused before any account is
# asked, and research is a plain run on the vendor's own default model, off the light row or not.
clear_stub
set_config 'light_paused=on' 'light_edit=claudeb:sonnet' 'light_research=gemini' 'claudeb_model=opus' 'claudeb_effort=high'
: >"$PICK_LOG"
printf 'SCOPE: file\ntest brief\n' >"$WORK/brief"
rc=0
WORKER_TEST_WORKDIR="$light_workdir" "$RUNNER" start light --brief "$WORK/brief" --workdir "$light_workdir" \
  >"$WORK/lightoff.out" 2>"$WORK/lightoff.err" || rc=$?
assert test "$rc" -ne 0
assert grep -qx 'OUTCOME: LIGHT_OFF' "$WORK/lightoff.out"
assert test ! -s "$PICK_LOG"
printf 'test brief\nsecond line\n' >"$WORK/brief"
start_ok claudeb --role research
assert jq -e '.model == "opus" and (has("light") | not)' "$RUN_DIR/meta.json" >/dev/null
assert await_done

# The Light write sandbox never receives $HOME as a root. gemini's main account IS the real HOME
# (shared-invariants row `m`), so it is granted the agy state directory a named profile's own home
# holds anyway — the shape codex and grok main already have.
clear_stub
set_config 'light_edit=gemini:flash38' 'gemini_model=flash38' 'gemini_effort=high'
export PICK_ACCOUNT=main PICK_RC=0
printf 'SCOPE: file\ntest brief\n' >"$WORK/brief"
WORKER_TEST_WORKDIR="$light_workdir" start_ok light
printf 'test brief\nsecond line\n' >"$WORK/brief"
home_real=$(cd "$HOME" && pwd -P)
assert meta_account_is main
assert_fails grep -qF "(subpath \"$home_real\")" "$RUN_DIR/light-sandbox.sb"
assert grep -qF "(subpath \"$home_real/.gemini\")" "$RUN_DIR/light-sandbox.sb"
assert await_done
export PICK_ACCOUNT=picked

# Legacy picker stderr remains visible but has no routing or report semantics.
clear_stub
set_config 'codex_effort=medium'
export PICK_ACCOUNT=picked PICK_RC=0 PICK_STDERR='worker-pick: legacy SESSION RESERVE note'
start_ok codex
assert meta_account_is picked
assert grep -qxF "$PICK_STDERR" "$WORK/start.err"
assert jq -e 'has("session_reserve") | not' "$RUN_DIR/meta.json" >/dev/null
assert await_done
assert grep -q '^ACCOUNT: picked (codex)$' <<<"$("$RUNNER" report "$RUN_ID")"
unset PICK_STDERR

for vendor in codex gemini; do
  clear_stub
  set_config 'codex_effort=medium' 'gemini_model=flash38' 'gemini_effort=high'
  export PICK_RC=2 PICK_ACCOUNT=ignored
  start_ok "$vendor"
  assert meta_account_is main
  assert await_done
  assert grep -qx DONE "$RUN_DIR/outcome"
done

for vendor in claudeb codex gemini; do
  clear_stub
  set_config 'claudeb_profile=pin' 'gemini_profile=pin'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" >"$WORK/refused.out" 2>"$WORK/refused.err" || rc=$?
  assert test "$rc" -eq 3
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_USAGE_LIMIT" "$WORK/refused.out"
  assert test ! -s "$CALL_LOG"
  assert test "$(tail -n1 "$WORKER_RUN_DIR/prelaunch.jsonl" | jq -r '"\(.outcome) \(.vendor)"')" = \
    "$(tr '[:lower:]' '[:upper:]' <<<"$vendor")_USAGE_LIMIT $vendor"
done

# An empty worker pool is a decision, not a limit: reporting it as a usage limit would send the
# orchestrator hunting for quota that was never the problem.
for vendor in claudeb codex gemini; do
  clear_stub
  set_config 'codex_effort=medium'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  export PICK_STDERR="worker-pick: every $vendor account is out of the worker pool (claude: one 3% off)"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" >"$WORK/pool-empty.out" 2>"$WORK/pool-empty.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/pool-empty.out"
  assert grep -q "every $vendor account is out of the worker pool" "$WORK/pool-empty.err"
  assert test ! -s "$CALL_LOG"
  unset PICK_STDERR
done

# A vendor switched off for workers is the same decision one step higher: its accounts may sit
# at 0%, so reading it as a usage limit would report a wall that does not exist.
for vendor in claudeb codex gemini; do
  clear_stub
  set_config 'codex_effort=medium'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  export PICK_STDERR="worker-pick: $vendor is switched off for workers"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" >"$WORK/role-off.out" 2>"$WORK/role-off.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/role-off.out"
  assert grep -q "$vendor is switched off for workers" "$WORK/role-off.err"
  assert test ! -s "$CALL_LOG"
  unset PICK_STDERR
done

# A paused vendor is parked, not spent: its refusal must land as UNAVAILABLE the way role-off does.
for vendor in claudeb codex gemini grok; do
  clear_stub
  set_config 'codex_effort=medium'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  export PICK_STDERR="worker-pick: $vendor is paused (${vendor}_paused=on in ~/.claude/worker-model)"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" >"$WORK/paused.out" 2>"$WORK/paused.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/paused.out"
  assert grep -q "$vendor is paused" "$WORK/paused.err"
  assert test ! -s "$CALL_LOG"
  unset PICK_STDERR
done

# The role switch closes the vendor, not one account of it, so naming an account outright — or
# falling back to the pin — cannot walk around it the way it cannot walk around the pool.
for vendor in claudeb codex gemini; do
  clear_stub
  set_config "${vendor}_workers=off" 'codex_effort=medium'
  export PICK_ACCOUNT=picked PICK_RC=0
  printf 'explicit\npicked\n' >"$STUB_DIR/gemini_profiles"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --account explicit \
    >"$WORK/role-wall.out" 2>"$WORK/role-wall.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/role-wall.out"
  assert grep -q "$vendor is switched off for workers" "$WORK/role-wall.err"
  assert test ! -s "$CALL_LOG"
  # The vendor pin is the one override, the same way it is the only way past the pool.
  clear_stub
  set_config "${vendor}_workers=off" "${vendor}_profile=explicit" 'codex_effort=medium'
  export PICK_ACCOUNT=ignored PICK_RC=2
  start_ok "$vendor"
  assert meta_account_is explicit
  assert await_done
  clear_stub
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --account other \
    >"$WORK/role-pin.out" 2>"$WORK/role-pin.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/role-pin.out"
  assert test ! -s "$CALL_LOG"
  # Only the literal `off` closes it.
  clear_stub
  set_config "${vendor}_workers=on" 'codex_effort=medium'
  export PICK_ACCOUNT=picked PICK_RC=0
  start_ok "$vendor" --account explicit
  assert meta_account_is explicit
  assert await_done
done

# A vendor pin (`*`) covers every pool account the limits store carries, and a chat's own pin file
# replaces the global pin for that session — both open the role wall exactly like an account pin.
printf '%s\n' '{"vendors":{"codex":{"available":true,"accounts":[{"account":"explicit"},{"account":"other"}]}}}' \
  >"$HOME/.llm-limits.json"
clear_stub
set_config 'codex_workers=off' 'codex_profile=*' 'codex_effort=medium'
export PICK_ACCOUNT=ignored PICK_RC=2
start_ok codex --account explicit
assert meta_account_is explicit
assert await_done
clear_stub
rc=0
"$RUNNER" start codex --brief "$WORK/brief" --account ghost \
  >"$WORK/role-star.out" 2>"$WORK/role-star.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'codex is switched off for workers' "$WORK/role-star.err"
mkdir -p "$CHAT_PINS_DIR"
printf 'codex_profile=other\n' >"$CHAT_PINS_DIR/chat-pin-test"
set_config 'codex_workers=off' 'codex_profile=explicit' 'codex_effort=medium'
clear_stub
rc=0
CLAUDE_CODE_SESSION_ID=chat-pin-test "$RUNNER" start codex --brief "$WORK/brief" --account explicit \
  >"$WORK/role-chat.out" 2>"$WORK/role-chat.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'codex is switched off for workers' "$WORK/role-chat.err"
clear_stub
CLAUDE_CODE_SESSION_ID=chat-pin-test start_ok codex --account other
assert meta_account_is other
assert await_done
# «воркер на все» (open=all) opens the switched-off vendor to a named account in that chat alone.
printf 'open=all
' >"$CHAT_PINS_DIR/chat-open-all"
set_config 'codex_workers=off' 'codex_effort=medium'
clear_stub
CLAUDE_CODE_SESSION_ID=chat-open-all start_ok codex --account explicit
assert meta_account_is explicit
assert await_done
clear_stub
rc=0
CLAUDE_CODE_SESSION_ID=chat-pin-test "$RUNNER" start codex --brief "$WORK/brief" --account explicit   >"$WORK/role-open.out" 2>"$WORK/role-open.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'codex is switched off for workers' "$WORK/role-open.err"
rm -rf "$CHAT_PINS_DIR" "$HOME/.llm-limits.json"

# Computer Use is not the implementation leg codex_workers=off closes: the picker is asked under
# `computer`, the role wall stays open, and only the launched brief carries the preamble.
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/cua-sync-ok"
printf '#!/bin/sh\necho "fake registration failure" >&2\nexit 2\n' >"$WORK/bin/cua-sync-broken"
chmod +x "$WORK/bin/cua-sync-ok" "$WORK/bin/cua-sync-broken"
set_config 'codex_workers=off' 'codex_effort=medium'
clear_stub
export PICK_ACCOUNT=cu PICK_RC=0
BROWSE_CUA_SYNC="$WORK/bin/cua-sync-ok" BROWSE_SKIP_PROCESSES=1 start_ok codex --computer
assert grep -qx -- '--account codex --role computer --claim' "$PICK_LOG"
assert meta_account_is cu
assert jq -e '.computer == true' "$RUN_DIR/meta.json" >/dev/null
assert grep -q 'Computer Use Preamble' "$RUN_DIR/brief.launch"
assert cmp -s "$WORK/brief" "$RUN_DIR/brief"
assert await_done
for computer_bad in 'claudeb --computer' 'codex --computer --browser'; do
  clear_stub
  rc=0
  # shellcheck disable=SC2086
  "$RUNNER" start $computer_bad --brief "$WORK/brief" >"$WORK/computer-bad.out" 2>"$WORK/computer-bad.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -Eq 'only codex drives the computer|drive different surfaces' "$WORK/computer-bad.err"
  assert test ! -s "$CALL_LOG"
done
clear_stub
rc=0
BROWSE_CUA_SYNC="$WORK/bin/cua-sync-broken" BROWSE_SKIP_PROCESSES=1 \
  "$RUNNER" start codex --computer --brief "$WORK/brief" >"$WORK/computer-cua.out" 2>&1 || rc=$?
assert test "$rc" -eq 2
assert grep -qx 'REASON: codex computer use unavailable — cua_repl registration failed: fake registration failure' "$WORK/computer-cua.out"
assert test ! -s "$CALL_LOG"
unset PICK_ACCOUNT PICK_RC
set_config

# A missing wall is loud: worker-run must refuse to launch rather than read every account as
# excluded because its include went missing.
NOSHARE_RUNNER="$WORK/noshare/bin/worker-run"
mkdir -p "$WORK/noshare/bin"
cp "$RUNNER" "$NOSHARE_RUNNER"
noshare_rc=0
"$NOSHARE_RUNNER" start codex --brief "$WORK/brief" >"$WORK/noshare.out" 2>"$WORK/noshare.err" || noshare_rc=$?
assert test "$noshare_rc" -eq 4
assert grep -q 'share/worker-pool.sh is missing' "$WORK/noshare.err"
assert_fails grep -q 'out of the worker pool' "$WORK/noshare.err"


echo "PASS: $asserts asserts; detached start, bounded waits, light runs, chat pins, computer use, missing pool"
