#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/codex-image"
FIXTURE="$ROOT/tests/fixtures/fake-codex-image.sh"
. "$ROOT/tests/fixtures/codexb-models.sh"
arg_after() { grep -A1 -x -- "ARG=$1" "$FAKE_CODEX_CALLS" | grep -qx -- "ARG=$2"; }
WORK="$(mktemp -d)"
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
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
FAKE_HOME="$WORK/home"
CODEX_PROFILES="$WORK/codex-profiles"
FAKE_CODEX_CALLS="$WORK/codex-calls"
FAKE_CODEX_PROMPT="$WORK/codex-prompt"
PICK_CALLS="$WORK/worker-pick-calls"
MAGICK_CALLS="$WORK/magick-calls"
REAL_MAGICK=$(command -v magick) || fail "magick is required for this suite"
export FAKE_CODEX_CALLS FAKE_CODEX_PROMPT PICK_CALLS MAGICK_CALLS REAL_MAGICK
mkdir -p "$FAKE_BIN" "$OUTPUT_DIR" "$TMP_ROOT" "$FAKE_HOME/.claude" \
  "$CODEX_PROFILES/explicit" "$CODEX_PROFILES/picked" "$CODEX_PROFILES/other" \
  "$CODEX_PROFILES/fresh"
: >"$FAKE_CODEX_CALLS"
: >"$FAKE_CODEX_PROMPT"
: >"$PICK_CALLS"
: >"$MAGICK_CALLS"
: >"$FAKE_HOME/.claude/worker-model"

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
CLAIMS_DIR="$WORK/worker-claims"
manifest_value() { jq -r "$1" "$ROOT/share/image-caps/codex.json"; }
VERIFIED_CLI=$(manifest_value '.cli.version')
image_run() {
  env PATH="${IMAGE_PATH:-$FAKE_BIN:$PATH}" TMPDIR="$TMP_ROOT" HOME="$FAKE_HOME" \
    CODEX_PROFILES_DIR="$CODEX_PROFILES" CODEXB_PROFILES_DIR="$CODEX_PROFILES" \
    WORKER_CLAIMS_DIR="$CLAIMS_DIR" WORKER_PICK_CONFIG_FILE="$FAKE_HOME/.claude/worker-model" \
    CODEX_IMAGE_CODEX="$FIXTURE" \
    FAKE_CODEX_MODE="${FAKE_CODEX_MODE:-image}" PICK_MODE="${PICK_MODE:-ok}" \
    PICK_ACCOUNT="${PICK_ACCOUNT:-picked}" FAKE_CODEX_IMAGE_FORMAT="${FAKE_CODEX_IMAGE_FORMAT:-png}" \
    FAKE_CODEX_VERSION="${FAKE_CODEX_VERSION:-$VERIFIED_CLI}" \
    FAKE_CODEX_THREAD="${FAKE_CODEX_THREAD:-01a09aaa-1111-7000-8000-00000000000a}" \
    bash "$SCRIPT" "$@" >"$IMAGE_OUT" 2>"$IMAGE_ERR"
}

REF_MAX=$(manifest_value '.refs.max')
assert test "$REF_MAX" -ge 1
assert test "$(manifest_value '.transparent')" = native+chroma
assert grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' <<<"$VERIFIED_CLI"

image_rc=0
image_run --dest relative.png --prompt badge || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '^usage: codex-image ' "$IMAGE_ERR"
# The usage line quotes the manifest rather than a literal of its own, so a changed cap is stated
# where a caller reads it.
assert grep -q "references: at most $REF_MAX" "$IMAGE_ERR"

# A generation is billed the moment it is sent, so everything the arguments alone can refuse is
# refused before anything goes out — the proof is that the CLI was never called.
: >"$FAKE_CODEX_CALLS"
for bad_dest in "$OUTPUT_DIR/noext" "$OUTPUT_DIR/trailing."; do
  image_rc=0
  image_run --dest "$bad_dest" --prompt badge || image_rc=$?
  assert test "$image_rc" -eq 2
  assert grep -q '^usage: codex-image ' "$IMAGE_ERR"
done
image_rc=0
image_run --dest "$OUTPUT_DIR/badsize.png" --prompt badge --size 800 || image_rc=$?
assert test "$image_rc" -eq 2
# Alpha, native or keyed, only a .png destination can hold.
image_rc=0
image_run --dest "$OUTPUT_DIR/flat.jpg" --prompt badge --transparent || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'requires a .png destination' "$IMAGE_ERR"

