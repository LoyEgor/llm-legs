#!/usr/bin/env bash
# Stop backstop, called by claude-setup's stop-dispatch.sh ahead of every stop.d hook and never
# deferred: a worker-run or review-bench run this chat launched, still alive, that no live relay of
# this chat owns, is a run Egor cannot see. The launch gate reads spellings; this reads the runs
# themselves, so no spelling dodges it. The chat's turn is held until it spawns the owning relay
# with `ATTACH <run-id>:`.
#
# Owned = a file in this chat's tag cache names the run (`run=` / `review=`) and carries no
# `stopped=` mark (worker-relay-hold.sh writes it when it lets a relay go), or is a spawn seed
# younger than the tag hook's seed age. A run whose state.json is not written yet is still inside
# `worker-run start`, before the claim that names its relay. Fail-open everywhere.
set -u

payload=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "${CLAUDEB_WORKER:-}" = 1 ] && exit 0
self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) && . "${self%/*}/../share/run-liveness.sh" 2>/dev/null || exit 0
{ IFS= read -r session; IFS= read -r agent; } <<EOF
$(jq -r '(.session_id // ""), (.agent_id // "")' <<<"$payload" 2>/dev/null)
EOF
[ -z "$agent" ] || exit 0
case "$session" in ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac

tags="$HOME/.cache/claude-worker-tags/$session"
seed_age=${WORKER_TAG_SEED_MAX_AGE_S:-600}
now=$(date +%s)
owned() { # key id
  local file mtime
  for file in "$tags"/*; do
    [ -f "$file" ] || continue
    case "${file##*/}" in *.holds | *.tmp.* | git-unlock-*) continue ;; esac
    grep -qxF "$1=$2" "$file" 2>/dev/null || continue
    case "${file##*/}" in
      pending-*)
        mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null) || continue
        [ $((now - mtime)) -le "$seed_age" ] && return 0 ;;
      *) grep -q '^stopped=' "$file" 2>/dev/null || return 0 ;;
    esac
  done
  return 1
}

relay_of() { # run-dir
  case "$(jq -r '[.vendor // "", .role // "", .light // ""] | join(":")' "$1/meta.json" 2>/dev/null)" in
    *:research:*) printf 'light-research' ;;
    *:*:edit) printf 'light-worker' ;;
    claudeb:* | codex:* | gemini:* | grok:*) printf '%s-worker' "$(jq -r .vendor "$1/meta.json")" ;;
    *) printf 'its relay worker' ;;
  esac
}

lines=''
run_root=${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}
for run in "$run_root"/*/; do
  run=${run%/}
  [ -f "$run/state.json" ] && [ ! -e "$run/exit_code" ] || continue
  [ "$(tr -d '[:space:]' <"$run/launcher" 2>/dev/null)" = "$session" ] || continue
  pid=$(jq -r '.pid // 0' "$run/meta.json" 2>/dev/null)
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && supervisor_running "$run" "$pid" || continue
  id=${run##*/}
  case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
  owned run "$id" && continue
  tag=$(head -n1 "$run/tag" 2>/dev/null)
  lines=$lines${lines:+$'\n'}"- worker run $id${tag:+ ($tag)} — spawn $(relay_of "$run") \`ATTACH $id:\`"
done

progress="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/progress"
while IFS= read -r id; do
  case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  owned review "$id" && continue
  lines=$lines${lines:+$'\n'}"- review $id — spawn review-waiter \`ATTACH $id:\`"
done < <(cat "$progress"/*.json 2>/dev/null | jq -r --arg s "$session" --argjson now "$now" \
  'select((.session // "") == $s and .state == "running" and (.heartbeat_epoch | type) == "number" and ($now - .heartbeat_epoch) < 600)
   | .run_id // empty' 2>/dev/null | awk '!seen[$0]++')

hold="$HOME/.cache/claude/stop-backstop/$session"
if [ -z "$lines" ]; then
  rm -f "$hold" 2>/dev/null
  exit 0
fi
# A chat held three times in a row within a few minutes is not going to spawn the relay: the fourth
# stop goes through rather than loop on its account.
mkdir -p "${hold%/*}" 2>/dev/null
{ read -r last count <"$hold"; } 2>/dev/null || { last=0; count=0; }
[[ "$last" =~ ^[0-9]+$ ]] || last=0
[[ "$count" =~ ^[0-9]+$ ]] || count=0
if [ $((now - last)) -lt 300 ]; then count=$((count + 1)); else count=1; fi
printf '%s %s\n' "$now" "$count" >"$hold" 2>/dev/null || exit 0
[ "$count" -le 3 ] || exit 0
jq -nc --arg r "Running with no task row, so Egor cannot see which account and model they spend:
$lines
Spawn each relay now (its brief is just that ATTACH line); it waits the run out on a visible row." \
  '{decision:"block",reason:$r}'
exit 0
