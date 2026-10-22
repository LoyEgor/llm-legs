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

# An untagged source stays untagged: a BT.601 tag on its re-encode made 11 cleaned deck films jump in brightness
# against their sources in Egor's browser (2026-10-22), since players read the untagged one differently.
ffmpeg -nostdin -v error -f lavfi -i color=c=0x4a8030:s=320x180:r=24:d=0.5 -c:v libx264 -pix_fmt yuv420p "$WORK/bare.mp4"
assert "$UV" run -q --script "$ROOT/share/video_jitter.py" settle "$WORK/bare.mp4" "$WORK/bare-out.mp4" 2>"$WORK/err"
assert [ "$(tags "$WORK/bare-out.mp4")" = "$(tags "$WORK/bare.mp4")" ]

# fix: an upscale is clamped to its 720p in place, the download kept beside it byte for byte, and registered so the
# door swaps a frame cut from it for the 720p's.
VJ() { "$UV" run -q --script "$ROOT/share/video_jitter.py" "$@"; }
FLOW=(-c:v libx264 -crf 12 -pix_fmt yuv420p
  -bsf:v h264_metadata=colour_primaries=6:transfer_characteristics=6:matrix_coefficients=6:video_full_range_flag=0)
ACCURATE=scale=flags=accurate_rnd+full_chroma_int+full_chroma_inp
pair() { # still-filter dir [upscale-filter]: a 320x180 "720p" and its 480x270 "upscale" with an unsharp mask's halos
  mkdir -p "$WORK/$2"
  ffmpeg -nostdin -v error -f lavfi -i "mandelbrot=s=320x180:start_scale=0.3:start_x=-0.75:start_y=0.1" -vf "$1" \
    -frames:v 1 "$WORK/$2/still.png"
  ffmpeg -nostdin -v error -loop 1 -i "$WORK/$2/still.png" -t 0.5 -r 24 "${FLOW[@]}" "$WORK/$2/u.720p.mp4"
  ffmpeg -nostdin -v error -loop 1 -i "$WORK/$2/still.png" -vf "scale=480:270:flags=lanczos,unsharp=5:5:1.5${3:+,$3}" -t 0.5 \
    -r 24 "${FLOW[@]}" "$WORK/$2/u.mp4"
  cp "$WORK/$2/u.mp4" "$WORK/$2/download.mp4"
}
pair hue=s=0.3,eq=contrast=0.6 calm
assert VJ fix "$WORK/calm/u.mp4" --ref720 "$WORK/calm/u.720p.mp4" --register "$WORK/upscales.jsonl" >"$WORK/out" 2>"$WORK/err"
assert jq -e '.cleaned and .steadied == "none" and .clamped > 0.02 and .colour_shift <= 1.5' "$WORK/out" >/dev/null
assert jq -e --arg raw "$WORK/calm/u.raw.mp4" '.raw_file == $raw' "$WORK/out" >/dev/null
assert cmp -s "$WORK/calm/u.raw.mp4" "$WORK/calm/download.mp4"
differ() { ! cmp -s "$1" "$2"; }
assert differ "$WORK/calm/u.mp4" "$WORK/calm/download.mp4"
assert [ "$(tags "$WORK/calm/u.mp4")" = "$(tags "$WORK/calm/download.mp4")" ]
assert jq -e --arg dir "$WORK/calm" '.film == "\($dir)/u.mp4" and .twin == "\($dir)/u.720p.mp4"
  and .raw == "\($dir)/u.raw.mp4" and (.hashes | length) == 12' "$WORK/upscales.jsonl" >/dev/null

# A vivid picture keeps its glints and shadows: the 720p toned onto the upscale follows its levels past the ends.
pair null vivid
assert VJ fix "$WORK/vivid/u.mp4" --ref720 "$WORK/vivid/u.720p.mp4" >"$WORK/out" 2>"$WORK/err"
assert jq -e '.cleaned and .colour_shift <= 0.5' "$WORK/out" >/dev/null

