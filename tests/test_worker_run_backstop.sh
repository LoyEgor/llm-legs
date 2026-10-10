#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-run-backstop.sh"
WORK=$(mktemp -d)
# A supervisor alive for as long as the suite: a `sleep 300` ended mid-suite under load, and every run read dead.
( while kill -0 $$ 2>/dev/null; do sleep 1; done ) &
LIVE_PID=$!
trap 'kill "$LIVE_PID" ${WAIT_PIDS:-} 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs" WORKER_STATS_DIR="$WORK/stats"
# The chat is this suite, never whatever `claude` happens to be among the runner's ancestors.
export WORKER_RUN_BACKSTOP_CHAT_PID=$$
unset CLAUDEB_WORKER
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "line ${BASH_LINENO[0]}: expected [$1] got [$2]"; }
assert_has() { asserts=$((asserts + 1)); case "$2" in *"$1"*) ;; *) fail "line ${BASH_LINENO[0]}: [$2] lacks [$1]" ;; esac; }

mkdir -p "$WORKER_STATS_DIR/progress"
run() { # id launcher vendor [pid]
  mkdir -p "$WORKER_RUN_DIR/$1"
  printf '%s\n' "$2" >"$WORKER_RUN_DIR/$1/launcher"
  jq -nc --arg v "$3" --argjson p "${4:-$LIVE_PID}" '{vendor:$v,role:"workers",pid:$p}' >"$WORKER_RUN_DIR/$1/meta.json"
  printf '{"phase":"start"}\n' >"$WORKER_RUN_DIR/$1/state.json"
  printf 'acct · astra · high\n' >"$WORKER_RUN_DIR/$1/tag"
}
stop() { # [extra jq]
  jq -cn "{hook_event_name:\"Stop\",session_id:\"s1\"} ${1:-}" | bash "$HOOK"
}
forget() { rm -rf "$HOME/.cache/claude/stop-backstop"; }
reason() { jq -r '.reason // empty' 2>/dev/null; }

# A live run of this chat with no live wait holds the stop and names the wait and the run's tag.
run r1 s1 codex
out=$(stop)
assert_eq block "$(jq -r .decision <<<"$out")"
assert_has 'worker run r1 (acct · astra · high) — `worker-run wait r1`' "$(reason <<<"$out")"
assert_has 'Start each wait now as a Bash with run_in_background: true' "$(reason <<<"$out")"

# Any live `worker-run wait` under the chat owns its runs, whatever id it names: its end wakes the chat
# and the next stop checks again. One under another process tree does not.
forget
mkdir -p "$WORK/bin"
# A stub's ready file is written once its own command line is in the process table.
mkdir -p "$WORK/ready"
printf '#!/bin/sh\n: >"%s/ready/${0##*/}-$2"\nwhile :; do sleep 1; done\n' "$WORK" >"$WORK/bin/worker-run"
cp "$WORK/bin/worker-run" "$WORK/bin/review-bench"
chmod +x "$WORK/bin/worker-run" "$WORK/bin/review-bench"
ready() { local name i; for name in "$@"; do
  for i in $(seq 1000); do [ -e "$WORK/ready/$name" ] && break; sleep 0.01; done
  [ -e "$WORK/ready/$name" ] || fail "line ${BASH_LINENO[0]}: $name never started"; done; }
wait_on() { rm -f "$WORK/ready/$1-$2"; "$WORK/bin/$1" wait "$2" & WAIT_PIDS="${WAIT_PIDS:-} $!"; ready "$1-$2"; }
# Children listed before any kill: a loop whose sleep dies first starts its next wait, an orphan that holds
# the suite's output open for good.
end_waits() { local p kids=''; for p in $WAIT_PIDS; do kids="$kids $(pgrep -P "$p")"; done
  kill $WAIT_PIDS $kids 2>/dev/null; wait $WAIT_PIDS 2>/dev/null; WAIT_PIDS=''; }
wait_on worker-run r1x
assert_eq "" "$(stop)"
assert_eq block "$(WORKER_RUN_BACKSTOP_CHAT_PID=$LIVE_PID stop | jq -r .decision)"
end_waits; forget
assert_eq block "$(stop | jq -r .decision)"
forget
assert_eq "" "$(bash "$HOOK" --relay "$WORKER_RUN_DIR/r1" </dev/null)"
assert_eq "" "$(printf 'run r1\n' | bash "$HOOK" --unowned)"
rm -rf "$WORKER_RUN_DIR/r1"; forget
# A background shell that waits on its runs in turn owns them before its own wait process exists, the
# ids written in it, read from a file, or the verb behind a variable while its first wait runs (the four
# holds of 2026-10-09); a shell naming the ids with no wait does not.
run r5 s1 codex; run r6 s1 codex
printf 'r5\nr6\n' >"$WORK/ids"
for loop in "for r in r5 r6; do sleep 30; $WORK/bin/worker-run wait \$r; done" \
  "for r in \$(cat $WORK/ids); do sleep 30; $WORK/bin/worker-run wait \$r; done" \
  "while read -r r; do sleep 30; $WORK/bin/worker-run wait \"\$r\"; done <$WORK/ids"; do
  rm -f "$WORK/ready/loop"
  bash -c ": >$WORK/ready/loop; $loop" & WAIT_PIDS="${WAIT_PIDS:-} $!"
  ready loop
  assert_eq "" "$(stop)"
  end_waits; forget
