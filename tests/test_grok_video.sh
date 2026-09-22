#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/grok-video"
FIXTURE="$ROOT/tests/fixtures/fake-grokb-video.sh"
MANIFEST="$ROOT/share/image-caps/grok.json"
WORK="$(mktemp -d)"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() {
  echo "FAIL: $*" >&2
  [ -z "${VIDEO_ERR:-}" ] || sed -n '1,80p' "$VIDEO_ERR" >&2
  exit 1
}
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
# Only grep's "found nothing" counts: an unreadable file or a bad pattern also exits non-zero, and
# taking that for the answer would let the assertion pass without ever looking at the text.
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -eq 1 ] || fail "assert $asserts failed with status $status, not a clean no-match: $*"
  fi
}

FAKE_BIN="$WORK/bin"
OUTPUT_DIR="$WORK/output"
TMP_ROOT="$WORK/tmp"
FAKE_GROKB_CALLS="$WORK/grokb-calls"
FAKE_GROKB_PROMPT="$WORK/grokb-prompt"
FAKE_GROKB_SESSION_ROOT="$WORK/grok-home/sessions"
PICK_CALLS="$WORK/worker-pick-calls"
export FAKE_GROKB_CALLS FAKE_GROKB_PROMPT FAKE_GROKB_SESSION_ROOT PICK_CALLS
mkdir -p "$FAKE_BIN" "$OUTPUT_DIR" "$TMP_ROOT"
: >"$FAKE_GROKB_CALLS"
: >"$FAKE_GROKB_PROMPT"
: >"$PICK_CALLS"

command -v ffprobe >/dev/null 2>&1 || fail "ffprobe is required for this suite"

cat >"$FAKE_BIN/worker-pick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_CALLS"
case "${PICK_MODE:-ok}" in
  ok) printf '%s\n' "${PICK_ACCOUNT:-picked}" ;;
  limit) exit 3 ;;
  fail) exit 7 ;;
esac
EOF
chmod +x "$FAKE_BIN/worker-pick"

cat >"$FAKE_BIN/grok" <<'EOF'
#!/usr/bin/env bash
printf 'grok %s (5e9a58528b76) [alpha]\n' "${FAKE_GROK_VERSION:-1.0.34}"
EOF
chmod +x "$FAKE_BIN/grok"

# Spotlight answers (null) for anything on an unindexed volume, so the fallback probe is exercised
# against a stub rather than against whatever this machine happens to have indexed.
cat >"$FAKE_BIN/fake-mdls" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_MDLS_MODE:-ok}" in
  null)
    printf 'kMDItemContentType     = (null)\nkMDItemDurationSeconds = (null)\nkMDItemPixelHeight     = (null)\nkMDItemPixelWidth      = (null)\n'
    ;;
  *)
    printf 'kMDItemContentType     = "public.mpeg-4"\nkMDItemDurationSeconds = 1.033\nkMDItemPixelHeight     = 36\nkMDItemPixelWidth      = 64\n'
    ;;
esac
EOF
chmod +x "$FAKE_BIN/fake-mdls"

VIDEO_OUT="$WORK/video.out"
VIDEO_ERR="$WORK/video.err"
GROK_PROFILES="$WORK/grok-profiles"
MAIN_GROK_HOME="$WORK/grok-main"
CLAIMS_DIR="$WORK/worker-claims"
SESSION_UUID=01a05a11-0000-7000-8000-00000000beef
mkdir -p "$GROK_PROFILES/explicit" "$GROK_PROFILES/picked"
printf 'reference\n' >"$WORK/ref-a.jpg"
printf 'reference\n' >"$WORK/ref-b.jpg"

