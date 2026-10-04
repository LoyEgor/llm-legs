#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CUTOUT="$ROOT/bin/image-cutout"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
cutout() { XDG_CACHE_HOME="$WORK/cache" "$CUTOUT" "$@" >"$WORK/out" 2>"$WORK/err"; }
exits() { local want=$1; shift; cutout "$@"; [ $? -eq "$want" ]; }
alpha_at() { magick "$1" -format "%[fx:int(255*p{$2}.a+0.5)]" info:; }

magick -size 64x48 xc:white "$WORK/plain.png"
in="$WORK/plain.png" dest="$WORK/out.png"
assert exits 2
assert exits 2 --in plain.png --dest "$dest"
assert exits 2 --in "$in" --dest "$WORK/out.jpg"
assert exits 2 --in "$in" --dest out.png
assert exits 2 --in "$WORK/missing.png" --dest "$dest"
assert exits 2 --in "$in" --dest "$WORK/no/such/dir/out.png"
for bad in 1.5,0.2 0.5 0.5,-0.1 a,b 0.5,0.5,0.5; do
  assert exits 2 --in "$in" --dest "$dest" --keep "$bad"
  assert exits 2 --in "$in" --dest "$dest" --drop "$bad"
done
assert exits 2 --in "$in" --dest "$dest" --keep
assert exits 2 --in "$in" --dest "$dest" --edge blurry
assert exits 2 --in "$in" --dest "$dest" --feather
assert test ! -e "$WORK/cache"

if [ "$(uname -s)" != Darwin ] || ! command -v swift >/dev/null 2>&1; then
  printf 'SKIP: macOS Vision and swift are unavailable here; %s flag asserts passed\n' "$asserts"
  exit 0
fi

mkdir "$WORK/fakebin" "$WORK/noswiftc"
cat >"$WORK/fakebin/swiftc" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$WORK/swiftc.log"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
printf '#!/bin/bash\necho stub "\$@"\n' >"\$out"
chmod +x "\$out"
EOF
chmod +x "$WORK/fakebin/swiftc"
fake() { PATH="$WORK/fakebin:$PATH" XDG_CACHE_HOME="$WORK/fakecache" "$1" --in "$in" --dest "$dest" >"$WORK/out" 2>"$WORK/err"; }
assert fake "$CUTOUT"
assert grep -qx "stub --in $in --dest $dest --edge soft" "$WORK/out"
assert test "$(wc -l <"$WORK/swiftc.log")" -eq 1
assert fake "$CUTOUT"
assert test "$(wc -l <"$WORK/swiftc.log")" -eq 1
assert test "$(ls "$WORK/fakecache/image-cutout" | wc -l)" -eq 1
mkdir -p "$WORK/edited/bin" "$WORK/edited/share"
cp "$CUTOUT" "$WORK/edited/bin/"
{ cat "$ROOT/share/image-cutout.swift"; printf '\n'; } >"$WORK/edited/share/image-cutout.swift"
assert fake "$WORK/edited/bin/image-cutout"
assert test "$(wc -l <"$WORK/swiftc.log")" -eq 2
assert test "$(ls "$WORK/fakecache/image-cutout" | wc -l)" -eq 2
assert test ! -e "$ROOT/share/image-cutout"

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s/swift.log"\n' "$WORK" >"$WORK/noswiftc/swift"
chmod +x "$WORK/noswiftc/swift"
for tool in dirname uname; do ln -s "$(command -v "$tool")" "$WORK/noswiftc/$tool"; done
assert env PATH="$WORK/noswiftc" "$BASH" "$CUTOUT" --in "$in" --dest "$dest" --keep 1,0.3 --drop .5,1.0 --holes
assert grep -qx "$ROOT/share/image-cutout.swift --in $in --dest $dest --edge soft --keep 1,0.3 --drop .5,1.0 --holes" "$WORK/swift.log"

assert exits 1 --in "$in" --dest "$dest"
assert grep -q 'Vision found no subject' "$WORK/err"
assert test ! -e "$dest"

two="$WORK/two.png"
magick -size 640x480 xc:white -fill '#d02020' -draw 'circle 160,240 160,140' \
  -fill '#2040d0' -draw 'rectangle 400,150 560,330' "$two"
