#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
UV=$(command -v uv || printf /opt/homebrew/bin/uv)
tags() { ffprobe -v error -select_streams v:0 -show_entries stream=color_space,color_primaries,color_transfer,color_range \
  -of csv=p=0 "$1"; }

# Flow tags its films BT.601; an untagged re-encode is read as BT.709 by players and its colours shift.
ffmpeg -nostdin -v error -f lavfi -i color=c=0x4a8030:s=320x180:r=24:d=0.5 -c:v libx264 -pix_fmt yuv420p \
  -bsf:v h264_metadata=colour_primaries=1:transfer_characteristics=13:matrix_coefficients=6:video_full_range_flag=0 "$WORK/in.mp4"
assert "$UV" run -q --script "$ROOT/share/video_jitter.py" settle "$WORK/in.mp4" "$WORK/out.mp4" 2>"$WORK/err"
assert [ "$(tags "$WORK/out.mp4")" = "$(tags "$WORK/in.mp4")" ]
assert [ "$(tags "$WORK/out.mp4")" = "tv,smpte170m,iec61966-2-1,bt709" ]

printf 'PASS: %s asserts; a re-encode keeps its source colour tags\n' "$asserts"
