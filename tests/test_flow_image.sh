#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The Flow route of gemini-image: wrapper flags, refusals, takes and footer on a fake engine, then the engine's
# rotation, start stamps, resume pinning, plan refusals and reply parsing on fixtures. Fixture stores only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UV_CACHE_DIR=${UV_CACHE_DIR:-$(uv cache dir 2>/dev/null)}
export UV_CACHE_DIR
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
export HOME="$WORK/home" TMPDIR="$WORK/tmp" GEMINI_WEB_DIR="$WORK/home/.gemini-web" PYTHONDONTWRITEBYTECODE=1
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl" FAKE_CALLS="$WORK/calls" FLOW_IMAGE_ENGINE="$WORK/flow-engine"
mkdir -p "$HOME" "$TMPDIR" "$WORK/media" "$WORK/out" "$GEMINI_WEB_DIR"
M=$WORK/media
magick -size 1200x896 xc:steelblue "$M/a.jpg" || exit 1
magick -size 1200x896 xc:tomato "$M/b.jpg" || exit 1
magick -size 64x64 xc:gray "$M/ref.png" || exit 1
export FAKE_A="$M/a.jpg" FAKE_B="$M/b.jpg"
cat >"$FLOW_IMAGE_ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_CALLS"
if [ "$1" = tool ]; then
  op='' image='' out=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --op) op=$2; shift 2 ;;
      --image) image=$2; shift 2 ;;
      --out-dir) out=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$op" = cutout ]; then
    if [ "${FAKE_CUTOUT:-}" = opaque ]; then
      magick "$image" -resize 768x768 "PNG32:$out/take1.png"
    else
      magick "$image" -resize 768x768 -alpha set -channel A -fx 'i > w/4 && i < 3*w/4 && j > h/4 && j < 3*h/4' \
        +channel "PNG32:$out/take1.png"
    fi
    jq -cn --arg p "$out/take1.png" '{ok: true, account: "flowacct", op: "cutout", bg_model: "modnet",
      build: "boq_test", takes: [{path: $p, id: null}]}'
  else
    cp "$FAKE_A" "$out/take1.jpg"
    jq -cn --arg p "$out/take1.jpg" --arg op "$op" '{ok: true, account: "flowacct", op: $op, model: "BELUGA",
      build: "boq_test", seconds: {render: 9.5, total: 20.1}, credits_before: 819, takes: [{path: $p, id: "wt1", media_id: "mt1"}]}'
  fi
  exit 0
fi
out='' count=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) out=$2; shift 2 ;;
    --count) count=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "${FAKE_ENGINE_MODE:-ok}" in
  walled) printf 'BROWSER_FAILURE route=flow account=flowacct code=3 shot=- reason=walled\n' >&2
    printf '{"ok": false, "reason": "every signed-in Flow account is walled (walls.json)"}\n'; exit 3 ;;
  login) printf '{"ok": false, "reason": "account flowacct has no browser login; run: geminib web flowacct"}\n'; exit 4 ;;
  crash) printf '{"ok": false, "reason": "Flow UI drift: image settings"}\n'; exit 1 ;;
  genfail) printf '{"ok": false, "reason": "flow_generation_failed (not charged): Flow'"'"'s Failed card came back after its own Retry on flowacct"}\n'; exit 1 ;;
  silent) exit 1 ;;
esac
cp "$FAKE_A" "$out/take1.jpg"
cp "$FAKE_B" "$out/take2.jpg"
jq -cn --arg o "$out" --argjson n "$count" '{ok: true, account: "flowacct", project: "p1", model: "BELUGA",
  build: "boq_test", seconds: {render: 9.5, total: 20.1}, refused: [{media_id: "m9", error: "PUBLIC_ERROR_UNSAFE"}],
  takes: [range($n - (if env.FAKE_SHORT then 1 else 0 end)) as $i | {path: "\($o)/take\(if $i == 0 then 1 else 2 end).jpg", id: "wf\($i + 1)",
    media_id: "m\($i + 1)", size: [1200, 896]}]} + (if env.FAKE_FAILED then {failed: (env.FAKE_FAILED | tonumber)} else {} end)
  + (if env.FAKE_PHASES then {phases: (env.FAKE_PHASES | fromjson), load: {lock: 3.1, saved: 280.5}} else {} end)'
EOF
chmod +x "$FLOW_IMAGE_ENGINE"
: >"$FAKE_CALLS"
: >"$WORK/err"

image() { bash "$ROOT/bin/gemini-image" "$@" >"$WORK/stdout" 2>"$WORK/err"; }
expect_rc() {
  local expected=$1 result=0
  shift
  image "$@" || result=$?
  assert test "$result" -eq "$expected"
}

# Every refusal exits 2 with one line before the engine starts.
dest="$WORK/out/pic.jpg"
refs11=()
for _ in $(seq 11); do refs11+=(--ref "$M/ref.png"); done
for flags in "--route cli --model pro" "--route cli --count 2" "--route cli --upscale 2k" "--route web" \
  "--route flow --model ultra" "--route flow --count 5" "--route flow --count 0" "--route flow --count two" \
  "--route flow --aspect wide" "--aspect 0:3" "--route flow --upscale 4k" \
  "--route flow --resume wf1 --account flowacct --count 2" \
  "--route flow --resume wf1 --account flowacct --ref $M/ref.png" "--route flow --resume wf1" "--model ultra" \
  "--count 5" "--upscale 4k" "--transparent"; do
  # shellcheck disable=SC2086
  expect_rc 2 --dest "$dest" --prompt 'a vase' $flags
  assert test "$(wc -l <"$WORK/err")" -eq 1
done
expect_rc 2 --dest "$dest" --prompt 'a vase' --route flow "${refs11[@]}"
assert grep -qx 'gemini-image: --route flow takes at most 10 --ref images' "$WORK/err"
expect_rc 2 --dest "$dest" --prompt 'a vase' "${refs11[@]}"
assert grep -qx 'gemini-image: --route flow takes at most 10 --ref images' "$WORK/err"
expect_rc 2 --dest "$dest" --prompt 'a vase' --aspect wide
assert grep -qx 'gemini-image: --aspect is W:H; --route flow maps it to the nearest of: 16:9 4:3 1:1 3:4 9:16' "$WORK/err"
expect_rc 2 --dest "$dest" --prompt 'a vase' --route flow --model ultra
assert grep -qx 'gemini-image: --model on --route flow is one of: pro, nb2, lite' "$WORK/err"
expect_rc 2 --dest "$dest" --prompt 'a vase' --route flow --count 5
assert grep -qx 'gemini-image: --count on --route flow is 1-4' "$WORK/err"
expect_rc 2 --dest "$dest" --prompt 'a vase' --route cli --model pro
assert grep -q -- '--model, --count and --upscale run on --route flow' "$WORK/err"
expect_rc 2 --dest "$dest" --prompt 'a vase' --transparent
assert grep -qx 'gemini-image: --transparent requires a .png destination' "$WORK/err"
assert test ! -s "$FAKE_CALLS"

# Every flag reaches the engine; the extra take lands as <stem>-2.<ext>; the footer names route and model.
assert image --route flow --dest "$dest" --prompt 'a blue vase' --model nb2 --count 2 --aspect 4:3 --ref "$M/ref.png" \
  --upscale 2k
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- "generate --prompt a blue vase --model nb2 --count 2 --out-dir $TMPDIR/gemini-image\.[^ ]* --aspect 4:3 --ref $M/ref.png --upscale 2k " <<<"$calls"
assert cmp -s "$M/a.jpg" "$dest"
assert cmp -s "$M/b.jpg" "$WORK/out/pic-2.jpg"
assert grep -qx "variant=$WORK/out/pic-2.jpg size=1200x896 session=wf2" "$WORK/stdout"
assert grep -qx 'account=flowacct' "$WORK/stdout"
assert grep -qx 'session=wf1' "$WORK/stdout"
assert grep -qx 'aspect=4:3 achieved=1.339 fit=ok' "$WORK/stdout"
assert grep -qx 'model=BELUGA model_caps=fresh' "$WORK/stdout"
assert grep -qx 'route=flow model=nb2 upscale=2k' "$WORK/stdout"
assert grep -qx 'refused=m9 PUBLIC_ERROR_UNSAFE' "$WORK/stdout"
assert grep -qx 'seconds=20.1 render=9.5' "$WORK/stdout"
assert test -z "$(ls "$TMPDIR")"
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -c '[.tool, .rc, .account, .served]')" = \
  '["gemini-image",0,"flowacct","BELUGA"]'

