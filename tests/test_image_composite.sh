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
compose() { "$UV" run -q --script "$ROOT/share/image_composite.py" "$@" >"$WORK/out" 2>"$WORK/err"; }
pixel() { magick "$1" -depth 8 -format "%[pixel:p{$2}]" info:; }
channel_gap() { # image-a image-b x,y -> largest channel difference in 0..255
  magick "$1" "$2" -crop "1x1+${3%,*}+${3#*,}" +repage -compose difference -composite \
    -format '%[fx:int(255*max(max(r,g),b)+0.5)]' info:
}
within() { [ "$(channel_gap "$1" "$2" "$3")" -le "$4" ]; }

base="$WORK/base.png"
magick -size 400x400 gradient:'#304a60-#c0a080' -fill '#556b2f' -draw 'circle 120,280 120,330' \
  -fill '#e0d0c0' -draw 'rectangle 40,40 140,90' -alpha off -depth 8 "$base"
drift() { magick "$1" -channel R -evaluate add 5% -channel G -evaluate add 2% +channel "$2"; }

# A tint, not a solid fill: the change must stand out against the drift only once that is subtracted.
magick "$base" \( +clone -crop 61x61+250+250 +repage -fill '#d02020' -colorize 25% \) -geometry +250+250 -composite "$WORK/intended.png"
drift "$WORK/intended.png" "$WORK/local.png"
assert compose --base "$base" --edited "$WORK/local.png" --out "$WORK/local-out.png"
assert grep -Eq '^composite=auto changed=([1-9]|10)\.[0-9]%$' "$WORK/out"
assert test "$(pixel "$WORK/local-out.png" 10,10)" = "$(pixel "$base" 10,10)"
assert test "$(pixel "$WORK/local-out.png" 380,200)" = "$(pixel "$base" 380,200)"
assert within "$WORK/local-out.png" "$WORK/intended.png" 280,280 2
assert within "$WORK/local-out.png" "$WORK/intended.png" 250,280 1
assert within "$WORK/local-out.png" "$base" 248,280 3

# A re-render: different grain everywhere plus two 3x3 sparkles; only the tinted square is the edit.
magick -size 400x400 gradient:'#304a60-#c0a080' -alpha off -depth 8 "$WORK/flat.png"
magick "$WORK/flat.png" -seed 1 -attenuate 0.5 +noise Gaussian -depth 8 "$WORK/grain.png"
magick "$WORK/flat.png" -seed 2 -attenuate 0.5 +noise Gaussian \
  \( +clone -crop 61x61+250+250 +repage -fill '#d02020' -colorize 40% \) -geometry +250+250 -composite \
  -fill white -draw 'rectangle 59,329 61,331' -draw 'rectangle 349,39 351,41' -depth 8 "$WORK/regrain.png"
assert compose --base "$WORK/grain.png" --edited "$WORK/regrain.png" --out "$WORK/grain-out.png"
assert grep -Eq '^composite=auto changed=2\.[0-9]%$' "$WORK/out"
assert test "$(pixel "$WORK/grain-out.png" 60,330)" = "$(pixel "$WORK/grain.png" 60,330)"
assert test "$(pixel "$WORK/grain-out.png" 350,40)" = "$(pixel "$WORK/grain.png" 350,40)"
assert within "$WORK/grain-out.png" "$WORK/regrain.png" 280,280 3

drift "$base" "$WORK/shift.png"
assert compose --base "$base" --edited "$WORK/shift.png" --out "$WORK/shift-out.png"
assert grep -qx 'composite=refused reason=no-local-change changed=0.0% kind=auto' "$WORK/out"
assert cmp "$WORK/shift.png" "$WORK/shift-out.png"

