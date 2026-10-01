#!/usr/bin/env bash
# Counted slots machine-wide: <dir>/<n> is a store-lock directory owned by the holder's $$, freed
# when it exits or dies. A waiter raises a limiter hold (docs/harness-doctor-design.md §12).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/store-lock.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/limiter-hold.sh"

slots_from_cores() { # divisor floor ceiling -> cores / divisor, clamped
  local n
  n=$(( $(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4) / $1 ))
  [ "$n" -ge "$2" ] || n=$2
  [ "$n" -le "$3" ] || n=$3
  printf '%s\n' "$n"
}

slot_take() { # dir count ceiling-seconds -> the slot taken; fails while all are held
  local i
  for ((i = 1; i <= $2; i++)); do
    LLM_STORE_LOCK_RETRIES=1 LLM_STORE_LOCK_CEILING_SECONDS=$3 store_lock_acquire "$1/$i" &&
      { printf '%s\n' "$1/$i"; return 0; }
  done
  return 1
}

slot_wait() { # dir count ceiling-seconds limiter what [tick command...] -> the slot, once one is free
  local dir=$1 count=$2 ceiling=$3 limiter=$4 what=$5 slot hold=''
  shift 5
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || count=1
  mkdir -p "$dir" || return 1
  until slot=$(slot_take "$dir" "$count" "$ceiling"); do
    if [ -z "$hold" ]; then
      hold=$(hold_raise "$limiter" "$what" "all $count $limiter slots are busy")
      printf '%s: waiting for one of %s slots under %s\n' "$limiter" "$count" "$dir" >&2
    fi
    [ $# -eq 0 ] || "$@"
    sleep "${SLOTS_POLL_S:-2}"
    # Run as $(slot_wait …), this loop outlives a killed caller and would take a slot for nobody.
    kill -0 "$$" 2>/dev/null || { hold_clear "$hold"; return 1; }
  done
  hold_clear "$hold"
  printf '%s\n' "$slot"
}

slot_release() { store_lock_release "${1:-}"; }

holds_in_tree() { # pid -> whether a live limiter hold's holder runs inside that process tree
  local file pid hops
  for file in "${HARNESS_HOLDS_DIR:-${HARNESS_DOCTOR_DIR:-$HOME/.cache/harness-doctor}/holds}"/*.json; do
    [ -e "$file" ] || return 1
    pid=$(jq -r '.pid // empty' "$file" 2>/dev/null) hops=0
    kill -0 "$pid" 2>/dev/null || continue
    while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$hops" -lt 64 ]; do
      [ "$pid" != "$1" ] || return 0
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') hops=$((hops + 1))
    done
  done
  return 1
}
