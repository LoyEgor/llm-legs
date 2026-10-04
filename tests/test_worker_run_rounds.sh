#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"

# A brief with no first line cannot identify its run: RESUME/ATTACH are read off the top of it, and
# a discovery prefix taken from a blank line matches every transcript in the tree at once.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=picked
printf '\nthe ask is on line two\n' >"$WORK/blank-first-brief"
printf '   \nthe ask is on line two\n' >"$WORK/spaces-first-brief"
: >"$WORK/empty-brief"
for bad_brief in blank-first-brief spaces-first-brief empty-brief; do
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/$bad_brief" --workdir "$WORK/workdir" \
    >"$WORK/blank.out" 2>"$WORK/blank.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -q 'brief starts with a blank line' "$WORK/blank.err"
  assert_fails grep -q '^RUN: ' "$WORK/blank.out"
done
unset PICK_RC PICK_ACCOUNT

# A garbage deadline falls back to the default instead of disarming the watchdog.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=deadacct WORKER_RUN_DEADLINE='not-a-number'
start_ok codex
unset WORKER_RUN_DEADLINE
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"

# The gemini brief travels on argv: oversized briefs are refused up front.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=high'
export PICK_RC=0 PICK_ACCOUNT=main
head -c 200000 /dev/zero | tr '\0' 'x' >"$WORK/huge-brief"
rc=0
"$RUNNER" start gemini --brief "$WORK/huge-brief" >"$WORK/huge.out" 2>"$WORK/huge.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'briefs over 128KB cannot launch' "$WORK/huge.err"

# An account that walls mid-task does not end the run: the same brief continues
# on the next account the picker offers, and the caller re-dispatches nothing.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=unused
printf 'walled1\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled1' '0 rescue1' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0
assert meta_account_is rescue1
assert jq -e '.walled_accounts == ["walled1"]' "$RUN_DIR/meta.json" >/dev/null
# The supervisor's launch instant survives the reroute untouched while started_at is restamped:
# it is the clock liveness is judged by, and a restamped one reads a live rerouted run as dead.
assert jq -e '(.pid_started_at | type == "number") and .pid_started_at <= .started_at' \
  "$RUN_DIR/meta.json" >/dev/null
assert grep -qx -- '--account codex --claim' "$PICK_LOG"
assert grep -qx -- '--account codex --claim --exclude walled1' "$PICK_LOG"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert grep -q '^CODEX_HOME=.*/\.codex-profiles/rescue1$' "$CALL_LOG"
assert grep -qx 'REROUTE: walled on walled1 → continued on rescue1' "$WORK/wait.out"
assert grep -qx 'rescue1 · astra · high' "$RUN_DIR/tag"
# The relaunch starts the brief fresh on the new account.
assert_launched_brief "$STUB_DIR/codex.stdin"
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'ACCOUNT: rescue1 (codex)' <<<"$report"
assert grep -qx 'REROUTE: walled on walled1 → continued on rescue1' <<<"$report"

# The chain survives several walls, and every account already burnt stays
# excluded from the next query.
clear_stub
set_config 'codex_effort=high'
printf 'walled1\nwalled2\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled1' '0 walled2' '0 rescue2' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert meta_account_is rescue2
assert jq -e '.walled_accounts == ["walled1","walled2"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx -- '--account codex --claim --exclude walled1' "$PICK_LOG"
assert grep -qx -- '--account codex --claim --exclude walled1,walled2' "$PICK_LOG"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 3
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 2
assert grep -qx 'REROUTE: walled on walled2 → continued on rescue2' "$WORK/wait.out"

# ALL WALLED is the only way the usage-limit outcome still reaches the caller.
clear_stub
set_config 'codex_effort=high'
printf 'walled1\nwalled2\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled1' '0 walled2' '3' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: pool exhausted (walled: walled1, walled2)' "$WORK/wait.out"
assert meta_account_is walled2
assert jq -e '.walled_accounts == ["walled1"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on walled1 → continued on walled2' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2

# A gemini rescue account must hold a usable geminib profile, the same check
# start_run applies: an unlisted answer ends the run instead of relaunching
# into a CLI error.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=high'
printf 'walledg\n' >"$STUB_DIR/gemini_profiles"
export STUB_CODE=9 STUB_ERROR='RESOURCE_EXHAUSTED'
printf '%s\n' '0 walledg' '0 unlisted' >"$STUB_DIR/pick_queue"
start_ok gemini
assert await_done
assert grep -qx 'OUTCOME: GEMINI_USAGE_LIMIT' "$WORK/wait.out"
assert meta_account_is walledg
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 0

