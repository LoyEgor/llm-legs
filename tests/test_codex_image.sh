#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
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
UV_CACHE_DIR=${UV_CACHE_DIR:-$(uv cache dir 2>/dev/null)}
export UV_CACHE_DIR
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
# The CLI route throughout; web is the default and its fallback has its own block at the end.
ROUTE_ARGS=(--route cli)
WEB_CALLS="$WORK/web-calls"
export WEB_CALLS
image_run() {
  env PATH="${IMAGE_PATH:-$FAKE_BIN:$PATH}" TMPDIR="$TMP_ROOT" HOME="$FAKE_HOME" \
    CODEX_IMAGE_WEB="$WORK/fake-web" \
    CODEX_PROFILES_DIR="$CODEX_PROFILES" CODEXB_PROFILES_DIR="$CODEX_PROFILES" \
    WORKER_CLAIMS_DIR="$CLAIMS_DIR" WORKER_PICK_CONFIG_FILE="$FAKE_HOME/.claude/worker-model" \
    CODEX_IMAGE_CODEX="$FIXTURE" \
    FAKE_CODEX_MODE="${FAKE_CODEX_MODE:-image}" PICK_MODE="${PICK_MODE:-ok}" \
    PICK_ACCOUNT="${PICK_ACCOUNT:-picked}" FAKE_CODEX_IMAGE_FORMAT="${FAKE_CODEX_IMAGE_FORMAT:-png}" \
    FAKE_CODEX_VERSION="${FAKE_CODEX_VERSION:-$VERIFIED_CLI}" \
    FAKE_CODEX_THREAD="${FAKE_CODEX_THREAD:-01a09aaa-1111-7000-8000-00000000000a}" \
    bash "$SCRIPT" ${ROUTE_ARGS[@]+"${ROUTE_ARGS[@]}"} "$@" >"$IMAGE_OUT" 2>"$IMAGE_ERR"
}
cat >"$WORK/fake-web" <<'EOF'
#!/usr/bin/env bash
{ printf 'JOB=%s\n' "${IMAGE_JOB_ID-unset}"; printf '%s\n' "$@"; } >"$WEB_CALLS"
dest='' count=1
while [ "$#" -gt 0 ]; do case "$1" in --dest) dest=$2; shift 2 ;; --count) count=$2; shift 2 ;; *) shift ;; esac; done
fail() { printf '{"ok": false, "reason": "%s", "account": "webacct"%s}\n' "$2" "$3"; exit "$1"; }
case "${WEB_MODE:-unset}" in
  takes | takes-limit)
    delivered=$count
    [ "$WEB_MODE" = takes ] || delivered=$((count - 1))
    takes=''
    for k in $(seq 1 "$delivered"); do
      path=$dest
      [ "$k" = 1 ] || path=$dest-$k
      "$REAL_MAGICK" -size $((60 + k))x64 "xc:#00FF0$k" "PNG24:$path"
      takes="$takes${takes:+,}{\"path\": \"$path\", \"chat\": \"0c0c0c0c-1111-4222-8333-94445555666$k\", \"bytes\": 9, \"format\": \"png\"}"
    done
    failures=''
    [ "$WEB_MODE" = takes ] || failures="{\"tab\": $count, \"code\": 3, \"reason\": \"ChatGPT image limit on webacct\"}"
    printf '{"ok": true, "account": "webacct", "chat": "0c0c0c0c-1111-4222-8333-944455556661", "count": %s, "takes": [%s], "failed": %s, "failures": [%s]}\n' \
      "$count" "$takes" "$((count - delivered))" "$failures"
    exit 0 ;;
  ok) "$REAL_MAGICK" -size 64x64 'xc:#00FF00' -fill blue -draw 'circle 32,32 32,22' "PNG24:$dest"
    printf '{"ok": true, "account": "webacct", "chat": "0c0c0c0c-1111-4222-8333-944455556666", "job": "%s", "phases": {"lock": 0.1, "browser": 1.5, "sent": 4}}\n' "$IMAGE_JOB_ID"
    exit 0 ;;
  signin) fail 4 'no ChatGPT account is signed in' ', "sent": false' ;;
  busy) fail 5 'every ChatGPT account is busy' ', "sent": false' ;;
  limit) fail 3 'ChatGPT image limit' ', "sent": false' ;;
  unsent) fail 1 'the composer never took the prompt' ', "sent": false' ;;
  sent) fail 1 'no image came back' ', "sent": true' ;;
  limit-sent) fail 3 'ChatGPT image limit after the prompt' ', "sent": true' ;;
  unknown) fail 1 'crashed' '' ;;
  refused) fail 1 'ChatGPT refused the image under its content policy' ', "sent": false' ;;
  *) printf 'the web engine ran with no WEB_MODE\n' >&2; exit 99 ;;
