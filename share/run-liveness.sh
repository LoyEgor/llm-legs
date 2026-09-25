# Whether a worker run's supervisor still lives (shared-invariants row ar). Sourced by bin/worker-run,
# bin/worker-relay-hold.sh and bin/worker-run-backstop.sh, so every reader of a run record answers
# the same way.

# How far a supervisor's own start may sit from the launch its record stamped before the pid is a
# different process wearing a recycled number. The review hooks judge these same runs by the same
# number (hooks/lib/review-journal.sh, RJ_PID_SLACK): two tools disagreeing about whether a run is
# alive is a chat told to wait forever for one the hooks have already retired.
PID_START_SLACK=30

etime_seconds() { # etime as ps prints it: [[dd-]hh:]mm:ss
  printf '%s' "$1" | awk -F'[-:]' '
    NF == 2 { print $1 * 60 + $2; exit }
    NF == 3 { print $1 * 3600 + $2 * 60 + $3; exit }
    NF == 4 { print $1 * 86400 + $2 * 3600 + $3 * 60 + $4; exit }
  ' 2>/dev/null
}

# Whether the process wearing a run's recorded pid IS that run's supervisor. The number is reused
# within a day on a busy machine, and whatever inherits it answers a signal probe exactly as the
# supervisor would — which is how an abandoned run kept reporting "running". `ps`, never `kill -0`:
# a live process owned by another user answers EPERM to the probe and reads as dead, and the probe
# is reached for only where ps itself proved unable to answer. A record
# written before pid_started_at existed cannot be checked this way and keeps the old answer, or
# every run started before that field went in would begin reading dead.
supervisor_running() { # directory pid
  local elapsed seconds started now begin drift
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] || return 1
  command -v ps >/dev/null 2>&1 || { kill -0 "$2" 2>/dev/null; return; }
  elapsed=$(ps -p "$2" -o etime= 2>/dev/null | tr -d '[:space:]')
  if [ -z "$elapsed" ]; then
    # "No such process" and "ps could not answer" are the same empty output, and one of them is a
    # live run about to be reported failed. A pid that must be listed settles it — pid 1, not `$$`:
    # a sandbox hiding every process but our own still lists `$$`, and a foreign supervisor then
    # still reads gone. If init is not listed either, ps is what is broken and the probe answers.
    [ -n "$(ps -p 1 -o etime= 2>/dev/null | tr -d '[:space:]')" ] && return 1
    kill -0 "$2" 2>/dev/null
    return
  fi
  started=$(jq -r '.pid_started_at // empty' "$1/meta.json" 2>/dev/null)
  [[ "$started" =~ ^[0-9]+$ ]] && [ "$started" -gt 0 ] || return 0
  seconds=$(etime_seconds "$elapsed")
  [[ "$seconds" =~ ^[0-9]+$ ]] || return 0
  now=$(date +%s)
  begin=$((now - seconds))
  drift=$((begin - started))
  [ "$drift" -ge 0 ] || drift=$((-drift))
  [ "$drift" -le "$PID_START_SLACK" ]
}
