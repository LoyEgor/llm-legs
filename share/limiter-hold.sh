# A limiter that holds work says so: docs/harness-doctor-design.md §12. Copy or source it; it needs
# nothing of llm-legs but the path. file=$(hold_raise <limiter> <what> <why> [until-epoch] [key]); hold_clear "$file".
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

hold_clear() { [ -z "${1:-}" ] || rm -f "$1" 2>/dev/null || :; }
