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
{
set -u
self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) || exit 0

light_off() {
  [ -n "${light_off_known:-}" ] || {
    light_off_known=no
    (. "${self%/*}/../share/worker-model.sh" 2>/dev/null && worker_light_off) && light_off_known=yes
  }
  [ "$light_off_known" = yes ]
}

# The one relay choice for a worker run; claude-setup's stop.d/ask-run-unfinished.sh asks it through
# `--relay <run-dir>`. Light off, the harness denies both Light agent types, so a Light run in flight
# is waited out by its vendor's plain relay; a research run launched while Light was off is plain.
relay_of() { # run-dir
  local vendor light
  { IFS= read -r vendor; IFS= read -r light; } <<EOF
$(jq -r '(.vendor // ""), (.light // "")' "$1/meta.json" 2>/dev/null)
EOF
  [ -n "$light" ] && light_off && light=''
  case "$vendor:$light" in
    *:research) printf 'light-research' ;;
    *:edit) printf 'light-worker' ;;
    claudeb:* | codex:* | gemini:* | grok:*) printf '%s-worker' "$vendor" ;;
    *) printf 'its relay worker' ;;
  esac
}
[ "${1:-}" = --relay ] && { relay_of "${2:-}"; exit 0; }

payload=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "${CLAUDEB_WORKER:-}" = 1 ] && exit 0
. "${self%/*}/../share/run-liveness.sh" 2>/dev/null || exit 0
{ IFS= read -r session; IFS= read -r agent; IFS= read -r transcript; } <<EOF
$(jq -r '(.session_id // ""), (.agent_id // ""), (.transcript_path // "")' <<<"$payload" 2>/dev/null)
EOF
[ -z "$agent" ] || exit 0
case "$session" in ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac

tags="$HOME/.cache/claude-worker-tags/$session"
seed_age=${WORKER_TAG_SEED_MAX_AGE_S:-600}
now=$(date +%s)
# One read of the whole cache per stop: a read per lookup, over an orchestrator's 400 tag files for
# each of its dozen live runs, still outran the 5 s hook cap at swap-full load. grep reads the files:
# awk dies on one deleted after the glob (a pending seed going) and every live run then reads unowned.
tag_keys=$(grep -HE '^(run|review|stopped)=' "$tags"/* 2>/dev/null | awk -v skip=$((${#tags} + 1)) '
  {
    rest = substr($0, skip + 1); colon = index(rest, ":")
    name = substr(rest, 1, colon - 1); line = substr(rest, colon + 1); file = substr($0, 1, skip + colon - 1)
  }
  name ~ /\.holds$|\.tmp\.|^git-unlock-/ { next }
  line ~ /^stopped=/ { stopped[file] = 1; next }
  { keys[file] = keys[file] line "\n"; base[file] = name }
  END {
    for (f in keys) {
      n = split(keys[f], k, "\n")
      for (i = 1; i < n; i++)
        if (base[f] ~ /^pending-/) print "pending\t" k[i] "\t" f
        else if (!(f in stopped)) print "live\t" k[i]
    }
  }')
owned() { # key id
  local kind key file mtime
  case $'\n'"$tag_keys"$'\n' in *$'\n'"live	$1=$2"$'\n'*) return 0 ;; esac
  while IFS=$'\t' read -r kind key file; do
    [ "$kind" = pending ] && [ "$key" = "$1=$2" ] || continue
    mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null) || continue
    [ $((now - mtime)) -le "$seed_age" ] && return 0
  done <<<"$tag_keys"
  return 1
}

lines=''
run_root=${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}
for run in "$run_root"/*/; do
  run=${run%/}
  [ ! -e "$run/exit_code" ] && [ -f "$run/state.json" ] || continue
  launcher=""
  { read -r launcher <"$run/launcher"; } 2>/dev/null
  [ "$launcher" = "$session" ] || continue
  id=${run##*/}
  case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
  owned run "$id" && continue
  pid=$(jq -r '.pid // 0' "$run/meta.json" 2>/dev/null)
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && supervisor_running "$run" "$pid" || continue
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
( . "${WORDS_LIB:-$HOME/.claude/hooks/lib/words.sh}" && command -v words_span_live &&
  words_span_live "$session" "$transcript" ) >/dev/null 2>&1 && exit 0
# A chat held three times in a row within a few minutes is not going to spawn the relay: the fourth
# stop goes through rather than loop on its account.
mkdir -p "${hold%/*}" 2>/dev/null
{ read -r last count <"$hold"; } 2>/dev/null || { last=0; count=0; }
[[ "$last" =~ ^[0-9]+$ ]] || last=0
[[ "$count" =~ ^[0-9]+$ ]] || count=0
if [ $((now - last)) -lt 300 ]; then count=$((count + 1)); else count=1; fi
printf '%s %s\n' "$now" "$count" >"$hold" 2>/dev/null || exit 0
[ "$count" -le 3 ] || exit 0
jq -nc --arg hook "${0##*/}" --arg r "Running with no task row, so Egor cannot see which account and model they spend:
$lines
Spawn each relay now (its brief is just that ATTACH line); it waits the run out on a visible row." \
  '{decision:"block",reason:("[" + $hook + "] " + $r)}'
exit 0
exit; }