esac
EOF
chmod +x "$WORK/fake-web"

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

legs_before=$(wc -l <"$IMAGE_LEG_LOG")
wrappers=(codex-image gemini-image gemini-listen gemini-music gemini-sfx gemini-speech gemini-video grok-image grok-video)
for wrapper in "${wrappers[@]}"; do
  help_rc=0
  help_out=$(HOME="$FAKE_HOME" bash "$ROOT/bin/$wrapper" --help 2>/dev/null) || help_rc=$?
  assert test "$help_rc" -eq 0
  assert grep -q "^usage: $wrapper " <<<"$help_out"
  assert test "$(grep -v '^#' "$ROOT/bin/$wrapper" | head -n 1)" = '{'
  assert test "$(tail -n 2 "$ROOT/bin/$wrapper" | tr '\n' ' ')" = 'exit } '
done
assert test "$(wc -l <"$IMAGE_LEG_LOG")" -eq "$legs_before"

# I23: a refusal names its cause on the first stderr line, and the line reaches the leg log's err.
refusal_log="$WORK/refusal-legs.jsonl"
for wrapper in "${wrappers[@]}"; do
  case $wrapper in
    gemini-listen) dest_args=(-o /nonexistent-i23/out.txt question "$WORK/clip.mp3") folder_flag=-o ;;
    gemini-music) dest_args=(--dest /nonexistent-i23/out.mp3 --prompt tune) folder_flag=--dest ;;
    gemini-sfx) dest_args=(--dest /nonexistent-i23/out.wav --prompt thud) folder_flag=--dest ;;
    gemini-speech) dest_args=(--dest /nonexistent-i23/out.wav --text hello) folder_flag=--dest ;;
    *-video) dest_args=(--dest /nonexistent-i23/out.mp4 --prompt clip --ref "$WORK/clip.png") folder_flag=--dest ;;
    *) dest_args=(--dest /nonexistent-i23/out.png --prompt badge) folder_flag=--dest ;;
  esac
  for case_args in "--bogus-i23|unknown argument --bogus-i23" "DEST|$folder_flag folder /nonexistent-i23 does not exist"; do
    want="$wrapper: ${case_args#*|}"
    if [ "${case_args%%|*}" = DEST ]; then args=("${dest_args[@]}"); else args=("${case_args%%|*}"); fi
    : >"$refusal_log"
    refusal_rc=0
    refusal_err=$(IMAGE_LEG_LOG="$refusal_log" HOME="$FAKE_HOME" bash "$ROOT/bin/$wrapper" "${args[@]}" 2>&1 >/dev/null) ||
      refusal_rc=$?
    assert test "$refusal_rc" -eq 2
    assert test "$(head -n 1 <<<"$refusal_err")" = "$want"
    assert test "$(jq -r '.err | split("\n") | map(select(startswith("'"$wrapper"': "))) | first' "$refusal_log")" = "$want"
  done
  assert grep -q "^usage: $wrapper " <<<"$(HOME="$FAKE_HOME" bash "$ROOT/bin/$wrapper" --bogus-i23 2>&1)"
  assert_fails grep -nE '(^|[^-_[:alnum:]])usage[[:space:]]*(;|\)|$)' <(grep -vE 'usage\(\)|image_leg_help usage' "$ROOT/bin/$wrapper")
done

# 2026-10-02: a chat rewrote bin/codex-image in place while two legs ran, and both died on shifted
# bytes ("line 559: the: command not found"). The leg here is rewritten while its codex runs.
MIRROR="$WORK/mirror"
mkdir -p "$MIRROR/bin"
ln -s "$ROOT/share" "$MIRROR/share"
cp "$SCRIPT" "$MIRROR/bin/codex-image"
cat >"$WORK/slow-codex" <<EOF
#!/usr/bin/env bash
[ "\${1-}" = --version ] || { : >"$WORK/codex-started"; while [ ! -e "$WORK/wrapper-edited" ] && [ -d "$WORK" ]; do sleep 0.1; done; }
exec "$FIXTURE" "\$@"
EOF
chmod +x "$WORK/slow-codex"
SCRIPT="$MIRROR/bin/codex-image" FIXTURE="$WORK/slow-codex" \
  image_run --dest "$OUTPUT_DIR/edited-mid-run.png" --prompt badge --account explicit &