magick "$base" -fill '#2040d0' -draw 'rectangle 0,0 399,330' "$WORK/global.png"
assert compose --base "$base" --edited "$WORK/global.png" --out "$WORK/global-out.png"
assert grep -Eq '^composite=refused reason=global changed=(6[0-9]|[7-9][0-9]|100)\.[0-9]% kind=auto$' "$WORK/out"
assert cmp "$WORK/global.png" "$WORK/global-out.png"

magick "$base" -fill "#2040d0" -colorize 70% "$WORK/recoloured.png"
assert compose --base "$base" --edited "$WORK/recoloured.png" --out "$WORK/region-out.png" --mask 0.5,0.25,0.4,0.5
assert grep -Eq '^composite=region changed=(19\.[5-9]|20\.[0-5])%$' "$WORK/out"
assert within "$WORK/region-out.png" "$WORK/recoloured.png" 280,200 1
assert within "$WORK/region-out.png" "$WORK/recoloured.png" 210,110 1
assert within "$WORK/region-out.png" "$WORK/recoloured.png" 350,290 1
for outside in 190,200 280,310 370,200 280,90; do
  assert test "$(pixel "$WORK/region-out.png" "$outside")" = "$(pixel "$base" "$outside")"
done
assert compose --base "$base" --edited "$WORK/recoloured.png" --out "$WORK/wide-out.png" --mask 0,0,0.9,0.9
assert grep -qx 'composite=refused reason=global changed=81.0% kind=region' "$WORK/out"
assert cmp "$WORK/recoloured.png" "$WORK/wide-out.png"

magick "$base" -fill '#d02020' -draw 'rectangle 40,180 90,230' -draw 'rectangle 300,60 350,110' "$WORK/two.png"
assert compose --base "$base" --edited "$WORK/two.png" --out "$WORK/points-out.png" --point '0.16,0.5=make it red'
assert grep -Eq '^composite=points changed=[0-9.]+%$' "$WORK/out"
assert within "$WORK/points-out.png" "$WORK/two.png" 65,205 2
assert test "$(pixel "$WORK/points-out.png" 325,85)" = "$(pixel "$base" 325,85)"

compose --base "$base" --edited "$WORK/two.png" --out "$WORK/bad.png" --mask 0.5,0.5,0.6,0.2
assert test $? -eq 2
assert test ! -e "$WORK/bad.png"

