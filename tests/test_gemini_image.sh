#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
REAL_MAGICK=$(command -v magick) || exit 1
export REAL_MAGICK
export HOME="$WORK/home" GEMINIB_PROFILES_DIR="$WORK/profiles"
export WORKER_CLAIMS_DIR="$WORK/claims" WORKER_PICK_CONFIG_FILE="$WORK/worker-model"
export LLM_LIMITS_GEMINI_CACHE="$WORK/main-cache" LLM_LIMITS_GEMINI_REMOVED="$WORK/main-removed"
export LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$WORK/account-caches" TMPDIR="$WORK/tmp"
export FAKE_GEMINIB_CALLS="$WORK/calls" FAKE_GEMINIB_PROMPT="$WORK/prompt"
export PICK_CALLS="$WORK/picks" AGY_BIN="$WORK/bin/agy"
mkdir -p "$HOME" "$WORK/bin" "$TMPDIR" "$WORK/output" "$GEMINIB_PROFILES_DIR/explicit" "$GEMINIB_PROFILES_DIR/picked"
ln -s "$ROOT/tests/fixtures/fake-geminib-image.sh" "$WORK/bin/geminib"
cat >"$WORK/bin/agy" <<'STUB'
#!/usr/bin/env bash
[ "$*" = --version ] || exit 91
printf '%s\n' "${FAKE_AGY_VERSION:-1.2.1}"
STUB
cat >"$WORK/bin/worker-pick" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_CALLS"
[ "${PICK_MODE:-ok}" != limit ] || exit 3
printf 'picked\n'
STUB
chmod +x "$WORK/bin/agy" "$WORK/bin/worker-pick"
export PATH="$WORK/bin:$PATH"
: >"$FAKE_GEMINIB_CALLS"
: >"$PICK_CALLS"
: >"$WORK/err"
image_run() { bash "${SCRIPT:-$ROOT/bin/gemini-image}" "$@" >"$WORK/out" 2>"$WORK/err"; }
expect_rc() {
  local expected=$1 result=0
  shift
  image_run "$@" || result=$?
  assert test "$result" -eq "$expected"
}
args=(--dest "$WORK/output/result.png" --prompt 'a blue badge')
printf 'reference\n' >"$WORK/reference.jpg"
ref="$WORK/reference.jpg"
expect_rc 2 --dest relative.png --prompt badge
expect_rc 2 "${args[@]}" --aspect 5:4
expect_rc 2 "${args[@]}" --ref "$ref" --ref "$ref" --ref "$ref" --ref "$ref"
expect_rc 2 "${args[@]}" --ref relative.png
expect_rc 2 "${args[@]}" --ref "$WORK/missing.jpg"
expect_rc 2 "${args[@]}" --account 'bad name'
expect_rc 2 "${args[@]}" --resume fixture-session
expect_rc 2 "${args[@]}" --resume ../bad --account explicit
expect_rc 2 "${args[@]}" --resume absent --account explicit
expect_rc 2 --dest "$WORK/output/noext" --prompt badge
expect_rc 2 --dest "$WORK/output/bad.jpg" --prompt badge --transparent
expect_rc 1 "${args[@]}" --account unknown
assert test ! -s "$FAKE_GEMINIB_CALLS"
assert test ! -d "$GEMINIB_PROFILES_DIR/unknown"

assert image_run "${args[@]}" --aspect 16:9 --ref "$ref" --ref "$ref" --ref "$ref"
assert grep -qx 'ImagePaths:' "$FAKE_GEMINIB_PROMPT"
assert test "$(grep -Fxc -- "- $ref" "$FAKE_GEMINIB_PROMPT")" -eq 3
assert grep -qx 'AspectRatio: 16:9' "$FAKE_GEMINIB_PROMPT"
assert grep -qx -- '--account gemini --role image' "$PICK_CALLS"
assert test -e "$WORKER_CLAIMS_DIR/gemini/picked"
assert grep -qx 'ARG=stream-json' "$FAKE_GEMINIB_CALLS"
printf 'dest=%s\nsize=16x12\nformat=png\naccount=picked\nsession=fixture-session\nmodel=gemini-3.1-flash-image model_caps=fresh\ncaps=fresh\n' "$WORK/output/result.png" >"$WORK/expected"
assert cmp "$WORK/expected" "$WORK/out"

: >"$PICK_CALLS"
assert image_run "${args[@]}" --account explicit
assert grep -qx 'Omit ImagePaths.' "$FAKE_GEMINIB_PROMPT"
assert test ! -s "$PICK_CALLS"
: >"$FAKE_GEMINIB_CALLS"
assert image_run "${args[@]}" --prompt 'now make it bluer' --resume fixture-session --account explicit
assert grep -qx 'ARG=--conversation' "$FAKE_GEMINIB_CALLS"
assert grep -qx 'ARG=fixture-session' "$FAKE_GEMINIB_CALLS"
assert grep -qx 'ARG=explicit' "$FAKE_GEMINIB_CALLS"
assert grep -q 'last generated image from this conversation as ImagePaths' "$FAKE_GEMINIB_PROMPT"
assert test "$(grep -c '^AspectRatio:' "$FAKE_GEMINIB_PROMPT")" -eq 0
assert image_run "${args[@]}" --prompt 'wider' --resume fixture-session --account explicit --aspect 16:9
assert grep -qx 'AspectRatio: 16:9' "$FAKE_GEMINIB_PROMPT"
assert grep -qx 'session=fixture-session' "$WORK/out"

