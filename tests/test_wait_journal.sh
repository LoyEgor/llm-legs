#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The wait journal: wait_note (bash and Python) writes one row per wait, hold_clear journals a hold's wait,
# and bin/harness-doctor's Wait classes shows every class with its day totals, red past a limit or on growth.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
jqe() { jq -e "$@" >/dev/null; }
export TZ=UTC HOME="$WORK/home" HARNESS_DOCTOR_DIR="$WORK/state" HARNESS_HOLDS_DIR="$WORK/holds"
unset HARNESS_WAITS_DIR
W="$WORK/state/waits"
T=1768032000

out=$(bash -c 'set -euo pipefail; . "$1/share/limiter-hold.sh"
  wait_note lock "$(printf "a \"q\" \\\\b\tc")" 1768032000.25 12.5
  wait_note lock x not-a-time
  HARNESS_WAITS_DIR=/dev/null/w wait_note lock x 1768032000
  wait_note lock future 4102444800
  file=$(hold_raise run-suites "suites of r" busy); hold_clear "$file"; echo survived' _ "$ROOT") ||
  fail "a writer failed its set -e caller"
/bin/bash -c '. "$1/share/limiter-hold.sh"; wait_note lock bash-3.2 1768032000 2' _ "$ROOT"
assert [ "$out" = survived ]
assert jqe -s 'length == 2 and .[0] == {class: "lock", source: "a \"q\" \\b c", started: 1768032000.25, seconds: 12.5, pid: .[0].pid}
  and .[1].source == "bash-3.2" and .[1].seconds == 2' "$W/2026-01-10.jsonl"
assert jqe -s 'map(select(.class == "run-suites")) | length == 1 and .[0].source == "suites of r" and .[0].seconds >= 0' \
  "$W/$(date +%Y-%m-%d).jsonl"
assert [ -z "$(ls "$HARNESS_HOLDS_DIR")" ]
assert [ ! -e "$W/2100-01-01.jsonl" ]
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import limiter_hold as h
h.wait_note("poll", "worker-run wait r1", 1767945600, 3); h.wait_note("poll", "x", "bad")
h.hold_clear(h.hold_raise("night-workers", "job", "busy"))' "$ROOT/share"
assert jqe -s 'length == 1 and .[0].class == "poll" and .[0].seconds == 3 and .[0].started == 1767945600' "$W/2026-01-09.jsonl"
assert jqe -s 'map(select(.class == "night-workers" and .source == "job")) | length == 1' "$W/$(date +%Y-%m-%d).jsonl"

RUNS="$WORK/runs"
mkdir -p "$RUNS/r1" "$RUNS/r2"
sleep 60 &
sup=$!
for r in r1 r2; do jq -n --argjson p "$sup" --argjson t "$(date +%s)" '{vendor: "none", pid: $p, started_at: $t}' >"$RUNS/$r/meta.json"; done
printf '0\n' >"$RUNS/r2/exit_code"
perl -e 'utime(time - 5, time - 5, $ARGV[0])' "$RUNS/r2/exit_code"
(until jq -e '.phase == "wait"' "$RUNS/r1/state.json" >/dev/null 2>&1; do sleep 0.1; done
  sleep 1.2; printf '0\n' >"$RUNS/r1/exit_code") &
for r in r2 r1; do
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDEB_WORKER WORKER_RUN_DIR="$RUNS" WORKER_RUN_WAIT_POLL_S=1 \
    bash "$ROOT/bin/worker-run" wait "$r" --max 30 >"$WORK/wait-$r.out" 2>&1
done
kill "$sup"
assert jqe -s 'map(select(.class == "poll")) | length == 1 and .[0].source == "worker-run wait r1" and .[0].seconds >= 0' \
  "$W/$(date +%Y-%m-%d).jsonl"

rm -rf "$W"
mkdir -p "$W"
day() { date -u -r "$1" +%Y-%m-%d; }
note() { printf '{"class":"%s","source":"%s","started":%s,"seconds":%s,"pid":1}\n' "$1" "$2" "$3" "$4" >>"$W/$(day "$3").jsonl"; }
for s in 30 60 90; do note run-suites "suites of r" $((T + s)) "$s"; done
note lock /store.lock $((T + 100)) 120.5
note lock /store.lock $((T + 200)) 1
for back in 1 2 3 4; do note night-workers job $((T - back * 86400)) 600; done
for s in 500 500 500; do note night-workers "job $s" $((T + s)) "$s"; done
note poll "worker-run wait r" $((T - 2 * 86400)) 4
printf 'not json\n{"class":"lock","seconds":"x","started":1}\n' >>"$W/$(day "$T").jsonl"
note lock /ancient $((T - 20 * 86400)) 1
read_section() {
  python3 -c 'import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(module)
now = float(sys.argv[2])
if sys.argv[3:] == ["prune"]:
    module.prune(now)
print(json.dumps(module.waits_classes_section(now)))' "$ROOT/bin/harness-doctor" "$((T + 3600))" "$@"
}
read_section >"$WORK/section.json" || fail "the reader failed"
cls() { jq -c --arg c "$1" '.rows[] | select(.key == "waits:" + $c)' "$WORK/section.json"; }
assert jqe '.name == "Wait classes" and .state == "problem" and ([.rows[].cells[0]] | sort) == ["lock", "night-workers", "poll", "run-suites"]' \
  "$WORK/section.json"
assert jqe '.dim and .red == [] and .cells == ["run-suites", "3", "180 s", "60 s", "90 s", "90 s", "–"]' <(cls run-suites)
assert jqe '.red == [5] and ([.judge[] | select(.level == "red") | [.rule, .value, .limit]] == [["wait_class", 120.5, 60]])
  and (.judge[0].evidence[0].ref | test("^waits/2026-01-10.jsonl 1768032100.000$"))' <(cls lock)
assert jqe '.red == [2] and ([.judge[] | select(.level == "red") | [.rule, .value, .limit]] == [["wait_growth", 1500, 1200]])
  and .cells[6] == "10m 00s"' <(cls night-workers)
assert jqe '.dim and .cells[1] == "0" and .cells[5] == "–" and .menu.rows[0].cells[0] == "2026-01-08"' <(cls poll)
read_section prune >/dev/null || fail "the reader failed after a prune"
assert [ ! -e "$W/$(day $((T - 20 * 86400))).jsonl" ]
assert [ -e "$W/$(day $((T - 4 * 86400))).jsonl" ]
rm -rf "$W"
assert jqe '.state == "blind" and .rows == []' <(read_section)

printf 'PASS: test_wait_journal.sh (%s asserts)\n' "$asserts"
