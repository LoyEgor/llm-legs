#!/usr/bin/env bash
set -u

usage() {
  echo "Usage: $0 [--json|--plain] [--no-write]" >&2
}

format=json
write_cache=1
for arg in "$@"; do
  case "$arg" in
    --json) format=json ;;
    --plain) format=plain ;;
    --no-write) write_cache=0 ;;
    *) usage; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "llm-limits.sh: jq is required" >&2; exit 3; }

chunk_bytes=${LLM_LIMITS_CHUNK_BYTES:-4194304}
case "$chunk_bytes" in
  ''|*[!0-9]*|0) echo "llm-limits.sh: LLM_LIMITS_CHUNK_BYTES must be a positive integer" >&2; exit 3 ;;
esac

now_epoch=$(date +%s)
local_iso() {
  date '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'
}

epoch_iso() {
  local epoch=$1
  if date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z' >/dev/null 2>&1; then
    date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'
  else
    date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'
  fi
}

file_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

wall_for() {
  local vendor=$1 log=${LLM_LIMITS_WALLS_LOG:-}
  if [ -n "$log" ] && [ -r "$log" ]; then
    jq -Rs --arg leg "$vendor" '
      split("\n") | map(fromjson? | select(.leg == $leg and .rc == 5)) |
      last | (.timestamp // .ts // null)
    ' "$log" 2>/dev/null || printf 'null\n'
  else
    printf 'null\n'
  fi
}

claude_wall=$(wall_for claude)
codex_wall=$(wall_for codex)
gemini_wall=$(wall_for gemini)

claude_file="$HOME/.claude/statusline-last.json"
claude_source=statusline-last
claude_model=''
claude_data=''
if [ -r "$claude_file" ]; then
  claude_data=$(jq -c '.rate_limits | select(
    (.five_hour.used_percentage | type) == "number" and
    (.five_hour.resets_at | type) == "number" and
    (.seven_day.used_percentage | type) == "number" and
    (.seven_day.resets_at | type) == "number"
  )' "$claude_file" 2>/dev/null || true)
  claude_model=$(jq -r '.model.display_name // empty' "$claude_file" 2>/dev/null || true)
fi

if [ -z "$claude_data" ]; then
  claude_file="$HOME/.claude/statusline-cache-rl"
  claude_source=statusline-cache
  claude_model=''
  if [ -r "$claude_file" ]; then
    claude_data=$(jq -c 'select(
      (.five_hour.used_percentage | type) == "number" and
      (.five_hour.resets_at | type) == "number" and
      (.seven_day.used_percentage | type) == "number" and
      (.seven_day.resets_at | type) == "number"
    )' "$claude_file" 2>/dev/null || true)
  fi
fi

claude='{"available":false,"status":"no rate-limit snapshot","source":"none","last_wall":null}'
if [ -n "$claude_data" ]; then
  mtime=$(file_mtime "$claude_file" || true)
  if [ -n "$mtime" ]; then
    stale=$((now_epoch - mtime)); [ "$stale" -ge 0 ] || stale=0
    claude=$(jq -cn --argjson d "$claude_data" --argjson wall "$claude_wall" \
      --arg source "$claude_source" --arg model "$claude_model" \
      --arg five_reset "$(epoch_iso "$(jq -r '.five_hour.resets_at' <<<"$claude_data")")" \
      --arg week_reset "$(epoch_iso "$(jq -r '.seven_day.resets_at' <<<"$claude_data")")" \
      --arg as_of "$(epoch_iso "$mtime")" --argjson stale "$stale" '
      {available:true,
       five_hour:{used_pct:$d.five_hour.used_percentage,resets_at:$five_reset},
       weekly:{used_pct:$d.seven_day.used_percentage,resets_at:$week_reset},
       as_of:$as_of,stale_seconds:$stale,source:$source,last_wall:$wall} +
       (if $model == "" then {} else {session_model:$model} end)')
  else
    claude=$(jq -cn --argjson wall "$claude_wall" \
      --arg source "$claude_source" \
      '{available:false,status:"missing snapshot mtime",source:$source,last_wall:$wall}')
  fi
fi

codex_event=''
codex_root="$HOME/.codex/sessions"
if [ -d "$codex_root" ]; then
  while IFS= read -r entry; do
    path=${entry#* }
    event=$(tail -c "$chunk_bytes" "$path" 2>/dev/null | jq -Rc '
      fromjson? |
      select(.payload.rate_limits? | type == "object") |
      select((.payload.rate_limits.primary.used_percent | type) == "number") |
      select((.payload.rate_limits.secondary.used_percent | type) == "number")
    ' 2>/dev/null | tail -n 1)
    if [ -n "$event" ]; then codex_event=$event; break; fi
  done < <(find "$codex_root" -type f -name 'rollout-*.jsonl' -exec stat -f '%m %N' {} + 2>/dev/null | sort -nr | head -n 5)
fi

if [ -n "$codex_event" ]; then
  codex_ts=$(jq -r '.timestamp' <<<"$codex_event")
  codex_epoch=$(jq -nr --arg ts "$codex_ts" '$ts | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601' 2>/dev/null || true)
  if [ -n "$codex_epoch" ]; then
    stale=$((now_epoch - codex_epoch)); [ "$stale" -ge 0 ] || stale=0
    primary_reset=$(jq -r '.payload.rate_limits.primary.resets_at' <<<"$codex_event")
    secondary_reset=$(jq -r '.payload.rate_limits.secondary.resets_at' <<<"$codex_event")
    codex=$(jq -cn --argjson e "$codex_event" --argjson wall "$codex_wall" \
      --arg five_reset "$(epoch_iso "$primary_reset")" --arg week_reset "$(epoch_iso "$secondary_reset")" \
      --arg as_of "$(epoch_iso "$codex_epoch")" --argjson stale "$stale" '
      {available:true,
       five_hour:{used_pct:$e.payload.rate_limits.primary.used_percent,resets_at:$five_reset},
       weekly:{used_pct:$e.payload.rate_limits.secondary.used_percent,resets_at:$week_reset},
       as_of:$as_of,stale_seconds:$stale,source:"session-rollout",last_wall:$wall,
       plan_type:($e.payload.rate_limits.plan_type // null)}')
  else
    codex=$(jq -cn --argjson wall "$codex_wall" \
      '{available:false,status:"unparsable session timestamp",source:"session-rollout",last_wall:$wall}')
  fi
else
  codex=$(jq -cn --argjson wall "$codex_wall" \
    '{available:false,status:"no rate-limit event",source:"session-rollout",last_wall:$wall}')
fi

gemini=$(jq -cn --argjson wall "$gemini_wall" \
  '{available:false,status:"unknown",last_wall:$wall,source:"none"}')
result=$(jq -cn --arg fetched_at "$(local_iso)" --argjson claude "$claude" \
  --argjson codex "$codex" --argjson gemini "$gemini" \
  '{schema:1,fetched_at:$fetched_at,vendors:{claude:$claude,codex:$codex,gemini:$gemini}}')

if [ "$write_cache" -eq 1 ]; then
  cache=${LLM_LIMITS_CACHE:-$HOME/.llm-limits.json}
  mkdir -p "$(dirname "$cache")"
  tmp=$(mktemp "${cache}.tmp.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  printf '%s\n' "$result" >"$tmp"
  mv -f "$tmp" "$cache"
  trap - EXIT HUP INT TERM
fi

if [ "$format" = json ]; then
  printf '%s\n' "$result"
else
  jq -r '
    def age:
      if .stale_seconds > 3600 then
        " (данные " + (if .stale_seconds >= 86400 then ((.stale_seconds / 86400 | floor | tostring) + "д") else ((.stale_seconds / 3600 | floor | tostring) + "ч") end) + " назад)"
      else "" end;
    .vendors | to_entries[] |
    if .value.available then
      (.key + ": " + (.value.five_hour.used_pct|tostring) + "%/" + (.value.weekly.used_pct|tostring) +
       "% | resets " + .value.five_hour.resets_at + " / " + .value.weekly.resets_at + (.value|age))
    else (.key + ": " + .value.status + (if .value.last_wall then " | last wall " + .value.last_wall else "" end)) end
  ' <<<"$result"
fi

available=$(jq '[.vendors[] | select(.available == true)] | length' <<<"$result")
[ "$available" -gt 0 ] && exit 0
exit 3
