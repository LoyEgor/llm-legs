#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
export HOME="$WORK/home" GEMINIB_PROFILES_DIR="$WORK/profiles"
export WORKER_CLAIMS_DIR="$WORK/claims" WORKER_PICK_CONFIG_FILE="$WORK/worker-model"
export LLM_LIMITS_GEMINI_CACHE="$WORK/main-cache" LLM_LIMITS_GEMINI_REMOVED="$WORK/main-removed"
export LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$WORK/account-caches" TMPDIR="$WORK/tmp"
export FAKE_GEMINIB_CALLS="$WORK/calls" FAKE_GEMINIB_PROMPT="$WORK/prompt"
export PICK_CALLS="$WORK/picks" GEMINIB_CACHE_DIR="$WORK/geminib-cache"
. "$ROOT/tests/fixtures/geminib-families.sh"
mkdir -p "$HOME" "$WORK/bin" "$TMPDIR" "$WORK/media" "$WORK/out" "$GEMINIB_PROFILES_DIR/explicit" "$GEMINIB_PROFILES_DIR/picked"
ln -s "$ROOT/tests/fixtures/fake-geminib-listen.sh" "$WORK/bin/geminib"
cat >"$WORK/bin/worker-pick" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_CALLS"
[ "${PICK_MODE:-ok}" != limit ] || exit 3
printf 'picked\n'
STUB
chmod +x "$WORK/bin/worker-pick"
export PATH="$WORK/bin:$PATH"
: >"$FAKE_GEMINIB_CALLS"
: >"$PICK_CALLS"
: >"$WORK/err"

M=$WORK/media
ffmpeg -v error -f lavfi -i testsrc2=size=64x48:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$M/clip.mp4" || exit 1
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 "$M/tone.wav" || exit 1
ffmpeg -v error -f lavfi -i testsrc2=size=64x48 -frames:v 1 "$M/still.png" || exit 1
ffmpeg -v error -f lavfi -i testsrc2=size=64x48:rate=24 -t 2 -c:v libx264 -pix_fmt yuv420p "$M/silent.mkv" || exit 1
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=48000 -t 200 -ac 2 "$M/long.wav" || exit 1
ffmpeg -v error -i "$M/tone.wav" -i "$M/still.png" -map 0:a -map 1:v -c:a libmp3lame -c:v mjpeg \
  -disposition:v attached_pic "$M/cover.mp3" || exit 1
printf 'not media\n' >"$M/notes.txt"

listen() { bash "$ROOT/bin/gemini-listen" "$@" >"$WORK/stdout" 2>"$WORK/err"; }
expect_rc() {
  local expected=$1 result=0
  shift
  listen "$@" || result=$?
  assert test "$result" -eq "$expected"
}

expect_rc 2 'what is heard?'
expect_rc 2 'what is heard?' relative.wav
expect_rc 2 'what is heard?' "$M/missing.wav"
expect_rc 2 'what is heard?' "$M/tone.wav" -o relative.md
expect_rc 2 'what is heard?' "$M/tone.wav" -o "$WORK/no-such-dir/a.md"
expect_rc 2 'what is heard?' "$M/tone.wav" --model ultra
expect_rc 2 'what is heard?' "$M/tone.wav" --account 'bad name'
expect_rc 2 'what is heard?' "$M/notes.txt"
assert grep -q 'no picture or sound' "$WORK/err"
expect_rc 2 'what is heard?' "$M/tone.wav" --account unknown
assert grep -q 'unknown account: unknown (not on the gemini roster' "$WORK/err"
: >"$LLM_LIMITS_GEMINI_REMOVED"
expect_rc 2 'what is heard?' "$M/tone.wav" --account main
rm -f "$LLM_LIMITS_GEMINI_REMOVED"
assert test ! -s "$FAKE_GEMINIB_CALLS"
assert test ! -s "$PICK_CALLS"

