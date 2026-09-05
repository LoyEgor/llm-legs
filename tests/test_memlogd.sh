#!/usr/bin/env bash
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
EOF

cat >"$FAKE_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
set -u
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
  *pid=,ppid=,rss=*)
    # The memory-guard cases register REAL process trees and check that real descendants really
    # died, so ancestry and pids come from the real ps: a fixture table cannot be killed. Only the
    # WEIGHT is dictated, for the pids a case names — allocating 1.5 GB for real in a suite is not a
    # test of the guard, it is the bug the guard is for.
    /bin/ps -axo pid=,ppid=,rss=,state= | awk -v fat="${HEAVY_PIDS:-}" '
      BEGIN {
        n = split(fat, list, " ")
        # `pid` weighs the default; `pid=KB` weighs exactly that, for a case needing two weights.
        for (i = 1; i <= n; i++) heavy[list[i] + 0] = (split(list[i], part, "=") == 2) ? part[2] + 0 : 900000
      }
      { if (($1 + 0) in heavy) $3 = heavy[$1 + 0]; print $1, $2, $3, $4 }'
    ;;
  *pid=,etime=*)
    # The identity check reads real elapsed times: a fixture etime would make every registered pid
    # verifiable by construction, which is the very thing being tested.
    /bin/ps -axo pid=,etime=
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
chmod +x "$FAKE_BIN/vm_stat" "$FAKE_BIN/sysctl" "$FAKE_BIN/ps" "$FAKE_BIN/date" "$FAKE_BIN/stat"
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
# The two registry roots are pinned to empty fixtures for EVERY case, not only the guard's own: the
# memory guard reads them on any tick under its availability floor, and left at their defaults a
# low-availability fixture would aim real SIGKILLs at whatever workers Egor has running. A case that
# wants a registry passes its own WORKER_RUN_DIR/WORKER_STATS_DIR, which land after these and win.
EMPTY_REGISTRY="$WORK/empty-registry"
mkdir -p "$EMPTY_REGISTRY/runs" "$EMPTY_REGISTRY/stats"
run_memlogd() {
  local dir="$1"; shift
  run_day=$(date +%F)
  env MEMLOGD_DIR="$dir" MEMLOGD_SYNC=0 MEMLOGD_QUIET_INTERVAL=0 MEMLOGD_INCIDENT_INTERVAL=0 \
    WORKER_RUN_DIR="$EMPTY_REGISTRY/runs" WORKER_STATS_DIR="$EMPTY_REGISTRY/stats" \
    "$@" bash "$SCRIPT" run
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
# Today's file is the one the incident evidence is read from, whatever it holds.
printf 'INCIDENT 1700000000 avail_mb=100 swap_used_mb=7000\n' >"$ROTATE_DIR/$(date +%F).log"
probes 8192 1024
assert run_memlogd "$ROTATE_DIR" MEMLOGD_MAX_TICKS=1
assert_fails test -e "$ROTATE_DIR/2000-01-01.log"
assert_fails test -e "$ROTATE_DIR/2000-01-02.log"
assert test -f "$ROTATE_DIR/$inside_edge.log"
assert_fails test -e "$ROTATE_DIR/$outside_edge.log"
assert test -f "$ROTATE_DIR/notes.txt"
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

# --- the memory guard --------------------------------------------------------------------------
# Every case here registers a REAL process tree and asserts against real signals: a fixture process
# table cannot be killed, and the whole point of the rule is which processes are still alive after.
GUARD_ROOT="$WORK/guard"
mkdir -p "$GUARD_ROOT/runs" "$GUARD_ROOT/stats/benches" "$GUARD_ROOT/stats/pool-runs"

# A root that outlives its children, holding two descendants that sleep until something kills them.
# The root is a bash that waits, so it is the tree's root by ancestry and never exits on its own.
TREE_PIDS=()
spawn_tree() { # -> sets TREE_ROOT / TREE_KIDS
  local report="$WORK/tree-$RANDOM.pids" hold="$WORK/hold-$RANDOM.fifo"
  rm -f "$report" "$hold"
  mkfifo "$hold"
  bash -c '
    sleep 300 & first=$!
    sleep 300 & second=$!
    printf "%s %s %s\n" "$$" "$first" "$second" >"$1"
    # Held open read-write, never `wait`: a root that waits on its children exits the instant the
    # guard kills them, and no assertion could tell that from a guard that killed the root too.
    exec 3<>"$2"
    read -r -t 300 -u 3 _ || :
  ' _ "$report" "$hold" 2>/dev/null &
  TREE_ROOT=$!
  local waited=0
  while [ ! -s "$report" ] && [ "$waited" -lt 200 ]; do sleep 0.05; waited=$((waited + 1)); done
  read -r _ first second <"$report"
  TREE_KIDS="$first $second"
  TREE_PIDS+=("$TREE_ROOT" "$first" "$second")
  rm -f "$report" "$hold"
}
reap_trees() { local pid; for pid in ${TREE_PIDS[@]+"${TREE_PIDS[@]}"}; do kill -KILL "$pid" 2>/dev/null || :; done; }

# A root with no descendants at all, for the candidate rule: only descendants are ever killed.
spawn_leaf() { # -> sets LEAF_ROOT
  sleep 300 &
  LEAF_ROOT=$!
  TREE_PIDS+=("$LEAF_ROOT")
}

# The real shape of a worker run: a supervisor holding a vendor CLI which holds the work. Three
# levels, because the whole cli_pid question is which of the top two the kill is rooted at.
cat >"$WORK/deep-tree.sh" <<'DEEP'
report=$1 hold=$2 supervisor=${3:-}
if [ -z "$supervisor" ]; then
  bash "$0" "$report" "$hold" "$$" &
else
  sleep 300 & first=$!
  sleep 300 & second=$!
  printf '%s %s %s %s\n' "$supervisor" "$$" "$first" "$second" >"$report"
fi
exec 3<>"$hold"
read -r -t 300 -u 3 _ || :
DEEP
spawn_deep_tree() { # -> sets DEEP_SUP / DEEP_CLI / DEEP_KIDS
  local report="$WORK/deep-$RANDOM.pids" hold="$WORK/deep-$RANDOM.fifo" waited=0 first second
  rm -f "$report" "$hold"
  mkfifo "$hold"
  bash "$WORK/deep-tree.sh" "$report" "$hold" 2>/dev/null &
  while [ ! -s "$report" ] && [ "$waited" -lt 200 ]; do sleep 0.05; waited=$((waited + 1)); done
  read -r DEEP_SUP DEEP_CLI first second <"$report"
  DEEP_KIDS="$first $second"
  TREE_PIDS+=("$DEEP_SUP" "$DEEP_CLI" "$first" "$second")
  rm -f "$report" "$hold"
}
trap 'reap_trees; rm -rf "$WORK"' EXIT

# A zombie is dead, and `kill -0` succeeds on one: these fixture roots deliberately do not reap
# (they must outlive their children), so liveness asked with a signal would call every SIGKILLed
# descendant alive forever. The real ps, since the fake one answers only the forms the daemon asks.
alive() {
  local state
  state=$(/bin/ps -o state= -p "$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$state" ] || return 1
  case "$state" in Z*) return 1 ;; esac
  return 0
}
# The kill lands before the process leaves the table, so this is asked a few times.
gone() {
  local waited=0
  while alive "$1" && [ "$waited" -lt 100 ]; do sleep 0.05; waited=$((waited + 1)); done
  ! alive "$1"
}

