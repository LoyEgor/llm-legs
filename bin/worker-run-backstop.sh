#!/usr/bin/env bash
# Stop backstop, called by claude-setup's stop-dispatch.sh ahead of every stop.d hook and never
# deferred: a worker-run or review-bench run this chat launched, still alive, that no live wait of
# this chat holds, ends with nothing to wake the chat and nothing in /tasks. The launch gate reads
# spellings; this reads the runs themselves, so no spelling dodges it. The chat's turn is held until
# it starts the wait as a background Bash.
#
# Owned = any live process in this chat's process tree, below the nearest `claude` ancestor of this
# hook, whose command line runs `worker-run wait` or `review-bench wait`, whatever ids it names: its
# end wakes the chat, and this stop checks again then. Matching ids held chats whose loops read them
# from a file or spelled the verb `$RB wait` (four times 2026-10-09). Or the process that started the
# run still alive (a script waiting on its runs one at a time). A run whose state.json is not written
# yet is still inside `worker-run start`. Fail-open everywhere.
{
set -u
self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) || exit 0
[ "$#" -eq 0 ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
[ "${CLAUDEB_WORKER:-}" = 1 ] && exit 0
. "${self%/*}/../share/run-liveness.sh" 2>/dev/null || exit 0
. "${self%/*}/../share/processes.sh" 2>/dev/null || exit 0

chat_pid() {
  [ -z "${WORKER_RUN_BACKSTOP_CHAT_PID:-}" ] || { printf '%s' "$WORKER_RUN_BACKSTOP_CHAT_PID"; return 0; }
  claude_ancestor "$PPID"
}
# One process table read per stop, and only once a run needs it.
waiting=''
owned() {
  if [ -z "$waiting" ]; then
    local root listing
    root=$(chat_pid) || exit 0
    listing=$(ps -Ao pid=,ppid=,command= 2>/dev/null)
    waiting=no
    (process_listing() { printf '%s\n' "$listing"; }
      process_tree "$root" | awk -v root="$root" '
      FNR == NR { if ($1 != root) below[$1] = 1; next }
      ($1 in below) && $0 ~ /(^|[^A-Za-z0-9._-])(worker-run|review-bench)[ ]+wait[ ]/ { found = 1; exit }
      END { exit !found }' - <(printf '%s\n' "$listing")) && waiting=yes
  fi
  [ "$waiting" = yes ]
}
run_root=${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}
resume_of() { # run|review id
  if [ "$1" = review ]; then
    printf 'review-bench wait %s' "$2"
  elif [ "$(jq -r '.light // ""' "$run_root/$2/meta.json" 2>/dev/null)" = research ]; then
    printf 'light-research --attach %s --out <answer-file>' "$2"
  else
    printf 'worker-run wait %s --report' "$2"
  fi
}

payload=''
IFS= read -r -d '' payload || :
{ IFS= read -r session; IFS= read -r agent; IFS= read -r transcript; } <<EOF
$(jq -r '(.session_id // ""), (.agent_id // ""), (.transcript_path // "")' <<<"$payload" 2>/dev/null)
EOF
[ -z "$agent" ] || exit 0
case "$session" in ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac

lines=''
# Every finished run stays for days; sorting that many names in a UTF-8 locale costs more CPU than testing them.
run_dirs() { local LC_COLLATE=C; runs=("$run_root"/*/); }
run_dirs
ids=()
for run in "${runs[@]}"; do
  run=${run%/}
  [ ! -e "$run/exit_code" ] && [ -f "$run/state.json" ] || continue
  launcher=""
  { read -r launcher <"$run/launcher"; } 2>/dev/null
  [ "$launcher" = "$session" ] || continue
  id=${run##*/}
  case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
  ids+=("$id")
done
# A run is held by its starter still alive (a script waiting on its runs one at a time) and needs a
# wait only while its supervisor lives: every run's two answers come off one listing.
if [ "${#ids[@]}" -gt 0 ] && ! owned; then
  live=$'\n'$({
    metas=()
    for id in "${ids[@]}"; do
      metas+=("$run_root/$id/meta.json")
      pid='' began=''
      { read -r pid began <"$run_root/$id/starter"; } 2>/dev/null
      [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [[ "$began" =~ ^[0-9]+$ ]] && [ "$began" -gt 0 ] &&
        printf 's/%s %s %s\n' "$id" "$pid" "$began"
    done
    jq -r 'select((.pid | numbers) > 1) | "r/\(input_filename | split("/") | .[-2]) \(.pid) \(.pid_started_at | numbers // 0)"' \
      "${metas[@]}" 2>/dev/null
  } | pids_alive_since)$'\n'
  for id in "${ids[@]}"; do
    case "$live" in *$'\n'"s/$id"$'\n'*) continue ;; *$'\n'"r/$id"$'\n'*) ;; *) continue ;; esac
    tag=$(head -n1 "$run_root/$id/tag" 2>/dev/null)
    lines=$lines${lines:+$'\n'}"- worker run $id${tag:+ ($tag)} — \`$(resume_of run "$id")\`"
  done
fi

progress="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/progress"
named=''
for f in "$progress"/*.json; do
  [ -f "$f" ] || continue
  body=''
  IFS= read -r -d '' body 2>/dev/null <"$f"
  case "$body" in *"\"$session\""*) named=1; break ;; esac
done
now=''
[ -z "$named" ] || {
  now=$(date +%s)
  while IFS= read -r id; do
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    owned && continue
    lines=$lines${lines:+$'\n'}"- review $id — \`$(resume_of review "$id")\`"
  done < <(cat "$progress"/*.json 2>/dev/null | jq -r --arg s "$session" --argjson now "$now" \
    'select((.session // "") == $s and .state == "running" and (.heartbeat_epoch | type) == "number" and ($now - .heartbeat_epoch) < 600)
     | .run_id // empty' 2>/dev/null | awk '!seen[$0]++')
}

hold="$HOME/.cache/claude/stop-backstop/$session"
if [ -z "$lines" ]; then
  [ ! -e "$hold" ] || rm -f "$hold" 2>/dev/null
  exit 0
fi
[ -n "$now" ] || now=$(date +%s)
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