# An explicit --account is spent first, then the pool: a wall moves the same brief on.
clear_stub
set_config 'codex_effort=high'
printf 'pinnedacct\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 rescue3' >"$STUB_DIR/pick_queue"
start_ok codex --account pinnedacct
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0
assert meta_account_is rescue3
assert jq -e '.walled_accounts == ["pinnedacct"]' "$RUN_DIR/meta.json" >/dev/null
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert grep -qx -- '--account codex --claim --exclude pinnedacct' "$PICK_LOG"
assert grep -qx 'REROUTE: walled on pinnedacct → continued on rescue3' "$WORK/wait.out"
assert test -f "$WORKER_WALLS_DIR/codex-pinnedacct"
wall_epoch=$(sed -n 1p "$WORKER_WALLS_DIR/codex-pinnedacct" | tr -d '[:space:]')
now=$(date +%s)
assert test "$wall_epoch" -ge $((now + 3600 - 30))
assert test "$wall_epoch" -le $((now + 3600 + 30))

# Pin fallback is the same rule: spent first, then the pool.
clear_stub
set_config 'codex_effort=high' 'codex_profile=pinacct'
printf 'pinacct\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '2' '0 rescue4' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert meta_account_is rescue4
assert jq -e '.walled_accounts == ["pinacct"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on pinacct → continued on rescue4' "$WORK/wait.out"
assert test -f "$WORKER_WALLS_DIR/codex-pinacct"
assert_fails grep -q '^codex_profile=' "$WORKER_RUN_CONFIG_FILE"

# (iii) a met wall drops only that pinned name; the run lands on the other pin.
clear_stub
set_config 'codex_effort=high' 'codex_profile=hot,cool'
printf 'hot\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '2' '0 cool' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert meta_account_is cool
assert jq -e '.walled_accounts == ["hot"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'codex_profile=cool' "$WORKER_RUN_CONFIG_FILE"
assert test -f "$WORKER_WALLS_DIR/codex-hot"
assert_fails test -f "$WORKER_WALLS_DIR/codex-cool"

# (iv) last pin removed → key deleted.
clear_stub
set_config 'codex_effort=high' 'codex_profile=lastpin'
printf 'lastpin\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '2' '0 leftover' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert meta_account_is leftover
assert_fails grep -q '^codex_profile=' "$WORKER_RUN_CONFIG_FILE"

# (h) limits at 100% without a run-observed wall still launch on the pin first.
clear_stub
now=$(date +%s)
set_config 'claudeb_model=opus' 'claudeb_effort=high' 'claudeb_profile=hot'
jq -cn --argjson now "$now" '{schema:1,fetched_at:$now,vendors:{claude:{available:true,accounts:[
  {account:"hot",enabled:true,auth:{status:"ok"},
   five_hour:{used_pct:10,as_of:$now},weekly:{used_pct:100,as_of:$now},
   rotation:{usable:{general:true,fable:true}}},
  {account:"cool",enabled:true,auth:{status:"ok"},
   five_hour:{used_pct:0,as_of:$now},weekly:{used_pct:0,as_of:$now},
   rotation:{usable:{general:true,fable:true}}}]}}}' >"$WORK/h-limits.json"
mkdir -p "$HOME/.claude-profiles/.claudeb"
: >"$HOME/.claude-profiles/.claudeb/disabled"
export WORKER_RUN_WORKER_PICK="$ROOT/bin/worker-pick"
export LLM_LIMITS_FILE="$WORK/h-limits.json"
export WORKER_PICK_CONFIG_FILE="$WORKER_RUN_CONFIG_FILE"
export WORKER_PICK_NOW="$now"
export CLAUDEB_DIR="$HOME/.claude-profiles/.claudeb"
export PICK_RC=0 PICK_ACCOUNT=should-not-use-stub
start_ok claudeb
assert meta_account_is hot
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
export WORKER_RUN_WORKER_PICK="$WORK/bin/worker-pick"
unset LLM_LIMITS_FILE WORKER_PICK_CONFIG_FILE WORKER_PICK_NOW