# Written through jq exactly as worker-run writes it (`"pid": N`, a space after the colon), so the
# guard's reader is tested against the real shape and never a hand-typed one.
# The stamps are real launch instants, because the guard now checks them against the process's own
# start: a fixture stamp frozen in the past would register a tree the daemon is right to refuse.
register_run() { # run-id supervisor-pid [cli-pid] [started-at]
  local began=${4:-$(date +%s)}
  mkdir -p "$GUARD_ROOT/runs/$1"
  jq -n --argjson pid "$2" --arg cli "${3:-}" --argjson began "$began" \
    '{vendor: "claudeb", account: "main", pid: $pid, pid_started_at: $began, workdir: "/tmp"}
     + if $cli == "" then {} else {cli_pid: ($cli | tonumber), cli_pid_started_at: $began} end' \
    >"$GUARD_ROOT/runs/$1/meta.json"
}

register_cell() { # bench-run-id cell-artifact root-pid
  mkdir -p "$GUARD_ROOT/stats/benches/$1"
  printf '%s\n' "$3" >"$GUARD_ROOT/stats/benches/$1/pid-$2"
}

clear_registry() { rm -rf "$GUARD_ROOT/runs" "$GUARD_ROOT/stats"; mkdir -p "$GUARD_ROOT/runs" "$GUARD_ROOT/stats"; }

