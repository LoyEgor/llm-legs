#!/usr/bin/env bash
set -u

usage() {
  echo "Usage: $0 [--json|--plain|--table] [--sort 5h|weekly|reset] [--no-write] [--refresh [--start-windows]]" >&2
}

format=''
write_cache=1
# --refresh is zero token spend (helpers query usage endpoints only); --start-windows is
# the only path that may issue paid model calls, and only for vendors whose 5h window expired.
refresh=0
start_windows=0
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
    --start-windows) start_windows=1 ;;
    *) usage; exit 2 ;;
  esac
  shift
done
if [ "$start_windows" -eq 1 ] && [ "$refresh" -eq 0 ]; then
  usage
  exit 2
fi

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

# Snapshots may carry null where an epoch is expected; a literal "null" inside $(( ))
# aborts the whole run under set -u.
int_or_empty() {
  case "$1" in ''|*[!0-9]*) : ;; *) printf '%s' "$1" ;; esac
}

run_bounded() {
  local seconds=$1 pid watchdog_pid timeout_cmd rc
  shift
  timeout_cmd=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$seconds" "$@" >/dev/null 2>&1
    return $?
  fi
  "$@" >/dev/null 2>&1 &
  pid=$!
  (sleep "$seconds"; kill "$pid" 2>/dev/null || true) &
  watchdog_pid=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$rc"
}

iso_def='def iso2epoch:
  if type != "string" then null
  else (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>[Zz]|[+-][0-9]{2}:?[0-9]{2})$") // null) as $c |
    if $c == null then null
    else ($c.d + "Z" | fromdateiso8601)
      - (if ($c.tz | ascii_upcase) == "Z" then 0
         else ($c.tz | capture("^(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")
               | (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60))
         end)
    end
  end;'

