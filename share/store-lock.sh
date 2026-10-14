#!/usr/bin/env bash
[ ! -r "${BASH_SOURCE[0]%/*}/limiter-hold.sh" ] || . "${BASH_SOURCE[0]%/*}/limiter-hold.sh"
[ ! -r "${BASH_SOURCE[0]%/*}/limit-hit.sh" ] || . "${BASH_SOURCE[0]%/*}/limit-hit.sh"

store_lock_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# Ownership lives in the pid file, not in the directory: between our mkdir and our write the
# directory may have been captured and replaced, and that replacement is never ours to remove.
store_lock_claim() {
  local lock=$1 owner=''
  if printf '%s\n' "$$" 2>/dev/null >"$lock/pid"; then
    read -r owner 2>/dev/null <"$lock/pid" || owner=''
    [ "$owner" = "$$" ] && return 0
    return 1
  fi
  read -r owner 2>/dev/null <"$lock/pid" || owner=''
  if [ -z "$owner" ] || [ "$owner" = "$$" ]; then
    rm -rf "$lock" 2>/dev/null
  fi
  return 1
}

# Who may take a lock away: a holder proven gone (its pid no longer runs) at once, an ownerless
# directory once it outlives the grace, a live holder never — until the ceiling, past which a
# recycled pid can no longer be told from the original owner.
store_lock_breakable() { # -> also store_lock_why (ceiling-live|ceiling|dead|ownerless), _owner and _age
  local lock=$1 stale=$2 ceiling=$3 now=$4 owner='' mtime
  store_lock_why=''
  mtime=$(store_lock_mtime "$lock" 2>/dev/null) || mtime=$now
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=$now
  store_lock_age=$((now - mtime))
  read -r owner 2>/dev/null <"$lock/pid" || owner=''
  case "$owner" in ''|*[!0-9]*) owner='' ;; esac
  store_lock_owner=$owner
  if [ "$((now - mtime))" -gt "$ceiling" ]; then
    store_lock_why=ceiling
    [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null || store_lock_why=ceiling-live
    return 0
  fi
  if [ -n "$owner" ]; then
    kill -0 "$owner" 2>/dev/null && return 1
    store_lock_why=dead
    return 0
  fi
  [ "$((now - mtime))" -gt "$stale" ] && store_lock_why=ownerless
}

store_lock_broke() { # lock stale ceiling
  declare -F limit_hit >/dev/null || return 0
  case $store_lock_why in
    ceiling-live) limit_hit store-lock.ceiling "$3" s break "the lock $1 of live pid $store_lock_owner: two writers may now overlap" \
      'share/store-lock.sh:local ceiling=${LLM_STORE_LOCK_CEILING_SECONDS' "$store_lock_age" ;;
    ownerless) limit_hit store-lock.ownerless-stale "$2" s break "the ownerless lock $1, $store_lock_age s old" \
      'share/store-lock.sh:local stale=${LLM_STORE_LOCK_STALE_SECONDS' "$store_lock_age" ;;
  esac
  return 0
}

store_lock_acquire() {
  local lock=$1 tries=0 now waited=''
  local max=${LLM_STORE_LOCK_RETRIES:-240}
  local delay=${LLM_STORE_LOCK_DELAY:-0.25}
  local stale=${LLM_STORE_LOCK_STALE_SECONDS:-30}
  local ceiling=${LLM_STORE_LOCK_CEILING_SECONDS:-3600}
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=240
  [[ "$delay" =~ ^[0-9]+(\.[0-9]+)?$ ]] || delay=0.25
  [[ "$stale" =~ ^[1-9][0-9]*$ ]] || stale=30
  [[ "$ceiling" =~ ^[1-9][0-9]*$ ]] || ceiling=3600
  while :; do
    if [ ! -d "$lock" ] && mkdir "$lock" 2>/dev/null; then
      store_lock_claim "$lock" && { store_lock_waited "$lock" "$waited"; return 0; }
    elif [ "$((tries + 1))" -ge "$max" ] || [ "$(((tries + 1) % 20))" -eq 0 ]; then
      now=${EPOCHSECONDS:-$(date +%s)} || return 1
      if store_lock_breakable "$lock" "$stale" "$ceiling" "$now"; then
        # One breaker at a time, under a lock of its own, judges the holder again and removes it. A lock
        # is never moved aside: a racer's live newborn captured and put back left a gap a newcomer's
        # mkdir filled, and both held the lock.
        if mkdir "$lock.break" 2>/dev/null; then
          if store_lock_claim "$lock.break"; then
            if store_lock_breakable "$lock" "$stale" "$ceiling" "${EPOCHSECONDS:-$now}"; then
              rm -rf "$lock"
              rm -rf "$lock.break"
              store_lock_broke "$lock" "$stale" "$ceiling"
              continue
            fi
            rm -rf "$lock.break"
          fi
        elif store_lock_breakable "$lock.break" "$stale" "$ceiling" "$now"; then
          rm -rf "$lock.break"
        fi
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      store_lock_waited "$lock (gave up)" "$waited"
      # One try is a try-lock, whose refusal is its answer: slot polls and night-run's lock make it every tick.
      [ "$max" -eq 1 ] || ! declare -F limit_hit >/dev/null || limit_hit store-lock.retries "$max" count retry-exhausted \
        "the write under $1: refused after $max tries behind holder ${store_lock_owner:-unknown}" 'share/store-lock.sh:local max=${LLM_STORE_LOCK_RETRIES'
      return 1
    fi
    waited=${waited:-${EPOCHREALTIME:-$(date +%s)}}
    sleep "$delay" 2>/dev/null || return 1
  done
}

store_lock_waited() {
  [ -z "$2" ] || ! declare -F wait_note >/dev/null || wait_note lock "$1" "$2"
}

# Only the owner may delete: a caller whose acquire failed, or whose lock was stale-broken,
# must never remove the live lock of whoever holds it now.
store_lock_release() {
  local owner=''
  [ -n "$1" ] || return 0
  read -r owner 2>/dev/null <"$1/pid" || owner=''
  [ "$owner" = "$$" ] || return 0
  rm -rf "$1" 2>/dev/null || true
}