guard_run() { # log-dir extra-env...
  local dir="$1"; shift
  run_memlogd "$dir" WORKER_RUN_DIR="$GUARD_ROOT/runs" WORKER_STATS_DIR="$GUARD_ROOT/stats" "$@"
}

# Healthy RAM and a registered tree: the availability half is unmet, so nothing is touched however
# the tree measures. Availability alone can never convict.
clear_registry
spawn_tree
ROOMY_ROOT=$TREE_ROOT ROOMY_KIDS=$TREE_KIDS
register_run claudeb-1-2-roomy "$ROOMY_ROOT"
ROOMY_DIR="$WORK/guard-roomy"
probes 8192 1024
assert guard_run "$ROOMY_DIR" MEMLOGD_MAX_TICKS=1
assert_fails grep -q '^KILLED ' "$(log_file "$ROOMY_DIR")"
assert_fails test -e "$GUARD_ROOT/runs/claudeb-1-2-roomy/memguard"
for pid in $ROOMY_KIDS; do assert alive "$pid"; done
assert alive "$ROOMY_ROOT"

# Low RAM but no tree over the ceiling: three sleeping shells weigh a few MB between them, so the
# fattest-tree half is unmet and the guard stays its hand. The tree half alone cannot convict either.
clear_registry
spawn_tree
THIN_ROOT=$TREE_ROOT THIN_KIDS=$TREE_KIDS
register_run claudeb-1-2-thin "$THIN_ROOT"
THIN_DIR="$WORK/guard-thin"
probes 2000 1024
assert guard_run "$THIN_DIR" MEMLOGD_MAX_TICKS=1
assert_fails grep -q '^KILLED ' "$(log_file "$THIN_DIR")"
assert_fails test -e "$GUARD_ROOT/runs/claudeb-1-2-thin/memguard"
for pid in $THIN_KIDS; do assert alive "$pid"; done
assert alive "$THIN_ROOT"

# Both halves met: HEAVY_PIDS makes this very tree's real descendants weigh ~879 MB apiece, so the
# ancestry, the kills and the survivors are all real and only the weight is dictated.
clear_registry
spawn_tree
FAT_ROOT=$TREE_ROOT FAT_KIDS=$TREE_KIDS
register_run claudeb-1-2-fat "$FAT_ROOT"
FAT_DIR="$WORK/guard-fat"
probes 2000 1024
assert guard_run "$FAT_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$FAT_KIDS"
fat_log=$(log_file "$FAT_DIR")
# The KILLED line names the agent, both readings and the root it did NOT kill.
assert grep -qE '^KILLED [0-9]{10} agent=claudeb-1-2-fat avail_mb=2000 tree_rss_mb=[0-9]+ root_pid='"$FAT_ROOT"' killed=[0-9]+(,[0-9]+)?$' "$fat_log"
# Descendants die; the root of the tree is spared, which is what leaves the run able to report.
for pid in $FAT_KIDS; do assert gone "$pid"; done
assert alive "$FAT_ROOT"
# And the run's own directory carries the record, with every field a reader needs.
fat_record="$GUARD_ROOT/runs/claudeb-1-2-fat/memguard"
assert test -s "$fat_record"
assert grep -qE '^MEMGUARD [0-9]{10} avail_mb=2000 tree_rss_mb=[0-9]+ agent=claudeb-1-2-fat root_pid='"$FAT_ROOT"' killed=[0-9]+(,[0-9]+)?$' "$fat_record"
assert test "$(awk -F'tree_rss_mb=' '{ split($2, f, " "); print (f[1] > 1536) }' "$fat_record")" = 1
# Kept for the surfacing section below, which must read a record this daemon actually wrote rather
# than one the suite composed to match its own expectations.
SURFACE_RUN="$WORK/surface-run"
mkdir -p "$SURFACE_RUN"
cp "$fat_record" "$SURFACE_RUN/memguard"