# Lineage: the sidecar chain and the session index, through the shared helpers.
export IMAGE_LEG_LOG="$WORK/legs/legs.jsonl"
sidecar() { (. "$ROOT/share/image-leg.sh"; image_leg_sidecar "$1"); }
lineage() { (account=acct; . "$ROOT/share/image-leg.sh"; image_leg_lineage "$@") >"$WORK/out" 2>"$WORK/err"; }
session_input() { (. "$ROOT/share/image-leg.sh"; image_leg_session_input "$@"); }
cp "$base" "$WORK/gen.png"
stale=$(sidecar "$WORK/gen.png")
mkdir -p "${stale%/*}"
printf '{"root":"%s","depth":3,"edits":[]}\n' "$WORK/older.png" >"$stale"
assert lineage gemini cli "$WORK/gen.png" conv-1 'a portrait' '' ''
assert grep -qx "edit_depth=0 root=$WORK/gen.png" "$WORK/out"
assert test ! -e "$(sidecar "$WORK/gen.png")"
assert test "$(session_input gemini conv-1)" = "$WORK/gen.png"
cp "$base" "$WORK/e1.png"
assert lineage gemini cli "$WORK/e1.png" conv-1 'red hair' '0.1,0.1,0.5,0.5' '' "$(session_input gemini conv-1)"
assert grep -qx "edit_depth=1 root=$WORK/gen.png" "$WORK/out"
assert test "$(session_input gemini conv-1)" = "$WORK/e1.png"
cp "$base" "$WORK/e2.png"
assert lineage codex web "$WORK/e2.png" chat-2 '' '' $'0.5,0.8=moon pendant\n0.2,0.2=strap' "$WORK/plain.png" "$WORK/e1.png"
assert grep -qx "edit_depth=2 root=$WORK/gen.png" "$WORK/out"
assert test "$(jq -c '.edits' "$(sidecar "$WORK/e2.png")")" = '[{"prompt":"red hair","region":"0.1,0.1,0.5,0.5","points":[],"route":"cli","vendor":"gemini","account":"acct"},{"prompt":"","region":null,"points":["0.5,0.8=moon pendant","0.2,0.2=strap"],"route":"web","vendor":"codex","account":"acct"}]'
cp "$base" "$WORK/plain.png"
cp "$base" "$WORK/p1.png"
assert lineage gemini cli "$WORK/p1.png" none 'bluer' '' '' "$WORK/plain.png"
assert grep -qx "edit_depth=1 root=$WORK/plain.png" "$WORK/out"
assert test "$(jq -r '.edits | length' "$(sidecar "$WORK/p1.png")")" = 1
assert test ! -e "$WORK/legs/sessions/gemini/none"
cp "$base" "$WORK/legacy.png"
printf '{"root":"%s","depth":2,"edits":[]}\n' "$WORK/older.png" >"$WORK/legacy.png.edit.json"
assert lineage gemini cli "$WORK/l1.png" none 'warmer' '' '' "$WORK/legacy.png"
assert grep -qx "edit_depth=3 root=$WORK/older.png" "$WORK/out"
assert test "$(jq -r '.depth' "$(sidecar "$WORK/l1.png")")" = 3
aged=$(sidecar "$WORK/aged.png")
mkdir -p "${aged%/*}"
: >"$aged"
touch -t 202001010000 "$aged"
assert lineage gemini cli "$WORK/l2.png" none 'cooler' '' '' "$WORK/l1.png"
assert test ! -e "$aged" -a ! -d "${aged%/*}"
assert test "$(find "$WORK" -maxdepth 1 -name '*.edit.json' ! -name 'legacy.png.edit.json' | wc -l | tr -d ' ')" = 0
rm "$WORK/e1.png"
assert test -z "$(session_input gemini conv-1)"

# Aspect: an edited image of another shape is no edit of this input, delivered as is.
magick "$WORK/local.png" -crop 400x300+0+0 +repage "$WORK/wide.png"
assert compose --base "$base" --edited "$WORK/wide.png" --out "$WORK/wide-out.png"
assert grep -qx 'composite=skipped reason=aspect-changed from=400x400 to=400x300' "$WORK/out"
assert cmp "$WORK/wide.png" "$WORK/wide-out.png"

# The shared default decision (share/image-leg.sh): every vendor, the same state, the same answer.
decide() { # vendor resume repaint render dest [ref...]; env ASK, OFF, MASK (a wrapper's --region)
  local vendor=$1 resume=$2 repaint=$3 render=$4 dest=$5
  shift 5
  (IMAGE_LEG_TOOL='' account=acct
    . "$ROOT/share/image-leg.sh"
    trap image_leg_exit EXIT
    IMAGE_LEG_COMPOSITE_ASK=${ASK:-} IMAGE_LEG_COMPOSITE_OFF=${OFF:-}
    [ -z "${MASK:-}" ] || IMAGE_LEG_COMPOSITE_ARGS=(--mask "$MASK")
    image_leg_composite_plan "$vendor" "$resume" "$repaint" "$@"
    cp "$render" "$dest"
    IMAGE_LEG_COMPOSITE_LINES=$(image_leg_composite_take "$ROOT" "$dest")
    image_leg_lineage "$vendor" cli "$dest" none prompt '' '' \
      ${IMAGE_LEG_COMPOSITE_INPUT:+"$IMAGE_LEG_COMPOSITE_INPUT"} "$@") >"$WORK/out" 2>"$WORK/err"
}
cp "$base" "$WORK/input.png"
cp "$base" "$WORK/input2.png"
for vendor in codex gemini grok; do
  cp "$base" "$WORK/$vendor-last.png"
  assert lineage "$vendor" cli "$WORK/$vendor-last.png" "sess-$vendor" first '' ''
