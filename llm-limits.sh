#!/usr/bin/env bash
set -u

usage() {
  echo "Usage: $0 [--json|--plain|--table] [--sort 5h|weekly|reset] [--no-write] [--refresh]" >&2
}

format=''
write_cache=1
# Only an explicit manual refresh may invoke claudeb and spend tokens.
refresh=0
sort_key=''
sort_given=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) format=json ;;
    --plain) format=plain ;;
    --table) format=table ;;
    --sort) shift; [ $# -gt 0 ] || { usage; exit 2; }; sort_key=$1; sort_given=1 ;;
    --sort=*) sort_key=${1#--sort=}; sort_given=1 ;;
    --no-write) write_cache=0 ;;
    --refresh) refresh=1 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

# Single source of truth for valid --sort keys; columns index the TSV emitted by render_table.
sort_args() {
  case "$1" in
    5h) printf '%s' '-k1,1gr' ;;
    weekly) printf '%s' '-k2,2gr' ;;
    reset) printf '%s' '-k5,5n' ;;
    *) return 1 ;;
  esac
}
sort_flags=''
if [ "$sort_given" -eq 1 ]; then
  sort_flags=$(sort_args "$sort_key") || { usage; exit 2; }
fi

# No explicit output flag: humans at a terminal get the table; pipes keep the JSON contract
# (hammerspoon and other consumers run the script bare and parse stdout).
if [ -z "$format" ]; then
  if [ -t 1 ]; then format=table; else format=json; fi
fi

command -v jq >/dev/null 2>&1 || { echo "llm-limits.sh: jq is required" >&2; exit 3; }

