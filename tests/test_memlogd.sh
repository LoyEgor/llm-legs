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
export TICK_FILE AVAIL_FILE SWAP_TICK SWAP_FILE

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
    printf '%8s %s\n' 512000 /opt/homebrew/bin/node
    printf '%8s %s\n' 512000 '/Applications/Some App/node'
    printf '%8s %s\n' 512000 /usr/local/bin/node
    printf '%8s %s\n' 900000 /Applications/Cursor.app/Contents/MacOS/Cursor
    ;;
  *pid,ppid,pgid,rss,etime,command*)
    printf '  PID  PPID  PGID    RSS  ELAPSED COMMAND\n'
    printf '    1     0     1  22096 05:32:41 /sbin/launchd\n'
    printf '  801   799   801 512000    01:12 node /tmp/worker.js\n'
    printf '  802   799   802 512000    00:04 node /tmp/worker.js\n'
    ;;
  *)
    printf 'UNEXPECTED-PS %s\n' "$*"
    ;;
esac
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
exec /bin/date "$@"
EOF
chmod +x "$FAKE_BIN/vm_stat" "$FAKE_BIN/sysctl" "$FAKE_BIN/ps" "$FAKE_BIN/date"
PATH="$FAKE_BIN:$PATH"
export PATH

# Every case declares its whole machine: an availability sequence, a swap sequence and both probe
# cursors, so no case reads what the case before it left behind.
probes() {
  printf '%s' "$1" >"$AVAIL_FILE"
  printf '%s' "$2" >"$SWAP_FILE"
  printf '0' >"$TICK_FILE"
  printf '0' >"$SWAP_TICK"
}