# One reference over the manifest's cap: the imagegen tool refuses the call itself, so the whole
# run would be spent to be told so.
refs=()
for index in $(seq 1 $((REF_MAX + 1))); do
  printf 'reference\n' >"$WORK/ref-$index.png"
  refs+=(--ref "$WORK/ref-$index.png")
done
image_rc=0
image_run --dest "$OUTPUT_DIR/many.png" --prompt badge "${refs[@]}" || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q "references exceed the $REF_MAX" "$IMAGE_ERR"
image_rc=0
image_run --dest "$OUTPUT_DIR/relref.png" --prompt badge --ref ref-1.png || image_rc=$?
assert test "$image_rc" -eq 2
image_rc=0
image_run --dest "$OUTPUT_DIR/missingref.png" --prompt badge --ref "$WORK/absent.png" || image_rc=$?
assert test "$image_rc" -eq 2
image_rc=0
image_run --dest "$OUTPUT_DIR/badacct.png" --prompt badge --account 'Ghost Acct' || image_rc=$?
assert test "$image_rc" -eq 2
# A thread NAME resumes in the CLI but cannot be traced back to the account holding it, and the
# session ids this script prints are always UUIDs.
image_rc=0
image_run --dest "$OUTPUT_DIR/badresume.png" --prompt badge --resume my-thread-name || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'takes the session UUID' "$IMAGE_ERR"
assert test ! -s "$FAKE_CODEX_CALLS"

image_rc=0
image_run --dest "$OUTPUT_DIR/ghostacct.png" --prompt badge --account ghostacct || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'account directory does not exist' "$IMAGE_ERR"
assert test ! -s "$FAKE_CODEX_CALLS"
assert test ! -e "$CODEX_PROFILES/ghostacct"

# The conversion tool is checked before the spend, not after it. The stub is not enough here: the
# script's own probe would find the real binary further down the inherited PATH.
mv "$FAKE_BIN/magick" "$WORK/magick-away"
image_rc=0
IMAGE_PATH="$FAKE_BIN:/usr/bin:/bin" \
  image_run --dest "$OUTPUT_DIR/nomagick.png" --prompt badge --account explicit || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'magick is required' "$IMAGE_ERR"
assert test ! -s "$FAKE_CODEX_CALLS"
mv "$WORK/magick-away" "$FAKE_BIN/magick"

# A claim de-prioritises the account it names for ten minutes, so it is not spent on an account
# whose profile this run cannot launch at all.
PICK_ACCOUNT=ghostpick
export PICK_ACCOUNT
image_rc=0
image_run --dest "$OUTPUT_DIR/ghost.png" --prompt badge || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'account directory does not exist' "$IMAGE_ERR"
assert test ! -e "$CLAIMS_DIR/codex/ghostpick"
assert test ! -s "$FAKE_CODEX_CALLS"
PICK_ACCOUNT=picked
export PICK_ACCOUNT

: >"$FAKE_CODEX_CALLS"
: >"$PICK_CALLS"
: >"$MAGICK_CALLS"
assert image_run --dest "$OUTPUT_DIR/generated.png" --prompt 'flat blue circle on green' --size 640x480
THREAD=01a09aaa-1111-7000-8000-00000000000a
assert cmp "$CODEX_PROFILES/picked/generated_images/$THREAD/exec-fixture.png" "$OUTPUT_DIR/generated.png"
assert test ! -s "$MAGICK_CALLS"
# The claim is taken after the account has proved usable, not by the pick itself.
assert grep -qx -- '--account codex --role image' "$PICK_CALLS"
assert test -e "$CLAIMS_DIR/codex/picked"
assert grep -qx 'ARG=exec' "$FAKE_CODEX_CALLS"
assert grep -qx 'ARG=--skip-git-repo-check' "$FAKE_CODEX_CALLS"
# The session id rides on the JSONL stream and nowhere else, so the flag that turns it on is not
# optional: dropped, every run reports session=none and no caller can resume one.
assert grep -qx 'ARG=--experimental-json' "$FAKE_CODEX_CALLS"
assert grep -qx 'ARG=-o' "$FAKE_CODEX_CALLS"
assert arg_after --disable fast_mode
assert grep -qx 'ARG=service_tier="default"' "$FAKE_CODEX_CALLS"
# The model is the table family's newest listed slug, not whatever a profile's config.toml names.
assert arg_after -m gpt-6.1-astra
assert grep -qx "CODEX_HOME=$CODEX_PROFILES/picked" "$FAKE_CODEX_CALLS"
assert_fails grep -qx 'ARG=resume' "$FAKE_CODEX_CALLS"
assert grep -q 'built-in image_gen tool' "$FAKE_CODEX_PROMPT"
assert grep -q 'flat blue circle on green' "$FAKE_CODEX_PROMPT"
assert grep -q 'exact size 640x480' "$FAKE_CODEX_PROMPT"
# The final block is a contract: existing consumers read the first four lines by position.
assert test "$(sed -n 1p "$IMAGE_OUT")" = "dest=$OUTPUT_DIR/generated.png"
assert test "$(sed -n 2p "$IMAGE_OUT")" = 'size=64x64'
assert test "$(sed -n 3p "$IMAGE_OUT")" = 'format=png'
assert test "$(sed -n 4p "$IMAGE_OUT")" = 'account=picked'
assert test "$(sed -n 5p "$IMAGE_OUT")" = "session=$THREAD"
# A PNG without a C2PA softwareAgent says unknown rather than echoing the manifest back.
assert test "$(sed -n 6p "$IMAGE_OUT")" = 'model=unknown model_caps=unknown'
assert test "$(sed -n 7p "$IMAGE_OUT")" = 'caps=fresh'
assert test "$(wc -l <"$IMAGE_OUT")" -eq 7
assert test -z "$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -name 'codex-image.*' -print -quit)"

