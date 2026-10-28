# worker-run, watchdog: deadlines, idle and silent kills, orphan ends; sourced by bin/worker-run in place, so
# an edit here runs its own suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

record_session_file() { # directory session transcript
  local directory="$1"
  case "$2" in ''|-|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s\n' "$2" >"$directory/session.tmp.$$" &&
    mv -f "$directory/session.tmp.$$" "$directory/session" || return 1
  printf '%s\n' "$3" >"$directory/session-file.tmp.$$" &&
    mv -f "$directory/session-file.tmp.$$" "$directory/session-file" || return 1
  # The launcher-to-worker mapping the review hooks price a LIVE run by, which until now could not
  # be written before the run ended.
  record_worker_session "$directory"
}

# Shared-checkout dirt is not this run's activity; only paths its own transcript names count.
transcript_answered() { # directory since
  local transcript since="${2:-0}"
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  { IFS= read -r transcript <"$1/session-file"; } 2>/dev/null && [ -f "$transcript" ] || return 1
  jq -ne --argjson since "$since" 'any(inputs; .type? == "assistant" and
    ((((.timestamp? // "") | tostring | sub("\\.[0-9]+"; "")) | fromdateiso8601? // 0) >= $since))' \
    <"$transcript" >/dev/null 2>&1
}

activity_fingerprint() { # directory vendor workdir
  local directory="$1" vendor="$2" workdir="$3" path stamp observed=y fingerprint='' session_path
  if [ "$vendor" = claudeb ]; then
    claudeb_discover_session "$directory"
    observed=n
    [ ! -s "$directory/session-file" ] || observed=y
  fi
  session_path=''
  if [ -r "$directory/session-file" ]; then
    IFS= read -r session_path <"$directory/session-file" || true
  fi
  for path in "$directory/out" "$directory/err" "$directory/log" "$session_path"; do
    [ -n "$path" ] && [ -e "$path" ] || continue
    if file_lstat "$path"; then fingerprint+="$path $FILE_SIZE $FILE_MTIME|"; else fingerprint+='|'; fi
  done
  [ -z "$workdir" ] || compute_transcript_files "$directory" list
  if stamp=$(workdir_activity_stamp "$directory" "$workdir" own "${RUN_FILES_LIST-}"); then
    observed=y
    fingerprint+="edit $stamp|"
  fi
  FINGERPRINT="$observed~$fingerprint"
}

# The vendor CLI in a process group of its own, so one signal takes the whole tree it built: every
# vendor here is reached through a wrapper (`claudeb`, `codexb`, `agy`), and a TERM delivered to
# the wrapper alone leaves the CLI it launched editing the workdir with nobody supervising it.
# perl and not setsid(1), which is absent on stock macOS and forks when the caller already leads a
# group — `wait` would then reap the wrapper and report a run that is still going.
CHILD_GROUP_PREFIX=()
if command -v perl >/dev/null 2>&1 && perl -MPOSIX -e 'exit 0' 2>/dev/null; then
  # `or exit 127`: a failed exec leaves perl running the rest of the script, and a missing CLI
  # would exit 0 and report the run as a success that produced nothing.
  CHILD_GROUP_PREFIX=(perl -MPOSIX -e 'POSIX::setsid(); exec {$ARGV[0]} @ARGV or exit 127' --)
fi

# The group where the child leads one, the child alone otherwise. Asked NOW and never at launch:
# the wrapper has not reached setsid() when the pid first appears, and a group kill aimed at a pid
# that leads no group would hit whatever group does wear that number.
end_child() { # pid signal
  [ -n "$1" ] || return 0
  [ "$(ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]')" != "$1" ] || kill -"$2" "-$1" 2>/dev/null || :
  kill -"$2" "$1" 2>/dev/null || :
}

# A process launchd adopted before the run ended is in no tree process_tree_end or end_child walks; the id it
# inherited is all that ties it to the run.
end_run_orphans() { # directory
  local holders pid etime command rows='' pids=()
  holders=$(run_env_holders "${1##*/}")
  [ -n "$holders" ] || return 0
  while IFS=$'\t' read -r pid etime command; do
    pids+=("$pid")
    rows+="$pid"$'\t'"$(etime_seconds "$etime")"$'\t'"${command:0:80}"$'\n'
  done <<<"$holders"
  pids_end 10 "${pids[@]}"
  meta_update "$1" '.orphans_ended = ((.orphans_ended // []) + $rows)' --argjson rows "$(printf '%s' "$rows" |
    jq -Rnc '[inputs | split("\t") | {pid: (.[0] | tonumber), age_s: (.[1] | tonumber? // null), command: .[2]}]')" || :
}

run_with_deadline() {
  local child watchdog='' rc rc_reaped signalled='' began ended
  # Per ATTEMPT, so a reroute's fresh launch cannot inherit the previous one's verdict.
  [ -z "$RUN_DIRECTORY" ] || rm -f "$RUN_DIRECTORY/killed" 2>/dev/null || :
  # <&0 is load-bearing: without an explicit stdin redirect, a background
  # command in a non-interactive shell gets /dev/null instead of the brief
  # the caller redirected in (live-caught: claudeb saw an empty stdin).
  ${CHILD_GROUP_PREFIX[@]+"${CHILD_GROUP_PREFIX[@]}"} "$@" <&0 &
  child=$!
  # The CLI's own pid, for memlogd's memory guard: that guard kills the DESCENDANTS of the pid a
  # run registers, and with only the supervisor's pid on record the CLI is a descendant and dies
  # with the hog (live 2026-09-05: run claudeb-1788615828-30933-684d, EXIT 137). The agent has to
  # outlive the kill to see its command die by signal 9 and read the preamble's answer to it.
  # The launch instant stands beside the number: pids are reused within the day, and the guard skips
  # a root whose process did not start when its registration says it did.
  printf -v began '%(%s)T' -1
  [ -z "$RUN_DIRECTORY" ] || meta_update "$RUN_DIRECTORY" \
    '.cli_pid = $pid | .cli_pid_started_at = $began | .cli_starts = ((.cli_starts // []) + [$began])' \
    --argjson pid "$child" --argjson began "$began" || :
  # A signal aimed at this supervisor is aimed at its run: the child goes with it, or the run keeps
  # writing to a workdir whose supervisor is gone and its record never gets an exit code (live
  # 2026-09-04: claudeb-1788518882-986-6f32, TERMed at 41s, worker landed edits afterwards).
  trap 'signalled=TERM; stop_run TERM' TERM
  trap 'signalled=INT; stop_run INT' INT
  # The watchdog sleeps in short hops: killing the subshell strands its in-flight
  # sleep, and a single sleep $DEADLINE would linger for hours after every run.
  (
    directory=$RUN_DIRECTORY
    vendor='' workdir=''
    WD_META_READY=''
    WD_STARTED=0
    WD_ACCOUNT=''
    WD_RESUME=''
    # Called in this shell, never in $(...): an unmoved transcript's parse is reused across ticks.
    TRANSCRIPT_MEMO=''
    if [ -n "$directory" ] && [ -r "$directory/meta.json" ]; then
      # Not a tab: IFS whitespace collapses an empty field and shifts the next one into its place.
      IFS=$'\x1f' read -r vendor workdir WD_STARTED WD_ACCOUNT WD_RESUME < <(
        jq -r '[.vendor // "", .workdir // "", (([.started_at, .slot_at] | map(numbers) | max // 0) | tostring), .account // "", .resume // ""] | join("\u001f")' \
          "$directory/meta.json" 2>/dev/null) || true
      WD_META_READY=1
    fi
    window=$DEADLINE
    [ "$IDLE" -eq 0 ] || [ "$IDLE" -ge "$window" ] || window=$IDLE
    [ "$SILENT" -eq 0 ] || [ "$SILENT" -ge "$window" ] || window=$SILENT
    hop=$((window / 10))
    [ "$hop" -ge 1 ] || hop=1
    [ "$hop" -le 30 ] || hop=30
    printf -v wd_now '%(%s)T' -1
    end=$((wd_now + DEADLINE))
    idle_since=$wd_now
    silent_since=$idle_since
    ever_active=0
    reason=''
    # Seeded before the first sleep, not left empty: an empty seed differs from every real reading,
    # so the first tick would always read as progress and no idle kill could land on its own hop.
    activity_fingerprint "$directory" "$vendor" "$workdir"
    seen=$FINGERPRINT
    while [ "$wd_now" -lt "$end" ]; do
      sleep "$hop"
      kill -0 "$child" 2>/dev/null || exit 0
      printf -v wd_now '%(%s)T' -1
      [ -z "$directory" ] || newest_mtime "$directory/out" "$directory/err"
      # Log text may quote a wall; a structured vendor error is authoritative even with heartbeats.
      if [ -n "$directory" ] && { [ "$((wd_now - NEWEST_MTIME))" -ge "$WALL_SETTLE" ] ||
           { [ "$vendor" = grok ] && grok_stream_errors "$directory" 4096 | grep -Eiq "$GROK_LIMIT_RE"; }; } &&
         has_limit_signature "$directory" "$vendor" 4096; then
        reason=wall
        break
      fi
      [ -n "$directory" ] && { [ "$SILENT" -gt 0 ] || [ "$IDLE" -gt 0 ]; } || continue
      # claudeb prints its JSON result only at the end, so empty out/err alone is not silence: the
      # transcript and workdir stamps in the fingerprint are what tell a working run from a hung one.
      activity_fingerprint "$directory" "$vendor" "$workdir"
      current=$FINGERPRINT
      if [ "$current" != "$seen" ]; then
        # Only a move of something already observed is activity: a claudeb transcript first found
        # is how a hung start looks too.
        [ "${seen%%~*}" != y ] || ever_active=1
        seen=$current
        idle_since=$wd_now
        silent_since=$idle_since
      fi
      # A tool call waiting in a limiter (a suite slot) is no hung worker.
      ! holds_in_tree "$child" || { idle_since=$wd_now silent_since=$wd_now; }
      # A transcript found already holding this launch's first answer (its first tool call long
      # running) never moved under observation, yet its start was not hung.
      [ "$ever_active" -eq 1 ] || ! transcript_answered "$directory" "$WD_STARTED" || ever_active=1
      # SILENT catches a hung START only: once the run has shown activity, a single long tool call
      # (a suite) freezes every source for many minutes and only IDLE may judge it (live 2026-09-24:
      # two sweep fixers killed mid `tests/run-all`).
      if [ "$SILENT" -gt 0 ] && [ "$ever_active" -eq 0 ] &&
         [ ! -s "$directory/out" ] && [ ! -s "$directory/err" ] &&
         [ $((wd_now - silent_since)) -ge "$SILENT" ]; then
        reason="silent $SILENT"
        break
      fi
      [ "$IDLE" -gt 0 ] || continue
      # An idle kill needs POSITIVE evidence that the worker stopped. A run none of the sources
      # above can see offers none, so it is left to the ceiling below instead of being killed for
      # being unobservable — a killed run hands nothing back.
      printf -v wd_clock '%(%s)T' -1
      if [ "${current%%~*}" = y ] && [ $((wd_clock - idle_since)) -ge "$IDLE" ]; then
        reason="idle $IDLE"
        break
      fi
    done
    [ -n "$reason" ] || reason="deadline $DEADLINE"
    # Written only over a live child, so `killed` names the kill whatever the exit code: codex exits 0
    # on TERM, and that idle kill journaled as done counted its cut jobs as orphans (live 2026-10-14).
    kill -0 "$child" 2>/dev/null || exit 0
    [ -z "$directory" ] || printf '%s\n' "$reason" >"$directory/killed" 2>/dev/null || :
    case $reason in
      'deadline '*) limit_hit worker-run.deadline "$DEADLINE" s kill "run ${directory##*/} ($vendor) killed while still served: its unfinished work" \
        'bin/worker-run:DEADLINE=${' "$((wd_now - end + DEADLINE))" ;;
      'idle '*) limit_hit worker-run.idle "$IDLE" s kill "run ${directory##*/} ($vendor) killed with nothing it writes changing: its unfinished work" \
        'bin/worker-run:IDLE=${' "$(($(date +%s) - idle_since))" ;;
      'silent '*) limit_hit worker-run.silent-start "$SILENT" s kill "run ${directory##*/} ($vendor) killed before its start showed activity" \
        'bin/worker-run:SILENT=${' "$((wd_now - silent_since))" ;;
    esac
    [ "$reason" != wall ] || record_run_wall "$directory" "$vendor"
    end_child "$child" TERM
    sleep 10
    end_child "$child" KILL
  ) &
  watchdog=$!
  wait "$child"
  rc=$?
  # `wait` interrupted by a trapped signal returns 128+n with the child not yet reaped; the second
  # one is what carries the status the child actually died of. 127 is "already reaped" and answers
  # for nothing.
  if [ -n "$signalled" ] && [ "$rc" -gt 128 ]; then
    wait "$child" 2>/dev/null
    rc_reaped=$?
    [ "$rc_reaped" -eq 127 ] || rc=$rc_reaped
  fi
  trap - TERM INT
  # The whole tree: killed alone, the watchdog's in-flight command substitutions outlive it. Grace 0:
  # its zombie stays unreaped until the wait below and answers kill -0 for any grace.
  process_tree_end "$watchdog" 0
  wait "$watchdog" 2>/dev/null
  printf -v ended '%(%s)T' -1
  [ -z "$RUN_DIRECTORY" ] || meta_update "$RUN_DIRECTORY" \
    '.attempt_secs = ((.attempt_secs // []) + [$secs]) | .attempt_rcs = ((.attempt_rcs // []) + [$rc])' \
    --argjson secs "$((ended - began))" --argjson rc "$rc" || :
  return "$rc"
}