run_pid=$!
for _ in $(seq 600); do [ -e "$WORK/codex-started" ] && break; sleep 0.1; done
assert test -e "$WORK/codex-started"
yes 'exit 97' | head -n 20000 >"$MIRROR/bin/codex-image"
: >"$WORK/wrapper-edited"
run_rc=0
wait "$run_pid" || run_rc=$?
assert test "$run_rc" -eq 0
assert test -s "$OUTPUT_DIR/edited-mid-run.png"

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
for zero in 0x512 512x0; do
  image_rc=0
  image_run --dest "$OUTPUT_DIR/badsize.png" --prompt badge --size "$zero" || image_rc=$?
  assert test "$image_rc" -eq 2
done
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
image_rc=0
image_run --dest "$OUTPUT_DIR/emptyacct.png" --prompt badge --account "" || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q -- "--account needs a profile name" "$IMAGE_ERR"
assert test ! -s "$PICK_CALLS"
# A thread NAME resumes in the CLI but cannot be traced back to the account holding it, and the
# session ids this script prints are always UUIDs.
image_rc=0
image_run --dest "$OUTPUT_DIR/badresume.png" --prompt badge --resume my-thread-name || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'takes the session UUID' "$IMAGE_ERR"
assert test ! -s "$FAKE_CODEX_CALLS"

image_rc=0
image_run --dest "$OUTPUT_DIR/ghostacct.png" --prompt badge --account ghostacct || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'unknown account: ghostacct (not on the codex roster' "$IMAGE_ERR"
assert test ! -s "$FAKE_CODEX_CALLS"
assert test ! -e "$CODEX_PROFILES/ghostacct"
# Removing codex main writes its marker: main leaves the roster while ~/.codex stays on disk.
mkdir -p "$FAKE_HOME/.codex"
: >"$FAKE_HOME/.llm-limits-codex.json.removed"
image_rc=0
image_run --dest "$OUTPUT_DIR/removedmain.png" --prompt badge --account main || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'unknown account: main' "$IMAGE_ERR"
assert test ! -s "$FAKE_CODEX_CALLS"
rm -f "$FAKE_HOME/.llm-limits-codex.json.removed"

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
assert grep -q 'unknown account: ghostpick' "$IMAGE_ERR"
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
assert test -e "$WORK/media-starts/codex/picked"
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
assert grep -q 'Make the image exactly 640x480 pixels.' "$FAKE_CODEX_PROMPT"
# The final block is a contract: existing consumers read the first four lines by position.
assert test "$(sed -n 1p "$IMAGE_OUT")" = "dest=$OUTPUT_DIR/generated.png"
assert test "$(sed -n 2p "$IMAGE_OUT")" = 'size=64x64'
assert test "$(sed -n 3p "$IMAGE_OUT")" = 'format=png'
assert test "$(sed -n 4p "$IMAGE_OUT")" = 'account=picked'
assert test "$(sed -n 5p "$IMAGE_OUT")" = "session=$THREAD"
assert grep -Eqx 'job=codex-image-[0-9]{8}T[0-9]{6}Z-[0-9]+' <<<"$(sed -n 6p "$IMAGE_OUT")"
assert test "$(sed -n 7p "$IMAGE_OUT")" = 'route=cli'
# A PNG without a C2PA softwareAgent says unknown rather than echoing the manifest back.
assert test "$(sed -n 8p "$IMAGE_OUT")" = 'model=unknown model_caps=unknown'
assert test "$(sed -n 9p "$IMAGE_OUT")" = 'caps=fresh'
# A missed ratio is reported and delivered as generated, never cropped to fit; the lineage closes the block.
assert test "$(sed -n 10p "$IMAGE_OUT")" = 'aspect=4:3 achieved=1.000 fit=miss'
assert test "$(sed -n 11p "$IMAGE_OUT")" = 'composite=skipped reason=new-generation'
assert test "$(sed -n 12p "$IMAGE_OUT")" = "edit_depth=0 root=$OUTPUT_DIR/generated.png"
assert test "$(wc -l <"$IMAGE_OUT")" -eq 12
assert jq -se --arg job "$(sed -n 's/^job=//p' "$IMAGE_OUT")" '.[-1] | .job == $job and .route == "cli"
  and .requested == 1 and .delivered == 1 and .aspect == {asked: "4:3", achieved: 1, fit: "miss"}
  and .composite == {kind: "skipped", changed: null, reason: "new-generation"} and (has("phases") | not)' "$IMAGE_LEG_LOG" >/dev/null
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
assert grep -q 'transparent_background argument to true' "$FAKE_CODEX_PROMPT"
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
FAKE_CODEX_THREAD=$RESUME_ID assert image_run --dest "$OUTPUT_DIR/first.png" --prompt 'a badge' --account other
assert test "$(tail -n 1 "$IMAGE_OUT")" = "edit_depth=0 root=$OUTPUT_DIR/first.png"
: >"$FAKE_CODEX_CALLS"
: >"$PICK_CALLS"
rm -rf "$WORK/media-starts"
assert image_run --dest "$OUTPUT_DIR/resumed.png" --prompt 'now make it bluer' --resume "$RESUME_ID"
assert test ! -s "$PICK_CALLS"
assert grep -qx 'ARG=resume' "$FAKE_CODEX_CALLS"
assert grep -qx "ARG=$RESUME_ID" "$FAKE_CODEX_CALLS"
assert_fails grep -qx 'ARG=-m' "$FAKE_CODEX_CALLS"
assert grep -qx "CODEX_HOME=$CODEX_PROFILES/other" "$FAKE_CODEX_CALLS"
assert grep -qx 'account=other' "$IMAGE_OUT"
assert grep -qx "session=$RESUME_ID" "$IMAGE_OUT"
assert test ! -e "$WORK/media-starts/codex/other"
assert test "$(tail -n 1 "$IMAGE_OUT")" = "edit_depth=1 root=$OUTPUT_DIR/first.png"
assert test "$(jq -c '.edits | map([.prompt, .route, .vendor, .account])' "$OUTPUT_DIR/resumed.png.edit.json")" = \
  '[["now make it bluer","cli","codex","other"]]'
