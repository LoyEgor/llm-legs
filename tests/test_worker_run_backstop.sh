#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-run-backstop.sh"
WORK=$(mktemp -d)
sleep 300 &
LIVE_PID=$!
trap 'kill "$LIVE_PID" ${WAIT_PIDS:-} 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs" WORKER_STATS_DIR="$WORK/stats"
unset CLAUDEB_WORKER
export WORKER_RUN_BACKSTOP_CHAT_PID=$$
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }
assert_has() { asserts=$((asserts + 1)); case "$2" in *"$1"*) ;; *) fail "[$2] lacks [$1]" ;; esac; }

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

# A live `worker-run wait r1` under the chat owns it; one under another process tree, or one waiting on
# another run, does not.
forget
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$WORK/bin/worker-run"
cp "$WORK/bin/worker-run" "$WORK/bin/review-bench"
chmod +x "$WORK/bin/worker-run" "$WORK/bin/review-bench"
wait_on() { "$WORK/bin/$1" wait "$2" & WAIT_PIDS="${WAIT_PIDS:-} $!"; sleep 0.2; }
end_waits() { kill $WAIT_PIDS 2>/dev/null; wait $WAIT_PIDS 2>/dev/null; WAIT_PIDS=''; }
wait_on worker-run r1x
assert_eq block "$(stop | jq -r .decision)"
wait_on worker-run r1
assert_eq "" "$(stop)"
assert_eq block "$(WORKER_RUN_BACKSTOP_CHAT_PID=$LIVE_PID stop | jq -r .decision)"
end_waits; forget
assert_eq block "$(stop | jq -r .decision)"
forget
assert_eq "" "$(bash "$HOOK" --relay "$WORKER_RUN_DIR/r1" </dev/null)"
# The Stop ask's question: the same ownership and resume command, for the candidates it names.
unowned() { printf '%s\n' "$@" | bash "$HOOK" --unowned; }
assert_eq $'run r1 worker-run wait r1\nreview v1 review-bench wait v1' "$(unowned 'run r1' 'review v1' 'bogus r1' 'run a/b')"
wait_on worker-run r1
wait_on review-bench v1
assert_eq "" "$(unowned 'run r1' 'review v1')"
assert_eq "run r1 worker-run wait r1" "$(WORKER_RUN_BACKSTOP_CHAT_PID=$LIVE_PID unowned 'run r1')"
end_waits
rm -rf "$WORKER_RUN_DIR/r1"; forget
# A background shell that waits on its runs in turn, or after a sleep, owns every id it names before its
# own wait process exists (2026-10-09, two chats held for waits they had started); a shell naming the id
# with no wait, or a wait naming only a longer id, does not.
run r5 s1 codex; run r6 s1 codex
bash -c "for r in r5 r6; do sleep 30; $WORK/bin/worker-run wait \$r; done" & WAIT_PIDS="${WAIT_PIDS:-} $!"
sleep 0.2
assert_eq "" "$(stop)"
end_waits; forget
bash -c "sleep 30; echo r5 r6" & WAIT_PIDS="${WAIT_PIDS:-} $!"
bash -c "R=r5x; sleep 30; $WORK/bin/worker-run wait \$R r6x" & WAIT_PIDS="${WAIT_PIDS:-} $!"
sleep 0.2
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
assert_eq "" "$(unowned 'run r3')"
rm -rf "$WORKER_RUN_DIR/r3"; forget
# A research run is picked up by light-research, which checks its citations and writes the answer file.
run r4 s1 gemini
jq -c '.light = "research"' "$WORKER_RUN_DIR/r4/meta.json" >"$WORK/m" && mv "$WORK/m" "$WORKER_RUN_DIR/r4/meta.json"
assert_has '`light-research --attach r4 --out <answer-file>`' "$(stop | reason)"
assert_eq "run r4 light-research --attach r4 --out <answer-file>" "$(unowned 'run r4')"
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

# A live review of this chat needs a live `review-bench wait` under the chat; a stale heartbeat is a dead panel.
R=20260924T010203Z-abc1234
jq -nc --arg r "$R" --argjson hb "$(date +%s)" '{run_id:$r,session:"s1",state:"running",heartbeat_epoch:$hb}' \
  >"$WORKER_STATS_DIR/progress/x.json"
assert_has "review $R — \`review-bench wait $R\`" "$(stop | reason)"
forget
wait_on worker-run "$R"
assert_eq block "$(stop | jq -r .decision)"
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
for i in $(seq 4 15); do run "r$i" s1 codex; wait_on worker-run "r$i"; done
assert_eq "" "$(PATH="$WORK/shim:$PATH" stop)"
assert_eq 1 "$(wc -l <"$WORK/ps-calls" | tr -d ' ')"
end_waits

printf 'PASS: %s asserts; a live worker or review run of this chat that no live `worker-run wait` / `review-bench wait` under the chat process owns holds the stop naming that wait, while another chat'"'"'s, a finished, a dead or a still-starting run, a stale panel, a worker, a subagent and the retired --relay mode pass, --unowned answers the Stop ask with the same verdict and resume command, a dozen owned runs cost one process-table read, and three holds in a row release the fourth\n' "$asserts"
