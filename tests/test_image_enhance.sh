#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ENHANCE="$ROOT/bin/image-enhance"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
enhance() { IMAGE_ENHANCE_MEDIA_RUN="$WORK/media-run" "$ENHANCE" "$@" >"$WORK/out" 2>"$WORK/err"; }
exits() { local want=$1; shift; enhance "$@"; [ $? -eq "$want" ]; }
size() { magick identify -format '%wx%h' "$1"; }
# The worst channel difference of two same-size images, 0-255.
diff_max() { magick compare -metric PAE "$1" "$2" null: 2>&1 | awk '{gsub(/[()]/, "", $2); printf "%d\n", $2 * 255 + 0.5}'; }

# A stand-in for `media-run image --jobs`: every job's edit comes back as ChatGPT returns a square tile
# (1254 px), its content untouched; FAKE_FAIL names a dest to fail every time, FAKE_EXIT forces an exit code.
cat >"$WORK/media-run" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_LOG"
[ -z "${FAKE_EXIT:-}" ] || exit "$FAKE_EXIT"
jobs='' takes=1
while [ $# -gt 0 ]; do
  case "$1" in --jobs) jobs=$2; shift 2 ;; --takes) takes=$2; shift 2 ;; *) shift ;; esac
done
while IFS= read -r line; do
  edit=$(jq -r .edit <<<"$line") dest=$(jq -r .dest <<<"$line")
  [ "$dest" != "${FAKE_FAIL:-}" ] || continue
  for k in $(seq 1 "$takes"); do
    out=$dest; [ "$k" -eq 1 ] || out=${dest%.png}-$k.png
    if [ "$(jq -r .aspect <<<"$line")" = 1:1 ]; then magick "$edit" -resize '1254x1254!' "$out"; else cp "$edit" "$out"; fi
  done
done <"$jobs"
EOF
chmod +x "$WORK/media-run"
export FAKE_LOG="$WORK/calls.log"

magick -size 1600x900 gradient:'#203040-#e0c080' \( -seed 7 -size 1600x900 plasma:fractal -blur 0x2 \) \
  -compose blend -define compose:args=50 -composite "$WORK/in.png"
in="$WORK/in.png" dest="$WORK/out.png"

assert exits 2
assert exits 2 --in in.png --dest "$dest"
assert exits 2 --in "$in" --dest "$WORK/out.jpg"
assert exits 2 --in "$in" --dest out.png
assert exits 2 --in "$WORK/missing.png" --dest "$dest"
assert exits 2 --in "$in" --dest "$WORK/no/such/out.png"
assert exits 2 --in "$in" --dest "$dest" --mode sharpen
assert exits 2 --in "$in" --dest "$dest" --size 2x
assert exits 2 --in "$in" --dest "$dest" --size 3200x1800 --scale 2
assert exits 2 --in "$in" --dest "$dest" --scale 20
assert exits 2 --in "$in" --dest "$dest" --takes 2
assert exits 2 --in "$in" --dest "$dest" --mode photo --change "make it night"
assert exits 2 --in "$in" --dest "$dest" --mode strong --takes 5
assert exits 2 --in "$in" --dest "$dest" --size 12000x8000
assert test ! -e "$WORK/calls.log"

assert enhance --in "$in" --dest "$dest" --mode strong --scale 2 --takes 2 --change "make it night" --dry-run
assert grep -qx 'mode=strong size=3200x1800 tiles=12 tile=1024 takes=2' "$WORK/out"
assert grep -q 'Also make this change: make it night\. Apart from it' "$WORK/out"
assert test ! -e "$WORK/out.enhance"

# photo at the input's size: 3 tiles of 900 px; the untouched renders merge back onto the input
assert enhance --in "$in" --dest "$dest" --focus "the trees"
assert grep -qx "dest=$dest size=1600x900 mode=photo tiles=3 work=$WORK/out.enhance" "$WORK/out"
assert test "$(size "$dest")" = 1600x900
assert test "$(diff_max "$in" "$dest")" -le 24
assert grep -q 'Give the strongest treatment to the trees' "$WORK/out.enhance/prompts.txt"
assert test "$(jq -s length "$WORK/out.enhance/x-jobs.jsonl")" -eq 3
assert grep -q -- '-- --dest-dir .* --no-composite' "$WORK/calls.log"

# restore as the upscaler: twice the size, the base is the Lanczos enlargement
assert enhance --in "$in" --dest "$WORK/up.png" --mode restore --scale 2
assert test "$(size "$WORK/up.png")" = 3200x1800
assert test "$(diff_max "$WORK/up.enhance/x-base.png" "$WORK/up.png")" -le 24

# strong: one whole-frame fan-out with --takes, then restore tiles per take
: >"$FAKE_LOG"
assert enhance --in "$in" --dest "$WORK/s.png" --mode strong --takes 2
assert test "$(size "$WORK/s.png")" = 1600x900
assert test "$(size "$WORK/s-2.png")" = 1600x900
assert grep -q -- '--takes 2' "$WORK/calls.log"
assert test "$(grep -c -- '--jobs' "$WORK/calls.log")" -eq 3
assert grep -q '"aspect": "16:9"' "$WORK/s.enhance/whole-jobs.jsonl"

# a tile that never comes back is retried once, then named
: >"$FAKE_LOG"
FAKE_FAIL="$WORK/f.enhance/out/x-t01.png" assert exits 1 --in "$in" --dest "$WORK/f.png"
assert test "$(wc -l <"$WORK/calls.log")" -eq 2
assert grep -q 'x-t01.png' "$WORK/err"
assert test ! -e "$WORK/f.png"
FAKE_EXIT=3 assert exits 3 --in "$in" --dest "$WORK/l.png"

printf 'PASS: %s asserts\n' "$asserts"
