#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
refute() { asserts=$((asserts + 1)); ! "$@" || fail "refute $asserts: $*"; }
export HOME="$WORK/home" TMPDIR="$WORK/tmp"
export FAKE_VIDEO_CALLS="$WORK/calls" GEMINI_SFX_VIDEO="$ROOT/tests/fixtures/fake-gemini-video-sfx.sh"
mkdir -p "$HOME" "$TMPDIR" "$WORK/media" "$WORK/out"
M=$WORK/media
ffmpeg -v error -f lavfi -i color=c=black:size=64x48:rate=24 -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=2' \
  -af 'volume=-12dB,adelay=1000|1000,apad=whole_dur=4' -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac "$M/take.mp4" || exit 1
ffmpeg -v error -f lavfi -i color=c=black:size=64x48:rate=24 -t 4 -c:v libx264 -pix_fmt yuv420p "$M/noaudio.mp4" || exit 1
ffmpeg -v error -f lavfi -i color=c=black:size=64x48:rate=24 -f lavfi -i anullsrc=r=48000:cl=stereo -t 4 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac "$M/mute.mp4" || exit 1
ffmpeg -v error -f lavfi -i color=c=black:size=64x48:rate=24 -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=4' \
  -af 'volume=-75dB' -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac "$M/faint.mp4" || exit 1
ffmpeg -v error -f lavfi -i testsrc2=size=64x48:rate=24 -t 3 -c:v libx264 -pix_fmt yuv420p "$M/scene.mp4" || exit 1
ffmpeg -v error -f lavfi -i testsrc2=size=64x48:rate=24 -t 12 -c:v libx264 -pix_fmt yuv420p "$M/long.mp4" || exit 1
export FAKE_VIDEO_SOURCE="$M/take.mp4" FAKE_VIDEO_NOAUDIO="$M/noaudio.mp4" FAKE_VIDEO_MUTE="$M/mute.mp4" FAKE_VIDEO_FAINT="$M/faint.mp4"
: >"$FAKE_VIDEO_CALLS"
: >"$WORK/err"

sfx() { bash "$ROOT/bin/gemini-sfx" "$@" >"$WORK/stdout" 2>"$WORK/err"; }
expect_rc() {
  local expected=$1 result=0
  shift
  sfx "$@" || result=$?
  assert test "$result" -eq "$expected"
}
seconds() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
near() { awk -v a="$1" -v b="$2" -v d="$3" 'BEGIN { exit !(a - b <= d && b - a <= d) }'; }
loudness() { ffmpeg -hide_banner -nostats -i "$1" -af loudnorm=print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p' | jq -r .input_i; }

out="$WORK/out/knock.wav"
expect_rc 2 --dest "$out"
expect_rc 2 --prompt 'a knock'
expect_rc 2 --dest relative.wav --prompt 'a knock'
expect_rc 2 --dest "$WORK/no-such-dir/a.wav" --prompt 'a knock'
expect_rc 2 --dest "$WORK/out/knock.mp3" --prompt 'a knock'
expect_rc 2 --dest "$out" --prompt 'a knock' --duration 5
assert grep -q 'one of 4, 6, 8, 10' "$WORK/err"
expect_rc 2 --dest "$out" --prompt 'a knock' --count 9
expect_rc 2 --dest "$out" --prompt 'a knock' --account 'bad name'
expect_rc 2 --dest "$out" --prompt 'a knock' --for-video "$M/scene.mp4" --duration 4
expect_rc 2 --dest "$out" --prompt 'a knock' --for-video "$M/scene.mp4" --count 2
expect_rc 2 --dest "$out" --prompt 'a knock' --for-video "$M/missing.mp4"
expect_rc 2 --dest "$out" --prompt 'a knock' --for-video "$M/long.mp4"
assert grep -q 'up to 10s' "$WORK/err"
expect_rc 2 --dest "$out" --prompt 'a knock' --bogus
assert test ! -s "$FAKE_VIDEO_CALLS"

assert sfx --dest "$out" --prompt 'three knocks on a wooden door'
assert grep -qx 'ARG=--model' "$FAKE_VIDEO_CALLS"
assert grep -qx 'ARG=omni' "$FAKE_VIDEO_CALLS"
assert grep -qx 'ARG=360p' "$FAKE_VIDEO_CALLS"
assert grep -qx 'ARG=4' "$FAKE_VIDEO_CALLS"
assert grep -qx 'LEG_LOG=/dev/null' "$FAKE_VIDEO_CALLS"
assert grep -q '^ARG=Sound effect reference clip\..* three knocks on a wooden door The soundtrack is only this sound effect' "$FAKE_VIDEO_CALLS"
refute grep -qx 'ARG=--edit' "$FAKE_VIDEO_CALLS"
assert grep -qx "dest=$out" "$WORK/stdout"
assert grep -qx 'format=wav' "$WORK/stdout"
assert grep -qx 'account=fakeacct' "$WORK/stdout"
assert grep -qx 'media=MEDIA1' "$WORK/stdout"
assert grep -qx 'model=abra_t2v_4s_360p' "$WORK/stdout"
assert grep -qx 'credits=4' "$WORK/stdout"
assert grep -qE '^seconds=[0-9]+$' "$WORK/stdout"
assert test "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$out")" = 'pcm_s16le,48000,2'
assert near "$(seconds "$out")" 2.1 0.25
assert grep -qx "duration=$(seconds "$out" | awk '{ printf "%.2f", $1 }')" "$WORK/stdout"
assert near "$(loudness "$out")" -16 1.5
assert test -z "$(ls "$TMPDIR")"
row=$(tail -n 1 "$IMAGE_LEG_LOG")
assert test "$(jq -c '[.tool, .kind, .rc, .account, .size]' <<<"$row")" = '["gemini-sfx","audio",0,"fakeacct",4]'

