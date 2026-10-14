# Run-observed usage walls live in the shared limits store (docs/shared-invariants.md row bz).

worker_walls_valid_name() {
  [ -n "$1" ] || return 1
  case "$1" in
    */*|*..*) return 1 ;;
  esac
}

# Same extraction print_outcome uses for RESET:. The value must open on a digit or a month and a
# digit, or `git reset --hard` in a transcript masks the real wall line.
WORKER_WALLS_RESET_RE='\<(try again at|retry[_ -]?at|reset(s)?([_ -]?at|[ _-]?in)?)[[:space:]:=]+([0-9]|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?[[:space:]]+[0-9])([^,;"\\]|,[[:space:]]*[0-9])*'

worker_walls_extract_reset() {
  grep -Eioh "$WORKER_WALLS_RESET_RE" "$@" 2>/dev/null | tail -n1
}

# Prints nothing when the text names no time: worker_walls_record takes an empty reset as a wall
# with no vendor time, and any made-up epoch here would be shown as the vendor's.
worker_walls_parse_reset() {
  local text="${1-}" rest epoch now n unit fmt zone=''
  local -a tz=()
  now=${WORKER_WALLS_NOW:-$(date +%s)} || return 1
  [ -n "$text" ] || return 0
  rest=$(printf '%s\n' "$text" | sed -E 's/^(try again at|retry[_ -]?at|resets?([_ -]?at|[ _-]?in)?)[[:space:]:=]+//I')
  rest=$(printf '%s\n' "$rest" | sed -E 's/([0-9])(st|nd|rd|th)/\1/g; s/^[[:space:]]+//; s/[[:space:].]+$//')
  case "$rest" in
    '') return 0 ;;
    *[!0-9]*) ;;
    *) printf '%s\n' "$rest"; return 0 ;;
  esac
  if [[ "$rest" =~ ^(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?$ ]]; then
    printf '%s\n' "$((now + 10#${BASH_REMATCH[2]:-0} * 3600 + 10#${BASH_REMATCH[4]:-0} * 60 + 10#${BASH_REMATCH[6]:-0}))"
    return 0
  fi
  n=$(printf '%s\n' "$rest" | sed -nE 's/^([0-9]+)[[:space:]]+[A-Za-z]+$/\1/p')
  unit=$(printf '%s\n' "$rest" | sed -nE 's/^[0-9]+[[:space:]]+//p' | tr '[:upper:]' '[:lower:]')
  if [ -n "$n" ]; then
    case "$unit" in
      hour|hours|hr|hrs|h) printf '%s\n' "$((now + n * 3600))"; return 0 ;;
      minute|minutes|min|mins|m) printf '%s\n' "$((now + n * 60))"; return 0 ;;
      second|seconds|sec|secs|s) printf '%s\n' "$((now + n))"; return 0 ;;
    esac
  fi
  case "$rest" in
    *'('*')'*) zone=${rest##*(}; zone=${zone%%)*}; rest=${rest%%(*} ;;
    *[0-9]Z) zone=UTC; rest=${rest%Z} ;;
  esac
  case "$zone" in
    UTC) ;;
    ''|*..*|/*) zone='' ;;
    *) [ -f "/usr/share/zoneinfo/$zone" ] || zone='' ;;
  esac
  [ -z "$zone" ] || tz=(env "TZ=$zone")
  rest=$(printf '%s\n' "$rest" | sed -E 's/,/ /g; s/[[:space:]]+at[[:space:]]+/ /I; s/[[:space:]]+/ /g; s/[[:space:]]+$//
    s/(^|[[:space:]])([0-9]{1,2})[[:space:]]*([ap]m)$/\1\2:00\3/I')
  # Every format takes the `%S` tail: without it date -j reads a prefix and fills the rest from now.
  for fmt in '%I:%M %p' '%I:%M%p' '%H:%M'; do
    epoch=$(${tz[@]+"${tz[@]}"} date -j -f "$fmt %S" "$rest 00" '+%s' 2>/dev/null) || continue
    # A time without seconds that passed minutes ago is this wall clearing, not tomorrow's reset.
    [ "$epoch" -gt "$((now - 300))" ] || epoch=$(${tz[@]+"${tz[@]}"} date -j -v+1d -f "$fmt %S" "$rest 00" '+%s' 2>/dev/null) || continue
    printf '%s\n' "$epoch"
    return 0
  done
  for fmt in '%b %e %I:%M %p' '%b %d %I:%M %p' '%b %e %I:%M%p' '%b %d %I:%M%p' \
             '%b %e %H:%M' '%b %d %H:%M' '%b %e %Y %I:%M %p' '%b %e %Y %I:%M%p' '%b %e %Y %H:%M' \
             '%Y-%m-%dT%H:%M:%S' '%Y-%m-%d %H:%M:%S'; do
    epoch=$(${tz[@]+"${tz[@]}"} date -j -f "$fmt %S" "$rest 00" '+%s' 2>/dev/null) || continue
    case "$fmt" in
      %b*%Y*|%Y*) ;;
      *) if [ "$epoch" -le "$now" ]; then
           epoch=$(${tz[@]+"${tz[@]}"} date -j -v+1y -f "$fmt %S" "$rest 00" '+%s' 2>/dev/null) || continue
           [ "$epoch" -le "$((now + 2678400))" ] || continue
         fi ;;
    esac
    [ "$epoch" -gt "$now" ] || continue
    printf '%s\n' "$epoch"
    return 0
  done
  epoch=$(${tz[@]+"${tz[@]}"} date -d "$rest" '+%s' 2>/dev/null) || true
  if [ -n "${epoch:-}" ] && [ "$epoch" -gt "$now" ]; then
    printf '%s\n' "$epoch"
    return 0
  fi
}

# `weekly` only for the account's main weekly bucket, else `unknown`: grok has no other bucket, a
# parsed codex reset past any five-hour window is its weekly one, and claude names it — an Opus or
# Fable wall is a model bucket that a usage reset is not known to clear.
worker_walls_kind() { # vendor parsed-reset-epoch-or-empty run-output-file...
  local vendor="$1" epoch="$2"
  shift 2
  case "$vendor" in
    grok) echo weekly ;;
    codex) if [ -n "$epoch" ] && [ "$epoch" -gt $(($(date +%s) + 18000)) ]; then echo weekly; else echo unknown; fi ;;
    claudeb) if tail -c 65536 "$@" 2>/dev/null | grep -Eiq 'hit your weekly limit'; then echo weekly; else echo unknown; fi ;;
    *) echo unknown ;;
  esac
}

# An account the store has no row for is left alone: a row made up here would show an account the
# collector never listed, and the collector would drop it again on its next pass.
worker_walls_record() (
  local vendor="$1" account="$2" epoch="$3" written="${4:-$(date +%s)}" since="${5:-}" store tmp
  worker_walls_valid_name "$vendor" && worker_walls_valid_name "$account" || return 1
  case "$epoch:$written:$since" in *[!0-9:]*|*::*) return 1 ;; esac
  since=${since:-$written}
  [ "$vendor" != claudeb ] || vendor=claude
  store=${LLM_LIMITS_FILE:-${LLM_LIMITS_CACHE:-$HOME/.llm-limits.json}}
  [ -e "$store" ] || return 0
  . "${BASH_SOURCE[0]%/*}/store-lock.sh"
  . "${BASH_SOURCE[0]%/*}/limits-view.sh"
  store_lock_acquire "$store.lock" || return 1
  tmp=''
  trap 'test -z "$tmp" || rm -f "$tmp"; store_lock_release "$store.lock"' EXIT
  tmp=$(mktemp "$store.tmp.XXXXXX") || return 1
  jq --arg v "$vendor" --arg a "$account" --argjson vendor_reset "${epoch:-null}" --argjson at "$written" --argjson since "$since" "$LIMITS_VIEW_JQ"'
    def wall($row):
      if $vendor_reset != null then {reset:$vendor_reset, guess:{}}
      else limits_wall_most_used($row; $at).reset as $known |
        if $known != null then {reset:$known, guess:{}}
        else {reset:($since + 3600), guess:{guessed:true}} end
      end;
    def record($w):
      $w.reset as $reset |
      if (.worker_wall.recorded_at // 0) > $at then .
      else .worker_wall = {resets_at:$reset,recorded_at:$at} + $w.guess end;
    select((.schema // 1) == 1 and (.vendors | type) == "object") |
    (.vendors[$v] // null) as $block |
    if $block == null or $block.removed == true then empty
    elif ($block.accounts | type) == "array" then
      select(any($block.accounts[]; .account == $a and .removed != true)) |
      wall(first($block.accounts[] | select(.account == $a))) as $w |
      .vendors[$v].accounts |= map(if .account == $a then record($w) else . end) |
      if ($block.current_account // "main") == $a then .vendors[$v] |= record($w) else . end
    elif ($block.account // "main") == $a then wall($block) as $w | .vendors[$v] |= record($w)
    else empty end
  ' "$store" >"$tmp" || return 1
  [ -s "$tmp" ] || return 0
  mv -f "$tmp" "$store" && tmp=''
)

worker_walls_fresh() {
  worker_walls_fresh_r "$@" || return
  printf '%s' "$WORKER_WALLS_R"
}

worker_walls_fresh_r() {
  local vendor="$1" now="${2:-$(date +%s)}" store
  [ "$vendor" != claudeb ] || vendor=claude
  store=${LLM_LIMITS_FILE:-${LLM_LIMITS_CACHE:-$HOME/.llm-limits.json}}
  . "${BASH_SOURCE[0]%/*}/limits-view.sh"
  WORKER_WALLS_R=$(jq -r --arg v "$vendor" --argjson now "$now" "$LIMITS_VIEW_JQ"'
    .vendors[$v] | (.accounts // [.])[]? |
    select(limits_observed_wall(.; $now) != null) | .account // "main"
  ' "$store" 2>/dev/null) || WORKER_WALLS_R=''
}

# worker_walls_fresh_r for several vendors in one jq: `vendor<TAB>account` lines, the vendor as
# named. A vendor whose block fails lists nothing on its own, as its own jq would have.
worker_walls_fresh_vendors_r() { # now vendor...
  local now="$1" store
  shift
  store=${LLM_LIMITS_FILE:-${LLM_LIMITS_CACHE:-$HOME/.llm-limits.json}}
  . "${BASH_SOURCE[0]%/*}/limits-view.sh"
  WORKER_WALLS_R=$(jq -r --argjson now "$now" "$LIMITS_VIEW_JQ"'
    $ARGS.positional[] as $name | (if $name == "claudeb" then "claude" else $name end) as $v |
    (try [.vendors[$v] | (.accounts // [.])[]? |
      select(limits_observed_wall(.; $now) != null) | .account // "main"] catch []) |
    .[] | "\($name)\t\(.)"
  ' "$store" --args "$@" 2>/dev/null) || WORKER_WALLS_R=''
}
