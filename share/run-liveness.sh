# Whether a worker run's supervisor still lives (shared-invariants row ar). Sourced by bin/worker-run,
# bin/worker-run-backstop.sh and share/run-suites.sh, so every reader of a run record answers the
# same way.

# How far a supervisor's own start may sit from the launch its record stamped before the pid is a
# different process wearing a recycled number. The review hooks judge these same runs by the same
# number (hooks/lib/review-journal.sh, RJ_PID_SLACK): two tools disagreeing about whether a run is
# alive is a chat told to wait forever for one the hooks have already retired.
PID_START_SLACK=30

etime_parse() { # etime as ps prints it: [[dd-]hh:]mm:ss -> ETIME_SECONDS, empty for any other shape
  local parts part total=0 scale
  ETIME_SECONDS=''
  IFS='-:' read -ra parts <<<"$1"
  case ${#parts[@]} in 2) scale=(60 1) ;; 3) scale=(3600 60 1) ;; 4) scale=(86400 3600 60 1) ;; *) return 1 ;; esac
  for part in "${!parts[@]}"; do
    [[ ${parts[part]} =~ ^[0-9]+$ ]] || return 1
    total=$((total + 10#${parts[part]} * scale[part]))
  done
  ETIME_SECONDS=$total
}

etime_seconds() { # etime as ps prints it: [[dd-]hh:]mm:ss
  etime_parse "$1" && printf '%s\n' "$ETIME_SECONDS"
}

# Whether the process wearing a run's recorded pid IS that run's supervisor. The number is reused
# within a day on a busy machine, and whatever inherits it answers a signal probe exactly as the
# supervisor would — which is how an abandoned run kept reporting "running". `ps`, never `kill -0`:
# a live process owned by another user answers EPERM to the probe and reads as dead, and the probe
# is reached for only where ps itself proved unable to answer. A record
# written before pid_started_at existed cannot be checked this way and keeps the old answer, or
# every run started before that field went in would begin reading dead.
pid_alive_since() { # pid start-epoch (none: unchecked)
  local elapsed drift now
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ] || return 1
  command -v ps >/dev/null 2>&1 || { kill -0 "$1" 2>/dev/null; return; }
  elapsed=$(ps -p "$1" -o etime= 2>/dev/null)
  elapsed=${elapsed//[[:space:]]/}
  if [ -z "$elapsed" ]; then
    # "No such process" and "ps could not answer" are the same empty output, and one of them is a
    # live run about to be reported failed. A pid that must be listed settles it — pid 1, not `$$`:
    # a sandbox hiding every process but our own still lists `$$`, and a foreign supervisor then
    # still reads gone. If init is not listed either, ps is what is broken and the probe answers.
    [ -n "$(ps -p 1 -o etime= 2>/dev/null | tr -d '[:space:]')" ] && return 1
    kill -0 "$1" 2>/dev/null
    return
  fi
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] || return 0
  etime_parse "$elapsed" || return 0
  printf -v now '%(%s)T' -1
  drift=$((now - ETIME_SECONDS - $2))
  [ "${drift#-}" -le "$PID_START_SLACK" ]
}

supervisor_running() { # directory pid [pid_started_at, read from meta.json when absent]
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] || return 1
  if [ "$#" -ge 3 ]; then pid_alive_since "$2" "$3"; return; fi
  pid_alive_since "$2" "$(jq -r '.pid_started_at // empty' "$1/meta.json" 2>/dev/null)"
}

starter_alive() { # directory
  local pid began
  { read -r pid began <"$1/starter"; } 2>/dev/null || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [[ "$began" =~ ^[0-9]+$ ]] && [ "$began" -gt 0 ] || return 1
  pid_alive_since "$pid" "$began"
}