# The model names itself in the PNG's C2PA softwareAgent; `2.0` is the manifest's `gpt-image-2`.
export FAKE_CODEX_AGENT_VERSION=2.0
assert image_run --dest "$OUTPUT_DIR/agent.png" --prompt badge --account explicit
assert grep -qx 'model=gpt-image-2 model_caps=fresh' "$IMAGE_OUT"
FAKE_CODEX_AGENT_VERSION=2.5
assert image_run --dest "$OUTPUT_DIR/agent25.png" --prompt badge --account explicit
assert grep -qx 'model=gpt-image-2.5 model_caps=stale verified=gpt-image-2' "$IMAGE_OUT"
# The live shape since cli 0.156.1: the product in `name`, the unversioned family in `version`.
FAKE_CODEX_AGENT_VERSION=gpt-image FAKE_CODEX_AGENT_NAME=ChatGPT \
  assert image_run --dest "$OUTPUT_DIR/agent-live.png" --prompt badge --account explicit
assert grep -qx 'model=gpt-image model_caps=unknown verified=gpt-image-2' "$IMAGE_OUT"
FAKE_CODEX_AGENT_VERSION=gpt-image-2.5 FAKE_CODEX_AGENT_NAME=ChatGPT \
  assert image_run --dest "$OUTPUT_DIR/agent-live25.png" --prompt badge --account explicit
assert grep -qx 'model=gpt-image-2.5 model_caps=stale verified=gpt-image-2' "$IMAGE_OUT"
unset FAKE_CODEX_AGENT_VERSION

# The tool schema lives in the binary, so a CLI other than the verified one may promise the wrong
# limits — said out loud, never fatal.
FAKE_CODEX_VERSION=999.0.0
export FAKE_CODEX_VERSION
FAKE_CODEX_THREAD=01a09bbb-2222-7000-8000-00000000000b
export FAKE_CODEX_THREAD
assert image_run --dest "$OUTPUT_DIR/stale.png" --prompt badge --account explicit
assert grep -qx "caps=stale cli=999.0.0 verified=$VERIFIED_CLI" "$IMAGE_OUT"
FAKE_CODEX_VERSION=$VERIFIED_CLI
export FAKE_CODEX_VERSION
FAKE_CODEX_THREAD=01a09aaa-1111-7000-8000-00000000000a
export FAKE_CODEX_THREAD

: >"$MAGICK_CALLS"
FAKE_CODEX_IMAGE_FORMAT=jpg
export FAKE_CODEX_IMAGE_FORMAT
assert image_run --dest "$OUTPUT_DIR/converted.png" --prompt badge --account explicit
assert test "$(sips -g format "$OUTPUT_DIR/converted.png" | awk '/format:/ {print $2}')" = png
assert grep -Fq "$CODEX_PROFILES/explicit/generated_images/$THREAD/exec-fixture.jpg $OUTPUT_DIR/converted.png" \
  "$MAGICK_CALLS"
FAKE_CODEX_IMAGE_FORMAT=png
export FAKE_CODEX_IMAGE_FORMAT

# References are an INSTRUCTION, not a bullet list the model may read as background: the built-in
# tool edits local files only through referenced_image_paths, and only after view_image has put
# them in context.
: >"$FAKE_CODEX_CALLS"
: >"$PICK_CALLS"
printf 'reference\n' >"$WORK/reference.png"
assert image_run --dest "$OUTPUT_DIR/edited.png" --prompt 'make the badge blue' \
  --ref "$WORK/reference.png" --account explicit
