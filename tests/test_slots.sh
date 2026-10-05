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
unset RUN_SUITES_SLOT NIGHT_FIXER_SLOT
. "$ROOT/share/slots.sh"

holder() { # dir count -> pid of a process holding one slot until killed
  bash -c '. "$1/share/slots.sh"; slot_take "$2" "$3" 3600 >/dev/null || exit 1; exec sleep 300' _ "$ROOT" "$1" "$2" \
    >/dev/null 2>&1 &
  printf '%s\n' "$!" >>"$WORK/holders"
  local i
  for i in $(seq 1 50); do [ "$(cat "$1"/*/pid 2>/dev/null | grep -cx "$!")" = 1 ] && break; sleep 0.1; done
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
# Each pool's floor is its count before room: suites cores / 3 (2 to 4), night workers cores / 2 (2 to 8).
sysctl() { echo 10; }
assert [ "$(run_suites_slots)" = 3-4 ]
assert [ "$(night_worker_slots)" = 5-10 ]
night_slots=$(night_worker_slots)
sysctl() { echo 2; }
assert [ "$(run_suites_slots)" = 2-4 ]
assert [ "$(night_worker_slots)" = 2-2 ]
sysctl() { echo 32; }
assert [ "$(run_suites_slots)" = 4-4 ]
assert [ "$(night_worker_slots)" = 8-12 ]
assert grep -qF '${RUN_SUITES_SLOTS:-$(run_suites_slots)}' "$ROOT/share/run-suites.sh"
assert grep -qF '${NIGHT_FIXER_SLOTS:-$(night_worker_slots)}' "$ROOT/bin/worker-run"
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
assert_fails slot_take "$WORK/r" 1-2 3600
assert [ -z "$SLOT_WHY" ]
slot_release "$r1"; rm -rf "$WORK/r"
# Under memory pressure the night pool still takes its whole floor of 5, and only the sixth waits.
mkdir -p "$WORK/f"
room 2 150 140 $((guard + 1))
for i in 1 2 3 4 5; do assert [ "$(slot_take "$WORK/f" "$night_slots" 3600)" = "$WORK/f/$i" ]; done
slot_take "$WORK/f" "$night_slots" 3600 >/dev/null
assert [ "$SLOT_WHY" = 'memory pressure level 2' ] && assert [ ! -e "$WORK/f/6" ]
for i in 1 2 3 4 5; do slot_release "$WORK/f/$i"; done; rm -rf "$WORK/f"
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

# worker-run: a run on a night branch waits for one of NIGHT_FIXER_SLOTS, its deadline counted from
# the slot; its slot goes when it ends. Any other branch never waits.
git -C "$WORK" init -q night && git -C "$WORK/night" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$WORK/night" worktree add -q -b night/n1/llm-health-1 "$WORK/night-wt"
mkdir -p "$WORK/run"
jq -n --arg w "$WORK/night-wt" '{vendor: "none", workdir: $w, started_at: 1}' >"$WORK/run/meta.json"
export NIGHT_FIXER_SLOTS_DIR="$WORK/fs" NIGHT_FIXER_SLOTS=1
mkdir -p "$NIGHT_FIXER_SLOTS_DIR"
h6=$(holder "$NIGHT_FIXER_SLOTS_DIR" 1)
bash "$ROOT/bin/worker-run" _supervise "$WORK/run" >/dev/null 2>&1 &
sup=$!
pids+=("$sup")
for i in $(seq 1 50); do [ "$(holds_of night-workers)" = 1 ] && break; sleep 0.1; done
assert [ "$(holds_of night-workers)" = 1 ]
assert jqe '.held.what | test("^worker run run on night/n1/llm-health-1$")' "$HARNESS_HOLDS_DIR"/night-workers-*.json
assert kill -0 "$sup"
before=$(date +%s)
kill "$h6"
wait "$sup"
assert [ $? = 4 ]
assert jqe --argjson b "$before" '.started_at == 1 and .slot_at >= $b' "$WORK/run/meta.json"
assert [ ! -e "$NIGHT_FIXER_SLOTS_DIR/1" ]
assert [ "$(holds_of night-workers)" = 0 ]
assert jqe 'length == 1 and (.[0].source | test("^worker run run on night/n1/llm-health-1$"))' <(waits_of night-workers)
# A night run nested under a slot holder's worker inherits its slot instead of waiting on its ancestor.
h8=$(holder "$NIGHT_FIXER_SLOTS_DIR" 1)
NIGHT_FIXER_SLOT="$NIGHT_FIXER_SLOTS_DIR/1" bash "$ROOT/bin/worker-run" _supervise "$WORK/run" >/dev/null 2>&1 &
nested=$!
until_gone "$nested" || { kill "$nested"; fail "a nested night run waited for the slot its ancestor holds"; }
wait "$nested"
assert [ $? = 4 ]
assert [ "$(holds_of night-workers)" = 0 ]
assert [ "$(cat "$NIGHT_FIXER_SLOTS_DIR/1/pid")" = "$h8" ]
kill "$h8"; until_gone "$h8"
git -C "$WORK/night-wt" checkout -q -b day-branch
h7=$(holder "$NIGHT_FIXER_SLOTS_DIR" 1)
bash "$ROOT/bin/worker-run" _supervise "$WORK/run" >/dev/null 2>&1
assert [ $? = 4 ]
assert [ "$(holds_of night-workers)" = 0 ]
kill "$h7"
# A slot taken or refused at once is no wait: slot polling never journals a lock row.
assert jqe 'length == 0' <(waits_of lock)

printf 'PASS: test_slots.sh (%s asserts)\n' "$asserts"
