#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# `worker-run in-flight <session-id> [<pid>...]` (share/worker-run-wait.sh inflight_run), the Chats app's
# APP_DETACHED: a chat's runs in flight in a fake runs root (WORKER_RUN_DIR) with the line that waits on each
# again, and which of the given pids are a background wait on one of them. A run of another chat, one whose
# supervisor is dead and a finished one are out; a process that waits on none is no wait.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/share/processes.sh"
WORK=$(mktemp -d)
# A supervisor alive for as long as the suite.
( while kill -0 $$ 2>/dev/null; do sleep 1; done ) &
LIVE_PID=$!
PIDS=''
trap 'kill "$LIVE_PID" 2>/dev/null; [ -z "$PIDS" ] || { pids_end 0 $(process_tree $PIDS); }; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs"
unset CLAUDEB_WORKER GROK_WORKER WORKER_RUN_ID
asserts=0
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "line ${BASH_LINENO[0]}: expected [$1] got [$2]"; }

( : ) & DEAD_PID=$!
wait "$DEAD_PID"
now=$(date +%s)
run() { # id session supervisor-pid phase [light]
  mkdir -p "$WORKER_RUN_DIR/$1"
  printf '%s\n' "$2" >"$WORKER_RUN_DIR/$1/launcher"
  printf '{"vendor":"codex","pid":%s,"started_at":%s%s}\n' "$3" "$now" "${5:+,\"light\":\"$5\"}" >"$WORKER_RUN_DIR/$1/meta.json"
  printf '{"phase":"%s","session":"%s"}\n' "$4" "$2" >"$WORKER_RUN_DIR/$1/state.json"
}
run codex-1-1-aaaa s1 "$LIVE_PID" wait
run codex-2-2-bbbb s1 "$LIVE_PID" start
run light-3-3-cccc s1 "$LIVE_PID" wait research
run codex-4-4-dddd s1 "$DEAD_PID" wait          # its supervisor is dead
run codex-5-5-eeee s1 "$LIVE_PID" done          # finished
run codex-6-6-ffff s1 "$LIVE_PID" wait
printf '0\n' >"$WORKER_RUN_DIR/codex-6-6-ffff/exit_code"
run codex-7-7-abcd s2 "$LIVE_PID" wait          # another chat's

inflight() { bash "$ROOT/bin/worker-run" in-flight "$@"; }
ids() { jq -r '[.jobs[].id] | sort | join(" ")'; }

out=$(inflight s1)
assert_eq "codex-1-1-aaaa codex-2-2-bbbb light-3-3-cccc" "$(ids <<<"$out")"
assert_eq "worker-run wait codex-1-1-aaaa --report" "$(jq -r '.jobs[] | select(.id == "codex-1-1-aaaa") | .attach' <<<"$out")"
assert_eq "light-research --attach light-3-3-cccc --out <answer-file>" \
  "$(jq -r '.jobs[] | select(.id == "light-3-3-cccc") | .attach' <<<"$out")"
assert_eq "[]" "$(jq -c '[.jobs[].waits[]]' <<<"$out")"
assert_eq '{"jobs":[]}' "$(inflight s9)"
# The supervisor dies: the run is no longer in flight.
( while kill -0 $$ 2>/dev/null; do sleep 1; done ) &
GOES=$!
run codex-8-8-face s3 "$GOES" wait
assert_eq "codex-8-8-face" "$(inflight s3 | ids)"
kill "$GOES"; wait "$GOES" 2>/dev/null
assert_eq "" "$(inflight s3 | ids)"

# Waits: a background shell running `worker-run wait <id>` (piped, as a chat's Bash does), one waiting on another
# chat's run, an ordinary process. A stub named worker-run stands for the wait; its ready file is written once its
# own command line is in the process table.
mkdir -p "$WORK/bin" "$WORK/ready"
printf '#!/bin/sh\n: >"%s/ready/$2"\nwhile :; do sleep 1; done\n' "$WORK" >"$WORK/bin/worker-run"
chmod +x "$WORK/bin/worker-run"
ready() { local i; for ((i = 0; i < 1000; i++)); do [ -e "$WORK/ready/$1" ] && return; sleep 0.01; done
  fail "line ${BASH_LINENO[0]}: the wait on $1 never started"; }
bash -c "\"$WORK/bin/worker-run\" wait codex-1-1-aaaa --report 2>&1 | tail -30" & W1=$!
bash -c "\"$WORK/bin/worker-run\" wait codex-7-7-abcd --report" & W2=$!
sleep 300 & OTHER=$!
PIDS="$W1 $W2 $OTHER"
ready codex-1-1-aaaa; ready codex-7-7-abcd
out=$(inflight s1 "$W1" "$W2" "$OTHER")
assert_eq "[$W1]" "$(jq -c '.jobs[] | select(.id == "codex-1-1-aaaa") | .waits' <<<"$out")"
assert_eq "[$W1]" "$(jq -c '[.jobs[].waits[]]' <<<"$out")"
assert_eq "[$W2]" "$(inflight s2 "$W1" "$W2" "$OTHER" | jq -c '[.jobs[].waits[]]')"
# A wait on a run whose supervisor died is no wait of a run in flight.
bash -c "\"$WORK/bin/worker-run\" wait codex-4-4-dddd --report" & W3=$!
PIDS="$PIDS $W3"
ready codex-4-4-dddd
assert_eq "[]" "$(inflight s1 "$W3" | jq -c '[.jobs[].waits[]]')"
# Bad arguments: refused, nothing printed.
for bad in "" "a b" "../x"; do
  asserts=$((asserts + 1))
  ! inflight "$bad" >/dev/null 2>&1 || fail "session [$bad] accepted"
done
asserts=$((asserts + 1))
! inflight s1 12x >/dev/null 2>&1 || fail "pid 12x accepted"
printf 'PASS: %s asserts; worker-run in-flight: a chat'"'"'s runs in flight (launcher, state.json session and phase, a live supervisor) with the line that waits on each again, and the given pids whose tree waits on one of them; another chat'"'"'s run, a dead supervisor, a finished run and an ordinary process are out\n' "$asserts"