# --resume is the one run that stays: the session lives on that account.
clear_stub
set_config 'codex_effort=high'
printf 'resacct\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 rescue5' >"$STUB_DIR/pick_queue"
start_ok codex --account resacct --resume sess-stay
assert await_done
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: resumed session stays on resacct' "$WORK/wait.out"
assert meta_account_is resacct
assert jq -e 'has("walled_accounts") | not' "$RUN_DIR/meta.json" >/dev/null
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 0
assert grep -qx '0 rescue5' "$STUB_DIR/pick_queue"
assert test -f "$WORKER_WALLS_DIR/codex-resacct"

# A named account that walls, then every remaining pick walls: pool exhausted.
clear_stub
set_config 'codex_effort=high'
printf 'walled1\nwalled2\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled2' '3' >"$STUB_DIR/pick_queue"
start_ok codex --account walled1
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: pool exhausted (walled: walled1, walled2)' "$WORK/wait.out"
assert meta_account_is walled2
assert jq -e '.walled_accounts == ["walled1"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on walled1 → continued on walled2' "$WORK/wait.out"

# A brief carrying a bench run's own `record` command is that run's triage, delegated: the bench is
# stamped with the supervisor's pid, which is what tells the Stop gate somebody is writing the
# report — and, once the pid is gone, that nobody is.
clear_stub
export PICK_ACCOUNT=deleg PICK_RC=0 STUB_SLEEP=3
DELEG_BENCHES="$HOME/.claude-profiles/.claudeb/worker-stats/benches"
mkdir -p "$DELEG_BENCHES/20260801T120000Z-abc123f" "$DELEG_BENCHES/20260801T130000Z-def4560"
cat >"$WORK/deleg-brief" <<'DELEGBRIEF'
STEP 1 — blind triage.
Record exactly with: review-bench record 20260801T120000Z-abc123f --no-corpus --verdicts /tmp/v.jsonl
No bench holds review-bench record 20260801T990000Z-fffffff, so nothing is stamped for it.
DELEGBRIEF
REVIEW_BENCH_STUB_EMPTY=1 "$RUNNER" start codex --brief "$WORK/deleg-brief" --workdir "$WORK/workdir" \
  >"$WORK/deleg.out" 2>"$WORK/deleg.err" || fail "delegated start failed: $(<"$WORK/deleg.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/deleg.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/deleg.out")
assert test -s "$DELEG_BENCHES/20260801T120000Z-abc123f/delegated"
assert test "$(awk 'NR == 1 {print $1}' "$DELEG_BENCHES/20260801T120000Z-abc123f/delegated")" \
  = "$(jq -r '.pid' "$RUN_DIR/meta.json")"
assert kill -0 "$(awk 'NR == 1 {print $1}' "$DELEG_BENCHES/20260801T120000Z-abc123f/delegated")"
# The launch instant stands beside the pid, and it is the same one the record stamps: read on the
# pid alone the stamp silences an untriaged run for as long as whatever recycled the number lives
# (shared-invariants row ar).
assert test "$(awk 'NR == 1 {print $2}' "$DELEG_BENCHES/20260801T120000Z-abc123f/delegated")" \
  = "$(jq -r '.pid_started_at' "$RUN_DIR/meta.json")"
# The stamp answers for a run that exists: an id no bench holds is not a directory to invent, and a
# brief that delegates no triage stamps nothing at all.
assert test ! -e "$DELEG_BENCHES/20260801T990000Z-fffffff"
assert test ! -e "$DELEG_BENCHES/20260801T130000Z-def4560/delegated"
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
await_done || fail "the delegated run never finished"

# A fixing worker's brief names the review round it fixes — line 1, or line 2 under a RESUME/ATTACH
# line — and the run record keeps it: review-bench closes the round on what that run produced.
clear_stub
mkdir -p "$DELEG_BENCHES/20260801T140000Z-0a1b2c3"
round_start() {
  "$RUNNER" start codex --brief "$WORK/round-brief" --workdir "$WORK/workdir" "$@" \
    >"$WORK/round.out" 2>"$WORK/round.err"
}
printf 'ROUND: 20260801T140000Z-0a1b2c3\nFix the confirmed findings.\n' >"$WORK/round-brief"
round_start || fail "round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
# A round brief a chat wrote by hand carries no fixer-row rule; the launch gets review-bench's.
assert test "$(sed '/^AUDIENCE: /,$d' "$RUN_DIR/brief.launch")" = "ROUND: 20260801T140000Z-0a1b2c3
Fix the confirmed findings.

