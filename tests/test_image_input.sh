#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -eu
ROOT=${IMAGE_INPUT_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d)
trap 'rm -f "$WORK"/*; rmdir "$WORK"' EXIT
export IMAGE_LEG_LOG="$WORK/legs.jsonl"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "$*"; }
magick -size 64x64 xc:white "$WORK/blank.png"
cat >"$WORK/viewbox.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="100 200 400 100"><path fill="black" d="M120 220h360v60H120z"/></svg>
SVG

blank_reference() {
  local code=0
  (
    . "$ROOT/share/image-leg.sh"
    trap image_leg_inputs_cleanup EXIT
    usage() { printf '%s\nusage: input\n' "$*" >&2; exit 2; }
    refs=("$WORK/blank.png")
    image_leg_inputs "$ROOT"
  ) >"$WORK/out" 2>"$WORK/err" || code=$?
  assert test "$code" = 2
  assert grep -Fq "blank reference: $WORK/blank.png (uniform image; an SVG rasterised without its viewBox?)" "$WORK/err"
}

svg_reference() {
  (
    . "$ROOT/share/image-leg.sh"
    trap image_leg_inputs_cleanup EXIT
    usage() { printf '%s\n' "$*" >&2; exit 2; }
    refs=("$WORK/viewbox.svg")
    image_leg_inputs "$ROOT"
    [[ "${refs[0]}" = *.png ]] || exit 1
    magick "${refs[0]}" -format '%w %h %[fx:standard_deviation.a] %[fx:minima.a]' info: >"$WORK/svg-stats"
    printf '%s' "${refs[0]}" >"$WORK/converted"
    image_leg_input "$ROOT" "${refs[0]}"
  ) || fail 'SVG reference must rasterise to a non-blank PNG'
  assert awk '{exit !($1 == 1024 && $2 == 256 && $3 > 0 && $4 == 0)}' "$WORK/svg-stats"
  assert test ! -e "$(cat "$WORK/converted")"
}

batch_start() {
  local real shim="$WORK/shim" i
  real=$(command -v uv)
  mkdir -p "$shim"
  printf '#!/bin/sh\necho start >>"%s/uv-starts"\nexec "%s" "$@"\n' "$WORK" "$real" >"$shim/uv"
  chmod +x "$shim/uv"
  for i in 1 2 3; do magick -size 64x64 gradient:red-blue "$WORK/ref$i.png"; done
  : >"$WORK/uv-starts"
  (
    PATH="$shim:$PATH"
    . "$ROOT/share/image-leg.sh"
    trap image_leg_inputs_cleanup EXIT
    usage() { printf '%s\n' "$*" >&2; exit 2; }
    refs=("$WORK/ref1.png" "$WORK/viewbox.svg" "$WORK/ref3.png")
    edit=$WORK/ref3.png
    first_frame=$WORK/ref1.png
    image_leg_inputs "$ROOT" "$WORK/ref2.png"
    printf '%s\n' "${refs[@]}" "$edit" "$first_frame" "[$last_frame]" "$IMAGE_LEG_INPUT" >"$WORK/batch-out"
  ) || fail 'batched inputs must validate'
  assert test "$(wc -l <"$WORK/uv-starts")" -eq 1
  assert test "$(sed -n 1p "$WORK/batch-out")" = "$WORK/ref1.png"
  assert grep -q '/image-input-.*\.png$' <(sed -n 2p "$WORK/batch-out")
  assert test "$(sed -n 3,6p "$WORK/batch-out" | paste -sd' ' -)" = "$WORK/ref3.png $WORK/ref3.png $WORK/ref1.png []"
  assert test "$(sed -n 7p "$WORK/batch-out")" = "$WORK/ref2.png"
  : >"$WORK/uv-starts"
  code=0
  (
    PATH="$shim:$PATH"
    . "$ROOT/share/image-leg.sh"
    usage() { printf '%s\n' "$*" >&2; exit 2; }
    refs=("$WORK/ref1.png" "$WORK/missing.png" "$WORK/blank.png")
    image_leg_inputs "$ROOT"
  ) >"$WORK/out" 2>"$WORK/err" || code=$?
  assert test "$code" = 2
  assert test "$(cat "$WORK/err")" = "input $WORK/missing.png is not an absolute path to a file"
  assert test "$(wc -l <"$WORK/uv-starts")" -eq 1
  rm -f "$shim/uv"
  rmdir "$shim"
}

case ${1:-} in
  batch_start) batch_start; exit ;;
  blank_reference) blank_reference; exit ;;
  svg_reference) svg_reference; exit ;;
esac
blank_reference
svg_reference
batch_start
for wrapper in codex-image gemini-image grok-image gemini-video grok-video; do
  case $wrapper in *-image) flags='--ref --edit'; ext=png ;; *) flags='--ref --first-frame --last-frame'; ext=mp4 ;; esac
  for flag in $flags; do
    code=0
    bash "$ROOT/bin/$wrapper" --dest "$WORK/out.$ext" --prompt test "$flag" "$WORK/blank.png" >"$WORK/out" 2>"$WORK/err" || code=$?
    assert test "$code" = 2
    assert grep -Fq "blank reference: $WORK/blank.png" "$WORK/err"
    assert grep -q '^usage:' "$WORK/err"
  done
done
for mode in flags jobs; do
  args=(--prompt test --ref "$WORK/blank.png")
  if [ "$mode" = jobs ]; then
    printf '{"prompt":"test","dest":"%s/out.png","refs":["%s"]}\n' "$WORK" "$WORK/blank.png" >"$WORK/jobs.jsonl"
    args=(--jobs "$WORK/jobs.jsonl")
  fi
  code=0
  bash "$ROOT/bin/image-fanout" --dest-dir "$WORK" --vendors codex --dry-run "${args[@]}" >"$WORK/out" 2>"$WORK/err" || code=$?
  assert test "$code" = 2
  assert grep -Fq "blank reference: $WORK/blank.png" "$WORK/err"
done
for color in black transparent '#808080'; do
  magick -size 64x64 "xc:$color" "$WORK/blank.png"
  blank_reference
done
for color in black white; do
  magick -size 64x64 xc:none -fill "$color" -draw 'rectangle 8,8 55,55' "$WORK/shape.png"
  result=$(uv run -q --script "$ROOT/share/image_input.py" "$WORK/shape.png")
  assert test "$result" = "$WORK/shape.png"
done
# A fully opaque RGBA photo at this size left ImageStat's variance a hair below zero (sqrt raised).
magick -size 1122x1402 gradient:green-white -alpha opaque -define png:color-type=6 "$WORK/opaque.png"
result=$(uv run -q --script "$ROOT/share/image_input.py" "$WORK/opaque.png" 2>&1)
assert test "$result" = "$WORK/opaque.png"
magick -size 64x64 gradient:'#808080-#818181' -evaluate multiply 0.1 "$WORK/blank.png"
blank_reference
printf 'PASS: %s asserts; blank_reference, svg_reference, opaque RGBA, all wrapper input flags and fanout jobs\n' "$asserts"