# Without --route the run is Flow's: the default model is pro and a png dest re-encodes; a model the caps do
# not list reads stale.
: >"$FAKE_CALLS"
assert image --dest "$WORK/out/one.png" --prompt 'a lamp'
assert grep -qx -- 'generate' "$FAKE_CALLS"
assert grep -qx 'route=flow model=pro upscale=none' "$WORK/stdout"
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -r .route)" = flow
assert grep -qx -- 'pro' "$FAKE_CALLS"
assert test "$(sips -g format "$WORK/out/one.png" | awk '/format:/ {print $2}')" = png
assert grep -Fqx 'model=BELUGA model_caps=stale verified=^GEM_PIX_2$' "$WORK/stdout"
assert test ! -e "$WORK/out/one-2.png"

# Variants convert side by side: each shimmed magick of a variant waits for the other's start, so a serial
# footer stalls into the shim's timeout and fails the run.
mkdir -p "$WORK/shim" "$WORK/conv"
cat >"$WORK/shim/magick" <<EOF
#!/usr/bin/env bash
out=\${@: -1}
case "\$out" in
  *-[23].png)
    touch "$WORK/conv/\${out##*/}"
    for _ in \$(seq 100); do [ "\$(ls "$WORK/conv" | wc -l)" -ge 2 ] && break; sleep 0.1; done
    [ "\$(ls "$WORK/conv" | wc -l)" -ge 2 ] || exit 1 ;;
esac
exec "$(command -v magick)" "\$@"
EOF
chmod +x "$WORK/shim/magick"
rc=0
(PATH="$WORK/shim:$PATH" image --dest "$WORK/out/trio.png" --prompt 'a lamp' --count 3) || rc=$?
assert test "$rc" -eq 0
assert test "$(ls "$WORK/conv" | tr '\n' ' ')" = 'trio-2.png trio-3.png '
assert grep -qx "variant=$WORK/out/trio-3.png size=1200x896 session=wf3" "$WORK/stdout"
assert test "$(sips -g format "$WORK/out/trio-3.png" | awk '/format:/ {print $2}')" = png

# An aspect Flow lacks goes as the nearest of its five, named in the aspect line; a W:H Flow lists goes as is.
: >"$FAKE_CALLS"
assert image --dest "$dest" --prompt 'a lamp' --aspect 2:3
assert grep -qx -- '3:4' "$FAKE_CALLS"
assert test "$(grep -c -- '2:3' "$FAKE_CALLS")" -eq 0
assert grep -qx 'aspect=3:4 achieved=1.339 fit=miss asked=2:3' "$WORK/stdout"
: >"$FAKE_CALLS"
assert image --dest "$dest" --prompt 'a lamp' --aspect 21:9
assert grep -qx -- '16:9' "$FAKE_CALLS"
assert grep -qx 'aspect=16:9 achieved=1.339 fit=miss asked=21:9' "$WORK/stdout"

# --transparent on Flow: the CLI route's green-screen words and local chroma key, on every take.
magick -size 120x90 xc:'#00FF00' -fill tomato -draw 'rectangle 40,30 80,60' "$M/green.png" || exit 1
: >"$FAKE_CALLS"
FAKE_A="$M/green.png" FAKE_B="$M/green.png" assert image --dest "$WORK/out/cut.png" --prompt 'a transparent lamp' \
  --transparent --count 2
assert grep -qx -- 'a  lamp on a flat solid #00FF00 green background' "$FAKE_CALLS"
for cut in "$WORK/out/cut.png" "$WORK/out/cut-2.png"; do
  assert test "$(sips -g hasAlpha "$cut" | awk '/hasAlpha:/ {print $2}')" = yes
  assert test "$(magick "$cut" -format '%[fx:int(255*p{2,2}.a)] %[fx:int(255*p{60,45}.a)]' info:)" = '0 255'
done

# --composite on Flow pastes the edited region back over the --ref it edits.
: >"$FAKE_CALLS"
magick "$M/green.png" -fill blue -draw 'rectangle 5,5 20,20' "$M/patched.png" || exit 1
FAKE_A="$M/patched.png" assert image --dest "$WORK/out/comp.png" --prompt 'add a patch' --ref "$M/green.png" --composite
assert grep -Eq '^composite=auto changed=[0-9.]+%$' "$WORK/stdout"
assert grep -qx "edit_depth=1 root=$M/green.png" "$WORK/stdout"
assert test "$(jq -r '.edits[0].route' "$WORK/out/comp.png.edit.json")" = flow
# By default too, and on every take of a --count: each composited, each render kept beside its file.
magick "$M/patched.png" -fill white -colorize 4% "$M/drifted.png" || exit 1
FAKE_A="$M/drifted.png" FAKE_B="$M/drifted.png" assert image --dest "$WORK/out/takes.png" --prompt 'add a patch' \
  --ref "$M/green.png" --count 2
assert test "$(grep -Ec '^composite=auto changed=[0-9.]+%$' "$WORK/stdout")" -eq 2
corner() { magick "$1" -depth 8 -format '%[pixel:p{110,80}]' info:; }
for take in takes takes-2; do
  assert grep -qx "rendered=$WORK/out/$take.rendered.png" "$WORK/stdout"
  assert test "$(corner "$WORK/out/$take.png")" = "$(corner "$M/green.png")"
  assert test "$(corner "$WORK/out/$take.rendered.png")" != "$(corner "$M/green.png")"
done
assert test "$(grep -n '^variant=' "$WORK/stdout" | cut -d: -f1)" -lt "$(grep -n "^rendered=$WORK/out/takes-2" "$WORK/stdout" | cut -d: -f1)"
assert test -z "$(ls "$TMPDIR")"
rm -f "$TMPDIR"/uv-*.lock

# A resume pins its account and sends no aspect it was not given.
: >"$FAKE_CALLS"
assert image --route flow --dest "$WORK/out/edit.jpg" --prompt 'make it red' --model nb2 --resume wf1 --account flowacct
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- '--resume wf1 --account flowacct' <<<"$calls"
assert test "$(grep -c -- '--aspect' "$FAKE_CALLS")" -eq 0

# A resume follows the route that made the session (its lineage record); a --route that contradicts it is refused
# before anything runs.
assert test "$(sed -n 2p "$WORK/sessions/gemini/wf1")" = flow
: >"$FAKE_CALLS"
assert image --dest "$WORK/out/edit.jpg" --prompt 'redder' --resume wf1 --account flowacct
assert grep -q -- '--resume wf1 --account flowacct' <<<"$(tr '\n' ' ' <"$FAKE_CALLS")"
: >"$FAKE_CALLS"
expect_rc 2 --dest "$WORK/out/edit.jpg" --prompt 'redder' --resume wf1 --account flowacct --route cli
assert test "$(cat "$WORK/err")" = 'gemini-image: --resume wf1 was made on --route flow and continues there; drop --route cli'
assert test ! -s "$FAKE_CALLS"