STUB FIX RULE fix 20260801T140000Z-0a1b2c3 --print
write verdicts.jsonl rows"
assert test "$(sed -n '7p' "$RUN_DIR/brief.launch" | cut -c1-10)" = "AUDIENCE: "
assert cmp -s "$WORK/round-brief" "$RUN_DIR/brief"
await_done || fail "the round run never finished"
clear_stub
printf 'ROUND: 20260801T140000Z-0a1b2c3\nWrite one row per finding into $WORKER_RUN_RECORD/verdicts.jsonl.\n' >"$WORK/round-brief"
round_start || fail "verdicts round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert_fails grep -q 'STUB FIX RULE' "$RUN_DIR/brief.launch"
await_done || fail "the verdicts round run never finished"
clear_stub
printf 'ROUND: 20260801T140000Z-0a1b2c3\nNothing is left.\n' >"$WORK/round-brief"
REVIEW_BENCH_STUB_EMPTY=1 round_start || fail "fixed round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(sed -n '4p' "$RUN_DIR/brief.launch" | cut -c1-10)" = "AUDIENCE: "
await_done || fail "the fixed round run never finished"
clear_stub
printf 'ROUND: 20260801T140000Z-0a1b2c3\nFix it.\n' >"$WORK/round-brief"
rc=0
REVIEW_BENCH_STUB_FAIL=1 round_start || rc=$?
assert test "$rc" -eq 4
assert test "$(wc -l <"$WORK/round.err" | tr -d ' ')" = 1
assert grep -Fq 'review-bench fix 20260801T140000Z-0a1b2c3 --print failed' "$WORK/round.err"
assert_fails grep -q '^RUN: ' "$WORK/round.out"
clear_stub
printf 'RESUME codex-resume:\nROUND: 20260801T140000Z-0a1b2c3\nFix the rest.\n' >"$WORK/round-brief"
round_start --account main --resume codex-resume || fail "resumed round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
await_done || fail "the resumed round run never finished"
clear_stub
printf 'ACCOUNT: main\nEFFORT: high\nROUND: 20260801T140000Z-0a1b2c3\n\nFix the findings.\n' >"$WORK/round-brief"
round_start || fail "header round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
await_done || fail "the header round run never finished"
clear_stub
printf 'ACCOUNT: main\n\nThe brief must carry the line\nROUND: 20260801T140000Z-0a1b2c3\n' >"$WORK/round-brief"
# A ROUND: past the header is not a header line — it is prose naming an open round, and prose is
# asked about rather than bound.
rc=0
round_start || rc=$?
assert test "$rc" -eq 4
assert grep -Fq "open review round(s) 20260801T140000Z-0a1b2c3 but has no ROUND: line" "$WORK/round.err"
assert_fails grep -q '^RUN: ' "$WORK/round.out"

# A relay that rewrote its brief drops the ROUND: header the orchestrator's Agent prompt carried
# (round c3c2395's fixer, 2026-09-28): worker-spawn-hook seeds it into the agent's tag file and the
# launch adopts it from there, and a brief or flag naming another round is refused.
SPAWN_TAGS="$HOME/.cache/claude-worker-tags/chat-spawn-round"
spawn_seed() { # round [agent]
  mkdir -p "$SPAWN_TAGS"
  printf 'seed · opus · high\nstart=%s\nround=%s\n' "$(date +%s)" "$1" >"$SPAWN_TAGS/${2:-agent-relay}"
}
clear_stub
spawn_seed 20260801T140000Z-0a1b2c3
printf 'Repository: somewhere\n\nFix the findings.\n' >"$WORK/round-brief"
CLAUDE_CODE_SESSION_ID=chat-spawn-round round_start || fail "prompt-round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
assert test "$(jq -r '.round_source' "$RUN_DIR/meta.json")" = prompt
assert grep -q 'STUB FIX RULE fix 20260801T140000Z-0a1b2c3' "$RUN_DIR/brief.launch"
assert test "$(cat "$RUN_DIR/agent-task")" = agent-relay
await_done || fail "the prompt-round run never finished"
clear_stub
spawn_seed 20260801T140000Z-0a1b2c3
printf 'ROUND: 20260801T140000Z-0a1b2c3\nFix the findings.\n' >"$WORK/round-brief"
CLAUDE_CODE_SESSION_ID=chat-spawn-round round_start || fail "agreeing prompt-round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.round_source' "$RUN_DIR/meta.json")" = header
await_done || fail "the agreeing prompt-round run never finished"
for conflict in 'ROUND: 20260801T130000Z-def4560' 'ROUND: none' '--round'; do
  clear_stub
  spawn_seed 20260801T140000Z-0a1b2c3
  conflict_args=()
  if [ "$conflict" = --round ]; then
    printf 'Fix the findings.\n' >"$WORK/round-brief"
    conflict_args=(--round 20260801T130000Z-def4560)
  else
    printf '%s\nFix the findings.\n' "$conflict" >"$WORK/round-brief"
  fi
  rc=0
  CLAUDE_CODE_SESSION_ID=chat-spawn-round round_start ${conflict_args[@]+"${conflict_args[@]}"} || rc=$?
  assert test "$rc" -eq 4
  assert grep -Fq "the Agent prompt that spawned this relay says 'ROUND: 20260801T140000Z-0a1b2c3'" "$WORK/round.err"
  assert_fails grep -q '^RUN: ' "$WORK/round.out"