# Resolve symlinks (e.g. ~/.local/bin/llm-limits) so helpers next to the real script are found.
script_path=$0
while [ -L "$script_path" ]; do
  link_target=$(readlink "$script_path")
  case "$link_target" in
    /*) script_path=$link_target ;;
    *) script_path=$(dirname "$script_path")/$link_target ;;
  esac
done
script_dir=$(cd "$(dirname "$script_path")" && pwd)

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

# Shared by the --plain and --table jq programs so the bucketing math cannot diverge.
stale_def='def stale_amount(day_u; hour_u):
  if (.stale_seconds // 0) > 3600 then
    (if .stale_seconds >= 86400
      then ((.stale_seconds / 86400 | floor | tostring) + day_u)
      else ((.stale_seconds / 3600 | floor | tostring) + hour_u) end)
  else null end;'

pct_cell() {
  # $4 is the raw numeric sort key emitted by jq (-1 = missing value).
  local cell num
  printf -v cell '%-*s' "$2" "$1"
  num=${4%%.*}
  if [ "$3" -eq 1 ] && [ "$num" != "-1" ]; then
    if [ "$num" -lt 50 ]; then printf '\033[32m%s\033[0m' "$cell"
    elif [ "$num" -lt 80 ]; then printf '\033[33m%s\033[0m' "$cell"
    else printf '\033[31m%s\033[0m' "$cell"; fi
  else
    printf '%s' "$cell"
  fi
}

render_table() {
  local table_color=0
  [ -t 1 ] && table_color=1
  # Sentinels (-1 / 9999999999) push rows with missing values last for every sort direction.
  # main is hidden from the table only; JSON output and the cache keep it.
  local rows
  rows=$(jq -r "$stale_def"'
    def pct(v): if v == null then "-" else ((v | tostring) + "%") end;
    def iso2epoch:
      if type != "string" then null
      else (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$") // null) as $c |
        if $c == null then null
        else ($c.d + "Z" | fromdateiso8601)
          - (if $c.tz == "Z" then 0
             else ($c.tz | capture("^(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")
                   | (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60))
             end)
        end
      end;
    (now | strflocaltime("%Y-%m-%d")) as $today |
    def fmt_reset($e): . as $iso |
      if $iso == null or $iso == "" then "-"
      elif $e == null then $iso
      elif ($e | strflocaltime("%Y-%m-%d")) == $today then ($e | strflocaltime("%H:%M"))
      else ($e | strflocaltime("%m-%d %H:%M")) end;
    def mknote($extra):
      (stale_amount("d"; "h")) as $a |
      ([$extra, (if $a then "stale " + $a else null end)]
       | map(select(. != null and . != "")) | join(", ")
       | if . == "" then "-" else . end);
    def row:
      (.five.used_pct) as $p5 | (.week.used_pct) as $pw |
      (.five.resets_at | iso2epoch) as $e5 | (.week.resets_at | iso2epoch) as $ew |
      [($p5 // -1), ($pw // -1),
       ($e5 // 9999999999), ($ew // 9999999999),
       ([($e5 // 9999999999), ($ew // 9999999999)] | min),
       .src, pct($p5), pct($pw),
       (.five.resets_at | fmt_reset($e5)), (.week.resets_at | fmt_reset($ew)),
       .note] | @tsv;
    .vendors as $v |
    [
      (if $v.claude.available and (($v.claude.accounts | type) == "array") then
         ($v.claude.accounts[] | select(.account != "main")
          | {src: ("claude/" + .account + (if .is_current then "*" else "" end)),
             five: .five_hour, week: .weekly,
             note: mknote(if .fable then "fable " + (.fable.used_pct | tostring) + "%" else null end)})
       else {src: "claude", five: null, week: null, note: ($v.claude.status // "-")} end),
      (("codex", "gemini") as $k | $v[$k]
       | if .available then
           {src: $k, five: .five_hour, week: .weekly,
            note: mknote(if $k == "codex" then .plan_type else .group end)}
         else {src: $k, five: null, week: null, note: (.status // "-")} end)
    ] | .[] | row
  ' <<<"$result")

  local sorted
  if [ -n "$sort_flags" ]; then
    sorted=$(sort -s -t $'\t' $sort_flags <<<"$rows")
  else
    sorted=$rows
  fi

  local k5 kw e5 ew kr src p5 pw d5 dw note
  local w_src=6 w_p5=3 w_pw=3 w_r5=8 w_rw=8
  while IFS=$'\t' read -r k5 kw e5 ew kr src p5 pw d5 dw note; do
    [ -n "$src" ] || continue
    [ "${#src}" -gt "$w_src" ] && w_src=${#src}
    [ "${#p5}" -gt "$w_p5" ] && w_p5=${#p5}
    [ "${#pw}" -gt "$w_pw" ] && w_pw=${#pw}
    [ "${#d5}" -gt "$w_r5" ] && w_r5=${#d5}
    [ "${#dw}" -gt "$w_rw" ] && w_rw=${#dw}
  done <<<"$sorted"

  printf '%-*s  %-*s  %-*s  %-*s  %-*s  %s\n' \
    "$w_src" SOURCE "$w_p5" "5H%" "$w_pw" "WK%" "$w_r5" "5H RESET" "$w_rw" "WK RESET" NOTE
  while IFS=$'\t' read -r k5 kw e5 ew kr src p5 pw d5 dw note; do
    [ -n "$src" ] || continue
    printf '%-*s  ' "$w_src" "$src"
    pct_cell "$p5" "$w_p5" "$table_color" "$k5"; printf '  '
    pct_cell "$pw" "$w_pw" "$table_color" "$kw"; printf '  '
    printf '%-*s  %-*s  %s\n' "$w_r5" "$d5" "$w_rw" "$dw" "$note"
  done <<<"$sorted"
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

# Gemini/Antigravity does not persist quota numbers. On an explicit refresh, start agy under a
# bounded PTY and ask its authenticated localhost Connect RPC for the same summary as /usage.
# Keep the last valid snapshot so ordinary menu opens remain file-only and instant.
gemini_cache=${LLM_LIMITS_GEMINI_CACHE:-$HOME/.llm-limits-gemini.json}
if [ "$refresh" -eq 1 ] && [ "${LLM_LIMITS_GEMINI_REFRESH:-1}" != 0 ]; then
  gemini_cmd=${LLM_LIMITS_GEMINI_CMD:-$script_dir/agy-quota.py}
  if [ -x "$gemini_cmd" ]; then
    mkdir -p "$(dirname "$gemini_cache")"
    gemini_tmp=$(mktemp "${gemini_cache}.tmp.XXXXXX") || exit 1
    if AGY_WORKDIR="${AGY_WORKDIR:-$script_dir}" "$gemini_cmd" >"$gemini_tmp" &&
      jq -e '
        (.groups | type) == "array" and
        any(.groups[]?;
          ((.displayName // "") | ascii_downcase | contains("gemini")) and
          any(.buckets[]?; .window == "5h" and (.remainingFraction | type) == "number") and
          any(.buckets[]?; .window == "weekly" and (.remainingFraction | type) == "number"))
      ' "$gemini_tmp" >/dev/null 2>&1; then
      mv -f "$gemini_tmp" "$gemini_cache"
    else
      rm -f "$gemini_tmp"
      echo "llm-limits.sh: Gemini refresh failed; keeping the last valid snapshot" >&2
    fi
  else
    echo "llm-limits.sh: Gemini quota helper is not executable: $gemini_cmd" >&2
  fi
fi

claude='{"available":false,"status":"no rate-limit snapshot","source":"none","last_wall":null}'
claudeb_root="${CLAUDEB_DIR:-$HOME/.claude-profiles}/.claudeb"
if [ "$refresh" -eq 1 ] && [ -d "$claudeb_root/limits" ]; then
  claudeb_cmd=$(command -v "${LLM_LIMITS_CLAUDEB_CMD:-claudeb}" 2>/dev/null || true)
  if [ -n "$claudeb_cmd" ]; then
    timeout_cmd=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
    if [ -n "$timeout_cmd" ]; then
      "$timeout_cmd" 25 "$claudeb_cmd" accounts >/dev/null 2>&1 || true
    else
      "$claudeb_cmd" accounts >/dev/null 2>&1 &
      claudeb_pid=$!
      (
        sleep 25
        kill "$claudeb_pid" 2>/dev/null || true
      ) &
      watchdog_pid=$!
      wait "$claudeb_pid" 2>/dev/null || true
      kill "$watchdog_pid" 2>/dev/null || true
      wait "$watchdog_pid" 2>/dev/null || true
    fi
  fi
fi
shopt -s nullglob
claudeb_files=("$claudeb_root/limits/"*.json)
shopt -u nullglob
if [ -d "$claudeb_root/limits" ] && [ "${#claudeb_files[@]}" -gt 0 ]; then
  current=$(tr -d '\r\n' <"$claudeb_root/.claudeb-state" 2>/dev/null || true)
  accounts='[]'
  for claude_file in "${claudeb_files[@]}"; do
    account=${claude_file##*/}; account=${account%.json}
    claude_data=$(jq -c 'select(
      (.five_hour.used_percentage | type) == "number" and
      (.five_hour.resets_at | type) == "number"
    )' "$claude_file" 2>/dev/null || true)
    mtime=$(file_mtime "$claude_file" || true)
    [ -n "$claude_data" ] && [ -n "$mtime" ] || continue
    stale=$((now_epoch - mtime)); [ "$stale" -ge 0 ] || stale=0
    week_reset=''
    if jq -e '(.seven_day.used_percentage | type) == "number" and (.seven_day.resets_at | type) == "number"' <<<"$claude_data" >/dev/null; then
      week_reset=$(epoch_iso "$(jq -r '.seven_day.resets_at' <<<"$claude_data")")
    fi
    fable_reset=''
    if jq -e '(.fable.used_percentage | type) == "number" and (.fable.resets_at | type) == "number"' <<<"$claude_data" >/dev/null; then
      fable_reset=$(epoch_iso "$(jq -r '.fable.resets_at' <<<"$claude_data")")
    fi
    account_json=$(jq -cn --argjson d "$claude_data" --arg account "$account" \
      --arg five_reset "$(epoch_iso "$(jq -r '.five_hour.resets_at' <<<"$claude_data")")" \
      --arg week_reset "$week_reset" --arg fable_reset "$fable_reset" --arg as_of "$(epoch_iso "$mtime")" --argjson stale "$stale" '
      {account:$account,is_current:false,
       five_hour:{used_pct:$d.five_hour.used_percentage,resets_at:$five_reset},
       as_of:$as_of,stale_seconds:$stale} +
      (if $week_reset == "" then {} else {weekly:{used_pct:$d.seven_day.used_percentage,resets_at:$week_reset}} end) +
      (if $fable_reset == "" then {} else {fable:{used_pct:$d.fable.used_percentage,resets_at:$fable_reset}} end)')
    accounts=$(jq -cn --argjson a "$accounts" --argjson item "$account_json" '$a + [$item]')
  done
  if [ "$(jq 'length' <<<"$accounts")" -gt 0 ]; then
    if ! jq -e --arg current "$current" 'any(.account == $current)' <<<"$accounts" >/dev/null; then
      current=$(jq -r 'if any(.account == "main") then "main" else sort_by(.account)[0].account end' <<<"$accounts")
    fi
    accounts=$(jq -c --arg current "$current" 'map(.is_current = (.account == $current)) | sort_by(if .is_current then 0 else 1 end, .account)' <<<"$accounts")
    claude=$(jq -cn --argjson accounts "$accounts" --argjson wall "$claude_wall" '
      ($accounts[0]) as $current |
      {available:true,source:"claudeb-store",current_account:$current.account,accounts:$accounts,
       five_hour:$current.five_hour,as_of:$current.as_of,stale_seconds:$current.stale_seconds,last_wall:$wall} +
      (if $current.weekly then {weekly:$current.weekly} else {} end) +
      (if $current.fable then {fable:$current.fable} else {} end)')
  fi
else
  claude_last="$HOME/.claude/statusline-last.json"
  claude_rl="$HOME/.claude/statusline-cache-rl"
  last_mtime=$(file_mtime "$claude_last" 2>/dev/null || echo 0)
  rl_mtime=$(file_mtime "$claude_rl" 2>/dev/null || echo 0)
  claude_data=''
  if [ -r "$claude_last" ] && [ "${last_mtime:-0}" -ge "${rl_mtime:-0}" ]; then
    claude_file="$claude_last"; claude_source=statusline-last
    claude_data=$(jq -c '.rate_limits | select((.five_hour.used_percentage|type)=="number" and (.five_hour.resets_at|type)=="number" and (.seven_day.used_percentage|type)=="number" and (.seven_day.resets_at|type)=="number")' "$claude_file" 2>/dev/null || true)
  fi
  if [ -z "$claude_data" ]; then
    claude_file="$claude_rl"; claude_source=statusline-cache
    [ ! -r "$claude_file" ] || claude_data=$(jq -c 'select((.five_hour.used_percentage|type)=="number" and (.five_hour.resets_at|type)=="number" and (.seven_day.used_percentage|type)=="number" and (.seven_day.resets_at|type)=="number")' "$claude_file" 2>/dev/null || true)
  fi
  if [ -n "$claude_data" ]; then
    mtime=$(file_mtime "$claude_file" || true)
    if [ -n "$mtime" ]; then
      stale=$((now_epoch - mtime)); [ "$stale" -ge 0 ] || stale=0
      claude=$(jq -cn --argjson d "$claude_data" --argjson wall "$claude_wall" --arg source "$claude_source" \
        --arg five_reset "$(epoch_iso "$(jq -r '.five_hour.resets_at' <<<"$claude_data")")" --arg week_reset "$(epoch_iso "$(jq -r '.seven_day.resets_at' <<<"$claude_data")")" \
        --arg as_of "$(epoch_iso "$mtime")" --argjson stale "$stale" '
        {account:"main",is_current:true,five_hour:{used_pct:$d.five_hour.used_percentage,resets_at:$five_reset},weekly:{used_pct:$d.seven_day.used_percentage,resets_at:$week_reset},as_of:$as_of,stale_seconds:$stale} as $account |
        {available:true,source:$source,current_account:"main",accounts:[$account],five_hour:$account.five_hour,weekly:$account.weekly,as_of:$as_of,stale_seconds:$stale,last_wall:$wall}')
    fi
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
  '{available:false,status:"no quota snapshot",last_wall:$wall,source:"agy-local-rpc"}')
if [ -r "$gemini_cache" ]; then
  gemini_data=$(jq -c '
    [.groups[]? | select((.displayName // "") | ascii_downcase | contains("gemini"))][0] as $group |
    [$group.buckets[]? | select(.window == "5h")][0] as $five |
    [$group.buckets[]? | select(.window == "weekly")][0] as $week |
    select(($five.remainingFraction | type) == "number" and
           ($five.resetTime | type) == "string" and
           ($week.remainingFraction | type) == "number" and
           ($week.resetTime | type) == "string") |
    {group:$group.displayName,five:$five,week:$week}
  ' "$gemini_cache" 2>/dev/null || true)
  gemini_mtime=$(file_mtime "$gemini_cache" 2>/dev/null || true)
  if [ -n "$gemini_data" ] && [ -n "$gemini_mtime" ]; then
    stale=$((now_epoch - gemini_mtime)); [ "$stale" -ge 0 ] || stale=0
    gemini=$(jq -cn --argjson d "$gemini_data" --argjson wall "$gemini_wall" \
      --arg as_of "$(epoch_iso "$gemini_mtime")" --argjson stale "$stale" '
      def used($remaining):
        ((1 - $remaining) * 100) |
        (if . < 0 then 0 elif . > 100 then 100 else . end) |
        . * 100 | round / 100;
      {available:true,source:"agy-local-rpc",group:$d.group,
       five_hour:{used_pct:used($d.five.remainingFraction),resets_at:$d.five.resetTime},
       weekly:{used_pct:used($d.week.remainingFraction),resets_at:$d.week.resetTime},
       as_of:$as_of,stale_seconds:$stale,last_wall:$wall}')
  fi
fi
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
elif [ "$format" = table ]; then
  render_table
else
  jq -r "$stale_def"'
    def age:
      (stale_amount("д"; "ч")) as $a |
      if $a == null then "" else " (данные " + $a + " назад)" end;
    .vendors | to_entries[] |
    if .value.available then
      if .key == "claude" and (.value.accounts | type) == "array" then
        .value.accounts[] | ("claude/" + .account + ": " + (.five_hour.used_pct|tostring) + "%/" + ((.weekly.used_pct // "-")|tostring) +
         "% | resets " + .five_hour.resets_at + " / " + (.weekly.resets_at // "—") + (. | age))
      else (.key + ": " + (.value.five_hour.used_pct|tostring) + "%/" + (.value.weekly.used_pct|tostring) +
       "% | resets " + .value.five_hour.resets_at + " / " + .value.weekly.resets_at + (.value|age)) end
    else (.key + ": " + .value.status + (if .value.last_wall then " | last wall " + .value.last_wall else "" end)) end
  ' <<<"$result"
fi

available=$(jq '[.vendors[] | select(.available == true)] | length' <<<"$result")
[ "$available" -gt 0 ] && exit 0
exit 3