# With no reference the edit target is the thread's own last image, which is what
# num_last_images_to_include names — referenced_image_paths would need a local path per target.
assert grep -q 'set num_last_images_to_include to 1' "$FAKE_CODEX_PROMPT"
assert_fails grep -q 'call view_image on each path below first' "$FAKE_CODEX_PROMPT"
# The subcommand goes after the options, which is the only order `codex exec [OPTIONS] <COMMAND>`
# accepts; taken from the argv the fixture recorded rather than from the script's own text.
assert test "$(grep -n 'ARG=--experimental-json' "$FAKE_CODEX_CALLS" | cut -d: -f1)" \
  -lt "$(grep -n 'ARG=resume' "$FAKE_CODEX_CALLS" | cut -d: -f1)"

# Composite is on by default for every edit, after the contract block: the thread's last delivered
# image or a single --ref is the input, and the vendor's render is kept beside the dest.
"$REAL_MAGICK" -size 64x64 'xc:#00FF00' "PNG24:$OUTPUT_DIR/resumed.png"
assert image_run --dest "$OUTPUT_DIR/resumed2.png" --prompt 'add a blue circle' --resume "$RESUME_ID"
assert test "$(sed -n 1p "$IMAGE_OUT")" = "dest=$OUTPUT_DIR/resumed2.png"
assert grep -Eq '^composite=auto changed=[0-9.]+%$' "$IMAGE_OUT"
assert grep -qx "rendered=$OUTPUT_DIR/resumed2.rendered.png" "$IMAGE_OUT"
assert cmp "$CODEX_PROFILES/other/generated_images/$RESUME_ID/exec-fixture.png" "$OUTPUT_DIR/resumed2.rendered.png"
assert test "$(tail -n 1 "$IMAGE_OUT")" = "edit_depth=2 root=$OUTPUT_DIR/first.png"
assert test "$(jq -r '.edits[1].composite.kind' "$OUTPUT_DIR/resumed2.png.edit.json")" = auto
"$REAL_MAGICK" -size 64x64 'xc:#00FF00' "PNG24:$WORK/green-ref.png"
assert image_run --dest "$OUTPUT_DIR/composited.png" --prompt 'add a blue circle' --ref "$WORK/green-ref.png" --account explicit
assert grep -Eq '^composite=auto changed=[0-9.]+%$' "$IMAGE_OUT"
assert test -e "$OUTPUT_DIR/composited.rendered.png"
assert image_run --dest "$OUTPUT_DIR/optout.png" --prompt 'add a blue circle' --ref "$WORK/green-ref.png" --account explicit --no-composite
assert_fails grep -q '^composite=\|^rendered=' "$IMAGE_OUT"
assert cmp "$CODEX_PROFILES/explicit/generated_images/$FAKE_CODEX_THREAD/exec-fixture.png" "$OUTPUT_DIR/optout.png"
assert test ! -e "$OUTPUT_DIR/optout.rendered.png"
assert image_run --dest "$OUTPUT_DIR/keyedref.png" --prompt 'a transparent circle' --ref "$WORK/green-ref.png" --account explicit --transparent
assert_fails grep -q '^composite=' "$IMAGE_OUT"
assert image_run --dest "$OUTPUT_DIR/tworefs.png" --prompt 'merge' --ref "$WORK/green-ref.png" --ref "$WORK/reference.png" --account explicit
assert grep -qx 'composite=skipped reason=several-inputs' "$IMAGE_OUT"
assert test ! -e "$OUTPUT_DIR/tworefs.rendered.png"

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

