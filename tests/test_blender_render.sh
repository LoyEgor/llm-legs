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
# second), and a vm_stat with 6000 MB available, room for no second 9.5 GB run.
mkdir -p "$WORK/shim"
printf '#!/bin/bash\n: >"%s/started-${!#}"\nsleep 1.2\nuntil [ -e "%s/release-${!#}" ]; do sleep 0.05; done\necho "RESULT name=${!#}"\n' \
  "$WORK" "$WORK" >"$WORK/blender"
printf '#!/bin/sh\nprintf "Mach Virtual Memory Statistics: (page size of 16384 bytes)\\nPages free:  384000.\\nPages inactive:  0.\\nPages speculative:  0.\\n"\n' \
  >"$WORK/shim/vm_stat"
chmod +x "$WORK/blender" "$WORK/shim/vm_stat"
: >"$WORK/scene.py"
export BLENDER_BIN="$WORK/blender" BLENDER_RENDER_DIR="$WORK/state" PATH="$WORK/shim:$PATH" \
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
# Each ended run gave its slot back and left its peak footprint for the next median.
assert test -z "$(find "$WORK/state/slots" -name pid)"
assert [ "$(grep -c '"mb"' "$WORK/state/peaks.jsonl")" = 2 ]

printf 'PASS: test_blender_render.sh (%s asserts)\n' "$asserts"
