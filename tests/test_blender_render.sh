#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
pids=()
trap 'touch "$WORK/release-a" "$WORK/release-b"; kill ${pids[@]+"${pids[@]}"} 2>/dev/null; rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
within() { # seconds command... -> whether the command held within that many seconds
  local i
  for ((i = 0; i < $1 * 20; i++)); do "${@:2}" && return 0; sleep 0.05; done
  return 1
}

# No real Blender, slot dir or holds: a fake Blender that runs until released (past one footprint sample a
# second), and a vm_stat with 15000 MB available, room for no second 9.5 GB run.
mkdir -p "$WORK/shim"
printf '#!/bin/bash\n: >"%s/started-${!#}"\nsleep 1.2\nuntil [ -e "%s/release-${!#}" ]; do sleep 0.05; done\necho "RESULT name=${!#}"\n' \
  "$WORK" "$WORK" >"$WORK/blender"
printf '#!/bin/sh\nprintf "Mach Virtual Memory Statistics: (page size of 16384 bytes)\\nPages free:  960000.\\nPages inactive:  0.\\nPages speculative:  0.\\n"\n' \
  >"$WORK/shim/vm_stat"
cat >"$WORK/shim/sysctl" <<'SH'
#!/bin/sh
case "$*" in
  '-n hw.memsize') echo 25769803776 ;;
  *) printf '1\n10\n{ 0.00 0.00 0.00 }\n' ;;
esac
SH
chmod +x "$WORK/blender" "$WORK/shim/vm_stat" "$WORK/shim/sysctl"
: >"$WORK/scene.py"
export BLENDER_BIN="$WORK/blender" BLENDER_RENDER_DIR="$WORK/state" PATH="$WORK/shim:$PATH" \
  SYSTEM_DOCTOR_SYSCTL="$WORK/shim/sysctl" \
  HARNESS_HOLDS_DIR="$WORK/holds" HARNESS_WAITS_DIR="$WORK/waits" SLOTS_POLL_S=0.2 SLOTS_ROOM_POLL_S=0.4
render() { "$ROOT/bin/blender-render" run "$WORK/scene.py" -- "$1" >"$WORK/out-$1" 2>&1; echo $? >"$WORK/rc-$1"; }

# With room for one Blender, a second concurrent render waits, held and announced, until the first ends.
render a &
pids+=($!)
assert within 20 test -e "$WORK/started-a"
render b &
pids+=($!)
assert within 20 grep -qx 'blender: waiting for a slot (1 running, room 1)' "$WORK/out-b"
assert test ! -e "$WORK/started-b"
assert within 5 eval 'compgen -G "$WORK/holds/blender-*.json" >/dev/null'
touch "$WORK/release-a"
assert within 20 test -e "$WORK/started-b"
touch "$WORK/release-b"
assert within 20 test -e "$WORK/rc-b"
assert within 5 test -e "$WORK/rc-a"
assert [ "$(cat "$WORK/rc-a") $(cat "$WORK/rc-b")" = "0 0" ]
assert grep -qx 'RESULT name=b' "$WORK/out-b"
assert test -z "$(compgen -G "$WORK/holds/blender-*.json")"
assert [ "$(cat "$WORK"/waits/*.jsonl | jq -s 'map(select(.class == "blender")) | length')" = 1 ]
# Each ended run gave its slot back and left its peak footprint for the next reservation.
assert test -z "$(find "$WORK/state/slots" -name pid)"
assert [ "$(grep -c '"mb"' "$WORK/state/peaks.jsonl")" = 2 ]

assert python3 - "$ROOT" <<'PY'
import importlib.machinery
import importlib.util
import json
import sys
import tempfile
from pathlib import Path
loader = importlib.machinery.SourceFileLoader('blender_render', sys.argv[1] + '/bin/blender-render')
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
with tempfile.TemporaryDirectory() as directory:
    m.STATE = directory
    rows = [(224, 'small.py'), (9400, 'small.py'), (8000, 'small.py'), (17000, 'big.py'), (9000, 'big.py'),
            (3, 'waiter.py')]
    Path(m.peaks_file()).write_text('\n'.join(json.dumps({'mb': n, 'what': w}) for n, w in rows))
    # A script reserves its own largest recent peak; others the median, never a waiter's few MB.
    assert m.footprint_mb('big.py') == 17000, m.footprint_mb('big.py')
    assert m.footprint_mb('small.py') == 9400, m.footprint_mb('small.py')
    assert m.footprint_mb('new.py') == 9200, m.footprint_mb('new.py')
    # The first slot checks memory only when a Blender outside the pool runs.
    m.subprocess.run = lambda *a, **k: type('R', (), {'stdout': ''})()
    assert not m.outside_blender()
    m.subprocess.run = lambda *a, **k: type('R', (), {'stdout': '4242\n'})()
    m.STATE = directory
    assert m.outside_blender()
PY
(
  . "$ROOT/share/slots.sh"
  slot_room() { printf 'fixture: insufficient memory\n'; return 1; }
  mkdir -p "$WORK/floor/2"
  printf '%s\n' "$$" >"$WORK/floor/2/pid"
  SLOTS_CHECK_FLOOR=1
  ! slot_take "$WORK/floor" 1-2 86400 >/dev/null
)
assert test "$?" -eq 0

assert python3 "$ROOT/tests/blender_wait_regression.py"

printf 'PASS: test_blender_render.sh (%s asserts)\n' "$asserts"
