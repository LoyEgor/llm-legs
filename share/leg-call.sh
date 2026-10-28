# leg_call OUT ERR COMMAND...: COMMAND's rc, its stdout in the file OUT, its stderr in ERR, stdin /dev/null.
# A leg's caller ends it with a timeout's SIGTERM to the process group, and a hung vendor CLI can ignore that:
# the wrapper died and the CLI ran on under launchd (2026-10-23..25: three `agy --print` of find-truth's
# morning advice, 3-5 days, 0.4 GB). `timeout -k` never reaches it either, since timeout waits only for its
# own child, the wrapper, which is gone by then. So the CLI runs in the background, and a TERM, INT or HUP to
# the wrapper interrupts the wait and SIGKILLs it before the wrapper exits.
leg_call() {
  local out=$1 err=$2 rc=0
  shift 2
  "$@" >"$out" 2>"$err" </dev/null &
  LEG_CALL_PID=$!
  trap 'kill -KILL "$LEG_CALL_PID" 2>/dev/null; exit 129' HUP
  trap 'kill -KILL "$LEG_CALL_PID" 2>/dev/null; exit 130' INT
  trap 'kill -KILL "$LEG_CALL_PID" 2>/dev/null; exit 143' TERM
  wait "$LEG_CALL_PID" || rc=$?
  trap - HUP INT TERM
  return "$rc"
}
