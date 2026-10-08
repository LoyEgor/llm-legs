#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/memlogd"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -ne 127 ] || fail "assert $asserts command not found: $*"
  fi
}

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
TICK_FILE="$WORK/tick"
AVAIL_FILE="$WORK/avail"
SWAP_TICK="$WORK/swap-tick"
SWAP_FILE="$WORK/swap"
NODE_TICK="$WORK/node-tick"
NODE_FILE="$WORK/node"
export TICK_FILE AVAIL_FILE SWAP_TICK SWAP_FILE NODE_TICK NODE_FILE

# One page = one MiB, so a fixture's "available MB" is literally its page count and no arithmetic
# stands between what a case declares and what the threshold sees.
cat >"$FAKE_BIN/vm_stat" <<'EOF'
#!/usr/bin/env bash
set -u
count=$(cat "$TICK_FILE" 2>/dev/null || echo 0)
printf '%s' "$((count + 1))" >"$TICK_FILE"
read -r -a values <<<"$(cat "$AVAIL_FILE")"
index=$count
[ "$index" -lt "${#values[@]}" ] || index=$(( ${#values[@]} - 1 ))
value=${values[$index]}
[ "$value" != "fail" ] || exit 1
printf 'Mach Virtual Memory Statistics: (page size of 1048576 bytes)\n'
printf 'Pages free: %s.\n' "$((value - 3))"
printf 'Pages active: 100.\n'
printf 'Pages inactive: 2.\n'
printf 'Pages speculative: 1.\n'
printf 'Pages wired down: 200.\n'
if [ -n "${SWAPINS_FILE:-}" ]; then
  read -r -a swapins <<<"$(cat "$SWAPINS_FILE")"
  index=$count
  [ "$index" -lt "${#swapins[@]}" ] || index=$(( ${#swapins[@]} - 1 ))
  printf 'Swapins: %s.\n' "${swapins[$index]}"
fi
EOF

cat >"$FAKE_BIN/notifyutil" <<'EOF'
#!/usr/bin/env bash
printf 'com.apple.system.thermalpressurelevel %s\n' "${THERMAL:-0}"
EOF

cat >"$FAKE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
[ -z "${JQ_FAILS:-}" ] || exit 1
exec /usr/bin/jq "$@"
EOF

cat >"$FAKE_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
set -u
case "$*" in
  *vm.loadavg*) [ -n "${LOADAVG:-}" ] || exit 1; printf '{ %s 1.00 0.50 }\n' "$LOADAVG"; exit 0 ;;
  *kern.boottime*) printf '8\n{ sec = 1790882097, usec = 398498 } Thu Oct  1 22:14:57 2026\n'; exit 0 ;;
esac
count=$(cat "$SWAP_TICK" 2>/dev/null || echo 0)
printf '%s' "$((count + 1))" >"$SWAP_TICK"
read -r -a values <<<"$(cat "$SWAP_FILE")"
index=$count
[ "$index" -lt "${#values[@]}" ] || index=$(( ${#values[@]} - 1 ))
printf 'total = 8192.00M  used = %s.00M  free = 100.00M  (encrypted)\n' "${values[$index]}"
EOF

cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -u
case "$*" in
  *rss=,comm=*)
    if [ -n "${NODE_FILE:-}" ] && [ -f "$NODE_FILE" ]; then
      ntick=$(cat "$NODE_TICK" 2>/dev/null || echo 0)
      printf '%s' "$((ntick + 1))" >"$NODE_TICK"
      read -r -a pairs <<<"$(cat "$NODE_FILE")"
      index=$ntick
      [ "$index" -lt "${#pairs[@]}" ] || index=$(( ${#pairs[@]} - 1 ))
      [ "${pairs[$index]}" != fail ] || exit 1
      IFS=, read -r ncount nrss <<<"${pairs[$index]}"
      i=0
      while [ "$i" -lt "$ncount" ]; do
        if [ "$i" -eq 0 ]; then
          printf '%8s %s\n' "$((nrss * 1024))" /opt/homebrew/bin/node
        else
          printf '%8s %s\n' 0 /opt/homebrew/bin/node
        fi
        i=$((i + 1))
      done
      printf '%8s %s\n' 900000 /Applications/Cursor.app/Contents/MacOS/Cursor
    else
      printf '%8s %s\n' 512000 /opt/homebrew/bin/node
      printf '%8s %s\n' 512000 '/Applications/Some App/node'
      printf '%8s %s\n' 512000 /usr/local/bin/node
      printf '%8s %s\n' 900000 /Applications/Cursor.app/Contents/MacOS/Cursor
    fi
    ;;
  *pid=,ppid=,pgid=,uid=,rss=,time=,etime=,state=,comm=*)
    # chat-load's table: the real ps cut down to the process groups a guard case spawned, so the
    # kills and the survivors are real and nothing outside the case is ever listed. Only the WEIGHT
    # is dictated, for the pids a case names — allocating 1.5 GB for real in a suite is not a test
    # of the guard, it is the bug the guard is for.
    [ -n "${GUARD_SCOPE:-}" ] || exit 0
    /bin/ps -axo "$2" | awk -v scope="$GUARD_SCOPE" -v fat="${HEAVY_PIDS:-}" -v foreign="${FOREIGN_PIDS:-}" '
      BEGIN {
        n = split(scope, groups, " ")
        for (i = 1; i <= n; i++) keep[groups[i] + 0] = 1
        n = split(fat, list, " ")
        # `pid` weighs the default; `pid=KB` weighs exactly that, for a case needing two weights.
        for (i = 1; i <= n; i++) heavy[list[i] + 0] = (split(list[i], part, "=") == 2) ? part[2] + 0 : 900000
        n = split(foreign, list, " ")
        for (i = 1; i <= n; i++) root[list[i] + 0] = 1
      }
      (($3 + 0) in keep) { if (($1 + 0) in heavy) $5 = heavy[$1 + 0]; if (($1 + 0) in root) $4 = 0; print }'
    ;;
  *pid,ppid,pgid,rss,etime,command*)
    printf '  PID  PPID  PGID    RSS  ELAPSED COMMAND\n'
    printf '    1     0     1  22096 05:32:41 /sbin/launchd\n'
    printf '  801   799   801 512000    01:12 node /tmp/worker.js\n'
    printf '  802   799   802 512000    00:04 node /tmp/worker.js\n'
    # A case that needs a frames file to reach the episode cap in a handful of ticks pads the dump.
    if [ "${PS_PAD_LINES:-0}" -gt 0 ]; then
      awk -v n="${PS_PAD_LINES}" 'BEGIN {
        pad = sprintf("%060d", 0)
        for (i = 0; i < n; i++) printf "  999   999   999 100000    00:01 %s\n", pad
      }'
    fi
    ;;
  *)
    printf 'UNEXPECTED-PS %s\n' "$*"
    ;;
esac
EOF

# A frames file that vanished between the glob and the stat: the real stat answers for the files
# that are still there and fails, whatever form the daemon asks in.
cat >"$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
set -u
if [ -n "${VANISH_FILE:-}" ]; then
  kept=()
  dropped=0
  for arg in "$@"; do
    if [ "$arg" = "$VANISH_FILE" ]; then dropped=1; continue; fi
    kept+=("$arg")
  done
  if [ "$dropped" = 1 ]; then
    [ "${#kept[@]}" -le 2 ] || /usr/bin/stat "${kept[@]}"
    printf 'stat: %s: No such file or directory\n' "$VANISH_FILE" >&2
    exit 1
  fi
fi
exec /usr/bin/stat "$@"
EOF

# Only the bare `date +%F` of a case that declares a day sequence is answered here; every other
# form, the daemon's own `date -v-Nd +%F` cutoff included, is the real date.
cat >"$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "$#" -eq 1 ] && [ "$1" = "+%F" ] && [ -n "${DAY_FILE:-}" ]; then
  count=$(cat "$DAY_TICK" 2>/dev/null || echo 0)
  printf '%s' "$((count + 1))" >"$DAY_TICK"
  read -r -a days <<<"$(cat "$DAY_FILE")"
  index=$count
  [ "$index" -lt "${#days[@]}" ] || index=$(( ${#days[@]} - 1 ))
  printf '%s\n' "${days[$index]}"
  exit 0
fi
# A case that needs an episode older than the retention window declares the episode file's stamp;
# the daemon's own cutoff stays real, so the two cannot drift onto the same side of it.
if [ "$#" -eq 3 ] && [ "$1" = "-r" ] && [ "$3" = "+%Y-%m-%dT%H%M%S" ] && [ -n "${FRAME_STAMP:-}" ]; then
  printf '%s\n' "$FRAME_STAMP"
  exit 0
fi
exec /bin/date "$@"
EOF
chmod +x "$FAKE_BIN/vm_stat" "$FAKE_BIN/sysctl" "$FAKE_BIN/ps" "$FAKE_BIN/date" "$FAKE_BIN/stat" \
  "$FAKE_BIN/notifyutil" "$FAKE_BIN/jq"
PATH="$FAKE_BIN:$PATH"
export PATH

# Every case declares its whole machine: an availability sequence, a swap sequence and both probe
# cursors, so no case reads what the case before it left behind.
probes() {
  printf '%s' "$1" >"$AVAIL_FILE"
  printf '%s' "$2" >"$SWAP_FILE"
  printf '0' >"$TICK_FILE"
  printf '0' >"$SWAP_TICK"
  rm -f "$NODE_FILE"
  printf '0' >"$NODE_TICK"
}

nodes() {
  printf '%s' "$1" >"$NODE_FILE"
  printf '0' >"$NODE_TICK"
}

# Day-file INCIDENT/JUMP markers name the frames file; the day log itself never holds PS-BEGIN.
frames_from() {
  local log="$1" base
  base=$(awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /^frames=/) { sub(/^frames=/, "", $i); print $i; exit }
  }' "$log")
  [ -n "$base" ] || return 1
  printf '%s/frames/%s\n' "$(dirname "$log")" "$base"
}

# The real ~/Library/Logs is never a test target: every case runs against its own MEMLOGD_DIR.
# Every seam chat-load reads is pinned to a fixture for EVERY case, not only the guard's own: it
# runs on every tick, and left at their defaults the registries, the live-session directories, the
# chat namer and the report bus would be Egor's real ones. A guard case passes its own, which land
# after these and win.
EMPTY_REGISTRY="$WORK/empty-registry"
mkdir -p "$EMPTY_REGISTRY/runs" "$EMPTY_REGISTRY/stats" "$EMPTY_REGISTRY/sessions"
BUS_LOG="$WORK/bus.log"
: >"$BUS_LOG"
export BUS_LOG
run_memlogd() {
  local dir="$1"; shift
  run_day=$(date +%F)
  env MEMLOGD_DIR="$dir" MEMLOGD_SYNC=0 MEMLOGD_QUIET_INTERVAL=0 MEMLOGD_INCIDENT_INTERVAL=0 \
    WORKER_RUN_DIR="$EMPTY_REGISTRY/runs" WORKER_STATS_DIR="$EMPTY_REGISTRY/stats" \
    CHAT_LOAD_SESSIONS="$EMPTY_REGISTRY/sessions" CHAT_NAME_ROOTS="$WORK/transcripts" \
    CHAT_NAMES_CACHE="$WORK/chat-names.json" CHAT_LOAD_REPORT_BUS="$FAKE_BIN/report-bus" GUARD_SCOPE='' \
    HARNESS_HOLDS_DIR="$EMPTY_REGISTRY/holds" "$@" bash "$SCRIPT" run
}

# The suite is allowed to run across midnight: a case writes under the day it started, and a
# rollover mid-case moves the log to the next one.
log_file() {
  local dir="$1" now
  now=$(date +%F)
  if [ ! -f "$dir/$run_day.log" ] && [ -f "$dir/$now.log" ]; then
    printf '%s/%s.log\n' "$dir" "$now"
  else
    printf '%s/%s.log\n' "$dir" "$run_day"
  fi
}

no_logs() { ! ls "$1"/????-??-??.log >/dev/null 2>&1; }

# --- quiet line format -------------------------------------------------------------------------
QUIET_DIR="$WORK/quiet"
probes 8192 1024
assert run_memlogd "$QUIET_DIR" MEMLOGD_MAX_TICKS=2
quiet_log=$(log_file "$QUIET_DIR")
assert test -f "$quiet_log"
assert test "$(wc -l <"$quiet_log")" -eq 2
assert grep -qE '^[0-9]{10} quiet avail_mb=8192 swap_used_mb=1024 node_count=3 node_rss_mb=1500$' \
  "$quiet_log"
assert_fails grep -q 'INCIDENT' "$quiet_log"

# --- machine sampler: its own day file, swap-in rate from deltas, the probe once a minute ---------
MACHINE_DIR="$WORK/machine"
printf '1000 1000 1600' >"$WORK/swapins"
probes 8192 1024
assert run_memlogd "$MACHINE_DIR" MEMLOGD_MAX_TICKS=3 MEMLOGD_QUIET_INTERVAL=1 MEMLOGD_MACHINE_INTERVAL=0 \
  LOADAVG=3.25 THERMAL=2 SWAPINS_FILE="$WORK/swapins"
machine_log="$MACHINE_DIR/machine/$run_day.log"
assert test "$(wc -l <"$machine_log")" -eq 3
assert grep -qE '^[0-9]{10} load1=3.25 ncpu=8 swap_mb=1024 swapin_pages_s=-1 thermal=2 boot=1790882097 probe_ms=[0-9]+$' \
  <(sed -n 1p "$machine_log")
assert grep -qE ' swapin_pages_s=0 thermal=2 boot=1790882097$' <(sed -n 2p "$machine_log")
assert grep -qE ' swapin_pages_s=(600|300|200) thermal=2 boot=1790882097$' <(sed -n 3p "$machine_log")
assert test "$(grep -c ' probe_ms=' "$machine_log")" -eq 1
assert test "$(wc -l <"$(log_file "$MACHINE_DIR")")" -eq 3

MACHINE_GATE_DIR="$WORK/machine-gate"
probes 8192 1024
assert run_memlogd "$MACHINE_GATE_DIR" MEMLOGD_MAX_TICKS=3 LOADAVG=1.5
assert test "$(wc -l <"$MACHINE_GATE_DIR/machine/$run_day.log")" -eq 1

MACHINE_FAIL_DIR="$WORK/machine-fail"
probes 8192 1024
assert run_memlogd "$MACHINE_FAIL_DIR" MEMLOGD_MAX_TICKS=1 JQ_FAILS=1
assert grep -qE '^[0-9]{10} load1=-1 ncpu=8 swap_mb=1024 swapin_pages_s=-1 thermal=0 boot=1790882097 probe_ms=-1$' \
  "$MACHINE_FAIL_DIR/machine/$run_day.log"

# --- a failed probe never reads as zero available ------------------------------------------------
PROBE_DIR="$WORK/probe"
probes fail 1024
assert run_memlogd "$PROBE_DIR" MEMLOGD_MAX_TICKS=1
probe_log=$(log_file "$PROBE_DIR")
assert grep -q 'quiet avail_mb=-1 swap_used_mb=1024 ' "$probe_log"
assert_fails grep -q 'INCIDENT' "$probe_log"

# --- incident trigger on available RAM -----------------------------------------------------------
INCIDENT_DIR="$WORK/incident"
probes '8192 2000 2000' 1024
assert run_memlogd "$INCIDENT_DIR" MEMLOGD_MAX_TICKS=3
incident_log=$(log_file "$INCIDENT_DIR")
assert grep -qE '^INCIDENT [0-9]{10} avail_mb=2000 swap_used_mb=1024 frames=[^ ]+\.log$' "$incident_log"
assert test "$(grep -c '^INCIDENT ' "$incident_log")" -eq 1
assert_fails grep -q '^PS-BEGIN ' "$incident_log"
incident_frames=$(frames_from "$incident_log")
assert test -f "$incident_frames"
assert test "$(grep -c '^PS-BEGIN ' "$incident_frames")" -eq 2
assert test "$(grep -c '^PS-END ' "$incident_frames")" -eq 2
assert grep -qE '^[0-9]{10} incident avail_mb=2000 swap_used_mb=1024 node_count=3 node_rss_mb=1500$' \
  "$incident_log"
# ppid/pgid/etime are the columns that expose a spawn loop, so the block carries the whole table.
assert grep -qE '^[0-9]{10} incident avail_mb=2000 swap_used_mb=1024 node_count=3 node_rss_mb=1500$' \
  "$incident_frames"
assert grep -q 'PID  PPID  PGID    RSS  ELAPSED COMMAND' "$incident_frames"
assert grep -q '  801   799   801 512000    01:12 node /tmp/worker.js' "$incident_frames"
assert_fails grep -q 'UNEXPECTED-PS' "$incident_frames"
assert_fails grep -q 'RECOVERED' "$incident_log"

# --- durable writes fsync the files written, never the whole machine -----------------------------
SYNC_BIN="$WORK/sync-bin"
SYNC_LOG="$WORK/sync.log"
mkdir -p "$SYNC_BIN"
: >"$SYNC_LOG"
printf '#!/usr/bin/env bash\nprintf "sync %%s\\n" "$*" >>"%s"\n' "$SYNC_LOG" >"$SYNC_BIN/sync"
printf '#!/usr/bin/env bash\nprintf "dd %%s\\n" "$*" >>"%s"\nexec /bin/dd "$@"\n' "$SYNC_LOG" >"$SYNC_BIN/dd"
chmod +x "$SYNC_BIN/sync" "$SYNC_BIN/dd"
DURABLE_DIR="$WORK/durable"
probes '8192 2000 2000' 1024
assert run_memlogd "$DURABLE_DIR" MEMLOGD_MAX_TICKS=3 MEMLOGD_SYNC=1 PATH="$SYNC_BIN:$PATH"
durable_log=$(log_file "$DURABLE_DIR")
durable_frames=$(frames_from "$durable_log")
assert_fails grep -q '^sync' "$SYNC_LOG"
assert grep -qxF "dd of=$durable_log conv=notrunc,fsync if=/dev/null" "$SYNC_LOG"
assert grep -qxF "dd of=$durable_frames conv=notrunc,fsync if=/dev/null" "$SYNC_LOG"
assert test "$(grep -c '^dd ' "$SYNC_LOG")" -eq 5
assert test "$(grep -c '^PS-BEGIN ' "$durable_frames")" -eq 2
assert grep -qE '^INCIDENT [0-9]{10} avail_mb=2000 ' "$durable_log"
assert test "$(grep -c ' incident avail_mb=2000 ' "$durable_log")" -eq 2

# --- swap decides nothing: a machine drowning in swap with healthy RAM stays quiet ----------------
# macOS keeps swap allocated for hours after the pressure that caused it is gone, so a swap term in
# the entry test latches 1 Hz process dumps for a whole day.
SWAP_DIR="$WORK/swap-quiet"
probes 8192 9000
assert run_memlogd "$SWAP_DIR" MEMLOGD_MAX_TICKS=2
swap_log=$(log_file "$SWAP_DIR")
assert_fails grep -q 'INCIDENT' "$swap_log"
assert_fails grep -q '^PS-BEGIN ' "$swap_log"
assert grep -q ' quiet avail_mb=8192 swap_used_mb=9000 ' "$swap_log"

# --- and it decides nothing on the way out either: available RAM alone recovers -------------------
SWAP_EXIT_DIR="$WORK/swap-exit"
probes '2000 6000 6000' 9000
assert run_memlogd "$SWAP_EXIT_DIR" MEMLOGD_MAX_TICKS=3 MEMLOGD_RECOVER_SECONDS=0
swap_exit_log=$(log_file "$SWAP_EXIT_DIR")
assert grep -qE '^INCIDENT [0-9]{10} avail_mb=2000 swap_used_mb=9000 frames=[^ ]+\.log$' "$swap_exit_log"
# Swap never moved, and the markers still carry it as data.
assert grep -qE '^RECOVERED [0-9]{10} avail_mb=6000 swap_used_mb=9000$' "$swap_exit_log"
assert_fails grep -q '^PS-BEGIN ' "$swap_exit_log"
assert test "$(grep -c '^PS-BEGIN ' "$(frames_from "$swap_exit_log")")" -eq 2
assert grep -q ' quiet avail_mb=6000 swap_used_mb=9000 ' "$swap_exit_log"

# --- a probe that breaks mid-incident is unknown, never a reason to stay latched -------------------
LATCH_DIR="$WORK/latch"
probes '2000 fail fail' 1024
assert run_memlogd "$LATCH_DIR" MEMLOGD_MAX_TICKS=3 MEMLOGD_RECOVER_SECONDS=0
latch_log=$(log_file "$LATCH_DIR")
assert grep -qE '^RECOVERED [0-9]{10} avail_mb=-1 swap_used_mb=1024$' "$latch_log"
assert test "$(grep -c '^INCIDENT ' "$latch_log")" -eq 1
assert grep -q ' quiet avail_mb=-1 ' "$latch_log"

# --- hysteresis holds the incident open while the recovery window is unmet ------------------------
HOLD_DIR="$WORK/hold"
probes '2000 6000 6000 6000' 1024
assert run_memlogd "$HOLD_DIR" MEMLOGD_MAX_TICKS=4 MEMLOGD_RECOVER_SECONDS=600
hold_log=$(log_file "$HOLD_DIR")
assert grep -q '^INCIDENT ' "$hold_log"
assert_fails grep -q '^RECOVERED ' "$hold_log"
assert_fails grep -q '^PS-BEGIN ' "$hold_log"
assert test "$(grep -c '^PS-BEGIN ' "$(frames_from "$hold_log")")" -eq 4

# --- a met recovery window closes the incident and returns the loop to quiet ----------------------
RECOVER_DIR="$WORK/recover"
probes '2000 6000 6000' 1024
assert run_memlogd "$RECOVER_DIR" MEMLOGD_MAX_TICKS=3 MEMLOGD_RECOVER_SECONDS=0
recover_log=$(log_file "$RECOVER_DIR")
assert grep -qE '^RECOVERED [0-9]{10} avail_mb=6000 swap_used_mb=1024$' "$recover_log"
assert_fails grep -q '^PS-BEGIN ' "$recover_log"
assert test "$(grep -c '^PS-BEGIN ' "$(frames_from "$recover_log")")" -eq 2
assert grep -q ' quiet avail_mb=6000 ' "$recover_log"
# Pressure between the enter and exit thresholds is not enough to re-open a closed incident.
assert test "$(grep -c '^INCIDENT ' "$recover_log")" -eq 1

# --- an incident that spans midnight marks the new day's file too ---------------------------------
# Without a marker of its own that file is a quiet log to rotation, and the tail of the incident is
# the part that gets deleted.
MIDNIGHT_DIR="$WORK/midnight"
DAY_FILE="$WORK/days"
DAY_TICK="$WORK/day-tick"
first_day=$(/bin/date -v-1d +%F)
second_day=$(/bin/date +%F)
printf '%s %s %s' "$first_day" "$first_day" "$second_day" >"$DAY_FILE"
printf '0' >"$DAY_TICK"
probes 2000 1024
assert run_memlogd "$MIDNIGHT_DIR" MEMLOGD_MAX_TICKS=2 MEMLOGD_RECOVER_SECONDS=600 \
  DAY_FILE="$DAY_FILE" DAY_TICK="$DAY_TICK"
assert grep -qE '^INCIDENT [0-9]{10} avail_mb=2000 swap_used_mb=1024 frames=[^ ]+\.log$' \
  "$MIDNIGHT_DIR/$first_day.log"
assert grep -qE '^INCIDENT [0-9]{10} continued=1$' "$MIDNIGHT_DIR/$second_day.log"
assert_fails grep -q '^PS-BEGIN ' "$MIDNIGHT_DIR/$first_day.log"
assert_fails grep -q '^PS-BEGIN ' "$MIDNIGHT_DIR/$second_day.log"
midnight_frames=$(frames_from "$MIDNIGHT_DIR/$first_day.log")
assert test -f "$midnight_frames"
assert test "$(grep -c '^PS-BEGIN ' "$midnight_frames")" -eq 2

# --- rotation: three days flat, and an INCIDENT day is no exemption -------------------------------
ROTATE_DIR="$WORK/rotate"
mkdir -p "$ROTATE_DIR"
quiet_line='1700000000 quiet avail_mb=8192 swap_used_mb=0 node_count=0 node_rss_mb=0'
# A day either side of the 3-day cutoff, never the edge itself: a midnight crossing between these
# dates and the daemon's own cutoff cannot move either one across it.
inside_edge=$(date -v-2d +%F)
outside_edge=$(date -v-4d +%F)
printf '%s\n' "$quiet_line" >"$ROTATE_DIR/2000-01-01.log"
printf 'INCIDENT 946684800 avail_mb=100 swap_used_mb=7000\n' >"$ROTATE_DIR/2000-01-02.log"
printf '%s\n' "$quiet_line" >"$ROTATE_DIR/$inside_edge.log"
printf 'INCIDENT 1700000000 avail_mb=100 swap_used_mb=7000\n' >"$ROTATE_DIR/$outside_edge.log"
printf 'keep me\n' >"$ROTATE_DIR/notes.txt"
mkdir -p "$ROTATE_DIR/machine"
printf '1700000000 load1=1\n' >"$ROTATE_DIR/machine/$outside_edge.log"
printf '1700000000 load1=1\n' >"$ROTATE_DIR/machine/$inside_edge.log"
# Today's file is the one the incident evidence is read from, whatever it holds.
printf 'INCIDENT 1700000000 avail_mb=100 swap_used_mb=7000\n' >"$ROTATE_DIR/$(date +%F).log"
probes 8192 1024
assert run_memlogd "$ROTATE_DIR" MEMLOGD_MAX_TICKS=1
assert_fails test -e "$ROTATE_DIR/2000-01-01.log"
assert_fails test -e "$ROTATE_DIR/2000-01-02.log"
assert test -f "$ROTATE_DIR/$inside_edge.log"
assert_fails test -e "$ROTATE_DIR/$outside_edge.log"
assert test -f "$ROTATE_DIR/notes.txt"
assert_fails test -e "$ROTATE_DIR/machine/$outside_edge.log"
assert test -f "$ROTATE_DIR/machine/$inside_edge.log"
rotate_log=$(log_file "$ROTATE_DIR")
assert test -f "$rotate_log"
assert grep -q '^INCIDENT 1700000000 ' "$rotate_log"
assert grep -q ' quiet avail_mb=8192 ' "$rotate_log"

# --- and the retention window is a knob, not a constant -------------------------------------------
SHORT_DIR="$WORK/rotate-short"
mkdir -p "$SHORT_DIR/frames"
short_keep=$(date -v-4d +%F)
short_drop=$(date -v-6d +%F)
printf '%s\n' "$quiet_line" >"$SHORT_DIR/$short_keep.log"
printf '%s\n' "$quiet_line" >"$SHORT_DIR/$short_drop.log"
printf 'keep\n' >"$SHORT_DIR/frames/${short_keep}T000000.log"
printf 'drop\n' >"$SHORT_DIR/frames/${short_drop}T000000.log"
printf 'drop\n' >"$SHORT_DIR/frames/jump-${short_drop}T010000.log"
probes 8192 1024
assert run_memlogd "$SHORT_DIR" MEMLOGD_MAX_TICKS=1 MEMLOGD_RETENTION_DAYS=5
assert test -f "$SHORT_DIR/$short_keep.log"
assert_fails test -e "$SHORT_DIR/$short_drop.log"
assert test -f "$SHORT_DIR/frames/${short_keep}T000000.log"
assert_fails test -e "$SHORT_DIR/frames/${short_drop}T000000.log"
assert_fails test -e "$SHORT_DIR/frames/jump-${short_drop}T010000.log"

# --- frames budget: oldest-first eviction, never the live episode ---------------------------------
EVICT_DIR="$WORK/evict"
mkdir -p "$EVICT_DIR/frames"
evict_old="$EVICT_DIR/frames/2020-01-01T000000.log"
evict_newer="$EVICT_DIR/frames/2020-01-02T000000.log"
dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\0' 'x' >"$evict_old"
dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\0' 'x' >"$evict_newer"
touch -t 202001010000 "$evict_old"
touch -t 202001020000 "$evict_newer"
probes 2000 1024
assert run_memlogd "$EVICT_DIR" MEMLOGD_MAX_TICKS=1 MEMLOGD_MAX_FRAMES_MB=1 MEMLOGD_RETENTION_DAYS=9999
evict_log=$(log_file "$EVICT_DIR")
evict_frames=$(frames_from "$evict_log")
assert test -f "$evict_frames"
assert_fails test -e "$evict_old"
assert test -f "$evict_newer"
assert_fails grep -q '^PS-BEGIN ' "$evict_log"
assert grep -q '^PS-BEGIN ' "$evict_frames"

# --- fast then slow: summaries every tick, frames drop after FAST_SECONDS -------------------------
# Loop stays at incident_interval (1s / 0 in tests); slow phase skips the ps dump, not the sleep.
CADENCE_DIR="$WORK/cadence"
probes 2000 1024
assert run_memlogd "$CADENCE_DIR" MEMLOGD_MAX_TICKS=4 MEMLOGD_FAST_SECONDS=0 \
  MEMLOGD_SLOW_INTERVAL=30 MEMLOGD_RECOVER_SECONDS=600
cadence_log=$(log_file "$CADENCE_DIR")
assert test "$(grep -c ' incident avail_mb=' "$cadence_log")" -eq 4
assert test "$(grep -c '^PS-BEGIN ' "$(frames_from "$cadence_log")")" -eq 1
assert_fails grep -q '^PS-BEGIN ' "$cadence_log"

# --- quiet-state jump: one frame + JUMP marker, state stays quiet ---------------------------------
JUMP_DIR="$WORK/jump"
probes 8192 1024
nodes '3,1500 11,1500'
assert run_memlogd "$JUMP_DIR" MEMLOGD_MAX_TICKS=2
jump_log=$(log_file "$JUMP_DIR")
assert grep -qE '^JUMP [0-9]{10} node_count=11 node_rss_mb=1500 frames=jump-[^ ]+\.log$' "$jump_log"
assert test "$(grep -c '^JUMP ' "$jump_log")" -eq 1
assert_fails grep -q 'INCIDENT' "$jump_log"
assert grep -q ' quiet avail_mb=8192 ' "$jump_log"
jump_frames=$(frames_from "$jump_log")
assert test -f "$jump_frames"
assert test "$(grep -c '^PS-BEGIN ' "$jump_frames")" -eq 1
# A quiet-state jump is not an incident, and its frame header is what a reader greps by.
assert grep -qE '^[0-9]{10} jump avail_mb=8192 swap_used_mb=1024 node_count=11 node_rss_mb=1500$' \
  "$jump_frames"
assert_fails grep -q ' incident avail_mb=' "$jump_frames"
assert_fails grep -q '^PS-BEGIN ' "$jump_log"
assert test "$(find "$JUMP_DIR/frames" -name 'jump-*.log' | wc -l | tr -d ' ')" -eq 1

# --- below both jump thresholds: no frame, no marker ----------------------------------------------
NOJUMP_DIR="$WORK/nojump"
probes 8192 1024
nodes '3,1500 10,2523'
assert run_memlogd "$NOJUMP_DIR" MEMLOGD_MAX_TICKS=2
nojump_log=$(log_file "$NOJUMP_DIR")
assert_fails grep -q '^JUMP ' "$nojump_log"
assert_fails grep -q 'INCIDENT' "$nojump_log"
assert_fails test -e "$NOJUMP_DIR/frames"

# --- a failed ps probe is unknown, and the healthy tick after it is no jump ------------------------
PSFAIL_DIR="$WORK/psfail"
probes 8192 1024
nodes 'fail 3,1500'
assert run_memlogd "$PSFAIL_DIR" MEMLOGD_MAX_TICKS=2
psfail_log=$(log_file "$PSFAIL_DIR")
assert grep -qE '^[0-9]{10} quiet avail_mb=8192 swap_used_mb=1024 node_count=-1 node_rss_mb=-1$' \
  "$psfail_log"
assert grep -qE '^[0-9]{10} quiet avail_mb=8192 swap_used_mb=1024 node_count=3 node_rss_mb=1500$' \
  "$psfail_log"
assert_fails grep -q '^JUMP ' "$psfail_log"
assert_fails test -e "$PSFAIL_DIR/frames"

# --- episode cap: a long episode stops writing frames and says so once ----------------------------
# The directory cap spares the live episode, so without a cap of its own a slow-phase freeze grows
# without bound and its eviction burns every older episode to make room.
EPCAP_DIR="$WORK/episode-cap"
probes 2000 1024
assert run_memlogd "$EPCAP_DIR" MEMLOGD_MAX_TICKS=4 MEMLOGD_RECOVER_SECONDS=600 \
  MEMLOGD_MAX_EPISODE_MB=1 PS_PAD_LINES=8000
epcap_log=$(log_file "$EPCAP_DIR")
epcap_frames=$(frames_from "$epcap_log")
assert test "$(grep -c '^PS-BEGIN ' "$epcap_frames")" -eq 2
assert test "$(grep -c '^EPISODE-CAP ' "$epcap_log")" -eq 1
assert grep -qE "^EPISODE-CAP [0-9]{10} frames=$(basename "$epcap_frames")\$" "$epcap_log"
# Summaries are the part that must survive the cap.
assert test "$(grep -c ' incident avail_mb=' "$epcap_log")" -eq 4
assert_fails grep -q '^PS-BEGIN ' "$epcap_log"

# --- rotation spares the frames file the live episode is still writing ----------------------------
LIVE_DIR="$WORK/rotate-live"
LIVE_DAYS="$WORK/live-days"
LIVE_DAY_TICK="$WORK/live-day-tick"
live_day=$(/bin/date +%F)
live_next=$(/bin/date -v+1d +%F)
printf '%s %s %s' "$live_day" "$live_day" "$live_next" >"$LIVE_DAYS"
printf '0' >"$LIVE_DAY_TICK"
# An episode that opened before the retention window: the rotate on the midnight rollover reads
# that date out of the file name and would delete the freeze in progress.
live_stamp="$(/bin/date -v-10d +%F)T000000"
probes 2000 1024
assert run_memlogd "$LIVE_DIR" MEMLOGD_MAX_TICKS=2 MEMLOGD_RECOVER_SECONDS=600 \
  DAY_FILE="$LIVE_DAYS" DAY_TICK="$LIVE_DAY_TICK" FRAME_STAMP="$live_stamp"
assert grep -qE "^INCIDENT [0-9]{10} avail_mb=2000 swap_used_mb=1024 frames=$live_stamp\.log\$" \
  "$LIVE_DIR/$live_day.log"
assert grep -qE '^INCIDENT [0-9]{10} continued=1$' "$LIVE_DIR/$live_next.log"
assert test -f "$LIVE_DIR/frames/$live_stamp.log"
assert test "$(grep -c '^PS-BEGIN ' "$LIVE_DIR/frames/$live_stamp.log")" -eq 2

# --- frames budget: one listing pass, names with spaces, a file that vanished under it ------------
RACE_DIR="$WORK/evict-race"
mkdir -p "$RACE_DIR/frames"
race_old="$RACE_DIR/frames/2020-01-01T000000 old.log"
race_newer="$RACE_DIR/frames/2020-01-02T000000 newer.log"
race_ghost="$RACE_DIR/frames/2020-01-03T000000.log"
for race_file in "$race_old" "$race_newer" "$race_ghost"; do
  dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\0' 'x' >"$race_file"
done
touch -t 202001010000 "$race_old"
touch -t 202001020000 "$race_newer"
touch -t 202001030000 "$race_ghost"
probes 2000 1024
assert run_memlogd "$RACE_DIR" MEMLOGD_MAX_TICKS=1 MEMLOGD_MAX_FRAMES_MB=1 \
  MEMLOGD_RETENTION_DAYS=9999 VANISH_FILE="$race_ghost"
race_log=$(log_file "$RACE_DIR")
assert_fails test -e "$race_old"
assert test -f "$race_newer"
assert grep -q '^PS-BEGIN ' "$(frames_from "$race_log")"

# --- single instance ------------------------------------------------------------------------------
LOCK_DIR="$WORK/lock"
mkdir -p "$LOCK_DIR/memlogd.lock"
printf '%s\n' "$$" >"$LOCK_DIR/memlogd.lock/pid"
probes 8192 1024
refusal=$(run_memlogd "$LOCK_DIR" MEMLOGD_MAX_TICKS=1 2>&1)
status=$?
assert test "$status" -eq 3
assert grep -q "already running (pid $$)" <<<"$refusal"
assert no_logs "$LOCK_DIR"

# A holder that has not written its pid yet is a daemon mid-start, and taking that lock over is how
# two of them end up sampling the same file.
rm -f "$LOCK_DIR/memlogd.lock/pid"
probes 8192 1024
refusal=$(run_memlogd "$LOCK_DIR" MEMLOGD_MAX_TICKS=1 2>&1)
status=$?
assert test "$status" -eq 3
assert grep -q 'no pid written' <<<"$refusal"
assert test -d "$LOCK_DIR/memlogd.lock"
assert no_logs "$LOCK_DIR"

# A lock left behind by a crash is not a live holder, and the daemon must take it over.
dead_pid=$(bash -c 'echo $$')
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
printf '%s\n' "$dead_pid" >"$LOCK_DIR/memlogd.lock/pid"
probes 8192 1024
assert run_memlogd "$LOCK_DIR" MEMLOGD_MAX_TICKS=1
assert grep -q ' quiet avail_mb=8192 ' "$(log_file "$LOCK_DIR")"
assert_fails test -e "$LOCK_DIR/memlogd.lock"

# --- the memory guard (bin/chat-load, run by the daemon every tick) ----------------------------
# Every case spawns REAL process groups and asserts against real signals: a fixture process table
# cannot be killed, and the whole point of the rule is which processes are still alive after. The
# fake ps shows chat-load only the groups a case put in GUARD_SCOPE, so nothing else on this Mac is
# ever in reach of a kill.
GUARD_ROOT="$WORK/guard"
SESSIONS_DIR="$GUARD_ROOT/sessions"
GUARD_SCOPE=''

# Records every post with how many of the job's processes were still alive at that instant: the
# notice must be on the bus BEFORE the kill, or the killed tool call's own hook flush misses it.
cat >"$FAKE_BIN/report-bus" <<'EOF'
#!/usr/bin/env bash
set -u
body=$(cat)
[ -z "${BUS_FAIL:-}" ] || exit 126
[ -z "${BUS_SLOW:-}" ] || sleep "$BUS_SLOW"
if [ -n "${BUS_JOIN:-}" ]; then
  python3 -c 'import os, sys, time; os.setpgid(0, int(sys.argv[1])); open(sys.argv[2], "w").write(str(os.getpid())); time.sleep(300)' \
    "$BUS_JOIN" "$BUS_JOINED.tmp" >/dev/null 2>&1 &
  for _ in $(seq 1 100); do [ ! -s "$BUS_JOINED.tmp" ] || break; sleep 0.02; done
  mv "$BUS_JOINED.tmp" "$BUS_JOINED"
fi
alive=0
for pid in ${BUS_WATCH:-}; do
  state=$(/bin/ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  case "$state" in ''|Z*) ;; *) alive=$((alive + 1)) ;; esac
done
frame=missing
[ ! -r "${REPORT_FRAME:-}" ] || frame=readable
if [ -n "${BUS_PEERS:-}" ]; then
  : >"$BUS_PEERS/$$"
  waited=0
  while [ "$(ls "$BUS_PEERS" | wc -l)" -lt "$BUS_PEERS_WANT" ] && [ "$waited" -lt 20 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  printf '%s peers=%s\n' "$*" "$(ls "$BUS_PEERS" | wc -l | tr -d ' ')" >>"$BUS_PEERS.log"
fi
printf '%s alive=%s frame=%s body=%s\n' "$*" "$alive" "$frame" "$body" >>"$BUS_LOG"
EOF
chmod +x "$FAKE_BIN/report-bus"

# The suite may itself run inside a chat, so its own session variables are scrubbed: a fixture is
# attributed only by what the case hands it, standing in for what a chat's Bash tool exports.
# Fixtures are python, never bash or sleep: macOS hides a platform binary's environment from
# KERN_PROCARGS2, so a bash fixture would be attributed by ancestry alone and the env path untested.
FIXTURE_PY=$(command -v python3)
session_env() { # session launcher
  GROUP_ENV=(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_LAUNCHER_SESSION)
  [ -z "$1" ] || GROUP_ENV+=("CLAUDE_CODE_SESSION_ID=$1")
  [ -z "$2" ] || GROUP_ENV+=("CLAUDE_LAUNCHER_SESSION=$2")
}

# One process group, as every Bash call a chat makes is: a root that leads the group and outlives
# its children (it never reaps them), under it an optional middle level, then two sleepers.
cat >"$WORK/tree.py" <<'PY'
import os, subprocess, sys, time
report, levels = sys.argv[1], int(sys.argv[2])
chain = sys.argv[3:]
if not chain:
    os.setpgrp()
chain.append(str(os.getpid()))
if len(chain) < levels:
    subprocess.Popen([sys.executable, __file__, report, str(levels)] + chain)
else:
    sleepers = [subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"]) for _ in range(2)]
    with open(report + ".tmp", "w") as handle:
        handle.write(" ".join(chain + [str(p.pid) for p in sleepers]) + "\n")
    os.rename(report + ".tmp", report)
time.sleep(300)
PY
TREE_PIDS=()
spawn_group() { # levels session launcher -> sets GROUP_PIDS
  local report="$WORK/group-$RANDOM.pids" waited=0
  rm -f "$report"
  session_env "$2" "$3"
  "${GROUP_ENV[@]}" "$FIXTURE_PY" "$WORK/tree.py" "$report" "$1" >/dev/null 2>&1 &
  disown
  while [ ! -s "$report" ] && [ "$waited" -lt 200 ]; do sleep 0.05; waited=$((waited + 1)); done
  read -r -a GROUP_PIDS <"$report"
  TREE_PIDS+=("${GROUP_PIDS[@]}")
  GUARD_SCOPE="${GUARD_SCOPE:+$GUARD_SCOPE }${GROUP_PIDS[0]}"
  rm -f "$report"
}
spawn_tree() { # [session] [launcher] -> sets TREE_ROOT / TREE_KIDS
  spawn_group 1 "${1:-}" "${2:-}"
  TREE_ROOT=${GROUP_PIDS[0]} TREE_KIDS="${GROUP_PIDS[1]} ${GROUP_PIDS[2]}"
}
# The real shape of a worker run: a supervisor holding a vendor CLI which holds the work.
spawn_deep_tree() { # [session] [launcher] -> sets DEEP_SUP / DEEP_CLI / DEEP_KIDS
  spawn_group 2 "${1:-}" "${2:-}"
  DEEP_SUP=${GROUP_PIDS[0]} DEEP_CLI=${GROUP_PIDS[1]} DEEP_KIDS="${GROUP_PIDS[2]} ${GROUP_PIDS[3]}"
}
# A lone process in its own group: the stand-in for a chat's CLI.
spawn_leaf() { # [session] -> sets LEAF_ROOT
  session_env "${1:-}" ''
  "${GROUP_ENV[@]}" "$FIXTURE_PY" -c 'import os, time; os.setpgrp(); time.sleep(300)' >/dev/null 2>&1 &
  LEAF_ROOT=$!
  disown
  TREE_PIDS+=("$LEAF_ROOT")
  GUARD_SCOPE="${GUARD_SCOPE:+$GUARD_SCOPE }$LEAF_ROOT"
  local waited=0
  while [ "$(/bin/ps -o pgid= -p "$LEAF_ROOT" 2>/dev/null | tr -d ' ')" != "$LEAF_ROOT" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05; waited=$((waited + 1))
  done
}
reap_trees() { local pid; for pid in ${TREE_PIDS[@]+"${TREE_PIDS[@]}"}; do kill -KILL "$pid" 2>/dev/null || :; done; }
trap 'reap_trees; rm -rf "$WORK"' EXIT

# A zombie is dead, and `kill -0` succeeds on one: these fixture roots deliberately do not reap, so
# liveness is asked of the real ps.
alive() {
  local state
  state=$(/bin/ps -o state= -p "$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$state" ] || return 1
  case "$state" in Z*) return 1 ;; esac
  return 0
}
gone() {
  local waited=0
  while alive "$1" && [ "$waited" -lt 100 ]; do sleep 0.05; waited=$((waited + 1)); done
  ! alive "$1"
}

# A live chat, in the shape Claude Code writes `<config>/sessions/<pid>.json`, and its transcript
# carrying the title the real resolver (share/chat_names.py) names it by.
register_session() { # session pid [status]
  jq -n --arg sid "$1" --argjson pid "$2" --arg status "${3:-busy}" \
    '{pid: $pid, sessionId: $sid, cwd: "/tmp", startedAt: 0, status: $status}' >"$SESSIONS_DIR/$2.json"
  retitle "$1" "Chat $1"
}
retitle() { # session title ('' = untitled)
  mkdir -p "$WORK/transcripts/demo"
  { jq -nc '{type: "user", cwd: "/work/demo"}'
    [ -z "$2" ] || jq -nc --arg title "$2" '{type: "custom-title", customTitle: $title}'
  } >"$WORK/transcripts/demo/$1.jsonl"
}
# Written through jq exactly as worker-run writes it (`"pid": N`, a space after the colon).
register_run() { # run-id supervisor-pid [cli-pid]
  mkdir -p "$GUARD_ROOT/runs/$1"
  jq -n --argjson pid "$2" --arg cli "${3:-}" --argjson began "$(date +%s)" \
    '{vendor: "claudeb", account: "main", pid: $pid, pid_started_at: $began, workdir: "/tmp"}
     + if $cli == "" then {} else {cli_pid: ($cli | tonumber), cli_pid_started_at: $began} end' \
    >"$GUARD_ROOT/runs/$1/meta.json"
}
register_cell() { # bench-run-id cell-artifact root-pid
  mkdir -p "$GUARD_ROOT/stats/benches/$1"
  printf '%s\n' "$3" >"$GUARD_ROOT/stats/benches/$1/pid-$2"
}

clear_registry() {
  rm -rf "$GUARD_ROOT/runs" "$GUARD_ROOT/stats" "$SESSIONS_DIR"
  mkdir -p "$GUARD_ROOT/runs" "$GUARD_ROOT/stats" "$SESSIONS_DIR"
  : >"$BUS_LOG"
  rm -rf "$WORK/transcripts"
  GUARD_SCOPE=''
}

guard_run() { # log-dir extra-env...
  local dir="$1"; shift
  run_memlogd "$dir" WORKER_RUN_DIR="$GUARD_ROOT/runs" WORKER_STATS_DIR="$GUARD_ROOT/stats" \
    CHAT_LOAD_SESSIONS="$SESSIONS_DIR" GUARD_SCOPE="$GUARD_SCOPE" "$@"
}
chats_json() { printf '%s/chats.json\n' "$1"; }

# Healthy RAM: the availability half is unmet, so a fat chat job is left alone. Availability
# alone can never convict.
clear_registry
spawn_tree chat-roomy
ROOMY_ROOT=$TREE_ROOT ROOMY_KIDS=$TREE_KIDS
ROOMY_DIR="$WORK/guard-roomy"
probes 8192 1024
assert guard_run "$ROOMY_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$ROOMY_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$ROOMY_DIR")"
for pid in $ROOMY_ROOT $ROOMY_KIDS; do assert alive "$pid"; done
assert test ! -s "$BUS_LOG"

# Low RAM but no job over the ceiling: three sleeping shells weigh a few MB, so the fattest-job half
# is unmet. The job half alone cannot convict either.
clear_registry
spawn_tree chat-thin
THIN_ROOT=$TREE_ROOT THIN_KIDS=$TREE_KIDS
THIN_DIR="$WORK/guard-thin"
probes 2000 1024
assert guard_run "$THIN_DIR" MEMLOGD_MAX_TICKS=1
assert_fails grep -q '^KILLED ' "$(log_file "$THIN_DIR")"
for pid in $THIN_ROOT $THIN_KIDS; do assert alive "$pid"; done

# Both halves met by a chat's own Bash job — the 2026-09-28 freeze, which no registry knew about.
# The whole group goes, its shell included; the chat's CLI, in a group of its own, stays; and the
# chat hears why BEFORE its job dies.
clear_registry
spawn_leaf
FAT_CLI=$LEAF_ROOT
register_session chat-fat "$FAT_CLI"
spawn_tree chat-fat
FAT_ROOT=$TREE_ROOT FAT_KIDS=$TREE_KIDS
FAT_DIR="$WORK/guard-fat"
probes 2000 1024
assert guard_run "$FAT_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$FAT_KIDS" BUS_WATCH="$FAT_ROOT $FAT_KIDS"
fat_log=$(log_file "$FAT_DIR")
assert grep -qE '^KILLED [0-9]{10} chat=chat-fat job_pgid='"$FAT_ROOT"' avail_mb=2000 job_rss_mb=[0-9]+ killed=[0-9]+,[0-9]+,[0-9]+ notified=chat-fat$' "$fat_log"
assert test "$(awk -F'job_rss_mb=' '/^KILLED /{ split($2, f, " "); print (f[1] > 1536) }' "$fat_log")" = 1
for pid in $FAT_ROOT $FAT_KIDS; do assert gone "$pid"; done
assert alive "$FAT_CLI"
assert test "$(wc -l <"$BUS_LOG" | tr -d ' ')" = 1
assert grep -qE "^post --kind notice --id memguard-[0-9]{10}-$FAT_ROOT --session chat-fat alive=3 frame=readable body=" "$BUS_LOG"
bus_body=$(sed 's/^.* body=//' "$BUS_LOG")
assert test "$(jq -r .word <<<"$bus_body")" = 'memory guard'
assert test "$(jq -r '.rows | map(.[0]) | join(",")' <<<"$bus_body")" = 'stopped,why,this is,next'
assert grep -q 'not a crash' <<<"$bus_body"
# Egor sees it too: the menu snapshot names the chat, in red, for the next quarter hour.
assert test "$(jq -r .alarm "$(chats_json "$FAT_DIR")")" = true
assert jq -e '.rows[] | objects | select(.alarm) | .text | test("^⚠ [0-9]{2}:[0-9]{2} guard killed a job of Chat chat-fat · freed [0-9.]+ GB$")' \
  "$(chats_json "$FAT_DIR")"

# A job never takes its chat's CLI or the CLI's ancestors with it, even in one group: the registry
# pid is protected and so is everything above it, while the work below goes.
clear_registry
spawn_deep_tree chat-deep
register_session chat-deep "$DEEP_CLI"
DEEP_DIR="$WORK/guard-deep"
probes 2000 1024
assert guard_run "$DEEP_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DEEP_KIDS"
assert grep -q "^KILLED .* chat=chat-deep job_pgid=$DEEP_SUP " "$(log_file "$DEEP_DIR")"
for pid in $DEEP_KIDS; do assert gone "$pid"; done
assert alive "$DEEP_CLI"
assert alive "$DEEP_SUP"

# A job no environment claims belongs to the chat whose CLI it runs under — while that CLI is the
# one its record was written by. A chat killed without deregistering leaves its record, and macOS
# hands its pid to a stranger: that stranger's job is claimed by no chat and killed by nobody.
clear_registry
spawn_deep_tree
register_session chat-own "$DEEP_CLI"
OWN_DIR="$WORK/guard-own"
probes 2000 1024
assert guard_run "$OWN_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DEEP_KIDS"
assert grep -q "^KILLED .* chat=chat-own job_pgid=$DEEP_SUP " "$(log_file "$OWN_DIR")"
clear_registry
spawn_deep_tree
register_session chat-gone "$DEEP_CLI"
touch -t 202001010000 "$SESSIONS_DIR/$DEEP_CLI.json"
STALE_DIR="$WORK/guard-stale"
assert guard_run "$STALE_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DEEP_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$STALE_DIR")"
for pid in $DEEP_KIDS; do assert alive "$pid"; done
assert test ! -s "$BUS_LOG"

# A worker run is attributed to the chat that launched it (CLAUDE_LAUNCHER_SESSION), its supervisor
# and vendor CLI are protected through meta.json, and the run's own directory carries the record
# `worker-run report` prints. The launching chat is gone here, so nobody is posted to — the kill
# still happens: a closed chat's job is exactly what nothing else would ever stop.
clear_registry
spawn_deep_tree '' chat-boss
register_run claudeb-1-2-fat "$DEEP_SUP" "$DEEP_CLI"
RUN_DIR="$WORK/guard-run"
probes 2000 1024
assert guard_run "$RUN_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DEEP_KIDS"
assert grep -qE "^KILLED [0-9]{10} chat=chat-boss .* notified=none$" "$(log_file "$RUN_DIR")"
for pid in $DEEP_KIDS; do assert gone "$pid"; done
assert alive "$DEEP_CLI"
assert alive "$DEEP_SUP"
assert test ! -s "$BUS_LOG"
fat_record="$GUARD_ROOT/runs/claudeb-1-2-fat/memguard"
assert grep -qE '^MEMGUARD [0-9]{10} avail_mb=2000 tree_rss_mb=[0-9]+ agent=claudeb-1-2-fat root_pid='"$DEEP_CLI"' killed=[0-9]+,[0-9]+$' "$fat_record"
assert test "$(awk -F'tree_rss_mb=' '{ split($2, f, " "); print (f[1] > 1536) }' "$fat_record")" = 1
# Kept for the surfacing section below, which must read a record this guard actually wrote.
SURFACE_RUN="$WORK/surface-run"
mkdir -p "$SURFACE_RUN"
cp "$fat_record" "$SURFACE_RUN/memguard"

# A run from before cli_pid existed protects only its supervisor, so the CLI goes with the work.
clear_registry
spawn_deep_tree '' chat-boss
register_run claudeb-1-2-legacy "$DEEP_SUP"
LEGACY_DIR="$WORK/guard-legacy"
probes 2000 1024
assert guard_run "$LEGACY_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DEEP_KIDS"
for pid in $DEEP_KIDS; do assert gone "$pid"; done
assert gone "$DEEP_CLI"
assert alive "$DEEP_SUP"
assert grep -q "root_pid=$DEEP_SUP " "$GUARD_ROOT/runs/claudeb-1-2-legacy/memguard"

# A review-bench cell registers through its own pid- file, and its record names the bench run and
# the cell, so a panel of many cells says WHICH one was cut.
clear_registry
spawn_tree chat-bench
CELL_ROOT=$TREE_ROOT CELL_KIDS=$TREE_KIDS
register_cell 20260905T101010Z-abc123 claudeb-opus-high "$CELL_ROOT"
CELL_DIR="$WORK/guard-cell"
probes 2000 1024
assert guard_run "$CELL_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$CELL_KIDS"
for pid in $CELL_KIDS; do assert gone "$pid"; done
assert alive "$CELL_ROOT"
assert grep -q 'agent=20260905T101010Z-abc123/claudeb-opus-high ' \
  "$GUARD_ROOT/stats/benches/20260905T101010Z-abc123/memguard"

# A run that has ended protects nothing, whatever its meta.json still says: its exit_code is on disk
# and its pid belongs to whatever holds that number now.
clear_registry
spawn_tree chat-done
DONE_ROOT=$TREE_ROOT DONE_KIDS=$TREE_KIDS
register_run claudeb-1-2-done "$DONE_ROOT"
printf '0\n' >"$GUARD_ROOT/runs/claudeb-1-2-done/exit_code"
DONE_DIR="$WORK/guard-done"
probes 2000 1024
assert guard_run "$DONE_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DONE_KIDS"
for pid in $DONE_ROOT $DONE_KIDS; do assert gone "$pid"; done
assert test ! -e "$GUARD_ROOT/runs/claudeb-1-2-done/memguard"

# A failed availability probe is unknown, not zero, so a broken vm_stat never kills anything.
clear_registry
spawn_tree chat-blind
BLIND_ROOT=$TREE_ROOT BLIND_KIDS=$TREE_KIDS
BLIND_DIR="$WORK/guard-blind"
probes fail 1024
assert guard_run "$BLIND_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$BLIND_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$BLIND_DIR")"
for pid in $BLIND_ROOT $BLIND_KIDS; do assert alive "$pid"; done

# Only the FATTEST job is cut, even when a second one is also over the ceiling: a job left
# standing beside the one that was is the difference between a guard and a cull.
clear_registry
spawn_tree chat-pick
BIG_ROOT=$TREE_ROOT BIG_KIDS=$TREE_KIDS
spawn_tree chat-pick
SMALL_ROOT=$TREE_ROOT SMALL_KIDS=$TREE_KIDS
PICK_DIR="$WORK/guard-pick"
small_weights=$(printf '%s=800000 ' $SMALL_KIDS)
probes 2000 1024
assert guard_run "$PICK_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$BIG_KIDS $small_weights"
assert grep -q "^KILLED .* job_pgid=$BIG_ROOT " "$(log_file "$PICK_DIR")"
assert test "$(grep -c '^KILLED ' "$(log_file "$PICK_DIR")")" = 1
for pid in $BIG_ROOT $BIG_KIDS; do assert gone "$pid"; done
for pid in $SMALL_ROOT $SMALL_KIDS; do assert alive "$pid"; done

# What no chat launched is never a candidate, however fat — Egor's apps and shells carry no session
# variable and no chat is their ancestor — and it does not shield the chat job behind it either.
clear_registry
spawn_tree
MINE_ROOT=$TREE_ROOT MINE_KIDS=$TREE_KIDS
spawn_tree chat-next
NEXT_ROOT=$TREE_ROOT NEXT_KIDS=$TREE_KIDS
MINE_DIR="$WORK/guard-mine"
mine_weights=$(printf '%s=2097152 ' $MINE_KIDS)
probes 2000 1024
assert guard_run "$MINE_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$mine_weights $NEXT_KIDS"
assert grep -q "^KILLED .* chat=chat-next job_pgid=$NEXT_ROOT " "$(log_file "$MINE_DIR")"
for pid in $NEXT_ROOT $NEXT_KIDS; do assert gone "$pid"; done
for pid in $MINE_ROOT $MINE_KIDS; do assert alive "$pid"; done
assert test "$(jq -c '[.rows[] | objects | select(.session) | .session]' "$(chats_json "$MINE_DIR")")" = '["chat-next"]'

# A chat's CLI fat on its own is never convicted for memory no kill of its work could free.
clear_registry
spawn_leaf
register_session chat-head "$LEAF_ROOT"
HEAD_CLI=$LEAF_ROOT
spawn_tree chat-head
HEAD_ROOT=$TREE_ROOT HEAD_KIDS=$TREE_KIDS
HEAD_DIR="$WORK/guard-fathead"
probes 2000 1024
assert guard_run "$HEAD_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$HEAD_CLI=4194304"
assert_fails grep -q '^KILLED ' "$(log_file "$HEAD_DIR")"
for pid in $HEAD_CLI $HEAD_ROOT $HEAD_KIDS; do assert alive "$pid"; done

# A worker's job belongs to the chat that launched the worker, and both hear of the kill: the
# launching chat, whose row Egor reads, and the worker, whose command it was.
clear_registry
spawn_leaf
register_session chat-lead "$LEAF_ROOT"
spawn_tree chat-worker chat-lead
register_session chat-worker "$TREE_ROOT"
LEAD_ROOT=$TREE_ROOT LEAD_KIDS=$TREE_KIDS
LEAD_DIR="$WORK/guard-lead"
probes 2000 1024
assert guard_run "$LEAD_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$LEAD_KIDS"
assert grep -qE "^KILLED [0-9]{10} chat=chat-lead job_pgid=$LEAD_ROOT .* notified=chat-lead,chat-worker$" "$(log_file "$LEAD_DIR")"
for pid in $LEAD_KIDS; do assert gone "$pid"; done
assert alive "$LEAD_ROOT"
assert test "$(grep -c -- '--session chat-lead alive=' "$BUS_LOG")" = 1
assert test "$(grep -c -- '--session chat-worker alive=' "$BUS_LOG")" = 1
assert test "$(jq '[.rows[] | objects | select(.session)] | length' "$(chats_json "$LEAD_DIR")")" = 1

# Both notices are in flight at once, each still posted while the job is alive: a slow bus costs
# the relief one post's wait, not one per chat told.
clear_registry
spawn_leaf
register_session chat-lead "$LEAF_ROOT"
spawn_tree chat-worker chat-lead
register_session chat-worker "$TREE_ROOT"
PAIR_KIDS=$TREE_KIDS
PAIR_DIR="$WORK/guard-pair"
PAIR_PEERS="$WORK/bus-peers"
mkdir -p "$PAIR_PEERS"
: >"$BUS_LOG"
probes 2000 1024
assert guard_run "$PAIR_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$PAIR_KIDS" BUS_WATCH="$PAIR_KIDS" \
  BUS_PEERS="$PAIR_PEERS" BUS_PEERS_WANT=2
assert grep -qE "^KILLED .* notified=chat-lead,chat-worker$" "$(log_file "$PAIR_DIR")"
assert test "$(grep -c -- '--session chat-[a-z]* peers=2$' "$PAIR_PEERS.log")" = 2
assert test "$(grep -cE -- '--session chat-(lead|worker) alive=2 ' "$BUS_LOG")" = 2
for pid in $PAIR_KIDS; do assert gone "$pid"; done

# The menu snapshot: one aligned row per chat, the title shortened to its column with a trailing
# phase number kept, state words for live chats, and every number carrying its unit.
clear_registry
spawn_leaf
register_session chat-long "$LEAF_ROOT" busy
LONG_CLI=$LEAF_ROOT
retitle chat-long 'Vector Magic macOS ARM migration phase 4'
spawn_leaf
register_session chat-calm "$LEAF_ROOT" idle
spawn_leaf
register_session chat-anon "$LEAF_ROOT" idle
retitle chat-anon ''
MENU_DIR="$WORK/guard-menu"
probes 8192 1024
assert guard_run "$MENU_DIR" MEMLOGD_MAX_TICKS=2 MEMLOGD_QUIET_INTERVAL=1 HEAVY_PIDS="$LONG_CLI=1048576"
menu=$(chats_json "$MENU_DIR")
assert jq -e '.title | test("^Chats/other  [0-9.]+/[0-9.]+ cores · [0-9]+/[0-9]+ GB$")' "$menu"
assert jq -e '.rows[0].text | test("^CPU +[0-9.]+ chats \\+ +[0-9.]+ other = +[0-9.]+ of [0-9]+ cores$")' "$menu"
assert jq -e '.rows[1].text | test("^RAM +[0-9.]+ chats \\+ +[0-9.]+ other = +[0-9.]+ of [0-9]+ GB · swap 1.0$")' "$menu"
assert test "$(jq -r '.rows[] | objects | select(.session == "chat-long") | .text[0:34]' "$menu")" = 'wait model  Vector Magic… phase 4 '
assert jq -e '.rows[] | objects | select(.session == "chat-long") | .text | test("  1.0 GB  ")' "$menu"
# A live chat's row carries its CLI pid: the menu finds the Terminal tab to raise through it.
assert test "$(jq -r '.rows[] | objects | select(.session == "chat-long") | .pid' "$menu")" = "$LONG_CLI"
assert jq -e '.rows[] | objects | select(.session == "chat-calm") | (.text | startswith("idle        Chat chat-calm")) and .dim' "$menu"
# Every column starts at the same code point on every chat row, the one with the ellipsis included.
columns() { python3 -c 'import json, sys
rows = [r["text"] for r in json.load(open(sys.argv[1]))["rows"] if isinstance(r, dict) and r.get("session")]
print(len(rows), len({(t.index(" cores  "), t.index(" GB  ")) for t in rows}))' "$1"; }
assert test "$(columns "$menu")" = '3 1'
# An untitled chat is never shown by its id and takes no neighbour's title.
assert jq -e '.rows[] | objects | select(.session == "chat-anon") | .text | startswith("idle        untitled chat · demo")' "$menu"
assert jq -e '[.rows[] | objects | .text | contains("chat-ano")] | any | not' "$menu"
assert jq -e '.rows[-1].text | test("^Other incl\\.: screen [0-9.]+ · kernel [0-9.]+ · signing [0-9.]+ cores$")' "$menu"
assert test "$(jq -r .alarm "$menu")" = false
assert test "$(jq -r .error "$menu")" = ''

# A limiter hold rides on the row of the chat whose process waits, as ⏳<jobs> <longest>; one no chat
# launched gets its own `queued` row; a queue no job left for QUEUE_STUCK_S turns its row and the title red.
clear_registry
spawn_leaf
register_session chat-held "$LEAF_ROOT" busy
HELD_CLI=$LEAF_ROOT
spawn_tree
LOOSE_ROOT=$TREE_ROOT
HELD_DIR="$WORK/guard-held" HOLDS="$WORK/held-holds"
mkdir -p "$HELD_DIR" "$HOLDS"
held_at=$(date +%s)
hold_json() { # limiter pid
  jq -n --arg l "$1" --argjson pid "$2" --argjson since "$held_at" \
    '{limiter: $l, pid: $pid, held: {what: "job"}, since: $since, why: "busy", until: null}' >"$HOLDS/$1-$2.json"
}
hold_json bench "$HELD_CLI"
hold_json run-suites "$LOOSE_ROOT"
jq -n --arg f "bench-$HELD_CLI.json" --argjson moved $((held_at - 2000)) '{queues: {bench: {files: [$f], moved: $moved}}}' \
  >"$HELD_DIR/chat-load.state.json"
probes 8192 1024
assert guard_run "$HELD_DIR" MEMLOGD_MAX_TICKS=1 HARNESS_HOLDS_DIR="$HOLDS"
menu=$(chats_json "$HELD_DIR")
assert jq -e '.rows[] | objects | select(.session == "chat-held") | (.text | test("  ⏳1 [0-9]+m$")) and .alarm and (.dim | not)' "$menu"
assert jq -e '[.rows[] | objects | select(.text | startswith("queued      run-suites")) | select((.text | test("  ⏳1 [0-9]+m$")) and .dim and (.alarm | not))] | length == 1' "$menu"
assert test "$(jq -c '[.queues[] | [.limiter, .count, .stuck, (.session != null)]]' "$menu")" = '[["bench",1,true,true],["run-suites",1,false,false]]'
assert test "$(jq -r .alarm "$menu")" = true
assert jq -e '.queues[0].text | test("^Chat chat-held: 1 job queued, none started for 3[0-9]m$")' "$menu"

# A notice that did not land says so on the kill row.
clear_registry
spawn_leaf
register_session chat-untold "$LEAF_ROOT"
spawn_tree chat-untold
UNTOLD_KIDS=$TREE_KIDS
UNTOLD_DIR="$WORK/guard-untold"
probes 2000 1024
assert guard_run "$UNTOLD_DIR" MEMLOGD_MAX_TICKS=1 BUS_FAIL=1 HEAVY_PIDS="$UNTOLD_KIDS"
assert grep -qE '^KILLED .* chat=chat-untold .* notified=none$' "$(log_file "$UNTOLD_DIR")"
assert jq -e '.rows[] | objects | select(.alarm) | .text | endswith(" · chat not told")' "$(chats_json "$UNTOLD_DIR")"

# A post still waiting on the queue lock past the guard's deadline is left to land, never killed:
# killed, its notice was gone without even a lost.log line.
clear_registry
spawn_leaf
register_session chat-slow "$LEAF_ROOT"
spawn_tree chat-slow
SLOW_DIR="$WORK/guard-slow"
: >"$BUS_LOG"
probes 2000 1024
assert guard_run "$SLOW_DIR" MEMLOGD_MAX_TICKS=1 BUS_SLOW=5 HEAVY_PIDS="$TREE_KIDS"
assert grep -qE '^KILLED .* chat=chat-slow .* notified=none$' "$(log_file "$SLOW_DIR")"
for _ in $(seq 1 100); do grep -q -- '--session chat-slow ' "$BUS_LOG" && break; sleep 0.1; done
assert grep -qE -- '^post --kind notice --id memguard-[0-9]{10}-[0-9]+ --session chat-slow ' "$BUS_LOG"

# A member this user cannot signal (a root child under sudo) is no part of a job: weighed in, its
# chat would get a notice every tick for a kill that always fails with EPERM.
clear_registry
spawn_leaf
register_session chat-rooted "$LEAF_ROOT"
spawn_tree chat-rooted
ROOTED_ROOT=$TREE_ROOT ROOTED_KIDS=$TREE_KIDS
ROOTED_DIR="$WORK/guard-rooted"
probes 2000 1024
assert guard_run "$ROOTED_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$ROOTED_KIDS" FOREIGN_PIDS="$ROOTED_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$ROOTED_DIR")"
assert test ! -s "$BUS_LOG"
for pid in $ROOTED_ROOT $ROOTED_KIDS; do assert alive "$pid"; done

# A job already SIGKILLed that has not finished dying under swap is not killed and announced again.
clear_registry
spawn_leaf
register_session chat-dying "$LEAF_ROOT"
spawn_tree chat-dying
DYING_KIDS=$TREE_KIDS
DYING_DIR="$WORK/guard-dying"
mkdir -p "$DYING_DIR"
jq -n --argjson at "$(date +%s)" --argjson kids "[${DYING_KIDS// /,}]" \
  '{guard: {at: $at, session: "chat-dying", mb: 1800, title: "", told: true, killed: $kids}}' \
  >"$DYING_DIR/chat-load.state.json"
probes 2000 1024
assert guard_run "$DYING_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DYING_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$DYING_DIR")"
assert test ! -s "$BUS_LOG"
for pid in $DYING_KIDS; do assert alive "$pid"; done

# What a job forks into its group while the notice is in flight goes with it (make -j, xargs -P).
clear_registry
spawn_leaf
register_session chat-fork "$LEAF_ROOT"
spawn_tree chat-fork
FORK_ROOT=$TREE_ROOT FORK_KIDS=$TREE_KIDS
FORK_DIR="$WORK/guard-fork"
rm -f "$WORK/joined.pid"
probes 2000 1024
assert guard_run "$FORK_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$FORK_KIDS" BUS_JOIN="$FORK_ROOT" BUS_JOINED="$WORK/joined.pid"
read -r FORK_LATE <"$WORK/joined.pid"
TREE_PIDS+=("$FORK_LATE")
assert grep -qE '^KILLED .* chat=chat-fork job_pgid='"$FORK_ROOT"' ' "$(log_file "$FORK_DIR")"
for pid in $FORK_ROOT $FORK_KIDS $FORK_LATE; do assert gone "$pid"; done

# exec keeps a pid and its start: an empty environment read off a shell before it exec'd python is
# read again once the command changed, or the python would belong to no chat.
clear_registry
spawn_tree chat-exec
EXEC_KIDS=$TREE_KIDS
EXEC_DIR="$WORK/guard-exec"
probes 8192 1024
assert guard_run "$EXEC_DIR" MEMLOGD_MAX_TICKS=1
jq '.env |= map_values([.[0], "", "", "bash"])' "$EXEC_DIR/chat-load.state.json" >"$WORK/exec-state.json"
mv "$WORK/exec-state.json" "$EXEC_DIR/chat-load.state.json"
probes 2000 1024
assert guard_run "$EXEC_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$EXEC_KIDS"
assert grep -qE '^KILLED .* chat=chat-exec ' "$(log_file "$EXEC_DIR")"

# Process starts are reckoned from when ps ran: memlogd's `now` lags it by seconds that swing under
# pressure, and a start shifted by that swing misses the env and CPU caches for every process.
clear_registry
spawn_tree chat-skew
SKEW_DIR="$WORK/guard-skew"
mkdir -p "$SKEW_DIR"
chat_load_sample() { # log-dir now
  env MEMLOGD_DIR="$1" WORKER_RUN_DIR="$GUARD_ROOT/runs" WORKER_STATS_DIR="$GUARD_ROOT/stats" \
    CHAT_LOAD_SESSIONS="$SESSIONS_DIR" CHAT_NAME_ROOTS="$WORK/transcripts" CHAT_NAMES_CACHE="$WORK/chat-names.json" \
    CHAT_LOAD_REPORT_BUS="$FAKE_BIN/report-bus" HARNESS_HOLDS_DIR="$EMPTY_REGISTRY/holds" GUARD_SCOPE="$GUARD_SCOPE" \
    python3 "$ROOT/bin/chat-load" sample --now "$2" --avail 8192 --swap 0
}
assert chat_load_sample "$SKEW_DIR" "$(date +%s)"
cp "$SKEW_DIR/chat-load.state.json" "$WORK/skew-before.json"
assert chat_load_sample "$SKEW_DIR" "$(($(date +%s) - 5))"
assert jq -e --slurpfile a "$WORK/skew-before.json" '
  def apart(x; y): (x - y) | if . < 0 then -. else . end;
  (.env | length) == 3 and ([.env | to_entries[] | apart(.value[0]; $a[0].env[.key][0]) <= 2] | all)
  and ([.procs | to_entries[] | apart(.value[0]; $a[0].procs[.key][0]) <= 2] | all)' "$SKEW_DIR/chat-load.state.json"

# --- MEMGUARD surfacing in worker-run report/wait -------------------------------------------------
# The record is written by this daemon and read by worker-run, so the two ends are checked against
# one another here rather than each against its own idea of the format.
WORKER_RUN="$ROOT/bin/worker-run"
assert test -s "$SURFACE_RUN/memguard"
surface=$(sed -n '/^memguard_lines() {/,/^}/p' "$WORKER_RUN")
assert test -n "$surface"
printf '%s\nmemguard_lines "%s"\n' "$surface" "$SURFACE_RUN" >"$WORK/surface.sh"
surface_out=$(bash "$WORK/surface.sh")
assert grep -qE '^MEMGUARD: [0-9]+ descendants? SIGKILLed under memory pressure \(avail 2000 MB, tree [0-9]+ MB\); the run'"'"'s own root was spared$' \
  <<<"$surface_out"
assert test "$(wc -l <<<"$surface_out" | tr -d ' ')" = 1
# A run the guard never touched says nothing at all: an empty or absent record is not a kill.
quiet_run="$WORK/surface-quiet-run"
mkdir -p "$quiet_run"
printf '%s\nmemguard_lines "%s"\n' "$surface" "$quiet_run" >"$WORK/surface-quiet.sh"
assert test -z "$(bash "$WORK/surface-quiet.sh")"
# And every shape `report`/`wait` can print carries the line, the RUNNING one included: a run can be
# cut while it is still going, and the cause must not wait for an exit code a torn run may never write.
for shape in terminal_report unknown_report running_report; do
  assert grep -q "memguard_lines" <(sed -n "/^$shape() {/,/^}/p" "$WORKER_RUN")
done
assert test "$(grep -c 'memguard_lines "\$directory"' "$WORKER_RUN")" -eq 5
# The guard's own thresholds are stated once, in chat-load, and the decision record quotes them;
# install-agent deploys chat-load beside the daemon copy launchd runs, which is where it is looked up.
assert grep -q '^GUARD_AVAIL_MB = 3072$' "$ROOT/bin/chat-load"
assert grep -q '^GUARD_JOB_MB = 1536$' "$ROOT/bin/chat-load"
assert grep -qF 'chat_load="$(dirname "$script_path")/chat-load"' "$SCRIPT"
# So are the resolver and the bus it runs: macOS denies the daemon's Python /Volumes/Work.
assert grep -qF 'for source in bin/chat-load share/chat_names.py bin/report-bus share/report_frame.py; do' "$SCRIPT"
assert grep -qF 'mv -f "$deployed_tmp" "$(dirname "$wrapper")/${source##*/}"' "$SCRIPT"
assert grep -q '3072' "$ROOT/docs/memory-guard.md"
assert grep -q '1536' "$ROOT/docs/memory-guard.md"
# The agent process env is scoped to the run's own tree and set nowhere wider.
assert grep -q 'export NX_PARALLEL=1 NX_DAEMON=false' "$WORKER_RUN"

# A Background agent gets no CPU once a runaway fan-out saturates the cores — on 2026-09-28 memlogd
# went silent 13 s before swap started and never woke to log or guard the freeze.
assert plutil -lint "$ROOT/launchd/com.egor.memlogd.plist"
assert test "$(plutil -extract ProcessType raw "$ROOT/launchd/com.egor.memlogd.plist")" = Interactive

reap_trees

echo "PASS: $asserts asserts; quiet line format and node roll-up, a failed vm_stat probe that never fakes pressure, durable writes that fsync the day log and frames file and never call sync(2), incident entry on available RAM alone with a marker naming its frames file and full pid/ppid/pgid/rss/etime blocks in frames/ not the day file, swap reported everywhere but deciding neither entry nor exit (drowning swap with healthy RAM stays quiet, recovery lands with swap unmoved), a probe that breaks mid-incident never latching it, recovery hysteresis both ways (held open under the window, closed and back to quiet once met), an incident spanning midnight marking the new day's file with frames continuing in the episode file, three-day rotation that spares neither an INCIDENT day nor a non-log file nor today's log and honours the retention knob including old frames, rotation sparing the frames file a live episode is still writing even when its name predates the window, a frames-directory budget that evicts the oldest file first and never the current episode, survives a name with a space and a file that vanished under the listing, an episode cap that stops the frames and says EPISODE-CAP once while the summaries keep coming, fast-then-slow incident frame cadence, a quiet-state jump that writes one frame headed jump and a JUMP marker without opening an incident, stays quiet below both thresholds and treats a failed ps probe as -1 rather than a rise on the next healthy tick, a LaunchAgent scheduled Interactive so it keeps running under a saturated CPU, and a single-instance lock that refuses a live holder, refuses one that has written no pid yet, and takes over a dead one; plus the memory guard on real process groups — neither low RAM nor a fat job convicting alone, a chat's own Bash job killed whole with its CLI left standing and the chat notified while the job was still alive, a registered CLI and its ancestors protected inside one group, a worker run attributed to its launching chat with supervisor and CLI protected and the run's memguard record written, a legacy run protecting its supervisor only, a bench cell's record naming bench and cell, an ended run protecting nothing, a failed probe never convicting, only the fattest job cut, nothing no chat launched ever a candidate, a fat CLI never convicted on its own weight, a worker's job billed to the launching chat with both sessions notified (both notices in flight at once, each before the kill), the menu snapshot's aligned one-line rows, shortened titles, state words and units, an untitled chat never taking a neighbour's title, a macOS denial of /Volumes/Work and an undelivered notice each shown as such, and the MEMGUARD: line the run report renders from the record in every shape"
