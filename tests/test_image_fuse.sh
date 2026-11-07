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
fuse() { "$UV" run -q --script "$ROOT/share/image_fuse.py" "$@" >"$WORK/out" 2>"$WORK/err"; }
rgba() { # image x,y -> r,g,b,a 0..255
  magick "$1" -depth 8 -format "%[fx:int(255*p{$2}.r+0.5)],%[fx:int(255*p{$2}.g+0.5)],%[fx:int(255*p{$2}.b+0.5)],%[fx:int(255*p{$2}.a+0.5)]" info:
}
scene() { # dir window-rectangle: an input, a cut-out that drew the window solid, a keyer that sees through it
  local dir=$1 window=$2
  mkdir -p "$dir"
  # The input: a dark body on a green screen, the screen seen through its window.
  magick -size 400x300 xc:'#10e010' -fill '#2a2a2a' -draw 'rectangle 60,60 340,240' \
    -fill '#3a8a3a' -draw "rectangle $window" -alpha off "$dir/base.png"
  # The cut-out laid back: the input's pixels in the body, the window drawn solid and light, alpha the body.
  magick "$dir/base.png" -fill '#8aa08a' -draw "rectangle $window" \
    \( -size 400x300 xc:black -fill white -draw 'rectangle 60,60 340,240' \) \
    -alpha off -compose CopyOpacity -composite "PNG32:$dir/gpt.png"
  # The keyer: 16-bit alpha, the window 40 % opaque; its colour runs its own policy on the opaque body (+20).
  magick -size 400x300 xc:black -fill white -draw 'rectangle 60,60 340,240' -fill '#666666' \
    -draw "rectangle $window" -colorspace Gray -depth 16 "$dir/alpha.png"
  magick -size 400x300 xc:'#10e010' -fill '#3e3e3e' -draw 'rectangle 60,60 340,240' \
    -fill '#303030' -draw "rectangle $window" -alpha off "$dir/fg.png"
}
run_scene() { # dir [args...]
  local dir=$1
  shift
  fuse --base "$dir/base.png" --gpt "$dir/gpt.png" --key-alpha "$dir/alpha.png" --key-fg "$dir/fg.png" \
    --out "$dir/out.png" "$@"
}

# A window framed by the body: the pane comes from the keyer, everything else stays the cut-out's bytes.
scene "$WORK/framed" '150,100 250,160'
assert run_scene "$WORK/framed" --overlay "$WORK/framed/cand.png"
assert grep -Eqx "fuse=glass taken=1 candidates=1:[0-9]+:closed step=[0-9]+ overlay=$WORK/framed/cand.png" "$WORK/out"
assert [ "$(rgba "$WORK/framed/out.png" 200,130)" = "48,48,48,102" ]
assert [ "$(rgba "$WORK/framed/out.png" 100,200)" = "$(rgba "$WORK/framed/gpt.png" 100,200)" ]
assert [ "$(rgba "$WORK/framed/out.png" 145,130)" = "$(rgba "$WORK/framed/gpt.png" 145,130)" ]
assert [ "$(rgba "$WORK/framed/out.png" 20,20)" = "$(rgba "$WORK/framed/gpt.png" 20,20)" ]
assert [ -s "$WORK/framed/cand.png" ]

# Picked by number: none taken writes nothing, the cut-out is delivered as is.
rm -f "$WORK/framed/out.png"
assert run_scene "$WORK/framed" --take none
assert grep -Eqx 'fuse=skipped reason=none-taken candidates=1:[0-9]+:closed' "$WORK/out"
assert [ ! -e "$WORK/framed/out.png" ]

# A pane that reaches the outline has no frame to cut along: refused, never cut across the glass.
scene "$WORK/open" '150,100 340,160'
assert run_scene "$WORK/open"
assert grep -Eqx 'fuse=skipped reason=no-frame candidates=1:[0-9]+:open' "$WORK/out"
assert [ ! -e "$WORK/open/out.png" ]

# No see-through glass: nothing to do.
scene "$WORK/none" '150,100 250,160'
magick -size 400x300 xc:black -fill white -draw 'rectangle 60,60 340,240' -colorspace Gray -depth 16 "$WORK/none/alpha.png"
assert run_scene "$WORK/none"
assert grep -Eqx 'fuse=skipped reason=no-glass candidates=' "$WORK/out"

# A keyer output in another frame is refused with exit 1; a bad --take is a usage error.
magick "$WORK/framed/fg.png" -resize 200x150! "$WORK/framed/small.png"
fuse --base "$WORK/framed/base.png" --gpt "$WORK/framed/gpt.png" --key-alpha "$WORK/framed/alpha.png" \
  --key-fg "$WORK/framed/small.png" --out "$WORK/framed/x.png"
assert [ $? -eq 1 ]
assert grep -q "the input's frame" "$WORK/err"
assert [ ! -e "$WORK/framed/x.png" ]
run_scene "$WORK/framed" --take first
assert [ $? -eq 2 ]

printf 'PASS: %d asserts; a framed window taken from the keyer pixel for pixel (its alpha and unmixed colour, the body and the outside the cut-out bytes, the keyer'"'"'s own colour on opaque pixels ignored), --take none and a pane reaching the outline deliver nothing, no glass skipped, a keyer in another frame exit 1, a bad --take exit 2\n' "$asserts"
