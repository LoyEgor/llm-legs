# run_bounded SECONDS COMMAND...: COMMAND's rc, 124 when `timeout` cut it; stdio stays the caller's.
# RUN_BOUNDED_ON_TIMEOUT names a function called with SECONDS COMMAND... on 124. Stock macOS ships
# neither `timeout` nor `gtimeout`, so a watchdog stands in where none is found.

run_bounded() {
  local seconds=$1 bin pid watchdog rc=0
  shift
  bin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
  if [ -n "$bin" ]; then
    "$bin" "$seconds" "$@" || rc=$?
  else
    "$@" &
    pid=$!
    # Its `sleep` outlives the kill below, so an inherited stdout holds a caller's $(…) open until it ends.
    (sleep "$seconds"; kill "$pid" 2>/dev/null) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" 2>/dev/null || rc=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
  fi
  [ "$rc" -ne 124 ] || [ -z "${RUN_BOUNDED_ON_TIMEOUT:-}" ] || "$RUN_BOUNDED_ON_TIMEOUT" "$seconds" "$@" || true
  return "$rc"
}
