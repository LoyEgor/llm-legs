# worker-run, `worker-run wait`: progress rows, the watch and the wait loop; sourced by bin/worker-run in
# place, so an edit here runs its own suites rather than every suite of worker-run (Egor 2026-10-23,
# 2026-10-28).

GEMINI_SESSION_KEY='' GEMINI_SESSION=''

WAIT_STAMP='' WAIT_TOKENS_STAMP='' WAIT_VENDOR='' WAIT_ACCOUNT='' WAIT_WORKDIR='' WAIT_STARTED=''
WAIT_PID='' WAIT_PID_STARTED='' WAIT_ATTEMPT_STARTED=''
WAIT_TRANSCRIPT='' WAIT_OFFSET=0 WAIT_ROWS_NEXT=0 WAIT_TOKENS_NEXT=0 WAIT_CLOCK=0
declare -A WAIT_PRINTED=() WAIT_COUNTS=()

# One kqueue watcher serves a whole wait: it prints `exit` once exit_code is in the run directory and
# `gone <pid>` once the supervisor it armed on ends, so no tick forks to sleep or to probe that pid.
WAIT_WATCH_STATE='' WAIT_WATCH_IN='' WAIT_ARMED='' WAIT_ARMED_SINCE='' WAIT_WATCH_SEEN=''