# Failure shapes are the CLI route's.
FAKE_ENGINE_MODE=walled expect_rc 3 --route flow --dest "$dest" --prompt 'a vase'
assert grep -qx 'GEMINI_USAGE_LIMIT' "$WORK/err"
assert grep -qx 'BROWSER_FAILURE route=flow account=flowacct code=3 shot=- reason=walled' "$WORK/err"
FAKE_ENGINE_MODE=login expect_rc 4 --route flow --dest "$dest" --prompt 'a vase'
assert grep -q 'has no browser login' "$WORK/err"
FAKE_ENGINE_MODE=crash expect_rc 1 --route flow --dest "$dest" --prompt 'a vase'
assert grep -qx 'gemini-image: Flow UI drift: image settings' "$WORK/err"
FAKE_ENGINE_MODE=silent expect_rc 1 --route flow --dest "$dest" --prompt 'a vase'
assert grep -qx 'gemini-image: the Flow engine printed no result (exit 1)' "$WORK/err"
FAKE_ENGINE_MODE=genfail expect_rc 1 --dest "$dest" --prompt 'a vase'
assert grep -q '^gemini-image: flow_generation_failed (not charged)' "$WORK/err"
assert test "$(grep -c 'late one lands' "$WORK/err")" -eq 0
rm -f "$WORK/out/pic-2.jpg"
FAKE_FAILED=1 assert image --dest "$dest" --prompt 'two vases' --count 2
assert grep -qx 'failed=1 reason=flow_generation_failed (not charged)' "$WORK/stdout"
assert test -s "$WORK/out/pic-2.jpg"
assert image --dest "$dest" --prompt 'a vase'
assert test "$(grep -c '^failed=' "$WORK/stdout")" -eq 0
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -c '[.requested, .delivered]')" = '[1,1]'
# A short Flow batch is logged as requested vs delivered; the engine's phases reach stdout and the log, the load
# at each phase the log only.
FAKE_FAILED=1 FAKE_SHORT=1 FAKE_PHASES='{"lock":0,"browser":2.5,"sent":5,"saved":31}' \
  assert image --dest "$dest" --prompt 'three vases' --count 3
assert grep -qx 'failed=1 reason=flow_generation_failed (not charged)' "$WORK/stdout"
assert grep -qx 'phases={"lock":0,"browser":2.5,"sent":5,"saved":31}' "$WORK/stdout"
assert grep -Eqx 'job=gemini-image-[0-9]{8}T[0-9]{6}Z-[0-9]+' <<<"$(grep -B1 -x 'route=flow model=pro upscale=none' "$WORK/stdout" | head -n 1)"
assert jq -e --arg job "$(sed -n 's/^job=//p' "$WORK/stdout")" \
  '.job == $job and .requested == 3 and .delivered == 2 and .phases.saved == 31 and .load == {lock: 3.1, saved: 280.5}
   and .route == "flow"' \
  <<<"$(tail -n 1 "$IMAGE_LEG_LOG")" >/dev/null
assert test -z "$(ls "$TMPDIR")"

# The Image Editor ops refuse before the engine starts, one line each.
magick -size 1000x750 pattern:checkerboard -fill tomato -draw 'circle 500,375 500,200' "$M/scene.png" || exit 1
magick -size 1600x900 xc:khaki "$M/wide.png" || exit 1
png="$WORK/out/tool.png"
: >"$FAKE_CALLS"
while IFS='#' read -r message flags; do
  read -ra argv <<<"$flags"
  expect_rc 2 --dest "${argv[0]}" "${argv[@]:1}"
  assert test "$(cat "$WORK/err")" = "gemini-image: $message"