video_run() {
  env PATH="$FAKE_BIN:$PATH" TMPDIR="$TMP_ROOT" \
    GROKB_PROFILES_DIR="$GROK_PROFILES" WORKER_CLAIMS_DIR="$CLAIMS_DIR" \
    GROKB_GROK_BIN="$FAKE_BIN/grok" GROKB_MAIN_GROK_HOME="$MAIN_GROK_HOME" \
    FAKE_GROK_VERSION="${FAKE_GROK_VERSION:-1.0.34}" \
    GROK_VIDEO_GROKB="$FIXTURE" GROK_VIDEO_WORKER_PICK="$FAKE_BIN/worker-pick" \
    GROK_VIDEO_FFPROBE="${GROK_VIDEO_FFPROBE:-ffprobe}" GROK_VIDEO_MDLS="${GROK_VIDEO_MDLS:-$FAKE_BIN/fake-mdls}" \
    FAKE_MDLS_MODE="${FAKE_MDLS_MODE:-ok}" \
    GROK_MEDIA_LOCK_WAIT="${GROK_MEDIA_LOCK_WAIT:-900}" \
    FAKE_GROKB_MODE="${FAKE_GROKB_MODE:-video}" PICK_MODE="${PICK_MODE:-ok}" \
    PICK_ACCOUNT="${PICK_ACCOUNT:-picked}" FAKE_GROKB_SESSION_ID="${FAKE_GROKB_SESSION_ID:-$SESSION_UUID}" \
    bash "$SCRIPT" "$@" >"$VIDEO_OUT" 2>"$VIDEO_ERR"
}

REFS_MAX=$(jq -r '.video.refs_max' "$MANIFEST")
VOICES_MAX=$(jq -r '.video.voices_max' "$MANIFEST")
SINGLE_TOOL=$(jq -r '.video.tools.single_ref' "$MANIFEST")
MULTI_TOOL=$(jq -r '.video.tools.multi_ref' "$MANIFEST")
CONTAINER=$(jq -r '.video.container' "$MANIFEST")

# A generation is billed the moment it is sent, so everything the arguments alone can refuse is
# refused before anything goes out — the proof is that the CLI was never called.
video_rc=0
video_run --dest "relative.$CONTAINER" --prompt 'push in' --ref "$WORK/ref-a.jpg" || video_rc=$?
assert test "$video_rc" -eq 2
assert grep -q '^usage: grok-video ' "$VIDEO_ERR"

for bad_dest in "$OUTPUT_DIR/clip.gif" "$OUTPUT_DIR/noext" "$OUTPUT_DIR/trailing."; do
  video_rc=0
  video_run --dest "$bad_dest" --prompt 'push in' --ref "$WORK/ref-a.jpg" || video_rc=$?
  assert test "$video_rc" -eq 2
done

# reference_to_video needs at least one image or one voice; there is no text-to-video tool at all.
video_rc=0
video_run --dest "$OUTPUT_DIR/empty.$CONTAINER" --prompt 'a city at night' || video_rc=$?
assert test "$video_rc" -eq 2

over_refs=()
for ((i = 0; i <= REFS_MAX; i++)); do over_refs+=(--ref "$WORK/ref-a.jpg"); done
video_rc=0
video_run --dest "$OUTPUT_DIR/manyrefs.$CONTAINER" --prompt 'push in' "${over_refs[@]}" || video_rc=$?
assert test "$video_rc" -eq 2

over_voices=()
for ((i = 0; i <= VOICES_MAX; i++)); do over_voices+=(--voice ara); done
video_rc=0
video_run --dest "$OUTPUT_DIR/manyvoices.$CONTAINER" --prompt 'speaking' "${over_voices[@]}" || video_rc=$?
assert test "$video_rc" -eq 2

for bad in 'Ara Voice' '' '../ara'; do
  video_rc=0
  video_run --dest "$OUTPUT_DIR/badvoice.$CONTAINER" --prompt speaking --voice "$bad" || video_rc=$?
  assert test "$video_rc" -eq 2
done

video_rc=0
video_run --dest "$OUTPUT_DIR/relref.$CONTAINER" --prompt 'push in' --ref ref-a.jpg || video_rc=$?
assert test "$video_rc" -eq 2
video_rc=0
video_run --dest "$OUTPUT_DIR/missingref.$CONTAINER" --prompt 'push in' --ref "$WORK/absent.jpg" || video_rc=$?
assert test "$video_rc" -eq 2