# How long ago this run last put bytes on disk. OUT-BYTES is no liveness signal — claudeb writes
# its JSON once, at the end, so it reads 0 for the whole run and a wrapper agent declared a healthy
# 52-minute run stalled one minute before it finished (live 2026-08-24). Newest mtime among the
# paths the dirt tracker already calls this run's own; nonzero where nothing has changed yet.
last_edit_age() { # directory workdir now
  local now="$3" newest own path age
  local -a named=()
  newest=$(workdir_activity_stamp "$1" "$2") || newest=0
  # Git sees no edit to an ignored path, a committed one or one in another repository; the run's own
  # transcript names them.
  compute_transcript_files "$1" list
  while IFS= read -r path; do
    case "$path" in '') ;; /*) named+=("$path") ;; *) named+=("${2%/}/$path") ;; esac
  done <<<"$RUN_FILES_LIST"
  newest_mtime ${named[@]+"${named[@]}"}
  own=$NEWEST_MTIME
  [ "$own" -le "$newest" ] || newest=$own
  [ "$newest" -gt 0 ] || return 1
  age=$((now - newest)); [ "$age" -ge 0 ] || age=0
  printf '%s\n' "$age"
}

# LAST-EDIT keeps the dirt view; the watchdog passes `own` to exclude co-tenant edits.
workdir_activity_stamp() { # directory workdir [own transcript-files]
  local directory="$1" workdir="$2" top path target mtime newest=''
  if [ "${3:-}" = own ]; then
    top=$workdir
  else
    [ -f "$directory/dirty-before" ] || return 1
    top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || return 1
  fi
  [ -n "$top" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ "${3:-}" = own ]; then
      case "$path" in /*|..|../*|*/../*|*/..) continue ;; esac
    fi
    target="$top/$path"
    if [ "${3:-}" = own ] && [ ! -e "$target" ]; then
      [ -n "$newest" ] || newest=0
      continue
    fi
    while ! file_lstat "$target"; do
      [ "$target" != "$top" ] || { FILE_MTIME=''; break; }
      target=${target%/*}
    done
    mtime=$FILE_MTIME
    [ -n "$mtime" ] || continue
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    [ -n "$newest" ] && [ "$mtime" -le "$newest" ] || newest=$mtime
  done < <(
    if [ "${3:-}" = own ]; then
      printf '%s\n' "${4-}"
    else
      workdir_gained_paths "$directory" "$workdir"
    fi
  )
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

# CPU the run has burned, summed over the whole process group: the supervisor is `setsid`'d, so its
# pid IS the group and one `ps` covers the CLI and everything it spawned. The second half of the
# liveness answer — a run whose files sit still is thinking if this keeps climbing.
pid_group_cpu_seconds() { # pid...
  local pid groups=''
  for pid; do [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && groups+=${groups:+,}$pid; done
  [ -n "$groups" ] || return 1
  ps -g "$groups" -o time= 2>/dev/null |
    awk 'NF { n = split($1, f, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + f[i]; total += s; seen = 1 }
         END { if (!seen) exit 1; printf "%d\n", total }'
}

running_report() {
  local directory="$1" now started elapsed out_bytes err_bytes workdir age cpu
  now=$(date +%s)
  started=$(jq -r '.started_at' "$directory/meta.json")
  elapsed=$((now - started)); [ "$elapsed" -ge 0 ] || elapsed=0
  out_bytes=$(wc -c <"$directory/out" | tr -d '[:space:]')
  err_bytes=$(wc -c <"$directory/err" | tr -d '[:space:]')
  printf 'STATUS: running\nELAPSED: %s\n' "$elapsed"
  printf 'OUT-BYTES: %s\nERR-BYTES: %s\nSESSION: %s\n' "$out_bytes" "$err_bytes" "$(session_id "$directory")"
  workdir=$(jq -r '.workdir' "$directory/meta.json" 2>/dev/null)
  age=$(last_edit_age "$directory" "$workdir" "$now") || age=none
  printf 'LAST-EDIT: %s\n' "$age"
  memguard_lines "$directory"
  # The CLI leads a session of its own (CHILD_GROUP_PREFIX), so the supervisor's group never holds it.
  cpu=$(pid_group_cpu_seconds $(jq -r '.pid // 0, .cli_pid // 0' "$directory/meta.json" 2>/dev/null)) &&
    printf 'CPU-SECONDS: %s\n' "$cpu"
  return 0
}

wait_poll_lag() { # directory run-id wait-started: how long an exit the poll had not yet seen waited
  local ended
  ended=$(stat -f %Fm "$1/exit_code" 2>/dev/null || stat -c %.3Y "$1/exit_code" 2>/dev/null) &&
    [ "${ended%.*}" -ge "$3" ] 2>/dev/null &&
    wait_note poll "worker-run wait $2" "$ended"
  return 0
}

run_live() { # directory
  [ ! -e "$1/exit_code" ] && supervisor_running "$1" "$(jq -r '.pid // 0' "$1/meta.json" 2>/dev/null)" &&
    ! run_overdue "$1"
}

# The file extractors drop read-only tools and messages, which are most of what a working run shows.
gemini_progress_rows() { # transcript since
  jq -rR --argjson since "$2" --arg writes "$GEMINI_WRITE_TOOLS" '
    def epoch(value):
      try ((value | tostring | sub("\\.[0-9]+(?=Z$)"; "")) | fromdateiso8601) catch null;
    fromjson? | objects | select(.type? == "PLANNER_RESPONSE" and (epoch(.created_at? // "") // 0) >= $since)
    | (if (.content? | type) == "string" then ["M", .content] else empty end),
      (.tool_calls[]? | objects | (.name? // "tool") as $name | (.args? // {}) as $args
       | if ($name | test($writes)) then ["F", ($args.TargetFile? // "")]
         elif $name == "run_command" then ["C", ($args.CommandLine? // "")]
         else ["X", $name + " " + ([$args | objects | .[] | strings] | first // "")] end)
    | .[0] + "\t" + (.[1] | tostring | gsub("[\n\r\t]+"; " ") | sub(" +$"; ""))' "$1" 2>/dev/null
}

codex_message_rows() { # rollout since
  jq -rR --argjson since "$2" '
    fromjson? | objects | select(.payload?.type? == "message" and .payload.role? == "assistant")
    | select((try ((.timestamp // "") | sub("\\.[0-9]+(?=Z$)"; "") | fromdateiso8601) catch 0) >= $since)
    | .payload.content[]? | objects | select(.type? == "output_text")
    | "M\t" + (.text // "" | tostring | gsub("[\n\r\t]+"; " "))' "$1" 2>/dev/null
}

run_transcript() { # directory vendor account workdir started [cached]
  run_transcript_to "$@" && printf '%s\n' "$RUN_TRANSCRIPT"
}

run_transcript_to() { # directory vendor account workdir started [cached] -> RUN_TRANSCRIPT
  local directory="$1" vendor="$2" transcript='' session='' key=''
  RUN_TRANSCRIPT=''
  if [ "$vendor" = claudeb ]; then
    { IFS= read -r transcript <"$directory/session-file"; } 2>/dev/null || transcript=''
  elif [ "$vendor" != gemini ] && [ -f "${6-}" ]; then
    transcript=$6
  fi
  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    # A gemini session is named by its log alone, which a streaming wait would otherwise grep every tick.
    if [ "$vendor" = gemini ] && file_lstat "$directory/log"; then
      key="$directory $FILE_INODE $FILE_SIZE $FILE_MTIME"
      [ "$key" != "$GEMINI_SESSION_KEY" ] || session=$GEMINI_SESSION
    fi
    [ -n "$session" ] || session=$(session_id "$directory" "$vendor")
    [ -z "$key" ] || GEMINI_SESSION_KEY=$key GEMINI_SESSION=$session
  fi
  [ -n "$transcript" ] && [ -f "$transcript" ] ||
    transcript=$(session_transcript "$vendor" "$3" "$session" "$4") ||
    { [ "$vendor" = grok ] && transcript=$(session_transcript grok "$3" "$(grok_live_session "$3" "$4" "$5" \
        "$(jq -r '.resume // empty' "$directory/meta.json" 2>/dev/null)")" "$4"); } || return 1
  RUN_TRANSCRIPT=$transcript
}

# What `wait` streams to the chat's /tasks view: one line per tool call or short message of the
# worker, read off its live session log with the same extractors the run's file list uses.
# A claudeb log is read from byte offset `from` on, and its first row `O<TAB>n` counts the bytes of the
# whole lines it read: a partial last line is left for the next read.
progress_rows() { # vendor transcript since from
  if [ "$1" = claudeb ]; then
    tail -c +$(($4 + 1)) "$2" 2>/dev/null | jq -rRs --argjson since "$3" 'split("\n") as $lines
        | (if ($lines | length) > 0 and ((($lines[-1] | fromjson?) // null) | type) == "object"
           then $lines else $lines[:-1] end) as $done
        | ("\u001f" + (([$done[] | utf8bytelength + 1] | add // 0)
            - (if ($done | length) > 0 and ($done | length) == ($lines | length) then 1 else 0 end) | tostring)),
          ($done[] | fromjson? | objects | select(.type? == "assistant")
        | select((((.timestamp? // "") | tostring | sub("\\.[0-9]+"; "")) | fromdateiso8601? // 0) >= $since)
        | .message.content[]? | objects
        | if .type? == "tool_use" then
            ((.name // "tool") + " " + ((.input.command // .input.file_path // .input.notebook_path // .input.pattern
              // .input.url // .input.query // .input.description // "") | tostring))
            | gsub("[\n\r\t]+"; " ") | select(test(" (outcome|arguments)$") | not)
          elif .type? == "text" then (.text // "") | gsub("[\n\r\t]+"; " ") | select(test("[^ ]")) | "» " + .
          else empty end)' 2>/dev/null
    return 0
  fi
  case "$1" in
    codex) codex_tool_rows "$2" "$3"; codex_message_rows "$2" "$3" ;;
    gemini) gemini_progress_rows "$2" "$3" ;;
    grok) grok_progress_rows "$2" "$3" ;;
  esac | awk -F'\t' '
    $1 == "O" { print "\037" $2; next }
    $1 == "F" { print "edit " $2; next }
    $1 == "C" { print "$ " $2; next }
    $1 == "X" && $2 !~ / (outcome|arguments)$/ { print $2; next }
    $1 == "M" && $2 ~ /[^ ]/ { print "» " $2 }'
}

elapsed_label() { # seconds -> ELAPSED_LABEL
  if [ "$1" -ge 3600 ]; then printf -v ELAPSED_LABEL '%dh%02dm' "$(($1 / 3600))" "$(($1 % 3600 / 60))"
  elif [ "$1" -ge 60 ]; then printf -v ELAPSED_LABEL '%dm%02ds' "$(($1 / 60))" "$(($1 % 60))"
  else printf -v ELAPSED_LABEL '%ds' "$1"; fi
}

# The worker's Opus-eq tokens so far, rounded: the total share/night_spend.py run_usage prices the run at.
run_tokens() { # run-id vendor transcript
  python3 - "$SCRIPT_DIRECTORY/../share" "$SCRIPT_PATH" "$1" "$2" "$3" 2>/dev/null <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import night_spend
usage = night_spend.run_usage(sys.argv[2], sys.argv[3], sys.argv[4], set(), {sys.argv[3]: sys.argv[5]})
if usage is not None:
    print(round(sum(usage.values())))
PY
}

wait_clock() {
  local t=${EPOCHREALTIME:-}
  t=${t/[.,]/}
  WAIT_CLOCK=${t%???}
  [ -n "$t" ] || WAIT_CLOCK=$((SECONDS * 1000))
}

# An empty WAIT_STAMP forces a full pass (the first and the last). Between them a slurped log is
# re-read only after ten times its last read, and the tokens after max(60 s, ten times their last count),
# so a long run's reads stay a bounded share of its wall time.
# meta.json is read again whenever it changes: a walled reroute moves the account and restamps started_at mid-run.
# wait_run's liveness and deadline checks read the WAIT_PID* fields this call leaves.
wait_progress() { # directory run-id stream
  local directory="$1" vendor account workdir started transcript='' stamp size row now prefix tokens out='' force=false began
  [ -n "$WAIT_STAMP" ] || force=true
  account=$WAIT_ACCOUNT
  meta_unchanged "$directory" WAIT_META_KEY ||
  { IFS= read -r WAIT_VENDOR; IFS= read -r WAIT_ACCOUNT; IFS= read -r WAIT_WORKDIR; IFS= read -r WAIT_STARTED
    IFS= read -r WAIT_PID; IFS= read -r WAIT_PID_STARTED; IFS= read -r WAIT_ATTEMPT_STARTED; } \
    < <(jq -r '.vendor, .account, .workdir, (.pid_started_at // .started_at // 0), (.pid // ""), (.pid_started_at // ""),
        ([.started_at, .slot_at] | map(numbers) | max // 0)' "$directory/meta.json" 2>/dev/null)
  [ "$WAIT_ACCOUNT" = "$account" ] || WAIT_TRANSCRIPT=''
  vendor=$WAIT_VENDOR account=$WAIT_ACCOUNT workdir=$WAIT_WORKDIR started=$WAIT_STARTED
  wait_clock
  [ "$force" = true ] || [ "$vendor" = claudeb ] || [ "$WAIT_CLOCK" -ge "$WAIT_ROWS_NEXT" ] ||
    [ "$WAIT_CLOCK" -ge "$WAIT_TOKENS_NEXT" ] || return 0
  run_transcript_to "$directory" "$vendor" "$account" "$workdir" "$started" "$WAIT_TRANSCRIPT" || return 0
  transcript=$RUN_TRANSCRIPT stamp=''
  ! file_lstat "$transcript" || stamp="$FILE_SIZE $FILE_MTIME $FILE_INODE"
  size=${stamp%% *}
  if [ "$transcript" != "$WAIT_TRANSCRIPT" ] || ! [ "$size" -ge "$WAIT_OFFSET" ] 2>/dev/null; then
    WAIT_TRANSCRIPT=$transcript WAIT_OFFSET=0
    WAIT_COUNTS=()
  fi
  stamp="$transcript $stamp"
  wait_clock
  if [ "$stamp" != "$WAIT_STAMP" ] &&
    { [ "$force" = true ] || [ "$vendor" = claudeb ] || [ "$WAIT_CLOCK" -ge "$WAIT_ROWS_NEXT" ]; }; then
    WAIT_STAMP=$stamp began=$WAIT_CLOCK
    printf -v now '%(%s)T' -1
    [[ "$started" =~ ^[0-9]+$ ]] || started=$now
    elapsed_label "$((now > started ? now - started : 0))"
    prefix="[$ELAPSED_LABEL] "
    [ "$vendor" = claudeb ] || WAIT_COUNTS=()
    [ "$3" = false ] || while IFS= read -r row; do
      case $row in
        '') continue ;;
        $'\037'*) [[ ${row#?} =~ ^[0-9]+$ ]] && WAIT_OFFSET=$((WAIT_OFFSET + ${row#?})); continue ;;
      esac
      WAIT_COUNTS[$row]=$((${WAIT_COUNTS[$row]:-0} + 1))
      [ "${WAIT_COUNTS[$row]}" -gt "${WAIT_PRINTED[$row]:-0}" ] || continue
      WAIT_PRINTED[$row]=${WAIT_COUNTS[$row]}
      out+="$prefix$row"$'\n'
    done < <(progress_rows "$vendor" "$transcript" "$started" "$WAIT_OFFSET")
    [ -z "$out" ] || wait_print_rows "$out"
    wait_clock
    WAIT_ROWS_NEXT=$((WAIT_CLOCK + 10 * (WAIT_CLOCK - began)))
  fi
  [ "$force" = true ] || { [ "$stamp" != "$WAIT_TOKENS_STAMP" ] && [ "$WAIT_CLOCK" -ge "$WAIT_TOKENS_NEXT" ]; } || return 0
  WAIT_TOKENS_STAMP=$stamp began=$WAIT_CLOCK
  tokens=$(run_tokens "$2" "$vendor" "$transcript")
  wait_clock
  WAIT_TOKENS_NEXT=$((WAIT_CLOCK + 10 * (WAIT_CLOCK - began)))
  [ "$WAIT_TOKENS_NEXT" -ge "$((WAIT_CLOCK + 60000))" ] || WAIT_TOKENS_NEXT=$((WAIT_CLOCK + 60000))
  [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "$tokens" >"$directory/tokens.tmp.$$" && mv -f "$directory/tokens.tmp.$$" "$directory/tokens" ||
    rm -f "$directory/tokens.tmp.$$"
}

wait_print_rows() { # lines: each cut to 120 characters
  # ${#line} counts characters only under a UTF-8 locale; under C it counts bytes.
  local LC_ALL=C.UTF-8 line out='' mark='…' 2>/dev/null
  if [ "${#mark}" -ne 1 ]; then
    printf '%s' "$1" | perl -CSD -ne 'chomp; print length($_) > 120 ? substr($_, 0, 119) . "\x{2026}" : $_, "\n"'
    return
  fi
  while IFS= read -r line; do
    [ "${#line}" -le 120 ] || line="${line:0:119}$mark"
    out+=$line$'\n'
  done <<<"${1%$'\n'}"
  printf '%s' "$out"
}

wait_watch_start() { # directory pid pid_started_at
  local read_end armed
  [ -z "$WAIT_WATCH_STATE" ] || return 0
  WAIT_WATCH_STATE=off
  coproc WAIT_WATCH { exec python3 -c '
import errno, os, select, sys
directory, pid, parent = sys.argv[1], sys.argv[2], os.getppid()
queue = select.kqueue()
queue.control([select.kevent(os.open(directory, os.O_RDONLY), select.KQ_FILTER_VNODE,
                             select.KQ_EV_ADD | select.KQ_EV_CLEAR, select.KQ_NOTE_WRITE),
               select.kevent(parent, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT),
               select.kevent(0, select.KQ_FILTER_READ, select.KQ_EV_ADD)], 0)
if pid.isdigit() and int(pid) > 0:
    try:
        queue.control([select.kevent(int(pid), select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0)
        os.write(1, b"armed %s\n" % pid.encode())
    except OSError as error:
        os.write(1, b"%s %s\n" % (b"gone" if error.errno == errno.ESRCH else b"unarmed", pid.encode()))
os.write(1, b"ready\n")
told = False
while True:
    if not told and os.path.exists(os.path.join(directory, "exit_code")):
        os.write(1, b"exit\n")
        told = True
    for event in queue.control(None, 8):
        if event.filter == select.KQ_FILTER_READ and not os.read(0, 4096):
            sys.exit(0)
        if event.filter == select.KQ_FILTER_PROC:
            if event.ident == parent:
                sys.exit(0)
            os.write(1, b"gone %d\n" % event.ident)
' "$1" "$2" 2>/dev/null; } 2>/dev/null
  read_end=${WAIT_WATCH[0]-}
  [ -n "$read_end" ] || return 1
  # A copy, because bash closes and unsets the coproc's own descriptors the moment it reaps the watcher.
  exec {WAIT_WATCH_IN}<&"$read_end" {read_end}<&-
  WAIT_WATCH_STATE=on
  wait_watch_line "^((armed|gone|unarmed) $2|ready)\$" 10 || { wait_watch_stop; return 1; }
  armed=$WAIT_WATCH_SEEN
  [ "$armed" = ready ] || wait_watch_line '^ready$' 10 || { wait_watch_stop; return 1; }
  [ "$armed" != "armed $2" ] || ! supervisor_running "$1" "$2" "$3" || WAIT_ARMED=$2 WAIT_ARMED_SINCE=$3
  return 0
}

wait_watch_stop() {
  [ "$WAIT_WATCH_STATE" = on ] || return 0
  WAIT_WATCH_STATE=off WAIT_ARMED=''
  exec {WAIT_WATCH_IN}<&-
}

wait_watch_line() { # regex seconds: fails on a timeout or on the armed pid's `gone`; a dead watcher is stopped
  local line now end left frac rc
  now=${EPOCHREALTIME/[.,]/}
  left=${2%%.*} frac=000000
  [[ "$2" != *.* ]] || { frac=${2#*.}000000; frac=${frac:0:6}; }
  end=$((now + ${left:-0} * 1000000 + 10#$frac))
  while :; do
    now=${EPOCHREALTIME/[.,]/}
    left=$((end - now))
    [ "$left" -gt 0 ] || return 1
    printf -v left '%d.%06d' "$((left / 1000000))" "$((left % 1000000))"
    IFS= read -r -t "$left" -u "$WAIT_WATCH_IN" line || {
      rc=$?
      [ "$rc" -gt 128 ] || wait_watch_stop
      return 1
    }
    WAIT_WATCH_SEEN=$line
    [[ ! "$line" =~ $1 ]] || return 0
    [ -z "$WAIT_ARMED" ] || [ "$line" != "gone $WAIT_ARMED" ] || { WAIT_ARMED=''; return 1; }
  done
}

wait_supervisor_running() { # directory pid pid_started_at
  [ -z "$WAIT_ARMED" ] || [ "$2" != "$WAIT_ARMED" ] || [ "$3" != "$WAIT_ARMED_SINCE" ] || return 0
  supervisor_running "$@"
}

wait_sleep() { # directory seconds: back early once exit_code appears; fails without the watcher
  [ "$WAIT_WATCH_STATE" = on ] || return 1
  [ ! -f "$1/exit_code" ] || return 0
  wait_watch_line '^exit$' "$2" || [ "$WAIT_WATCH_STATE" = on ] || return 1
  return 0
}

wait_report() { # directory
  report_run "${1##*/}"
  workdir_escape_line "$1"
}