done <<EOF
--remove-bg requires a .png destination#$dest --ref $M/scene.png --remove-bg
--remove-bg runs alone: no --prompt, --aspect, --region or --point#$png --ref $M/scene.png --remove-bg --prompt x
--remove-bg runs alone: no --prompt, --aspect, --region or --point#$png --ref $M/scene.png --remove-bg --aspect 16:9
--bg-model is one of: modnet#$png --ref $M/scene.png --remove-bg --bg-model u2net
--bg-model goes with --remove-bg#$png --ref $M/scene.png --region 0.1,0.1,0.2,0.2 --prompt x --bg-model modnet
--bg-model goes with --remove-bg#$png --prompt x --bg-model modnet
the cutout edit takes no --count, --upscale or --transparent#$png --ref $M/scene.png --remove-bg --count 2
the cutout edit takes one image: a single --ref, or --resume of a session this machine delivered#$png --remove-bg
the inpaint edit takes one image: a single --ref, or --resume of a session this machine delivered#$png --ref $M/scene.png --ref $M/wide.png --region 0.1,0.1,0.2,0.2 --prompt x
--region needs a --prompt for the painted area#$png --ref $M/scene.png --region 0.1,0.1,0.2,0.2
pass --region or --point, not both#$png --ref $M/scene.png --region 0.1,0.1,0.2,0.2 --point 0.5,0.5=x --prompt x
--point carries its own text (x,y=<text>): no --prompt#$png --ref $M/scene.png --point 0.5,0.5=x --prompt y
--point takes x,y=<text> with x,y fractions of the image (0..1), not 1.5,0.5=x#$png --ref $M/scene.png --point 1.5,0.5=x
--point takes x,y=<text> with x,y fractions of the image (0..1), not 0.5,0.5#$png --ref $M/scene.png --point 0.5,0.5
--region takes x,y,w,h as fractions of the image (0..1, inside it), not 0.9,0.1,0.2,0.2#$png --ref $M/scene.png --region 0.9,0.1,0.2,0.2 --prompt x
an inpaint keeps the image's size: no --aspect#$png --ref $M/scene.png --region 0.1,0.1,0.2,0.2 --prompt x --aspect 16:9
the Image Editor runs --model pro|nb2#$png --ref $M/scene.png --region 0.1,0.1,0.2,0.2 --prompt x --model lite
--region, --point, --remove-bg and a prompt-less --aspect edit run on --route flow (Flow's Image Editor)#$png --ref $M/scene.png --remove-bg --route cli
outpaint takes --aspect 16:9|4:3|1:1|3:4|9:16, not 3:2#$png --ref $M/scene.png --aspect 3:2
the image is 1600x900, already 16:9: nothing to outpaint#$png --ref $M/wide.png --aspect 16:9
an outpaint changes the canvas, so nothing composites onto the input: no --composite#$png --ref $M/scene.png --aspect 16:9 --composite
EOF
expect_rc 2 --dest "$png" --ref "$M/scene.png" --remove-bg --bg-model ben2
assert grep -q "^gemini-image: --bg-model ben2: Flow's BEN2 (General, Quality) fails in the page" "$WORK/err"
assert test ! -s "$FAKE_CALLS"

# Cutout: Flow's matte (at most 768 wide) over the full-size input, so the opaque pixels are the input's own.
assert image --dest "$png" --ref "$M/scene.png" --remove-bg
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- "^tool --op cutout --image $M/scene.png --size 1000x750 --out-dir $TMPDIR/gemini-image\.[^ ]* --bg-model modnet $" <<<"$calls"
assert test "$(sips -g pixelWidth -g pixelHeight "$png" | awk '/pixel/ {printf "%s ", $2}')" = '1000 750 '
alpha_at() { magick "$1" -format "%[fx:int(255*p{$2}.a)]" info:; }
assert test "$(alpha_at "$png" 10,10) $(alpha_at "$png" 500,375)" = '0 255'
pixel() { magick "$1" -alpha off -depth 8 -format "%[pixel:p{$2}]" info:; }
assert test "$(pixel "$png" 301,201)" = "$(pixel "$M/scene.png" 301,201)"
assert test "$(pixel "$png" 302,201)" = "$(pixel "$M/scene.png" 302,201)"
assert grep -qx 'tool=cutout bg_model=modnet on_device=true' "$WORK/stdout"
assert grep -qx 'route=flow tool=cutout' "$WORK/stdout"
assert test "$(grep -c '^composite=' "$WORK/stdout")" -eq 0
assert test "$(jq -r '.edits[0].route' "$png.edit.json")" = flow
FAKE_CUTOUT=opaque expect_rc 1 --dest "$WORK/out/opaque.png" --ref "$M/scene.png" --remove-bg
assert test "$(cat "$WORK/err")" = "gemini-image: Flow's Cutout returned no transparency; nothing delivered"
assert test ! -e "$WORK/out/opaque.png"
# --resume edits what this machine delivered for the session, on any account.
: >"$FAKE_CALLS"
assert image --dest "$png" --resume wf1 --remove-bg
assert grep -qx -- "$(head -n 1 "$WORK/sessions/gemini/wf1")" "$FAKE_CALLS"
assert test "$(grep -c -- '--account\|--resume' "$FAKE_CALLS")" -eq 0

# Inpaint: the painted area's prompt (a --point's own text), and the composite keeps every pixel outside it.
magick "$M/scene.png" -fill white -colorize 8% -fill navy -draw 'rectangle 100,100 299,249' "$M/inpainted.png" || exit 1
: >"$FAKE_CALLS"
FAKE_A="$M/inpainted.png" assert image --dest "$png" --ref "$M/scene.png" --region 0.1,0.1,0.2,0.2 \
  --prompt 'a navy box' --model nb2
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- "^tool --op inpaint --image $M/scene.png --size 1000x750 --out-dir [^ ]* --model nb2 --prompt a navy box --region 0.1,0.1,0.2,0.2 $" <<<"$calls"
assert grep -Eq '^composite=region ' "$WORK/stdout"
assert test "$(pixel "$png" 800,600)" = "$(pixel "$M/scene.png" 800,600)"
assert test "$(pixel "$png" 200,170)" != "$(pixel "$M/scene.png" 200,170)"
assert grep -qx 'route=flow tool=inpaint model=nb2' "$WORK/stdout"
assert grep -qx 'credits_before=819' "$WORK/stdout"
assert grep -qx 'model=BELUGA model_caps=fresh' "$WORK/stdout"
: >"$FAKE_CALLS"
FAKE_A="$M/inpainted.png" assert image --dest "$png" --ref "$M/scene.png" --point '0.2,0.23=a navy box' \
  --point '0.7,0.7=a red dot'
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- " --prompt a navy box; a red dot --point 0.2,0.23=a navy box --point 0.7,0.7=a red dot $" <<<"$calls"
assert grep -Eq '^composite=points ' "$WORK/stdout"
assert test "$(pixel "$png" 900,100)" = "$(pixel "$M/scene.png" 900,100)"
assert test "$(jq -c '.edits[-1].points' "$png.edit.json")" != null

# Outpaint: a prompt-less --aspect on one image; the canvas changes, so nothing composites.
magick -size 1333x750 xc:olive "$M/outpainted.png" || exit 1
: >"$FAKE_CALLS"
FAKE_A="$M/outpainted.png" assert image --dest "$png" --ref "$M/scene.png" --aspect 16:9
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- "^tool --op outpaint --image $M/scene.png --size 1000x750 --out-dir [^ ]* --model pro --aspect 16:9 $" <<<"$calls"
assert grep -qx 'aspect=16:9 achieved=1.777 fit=ok' "$WORK/stdout"
assert test "$(grep -c '^composite=' "$WORK/stdout")" -eq 0
# A side Flow left black from the edge in (Pro on 9:16, live, wholly or in part) is no outpaint; dark content
# that does not span the edge still is.
magick -size 768x1365 xc:olive -fill black -draw 'rectangle 0,1000 767,1364' "$M/unfilled.png" || exit 1
magick -size 768x1365 xc:olive -fill black -draw 'rectangle 100,1000 667,1364' "$M/dark.png" || exit 1
FAKE_A="$M/unfilled.png" expect_rc 1 --dest "$WORK/out/tall.png" --ref "$M/scene.png" --aspect 9:16
assert test "$(cat "$WORK/err")" = "gemini-image: Flow's Outpaint left the bottom band unfilled (black); nothing delivered"
assert test ! -e "$WORK/out/tall.png"
FAKE_A="$M/dark.png" assert image --dest "$WORK/out/tall.png" --ref "$M/scene.png" --aspect 9:16
assert test "$(bash -c '. "$1/share/flow-image.sh"; flow_image_outpaint_bands 1000x750 9:16 768x1365
  flow_image_outpaint_bands 1080x1080 16:9 1376x768' _ "$ROOT")" = \
  $'top 768x16+0+0\nbottom 768x16+0+1349\nleft 16x768+0+0\nright 16x768+1360+0'
# With a --prompt the same flags stay a ref-guided generation.
: >"$FAKE_CALLS"
assert image --dest "$png" --ref "$M/scene.png" --aspect 16:9 --prompt 'a wider view'
assert grep -qx generate "$FAKE_CALLS"
assert test -z "$(ls "$TMPDIR")"

# The engine on fixtures.
assert python3 - "$ROOT" "$WORK" <<'PY'
import argparse, contextlib, io, json, math, os, sys, time, types, urllib.parse
from pathlib import Path
root, work = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "share"))
import gemini_web as gw
import flow_image as fi

base = Path(os.environ["GEMINI_WEB_DIR"])
assert gw.ROOT == base, gw.ROOT
names = ["old", "new", "walled", "outpool", "unbound", "nologin"]
gw.roster = lambda: names
gw._pool = ({"outpool"}, set())
for name, started in [("old", 100), ("new", 300), ("walled", 50), ("outpool", 10), ("unbound", 1), ("nologin", 5)]:
    cookies = base / "profiles" / name / "Default" / "Cookies"
    cookies.parent.mkdir(parents=True)
    if name != "nologin":
        cookies.write_text("")
    meta = {"generation_started_at": started}
    if name != "unbound":
        meta["email"] = f"{name}@example.com"
    gw.write_meta(name, **meta)
gw.set_wall("walled", time.time() + 3600)

assert fi.rotation() == ["old", "new"], fi.rotation()
gw.set_wall("walled", time.time() - 1)
assert fi.rotation() == ["walled", "old", "new"], fi.rotation()


def args(**over):
    base_args = dict(prompt="a vase", out_dir=work, model="pro", aspect=None, count=1, ref=[], upscale=None,
                     resume=None, account=None, timeout=None, dry_run=False, lock_wait=900)
    return argparse.Namespace(**{**base_args, **over})


def refused(**over):
    try:
        fi.make_plan(args(**over))
    except gw.Failure as failure:
        return failure.code
    return None


plan = fi.make_plan(args(model="nb2", aspect="9:16", count=4, upscale="2k"))
assert (plan["label"], plan["price"], plan["count"], plan["timeout_s"]) == ("Nano Banana 2.1", 0, 4, 300), plan
ref = os.path.join(work, "media", "ref.png")
assert fi.make_plan(args(ref=[ref] * 10))["refs"] == [ref] * 10
for over in [dict(model="ultra"), dict(aspect="2:3"), dict(count=5), dict(ref=[ref] * 11), dict(upscale="4k"),
             dict(ref=[ref + ".missing"]), dict(resume="wf1"), dict(resume="wf1", account="old", count=2),
             dict(resume="wf1", account="old", ref=[ref])]:
    assert refused(**over) == 2, over

class Anything:
    pages = []

    def __getattr__(self, name):
        return self if name in ("last", "first", "keyboard") else lambda *a, **k: self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def is_enabled(self):
        return True


