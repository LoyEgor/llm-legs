#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
# audiokit on a made track: 120 BPM, a four-bar chord cycle with a kick on every beat (ffmpeg aevalsrc), so a clean
# loop exists and a cut off the beat is a click. The real engine runs through uv (numpy only); stems are off or a
# stub, never Demucs.

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
kit() { AUDIOKIT_CACHE="$WORK/cache" "$ROOT/bin/audiokit" "$@" >"$WORK/out" 2>"$WORK/err"; }
exits() { local want=$1; shift; kit "$@"; [ $? -eq "$want" ]; }
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

f='if(eq(mod(floor(t/2),4),0),220,if(eq(mod(floor(t/2),4),1),293.66,if(eq(mod(floor(t/2),4),2),329.63,246.94)))'
ffmpeg -v error -f lavfi -i "aevalsrc='0.2*sin(2*PI*$f*t)+0.12*sin(2*PI*$f*1.26*t)+0.1*sin(2*PI*$f*1.5*t)+0.5*exp(-25*mod(t,0.5))*sin(2*PI*55*t)':s=48000:d=64" \
  -ac 2 "$WORK/take.wav" || fail "ffmpeg could not make the take"

assert exits 2
assert exits 2 loop "$WORK/take.wav"

# The loop: whole bars, its own checks clean, the file exactly the length it printed, and check --loop agrees.
export AUDIOKIT_STEMS=off
assert exits 0 loop "$WORK/take.wav" "$WORK/loop.m4a" --min 16 --lufs -20
assert grep -q '^verdict=clean$' "$WORK/out"
assert grep -q 'stems=skipped' "$WORK/out"
assert grep -q 'stems off' "$WORK/err"
assert grep -qE '^loop [0-9.]+-[0-9.]+ s of 64.0 s: [0-9.]+ s, (8|9|1[0-9]|2[0-9])\.(00|01|99) bars of 2\.000 s' "$WORK/out"
len=$(sed -nE 's/^loop [0-9.-]+ s of [0-9.]+ s: ([0-9.]+) s,.*/\1/p' "$WORK/out")
assert awk -v a="$(dur "$WORK/loop.m4a")" -v b="$len" 'BEGIN { exit !(a - b < 0.001 && b - a < 0.001) }'
[ "$(uname)" != Darwin ] || assert grep -q 'checked=ffmpeg+apple' "$WORK/out"
assert exits 0 check "$WORK/loop.m4a" --loop
assert grep -q '^verdict=clean$' "$WORK/out"

# A loop cut by hand off the beat: a click at the wrap and a rhythm slip, both called.
ffmpeg -v error -ss 0.3 -t 15.37 -i "$WORK/take.wav" "$WORK/naive.wav"
assert exits 0 check "$WORK/naive.wav" --loop
assert grep -q '^verdict=audible$' "$WORK/out"
assert grep -qE 'step|silence|grid' "$WORK/out"

# Stems from the AUDIOKIT_STEMS command, cached by content: the second run does not call it again.
cat >"$WORK/stems" <<STUB
#!/usr/bin/env bash
printf 'call\n' >>"$WORK/stem-calls"
ffmpeg -v error -i "\$1" -ar 44100 "\$2/other.wav"
for n in drums bass vocals; do ffmpeg -v error -f lavfi -i anullsrc=r=44100:cl=stereo -t 64 "\$2/\$n.wav"; done
STUB
chmod +x "$WORK/stems"
export AUDIOKIT_STEMS="$WORK/stems"
assert exits 0 loop "$WORK/take.wav" "$WORK/loop2.wav" --min 16
assert grep -qE '^voice_cut=[0-9.-]+dB stems=[+-][0-9.]+dB \([a-z]+, [12] s\) notes=[0-9.]+ ' "$WORK/out"
assert grep -q '^share=' "$WORK/out"
assert test "$(ls "$WORK"/cache/stems/*/ | wc -l | tr -d ' ')" -eq 4
assert exits 0 points "$WORK/take.wav" --min 16 --top 3
assert test "$(wc -l <"$WORK/stem-calls" | tr -d ' ')" -eq 1
assert grep -qE '^0\.[0-9]+  [0-9.]+ .* (clean|borderline|heard)$' "$WORK/out"

printf 'PASS: audiokit (%s asserts)\n' "$asserts"