done
scenario() { # name render [decide args after render: resume repaint refs...]
  local name=$1 render=$2 vendor resume repaint
  shift 2
  resume=$1 repaint=$2
  shift 2
  for vendor in codex gemini grok; do
    rc=0
    decide "$vendor" "${resume:+$resume-$vendor}" "$repaint" "$render" "$WORK/$name-$vendor.png" "$@" || rc=$?
    printf 'rc=%s\n' "$rc" >>"$WORK/out"
    sed -e "s/-$vendor\././g" -e "s/$vendor-last/vendor-last/g" "$WORK/out" >"$WORK/$name-$vendor.out"
    [ ! -e "$(sidecar "$WORK/$name-$vendor.png")" ] ||
      jq -c '.edits[-1].composite // "none"' "$(sidecar "$WORK/$name-$vendor.png")" >>"$WORK/$name-$vendor.out"
  done
  assert cmp "$WORK/$name-codex.out" "$WORK/$name-gemini.out"
  assert cmp "$WORK/$name-codex.out" "$WORK/$name-grok.out"
}
applied() { # name
  assert grep -Eq '^composite=auto changed=([1-9]|10)\.[0-9]%$' "$WORK/$1-codex.out"
  assert grep -qx "rendered=$WORK/$1.rendered.png" "$WORK/$1-codex.out"
  assert cmp "$WORK/local.png" "$WORK/$1-grok.rendered.png"
  assert within "$WORK/$1-gemini.png" "$WORK/intended.png" 280,280 2
  assert test "$(pixel "$WORK/$1-grok.png" 10,10)" = "$(pixel "$base" 10,10)"
  assert grep -Eqx '\{"kind":"auto","changed":([1-9]|10)\.[0-9],"reason":null\}' "$WORK/$1-codex.out"
}
untouched() { # name render
  assert test ! -e "$WORK/$1-gemini.rendered.png"
  assert cmp "$2" "$WORK/$1-grok.png"
}
scenario resume "$WORK/local.png" sess false
applied resume
scenario ref "$WORK/local.png" '' false "$WORK/input.png"
applied ref
scenario two "$WORK/local.png" '' false "$WORK/input.png" "$WORK/input2.png"
assert grep -qx 'composite=skipped reason=several-inputs' "$WORK/two-codex.out"
assert grep -qx '{"kind":"skipped","changed":null,"reason":"several-inputs"}' "$WORK/two-codex.out"
untouched two "$WORK/local.png"
scenario new "$WORK/local.png" '' false
assert grep -qx 'composite=skipped reason=new-generation' "$WORK/new-codex.out"
assert grep -qx "edit_depth=0 root=$WORK/new.png" "$WORK/new-codex.out"
untouched new "$WORK/local.png"
scenario unknown "$WORK/local.png" gone false
assert grep -qx 'composite=skipped reason=input-unknown' "$WORK/unknown-codex.out"
untouched unknown "$WORK/local.png"
scenario keyed "$WORK/local.png" '' true "$WORK/input.png"
assert_none() { ! grep -q '^composite=' "$1"; }
assert assert_none "$WORK/keyed-codex.out"
assert grep -qx '{"kind":"skipped","changed":null,"reason":"transparent"}' "$WORK/keyed-codex.out"
untouched keyed "$WORK/local.png"
OFF=true scenario off "$WORK/local.png" '' false "$WORK/input.png"
assert assert_none "$WORK/off-codex.out"
assert grep -qx '{"kind":"skipped","changed":null,"reason":"opted-out"}' "$WORK/off-codex.out"
untouched off "$WORK/local.png"
scenario global "$WORK/global.png" '' false "$WORK/input.png"
assert grep -Eqx 'composite=refused reason=global changed=(6[0-9]|[7-9][0-9]|100)\.[0-9]% kind=auto' "$WORK/global-codex.out"
assert grep -Eqx '\{"kind":"refused","changed":(6[0-9]|[7-9][0-9]|100)(\.[0-9])?,"reason":"global"\}' "$WORK/global-codex.out"
untouched global "$WORK/global.png"
scenario wide "$WORK/wide.png" '' false "$WORK/input.png"
assert grep -qx 'composite=skipped reason=aspect-changed from=400x400 to=400x300' "$WORK/wide-codex.out"
untouched wide "$WORK/wide.png"
ASK=auto scenario forced "$WORK/local.png" '' false "$WORK/input.png" "$WORK/input2.png"
assert grep -Eq '^composite=auto changed=' "$WORK/forced-codex.out"
MASK=0.5,0.5,0.4,0.4 scenario marked "$WORK/local.png" '' false "$WORK/input.png"
assert grep -qx 'composite=region changed=16.0%' "$WORK/marked-codex.out"
ASK=auto MASK=0.5,0.5,0.4,0.4 scenario askwins "$WORK/local.png" '' false "$WORK/input.png"
assert grep -Eq '^composite=auto changed=' "$WORK/askwins-codex.out"
ASK=0.5,0.5,0.4,0.4 scenario boxed "$WORK/local.png" '' false "$WORK/input.png"
assert grep -qx 'composite=region changed=16.0%' "$WORK/boxed-codex.out"
for refusal in "ASK=auto OFF=true||false|$WORK/input.png" "ASK=auto||true|$WORK/input.png" "ASK=auto||false|" \
  "ASK=0.5,0.5,0.6,0.1||false|$WORK/input.png"; do
  IFS='|' read -r env resume repaint ref <<<"$refusal"
  rc=0
  env $env bash -c "$(declare -f decide); ROOT='$ROOT' WORK='$WORK'; decide gemini '$resume' $repaint '$WORK/local.png' '$WORK/refused.png' $ref" || rc=$?
  assert test "$rc" -eq 2
  assert test ! -e "$WORK/refused.png"
