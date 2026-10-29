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
enhance() {
  IMAGE_ENHANCE_MEDIA_RUN="$WORK/media-run" IMAGE_ENHANCE_CHATGPT_WEB="$WORK/chatgpt-web" \
    IMAGE_ENHANCE_ROOM_MB=${ROOM_MB:-20000} "$ENHANCE" "$@" >"$WORK/out" 2>"$WORK/err"
}
exits() { local want=$1; shift; enhance "$@"; [ $? -eq "$want" ]; }
size() { magick identify -format '%wx%h' "$1"; }
# The worst channel difference of two same-size images, 0-255.
diff_max() { magick compare -metric PAE "$1" "$2" null: 2>&1 | awk '{gsub(/[()]/, "", $2); printf "%d\n", $2 * 255 + 0.5}'; }

# A stand-in for `media-run image`: a --jobs fan-out (the strong whole frame) or a pinned pack (--edit, or
# --each per tab at dest, dest-2...); every edit comes back as ChatGPT returns a tile of its aspect (1254x1254,
# 1672x941), its content untouched; each tab shows first at its .landing path, the way codex-image --each puts
# the engine's bytes, and its delivered file when the run ends. FAKE_FAIL names a tile that fails every time,
# FAKE_EXIT forces an exit code, FAKE_GONE an account that exits 5 (busy) having sent nothing, FAKE_SLOW an
# account that renders only after 30 s, FAKE_HOLD the seconds a pack runs on after its tabs landed.
cat >"$WORK/media-run" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_LOG"
[ -z "${FAKE_EXIT:-}" ] || exit "$FAKE_EXIT"
render() { # edit aspect out
  [ "$1" != "${FAKE_FAIL:-}" ] || return 0
  case $2 in
    1:1) magick "$1" -resize '1254x1254!' "$3" ;;
    16:9) magick "$1" -resize '1672x941!' "$3" ;;
    *) cp "$1" "$3" ;;
  esac
}
jobs='' takes=1 dest='' aspect='' account='' edits=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) jobs=$2; shift 2 ;; --takes) takes=$2; shift 2 ;; --dest) dest=$2; shift 2 ;;
    --aspect) aspect=$2; shift 2 ;; --account) account=$2; shift 2 ;;
    --edit | --each) edits+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done
[ -z "${FAKE_GONE:-}" ] || [ "$account" != "$FAKE_GONE" ] || exit 5
if [ -z "$jobs" ]; then
  printf '%s\n' "$$" >"$FAKE_PIDS/$account"
  [ "$account" != "${FAKE_SLOW:-}" ] || sleep 30
  for k in "${!edits[@]}"; do
    land=${dest%.png}.landing; [ "$k" -eq 0 ] || land=${dest%.png}-$((k + 1)).landing
    render "${edits[k]}" "$aspect" "$land.png"
    [ ! -f "$land.png" ] || mv "$land.png" "$land"
  done
  [ -z "${FAKE_HOLD:-}" ] || sleep "$FAKE_HOLD"
  for k in "${!edits[@]}"; do
    land=${dest%.png}.landing out=$dest
    [ "$k" -eq 0 ] || { land=${dest%.png}-$((k + 1)).landing; out=${dest%.png}-$((k + 1)).png; }
    [ ! -f "$land" ] || mv "$land" "$out"
  done
  exit 0
fi
while IFS= read -r line; do
  edit=$(jq -r .edit <<<"$line") dest=$(jq -r .dest <<<"$line")
  for k in $(seq 1 "$takes"); do
    out=$dest; [ "$k" -eq 1 ] || out=${dest%.png}-$k.png
    render "$edit" "$(jq -r .aspect <<<"$line")" "$out"
  done
done <"$jobs"
EOF
# Four signed-in accounts in the order a1 a2 a3 p0: by last use, a Plus seat last whatever its; one walled and one
# out of the pool.
cat >"$WORK/chatgpt-web" <<EOF
#!/bin/bash
printf '%s\n' '{"ok":true,"accounts":[{"account":"p0","login":true,"last_used":0,"plan":"plus"},{"account":"a2","login":true,"last_used":20,"lock":"$WORK/a2.lock"},{"account":"a1","login":true,"last_used":10,"lock":"$WORK/a1.lock"},{"account":"a3","login":true,"last_used":30},{"account":"w","login":true,"walled_until":9999999999},{"account":"off","login":true,"roster":false}]}'
EOF
chmod +x "$WORK/media-run" "$WORK/chatgpt-web"
export FAKE_LOG="$WORK/calls.log" FAKE_PIDS="$WORK"

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
assert grep -qx 'mode=strong size=3200x1800 tiles=6 tile=1254x1254 aspect=1:1 takes=2' "$WORK/out"
assert grep -q 'Also make this change: make it night\. Apart from it' "$WORK/out"
# the render shape needing the fewest tiles: a 2752x1536 wall is 4 wide tiles (one round of the accounts), a
# square 1400 picture 2 wide tiles scaled to its width
assert enhance --in "$in" --dest "$dest" --size 2752x1536 --dry-run
assert grep -qx 'mode=photo size=2752x1536 tiles=4 tile=1672x941 aspect=16:9 takes=1' "$WORK/out"
assert enhance --in "$in" --dest "$dest" --size 1400x1400 --dry-run
assert grep -qx 'mode=photo size=1400x1400 tiles=2 tile=1400x788 aspect=16:9 takes=1' "$WORK/out"
assert exits 2 --in "$in" --dest "$dest" --mode strong --takes 4 --size 7000x4000
assert test ! -e "$WORK/out.enhance"

