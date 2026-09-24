#!/usr/bin/env bash
# SubagentStop: a relay agent's task row IS Egor's view of a worker — which account, which model —
# and it vanishes when the relay stops. A relay that returned on a checkpoint while its run kept
# going left two fixers invisible for an hour (2026-09-24), so a relay whose worker run is still
# alive is sent back to wait. Fail-open everywhere.
set -u

input=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

case "$(field '.agent_type')" in
  claudeb-worker | codex-worker | gemini-worker | grok-worker | light-worker) ;;
  *) exit 0 ;;
esac
agent_id=$(field '.agent_id' | tr -cd 'A-Za-z0-9_-')
session_id=$(field '.session_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$agent_id" ] && [ -n "$session_id" ] || exit 0

tag_file="$HOME/.cache/claude-worker-tags/$session_id/$agent_id"
run_id=$({ tr ' ' '\n' <"$tag_file"; } 2>/dev/null | sed -n 's/^run=//p' | tail -n1 | tr -cd 'A-Za-z0-9_-')
[ -n "$run_id" ] || exit 0
directory="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}/$run_id"
[ -r "$directory/meta.json" ] && [ ! -e "$directory/exit_code" ] || exit 0
pid=$(jq -r '.pid // 0' "$directory/meta.json" 2>/dev/null)
[[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null || exit 0

# A relay that stops again within a minute of being held never waited: five of those in a row is
# a loop burning its account, and the stop goes through.
holds="$tag_file.holds"
now=$(date +%s)
{ read -r last count <"$holds"; } 2>/dev/null || { last=0; count=0; }
[[ "$last" =~ ^[0-9]+$ ]] || last=0
[[ "$count" =~ ^[0-9]+$ ]] || count=0
if [ $((now - last)) -lt 60 ]; then count=$((count + 1)); else count=1; fi
printf '%s %s\n' "$now" "$count" >"$holds" 2>/dev/null || exit 0
[ "$count" -le 5 ] || exit 0

jq -cn --arg run "$run_id" '{decision: "block",
  reason: ("Run \($run) is still running, and your task row is the only place Egor sees this worker. Do not return: run `worker-run wait \($run) --max 540` (Bash timeout 600000) again, repeated until it prints STATUS: done or failed, then report.")}'
exit 0