done
rm -f "$WORK/ready/worker-run-r5"
bash -c "W=$WORK/bin/worker-run; \$W wait r5; \$W wait r6" & WAIT_PIDS="${WAIT_PIDS:-} $!"
ready worker-run-r5
assert_eq "" "$(stop)"
end_waits; forget
bash -c ": >$WORK/ready/echo; sleep 30; echo r5 r6 worker-run" & WAIT_PIDS="${WAIT_PIDS:-} $!"
ready echo
assert_eq block "$(stop | jq -r .decision)"
end_waits; rm -rf "$WORKER_RUN_DIR/r5" "$WORKER_RUN_DIR/r6"; forget

# A run whose starter (a script waiting on its runs one at a time) still lives is owned by it; a starter
# that is gone, or whose pid now belongs to a younger process, is not.
. "$ROOT/share/run-liveness.sh"
live_began=$(($(date +%s) - $(etime_seconds "$(ps -p "$LIVE_PID" -o etime= | tr -d '[:space:]')")))
run r3 s1 codex
printf '%s %s\n' "$LIVE_PID" "$live_began" >"$WORKER_RUN_DIR/r3/starter"
assert_eq "" "$(stop)"
printf '%s %s\n' "$LIVE_PID" "$((live_began - 3600))" >"$WORKER_RUN_DIR/r3/starter"
assert_eq block "$(stop | jq -r .decision)"
forget
printf '999999 %s\n' "$live_began" >"$WORKER_RUN_DIR/r3/starter"
assert_eq block "$(stop | jq -r .decision)"
forget
# A ps that lists nothing, not even pid 1, cannot answer: the live starter still owns its run.
mkdir -p "$WORK/mute"
printf '#!/bin/sh\nexit 0\n' >"$WORK/mute/ps"
chmod +x "$WORK/mute/ps"
printf '%s %s\n' "$LIVE_PID" "$live_began" >"$WORKER_RUN_DIR/r3/starter"
assert_eq "" "$(PATH="$WORK/mute:$PATH" stop)"
rm -rf "$WORKER_RUN_DIR/r3"; forget
# A research run is picked up by light-research, which checks its citations and writes the answer file.
run r4 s1 gemini
jq -c '.light = "research"' "$WORKER_RUN_DIR/r4/meta.json" >"$WORK/m" && mv "$WORK/m" "$WORKER_RUN_DIR/r4/meta.json"
assert_has '`light-research --attach r4 --out <answer-file>`' "$(stop | reason)"
rm -rf "$WORKER_RUN_DIR/r4"; forget

# Not this chat's, finished, dead, or still inside `worker-run start` (no state.json yet): nothing to hold.
rm -rf "$WORKER_RUN_DIR"; forget
run other s2 codex
run done s1 codex; printf '0\n' >"$WORKER_RUN_DIR/done/exit_code"
run dead s1 codex 999999
run starting s1 codex; rm -f "$WORKER_RUN_DIR/starting/state.json"
run recycled s1 codex
jq -c --argjson t "$(($(date +%s) - 86400))" '.pid_started_at = $t' "$WORKER_RUN_DIR/recycled/meta.json" >"$WORK/m" &&
  mv "$WORK/m" "$WORKER_RUN_DIR/recycled/meta.json"
assert_eq "" "$(stop)"

# Inside a headless worker or a subagent the backstop is silent.
run r2 s1 claudeb
assert_eq "" "$(CLAUDEB_WORKER=1 stop)"
assert_eq "" "$(stop '+ {agent_id:"a1"}')"
assert_has '`worker-run wait r2`' "$(stop | reason)"
# Inside Egor's autonomy span the stop is never held.
forget
printf 'words_span_live() { [ "$1" = s1 ] && [ "$2" = /t/s1.jsonl ]; }\n' >"$WORK/span-words.sh"
assert_eq "" "$(WORDS_LIB="$WORK/span-words.sh" stop '+ {transcript_path:"/t/s1.jsonl"}')"
assert_eq block "$(WORDS_LIB="$WORK/span-words.sh" stop | jq -r .decision)"
rm -rf "$WORKER_RUN_DIR/r2"; forget

