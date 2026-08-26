#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEMLOG="$ROOT/share/rbench/memlog.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

HOME="$WORK/home"
export HOME
mkdir -p "$HOME"

# The whole machine is shimmed, because every reading this sampler takes is a moving number on a
# real Mac: a suite that watched the live one could only assert that something was written.
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
PATH="$FAKE_BIN:$PATH"
export PATH

cat >"$FAKE_BIN/vm_stat" <<'EOF'
#!/bin/sh
cat <<INNER
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                               ${MEMLOG_FREE_PAGES}.
Pages active:                             500000.
Pages inactive:                           0.
Pages speculative:                        0.
INNER
EOF

cat >"$FAKE_BIN/sysctl" <<'EOF'
#!/bin/sh
echo "total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)"
EOF

cat >"$FAKE_BIN/ps" <<'EOF'
#!/bin/sh
cat "$MEMLOG_PS_TABLE"
EOF
chmod +x "$FAKE_BIN/vm_stat" "$FAKE_BIN/sysctl" "$FAKE_BIN/ps"

PS_TABLE="$WORK/ps-table"
cat >"$PS_TABLE" <<'EOF'
  PID  PPID    RSS     ELAPSED COMMAND
  101     1 204800    01:02:03 /opt/fake/hog
  102   101   1024    00:00:05 node /opt/fake/spawner.js
  103   102   1024    00:00:01 /usr/bin/tiny-quiet-tool
EOF
MEMLOG_PS_TABLE="$PS_TABLE"
export MEMLOG_PS_TABLE

BENCHES="$WORK/benches"
GB8_PAGES=2097152
GB2_PAGES=524288

# Sampling is paced by the wall clock, so a case waits for the ticks it is about to assert instead
# of for a duration a loaded machine can miss; the deadline only keeps a broken sampler from
# hanging the suite, and the assert that follows it is what fails.
sample_until() {
  run_dir="$1"
  want="$2"
  deadline=$((SECONDS + 60))
  mkdir -p "$run_dir"
  python3 "$MEMLOG" "$run_dir" $$ &
  sampler_pid=$!
  while [ "$(grep -c '^T ' "$run_dir/memlog.txt" 2>/dev/null || echo 0)" -lt "$want" ]; do
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.2
  done
  kill -TERM "$sampler_pid" 2>/dev/null
  wait "$sampler_pid" 2>/dev/null
}

MEMLOG_FREE_PAGES="$GB8_PAGES"
export MEMLOG_FREE_PAGES
QUIET="$BENCHES/20260826T120000Z-quiet"
sample_until "$QUIET" 2
QUIET_LOG="$QUIET/memlog.txt"
assert test -s "$QUIET_LOG"
assert grep -Eq '^T [0-9]{10} avail_mb=8192 swap_mb=512 mode=quiet procs=2$' "$QUIET_LOG"
# The fat process is kept on its RSS alone, its command matching nothing the filter watches.
assert grep -q '^101     1 204800    01:02:03 /opt/fake/hog$' "$QUIET_LOG"
# And a small one is kept on its command, which is how a spawn loop is visible before it is fat.
assert grep -q '^102   101   1024    00:00:05 node /opt/fake/spawner.js$' "$QUIET_LOG"
assert test "$(grep -c 'tiny-quiet-tool' "$QUIET_LOG")" -eq 0
assert test "$(grep -c '^INCIDENT ' "$QUIET_LOG")" -eq 0
assert grep -q ' final=1$' "$QUIET_LOG"
assert test "$(grep -c ' final=1$' "$QUIET_LOG")" -eq 1
assert test "$(grep -c '^T ' "$QUIET_LOG")" -ge 2

MEMLOG_FREE_PAGES="$GB2_PAGES"
export MEMLOG_FREE_PAGES
HOT="$BENCHES/20260826T130000Z-hot"
sample_until "$HOT" 3
HOT_LOG="$HOT/memlog.txt"
assert grep -Eq '^INCIDENT [0-9]{10}$' "$HOT_LOG"
# Entering is one event however long the run stays under the threshold.
assert test "$(grep -c '^INCIDENT ' "$HOT_LOG")" -eq 1
assert grep -Eq '^T [0-9]{10} avail_mb=2048 swap_mb=512 mode=incident procs=3$' "$HOT_LOG"
assert grep -q 'tiny-quiet-tool' "$HOT_LOG"
# 1 Hz under the threshold against the 2 s of a quiet run.
assert test "$(grep -c '^T ' "$HOT_LOG")" -ge 3
MEMLOG_FREE_PAGES="$GB8_PAGES"
export MEMLOG_FREE_PAGES

