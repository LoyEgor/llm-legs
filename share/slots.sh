#!/usr/bin/env bash
# Counted slots machine-wide: <dir>/<n> is a store-lock directory owned by the holder's $$, freed
# when it exits or dies. A waiter raises a limiter hold (docs/harness-doctor-design.md §12).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/store-lock.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/limiter-hold.sh"

slots_from_cores() { # divisor floor [ceiling] -> cores / divisor, clamped
  local n
  n=$(( $(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4) / $1 ))
  [ "$n" -ge "$2" ] || n=$2
  [ -z "${3:-}" ] || [ "$n" -le "$3" ] || n=$3
  printf '%s\n' "$n"
}

# The floor is each pool's count before room existed, so admission never falls below it.
run_suites_slots() { printf '%s-4\n' "$(slots_from_cores 3 2 4)"; }
night_worker_slots() { printf '%s-%s\n' "$(slots_from_cores 2 2 8)" "$(slots_from_cores 1 2 12)"; }

# Load is judged against its own 15-minute base, never against the cores: the owner's benchmark
# holds that base at 130-340 on 10 cores, and only a burst above it is ours.
slot_room() { # -> fails, printing why, while one more holder would crowd the machine
  local level cores load1 load15 avail guard
  { read -r level; read -r cores; read -r _ load1 _ load15 _; } < <(sysctl -n kern.memorystatus_vm_pressure_level hw.ncpu vm.loadavg 2>/dev/null)
  if [[ "${level:-}" =~ ^[0-9]+$ ]] && [ "$level" -gt 1 ]; then printf 'memory pressure level %s\n' "$level"; return 1; fi
  declare -F available_mb >/dev/null ||
    eval "$(sed -n '/^available_mb() {/,/^}/p' "${BASH_SOURCE[0]%/*}/../bin/memlogd" 2>/dev/null)"
  guard=$(sed -n 's/^GUARD_AVAIL_MB = \([0-9][0-9]*\).*/\1/p' "${BASH_SOURCE[0]%/*}/../bin/chat-load" 2>/dev/null | head -n 1)
  guard=$((${guard:-0} + ${SLOTS_ROOM_MB:-1500}))
  if declare -F available_mb >/dev/null; then
    avail=$(available_mb "$(vm_stat 2>/dev/null || true)")
    if [[ "$avail" =~ ^[0-9]+$ ]] && [ "$avail" -lt "$guard" ]; then printf 'available %s MB < %s MB\n' "$avail" "$guard"; return 1; fi
  fi
  [[ "${cores:-}" =~ ^[1-9][0-9]*$ ]] || return 0
  if awk -v l1="${load1:-0}" -v l15="${load15:-0}" -v c="$cores" 'BEGIN { exit !(l1 + 0 > l15 + c) }'; then
    printf 'load %s over its 15-minute base %s + %s cores\n' "$load1" "$load15" "$cores"
    return 1
  fi
}

# A count is N slots, or F-M: F always, F+1 to M only while slot_room finds room. A failed take
# leaves SLOT_WHY empty when every slot is held, else the room it lacked.
slot_take() { # dir count ceiling-seconds -> the slot taken; fails while all are held or the machine is full
  local i ceiling floor=${2%-*} max=${2#*-}
  SLOT_WHY='' SLOT_TAKEN=''
  for ((i = 1; i <= max; i++)); do
    # The holder's own ceiling, not the waiter's: a waiter with a shorter one would break a live slot.
    read -r ceiling 2>/dev/null <"$1/$i/ceiling" && [[ "$ceiling" =~ ^[1-9][0-9]*$ ]] || ceiling=$3
    LLM_STORE_LOCK_RETRIES=1 LLM_STORE_LOCK_CEILING_SECONDS=$ceiling store_lock_acquire "$1/$i" || continue
    if [ "$i" -gt "$floor" ] && ! SLOT_WHY=$(slot_room); then
      store_lock_release "$1/$i"
      return 1
    fi
    printf '%s\n' "$3" >"$1/$i/ceiling"
    SLOT_TAKEN=$1/$i
    printf '%s\n' "$SLOT_TAKEN"
    return 0
  done
  return 1
}

slot_wait() { # dir count ceiling-seconds limiter what [tick command...] -> the slot, once one is free
  local dir=$1 count=$2 ceiling=$3 limiter=$4 what=$5 hold=''
  shift 5
  [[ "$count" =~ ^[1-9][0-9]*(-[1-9][0-9]*)?$ ]] || count=1
  mkdir -p "$dir" || return 1
  until slot_take "$dir" "$count" "$ceiling" >/dev/null; do
    if [ -z "$hold" ]; then
      hold=$(hold_raise "$limiter" "$what" "${SLOT_WHY:-all ${count#*-} $limiter slots are busy}")
      printf '%s: waiting for one of %s slots under %s\n' "$limiter" "$count" "$dir" >&2
    fi
    [ $# -eq 0 ] || "$@"
    if [ -n "$SLOT_WHY" ]; then sleep "${SLOTS_ROOM_POLL_S:-15}"; else sleep "${SLOTS_POLL_S:-2}"; fi
    # Run as $(slot_wait …), this loop outlives a killed caller and would take a slot for nobody.
    kill -0 "$$" 2>/dev/null || { hold_clear "$hold"; return 1; }
  done
  hold_clear "$hold"
  printf '%s\n' "$SLOT_TAKEN"
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