answer="$WORK/out/answer.md"
assert listen 'what happens?' "$M/clip.mp4" "$M/tone.wav" "$M/still.png" "$M/cover.mp3" -o "$answer"
assert grep -qx -- '--account gemini --role image' "$PICK_CALLS"
assert test -e "$WORKER_CLAIMS_DIR/gemini/picked"
assert grep -qx 'ARG=gemini-3.1-pro-high' "$FAKE_GEMINIB_CALLS"
assert grep -qx 'ARG=stream-json' "$FAKE_GEMINIB_CALLS"
assert grep -q "^PWD=$TMPDIR/gemini-listen\." "$FAKE_GEMINIB_CALLS"
assert grep -q '^File 1: /.*/media/file1\.mp4 (video, 2\.0 s, 64x48, with sound; the caller'\''s file clip\.mp4)$' "$FAKE_GEMINIB_PROMPT"
assert grep -q '^File 2: /.*/media/file2\.wav (audio, 2\.0 s; the caller'\''s file tone\.wav)$' "$FAKE_GEMINIB_PROMPT"
assert grep -q '^File 3: /.*/media/file3\.png (image, 64x48; the caller'\''s file still\.png)$' "$FAKE_GEMINIB_PROMPT"
assert grep -q '^File 4: /.*/media/file4\.mp3 (audio, 2\.0 s; the caller'\''s file cover\.mp3)$' "$FAKE_GEMINIB_PROMPT"
assert grep -qx 'what happens?' "$FAKE_GEMINIB_PROMPT"
assert test "$(head -n 1 "$answer")" = '<!-- gemini-3.1-pro-high -->'
assert grep -qF "[file1](file://$M/clip.mp4)" "$answer"
assert grep -qx 'The pitch steps up at 3 s.' "$answer"
assert grep -qx "dest=$answer" "$WORK/stdout"
assert grep -qx 'account=picked' "$WORK/stdout"
assert grep -qx 'session=listen-session' "$WORK/stdout"
assert grep -qx 'model=gemini-3.1-pro-high' "$WORK/stdout"
assert grep -qx 'files=4 proxied=0' "$WORK/stdout"
assert grep -qE '^seconds=[0-9]+$' "$WORK/stdout"
assert test -z "$(find "$TMPDIR" -name 'gemini-listen.*' -print -quit)"
assert test "$(jq -sc 'map(select(.rc == 0)) | .[0] | [.tool, .kind, .account, .size]' "$IMAGE_LEG_LOG")" = '["gemini-listen","listen","picked",4]'

: >"$PICK_CALLS"
: >"$FAKE_GEMINIB_CALLS"
assert listen 'is it silent?' "$M/silent.mkv" "$M/long.wav" --model flash --account explicit
assert test ! -s "$PICK_CALLS"
assert grep -qx 'ARG=gemini-3.8-flash-high' "$FAKE_GEMINIB_CALLS"
assert grep -qx 'ARG=explicit' "$FAKE_GEMINIB_CALLS"
assert test "$(head -n 1 "$WORK/stdout")" = '<!-- gemini-3.8-flash-high -->'
assert grep -qF "[file1](file://$M/silent.mkv)" "$WORK/stdout"
assert grep -qx 'dest=-' "$WORK/err"
assert grep -qx 'files=2 proxied=2' "$WORK/err"
assert grep -qE "^proxy=file1\.mp4 [0-9]+ bytes from [0-9]+: $M/silent\.mkv$" "$WORK/err"
assert grep -qE "^proxy=file2\.mp3 [0-9]+ bytes from [0-9]+: $M/long\.wav$" "$WORK/err"
assert grep -q '^File 1: /.*/media/file1\.mp4 (video, 2\.0 s, 64x48, silent; ' "$FAKE_GEMINIB_PROMPT"
assert grep -q '^File 2: /.*/media/file2\.mp3 (audio, 200\.0 s; ' "$FAKE_GEMINIB_PROMPT"

FAKE_GEMINIB_MODE=skip-view expect_rc 1 'q' "$M/clip.mp4" "$M/tone.wav" --account explicit
assert grep -q "answered without opening $M/tone.wav" "$WORK/err"
FAKE_GEMINIB_MODE=view-error expect_rc 1 'q' "$M/clip.mp4" "$M/tone.wav" --account explicit
assert grep -q "answered without opening $M/clip.mp4" "$WORK/err"
FAKE_GEMINIB_MODE=quota expect_rc 3 'q' "$M/tone.wav" --account explicit
assert grep -qx GEMINI_USAGE_LIMIT "$WORK/err"
assert grep -q 'retry with --model flash' "$WORK/err"
FAKE_GEMINIB_MODE=quota-stderr expect_rc 3 'q' "$M/tone.wav" --account explicit --model flash
assert grep -q 'retry with --model pro' "$WORK/err"
FAKE_GEMINIB_MODE=pool expect_rc 4 'q' "$M/tone.wav" --account explicit
FAKE_GEMINIB_MODE=cannot-open expect_rc 1 'q' "$M/tone.wav" --account explicit
assert grep -q 'could not open a file: 1 file size' "$WORK/err"
FAKE_GEMINIB_MODE=empty expect_rc 1 'q' "$M/tone.wav" --account explicit
FAKE_GEMINIB_MODE=error expect_rc 1 'q' "$M/tone.wav" --account explicit
: >"$FAKE_GEMINIB_CALLS"
PICK_MODE=limit expect_rc 3 'q' "$M/tone.wav"
assert test ! -s "$FAKE_GEMINIB_CALLS"
assert test -z "$(find "$TMPDIR" -name 'gemini-listen.*' -print -quit)"

printf 'PASS: gemini-listen (%s asserts)\n' "$asserts"
