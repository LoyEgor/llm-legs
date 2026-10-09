#!/usr/bin/env bash
# Stop backstop, called by claude-setup's stop-dispatch.sh ahead of every stop.d hook and never
# deferred: a worker-run or review-bench run this chat launched, still alive, that no live wait of
# this chat holds, ends with nothing to wake the chat and nothing in /tasks. The launch gate reads
# spellings; this reads the runs themselves, so no spelling dodges it. The chat's turn is held until
# it starts the wait as a background Bash.
#
# Owned = a live `worker-run wait <run-id>` (`review-bench wait <run-id>` for a review) in this chat's
# process tree, below the nearest `claude` ancestor of this hook, or the process that started the
# run still alive (a script waiting on its runs one at a time). A run whose state.json is not written yet is still inside
# `worker-run start`. Fail-open everywhere.
{
set -u
self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) || exit 0
[ "$#" -eq 0 ] || [ "$*" = --unowned ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
[ "${CLAUDEB_WORKER:-}" = 1 ] && exit 0
. "${self%/*}/../share/run-liveness.sh" 2>/dev/null || exit 0
. "${self%/*}/../share/processes.sh" 2>/dev/null || exit 0

chat_pid() {
  local pid=$PPID comm guard=0
  [ -z "${WORKER_RUN_BACKSTOP_CHAT_PID:-}" ] || { printf '%s' "$WORKER_RUN_BACKSTOP_CHAT_PID"; return 0; }
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$guard" -lt 40 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    [ "${comm##*/}" != claude ] || { printf '%s' "$pid"; return 0; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    guard=$((guard + 1))
  done
  return 1
}
now=$(date +%s)
# One process table read per stop, and only once a run needs it: "<run|review>=<id>" of every wait
# below the chat.
waits=''
waits_read=false
owned() { # key id
  if [ "$waits_read" = false ]; then
    waits_read=true
    local root listing
    root=$(chat_pid) || exit 0
    listing=$(ps -Ao pid=,ppid=,command= 2>/dev/null)
    waits=$(process_listing() { printf '%s\n' "$listing"; }
      process_tree "$root" | awk -v root="$root" '
      FNR == NR { if ($1 != root) below[$1] = 1; next }
      ($1 in below) {
        $1 = ""; $2 = ""
        if (!match($0, /(^|[ \/])(worker-run|review-bench)[ ]+wait[ ]+[A-Za-z0-9._-]+/)) next
        split(substr($0, RSTART, RLENGTH), w, " ")
        sub(/.*\//, "", w[1])
        print (w[1] == "review-bench" ? "review" : "run") "=" w[3]
      }' - <(printf '%s\n' "$listing"))
  fi
  case $'\n'"$waits"$'\n' in *$'\n'"$1=$2"$'\n'*) return 0 ;; esac
  return 1
}
run_root=${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}
held() { # run|review id
  owned "$1" "$2" || { [ "$1" = run ] && starter_alive "$run_root/$2"; }
}
resume_of() { # run|review id
  if [ "$1" = review ]; then
    printf 'review-bench wait %s' "$2"
  elif [ "$(jq -r '.light // ""' "$run_root/$2/meta.json" 2>/dev/null)" = research ]; then
    printf 'light-research --attach %s --out <answer-file>' "$2"
  else
    printf 'worker-run wait %s' "$2"
  fi
}

# claude-setup's stop.d/ask-run-unfinished.sh asks the same question of its own candidates: stdin
# `<run|review> <id>` lines, out `<kind> <id> <resume command>` for each nothing holds. A chat that
# cannot be found prints nothing, so the ask stays quiet exactly where the hold does.
if [ "$#" -eq 1 ]; then
  while read -r kind id; do
    case "$kind" in run|review) ;; *) continue ;; esac
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    held "$kind" "$id" || printf '%s %s %s\n' "$kind" "$id" "$(resume_of "$kind" "$id")"
  done
  exit 0
fi

payload=$(cat 2>/dev/null) || exit 0
{ IFS= read -r session; IFS= read -r agent; IFS= read -r transcript; } <<EOF
$(jq -r '(.session_id // ""), (.agent_id // ""), (.transcript_path // "")' <<<"$payload" 2>/dev/null)
EOF
[ -z "$agent" ] || exit 0
case "$session" in ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac

lines=''
for run in "$run_root"/*/; do
  run=${run%/}
  [ ! -e "$run/exit_code" ] && [ -f "$run/state.json" ] || continue
  launcher=""
  { read -r launcher <"$run/launcher"; } 2>/dev/null
  [ "$launcher" = "$session" ] || continue
  id=${run##*/}
  case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
  held run "$id" && continue
  pid=$(jq -r '.pid // 0' "$run/meta.json" 2>/dev/null)
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && supervisor_running "$run" "$pid" || continue
  tag=$(head -n1 "$run/tag" 2>/dev/null)
  lines=$lines${lines:+$'\n'}"- worker run $id${tag:+ ($tag)} — \`$(resume_of run "$id")\`"
done

progress="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/progress"
while IFS= read -r id; do
  case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  held review "$id" && continue
  lines=$lines${lines:+$'\n'}"- review $id — \`$(resume_of review "$id")\`"
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
# A chat held three times in a row within a few minutes is not going to start the wait: the fourth
# stop goes through rather than loop on its account.
mkdir -p "${hold%/*}" 2>/dev/null
{ read -r last count <"$hold"; } 2>/dev/null || { last=0; count=0; }
[[ "$last" =~ ^[0-9]+$ ]] || last=0
[[ "$count" =~ ^[0-9]+$ ]] || count=0
if [ $((now - last)) -lt 300 ]; then count=$((count + 1)); else count=1; fi
printf '%s %s\n' "$now" "$count" >"$hold" 2>/dev/null || exit 0
[ "$count" -le 3 ] || exit 0
jq -nc --arg hook "${0##*/}" --arg r "Running with no live wait, so nothing wakes this chat when they end and /tasks shows nothing:
$lines
Start each wait now as a Bash with run_in_background: true; it blocks until the run ends." \
  '{decision:"block",reason:("[" + $hook + "] " + $r)}'
exit 0
exit; }