# The answer is never the discovery: the built-in tool keys its output directory on the thread, so
# the harvested session finds the image whatever the model replies, a fresh file it names included.
FAKE_CODEX_MODE=nopath
export FAKE_CODEX_MODE
assert image_run --dest "$OUTPUT_DIR/rescued.png" --prompt badge --account explicit
assert cmp "$CODEX_PROFILES/explicit/generated_images/$THREAD/exec-fixture.png" "$OUTPUT_DIR/rescued.png"
FAKE_CODEX_MODE=decoy
assert image_run --dest "$OUTPUT_DIR/decoy.png" --prompt badge --account explicit
assert cmp "$CODEX_PROFILES/explicit/generated_images/$THREAD/exec-fixture.png" "$OUTPUT_DIR/decoy.png"
assert grep -q 'do not read the imagegen skill or any SKILL.md first' "$FAKE_CODEX_PROMPT"
assert grep -qx 'Leave the image where image_gen saved it: do not copy, move or convert it. Once image_gen has returned, reply with just: done' "$FAKE_CODEX_PROMPT"
assert_fails grep -qi 'copy the final image\|(imagegen skill)' "$FAKE_CODEX_PROMPT"

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

FAKE_CODEX_MODE=credits
export FAKE_CODEX_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/credits.png" --prompt badge --account explicit || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx CODEX_USAGE_LIMIT "$IMAGE_ERR"

# 0.159.0's ImageGenerationFailure::usageLimitExceeded: the image item fails and the turn ends clean.
FAKE_CODEX_MODE=limit-item
export FAKE_CODEX_MODE
image_rc=0
image_run --dest "$OUTPUT_DIR/limit-item.png" --prompt badge --account fresh || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx CODEX_USAGE_LIMIT "$IMAGE_ERR"
assert_fails grep -q 'generated file not found' "$IMAGE_ERR"

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

# A leg killed by a caller's timeout is logged with the signal's status, never as a success.
killed_log="$WORK/killed-legs.jsonl"
for signal_rc in TERM:143 HUP:129; do
  # A worker's suite runs under worker-run's nohup: a HUP ignored on entry cannot be trapped by
  # bash, so the leg would sleep out and exit 0 unless the disposition is reset before it starts.
  IMAGE_LEG_LOG="$killed_log" perl -e '$SIG{HUP} = $SIG{TERM} = "DEFAULT"; exec @ARGV or die' \
    bash -c '. "$1/share/image-leg.sh"; image_leg_start killed-leg image
    trap "image_leg_exit" EXIT; sleep 30' _ "$ROOT" 2>/dev/null &
  leg_pid=$!
  leg_ready=0
  for _ in $(seq 600); do pgrep -qP "$leg_pid" sleep && { leg_ready=1; break; }; sleep 0.1; done
  [ "$leg_ready" -eq 1 ] || fail "killed-leg $signal_rc: the leg never reached its sleep within 60 s"
  kill -"${signal_rc%:*}" "$leg_pid"
  pkill -"${signal_rc%:*}" -P "$leg_pid" sleep
  leg_rc=0
  wait "$leg_pid" || leg_rc=$?
  assert test "$leg_rc" -eq "${signal_rc#*:}"
  assert test "$(tail -n1 "$killed_log" | jq -r '"\(.tool) \(.rc)"')" = "killed-leg ${signal_rc#*:}"
done