done
: >"$WORK/stale.rendered.png"
(. "$ROOT/share/image-leg.sh"; IMAGE_LEG_COMPOSITE_SKIP=new-generation
  image_leg_composite_take "$ROOT" "$WORK/stale.png" variant) >"$WORK/out" 2>"$WORK/err"
assert test ! -s "$WORK/out"
assert test ! -e "$WORK/stale.rendered.png"
assert test -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'image-leg-composite.*' -newer "$base" -print -quit)"
for wrapper in codex-image gemini-image grok-image; do
  assert grep -q 'image_leg_composite_plan ' "$ROOT/bin/$wrapper"
  assert grep -q 'IMAGE_LEG_COMPOSITE_LINES=$(image_leg_composite_take "$root" "$dest")' "$ROOT/bin/$wrapper"
  assert grep -q -- '--composite | --composite=\* | --no-composite) *$' "$ROOT/bin/$wrapper"
  assert_none "$ROOT/bin/$wrapper"
  assert test "$(grep -c 'image_composite.py' "$ROOT/bin/$wrapper")" -eq 0
done
assert grep -q 'image_leg_composite_take "$1" "$out" variant' "$ROOT/share/image-leg.sh"
assert grep -q '^  image_leg_variants "$root" "$dest" "$flow_result" id ' "$ROOT/share/flow-image.sh"
assert grep -q '^  image_leg_variants "$root" "$dest" "$web_result" chat ' "$ROOT/bin/codex-image"

printf 'PASS: %s asserts; local paste with its edge, re-render grain and specks, drift-only no mask, global refusal, rectangle fractions, points, aspect change, lineage depth/root/session, and the shared default decision identical on codex/gemini/grok (resume/single-ref composited with the render kept, several inputs/new generation/unknown input/aspect skipped, transparent and --no-composite silent, global refused, explicit --composite forced or refused before spending)\n' "$asserts"