assert test ! -s "$PICK_CALLS"
assert grep -q 'call view_image on each path below first' "$FAKE_CODEX_PROMPT"
assert grep -q 'referenced_image_paths' "$FAKE_CODEX_PROMPT"
assert grep -q 'leave num_last_images_to_include unset' "$FAKE_CODEX_PROMPT"
assert grep -qx -- "- $WORK/reference.png" "$FAKE_CODEX_PROMPT"

# Native transparency first: the request keeps every word the caller wrote — the word the
# chroma-only vendors have to strip is the very thing this tool is being asked for.
: >"$MAGICK_CALLS"
FAKE_CODEX_IMAGE_FORMAT=rgba
export FAKE_CODEX_IMAGE_FORMAT
assert image_run --dest "$OUTPUT_DIR/native.png" \
  --prompt 'transparent green badge' --transparent --account explicit
assert grep -q 'transparent green badge' "$FAKE_CODEX_PROMPT"
assert grep -q 'genuinely transparent background' "$FAKE_CODEX_PROMPT"
assert grep -q 'Only if real transparency is impossible' "$FAKE_CODEX_PROMPT"
assert test "$(sips -g hasAlpha "$OUTPUT_DIR/native.png" | awk '/hasAlpha:/ {print $2}')" = yes
assert cmp "$CODEX_PROFILES/explicit/generated_images/$THREAD/exec-fixture.png" "$OUTPUT_DIR/native.png"
# A generation that already carries alpha is delivered as it is; keying it would eat the subject.
assert_fails grep -q -- '-alpha extract -morphology EdgeIn Octagon:2' "$MAGICK_CALLS"

# The tool answered without alpha, on the flat key colour the prompt ordered as the fallback.
: >"$MAGICK_CALLS"
FAKE_CODEX_IMAGE_FORMAT=opaque
export FAKE_CODEX_IMAGE_FORMAT
assert image_run --dest "$OUTPUT_DIR/keyed.png" \
  --prompt 'transparent green badge' --transparent --account explicit
assert grep -q -- '-alpha extract -morphology EdgeIn Octagon:2' "$MAGICK_CALLS"
assert test "$(sips -g format "$OUTPUT_DIR/keyed.png" | awk '/format:/ {print $2}')" = png
# A composite flattened to an opaque PNG would keep every other assertion here green while the
# flag's whole purpose is gone.
assert test "$(sips -g hasAlpha "$OUTPUT_DIR/keyed.png" | awk '/hasAlpha:/ {print $2}')" = yes

# An alpha CHANNEL is not transparency: gpt-image answers a transparency request with a PNG32
# whose alpha is uniformly opaque often enough that trusting the channel alone would deliver a
# flat image under the flag, and the green the prompt ordered as the fallback is right there.
: >"$MAGICK_CALLS"
FAKE_CODEX_IMAGE_FORMAT=alpha-opaque
export FAKE_CODEX_IMAGE_FORMAT
assert image_run --dest "$OUTPUT_DIR/opaque-alpha.png" \
  --prompt 'transparent green badge' --transparent --account explicit
assert grep -q -- '-alpha extract -morphology EdgeIn Octagon:2' "$MAGICK_CALLS"
assert awk -v value="$(magick "$OUTPUT_DIR/opaque-alpha.png" -alpha extract -format '%[fx:minima]' info:)" \
  'BEGIN { exit !(value + 0 < 0.99) }'
FAKE_CODEX_IMAGE_FORMAT=png
export FAKE_CODEX_IMAGE_FORMAT

# Multi-turn editing. The account is recovered from the store that holds the session, never routed
# for: a resume on the wrong CODEX_HOME finds no thread and starts a new one instead.
RESUME_ID=01a09ccc-3333-7000-8000-00000000000c
mkdir -p "$CODEX_PROFILES/other/sessions/2026/09/11"
: >"$CODEX_PROFILES/other/sessions/2026/09/11/rollout-2026-09-11T00-00-00-$RESUME_ID.jsonl"
: >"$FAKE_CODEX_CALLS"
: >"$PICK_CALLS"
assert image_run --dest "$OUTPUT_DIR/resumed.png" --prompt 'now make it bluer' --resume "$RESUME_ID"
assert test ! -s "$PICK_CALLS"
assert grep -qx 'ARG=resume' "$FAKE_CODEX_CALLS"
assert grep -qx "ARG=$RESUME_ID" "$FAKE_CODEX_CALLS"
assert_fails grep -qx 'ARG=-m' "$FAKE_CODEX_CALLS"
assert grep -qx "CODEX_HOME=$CODEX_PROFILES/other" "$FAKE_CODEX_CALLS"
assert grep -qx 'account=other' "$IMAGE_OUT"
assert grep -qx "session=$RESUME_ID" "$IMAGE_OUT"
# With no reference the edit target is the thread's own last image, which is what
# num_last_images_to_include names — referenced_image_paths would need a local path per target.
assert grep -q 'set num_last_images_to_include to 1' "$FAKE_CODEX_PROMPT"
assert_fails grep -q 'call view_image on each path below first' "$FAKE_CODEX_PROMPT"
# The subcommand goes after the options, which is the only order `codex exec [OPTIONS] <COMMAND>`
# accepts; taken from the argv the fixture recorded rather than from the script's own text.
assert test "$(grep -n 'ARG=--experimental-json' "$FAKE_CODEX_CALLS" | cut -d: -f1)" \
  -lt "$(grep -n 'ARG=resume' "$FAKE_CODEX_CALLS" | cut -d: -f1)"