done
rm -rf "$SPAWN_TAGS"

# The prompt's `ROUND: none` is the orchestrator's opt-out and survives the rewrite too: the prose scan
# asks nothing, and a brief naming a round under it is refused like any other mismatch.
clear_stub
spawn_seed none
printf 'Audit the labels of review round 20260801T140000Z-0a1b2c3 (see the bench). Edit nothing.\n' >"$WORK/round-brief"
CLAUDE_CODE_SESSION_ID=chat-spawn-round round_start || fail "prompt-none start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq 'has("review_round") or has("round_source")' "$RUN_DIR/meta.json")" = false
assert_fails grep -q 'STUB FIX RULE' "$RUN_DIR/brief.launch"
await_done || fail "the prompt-none run never finished"
for conflict in 'ROUND: 20260801T140000Z-0a1b2c3' '--round'; do
  clear_stub
  spawn_seed none
  conflict_args=()
  if [ "$conflict" = --round ]; then
    printf 'Fix the findings.\n' >"$WORK/round-brief"
    conflict_args=(--round 20260801T140000Z-0a1b2c3)
  else
    printf '%s\nFix the findings.\n' "$conflict" >"$WORK/round-brief"
  fi
  rc=0
  CLAUDE_CODE_SESSION_ID=chat-spawn-round round_start ${conflict_args[@]+"${conflict_args[@]}"} || rc=$?
  assert test "$rc" -eq 4
  assert grep -Fq "the Agent prompt that spawned this relay says 'ROUND: none'" "$WORK/round.err"
  assert_fails grep -q '^RUN: ' "$WORK/round.out"
done
rm -rf "$SPAWN_TAGS"

# Two relays of one chat launching within the claim window, no CLAUDE_AGENT_ID: the newest `start=`
# may be the sibling's, so disagreeing seeds bind nothing and refuse nothing; CLAUDE_AGENT_ID picks.
clear_stub
spawn_seed 20260801T140000Z-0a1b2c3
spawn_seed 20260801T130000Z-def4560 agent-sibling
printf 'Fix the findings.\n' >"$WORK/round-brief"
(unset CLAUDE_AGENT_ID; CLAUDE_CODE_SESSION_ID=chat-spawn-round round_start) || fail "ambiguous prompt-round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
await_done || fail "the ambiguous prompt-round run never finished"
clear_stub
rm -rf "$SPAWN_TAGS"
spawn_seed 20260801T140000Z-0a1b2c3
spawn_seed 20260801T130000Z-def4560 agent-sibling
printf 'ROUND: 20260801T140000Z-0a1b2c3\nFix the findings.\n' >"$WORK/round-brief"
(unset CLAUDE_AGENT_ID; CLAUDE_CODE_SESSION_ID=chat-spawn-round round_start) || fail "ambiguous header start was refused: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.round_source' "$RUN_DIR/meta.json")" = header
await_done || fail "the ambiguous header run never finished"
clear_stub
rm -rf "$SPAWN_TAGS"
spawn_seed 20260801T130000Z-def4560
spawn_seed 20260801T140000Z-0a1b2c3 agent-sibling
printf 'Fix the findings.\n' >"$WORK/round-brief"
CLAUDE_AGENT_ID=agent-sibling CLAUDE_CODE_SESSION_ID=chat-spawn-round round_start || fail "agent-id prompt-round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
assert test "$(jq -r '.round_source' "$RUN_DIR/meta.json")" = prompt
assert test "$(cat "$RUN_DIR/agent-task")" = agent-sibling
await_done || fail "the agent-id prompt-round run never finished"
clear_stub
rm -rf "$SPAWN_TAGS"

