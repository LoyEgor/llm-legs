# Run-observed usage walls. Path and format: docs/shared-invariants.md row bz.
# One file per vendor+account: line 1 the reset epoch, line 2 the write epoch. Unexpired → walled,
# unless llm-limits has read the account after the write and found it open (worker-pick lapses it).

worker_walls_dir() {
  printf '%s\n' "${WORKER_WALLS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-worker-runs/walls}"
}

worker_walls_valid_name() {
  [ -n "$1" ] || return 1
  case "$1" in
    */*|*..*) return 1 ;;
  esac
}

worker_walls_path() {
  worker_walls_valid_name "$1" || return 1
  worker_walls_valid_name "$2" || return 1
  printf '%s/%s-%s\n' "$(worker_walls_dir)" "$1" "$2"
}

# Same extraction print_outcome uses for RESET:.
WORKER_WALLS_RESET_RE='(try again at|retry[_ -]?at|reset(s)?([_ -]?at|[ _-]?in)?)[[:space:]:=]+[^,;]+'

worker_walls_extract_reset() {
  grep -Eioh "$WORKER_WALLS_RESET_RE" "$@" 2>/dev/null | head -n1
}

worker_walls_parse_reset() {
  local text="${1-}" rest epoch now n unit fmt
  now=$(date +%s) || return 1
  if [ -z "$text" ]; then
    printf '%s\n' "$((now + 3600))"
    return 0
  fi
  rest=$(printf '%s\n' "$text" | sed -E 's/^(try again at|retry[_ -]?at|resets?([_ -]?at|[ _-]?in)?)[[:space:]:=]+//I')
  rest=$(printf '%s\n' "$rest" | sed -E 's/([0-9])(st|nd|rd|th)/\1/g; s/^[[:space:]]+//; s/[[:space:]]+$//')
  case "$rest" in
    '') printf '%s\n' "$((now + 3600))"; return 0 ;;
    *[!0-9]*) ;;
    *) printf '%s\n' "$rest"; return 0 ;;
  esac
  n=$(printf '%s\n' "$rest" | sed -nE 's/^([0-9]+)[[:space:]]+[A-Za-z]+$/\1/p')
  unit=$(printf '%s\n' "$rest" | sed -nE 's/^[0-9]+[[:space:]]+//p' | tr '[:upper:]' '[:lower:]')
  if [ -n "$n" ]; then
    case "$unit" in
      hour|hours|hr|hrs|h) printf '%s\n' "$((now + n * 3600))"; return 0 ;;
      minute|minutes|min|mins|m) printf '%s\n' "$((now + n * 60))"; return 0 ;;
      second|seconds|sec|secs|s) printf '%s\n' "$((now + n))"; return 0 ;;
    esac
  fi
  for fmt in '%b %e %I:%M %p' '%b %d %I:%M %p' '%b %e %I:%M%p' '%b %d %I:%M%p' \
             '%b %e %H:%M' '%b %d %H:%M' '%Y-%m-%dT%H:%M:%S' '%Y-%m-%d %H:%M:%S' \
             '%Y-%m-%dT%H:%M:%SZ'; do
    epoch=$(date -j -f "$fmt" "$rest" '+%s' 2>/dev/null) || continue
    [ "$epoch" -gt "$now" ] || continue
    printf '%s\n' "$epoch"
    return 0
  done
  epoch=$(date -d "$rest" '+%s' 2>/dev/null) || true
  if [ -n "${epoch:-}" ] && [ "$epoch" -gt "$now" ]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  printf '%s\n' "$((now + 3600))"
}

worker_walls_record() {
  local vendor="$1" account="$2" epoch="$3" written="${4:-$(date +%s)}" path dir tmp
  path=$(worker_walls_path "$vendor" "$account") || return 1
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$written" in
    ''|*[!0-9]*) return 1 ;;
  esac
  dir=$(worker_walls_dir) || return 1
  mkdir -p -- "$dir" || return 1
  tmp="$path.tmp.$$"
  printf '%s\n%s\n' "$epoch" "$written" >"$tmp" && mv -f "$tmp" "$path"
}

# The write epoch of a record; empty for a one-line record written before the line existed.
worker_walls_written() {
  local path written
  path=$(worker_walls_path "$1" "$2") || return 1
  written=$(sed -n '2p' "$path" 2>/dev/null | tr -d '[:space:]')
  case "$written" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$written"
}

# Drops the record when a usage reading taken after its write shows the account open (pct < 100).
# The record stands in for the collector only until the collector has looked again; an older
# reading, an unknown reading or a one-line record leaves it in force. Returns 0 when lapsed.
worker_walls_lapse_if_read() {
  local vendor="$1" account="$2" as_of="$3" pct="$4" path written
  case "$as_of" in ''|*[!0-9]*) return 1 ;; esac
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  written=$(worker_walls_written "$vendor" "$account") || return 1
  [ -n "$written" ] || return 1
  [ "$as_of" -gt "$written" ] || return 1
  [ "$pct" -lt 100 ] || return 1
  path=$(worker_walls_path "$vendor" "$account") || return 1
  rm -f -- "$path"
}

# Prints unexpired account names for vendor. Deletes expired files.
worker_walls_fresh() {
  local vendor="$1" now="${2:-$(date +%s)}" dir prefix file epoch account
  worker_walls_valid_name "$vendor" || return 1
  dir=$(worker_walls_dir) || return 1
  [ -d "$dir" ] || return 0
  prefix="$vendor-"
  for file in "$dir"/"$prefix"*; do
    [ -f "$file" ] || continue
    account=${file##*/}
    account=${account#"$prefix"}
    [ -n "$account" ] || continue
    epoch=$(sed -n '1p' "$file" 2>/dev/null | tr -d '[:space:]') || continue
    case "$epoch" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$epoch" -gt "$now" ]; then
      printf '%s\n' "$account"
    else
      rm -f -- "$file"
    fi
  done
  return 0
}