# The one-call delegation: the account pick, the start and a `wait --report`, so a chat spends one
# background Bash and one wake on a run. `auto` is the vendor of worker-pick's NEXT row 1; a RESUME
# brief goes back to the vendor and account its session lives in.
run_run() { # auto|vendor start-args...
  [ "$#" -ge 1 ] || usage
  local vendor=$1 brief='' account='' handle='' entry='' picked started rc=0 run_id i role=''
  shift
  local -a args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
      --brief) brief=${args[i + 1]-} ;;
      --account) account=${args[i + 1]-} ;;
      --browser) role=browser ;;
    esac
  done
  [ -r "$brief" ] || fail "brief is not readable: ${brief:-none given}"
  [ -n "$account" ] || account=$(brief_line_value "$brief" ACCOUNT)
  case "$(brief_line_value "$brief" BROWSER)" in chrome | yes | dia) role=browser ;; esac
  handle=$(sed -n '1s/^RESUME \([^[:space:]:]\{1,\}\):.*/\1/p' "$brief" 2>/dev/null)
  if [ -n "$handle" ]; then
    if valid_run_id "$handle" && [ -r "$(run_path "$handle")/meta.json" ]; then entry=$(run_path "$handle")
    else
      entry=$(refuse_live_matches "$handle" "${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}" worker-session | head -n1)
      entry=${entry%/worker-session}
    fi
    if [ -n "$entry" ]; then
      [ "$vendor" != auto ] || vendor=$(jq -r '.vendor // "auto"' "$entry/meta.json" 2>/dev/null)
      [ -n "$account" ] || { account=$(jq -r '.account // empty' "$entry/meta.json" 2>/dev/null) && [ -n "$account" ] &&
        args+=(--account "$account"); }
    fi
  fi
  if [ "$vendor" = auto ]; then
    picked=$("${WORKER_RUN_WORKER_PICK:-$SCRIPT_DIRECTORY/worker-pick}" ${role:+--role "$role"} 2>/dev/null)
    vendor=$(sed -n 's/^START: worker-run [a-z]* \([a-z]*\)$/\1/p' <<<"$picked" | head -n1)
    picked=$(sed -n 's/^NEXT: //p' <<<"$picked" | head -n1)
    [ -n "$vendor" ] || fail "worker-pick names no vendor to start${picked:+ ($picked)}. Nothing was launched and no account was spent."
  fi
  started=$(start_run "$vendor" "${args[@]}") || rc=$?
  [ -z "$started" ] || grep -v '^NEXT: ' <<<"$started"
  [ "$rc" -eq 0 ] || exit "$rc"
  run_id=$(sed -n 's/^RUN: //p' <<<"$started" | head -n1)
  [ -n "$run_id" ] || exit 0
  # exec, so the process every wait reader looks for (the backstop, the statusline) is this wait.
  exec "$SCRIPT_PATH" wait "$run_id" --report
}

