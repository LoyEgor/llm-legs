#!/usr/bin/env bash
set -u

# The split's whole performance argument is the bytecode cache: a __main__ script is compiled on
# every launch, a package under share/ is compiled once. Absolute millisecond ceilings measured the
# HOST instead of that claim — slack enough on a fast machine that a launch which lost the cache
# entirely still passed, and spurious failure on a slow or loaded one. So every launch is gated
# against ITSELF with no cache: the same tree copied without `__pycache__` and run under
# PYTHONDONTWRITEBYTECODE, which is what the pre-split single file paid on every launch. A package
# that stopped being cached drives the ratio to 1.0 and fails here on any machine.
CACHE_GAIN_MAX=0.75

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/review-bench"
PKG="$ROOT/share/rbench"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

COLD="$WORK/cold"
COLD_SCRIPT="$COLD/bin/review-bench"
mkdir -p "$COLD/bin"
cp "$SCRIPT" "$COLD_SCRIPT"
cp -R "$ROOT/share" "$COLD/share"
find "$COLD/share" -type d -name __pycache__ -exec rm -rf {} +
[ -z "$(find "$COLD/share" -name '*.pyc' -print -quit)" ] || fail "the no-cache tree still carries bytecode"

REPO="$WORK/repo"
STORE="$WORK/store"
export WORKER_STATS_DIR="$STORE"
mkdir -p "$REPO" "$STORE/benches/speed-run"
git -C "$REPO" init -q
git -C "$REPO" config user.email speed@test
git -C "$REPO" config user.name speed
printf 'x = 1\n' > "$REPO/a.py"
git -C "$REPO" add a.py
git -C "$REPO" -c commit.gpgsign=false commit -qm seed
printf 'x = 2\n' > "$REPO/a.py"

python3 - "$REPO" "$STORE/benches/speed-run/meta.json" <<'PY'
import json
import sys

repo, meta = sys.argv[1], sys.argv[2]
json.dump({
    "run_id": "speed-run",
    "commit": "a" * 40,
    "repo": repo,
    "tier": "T0",
    "raters": ["sol-high"],
    "rater_runs": [{"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
                    "duration_ms": 12000, "findings": 1, "exit_code": 0}],
    "durations": {},
    "focus": "",
    "started": "2026-08-23T11:32:38+00:00",
    "finished": "2026-08-23T11:33:38+00:00",
}, open(meta, "w"))
PY
printf '{"rater": "sol-high", "path": "a.py", "line": 1, "severity": "P2", "title": "t", "body": "b"}\n' \
  > "$STORE/benches/speed-run/findings-sol-high.jsonl"

# A crash is the fastest possible launch, so an unchecked exit code makes this suite reward the
# very failure it guards: an import error inside the package returns in a few ms and passes every
# ratio below. Both the warm-up and each timed run must succeed for a median to mean anything.
median_ms() {  # <label> <argv...>
  local label="$1"; shift
  "$@" >/dev/null 2>&1 || { printf 'FAIL: %s warm-up exited %s\n' "$label" "$?" >&2; return 1; }
  python3 - "$label" "$@" <<'PY'
import statistics
import subprocess
import sys
import time

label, cmd = sys.argv[1], sys.argv[2:]
ms = []
for _ in range(7):
    t = time.perf_counter()
    done = subprocess.run(cmd, capture_output=True)
    ms.append((time.perf_counter() - t) * 1000)
    if done.returncode != 0:
        sys.stderr.write("%s exited %d\n%s\n"
                         % (label, done.returncode, done.stderr.decode()[-2000:]))
        raise SystemExit(1)
print("%.1f" % statistics.median(ms))
PY
}

gate() {  # <label> <argv...>  — the same command cached and uncached, on this machine
  local label="$1" warm cold
  shift
  warm=$(median_ms "$label warm" "$SCRIPT" "$@") || return 1
  cold=$(median_ms "$label cold" env PYTHONDONTWRITEBYTECODE=1 "$COLD_SCRIPT" "$@") || return 1
  python3 -c 'import sys
warm, cold, cap, label = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
print("%8s  cached %6.1f ms  uncached %6.1f  ratio %.2f  max %.2f" % (label, warm, cold, warm / cold, cap))
sys.exit(0 if warm <= cold * cap else 1)' "$warm" "$cold" "$CACHE_GAIN_MAX" "$label"
}

assert gate help --help
assert gate debt debt --list --repo "$REPO"
assert gate report report speed-run

# The cache is the whole performance argument, so the assert has to name THIS package's own
# bytecode: any `.pyc` under `__pycache__` is also what a deleted module or a crashed half-import
# leaves behind, and either would keep passing while the launches recompile every module.
assert python3 - "$PKG" <<'PY'
import importlib.util
import os
import struct
import sys

pkg = sys.argv[1]
stale = []
for name in sorted(f for f in os.listdir(pkg) if f.endswith(".py")):
    source = os.path.join(pkg, name)
    cached = importlib.util.cache_from_source(source)
    if not os.path.exists(cached):
        stale.append(f"{name}: no {os.path.basename(cached)}")
        continue
    with open(cached, "rb") as handle:
        header = handle.read(16)
    if len(header) < 16 or header[:4] != importlib.util.MAGIC_NUMBER:
        stale.append(f"{name}: bytecode of another interpreter")
        continue
    flags, mtime, size = struct.unpack("<III", header[4:16])
    info = os.stat(source)
    if flags & 0b1:
        stale.append(f"{name}: hash-based pyc, no source stamp to check")
    elif (mtime, size) != (int(info.st_mtime) & 0xFFFFFFFF, info.st_size & 0xFFFFFFFF):
        stale.append(f"{name}: pyc predates the source it is cached for")
if stale:
    sys.stderr.write("bytecode cache does not cover this package: " + "; ".join(stale) + "\n")
    raise SystemExit(1)
PY

printf 'PASS: %s asserts; review-bench launches at most %sx of its own uncached cost and caches its bytecode\n' \
  "$asserts" "$CACHE_GAIN_MAX"
