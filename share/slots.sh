#!/usr/bin/env bash
# Counted slots machine-wide: <dir>/<n> is a store-lock directory owned by the holder's $$, freed
# when it exits or dies. A waiter raises a limiter hold (docs/harness-doctor-design.md §12).
. "${BASH_SOURCE[0]%/*}/store-lock.sh"
. "${BASH_SOURCE[0]%/*}/limiter-hold.sh"

slots_from_cores() { # divisor floor [ceiling] -> cores / divisor, clamped
  local n
  n=$(( $(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4) / $1 ))
  [ "$n" -ge "$2" ] || n=$2
  [ -z "${3:-}" ] || [ "$n" -le "$3" ] || n=$3
  printf '%s\n' "$n"
}

# The floor is each pool's count before room existed, so admission never falls below it.
run_suites_slots() { printf '%s-4\n' "$(slots_from_cores 3 2 4)"; }
# A direct run is one suite against a fan-out's -j cores/2: twice the runs, the rest above the floor only with room.
run_suites_direct_slots() { printf '%s-8\n' "$(slots_from_cores 3 2 4)"; }
# A run's -j: cores/2 always, up to 8 while slot_room finds room.
run_suites_jobs() {
  local floor
  floor=$(slots_from_cores 2 2)
  printf '%s-%s\n' "$floor" $((floor > 8 ? floor : 8))
}
worker_slots() {
  local max
  max=$(($(slots_from_cores 1 2) * 4))
  [ "$max" -le 40 ] || max=40
  printf '%s-%s\n' "$(slots_from_cores 2 2 8)" "$max"
}

# Load is judged against its own 15-minute base, never against the cores: the owner's benchmark
# holds that base at 130-340 on 10 cores, and only a burst above it is ours.
# A pool whose holder is big and measured (blender-render) defines slot_room_mb, printing the MB one more
# holder needs, in place of SLOTS_ROOM_MB.
# Run as $(slot_room), a definition made there dies with the subshell: a waiter defines it once in its own shell.
slot_room_define() {
  declare -F available_mb >/dev/null ||
    eval "$(sed -n '/^available_mb() {/,/^}/p' "${BASH_SOURCE[0]%/*}/../bin/memlogd" 2>/dev/null)" || :
}
slot_room() { # -> fails, printing why, while one more holder would crowd the machine
  local level cores load1 load15 avail guard need=${SLOTS_ROOM_MB:-1500}
  { read -r level; read -r cores; read -r _ load1 _ load15 _; } < <(sysctl -n kern.memorystatus_vm_pressure_level hw.ncpu vm.loadavg 2>/dev/null)
  # Warn (2) is this machine's resting state: on 2026-10-26 it held a worker 23 min at 4.8-7.3 GB available.
  if [[ "${level:-}" =~ ^[0-9]+$ ]] && [ "$level" -ge 4 ]; then printf 'memory pressure level %s\n' "$level"; return 1; fi
  slot_room_define
  # chat-load's constant sits near its top: a read loop finds it with no fork.
  while IFS= read -r guard; do
    [[ "$guard" =~ ^GUARD_AVAIL_MB\ =\ ([0-9]+) ]] && { guard=${BASH_REMATCH[1]}; break; }
    guard=''
  done 2>/dev/null <"${BASH_SOURCE[0]%/*}/../bin/chat-load"
  if declare -F slot_room_mb >/dev/null; then
    need=$(slot_room_mb)
    [[ "$need" =~ ^[0-9]+$ ]] || need=${SLOTS_ROOM_MB:-1500}
  fi
  guard=$((${guard:-0} + need))
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
  local i ceiling floor=${2%-*} max=${2#*-} now=${EPOCHSECONDS:-$(date +%s)} mtime path owner
  local -a mtimes=()
  SLOT_WHY='' SLOT_TAKEN=''
  # Mirrors store_lock_breakable's refusal (live owner, under its ceiling) without its forks per held slot.
  while read -r mtime path; do
    path=${path%/} path=${path##*/}
    [[ "$path" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]] && mtimes[path]=$mtime
  done < <(stat -f '%m %N' "$1"/*/ 2>/dev/null || stat -c '%Y %n' "$1"/*/ 2>/dev/null)
  for ((i = 1; i <= max; i++)); do
    # The holder's own ceiling, not the waiter's: a waiter with a shorter one would break a live slot.
    read -r ceiling 2>/dev/null <"$1/$i/ceiling" && [[ "$ceiling" =~ ^[1-9][0-9]*$ ]] || ceiling=$3
    if [ -n "${mtimes[i]:-}" ] && [ "$((now - mtimes[i]))" -le "$ceiling" ] &&
      read -r owner 2>/dev/null <"$1/$i/pid" && [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
      continue
    fi
    LLM_STORE_LOCK_RETRIES=1 LLM_STORE_LOCK_CEILING_SECONDS=$ceiling store_lock_acquire "$1/$i" || continue
    if { [ "$i" -gt "$floor" ] || [ "${SLOTS_CHECK_FLOOR:-0}" = 1 ]; } && slot_room_define && ! SLOT_WHY=$(slot_room); then
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

slot_wait() { # dir count ceiling-seconds limiter what [tick command...] -> the slot, once one is free;
  # fails once the command $SLOT_OWNER_ENDED succeeds
  local dir=$1 count=$2 ceiling=$3 limiter=$4 what=$5 hold='' reason='' room=''
  shift 5
  [[ "$count" =~ ^[1-9][0-9]*(-[1-9][0-9]*)?$ ]] || count=1
  mkdir -p "$dir" || return 1
  until slot_take "$dir" "$count" "$ceiling" >/dev/null; do
    # The row names the slot_room clause of the last room refusal: level, mb or load.
    case $SLOT_WHY in
      '') reason=limit room='' ;;
      'memory pressure'*) reason=room room=level ;;
      available*) reason=room room=mb ;;
      *) reason=room room=load ;;
    esac
    if [ -z "$hold" ]; then
      hold=$(hold_raise "$limiter" "$what" "${SLOT_WHY:-all ${count#*-} $limiter slots are busy}")
      printf '%s: waiting for one of %s slots under %s\n' "$limiter" "$count" "$dir" >&2
    fi
    [ $# -eq 0 ] || "$@"
    if [ "$reason" = room ]; then slot_floor_wait "$dir" "${count%-*}" "$ceiling" && break; else sleep "${SLOTS_POLL_S:-2}"; fi
    # Run as $(slot_wait …), this loop outlives a killed caller and would take a slot for nobody.
    kill -0 "$$" 2>/dev/null || { slot_wait_end "$dir" "$count" "$hold" "$reason" "$room"; return 1; }
    [ -z "${SLOT_OWNER_ENDED:-}" ] || ! $SLOT_OWNER_ENDED || { slot_wait_end "$dir" "$count" "$hold" owner-ended; return 1; }
  done
  # The caller can also die inside the take, after the check above passed.
  kill -0 "$$" 2>/dev/null || { slot_release "$SLOT_TAKEN"; slot_wait_end "$dir" "$count" "$hold" "$reason" "$room"; return 1; }
  slot_wait_end "$dir" "$count" "$hold" "$reason" "$room"
  printf '%s\n' "$SLOT_TAKEN"
}