# Shared by the --plain and --table jq programs so the bucketing math cannot diverge.
stale_def='def stale_amount(day_u; hour_u):
  if (.stale_seconds // 0) > 3600 then
    (if .stale_seconds >= 86400
      then ((.stale_seconds / 86400 | floor | tostring) + day_u)
      else ((.stale_seconds / 3600 | floor | tostring) + hour_u) end)
  else null end;'

reset_format_def='def format_reset($now):
  . as $iso | ($iso | iso2epoch) as $epoch |
  if $iso == null or $iso == "" then "-"
  elif $epoch == null then $iso
  elif ($epoch - $now) < 86400 then ($epoch | strflocaltime("%H:%M"))
  elif ($epoch - $now) < 604800 then
    (["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$epoch | strflocaltime("%w") | tonumber]
     + " " + ($epoch | strflocaltime("%H:%M")))
  else ($epoch | strflocaltime("%m-%d %H:%M")) end;'

pct_cell() {
  # $4 is the raw numeric sort key emitted by jq (-1 = missing value); $5 dims the cell:
  # expired/stale values must never render in the live severity colors.
  local cell num
  printf -v cell '%-*s' "$2" "$1"
  num=${4%%.*}
  if [ "$3" -eq 1 ] && [ "${5:-0}" -eq 1 ] && [ "$1" != "-" ]; then
    printf '\033[2m%s\033[0m' "$cell"
  elif [ "$3" -eq 1 ] && [ "$num" != "-1" ] && [ "$1" != "-" ]; then
    if [ "$num" -lt 50 ]; then printf '\033[32m%s\033[0m' "$cell"
    elif [ "$num" -lt 80 ]; then printf '\033[33m%s\033[0m' "$cell"
    else printf '\033[31m%s\033[0m' "$cell"; fi
  else
    printf '%s' "$cell"
  fi
}

dim_cell() {
  pct_cell "$1" "$2" "$3" -1 "${4:-0}"
}

render_table() {
  local table_color=0 note_dim='' note_rst=''
  if [ -t 1 ]; then
    table_color=1
    note_dim=$'\033[2m'
    note_rst=$'\033[0m'
  fi
  # Sentinels (-1 / 9999999999) push rows with missing values last for every sort direction.
  local rows
  rows=$(jq -r --arg dim "$note_dim" --arg rst "$note_rst" --argjson render_now "$now_epoch" "$stale_def$iso_def$reset_format_def"'
    def pct(v): if v == null then "-" else ((v | round | tostring) + "%") end;
    def mknote($extra):
      (stale_amount("d"; "h")) as $a |
      ([$extra, (if $a then "stale " + $a else null end)]
       | map(select(. != null and . != "")) | join(", ")
       | if . == "" then "-" else . end);
    def fable_note:
      if (.fable | type) == "object" then
        ("fable " + pct(.fable.used_pct)) as $f |
        (if (.fable.expired == true or .fable.stale == true) then $dim + $f + $rst else $f end)
      else null end;
    def row:
      (.five.expired == true) as $x5 | (.week.expired == true) as $xw |
      (if ($x5 or .five.stale == true) then 1 else 0 end) as $d5 |
      (if ($xw or .week.stale == true) then 1 else 0 end) as $dw |
      .five.used_pct as $p5 | .week.used_pct as $pw |
      (.five.resets_at | iso2epoch) as $e5 |
      (.week.resets_at | iso2epoch) as $ew |
      (if $x5 then null else $e5 end) as $s5 |
      (if $xw then null else $ew end) as $sw |
      ([(if $x5 then "5h reset passed" else empty end),
        (if $xw then "wk reset passed" else empty end)] | join(", ")) as $xn |
      [(if $x5 then 0 else ($p5 // -1) end), (if $xw then 0 else ($pw // -1) end),
       ($s5 // 9999999999), ($sw // 9999999999),
       ([($s5 // 9999999999), ($sw // 9999999999)] | min),
       $d5, $dw,
       .src, pct($p5), pct($pw),
       (.five.resets_at | format_reset($render_now)),
       (.week.resets_at | format_reset($render_now)),
       (if $xn == "" then .note
        elif .note == "-" or .note == "" then $xn
        else .note + ", " + $xn end)] | @tsv;
    .vendors as $v |
    [
      (if $v.claude.available and (($v.claude.accounts | type) == "array") then
         ($v.claude.accounts[]
          | {src: ("claude/" + .account + (if .is_current then "*" else "" end)),
             five: .five_hour, week: .weekly,
             note: mknote(([fable_note, (if .enabled == false then "off" else null end)]
                           | map(select(. != null)) | join(", ")))})
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

  local k5 kw e5 ew kr dim5 dimw src p5 pw r5 rw note
  local w_src=6 w_p5=3 w_pw=3 w_r5=8 w_rw=8
  while IFS=$'\t' read -r k5 kw e5 ew kr dim5 dimw src p5 pw r5 rw note; do
    [ -n "$src" ] || continue
    [ "${#src}" -gt "$w_src" ] && w_src=${#src}
    [ "${#p5}" -gt "$w_p5" ] && w_p5=${#p5}
    [ "${#pw}" -gt "$w_pw" ] && w_pw=${#pw}
    [ "${#r5}" -gt "$w_r5" ] && w_r5=${#r5}
    [ "${#rw}" -gt "$w_rw" ] && w_rw=${#rw}
  done <<<"$sorted"

  printf '%-*s  %-*s  %-*s  %-*s  %-*s  %s\n' \
    "$w_src" SOURCE "$w_p5" "5H%" "$w_pw" "WK%" "$w_r5" "5H RESET" "$w_rw" "WK RESET" NOTE
  while IFS=$'\t' read -r k5 kw e5 ew kr dim5 dimw src p5 pw r5 rw note; do
    [ -n "$src" ] || continue
    printf '%-*s  ' "$w_src" "$src"
    pct_cell "$p5" "$w_p5" "$table_color" "$k5" "$dim5"; printf '  '
    pct_cell "$pw" "$w_pw" "$table_color" "$kw" "$dimw"; printf '  '
    dim_cell "$r5" "$w_r5" "$table_color" "$dim5"; printf '  '
    dim_cell "$rw" "$w_rw" "$table_color" "$dimw"; printf '  '
    printf '%s\n' "$note"
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
gemini_refresh_error=''
refresh_gemini_quota() {
  local gemini_cmd=${LLM_LIMITS_GEMINI_CMD:-$script_dir/agy-quota.py} gemini_tmp
  if [ ! -x "$gemini_cmd" ]; then
    gemini_refresh_error='helper not executable'
    echo "llm-limits.sh: Gemini quota helper is not executable: $gemini_cmd" >&2
    return 1
  fi
  mkdir -p "$(dirname "$gemini_cache")"
  gemini_tmp=$(mktemp "${gemini_cache}.tmp.XXXXXX") || { gemini_refresh_error='cache temp failed'; return 1; }
  if AGY_WORKDIR="${AGY_WORKDIR:-$script_dir}" "$gemini_cmd" >"$gemini_tmp" &&
    jq -e '
      (.groups | type) == "array" and
      any(.groups[]?;
        ((.displayName // "") | ascii_downcase | contains("gemini")) and
        any(.buckets[]?; .window == "5h" and (.remainingFraction | type) == "number") and
        any(.buckets[]?; .window == "weekly" and (.remainingFraction | type) == "number"))
    ' "$gemini_tmp" >/dev/null 2>&1; then
    mv -f "$gemini_tmp" "$gemini_cache"
    gemini_refresh_error=''
  else
    gemini_refresh_error='live query failed'
    rm -f "$gemini_tmp"
    echo "llm-limits.sh: Gemini refresh failed; keeping the last valid snapshot" >&2
    return 1
  fi
}
if [ "$refresh" -eq 1 ] && [ "${LLM_LIMITS_GEMINI_REFRESH:-1}" != 0 ]; then
  refresh_gemini_quota || true
fi
if [ "$start_windows" -eq 1 ]; then
  if [ "${LLM_LIMITS_GEMINI_REFRESH:-1}" = 0 ]; then
    echo "llm-limits.sh: gemini window start skipped (LLM_LIMITS_GEMINI_REFRESH=0)" >&2
  else
    gemini_5h_reset=''
    if [ -r "$gemini_cache" ]; then
      gemini_5h_reset=$(int_or_empty "$(jq -r "$iso_def"'
        [.groups[]? | select((.displayName // "") | ascii_downcase | contains("gemini"))][0] as $g |
        [$g.buckets[]? | select(.window == "5h")][0].resetTime | iso2epoch // empty
      ' "$gemini_cache" 2>/dev/null || true)")
    fi
    if [ -z "$gemini_5h_reset" ]; then
      echo "llm-limits.sh: gemini 5h window state unknown; not starting a window" >&2
    elif [ "$gemini_5h_reset" -le "$now_epoch" ]; then
      agy_bin=${AGY_BIN:-$HOME/.local/bin/agy}
      if [ -x "$agy_bin" ]; then
        (cd "${AGY_WORKDIR:-$script_dir}" && run_bounded 120 "$agy_bin" --print 'Reply with exactly: ok')
        refresh_gemini_quota || true
      else
        echo "llm-limits.sh: agy not found; cannot start a gemini window" >&2
      fi
    fi
  fi
fi

claude='{"available":false,"status":"no rate-limit snapshot","source":"none","last_wall":null}'
claudeb_root="${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}"
claude_refresh_error=''
if [ "$refresh" -eq 1 ]; then
  if [ -d "$claudeb_root/limits" ]; then
    claudeb_cmd=$(command -v "${LLM_LIMITS_CLAUDEB_CMD:-claudeb}" 2>/dev/null || true)
    if [ -n "$claudeb_cmd" ]; then
      if [ "$start_windows" -eq 1 ]; then
        # Feature-detect: older claudeb builds predate --start-windows and would die on it.
        if "$claudeb_cmd" --help 2>/dev/null | grep -q -- '--start-windows'; then
          run_bounded 180 "$claudeb_cmd" --refresh --start-windows || claude_refresh_error='probe failed'
        else
          echo "llm-limits.sh: claudeb lacks --start-windows; claude windows not started (free refresh only)" >&2
          run_bounded 60 "$claudeb_cmd" accounts --no-spend || claude_refresh_error='probe failed'
        fi
      else
        run_bounded 60 "$claudeb_cmd" accounts --no-spend || claude_refresh_error='probe failed'
      fi
    elif [ "$start_windows" -eq 1 ]; then
      echo "llm-limits.sh: claudeb not found; cannot start claude windows" >&2
    fi
  elif [ "$start_windows" -eq 1 ]; then
    echo "llm-limits.sh: no claudeb store; cannot start claude windows" >&2
  fi
fi
shopt -s nullglob
claudeb_files=("$claudeb_root/limits/"*.json)
shopt -u nullglob
if [ -d "$claudeb_root/limits" ] && [ "${#claudeb_files[@]}" -gt 0 ]; then
  current=$(tr -d '\r\n' <"$claudeb_root/.claudeb-state" 2>/dev/null || true)
  claudeb_disabled="$claudeb_root/disabled"
  accounts_lines=''
  for claude_file in "${claudeb_files[@]}"; do
    account=${claude_file##*/}; account=${account%.json}
    [ "$account" != main ] || continue
    enabled=true
    if [ -r "$claudeb_disabled" ] && grep -qxF "$account" "$claudeb_disabled"; then enabled=false; fi
    # Snapshots without a valid five_hour bucket (e.g. auth-only after a failed probe) must
    # stay visible as unknown values, never vanish from the account list.
    claude_data=$(jq -c 'select(type == "object")' "$claude_file" 2>/dev/null || true)
    mtime=$(file_mtime "$claude_file" || true)
    [ -n "$claude_data" ] && [ -n "$mtime" ] || continue
    has_five=0
    if jq -e '(.five_hour.used_percentage | type) == "number" and (.five_hour.resets_at | type) == "number"' <<<"$claude_data" >/dev/null; then
      has_five=1
    fi
    stale=$((now_epoch - mtime)); [ "$stale" -ge 0 ] || stale=0
    five_reset=''
    [ "$has_five" -eq 0 ] || five_reset=$(epoch_iso "$(jq -r '.five_hour.resets_at' <<<"$claude_data")")
    week_reset=''
    if jq -e '(.seven_day.used_percentage | type) == "number" and (.seven_day.resets_at | type) == "number"' <<<"$claude_data" >/dev/null; then
      week_reset=$(epoch_iso "$(jq -r '.seven_day.resets_at' <<<"$claude_data")")
    fi
    fable_reset=''
    if jq -e '(.fable.used_percentage | type) == "number" and (.fable.resets_at | type) == "number" and .fable.resets_at > 0' <<<"$claude_data" >/dev/null; then
      fable_reset=$(epoch_iso "$(jq -r '.fable.resets_at' <<<"$claude_data")")
    fi
    account_json=$(jq -cn --argjson d "$claude_data" --arg account "$account" --argjson enabled "$enabled" \
      --arg five_reset "$five_reset" --argjson mtime "$mtime" --argjson now "$now_epoch" \
      --arg week_reset "$week_reset" --arg fable_reset "$fable_reset" --arg as_of "$(epoch_iso "$mtime")" \
      --argjson stale "$stale" '
      (($d.auth | type) == "object" and $d.auth.status == "expired") as $expired |
      def meta($b; $thr):
        if ($b | type) != "object" then null else
          (if ($b.as_of | type) == "number" then $b.as_of else $mtime end) as $asof |
          ({as_of: $asof,
            stale: ($expired or (($b.origin // "") == "cached") or (($now - $asof) > $thr))} +
           (if ($b.origin | type) == "string" then {origin: $b.origin} else {} end))
        end;
      {auth: (if ($d.auth | type) == "object" then $d.auth else null end),
       five: ($d | meta(.five_hour; 1800)),
       week: ($d | meta(.seven_day; 21600)),
       fable: ($d | meta(.fable; 21600))} as $x |
      {account:$account,is_current:false,enabled:$enabled,
       five_hour:(if $five_reset == ""
                  then {used_pct:null,resets_at:null,as_of:$mtime,stale:true}
                  else {used_pct:$d.five_hour.used_percentage,resets_at:$five_reset} + ($x.five // {}) end),
       as_of:$as_of,stale_seconds:$stale} +
      (if $x.auth then {auth:$x.auth} else {} end) +
      (if $week_reset == "" then {} else {weekly:({used_pct:$d.seven_day.used_percentage,resets_at:$week_reset} + ($x.week // {}))} end) +
      (if $fable_reset == "" then {} else {fable:({used_pct:$d.fable.used_percentage,resets_at:$fable_reset} + ($x.fable // {}))} end)' <<<"$claude_data")
    accounts_lines+="$account_json"$'\n'
  done
  accounts=$(jq -sc '.' <<<"$accounts_lines")
  if [ "$(jq 'length' <<<"$accounts")" -gt 0 ]; then
    if ! jq -e --arg current "$current" 'any(.account == $current)' <<<"$accounts" >/dev/null; then
      current=$(jq -r 'sort_by(.account)[0].account' <<<"$accounts")
    fi
    accounts=$(jq -c --arg current "$current" 'map(.is_current = (.account == $current)) | sort_by(if .is_current then 0 else 1 end, .account)' <<<"$accounts")
    claude=$(jq -cn --argjson accounts "$accounts" --argjson wall "$claude_wall" '
      ($accounts[0]) as $current |
      (first($accounts[] | select(.five_hour.used_pct | type == "number")) // $current) as $five_source |
      {available:true,source:"claudeb-store",current_account:$current.account,accounts:$accounts,
       five_hour:$five_source.five_hour,as_of:$current.as_of,stale_seconds:$current.stale_seconds,last_wall:$wall} +
      (if $current.auth then {auth:$current.auth} else {} end) +
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
        --arg as_of "$(epoch_iso "$mtime")" --argjson as_of_epoch "$mtime" --argjson stale "$stale" '
        {account:"main",is_current:true,
         five_hour:{used_pct:$d.five_hour.used_percentage,resets_at:$five_reset,as_of:$as_of_epoch,stale:($stale > 1800)},
         weekly:{used_pct:$d.seven_day.used_percentage,resets_at:$week_reset,as_of:$as_of_epoch,stale:($stale > 21600)},
         as_of:$as_of,stale_seconds:$stale} as $account |
        {available:true,source:$source,current_account:"main",accounts:[$account],five_hour:$account.five_hour,weekly:$account.weekly,as_of:$as_of,stale_seconds:$stale,last_wall:$wall}')
    fi
  fi
fi

codex_root="$HOME/.codex/sessions"
collect_codex_event() {
  [ -d "$codex_root" ] || return
  local events
  events=$(
    while IFS= read -r entry; do
      path=${entry#* }
      tail -c "$chunk_bytes" "$path" 2>/dev/null | jq -Rc '
        fromjson? |
        select(.payload.rate_limits? | type == "object") |
        select((.payload.rate_limits.primary.used_percent | type) == "number") |
        select((.payload.rate_limits.secondary.used_percent | type) == "number")
      ' 2>/dev/null
    done < <(find "$codex_root" -type f -name 'rollout-*.jsonl' -exec stat -f '%m %N' {} + 2>/dev/null | sort -nr | head -n 5)
  )
  jq -sc "$iso_def"'
    def timestamp_key:
      .timestamp | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.(?<fraction>[0-9]+))?(?<tz>[Zz]|[+-][0-9]{2}:?[0-9]{2})$") as $t |
      [($t.base + $t.tz | iso2epoch), ("0." + ($t.fraction // "0") | tonumber)];
    map(select((try timestamp_key catch null) != null)) |
    if length == 0 then empty else max_by(timestamp_key) end
  ' <<<"$events" 2>/dev/null || true
}

# Live rate limits via the codex app-server RPC (account/rateLimits/read): a usage query,
# not a model call — zero token spend. Rollout tails remain the offline fallback.
codex_cache=${LLM_LIMITS_CODEX_CACHE:-$HOME/.llm-limits-codex.json}
codex_refresh_error=''
refresh_codex_quota() {
  local codex_quota_cmd=${LLM_LIMITS_CODEX_QUOTA_CMD:-$script_dir/codex-quota.py} codex_tmp
  if [ ! -x "$codex_quota_cmd" ]; then
    codex_refresh_error='helper not executable'
    echo "llm-limits.sh: Codex quota helper is not executable: $codex_quota_cmd" >&2
    return 1
  fi
  mkdir -p "$(dirname "$codex_cache")"
  codex_tmp=$(mktemp "${codex_cache}.tmp.XXXXXX") || { codex_refresh_error='cache temp failed'; return 1; }
  if "$codex_quota_cmd" >"$codex_tmp" 2>/dev/null &&
    jq -e '(.rateLimits.primary.usedPercent | type) == "number" and
           (.rateLimits.secondary.usedPercent | type) == "number"' "$codex_tmp" >/dev/null 2>&1; then
    mv -f "$codex_tmp" "$codex_cache"
    codex_refresh_error=''
  else
    codex_refresh_error='live query failed'
    rm -f "$codex_tmp"
    echo "llm-limits.sh: Codex live quota query failed; keeping the last known data" >&2
    return 1
  fi
}

select_codex_event() {
  codex_event=$(collect_codex_event)
  codex_origin=headers
  [ -r "$codex_cache" ] || return 0
  local cache_mtime rollout_epoch cache_event
  cache_mtime=$(int_or_empty "$(file_mtime "$codex_cache" 2>/dev/null || true)")
  [ -n "$cache_mtime" ] || return 0
  rollout_epoch=''
  if [ -n "$codex_event" ]; then
    rollout_epoch=$(int_or_empty "$(jq -nr --arg ts "$(jq -r '.timestamp' <<<"$codex_event")" "$iso_def"'$ts | iso2epoch // empty' 2>/dev/null || true)")
  fi
  if [ -z "$rollout_epoch" ] || [ "$cache_mtime" -ge "$rollout_epoch" ]; then
    cache_event=$(jq -c --arg ts "$(epoch_iso "$cache_mtime")" '
      select((.rateLimits.primary.usedPercent | type) == "number" and
             (.rateLimits.secondary.usedPercent | type) == "number") |
      {timestamp: $ts,
       payload: {rate_limits: {
         primary: {used_percent: .rateLimits.primary.usedPercent,
                   resets_at: (.rateLimits.primary.resetsAt // null)},
         secondary: {used_percent: .rateLimits.secondary.usedPercent,
                     resets_at: (.rateLimits.secondary.resetsAt // null)},
         plan_type: (.rateLimits.planType // null)}}}' "$codex_cache" 2>/dev/null || true)
    if [ -n "$cache_event" ]; then
      codex_event=$cache_event
      codex_origin=usage
    fi
  fi
}

if [ "$refresh" -eq 1 ] && [ "${LLM_LIMITS_CODEX_REFRESH:-1}" != 0 ]; then
  refresh_codex_quota || true
fi
select_codex_event

if [ "$start_windows" -eq 1 ]; then
  if [ "${LLM_LIMITS_CODEX_REFRESH:-1}" = 0 ]; then
    echo "llm-limits.sh: codex window start skipped (LLM_LIMITS_CODEX_REFRESH=0)" >&2
  else
    codex_5h_reset=''
    [ -z "$codex_event" ] || codex_5h_reset=$(int_or_empty "$(jq -r '.payload.rate_limits.primary.resets_at // empty' <<<"$codex_event")")
    if [ -z "$codex_5h_reset" ]; then
      echo "llm-limits.sh: codex 5h window state unknown; not starting a window" >&2
    elif [ "$codex_5h_reset" -le "$now_epoch" ]; then
      codex_cmd=$(command -v codex 2>/dev/null || true)
      if [ -z "$codex_cmd" ]; then
        shopt -s nullglob
        codex_candidates=("$HOME"/.nvm/versions/node/*/bin/codex)
        shopt -u nullglob
        if [ "${#codex_candidates[@]}" -gt 0 ]; then
          while IFS= read -r candidate; do
            if [ -x "$candidate" ]; then codex_cmd=$candidate; break; fi
          done < <(printf '%s\n' "${codex_candidates[@]}" | sort -Vr)
        fi
        if [ -z "$codex_cmd" ]; then
          for candidate in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex; do
            if [ -x "$candidate" ]; then codex_cmd=$candidate; break; fi
          done
        fi
      fi
      if [ -n "$codex_cmd" ]; then
        codex_args=(exec --skip-git-repo-check --sandbox read-only -c 'model_reasoning_effort="low"')
        if [ -n "${LLM_LIMITS_CODEX_MODEL:-}" ]; then
          codex_args+=(-m "$LLM_LIMITS_CODEX_MODEL")
        fi
        codex_args+=('Reply with exactly: ok')
        run_bounded 60 "$codex_cmd" "${codex_args[@]}"
        refresh_codex_quota || true
        select_codex_event
      else
        echo "llm-limits.sh: codex CLI not found; cannot start a codex window" >&2
      fi
    fi
  fi
fi

if [ -n "$codex_event" ]; then
  codex_ts=$(jq -r '.timestamp' <<<"$codex_event")
  codex_epoch=$(int_or_empty "$(jq -nr --arg ts "$codex_ts" "$iso_def"'$ts | iso2epoch // empty' 2>/dev/null || true)")
  if [ -n "$codex_epoch" ]; then
    stale=$((now_epoch - codex_epoch)); [ "$stale" -ge 0 ] || stale=0
    primary_reset=$(int_or_empty "$(jq -r '.payload.rate_limits.primary.resets_at // empty' <<<"$codex_event")")
    secondary_reset=$(int_or_empty "$(jq -r '.payload.rate_limits.secondary.resets_at // empty' <<<"$codex_event")")
    five_reset=''; [ -z "$primary_reset" ] || five_reset=$(epoch_iso "$primary_reset")
    week_reset=''; [ -z "$secondary_reset" ] || week_reset=$(epoch_iso "$secondary_reset")
    codex_source=session-rollout
    [ "$codex_origin" != usage ] || codex_source=codex-app-server
    codex=$(jq -cn --argjson e "$codex_event" --argjson wall "$codex_wall" \
      --arg five_reset "$five_reset" --arg week_reset "$week_reset" \
      --arg as_of "$(epoch_iso "$codex_epoch")" --argjson as_of_epoch "$codex_epoch" \
      --arg origin "$codex_origin" --arg source "$codex_source" --argjson stale "$stale" '
      {available:true,
       five_hour:{used_pct:$e.payload.rate_limits.primary.used_percent,
                  resets_at:(if $five_reset == "" then null else $five_reset end),
                  as_of:$as_of_epoch,origin:$origin,stale:($stale > 1800)},
       weekly:{used_pct:$e.payload.rate_limits.secondary.used_percent,
               resets_at:(if $week_reset == "" then null else $week_reset end),
               as_of:$as_of_epoch,origin:$origin,stale:($stale > 21600)},
       as_of:$as_of,stale_seconds:$stale,source:$source,last_wall:$wall,
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
      --arg as_of "$(epoch_iso "$gemini_mtime")" --argjson as_of_epoch "$gemini_mtime" --argjson stale "$stale" '
      def used($remaining):
        ((1 - $remaining) * 100) |
        (if . < 0 then 0 elif . > 100 then 100 else . end) | round;
      {available:true,source:"agy-local-rpc",group:$d.group,
       five_hour:{used_pct:used($d.five.remainingFraction),resets_at:$d.five.resetTime,
                  as_of:$as_of_epoch,origin:"usage",stale:($stale > 1800)},
       weekly:{used_pct:used($d.week.remainingFraction),resets_at:$d.week.resetTime,
               as_of:$as_of_epoch,origin:"usage",stale:($stale > 21600)},
       as_of:$as_of,stale_seconds:$stale,last_wall:$wall}')
  fi
fi
# Snapshots are passive: a window whose resets_at is already behind us has been reset
# server-side, so its used_pct is stale noise. Flag it (values kept for provenance).
result=$(jq -cn --arg fetched_at "$(local_iso)" --argjson claude "$claude" \
  --argjson codex "$codex" --argjson gemini "$gemini" --argjson now "$now_epoch" \
  --arg claude_error "$claude_refresh_error" --arg codex_error "$codex_refresh_error" --arg gemini_error "$gemini_refresh_error" \
  "$iso_def"'
  def mark:
    if type == "object" and has("used_pct") and has("resets_at")
    then (.resets_at | iso2epoch) as $e |
      if $e != null and $e <= $now then . + {expired:true} else . end
    else . end;
  def vendor_stale:
    [.five_hour?, .weekly?, .fable?] | map(select(type == "object") | .stale == true) | any;
  {schema:1,fetched_at:$fetched_at,vendors:{claude:$claude,codex:$codex,gemini:$gemini}}
  | if $claude_error != "" and .vendors.claude.available then .vendors.claude.refresh_error = $claude_error else . end
  | if $codex_error != "" and .vendors.codex.available then .vendors.codex.refresh_error = $codex_error else . end
  | if $gemini_error != "" and .vendors.gemini.available then .vendors.gemini.refresh_error = $gemini_error else . end
  | .vendors |= with_entries(if .value.available == true then .value += {stale: (.value | vendor_stale)} else . end)
  | walk(mark)')

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
  plain_dim=''
  plain_rst=''
  if [ -t 1 ]; then
    plain_dim=$'\033[2m'
    plain_rst=$'\033[0m'
  fi
  jq -r --arg dim "$plain_dim" --arg rst "$plain_rst" --argjson render_now "$now_epoch" "$stale_def$iso_def$reset_format_def"'
    def age:
      (stale_amount("d"; "h")) as $a |
      if $a == null then "" else " (stale " + $a + ")" end;
    def dimmed($window):
      if ($window.expired == true or $window.stale == true) then $dim + . + $rst else . end;
    def pct($window):
      if $window == null or $window.used_pct == null then "-"
      else ((($window.used_pct | round | tostring) + "%") | dimmed($window)) end;
    def reset($window):
      if $window == null then "—"
      else (($window.resets_at | format_reset($render_now)) | dimmed($window)) end;
    .vendors | to_entries[] |
    if .value.available then
      if .key == "claude" and (.value.accounts | type) == "array" then
        .value.accounts[] | ("claude/" + .account + ": " + pct(.five_hour) + "/" + pct(.weekly) +
         " | resets " + reset(.five_hour) + " / " + reset(.weekly) +
         (if .enabled == false then " | off" else "" end) + (. | age))
      else (.key + ": " + pct(.value.five_hour) + "/" + pct(.value.weekly) +
       " | resets " + reset(.value.five_hour) + " / " + reset(.value.weekly) + (.value|age)) end
    else (.key + ": " + .value.status + (if .value.last_wall then " | last wall " + .value.last_wall else "" end)) end
  ' <<<"$result"
fi

available=$(jq '[.vendors[] | select(.available == true)] | length' <<<"$result")
[ "$available" -gt 0 ] && exit 0
exit 3