# What the traps above do, in the scope that holds the pids: the watchdog first, so the reason this
# run ends is the signal and not a deadline it races, then the child's whole group, then a KILL
# escalation for a CLI that ignores TERM — detached, because this supervisor is on its way out.
stop_run() { # signal
  local reason="signal $1"
  [ "$1" != TERM ] || reason=term
  [ -z "$RUN_DIRECTORY" ] || printf '%s\n' "$reason" >"$RUN_DIRECTORY/killed" 2>/dev/null || :
  process_tree_end "$watchdog" 0
  end_child "$child" TERM
  ( sleep 5; end_child "$child" KILL ) >/dev/null 2>&1 &
}

run_overdue() { # directory [attempt-start, read from meta.json when absent]
  # A pid check alone cannot be trusted forever: a legacy record carries no launch
  # stamp for supervisor_running to compare, and then a run whose supervisor never
  # wrote exit_code reports "running" indefinitely. Twice the deadline covers the one
  # compatibility retry each vendor may make. Unparseable started_at counts as
  # overdue — better a failed report than an eternal "running".
  local started now
  if [ "$#" -ge 2 ]; then started=$2
  else started=$(jq -r '([.started_at, .slot_at] | map(numbers) | max // 0)' "$1/meta.json" 2>/dev/null); fi
  [[ "$started" =~ ^[0-9]+$ ]] && [ "$started" -gt 0 ] || return 0
  printf -v now '%(%s)T' -1
  [ $((now - started)) -gt $((2 * DEADLINE + 900)) ]
}
