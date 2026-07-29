#!/usr/bin/env bash
set -u

usage() {
  echo "Usage: $0 [--json|--plain|--table] [--sort 5h|weekly|reset] [--no-write] [--refresh [--start-windows] | --refresh-account claude/NAME [--start-windows]|codex/NAME|gemini/NAME] [--gemini-remove]" >&2
}

format=''
write_cache=1
# --refresh is zero token spend (helpers query usage endpoints only); --start-windows is
# the only path that may issue paid model calls, and only for vendors whose 5h window expired.
refresh=0
refresh_account=''
start_windows=0
gemini_remove=0
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
    --refresh-account) shift; [ $# -gt 0 ] || { usage; exit 2; }; refresh=1; refresh_account=$1 ;;
    --start-windows) start_windows=1 ;;
    --gemini-remove) gemini_remove=1 ;;
    *) usage; exit 2 ;;
  esac
  shift
done
if [ "$start_windows" -eq 1 ] && [ "$refresh" -eq 0 ]; then
  usage
  exit 2
fi
case "$refresh_account" in
  ''|gemini|gemini/?*|claude/?*|codex/?*) ;;
  *) usage; exit 2 ;;
esac
if [ -n "$refresh_account" ] && [ "$start_windows" -eq 1 ]; then
  case "$refresh_account" in
    claude/?*) ;;
    *) usage; exit 2 ;;
  esac
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

cache=${LLM_LIMITS_CACHE:-$HOME/.llm-limits.json}
previous_cache='{}'
if [ -r "$cache" ]; then
  previous_cache=$(jq -c 'select(.schema == 1 and (.vendors | type) == "object")' "$cache" 2>/dev/null || true)
  [ -n "$previous_cache" ] || previous_cache='{}'
fi

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

now_epoch=${LLM_LIMITS_NOW:-$(date +%s)}
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

format_reset_time() {
  local epoch=$1
  if date -r "$epoch" '+%H:%M' >/dev/null 2>&1; then
    date -r "$epoch" '+%H:%M'
  else
    date -d "@$epoch" '+%H:%M' 2>/dev/null || printf 'unknown'
  fi
}

token_freeze_active_at() {
  local dir=$1 f until now
  f="$dir/token-freeze"
  [ -f "$f" ] || return 1
  until=$(jq -r '.until // empty' "$f" 2>/dev/null) || until=''
  if [[ "$until" =~ ^[0-9]+$ ]]; then
    now=${now_epoch:-$(date +%s)}
    [ "$until" -gt "$now" ] || return 1
  fi
  return 0
}