# A live review of this chat needs a live wait under the chat; a stale heartbeat is a dead panel.
R=20260924T010203Z-abc1234
jq -nc --arg r "$R" --argjson hb "$(date +%s)" '{run_id:$r,session:"s1",state:"running",heartbeat_epoch:$hb}' \
  >"$WORKER_STATS_DIR/progress/x.json"
assert_has "review $R — \`review-bench wait $R\`" "$(stop | reason)"
forget
wait_on review-bench "$R"
assert_eq "" "$(stop)"
end_waits; forget
jq '.heartbeat_epoch -= 3600' "$WORKER_STATS_DIR/progress/x.json" >"$WORK/x" && mv "$WORK/x" "$WORKER_STATS_DIR/progress/x.json"
assert_eq "" "$(stop)"
rm -f "$WORKER_STATS_DIR/progress/x.json"

# Three holds in a row, then the stop goes through; a hold minutes apart starts the count over.
run r3 s1 gemini
for _ in 1 2 3; do assert_eq block "$(stop | jq -r .decision)"; done
assert_eq "" "$(stop)"
printf '%s 9\n' "$(($(date +%s) - 900))" >"$HOME/.cache/claude/stop-backstop/s1"
assert_eq block "$(stop | jq -r .decision)"
rm -rf "$WORKER_RUN_DIR/r3"; forget

# An orchestrator's dozen live runs cost one process-table read per stop, and an owned run is settled
# before its liveness probe: a jq and a ps each per run were 2.2-2.7 s of the dispatcher's critical
# path at load 220.
mkdir -p "$WORK/shim"
printf '#!/bin/sh\necho "$*" >>"%s/ps-calls"\nexec %s "$@"\n' "$WORK" "$(command -v ps)" >"$WORK/shim/ps"
chmod +x "$WORK/shim/ps"
WORKER_RUN_DIR="$WORK/runs-owned"
for i in $(seq 4 15); do run "r$i" s1 codex; "$WORK/bin/worker-run" wait "r$i" & WAIT_PIDS="${WAIT_PIDS:-} $!"; done
for i in $(seq 4 15); do ready "worker-run-r$i"; done
assert_eq "" "$(PATH="$WORK/shim:$PATH" stop)"
assert_eq 1 "$(wc -l <"$WORK/ps-calls" | tr -d ' ')"
end_waits
# Finding the chat's `claude` ancestor costs one more table read, however deep the hook sits below it.
rm -f "$WORK/ps-calls"
ln -s "$(command -v bash)" "$WORK/bin/claude"
WORKER_RUN_DIR="$WORK/runs-chat"
run r16 s1 codex
assert_eq "" "$(unset WORKER_RUN_BACKSTOP_CHAT_PID; PATH="$WORK/shim:$PATH" HOOK="$HOOK" WORK="$WORK" "$WORK/bin/claude" -c '
  "$WORK/bin/worker-run" wait r16 & w=$!
  until [ -e "$WORK/ready/worker-run-r16" ]; do sleep 0.01; done
  bash -c "jq -cn \"{hook_event_name:\\\"Stop\\\",session_id:\\\"s1\\\"}\" | bash \"\$HOOK\""
  kill $w')"
assert_eq 2 "$(wc -l <"$WORK/ps-calls" | tr -d ' ')"

# A stop with nothing of this chat's to hold starts one jq and nothing else: another chat's review
# in the progress store, and a quiet chat's stop at all, cost the dispatcher's critical path.
mkdir -p "$WORK/count"
for tool in cat date awk rm jq; do
  printf '#!/bin/sh\necho %s >>"%s/forks"\nexec %s "$@"\n' "$tool" "$WORK" "$(command -v "$tool")" >"$WORK/count/$tool"
  chmod +x "$WORK/count/$tool"
done
jq -nc --argjson hb "$(date +%s)" '{run_id:"other-review",session:"s9",state:"running",heartbeat_epoch:$hb}' \
  >"$WORKER_STATS_DIR/progress/other.json"
assert_eq "" "$(jq -cn '{hook_event_name:"Stop",session_id:"s7"}' | PATH="$WORK/count:$PATH" bash "$HOOK")"
assert_eq jq "$(tr '\n' ' ' <"$WORK/forks" | sed 's/ $//')"
rm -f "$WORKER_STATS_DIR/progress/other.json"
printf 'PASS: %s asserts; a live worker or review run of this chat with no live `worker-run wait` / `review-bench wait` under the chat process holds the stop naming that wait, while another chat'"'"'s, a finished, a dead or a still-starting run, a stale panel, a worker, a subagent and the retired --relay and --unowned modes pass, a dozen owned runs cost one process-table read, and three holds in a row release the fourth\n' "$asserts"
