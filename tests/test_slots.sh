#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
pids=()
trap 'kill ${pids[@]+"${pids[@]}"} $(cat "$WORK/holders" 2>/dev/null) 2>/dev/null; rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
jqe() { jq -e "$@" >/dev/null; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly held: $*"; }
export HARNESS_HOLDS_DIR="$WORK/holds" HARNESS_WAITS_DIR="$WORK/waits" SLOTS_POLL_S=0.2 STATUSLINE_CACHE_DIR="$WORK/sl" RUN_SUITES_TIMES="$WORK/times.tsv"
unset RUN_SUITES_SLOT WORKER_SLOT WORKER_RUN_RECORD WORKER_RUN_ID
. "$ROOT/share/slots.sh"

holder() { # dir count -> pid of a process holding one slot until killed
  # A waiter's probe locks a free slot for a moment before it finds no room: one try could lose it to that.
  bash -c '. "$1/share/slots.sh"; until slot_take "$2" "$3" 3600 >/dev/null; do sleep 0.1; done; exec sleep 300' _ "$ROOT" "$1" "$2" \
    >/dev/null 2>&1 &
  printf '%s\n' "$!" >>"$WORK/holders"
  local i
  for i in $(seq 1 300); do [ "$(cat "$1"/*/pid 2>/dev/null | grep -cx "$!")" = 1 ] && break; sleep 0.1; done
  printf '%s\n' "$!"
}
unheld() { local pid=''; read -r pid 2>/dev/null <"$1/pid"; ! kill -0 "$pid" 2>/dev/null; }
until_gone() { local i; for i in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
holds_of() { cat "$HARNESS_HOLDS_DIR"/"$1"-*.json 2>/dev/null | jq -s length; }
waits_of() { cat "$HARNESS_WAITS_DIR"/*.jsonl 2>/dev/null | jq -sc --arg c "$1" 'map(select(.class == $c))'; }

sysctl() { echo 12; }
assert [ "$(slots_from_cores 1000 2 4)" = 2 ]
assert [ "$(slots_from_cores 1 2 4)" = 4 ]
assert [ "$(slots_from_cores 1 2)" = 12 ]
sysctl() { echo 3; }
assert [ "$(slots_from_cores 1 2 4)" = 3 ]
# Each pool's floor is its count before room: suites cores / 3 (2 to 4), workers cores / 2 (2 to 8), then up to
# 4 x the cores capped at 40 while there is room.
sysctl() { echo 10; }
assert [ "$(run_suites_slots)" = 3-4 ]
assert [ "$(worker_slots)" = 5-40 ]
pool_slots=$(worker_slots)
sysctl() { echo 2; }
assert [ "$(run_suites_slots)" = 2-4 ]
assert [ "$(worker_slots)" = 2-8 ]
sysctl() { echo 6; }
assert [ "$(worker_slots)" = 3-24 ]
sysctl() { echo 32; }
assert [ "$(run_suites_slots)" = 4-4 ]
assert [ "$(worker_slots)" = 8-40 ]
assert grep -qF '${RUN_SUITES_SLOTS:-$(run_suites_slots)}' "$ROOT/share/run-suites.sh"
assert grep -qF '${WORKER_SLOTS:-$(worker_slots)}' "$ROOT/bin/worker-run"
unset -f sysctl

# Room: pressure level, load1, load15 and free MB, read by stubs from one file a background waiter sees too.
sysctl() { local r; read -ra r <"$WORK/room"; printf '%s\n10\n{ %s 0.00 %s }\n' "${r[0]}" "${r[1]}" "${r[2]}"; }
vm_stat() { local r; read -ra r <"$WORK/room"; printf 'Mach Virtual Memory Statistics: (page size of 1048576 bytes)\nPages free: %s.\nPages inactive: 0.\nPages speculative: 0.\n' "${r[3]}"; }
room() { printf '%s\n' "$*" >"$WORK/room"; }
guard=$(( $(sed -n 's/^GUARD_AVAIL_MB = \([0-9]*\).*/\1/p' "$ROOT/bin/chat-load") + 1500 ))
room 1 150 140 $((guard + 1)); assert slot_room
assert [ -z "$(slot_room)" ]
room 2 150 140 $((guard + 1)); assert_fails slot_room >/dev/null
assert [ "$(slot_room)" = 'memory pressure level 2' ]
room 1 150 140 $((guard - 1)); assert [ "$(slot_room)" = "available $((guard - 1)) MB < $guard MB" ]
room 1 160.5 150 $((guard + 1)); assert [ "$(slot_room)" = 'load 160.5 over its 15-minute base 150 + 10 cores' ]
room 1 160 150 $((guard + 1)); assert slot_room
# A range takes its floor whatever the room, the rest only with room.
mkdir -p "$WORK/r"
room 2 150 140 $((guard + 1))
r1=$(slot_take "$WORK/r" 1-2 3600) || fail "a floor slot waited for room"
assert [ "$r1" = "$WORK/r/1" ]
assert_fails slot_take "$WORK/r" 1-2 3600
slot_take "$WORK/r" 1-2 3600 >/dev/null
assert [ "$SLOT_WHY" = 'memory pressure level 2' ] && assert [ ! -e "$WORK/r/2" ]
(SLOTS_ROOM_POLL_S=0.2 slot_wait "$WORK/r" 1-2 3600 room-limiter "a roomy job" >"$WORK/room-waited") &
waiter=$!
for i in $(seq 1 50); do [ "$(holds_of room-limiter)" = 1 ] && break; sleep 0.1; done
assert jqe '.why == "memory pressure level 2"' "$HARNESS_HOLDS_DIR"/room-limiter-*.json
room 1 150 140 $((guard + 1))
wait "$waiter" || fail "slot_wait never took the room it was given"
assert [ "$(cat "$WORK/room-waited")" = "$WORK/r/2" ]
# Free worker capacity, the night's per-kind share: the count room admits less the live holders.
capacity() { WORKER_SLOTS=2-5 WORKER_SLOTS_DIR="$WORK/cap" worker_capacity; }
mkdir -p "$WORK/cap"
assert [ "$(capacity)" = 5 ]
capper=$(holder "$WORK/cap" 2-5)
assert [ "$(capacity)" = 4 ]
room 2 150 140 $((guard + 1))
assert [ "$(capacity)" = 1 ]
kill "$capper" && until_gone "$capper"
assert [ "$(capacity)" = 2 ]
room 1 150 140 $((guard + 1))
# Its row: refused for room, re-judged on a later poll, admitted at the count room allows.
assert jqe 'length == 1 and .[0].allowed == 2 and .[0].held == 2 and .[0].reason == "room"' <(waits_of room-limiter)
assert_fails slot_take "$WORK/r" 1-2 3600
assert [ -z "$SLOT_WHY" ]
slot_release "$r1"; rm -rf "$WORK/r"
# The last refusal names the wait: refused for room, then every slot held, then admitted.
mkdir -p "$WORK/lr"
room 2 150 140 $((guard + 1))
l1=$(holder "$WORK/lr" 1)
lr_tick() { printf '%s\n' "${SLOT_WHY:-limit}" >>"$WORK/lr-ticks"; }
(HARNESS_WAITS_DIR="$WORK/lr-waits" SLOTS_ROOM_POLL_S=0.2 slot_wait "$WORK/lr" 1-2 3600 workers "last refusal" lr_tick \
  >"$WORK/lr-waited") &
waiter=$!
for i in $(seq 1 100); do grep -q pressure "$WORK/lr-ticks" 2>/dev/null && break; sleep 0.1; done
l2=$(holder "$WORK/lr" 2)
room 1 150 140 $((guard + 1))
for i in $(seq 1 100); do [ "$(tail -n 1 "$WORK/lr-ticks")" = limit ] && break; sleep 0.1; done
assert [ "$(tail -n 1 "$WORK/lr-ticks")" = limit ]
kill "$l2"; until_gone "$l2"
wait "$waiter" || fail "slot_wait never took the slot freed under it"
assert [ "$(cat "$WORK/lr-waited")" = "$WORK/lr/2" ]
assert jqe -s 'length == 1 and .[0].class == "workers" and .[0].allowed == 2 and .[0].held == 2 and .[0].reason == "limit"' \
  "$WORK/lr-waits"/*.jsonl
slot_release "$WORK/lr/2"; kill "$l1"; until_gone "$l1"; rm -rf "$WORK/lr"
# Under memory pressure the worker pool still takes its whole floor of 5, and only the sixth waits.
mkdir -p "$WORK/f"
room 2 150 140 $((guard + 1))
for i in 1 2 3 4 5; do assert [ "$(slot_take "$WORK/f" "$pool_slots" 3600)" = "$WORK/f/$i" ]; done
slot_take "$WORK/f" "$pool_slots" 3600 >/dev/null
assert [ "$SLOT_WHY" = 'memory pressure level 2' ] && assert [ ! -e "$WORK/f/6" ]
# With room it fills to 4 x the cores, 40 here, and the 41st waits for a held slot, not for room.
room 1 150 140 $((guard + 1))
for i in $(seq 6 41); do slot_take "$WORK/f" "$pool_slots" 3600 >/dev/null || break; done
assert [ "$i" = 41 ] && assert [ -e "$WORK/f/40" ] && assert [ ! -e "$WORK/f/41" ]
assert [ -z "$SLOT_WHY" ]
for i in $(seq 1 40); do slot_release "$WORK/f/$i"; done; rm -rf "$WORK/f"
unset -f sysctl vm_stat

mkdir -p "$WORK/s"
h1=$(holder "$WORK/s" 2)
h2=$(holder "$WORK/s" 2)
assert [ -n "$h1" ] && assert [ -n "$h2" ]
assert_fails slot_take "$WORK/s" 2 3600
kill "$h1"; until_gone "$h1"
slot=$(slot_take "$WORK/s" 2 3600) || fail "a dead holder's slot stayed taken"
assert [ "$(cat "$slot/pid")" = $$ ]
slot_release "$slot"
assert [ ! -e "$slot" ]
# A live holder's slot breaks past the holder's own ceiling, never a waiter's shorter one.
mkdir -p "$WORK/c"
h10=$(holder "$WORK/c" 1)
perl -e 'utime(time - 100, time - 100, $ARGV[0])' "$WORK/c/1"
assert_fails slot_take "$WORK/c" 1 10
assert [ "$(cat "$WORK/c/1/pid")" = "$h10" ]
kill "$h10"; until_gone "$h10"

h3=$(holder "$WORK/s" 2)
(slot_wait "$WORK/s" 2 3600 test-limiter "a test job" >"$WORK/waited" 2>"$WORK/wait.err") &
waiter=$!
for i in $(seq 1 50); do [ "$(holds_of test-limiter)" = 1 ] && break; sleep 0.1; done
assert [ "$(holds_of test-limiter)" = 1 ]
assert jqe '.limiter == "test-limiter" and .held.what == "a test job" and .why == "all 2 test-limiter slots are busy"' \
  "$HARNESS_HOLDS_DIR"/test-limiter-*.json
assert grep -qF 'test-limiter: waiting for one of 2 slots' "$WORK/wait.err"
assert kill -0 "$waiter"
kill "$h2"
wait "$waiter" || fail "slot_wait failed"
assert grep -q "^$WORK/s/[12]$" "$WORK/waited"
assert [ "$(holds_of test-limiter)" = 0 ]
assert jqe 'length == 1 and .[0].source == "a test job" and .[0].seconds > 0' <(waits_of test-limiter)
assert jqe '.[0].allowed == 2 and .[0].held == 2 and .[0].reason == "limit"' <(waits_of test-limiter)
kill "$h3"; until_gone "$h3"
# A waiter whose caller was killed stops waiting: slot_wait runs in the caller's $(...) subshell,
# which a TERM to the caller leaves polling, and it would take the next free slot for nobody.
h9=$(holder "$WORK/s" 1)
bash -c '. "$1/share/slots.sh"; slot=$(slot_wait "$2" 1 3600 orphan-limiter "a killed job"); exec sleep 300' \
  _ "$ROOT" "$WORK/s" >/dev/null 2>&1 &
caller=$!
pids+=("$caller")
for i in $(seq 1 50); do [ "$(holds_of orphan-limiter)" = 1 ] && break; sleep 0.1; done
assert [ "$(holds_of orphan-limiter)" = 1 ]
kill "$caller"; until_gone "$caller"
kill "$h9"; until_gone "$h9"
sleep 1
assert unheld "$WORK/s/1"
assert [ "$(holds_of orphan-limiter)" = 0 ]
rm -rf "$WORK/s/1"
# The caller can die inside the take, past the waiter's check: the wrapper kills it right there.
mkdir -p "$WORK/o"
h11=$(holder "$WORK/o" 1)
bash -c '. "$1/share/slots.sh"; eval "real_$(declare -f slot_take)"; marker=$3
  slot_take() {
    real_slot_take "$@" || return 1
    printf "%s\n" "$BASHPID" >"$marker"; kill $$
    while kill -0 $$ 2>/dev/null; do sleep 0.05; done
  }
  slot=$(slot_wait "$2" 1 3600 inside-limiter "a job killed in the take"); exec sleep 300' \
  _ "$ROOT" "$WORK/o" "$WORK/inside-waiter" >/dev/null 2>&1 &
pids+=("$!")
for i in $(seq 1 50); do [ "$(holds_of inside-limiter)" = 1 ] && break; sleep 0.1; done
assert [ "$(holds_of inside-limiter)" = 1 ]
kill "$h11"; until_gone "$h11"
for i in $(seq 1 100); do [ -s "$WORK/inside-waiter" ] && break; sleep 0.1; done
assert until_gone "$(cat "$WORK/inside-waiter")"
assert [ ! -e "$WORK/o/1" ]
assert [ "$(holds_of inside-limiter)" = 0 ]

bash -c 'bash -c "exec sleep 300" & wait' &
tree=$!
pids+=("$tree")
for i in $(seq 1 100); do leaf=$(pgrep -P "$tree" | head -1); [ -z "$leaf" ] || break; sleep 0.1; done
mkdir -p "$HARNESS_HOLDS_DIR"
printf '{"limiter": "x", "pid": %s}\n' "$leaf" >"$HARNESS_HOLDS_DIR/x-$leaf.json"
assert holds_in_tree "$tree"
sleep 300 &
other=$!
pids+=("$other")
assert_fails holds_in_tree "$other"
kill "$leaf"; until_gone "$leaf"
assert_fails holds_in_tree "$tree"
rm -f "$HARNESS_HOLDS_DIR"/x-*.json

mkdir -p "$WORK/repo/tests"
printf '#!/usr/bin/env bash\necho "PASS: slot=$RUN_SUITES_SLOT"\n' >"$WORK/repo/tests/test_a.sh"
export RUN_SUITES_SLOTS_DIR="$WORK/rs" RUN_SUITES_SLOTS=1
mkdir -p "$RUN_SUITES_SLOTS_DIR"
h4=$(holder "$RUN_SUITES_SLOTS_DIR" 1)
bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" >"$WORK/rs.out" 2>&1 &
run=$!
pids+=("$run")
for i in $(seq 1 50); do [ "$(holds_of run-suites)" = 1 ] && break; sleep 0.1; done
assert [ "$(holds_of run-suites)" = 1 ]
assert jqe --arg r "$WORK/repo" '.held.what == "suites of \($r)"' "$HARNESS_HOLDS_DIR"/run-suites-*.json
assert [ -z "$(ls "$STATUSLINE_CACHE_DIR" 2>/dev/null | grep '^suites-')" ]
assert kill -0 "$run"
sleep 1
kill "$h4"
wait "$run" || fail "run-suites failed: $(cat "$WORK/rs.out")"
assert grep -q "PASS: slot=$RUN_SUITES_SLOTS_DIR/1" "$WORK/rs.out"
# Its journal row keeps the queue apart from the run: queued at launch, started once slotted.
assert jqe --arg slot "$RUN_SUITES_SLOTS_DIR/1" --argjson pid "$run" \
  '.pid == $pid and .slot == $slot and .started_at - .queued_at >= 1 and .ended_at >= .started_at' "$WORK/runs.jsonl"
# Its pointer outlives it, so a probe that only ever saw it queued still journals it.
assert [ "$(cut -f2 "$STATUSLINE_CACHE_DIR/suites-$run.done")" = 1 ]
assert [ ! -e "$RUN_SUITES_SLOTS_DIR/1" ]
assert [ "$(holds_of run-suites)" = 0 ]
assert jqe --arg r "$WORK/repo" 'length == 1 and .[0].source == "suites of \($r)" and .[0].seconds >= 1' <(waits_of run-suites)
# A nested run inside a suite inherits its parent's slot instead of queueing behind it.
h5=$(holder "$RUN_SUITES_SLOTS_DIR" 1)
RUN_SUITES_SLOT="$RUN_SUITES_SLOTS_DIR/1" bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" >"$WORK/nested.out" 2>&1 ||
  fail "a nested run failed: $(cat "$WORK/nested.out")"
assert grep -q '1 PASS' "$WORK/nested.out"
assert jqe --arg slot "$RUN_SUITES_SLOTS_DIR/1" '.slot == $slot and .started_at - .queued_at < 0.5' <(tail -1 "$WORK/runs.jsonl")
# Its progress file still carries a start stamp, or the statusline shows it queued until it ends.
mkdir -p "$WORK/stamp/tests"
printf '#!/usr/bin/env bash\necho "PASS: stamp=$(cut -f4 "$STATUSLINE_CACHE_DIR"/suites-*[0-9])"\n' >"$WORK/stamp/tests/test_s.sh"
RUN_SUITES_SLOT="$RUN_SUITES_SLOTS_DIR/1" bash "$ROOT/share/run-suites.sh" --repo "$WORK/stamp" >"$WORK/stamp.out" 2>&1 ||
  fail "a nested run failed: $(cat "$WORK/stamp.out")"
assert grep -Eq 'PASS: stamp=[0-9]+$' "$WORK/stamp.out"
kill "$h5"; until_gone "$h5"
# A run down to its last suite frees its slot: a queued run goes through while that suite still runs.
mkdir -p "$WORK/tail/tests"
printf '#!/usr/bin/env bash\n: >"%s/long-started"\nuntil [ -e "%s/tail-go" ]; do sleep 0.1; done\n' "$WORK" "$WORK" \
  >"$WORK/tail/tests/test_long.sh"
printf '#!/usr/bin/env bash\n:\n' >"$WORK/tail/tests/test_short.sh"
bash "$ROOT/share/run-suites.sh" --repo "$WORK/tail" -j 2 >"$WORK/tail.out" 2>&1 &
tail_run=$!
pids+=("$tail_run")
for i in $(seq 1 100); do [ -e "$WORK/long-started" ] && break; sleep 0.1; done
bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" >"$WORK/after-tail.out" 2>&1 &
next_run=$!
pids+=("$next_run")
assert until_gone "$next_run"
assert kill -0 "$tail_run"
: >"$WORK/tail-go"
wait "$tail_run" || fail "the tail run failed: $(cat "$WORK/tail.out")"
assert grep -q '2 PASS' "$WORK/tail.out"
assert [ ! -e "$RUN_SUITES_SLOTS_DIR/1" ]
# A worker's run stops queueing once that worker has ended; an exit code already there is a stale export.
h7=$(holder "$RUN_SUITES_SLOTS_DIR" 1)
# A run that cannot start fails before it queues.
bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" test_nope.sh >"$WORK/nope.out" 2>&1 &
nope_run=$!
pids+=("$nope_run")
until_gone "$nope_run" || fail "a run naming no suite queued for a slot"
assert grep -q 'no such suite' "$WORK/nope.out"
mkdir -p "$WORK/wrun"
WORKER_RUN_RECORD="$WORK/wrun" WORKER_RUN_ID=wrun bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" test_a.sh \
  >"$WORK/ended.out" 2>&1 &
ended_run=$!
pids+=("$ended_run")
for i in $(seq 1 50); do [ "$(holds_of run-suites)" = 1 ] && break; sleep 0.1; done
assert [ "$(holds_of run-suites)" = 1 ]
echo 0 >"$WORK/wrun/exit_code"
until_gone "$ended_run" || fail "a run kept queueing after its worker ended"
ended_rc=0; wait "$ended_run" || ended_rc=$?
assert [ "$ended_rc" -eq 4 ]
assert grep -q 'worker wrun ended while this run waited for a slot' "$WORK/ended.out"
assert [ "$(holds_of run-suites)" = 0 ]
assert [ "$(cat "$RUN_SUITES_SLOTS_DIR/1/pid")" = "$h7" ]
assert jqe --arg r "$WORK/repo" 'map(select(.reason == "owner-ended")) | length == 1 and .[0].source == "suites of \($r)"
  and .[0].allowed == 1 and .[0].held == 1' <(waits_of run-suites)
# A supervisor gone without an exit code ends its queued run the same way.
sleep 300 &
owner_sup=$!
pids+=("$owner_sup")
mkdir -p "$WORK/dead-owner"
jq -n --argjson p "$owner_sup" '{pid: $p}' >"$WORK/dead-owner/meta.json"
WORKER_RUN_RECORD="$WORK/dead-owner" WORKER_RUN_ID=dead-owner bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" test_a.sh \
  >"$WORK/dead.out" 2>&1 &
dead_run=$!
pids+=("$dead_run")
for i in $(seq 1 50); do [ "$(holds_of run-suites)" = 1 ] && break; sleep 0.1; done
assert [ "$(holds_of run-suites)" = 1 ]
kill "$owner_sup"; until_gone "$owner_sup"
until_gone "$dead_run" || fail "a run kept queueing after its worker's supervisor died"
dead_rc=0; wait "$dead_run" || dead_rc=$?
assert [ "$dead_rc" -eq 4 ]
assert jqe 'map(select(.reason == "owner-ended")) | length == 2' <(waits_of run-suites)
kill "$h7"; until_gone "$h7"
WORKER_RUN_RECORD="$WORK/wrun" WORKER_RUN_ID=wrun bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" test_a.sh \
  >"$WORK/stale.out" 2>&1 || fail "a stale worker export refused the run: $(cat "$WORK/stale.out")"
assert jqe -s 'last | .worker_run == null' "$WORK/runs.jsonl"
# Once its worker ends, a slotted run drops its queued suites and ends its running ones as a tree;
# a run with no worker owner beside it runs on.
export OWNER_FIXTURE="$WORK/of"
mkdir -p "$OWNER_FIXTURE" "$WORK/owned/tests" "$WORK/ownerless/tests" "$WORK/owner"
printf '#!/usr/bin/env bash\nsleep 300 &\necho "$!" >"$OWNER_FIXTURE/child"\nwait\n' >"$WORK/owned/tests/test_long.sh"
printf '#!/usr/bin/env bash\n: >"$OWNER_FIXTURE/next-ran"\n' >"$WORK/owned/tests/test_next.sh"
printf '#!/usr/bin/env bash\n: >"$OWNER_FIXTURE/free-started"\nuntil [ -e "$OWNER_FIXTURE/release" ]; do sleep 0.1; done\n' \
  >"$WORK/ownerless/tests/test_free.sh"
sleep 300 &
owner_sup=$!
pids+=("$owner_sup")
jq -n --argjson p "$owner_sup" '{pid: $p}' >"$WORK/owner/meta.json"
RUN_SUITES_SLOTS=2 WORKER_RUN_RECORD="$WORK/owner" WORKER_RUN_ID=owner bash "$ROOT/share/run-suites.sh" --repo "$WORK/owned" -j 1 \
  >"$WORK/owned.out" 2>&1 &
owned_run=$!
RUN_SUITES_SLOTS=2 bash "$ROOT/share/run-suites.sh" --repo "$WORK/ownerless" >"$WORK/ownerless.out" 2>&1 &
free_run=$!
pids+=("$owned_run" "$free_run")
for i in $(seq 1 300); do [ -s "$OWNER_FIXTURE/child" ] && [ -e "$OWNER_FIXTURE/free-started" ] && break; sleep 0.1; done
assert [ -s "$OWNER_FIXTURE/child" ]
assert [ -e "$OWNER_FIXTURE/free-started" ]
owned_child=$(cat "$OWNER_FIXTURE/child")
echo 0 >"$WORK/owner/exit_code"
for i in $(seq 1 300); do kill -0 "$owned_run" 2>/dev/null || break; sleep 0.1; done
owned_rc=0; wait "$owned_run" || owned_rc=$?
assert [ "$owned_rc" -eq 1 ]
assert until_gone "$owned_child"
assert [ ! -e "$OWNER_FIXTURE/next-ran" ]
assert grep -Eq '^test_long\.sh +FAIL .*cancelled, its worker run ended$' "$WORK/owned.out"
assert grep -Eq '^test_next\.sh +FAIL .*cancelled, its worker run ended$' "$WORK/owned.out"
assert_fails grep -q 'No such file' "$WORK/owned.out"
assert jqe -s --argjson p "$owned_run" 'map(select(.pid == $p)) | length == 1
  and .[0].reason == "owner-ended" and .[0].complete == false and .[0].suites == {}' "$WORK/runs.jsonl"
assert kill -0 "$free_run"
: >"$OWNER_FIXTURE/release"
wait "$free_run" || fail "an ownerless run failed: $(cat "$WORK/ownerless.out")"
assert jqe -s --argjson p "$free_run" 'map(select(.pid == $p)) | length == 1
  and (.[0] | has("reason") | not) and .[0].complete and .[0].suites["test_free.sh"].rc == 0' "$WORK/runs.jsonl"

# worker-run: a run waits for one of WORKER_SLOTS, its deadline counted from the slot; its slot goes
# when it ends.
git -C "$WORK" init -q night && git -C "$WORK/night" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$WORK/night" worktree add -q -b night/n1/llm-health-1 "$WORK/night-wt"
mkdir -p "$WORK/run"
jq -n --arg w "$WORK/night-wt" '{vendor: "none", workdir: $w, started_at: 1}' >"$WORK/run/meta.json"
export WORKER_SLOTS_DIR="$WORK/fs" WORKER_SLOTS=1
mkdir -p "$WORKER_SLOTS_DIR"
h6=$(holder "$WORKER_SLOTS_DIR" 1)
bash "$ROOT/bin/worker-run" _supervise "$WORK/run" >/dev/null 2>&1 &
sup=$!
pids+=("$sup")
for i in $(seq 1 50); do [ "$(holds_of workers)" = 1 ] && break; sleep 0.1; done
assert [ "$(holds_of workers)" = 1 ]
assert jqe '.held.what | test("^worker run run on night/n1/llm-health-1$")' "$HARNESS_HOLDS_DIR"/workers-*.json
assert kill -0 "$sup"
before=$(date +%s)
kill "$h6"
wait "$sup"
assert [ $? = 4 ]
assert jqe --argjson b "$before" '.started_at == 1 and .slot_at >= $b' "$WORK/run/meta.json"
assert [ ! -e "$WORKER_SLOTS_DIR/1" ]
assert [ "$(holds_of workers)" = 0 ]
assert jqe 'length == 1 and (.[0].source | test("^worker run run on night/n1/llm-health-1$"))' <(waits_of workers)
# A night run nested under a slot holder's worker inherits its slot instead of waiting on its ancestor.
h8=$(holder "$WORKER_SLOTS_DIR" 1)
WORKER_SLOT="$WORKER_SLOTS_DIR/1" bash "$ROOT/bin/worker-run" _supervise "$WORK/run" >/dev/null 2>&1 &
nested=$!
until_gone "$nested" || { kill "$nested"; fail "a nested night run waited for the slot its ancestor holds"; }
wait "$nested"
assert [ $? = 4 ]
assert [ "$(holds_of workers)" = 0 ]
assert [ "$(cat "$WORKER_SLOTS_DIR/1/pid")" = "$h8" ]
kill "$h8"; until_gone "$h8"
# A day branch and a workdir outside git wait for the same pool and start once a slot frees.
admitted() { # run-dir what
  local h sup i
  h=$(holder "$WORKER_SLOTS_DIR" 1)
  bash "$ROOT/bin/worker-run" _supervise "$1" >/dev/null 2>&1 &
  sup=$!
  pids+=("$sup")
  for i in $(seq 1 50); do [ "$(holds_of workers)" = 1 ] && break; sleep 0.1; done
  assert [ "$(holds_of workers)" = 1 ]
  assert jqe --arg w "worker run ${1##*/} on $2" '.held.what == $w' "$HARNESS_HOLDS_DIR"/workers-*.json
  assert kill -0 "$sup"
  kill "$h"
  wait "$sup"
  assert [ $? = 4 ]
  assert jqe '.slot_at >= .started_at' "$1/meta.json"
  assert [ ! -e "$WORKER_SLOTS_DIR/1" ]
  assert [ "$(holds_of workers)" = 0 ]
}
git -C "$WORK/night-wt" checkout -q -b day-branch
admitted "$WORK/run" day-branch
mkdir -p "$WORK/plain" "$WORK/run-plain"
jq -n --arg w "$WORK/plain" '{vendor: "none", workdir: $w, started_at: 1}' >"$WORK/run-plain/meta.json"
admitted "$WORK/run-plain" "$WORK/plain"
assert jqe --arg p "worker run run-plain on $WORK/plain" 'length == 3 and .[1].source == "worker run run on day-branch"
  and .[2].source == $p' <(waits_of workers)
# The Speed window, checked once the slot is taken: a Speed fixer whose slot comes 6 h or more after the
# night's start is not started and its job is left; one inside the window starts; a non-speed fixer after
# 6 h starts too.
export DOCTORS_DIR="$WORK/doctors"
mkdir -p "$DOCTORS_DIR/runs" "$DOCTORS_DIR/nights"
gated() { # night hours-ago ref area -> the supervised run's err once it ended
  jq -n --arg id "$1" --argjson h "$2" --arg r "$3" '{id: $id, started_at: (now - $h * 3600 | floor | todate),
    finished_at: null, jobs: [{kind: "fixer", ref: $r, state: "pending", reason: null}]}' >"$DOCTORS_DIR/nights/$1.json"
  jq -n --arg id "$3" --arg a "$4" '{id: $id, doctor: "harness", area: $a, launched_at: "2026-10-07T00:00:00Z",
    closed_at: null, abandoned_at: null, failed_at: null, problems: [{id: "p"}]}' >"$DOCTORS_DIR/runs/$3.json"
  git -C "$WORK/night" worktree add -q -b "night/$1/$3" "$WORK/wt-$3"
  mkdir -p "$WORK/run-$3"
  jq -n --arg w "$WORK/wt-$3" '{vendor: "none", workdir: $w, started_at: 1}' >"$WORK/run-$3/meta.json"
  bash "$ROOT/bin/worker-run" _supervise "$WORK/run-$3" >/dev/null 2>&1
  cat "$WORK/run-$3/err" 2>/dev/null
}
assert [ "$(gated nlate 7 hs-late speed-tests-llm-legs-test-a)" = "worker-run: speed window closed (6 h): night nlate job hs-late left, its fixer not started" ]
assert jq -e '.jobs[0].state == "left" and .jobs[0].reason == "speed window closed (6 h)" and all(.events[]; .phase != "speed-start")' "$DOCTORS_DIR/nights/nlate.json" >/dev/null
assert jq -e '.abandoned_at != null' "$DOCTORS_DIR/runs/hs-late.json" >/dev/null
assert [ -z "$(gated nopen 5 hs-in speed-chat-hooks)" ]
assert jq -e '.jobs[0].state == "pending" and [.events[] | .phase] == ["speed-start"]' "$DOCTORS_DIR/nights/nopen.json" >/dev/null
assert [ -z "$(gated nhooks 7 hh-late hooks)" ]
assert jq -e '.jobs[0].state == "pending" and .events == null' "$DOCTORS_DIR/nights/nhooks.json" >/dev/null
assert jq -e '.abandoned_at == null' "$DOCTORS_DIR/runs/hh-late.json" >/dev/null
# The Speed window is the night's own deadline: only a run on a night branch asks night-run speed-gate.
mkdir -p "$WORK/fake/bin"
cp "$ROOT/bin/worker-run" "$WORK/fake/bin/worker-run"
ln -s "$ROOT/share" "$WORK/fake/share"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/gate-calls"\n' "$WORK" >"$WORK/fake/bin/night-run"
chmod +x "$WORK/fake/bin/night-run"
for r in run run-plain run-hs-in; do bash "$WORK/fake/bin/worker-run" _supervise "$WORK/$r" >/dev/null 2>&1; done
assert [ "$(cat "$WORK/gate-calls")" = 'speed-gate nopen hs-in' ]
assert [ ! -e "$WORKER_SLOTS_DIR/1" ]
# A slot taken or refused at once is no wait: slot polling never journals a lock row.
assert jqe 'length == 0' <(waits_of lock)

printf 'PASS: test_slots.sh (%s asserts)\n' "$asserts"