watcher = types.SimpleNamespace(errors={"PUBLIC_ERROR_EARLY"}, images={}, models=[])
saved_gw = gw.browser, gw.open_project, gw.manual_composer, gw.page_state, gw.save_video
saved_fi = fi.Images, fi.settings, fi.await_takes
gw.browser = lambda account: Anything()
gw.open_project = lambda page, account: "p-render"
gw.manual_composer = lambda page: None
gw.page_state = lambda page: {"email": "new@example.com", "build": "b"}
fi.Images = lambda page: watcher
fi.settings = lambda page, plan, editor: "chip"
at_send = []


def stop_at_send(page, watcher, plan, known, account, project):
    at_send.append(set(watcher.errors))
    raise gw.Failure(1, "stop")


fi.await_takes = stop_at_send
try:
    fi.render_on("new", fi.make_plan(args()), {"email": "new@example.com"}, time.time())
except gw.Failure as failure:
    assert failure.reason == "stop", failure.reason
assert at_send == [set()], at_send
fi.await_takes = lambda *a: ([{"media_id": "m1", "url": "u1"}, {"media_id": "m2", "url": "u2"}], 0)


def save_once(context, url, part, check, what):
    if url == "u2":
        raise gw.Failure(1, "the download of u2 failed")
    part.write_bytes(b"\xff\xd8\xff" + bytes(20))
    return 23


gw.save_video = save_once
gw.PHASES.clear()
kept = fi.render_on("new", fi.make_plan(args(count=2)), {"email": "new@example.com"}, time.time())
assert [t["media_id"] for t in kept["takes"]] == ["m1"] and kept["unsaved"] == ["the download of u2 failed"], kept
assert list(gw.PHASES) == ["page", "sent", "media", "saved"], gw.PHASES


passes = []
fi.settings = lambda page, plan, editor: passes.append(editor) or "chip"
gw.add_ingredients = lambda page, paths, kind: passes.append([p.name for p in paths])
gw.browser = lambda account: Anything()
fi.render_on("new", fi.make_plan(args(count=2, ref=[ref])), {"email": "new@example.com"}, time.time())
assert passes == [False, [Path(ref).name], False], passes
# Uploads go out as one chooser batch named by content hash; bytes this account already holds are picked, not resent.
class UploadPage:
    def __init__(self): self.assets, self.sent, self.polls = {}, [], 0
    def get_by_role(self, role, name=None, exact=False):
        page = self
        class Loc:
            def count(self):
                if role == "button":
                    return 0 if name == "I agree" else 1
                return sum(1 for asset in page.assets if name.search(asset))
            @property
            def last(self): return self
            @property
            def first(self): return [asset for asset in page.assets if name.search(asset)][0]
            def click(self): pass
        return Loc()
    @contextlib.contextmanager
    def expect_file_chooser(self, timeout=None):
        page = self
        class Chooser:
            def set_files(self, files):
                page.sent.append([os.path.basename(f) for f in files])
                for f in files:
                    page.assets[f"Uploading {os.path.basename(f)} Image"] = page.polls + 2
        yield types.SimpleNamespace(value=Chooser())
    def wait_for_timeout(self, ms):
        self.polls += 1
        for asset, ready in list(self.assets.items()):
            if asset.startswith("Uploading ") and ready <= self.polls:
                del self.assets[asset]
                self.assets[asset[len("Uploading "):]] = 0


import hashlib
media = Path(work) / "media"
blobs = {name: media / f"{name}.png" for name in ("a", "b", "c", "a-copy")}
for name, path in blobs.items():
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + (b"a" if name == "a-copy" else name.encode()) * 64)
named = {name: f"image-{hashlib.sha256(path.read_bytes()).hexdigest()[:16]}.png" for name, path in blobs.items()}
up = UploadPage()
picked = gw.upload(up, [blobs["a"], blobs["b"]], "image", " Image", 180)
assert up.sent == [[named["a"], named["b"]]], up.sent
assert picked == [f"{named['a']} Image", f"{named['b']} Image"] and up.polls >= 2, (picked, up.polls)
picked = gw.upload(up, [blobs["c"], blobs["b"], blobs["a-copy"], blobs["c"]], "image", " Image", 180)
assert up.sent[1:] == [[named["c"]]], up.sent
assert picked == [f"{named[n]} Image" for n in ("c", "b", "a", "c")], picked
before = list(up.sent)
assert gw.upload(up, [blobs["b"]], "image", " Image", 180) == [f"{named['b']} Image"] and up.sent == before
gw.browser, gw.open_project, gw.manual_composer, gw.page_state, gw.save_video = saved_gw
fi.Images, fi.settings, fi.await_takes = saved_fi

calls = []
fi.render_on = lambda account, plan, meta, started: calls.append(account) or {"ok": True, "account": account}
before = gw.read_meta("old")["generation_started_at"]
fi.generate_on("old", fi.make_plan(args(resume="wf1", account="old")))
fi.generate_on("old", fi.make_plan(args(dry_run=True)))
assert gw.read_meta("old")["generation_started_at"] == before
fi.generate_on("old", fi.make_plan(args()))
assert gw.read_meta("old")["generation_started_at"] >= time.time() - 5
assert calls == ["old", "old", "old"], calls
for name, code in [("nologin", 4), ("unbound", 4)]:
    try:
        fi.generate_on(name, fi.make_plan(args()))
        raise AssertionError(name)
    except gw.Failure as failure:
        assert failure.code == code, (name, failure.code)

gw.ledger({"kind": "flow-image", "event": "saved", "account": "old", "id": "wf1", "project": "p-old"})
gw.ledger({"kind": "flow-image", "event": "saved", "account": "new", "id": "wf1", "project": "p-new"})
gw.ledger({"kind": "flow-video", "event": "saved", "account": "old", "id": "wf2", "project": "p-video"})
gw.write_meta("old", project="p-meta")
assert fi.resume_project("old", "wf1") == "p-old"
assert fi.resume_project("new", "wf1") == "p-new"
assert fi.resume_project("old", "wf2") == "p-meta"
try:
    fi.resume_project("new", "wf2")
    raise AssertionError("no project")
except gw.Failure as failure:
    assert failure.code == 2

url = "https://flow-content.google/image/m1?Expires=9&Signature=abc"
payload = [[["m1", None, "wf1", None, None, None, [[None, 1, None, None, None, None, 1, "a vase", 25, url]], None,
             [1376, 768]],
            ["m2", None, "wf2", None, None, None, [[None, "PUBLIC_ERROR_UNSAFE_GENERATION"]], None, [1024, 1024]]]]
body = ")]}'\n\n120\n" + json.dumps([["wrb.fr", "ogiZ0b", json.dumps(payload), None, None, None, "generic"]])
watcher = fi.Images()
watcher.feed(body)
assert watcher.images["m1"] == {"media_id": "m1", "id": "wf1", "url": url, "size": [1376, 768]}, watcher.images
assert watcher.images["m2"]["error"] == "PUBLIC_ERROR_UNSAFE_GENERATION"
assert "url" not in watcher.images["m2"]
assert [i["media_id"] for i in watcher.new_images({"m1"})] == ["m2"]
other = fi.Images()
other.feed(")]}'\n" + json.dumps([["wrb.fr", "otherRpc", json.dumps(payload), None, None, None, "generic"]]))
assert other.images == {}
denied = fi.Images()
denied.feed(")]}'\n" + json.dumps([["wrb.fr", "ogiZ0b", None, None, None, [3, None, [["x", ["PUBLIC_ERROR_QUOTA"]]]],
                                     "generic"]]))
assert denied.errors == {"PUBLIC_ERROR_QUOTA"} and denied.images == {}

inner = json.dumps([{"ctx": 1}, [[0, 1, 2, 3, 4, "GEM_PIX_2"], [0, 1, 2, 3, 4, "GEM_PIX_2"], "x"]])
post = urllib.parse.urlencode({"f.req": json.dumps([[["ogiZ0b", inner, None, "generic"]]]), "at": "t"})
assert fi.wire_models(post) == ["GEM_PIX_2"]
assert fi.wire_models("garbage") == []
assert fi.model_item("Nano Banana 2").match("🍌 Nano Banana 2")
assert not fi.model_item("Nano Banana 2").match("🍌 Nano Banana 2 Lite")
caps = fi.caps()
assert all(m["wire"] for m in caps["models"].values()), caps["models"]


