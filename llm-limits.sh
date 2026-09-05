#!/usr/bin/env bash
set -u

usage() {
  echo "Usage: $0 [--json|--plain|--table] [--sort 5h|weekly|reset] [--no-write] [--refresh [--start-windows] | --refresh-account claude/NAME [--start-windows]|codex/NAME|gemini/NAME|grok/NAME|claude|codex|gemini|grok] [--gemini-remove]" >&2
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
  ''|claude|codex|gemini|grok|gemini/?*|claude/?*|codex/?*|grok/?*) ;;
  *) usage; exit 2 ;;
esac
# A bare vendor name refreshes every account of that vendor and touches no other vendor. It is
# free by construction: --start-windows (the only paid path) stays a single-account request.
refresh_vendor=''
case "$refresh_account" in
  claude|codex|gemini|grok) refresh_vendor=$refresh_account ;;
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
. "$script_dir/share/store-lock.sh"

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

claude_stale_cause() {
  local attempts_file=$1 name=$2 auth=${3:-ok} raw kind value cli_evidence=false
  raw=$(jq -r --arg n "$name" --arg auth "$auth" '
    (.[$n] // null) as $e |
    if $e == null then ["cause", (if $auth == "failed" then "stale data kept" else "usage weather" end)] | @tsv
    else
      (if ($e.attempted_at | type) == "number" then $e.attempted_at else 0 end) as $outcome_at |
      (if ($e.warm_outcome // "") == "warm-failed"
       then (if ($e.warm_attempted_at | type) == "number" then $e.warm_attempted_at else 0 end)
       elif ($e.outcome // "") == "warm-failed"
       then $outcome_at
       else 0 end) as $warm_at |
      (($e.warm_outcome // "") == "warm-failed" or ($e.outcome // "") == "warm-failed") as $has_warm |
      (if ($e.warm_kind // "") == "revive" then "revive-cause"
       elif ($e.warm_cause // "") == "robot-skip" then "cause"
       else "warm-cause" end) as $warm_kind |
      (($e.outcome // "") == "429" or ($e.outcome // "") == "weather" or
       (($e.outcome // "") == "failed" and (($e.http_status // 0) > 0))) as $has_outcome |
    if $has_warm and ($e.warm_cause // "") != "" and
       (($has_outcome | not) or $warm_at > $outcome_at)
      then [$warm_kind, $e.warm_cause] | @tsv
    elif ($e.outcome // "") == "429" then
      (((($e.strikes // 0) | if type != "number" or . < 1 then 1 else floor end)) as $s |
       (900 * (2 | pow(.; $s - 1)) | if . > 14400 then 14400 else . end) as $c |
       ([($outcome_at + $c),
         (if ($e.retry_after_until | type) == "number" then $e.retry_after_until else 0 end)] | max) as $until |
       ["429", $until] | @tsv)
    elif ($e.outcome // "") == "weather" and (($e.http_status // 0) > 0)
      then ["cause", ("token refresh HTTP " + ($e.http_status | tostring))] | @tsv
    elif ($e.outcome // "") == "weather" and (($e.transport_rc // 0) > 0)
      then ["cause", ("token refresh transport error (curl " + ($e.transport_rc | tostring) + ")")] | @tsv
    elif ($e.outcome // "") == "weather" then ["cause", "network weather"] | @tsv
    elif ($e.outcome // "") == "failed" and (($e.http_status // 0) > 0)
      then ["cause", ("token refresh HTTP " + ($e.http_status | tostring))] | @tsv
    elif $has_warm and ($e.warm_cause // "") != "" then [$warm_kind, $e.warm_cause] | @tsv
    else ["cause", "stale data kept"] | @tsv end end' "$attempts_file" 2>/dev/null) || raw=$'cause\tstale data kept'
  IFS=$'\t' read -r kind value <<<"$raw"
  # Warm and revive run the free CLI path, which robots do reach, so their failure causes are
  # live evidence; only causes that could have come from the curl POST get the robot banner.
  case "$kind" in revive-cause|warm-cause) kind=cause; cli_evidence=true ;; esac
  # An auth-shaped cause (logged out / needs re-login) is actionable and must surface
  # even on a robot run — the account is genuinely dead, not just left unrefreshed.
  case "$value" in
    *relogin*|*re-login*|*"log in"*|*"logged out"*|*"login needed"*)
      printf '%s' "$value"; return ;;
  esac
  case "$value" in
    usage-probe-failed) value='usage probe failed' ;;
    timeout) value='warm timeout' ;;
    warm-failed) value='warm session failed' ;;
    warm-429) value='warm HTTP 429' ;;
    robot-skip) value='robot refresh skipped' ;;
  esac
  if [ "$cli_evidence" != true ] && [ "${CLAUDEB_WARM_USER_EXPLICIT:-false}" != true ]; then
    # A robot run never POSTs the token endpoint, so an older 429 (or generic
    # weather/stale) cause would claim a rate limit nothing hit this run.
    printf 'robot curl refresh off (manual refresh only) — revive path active'
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
  limits_age_text($seconds);'

reset_format_def='def format_reset($now):
  . as $iso | ($iso | iso2epoch) as $epoch |
  if $iso == null or $iso == "" then "-"
  elif $epoch == null then $iso
  else limits_reset_text($epoch; $now) end;'

color_stdout() {
  [ -t 1 ] || [ -n "${CLICOLOR_FORCE:-}" ]
}

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

# The AGE cell answers to one flag the collector already computed, never to its own reading of
# the text: `never` and a two-day span are the same verdict and must not drift apart here.
age_cell() {
  local cell
  printf -v cell '%-*s' "$2" "$1"
  if [ "$3" -eq 1 ] && [ "${4:-0}" -eq 1 ]; then
    printf '\033[31m%s\033[0m' "$cell"
  else
    printf '%s' "$cell"
  fi
}

render_table() {
  local table_color=0
  if color_stdout; then
    table_color=1
  fi
  # Sentinels (-1 / 9999999999) push rows with missing values last for every sort direction.
  local rows
  rows=$(jq -r --argjson render_now "$now_epoch" "$iso_def$LIMITS_VIEW_JQ$age_def$reset_format_def"'
    def marked_pct($window):
      limits_pct_text($window.effective_pct; ($window.stale == true); ($window.expired == true));
    def rotation:
      if .enabled == false then "off"
      elif (.five_hour.effective_pct // 0) >= 100 then "limit-5h"
      elif (.weekly.effective_pct // 0) >= 100 then "limit-weekly"
      elif (.fable.effective_pct // 0) >= 100 then "fb:limit-fable"
      else "-" end;
    def account_status($vendor):
      if .auth_needed == true or
         ((.auth.status? | type) == "string" and .auth.status != "ok"
          and ($vendor != "grok" or .auth.status != "expired"))
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
       (if .alarm then 1 else 0 end),
       .src, marked_pct(.five), marked_pct(.week), marked_pct(.fable),
       (.five.resets_at | format_reset($render_now)),
       (.week.resets_at | format_reset($render_now)),
       (.fable.resets_at | format_reset($render_now)),
       .age, .rot, .credits, .status] | @tsv;
    .vendors as $v |
    [
    # An absent vendor prints nothing. Both branches below otherwise fall through to a row built
    # out of nulls, which reads as a leg that answered with no data rather than one that is gone.
      (if ($v | has("claude") | not) then empty
       elif $v.claude.available and (($v.claude.accounts | type) == "array") then
         ($v.claude.accounts[]
          | {src: ("claude/" + .account + (if .is_current then "*" else "" end)),
             five: .five_hour, week: .weekly, fable: .fable,
             age: compact_age($render_now), alarm: (.age_alarm == true),
             rot: rotation, credits: "-", status: account_status("claude")})
       else {src: "claude", five: null, week: null, fable:null,
             age: ($v.claude | compact_age($render_now)), alarm: ($v.claude.age_alarm == true),
             rot:"-", credits:"-", status:($v.claude.status // "-")} end),
      (("codex", "gemini", "grok") as $k | select($v | has($k)) | $v[$k]
       | select(.removed != true)
       | if ((.accounts | type) == "array") and
            (($k == "codex" and any(.accounts[]; .auth_needed == true)) or (.accounts | length) > 1 or
             (($k == "gemini" or $k == "grok") and (.accounts | length) > 0)) then
           (.accounts[] | select(.removed != true)
              | {src: ($k + "/" + .account + (if .is_current then "*" else "" end)),
                 five: .five_hour, week: .weekly, fable:null,
                 age: compact_age($render_now), alarm: (.age_alarm == true), rot: rotation,
                 credits:(if (.reset_credits | type) == "number" then "↻" + (.reset_credits | tostring) else "-" end),
                 status:account_status($k)})
         elif .available then
           {src: $k, five: .five_hour, week: .weekly, fable:null,
            age: compact_age($render_now), alarm: (.age_alarm == true),
            rot: ((.accounts[0] // .) | rotation),
            credits:(if (.reset_credits | type) == "number" then "↻" + (.reset_credits | tostring) else "-" end),
            status:"-"}
           else
           {src: $k, five: null, week: null, fable:null,
            age: compact_age($render_now), alarm: (.age_alarm == true), rot:"-", credits:"-",
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

  local k5 kw e5 ew kr kf dim5 dimw dimf alarm src p5 pw pf r5 rw rf age rot credits status
  local w_src=6 w_p5=3 w_pw=3 w_pf=3 w_r5=8 w_rw=8 w_rf=8 w_age=3 w_rot=3 w_cr=2
  while IFS=$'\t' read -r k5 kw e5 ew kr kf dim5 dimw dimf alarm src p5 pw pf r5 rw rf age rot credits status; do
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
  while IFS=$'\t' read -r k5 kw e5 ew kr kf dim5 dimw dimf alarm src p5 pw pf r5 rw rf age rot credits status; do
    [ -n "$src" ] || continue
    printf '%-*s  ' "$w_src" "$src"
    pct_cell "$p5" "$w_p5" "$table_color" "$k5" "$dim5"; printf '  '
    pct_cell "$pw" "$w_pw" "$table_color" "$kw" "$dimw"; printf '  '
    pct_cell "$pf" "$w_pf" "$table_color" "$kf" "$dimf"; printf '  '
    dim_cell "$r5" "$w_r5" "$table_color" "$dim5"; printf '  '
    dim_cell "$rw" "$w_rw" "$table_color" "$dimw"; printf '  '
    dim_cell "$rf" "$w_rf" "$table_color" "$dimf"; printf '  '
    age_cell "$age" "$w_age" "$table_color" "$alarm"; printf '  '
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
grok_wall=$(wall_for grok)

gemini_base_home=$HOME
gemini_profiles_dir="${GEMINIB_PROFILES_DIR:-$HOME/.gemini-profiles}"
gemini_accounts_cache_dir="${LLM_LIMITS_GEMINI_ACCOUNTS_DIR:-$HOME/.llm-limits-gemini}"
gemini_main_cache=${LLM_LIMITS_GEMINI_CACHE:-$HOME/.llm-limits-gemini.json}
agy_bin=${AGY_BIN:-$HOME/.local/bin/agy}
. "$script_dir/share/gemini-accounts.sh"
gemini_legacy_removed=$(gemini_removal_marker main)
. "$script_dir/share/worker-pool.sh"
. "$script_dir/share/experiments.sh"
. "$script_dir/share/limits-view.sh"
. "$script_dir/share/worker-model.sh"

# A paused vendor is parked for months and must not exist for the infrastructure: no collector
# runs for it and the store carries no entry (docs/routing-contract.md, "Pause"). Read once, so a
# file edited mid-run cannot make the collectors and the merge below disagree about one vendor.
# `worker_model_pinned_account` is that file's one generic reader, and `_paused` resolves through
# it exactly as every other key does — first line wins, literal value only.
# The store spells Claude `claude` and the worker-model file spells it `claudeb`.
pause_config_vendor() { case "$1" in claude) printf 'claudeb' ;; *) printf '%s' "$1" ;; esac; }
paused_vendors=' '
for pause_vendor in claude codex gemini grok opencode; do
  [ "$(worker_model_pinned_account "$(pause_config_vendor "$pause_vendor")_paused" 2>/dev/null || true)" = on ] \
    || continue
  paused_vendors="$paused_vendors$pause_vendor "
done
vendor_paused() { case "$paused_vendors" in *" $1 "*) return 0 ;; esac; return 1; }
paused_vendors_json=$(printf '%s' "$paused_vendors" | jq -Rc 'split(" ") | map(select(length > 0))')

# --refresh-account names a vendor deliberately, so a parked one is refused rather than quietly
# skipped: a silent success would leave the caller reading a parked vendor's old numbers as fresh.
refresh_account_vendor=${refresh_account%%/*}
if [ -n "$refresh_account_vendor" ] && vendor_paused "$refresh_account_vendor"; then
  printf '%s is paused (%s_paused=on in ~/.claude/worker-model)\n' \
    "$(pause_config_vendor "$refresh_account_vendor")" \
    "$(pause_config_vendor "$refresh_account_vendor")" >&2
  exit 2
fi

codex_pool_dir=$(worker_pool_dir codex)
gemini_pool_dir=$(worker_pool_dir gemini)
grok_pool_dir=$(worker_pool_dir grok)
claude_profiles_root="${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"
codex_profiles_dir="${CODEXB_PROFILES_DIR:-$HOME/.codex-profiles}"
grok_profiles_dir="${GROKB_PROFILES_DIR:-$HOME/.grok-profiles}"

# The roster grok-quota.py itself would walk: `main` is the real ~/.grok and counts only once it
# carries a login, dotted names are grokb's own state, and `main` under the profiles directory is
# a name nothing can address.
grok_account_names() {
  local path name
  [ -f "$HOME/.grok/auth.json" ] && printf 'main\n'
  if [ -d "$grok_profiles_dir" ]; then
    for path in "$grok_profiles_dir"/*; do
      [ -d "$path" ] || continue
      name=$(basename "$path")
      case "$name" in .*|main) continue ;; esac
      printf '%s\n' "$name"
    done | LC_ALL=C sort
  fi
}

if [ -n "${LLM_LIMITS_GROKB:-}" ]; then
  grokb_cmd=$LLM_LIMITS_GROKB
else
  grokb_cmd=$script_dir/bin/grokb
  [ -x "$grokb_cmd" ] || grokb_cmd=$(command -v grokb 2>/dev/null || printf '%s' "$grokb_cmd")
fi
grok_touch_timeout=${LLM_LIMITS_GROK_TOUCH_TIMEOUT:-30}
case "$grok_touch_timeout" in ''|*[!0-9]*|0) grok_touch_timeout=30 ;; esac

# A token past its own expiry, or one the last poll saw rejected, is rotated by the vendor CLI as a
# side effect of any authenticated subcommand — never minted here. The CLI prints "You are not
# authenticated." while rotating, so its words and exit status decide nothing; the poll that
# follows writes the verdict (shared-invariants row ak).
grok_token_expired() {
  local auth
  case "$1" in main) auth=$HOME/.grok/auth.json ;; *) auth=$grok_profiles_dir/$1/auth.json ;; esac
  if [ -r "$auth" ] && jq -e --argjson now "$now_epoch" '
      def entry: if type != "object" then empty
        elif (.key | type) == "string" then .
        else first(.[]? | select(type == "object" and (.key | type) == "string")) end;
      ((entry // null) | .expires_at? // null) as $exp |
      (if ($exp | type) == "number" then $exp
       elif ($exp | type) == "string" then
         ($exp | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null)
       else null end) as $epoch |
      $epoch != null and $epoch <= $now
    ' "$auth" >/dev/null 2>&1; then
    return 0
  fi
  [ -r "$grok_cache" ] && jq -e --arg account "$1" \
    '.accounts[]? | select(.account == $account) | .auth == "expired"' "$grok_cache" >/dev/null 2>&1
}

grok_touch_expired() { # <account>...
  local account
  for account in "$@"; do
    grok_token_expired "$account" || continue
    if [ ! -x "$grokb_cmd" ]; then
      printf 'llm-limits.sh: Grok account %s: token expired and no grokb at %s to rotate it\n' \
        "$account" "$grokb_cmd" >&2
      continue
    fi
    printf 'llm-limits.sh: Grok account %s: token touch\n' "$account" >&2
    run_bounded "$grok_touch_timeout" "$grokb_cmd" "$account" exec models || true
  done
}

worker_pool_name_in_list() {
  local target="$1" name
  shift
  for name in "$@"; do [ "$name" != "$target" ] || return 0; done
  return 1
}

reconcile_vendor_shields() {
  local vendor="$1" payload="$2" pool_vendor="$1" dir rows name reset main should marker kind
  local -a accounts=()
  [ "$pool_vendor" != claude ] || pool_vendor=claudeb
  dir=$(worker_pool_dir "$pool_vendor") || return 1
  rows=$(jq -r --arg vendor "$vendor" --argjson now "$now_epoch" \
    --argjson floor "$WORKER_POOL_SHIELD_PER_DAY" "$iso_def$LIMITS_VIEW_JQ"'
    (.accounts // [])[] |
    (.weekly.resets_at | iso2epoch) as $reset |
    (limits_effective_pct(.weekly.used_pct;
       limits_bucket_expired($now; $reset))) as $effective |
    (limits_daily_budget($effective; limits_days_remaining($reset; $now))) as $budget |
    [ .account,
      ($reset // ""),
      (if $vendor == "claude" then (.is_current == true)
       elif $vendor == "codex" then (.account == "main")
       else false end),
      (($budget | type) == "number" and $budget < $floor)
    ] | map(tostring) | join("\u001f")' <<<"$payload") || return 1

  while IFS=$'\x1f' read -r name reset main should; do
    [ -n "$name" ] || continue
    worker_pool_valid_name "$name" || return 1
    accounts+=("$name")
    if [ "$vendor" = gemini ] || [ "$vendor" = grok ]; then
      worker_pool_override_clear "$pool_vendor" "$name" || return 1
    elif [ -z "$reset" ] || ! worker_pool_override_current "$pool_vendor" "$name" "$reset"; then
      worker_pool_override_clear "$pool_vendor" "$name" || return 1
    fi
    if [ "$main" = true ] && [ "$should" = true ] && [ -n "$reset" ] &&
       ! worker_pool_override_current "$pool_vendor" "$name" "$reset"; then
      worker_pool_shield_set "$pool_vendor" "$name" "$reset" || return 1
    else
      worker_pool_shield_clear "$pool_vendor" "$name" || return 1
    fi
  done <<<"$rows"

  for kind in shielded shield-override; do
    [ -d "$dir/$kind" ] || continue
    while IFS= read -r marker; do
      name=${marker##*/}
      worker_pool_valid_name "$name" || continue
      worker_pool_name_in_list "$name" ${accounts[@]+"${accounts[@]}"} && continue
      if [ "$kind" = shielded ]; then
        worker_pool_shield_clear "$pool_vendor" "$name" || return 1
      else
        worker_pool_override_clear "$pool_vendor" "$name" || return 1
      fi
    done < <(find "$dir/$kind" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  done
}

apply_vendor_shield_state() {
  local vendor="$1" payload="$2" pool_vendor="$1" dir pool_out shielded
  [ "$pool_vendor" != claude ] || pool_vendor=claudeb
  dir=$(worker_pool_dir "$pool_vendor") || return 1
  pool_out=$(worker_pool_disabled_json "$dir") || return 1
  shielded=$(worker_pool_shielded_json "$dir") || return 1
  jq -c --arg vendor "$vendor" --argjson pool_out "$pool_out" --argjson shielded "$shielded" '
    if (.accounts | type) != "array" then .
    else .accounts |= map(
      .account as $account |
      .shielded = ($shielded == null or ($shielded | index($account)) != null) |
      .enabled = ($pool_out != null and ($pool_out | index($account)) == null) |
      if $vendor == "claude" and (.rotation.usable | type) == "object" then
        ((.auth | type) == "object" and .auth.status == "ok") as $auth_alive |
        .blocked = ((.enabled and $auth_alive) | not) |
        .rotation.usable.general = $auth_alive |
        .rotation.usable.fable = ($auth_alive and (.fable | type) == "object" and .plan_type != "pro")
      else . end)
    end' <<<"$payload"
}

# Account order in the cache, which the menu, --table and --plain all render as-is. The two
# accounts Egor works from lead every vendor by name; this hardcode is the whole point of the
# rule, not a default to be derived from data.
account_priority_names() {
  case "$1" in
    claude) printf 'notcom\ncom\n' ;;
    codex) printf 'main\n' ;;
    gemini) printf 'main\ncom\n' ;;
    grok) printf 'supergrok\n' ;;
  esac
}

account_profile_dir() {
  case "$1" in
    claude) printf '%s/%s\n' "$claude_profiles_root" "$2" ;;
    codex) if [ "$2" = main ]; then printf '%s/.codex\n' "$HOME"; else printf '%s/%s\n' "$codex_profiles_dir" "$2"; fi ;;
    gemini) gemini_account_home "$2" ;;
    grok) if [ "$2" = main ]; then printf '%s/.grok\n' "$HOME"; else printf '%s/%s\n' "$grok_profiles_dir" "$2"; fi ;;
  esac
}

# Everything outside the priority list follows in profile-creation order (macOS birth time), so a
# newly added account lands at the end instead of wherever the alphabet drops it. An account whose
# directory has no readable birth time sorts last, by name.
account_order() {
  local vendor=$1 name candidate index rank birth
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    rank=''
    index=0
    while IFS= read -r candidate; do
      if [ "$candidate" = "$name" ]; then rank=$index; break; fi
      index=$((index + 1))
    done <<<"$(account_priority_names "$vendor")"
    if [ -n "$rank" ]; then
      printf '0\t%s\t%s\n' "$rank" "$name"
      continue
    fi
    birth=$(stat -f %B "$(account_profile_dir "$vendor" "$name")" 2>/dev/null || true)
    case "$birth" in
      ''|*[!0-9]*) printf '2\t0\t%s\n' "$name" ;;
      *) printf '1\t%s\t%s\n' "$birth" "$name" ;;
    esac
  done | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3 | cut -f3
}

# The same order as a JSON array, for the jq filters that assemble each vendor's accounts.
account_order_json() {
  account_order "$1" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

gemini_account_cache() {
  if [ "$1" = main ]; then printf '%s\n' "$gemini_main_cache"
  else printf '%s/%s.json\n' "$gemini_accounts_cache_dir" "$1"
  fi
}

gemini_account_marker() { gemini_removal_marker "$1"; }

# Written before the roster is read, so the removing run renders exactly what every run after it
# renders: `--gemini-remove` is the menubar's spelling of `geminib remove main`, and both write and
# read the one marker `gemini_removal_marker main` names.
if [ "$gemini_remove" -eq 1 ]; then
  mkdir -p "$(dirname "$gemini_legacy_removed")" 2>/dev/null || true
  # A swallowed write turns removal into a silent no-op; surface it and fail.
  if ! : > "$gemini_legacy_removed" 2>/dev/null; then
    echo "llm-limits.sh: failed to write gemini removed-marker: $gemini_legacy_removed" >&2
    exit 1
  fi
fi
gemini_refresh_accounts_list=''
gemini_accounts_list=''
if ! vendor_paused gemini; then
  gemini_refresh_accounts_list=$(gemini_account_names)
  gemini_accounts_list=$(
    {
      printf '%s\n' "$gemini_refresh_accounts_list"
      if [ -d "$gemini_accounts_cache_dir" ]; then
        for gemini_removed_path in "$gemini_accounts_cache_dir"/*.json.removed; do
          [ -e "$gemini_removed_path" ] || continue
          gemini_removed_name=$(basename "$gemini_removed_path" .json.removed)
          # A named account keeps a `removed:true` row; main's removal is total absence, so its
          # marker must not put it back into the roster it was just taken out of.
          [ "$gemini_removed_name" != main ] || continue
          printf '%s\n' "$gemini_removed_name"
        done
      fi
    } | awk 'NF && !seen[$0]++'
  )
fi
gemini_refresh_error=''
gemini_refresh_attempted=0
gemini_refresh_succeeded=0
gemini_refresh_records='[]'
gemini_refresh_results_dir=''
gemini_refresh_result_index=0
gemini_refresh_result_file=''
cache_lock=''
cache_tmp=''

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
  [ -z "$cache_tmp" ] || rm -f "$cache_tmp"
  [ -z "$cache_lock" ] || store_lock_release "$cache_lock"
}
trap cleanup_gemini_refresh_results EXIT
# A bare signal death skips the EXIT trap and would strand the store lock until the stale-break.
trap 'exit 129' HUP INT TERM

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
  gemini/*) gemini_refresh_target=${refresh_account#gemini/} ;;
esac
if [ -n "$gemini_refresh_target" ] && ! grep -qxF "$gemini_refresh_target" <<<"$gemini_refresh_accounts_list"; then
  printf 'llm-limits.sh: unknown Gemini account: %s\n' "$gemini_refresh_target" >&2
  exit 2
fi
if [ "$refresh" -eq 1 ] && ! vendor_paused gemini &&
   { [ -z "$refresh_account" ] || [ -n "$gemini_refresh_target" ] || [ "$refresh_vendor" = gemini ]; }; then
  if [ "${LLM_LIMITS_GEMINI_REFRESH:-1}" != 0 ]; then
    gemini_refresh_pids=()
    while IFS= read -r gemini_account; do
      [ -n "$gemini_account" ] || continue
      [ -z "$gemini_refresh_target" ] || [ "$gemini_account" = "$gemini_refresh_target" ] || continue
      new_gemini_refresh_result
      refresh_gemini_quota "$gemini_account" "$gemini_refresh_result_file" &
      gemini_refresh_pids[${#gemini_refresh_pids[@]}]=$!
    done <<<"$gemini_refresh_accounts_list"
    for gemini_refresh_pid in ${gemini_refresh_pids[@]+"${gemini_refresh_pids[@]}"}; do
      wait "$gemini_refresh_pid" || true
    done
  elif [ -n "$gemini_refresh_target" ] || [ "$refresh_vendor" = gemini ]; then
    while IFS= read -r gemini_account; do
      [ -n "$gemini_account" ] || continue
      [ -z "$gemini_refresh_target" ] || [ "$gemini_account" = "$gemini_refresh_target" ] || continue
      new_gemini_refresh_result
      record_gemini_refresh "$gemini_refresh_result_file" "$gemini_account" true false 'refresh disabled'
    done <<<"$gemini_refresh_accounts_list"
    printf 'llm-limits.sh: Gemini refresh is disabled\n' >&2
  fi
fi
if [ "$start_windows" -eq 1 ] && [ -z "$refresh_account" ] && ! vendor_paused gemini; then
  if [ "${LLM_LIMITS_GEMINI_REFRESH:-1}" = 0 ]; then
    echo "llm-limits.sh: gemini window start skipped (LLM_LIMITS_GEMINI_REFRESH=0)" >&2
  else
    while IFS= read -r gemini_account; do
      [ -n "$gemini_account" ] || continue
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
if [ "$refresh" -eq 1 ] && ! vendor_paused claude &&
   { [ -z "$refresh_account" ] || [ -n "$claude_refresh_target" ] || [ "$refresh_vendor" = claude ]; }; then
  if [ -d "$claudeb_root/limits" ]; then
    claude_refresh_attempted=1
    claude_refresh_run_start=$(date +%s)
    claudeb_cmd=$(command -v "${LLM_LIMITS_CLAUDEB_CMD:-claudeb}" 2>/dev/null || true)
    if [ -n "$claudeb_cmd" ]; then
      claudeb_child=(env LLM_LIMITS_ANNOUNCE_SUPPRESS=1 "$claudeb_cmd")
      if [ "${CLAUDEB_WARM_USER_EXPLICIT:-false}" = true ]; then
        claudeb_child=(env LLM_LIMITS_ANNOUNCE_SUPPRESS=1 CLAUDEB_WARM_USER_EXPLICIT=true "$claudeb_cmd")
      fi
      if [ -n "$claude_refresh_target" ]; then
        warm_args=(warm)
        if [ "$start_windows" -eq 1 ]; then
          # Feature-detect; the trailing ] keeps old builds' [--start-windows] from matching.
          if "${claudeb_child[@]}" --help 2>/dev/null | grep -q -- '--start-window]'; then
            warm_args+=(--start-window)
          else
            echo "llm-limits.sh: claudeb warm lacks --start-window; free account refresh only" >&2
          fi
        fi
        if run_bounded_claude "$claude_refresh_timeout" "account refresh ($claude_refresh_target)" \
            "${claudeb_child[@]}" "${warm_args[@]}" "$claude_refresh_target"; then
          claude_refresh_succeeded=1
        else
          [ -n "$claude_refresh_error" ] || claude_refresh_error=$(claude_stale_cause "$claudeb_root/oauth-attempts.json" "$claude_refresh_target" ok)
          claude_refresh_error="$claude_refresh_target: not refreshed ($claude_refresh_error)"
        fi
      elif [ "$start_windows" -eq 1 ]; then
        # Feature-detect: older claudeb builds predate --start-windows and would die on it.
        if "${claudeb_child[@]}" --help 2>/dev/null | grep -q -- '--start-windows'; then
          if run_bounded_claude "$claude_sw_timeout" 'refresh + start-windows + heal' "${claudeb_child[@]}" --refresh --start-windows --heal; then
            claude_refresh_succeeded=1
          else
            [ -n "$claude_refresh_error" ] || claude_refresh_error='probe failed'
          fi
        else
          echo "llm-limits.sh: claudeb lacks --start-windows; claude windows not started (free refresh only)" >&2
          if run_bounded_claude "$claude_refresh_timeout" 'free refresh (no start-windows support)' "${claudeb_child[@]}" accounts --no-spend; then
            claude_refresh_succeeded=1
          else
            [ -n "$claude_refresh_error" ] || claude_refresh_error='probe failed'
          fi
        fi
      else
        if run_bounded_claude "$claude_refresh_timeout" 'free refresh + heal' "${claudeb_child[@]}" accounts --no-spend --heal; then
          claude_refresh_succeeded=1
        else
          [ -n "$claude_refresh_error" ] || claude_refresh_error='probe failed'
        fi
      fi
    else
      claude_refresh_error='claudeb not found'
      echo "llm-limits.sh: claudeb not found; cannot refresh claude accounts" >&2
    fi
  elif [ -n "$claude_refresh_target" ] || [ "$refresh_vendor" = claude ]; then
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
if vendor_paused claude; then
  :
elif [ -d "$claudeb_root/limits" ] && [ "${#claudeb_files[@]}" -gt 0 ]; then
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
      --argjson stale "$stale" --arg plan_type "$plan_type" \
      --argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY" \
      --argjson thrf "$LIMITS_STALE_FABLE" "$LIMITS_VIEW_JQ"'
      (($d.auth | type) == "object" and $d.auth.status == "expired") as $expired |
      # Pool membership is consent and has its own field (`enabled`); `rotation.usable` is
      # capability alone, so a reader can tell "taken out of the pool" from "cannot work" — the
      # pin overrides the first and not the second. `blocked` stays the combined verdict.
      (($d.auth | type) == "object" and $d.auth.status == "ok") as $auth_alive |
      (($d.auth | type) == "object" and
       ($d.auth.status == "expired" or $d.auth.status == "failed")) as $auth_needed |
      (if ($d.five_hour.as_of | type) == "number" then $d.five_hour.as_of else $mtime end) as $account_asof |
      def meta($b; $thr):
        if ($b | type) != "object" then null else
          (if ($b.as_of | type) == "number" then $b.as_of else $mtime end) as $asof |
          ({as_of: $asof,
            stale: limits_bucket_stale($now; $thr; $expired; ($b.origin // ""); $asof)} +
           (if ($b.origin | type) == "string" then {origin: $b.origin} else {} end))
        end;
      {auth: (if ($d.auth | type) == "object" then $d.auth else null end),
       five: ($d | meta(.five_hour; $thr5)),
       week: ($d | meta(.seven_day; $thrw)),
       fable: ($d | meta(.fable; $thrf))} as $x |
      {account:$account,is_current:false,enabled:$enabled,
       five_hour:(if $has_five == 0
                  then {used_pct:null,resets_at:null,as_of:$mtime,stale:true}
                  else {used_pct:$d.five_hour.used_percentage,
                        resets_at:(if $five_reset == "" then null else $five_reset end)} + ($x.five // {}) end),
       as_of:($account_asof | todateiso8601),stale_seconds:($now - $account_asof)} +
      (if $plan_type == "" then {} else {plan_type:$plan_type} end) +
      {blocked:(($enabled and $auth_alive) | not)} +
      (if $d.auth_needed == true or $auth_needed then {auth_needed:true} else {} end) +
      (if $x.auth then {auth:$x.auth} else {} end) +
      (if $has_week == 0 then {} else {weekly:({used_pct:$d.seven_day.used_percentage,
        resets_at:(if $week_reset == "" then null else $week_reset end)} + ($x.week // {}))} end) +
      (if $has_fable == 0 then {} else {fable:({used_pct:$d.fable.used_percentage,
        resets_at:(if $fable_reset == "" then null else $fable_reset end)} + ($x.fable // {}))} end) +
      {rotation:{usable:{general:$auth_alive,
                         fable:($auth_alive and
                                $has_fable == 1 and $plan_type != "pro")}}}' <<<"$claude_data")
    accounts_lines+="$account_json"$'\n'
  done
  accounts=$(jq -sc '.' <<<"$accounts_lines")
  if [ "$(jq 'length' <<<"$accounts")" -gt 0 ]; then
    if ! jq -e --arg current "$current" 'any(.account == $current)' <<<"$accounts" >/dev/null; then
      current=$(jq -r 'sort_by(.account)[0].account' <<<"$accounts")
    fi
    claude_order=$(jq -r '.[].account' <<<"$accounts" | account_order_json claude)
    accounts=$(jq -c --arg current "$current" --argjson order "$claude_order" '
      map(.is_current = (.account == $current)) |
      sort_by(.account as $n | (($order | index($n)) // ($order | length)))
    ' <<<"$accounts")
    claude_bundle=$(jq -cn --argjson accounts "$accounts" --argjson wall "$claude_wall" '
      (first($accounts[] | select(.is_current)) // $accounts[0]) as $current |
      (if ($current.five_hour.used_pct | type) == "number" then $current
       else (first($accounts[] | select(.five_hour.used_pct | type == "number")) // $current)
       end) as $five_source |
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
        --arg as_of "$(epoch_iso "$mtime")" --argjson as_of_epoch "$mtime" --argjson stale "$stale" \
        --argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY" '
        {account:"main",is_current:true,enabled:true,
         five_hour:{used_pct:$d.five_hour.used_percentage,resets_at:(if $five_reset == "" then null else $five_reset end),as_of:$as_of_epoch,stale:($stale > $thr5)},
         weekly:{used_pct:$d.seven_day.used_percentage,resets_at:(if $week_reset == "" then null else $week_reset end),as_of:$as_of_epoch,stale:($stale > $thrw)},
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
  codex_origin=usage
  codex_source=session-rollout
  [ -r "$codex_cache" ] || return 0
  local cache_mtime rollout_epoch cache_event merged
  cache_mtime=$(int_or_empty "$(file_mtime "$codex_cache" 2>/dev/null || true)")
  [ -n "$cache_mtime" ] || return 0
  rollout_epoch=''
  if [ -n "$codex_event" ]; then
    rollout_epoch=$(int_or_empty "$(jq -nr --arg ts "$(jq -r '.timestamp' <<<"$codex_event")" "$iso_def"'$ts | iso2epoch // empty' 2>/dev/null || true)")
  fi
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
  [ -n "$cache_event" ] || return 0
  if [ -z "$rollout_epoch" ] || [ "$cache_mtime" -ge "$rollout_epoch" ]; then
    codex_event=$cache_event
    codex_origin=usage
    codex_source=codex-app-server
    return 0
  fi
  # The cache is the only account roster: a fresher rollout tail comes from the main codex
  # home alone, so it may overlay main's numbers but never shrink the list to that account.
  merged=$(jq -c --argjson rollout "$codex_event" --argjson as_of "$rollout_epoch" '
    (.payload.rate_limits.accounts // []) as $accounts |
    select(($accounts | length) > 0) |
    $rollout.payload.rate_limits as $r |
    .payload.rate_limits.plan_type as $plan |
    (.payload.rate_limits.current_account // "main") as $current |
    [$accounts[] |
      if (.account // "main") == "main" then
        del(.auth_needed, .cause) +
        {five_hour:{used_pct:$r.primary.used_percent,resets_at:$r.primary.resets_at,origin:"usage"},
         weekly:{used_pct:$r.secondary.used_percent,resets_at:$r.secondary.resets_at,origin:"usage"},
         reset_credits_as_of:(.reset_credits_as_of // .as_of),as_of:$as_of}
      else
        . + {five_hour:((.five_hour // {}) + {origin:"usage"}),
             weekly:((.weekly // {}) + {origin:"usage"})}
      end] as $merged |
    (first($merged[] | select((.account // "main") == $current)) // $merged[0]) as $selected |
    {timestamp:$rollout.timestamp,payload:{rate_limits:{
      primary:{used_percent:($selected.five_hour.used_pct // null),
               resets_at:($selected.five_hour.resets_at // null)},
      secondary:{used_percent:($selected.weekly.used_pct // null),
                 resets_at:($selected.weekly.resets_at // null)},
      plan_type:($selected.plan_type // $plan // null),
      accounts:$merged,current_account:$selected.account}}}' <<<"$cache_event" 2>/dev/null || true)
  [ -n "$merged" ] || return 0
  codex_event=$merged
  codex_origin=usage
  codex_source=codex-app-server
  [ "$(jq -r '.payload.rate_limits.current_account // "main"' <<<"$merged")" != main ] || codex_source=session-rollout
}

codex_refresh_target=''
case "$refresh_account" in codex/*) codex_refresh_target=${refresh_account#codex/} ;; esac
if [ "$refresh" -eq 1 ] && ! vendor_paused codex &&
   { [ -z "$refresh_account" ] || [ -n "$codex_refresh_target" ] || [ "$refresh_vendor" = codex ]; }; then
  if [ "${LLM_LIMITS_CODEX_REFRESH:-1}" != 0 ]; then
    codex_refresh_attempted=1
    refresh_codex_quota "$codex_refresh_target" || true
  elif [ -n "$codex_refresh_target" ] || [ "$refresh_vendor" = codex ]; then
    codex_refresh_attempted=1
    codex_refresh_error='refresh disabled'
    printf 'llm-limits.sh: Codex%s refresh is disabled\n' \
      "$([ -n "$codex_refresh_target" ] && printf ' account %s' "$codex_refresh_target")" >&2
  fi
fi
codex_event=''
vendor_paused codex || select_codex_event

if [ "$start_windows" -eq 1 ] && [ -z "$refresh_account" ] && ! vendor_paused codex; then
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
    codex_order=$(jq -r '[.payload.rate_limits.accounts[]?.account // "main"] | .[]' <<<"$codex_event" \
      | account_order_json codex)
    codex=$(jq -cn --argjson e "$codex_event" --argjson wall "$codex_wall" --argjson now "$now_epoch" \
      --argjson order "$codex_order" \
      --arg five_reset "$five_reset" --arg week_reset "$week_reset" \
      --arg as_of "$(epoch_iso "$codex_epoch")" --argjson as_of_epoch "$codex_epoch" \
      --arg origin "$codex_origin" --arg source "$codex_source" --argjson stale "$stale" \
      --argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY" \
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
         as_of:$bucket_asof,origin:($b.origin // $origin),stale:(($now - $bucket_asof) > $threshold)};
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
             five_hour:bucket(($a.five_hour // {}); null; $account_asof; $thr5),
             weekly:bucket(($a.weekly // {}); null; $account_asof; $thrw),
             as_of:($account_asof | todateiso8601),stale_seconds:$account_age}
          end) +
         (if ($a.reset_credits | type) == "number" then
            (if ($a.reset_credits_as_of | type) == "number" then $a.reset_credits_as_of else $account_asof end) as $credits_asof |
            {reset_credits:$a.reset_credits,reset_credits_as_of:$credits_asof,
             reset_credits_stale:(([$now - $credits_asof, 0] | max) > $thrw)}
          else {} end) +
         (if ($a.reset_credits_expires_at | type) == "string" then
            {reset_credits_expires_at:$a.reset_credits_expires_at} else {} end));
      (if (($e.payload.rate_limits.accounts | type) == "array") and
          ($e.payload.rate_limits.accounts | length) > 0 then
         ($e.payload.rate_limits.current_account // "main") as $requested |
         (if any($e.payload.rate_limits.accounts[]; (.account // "main") == $requested)
          then $requested else ($e.payload.rate_limits.accounts[0].account // "main") end) as $current |
         [$e.payload.rate_limits.accounts[] | account(.; $current)] |
         sort_by(.account as $n | (($order | index($n)) // ($order | length)))
       else
         [{account:"main",is_current:true,enabled:($pool_out != null and ($pool_out | index("main")) == null),
           plan_type:($e.payload.rate_limits.plan_type // null),
           five_hour:{used_pct:$e.payload.rate_limits.primary.used_percent,
                      resets_at:(if $five_reset == "" then null else $five_reset end),
                      as_of:$as_of_epoch,origin:$origin,stale:($stale > $thr5)},
           weekly:{used_pct:$e.payload.rate_limits.secondary.used_percent,
                   resets_at:(if $week_reset == "" then null else $week_reset end),
                   as_of:$as_of_epoch,origin:$origin,stale:($stale > $thrw)},
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

# Live weekly quota through the Grok CLI's own billing endpoint (GET /v1/billing?format=credits):
# a usage query on the token the CLI already maintains, so zero token spend — and read-only, since
# the CLI owns auth.json rotation and a second writer there is the one real hazard.
grok_cache=${LLM_LIMITS_GROK_CACHE:-$HOME/.llm-limits-grok.json}
grok_refresh_error=''
grok_refresh_attempted=0
refresh_grok_quota() {
  local target=${1:-} grok_quota_cmd=${LLM_LIMITS_GROK_QUOTA:-$script_dir/grok-quota.py}
  local grok_tmp grok_err fresh old merged detail rc account touch_names
  local -a helper_args=(--profiles-dir "$grok_profiles_dir"
    --timeout "${LLM_LIMITS_GROK_QUOTA_TIMEOUT:-10}")
  if [ ! -x "$grok_quota_cmd" ]; then
    grok_refresh_error='helper not executable'
    echo "llm-limits.sh: Grok quota helper is not executable: $grok_quota_cmd" >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "$grok_cache")"; then
    grok_refresh_error='cache directory failed'
    return 1
  fi
  [ -z "$target" ] || helper_args+=(--account "$target")
  # A deliberate ask — one account, or the vendor row's Hard refresh — earns the touch; the passive
  # all-vendor collection stays a plain read.
  if [ -n "$target" ]; then
    grok_touch_expired "$target"
  elif [ "$refresh_vendor" = grok ]; then
    touch_names=()
    while IFS= read -r account; do [ -z "$account" ] || touch_names+=("$account"); done < <(grok_account_names)
    [ "${#touch_names[@]}" -eq 0 ] || grok_touch_expired "${touch_names[@]}"
  fi
  grok_tmp=$(mktemp "${grok_cache}.tmp.XXXXXX") || { grok_refresh_error='cache temp failed'; return 1; }
  grok_err=$(mktemp "${grok_cache}.err.XXXXXX") || { rm -f "$grok_tmp"; grok_refresh_error='cache temp failed'; return 1; }
  rc=0
  "$grok_quota_cmd" "${helper_args[@]}" >"$grok_tmp" 2>"$grok_err" || rc=$?
  fresh=$(jq -c 'select((.accounts | type) == "array")' "$grok_tmp" 2>/dev/null || true)
  detail=''
  if [ -n "$fresh" ]; then
    detail=$(jq -r '[.accounts[] | select((.error | type) == "string") | .account + ": " + .error]
      | join("; ")' <<<"$fresh" 2>/dev/null || true)
  fi
  if [ -z "$fresh" ]; then
    # The helper's own last word says which failure this was; without it the cause is the exit
    # code alone, the way the codex and gemini paths never report it.
    detail=$(grep -v '^[[:space:]]*$' "$grok_err" 2>/dev/null | tail -n 1 | tr -d '\r')
    [ -n "$detail" ] || detail="helper exit $rc"
    grok_refresh_error="live query failed: $detail"
    rm -f "$grok_tmp" "$grok_err"
    printf 'llm-limits.sh: Grok%s live quota query failed: %s\n' \
      "$([ -n "$target" ] && printf ' account %s' "$target")" "$detail" >&2
    return 1
  fi
  old='{"accounts":[]}'
  if [ -r "$grok_cache" ]; then
    old=$(jq -c 'select((.accounts | type) == "array")' "$grok_cache" 2>/dev/null || true)
    [ -n "$old" ] || old='{"accounts":[]}'
  fi
  merged=$(jq -c --argjson old "$old" --argjson replace "$([ -n "$target" ] && printf 'false' || printf 'true')" '
    def stated: (.used_pct | type) == "number" or ((.auth // "ok") != "ok");
    # A transient failure states nothing about the account, so the row the last successful read
    # left stands: a network blip must not blank a percentage every surface reads as live. An
    # auth verdict is the opposite — a definite state that always replaces older data.
    def settled($old_rows): . as $new |
      (first($old_rows[] | select(.account == $new.account)) // null) as $prev |
      if ($new | stated) then $new
      elif $prev != null and ($prev | stated) then $prev
      else $new end;
    ($old.accounts // []) as $old_rows |
    [.accounts[] | settled($old_rows)] as $rows |
    if $replace then {accounts:$rows}
    else
      ([$rows[].account]) as $names |
      {accounts:($rows + [$old_rows[] | select(.account as $n | ($names | index($n)) == null)])}
    end' <<<"$fresh" 2>/dev/null || true)
  # A leg with no accounts at all read nothing because there was nothing to read: calling that a
  # failed refresh would leave an empty vendor permanently red on every surface.
  if [ -n "$merged" ] && [ -z "$detail" ] &&
     jq -e '(.accounts | length) == 0' <<<"$merged" >/dev/null 2>&1; then
    if ! printf '%s\n' "$merged" >"$grok_tmp" || ! mv -f "$grok_tmp" "$grok_cache"; then
      grok_refresh_error='cache replace failed'
      rm -f "$grok_tmp" "$grok_err"
      return 1
    fi
    rm -f "$grok_err"
    grok_refresh_error=''
    return 0
  fi
  if [ -z "$merged" ] ||
     ! jq -e '[.accounts[] | select((.used_pct | type) == "number" or ((.auth // "ok") != "ok"))]
              | length > 0' <<<"$merged" >/dev/null 2>&1; then
    [ -n "$detail" ] || detail='live query failed'
    grok_refresh_error=$detail
    rm -f "$grok_tmp" "$grok_err"
    printf 'llm-limits.sh: Grok%s live quota query failed: %s\n' \
      "$([ -n "$target" ] && printf ' account %s' "$target")" "$detail" >&2
    return 1
  fi
  if ! printf '%s\n' "$merged" >"$grok_tmp" || ! mv -f "$grok_tmp" "$grok_cache"; then
    grok_refresh_error='cache replace failed'
    rm -f "$grok_tmp" "$grok_err"
    return 1
  fi
  rm -f "$grok_err"
  grok_refresh_error=$detail
  if [ -n "$detail" ]; then
    printf 'llm-limits.sh: Grok%s partial quota read: %s\n' \
      "$([ -n "$target" ] && printf ' account %s' "$target")" "$detail" >&2
    return 1
  fi
}

grok_refresh_target=''
case "$refresh_account" in grok/*) grok_refresh_target=${refresh_account#grok/} ;; esac
# A name off the roster resolves to a directory with no auth.json, which the helper answers as a
# definite `needs_login` verdict — and that would write a phantom account into the store and the
# menu, asking Egor to log into an account that does not exist.
if [ -n "$grok_refresh_target" ] && ! grep -qxF "$grok_refresh_target" <<<"$(grok_account_names)"; then
  printf 'llm-limits.sh: unknown Grok account: %s\n' "$grok_refresh_target" >&2
  exit 2
fi
if [ "$refresh" -eq 1 ] && ! vendor_paused grok &&
   { [ -z "$refresh_account" ] || [ -n "$grok_refresh_target" ] || [ "$refresh_vendor" = grok ]; }; then
  if [ "${LLM_LIMITS_GROK_REFRESH:-1}" != 0 ]; then
    grok_refresh_attempted=1
    refresh_grok_quota "$grok_refresh_target" || true
  elif [ -n "$grok_refresh_target" ] || [ "$refresh_vendor" = grok ]; then
    grok_refresh_attempted=1
    grok_refresh_error='refresh disabled'
    printf 'llm-limits.sh: Grok%s refresh is disabled\n' \
      "$([ -n "$grok_refresh_target" ] && printf ' account %s' "$grok_refresh_target")" >&2
  fi
fi

grok_payload='{"accounts":[]}'
if ! vendor_paused grok && [ -r "$grok_cache" ]; then
  grok_payload=$(jq -c 'select((.accounts | type) == "array")' "$grok_cache" 2>/dev/null || true)
  [ -n "$grok_payload" ] || grok_payload='{"accounts":[]}'
fi
grok_cache_mtime=$(int_or_empty "$(file_mtime "$grok_cache" 2>/dev/null || true)")
[ -n "$grok_cache_mtime" ] || grok_cache_mtime=$now_epoch
grok_pin=$(worker_model_pinned_account grok_profile 2>/dev/null || true)
grok_order=$(jq -r '.accounts[]?.account // empty' <<<"$grok_payload" | account_order_json grok)
grok=$(jq -cn --argjson payload "$grok_payload" --argjson wall "$grok_wall" --argjson now "$now_epoch" \
  --argjson order "$grok_order" --argjson mtime "$grok_cache_mtime" --arg pin "$grok_pin" \
  --argjson thrw "$LIMITS_STALE_WEEKLY" \
  --argjson pool_out "$(worker_pool_disabled_json "$grok_pool_dir")" '
  def enabled($name): ($pool_out != null and ($pool_out | index($name)) == null);
  def account($a; $current):
    (if ($a.as_of | type) == "number" then $a.as_of else $mtime end) as $asof |
    ([$now - $asof, 0] | max) as $age |
    ($a.auth // null) as $auth |
    {account:$a.account,is_current:($a.account == $current),enabled:enabled($a.account)} +
    (if ($auth | type) == "string" then
       {auth:{status:$auth}} +
       # `expired` is refreshable by the CLI itself, so only `needs_login` is a state no
       # automated path can leave — the one that must reach Egor as an action.
       (if $auth == "needs_login" then {auth_needed:true,status:"login needed"} else {} end)
     else {} end) +
    (if ($a.used_pct | type) == "number" then
       {weekly:{used_pct:$a.used_pct,resets_at:($a.resets_at // null),
                as_of:$asof,origin:"billing",stale:($age > $thrw)},
        as_of:($asof | todateiso8601),stale_seconds:$age}
     else {} end) +
    (if ($a.plan_type | type) == "string" then {plan_type:$a.plan_type} else {} end) +
    (if ($a.email | type) == "string" then {email:$a.email} else {} end) +
    (if ($a.period | type) == "string" then {period:$a.period} else {} end) +
    (if ($a.build_pct | type) == "number" then {build_pct:$a.build_pct} else {} end) +
    (if ($a.reset_credits | type) == "number" then
       (if ($a.reset_credits_as_of | type) == "number" then $a.reset_credits_as_of else $asof end) as $credits_asof |
       {reset_credits:$a.reset_credits,reset_credits_as_of:$credits_asof,
        reset_credits_stale:(([$now - $credits_asof, 0] | max) > $thrw)}
     else {} end) +
    (if ($a.reset_credits_expires_at | type) == "string" then
       {reset_credits_expires_at:$a.reset_credits_expires_at} else {} end) +
    (if ($a.cause | type) == "string" then {cause:$a.cause} else {} end);
  # Rows are ordered before anything reads "the first one": a targeted refresh rewrites the cache
  # in its own order, and current-account picked off that would follow whichever account was
  # refreshed last.
  ($payload.accounts // []
   | sort_by(.account as $n | (($order | index($n)) // ($order | length)))) as $rows |
  # The pin is the deliberate "this account" and outranks the roster; without one the first
  # account a worker could actually use is the one every surface names as current.
  (if $pin != "" and any($rows[]; .account == $pin) then $pin
   else ((first($rows[] | select(enabled(.account)) | .account)) // ($rows[0].account // null)) end) as $current |
  ([$rows[] | account(.; $current)]) as $accounts |
  (first($accounts[] | select(.is_current)) // $accounts[0] // null) as $selected |
  if ($accounts | length) == 0 then
    {available:false,status:"no quota snapshot",source:"grok-billing",last_wall:$wall}
  else
    {available:true,current_account:$selected.account,accounts:$accounts,
     source:"grok-billing",last_wall:$wall} +
    (if ($selected.weekly | type) == "object" then
       ($selected | {weekly,as_of,stale_seconds}) +
       (if ($selected.plan_type | type) == "string" then {plan_type:$selected.plan_type} else {} end)
     elif $selected.auth_needed == true then {auth_needed:true,status:"login needed"}
     else {status:"no quota snapshot"} end)
  end')

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
      --argjson stale "$stale" --arg auth "$gemini_auth" \
      --argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY" '
      def used($remaining):
        ((1 - $remaining) * 100) |
        (if . < 0 then 0 elif . > 100 then 100 else . end) | round;
      {account:$account,enabled:$enabled,source:"agy-local-rpc",group:$d.group,
       five_hour:{used_pct:used($d.five.remainingFraction),resets_at:$d.five.resetTime,
                  as_of:$as_of_epoch,origin:"usage",stale:($stale > $thr5)},
       weekly:{used_pct:used($d.week.remainingFraction),resets_at:$d.week.resetTime,
               as_of:$as_of_epoch,origin:"usage",stale:($stale > $thrw)},
       as_of:$as_of,stale_seconds:$stale}
      | if $auth == "1" then . + {auth_needed:true,status:"login needed"} else . end')
  elif [ "$gemini_auth" = 1 ]; then
    gemini_account_json=$(jq -cn --arg account "$gemini_account" --argjson enabled "$gemini_enabled" \
      --arg as_of "$(epoch_iso "$gemini_mtime")" --argjson as_of_epoch "$gemini_mtime" \
      '{account:$account,enabled:$enabled,auth_needed:true,
        status:"login needed",source:"agy-local-rpc",as_of:$as_of,as_of_epoch:$as_of_epoch}')
  else
    # No cache and no auth marker = the account has never been refreshed. Emit
    # nothing, matching claude/codex: accounts exist for the menu only via their
    # vendor cache; the add/create announce hook is what first populates it.
    gemini_account_json=''
  fi
  if [ -e "$gemini_removed_marker" ]; then
    # Only NAMED accounts reach this: a removed one is a profile whose creds went bad, so valid
    # creds again (owner re-logged in via agy) self-clear it. main never reaches it — its removal
    # is deliberate, and a self-clear would undo `geminib remove main` on the very next collect.
    if printf '%s' "$gemini_account_json" | jq -e '.auth_needed != true and (.five_hour | type) == "object"' >/dev/null 2>&1; then
      rm -f "$gemini_removed_marker"
    else
      gemini_account_json=$(jq -cn --arg account "$gemini_account" --argjson enabled "$gemini_enabled" \
        '{account:$account,enabled:$enabled,removed:true,
          status:"removed",source:"agy-local-rpc"}')
    fi
  fi
  [ -n "$gemini_account_json" ] || continue
  gemini_account_lines="${gemini_account_lines}${gemini_account_json}"$'\n'
done <<<"$gemini_accounts_list"

gemini_order=$(printf '%s\n' "$gemini_accounts_list" | account_order_json gemini)
if [ "$write_cache" -eq 1 ]; then
  if ! mkdir -p "$(dirname "$cache")"; then
    echo "llm-limits.sh: cache directory creation failed" >&2
    exit 5
  fi
  # Only a held lock goes into cache_lock: the EXIT trap must never release one we lost.
  cache_lock_path="${cache}.lock"
  if ! store_lock_acquire "$cache_lock_path"; then
    echo "llm-limits.sh: cache lock acquisition failed" >&2
    exit 5
  fi
  cache_lock=$cache_lock_path
  # Re-read under the lock so every merge includes the preceding writer's update.
  previous_cache='{}'
  if [ -r "$cache" ]; then
    previous_cache=$(jq -c 'select(.schema == 1 and (.vendors | type) == "object")' "$cache" 2>/dev/null || true)
    [ -n "$previous_cache" ] || previous_cache='{}'
  fi
fi
gemini_accounts=$(printf '%s' "$gemini_account_lines" | jq -sc --argjson order "$gemini_order" \
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
  | sort_by(.account as $n | (($order | index($n)) // ($order | length)))
  # The base profile is deletable like every other account, so no fixed name can be the current one.
  | (first(.[] | select(.removed != true and .enabled != false) | .account) //
     first(.[] | select(.removed != true) | .account) // null) as $current
  | map(.is_current = (.account == $current))
')

gemini_refresh_error=$(jq -rn --argjson rows "$gemini_accounts" --argjson records "$gemini_refresh_records" '
  ($rows | map(.account)) as $listed |
  # A failed refresh of an account with no emitted row (never cached) must still
  # surface as a vendor error, like claude/codex vendor-level refresh errors.
  ($records | group_by(.account) | map(last) |
   map(select((.error // "") != "" and (.account as $a | $listed | index($a) | not)) |
       {account:.account,error:.error})) as $orphans |
  (([$rows[] | select(.removed != true) |
     {account:.account,error:(.refresh_error.cause // "")} | select(.error != "")]) + $orphans) as $errors |
  if ($errors | length) == 0 then ""
  elif ($errors | length) == 1 and $errors[0].account == "main" then $errors[0].error
  else $errors | map(.account + ": " + .error) | join("; ")
  end
')

gemini_main_removed_json=false
if gemini_main_removed; then gemini_main_removed_json=true; fi
gemini=$(jq -cn --argjson accounts "$gemini_accounts" --argjson wall "$gemini_wall" \
  --argjson main_removed "$gemini_main_removed_json" '
  [$accounts[] | select(.removed != true)] as $visible |
  [$visible[] |
   select(.auth_needed != true and
          (.five_hour.used_pct | type) == "number" and
          (.weekly.used_pct | type) == "number" and
          .five_hour.used_pct < 100 and .weekly.used_pct < 100)] as $usable |
  (first($accounts[] | select(.is_current)) // $visible[0] // null) as $current |
  ($usable | sort_by(if .account == "main" then 1 else 0 end,
                     ([.five_hour.used_pct,.weekly.used_pct] | max), .account) | .[0]) as $selected |
  if ($accounts | length) == 0 then
    # `geminib remove main` takes main out of the roster instead of leaving a row behind, so with
    # no profile beside it the vendor states its removal HERE — it is the one thing that tells a
    # store Egor emptied on purpose from one whose accounts have simply never been refreshed, and
    # the menubar skips a removed vendor whole where it renders the other as "no live data".
    {available:false,source:"agy-local-rpc",last_wall:$wall} +
    (if $main_removed then {removed:true,status:"removed"}
     else {status:"no quota snapshot"} end)
  # The flat shape is what a store holding nothing but the base profile has always been; every
  # other roster, main deleted or not, is rendered as named account rows.
  elif ($accounts | length) == 1 and $accounts[0].account == "main" then
    $accounts[0]
    | del(.account,.is_current)
    | .available = (.removed != true and .auth_needed != true and
                    (.five_hour | type) == "object" and (.weekly | type) == "object")
    | .last_wall = $wall
  else
    ({available:(($usable | length) > 0),accounts:$accounts,
      source:"agy-local-rpc",last_wall:$wall} +
     (if $current == null then {} else {current_account:$current.account} end) +
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
  refresh_attempts=$((claude_refresh_attempted + codex_refresh_attempted + gemini_refresh_attempted + grok_refresh_attempted))
  refresh_successes=0
  if [ "$claude_refresh_attempted" -eq 1 ] && [ "$claude_refresh_succeeded" -eq 1 ]; then refresh_successes=$((refresh_successes + 1)); fi
  if [ "$codex_refresh_attempted" -eq 1 ] && [ -z "$codex_refresh_error" ]; then refresh_successes=$((refresh_successes + 1)); fi
  if [ "$gemini_refresh_attempted" -eq 1 ] && [ "$gemini_refresh_succeeded" -eq 1 ]; then refresh_successes=$((refresh_successes + 1)); fi
  if [ "$grok_refresh_attempted" -eq 1 ] && [ -z "$grok_refresh_error" ]; then refresh_successes=$((refresh_successes + 1)); fi
  if [ "$refresh_attempts" -gt 0 ] && [ "$refresh_successes" -eq 0 ]; then
    global_refresh_error='all vendor refreshes failed'
  fi
fi

# OpenCode Go publishes no usage endpoint, so there is no percentage to collect and never will be:
# an account has exactly two knowable states, a refusal the gateway stated and the last completion
# it served, both written by bin/opencode-go at the request itself. Whether a recorded wall still
# stands is decided HERE and nowhere else, by reading the two against each other (shared-invariants
# row al) — the menubar and bin/llm-refresh render these rows like every other vendor's.
opencode_state_dir=${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}
opencode_profiles_file=${OPENCODE_GO_PROFILES:-$HOME/.config/opencode-go/profiles}
opencode_profiles() {
  if [ -r "$opencode_profiles_file" ]; then
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$opencode_profiles_file" |
      grep -v -e '^#' -e '^$'
  else
    printf -- '-\n'
  fi
}

opencode_seen_tsv=''
if ! vendor_paused opencode; then
  opencode_seen_tsv=$(opencode_profiles | while IFS= read -r opencode_profile; do
    [ -n "$opencode_profile" ] || continue
    if [ "$opencode_profile" = '-' ]; then
      opencode_service=opencode-go
    else
      opencode_service="opencode-go-$opencode_profile"
    fi
    printf '%s\t%s\t%s\n' "$opencode_profile" "$opencode_service" \
      "$(cat "$opencode_state_dir/opencode-seen/$opencode_service" 2>/dev/null | tr -dc '0-9')"
  done)
fi

opencode=$(jq -Rsc --argjson now "$now_epoch" \
  --arg walls "$(cat "$opencode_state_dir/walls.jsonl" 2>/dev/null)" \
  --argjson alarm "$LIMITS_AGE_ALARM" "$LIMITS_VIEW_JQ"'
  def marks: {"5-hour":"5h","weekly":"wk","monthly":"mo"};
  def mark_of: marks[.window // ""] // "?";
  ($walls | split("\n") | map(fromjson? // empty) |
   map(select(.side == "opencode" and .bucket == "general" and
              (.account | type) == "string" and (.detected_at | type) == "number"))) as $rows |
  # The clock retires nothing here. The gateway states a reset to the day, so a window is regularly
  # shut hours past the horizon it named, and the only thing that ever proved the plan open again is
  # a completion it served: a refusal recorded after the last served call still stands, however old
  # it is and whatever date it carried. A tie goes to the wall: only a standing wall is ever probed
  # again, so a same-second pair read as served would freeze a walled account clean forever.
  def standing($service; $served):
    [$rows[] | select(.account == $service and ($served == null or .detected_at >= $served))] |
    group_by(mark_of) |
    [.[] |
      {window:(.[0] | mark_of),
       resets_at:([.[] | select((.reset_at | type) == "number") | .reset_at] | max)}] as $windows |
    # "?" is a pre-window legacy record; beside a named wall it re-states the same 429.
    ([$windows[] | select(.window != "?")]) as $named |
    (if ($named | length) > 0 then $named else $windows end) |
    sort_by(.window as $mark | ["5h","wk","mo","?"] | index($mark));
  split("\n") | map(select(length > 0) | split("\t")) |
  map(.[0] as $profile | .[1] as $service |
      (.[2] | if . == "" then null else tonumber end) as $served |
      standing($service; $served) as $windows |
      {account:$profile, walled:(($windows | length) > 0),
       windows:[$windows[] | {window, resets_at:(.resets_at | if . == null then null else todateiso8601 end)}]} +
      # The age is when the plan last SERVED this account. A 429 is not an answer about the account
      # being alive, and dating the row by one would show a walled account getting fresher the more
      # often it refuses.
      (if $served == null then {age_alarm:true}
       else ([$now - $served, 0] | max) as $age |
         {as_of:($served | todateiso8601), stale_seconds:$age,
          age_alarm:limits_age_alarm($age; $alarm)} end)) |
  {source:"opencode-go", accounts:., age_alarm:true}' <<<"$opencode_seen_tsv")
[ -n "$opencode" ] || opencode='{"source":"opencode-go","accounts":[],"age_alarm":true}'

for shield_vendor in claude codex gemini grok; do
  ! vendor_paused "$shield_vendor" || continue
  case "$shield_vendor" in
    claude) shield_payload=$claude ;;
    codex) shield_payload=$codex ;;
    gemini) shield_payload=$gemini ;;
    grok) shield_payload=$grok ;;
  esac
  # Reconciliation writes and removes pool markers: under --no-write the read must not change
  # worker-pool membership, and a marker write failure must not kill a read-only table.
  if [ "$write_cache" -eq 1 ]; then
    reconcile_vendor_shields "$shield_vendor" "$shield_payload" || {
      printf 'llm-limits.sh: failed to reconcile %s worker-pool shield\n' "$shield_vendor" >&2
      exit 5
    }
  fi
  shield_payload=$(apply_vendor_shield_state "$shield_vendor" "$shield_payload") || {
    printf 'llm-limits.sh: failed to apply %s worker-pool shield state\n' "$shield_vendor" >&2
    exit 5
  }
  case "$shield_vendor" in
    claude) claude=$shield_payload ;;
    codex) codex=$shield_payload ;;
    gemini) gemini=$shield_payload ;;
    grok) grok=$shield_payload ;;
  esac
done

# Live experiments travel with the data so consumers need no repo knowledge.
experiments_json=$(experiments_active_lines "$(experiments_registry_path "$script_dir")" \
  | jq -Rsc 'split("\n") | map(select(length > 0))')
[ -n "$experiments_json" ] || experiments_json='[]'

if ! result=$(jq -cn --arg fetched_at "$(local_iso)" --argjson experiments "$experiments_json" --argjson claude "$claude" \
  --argjson codex "$codex" --argjson gemini "$gemini" --argjson grok "$grok" \
  --argjson opencode "$opencode" --argjson now "$now_epoch" \
  --argjson previous "$previous_cache" --argjson refresh "$refresh" --arg refresh_account "$refresh_account" \
  --argjson claude_attempted "$claude_refresh_attempted" --argjson codex_attempted "$codex_refresh_attempted" \
  --argjson gemini_attempted "$gemini_refresh_attempted" --argjson grok_attempted "$grok_refresh_attempted" \
  --arg global_error "$global_refresh_error" \
  --arg claude_error "$claude_refresh_error" --arg codex_error "$codex_refresh_error" \
  --arg gemini_error "$gemini_refresh_error" --arg grok_error "$grok_refresh_error" \
  --arg claude_target "$claude_refresh_target" --arg codex_target "$codex_refresh_target" \
  --arg gemini_target "$gemini_refresh_target" --arg grok_target "$grok_refresh_target" \
  --argjson alarm "$LIMITS_AGE_ALARM" --argjson paused "$paused_vendors_json" \
  "$iso_def$LIMITS_VIEW_JQ"'
  def normalize_reset:
    . as $value |
    if $value == null or $value == "" then null
    elif ($value | type) == "number" then
      if $value < limits_reset_epoch_floor then null else ($value | todateiso8601) end
    elif ($value | type) == "string" then
      ($value | iso2epoch) as $epoch |
      if $epoch != null and $epoch < limits_reset_epoch_floor then null else $value end
    else null
    end;
  def drop_ancient_reset:
    if limits_reset_ancient($now; (.resets_at | iso2epoch)) then .resets_at = null else . end;
  def mark:
    if type == "object" and has("used_pct")
    then .resets_at = ((.resets_at // null) | normalize_reset) |
      # A row whose date THIS pass drops must survive the next one: every collection walks the
      # merged document, cached rows included, and a bucket judged by a date that is gone would
      # come back unexpired — its dead reading rendered as a live percentage.
      (limits_bucket_expired($now; (.resets_at | iso2epoch))
       or (.resets_at == null and .expired == true)) as $x |
      drop_ancient_reset |
      if $x
      then . + {expired:true,effective_pct:0}
      else . + {effective_pct:.used_pct}
      end
    # A window nobody measured still carries the date it was told, and every surface reads that
    # field as a schedule whether or not a percentage sits beside it.
    elif type == "object" and has("resets_at")
    then .resets_at = ((.resets_at // null) | normalize_reset) | drop_ancient_reset
    else . end;
  def data_as_of:
    [.five_hour?, .weekly?, .fable? |
      select(type == "object" and (.used_pct | type) == "number") |
      (.as_of | if type == "number" then . elif type == "string" then iso2epoch else null end)] |
    map(select(. != null)) | min;
  def set_data_age:
    data_as_of as $asof |
    (if $asof == null then del(.as_of, .stale_seconds)
     else .as_of = ($asof | todateiso8601) |
       .stale_seconds = ([$now - $asof, 0] | max)
     end)
    | .age_alarm = limits_age_alarm((if (.stale_seconds | type) == "number"
                                     then .stale_seconds else null end); $alarm);
  def under_limit($bucket):
    ($bucket | type) != "object" or $bucket.effective_pct == null or $bucket.effective_pct < 100;
  def account_usable($key):
    .removed != true and
    .enabled != false and
    .auth_needed != true and
    (if $key == "grok" then
       ((.auth.status? // "ok") | IN("ok", "expired"))
     else
       ((.auth.status? // "") != "expired" and (.auth.status? // "") != "failed")
     end) and
    (if $key == "gemini" then
       (.five_hour.effective_pct | type) == "number" and
       (.weekly.effective_pct | type) == "number"
     elif $key == "grok" then (.weekly.effective_pct | type) == "number"
     else true end) and
    under_limit(.five_hour) and under_limit(.weekly);
  def vendor_usable($key):
    if $key == "claude" or $key == "codex" or $key == "grok" or
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
  def user_entry_cause:
    . == "needs-relogin" or . == "needs re-login" or
    startswith("login needed") or test("needs-?relogin") or test("needs.?login");
  def classify_cause:
    if test("helper not executable|claudeb not found|helper missing") then "helper missing"
    elif test("refresh disabled") then "refresh disabled"
    elif test("timed? ?out|timeout") then "timeout"
    elif test("login needed|needs-?relogin|needs re-login|needs.?login|not signed in|auth_needed") then "login needed"
    elif test("deactivated_workspace") then "workspace deactivated"
    elif test("402|Payment Required|payment required") then "402 payment required"
    elif test("(^|[^0-9])40[13]([^0-9]|$)|unauthorized|forbidden") then "401/403 auth"
    elif test("(^|[^0-9])429([^0-9]|$)|rate[- ]?limit|too many requests") then "429 rate limit"
    elif test("(^|[^0-9])5[0-9]{2}([^0-9]|$)|server error|internal server") then "5xx server error"
    elif test("not refreshed \\(") then
      "not refreshed (" + ((capture("not refreshed \\((?<w>.*)\\)$") // {w:"?"}) | .w) + ")"
    elif test("not refreshed") then "not refreshed"
    else "refresh failed"
    end;
  # A leading word is an ATTRIBUTION only when the roster of this vendor holds that account. A
  # leading `curl: `, `jq: ` or `error: ` is the shape of a cause, and read as a name it invented an
  # account nobody has — which drop_unknown then discarded along with the cause it was carrying. An
  # empty roster is no evidence either way, so there the prefix is read as before.
  def account_prefix($roster):
    (if test("^[a-z0-9][a-z0-9-]*: ") then capture("^(?<a>[a-z0-9][a-z0-9-]*): ").a
     elif test("^[a-z0-9][a-z0-9-]* auth(?: \\(.*\\))?$") then capture("^(?<a>[a-z0-9][a-z0-9-]*) auth").a
     else null end) as $a |
    if $a == null or ($roster | length) == 0 then $a
    elif ($roster | index($a)) != null then $a
    else null end;
  # "; " starts a new error when the next fragment is an account prefix; free prose with ": "
  # ("agy exited during startup: broken pipe") and HTTP bodies must stay one cause.
  def split_legacy_cause($roster):
    if type != "string" or . == "" then []
    else
      split("; ") as $parts |
      reduce $parts[] as $part (
        {chunks: [], cur: ""};
        if .cur == "" then .cur = $part
        elif ($part | account_prefix($roster)) != null then .chunks += [.cur] | .cur = $part
        else .cur = (.cur + "; " + $part)
        end
      ) | .chunks + (if .cur == "" then [] else [.cur] end)
    end;
  def entry_account($roster; $target):
    account_prefix($roster) as $a |
    if $a != null then $a
    elif $target != "" then $target
    else null end;
  def parse_entries($cause; $at; $roster; $target):
    if ($cause | type) != "string" or $cause == "" then []
    else
      [$cause | split_legacy_cause($roster)[] |
        {account:(entry_account($roster; $target)), cause:., at:$at}]
    end;
  def classify_entry:
    if (.cause | type) != "string" then .
    else
      .class = (.cause | classify_cause) |
      if (.class == "login needed") or (.class == "workspace deactivated") or
         (.cause | user_entry_cause) or (.cause | test(" auth(?: \\(.*\\))?$"))
      then .needs_user_entry = true else del(.needs_user_entry) end
    end;
  def roster_names:
    if (.accounts | type) == "array" then [.accounts[] | select(.removed != true) | .account]
    else [] end;
  def account_error_entries:
    if (.accounts | type) != "array" then []
    else
      [.accounts[] | select((.refresh_error.cause | type) == "string") |
        {account, cause:.refresh_error.cause, at:((.refresh_error.at // $now))}]
    end;
  def drop_unknown($roster):
    if ($roster | length) == 0 then .
    else map(select(.account == null or (.account as $a | ($roster | index($a)) != null)))
    end;
  def heal_entries($accounts):
    map(. as $e |
      if ($e.account == null) or (($e.cause | test("^[^:]+: not refreshed \\(")) | not) then $e
      else
        (first($accounts[]? | select(.account == $e.account) | .five_hour.as_of)) as $asof |
        if ($asof | type) == "number" and $asof > $e.at then empty else $e end
      end);
  def previous_entries($old; $roster):
    if ($old.refresh_errors | type) == "array" then
      [($old.refresh_errors[]? |
        parse_entries(.cause; (.at // $now); $roster; (.account // ""))[])]
    else parse_entries(($old.refresh_error.cause // ""); ($old.refresh_error.at // $now); $roster; "")
    end;
  # A vendor cause with no account (a sole failing account is reported unprefixed) describes the
  # same failure as the account row that produced it, so it absorbs it like a same-account entry.
  def absorb_account_errs($acct):
    . as $base |
    $base + [$acct[] | . as $e |
      select(all($base[];
        ((.account != null) and (.account != $e.account)) or
        ((.cause != $e.cause) and ((.cause | contains($e.cause)) | not))))];
  def to_legacy($entries):
    if ($entries | length) == 0 then null
    else
      {cause:($entries | map(.cause) | join("; ")), at:($entries | map(.at) | min)} |
      if ($entries | all(.needs_user_entry == true)) then .needs_user_entry = true else . end
    end;
  def apply_vendor_errors($key; $attempted; $cause; $target):
    . as $vendor |
    ($vendor | roster_names) as $roster |
    previous_entries($previous.vendors[$key] // {}; $roster) as $prev |
    parse_entries($cause; $now; $roster; $target) as $incoming |
    ($vendor | account_error_entries) as $acct |
    (if $attempted != 1 then $prev
     elif $key == "gemini" or $target == "" then $incoming
     else [$prev[] | select(.account != $target)] + $incoming
     end | absorb_account_errs($acct)
         | unique_by([.account // "", .cause])
         | drop_unknown($roster)
         | heal_entries($vendor.accounts // [])
         | map(classify_entry));
  def mark_user_entry_accounts:
    ([.refresh_errors[]? | select(.needs_user_entry == true) | .account // empty]) as $named |
    ([.refresh_errors[]? | select(.class == "workspace deactivated") | .account // empty]) as $dead |
    if (.accounts | type) != "array" then
      if .auth_needed == true or (.refresh_error.needs_user_entry // false) or
         ((.refresh_errors | type) == "array" and (.refresh_errors | length) > 0 and
          all(.refresh_errors[]; .needs_user_entry == true))
      then . + {needs_user_entry:true}
      else del(.needs_user_entry) end
    else
      .accounts |= map(
        (if (.account as $a | $dead | index($a)) != null
         then . + {auth_needed:true, status:"login needed"} else . end) |
        if (.refresh_error | type) == "object" then
          (.refresh_error |= classify_entry) |
          if .auth_needed == true
          then . + {needs_user_entry:true} | .refresh_error.needs_user_entry = true
          elif .refresh_error.needs_user_entry == true
          then . + {needs_user_entry:true}
          elif ((.account as $a | $named | index($a)) != null)
          then . + {needs_user_entry:true}
          else del(.needs_user_entry) end
        elif .auth_needed == true or ((.account as $a | $named | index($a)) != null)
        then . + {needs_user_entry:true}
        else del(.needs_user_entry)
        end)
    end;
  def row_as_of:
    [.five_hour?.as_of, .weekly?.as_of, .fable?.as_of, .as_of, .as_of_epoch] |
    map(if type == "number" then . elif type == "string" then iso2epoch else null end) |
    map(select(type == "number")) | max;
  def newest_accounts($key):
    ($previous.vendors[$key].accounts) as $old |
    if (.accounts | type) != "array" or ($old | type) != "array" then .
    else
      .accounts |= map(. as $new |
        (first($old[] | select(.account == $new.account)) // null) as $prev |
        if $new.removed == true or $prev == null then $new
        else
          ($new | row_as_of) as $new_at | ($prev | row_as_of) as $prev_at |
          if ($prev_at | type) == "number" and
             (($new_at | type) != "number" or $prev_at > $new_at)
          then
            # Local state (auth, pool usability, removal, current-account mark) is read fresh
            # by this run, so a newer cached row must not carry an older verdict of it back in —
            # including blocked/rotation, which are derived from auth+enabled and would
            # otherwise contradict the grafted fields they derive from.
            ($prev | del(.auth, .auth_needed, .enabled, .shielded, .removed, .blocked, .rotation, .is_current))
            + ($new | {auth,auth_needed,enabled,shielded,removed,blocked,rotation,is_current}
                    | with_entries(select(.value != null)))
          else $new end
        end)
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
    gemini:vendor_data("gemini"; $gemini; $gemini_attempted; $gemini_error),
    grok:vendor_data("grok"; $grok; $grok_attempted; $grok_error)}}
  | .vendors |= with_entries(.key as $key | .value |= newest_accounts($key))
  | .vendors.claude.refresh_errors = (.vendors.claude | apply_vendor_errors("claude"; $claude_attempted; $claude_error; $claude_target))
  | .vendors.codex.refresh_errors = (.vendors.codex | apply_vendor_errors("codex"; $codex_attempted; $codex_error; $codex_target))
  | .vendors.gemini.refresh_errors = (.vendors.gemini | apply_vendor_errors("gemini"; $gemini_attempted; $gemini_error; $gemini_target))
  | .vendors.grok.refresh_errors = (.vendors.grok | apply_vendor_errors("grok"; $grok_attempted; $grok_error; $grok_target))
  | .vendors |= with_entries(
      (.value.refresh_errors) as $ents |
      if ($ents | type) != "array" or ($ents | length) == 0
      then .value |= del(.refresh_error, .refresh_errors)
      else .value.refresh_error = to_legacy($ents) end)
  # A removed vendor has nothing a refresh could have been for, so a cause still attached to one is
  # a verdict about an account that no longer exists. `removed` is the whole test: the status word
  # is not, because the multi-account branch spells `no quota snapshot` whenever nothing is
  # selectable — every account walled at 100, every one of them removed, or a roster whose accounts
  # have never been cached and so emit no row at all — and gated on that word a real refresh
  # failure was deleted and every surface showed a failed refresh with no cause (audit,
  # 2026-08-26). Removal itself is what `geminib remove main` writes, and the empty-roster branch
  # above states it.
  | if .vendors.gemini.removed == true
    then .vendors.gemini |= del(.refresh_error, .refresh_errors) else . end
  | .vendors |= with_entries(
      .value |= (
        if (.accounts | type) == "array" then .accounts |= map(set_data_age) else . end
        | set_data_age))
  | .vendors |= with_entries(.value |= mark_user_entry_accounts)
  | .vendors |= with_entries(if .value.available == true then .value += {stale: (.value | vendor_stale)} else . end)
  | walk(mark)
  | .vendors |= with_entries(.key as $key | .value.usable_now = (.value | vendor_usable($key)))
  | if ([.vendors[] | select(.available == true)] | length) == 0
    then .refresh_error = {cause:"no vendor data available",at:$now}
    elif $refresh == 1 and $refresh_account == ""
    then if $global_error == "" then del(.refresh_error) else .refresh_error = {cause:$global_error,at:$now} end
    else old_error($previous.refresh_error) as $old_global |
      if $old_global == null then . else .refresh_error = $old_global end
    end
  # Last, and past every pass above: this vendor states no percentage, so nothing that reads one —
  # staleness, expiry, usability, the "no vendor data" verdict that decides the exit code — has
  # anything to say about it, and a pass that touched it would be inventing a reading.
  | .vendors.opencode = $opencode
  # Last of all, and after the merge above: a parked vendor collected nothing this run, so any
  # entry left here came from the previous snapshot, and every surface would read it as a live
  # measurement of a vendor nobody is polling. Absence is the whole interface — the same one a leg
  # this machine never installed leaves.
  | delpaths([$paused[] | ["vendors", .]])'); then
  echo "llm-limits.sh: failed to build cache JSON" >&2
  exit 5
fi

if ! jq -e '.schema == 1 and (.vendors | type) == "object"' <<<"$result" >/dev/null 2>&1; then
  echo "llm-limits.sh: refusing to replace cache with invalid JSON" >&2
  exit 5
fi

if [ "$write_cache" -eq 1 ]; then
  cache_tmp=$(mktemp "${cache}.tmp.XXXXXX") || { echo "llm-limits.sh: cache temp creation failed" >&2; exit 5; }
  if ! printf '%s\n' "$result" >"$cache_tmp" || ! jq -e '.schema == 1 and (.vendors | type) == "object"' "$cache_tmp" >/dev/null 2>&1; then
    echo "llm-limits.sh: cache temp validation failed" >&2
    exit 5
  fi
  if ! mv -f "$cache_tmp" "$cache"; then
    echo "llm-limits.sh: cache replace failed" >&2
    exit 5
  fi
  cache_tmp=''
  store_lock_release "$cache_lock"
  cache_lock=''
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
  plain_red=''
  if color_stdout; then
    plain_dim=$'\033[2m'
    plain_rst=$'\033[0m'
    plain_red=$'\033[31m'
  fi
  jq -r --arg dim "$plain_dim" --arg rst "$plain_rst" --arg red "$plain_red" --argjson render_now "$now_epoch" "$iso_def$LIMITS_VIEW_JQ$age_def$reset_format_def"'
    def dimmed($window):
      if ($window.expired == true or $window.stale == true) then $dim + . + $rst else . end;
    def pct($window):
      (if $window == null or $window.effective_pct == null
       then limits_pct_text(null; ($window.stale == true); ($window.expired == true))
       else (limits_pct_text($window.effective_pct; ($window.stale == true); ($window.expired == true))
             | dimmed($window))
       end);
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
    def account_status($vendor):
      if .auth_needed == true or
         ((.auth.status? | type) == "string" and .auth.status != "ok"
          and ($vendor != "grok" or .auth.status != "expired"))
      then "login needed" else "-" end;
    def aged($row): ($row | compact_age($render_now)) |
      if $row.age_alarm == true then $red + . + $rst else . end;
    def line($src; $row; $rot; $credits; $status):
      $src + ": 5h " + pct($row.five_hour) + " @ " + reset($row.five_hour) +
      " | wk " + pct($row.weekly) + " @ " + reset($row.weekly) +
      " | fb " + pct($row.fable) + " @ " + reset($row.fable) +
      " | age " + aged($row) +
      " | rot " + $rot + " | cr " + $credits + " | status " + $status;
    .vendors | to_entries[] |
    select(.value.removed != true) |
    # Every column here is a percentage or its reset; opencode states none, and a row of dashes
    # reads as a reading taken.
    select(.key != "opencode") |
    if .key == "claude" and .value.available and (.value.accounts | type) == "array" then
        .value.accounts[] |
        line("claude/" + .account + (if .is_current then "*" else "" end); .; rotation; "-"; account_status("claude"))
    elif (.key == "codex" or .key == "gemini" or .key == "grok") and
         ((.value.accounts | type) == "array") and
         ((.value.accounts | length) > 1 or
          (.key == "codex" and any(.value.accounts[]; .auth_needed == true)) or
          ((.key == "gemini" or .key == "grok") and (.value.accounts | length) > 0)) then
      .key as $key | .value.accounts[] | select(.removed != true) |
      line($key + "/" + .account + (if .is_current then "*" else "" end); .; rotation;
        credits; account_status($key))
    elif .value.available then
      line(.key; .value; ((.value.accounts[0] // .value) | rotation);
        (.value | credits); "-")
    else line(.key; {age_alarm: (.value.age_alarm == true)}; "-"; "-";
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