claude_stale_cause() {
  local attempts_file=$1 name=$2 auth=${3:-ok} raw kind value
  raw=$(jq -r --arg n "$name" --arg auth "$auth" '
    (.[$n] // null) as $e |
    if $e == null then ["cause", (if $auth == "failed" then "stale data kept" else "usage weather" end)] | @tsv
    elif ($e.outcome // "") == "429" then
      (((($e.strikes // 0) | if type != "number" or . < 1 then 1 else floor end)) as $s |
       (900 * (2 | pow(.; $s - 1)) | if . > 14400 then 14400 else . end) as $c |
       ([((if ($e.attempted_at | type) == "number" then $e.attempted_at else 0 end) + $c),
         (if ($e.retry_after_until | type) == "number" then $e.retry_after_until else 0 end)] | max) as $until |
       ["429", $until] | @tsv)
    elif ($e.outcome // "") == "weather" then ["cause", "network weather"] | @tsv
    elif (($e.warm_outcome // "") == "warm-failed" or ($e.outcome // "") == "warm-failed")
         and ($e.warm_cause // "") != "" then ["cause", $e.warm_cause] | @tsv
    else ["cause", "stale data kept"] | @tsv end' "$attempts_file" 2>/dev/null) || raw=$'cause\tstale data kept'
  IFS=$'\t' read -r kind value <<<"$raw"
  # An auth-shaped cause (logged out / needs re-login) is actionable and must
  # surface even under a freeze — the account is genuinely dead, not just paused.
  case "$value" in
    *relogin*|*re-login*|*"log in"*|*"logged out"*|*"login needed"*)
      printf '%s' "$value"; return ;;
  esac
  if token_freeze_active_at "$(dirname "$attempts_file")"; then
    # Freeze outranks a stale pre-freeze 429 (or generic weather/stale) cause:
    # the endpoint is frozen this run, so nothing is really "rate-limited".
    printf 'auto-refresh frozen (experiment) — enter the account to refresh'
  elif [ "$kind" = 429 ]; then
    if [ "$value" -le "${now_epoch:-$(date +%s)}" ] 2>/dev/null; then
      printf 'token rate-limited, retrying'
    else
      printf 'token rate-limited, retry ~%s' "$(format_reset_time "$value")"
    fi
  else
    printf '%s' "${value:-stale data kept}"
  fi
}

file_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

claude_subscription_type() {
  local account=$1 profile hash service credentials subscription
  command -v security >/dev/null 2>&1 || return 0
  profile="${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}/$account"
  hash=$(printf '%s' "$profile" | shasum -a 256 | awk '{print substr($1, 1, 8)}')
  service="Claude Code-credentials-$hash"
  credentials=$(security find-generic-password -s "$service" -w 2>/dev/null) || return 0
  subscription=$(printf '%s' "$credentials" | jq -r '
    .claudeAiOauth.subscriptionType // empty |
    select(type == "string") | ascii_downcase' 2>/dev/null || true)
  credentials=''
  printf '%s' "$subscription"
}

# Snapshots may carry null where an epoch is expected; a literal "null" inside $(( ))
# aborts the whole run under set -u.
int_or_empty() {
  case "$1" in ''|*[!0-9]*) : ;; *) printf '%s' "$1" ;; esac
}

reset_iso_or_empty() {
  local epoch
  epoch=$(int_or_empty "$1")
  [ -z "$epoch" ] || epoch_iso "$epoch"
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

# Like run_bounded, but for the claude refresh/heal/start-windows path specifically:
# a bound expiring must be reported as an explicit "timed out" cause (never a silent
# kill folded into a clean exit), and claudeb's own diagnostic stderr (skip reasons,
# backoff notices) must reach the invoking terminal/log instead of being discarded.
run_bounded_claude() {
  local seconds=$1 phase=$2 pid watchdog_pid timeout_cmd rc errfile stderr_text
  shift 2
  errfile=$(mktemp "${TMPDIR:-/tmp}/llm-limits-claude-err.XXXXXX") || errfile=/dev/null
  timeout_cmd=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$seconds" "$@" >/dev/null 2>"$errfile"
    rc=$?
  else
    "$@" >/dev/null 2>"$errfile" &
    pid=$!
    (sleep "$seconds"; kill "$pid" 2>/dev/null || true) &
    watchdog_pid=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  stderr_text=$(cat "$errfile" 2>/dev/null || true)
  rm -f "$errfile"
  [ -z "$stderr_text" ] || printf '%s\n' "$stderr_text" >&2
  if [ "$rc" -eq 124 ]; then
    claude_refresh_error="timed out during $phase (${seconds}s)"
  fi
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

age_def='def compact_age($now):
  (.as_of | iso2epoch) as $asof |
  (if $asof != null then ([$now - $asof, 0] | max)
   elif (.stale_seconds | type) == "number" then .stale_seconds
   else null end) as $seconds |
  if $seconds == null then "-"
  elif $seconds < 60 then "0m"
  elif $seconds < 3600 then (($seconds / 60 | floor | tostring) + "m")
  elif $seconds < 86400 then
    (($seconds / 3600 | floor | tostring) + "h" +
     (if (($seconds % 3600) / 60 | floor) == 0 then ""
      else ((($seconds % 3600) / 60 | floor | tostring) + "m") end))
  else
    (($seconds / 86400 | floor | tostring) + "d" +
     (if (($seconds % 86400) / 3600 | floor) == 0 then ""
      else ((($seconds % 86400) / 3600 | floor | tostring) + "h") end))
  end;'

reset_format_def='def format_reset($now):
  . as $iso | ($iso | iso2epoch) as $epoch |
  if $iso == null or $iso == "" then "-"
  elif $epoch == null then $iso
  elif ($epoch - $now) < 604800 then
    (if ($epoch | strflocaltime("%Y-%m-%d")) != ($now | strflocaltime("%Y-%m-%d"))
     then (["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$epoch | strflocaltime("%w") | tonumber]
           + " " + ($epoch | strflocaltime("%H:%M")))
     else ($epoch | strflocaltime("%H:%M")) end)
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
  local table_color=0
  if [ -t 1 ]; then
    table_color=1
  fi
  # Sentinels (-1 / 9999999999) push rows with missing values last for every sort direction.
  local rows
  rows=$(jq -r --argjson render_now "$now_epoch" "$iso_def$age_def$reset_format_def"'
    def pct(v): if v == null then "-" else ((v | round | tostring) + "%") end;
    def marked_pct($window):
      pct($window.used_pct) +
      (if $window.stale == true then "~" else "" end) +
      (if $window.expired == true then "!" else "" end);
    def rotation:
      if .enabled == false then "off"
      elif (.five_hour.effective_pct // 0) >= 100 then "limit-5h"
      elif (.weekly.effective_pct // 0) >= 100 then "limit-weekly"
      elif (.fable.effective_pct // 0) >= 100 then "fb:limit-fable"
      else "-" end;
    def account_status:
      if .auth_needed == true or
         ((.auth.status? | type) == "string" and .auth.status != "ok")
      then "login needed" else "-" end;
    def row:
      (.five.expired == true) as $x5 | (.week.expired == true) as $xw | (.fable.expired == true) as $xf |
      (if ($x5 or .five.stale == true) then 1 else 0 end) as $d5 |
      (if ($xw or .week.stale == true) then 1 else 0 end) as $dw |
      (if ($xf or .fable.stale == true) then 1 else 0 end) as $df |
      .five.used_pct as $p5 | .week.used_pct as $pw | .fable.used_pct as $pf |
      (.five.resets_at | iso2epoch) as $e5 |
      (.week.resets_at | iso2epoch) as $ew |
      (.fable.resets_at | iso2epoch) as $ef |
      (if $x5 then null else $e5 end) as $s5 |
      (if $xw then null else $ew end) as $sw |
      (if $xf then null else $ef end) as $sf |
      [(if $x5 then 0 else ($p5 // -1) end), (if $xw then 0 else ($pw // -1) end),
       ($s5 // 9999999999), ($sw // 9999999999),
       ([($s5 // 9999999999), ($sw // 9999999999), ($sf // 9999999999)] | min),
       ($pf // -1), $d5, $dw, $df,
       .src, marked_pct(.five), marked_pct(.week), marked_pct(.fable),
       (.five.resets_at | format_reset($render_now)),
       (.week.resets_at | format_reset($render_now)),
       (.fable.resets_at | format_reset($render_now)),
       .age, .rot, .credits, .status] | @tsv;
    .vendors as $v |
    [
      (if $v.claude.available and (($v.claude.accounts | type) == "array") then
         ($v.claude.accounts[]
          | {src: ("claude/" + .account + (if .is_current then "*" else "" end)),
             five: .five_hour, week: .weekly, fable: .fable,
             age: compact_age($render_now),
             rot: rotation, credits: "-", status: account_status})
       else {src: "claude", five: null, week: null, fable:null, age:"-", rot:"-", credits:"-", status:($v.claude.status // "-")} end),
      (("codex", "gemini") as $k | $v[$k]
       | select(.removed != true)
       | if ((.accounts | type) == "array") and
            (($k == "codex" and any(.accounts[]; .auth_needed == true)) or (.accounts | length) > 1) then
           (.accounts[] | select(.removed != true)
              | {src: ($k + "/" + .account + (if .is_current then "*" else "" end)),
                 five: .five_hour, week: .weekly, fable:null,
                 age: compact_age($render_now), rot: rotation,
                 credits:(if $k == "codex" and (.reset_credits | type) == "number" then "↻" + (.reset_credits | tostring) else "-" end),
                 status:account_status})
         elif .available then
           {src: $k, five: .five_hour, week: .weekly, fable:null,
            age: compact_age($render_now), rot: ((.accounts[0] // .) | rotation),
            credits:(if $k == "codex" and (.reset_credits | type) == "number" then "↻" + (.reset_credits | tostring) else "-" end),
            status:"-"}
           else
           {src: $k, five: null, week: null, fable:null, age:"-", rot:"-", credits:"-",
            status:(if .auth_needed == true then "login needed" else (.status // "-") end)}
         end)
    ] | .[] | row
  ' <<<"$result")

  local sorted
  if [ -n "$sort_flags" ]; then
    sorted=$(sort -s -t $'\t' $sort_flags <<<"$rows")
  else
    sorted=$rows
  fi

  local k5 kw e5 ew kr kf dim5 dimw dimf src p5 pw pf r5 rw rf age rot credits status
  local w_src=6 w_p5=3 w_pw=3 w_pf=3 w_r5=8 w_rw=8 w_rf=8 w_age=3 w_rot=3 w_cr=2
  while IFS=$'\t' read -r k5 kw e5 ew kr kf dim5 dimw dimf src p5 pw pf r5 rw rf age rot credits status; do
    [ -n "$src" ] || continue
    [ "${#src}" -gt "$w_src" ] && w_src=${#src}
    [ "${#p5}" -gt "$w_p5" ] && w_p5=${#p5}
    [ "${#pw}" -gt "$w_pw" ] && w_pw=${#pw}
    [ "${#pf}" -gt "$w_pf" ] && w_pf=${#pf}
    [ "${#r5}" -gt "$w_r5" ] && w_r5=${#r5}
    [ "${#rw}" -gt "$w_rw" ] && w_rw=${#rw}
    [ "${#rf}" -gt "$w_rf" ] && w_rf=${#rf}
    [ "${#age}" -gt "$w_age" ] && w_age=${#age}
    [ "${#rot}" -gt "$w_rot" ] && w_rot=${#rot}
    [ "${#credits}" -gt "$w_cr" ] && w_cr=${#credits}
  done <<<"$sorted"

  printf '%-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %s\n' \
    "$w_src" SOURCE "$w_p5" "5H%" "$w_pw" "WK%" "$w_pf" "FB%" \
    "$w_r5" "5H RESET" "$w_rw" "WK RESET" "$w_rf" "FB RESET" \
    "$w_age" AGE "$w_rot" ROT "$w_cr" CR STATUS
  while IFS=$'\t' read -r k5 kw e5 ew kr kf dim5 dimw dimf src p5 pw pf r5 rw rf age rot credits status; do
    [ -n "$src" ] || continue
    printf '%-*s  ' "$w_src" "$src"
    pct_cell "$p5" "$w_p5" "$table_color" "$k5" "$dim5"; printf '  '
    pct_cell "$pw" "$w_pw" "$table_color" "$kw" "$dimw"; printf '  '
    pct_cell "$pf" "$w_pf" "$table_color" "$kf" "$dimf"; printf '  '
    dim_cell "$r5" "$w_r5" "$table_color" "$dim5"; printf '  '
    dim_cell "$rw" "$w_rw" "$table_color" "$dimw"; printf '  '
    dim_cell "$rf" "$w_rf" "$table_color" "$dimf"; printf '  '
    printf '%-*s  ' "$w_age" "$age"
    printf '%-*s  %-*s  %s\n' "$w_rot" "$rot" "$w_cr" "$credits" "$status"
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

gemini_base_home=$HOME
gemini_profiles_dir="${GEMINIB_PROFILES_DIR:-$HOME/.gemini-profiles}"
gemini_accounts_cache_dir="${LLM_LIMITS_GEMINI_ACCOUNTS_DIR:-$HOME/.llm-limits-gemini}"
gemini_main_cache=${LLM_LIMITS_GEMINI_CACHE:-$HOME/.llm-limits-gemini.json}
gemini_legacy_removed="${LLM_LIMITS_GEMINI_REMOVED:-${gemini_main_cache}.removed}"
agy_bin=${AGY_BIN:-$HOME/.local/bin/agy}
. "$script_dir/share/gemini-accounts.sh"
. "$script_dir/share/worker-pool.sh"
. "$script_dir/share/experiments.sh"

codex_pool_dir="${CODEXB_PROFILES_DIR:-$HOME/.codex-profiles}/.codexb"
gemini_pool_dir="$gemini_profiles_dir/.geminib"

gemini_account_cache() {
  if [ "$1" = main ]; then printf '%s\n' "$gemini_main_cache"
  else printf '%s/%s.json\n' "$gemini_accounts_cache_dir" "$1"
  fi
}

gemini_account_marker() {
  if [ "$1" = main ]; then printf '%s\n' "$gemini_legacy_removed"
  else printf '%s/%s.json.removed\n' "$gemini_accounts_cache_dir" "$1"
  fi
}

gemini_refresh_accounts_list=$(gemini_account_names)
gemini_accounts_list=$(
  {
    printf '%s\n' "$gemini_refresh_accounts_list"
    if [ -d "$gemini_accounts_cache_dir" ]; then
      for gemini_removed_path in "$gemini_accounts_cache_dir"/*.json.removed; do
        [ -e "$gemini_removed_path" ] || continue
        basename "$gemini_removed_path" .json.removed
      done
    fi
  } | awk 'NF && !seen[$0]++'
)
gemini_just_removed_marker=''
if [ "$gemini_remove" -eq 1 ]; then
  mkdir -p "$(dirname "$gemini_legacy_removed")" 2>/dev/null || true
  # A swallowed write turns removal into a silent no-op; surface it and fail.
  if : > "$gemini_legacy_removed" 2>/dev/null; then
    gemini_just_removed_marker="$gemini_legacy_removed"
  else
    echo "llm-limits.sh: failed to write gemini removed-marker: $gemini_legacy_removed" >&2
    exit 1
  fi
fi
gemini_refresh_error=''
gemini_refresh_attempted=0
gemini_refresh_succeeded=0
gemini_refresh_records='[]'
gemini_refresh_results_dir=''
gemini_refresh_result_index=0
gemini_refresh_result_file=''

record_gemini_refresh() {
  jq -cn --arg account "$2" --argjson attempted "$3" --argjson succeeded "$4" --arg error "$5" \
    '{account:$account,attempted:$attempted,succeeded:$succeeded,error:$error}' >"$1"
}

new_gemini_refresh_result() {
  if [ -z "$gemini_refresh_results_dir" ]; then
    gemini_refresh_results_dir=$(mktemp -d "${TMPDIR:-/tmp}/llm-limits-gemini.XXXXXX") || {
      echo "llm-limits.sh: Gemini refresh result directory creation failed" >&2
      exit 5
    }
  fi
  gemini_refresh_result_index=$((gemini_refresh_result_index + 1))
  printf -v gemini_refresh_result_file '%s/%08d.json' \
    "$gemini_refresh_results_dir" "$gemini_refresh_result_index"
}

cleanup_gemini_refresh_results() {
  [ -z "$gemini_refresh_results_dir" ] || rm -rf "$gemini_refresh_results_dir"
}
trap cleanup_gemini_refresh_results EXIT

refresh_gemini_quota() {
  local account=$1 result_file=$2 gemini_cmd=${LLM_LIMITS_GEMINI_CMD:-$script_dir/agy-quota.py}
  local gemini_cache gemini_home gemini_tmp gemini_err detail auth_detail rc error=''
  gemini_cache=$(gemini_account_cache "$account")
  gemini_home=$(gemini_account_home "$account")
  gemini_ensure_keychain "$gemini_home"
  if [ ! -x "$gemini_cmd" ]; then
    record_gemini_refresh "$result_file" "$account" true false 'helper not executable'
    echo "llm-limits.sh: Gemini quota helper is not executable: $gemini_cmd" >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "$gemini_cache")"; then
    record_gemini_refresh "$result_file" "$account" true false 'cache directory failed'
    return 1
  fi
  gemini_tmp=$(mktemp "${gemini_cache}.tmp.XXXXXX") || {
    record_gemini_refresh "$result_file" "$account" true false 'cache temp failed'
    return 1
  }
  gemini_err=$(mktemp "${gemini_cache}.err.XXXXXX") || {
    rm -f "$gemini_tmp"
    record_gemini_refresh "$result_file" "$account" true false 'cache temp failed'
    return 1
  }
  rc=0
  env HOME="$gemini_home" AGY_BIN="$agy_bin" AGY_WORKDIR="${AGY_WORKDIR:-$script_dir}" \
    "$gemini_cmd" >"$gemini_tmp" 2>"$gemini_err" || rc=$?
  if [ "$rc" -eq 2 ] && jq -e '.auth_needed == true' "$gemini_tmp" >/dev/null 2>&1; then
    auth_detail=$(jq -r '.detail // empty' "$gemini_tmp" 2>/dev/null || true)
    if [ -r "$gemini_cache" ] && jq -e '(.groups | type) == "array"' "$gemini_cache" >/dev/null 2>&1 &&
      jq -e --arg detail "$auth_detail" '. + {auth_needed:true, detail:$detail}' "$gemini_cache" >"$gemini_tmp.auth" 2>/dev/null; then
      touch -r "$gemini_cache" "$gemini_tmp.auth" 2>/dev/null || true
      mv -f "$gemini_tmp.auth" "$gemini_tmp"
    fi
    if mv -f "$gemini_tmp" "$gemini_cache"; then
      rm -f "$gemini_err"
      if [ -n "$auth_detail" ]; then
        error="login needed ($auth_detail)"
      else
        error='login needed'
      fi
      record_gemini_refresh "$result_file" "$account" true true "$error"
    else
      rm -f "$gemini_tmp" "$gemini_tmp.auth" "$gemini_err"
      record_gemini_refresh "$result_file" "$account" true false 'cache replace failed'
      return 1
    fi
  elif [ "$rc" -eq 0 ] &&
    jq -e '
      (.groups | type) == "array" and
      any(.groups[]?;
        ((.displayName // "") | ascii_downcase | contains("gemini")) and
        any(.buckets[]?; .window == "5h" and (.remainingFraction | type) == "number") and
        any(.buckets[]?; .window == "weekly" and (.remainingFraction | type) == "number"))
    ' "$gemini_tmp" >/dev/null 2>&1; then
    if mv -f "$gemini_tmp" "$gemini_cache"; then
      rm -f "$gemini_err"
      record_gemini_refresh "$result_file" "$account" true true ''
    else
      rm -f "$gemini_tmp" "$gemini_err"
      record_gemini_refresh "$result_file" "$account" true false 'cache replace failed'
      return 1
    fi
  else
    detail=$(jq -r '.error // empty' "$gemini_err" 2>/dev/null || true)
    [ -n "$detail" ] || detail='live query failed'
    rm -f "$gemini_tmp" "$gemini_err"
    record_gemini_refresh "$result_file" "$account" true false "$detail"
    printf 'llm-limits.sh: Gemini/%s refresh failed: %s\n' "$account" "$detail" >&2
    return 1
  fi
}

gemini_refresh_target=''
case "$refresh_account" in
  gemini) gemini_refresh_target=main ;;
  gemini/*) gemini_refresh_target=${refresh_account#gemini/} ;;
esac
if [ -n "$gemini_refresh_target" ] && ! grep -qxF "$gemini_refresh_target" <<<"$gemini_refresh_accounts_list"; then
  printf 'llm-limits.sh: unknown Gemini account: %s\n' "$gemini_refresh_target" >&2
  exit 2
fi
if [ "$refresh" -eq 1 ] && { [ -z "$refresh_account" ] || [ -n "$gemini_refresh_target" ]; }; then
  if [ "${LLM_LIMITS_GEMINI_REFRESH:-1}" != 0 ]; then
    gemini_refresh_pids=()
    while IFS= read -r gemini_account; do
      [ -z "$gemini_refresh_target" ] || [ "$gemini_account" = "$gemini_refresh_target" ] || continue
      new_gemini_refresh_result
      refresh_gemini_quota "$gemini_account" "$gemini_refresh_result_file" &
      gemini_refresh_pids[${#gemini_refresh_pids[@]}]=$!
    done <<<"$gemini_refresh_accounts_list"
    for gemini_refresh_pid in "${gemini_refresh_pids[@]}"; do
      wait "$gemini_refresh_pid" || true
    done
  elif [ -n "$gemini_refresh_target" ]; then
    new_gemini_refresh_result
    record_gemini_refresh "$gemini_refresh_result_file" "$gemini_refresh_target" true false 'refresh disabled'
    printf 'llm-limits.sh: Gemini refresh is disabled\n' >&2
  fi
fi
if [ "$start_windows" -eq 1 ] && [ -z "$refresh_account" ]; then
  if [ "${LLM_LIMITS_GEMINI_REFRESH:-1}" = 0 ]; then
    echo "llm-limits.sh: gemini window start skipped (LLM_LIMITS_GEMINI_REFRESH=0)" >&2
  else
    while IFS= read -r gemini_account; do
      gemini_cache=$(gemini_account_cache "$gemini_account")
      gemini_home=$(gemini_account_home "$gemini_account")
      gemini_ensure_keychain "$gemini_home"
      gemini_5h_reset=''
      if [ -r "$gemini_cache" ]; then
        gemini_5h_reset=$(int_or_empty "$(jq -r "$iso_def"'
          [.groups[]? | select((.displayName // "") | ascii_downcase | contains("gemini"))][0] as $g |
          [$g.buckets[]? | select(.window == "5h")][0].resetTime | iso2epoch // empty
        ' "$gemini_cache" 2>/dev/null || true)")
      fi
      if [ -z "$gemini_5h_reset" ]; then
        printf 'llm-limits.sh: gemini/%s 5h window state unknown; not starting a window\n' "$gemini_account" >&2
      elif [ "$gemini_5h_reset" -le "$now_epoch" ]; then
        if [ -x "$agy_bin" ]; then
          (export HOME="$gemini_home"; cd "${AGY_WORKDIR:-$script_dir}" &&
            run_bounded 120 "$agy_bin" --print 'Reply with exactly: ok')
          new_gemini_refresh_result
          refresh_gemini_quota "$gemini_account" "$gemini_refresh_result_file" || true
        else
          printf 'llm-limits.sh: agy not found; cannot start gemini/%s window\n' "$gemini_account" >&2
        fi
      fi
    done <<<"$gemini_refresh_accounts_list"
  fi
fi
if [ -n "$gemini_refresh_results_dir" ] &&
   find "$gemini_refresh_results_dir" -name '*.json' -type f -print -quit | grep -q .; then
  gemini_refresh_records=$(jq -sc '.' "$gemini_refresh_results_dir"/*.json)
  if jq -e 'any(.[]; .attempted == true)' >/dev/null <<<"$gemini_refresh_records"; then
    gemini_refresh_attempted=1
  fi
  if jq -e 'any(.[]; .succeeded == true)' >/dev/null <<<"$gemini_refresh_records"; then
    gemini_refresh_succeeded=1
  fi
fi

claude='{"available":false,"status":"no rate-limit snapshot","source":"none","last_wall":null}'
claudeb_root="${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}"
claude_refresh_error=''
claude_refresh_attempted=0
claude_refresh_succeeded=0
claude_refresh_run_start=0
claude_refresh_target=''
case "$refresh_account" in claude/*) claude_refresh_target=${refresh_account#claude/} ;; esac
# Action-path bounds only: the detached collect-on-open path has no --refresh, so these
# never constrain it. Generous defaults favor a complete, honest refresh.
claude_sw_timeout=${LLM_LIMITS_CLAUDE_SW_TIMEOUT:-1200}
claude_refresh_timeout=${LLM_LIMITS_CLAUDE_REFRESH_TIMEOUT:-300}
if [ "$refresh" -eq 1 ] && { [ -z "$refresh_account" ] || [ -n "$claude_refresh_target" ]; }; then
  if [ -d "$claudeb_root/limits" ]; then
    claude_refresh_attempted=1
    claude_refresh_run_start=$(date +%s)
    claudeb_cmd=$(command -v "${LLM_LIMITS_CLAUDEB_CMD:-claudeb}" 2>/dev/null || true)
    if [ -n "$claudeb_cmd" ]; then
      if [ -n "$claude_refresh_target" ]; then
        warm_args=(warm)
        if [ "$start_windows" -eq 1 ]; then
          # Feature-detect; the trailing ] keeps old builds' [--start-windows] from matching.
          if "$claudeb_cmd" --help 2>/dev/null | grep -q -- '--start-window]'; then
            warm_args+=(--start-window)
          else
            echo "llm-limits.sh: claudeb warm lacks --start-window; free account refresh only" >&2
          fi
        fi
        if run_bounded_claude "$claude_refresh_timeout" "account refresh ($claude_refresh_target)" \
            "$claudeb_cmd" "${warm_args[@]}" "$claude_refresh_target"; then
          claude_refresh_succeeded=1
        else
          [ -n "$claude_refresh_error" ] || claude_refresh_error=$(claude_stale_cause "$claudeb_root/oauth-attempts.json" "$claude_refresh_target" ok)
          claude_refresh_error="$claude_refresh_target: not refreshed ($claude_refresh_error)"
        fi
      elif [ "$start_windows" -eq 1 ]; then
        # Feature-detect: older claudeb builds predate --start-windows and would die on it.
        if "$claudeb_cmd" --help 2>/dev/null | grep -q -- '--start-windows'; then
          if run_bounded_claude "$claude_sw_timeout" 'refresh + start-windows + heal' "$claudeb_cmd" --refresh --start-windows --heal; then
            claude_refresh_succeeded=1
          else
            [ -n "$claude_refresh_error" ] || claude_refresh_error='probe failed'
          fi
        else
          echo "llm-limits.sh: claudeb lacks --start-windows; claude windows not started (free refresh only)" >&2
          if run_bounded_claude "$claude_refresh_timeout" 'free refresh (no start-windows support)' "$claudeb_cmd" accounts --no-spend; then
            claude_refresh_succeeded=1
          else
            [ -n "$claude_refresh_error" ] || claude_refresh_error='probe failed'
          fi
        fi
      else
        if run_bounded_claude "$claude_refresh_timeout" 'free refresh + heal' "$claudeb_cmd" accounts --no-spend --heal; then
          claude_refresh_succeeded=1
        else
          [ -n "$claude_refresh_error" ] || claude_refresh_error='probe failed'
        fi
      fi
    else
      claude_refresh_error='claudeb not found'
      echo "llm-limits.sh: claudeb not found; cannot refresh claude accounts" >&2
    fi
  elif [ -n "$claude_refresh_target" ]; then
    claude_refresh_attempted=1
    claude_refresh_error='no claudeb store'
    echo "llm-limits.sh: no claudeb store; cannot refresh claude account" >&2
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
    [ "$account" != main ] && [ "$account" != - ] || continue
    plan_type=$(claude_subscription_type "$account")
    enabled=true
    if worker_pool_is_disabled "$claudeb_root" "$account"; then enabled=false; fi
    # Snapshots without a valid five_hour bucket (e.g. auth-only after a failed probe) must
    # stay visible as unknown values, never vanish from the account list.
    # Header-origin week = never measured (shared-invariants n): render unknown, not a number.
    claude_data=$(jq -c 'select(type == "object")
      | if (.seven_day.origin? == "headers") then del(.seven_day) else . end' "$claude_file" 2>/dev/null || true)
    mtime=$(file_mtime "$claude_file" || true)
    [ -n "$claude_data" ] && [ -n "$mtime" ] || continue
    has_five=0
    if jq -e '(.five_hour.used_percentage | type) == "number"' <<<"$claude_data" >/dev/null; then has_five=1; fi
    stale=$((now_epoch - mtime)); [ "$stale" -ge 0 ] || stale=0
    five_reset=''
    five_reset_epoch=$(int_or_empty "$(jq -r '.five_hour.resets_at // empty' <<<"$claude_data")")
    [ -z "$five_reset_epoch" ] || five_reset=$(epoch_iso "$five_reset_epoch")
    has_week=0
    week_reset=''
    if jq -e '(.seven_day.used_percentage | type) == "number"' <<<"$claude_data" >/dev/null; then has_week=1; fi
    week_reset_epoch=$(int_or_empty "$(jq -r '.seven_day.resets_at // empty' <<<"$claude_data")")
    [ -z "$week_reset_epoch" ] || week_reset=$(epoch_iso "$week_reset_epoch")
    has_fable=0
    fable_reset=''
    if jq -e '(.fable.used_percentage | type) == "number"' <<<"$claude_data" >/dev/null; then has_fable=1; fi
    fable_reset_epoch=$(int_or_empty "$(jq -r '.fable.resets_at // empty' <<<"$claude_data")")
    [ -z "$fable_reset_epoch" ] || fable_reset=$(epoch_iso "$fable_reset_epoch")
    account_json=$(jq -cn --argjson d "$claude_data" --arg account "$account" --argjson enabled "$enabled" \
      --argjson has_five "$has_five" --argjson has_week "$has_week" --argjson has_fable "$has_fable" \
      --arg five_reset "$five_reset" --argjson mtime "$mtime" --argjson now "$now_epoch" \
      --arg week_reset "$week_reset" --arg fable_reset "$fable_reset" \
      --argjson stale "$stale" --arg plan_type "$plan_type" '
      (($d.auth | type) == "object" and $d.auth.status == "expired") as $expired |
      ($enabled and (($d.auth | type) == "object" and $d.auth.status == "ok")) as $general_usable |
      (($d.auth | type) == "object" and
       ($d.auth.status == "expired" or $d.auth.status == "failed")) as $auth_needed |
      (if ($d.five_hour.as_of | type) == "number" then $d.five_hour.as_of else $mtime end) as $account_asof |
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
       five_hour:(if $has_five == 0
                  then {used_pct:null,resets_at:null,as_of:$mtime,stale:true}
                  else {used_pct:$d.five_hour.used_percentage,
                        resets_at:(if $five_reset == "" then null else $five_reset end)} + ($x.five // {}) end),
       as_of:($account_asof | todateiso8601),stale_seconds:($now - $account_asof)} +
      (if $plan_type == "" then {} else {plan_type:$plan_type} end) +
      {blocked:($general_usable | not)} +
      (if $d.auth_needed == true or $auth_needed then {auth_needed:true} else {} end) +
      (if $x.auth then {auth:$x.auth} else {} end) +
      (if $has_week == 0 then {} else {weekly:({used_pct:$d.seven_day.used_percentage,
        resets_at:(if $week_reset == "" then null else $week_reset end)} + ($x.week // {}))} end) +
      (if $has_fable == 0 then {} else {fable:({used_pct:$d.fable.used_percentage,
        resets_at:(if $fable_reset == "" then null else $fable_reset end)} + ($x.fable // {}))} end) +
      {rotation:{usable:{general:$general_usable,
                         fable:($general_usable and
                                $has_fable == 1 and $plan_type != "pro")}}}' <<<"$claude_data")
    accounts_lines+="$account_json"$'\n'
  done
  accounts=$(jq -sc '.' <<<"$accounts_lines")
  if [ "$(jq 'length' <<<"$accounts")" -gt 0 ]; then
    if ! jq -e --arg current "$current" 'any(.account == $current)' <<<"$accounts" >/dev/null; then
      current=$(jq -r 'sort_by(.account)[0].account' <<<"$accounts")
    fi
    accounts=$(jq -c --arg current "$current" '
      map(.is_current = (.account == $current)) |
      sort_by(if .is_current then 0 else 1 end, .account)
    ' <<<"$accounts")
    claude_bundle=$(jq -cn --argjson accounts "$accounts" --argjson wall "$claude_wall" '
      ($accounts[0]) as $current |
      (first($accounts[] | select(.five_hour.used_pct | type == "number")) // $current) as $five_source |
      ({available:true,source:"claudeb-store",current_account:$current.account,accounts:$accounts,
       five_hour:$five_source.five_hour,as_of:$current.as_of,stale_seconds:$current.stale_seconds,last_wall:$wall} +
      (if $current.auth then {auth:$current.auth} else {} end) +
      (if $current.weekly then {weekly:$current.weekly} else {} end) +
      (if $current.fable then {fable:$current.fable} else {} end)) as $claude |
      {claude:$claude,auth_failures:([$accounts[] | select(.auth.status? == "expired") |
        (.account + " auth" + (if (.auth.cause? // "") == "" then "" else " (" + .auth.cause + ")" end))] | join("; "))}')
    claude=$(jq -c .claude <<<"$claude_bundle")
    auth_failures=$(jq -r .auth_failures <<<"$claude_bundle")
    if [ "$claude_refresh_attempted" -eq 1 ] && [ -n "$auth_failures" ]; then
      if [ -n "$claude_refresh_error" ]; then
        claude_refresh_error="$claude_refresh_error; $auth_failures"
      else
        claude_refresh_error="$auth_failures"
      fi
    fi
    # A refresh can claim success while weather kept an account's old snapshot; surface
    # each such enabled account as a vendor-level cause (recomputed each run → self-clears).
    if [ "$claude_refresh_attempted" -eq 1 ] && [ "$claude_refresh_succeeded" -eq 1 ] && [ -z "$claude_refresh_target" ]; then
      claude_oauth_attempts="$claudeb_root/oauth-attempts.json"
      while IFS= read -r stale_account; do
        [ -n "$stale_account" ] || continue
        stale_auth=$(jq -r --arg n "$stale_account" '(.[] | select(.account == $n) | .auth.status) // "ok"' <<<"$accounts" 2>/dev/null) || stale_auth=ok
        stale_cause=$(claude_stale_cause "$claude_oauth_attempts" "$stale_account" "$stale_auth")
        [ -n "$stale_cause" ] || stale_cause='stale data kept'
        stale_entry="$stale_account: not refreshed ($stale_cause)"
        if [ -n "$claude_refresh_error" ]; then
          claude_refresh_error="$claude_refresh_error; $stale_entry"
        else
          claude_refresh_error="$stale_entry"
        fi
      done < <(jq -r --argjson rs "$claude_refresh_run_start" '
        .[] | select(.enabled == true) | select((.auth.status // "") != "expired")
        | select(.auth_needed != true)
        | select((.five_hour.as_of | type) == "number" and .five_hour.as_of < $rs)
        | .account' <<<"$accounts")
    fi
  fi
else
  claude_last="$HOME/.claude/statusline-last.json"
  claude_rl="$HOME/.claude/statusline-cache-rl"
  last_mtime=$(file_mtime "$claude_last" 2>/dev/null || echo 0)
  rl_mtime=$(file_mtime "$claude_rl" 2>/dev/null || echo 0)
  claude_data=''
  # These caches can still hold a header-origin week written before invariant n existed.
  measured_week='select((.five_hour.used_percentage|type)=="number"
    and (.seven_day.used_percentage|type)=="number" and (.seven_day.origin? != "headers"))'
  if [ -r "$claude_last" ] && [ "${last_mtime:-0}" -ge "${rl_mtime:-0}" ]; then
    claude_file="$claude_last"; claude_source=statusline-last
    claude_data=$(jq -c ".rate_limits | $measured_week" "$claude_file" 2>/dev/null || true)
  fi
  if [ -z "$claude_data" ]; then
    claude_file="$claude_rl"; claude_source=statusline-cache
    [ ! -r "$claude_file" ] || claude_data=$(jq -c "$measured_week" "$claude_file" 2>/dev/null || true)
  fi
  if [ -n "$claude_data" ]; then
    mtime=$(file_mtime "$claude_file" || true)
    if [ -n "$mtime" ]; then
      stale=$((now_epoch - mtime)); [ "$stale" -ge 0 ] || stale=0
      claude=$(jq -cn --argjson d "$claude_data" --argjson wall "$claude_wall" --arg source "$claude_source" \
        --arg five_reset "$(reset_iso_or_empty "$(jq -r '.five_hour.resets_at // empty' <<<"$claude_data")")" \
        --arg week_reset "$(reset_iso_or_empty "$(jq -r '.seven_day.resets_at // empty' <<<"$claude_data")")" \
        --arg as_of "$(epoch_iso "$mtime")" --argjson as_of_epoch "$mtime" --argjson stale "$stale" '
        {account:"main",is_current:true,enabled:true,
         five_hour:{used_pct:$d.five_hour.used_percentage,resets_at:(if $five_reset == "" then null else $five_reset end),as_of:$as_of_epoch,stale:($stale > 1800)},
         weekly:{used_pct:$d.seven_day.used_percentage,resets_at:(if $week_reset == "" then null else $week_reset end),as_of:$as_of_epoch,stale:($stale > 21600)},
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
codex_refresh_attempted=0
refresh_codex_quota() {
  local target=${1:-} codex_quota_cmd=${LLM_LIMITS_CODEX_QUOTA_CMD:-$script_dir/codex-quota.py}
  local codex_tmp codex_err detail rc old_current cause
  local -a helper_args=(--all-accounts)
  if [ ! -x "$codex_quota_cmd" ]; then
    codex_refresh_error='helper not executable'
    echo "llm-limits.sh: Codex quota helper is not executable: $codex_quota_cmd" >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "$codex_cache")"; then
    codex_refresh_error='cache directory failed'
    return 1
  fi
  codex_tmp=$(mktemp "${codex_cache}.tmp.XXXXXX") || { codex_refresh_error='cache temp failed'; return 1; }
  codex_err=$(mktemp "${codex_cache}.err.XXXXXX") || { rm -f "$codex_tmp"; codex_refresh_error='cache temp failed'; return 1; }
  old_current=$(jq -r '.current // "main"' "$codex_cache" 2>/dev/null || printf 'main')
  if [ -n "$target" ]; then
    helper_args=(--profile "$target" --no-cache)
  fi
  rc=0
  if [ -n "$target" ]; then
    "$codex_quota_cmd" "${helper_args[@]}" >"$codex_tmp" 2>"$codex_err" || rc=$?
  else
    CODEX_QUOTA_TIMEOUT="${LLM_LIMITS_CODEX_QUOTA_TIMEOUT:-10}" \
      "$codex_quota_cmd" "${helper_args[@]}" >"$codex_tmp" 2>"$codex_err" || rc=$?
  fi
  if [ "$rc" -eq 0 ] &&
    jq -e '([.rateLimits.primary?, .rateLimits.secondary?]
            | any((.usedPercent | type) == "number")) or
           ([.five_hour?, .weekly?, .accounts[]?.five_hour?, .accounts[]?.weekly?]
            | any((.used_pct | type) == "number"))' "$codex_tmp" >/dev/null 2>&1; then
    if [ -n "$target" ]; then
      if ! jq --arg current "$old_current" '.current = $current' "$codex_tmp" >"$codex_tmp.current" \
          || ! mv -f "$codex_tmp.current" "$codex_tmp"; then
        codex_refresh_error='cache normalization failed'
        rm -f "$codex_tmp" "$codex_tmp.current" "$codex_err"
        return 1
      fi
    fi
    if mv -f "$codex_tmp" "$codex_cache"; then
      rm -f "$codex_err"
      codex_refresh_error=''
    else
      codex_refresh_error='cache replace failed'
      rm -f "$codex_tmp" "$codex_tmp.current" "$codex_err"
      return 1
    fi
  elif [ "$rc" -eq 2 ] && jq -e '.auth_needed == true' "$codex_tmp" >/dev/null 2>&1; then
    # An auth-needed verdict is a definite per-account state: persist the marker (short
    # cause, never the raw blob) and count the probe as a success, exactly like Gemini.
    # The full RPC error still goes to the log (stderr) so the HTTP/RPC context survives.
    cause=$(jq -r '.cause // "login needed"' "$codex_tmp" 2>/dev/null || printf 'login needed')
    detail=$(jq -r '.error // empty' "$codex_err" 2>/dev/null || true)
    if [ -n "$target" ]; then
      if ! jq --arg current "$old_current" '.current = $current' "$codex_tmp" >"$codex_tmp.current" \
          || ! mv -f "$codex_tmp.current" "$codex_tmp"; then
        codex_refresh_error='cache normalization failed'
        rm -f "$codex_tmp" "$codex_tmp.current" "$codex_err"
        return 1
      fi
    fi
    if mv -f "$codex_tmp" "$codex_cache"; then
      rm -f "$codex_err"
      codex_refresh_error=''
      printf 'llm-limits.sh: Codex%s %s%s\n' \
        "$([ -n "$target" ] && printf ' account %s' "$target")" "$cause" \
        "$([ -n "$detail" ] && printf ' (raw: %s)' "$detail")" >&2
    else
      codex_refresh_error='cache replace failed'
      rm -f "$codex_tmp" "$codex_tmp.current" "$codex_err"
      return 1
    fi
  else
    detail=$(jq -r '.error // empty' "$codex_err" 2>/dev/null || true)
    [ -n "$detail" ] || detail='live query failed'
    if [ -n "$target" ]; then codex_refresh_error=$detail; else codex_refresh_error='live query failed'; fi
    rm -f "$codex_tmp" "$codex_tmp.current" "$codex_err"
    printf 'llm-limits.sh: Codex%s live quota query failed: %s\n' \
      "$([ -n "$target" ] && printf ' account %s' "$target")" "$detail" >&2
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
      if ((.accounts | type) == "array" and (.accounts | length) > 0) or
         ((.five_hour | type) == "object") or ((.weekly | type) == "object") then
        (if (.accounts | type) == "array" and (.accounts | length) > 0 then .accounts
         else [{account:"main",plan_type:(.plan_type // null),five_hour:.five_hour,
                weekly:.weekly,as_of:(.as_of // null)}] end) as $accounts |
        (.current // "main") as $current |
        (first($accounts[] | select(.account == $current)) // $accounts[0]) as $selected |
        select(([$accounts[].five_hour?, $accounts[].weekly?]
                | any((.used_pct | type) == "number")) or
               any($accounts[]; .auth_needed == true)) |
        {timestamp:$ts,payload:{rate_limits:{
          primary:{used_percent:($selected.five_hour.used_pct // null),
                   resets_at:($selected.five_hour.resets_at // null)},
          secondary:{used_percent:($selected.weekly.used_pct // null),
                     resets_at:($selected.weekly.resets_at // null)},
          plan_type:($selected.plan_type // .plan_type // null),
          accounts:$accounts,current_account:$selected.account}}}
      else
        [.rateLimits.primary?, .rateLimits.secondary?
         | select(type == "object" and (.usedPercent | type) == "number")] as $all |
        ([$all[] | select((.windowDurationMins // 0) <= 300)][0] //
         [$all[] | select(.windowDurationMins == null)][0]) as $five |
        ([$all[] | select((.windowDurationMins // 0) >= 10000)][0] //
         (if ($all | length) > 1 then $all[1] else null end)) as $week |
        select($five != null or $week != null) |
        {timestamp:$ts,payload:{rate_limits:{
          primary:{used_percent:($five.usedPercent // null),resets_at:($five.resetsAt // null)},
          secondary:{used_percent:($week.usedPercent // null),resets_at:($week.resetsAt // null)},
          plan_type:(.rateLimits.planType // null)}}}
      end' "$codex_cache" 2>/dev/null || true)
    if [ -n "$cache_event" ]; then
      codex_event=$cache_event
      codex_origin=usage
    fi
  fi
}

codex_refresh_target=''
case "$refresh_account" in codex/*) codex_refresh_target=${refresh_account#codex/} ;; esac
if [ "$refresh" -eq 1 ] && { [ -z "$refresh_account" ] || [ -n "$codex_refresh_target" ]; }; then
  if [ "${LLM_LIMITS_CODEX_REFRESH:-1}" != 0 ]; then
    codex_refresh_attempted=1
    refresh_codex_quota "$codex_refresh_target" || true
  elif [ -n "$codex_refresh_target" ]; then
    codex_refresh_attempted=1
    codex_refresh_error='refresh disabled'
    printf 'llm-limits.sh: Codex account %s refresh is disabled\n' "$codex_refresh_target" >&2
  fi
fi
select_codex_event

if [ "$start_windows" -eq 1 ] && [ -z "$refresh_account" ]; then
  if [ "${LLM_LIMITS_CODEX_REFRESH:-1}" = 0 ]; then
    echo "llm-limits.sh: codex window start skipped (LLM_LIMITS_CODEX_REFRESH=0)" >&2
  else
    codex_5h_reset=''
    [ -z "$codex_event" ] || codex_5h_reset=$(int_or_empty "$(jq -r "$iso_def"'
      .payload.rate_limits.primary.resets_at |
      if type == "number" then . elif type == "string" then iso2epoch // empty else empty end' <<<"$codex_event")")
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
    primary_reset=$(int_or_empty "$(jq -r "$iso_def"'
      .payload.rate_limits.primary.resets_at |
      if type == "number" then . elif type == "string" then iso2epoch // empty else empty end' <<<"$codex_event")")
    secondary_reset=$(int_or_empty "$(jq -r "$iso_def"'
      .payload.rate_limits.secondary.resets_at |
      if type == "number" then . elif type == "string" then iso2epoch // empty else empty end' <<<"$codex_event")")
    five_reset=''; [ -z "$primary_reset" ] || five_reset=$(epoch_iso "$primary_reset")
    week_reset=''; [ -z "$secondary_reset" ] || week_reset=$(epoch_iso "$secondary_reset")
    codex_source=session-rollout
    [ "$codex_origin" != usage ] || codex_source=codex-app-server
    codex=$(jq -cn --argjson e "$codex_event" --argjson wall "$codex_wall" --argjson now "$now_epoch" \
      --arg five_reset "$five_reset" --arg week_reset "$week_reset" \
      --arg as_of "$(epoch_iso "$codex_epoch")" --argjson as_of_epoch "$codex_epoch" \
      --arg origin "$codex_origin" --arg source "$codex_source" --argjson stale "$stale" \
      --argjson pool_out "$(worker_pool_disabled_json "$codex_pool_dir")" "$iso_def"'
      def reset_iso:
        if type == "number" then todateiso8601
        elif type == "string" then (iso2epoch | if . == null then null else todateiso8601 end)
        else null
        end;
      def bucket($b; $fallback_reset; $asof; $threshold):
        (if ($b.as_of | type) == "number" then $b.as_of
         elif ($b.as_of | type) == "string" then (($b.as_of | iso2epoch) // $asof)
         else $asof end) as $bucket_asof |
        {used_pct:($b.used_pct // $b.used_percent // null),
         resets_at:(($b.resets_at // $fallback_reset // null) | reset_iso),
         as_of:$bucket_asof,origin:$origin,stale:(($now - $bucket_asof) > $threshold)};
      def account($a; $current):
        (if ($a.as_of | type) == "number" then $a.as_of else $as_of_epoch end) as $account_asof |
        ([$now - $account_asof, 0] | max) as $account_age |
        ({account:($a.account // "main"),is_current:(($a.account // "main") == $current),
          enabled:($pool_out != null and ($pool_out | index($a.account // "main")) == null)} +
         (if $a.auth_needed == true then
            {auth_needed:true,status:"login needed"} +
            (if ($a.cause | type) == "string" then {cause:$a.cause} else {} end)
          else
            {plan_type:($a.plan_type // $e.payload.rate_limits.plan_type // null),
             five_hour:bucket(($a.five_hour // {}); null; $account_asof; 1800),
             weekly:bucket(($a.weekly // {}); null; $account_asof; 21600),
             as_of:($account_asof | todateiso8601),stale_seconds:$account_age}
          end) +
         (if ($a.reset_credits | type) == "number" then
            {reset_credits:$a.reset_credits,reset_credits_as_of:$account_asof,
             reset_credits_stale:($account_age > 21600)}
          else {} end));
      (if (($e.payload.rate_limits.accounts | type) == "array") and
          ($e.payload.rate_limits.accounts | length) > 0 then
         ($e.payload.rate_limits.current_account // "main") as $requested |
         (if any($e.payload.rate_limits.accounts[]; (.account // "main") == $requested)
          then $requested else ($e.payload.rate_limits.accounts[0].account // "main") end) as $current |
         [$e.payload.rate_limits.accounts[] | account(.; $current)] |
         sort_by(if .is_current then 0 else 1 end, .account)
       else
         [{account:"main",is_current:true,enabled:($pool_out != null and ($pool_out | index("main")) == null),
           plan_type:($e.payload.rate_limits.plan_type // null),
           five_hour:{used_pct:$e.payload.rate_limits.primary.used_percent,
                      resets_at:(if $five_reset == "" then null else $five_reset end),
                      as_of:$as_of_epoch,origin:$origin,stale:($stale > 1800)},
           weekly:{used_pct:$e.payload.rate_limits.secondary.used_percent,
                   resets_at:(if $week_reset == "" then null else $week_reset end),
                   as_of:$as_of_epoch,origin:$origin,stale:($stale > 21600)},
           as_of:$as_of,stale_seconds:$stale}]
       end) as $accounts |
      (first($accounts[] | select(.is_current)) // $accounts[0]) as $current |
      {available:true,current_account:$current.account,accounts:$accounts,
       five_hour:$current.five_hour,weekly:$current.weekly,
       as_of:$current.as_of,stale_seconds:$current.stale_seconds,source:$source,last_wall:$wall,
       plan_type:$current.plan_type}')
  else
    codex=$(jq -cn --argjson wall "$codex_wall" \
      '{available:false,status:"unparsable session timestamp",source:"session-rollout",last_wall:$wall}')
  fi
else
  codex=$(jq -cn --argjson wall "$codex_wall" \
    '{available:false,status:"no rate-limit event",source:"session-rollout",last_wall:$wall}')
fi

gemini_account_lines=''
while IFS= read -r gemini_account; do
  gemini_cache=$(gemini_account_cache "$gemini_account")
  gemini_removed_marker=$(gemini_account_marker "$gemini_account")
  gemini_enabled=true
  if worker_pool_is_disabled "$gemini_pool_dir" "$gemini_account"; then gemini_enabled=false; fi
  gemini_auth=''
  gemini_data=''
  gemini_mtime=$now_epoch
  if [ -r "$gemini_cache" ]; then
    gemini_auth=$(jq -r 'if .auth_needed == true then "1" else "" end' "$gemini_cache" 2>/dev/null || true)
    gemini_data=$(jq -c '
      [.groups[]? | select((.displayName // "") | ascii_downcase | contains("gemini"))][0] as $group |
      [$group.buckets[]? | select(.window == "5h")][0] as $five |
      [$group.buckets[]? | select(.window == "weekly")][0] as $week |
      select(($five.remainingFraction | type) == "number" and
             ($week.remainingFraction | type) == "number") |
      {group:$group.displayName,five:$five,week:$week}
    ' "$gemini_cache" 2>/dev/null || true)
    gemini_mtime=$(file_mtime "$gemini_cache" 2>/dev/null || true)
    [ -n "$gemini_mtime" ] || gemini_mtime=$now_epoch
  fi
  if [ -n "$gemini_data" ]; then
    stale=$((now_epoch - gemini_mtime)); [ "$stale" -ge 0 ] || stale=0
    gemini_account_json=$(jq -cn --arg account "$gemini_account" --argjson enabled "$gemini_enabled" --argjson d "$gemini_data" \
      --arg as_of "$(epoch_iso "$gemini_mtime")" --argjson as_of_epoch "$gemini_mtime" \
      --argjson stale "$stale" --arg auth "$gemini_auth" '
      def used($remaining):
        ((1 - $remaining) * 100) |
        (if . < 0 then 0 elif . > 100 then 100 else . end) | round;
      {account:$account,is_current:($account == "main"),enabled:$enabled,source:"agy-local-rpc",group:$d.group,
       five_hour:{used_pct:used($d.five.remainingFraction),resets_at:$d.five.resetTime,
                  as_of:$as_of_epoch,origin:"usage",stale:($stale > 1800)},
       weekly:{used_pct:used($d.week.remainingFraction),resets_at:$d.week.resetTime,
               as_of:$as_of_epoch,origin:"usage",stale:($stale > 21600)},
       as_of:$as_of,stale_seconds:$stale}
      | if $auth == "1" then . + {auth_needed:true,status:"login needed"} else . end')
  elif [ "$gemini_auth" = 1 ]; then
    gemini_account_json=$(jq -cn --arg account "$gemini_account" --argjson enabled "$gemini_enabled" \
      --arg as_of "$(epoch_iso "$gemini_mtime")" --argjson as_of_epoch "$gemini_mtime" \
      '{account:$account,is_current:($account == "main"),enabled:$enabled,auth_needed:true,
        status:"login needed",source:"agy-local-rpc",as_of:$as_of,as_of_epoch:$as_of_epoch}')
  else
    gemini_account_json=$(jq -cn --arg account "$gemini_account" --argjson enabled "$gemini_enabled" \
      '{account:$account,is_current:($account == "main"),enabled:$enabled,
        status:"no quota snapshot",source:"agy-local-rpc"}')
  fi
  if [ -e "$gemini_removed_marker" ]; then
    # Never self-clear the marker in the very run that set it: gemini removal is a
    # UX hide with creds still valid, so the "creds look fine → un-remove" check
    # would otherwise fire immediately and make removal a no-op. A later run (after
    # a genuine re-login) still clears it.
    if [ "$gemini_removed_marker" != "$gemini_just_removed_marker" ] \
       && printf '%s' "$gemini_account_json" | jq -e '.auth_needed != true and (.five_hour | type) == "object"' >/dev/null 2>&1; then
      rm -f "$gemini_removed_marker"
    else
      gemini_account_json=$(jq -cn --arg account "$gemini_account" --argjson enabled "$gemini_enabled" \
        '{account:$account,is_current:($account == "main"),enabled:$enabled,removed:true,
          status:"removed",source:"agy-local-rpc"}')
    fi
  fi
  gemini_account_lines="${gemini_account_lines}${gemini_account_json}"$'\n'
done <<<"$gemini_accounts_list"

gemini_accounts=$(printf '%s' "$gemini_account_lines" | jq -sc \
  --argjson previous "$previous_cache" --argjson records "$gemini_refresh_records" --argjson now "$now_epoch" '
  def old_error($name):
    if ($previous.vendors.gemini.accounts | type) == "array" then
      (first($previous.vendors.gemini.accounts[] | select(.account == $name) | .refresh_error) // null)
    elif $name == "main" then $previous.vendors.gemini.refresh_error
    else null end;
  ($records | group_by(.account) | map(last)) as $latest |
  map(. as $account |
    (first($latest[] | select(.account == $account.account)) // null) as $record |
    if .removed == true then del(.refresh_error)
    elif $record != null then
      if $record.error == "" then del(.refresh_error)
      else .refresh_error = {cause:$record.error,at:$now} end
    else (old_error(.account)) as $old |
      if ($old | type) == "object" then .refresh_error = $old else del(.refresh_error) end
    end)
  | sort_by(if .account == "main" then 0 else 1 end, .account)
')

gemini_refresh_error=$(jq -r '
  [.[] | select(.removed != true) |
   {account:.account,error:(.refresh_error.cause // "")} | select(.error != "")] as $errors |
  if ($errors | length) == 0 then ""
  elif ($errors | length) == 1 and $errors[0].account == "main" then $errors[0].error
  else $errors | map(.account + ": " + .error) | join("; ")
  end
' <<<"$gemini_accounts")

gemini=$(jq -cn --argjson accounts "$gemini_accounts" --argjson wall "$gemini_wall" '
  [$accounts[] | select(.removed != true)] as $visible |
  [$visible[] |
   select(.auth_needed != true and
          (.five_hour.used_pct | type) == "number" and
          (.weekly.used_pct | type) == "number" and
          .five_hour.used_pct < 100 and .weekly.used_pct < 100)] as $usable |
  (first($accounts[] | select(.account == "main")) // $accounts[0]) as $main |
  ($usable | sort_by(if .account == "main" then 1 else 0 end,
                     ([.five_hour.used_pct,.weekly.used_pct] | max), .account) | .[0]) as $selected |
  if ($accounts | length) == 1 then
    $main
    | del(.account,.is_current)
    | .available = (.removed != true and .auth_needed != true and
                    (.five_hour | type) == "object" and (.weekly | type) == "object")
    | .last_wall = $wall
  else
    ({available:(($usable | length) > 0),current_account:"main",accounts:$accounts,
      source:"agy-local-rpc",last_wall:$wall} +
     (if ($usable | length) == 0 and any($visible[]; .auth_needed == true)
      then {auth_needed:true} else {} end) +
     (if $selected != null then
        ($selected | {five_hour,weekly,as_of,stale_seconds,group})
      elif any($visible[]; .auth_needed == true) then {status:"login needed"}
      else {status:"no quota snapshot"} end))
  end
')
# Snapshots are passive: a window whose resets_at is already behind us has been reset
# server-side, so its used_pct is stale noise. Flag it (values kept for provenance).
global_refresh_error=''
if [ "$refresh" -eq 1 ] && [ -z "$refresh_account" ]; then
  refresh_attempts=$((claude_refresh_attempted + codex_refresh_attempted + gemini_refresh_attempted))
  refresh_successes=0
  if [ "$claude_refresh_attempted" -eq 1 ] && [ "$claude_refresh_succeeded" -eq 1 ]; then refresh_successes=$((refresh_successes + 1)); fi
  if [ "$codex_refresh_attempted" -eq 1 ] && [ -z "$codex_refresh_error" ]; then refresh_successes=$((refresh_successes + 1)); fi
  if [ "$gemini_refresh_attempted" -eq 1 ] && [ "$gemini_refresh_succeeded" -eq 1 ]; then refresh_successes=$((refresh_successes + 1)); fi
  if [ "$refresh_attempts" -gt 0 ] && [ "$refresh_successes" -eq 0 ]; then
    global_refresh_error='all vendor refreshes failed'
  fi
fi

# Live experiments travel with the data so consumers need no repo knowledge.
experiments_json=$(experiments_active_lines "$(experiments_registry_path "$script_dir")" \
  | jq -Rsc 'split("\n") | map(select(length > 0))')
[ -n "$experiments_json" ] || experiments_json='[]'

if ! result=$(jq -cn --arg fetched_at "$(local_iso)" --argjson experiments "$experiments_json" --argjson claude "$claude" \
  --argjson codex "$codex" --argjson gemini "$gemini" --argjson now "$now_epoch" \
  --argjson previous "$previous_cache" --argjson refresh "$refresh" --arg refresh_account "$refresh_account" \
  --argjson claude_attempted "$claude_refresh_attempted" --argjson codex_attempted "$codex_refresh_attempted" \
  --argjson gemini_attempted "$gemini_refresh_attempted" --arg global_error "$global_refresh_error" \
  --arg claude_error "$claude_refresh_error" --arg codex_error "$codex_refresh_error" --arg gemini_error "$gemini_refresh_error" \
  "$iso_def"'
  def normalize_reset:
    . as $value |
    if $value == null or $value == "" then null
    elif ($value | type) == "number" then
      if $value < 31536000 then null else ($value | todateiso8601) end
    elif ($value | type) == "string" then
      ($value | iso2epoch) as $epoch |
      if $epoch != null and $epoch < 31536000 then null else $value end
    else null
    end;
  def mark:
    if type == "object" and has("used_pct")
    then .resets_at = ((.resets_at // null) | normalize_reset) |
      (.resets_at | iso2epoch) as $e |
      if $e != null and $e <= $now
      then . + {expired:true,effective_pct:0}
      else . + {effective_pct:.used_pct}
      end
    else . end;
  def data_as_of:
    [.five_hour?, .weekly?, .fable? |
      select(type == "object" and (.used_pct | type) == "number") |
      (.as_of | if type == "number" then . elif type == "string" then iso2epoch else null end)] |
    map(select(. != null)) | min;
  def set_data_age:
    data_as_of as $asof |
    if $asof == null then del(.as_of, .stale_seconds)
    else .as_of = ($asof | todateiso8601) |
      .stale_seconds = ([$now - $asof, 0] | max)
    end;
  def under_limit($bucket):
    ($bucket | type) != "object" or $bucket.effective_pct == null or $bucket.effective_pct < 100;
  def account_usable($key):
    .removed != true and
    .enabled != false and
    .auth_needed != true and
    ((.auth.status? // "") != "expired" and (.auth.status? // "") != "failed") and
    (if $key == "gemini" then
       (.five_hour.effective_pct | type) == "number" and
       (.weekly.effective_pct | type) == "number"
     else true end) and
    under_limit(.five_hour) and under_limit(.weekly);
  def vendor_usable($key):
    if $key == "claude" or $key == "codex" or
       ($key == "gemini" and (.accounts | type) == "array") then
      .available == true and ((.accounts | type) == "array") and any(.accounts[]; account_usable($key))
    else
      .available == true and .auth_needed != true and under_limit(.five_hour) and under_limit(.weekly)
    end;
  def vendor_stale:
    ([.five_hour?, .weekly?, .fable?] +
     [(.accounts[]? | .five_hour?, .weekly?, .fable?)]) |
    map(select(type == "object") | .stale == true) | any;
  def old_error($value):
    if ($value | type) == "object" and ($value.cause | type) == "string" and ($value.at | type) == "number"
    then {cause:$value.cause,at:$value.at}
    elif ($value | type) == "string" and $value != ""
    then {cause:$value,at:(($previous.fetched_at | iso2epoch) // $now)}
    else null end;
  def outcome_error($old; $attempted; $cause):
    if $attempted == 1 then
      if $cause == "" then null else {cause:$cause,at:$now} end
    else old_error($old) end;
  def user_entry_cause:
    . == "auto-refresh frozen (experiment) — enter the account to refresh" or
    . == "needs-relogin" or . == "needs re-login" or
    startswith("login needed");
  def user_entry_error:
    if (.cause | type) != "string" then false
    else
      [.cause | split("; ")[] |
       if test("^[^:]+: not refreshed \\(.*\\)$") then
         capture("^[^:]+: not refreshed \\((?<detail>.*)\\)$").detail | user_entry_cause
       elif test("^[^:]+: login needed(?: \\(.*\\))?$") then
         capture("^[^:]+: (?<detail>.*)$").detail | user_entry_cause
       elif test("^.+ auth(?: \\(.*\\))?$") then true
       else user_entry_cause
       end] as $classes |
      ($classes | length) > 0 and all($classes[]; .)
    end;
  def classify_error:
    if (. | type) == "object" and user_entry_error
    then . + {needs_user_entry:true}
    elif (. | type) == "object" then del(.needs_user_entry)
    else .
    end;
  def mark_user_entry_accounts($vendor):
    if (.accounts | type) != "array" then
      if .auth_needed == true or (.refresh_error.needs_user_entry // false)
      then . + {needs_user_entry:true}
      else del(.needs_user_entry) end
    elif $vendor == "claude" then
      ([.refresh_error.cause // "" | split("; ")[] |
        if test("^[^:]+: not refreshed \\(.*\\)$") then
          capture("^(?<account>[^:]+): not refreshed \\((?<detail>.*)\\)$") |
          select(.detail | user_entry_cause) | .account
        elif test("^.+ auth(?: \\(.*\\))?$") then
          capture("^(?<account>.+) auth(?: \\(.*\\))?$").account
        else empty
        end]) as $accounts |
      .accounts |= map(.account as $account |
        if .auth_needed == true or ($accounts | index($account))
        then . + {needs_user_entry:true}
        else del(.needs_user_entry) end)
    elif $vendor == "gemini" then
      .accounts |= map(
        if (.refresh_error | type) == "object" then
          (.refresh_error |= classify_error) |
          if .auth_needed == true
          then . + {needs_user_entry:true} | .refresh_error.needs_user_entry = true
          elif .refresh_error.needs_user_entry == true
          then . + {needs_user_entry:true}
          else del(.needs_user_entry) end
        elif .auth_needed == true then . + {needs_user_entry:true}
        else del(.needs_user_entry)
        end)
    else
      .accounts |= map(
        if .auth_needed == true then . + {needs_user_entry:true}
        else del(.needs_user_entry) end)
    end;
  # A "<name>: not refreshed (...)" entry self-clears once its snapshot as_of moves past the failed run; other shapes are unprovable-healed, carried verbatim.
  def heal_claude_error($err; $accounts):
    if ($err | type) != "object" or ($err.cause | type) != "string" or ($err.at | type) != "number" then $err
    else
      [ $err.cause | split("; ")[] |
        if test("^[^:]+: not refreshed \\(.*\\)$") | not then .
        else
          (capture("^(?<a>[^:]+): not refreshed \\(") | .a) as $acct |
          (first($accounts[]? | select(.account == $acct) | .five_hour.as_of)) as $asof |
          if ($asof | type) == "number" and $asof > $err.at then empty else . end
        end
      ] as $kept |
      if ($kept | length) == 0 then null else {cause:($kept | join("; ")),at:$err.at} end
    end;
  # A failed refresh keeps the last good buckets, but an auth-needed verdict is a definite
  # state (not a transient failure) and must never be overwritten by stale prior data.
  def vendor_data($key; $current; $attempted; $cause):
    if $attempted == 1 and $cause != "" and $current.available != true and
       $current.auth_needed != true and $previous.vendors[$key].available == true
    then $previous.vendors[$key]
    else $current end;
  {schema:1,fetched_at:$fetched_at,experiments:$experiments,vendors:{
    claude:vendor_data("claude"; $claude; $claude_attempted; $claude_error),
    codex:vendor_data("codex"; $codex; $codex_attempted; $codex_error),
    gemini:vendor_data("gemini"; $gemini; $gemini_attempted; $gemini_error)}}
  | heal_claude_error(outcome_error($previous.vendors.claude.refresh_error; $claude_attempted; $claude_error); .vendors.claude.accounts) as $claude_outcome
  | outcome_error($previous.vendors.codex.refresh_error; $codex_attempted; $codex_error) as $codex_outcome
  | outcome_error($previous.vendors.gemini.refresh_error; $gemini_attempted; $gemini_error) as $gemini_outcome
  | if $claude_outcome == null then . else .vendors.claude.refresh_error = $claude_outcome end
  | if $codex_outcome == null then . else .vendors.codex.refresh_error = $codex_outcome end
  | if $gemini_outcome == null then . else .vendors.gemini.refresh_error = $gemini_outcome end
  | if .vendors.gemini.removed == true then .vendors.gemini |= del(.refresh_error) else . end
  | .vendors |= with_entries(
      .value |= (
        if (.accounts | type) == "array" then .accounts |= map(set_data_age) else . end
        | set_data_age))
  | .vendors |= with_entries(
      (if (.value.refresh_error | type) == "object"
       then .value.refresh_error |= classify_error else . end) |
      .key as $key | .value |= mark_user_entry_accounts($key))
  | .vendors |= with_entries(if .value.available == true then .value += {stale: (.value | vendor_stale)} else . end)
  | walk(mark)
  | .vendors |= with_entries(.key as $key | .value.usable_now = (.value | vendor_usable($key)))
  | if ([.vendors[] | select(.available == true)] | length) == 0
    then .refresh_error = {cause:"no vendor data available",at:$now}
    elif $refresh == 1 and $refresh_account == ""
    then if $global_error == "" then del(.refresh_error) else .refresh_error = {cause:$global_error,at:$now} end
    else old_error($previous.refresh_error) as $old_global |
      if $old_global == null then . else .refresh_error = $old_global end
    end'); then
  echo "llm-limits.sh: failed to build cache JSON" >&2
  exit 5
fi

if ! jq -e '.schema == 1 and (.vendors | type) == "object"' <<<"$result" >/dev/null 2>&1; then
  echo "llm-limits.sh: refusing to replace cache with invalid JSON" >&2
  exit 5
fi

if [ "$write_cache" -eq 1 ]; then
  if ! mkdir -p "$(dirname "$cache")"; then
    echo "llm-limits.sh: cache directory creation failed" >&2
    exit 5
  fi
  tmp=$(mktemp "${cache}.tmp.XXXXXX") || { echo "llm-limits.sh: cache temp creation failed" >&2; exit 5; }
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  if ! printf '%s\n' "$result" >"$tmp" || ! jq -e '.schema == 1 and (.vendors | type) == "object"' "$tmp" >/dev/null 2>&1; then
    echo "llm-limits.sh: cache temp validation failed" >&2
    exit 5
  fi
  if ! mv -f "$tmp" "$cache"; then
    echo "llm-limits.sh: cache replace failed" >&2
    exit 5
  fi
  trap - EXIT HUP INT TERM
fi

experiments_banner() {
  experiments_active_lines "$(experiments_registry_path "$script_dir")"
}

if [ "$format" = json ]; then
  printf '%s\n' "$result"
elif [ "$format" = table ]; then
  experiments_banner
  render_table
else
  experiments_banner
  plain_dim=''
  plain_rst=''
  if [ -t 1 ]; then
    plain_dim=$'\033[2m'
    plain_rst=$'\033[0m'
  fi
  jq -r --arg dim "$plain_dim" --arg rst "$plain_rst" --argjson render_now "$now_epoch" "$iso_def$age_def$reset_format_def"'
    def dimmed($window):
      if ($window.expired == true or $window.stale == true) then $dim + . + $rst else . end;
    def pct($window):
      ((if $window == null or $window.used_pct == null then "-"
      else ((($window.used_pct | round | tostring) + "%") | dimmed($window)) end) +
        (if $window.stale == true then "~" else "" end) +
        (if $window.expired == true then "!" else "" end));
    def reset($window):
      if $window == null then "-"
      else (($window.resets_at | format_reset($render_now)) | dimmed($window)) end;
    def rotation:
      if .enabled == false then "off"
      elif (.five_hour.effective_pct // 0) >= 100 then "limit-5h"
      elif (.weekly.effective_pct // 0) >= 100 then "limit-weekly"
      elif (.fable.effective_pct // 0) >= 100 then "fb:limit-fable"
      else "-" end;
    def credits:
      if (.reset_credits | type) == "number" then "↻" + (.reset_credits | tostring) else "-" end;
    def account_status:
      if .auth_needed == true or
         ((.auth.status? | type) == "string" and .auth.status != "ok")
      then "login needed" else "-" end;
    def line($src; $row; $rot; $credits; $status):
      $src + ": 5h " + pct($row.five_hour) + " @ " + reset($row.five_hour) +
      " | wk " + pct($row.weekly) + " @ " + reset($row.weekly) +
      " | fb " + pct($row.fable) + " @ " + reset($row.fable) +
      " | age " + ($row | compact_age($render_now)) +
      " | rot " + $rot + " | cr " + $credits + " | status " + $status;
    .vendors | to_entries[] |
    select(.value.removed != true) |
    if .key == "claude" and .value.available and (.value.accounts | type) == "array" then
        .value.accounts[] |
        line("claude/" + .account + (if .is_current then "*" else "" end); .; rotation; "-"; account_status)
    elif (.key == "codex" or .key == "gemini") and
         ((.value.accounts | type) == "array") and
         ((.value.accounts | length) > 1 or
          (.key == "codex" and any(.value.accounts[]; .auth_needed == true))) then
      .key as $key | .value.accounts[] | select(.removed != true) |
      line($key + "/" + .account + (if .is_current then "*" else "" end); .; rotation;
        (if $key == "codex" then credits else "-" end); account_status)
    elif .value.available then
      line(.key; .value; ((.value.accounts[0] // .value) | rotation);
        (if .key == "codex" then (.value | credits) else "-" end); "-")
    else line(.key; {}; "-"; "-";
      (if .value.auth_needed == true then "login needed" else (.value.status // "-") end)) +
      (if .value.last_wall then " | last wall " + .value.last_wall else "" end) end
  ' <<<"$result"
fi

available=$(jq '[.vendors[] | select(.available == true)] | length' <<<"$result")
if [ "$available" -eq 0 ]; then
  exit 3
fi
# Only a full refresh with zero successful vendor outcomes is a process-level failure.
[ -z "$global_refresh_error" ] || exit 4
exit 0