# A brief that names an open round in prose alone is refused, never bound: bound, a read-only audit
# that cited a run as evidence was handed that round's findings to fix (2026-09-23), and unasked a
# hand-written fix brief lands its fixes as debt. The refusal names both headers that answer it.
clear_stub
printf 'ACCOUNT: main\n\nAudit the labels of review round 20260801T140000Z-0a1b2c3 (see the bench). Edit nothing.\n' >"$WORK/round-brief"
rc=0
round_start || rc=$?
assert test "$rc" -eq 4
assert test "$(wc -l <"$WORK/round.err" | tr -d ' ')" = 1
assert grep -Fq "add 'ROUND: <id>' when this run fixes that round, or 'ROUND: none' when it only cites it" "$WORK/round.err"
assert_fails grep -q '^RUN: ' "$WORK/round.out"
# `ROUND: none` launches it unbound: no round, no fix rule appended.
clear_stub
printf 'ACCOUNT: main\nROUND: none\n\nAudit the labels of review round 20260801T140000Z-0a1b2c3 (see the bench). Edit nothing.\n' >"$WORK/round-brief"
round_start || fail "ROUND: none start failed: $(<"$WORK/round.err")"
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
assert_fails grep -q 'STUB FIX RULE' "$RUN_DIR/brief.launch"
await_done || fail "the ROUND: none run never finished"

# The same brief against a settled round: `fix --print` prints nothing, so nothing is asked — a
# round with no confirmed finding left is not a round this run could fix.
clear_stub
printf 'ACCOUNT: main\n\nFix the three findings of review round 20260801T140000Z-0a1b2c3 (see the bench).\n' >"$WORK/round-brief"
REVIEW_BENCH_STUB_EMPTY=1 round_start || fail "settled brief-text start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
assert test "$(jq 'has("round_source")' "$RUN_DIR/meta.json")" = false
assert_fails grep -q 'STUB FIX RULE' "$RUN_DIR/brief.launch"
assert_fails grep -q 'ROUND: line' "$WORK/round.err"
await_done || fail "the settled brief-text run never finished"

# A member id of a chunked round is one token to the scan as well as to the validator: the prose of
# a chunk's fix brief names `<round>-<n>`, and a scan blind to the suffix would ask nothing.
clear_stub
mkdir -p "$DELEG_BENCHES/20260801T140000Z-0a1b2c3-2"
printf 'ACCOUNT: main\n\nFix the findings of review round 20260801T140000Z-0a1b2c3-2 (see the bench).\n' >"$WORK/round-brief"
rc=0
round_start || rc=$?
assert test "$rc" -eq 4
assert grep -Fq "open review round(s) 20260801T140000Z-0a1b2c3-2 but" "$WORK/round.err"

# Two open rounds in the prose and no line choosing between them: a run that picked one would
# anchor half its fixes against the other, so it refuses and asks for the ROUND: line.
clear_stub
printf 'ACCOUNT: main\n\nFix 20260801T140000Z-0a1b2c3 and then 20260801T130000Z-def4560.\n' >"$WORK/round-brief"
rc=0
round_start || rc=$?
assert test "$rc" -eq 4
assert test "$(wc -l <"$WORK/round.err" | tr -d ' ')" = 1
assert grep -Fq '20260801T140000Z-0a1b2c3 20260801T130000Z-def4560' "$WORK/round.err"
assert grep -Fq "add 'ROUND: <id>'" "$WORK/round.err"
assert_fails grep -q '^RUN: ' "$WORK/round.out"

# A ROUND: header answers alone: the prose beside it names another open round and is never scanned.
clear_stub
printf 'ROUND: 20260801T140000Z-0a1b2c3\nThe findings 20260801T130000Z-def4560 raised are already fixed.\n' >"$WORK/round-brief"
round_start || fail "header-wins start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
assert test "$(jq -r '.round_source' "$RUN_DIR/meta.json")" = header
assert_fails grep -q 'ROUND: line' "$WORK/round.err"
await_done || fail "the header-wins run never finished"

