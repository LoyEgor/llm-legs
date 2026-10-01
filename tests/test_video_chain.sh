#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/video-chain"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() {
  echo "FAIL: $*" >&2
  [ ! -s "$WORK/err" ] || sed -n '1,20p' "$WORK/err" >&2
  exit 1
}
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then fail "assert $asserts unexpectedly succeeded: $*"; fi
}
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required for this suite"
run() { "$SCRIPT" "$@" >"$WORK/out" 2>"$WORK/err"; }
rc() { run "$@"; printf '%s' "$?"; }
out() { grep -qx "$1" "$WORK/out"; }
stream() { ffprobe -v error -select_streams "$2" -show_entries "$3" -of csv=p=0 "$1" | head -n 1; }

RED_BLUE="$WORK/red-blue.mp4"
ffmpeg -v error -f lavfi -i color=c=red:s=320x180:d=1:r=24 -f lavfi -i color=c=blue:s=320x180:d=0.125:r=24 \
  -filter_complex '[0:v][1:v]concat=n=2:v=1[v]' -map '[v]' -c:v libx264 -pix_fmt yuv420p "$RED_BLUE" \
  || fail "no red-blue fixture"
STILL="$WORK/still.mp4"
ffmpeg -v error -f lavfi -i color=c=gray:s=320x180:d=2:r=24 -c:v libx264 -pix_fmt yuv420p "$STILL" || fail "no still fixture"
BUSY="$WORK/busy.mp4"
ffmpeg -v error -f lavfi -i testsrc2=s=640x360:d=2:r=30 -f lavfi -i sine=f=440:d=3 -c:v libx264 -pix_fmt yuv420p \
  -c:a aac "$BUSY" || fail "no busy fixture"

assert run last-frame "$RED_BLUE" "$WORK/last.png"
assert out "frame=$WORK/last.png"
assert out 'size=320x180'
rgb=$(ffmpeg -v error -i "$WORK/last.png" -vf 'crop=1:1:160:90' -f rawvideo -pix_fmt rgb24 - | od -An -tu1 | tr -s ' ')
read -r r g b <<<"$rgb"
assert test "$b" -gt 200 -a "$r" -lt 60
assert test "$(rc last-frame "$RED_BLUE" "$WORK/last.gif")" = 2
assert test "$(rc last-frame "$WORK/missing.mp4" "$WORK/x.png")" = 2
printf 'not a video' >"$WORK/text.mp4"
assert test "$(rc last-frame "$WORK/text.mp4" "$WORK/x.png")" = 2
assert grep -q 'no video stream' "$WORK/err"

assert run end-motion "$STILL"
assert out 'motion=still score=0.0 tail=1'
assert run end-motion "$BUSY" --tail 0.5 --strip "$WORK/strip.png"
assert grep -q '^motion=moving score=[0-9.]* tail=0.5$' "$WORK/out"
assert out "strip=$WORK/strip.png"
assert test "$(stream "$WORK/strip.png" v:0 stream=width,height)" = 1440,270
assert test "$(rc end-motion "$BUSY" --tail soon)" = 2
assert test "$(rc end-motion)" = 2

assert run join "$WORK/joined.mp4" "$BUSY" "$STILL" "$RED_BLUE"
assert out "dest=$WORK/joined.mp4"
assert out 'size=640x360'
assert out 'clips=3'
assert test "$(stream "$WORK/joined.mp4" v:0 stream=width,height,r_frame_rate)" = 640,360,30/1
seconds=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/joined.mp4")
awk -v s="$seconds" 'BEGIN { exit !(s > 5.0 && s < 5.3) }' || fail "joined length $seconds, expected about 5.1s"
audio=$(stream "$WORK/joined.mp4" a:0 stream=codec_name,sample_rate,channels,duration)
assert test "${audio%,*}" = aac,48000,2
awk -v a="${audio##*,}" -v s="$seconds" 'BEGIN { exit !(a > s - 0.1 && a < s + 0.1) }' \
  || fail "audio runs ${audio##*,}s against ${seconds}s of video"
assert test "$(rc join "$WORK/joined.mov" "$BUSY" "$STILL")" = 2
assert test "$(rc join "$WORK/one.mp4" "$BUSY")" = 2
assert test "$(rc join "$WORK/bad.mp4" "$BUSY" "$WORK/text.mp4")" = 2
assert test ! -e "$WORK/bad.mp4"
assert test "$(rc splice "$BUSY")" = 2

echo "PASS: $asserts asserts; last-frame returns the very last frame, end-motion tells a still tail from a moving one and tiles a direction strip, join cuts clips of any size, rate and audio into one at the first clip's format with audio held to each clip's video, and usage errors exit 2"