# A machine that answers nothing is logged and sampled on: a diagnostic that raised would take
# the review with it.
cat >"$FAKE_BIN/ps" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKE_BIN/ps"
BROKEN="$BENCHES/20260826T140000Z-broken"
sample_until "$BROKEN" 1
BROKEN_LOG="$BROKEN/memlog.txt"
assert grep -Eq '^ERROR [0-9]{10} ps CalledProcessError' "$BROKEN_LOG"
assert grep -q 'mode=quiet procs=0' "$BROKEN_LOG"
assert grep -q ' final=1$' "$BROKEN_LOG"
cat >"$FAKE_BIN/ps" <<'EOF'
#!/bin/sh
cat "$MEMLOG_PS_TABLE"
EOF
chmod +x "$FAKE_BIN/ps"

# A vm_stat that answers with no page counts changed shape; it did not report an empty machine.
# Zero would sit under the threshold and hold the rest of the run in incident mode.
cat >"$FAKE_BIN/vm_stat" <<'EOF'
#!/bin/sh
echo "Mach Virtual Memory Statistics: (page size of 4096 bytes)"
EOF
chmod +x "$FAKE_BIN/vm_stat"
BLIND="$BENCHES/20260826T145000Z-blind"
sample_until "$BLIND" 1
BLIND_LOG="$BLIND/memlog.txt"
assert grep -Eq '^ERROR [0-9]{10} vm_stat ValueError' "$BLIND_LOG"
assert grep -qF 'avail_mb=? swap_mb=512 mode=quiet' "$BLIND_LOG"
assert test "$(grep -c '^INCIDENT ' "$BLIND_LOG")" -eq 0
cat >"$FAKE_BIN/vm_stat" <<'EOF'
#!/bin/sh
cat <<INNER
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                               ${MEMLOG_FREE_PAGES}.
Pages active:                             500000.
Pages inactive:                           0.
Pages speculative:                        0.
INNER
EOF
chmod +x "$FAKE_BIN/vm_stat"

python3 - "$MEMLOG" "$BENCHES" "$ROOT/share" <<'PY' || fail "python checks failed"
import importlib.util
import os
import subprocess
import sys
import time
from pathlib import Path

memlog_path, benches, share = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location("memlog_under_test", memlog_path)
memlog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memlog)

# stop() ends the sampler, and leaves no orphan behind it.
live = benches / "20260826T150000Z-live"
live.mkdir(parents=True)
handle = memlog.start(live)
assert handle is not None
pid = handle.process.pid
os.kill(pid, 0)
memlog.stop(handle)
assert handle.process.poll() is not None, handle.process.poll()
try:
    os.kill(pid, 0)
    raise SystemExit(f"sampler {pid} survived stop()")
except ProcessLookupError:
    pass

# A sampler outlives the panel only far enough to notice it is gone: the parent pid is polled,
# and a vanished parent ends the sampler with it.
orphan_pid = int(subprocess.run(
    [sys.executable, "-c",
     "import importlib.util,sys;"
     "spec=importlib.util.spec_from_file_location('m', sys.argv[1]);"
     "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);"
     "print(m.start(sys.argv[2]).process.pid)",
     memlog_path, str(benches / "20260826T150000Z-live")],
    capture_output=True, text=True, check=True,
).stdout.strip())
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    try:
        os.kill(orphan_pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.25)
else:
    os.kill(orphan_pid, 9)
    raise SystemExit(f"orphaned sampler {orphan_pid} outlived its panel")

# An incident that never reached the file is not on record: returning "recorded" for a write that
# failed leaves the marker unwritten, and rotation later deletes the only evidence as a quiet log.
os.environ["MEMLOG_FREE_PAGES"] = "524288"
assert memlog.sample(benches / "20260826T151000Z-no-such-dir" / memlog.MEMLOG_NAME, False) is False
recorded = benches / "20260826T151500Z-hot-write"
recorded.mkdir(parents=True)
recorded_log = recorded / memlog.MEMLOG_NAME
assert memlog.sample(recorded_log, False) is True
assert recorded_log.read_text().count(f"{memlog.INCIDENT_MARKER} ") == 1
os.environ["MEMLOG_FREE_PAGES"] = "2097152"