# A 720p one frame ahead of its upscale is paired by content, not by index: a box crossing the frame stays put.
MOVE="[0][1]overlay=x=10+24*n:y=30"
mkdir -p "$WORK/lead"
ffmpeg -nostdin -v error -loop 1 -i "$WORK/calm/still.png" -f lavfi -i color=c=0xc04040:s=110x110 -filter_complex "$MOVE" \
  -frames:v 9 -r 24 "${FLOW[@]}" "$WORK/lead/u.720p.mp4"
ffmpeg -nostdin -v error -loop 1 -i "$WORK/calm/still.png" -f lavfi -i color=c=0xc04040:s=110x110 -filter_complex \
  "$MOVE,select=gte(n\,1),setpts=N/24/TB,scale=480:270:flags=lanczos,unsharp=5:5:1.5" -frames:v 8 -r 24 "${FLOW[@]}" \
  "$WORK/lead/u.mp4"
assert VJ fix "$WORK/lead/u.mp4" --ref720 "$WORK/lead/u.720p.mp4" >"$WORK/out" 2>"$WORK/err"
assert jq -e '.cleaned and .clamped < 0.08' "$WORK/out" >/dev/null

# An upscale whose hue drifted from its 720p's: the clamp would move its mean colour over 1.5 of 255, so the download
# stays untouched.
pair null strong hue=h=60
assert VJ fix "$WORK/strong/u.mp4" --ref720 "$WORK/strong/u.720p.mp4" >"$WORK/out" 2>"$WORK/err"
assert jq -e '(.cleaned | not) and .colour_shift > 1.5 and (.reason | test("upscale is kept"))' "$WORK/out" >/dev/null
assert cmp -s "$WORK/strong/u.mp4" "$WORK/strong/download.mp4"
assert [ ! -e "$WORK/strong/u.raw.mp4" ]

# The door: the upscale's frame (from the download) is swapped for the 720p's, a frame painted over after the cut is
# named, and a 720p frame or the still the take started from passes.
ffmpeg -nostdin -v error -i "$WORK/calm/download.mp4" -vf "select=eq(n\,5),$ACCURATE" -frames:v 1 "$WORK/cut.png"
ffmpeg -nostdin -v error -i "$WORK/calm/u.720p.mp4" -vf "select=eq(n\,5),$ACCURATE" -frames:v 1 "$WORK/low.png"
ffmpeg -nostdin -v error -i "$WORK/cut.png" -vf drawbox=x=400:y=20:w=40:h=30:color=white:t=fill "$WORK/painted.png"
assert VJ door "$WORK/cut.png" "$WORK/low.png" "$WORK/painted.png" "$WORK/calm/still.png" \
  --register "$WORK/upscales.jsonl" >"$WORK/out" 2>"$WORK/err"
assert [ "$(jq -r '[(.image | split("/") | last), .verdict] | join(" ")' "$WORK/out" | tr '\n' ,)" = "cut.png swap,painted.png edited," ]
swapped=$(jq -r 'select(.verdict == "swap") | .swapped' "$WORK/out")
assert [ "$(dirname "$swapped")" = "$WORK/frames" ]
assert [ "$(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$swapped")" = 320,180 ]
# An image to edit keeps its size: the swap is the fixed film's own frame, cleaned.
assert VJ door "$WORK/cut.png" --clean --register "$WORK/upscales.jsonl" >"$WORK/out" 2>"$WORK/err"
assert jq -e '.verdict == "swap" and .as == "cleaned"' "$WORK/out" >/dev/null
swapped=$(jq -r .swapped "$WORK/out")
assert [ "$(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$swapped")" = 480,270 ]
assert differ "$swapped" "$WORK/cut.png"

printf 'PASS: %s asserts; a re-encode keeps its source colour tags; fix clamps an upscale in place, keeps the download and registers it, and keeps it whole when the colour moves; the door swaps its frame for the 720p'"'"'s, or for an edit the cleaned one at its size, and names a painted one\n' "$asserts"