assert cutout --in "$two" --dest "$WORK/dry.png" --dry-run
assert test ! -e "$WORK/dry.png"
assert test "$(grep -c '^instance=[12] center=' "$WORK/out")" -eq 2
assert grep -Eq '^dest=[^ ]+/dry.png size=640x480 instances=2/2 transparent=0\.[0-9]{3} seconds=[0-9.]+$' "$WORK/out"
assert cutout --in "$two" --dest "$WORK/all.png"
assert grep -q ' instances=2/2 ' "$WORK/out"
assert test "$(alpha_at "$WORK/all.png" 160,240)/$(alpha_at "$WORK/all.png" 480,240)/$(alpha_at "$WORK/all.png" 10,10)" = 255/255/0
assert cutout --in "$two" --dest "$WORK/left.png" --keep 0.25,0.5
assert grep -q ' instances=1/2 ' "$WORK/out"
assert test "$(alpha_at "$WORK/left.png" 160,240)/$(alpha_at "$WORK/left.png" 480,240)" = 255/0
assert cutout --in "$two" --dest "$WORK/near.png" --keep 0.97,0.5
assert test "$(alpha_at "$WORK/near.png" 160,240)/$(alpha_at "$WORK/near.png" 480,240)" = 0/255
assert cutout --in "$two" --dest "$WORK/dropped.png" --drop 0.25,0.5
assert grep -q ' instances=1/2 ' "$WORK/out"
assert test "$(alpha_at "$WORK/dropped.png" 160,240)/$(alpha_at "$WORK/dropped.png" 480,240)" = 0/255
assert exits 1 --in "$two" --dest "$WORK/none.png" --keep 0.25,0.5 --drop 0.26,0.5
assert grep -q 'leave no instance' "$WORK/err"

table="$WORK/table.png"
magick -size 640x480 gradient:'#e6e0d4'-'#cfc4b0' -fill '#80522f' -draw 'rectangle 0,325 640,480' \
  -fill '#2f6aa8' -draw 'ellipse 260,290 110,90 0,360' -fill '#d02020' -draw 'circle 490,340 490,380' "$table"
assert cutout --in "$table" --dest "$WORK/table-all.png"
assert grep -q ' instances=2/2 ' "$WORK/out"
assert test "$(alpha_at "$WORK/table-all.png" 260,290)/$(alpha_at "$WORK/table-all.png" 490,340)/$(alpha_at "$WORK/table-all.png" 10,10)/$(alpha_at "$WORK/table-all.png" 600,420)" = 255/255/0/0
assert cutout --in "$table" --dest "$WORK/table-ball.png" --keep 0.766,0.71
assert test "$(alpha_at "$WORK/table-ball.png" 260,290)/$(alpha_at "$WORK/table-ball.png" 490,340)" = 0/255
assert cutout --in "$table" --dest "$WORK/table-pot.png" --drop 0.766,0.71
assert test "$(alpha_at "$WORK/table-pot.png" 260,290)/$(alpha_at "$WORK/table-pot.png" 490,340)" = 255/0

magick -seed 7 -size 400x300 plasma:fractal -colorspace gray +level 10%,30% -fill '#1d3a24' -tint 60 -alpha off "$WORK/bg.png"
magick -size 400x300 xc:black -fill white -draw 'roundrectangle 60,60 340,240 30,30' -fill black \
  -draw 'roundrectangle 80,80 320,220 20,20' -fill white -draw 'polygon 120,200 200,95 280,200' \
  -draw 'rectangle 100,100 150,130' "$WORK/shape.png"
decal="$WORK/decal.png"
magick "$WORK/bg.png" \( -size 400x300 xc:'#e0208a' \) "$WORK/shape.png" -compose over -composite -alpha off "$decal"