def walled_then_ok(account, plan):
    if account == "walled":
        raise gw.Failure(3, "Flow walled the image", wall_s=600)
    return {"ok": True, "account": account, "model": "GEM_PIX_2", "takes": [{"path": "p", "account": account}]}


fi.generate_on = walled_then_ok
out = io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
    fi.cmd_generate(args())
emitted = json.loads(out.getvalue().strip().splitlines()[-1])
assert (emitted["account"], emitted["model"]) == ("new", "GEM_PIX_2"), out.getvalue()
assert time.time() + 500 < gw.walls()["walled"] <= time.time() + 600, gw.walls()
gw.set_wall("walled", None)
out = io.StringIO()
try:
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        fi.cmd_generate(args(account="walled"))
    raise AssertionError("pinned")
except SystemExit as exit_:
    failure = json.loads(out.getvalue().strip().splitlines()[-1])
    assert (exit_.code, failure["reason"], failure["account"]) == (3, "Flow walled the image", "walled"), failure
# A pinned account's wall is recorded like a rotated one's, and a walled pinned account is refused unsent.
assert time.time() + 500 < gw.walls()["walled"] <= time.time() + 600, gw.walls()
ran = []
fi.generate_on = lambda account, plan: ran.append(account) or {"ok": True, "account": account, "takes": []}
try:
    fi.cmd_generate(args(account="walled"))
    raise AssertionError("a walled pinned account ran")
except gw.Failure as failure:
    assert failure.code == 3 and "walled is walled until" in failure.reason and ran == [], failure.reason
    assert failure.extra["until"] == gw.walls()["walled"], failure.extra
gw.set_wall("walled", None)

# take_failover try-locks in order (a busy account is passed at once), and a pinned or all-busy pick is exit 5.
import fcntl
def hold(*names):
    handles = [open(gw.lock_path(name), "w") for name in names]
    for handle in handles:
        fcntl.flock(handle, fcntl.LOCK_EX)
    return handles


def failover(accounts, pinned, lock_wait):
    ran.clear()
    out = io.StringIO()
    started = time.time()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            gw.take_failover(accounts, fi.make_plan(args()), fi.generate_on, gw.set_wall, pinned, lock_wait=lock_wait)
        code = 0
    except SystemExit as exit_:
        code = exit_.code
    return code, json.loads(out.getvalue().strip().splitlines()[-1]), time.time() - started


held = hold("old")
code, line, took = failover(["old", "new"], False, 5)
assert code == 0 and ran == ["new"] and took < 2, (code, ran, took)
code, line, took = failover(["old"], True, 0.2)
assert code == 5 and ran == [] and line["reason"].startswith("account busy: timed out waiting for old.lock"), line
held += hold("new")
code, line, took = failover(["old", "new"], False, 0.2)
assert code == 5 and ran == [] and line["code"] == 5, (code, line)
for handle in held:
    handle.close()
assert not gw._held, gw._held


# A quota-shaped refusal after the send is a limit: walled, and the job moves on instead of failing whole.
def quota_then_ok(account, plan):
    ran.append(account)
    if account == "old":
        raise fi.refusal({"PUBLIC_ERROR_QUOTA"})
    return {"ok": True, "account": account, "model": "GEM_PIX_2", "takes": [{"path": "p", "account": account}]}


fi.generate_on = quota_then_ok
code, line, took = failover(["old", "new"], False, 5)
assert code == 0 and ran == ["old", "new"] and line["account"] == "new", (code, ran, line)
assert time.time() + gw.WALL_SECONDS - 60 < gw.walls()["old"] <= time.time() + gw.WALL_SECONDS, gw.walls()
gw.set_wall("old", None)


# Google's flag walls the account even on a pinned run that records no other wall.
def flagged(account, plan):
    ran.append(account)
    raise gw.Failure(3, "Flow flagged this account (PUBLIC_ERROR_UNUSUAL_ACTIVITY)", wall_s=gw.BLOCK_WALL_SECONDS,
                     flagged=True)


def flag_once():
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        try:
            gw.take_failover(["old"], fi.make_plan(args()), fi.generate_on, gw.set_wall, True, wall_pinned=False,
                             lock_wait=5)
        except SystemExit:
            pass
    return gw.walls()["old"] - time.time()


fi.generate_on = flagged
ran.clear()
gw.write_meta("old", flagged_at=0)
assert gw.BLOCK_WALL_SECONDS - 60 < flag_once() <= gw.BLOCK_WALL_SECONDS and ran == ["old"], (ran, gw.walls())
# A repeat flag inside the window walls for the whole window instead of another daily strike.
assert gw.REFLAG_WALL_SECONDS - 60 < flag_once() <= gw.REFLAG_WALL_SECONDS, gw.walls()
gw.write_meta("old", flagged_at=int(time.time()) - gw.REFLAG_WALL_SECONDS - 1)
assert flag_once() <= gw.BLOCK_WALL_SECONDS, gw.walls()
gw.set_wall("old", None)
watcher = gw.Watcher.__new__(gw.Watcher)
watcher.errors = {"PUBLIC_ERROR_UNUSUAL_ACTIVITY"}
assert watcher.blocked().extra.get("flagged") is True, watcher.blocked().extra
assert fi.refusal(["PUBLIC_ERROR_UNSAFE_GENERATION", "PUBLIC_ERROR_RESOURCE_EXHAUSTED"]).code == 3
assert fi.refusal(["PUBLIC_ERROR_UNSAFE_GENERATION", "PUBLIC_ERROR_UNSAFE_GENERATION"]).reason \
    == "Flow refused the image: PUBLIC_ERROR_UNSAFE_GENERATION"


class Clock:
    now = 1000.0

    def time(self):
        return self.now


class Page:
    """Flow's page as await_takes reads it: fresh Failed cards, their Retry buttons, a script of later events."""

    def __init__(self, watcher, steps, on_click):
        self.watcher, self.steps, self.on_click = watcher, steps, on_click
        self.failed = self.clicks = self.ticks = 0

    def evaluate(self, script, op):
        assert (script, op) == (gw.FAILED_CARDS, "count"), op
        self.scans = getattr(self, "scans", 0) + 1
        return self.failed

    def evaluate_handle(self, script, op):
        assert (script, op) == (gw.FAILED_CARDS, "retry"), op
        page = self

        class Button:
            def as_element(self):
                return self

            def click(self, timeout=None):
                page.clicks += 1
                page.on_click(page)

        return types.SimpleNamespace(get_properties=lambda: {str(i): Button() for i in range(self.failed)})

    def wait_for_timeout(self, ms):
        clock.now += ms / 1000
        self.ticks += 1
        self.steps.get(self.ticks, lambda page: None)(self)


def image_body(media_id):
    url = f"https://flow-content.google/image/{media_id}?Expires=9&Signature=abc"
    entry = [media_id, None, "wf-" + media_id, None, None, None, [[None, 1, None, None, None, None, 1, "x", 25, url]],
             None, [1024, 1024]]
    return ")]}'\n" + json.dumps([["wrb.fr", "ogiZ0b", json.dumps([[entry]]), None, None, None, "generic"]])


def wait_takes(count, steps, on_click):
    watcher = fi.Images()
    page = Page(watcher, steps, on_click)
    plan = {"count": count, "timeout_s": 300, "resume": None}
    try:
        result = fi.await_takes(page, watcher, plan, set(), "old", "p1")
    except gw.Failure as failure:
        result = failure
    return result, page