# An id the store cannot resolve is answered by the CLI with a brand-new thread (openai/codex#15538),
# so the account is never guessed for it.
image_rc=0
image_run --dest "$OUTPUT_DIR/lost.png" --prompt 'bluer' \
  --resume 01a09fff-9999-7000-8000-00000000000f || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '0 accounts hold session' "$IMAGE_ERR"

# The same trap with an explicit account: the CLI answered with a thread that is not the one asked
# for, which is a resume that silently did not happen.
FAKE_CODEX_MODE=newthread
export FAKE_CODEX_MODE
assert image_run --dest "$OUTPUT_DIR/newthread.png" --prompt bluer \
  --resume "$RESUME_ID" --account other
assert grep -q "resume $RESUME_ID opened a new thread" "$IMAGE_ERR"
assert grep -qx 'session=01a09aaa-1111-7000-8000-00000000000a' "$IMAGE_OUT"
FAKE_CODEX_MODE=image
export FAKE_CODEX_MODE

# The last agent message is a cross-check, not the discovery: the built-in tool keys its output
# directory on the thread, so the harvested session finds the file the answer failed to name.
FAKE_CODEX_MODE=nopath
export FAKE_CODEX_MODE
assert image_run --dest "$OUTPUT_DIR/rescued.png" --prompt badge --account explicit
assert cmp "$CODEX_PROFILES/explicit/generated_images/$THREAD/exec-fixture.png" "$OUTPUT_DIR/rescued.png"

FAKE_CODEX_MODE=no-image
export FAKE_CODEX_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/no-image.png" --prompt badge --account fresh || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'generated file not found' "$IMAGE_ERR"

FAKE_CODEX_MODE=limit
export FAKE_CODEX_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/limit.png" --prompt badge --account explicit || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx CODEX_USAGE_LIMIT "$IMAGE_ERR"

FAKE_CODEX_MODE=fail
export FAKE_CODEX_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/fail.png" --prompt badge --account explicit || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'generation failed' "$IMAGE_ERR"

FAKE_CODEX_MODE=image
PICK_MODE=limit
export FAKE_CODEX_MODE PICK_MODE
: >"$FAKE_CODEX_CALLS"
image_rc=0
image_run --dest "$OUTPUT_DIR/pick-limit.png" --prompt badge || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx CODEX_USAGE_LIMIT "$IMAGE_ERR"
assert test ! -s "$FAKE_CODEX_CALLS"
PICK_MODE=ok
export PICK_MODE

# An image script is not a relay of its own: whatever it writes is journaled by the agent that ran
# it, so the one thing it owes the review ledger is to pass the launching chat's stamp THROUGH to
# every process it starts. Scrubbed here, an asset a worker generated is an edit no chat owns.
: >"$FAKE_CODEX_CALLS"
image_rc=0
CLAUDE_LAUNCHER_SESSION=image-launching-chat \
  image_run --dest "$OUTPUT_DIR/stamped.png" --prompt badge --account explicit || image_rc=$?
assert test "$image_rc" -eq 0
assert grep -qx 'CLAUDE_LAUNCHER_SESSION=image-launching-chat' "$FAKE_CODEX_CALLS"

echo "PASS: $asserts asserts; manifest-driven usage and reference cap, pre-spend argument refusals, routing and account pinning, exact codex exec launch controls with --experimental-json, the seven-line contract block including session/model/caps, caps staleness on a changed CLI, byte-identical same-format delivery, differing-format conversion, the view_image + referenced_image_paths reference instruction, native alpha kept unkeyed, chroma fallback on an opaque answer, resume account recovery from the session store, resume argv order, unresolvable and silently-new threads, thread-keyed output rescue, missing image, usage-limit and generic failure classification, worker-pick limit propagation, and the launching chat's stamp passed through"