same_kept_rgb() { # input output
  magick "$1" -alpha off -depth 8 rgb:"$WORK/in.rgb"
  magick "$2" -alpha off -depth 8 rgb:"$WORK/out.rgb"
  magick "$2" -alpha extract -depth 8 gray:"$WORK/out.a"
  python3 - "$WORK" <<'PY'
import sys
w = sys.argv[1]
i, o, a = (open(f"{w}/{n}", "rb").read() for n in ("in.rgb", "out.rgb", "out.a"))
kept = [k for k in range(len(a)) if a[k]]
partial = sum(1 for k in kept if a[k] < 255)
sys.exit(0 if kept and partial and all(i[3*k:3*k+3] == o[3*k:3*k+3] for k in kept) else 1)
PY
}
alpha_values() { magick "$1" -alpha extract -depth 8 -format '%k' info:; }
assert cutout --in "$decal" --dest "$WORK/soft.png"
assert same_kept_rgb "$decal" "$WORK/soft.png"
magick "$decal" -alpha set -channel A -evaluate set 90% +channel -depth 8 "$WORK/translucent.png"
assert cutout --in "$WORK/translucent.png" --dest "$WORK/soft-rgba.png"
assert same_kept_rgb "$WORK/translucent.png" "$WORK/soft-rgba.png"
assert test "$(magick "$WORK/soft-rgba.png" -alpha extract -format '%[fx:int(maxima*255+0.5)]' info:)" -eq 230
assert cutout --in "$decal" --dest "$WORK/hard.png" --edge hard
assert test "$(alpha_values "$WORK/hard.png")" -eq 2
assert test "$(alpha_values "$WORK/soft.png")" -gt 2

magick -size 1600x1200 xc:'#f4f4f0' -fill '#c03020' -draw 'circle 800,600 800,250' "$WORK/crisp.png"
assert cutout --in "$WORK/crisp.png" --dest "$WORK/crisp-out.png"
partial=$(magick "$WORK/crisp-out.png" -alpha extract -fx 'u>0.02&&u<0.98' -format '%[fx:int(mean*w*h)]' info:)
assert test "$partial" -lt 15000

magick "$two" -quality 95 "$WORK/plain.jpg"
python3 - "$WORK/plain.jpg" "$WORK/rotated.jpg" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
exif = bytes.fromhex("ffe10022457869660000") + bytes.fromhex("4d4d002a00000008000101120003000000010006000000000000")
open(sys.argv[2], "wb").write(data[:2] + exif + data[2:])
PY
assert cutout --in "$WORK/rotated.jpg" --dest "$WORK/rotated.png" --keep 0.5,0.25
assert grep -q ' size=480x640 instances=1/2 ' "$WORK/out"
assert test "$(alpha_at "$WORK/rotated.png" 240,160)/$(alpha_at "$WORK/rotated.png" 240,480)" = 255/0

opaque_counts() { # output -> "<opaque pink pixels>/<pink pixels> <opaque background pixels inside the frame>"
  magick "$WORK/shape.png" -depth 8 gray:"$WORK/shape.g"
  magick "$1" -alpha extract -depth 8 gray:"$WORK/out.a"
  python3 - "$WORK" <<'PY'
import sys
w = sys.argv[1]
s, a = open(f"{w}/shape.g", "rb").read(), open(f"{w}/out.a", "rb").read()
inner = [y * 400 + x for y in range(84, 217) for x in range(84, 317)]
pink = [k for k in range(len(s)) if s[k] == 255]
print(f"{sum(1 for k in pink if a[k] == 255)}/{len(pink)} {sum(1 for k in inner if s[k] == 0 and a[k] >= 128)}")
PY
}
assert cutout --in "$decal" --dest "$WORK/kept-holes.png"
read -r pink_plain holes_plain < <(opaque_counts "$WORK/kept-holes.png")
assert cutout --in "$decal" --dest "$WORK/holes.png" --holes
assert grep -Eq ' holes=0\.[0-9]{3} seconds=' "$WORK/out"
read -r pink_holes holes_left < <(opaque_counts "$WORK/holes.png")
assert test "$holes_left" -eq 0
if [ "$holes_plain" -gt 0 ]; then
  assert test "${pink_holes%/*}" -ge "$(( ${pink_plain%/*} * 99 / 100 ))"
else
  printf 'NOTE: Vision already removed every hole of the decal fixture (pink %s); --holes ran on nothing\n' "$pink_plain"
fi

printf 'PASS: %s asserts\n' "$asserts"