# Web is routes[0]: without --route it runs first, and a route-level failure there (sign-in, busy, limit,
# unsent) reruns the same request on the CLI; anything sent, refused or unknown stays the web's verdict.
FAKE_CODEX_MODE=image
export FAKE_CODEX_MODE
ROUTE_ARGS=()
web_run() { # mode args...
  local mode=$1
  shift
  rm -f "$WEB_CALLS"
  : >"$FAKE_CODEX_CALLS"
  image_rc=0
  WEB_MODE=$mode image_run "$@" || image_rc=$?
}
web_run ok --dest "$OUTPUT_DIR/web.png" --prompt badge --aspect 16:9
assert test "$image_rc" -eq 0
assert test ! -s "$FAKE_CODEX_CALLS"
assert grep -qx 'route=web' "$IMAGE_OUT"
assert_fails grep -q '^fallback_' "$IMAGE_OUT"
assert grep -qx 'phases={"lock":0.1,"browser":1.5,"sent":4}' "$IMAGE_OUT"
web_job=$(sed -n 's/^job=//p' "$IMAGE_OUT")
assert grep -Eqx 'codex-image-[0-9]{8}T[0-9]{6}Z-[0-9]+' <<<"$web_job"
assert grep -qx "JOB=$web_job" "$WEB_CALLS"
assert jq -se --arg job "$web_job" '.[-1] | .job == $job and .route == "web" and .phases == {lock: 0.1, browser: 1.5, sent: 4}
  and .aspect.fit == "miss" and .aspect.asked == "16:9" and .requested == 1 and .delivered == 1' "$IMAGE_LEG_LOG" >/dev/null
IMAGE_JOB_ID=fanout-7 web_run ok --dest "$OUTPUT_DIR/web.png" --prompt badge
assert grep -qx 'job=fanout-7' "$IMAGE_OUT"
assert grep -qx 'JOB=fanout-7' "$WEB_CALLS"
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -r .job)" = fanout-7

for trigger in signin:sign-in busy:busy limit:limit unsent:not-sent; do
  web_run "${trigger%:*}" --dest "$OUTPUT_DIR/fallback.png" --prompt badge --account explicit --lock-wait 30
  assert test "$image_rc" -eq 0
  assert grep -qx 30 <<<"$(grep -A1 -x -- --lock-wait "$WEB_CALLS")"
  assert grep -qx "CODEX_HOME=$CODEX_PROFILES/explicit" "$FAKE_CODEX_CALLS"
  assert_fails grep -qx -- 'ARG=--lock-wait' "$FAKE_CODEX_CALLS"
  assert grep -qx 'route=cli' "$IMAGE_OUT"
  assert grep -qx 'fallback_from=web' "$IMAGE_OUT"
  assert grep -qx "fallback_reason=${trigger#*:}" "$IMAGE_OUT"
  assert grep -qx 'account=explicit' "$IMAGE_OUT"
  assert_fails grep -q '^phases=' "$IMAGE_OUT"
  assert grep -q "route web failed (${trigger#*:}); the same request goes to --route cli" "$IMAGE_ERR"
  assert jq -se --arg why "${trigger#*:}" '.[-1] | .rc == 0 and .route == "cli" and .fallback_from == "web"
    and .fallback_reason == $why and .account == "explicit" and .delivered == 1' "$IMAGE_LEG_LOG" >/dev/null
done
assert test ! -e "$OUTPUT_DIR/fallback.rendered.png"

for refusal in sent:1 limit-sent:3 unknown:1 refused:1; do
  web_run "${refusal%:*}" --dest "$OUTPUT_DIR/stay.png" --prompt badge --account explicit
  assert test "$image_rc" -eq "${refusal#*:}"
  assert test -s "$WEB_CALLS"
  assert test ! -s "$FAKE_CODEX_CALLS"
  assert_fails grep -q 'the same request goes to' "$IMAGE_ERR"
  assert jq -se '.[-1] | .route == "web" and (has("fallback_from") | not) and .delivered == 0' "$IMAGE_LEG_LOG" >/dev/null
done
"$REAL_MAGICK" -size 64x64 'xc:#00FF00' "PNG24:$WORK/edit-base.png"
for blocked in "--route web" "--remove-bg --ref $WORK/edit-base.png" "--point 0.5,0.5=bluer --ref $WORK/edit-base.png" \
    "--resume 0c0c0c0c-1111-4222-8333-944455556666"; do
  read -r -a blocked_args <<<"$blocked"
  web_run signin --dest "$OUTPUT_DIR/stay.png" ${blocked_args[@]+"${blocked_args[@]}"} \
    $(case $blocked in --remove-bg* | --point*) ;; *) printf '%s\n' --prompt badge ;; esac)
  assert test "$image_rc" -eq 4
  assert test -s "$WEB_CALLS"
  assert test ! -s "$FAKE_CODEX_CALLS"
done
# The resumed chat was made on the web (session record), so no --route still means web.
assert grep -qx 0c0c0c0c-1111-4222-8333-944455556666 <<<"$(grep -A1 -x -- --resume "$WEB_CALLS")"
cli_cap=$(manifest_value '.refs.max')
over_cli=()
for index in $(seq 0 "$cli_cap"); do over_cli+=(--ref "$WORK/edit-base.png"); done
web_run signin --dest "$OUTPUT_DIR/stay.png" --prompt badge "${over_cli[@]}"
assert test "$image_rc" -eq 4
assert test ! -s "$FAKE_CODEX_CALLS"

