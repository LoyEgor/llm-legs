#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
UV=$(command -v uv || printf /opt/homebrew/bin/uv)
matte() { "$UV" run -q --script "$ROOT/share/image_matte.py" "$@" >"$WORK/out" 2>"$WORK/err"; }
pixels() { # image x,y... -> its size, then each point's colour, alpha dropped, space-separated
  local format='%wx%h' point image=$1
  shift
  for point; do format+=" %[pixel:p{$point}]"; done
  magick "$image" -alpha off -depth 8 -format "$format" info:
}
alphas() { # image x,y... -> each point's alpha 0..255, space-separated
  local format='' point image=$1
  shift
  for point; do format+="%[fx:int(255*p{$point}+0.5)] "; done
  magick "$image" -alpha extract -depth 8 -format "$format" info:
}
channel_gap() { # image-a image-b x,y -> largest channel difference in 0..255
  magick "$1" "$2" -alpha off -crop "1x1+${3%,*}+${3#*,}" +repage -compose difference -composite \
    -format '%[fx:int(255*max(max(r,g),b)+0.5)]' info:
}
cutout_of() { # source dest: a Remove BG stand-in, reframed (x1.08, shifted), brighter, an ellipse of alpha
  magick "$1" -virtual-pixel edge -distort SRT '240,180 1.08 0 252,170' -modulate 108 +write "$WORK/cut-rgb.png" \
    \( -size 480x360 xc:black -fill white -draw 'ellipse 252,170 162,119 0,360' \) \
    -alpha off -compose CopyOpacity -composite "PNG32:$2"
}

magick -size 480x360 -seed 3 xc: +noise Random -blur 0x2.5 -auto-level -alpha off -depth 8 "$WORK/base.png"
cutout_of "$WORK/base.png" "$WORK/cut.png"
assert matte --base "$WORK/base.png" --edited "$WORK/cut.png" --out "$WORK/out.png"
assert grep -Eqx 'composite=matte changed=[0-9.]+%' "$WORK/out"
read -r size got_a got_b <<<"$(pixels "$WORK/out.png" 240,180 180,150)"
read -r _ want_a want_b <<<"$(pixels "$WORK/base.png" 240,180 180,150)"
read -r alpha_in alpha_corner alpha_far <<<"$(alphas "$WORK/out.png" 240,180 6,6 470,350)"
assert test "$size" = 480x360
assert test "$got_a" = "$want_a"
assert test "$got_b" = "$want_b"
assert test "$alpha_in" = 255
assert test "$alpha_corner" = 0
assert test "$alpha_far" = 0
assert test "$(channel_gap "$WORK/out.png" "$WORK/base.png" 384,180)" -le 14
assert test "$(channel_gap "$WORK/cut-rgb.png" "$WORK/base.png" 240,180)" -gt 0

# Another picture entirely: nothing to lay back, nothing written.
magick -size 480x360 -seed 11 xc: +noise Random -blur 0x2.5 -auto-level -alpha off -depth 8 "$WORK/other.png"
cutout_of "$WORK/other.png" "$WORK/other-cut.png"
assert matte --base "$WORK/base.png" --edited "$WORK/other-cut.png" --out "$WORK/none.png"
assert grep -qx 'composite=skipped reason=unregistered' "$WORK/out"
assert test ! -e "$WORK/none.png"
assert test "$(matte --base "$WORK/missing.png" --edited "$WORK/cut.png" --out "$WORK/none.png"; echo $?)" = 1

# Wired through share/image-leg.sh: only an explicit --composite lays a Remove BG cutout back.
# The plan's composite copy is removed by image_leg_exit, which take() does not trap: TMPDIR keeps it in $WORK.
mkdir -p "$WORK/tmp"
take() { # dest; env ASK, OFF
  (IMAGE_LEG_TOOL=codex-image account=acct TMPDIR="$WORK/tmp"
    . "$ROOT/share/image-leg.sh"
    IMAGE_LEG_COMPOSITE_ASK=${ASK:-} IMAGE_LEG_COMPOSITE_OFF=${OFF:-} IMAGE_LEG_COMPOSITE_ARGS=()
    image_leg_composite_plan codex '' matte "$WORK/base.png"
    cp "$WORK/cut.png" "$1"
    IMAGE_LEG_COMPOSITE_LINES=$(image_leg_composite_take "$ROOT" "$1")
    printf '%s\n' "$IMAGE_LEG_COMPOSITE_LINES"
    image_leg_composite_record) >"$WORK/out" 2>"$WORK/err"
}
ASK=auto assert take "$WORK/asked.png"
assert grep -Eqx 'composite=matte changed=[0-9.]+%' "$WORK/out"
assert grep -qx "rendered=$WORK/asked.rendered.png" "$WORK/out"
assert grep -Eqx '\{"kind":"matte","changed":[0-9.]+,"reason":null\}' "$WORK/out"
assert cmp "$WORK/cut.png" "$WORK/asked.rendered.png"
read -r _ asked_a <<<"$(pixels "$WORK/asked.png" 240,180)"
assert test "$asked_a" = "$want_a"
assert take "$WORK/default.png"
assert test "$(grep -c '^composite=' "$WORK/out")" -eq 0
assert grep -qx '{"kind":"skipped","changed":null,"reason":"transparent"}' "$WORK/out"
assert cmp "$WORK/cut.png" "$WORK/default.png"
assert test ! -e "$WORK/default.rendered.png"
rc=0; ASK=0.1,0.1,0.5,0.5 take "$WORK/boxed.png" || rc=$?
assert test "$rc" -eq 2
assert grep -q -- '--composite on --remove-bg lays the cutout back onto the whole input' "$WORK/err"
assert grep -q 'repaint=matte' "$ROOT/bin/codex-image"

printf 'PASS: %s asserts; a reframed, brighter cutout laid back in the input frame (input pixels inside, its alpha, the edge toned to the input), an unrelated cutout skipped with nothing written, an unreadable input exit 1, and Remove BG matte only on an explicit --composite (default delivers the cutout untouched, a rectangle refused)\n' "$asserts"
