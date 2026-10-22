#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() {
  echo "FAIL: $*" >&2
  [ ! -f "$WORK/check.out" ] || sed -n '1,20p' "$WORK/check.out" >&2
  exit 1
}
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then fail "assert $asserts unexpectedly succeeded: $*"; fi
}

# The judge is a stub worker-run: it keeps every brief and answers by the clip the brief names, so no
# suite ever reaches Sol.
mkdir -p "$WORK/bin" "$WORK/briefs"
cat >"$WORK/bin/worker-run" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do [ "$1" = --brief ] && brief=$2; shift; done
cp "$brief" "$BRIEFS/$(md5 -q "$brief").md"
if grep -q 'broken.mp4' "$brief"; then printf 'worker-run: every codex account is walled\n' >&2; exit 3; fi
printf 'RUN: stub\nRESULT:\nINVENTORY: one hinged door\nVERDICT: defects\n'
printf 't=0.5-1 | door | opens by itself | noticeable: yes | confidence: high | fix: start with the door open\n'
printf 't=1 | cup | shifts a little | noticeable: no | confidence: low | fix: none\n'
EOF
chmod +x "$WORK/bin/worker-run"
ffmpeg -nostdin -v error -f lavfi -i testsrc=size=320x240:rate=10 -t 1.5 "$WORK/door.mp4"
ffmpeg -nostdin -v error -f lavfi -i testsrc2=size=320x240:rate=10 -t 1.5 "$WORK/broken.mp4"

rc=0
env PATH="$WORK/bin:$PATH" BRIEFS="$WORK/briefs" VIDEO_GLITCH_DATA="$WORK/data" \
  "$ROOT/bin/video-glitch" check "$WORK/door.mp4" "$WORK/broken.mp4" >"$WORK/check.out" 2>"$WORK/check.err" || rc=$?
# Every clip gets its own block in the order given; one the judge could not check fails the call, not the other.
assert test "$rc" = 1
assert test "$(sed -n 1p "$WORK/check.out")" = "glitch=defects video=$WORK/door.mp4"
assert test "$(sed -n 2p "$WORK/check.out")" = 't=0.5-1 door: opens by itself fix: start with the door open'
assert test "$(sed -n 3p "$WORK/check.out")" = \
  "glitch=unchecked video=$WORK/broken.mp4 reason=the judge gave no verdict: worker-run: every codex account is walled"
assert test "$(wc -l <"$WORK/check.out" | tr -d ' ')" = 3
# What the judge itself calls unnoticeable never reaches the parent, only the record.
assert_fails grep -q cup "$WORK/check.out"
assert test "$(jq -s 'length' "$WORK/data/checks.jsonl")" = 1
assert test "$(jq -r '.defects | map(.object) | join(",")' "$WORK/data/checks.jsonl")" = door,cup
# 1.5 s at 2 frames a second, each brief lists its own frames, and no frame outlives its check.
assert test "$(cat "$WORK"/briefs/*.md | grep -c '^- .*/frames/f0[1-9].jpg$')" = 6
assert test -z "$(find "$WORK/data" -name 'f*.jpg' -print -quit)"

echo "PASS: $asserts asserts; check judges every clip at once in the given order, prints only noticeable defects with their fix, records every defect, says unchecked with the judge's reason for a clip it could not check, and deletes the frames"