for mode in stream rescue init-only; do
  FAKE_GEMINIB_MODE=$mode assert image_run "${args[@]}" --account explicit
  assert grep -qx 'session=fixture-session' "$WORK/out"
  assert grep -qx 'model=gemini-3.1-flash-image model_caps=fresh' "$WORK/out"
done
FAKE_GEMINIB_MODE=no-session assert image_run "${args[@]}" --account explicit
assert grep -qx 'session=none' "$WORK/out"
assert grep -qx 'model=unknown model_caps=unknown' "$WORK/out"
FAKE_GEMINIB_MODE=no-model assert image_run "${args[@]}" --account explicit
assert grep -qx 'model=unknown model_caps=unknown' "$WORK/out"
FAKE_IMAGE_MODEL=gemini-future-image FAKE_AGY_VERSION=1.3.0 assert image_run "${args[@]}" --account explicit
assert grep -qx 'model=gemini-future-image model_caps=stale verified=gemini-3.1-flash-image' "$WORK/out"
assert grep -qx 'caps=stale cli=1.3.0 verified=1.2.1' "$WORK/out"

for mode in quota quota-plain quota-stderr quota-log quota-exit quota-tool; do
  FAKE_GEMINIB_MODE=$mode expect_rc 3 "${args[@]}" --account explicit
  assert grep -qx GEMINI_USAGE_LIMIT "$WORK/err"
  assert test ! -s "$WORK/out"
done
for mode in error no-image stale; do
  FAKE_GEMINIB_MODE=$mode expect_rc 1 "${args[@]}" --account explicit
done
FAKE_GEMINIB_MODE=pool expect_rc 4 "${args[@]}" --account explicit
assert grep -q 'refused by the worker pool' "$WORK/err"
assert test ! -s "$WORK/out"
: >"$FAKE_GEMINIB_CALLS"
mkdir -p "$GEMINIB_PROFILES_DIR/.geminib"
printf 'explicit\n' >"$GEMINIB_PROFILES_DIR/.geminib/disabled"
expect_rc 4 "${args[@]}" --account explicit
assert test ! -s "$FAKE_GEMINIB_CALLS"
rm -f "$GEMINIB_PROFILES_DIR/.geminib/disabled"
: >"$FAKE_GEMINIB_CALLS"
PICK_MODE=limit expect_rc 3 "${args[@]}"
assert test ! -s "$FAKE_GEMINIB_CALLS"

assert image_run "${args[@]}" --prompt 'transparent badge' --transparent --account explicit
assert grep -q '#00FF00' "$FAKE_GEMINIB_PROMPT"
assert test "$(sips -g hasAlpha "$WORK/output/result.png" | awk '/hasAlpha:/ {print $2}')" = yes
CLAUDE_LAUNCHER_SESSION=launching-chat assert image_run "${args[@]}" --account explicit
assert grep -qx 'CLAUDE_LAUNCHER_SESSION=launching-chat' "$FAKE_GEMINIB_CALLS"
assert test -z "$(find "$TMPDIR" -name 'gemini-image.*' -print -quit)"

mkdir -p "$WORK/repo/bin" "$WORK/repo/share/image-caps"
cp "$ROOT/bin/gemini-image" "$WORK/repo/bin/"
cp "$ROOT/share/"{image-caps,image-chroma,gemini-accounts,worker-model,worker-pool,worker-claims}.sh "$WORK/repo/share/"
jq '.refs.max=1 | .aspects.generate=["5:4"] | .aspects.edit=["5:4"] | .aspects.default="5:4"' "$ROOT/share/image-caps/gemini.json" >"$WORK/repo/share/image-caps/gemini.json"
SCRIPT="$WORK/repo/bin/gemini-image"
assert image_run "${args[@]}" --ref "$ref" --account explicit
assert grep -qx 'AspectRatio: 5:4' "$FAKE_GEMINIB_PROMPT"
expect_rc 2 "${args[@]}" --ref "$ref" --ref "$ref" --account explicit
expect_rc 2 "${args[@]}" --aspect 1:1 --account explicit
jq '.transparent="native"' "$ROOT/share/image-caps/gemini.json" >"$WORK/repo/share/image-caps/gemini.json"
expect_rc 1 "${args[@]}" --transparent --account explicit

printf 'PASS: %s asserts; manifest limits, account isolation, stream paths, resume, brain rescue, model provenance, quota, chroma, and output contract\n' "$asserts"