# image_to_video takes 6 or 10 seconds and nothing between; reference_to_video takes 1 to 15. The
# wrong one for the tool the refs select is refused rather than sent to be billed and rejected.
for bad_duration in 8 0 16 six; do
  video_rc=0
  video_run --dest "$OUTPUT_DIR/badduration.$CONTAINER" --prompt 'push in' \
    --ref "$WORK/ref-a.jpg" --duration "$bad_duration" || video_rc=$?
  assert test "$video_rc" -eq 2
done
for good_duration in 6 10; do
  video_rc=0
  video_run --dest "$OUTPUT_DIR/gooddur.$CONTAINER" --prompt 'push in' --account explicit \
    --ref "$WORK/ref-a.jpg" --duration "$good_duration" || video_rc=$?
  assert test "$video_rc" -eq 0
done
for bad_duration in 0 16; do
  video_rc=0
  video_run --dest "$OUTPUT_DIR/badrefdur.$CONTAINER" --prompt 'push in' \
    --ref "$WORK/ref-a.jpg" --ref "$WORK/ref-b.jpg" --duration "$bad_duration" || video_rc=$?
  assert test "$video_rc" -eq 2
  assert grep -q "grok-video: $MULTI_TOOL takes duration" "$VIDEO_ERR"
done
video_rc=0
video_run --dest "$OUTPUT_DIR/refdur.$CONTAINER" --prompt 'push in' --account explicit \
  --ref "$WORK/ref-a.jpg" --ref "$WORK/ref-b.jpg" --duration 8 || video_rc=$?
assert test "$video_rc" -eq 0
assert grep -q '^- duration: 8$' "$FAKE_GROKB_PROMPT"

video_rc=0
video_run --dest "$OUTPUT_DIR/badres.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --resolution 1080p || video_rc=$?
assert test "$video_rc" -eq 2

# image_to_video has no aspect_ratio field: quietly promoting the run to reference_to_video to
# honour the flag would animate a different tool than the reference count asked for.
video_rc=0
video_run --dest "$OUTPUT_DIR/aspect1.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --aspect 16:9 || video_rc=$?
assert test "$video_rc" -eq 2
assert grep -q "grok-video: $SINGLE_TOOL takes no aspect ratio" "$VIDEO_ERR"
video_rc=0
video_run --dest "$OUTPUT_DIR/aspect2.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --ref "$WORK/ref-b.jpg" --aspect 19.5:9 || video_rc=$?
assert test "$video_rc" -eq 2

video_rc=0
video_run --dest "$OUTPUT_DIR/badresume.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --resume 'my session' || video_rc=$?
assert test "$video_rc" -eq 2
assert grep -q 'session UUID printed as session=' "$VIDEO_ERR"

video_rc=0
video_run --dest "$OUTPUT_DIR/badacct.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account 'Ghost Acct' || video_rc=$?
assert test "$video_rc" -eq 2

# The probe is checked before the spend, the way grok-image checks magick: a video nobody can
# measure has already been billed by the time the missing tool is noticed.
video_rc=0
GROK_VIDEO_FFPROBE=/nonexistent-ffprobe GROK_VIDEO_MDLS=/nonexistent-mdls \
  video_run --dest "$OUTPUT_DIR/noprobe.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit || video_rc=$?
assert test "$video_rc" -eq 1
assert grep -q 'ffprobe or mdls is required' "$VIDEO_ERR"

: >"$FAKE_GROKB_CALLS"
video_rc=0
video_run --dest "$OUTPUT_DIR/ghostacct.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account ghostacct || video_rc=$?
assert test "$video_rc" -eq 1
assert grep -q 'account directory does not exist' "$VIDEO_ERR"
assert test ! -e "$GROK_PROFILES/ghostacct"
assert test ! -s "$FAKE_GROKB_CALLS"