wait_run() {
  local rc=0
  wait_run_loop "$@" || rc=$?
  wait_watch_stop
  return "$rc"
}

wait_run_loop() {
  [ "$#" -ge 1 ] || usage
  local run_id="$1" max='' stream=false report=false directory wait_started now waited remaining sleep_for ticks pid account
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max) [ "$#" -ge 2 ] || usage; max="$2"; shift 2 ;;
      --report) report=true; shift ;;
      *) usage ;;
    esac
  done
  # No --max blocks until the run ends and streams its progress; a --max poll answers STATUS: running.
  # --report streams nothing and ends in the whole report: the chat reads that output once, on wake.
  if [ -z "$max" ]; then stream=true max=$((1 << 62)); fi
  [ "$report" = false ] || stream=false
  [[ "$max" =~ ^[0-9]+$ ]] || usage
  directory=$(run_path "$run_id")
  [ -d "$directory" ] && [ -r "$directory/meta.json" ] || fail "unknown run: $run_id"
  wait_started=$(date +%s)
  write_run_state "$directory" wait
  while :; do
    if [ -f "$directory/exit_code" ]; then
      WAIT_STAMP=''; wait_progress "$directory" "$run_id" "$stream"
      wait_poll_lag "$directory" "$run_id" "$wait_started"; run_state_terminal "$directory"
      if [ "$report" = true ]; then wait_report "$directory"; else terminal_report "$directory"; fi
      return 0
    fi
    wait_progress "$directory" "$run_id" "$stream"
    pid=$WAIT_PID
    # pid 0 is the pre-launch placeholder, and a probe of it would answer for our own
    # process group and report a never-started run as alive.
    if ! wait_supervisor_running "$directory" "$pid" "$WAIT_PID_STARTED" || run_overdue "$directory" "$WAIT_ATTEMPT_STARTED"; then
      sleep 0.1
      WAIT_STAMP=''; wait_progress "$directory" "$run_id" "$stream"
      if [ -f "$directory/exit_code" ]; then
        run_state_terminal "$directory"
        [ "$report" = true ] || terminal_report "$directory"
      else
        write_run_state "$directory" failed unknown
        chrome_run_end "$directory"
        [ "$report" = true ] || unknown_report "$directory"
      fi
      [ "$report" = false ] || wait_report "$directory"
      return 0
    fi
    printf -v now '%(%s)T' -1
    waited=$((now - wait_started)); [ "$waited" -ge 0 ] || waited=0
    if [ "$waited" -ge "$max" ]; then running_report "$directory"; return 0; fi
    remaining=$((max - waited))
    sleep_for=$WAIT_POLL; [[ "$sleep_for" == *.* || "$remaining" -ge "$sleep_for" ]] || sleep_for=$remaining
    wait_watch_start "$directory" "$pid" "$WAIT_PID_STARTED"
    wait_sleep "$directory" "$sleep_for" || exit_file_wait "$directory" "$sleep_for" || {
      ticks=$((${sleep_for%.*} * 5)); [ "$ticks" -gt 0 ] || ticks=1
      while [ "$ticks" -gt 0 ] && [ ! -f "$directory/exit_code" ]; do
        sleep 0.2; ticks=$((ticks - 1))
      done
    }
  done
}