# A review-bench cell registers the same way through its own pid- file, and its agent id names the
# bench run and the cell, so a panel of many cells says WHICH one was cut.
clear_registry
spawn_tree
CELL_ROOT=$TREE_ROOT CELL_KIDS=$TREE_KIDS
register_cell 20260905T101010Z-abc123 claudeb-opus-high "$CELL_ROOT"
CELL_DIR="$WORK/guard-cell"
probes 2000 1024
assert guard_run "$CELL_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$CELL_KIDS"
assert grep -q '^KILLED .* agent=20260905T101010Z-abc123/claudeb-opus-high ' "$(log_file "$CELL_DIR")"
for pid in $CELL_KIDS; do assert gone "$pid"; done
assert alive "$CELL_ROOT"
assert grep -q 'agent=20260905T101010Z-abc123/claudeb-opus-high ' \
  "$GUARD_ROOT/stats/benches/20260905T101010Z-abc123/memguard"

# A run that has already ended is not a candidate, whatever its meta.json still says: its exit_code
# is on disk, and its pid belongs to whatever holds that number now.
clear_registry
spawn_tree
DONE_ROOT=$TREE_ROOT DONE_KIDS=$TREE_KIDS
register_run claudeb-1-2-done "$DONE_ROOT"
printf '0\n' >"$GUARD_ROOT/runs/claudeb-1-2-done/exit_code"
DONE_DIR="$WORK/guard-done"
probes 2000 1024
assert guard_run "$DONE_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DONE_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$DONE_DIR")"
for pid in $DONE_KIDS; do assert alive "$pid"; done

# A failed availability probe is unknown, not zero — the same rule pressure() applies, so a broken
# vm_stat can never be the reason an agent's children are killed.
clear_registry
spawn_tree
BLIND_ROOT=$TREE_ROOT BLIND_KIDS=$TREE_KIDS
register_run claudeb-1-2-blind "$BLIND_ROOT"
BLIND_DIR="$WORK/guard-blind"
probes fail 1024
assert guard_run "$BLIND_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$BLIND_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$BLIND_DIR")"
for pid in $BLIND_KIDS; do assert alive "$pid"; done

# Only the FATTEST tree is cut. A second registered tree left standing beside the one that was is
# the whole difference between a guard and a cull.
clear_registry
spawn_tree
BIG_ROOT=$TREE_ROOT BIG_KIDS=$TREE_KIDS
spawn_tree
SMALL_ROOT=$TREE_ROOT SMALL_KIDS=$TREE_KIDS
register_run claudeb-1-2-big "$BIG_ROOT"
register_run claudeb-1-2-small "$SMALL_ROOT"
PICK_DIR="$WORK/guard-pick"
probes 2000 1024
assert guard_run "$PICK_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$BIG_KIDS"
assert grep -q '^KILLED .* agent=claudeb-1-2-big ' "$(log_file "$PICK_DIR")"
assert_fails grep -q 'agent=claudeb-1-2-small ' "$(log_file "$PICK_DIR")"
for pid in $BIG_KIDS; do assert gone "$pid"; done
assert alive "$BIG_ROOT"
for pid in $SMALL_KIDS; do assert alive "$pid"; done

# A run that recorded its vendor CLI is rooted THERE and not at its supervisor: the CLI's own
# children — the agent's commands, the hog among them — are what dies, and the agent lives to be
# told its command was killed by signal 9 (live 2026-09-05: rooted at the supervisor instead, the
# agent went with them and the run came back a bare exit 137).
clear_registry
spawn_deep_tree
register_run claudeb-1-2-cli "$DEEP_SUP" "$DEEP_CLI"
CLI_DIR="$WORK/guard-cli"
probes 2000 1024
assert guard_run "$CLI_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DEEP_KIDS"
assert grep -q "^KILLED .* root_pid=$DEEP_CLI " "$(log_file "$CLI_DIR")"
for pid in $DEEP_KIDS; do assert gone "$pid"; done
assert alive "$DEEP_CLI"
assert alive "$DEEP_SUP"

