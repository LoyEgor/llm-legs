#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-run-backstop.sh"
WORK=$(mktemp -d)
sleep 300 &
LIVE_PID=$!
trap 'kill "$LIVE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs" WORKER_STATS_DIR="$WORK/stats"
unset CLAUDEB_WORKER
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }
assert_has() { asserts=$((asserts + 1)); case "$2" in *"$1"*) ;; *) fail "[$2] lacks [$1]" ;; esac; }

TAGS="$HOME/.cache/claude-worker-tags/s1"
mkdir -p "$TAGS" "$WORKER_STATS_DIR/progress"
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

# A live run of this chat with no relay holds the stop and names the ATTACH spawn and the run's tag.
run r1 s1 codex
out=$(stop)
assert_eq block "$(jq -r .decision <<<"$out")"
assert_has 'worker run r1 (acct · astra · high) — spawn codex-worker `ATTACH r1:`' "$(reason <<<"$out")"

# A relay tag naming the run owns it; one marked stopped does not; a fresh ATTACH seed does, a stale one not.
forget
printf 'acct · astra · high\nrun=r1\n' >"$TAGS/agent1"
assert_eq "" "$(stop)"
printf 'stopped=1\n' >>"$TAGS/agent1"
assert_eq block "$(stop | jq -r .decision)"
forget
printf 'acct · astra · high\nspawn=x\nrun=r1\n' >"$TAGS/pending-codex-worker-t1"
assert_eq "" "$(stop)"
touch -t "$(date -v-20M +%Y%m%d%H%M.%S)" "$TAGS/pending-codex-worker-t1"
assert_eq block "$(stop | jq -r .decision)"
rm -f "$TAGS/pending-codex-worker-t1" "$TAGS/agent1"

# Not this chat's, finished, dead, or still inside `worker-run start` (no state.json yet): nothing to hold.
rm -rf "$WORKER_RUN_DIR"; forget
run other s2 codex
run done s1 codex; printf '0\n' >"$WORKER_RUN_DIR/done/exit_code"
run dead s1 codex 999999
run starting s1 codex; rm -f "$WORKER_RUN_DIR/starting/state.json"
assert_eq "" "$(stop)"

# Inside a headless worker or a subagent the backstop is silent.
run r2 s1 claudeb
assert_eq "" "$(CLAUDEB_WORKER=1 stop)"
assert_eq "" "$(stop '+ {agent_id:"a1"}')"
assert_has 'spawn claudeb-worker `ATTACH r2:`' "$(stop | reason)"
rm -rf "$WORKER_RUN_DIR/r2"; forget

# A live review of this chat needs a live review-waiter tag; a stale heartbeat is a dead panel.
R=20260924T010203Z-abc1234
jq -nc --arg r "$R" --argjson hb "$(date +%s)" '{run_id:$r,session:"s1",state:"running",heartbeat_epoch:$hb}' \
  >"$WORKER_STATS_DIR/progress/x.json"
assert_has "review $R — spawn review-waiter \`ATTACH $R:\`" "$(stop | reason)"
forget
printf 'T2 · double · bugs\nreview=%s\n' "$R" >"$TAGS/waiter1"
assert_eq "" "$(stop)"
rm -f "$TAGS/waiter1"
jq '.heartbeat_epoch -= 3600' "$WORKER_STATS_DIR/progress/x.json" >"$WORK/x" && mv "$WORK/x" "$WORKER_STATS_DIR/progress/x.json"
assert_eq "" "$(stop)"
rm -f "$WORKER_STATS_DIR/progress/x.json"

# Three holds in a row, then the stop goes through; a hold minutes apart starts the count over.
run r3 s1 gemini
for _ in 1 2 3; do assert_eq block "$(stop | jq -r .decision)"; done
assert_eq "" "$(stop)"
printf '%s 9\n' "$(($(date +%s) - 900))" >"$HOME/.cache/claude/stop-backstop/s1"
assert_eq block "$(stop | jq -r .decision)"

printf 'PASS: %s asserts; a live worker or review run of this chat that no live relay tag or fresh ATTACH seed owns holds the stop naming the ATTACH spawn, while another chat'"'"'s, a finished, a dead or a still-starting run, a stale panel, a worker and a subagent pass, and three holds in a row release the fourth\n' "$asserts"