# The flag answers alone the same way, and names its own source.
clear_stub
round_start --round 20260801T130000Z-def4560 || fail "flag-source start failed: $(<"$WORK/round.err")"
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T130000Z-def4560
assert test "$(jq -r '.round_source' "$RUN_DIR/meta.json")" = flag
await_done || fail "the flag-source run never finished"

# A round over several repositories grants the fixer every one of them: round dd96a57's claudeb fixer
# ran in llm-legs alone, and its writes to claude-setup had no baseline and read as escaped. The
# workdir's own repository is not granted again, even when the workdir is a worktree of it.
round_repos="$WORK/round-repos"
for name in alpha beta gamma; do
  git init -q "$round_repos/$name"
  git -C "$round_repos/$name" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
done
git -C "$round_repos/alpha" worktree add -q -b fix "$round_repos/alpha-fix"
round_repos=$(cd "$round_repos" && pwd -P)
mkdir -p "$DELEG_BENCHES/20260801T160000Z-1b2c3d4"
jq -n --arg root "$round_repos" '{repo: ($root + "/merged"),
  repos: [{label: "alpha", repo: ($root + "/alpha")}, {label: "beta", repo: ($root + "/beta")},
          {label: "gamma", repo: ($root + "/gamma")}]}' \
  >"$DELEG_BENCHES/20260801T160000Z-1b2c3d4/meta.json"
cp "$WORK/brief" "$WORK/brief.before-round"
printf 'ROUND: 20260801T160000Z-1b2c3d4\nFix the confirmed findings.\n' >"$WORK/brief"
for round_vendor in codex claudeb; do
  clear_stub
  start_ok "$round_vendor" --workdir "$round_repos/alpha-fix" --add-dir "$round_repos/gamma"
  assert test "$(jq -c '.add_dirs' "$RUN_DIR/meta.json")" \
    = "$(jq -cn --arg root "$round_repos" '[$root + "/gamma", $root + "/beta"]')"
  await_done || fail "the $round_vendor multi-repository round run never finished"
done
assert grep -qx "ARG=--add-dir" "$CALL_LOG"
assert grep -qx "ARG=$(printf '%q' "$round_repos/beta")" "$CALL_LOG"
mv "$WORK/brief.before-round" "$WORK/brief"

# Round-SHAPED is not a round id: a bare timestamp, a date and a run id are tokens the scan drops
# before it asks review-bench anything.
clear_stub
printf 'ACCOUNT: main\n\nThe 20260801T140000Z snapshot of 2026-08-01, run codex-20260801-1234-ab12.\n' >"$WORK/round-brief"
round_start || fail "non-round token start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
assert_fails grep -q 'ROUND: line' "$WORK/round.err"
await_done || fail "the non-round token run never finished"

for bad_round in 'ROUND: 20260801T140000Z-0A1B2C3' 'ROUND: 20260801T140000Z-0a1b2c' \
  'ROUND: 20260801T150000Z-0a1b2c3' 'ROUND: 20260801T140000Z- 0a1b2c3'; do
  clear_stub
  printf '%s\nFix it.\n' "$bad_round" >"$WORK/round-brief"
  rc=0
  round_start || rc=$?
  assert test "$rc" -eq 4
  assert test "$(wc -l <"$WORK/round.err" | tr -d ' ')" = 1
  assert grep -Fq "the shape is 'ROUND: <review-bench run id YYYYMMDDTHHMMSSZ-<7 hex>>'" "$WORK/round.err"
  assert_fails grep -q '^RUN: ' "$WORK/round.out"
done

clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokacct
# grok takes no --add-dir, so a round over several repositories grants it none: one run per repository.
clear_stub
printf 'ROUND: 20260801T160000Z-1b2c3d4\nFix the confirmed findings.\n' >"$WORK/round-brief"
"$RUNNER" start grok --brief "$WORK/round-brief" --workdir "$round_repos/alpha" \
  >"$WORK/start.out" 2>"$WORK/start.err" || fail "grok multi-repository round start failed: $(<"$WORK/start.err")"
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
assert test "$(jq -c '.add_dirs // []' "$RUN_DIR/meta.json")" = '[]'
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
assert await_done

echo "PASS: $asserts asserts; blank briefs, pinned walls, limits-driven picks, delegation and review rounds"
