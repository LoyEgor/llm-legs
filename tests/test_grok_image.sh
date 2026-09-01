#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/grok-image"
FIXTURE="$ROOT/tests/fixtures/fake-grokb-image.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() {
  echo "FAIL: $*" >&2
  [ -z "${IMAGE_ERR:-}" ] || sed -n '1,80p' "$IMAGE_ERR" >&2
  exit 1
}
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -ne 127 ] || fail "assert $asserts command not found: $*"
  fi
}

FAKE_BIN="$WORK/bin"
OUTPUT_DIR="$WORK/output"
TMP_ROOT="$WORK/tmp"
FAKE_GROKB_CALLS="$WORK/grokb-calls"
FAKE_GROKB_PROMPT="$WORK/grokb-prompt"
FAKE_GROKB_SESSION_ROOT="$WORK/grok-home/sessions"
PICK_CALLS="$WORK/worker-pick-calls"
MAGICK_CALLS="$WORK/magick-calls"
REAL_MAGICK=$(command -v magick)
export FAKE_GROKB_CALLS FAKE_GROKB_PROMPT FAKE_GROKB_SESSION_ROOT PICK_CALLS MAGICK_CALLS REAL_MAGICK
mkdir -p "$FAKE_BIN" "$OUTPUT_DIR" "$TMP_ROOT"
: >"$FAKE_GROKB_CALLS"
: >"$FAKE_GROKB_PROMPT"
: >"$PICK_CALLS"
: >"$MAGICK_CALLS"

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

cat >"$FAKE_BIN/magick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MAGICK_CALLS"
exec "$REAL_MAGICK" "$@"
EOF
chmod +x "$FAKE_BIN/magick"

IMAGE_OUT="$WORK/image.out"
IMAGE_ERR="$WORK/image.err"
image_run() {
  env PATH="$FAKE_BIN:$PATH" TMPDIR="$TMP_ROOT" \
    GROK_IMAGE_GROKB="$FIXTURE" GROK_IMAGE_WORKER_PICK="$FAKE_BIN/worker-pick" \
    FAKE_GROKB_MODE="${FAKE_GROKB_MODE:-image}" PICK_MODE="${PICK_MODE:-ok}" \
    PICK_ACCOUNT="${PICK_ACCOUNT:-picked}" FAKE_GROKB_IMAGE_FORMAT="${FAKE_GROKB_IMAGE_FORMAT:-jpg}" \
    bash "$SCRIPT" "$@" >"$IMAGE_OUT" 2>"$IMAGE_ERR"
}

image_rc=0
image_run --dest relative.png --prompt badge || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '^usage: grok-image ' "$IMAGE_ERR"

image_rc=0
image_run --dest "$OUTPUT_DIR/bad.png" --prompt badge --aspect 5:4 || image_rc=$?
assert test "$image_rc" -eq 2

# 4:3 and 3:4 are image_edit's, never image_gen's: sent without a reference the ratio reaches the
# images API unvalidated and costs a whole generation to be refused, so it is refused here instead.
: >"$FAKE_GROKB_CALLS"
for unsupported in 4:3 3:4; do
  image_rc=0
  image_run --dest "$OUTPUT_DIR/bad.png" --prompt badge --aspect "$unsupported" || image_rc=$?
  assert test "$image_rc" -eq 2
  assert grep -q "^grok-image: --aspect $unsupported needs --ref" "$IMAGE_ERR"
done
assert test ! -s "$FAKE_GROKB_CALLS"
# With a reference the run goes to image_edit, which takes them.
printf 'reference\n' >"$WORK/aspect-reference.jpg"
FAKE_GROKB_IMAGE_FORMAT=jpg
assert image_run --dest "$OUTPUT_DIR/wide.jpg" --prompt 'make the badge blue' \
  --aspect 4:3 --ref "$WORK/aspect-reference.jpg" --account explicit
assert grep -q 'Aspect ratio: 4:3' "$FAKE_GROKB_PROMPT"

