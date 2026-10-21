#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required for this suite"
sheet() { "$ROOT/bin/frame-sheet" "$@" >"$WORK/out" 2>"$WORK/err"; }
exits() { local want=$1; shift; sheet "$@"; [ $? -eq "$want" ]; }
out() { grep -qx "$1" "$WORK/out"; }
differ() { ! cmp -s "$1" "$2"; }

CLIP="$WORK/clip.mp4"
ffmpeg -nostdin -v error -f lavfi -i testsrc=s=320x180:d=2:r=24 -c:v libx264 -pix_fmt yuv420p "$CLIP" || fail "no clip fixture"
SOLID="$WORK/solid.mp4"
ffmpeg -nostdin -v error -f lavfi -i color=c=0x4a8030:s=320x180:d=2:r=24 -c:v libx264 -pix_fmt yuv420p "$SOLID" \
  || fail "no solid fixture"

cd "$WORK" || exit 1
assert exits 2
assert exits 2 clip.mp4 --dest "$WORK/x.jpg"
assert grep -q 'clip.mp4 is not an absolute path' "$WORK/err"
assert exits 2 "$CLIP"
assert grep -q 'missing --dest' "$WORK/err"
assert exits 2 "$CLIP" --dest "$WORK/x.png"
assert exits 2 "$CLIP" --dest "$WORK/x.jpg" --fps 0
assert exits 2 "$CLIP" --dest "$WORK/x.jpg" --cols 0
assert exits 2 "$CLIP" --dest "$WORK/x.jpg" --start 1 --end 1
assert exits 2 "$CLIP" --dest "$WORK/x.jpg" --rows 2
assert test ! -e "$WORK/x.jpg"
assert exits 1 "$CLIP" --dest "$WORK/x.jpg" --start 5
assert grep -q 'no frame' "$WORK/err"

# 2 s at 8 fps, 420x236 tiles 8 to a row with 4 px between and around them.
assert exits 0 "$CLIP" --dest "$WORK/all.jpg"
assert out "dest=$WORK/all.jpg"
assert out 'frames=16'
assert out 'size=3396x484'
assert test "$(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$WORK/all.jpg")" = '3396,484'
assert exits 0 "$CLIP" --dest "$WORK/range.jpg" --start 0.5 --end 1.6
assert out 'frames=9'
assert exits 0 "$CLIP" --dest "$WORK/small.jpg" --fps 2 --width 200 --cols 3
assert out 'frames=4'
assert out 'size=616x236'
# Fewer frames than --cols make one row exactly as wide as the frames.
assert exits 0 "$CLIP" --dest "$WORK/wide.jpg" --cols 20
assert out 'size=6788x244'

# Every frame of a solid clip is the same picture, so two one-frame sheets differ only by their labels:
# t=1.000 under --start 1 is the source's time, not the sheet's.
assert exits 0 "$SOLID" --dest "$WORK/at0.jpg" --end 0.1
assert out 'frames=1'
assert exits 0 "$SOLID" --dest "$WORK/at1.jpg" --start 1 --end 1.1
assert out 'frames=1'
assert exits 0 "$SOLID" --dest "$WORK/at1-again.jpg" --start 1 --end 1.1
assert cmp -s "$WORK/at1.jpg" "$WORK/at1-again.jpg"
assert differ "$WORK/at0.jpg" "$WORK/at1.jpg"

printf 'PASS: frame-sheet (%s asserts)\n' "$asserts"