# Exit 5 is account busy, said once on stderr, wherever no fallback takes the request.
web_run busy --route web --dest "$OUTPUT_DIR/stay.png" --prompt badge
assert test "$image_rc" -eq 5
assert grep -qx 'ACCOUNT_BUSY account=webacct' "$IMAGE_ERR"
web_run busy --dest "$OUTPUT_DIR/stay.png" --ref "$WORK/edit-base.png" --remove-bg
assert test "$image_rc" -eq 5
assert grep -qx 'ACCOUNT_BUSY account=webacct' "$IMAGE_ERR"
web_run ok --dest "$OUTPUT_DIR/stay.png" --prompt badge --lock-wait soon
assert test "$image_rc" -eq 2
assert test ! -e "$WEB_CALLS"

# A session no record names is the CLI's when a codex home holds it.
IMAGE_LEG_LOG="$WORK/fresh-legs/legs.jsonl" web_run ok --dest "$OUTPUT_DIR/legacy.png" --prompt bluer --resume "$RESUME_ID"
assert test "$image_rc" -eq 0
assert test ! -e "$WEB_CALLS"
assert grep -qx 'ARG=resume' "$FAKE_CODEX_CALLS"

# --edit is the composite base and the first reference; the other refs are references only.
"$REAL_MAGICK" -size 64x64 'xc:#FF0000' "PNG24:$WORK/style-a.png"
"$REAL_MAGICK" -size 64x64 'xc:#0000FF' "PNG24:$WORK/style-b.png"
web_run ok --dest "$OUTPUT_DIR/edited-web.png" --prompt 'add a blue circle' --edit "$WORK/edit-base.png" \
  --ref "$WORK/style-a.png" --ref "$WORK/style-b.png"
assert test "$image_rc" -eq 0
assert test "$(grep -A1 -x -- --ref "$WEB_CALLS" | grep -v -x -- --ref | grep -v -x -- -- | tr '\n' ' ')" = \
  "$WORK/edit-base.png $WORK/style-a.png $WORK/style-b.png "
assert grep -qx 'The first image is the one to edit; the other images are references only.' "$WEB_CALLS"
assert grep -Eqx 'composite=auto changed=[0-9.]+%' "$IMAGE_OUT"
assert grep -qx "rendered=$OUTPUT_DIR/edited-web.rendered.png" "$IMAGE_OUT"
assert grep -qx "edit_depth=1 root=$WORK/edit-base.png" "$IMAGE_OUT"
assert test "$(jq -r '.root' "$OUTPUT_DIR/edited-web.png.edit.json")" = "$WORK/edit-base.png"
assert jq -se '.[-1] | .composite.kind == "auto" and (.composite.changed | type) == "number" and .size == 4' "$IMAGE_LEG_LOG" >/dev/null
ROUTE_ARGS=(--route cli)
web_run unset --dest "$OUTPUT_DIR/edited-cli.png" --prompt 'add a blue circle' --edit "$WORK/edit-base.png" \
  --ref "$WORK/style-a.png" --ref "$WORK/style-b.png" --account explicit
assert test "$image_rc" -eq 0
assert test "$(grep -A1 -x -- '- '"$WORK/edit-base.png" "$FAKE_CODEX_PROMPT" | head -n 1)" = "- $WORK/edit-base.png"
assert test "$(grep -x -- "- $WORK/[a-z-]*.png" "$FAKE_CODEX_PROMPT" | tr '\n' ' ')" = \
  "- $WORK/edit-base.png - $WORK/style-a.png - $WORK/style-b.png "
assert grep -Eqx 'composite=auto changed=[0-9.]+%' "$IMAGE_OUT"
assert grep -qx "edit_depth=1 root=$WORK/edit-base.png" "$IMAGE_OUT"
over_cli=()
for index in $(seq 1 "$cli_cap"); do over_cli+=(--ref "$WORK/style-a.png"); done
web_run unset --dest "$OUTPUT_DIR/stay.png" --prompt badge --edit "$WORK/edit-base.png" "${over_cli[@]}" --account explicit
assert test "$image_rc" -eq 2
assert grep -q "references exceed the $cli_cap" "$IMAGE_ERR"
web_run unset --dest "$OUTPUT_DIR/stay.png" --prompt badge --edit "$WORK/edit-base.png" --resume "$RESUME_ID"
assert test "$image_rc" -eq 2
assert grep -q -- '--edit names the image to edit' "$IMAGE_ERR"
web_run unset --dest "$OUTPUT_DIR/stay.png" --prompt badge --edit edit-base.png
assert test "$image_rc" -eq 2
assert test ! -s "$FAKE_CODEX_CALLS"