# A worker-pick failure that is not a wall may not be reported as one: callers reroute off exit 3
# as if the account's quota were spent.
PICK_MODE=fail
export PICK_MODE
video_rc=0
video_run --dest "$OUTPUT_DIR/pickfail.$CONTAINER" --prompt 'push in' --ref "$WORK/ref-a.jpg" || video_rc=$?
assert test "$video_rc" -eq 1
assert grep -q 'worker-pick failed' "$VIDEO_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"
PICK_MODE=ok
export PICK_MODE

# One reference and no voice is image_to_video; anything else is reference_to_video, and the tool
# the run is allowed to call is the only one on the list.
: >"$FAKE_GROKB_CALLS"
: >"$PICK_CALLS"
assert video_run --dest "$OUTPUT_DIR/single.$CONTAINER" --prompt 'gentle camera push-in' \
  --ref "$WORK/ref-a.jpg"
assert grep -qx "ARG=$SINGLE_TOOL" "$FAKE_GROKB_CALLS"
assert_fails grep -qx "ARG=$MULTI_TOOL" "$FAKE_GROKB_CALLS"
assert grep -qx -- '--account grok --role image' "$PICK_CALLS"
assert test -e "$CLAIMS_DIR/grok/picked"
assert grep -qx 'ARG=profile' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=picked' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--always-approve' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=streaming-json' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--disable-web-search' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--no-subagents' "$FAKE_GROKB_CALLS"
assert grep -qx 'GROK_MEMORY=0' "$FAKE_GROKB_CALLS"
assert grep -q "^- image: $WORK/ref-a.jpg$" "$FAKE_GROKB_PROMPT"
assert grep -qx -- '- resolution_name: 480p' "$FAKE_GROKB_PROMPT"
assert grep -qx -- '- duration: 6' "$FAKE_GROKB_PROMPT"
assert_fails grep -q 'aspect_ratio' "$FAKE_GROKB_PROMPT"
# The footer contract: dest, size, format then the video's own duration, and only then the routing
# and provenance lines.
assert test "$(cut -d= -f1 "$VIDEO_OUT" | tr '\n' ' ')" = 'dest size format duration account session model caps '
assert grep -qx "dest=$OUTPUT_DIR/single.$CONTAINER" "$VIDEO_OUT"
assert grep -qx 'size=64x36' "$VIDEO_OUT"
assert grep -qx "format=$CONTAINER" "$VIDEO_OUT"
assert grep -qx 'duration=1' "$VIDEO_OUT"
assert grep -qx 'account=picked' "$VIDEO_OUT"
assert grep -qx "session=$SESSION_UUID" "$VIDEO_OUT"
assert grep -qx "model=$(jq -r '.model.video' "$MANIFEST") model_caps=fresh" "$VIDEO_OUT"
assert grep -qx 'caps=fresh' "$VIDEO_OUT"
assert cmp "$FAKE_GROKB_SESSION_ROOT/fake-session/videos/1.mp4" "$OUTPUT_DIR/single.$CONTAINER"
assert test -z "$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -name 'grok-video.*' -print -quit)"

: >"$FAKE_GROKB_CALLS"
: >"$FAKE_GROKB_PROMPT"
assert video_run --dest "$OUTPUT_DIR/multi.$CONTAINER" --prompt 'the person from <IMAGE_0> waves' \
  --ref "$WORK/ref-a.jpg" --ref "$WORK/ref-b.jpg" --aspect 9:16 --resolution 720p \
  --duration 10 --account explicit
assert grep -qx "ARG=$MULTI_TOOL" "$FAKE_GROKB_CALLS"
assert grep -q "^  - $WORK/ref-a.jpg$" "$FAKE_GROKB_PROMPT"
assert grep -q "^  - $WORK/ref-b.jpg$" "$FAKE_GROKB_PROMPT"
assert grep -qx -- '- aspect_ratio: 9:16' "$FAKE_GROKB_PROMPT"
assert grep -qx -- '- resolution_name: 720p' "$FAKE_GROKB_PROMPT"

