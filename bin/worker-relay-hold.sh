#!/usr/bin/env bash
# SubagentStop: a relay agent's task row IS Egor's view of a worker — which account, which model —
# and it vanishes when the relay stops. A relay that returned on a checkpoint while its run kept
# going left two fixers invisible for an hour (2026-09-24), so a relay whose run is still alive is
# sent back to wait. A relay let go is marked `stopped=` in its tag file: bin/worker-run-backstop.sh
# reads that mark as "no relay owns this run any more". Fail-open everywhere.
set -u

input=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

agent_type=$(field '.agent_type')
case "$agent_type" in
  claudeb-worker | codex-worker | gemini-worker | grok-worker | light-worker | light-research) key=run ;;
  review-waiter) key=review ;;
  *) exit 0 ;;
esac
agent_id=$(field '.agent_id' | tr -cd 'A-Za-z0-9_-')
session_id=$(field '.session_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$agent_id" ] && [ -n "$session_id" ] || exit 0

tag_file="$HOME/.cache/claude-worker-tags/$session_id/$agent_id"
[ -f "$tag_file" ] || exit 0
release() {
  grep -q '^stopped=' "$tag_file" 2>/dev/null || printf 'stopped=%s\n' "$(date +%s)" >>"$tag_file" 2>/dev/null
  exit 0
}

run_live() { # run-id
  local directory="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}/$1" pid
  [ -r "$directory/meta.json" ] && [ ! -e "$directory/exit_code" ] || return 1
  pid=$(jq -r '.pid // 0' "$directory/meta.json" 2>/dev/null)
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null
}
# A panel whose heartbeat stopped is dead whatever its document still says.
review_live() { # run-id
  local progress="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/progress"
  cat "$progress"/*.json 2>/dev/null | jq -e -s --arg run "$1" --argjson now "$(date +%s)" \
    'any(.[]; .run_id? == $run and .state? == "running" and ($now - (.heartbeat_epoch // $now)) < 600)' \
    >/dev/null 2>&1
}

live=''
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if [ "$key" = review ]; then review_live "$id" && live=$id; else run_live "$id" && live=$id; fi
  [ -z "$live" ] || break
done < <(tr ' ' '\n' <"$tag_file" 2>/dev/null | sed -n "s/^$key=//p" | tr -cd 'A-Za-z0-9_\n-' | awk '!seen[$0]++' | tail -r 2>/dev/null)
[ -n "$live" ] || release

# A relay that stops again within a minute of being held never waited: five of those in a row is
# a loop burning its account, and the stop goes through.
holds="$tag_file.holds"
now=$(date +%s)
{ read -r last count <"$holds"; } 2>/dev/null || { last=0; count=0; }
[[ "$last" =~ ^[0-9]+$ ]] || last=0
[[ "$count" =~ ^[0-9]+$ ]] || count=0
if [ $((now - last)) -lt 60 ]; then count=$((count + 1)); else count=1; fi
printf '%s %s\n' "$now" "$count" >"$holds" 2>/dev/null || exit 0
[ "$count" -le 5 ] || release
if grep -q '^stopped=' "$tag_file" 2>/dev/null; then
  grep -v '^stopped=' "$tag_file" >"$tag_file.tmp.$$" 2>/dev/null && mv -f "$tag_file.tmp.$$" "$tag_file"
fi

case "$agent_type" in
  review-waiter) wait_call="review-bench wait $live --max 540" ;;
  light-research) wait_call="light-research --attach $live --out <the same OUT>" ;;
  *) wait_call="worker-run wait $live --max 540" ;;
esac
jq -cn --arg run "$live" --arg call "$wait_call" '{decision: "block",
  reason: ("Run \($run) is still running, and your task row is the only place Egor sees this worker. Do not return: run `\($call)` (Bash timeout 600000) again, repeated until the run is over, then report.")}'
exit 0