# --count N on the web route: one engine launch, the other takes printed as variant= lines the way Flow's are,
# requested/delivered in legs.jsonl, a failed= line when some take failed; no CLI fallback (it renders one image).
ROUTE_ARGS=()
web_run takes --dest "$OUTPUT_DIR/many.png" --prompt badge --count 3
assert test "$image_rc" -eq 0
assert grep -qx 3 <<<"$(grep -A1 -x -- --count "$WEB_CALLS")"
assert grep -qx "dest=$OUTPUT_DIR/many.png" "$IMAGE_OUT"
assert grep -qx "variant=$OUTPUT_DIR/many-2.png size=62x64 session=0c0c0c0c-1111-4222-8333-944455556662" "$IMAGE_OUT"
assert grep -qx "variant=$OUTPUT_DIR/many-3.png size=63x64 session=0c0c0c0c-1111-4222-8333-944455556663" "$IMAGE_OUT"
assert test "$(sips -g pixelWidth "$OUTPUT_DIR/many-3.png" | awk '/pixelWidth:/ {print $2}')" = 63
assert_fails grep -q '^failed=' "$IMAGE_OUT"
assert jq -se '.[-1] | .route == "web" and .requested == 3 and .delivered == 3' "$IMAGE_LEG_LOG" >/dev/null
web_run takes-limit --dest "$OUTPUT_DIR/some.jpg" --prompt badge --count 3
assert test "$image_rc" -eq 0
assert grep -qx "variant=$OUTPUT_DIR/some-2.jpg size=62x64 session=0c0c0c0c-1111-4222-8333-944455556662" "$IMAGE_OUT"
assert test "$(sips -g format "$OUTPUT_DIR/some-2.jpg" | awk '/format:/ {print $2}')" = jpeg
assert_fails grep -q '^variant=.*some-3' "$IMAGE_OUT"
assert grep -qx 'failed=1 reason=chatgpt_take_failed' "$IMAGE_OUT"
assert grep -qx 'codex-image: take 3 failed: ChatGPT image limit on webacct' "$IMAGE_ERR"
assert jq -se '.[-1] | .requested == 3 and .delivered == 2' "$IMAGE_LEG_LOG" >/dev/null
web_run signin --dest "$OUTPUT_DIR/stay.png" --prompt badge --count 2
assert test "$image_rc" -eq 4
assert test ! -s "$FAKE_CODEX_CALLS"
assert_fails grep -q 'the same request goes to' "$IMAGE_ERR"
for refused in "--route cli --count 2" "--count 5" "--count 0" "--count two" \
    "--count 2 --resume 0c0c0c0c-1111-4222-8333-944455556666" "--count 2 --region 0,0,1,1 --ref $WORK/edit-base.png"; do
  read -r -a refused_args <<<"$refused"
  web_run ok --dest "$OUTPUT_DIR/stay.png" --prompt badge "${refused_args[@]}"
  assert test "$image_rc" -eq 2
  assert grep -q -- '--count' "$IMAGE_ERR"
  assert test ! -e "$WEB_CALLS"
  assert test ! -s "$FAKE_CODEX_CALLS"
done
for refused in "--remove-bg" "--point 0.5,0.5=bluer"; do
  read -r -a refused_args <<<"$refused"
  web_run ok --dest "$OUTPUT_DIR/stay.png" --ref "$WORK/edit-base.png" --count 2 "${refused_args[@]}"
  assert test "$image_rc" -eq 2
  assert grep -q -- '--count renders new chats' "$IMAGE_ERR"
  assert test ! -e "$WEB_CALLS"
done

echo "PASS:$asserts asserts; manifest-driven usage and reference cap, pre-spend argument refusals, routing and account pinning, exact codex exec launch controls with --experimental-json, the seven-line contract block including session/model/caps, caps staleness on a changed CLI, byte-identical same-format delivery, differing-format conversion, the view_image + referenced_image_paths reference instruction, native alpha kept unkeyed, chroma fallback on an opaque answer, resume account recovery from the session store, edit lineage through a resume, resume argv order, unresolvable and silently-new threads, thread-keyed output rescue, missing image, usage-limit and generic failure classification, worker-pick limit propagation, and the launching chat's stamp passed through; web-first routing with the CLI fallback on sign-in/busy/limit/unsent only, exit 5 ACCOUNT_BUSY, --lock-wait forwarded, job=/phases= and the legs.jsonl soft fields, and --edit as composite base and first reference"