# photo at the input's size: one wide tile, a render 4% wider stretched back onto it, and its copy on a2
assert enhance --in "$in" --dest "$dest" --focus "the trees"
assert grep -qx "dest=$dest size=1600x900 mode=photo tiles=1 work=$WORK/out.enhance" "$WORK/out"
assert test "$(size "$dest")" = 1600x900
assert test "$(diff_max "$in" "$dest")" -le 24
assert grep -q 'Give the strongest treatment to the trees' "$WORK/out.enhance/prompts.txt"
assert test "$(wc -l <"$WORK/calls.log")" -eq 2
assert grep -q -- '--vendor codex -- --account a1 .*--no-composite .*--edit .*/x-t00.png' "$WORK/calls.log"
assert grep -q -- '--vendor codex -- --account a2 .*--edit .*/x-t00.png' "$WORK/calls.log"
assert test -z "$(find "$WORK/out.enhance/out" -name 'pack-*')"

# restore as the upscaler: twice the size in 6 square tiles and a copy of each, as 3 tabs on each of the 4 free
# accounts, a copy never on its original's account
: >"$FAKE_LOG"
assert enhance --in "$in" --dest "$WORK/up.png" --mode restore --scale 2
assert test "$(size "$WORK/up.png")" = 3200x1800
assert test "$(diff_max "$WORK/up.enhance/x-base.png" "$WORK/up.png")" -le 24
assert test "$(grep -c -- '--each .* --each .* --each' "$WORK/calls.log")" -eq 4
assert test "$(grep -o -- '--account [a-z0-9]*' "$WORK/calls.log" | sort -u | tr '\n' ' ')" = '--account a1 --account a2 --account a3 --account p0 '
assert grep -q '6 tile(s) + 6 copies: 4 account(s) x 3 tab(s) in parallel' "$WORK/err"
assert test "$(find "$WORK/up.enhance/logs" -name 'pack-*.log' | wc -l)" -eq 4
assert test "$(grep -o 'x-t[0-9]*' "$WORK/calls.log" | sort | uniq -c | awk '{print $1}' | sort -u)" = 2
assert test "$(awk '{ split("", seen); for (i = 1; i <= NF; i++) if ($i ~ /x-t0[0-9]/ && seen[$i]++) print $i }' "$WORK/calls.log")" = ''
assert enhance --in "$in" --dest "$WORK/up.png" --mode restore --scale 2 --no-copies
assert grep -q '6 tile(s) + 0 copies: 4 account(s) x 2 tab(s) in parallel' "$WORK/err"
# memory for one browser only: no copies, the 6 tiles go as 4 tabs, then 2 on the next account once the first ends
: >"$FAKE_LOG"
ROOM_MB=2000 assert enhance --in "$in" --dest "$WORK/up.png" --mode restore --scale 2
assert grep -q '6 tile(s) + 0 copies: 1 account(s) x 4 tab(s)' "$WORK/err"
assert test "$(grep -c -- '--account a1 .*--each .*--each .*--each .*--each' "$WORK/calls.log")" -eq 1
assert test "$(grep -o -- '--each' "$WORK/calls.log" | wc -l)" -eq 6
# a busy account that sent nothing hands its tile to an unused one, at no attempt's cost
: >"$FAKE_LOG"
FAKE_GONE=a1 assert enhance --in "$in" --dest "$WORK/g.png" --no-copies
assert test "$(wc -l <"$WORK/calls.log")" -eq 2
assert grep -q -- '--account a2 ' "$WORK/calls.log"

# strong: one whole-frame fan-out with --takes, then every take's restore tiles in one pass
: >"$FAKE_LOG"
assert enhance --in "$in" --dest "$WORK/s.png" --mode strong --takes 2
assert test "$(size "$WORK/s.png")" = 1600x900
assert test "$(size "$WORK/s-2.png")" = 1600x900
assert grep -q -- '--takes 2' "$WORK/calls.log"
assert test "$(grep -c -- '--jobs' "$WORK/calls.log")" -eq 1
assert test "$(wc -l <"$WORK/calls.log")" -eq 5
assert grep -q '"aspect": "16:9"' "$WORK/s.enhance/whole-jobs.jsonl"

# the first render of a tile wins: the copy on a2 lands while a1 still renders, and a1's pack is stopped
: >"$FAKE_LOG"
started=$SECONDS
FAKE_SLOW=a1 assert enhance --in "$in" --dest "$WORK/c.png"
assert test $((SECONDS - started)) -lt 20
assert test "$(size "$WORK/c.png")" = 1600x900
assert grep -q 'a2: 1 of 1 tile(s)' "$WORK/err"
assert_gone() { ! kill -0 "$(cat "$WORK/$1")" 2>/dev/null; }
assert assert_gone a1
# a tab is taken the moment it lands: packs that run on after every tile landed are stopped, not waited for
: >"$FAKE_LOG"
started=$SECONDS
FAKE_HOLD=30 assert enhance --in "$in" --dest "$WORK/h.png" --mode restore --scale 2 --no-copies
assert test $((SECONDS - started)) -lt 25
assert test "$(size "$WORK/h.png")" = 3200x1800
assert assert_gone a3

# a tile that never comes back is retried once, then named
: >"$FAKE_LOG"
FAKE_FAIL="$WORK/f.enhance/tiles/x-t00.png" assert exits 1 --in "$in" --dest "$WORK/f.png"
assert test "$(wc -l <"$WORK/calls.log")" -eq 2
assert grep -q 'x-t00.png' "$WORK/err"
assert test ! -e "$WORK/f.png"
# every account walled mid-run
: >"$FAKE_LOG"
FAKE_EXIT=3 assert exits 3 --in "$in" --dest "$WORK/l.png"
assert test "$(wc -l <"$WORK/calls.log")" -eq 4

printf 'PASS: %s asserts\n' "$asserts"