: >"$FAKE_GROKB_CALLS"
: >"$PICK_CALLS"
: >"$MAGICK_CALLS"
FAKE_GROKB_IMAGE_FORMAT=png
assert image_run --dest "$OUTPUT_DIR/generated.png" --prompt 'flat blue square on white' --aspect 1:1
assert cmp "$FAKE_GROKB_SESSION_ROOT/fake-session/images/1.png" "$OUTPUT_DIR/generated.png"
assert test "$(sips -g format "$OUTPUT_DIR/generated.png" | awk '/format:/ {print $2}')" = png
assert test "$(sips -g hasAlpha "$OUTPUT_DIR/generated.png" | awk '/hasAlpha:/ {print $2}')" = yes
assert test ! -s "$MAGICK_CALLS"
assert grep -qx -- '--account grok --claim' "$PICK_CALLS"
assert grep -qx 'ARG=profile' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=picked' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--tools' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=streaming-json' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=image_gen' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--always-approve' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--max-turns' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=4' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--output-format' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--disable-web-search' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--no-subagents' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=--cwd' "$FAKE_GROKB_CALLS"
assert grep -qx 'GROK_MEMORY=0' "$FAKE_GROKB_CALLS"
assert grep -q 'Generate exactly one image and stop' "$FAKE_GROKB_PROMPT"
assert grep -q 'Aspect ratio: 1:1' "$FAKE_GROKB_PROMPT"
assert grep -qx 'account=picked' "$IMAGE_OUT"
assert test -z "$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -name 'grok-image.*' -print -quit)"

: >"$MAGICK_CALLS"
FAKE_GROKB_IMAGE_FORMAT=jpg
assert image_run --dest "$OUTPUT_DIR/converted.png" --prompt 'flat blue square on white' --account explicit
assert test "$(sips -g format "$OUTPUT_DIR/converted.png" | awk '/format:/ {print $2}')" = png
assert test -s "$MAGICK_CALLS"
assert grep -Fq "$FAKE_GROKB_SESSION_ROOT/fake-session/images/1.jpg $OUTPUT_DIR/converted.png" "$MAGICK_CALLS"

printf 'reference\n' >"$WORK/reference.jpg"
: >"$FAKE_GROKB_CALLS"
: >"$PICK_CALLS"
assert image_run --dest "$OUTPUT_DIR/edited.jpg" --prompt 'make the badge blue' \
  --ref "$WORK/reference.jpg" --account explicit
assert test ! -s "$PICK_CALLS"
assert grep -qx 'ARG=explicit' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=image_gen,image_edit' "$FAKE_GROKB_CALLS"
assert grep -q "^- $WORK/reference.jpg$" "$FAKE_GROKB_PROMPT"
assert grep -q 'Use image_edit' "$FAKE_GROKB_PROMPT"
assert cmp "$FAKE_GROKB_SESSION_ROOT/fake-session/images/1.jpg" "$OUTPUT_DIR/edited.jpg"

: >"$MAGICK_CALLS"
assert image_run --dest "$OUTPUT_DIR/transparent.png" \
  --prompt 'transparent green badge' --transparent --account explicit
assert grep -q '#00FF00' "$FAKE_GROKB_PROMPT"
assert_fails grep -Eqi '(^|[^[:alnum:]_])transparent([^[:alnum:]_]|$)' "$FAKE_GROKB_PROMPT"
assert grep -q -- '-alpha extract -morphology EdgeIn Octagon:2' "$MAGICK_CALLS"
assert test "$(sips -g format "$OUTPUT_DIR/transparent.png" | awk '/format:/ {print $2}')" = png

FAKE_GROKB_MODE=limit
export FAKE_GROKB_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/limit.jpg" --prompt portrait --account explicit || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx GROK_USAGE_LIMIT "$IMAGE_ERR"

FAKE_GROKB_MODE=generic-limit
export FAKE_GROKB_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/generic-limit.jpg" --prompt portrait --account explicit || image_rc=$?
assert test "$image_rc" -eq 1

FAKE_GROKB_MODE=pool
export FAKE_GROKB_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/pool.jpg" --prompt portrait --account explicit || image_rc=$?
assert test "$image_rc" -eq 4
assert grep -q 'refused by the worker pool' "$IMAGE_ERR"

FAKE_GROKB_MODE=no-image
export FAKE_GROKB_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/no-image.jpg" --prompt portrait --account explicit || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'no ImageGen event' "$IMAGE_ERR"

FAKE_GROKB_MODE=image
PICK_MODE=limit
export FAKE_GROKB_MODE PICK_MODE
: >"$FAKE_GROKB_CALLS"
image_rc=0
image_run --dest "$OUTPUT_DIR/pick-limit.jpg" --prompt portrait || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx GROK_USAGE_LIMIT "$IMAGE_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"

echo "PASS: $asserts asserts; routing and account pinning, exact Grok launch controls, verbatim ImageGen stream harvesting despite max-turns exit, byte-identical same-format delivery with alpha, differing-format conversion, transparent chroma path, persistent-only limit classification, pool refusal, missing ImageGen failure, worker-pick limit propagation, fake session preservation, and temp-cwd cleanup"