# A voice turns a single reference into a reference_to_video run, and voices alone are a legal run
# of their own: the tool needs one of the two, not both.
: >"$FAKE_GROKB_CALLS"
: >"$FAKE_GROKB_PROMPT"
assert video_run --dest "$OUTPUT_DIR/voiced.$CONTAINER" --prompt '<IMAGE_0> speaks with <AUDIO_0>' \
  --ref "$WORK/ref-a.jpg" --voice ara --account explicit
assert grep -qx "ARG=$MULTI_TOOL" "$FAKE_GROKB_CALLS"
assert grep -q '^  - ara$' "$FAKE_GROKB_PROMPT"
: >"$FAKE_GROKB_CALLS"
assert video_run --dest "$OUTPUT_DIR/voiceonly.$CONTAINER" --prompt 'a narrator reads <AUDIO_0>' \
  --voice eve --voice leo --account explicit
assert grep -qx "ARG=$MULTI_TOOL" "$FAKE_GROKB_CALLS"

# The account is recovered from the store that holds the session, so a resume routes itself and
# spends no claim on the selector.
mkdir -p "$GROK_PROFILES/explicit/sessions/%2Ftmp%2Fwork/$SESSION_UUID"
: >"$FAKE_GROKB_CALLS"
: >"$PICK_CALLS"
assert video_run --dest "$OUTPUT_DIR/resumed.$CONTAINER" --prompt 'now pan left' \
  --ref "$WORK/ref-a.jpg" --resume "$SESSION_UUID"
assert test ! -s "$PICK_CALLS"
assert grep -qx 'ARG=--resume' "$FAKE_GROKB_CALLS"
assert grep -qx "ARG=$SESSION_UUID" "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=explicit' "$FAKE_GROKB_CALLS"
assert grep -qx 'account=explicit' "$VIDEO_OUT"
: >"$FAKE_GROKB_CALLS"
video_rc=0
video_run --dest "$OUTPUT_DIR/orphan.$CONTAINER" --prompt 'pan left' --ref "$WORK/ref-a.jpg" \
  --resume 01a05000-0000-7000-8000-000000000000 || video_rc=$?
assert test "$video_rc" -eq 1
assert grep -q 'no account holds session' "$VIDEO_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"

# Without ffprobe the run still reports, from whatever Spotlight knows; when Spotlight knows
# nothing either the file is kept and named rather than silently reported at a made-up size.
GROK_VIDEO_FFPROBE=/nonexistent-ffprobe
export GROK_VIDEO_FFPROBE
assert video_run --dest "$OUTPUT_DIR/mdls.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit
assert grep -qx 'size=64x36' "$VIDEO_OUT"
assert grep -qx "format=$CONTAINER" "$VIDEO_OUT"
assert grep -qx 'duration=1' "$VIDEO_OUT"
FAKE_MDLS_MODE=null
export FAKE_MDLS_MODE
video_rc=0
video_run --dest "$OUTPUT_DIR/unmeasurable.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit || video_rc=$?
assert test "$video_rc" -eq 1
assert grep -q 'could not inspect it; install ffmpeg' "$VIDEO_ERR"
assert test -s "$OUTPUT_DIR/unmeasurable.$CONTAINER"
FAKE_MDLS_MODE=ok
export FAKE_MDLS_MODE
unset GROK_VIDEO_FFPROBE

# One long generation per account at a time: a second run waits rather than racing the first one's
# quota, and a caller that will not wait is told so instead of being billed.
: >"$FAKE_GROKB_CALLS"
mkdir -p "$TMP_ROOT/grok-video.explicit.lock"
video_rc=0
GROK_MEDIA_LOCK_WAIT=0 video_run --dest "$OUTPUT_DIR/locked.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit || video_rc=$?
assert test "$video_rc" -eq 1
assert grep -q 'timed out waiting for account lock' "$VIDEO_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"
rmdir "$TMP_ROOT/grok-video.explicit.lock"
assert video_run --dest "$OUTPUT_DIR/unlocked.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit
assert test ! -e "$TMP_ROOT/grok-video.explicit.lock"