# A run from before cli_pid existed still has a root: the supervisor's pid, which is what its
# meta.json carries. Everything under it goes, the CLI included — the old behaviour, kept because a
# guard that skipped such runs would leave exactly the trees it was built to cut.
clear_registry
spawn_deep_tree
register_run claudeb-1-2-legacy "$DEEP_SUP"
LEGACY_DIR="$WORK/guard-legacy"
probes 2000 1024
assert guard_run "$LEGACY_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$DEEP_KIDS"
assert grep -q "^KILLED .* root_pid=$DEEP_SUP " "$(log_file "$LEGACY_DIR")"
for pid in $DEEP_KIDS; do assert gone "$pid"; done
assert gone "$DEEP_CLI"
assert alive "$DEEP_SUP"

# A registered pid is only a claim about a NUMBER, and macOS hands numbers out again within the day:
# a supervisor killed before it wrote exit_code leaves its registration standing until the 7-day
# prune. So the process wearing the number must have STARTED when the registration says it did —
# here it started minutes ago and the stamp says two hours, so the guard leaves the tree alone
# rather than SIGKILLing an unrelated process's children.
clear_registry
spawn_tree
STAMP_ROOT=$TREE_ROOT STAMP_KIDS=$TREE_KIDS
register_run claudeb-1-2-stamp "$STAMP_ROOT" '' $(( $(date +%s) - 7200 ))
STAMP_DIR="$WORK/guard-stamp"
probes 2000 1024
assert guard_run "$STAMP_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$STAMP_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$STAMP_DIR")"
for pid in $STAMP_KIDS; do assert alive "$pid"; done
# The same tree, the same pids, the stamp now telling the truth: this is what the check is FOR, so
# the accepting half is asserted against the very fixture the refusing half just spared.
register_run claudeb-1-2-stamp "$STAMP_ROOT" '' "$(date +%s)"
MATCH_DIR="$WORK/guard-stamp-match"
probes 2000 1024
assert guard_run "$MATCH_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$STAMP_KIDS"
assert grep -q "^KILLED .* root_pid=$STAMP_ROOT " "$(log_file "$MATCH_DIR")"
for pid in $STAMP_KIDS; do assert gone "$pid"; done
assert alive "$STAMP_ROOT"

# A record carrying no stamp at all cannot be checked, and unverifiable is SKIPPED: a run old enough
# to predate the stamps is prunable in days, and a kill on an identity nobody could confirm is not
# the trade this guard makes.
clear_registry
spawn_tree
NOSTAMP_ROOT=$TREE_ROOT NOSTAMP_KIDS=$TREE_KIDS
mkdir -p "$GUARD_ROOT/runs/claudeb-1-2-nostamp"
jq -n --argjson pid "$NOSTAMP_ROOT" '{vendor: "claudeb", account: "main", pid: $pid, workdir: "/tmp"}' \
  >"$GUARD_ROOT/runs/claudeb-1-2-nostamp/meta.json"
NOSTAMP_DIR="$WORK/guard-nostamp"
probes 2000 1024
assert guard_run "$NOSTAMP_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$NOSTAMP_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$NOSTAMP_DIR")"
for pid in $NOSTAMP_KIDS; do assert alive "$pid"; done

# A cell file carries no stamp of its own, so its mtime answers — it is written right after Popen.
# One whose mtime sits nowhere near its pid's start is a leftover pointing at a recycled number.
clear_registry
spawn_tree
MTIME_ROOT=$TREE_ROOT MTIME_KIDS=$TREE_KIDS
register_cell 20260905T202020Z-def456 claudeb-opus-high "$MTIME_ROOT"
touch -t 202601010101.00 "$GUARD_ROOT/stats/benches/20260905T202020Z-def456/pid-claudeb-opus-high"
MTIME_DIR="$WORK/guard-mtime"
probes 2000 1024
assert guard_run "$MTIME_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$MTIME_KIDS"
assert_fails grep -q '^KILLED ' "$(log_file "$MTIME_DIR")"
for pid in $MTIME_KIDS; do assert alive "$pid"; done