: >"$FAKE_VIDEO_CALLS"
assert sfx --dest "$out" --prompt 'a glass clink' --duration 6 --count 2
assert grep -qx 'ARG=6' "$FAKE_VIDEO_CALLS"
assert grep -qx 'credits=10' "$WORK/stdout"
assert grep -qx "variant=$WORK/out/knock-2.wav duration=$(seconds "$WORK/out/knock-2.wav" | awk '{ printf "%.2f", $1 }')" "$WORK/stdout"
assert near "$(seconds "$WORK/out/knock-2.wav")" 2.1 0.25

: >"$FAKE_VIDEO_CALLS"
scored="$WORK/out/scene.wav"
assert sfx --dest "$scored" --prompt 'a click when the dial turns' --for-video "$M/scene.mp4"
assert grep -qx 'ARG=--edit' "$FAKE_VIDEO_CALLS"
assert grep -qx "ARG=$M/scene.mp4" "$FAKE_VIDEO_CALLS"
assert grep -qx 'ARG=720p' "$FAKE_VIDEO_CALLS"
refute grep -qx 'ARG=--duration' "$FAKE_VIDEO_CALLS"
assert grep -q '^ARG=Keep the picture exactly as it is.* a click when the dial turns$' "$FAKE_VIDEO_CALLS"
assert grep -qx 'credits=20' "$WORK/stdout"
assert grep -qx "source=$M/scene.mp4 source_duration=3.00" "$WORK/stdout"
assert near "$(seconds "$scored")" 4 0.05

for mode in limit:3 login:4 usage:2 crash:1; do
  FAKE_VIDEO_MODE=${mode%%:*} expect_rc "${mode##*:}" --dest "$out" --prompt 'a knock'
done
FAKE_VIDEO_MODE=limit expect_rc 3 --dest "$out" --prompt 'a knock'
assert grep -qx 'GEMINI_USAGE_LIMIT' "$WORK/err"
FAKE_VIDEO_MODE=noaudio expect_rc 1 --dest "$WORK/out/none.wav" --prompt 'a knock'
assert grep -q 'without a soundtrack' "$WORK/err"
assert test ! -e "$WORK/out/none.wav"
FAKE_VIDEO_MODE=mute expect_rc 1 --dest "$WORK/out/none.wav" --prompt 'a knock'
assert grep -Eq 'is silent \(-?[0-9.inf]+ LUFS\) \(kept: '"$HOME"'/\.gemini-web/failures/[0-9TZ]+-[a-z-]+-[0-9]+-take\.mp4\)$' "$WORK/err"
assert test -s "$(sed -n 's/.*(kept: \(.*\))$/\1/p' "$WORK/err" | head -n 1)"
FAKE_VIDEO_MODE=faint expect_rc 1 --dest "$WORK/out/none.wav" --prompt 'a knock' --for-video "$M/scene.mp4"
assert grep -q 'is silent' "$WORK/err"
# A silent first take leaves the usable ones; a temp folder with a space keeps its variant paths whole.
mkdir -p "$WORK/tmp space"
TMPDIR="$WORK/tmp space" FAKE_VIDEO_MODE=first-mute assert sfx --dest "$WORK/out/kept.wav" --prompt 'a knock' --count 3
assert grep -qx "dest=$WORK/out/kept.wav" "$WORK/stdout"
assert grep -q "^variant=$WORK/out/kept-2.wav duration=" "$WORK/stdout"
refute grep -q 'kept-3' "$WORK/stdout"
assert grep -q 'is silent' "$WORK/err"
assert grep -qx 'gemini-sfx: kept 2 of 3 takes' "$WORK/err"
assert test -s "$WORK/out/kept-2.wav"
assert test -z "$(ls "$TMPDIR")" -a -z "$(ls "$WORK/tmp space")"
assert test "$(jq -s 'map(select(.tool == "gemini-sfx")) | length' "$IMAGE_LEG_LOG")" -ge 8

printf 'PASS test_gemini_sfx (%s asserts)\n' "$asserts"
