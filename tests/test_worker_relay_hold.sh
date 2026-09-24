#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/worker-relay-hold.sh"
WORK=$(mktemp -d)
sleep 300 &
LIVE_PID=$!
trap 'kill "$LIVE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }

TAGS="$HOME/.cache/claude-worker-tags/s1"
mkdir -p "$TAGS" "$WORKER_RUN_DIR/run-live" "$WORKER_RUN_DIR/run-done" "$WORKER_RUN_DIR/run-dead"
printf '{"pid":%s}\n' "$LIVE_PID" >"$WORKER_RUN_DIR/run-live/meta.json"
printf '{"pid":%s}\n' "$LIVE_PID" >"$WORKER_RUN_DIR/run-done/meta.json"
printf '0\n' >"$WORKER_RUN_DIR/run-done/exit_code"
printf '{"pid":999999}\n' >"$WORKER_RUN_DIR/run-dead/meta.json"
printf 'locomthebest · opus · high run=run-live\n' >"$TAGS/a-live"
printf 'locomthebest · opus · high run=run-done\n' >"$TAGS/a-done"
printf 'locomthebest · opus · high run=run-dead\n' >"$TAGS/a-dead"
printf 'locomthebest · opus · high\n' >"$TAGS/a-norun"

stop() { # agent-type agent-id
  jq -cn --arg t "$1" --arg a "$2" \
    '{hook_event_name:"SubagentStop",session_id:"s1",agent_type:$t,agent_id:$a,stop_hook_active:true}' |
    bash "$HOOK"
}
decision() { jq -r '.decision // empty' 2>/dev/null; }

# A relay whose run is alive is sent back to wait, naming the run.
out=$(stop claudeb-worker a-live)
assert_eq block "$(printf '%s' "$out" | decision)"
assert_eq true "$(printf '%s' "$out" | jq -r '.reason | contains("worker-run wait run-live")')"
for relay in codex-worker gemini-worker grok-worker light-worker; do
  rm -f "$TAGS/a-live.holds"
  assert_eq block "$(stop "$relay" a-live | decision)"
done

# A finished run, a dead supervisor, a tag without a run and a non-relay agent stop freely.
assert_eq "" "$(stop claudeb-worker a-done)"
assert_eq "" "$(stop claudeb-worker a-dead)"
assert_eq "" "$(stop claudeb-worker a-norun)"
assert_eq "" "$(stop claudeb-worker a-missing)"
assert_eq "" "$(stop general-purpose a-live)"
assert_eq "" "$(stop review-waiter a-live)"

# Five holds in a row within a minute each are a relay that never waits: the sixth stop goes through.
rm -f "$TAGS/a-live.holds"
for _ in 1 2 3 4 5; do assert_eq block "$(stop claudeb-worker a-live | decision)"; done
assert_eq "" "$(stop claudeb-worker a-live)"
# A hold a real wait apart starts the count over.
printf '%s 9\n' "$(($(date +%s) - 600))" >"$TAGS/a-live.holds"
assert_eq block "$(stop claudeb-worker a-live | decision)"

# A relay let go is marked stopped for the Stop backstop; a held one is not.
assert_eq 1 "$(grep -c '^stopped=' "$TAGS/a-done")"
rm -f "$TAGS/a-live.holds"
stop claudeb-worker a-live >/dev/null
assert_eq 0 "$(grep -c '^stopped=' "$TAGS/a-live")"

# Any live run the tag names holds it, not only the last one written.
printf 'locomthebest · opus · high\nrun=run-live\nrun=run-done\n' >"$TAGS/a-many"
assert_eq block "$(stop light-worker a-many | decision)"

# light-research holds on its run with its own attach call; review-waiter on a running panel.
printf 'light research · flash · acct\nrun=run-live\n' >"$TAGS/a-research"
out=$(stop light-research a-research)
assert_eq true "$(printf '%s' "$out" | jq -r '.reason | contains("light-research --attach run-live")')"
export WORKER_STATS_DIR="$WORK/stats"
mkdir -p "$WORKER_STATS_DIR/progress"
jq -nc --argjson hb "$(date +%s)" '{run_id:"20260924T010203Z-abc1234",state:"running",heartbeat_epoch:$hb}' \
  >"$WORKER_STATS_DIR/progress/p.json"
printf 'T2 · double · bugs\nreview=20260924T010203Z-abc1234\n' >"$TAGS/a-waiter"
out=$(stop review-waiter a-waiter)
assert_eq true "$(printf '%s' "$out" | jq -r '.reason | contains("review-bench wait 20260924T010203Z-abc1234 --max 540")')"
jq '.state = "done"' "$WORKER_STATS_DIR/progress/p.json" >"$WORK/p" && mv "$WORK/p" "$WORKER_STATS_DIR/progress/p.json"
assert_eq "" "$(stop review-waiter a-waiter)"
assert_eq 1 "$(grep -c '^stopped=' "$TAGS/a-waiter")"

printf 'PASS: %s asserts; a relay agent whose worker run (any the tag names), light-research run or running review panel is still alive is held so its row stays, a relay let go is marked stopped, every other stop goes through, and a relay that never waits is released after five holds\n' "$asserts"