# The marker is a line start, and the chunked read has to find one that straddles a chunk boundary.
straddle = benches / "20260826T152000Z-straddle" / memlog.MEMLOG_NAME
straddle.parent.mkdir(parents=True)
straddle.write_text("T 1780000000 avail_mb=8192 swap_mb=0 mode=quiet procs=1\n" * 30000
                    + "INCIDENT 1780000002\n")
assert memlog.has_incident(straddle)

# Rotation keeps every log that ever saw the incident it exists to catch, and only those.
old = time.time() - 20 * 24 * 60 * 60
for name, body in (
    ("20260701T000000Z-old-quiet", "T 1780000000 avail_mb=8192 swap_mb=0 mode=quiet procs=1\n"),
    ("20260701T000100Z-old-hot", "INCIDENT 1780000001\nT 1780000001 avail_mb=900 swap_mb=9 mode=incident procs=1\n"),
    # The word inside a ps command line is not the marker, or one rater's argv exempts a quiet log
    # from rotation for good.
    ("20260701T000200Z-old-word", "T 1780000000 avail_mb=8192 swap_mb=0 mode=quiet procs=1\n"
                                  "  102   101   1024 00:00:05 node --title INCIDENT /opt/fake/x\n"),
    ("20260826T160000Z-fresh", "T 1787700000 avail_mb=8192 swap_mb=0 mode=quiet procs=1\n"),
):
    directory = benches / name
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / memlog.MEMLOG_NAME
    log.write_text(body)
    if name.startswith("202607"):
        os.utime(log, (old, old))

fresh_run = benches / "20260826T170000Z-rotating"
fresh_run.mkdir(parents=True)
memlog.stop(memlog.start(fresh_run))
assert not (benches / "20260701T000000Z-old-quiet" / memlog.MEMLOG_NAME).exists()
assert (benches / "20260701T000100Z-old-hot" / memlog.MEMLOG_NAME).exists()
assert not (benches / "20260701T000200Z-old-word" / memlog.MEMLOG_NAME).exists()
assert (benches / "20260826T160000Z-fresh" / memlog.MEMLOG_NAME).exists()

# A run directory that is not there is a diagnostic that cannot run, never a review that dies.
assert memlog.start(benches / "20260826T180000Z-missing") is None
assert memlog.start(benches / "20260826T160000Z-fresh" / memlog.MEMLOG_NAME) is None

# And the panel holds the sampler between its cells: the first one in starts it, the last out
# stops it, and a sampler that refuses to start costs the cell nothing.
sys.path.insert(0, share)
import rbench

started, stopped = [], []


def record_start(run_dir):
    started.append(str(run_dir))
    return "handle"


rbench.launch._memlog = type("Stub", (), {
    "start": staticmethod(record_start),
    "stop": staticmethod(stopped.append),
})()
rbench.launch.run_rater_task = lambda *args: ("rater", None, (0, 1, "", "", []))
cell = {"spec": "stub"}
assert rbench.launch.run_rater_chunks(cell, "repo", "sha", "", live, "diff", [])[2][0] == 0
assert started == [str(live)], started
assert stopped == ["handle"], stopped

rbench.launch._memlog_handle = None
rbench.launch._memlog_cells = 0


def refuse(run_dir):
    raise RuntimeError("no telemetry today")


rbench.launch._memlog = type("Broken", (), {
    "start": staticmethod(refuse),
    "stop": staticmethod(lambda handle: None),
})()
assert rbench.launch.run_rater_chunks(cell, "repo", "sha", "", live, "diff", [])[2][0] == 0
print("python checks ok")
PY
asserts=$((asserts + 1))

echo "PASS: $asserts asserts; quiet sampling (epoch, available and swap header, a fat process kept on RSS alone, a small one kept on its command, an unwatched small one left out, one final block), incident mode (marker written once on entry, full process table, 1 Hz), a broken machine logged rather than raised, an unreadable vm_stat that never reads as zero available and never marks an incident, a marker not counted as recorded until its write lands, stop() leaving no orphan, a sampler self-terminating on a vanished panel, rotation deleting old quiet logs while keeping every INCIDENT one (anchored at a line start, found across a chunk boundary, the word inside a command line not counting) and every fresh one, a missing run directory refused without raising, and the panel wiring starting and stopping the sampler around its cells while a refusing sampler costs the cell nothing"