# The tree's weight is its DESCENDANTS, never its root: only descendants are killed, so a run fat at
# the root alone would be convicted for memory no kill can free — and its small children would be
# SIGKILLed every tick for nothing.
clear_registry
spawn_tree
HEAD_ROOT=$TREE_ROOT HEAD_KIDS=$TREE_KIDS
register_run claudeb-1-2-fathead "$HEAD_ROOT"
HEAD_DIR="$WORK/guard-fathead"
probes 2000 1024
assert guard_run "$HEAD_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$HEAD_ROOT=2097152"
assert_fails grep -q '^KILLED ' "$(log_file "$HEAD_DIR")"
for pid in $HEAD_KIDS; do assert alive "$pid"; done
# The same tree with the weight where the kill can reach it does fire, so the case above is the
# root being excluded and not the fixture failing to weigh anything.
probes 2000 1024
assert guard_run "$WORK/guard-fatkids" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$HEAD_KIDS"
assert grep -q "^KILLED .* root_pid=$HEAD_ROOT " "$(log_file "$WORK/guard-fatkids")"
for pid in $HEAD_KIDS; do assert gone "$pid"; done

# A candidate is a tree with something to kill. A childless root that outweighs every other tree
# would otherwise win the pick each tick, kill nothing, and leave the tree that IS cuttable standing
# while the machine thrashes.
clear_registry
spawn_leaf
spawn_tree
NEXT_ROOT=$TREE_ROOT NEXT_KIDS=$TREE_KIDS
register_run claudeb-1-2-leaf "$LEAF_ROOT"
register_run claudeb-1-2-next "$NEXT_ROOT"
LEAF_DIR="$WORK/guard-leaf"
probes 2000 1024
assert guard_run "$LEAF_DIR" MEMLOGD_MAX_TICKS=1 HEAVY_PIDS="$LEAF_ROOT=2097152 $NEXT_KIDS"
assert grep -q '^KILLED .* agent=claudeb-1-2-next ' "$(log_file "$LEAF_DIR")"
for pid in $NEXT_KIDS; do assert gone "$pid"; done
assert alive "$LEAF_ROOT"

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
# The guard's own thresholds are stated once, in the daemon, and the decision record quotes them.
assert grep -q '^memguard_avail_mb=3072$' "$SCRIPT"
assert grep -q '^memguard_tree_mb=1536$' "$SCRIPT"
assert grep -q '3072' "$ROOT/docs/memory-guard.md"
assert grep -q '1536' "$ROOT/docs/memory-guard.md"
# The agent process env is scoped to the run's own tree and set nowhere wider.
assert grep -q 'export NX_PARALLEL=1 NX_DAEMON=false' "$WORKER_RUN"

reap_trees

echo "PASS: $asserts asserts; quiet line format and node roll-up, a failed vm_stat probe that never fakes pressure, incident entry on available RAM alone with a marker naming its frames file and full pid/ppid/pgid/rss/etime blocks in frames/ not the day file, swap reported everywhere but deciding neither entry nor exit (drowning swap with healthy RAM stays quiet, recovery lands with swap unmoved), a probe that breaks mid-incident never latching it, recovery hysteresis both ways (held open under the window, closed and back to quiet once met), an incident spanning midnight marking the new day's file with frames continuing in the episode file, three-day rotation that spares neither an INCIDENT day nor a non-log file nor today's log and honours the retention knob including old frames, rotation sparing the frames file a live episode is still writing even when its name predates the window, a frames-directory budget that evicts the oldest file first and never the current episode, survives a name with a space and a file that vanished under the listing, an episode cap that stops the frames and says EPISODE-CAP once while the summaries keep coming, fast-then-slow incident frame cadence, a quiet-state jump that writes one frame headed jump and a JUMP marker without opening an incident, stays quiet below both thresholds and treats a failed ps probe as -1 rather than a rise on the next healthy tick, and a single-instance lock that refuses a live holder, refuses one that has written no pid yet, and takes over a dead one; plus the memory guard on real process trees — neither low RAM nor a fat tree convicting alone, both halves firing SIGKILL at the descendants while the tree's root survives, a failed probe never convicting, only the fattest tree cut with its neighbour left standing, an ended run dropping out of the registry, both registries read (worker-run meta.json and review-bench pid- cell files), a run rooted at its recorded cli_pid so the vendor CLI outlives the kill while its own children go, and a legacy run with no cli_pid still rooted at the supervisor, a registered root proving its identity before it can be cut (a stamp far from the process's own start skipped, the same tree with a truthful stamp cut, a record with no stamp skipped, a cell file whose mtime is nowhere near its pid's start skipped), a tree weighed by its descendants alone so a root fat by itself never costs its children their lives, a childless root never taking the pick from a tree that can be cut, the memguard record's fields, and the MEMGUARD: line worker-run renders from it in every report shape"
