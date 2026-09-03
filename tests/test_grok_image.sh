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
MAGICK_CALLS="$WORK/magick-calls"
REAL_MAGICK=$(command -v magick) || fail "magick is required for this suite"
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
GROK_PROFILES="$WORK/grok-profiles"
mkdir -p "$GROK_PROFILES/explicit" "$GROK_PROFILES/picked"
CLAIMS_DIR="$WORK/worker-claims"
image_run() {
  env PATH="${IMAGE_PATH:-$FAKE_BIN:$PATH}" TMPDIR="$TMP_ROOT" \
    GROKB_PROFILES_DIR="$GROK_PROFILES" WORKER_CLAIMS_DIR="$CLAIMS_DIR" \
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

# A generation is billed the moment it is sent, so everything the arguments alone can refuse is
# refused before anything goes out — the proof is that the CLI was never called.
: >"$FAKE_GROKB_CALLS"
for bad_dest in "$OUTPUT_DIR/noext" "$OUTPUT_DIR/trailing."; do
  image_rc=0
  image_run --dest "$bad_dest" --prompt badge || image_rc=$?
  assert test "$image_rc" -eq 2
  assert grep -q '^usage: grok-image ' "$IMAGE_ERR"
done
# The chroma path writes alpha, which only a .png destination can hold.
image_rc=0
image_run --dest "$OUTPUT_DIR/flat.jpg" --prompt badge --transparent || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'requires a .png destination' "$IMAGE_ERR"
# More references than image_edit takes, a relative one and one that is not there.
image_rc=0
printf 'reference\n' >"$WORK/ref-a.jpg"
image_run --dest "$OUTPUT_DIR/many.png" --prompt badge \
  --ref "$WORK/ref-a.jpg" --ref "$WORK/ref-a.jpg" --ref "$WORK/ref-a.jpg" --ref "$WORK/ref-a.jpg" \
  || image_rc=$?
assert test "$image_rc" -eq 2
image_rc=0
image_run --dest "$OUTPUT_DIR/relref.png" --prompt badge --ref ref-a.jpg || image_rc=$?
assert test "$image_rc" -eq 2
image_rc=0
image_run --dest "$OUTPUT_DIR/missingref.png" --prompt badge --ref "$WORK/absent.jpg" || image_rc=$?
assert test "$image_rc" -eq 2
# `grokb profile` CREATES an unknown name, so a name the pattern refuses may never reach it.
image_rc=0
image_run --dest "$OUTPUT_DIR/badacct.png" --prompt badge --account 'Ghost Acct' || image_rc=$?
assert test "$image_rc" -eq 2
assert test ! -s "$FAKE_GROKB_CALLS"
# A well-formed name that is on no roster creates just as surely: a typo would leave a permanent
# ghost profile behind, asking for a login in grokb list and in the menu.
image_rc=0
image_run --dest "$OUTPUT_DIR/ghostacct.png" --prompt badge --account ghostacct || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'account directory does not exist' "$IMAGE_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"
assert test ! -e "$GROK_PROFILES/ghostacct"
# The conversion tool is checked before the spend, not after it. The stub is not enough here: the
# script's own probe would find the real binary further down the inherited PATH.
mv "$FAKE_BIN/magick" "$WORK/magick-away"
image_rc=0
IMAGE_PATH="$FAKE_BIN:/usr/bin:/bin" \
  image_run --dest "$OUTPUT_DIR/nomagick.png" --prompt badge --account explicit || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'magick is required' "$IMAGE_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"
mv "$WORK/magick-away" "$FAKE_BIN/magick"

# A worker-pick failure that is not a wall may not be reported as one: callers reroute off exit 3
# as if the account's quota were spent.
PICK_MODE=fail
export PICK_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/pickfail.png" --prompt badge || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'worker-pick failed' "$IMAGE_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"
PICK_MODE=ok
export PICK_MODE

# A claim de-prioritises the account it names for ten minutes, so it is not spent on an account
# whose profile this run cannot launch at all.
PICK_ACCOUNT=ghostpick
export PICK_ACCOUNT
image_rc=0
image_run --dest "$OUTPUT_DIR/ghost.png" --prompt badge || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'account directory does not exist' "$IMAGE_ERR"
assert test ! -e "$CLAIMS_DIR/grok/ghostpick"
assert test ! -s "$FAKE_GROKB_CALLS"
PICK_ACCOUNT=picked
export PICK_ACCOUNT

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
# image_gen is not on offer for a reference run: it takes neither 4:3 nor 3:4, and a model that
# reached for it would spend the generation on a ratio the gate exists to keep off the wire.
assert grep -qx 'ARG=image_edit' "$FAKE_GROKB_CALLS"
assert_fails grep -qx 'ARG=image_gen,image_edit' "$FAKE_GROKB_CALLS"

: >"$FAKE_GROKB_CALLS"
: >"$PICK_CALLS"
: >"$MAGICK_CALLS"
FAKE_GROKB_IMAGE_FORMAT=png
assert image_run --dest "$OUTPUT_DIR/generated.png" --prompt 'flat blue square on white' --aspect 1:1
assert cmp "$FAKE_GROKB_SESSION_ROOT/fake-session/images/1.png" "$OUTPUT_DIR/generated.png"
assert test "$(sips -g format "$OUTPUT_DIR/generated.png" | awk '/format:/ {print $2}')" = png
assert test "$(sips -g hasAlpha "$OUTPUT_DIR/generated.png" | awk '/hasAlpha:/ {print $2}')" = yes
assert test ! -s "$MAGICK_CALLS"
# The claim is taken after the account has proved usable, not by the pick itself.
assert grep -qx -- '--account grok' "$PICK_CALLS"
assert test -e "$CLAIMS_DIR/grok/picked"
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
assert grep -qx 'ARG=image_edit' "$FAKE_GROKB_CALLS"
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
# This is the repo's only exercise of share/image-chroma.sh, and a composite flattened to an opaque
# PNG would keep every other assertion here green while the flag's whole purpose is gone.
assert test "$(sips -g hasAlpha "$OUTPUT_DIR/transparent.png" | awk '/hasAlpha:/ {print $2}')" = yes

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

# An image script is not a relay of its own: whatever it writes is journaled by the agent that ran
# it, so the one thing it owes the review ledger is to pass the launching chat's stamp THROUGH to
# every process it starts. Scrubbed here, an asset a worker generated is an edit no chat owns.
FAKE_GROKB_MODE=image
PICK_MODE=ok
export FAKE_GROKB_MODE PICK_MODE
: >"$FAKE_GROKB_CALLS"
image_rc=0
CLAUDE_LAUNCHER_SESSION=image-launching-chat \
  image_run --dest "$OUTPUT_DIR/stamped.jpg" --prompt portrait --account explicit || image_rc=$?
assert test "$image_rc" -eq 0
assert grep -qx 'CLAUDE_LAUNCHER_SESSION=image-launching-chat' "$FAKE_GROKB_CALLS"

echo "PASS: $asserts asserts; routing and account pinning, exact Grok launch controls, verbatim ImageGen stream harvesting despite max-turns exit, byte-identical same-format delivery with alpha, differing-format conversion, transparent chroma path, persistent-only limit classification, pool refusal, missing ImageGen failure, worker-pick limit propagation, fake session preservation, temp-cwd cleanup, and the launching chat's stamp passed through to the CLI it starts"