mkdir -p "$TMP_ROOT/grok-video.explicit.lock"
: >"$FAKE_GROKB_CALLS"
GROK_MEDIA_LOCK_WAIT=8 video_run --dest "$OUTPUT_DIR/waiter.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit &
waiter=$!
sleep 0.3
kill -INT "$waiter" 2>/dev/null || true
wait "$waiter" 2>/dev/null || true
assert test -d "$TMP_ROOT/grok-video.explicit.lock"
assert test ! -s "$FAKE_GROKB_CALLS"
rmdir "$TMP_ROOT/grok-video.explicit.lock"

# An image tag where a video tag belongs is not a video: shipping the session's last still frame
# would report a generation that never animated anything.
FAKE_GROKB_MODE=image-only
export FAKE_GROKB_MODE
video_rc=0
video_run --dest "$OUTPUT_DIR/stillframe.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit || video_rc=$?
assert test "$video_rc" -eq 1
assert grep -q 'no ImageToVideo event' "$VIDEO_ERR"
assert test ! -e "$OUTPUT_DIR/stillframe.$CONTAINER"

for mode_case in 'limit 3 GROK_USAGE_LIMIT' 'generic-limit 1 .' 'pool 4 refused by the worker pool' \
  'no-video 1 no ImageToVideo event' 'zdr 1 zero data retention' 'tier 1 no video generation on its tier'; do
  set -- $mode_case
  FAKE_GROKB_MODE=$1
  export FAKE_GROKB_MODE
  video_rc=0
  video_run --dest "$OUTPUT_DIR/$1.$CONTAINER" --prompt 'push in' \
    --ref "$WORK/ref-a.jpg" --account explicit || video_rc=$?
  assert test "$video_rc" -eq "$2"
  shift 2
  assert grep -q "$*" "$VIDEO_ERR"
done
FAKE_GROKB_MODE=video
export FAKE_GROKB_MODE

PICK_MODE=limit
export PICK_MODE
: >"$FAKE_GROKB_CALLS"
video_rc=0
video_run --dest "$OUTPUT_DIR/picklimit.$CONTAINER" --prompt 'push in' --ref "$WORK/ref-a.jpg" || video_rc=$?
assert test "$video_rc" -eq 3
assert grep -qx GROK_USAGE_LIMIT "$VIDEO_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"
PICK_MODE=ok
export PICK_MODE

# A CLI other than the verified one may promise the wrong limits, and the video model is compiled
# into the binary rather than configurable, so an unverified binary knows no model either.
FAKE_GROK_VERSION=9.9.9
export FAKE_GROK_VERSION
assert video_run --dest "$OUTPUT_DIR/staleversion.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit
assert grep -qx "caps=stale cli=9.9.9 verified=$(jq -r '.cli.version' "$MANIFEST")" "$VIDEO_OUT"
assert grep -qx 'model=unknown model_caps=unknown' "$VIDEO_OUT"
FAKE_GROK_VERSION=1.0.34
export FAKE_GROK_VERSION

# Whatever a media script writes is journalled by the agent that ran it, so the one thing it owes
# the review ledger is to pass the launching chat's stamp THROUGH to every process it starts.
: >"$FAKE_GROKB_CALLS"
CLAUDE_LAUNCHER_SESSION=video-launching-chat \
  video_run --dest "$OUTPUT_DIR/stamped.$CONTAINER" --prompt 'push in' \
  --ref "$WORK/ref-a.jpg" --account explicit
assert grep -qx 'CLAUDE_LAUNCHER_SESSION=video-launching-chat' "$FAKE_GROKB_CALLS"

echo "PASS: $asserts asserts; manifest-driven refs/voices/duration/resolution/aspect gates refused before any spend, image_to_video vs reference_to_video selection, account routing with claims and pool/limit classification, per-account lock, ffprobe and Spotlight probes plus the unmeasurable case, ImageToVideo-only harvesting, ZDR and tier refusals kept off exit 3, session resume routed by the store that holds it, the eight-line footer, and the launching chat's stamp passed through"
