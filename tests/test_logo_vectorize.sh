#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VECTORIZE="$ROOT/bin/logo-vectorize"
REAL_PY=/Volumes/Work/Projects/logo-vectorizer-bench/.venv/bin/python
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
vectorize() { LOGO_BENCH="$WORK/bench" "$VECTORIZE" "$@" >"$WORK/out" 2>"$WORK/err"; }
exits() { local want=$1; shift; vectorize "$@"; [ $? -eq "$want" ]; }

magick -size 1024x768 xc:white -fill '#d02020' -draw 'circle 512,384 512,184' "$WORK/big.png"
magick -size 300x200 xc:white -fill '#2040d0' -draw 'rectangle 50,50 250,150' "$WORK/small.png"
printf 'not an image\n' >"$WORK/text.png"
in="$WORK/big.png" dest="$WORK/out.svg"
assert exits 2
assert exits 2 --in big.png --dest "$dest"
assert exits 2 --in "$in" --dest out.svg
assert exits 2 --in "$in" --dest "$WORK/out.png"
assert exits 2 --in "$WORK/missing.png" --dest "$dest"
assert exits 2 --in "$in" --dest "$WORK/no/such/dir/out.svg"
assert exits 2 --in "$in" --dest "$dest" --size 256
assert exits 2 --in "$in" --dest "$dest" --size
assert exits 2 --in "$in" --dest "$dest" --colors 4
assert exits 1 --in "$in" --dest "$dest"
assert grep -q 'no stable champion' "$WORK/err"

if [ ! -x "$REAL_PY" ] || ! "$REAL_PY" -c 'import PIL' 2>/dev/null; then
  printf 'SKIP: the logo bench python is unavailable here; %s flag asserts passed\n' "$asserts"
  exit 0
fi

mkdir -p "$WORK/bench/.venv/bin" "$WORK/bench/tracers/champ99"
printf '#!/bin/bash\nexec %q "$@"\n' "$REAL_PY" >"$WORK/bench/.venv/bin/python"
cat >"$WORK/bench/tracers/champ99/run.sh" <<EOF
#!/bin/bash
cp "\$1" "$WORK/seen.\${1##*.}"
printf '%s\n' "\$BENCH_IN_SLOT" >"$WORK/slot"
[ -e "$WORK/fail" ] && { echo 'stub tracer failed' >&2; exit 3; }
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 384" width="512" height="384"><rect width="1" height="1"/></svg>' >"\$2"
EOF
chmod +x "$WORK/bench/.venv/bin/python" "$WORK/bench/tracers/champ99/run.sh"
ln -s champ99 "$WORK/bench/tracers/stable"

assert vectorize --in "$in" --dest "$dest" --dry-run
assert grep -qx 'champion=champ99 source=1024x768 traced=512x384 size=512' "$WORK/out"
assert test ! -e "$dest"
assert test ! -e "$WORK/seen.png"
assert vectorize --in "$in" --dest "$dest" --dry-run --size native
assert grep -qx 'champion=champ99 source=1024x768 traced=1024x768 size=native' "$WORK/out"
assert exits 2 --in "$WORK/text.png" --dest "$dest"

assert vectorize --in "$in" --dest "$dest"
assert grep -Eq "^svg=$dest champion=champ99 source=1024x768 traced=512x384 seconds=[0-9]+$" "$WORK/out"
assert test "$(magick identify -format %wx%h "$WORK/seen.png")" = 512x384
assert grep -q '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 384" width="1024" height="768">' "$dest"
assert test "$(grep -o 'width="[0-9]*"' "$dest" | head -1)" = 'width="1024"'
assert test "$(cat "$WORK/slot")" = 1

assert vectorize --in "$WORK/small.png" --dest "$WORK/small.svg"
assert cmp -s "$WORK/small.png" "$WORK/seen.png"
assert grep -q 'width="300" height="200"' "$WORK/small.svg"
magick "$WORK/small.png" -quality 90 "$WORK/small.jpg"
assert vectorize --in "$WORK/small.jpg" --dest "$WORK/small-jpg.svg"
assert cmp -s "$WORK/small.jpg" "$WORK/seen.jpg"
magick "$WORK/small.png" "$WORK/small.webp"
assert vectorize --in "$WORK/small.webp" --dest "$WORK/small-webp.svg"
assert test "$(magick identify -format %wx%h "$WORK/seen.png")" = 300x200

touch "$WORK/fail"
assert exits 1 --in "$in" --dest "$WORK/failed.svg"
assert grep -q 'stub tracer failed' "$WORK/err"
assert test ! -e "$WORK/failed.svg"

printf 'PASS: %s asserts\n' "$asserts"
