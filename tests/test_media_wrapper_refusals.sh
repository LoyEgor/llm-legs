#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude"
: >"$FAKE_HOME/.claude/worker-model"
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl" VENDOR_CLI_UPDATE_STATE_DIR="$WORK/vendor-state"
: >"$IMAGE_LEG_LOG"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -eq 1 ] || fail "assert $asserts failed with status $status, not a clean no-match: $*"
  fi
}

wrappers=(codex-image gemini-image gemini-listen gemini-music gemini-sfx gemini-speech gemini-video grok-image grok-video)
for wrapper in "${wrappers[@]}"; do
  help_rc=0
  help_out=$(HOME="$FAKE_HOME" bash "$ROOT/bin/$wrapper" --help 2>/dev/null) || help_rc=$?
  assert test "$help_rc" -eq 0
  assert grep -q "^usage: $wrapper " <<<"$help_out"
  assert test "$(grep -v '^#' "$ROOT/bin/$wrapper" | head -n 1)" = '{'
  assert test "$(tail -n 2 "$ROOT/bin/$wrapper" | tr '\n' ' ')" = 'exit } '
done
assert test ! -s "$IMAGE_LEG_LOG"

# I23: a refusal names its cause on the first stderr line, and the line reaches the err of
# image-leg.sh's leg log.
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
    [ "${case_args%%|*}" = DEST ] || assert grep -q "^usage: $wrapper " <<<"$refusal_err"
  done
  assert_fails grep -nE '(^|[^-_[:alnum:]])usage[[:space:]]*(;|\)|$)' <(grep -vE 'usage\(\)|image_leg_help usage' "$ROOT/bin/$wrapper")
done

echo "PASS:$asserts asserts; every media wrapper's --help exits 0 unjournaled with its usage line, each script is one brace block ending in exit, and an unknown argument or a missing destination folder is refused with exit 2, the cause on the first stderr line and in the leg log, usage after an unknown argument"
