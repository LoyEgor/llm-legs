#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/elevenlabs_media.py: what the API refused on the first live calls (2026-10-05) is settled before a
# request. Fixture keys and a dead API host: a request that slips through fails on the network, never bills.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
export ELEVENLABS_KEYS="$WORK/keys.txt" ELEVENLABS_API_BASE="http://127.0.0.1:9" IMAGE_LEG_LOG="$WORK/legs.jsonl"
printf 'fixture-key trimmed\n' >"$ELEVENLABS_KEYS"
el() { python3 "$ROOT/share/elevenlabs_media.py" "$@" >"$WORK/out" 2>"$WORK/err"; }
python3 -c 'import sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(2 * 16000 * 27 // 10))' "$WORK/short.wav"

# Text to speech refuses pcm_44100 below the Pro tier (HTTP 403 output_format_not_allowed): a .wav is no raw PCM.
assert el speech --dest "$WORK/a.wav" --text hi --voice abcdefghij0123456789 --dry-run
assert python3 -c 'import json, sys; fmt = json.load(open(sys.argv[1]))["output_format"]; assert not fmt.startswith("pcm_"), fmt' "$WORK/out"

# Isolation refuses audio under 4.6 s (HTTP 400 invalid_audio_duration): exit 2 before any request.
el isolate --in "$WORK/short.wav" --dest "$WORK/iso.wav"
assert test $? -eq 2
assert grep -q 'isolation takes at least 4.6 s' "$WORK/err"

# An srt needs diarization on (HTTP 400 invalid_parameters).
assert el transcribe --in "$WORK/short.wav" --dest "$WORK/t.srt" --dry-run
assert python3 -c 'import json, sys; assert ["diarize", "true"] in json.load(open(sys.argv[1]))["fields"]' "$WORK/out"

# Lip-sync needs a Pro plan (HTTP 402 paid_plan_required): no kind runs it.
el lipsync --dest "$WORK/l.mp4"
assert test $? -eq 2

echo "PASS test_elevenlabs_media ($asserts asserts)"