def set_failed(n):
    return lambda page: setattr(page, "failed", n)


def arrive(media_id, failed=None):
    def step(page):
        page.watcher.feed(image_body(media_id))
        if failed is not None:
            page.failed = failed
    return step


clock = Clock()
real_time, fi.time = fi.time, clock
try:
    # A second Failed card after Flow's own Retry ends the run at once, not at the 300 s timeout. The page-wide
    # card scan runs every CARDS_SCAN_S (3 s = 6 ticks), right after a Retry, and at the start.
    started = clock.now
    result, page = wait_takes(1, {2: set_failed(1), 12: set_failed(1)}, set_failed(0))
    assert isinstance(result, gw.Failure) and result.code == 1, result
    assert result.reason.startswith("flow_generation_failed (not charged)") and "late one" not in result.reason, result
    assert page.clicks == 1 and clock.now - started < 30, (page.clicks, clock.now - started)
    retried = [r for r in gw.job_rows() if r.get("event") == "retried"]
    assert retried and retried[-1]["account"] == "old", retried
    # The retried take that comes back is delivered.
    result, page = wait_takes(1, {2: set_failed(1), 9: arrive("r1")}, set_failed(0))
    assert [i["media_id"] for i in result[0]] == ["r1"] and result[1] == 0 and page.clicks == 1, result
    # Two takes, one fails twice (Flow keeping the first card beside the retried one): one delivered, one lost.
    result, page = wait_takes(2, {2: arrive("k1", failed=1), 7: set_failed(2)}, lambda page: None)
    assert [i["media_id"] for i in result[0]] == ["k1"] and result[1] == 1 and page.clicks == 1, result
    # With no Failed card the wait is the timeout, and a late image may still land.
    result, page = wait_takes(1, {}, lambda page: None)
    assert isinstance(result, gw.Failure) and "any late one lands in project p1" in result.reason, result
    assert page.clicks == 0
    # A sibling that never comes back: the finished take is delivered at the timeout, the missing one counted.
    started = clock.now
    with contextlib.redirect_stderr(io.StringIO()) as err:
        result, page = wait_takes(2, {2: arrive("k1")}, lambda page: None)
    assert [i["media_id"] for i in result[0]] == ["k1"] and result[1] == 1, result
    assert clock.now - started >= 300 and "1 of 2 takes never came back" in err.getvalue(), err.getvalue()
    assert page.scans <= page.ticks / 5, (page.scans, page.ticks)
    # A whole failed envelope: a quota-shaped code is exit 3 (the failover's limit), any other a refusal (1).
    def denied(error):
        return lambda page: page.watcher.feed(")]}'\n" + json.dumps(
            [["wrb.fr", "ogiZ0b", None, None, None, [3, None, [["x", [error]]]], "generic"]]))
    result, page = wait_takes(1, {2: denied("PUBLIC_ERROR_QUOTA")}, lambda page: None)
    assert isinstance(result, gw.Failure) and result.code == 3 and "PUBLIC_ERROR_QUOTA" in result.reason, result
    result, page = wait_takes(1, {2: denied("PUBLIC_ERROR_UNSAFE_GENERATION")}, lambda page: None)
    assert isinstance(result, gw.Failure) and result.code == 1, result
finally:
    fi.time = real_time
Path(work, "failed-cards.js").write_text(gw.FAILED_CARDS)

image = os.path.join(work, "media", "scene.png")


def tool_args(**over):
    base_args = dict(op="inpaint", image=image, size="1000x750", out_dir=work, prompt="a box", region="0.1,0.1,0.2,0.2",
                     point=[], aspect=None, model="pro", bg_model=None, account=None, timeout=None, dry_run=False,
                     lock_wait=900)
    return argparse.Namespace(**{**base_args, **over})


def tool_refused(**over):
    try:
        fi.tool_plan(tool_args(**over))
    except gw.Failure as failure:
        return failure.code
    return None


plan = fi.tool_plan(tool_args())
assert (plan["region"], plan["size"], plan["label"], plan["timeout_s"]) == ((0.1, 0.1, 0.2, 0.2), [1000, 750], "Nano Banana Pro", 300), plan
plan = fi.tool_plan(tool_args(op="cutout", region=None, prompt=None))
assert plan["bg_model"] == "modnet", plan
plan = fi.tool_plan(tool_args(region=None, prompt="hair", point=["0.2,0.3=red hair", "0.7,0.3=red hair"]))
assert plan["points"] == [(0.2, 0.3), (0.7, 0.3)], plan
for over in [dict(model="lite"), dict(op="cutout", region=None, prompt=None, bg_model="ben2"), dict(image=image + "x"),
             dict(size="1000"), dict(size="0x750"), dict(op="outpaint", aspect="16:9"), dict(region=None),
             dict(prompt=None), dict(op="outpaint", region=None, aspect="3:2"), dict(op="cutout", prompt=None)]:
    assert tool_refused(**over) == 2, over

assert fi.outpaint_layout((1080, 1080), "16:9") == ((1920, 1080), (420, 0, 1080, 1080))
assert fi.outpaint_layout((1080, 1080), "9:16") == ((1080, 1920), (0, 420, 1080, 1080))
assert fi.outpaint_layout((1000, 750), "1:1") == ((1000, 1000), (0, 125, 1000, 750))

[path] = fi.region_strokes((0.1, 0.1, 0.2, 0.2), 1000, 750, 44)
xs, ys = [p[0] for p in path], [p[1] for p in path]
assert [round(n, 6) for n in (min(xs), max(xs), min(ys), max(ys))] == [122, 278, 97, 203], (xs, ys)
rows = sorted(set(ys))
assert all(b - a <= 44 * 0.6 for a, b in zip(rows, rows[1:])), rows
[path] = fi.region_strokes((0.5, 0.5, 0.01, 0.01), 1000, 750, 44)
assert {p[0] for p in path} == {505.0}, path
[path] = fi.point_strokes((0.25, 0.5), 1000, 750, 44)
assert path[0] == (250, 375) and all(math.dist(p, path[0]) <= 44 * 2 / 3 + 1e-9 for p in path), path
assert max(math.dist(p, path[0]) for p in path) > 44 / 2

assert fi.editor_accounts() == []
try:
    fi.cmd_tool(tool_args())
    raise AssertionError("no editor account")
except gw.Failure as failure:
    assert failure.code == 4 and "My Tools" in failure.reason, failure.reason
gw.write_meta("new", image_editor=True)
assert fi.editor_accounts() == ["new"]
seen = []
fi.tool_on = lambda account, plan, meta, started: seen.append(account) or {"ok": True, "account": account, "takes": []}
stamp = gw.read_meta("new")["generation_started_at"]
with contextlib.redirect_stdout(io.StringIO()):
    fi.cmd_tool(tool_args())
assert seen == ["new"] and gw.read_meta("new")["generation_started_at"] > stamp, seen
gw.write_meta("new", generation_started_at=7)
with contextlib.redirect_stdout(io.StringIO()):
    fi.cmd_tool(tool_args(op="cutout", region=None, prompt=None))
    fi.cmd_tool(tool_args(dry_run=True))
assert seen == ["new"] * 3 and gw.read_meta("new")["generation_started_at"] == 7, seen
gw.set_wall("new", time.time() + 3600)
try:
    with contextlib.redirect_stdout(io.StringIO()):
        fi.cmd_tool(tool_args())
    raise AssertionError("a walled editor account ran")
except SystemExit as walled:
    assert walled.code == 3, walled.code
gw.set_wall("new", time.time() - 1)


class Tile:
    first = property(lambda self: self)

    def wait_for(self, timeout):
        raise TimeoutError

    def count(self):
        return 0

    def click(self, timeout=None):
        pass

    def get_by_text(self, pattern):
        return self