# Not run_live: an overdue run's supervisor may still be alive, and stop must end it. Only a record
# without pid_started_at, whose pid may be recycled, needs run_live's overdue cutoff.
supervisor_stoppable() { # directory
  [ ! -e "$1/exit_code" ] && supervisor_running "$1" "$(jq -r '.pid // 0' "$1/meta.json" 2>/dev/null)" &&
    { jq -e '.pid_started_at != null' "$1/meta.json" >/dev/null 2>&1 || ! run_overdue "$1"; }
}

# A TaskStop of a background wait ends only the wait: the run is detached so a new wait can adopt it.
stop_command() {
  [ "$#" -eq 1 ] || usage
  local directory ticks=0 pid started
  directory=$(run_path "$1")
  [ -d "$directory" ] && [ -r "$directory/meta.json" ] || fail "unknown run: $1"
  if supervisor_stoppable "$directory"; then
    { read -r pid; read -r started; } < <(jq -r '(.pid // ""), (.pid_started_at // "")' "$directory/meta.json" 2>/dev/null)
    kill -TERM "$pid" 2>/dev/null
    while [ ! -e "$directory/exit_code" ] && supervisor_running "$directory" "$pid" "$started" &&
        { [ -n "$started" ] || ! run_overdue "$directory"; } && [ "$ticks" -lt 300 ]; do
      sleep 0.1
      ticks=$((ticks + 1))
    done
  fi
  wait_run "$1" --max 0
}

exit_file_wait() { # directory seconds: back as soon as exit_code appears, else after the seconds; fails without kqueue
  python3 - "$1" "$2" 2>/dev/null <<'PY'
import os, select, sys, time
directory, end = sys.argv[1], time.monotonic() + float(sys.argv[2])
queue = select.kqueue()
# Armed before the existence check, so an exit written in between still wakes the wait.
queue.control([select.kevent(os.open(directory, os.O_RDONLY), select.KQ_FILTER_VNODE,
                             select.KQ_EV_ADD | select.KQ_EV_CLEAR, select.KQ_NOTE_WRITE)], 0)
while not os.path.exists(os.path.join(directory, "exit_code")) and (left := end - time.monotonic()) > 0:
    queue.control(None, 1, left)
PY
}