# A floor slot needs no room: while room is lacking, the floor is scanned every SLOTS_POLL_S and the
# room judged again only after SLOTS_ROOM_POLL_S.
slot_floor_wait() { # dir floor ceiling-seconds -> succeeds once a floor slot was taken within one room poll
  local ticks
  ticks=$(awk -v r="${SLOTS_ROOM_POLL_S:-15}" -v p="${SLOTS_POLL_S:-2}" 'BEGIN { n = p > 0 ? int(r / p) : 1; print (n < 1 ? 1 : n) }')
  while [ "$ticks" -gt 0 ]; do
    sleep "${SLOTS_POLL_S:-2}"
    ticks=$((ticks - 1))
    slot_take "$1" "$2" "$3" >/dev/null && return 0
  done
  return 1
}

slot_wait_end() { # dir count hold reason [room] -> journals the hold's wait with the count allowed and held at its end
  local allowed=${2#*-} held taken=${SLOT_TAKEN##*/}
  [ -n "$3" ] || return 0
  if [ "${2%-*}" != "$allowed" ] && ! { [[ "$taken" =~ ^[0-9]+$ ]] && [ "$taken" -gt "${2%-*}" ]; } &&
    ! slot_room >/dev/null; then allowed=${2%-*}; fi
  held=$(slots_held "$1")
  hold_clear "$3" "$allowed" "$held" "$4" "${5:-}"
}

slots_held() { # dir -> the slots a live process holds
  local file pid held=0
  for file in "$1"/*/pid; do
    { read -r pid <"$file"; } 2>/dev/null && [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null && held=$((held + 1))
  done
  printf '%s\n' "$held"
}

slot_release() { store_lock_release "${1:-}"; }

holds_in_tree() { # pid -> whether a live limiter hold's holder runs inside that process tree
  local file text pid hops child parent
  local -a live=() parents=()
  # Every watchdog tick calls this: one ps snapshot, never a jq and a ps per hold and hop.
  for file in "${HARNESS_HOLDS_DIR:-${HARNESS_DOCTOR_DIR:-$HOME/.cache/harness-doctor}/holds}"/*.json; do
    [ -e "$file" ] || return 1
    text=''
    IFS= read -r -d '' text 2>/dev/null <"$file" || :
    # The top-level pid: both writers (limiter-hold.sh, limiter_hold.py) put it before any nested object.
    [[ "$text" =~ \"pid\":[[:space:]]*([0-9]+)[,}[:space:]] ]] || continue
    pid=${BASH_REMATCH[1]}
    kill -0 "$pid" 2>/dev/null || continue
    [ "$pid" != "$1" ] || return 0
    live+=("$pid")
  done
  [ "${#live[@]}" -gt 0 ] || return 1
  while read -r child parent; do parents[child]=$parent; done < <(ps -axo pid=,ppid= 2>/dev/null)
  for pid in "${live[@]}"; do
    hops=0
    while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$hops" -lt 64 ]; do
      [ "$pid" != "$1" ] || return 0
      pid=${parents[pid]:-} hops=$((hops + 1))
    done
  done
  return 1
}