# The real ~/Library/Logs is never a test target: every case runs against its own MEMLOGD_DIR.
run_memlogd() {
  local dir="$1"; shift
  run_day=$(date +%F)
  env MEMLOGD_DIR="$dir" MEMLOGD_SYNC=0 MEMLOGD_QUIET_INTERVAL=0 MEMLOGD_INCIDENT_INTERVAL=0 \
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
assert grep -qE '^INCIDENT [0-9]{10} avail_mb=2000 swap_used_mb=1024$' "$incident_log"
assert test "$(grep -c '^INCIDENT ' "$incident_log")" -eq 1
assert test "$(grep -c '^PS-BEGIN ' "$incident_log")" -eq 2
assert test "$(grep -c '^PS-END ' "$incident_log")" -eq 2
assert grep -qE '^[0-9]{10} incident avail_mb=2000 swap_used_mb=1024 node_count=3 node_rss_mb=1500$' \
  "$incident_log"
# ppid/pgid/etime are the columns that expose a spawn loop, so the block carries the whole table.
assert grep -q 'PID  PPID  PGID    RSS  ELAPSED COMMAND' "$incident_log"
assert grep -q '  801   799   801 512000    01:12 node /tmp/worker.js' "$incident_log"
assert_fails grep -q 'UNEXPECTED-PS' "$incident_log"
assert_fails grep -q 'RECOVERED' "$incident_log"

# --- incident trigger on swap alone ---------------------------------------------------------------
SWAP_DIR="$WORK/swap-trigger"
probes 8192 7000
assert run_memlogd "$SWAP_DIR" MEMLOGD_MAX_TICKS=1
assert grep -qE '^INCIDENT [0-9]{10} avail_mb=8192 swap_used_mb=7000$' "$(log_file "$SWAP_DIR")"

# --- swap that entered the incident has to leave it: healthy RAM alone never recovers -------------
# A machine with free RAM and permanent swap pressure would otherwise flap INCIDENT/RECOVERED every
# tick and dump the whole process table at 1 Hz forever.
FLAP_DIR="$WORK/swap-flap"
probes 8192 7000
assert run_memlogd "$FLAP_DIR" MEMLOGD_MAX_TICKS=3 MEMLOGD_RECOVER_SECONDS=0
flap_log=$(log_file "$FLAP_DIR")
assert test "$(grep -c '^INCIDENT ' "$flap_log")" -eq 1
assert_fails grep -q '^RECOVERED ' "$flap_log"
assert test "$(grep -c '^PS-BEGIN ' "$flap_log")" -eq 3

# --- and swap leaves it on its own exit threshold, not on the entry one ---------------------------
SWAP_EXIT_DIR="$WORK/swap-exit"
probes 8192 '7000 5500 5000'
assert run_memlogd "$SWAP_EXIT_DIR" MEMLOGD_MAX_TICKS=3 MEMLOGD_RECOVER_SECONDS=0
swap_exit_log=$(log_file "$SWAP_EXIT_DIR")
# 5500 is under the entry threshold and over the exit one: that band is the hysteresis.
assert grep -qE '^RECOVERED [0-9]{10} avail_mb=8192 swap_used_mb=5000$' "$swap_exit_log"
assert test "$(grep -c '^PS-BEGIN ' "$swap_exit_log")" -eq 3

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
assert test "$(grep -c '^PS-BEGIN ' "$hold_log")" -eq 4

# --- a met recovery window closes the incident and returns the loop to quiet ----------------------
RECOVER_DIR="$WORK/recover"
probes '2000 6000 6000' 1024
assert run_memlogd "$RECOVER_DIR" MEMLOGD_MAX_TICKS=3 MEMLOGD_RECOVER_SECONDS=0
recover_log=$(log_file "$RECOVER_DIR")
assert grep -qE '^RECOVERED [0-9]{10} avail_mb=6000 swap_used_mb=1024$' "$recover_log"
assert test "$(grep -c '^PS-BEGIN ' "$recover_log")" -eq 2
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
assert grep -qE '^INCIDENT [0-9]{10} avail_mb=2000 swap_used_mb=1024$' \
  "$MIDNIGHT_DIR/$first_day.log"
assert grep -qE '^INCIDENT [0-9]{10} continued=1$' "$MIDNIGHT_DIR/$second_day.log"
assert test "$(grep -c '^PS-BEGIN ' "$MIDNIGHT_DIR/$second_day.log")" -eq 1

# --- rotation: age drops quiet logs, an INCIDENT marker keeps one ---------------------------------
ROTATE_DIR="$WORK/rotate"
mkdir -p "$ROTATE_DIR"
quiet_line='1700000000 quiet avail_mb=8192 swap_used_mb=0 node_count=0 node_rss_mb=0'
recent=$(date -v-2d +%F)
# The 21-day edge itself, a day either side of the cutoff: far enough out that a midnight crossing
# between these dates and the daemon's own cutoff cannot move either one across it.
inside_edge=$(date -v-20d +%F)
outside_edge=$(date -v-22d +%F)
printf '%s\n' "$quiet_line" >"$ROTATE_DIR/2000-01-01.log"
printf 'INCIDENT 946684800 avail_mb=100 swap_used_mb=7000\n' >"$ROTATE_DIR/2000-01-02.log"
printf '  801   799   801 512000 01:12 node --title INCIDENT /tmp/worker.js\n' \
  >"$ROTATE_DIR/2000-01-03.log"
printf '%s\n' "$quiet_line" >"$ROTATE_DIR/$recent.log"
printf '%s\n' "$quiet_line" >"$ROTATE_DIR/$inside_edge.log"
printf '%s\n' "$quiet_line" >"$ROTATE_DIR/$outside_edge.log"
printf 'keep me\n' >"$ROTATE_DIR/notes.txt"
probes 8192 1024
assert run_memlogd "$ROTATE_DIR" MEMLOGD_MAX_TICKS=1
assert_fails test -e "$ROTATE_DIR/2000-01-01.log"
assert test -f "$ROTATE_DIR/2000-01-02.log"
# The word inside a ps command line is not a marker; only a line that starts with it is.
assert_fails test -e "$ROTATE_DIR/2000-01-03.log"
assert test -f "$ROTATE_DIR/$recent.log"
assert test -f "$ROTATE_DIR/$inside_edge.log"
assert_fails test -e "$ROTATE_DIR/$outside_edge.log"
assert test -f "$ROTATE_DIR/notes.txt"
assert test -f "$(log_file "$ROTATE_DIR")"

# --- and the retention window is a knob, not a constant -------------------------------------------
SHORT_DIR="$WORK/rotate-short"
mkdir -p "$SHORT_DIR"
short_keep=$(date -v-4d +%F)
short_drop=$(date -v-6d +%F)
printf '%s\n' "$quiet_line" >"$SHORT_DIR/$short_keep.log"
printf '%s\n' "$quiet_line" >"$SHORT_DIR/$short_drop.log"
probes 8192 1024
assert run_memlogd "$SHORT_DIR" MEMLOGD_MAX_TICKS=1 MEMLOGD_RETENTION_DAYS=5
assert test -f "$SHORT_DIR/$short_keep.log"
assert_fails test -e "$SHORT_DIR/$short_drop.log"

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

echo "PASS: $asserts asserts; quiet line format and node roll-up, a failed vm_stat probe that never fakes pressure, incident entry on available RAM and on swap alone with a marker and full pid/ppid/pgid/rss/etime blocks, recovery that needs every reading back under its own exit threshold (sustained swap never flaps, the swap band is hysteresis, a probe that breaks mid-incident never latches it), recovery hysteresis both ways (held open under the window, closed and back to quiet once met), an incident spanning midnight marking the new day's file, rotation pinned at the 21-day edge and honouring the retention knob, INCIDENT logs kept and only anchored markers counted, non-log files untouched, and a single-instance lock that refuses a live holder, refuses one that has written no pid yet, and takes over a dead one"