class ToolsPage:
    def set_viewport_size(self, size):
        pass

    def get_by_role(self, *a, **k):
        return Tile()


saved_nav = gw.goto_flow, gw.dismiss_dialogs
gw.goto_flow = gw.dismiss_dialogs = lambda *a, **k: None
try:
    fi.open_editor_once(ToolsPage(), "new", "p1")
    raise AssertionError("a tools page with no tile opened the editor")
except gw.Failure as failure:
    assert failure.code == 4, failure.code
gw.goto_flow, gw.dismiss_dialogs = saved_nav
assert gw.read_meta("new").get("image_editor") is True, "one slow My Tools load dropped the account for good"

# 2026-10-02 jihangarangan: the 2K download clicked a fresh image's black editor, Download media disabled.
class EditorPage:
    loads, settles_at = 0, 3

    def get_by_text(self, text, exact):
        return types.SimpleNamespace(wait_for=self.wait_for)

    def wait_for(self, timeout):
        if self.loads < self.settles_at:
            raise TimeoutError("black editor")


gw.goto_flow = lambda page, path: setattr(page, "loads", page.loads + 1)
gw.close_promos = lambda page, account: None
editor = EditorPage()
assert fi.open_editor(editor, "new", "p", "i", wait_s=60) and editor.loads == 3, editor.loads
editor.loads, editor.settles_at = 0, float("inf")
assert not fi.open_editor(editor, "new", "p", "i", wait_s=0) and editor.loads == 1, editor.loads

# 2026-10-03 com: the Image Editor frame kept a squashed width, and the layer landed at (108, 108, 864, 864).
def frames(*widths):
    queue = [types.SimpleNamespace(width=w, frame_element=lambda w=w: types.SimpleNamespace(
        bounding_box=lambda: {"width": w})) for w in widths]
    fi.open_editor_once = lambda page, account, project: queue.pop(0)
    return queue


wide = fi.TOOL_VIEWPORT["width"] * 0.88
left = frames(wide * 0.5, wide)
assert fi.open_editor_tool(None, "new", "p").width == wide and not left, left
frames(wide * 0.5, wide * 0.5)
try:
    fi.open_editor_tool(None, "new", "p")
    raise AssertionError("a squashed frame twice")
except gw.Failure as failure:
    assert "Image Editor frame stays" in failure.reason, failure.reason


# 2026-10-05 loiyehor: the model menu lacked the label and stayed open; the finally's click on Settings trigger
# waited 30 s behind the menu's backdrop and its bare TimeoutError replaced the drift.
class SettingsPage:
    popover = menu = False
    onboarding = True

    def get_by_role(self, role, name=None, exact=None):
        page = self

        class Target:
            last = first = property(lambda self: self)

            def count(self):
                if name == "Select model family":
                    return int(page.popover)
                if hasattr(name, "search"):
                    return int(page.onboarding and bool(name.search("Got it, dismiss onboarding message")))
                return 1

            def nth(self, index):
                return self

            def is_visible(self):
                return self.count() > 0

            def wait_for(self, timeout=None):
                if not self.count():
                    raise TimeoutError("family")

            def inner_text(self, timeout=None):
                return "Nano Banana Pro arrow_drop_down"

            def click(self, timeout=None):
                if name == "Settings trigger":
                    if page.menu:
                        raise TimeoutError(f"Locator.click: Timeout {timeout or 30000}ms exceeded.")
                    page.popover = not page.popover
                elif name == "Select model family":
                    page.menu = True
                elif role == "menuitem":
                    raise TimeoutError("Locator.click: Timeout 5000ms exceeded.")
                elif hasattr(name, "search"):
                    page.onboarding = False

        return Target()

    def locator(self, selector):
        page = self
        if selector != ".cdk-overlay-backdrop":
            return types.SimpleNamespace(count=lambda: 0)
        return types.SimpleNamespace(count=lambda: int(page.menu), last=types.SimpleNamespace(
            click=lambda position: setattr(page, "menu", False)))

    def wait_for_timeout(self, ms):
        pass


page = SettingsPage()
try:
    fi.settings(page, {"label": "Nano Banana 2.1", "aspect": None, "count": 1, "price": 0}, editor=True)
    raise AssertionError("a model the menu lacks was set")
except gw.Failure as failure:
    assert failure.reason.startswith("Flow UI drift: image settings (TimeoutError"), failure.reason
assert not page.menu and not page.popover, vars(page)
# Flow's model onboarding callout names its button "Got it, dismiss onboarding message".
saved_promos, gw.close_promos = gw.close_promos, lambda page, account: 0
gw.dismiss_dialogs(page)
gw.close_promos = saved_promos
assert not page.onboarding, "the onboarding callout stayed open"
PY

# The card finder on a fake DOM shaped like the live editor history (2026-10-02 failure shot): a Failed card
# from an earlier job stays out, a new one is found with its own Retry, a page-level Retry is no card.
if command -v node >/dev/null 2>&1; then
  assert node - "$WORK/failed-cards.js" <<'JS'
const assert = require('assert');
const find = eval('(' + require('fs').readFileSync(process.argv[2], 'utf8') + ')');
class Text { constructor(text) { this.nodeType = 3; this.textContent = text; } }
class El {
  constructor(tag, attrs, kids = []) {
    Object.assign(this, {nodeType: 1, tag, attrs, childNodes: [], parentElement: null});
    kids.forEach(kid => this.append(kid));
  }
  append(kid) {
    if (typeof kid === 'string') kid = new Text(kid);
    this.childNodes.push(kid);
    if (kid.nodeType === 1) kid.parentElement = this;
    return kid;
  }
  all() { return this.childNodes.filter(n => n.nodeType === 1).flatMap(n => [n, ...n.all()]); }
  querySelectorAll(selector) { return selector === 'button' ? this.all().filter(n => n.tag === 'button') : this.all(); }
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; }
  get innerText() { return this.childNodes.map(n => n.nodeType === 3 ? n.textContent : n.innerText).join('\n'); }
}
const card = (retry) => new El('div', {}, [
  new El('i', {}, ['warning']), new El('div', {}, ['Failed']),
  new El('div', {}, ['Sorry, this image failed to generate.']),
  new El('div', {}, ['You have not been charged for this generation.']),
  new El('div', {}, [retry, new El('button', {'aria-label': 'Reuse prompt'}, [new El('i', {}, ['undo'])]),
                     new El('button', {'aria-label': 'Delete'}, [new El('i', {}, ['delete'])])])]);
const prompt = () => new El('div', {}, [new El('div', {}, ['Change only the pendant']),
                                        new El('button', {'aria-label': 'Reuse prompt'}, [])]);
const body = new El('body', {});
globalThis.document = {querySelectorAll: selector => { assert.strictEqual(selector, 'body *'); return body.all(); }};
const panel = body.append(new El('div', {}, [prompt(), card(new El('button', {'aria-label': 'Retry'}, [])), prompt()]));
body.append(new El('button', {}, ['refresh\nRetry']));
assert.strictEqual(find('mark'), 1);
assert.strictEqual(find('count'), 0);
const retry = new El('button', {'aria-label': 'Retry'}, [new El('i', {}, ['refresh'])]);
const fresh = panel.append(card(retry));
assert.strictEqual(find('count'), 1);
assert.deepStrictEqual(find('retry'), [retry]);
const textRetry = new El('button', {}, ['refresh\nRetry']);
panel.append(card(textRetry));
assert.strictEqual(find('count'), 2);
panel.append(new El('div', {}, ['2 images failed to generate']));
assert.strictEqual(find('count'), 2);
fresh.childNodes[2].childNodes[0].textContent = 'Generating';
assert.deepStrictEqual(find('retry'), [textRetry]);
JS
else
  printf 'SKIP failed-card finder: no node on PATH\n' >&2
fi

echo "PASS test_flow_image ($asserts asserts)"
