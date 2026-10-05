# A limiter that holds work says so: docs/harness-doctor-design.md §12. Copy or source it; it needs
# nothing of llm-legs but the path. file=$(hold_raise <limiter> <what> <why> [until-epoch] [key]); hold_clear "$file"
# journals the hold's wait (wait_note) and removes it.
# Jobs of one process that wait at once (background subshells share $$) each pass their own key.
hold_raise() {
  local dir="${HARNESS_HOLDS_DIR:-${HARNESS_DOCTOR_DIR:-$HOME/.cache/harness-doctor}/holds}" name="${1//[^A-Za-z0-9_.-]/_}"
  local file="$dir/$name-$$${5:+-$5}.json"
  mkdir -p "$dir" 2>/dev/null && jq -cn --arg limiter "$name" --argjson pid "$$" --arg what "$2" --arg why "$3" \
    --arg until "${4:-}" --arg session "${CLAUDE_CODE_SESSION_ID:-}" --arg cwd "$PWD" \
    --argjson since "${EPOCHSECONDS:-$(date +%s)}" '{limiter: $limiter, pid: $pid,
      held: {what: $what, session: (if $session == "" then null else $session end), cwd: $cwd},
      since: $since, why: $why,
      until: ($until | tonumber? // null | if . != null and (isinfinite or isnan) then null else . end)}' \
    >"$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file" && printf '%s\n' "$file" || hold_clear "$file.tmp"
}

hold_clear() {
  [ -n "${1:-}" ] || return 0
  local row limiter what since
  row=$(jq -r '[.limiter, .held.what, .since] | @tsv' "$1" 2>/dev/null) &&
    IFS=$'\t' read -r limiter what since <<<"$row" && wait_note "$limiter" "$what" "$since" "" "${2:-}" "${3:-}" "${4:-}"
  rm -f "$1" 2>/dev/null || :
}

# wait_note <class> <source> <started epoch[.frac]> [seconds [allowed held reason]]: one wait journal row
# (shared-invariants row ed); seconds default to now - started. hold_clear <file> [allowed held reason].
wait_note() {
  local dir="${HARNESS_WAITS_DIR:-${HARNESS_DOCTOR_DIR:-$HOME/.cache/harness-doctor}/waits}" start ms source day extra='' allowed=${5:-null} held=${6:-null} reason=${7:-}
  start=$(wait_ms "${3:-}") || return 0
  ms=$(wait_ms "${4:-}") || ms=$(( $(wait_ms "${EPOCHREALTIME:-$(date +%s)}") - start ))
  [ "$ms" -ge 0 ] 2>/dev/null || return 0
  source=${2//\\/\\\\}; source=${source//\"/\\\"}; source=${source//[[:cntrl:]]/ }
  if [ "$1" = night-workers ] || [ "$1" = run-suites ] || [ -n "$reason" ]; then
    [[ "$allowed" =~ ^[0-9]+$ ]] || allowed=null
    [[ "$held" =~ ^[0-9]+$ ]] || held=null
    [ -z "$reason" ] && reason=null || reason="\"${reason//[^A-Za-z0-9_.-]/_}\""
    extra=",\"allowed\":$allowed,\"held\":$held,\"reason\":$reason"
  fi
  printf -v day '%(%Y-%m-%d)T' "$(( start / 1000 ))" 2>/dev/null || day=$(date -r "$(( start / 1000 ))" +%Y-%m-%d) || return 0
  mkdir -p "$dir" 2>/dev/null &&
    printf '{"class":"%s","source":"%s","started":%d.%03d,"seconds":%d.%03d,"pid":%d%s}\n' "${1//[^A-Za-z0-9_.-]/_}" "$source" \
      $(( start / 1000 )) $(( start % 1000 )) $(( ms / 1000 )) $(( ms % 1000 )) "$$" "$extra" >>"$dir/$day.jsonl" 2>/dev/null
  return 0
}

wait_ms() { # epoch[.frac] -> milliseconds; fails on anything else
  local int=${1%%.*} frac=000
  [[ "$1" == *.* ]] && frac="${1#*.}000"
  [[ "$int" =~ ^[0-9]+$ ]] && [[ "$frac" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' $(( 10#$int * 1000 + 10#${frac:0:3} ))
}
