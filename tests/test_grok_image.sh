#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFIED_CLI=$(jq -r .cli.version "$ROOT/share/image-caps/grok.json")
SCRIPT="$ROOT/bin/grok-image"
FIXTURE="$ROOT/tests/fixtures/fake-grokb-image.sh"
WORK="$(mktemp -d)"
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
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

cat >"$FAKE_BIN/grok" <<'EOF'
#!/usr/bin/env bash
printf 'grok %s (5e9a58528b76) [alpha]\n' "${FAKE_GROK_VERSION:?}"
EOF
chmod +x "$FAKE_BIN/grok"

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
MAIN_GROK_HOME="$WORK/grok-main"
SESSION_UUID=01a058dd-9d01-7ee3-8e4a-fdfda5426483
image_run() {
  env PATH="${IMAGE_PATH:-$FAKE_BIN:$PATH}" TMPDIR="$TMP_ROOT" \
    GROKB_PROFILES_DIR="$GROK_PROFILES" WORKER_CLAIMS_DIR="$CLAIMS_DIR" \
    GROKB_GROK_BIN="$FAKE_BIN/grok" GROKB_MAIN_GROK_HOME="$MAIN_GROK_HOME" \
    FAKE_GROK_VERSION="${FAKE_GROK_VERSION:-$VERIFIED_CLI}" \
    GROK_IMAGE_GROKB="$FIXTURE" GROK_IMAGE_WORKER_PICK="$FAKE_BIN/worker-pick" \
    FAKE_GROKB_MODE="${FAKE_GROKB_MODE:-image}" PICK_MODE="${PICK_MODE:-ok}" \
    PICK_ACCOUNT="${PICK_ACCOUNT:-picked}" FAKE_GROKB_IMAGE_FORMAT="${FAKE_GROKB_IMAGE_FORMAT:-jpg}" \
    FAKE_GROKB_OUTPUT_TYPE="${FAKE_GROKB_OUTPUT_TYPE:-ImageGen}" \
    FAKE_GROKB_SESSION_ID="${FAKE_GROKB_SESSION_ID:-$SESSION_UUID}" \
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
# The reference cap is the manifest's, never a literal in the script or in this suite: one more
# than it is refused, exactly it is sent. A suite that hard-coded the number would keep passing
# while the two drifted apart.
MANIFEST="$ROOT/share/image-caps/grok.json"
REFS_MAX=$(jq -r '.refs.max' "$MANIFEST")
assert test "$REFS_MAX" -ge 3
printf 'reference\n' >"$WORK/ref-a.jpg"
over_cap=()
for ((i = 0; i <= REFS_MAX; i++)); do over_cap+=(--ref "$WORK/ref-a.jpg"); done
image_rc=0
image_run --dest "$OUTPUT_DIR/many.png" --prompt badge "${over_cap[@]}" || image_rc=$?
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
# Exactly the manifest's cap goes out whole: the three-reference ceiling this script used to
# enforce was its own, not the vendor's.
: >"$FAKE_GROKB_CALLS"
at_cap=()
for ((i = 0; i < REFS_MAX; i++)); do at_cap+=(--ref "$WORK/ref-a.jpg"); done
assert image_run --dest "$OUTPUT_DIR/atcap.jpg" --prompt badge --account explicit "${at_cap[@]}"
assert test "$(grep -c "^- $WORK/ref-a.jpg$" "$FAKE_GROKB_PROMPT")" -eq "$REFS_MAX"

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

# The whole image_edit list, straight from the manifest: the exotic ratios are exactly the ones a
# hand-written enum drops, and `auto` is what an unrequested size means on both tools.
while IFS= read -r edit_aspect; do
  : >"$FAKE_GROKB_PROMPT"
  assert image_run --dest "$OUTPUT_DIR/exotic.jpg" --prompt 'make the badge blue' \
    --aspect "$edit_aspect" --ref "$WORK/aspect-reference.jpg" --account explicit
  assert grep -qF "Aspect ratio: $edit_aspect" "$FAKE_GROKB_PROMPT"
done < <(jq -r '.aspects.edit[]' "$MANIFEST")
while IFS= read -r gen_aspect; do
  : >"$FAKE_GROKB_PROMPT"
  assert image_run --dest "$OUTPUT_DIR/gen.jpg" --prompt badge --aspect "$gen_aspect" --account explicit
  assert grep -qF "Aspect ratio: $gen_aspect" "$FAKE_GROKB_PROMPT"
done < <(jq -r '.aspects.generate[]' "$MANIFEST")
: >"$FAKE_GROKB_PROMPT"
assert image_run --dest "$OUTPUT_DIR/defaultgen.jpg" --prompt badge --account explicit
assert grep -qF "Aspect ratio: $(jq -r '.aspects.default' "$MANIFEST")" "$FAKE_GROKB_PROMPT"

# image_edit answers under its own ToolOutput tag, not image_gen's. A harvester that matched
# ImageGen alone would read every real edit as a run that produced nothing and bill it twice.
FAKE_GROKB_OUTPUT_TYPE=ImageEdit
export FAKE_GROKB_OUTPUT_TYPE
assert image_run --dest "$OUTPUT_DIR/editvariant.jpg" --prompt 'make the badge blue' \
  --ref "$WORK/aspect-reference.jpg" --account explicit
assert cmp "$FAKE_GROKB_SESSION_ROOT/fake-session/images/1.jpg" "$OUTPUT_DIR/editvariant.jpg"
FAKE_GROKB_OUTPUT_TYPE=ImageGen
export FAKE_GROKB_OUTPUT_TYPE

# --resume names a session, and a session lives in exactly one profile's store: the account is
# recovered from the store that holds it, so no selector runs and no claim is spent.
RESUMED_SESSION=$SESSION_UUID
mkdir -p "$GROK_PROFILES/explicit/sessions/%2Ftmp%2Fwork/$RESUMED_SESSION"
: >"$FAKE_GROKB_CALLS"
: >"$PICK_CALLS"
: >"$FAKE_GROKB_PROMPT"
assert image_run --dest "$OUTPUT_DIR/resumed.jpg" --prompt 'now make it bluer' --resume "$RESUMED_SESSION"
assert test ! -s "$PICK_CALLS"
assert grep -qx 'ARG=--resume' "$FAKE_GROKB_CALLS"
assert grep -qx "ARG=$RESUMED_SESSION" "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=explicit' "$FAKE_GROKB_CALLS"
assert grep -qx 'ARG=image_edit' "$FAKE_GROKB_CALLS"
assert grep -qx 'account=explicit' "$IMAGE_OUT"
assert grep -q 'image you produced most recently in this session' "$FAKE_GROKB_PROMPT"
# A resumed run is an edit even with no --ref, so image_edit's wider ratio list applies to it.
assert image_run --dest "$OUTPUT_DIR/resumedwide.jpg" --prompt bluer --aspect 20:9 --resume "$RESUMED_SESSION"
# A session id no store holds cannot be routed by guessing an account.
: >"$FAKE_GROKB_CALLS"
image_rc=0
image_run --dest "$OUTPUT_DIR/orphan.jpg" --prompt bluer \
  --resume 01a05000-0000-7000-8000-000000000000 || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'no account holds session' "$IMAGE_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"
# Grok reads a non-UUID resume value as a session TITLE scoped to the current directory, and this
# script's cwd is a fresh temp dir that owns no sessions: it would resolve to nothing or to a
# stranger's session, after the spend.
image_rc=0
image_run --dest "$OUTPUT_DIR/badresume.jpg" --prompt bluer --resume 'my session' || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'session UUID printed as session=' "$IMAGE_ERR"
assert test ! -s "$FAKE_GROKB_CALLS"

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
assert grep -qx -- '--account grok --role image' "$PICK_CALLS"
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
# The footer is the shared image-script contract: the four keys existing consumers already read,
# in their old positions, then session, model and caps.
assert test "$(cut -d= -f1 "$IMAGE_OUT" | tr '\n' ' ')" = 'dest size format account session model caps '
assert grep -qx "session=$SESSION_UUID" "$IMAGE_OUT"
assert grep -qx "model=$(jq -r '.model.image' "$MANIFEST") model_caps=fresh" "$IMAGE_OUT"
assert grep -qx 'caps=fresh' "$IMAGE_OUT"
assert test -z "$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -name 'grok-image.*' -print -quit)"

# A CLI other than the verified one may promise the wrong limits, and the model id it would send
# is no longer knowable either: both say so rather than repeating the manifest.
FAKE_GROK_VERSION=9.9.9
export FAKE_GROK_VERSION
assert image_run --dest "$OUTPUT_DIR/staleversion.jpg" --prompt badge --account explicit
assert grep -qx "caps=stale cli=9.9.9 verified=$(jq -r '.cli.version' "$MANIFEST")" "$IMAGE_OUT"
assert grep -qx 'model=unknown model_caps=unknown' "$IMAGE_OUT"
FAKE_GROK_VERSION=$VERIFIED_CLI
export FAKE_GROK_VERSION

# The manifest's model is pinned into the account's config.toml before the launch: a missing table
# is added, a different pin replaced, everything else kept, and an equal pin never rewritten. Both
# tool knobs carry it, the edit one included — an unpinned edit runs on the compiled-in default.
manifest_model=$(jq -r '.model.image' "$MANIFEST")
explicit_config="$GROK_PROFILES/explicit/config.toml"
printf 'model = "grok-4.7"\n\n[ui]\ntheme = "dark"\n' >"$explicit_config"
assert image_run --dest "$OUTPUT_DIR/pinmissing.jpg" --prompt badge --account explicit
assert test "$(cat "$explicit_config")" = "$(printf 'model = "grok-4.7"\n\n[ui]\ntheme = "dark"\n\n[features]\nimage_edit_model_override = "%s"\nimage_gen_model_override = "%s"' "$manifest_model" "$manifest_model")"
assert grep -qx "model=$manifest_model model_caps=fresh" "$IMAGE_OUT"
printf '[features]\nimage_gen_model_override = "grok-imagine-image-fast"\nimage_edit_model_override = "grok-imagine-image-quality"\n[ui]\ntheme = "dark"\n' >"$explicit_config"
assert image_run --dest "$OUTPUT_DIR/pindifferent.jpg" --prompt badge --account explicit
assert test "$(cat "$explicit_config")" = "$(printf '[features]\nimage_gen_model_override = "%s"\nimage_edit_model_override = "%s"\n[ui]\ntheme = "dark"' "$manifest_model" "$manifest_model")"
assert grep -qx "model=$manifest_model model_caps=fresh" "$IMAGE_OUT"
touch -t 202001010000 "$explicit_config"
pin_mtime=$(stat -f %m "$explicit_config")
assert image_run --dest "$OUTPUT_DIR/pinequal.jpg" --prompt badge --account explicit
assert test "$(stat -f %m "$explicit_config")" = "$pin_mtime"
rm -f "$explicit_config"

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
# An edit reads the edit knob, so the run reports the manifest model rather than `unknown`.
assert test "$(cat "$explicit_config")" = "$(printf '[features]\nimage_edit_model_override = "%s"\nimage_gen_model_override = "%s"' "$manifest_model" "$manifest_model")"
assert grep -qx "model=$manifest_model model_caps=fresh" "$IMAGE_OUT"

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
assert test "$(tail -n1 "$IMAGE_LEG_LOG" | jq -r '"\(.tool) \(.kind) \(.rc) \(.account)"')" = 'grok-image image 3 explicit'

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
# llm-doctor reads the failure's own words off the image-leg log, so the row must carry stderr.
assert grep -q 'no ImageGen event' <(tail -n1 "$IMAGE_LEG_LOG" | jq -r '.err')

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


# Tripwire: the compiled-in default `grok-imagine-image-quality` retires 2026-11-02 and is then served as
# `grok-imagine-image-2.0` at quality low (docs.x.ai migration notice). From that day the manifest's
# model.image note, which pins the override because of that retirement, must be re-verified.
asserts=$((asserts + 1))
if [ "$(date -u +%Y%m%d)" -ge 20261102 ] &&
   jq -e '.field_sources["model.image"] | contains("retires 2026-11-02")' "$MANIFEST" >/dev/null; then
  fail "grok-imagine-image-quality retired 2026-11-02: re-verify share/image-caps/grok.json model.image (docs/vendor-release.md)"
fi
echo "PASS: $asserts asserts; routing and account pinning, exact Grok launch controls, manifest-driven aspect enums per tool with auto and the manifest ref cap, ImageGen and ImageEdit stream harvesting despite max-turns exit, byte-identical same-format delivery with alpha, differing-format conversion, transparent chroma path, persistent-only limit classification, pool refusal, missing ImageGen failure, worker-pick limit propagation, --resume routed to image_edit through the store that holds the session without worker-pick, the seven-line footer with model and caps freshness, one image-leg log row per run with its status and stderr, fake session preservation, temp-cwd cleanup, and the launching chat's stamp passed through to the CLI it starts"
