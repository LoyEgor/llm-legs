#!/usr/bin/env bash

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
store_lock_breakable() {
  local lock=$1 stale=$2 ceiling=$3 now=$4 owner='' mtime
  mtime=$(store_lock_mtime "$lock" 2>/dev/null) || mtime=$now
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=$now
  [ "$((now - mtime))" -gt "$ceiling" ] && return 0
  read -r owner 2>/dev/null <"$lock/pid" || owner=''
  case "$owner" in ''|*[!0-9]*) owner='' ;; esac
  if [ -n "$owner" ]; then
    kill -0 "$owner" 2>/dev/null && return 1
    return 0
  fi
  [ "$((now - mtime))" -gt "$stale" ]
}

store_lock_acquire() {
  local lock=$1 tries=0 now captured
  local max=${LLM_STORE_LOCK_RETRIES:-240}
  local delay=${LLM_STORE_LOCK_DELAY:-0.25}
  local stale=${LLM_STORE_LOCK_STALE_SECONDS:-30}
  local ceiling=${LLM_STORE_LOCK_CEILING_SECONDS:-3600}
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=240
  [[ "$delay" =~ ^[0-9]+(\.[0-9]+)?$ ]] || delay=0.25
  [[ "$stale" =~ ^[1-9][0-9]*$ ]] || stale=30
  [[ "$ceiling" =~ ^[1-9][0-9]*$ ]] || ceiling=3600
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      store_lock_claim "$lock" && return 0
    elif [ "$((tries + 1))" -ge "$max" ] || [ "$(((tries + 1) % 20))" -eq 0 ]; then
      now=$(date +%s) || return 1
      if store_lock_breakable "$lock" "$stale" "$ceiling" "$now"; then
        # Claim by renaming aside: of several racing waiters only one wins the mv, and what it
        # captured is judged again — a racer's live newborn goes back untouched.
        captured="${lock}.break.$$"
        if mv "$lock" "$captured" 2>/dev/null; then
          if store_lock_breakable "$captured" "$stale" "$ceiling" "$now"; then
            rm -rf "$captured"
            continue
          fi
          # mv into an existing directory would nest, so restore only onto a free path.
          [ -e "$lock" ] || mv "$captured" "$lock" 2>/dev/null
          rm -rf "$captured" 2>/dev/null
        fi
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -ge "$max" ] && return 1
    sleep "$delay" 2>/dev/null || return 1
  done
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
