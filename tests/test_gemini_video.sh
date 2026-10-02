#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/gemini-video"
MANIFEST="$ROOT/share/image-caps/gemini.json"
WORK="$(mktemp -d)"
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
export LLM_LIMITS_GEMINI_REMOVED="$WORK/gemini-main.removed"
export GEMINIB_PROFILES_DIR="$WORK/gemini-profiles" WORKER_PICK_CONFIG_FILE="$WORK/pins" LLM_LIMITS_FILE="$WORK/limits.json" CHAT_PINS_DIR="$WORK/chat-pins"
mkdir -p "$GEMINIB_PROFILES_DIR/.geminib"
: >"$WORKER_PICK_CONFIG_FILE"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() {
  echo "FAIL: $*" >&2
  [ -z "${VIDEO_ERR:-}" ] || sed -n '1,40p' "$VIDEO_ERR" >&2
  exit 1
}
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then fail "assert $asserts unexpectedly succeeded: $*"; fi
}

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required for this suite"
OUT="$WORK/out"
mkdir -p "$OUT"
CLIP="$WORK/clip.mp4"
ffmpeg -v error -f lavfi -i color=c=blue:s=1280x720:d=1:r=24 -c:v libx264 -pix_fmt yuv420p "$CLIP" \
  || fail "could not build the fixture clip"
FRAME="$WORK/frame.png"
ffmpeg -v error -f lavfi -i color=c=red:s=1280x720 -frames:v 1 "$FRAME" || fail "no fixture frame"
LONG="$WORK/long.mp4"
ffmpeg -v error -f lavfi -i color=c=green:s=320x180:d=31:r=4 -c:v libx264 -pix_fmt yuv420p "$LONG" \
  || fail "could not build the long fixture clip"

ENGINE="$WORK/fake-gemini-web"
ENGINE_CALLS="$WORK/engine-calls"
export ENGINE_CALLS CLIP
cat >"$ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ENGINE_CALLS"
dest=''
while [ "$#" -gt 0 ]; do
  case "$1" in --dest) dest=$2; shift 2 ;; *) shift ;; esac
done
case "${ENGINE_MODE:-ok}" in
  ok)
    cp "$CLIP" "$dest"
    printf '{"ok": true, "account": "acct-a", "model": "%s", "media_id": "m-1", "build": "boq_test_1", "cost": 20, "charged": %s, "seconds": {"harness": 12.5, "render": 55.0, "total": 87.6}}\n' \
      "${ENGINE_MODEL:-veo_3_1_t2v_fast}" "${ENGINE_CHARGED:-20}" ;;
  variants)
    cp "$CLIP" "$dest"
    cp "$CLIP" "${dest%.mp4}-2.mp4"
    printf '{"ok": true, "account": "acct-a", "model": "abra_t2v_4s_360p", "media_id": "m-1", "build": "b", "variants": [{"dest": "%s", "media_id": "m-1"}, {"dest": "%s", "media_id": "m-2"}], "refused": [{"media_id": "m-3", "error": "PUBLIC_ERROR_SAFETY"}]}\n' \
      "$dest" "${dest%.mp4}-2.mp4" ;;
  refuse) printf '{"ok": false, "code": 2, "reason": "Flow will not extend this clip (Only Veo-generated videos can be extended)"}\n'; exit 2 ;;
  empty) printf '{"ok": true, "account": "acct-a"}\n' ;;
  limit) printf '{"ok": false, "code": 3, "reason": "acct-a has 5 Flow credits", "account": "acct-a"}\n'; exit 3 ;;
  login) printf '{"ok": false, "code": 4, "reason": "account acct-a has no browser login"}\n'; exit 4 ;;
  drift) printf '{"ok": false, "code": 1, "reason": "Flow UI drift: no composer"}\n'; exit 1 ;;
  garbage) printf 'Traceback (most recent call last)\n'; exit 1 ;;
esac
EOF
chmod +x "$ENGINE"
export GEMINI_VIDEO_ENGINE="$ENGINE"

VIDEO_OUT="$WORK/video.out"
VIDEO_ERR="$WORK/video.err"
video_run() { "$SCRIPT" "$@" >"$VIDEO_OUT" 2>"$VIDEO_ERR"; }
video_rc() { video_run "$@"; printf '%s' "$?"; }
calls() { cat "$ENGINE_CALLS" 2>/dev/null; }
reset_calls() { : >"$ENGINE_CALLS"; }

reset_calls
assert test "$(video_rc --prompt 'drift')" = 2
assert test "$(video_rc --dest relative.mp4 --prompt 'drift')" = 2
assert test "$(video_rc --dest "$OUT/a.mov" --prompt 'drift')" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --aspect 4:3)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --duration 5)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --duration 6 --model fast)" = 2
assert grep -q 'Veo 3.1 - Fast takes duration 8, not 6' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --model nope)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --ref "$FRAME" --ref "$FRAME" --ref "$FRAME" --ref "$FRAME" --ref "$FRAME")" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --model fast --ref "$FRAME" --ref "$FRAME" --ref "$FRAME" --ref "$FRAME")" = 2
assert grep -q 'Veo 3.1 - Fast takes at most 3 --ref images' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --first-frame "$WORK/missing.png")" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --last-frame "$WORK/missing.png")" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --account 'Bad Name')" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --first-frame "$FRAME" --ref "$FRAME" --ref "$FRAME")" = 2
assert grep -q 'separate Flow modes' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --last-frame "$FRAME" --edit "$CLIP")" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --edit "$CLIP" --duration 8)" = 2
assert grep -q 'keeps the length of its source' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --edit "$LONG")" = 2
assert grep -q 'edits videos of up to 30s' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --edit "$CLIP" --model fast)" = 2
assert grep -q 'Veo 3.1 - Fast cannot edit a video at 720p' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --model fast --resolution 360p)" = 2
assert grep -q 'Veo 3.1 - Fast renders 720p, not 360p' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --resolution 4k)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --edit "$CLIP" --resolution 360p)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --count 5)" = 2
assert grep -q 'Flow makes 1|2|3|4 clips per send, not 5' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'drift' --count 0)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$CLIP" --ref "$FRAME")" = 2
assert grep -q 'takes no frames, --ref or --edit' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$CLIP" --first-frame "$FRAME")" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$CLIP" --edit "$CLIP")" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$CLIP" --duration 8)" = 2
assert grep -q 'adds 7s' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$CLIP" --model fast)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$CLIP" --aspect 9:16)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$CLIP" --count 2)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$CLIP" --resolution 360p)" = 2
assert grep -q 'Extend (Veo 3.1 - Lite) renders 720p, not 360p' "$VIDEO_ERR"
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend clip.mp4)" = 2
assert test "$(video_rc --dest "$OUT/a.mp4" --prompt 'go on' --extend "$WORK/missing.mp4")" = 2
assert test ! -s "$ENGINE_CALLS"

reset_calls
ENGINE_MODEL=veo_3_1_extension_lite ENGINE_CHARGED=10 video_run --dest "$OUT/ext.mp4" --prompt 'go on' --extend "$CLIP"
assert grep -qx -- "generate --prompt go on --dest $OUT/ext.mp4 --extend $CLIP --resolution 720p" "$ENGINE_CALLS"
assert grep -qx 'model=veo_3_1_extension_lite model_caps=fresh' "$VIDEO_OUT"
assert test "$(video_rc --dest "$OUT/ext.mp4" --prompt 'go on' --extend "$CLIP" --resolution 1080p)" = 2
assert grep -q 'no upscaled download of an extension' "$VIDEO_ERR"
reset_calls
ENGINE_MODEL='models/veo-3.1-lite-generate-002;backend_beyond' video_run --dest "$OUT/ext.mp4" --prompt 'go on' --extend "$CLIP" --account acct-a
assert grep -qx -- "generate --prompt go on --dest $OUT/ext.mp4 --extend $CLIP --resolution 720p --account acct-a" "$ENGINE_CALLS"
assert grep -qx 'model=models/veo-3.1-lite-generate-002;backend_beyond model_caps=fresh' "$VIDEO_OUT"
assert_fails grep -q 'Flow charged' "$VIDEO_ERR"
assert test "$(ENGINE_MODE=refuse video_rc --dest "$OUT/r.mp4" --prompt 'go on' --extend "$CLIP")" = 2
assert grep -q 'Only Veo-generated videos can be extended' "$VIDEO_ERR"
assert_fails grep -q GEMINI_USAGE_LIMIT "$VIDEO_ERR"

reset_calls
ENGINE_MODE=variants video_run --dest "$OUT/var.mp4" --prompt 'water light' --duration 4 --resolution 360p --count 2
assert grep -q -- '--duration 4 --aspect 16:9 --model omni --resolution 360p --count 2' "$ENGINE_CALLS"
assert grep -qx "dest=$OUT/var.mp4" "$VIDEO_OUT"
assert grep -qx "variant=$OUT/var-2.mp4 size=1280x720 duration=1 media=m-2" "$VIDEO_OUT"
assert grep -qx 'refused=m-3 PUBLIC_ERROR_SAFETY' "$VIDEO_OUT"
reset_calls
ENGINE_CHARGED=25 video_run --dest "$OUT/eight.mp4" --prompt 'water light'
assert grep -q 'Flow charged 25 credits, the manifest says 20' "$VIDEO_ERR"
assert_fails grep -q -- '--count' "$ENGINE_CALLS"
assert_fails grep -q '^variant=' "$VIDEO_OUT"

reset_calls
assert video_run --dest "$OUT/eight.mp4" --prompt 'water light'
assert_fails grep -q 'Flow charged' "$VIDEO_ERR"
assert grep -q -- '--duration 8 --aspect 16:9 --model fast' "$ENGINE_CALLS"
assert_fails grep -q -- '--account' "$ENGINE_CALLS"
reset_calls
ENGINE_MODEL=abra_t2v_6s_720p video_run --dest "$OUT/six.mp4" --prompt 'water light' --duration 6
assert grep -q -- '--duration 6 --aspect 16:9 --model omni --resolution 720p' "$ENGINE_CALLS"
assert grep -qx 'model=abra_t2v_6s_720p model_caps=fresh' "$VIDEO_OUT"
reset_calls
ENGINE_MODEL=veo_3_1_t2v_lite video_run --dest "$OUT/swap.mp4" --prompt 'water light' --duration 6
assert grep -qx 'model=veo_3_1_t2v_lite model_caps=stale verified=^abra_,^omni_flash_' "$VIDEO_OUT"
reset_calls
ENGINE_MODEL=abra_t2v_8s_360p video_run --dest "$OUT/low.mp4" --prompt 'water light' --resolution 360p
assert grep -q -- '--duration 8 --aspect 16:9 --model omni --resolution 360p' "$ENGINE_CALLS"

reset_calls
assert video_run --dest "$OUT/hd.mp4" --prompt 'water light' --resolution 1080p
assert grep -q -- '--duration 8 --aspect 16:9 --model fast --resolution 1080p' "$ENGINE_CALLS"
reset_calls
assert video_run --dest "$OUT/hd4.mp4" --prompt 'water light' --resolution 1080p --duration 4
assert grep -q -- '--duration 4 --aspect 16:9 --model omni --resolution 1080p' "$ENGINE_CALLS"

reset_calls
assert video_run --dest "$OUT/ff.mp4" --prompt 'water light' --ref "$FRAME" --account acct-a
assert grep -q -- "--account acct-a --first-frame $FRAME" "$ENGINE_CALLS"
assert_fails grep -q -- '--ref' "$ENGINE_CALLS"
reset_calls
cp "$FRAME" "$WORK/last.png"
assert video_run --dest "$OUT/fl.mp4" --prompt 'water light' --ref "$FRAME" --last-frame "$WORK/last.png"
assert grep -q -- "--first-frame $FRAME --last-frame $WORK/last.png" "$ENGINE_CALLS"
reset_calls
assert video_run --dest "$OUT/refs.mp4" --prompt 'water light' --ref "$FRAME" --ref "$WORK/last.png"
assert grep -q -- "--model fast --resolution 720p --ref $FRAME --ref $WORK/last.png" "$ENGINE_CALLS"
assert_fails grep -q -- '--first-frame' "$ENGINE_CALLS"
reset_calls
assert video_run --dest "$OUT/refs4.mp4" --prompt 'water light' --ref "$FRAME" --ref "$FRAME" --ref "$FRAME" --ref "$FRAME"
assert grep -q -- '--model omni' "$ENGINE_CALLS"
test "$(grep -o -- '--ref ' "$ENGINE_CALLS" | wc -l | tr -d ' ')" = 4 || fail "four refs were not passed through"
reset_calls
assert video_run --dest "$OUT/edit.mp4" --prompt 'turn it into watercolor' --edit "$CLIP" --ref "$FRAME"
assert grep -q -- "--model omni --resolution 720p --edit $CLIP --ref $FRAME" "$ENGINE_CALLS"
assert_fails grep -q -- '--first-frame' "$ENGINE_CALLS"

reset_calls
assert video_run --dest "$OUT/footer.mp4" --prompt 'water light' --aspect 9:16
assert grep -qx "dest=$OUT/footer.mp4" "$VIDEO_OUT"
assert grep -qx 'size=1280x720' "$VIDEO_OUT"
assert grep -qx 'format=mp4' "$VIDEO_OUT"
assert grep -qx 'duration=1' "$VIDEO_OUT"
assert grep -qx 'account=acct-a' "$VIDEO_OUT"
assert grep -qx 'media=m-1' "$VIDEO_OUT"
assert grep -qx 'model=veo_3_1_t2v_fast model_caps=fresh' "$VIDEO_OUT"
assert grep -qx 'caps=fresh surface=boq_test_1' "$VIDEO_OUT"
assert grep -qx 'seconds=87.6 harness=12.5 render=55.0' "$VIDEO_OUT"
assert jq -e 'select(.tool == "gemini-video" and .kind == "video" and .rc == 0 and .account == "acct-a")' \
  "$IMAGE_LEG_LOG" >/dev/null

# Exit 3 sends callers round the pool as if quota were spent, so a login or drift must never map to it.
assert test "$(ENGINE_MODE=limit video_rc --dest "$OUT/l.mp4" --prompt 'x')" = 3
assert grep -qx GEMINI_USAGE_LIMIT "$VIDEO_ERR"
assert grep -q 'acct-a has 5 Flow credits' "$VIDEO_ERR"
assert test "$(ENGINE_MODE=login video_rc --dest "$OUT/l.mp4" --prompt 'x')" = 4
assert grep -q 'no browser login' "$VIDEO_ERR"
assert test "$(ENGINE_MODE=drift video_rc --dest "$OUT/d.mp4" --prompt 'x')" = 1
assert grep -q 'Flow UI drift' "$VIDEO_ERR"
assert test "$(ENGINE_MODE=garbage video_rc --dest "$OUT/g.mp4" --prompt 'x')" = 1
assert grep -q 'engine failed with exit 1' "$VIDEO_ERR"
assert test "$(ENGINE_MODE=empty video_rc --dest "$OUT/e.mp4" --prompt 'x')" = 1
assert grep -q 'is empty' "$VIDEO_ERR"

assert python3 - "$ROOT/share" "$ROOT/tests/fixtures/flow-traffic.json" <<'EOF'
import json, sys, urllib.parse
sys.path.insert(0, sys.argv[1])
import gemini_web as g

items = [item for item in json.load(open(sys.argv[2])) if item["kind"] in ("jwpduf", "as29s")]
clip = "0204fe88-a03f-4762-8ae3-b182951b626d"
prompt = "slow ripples of sunlight on clear shallow water over pale sand, gentle caustics, calm, no people, no text."
w = g.Watcher()
w.feed(items[0]["body"])
assert w.media[clip]["status"] == 2 and w.media[clip]["fresh"], w.media[clip]
assert w.media[clip]["prompt"] == prompt and w.media[clip]["model"] == "veo_3_1_t2v_fast", w.media[clip]
assert w.new_clip(set(), prompt) == clip
assert w.new_clip({clip}, prompt) is None
for item in items[1:]:
    w.feed(item["body"])
record = w.media[clip]
assert record["status"] == g.DONE and record["duration"] == 8 and record["fresh"], record
assert record["url"].startswith("https://flow-content.google/video/" + clip + "?"), record
assert "Signature=FIXTURE" in record["url"], record["url"]
assert w.credits == 1030, w.credits
late = g.Watcher()
for item in items[1:]:
    late.feed(item["body"])
assert not late.media[clip]["fresh"] and late.new_clip(set(), prompt) is None, late.media[clip]
other = g.Watcher()
other.feed(items[0]["body"])
assert other.new_clip(set(), "a different prompt") == clip
other.feed(items[0]["body"].replace("0204fe88", "0204fe99"))
assert other.new_clip(set(), "a different prompt") is None
assert other.new_clip(set(), prompt) in (clip, clip.replace("0204fe88", "0204fe99"))

manual = json.load(open(sys.argv[2].replace("flow-traffic", "flow-manual-traffic")))
made = "1023f0f5-b655-4402-859c-eafc600a06d5"
m = g.Watcher()
m.feed(items[0]["body"])
m.feed(manual[0]["body"])
assert manual[0]["kind"] in g.GENERATE_RPCS and m.credits == 1046, m.credits
assert m.media[made]["created"] and m.media[made]["model"] == "abra_t2v_4s_360p", m.media[made]
assert m.new_clip(set(), "the prompt text Flow shows is not the one we sent") == made
assert m.media[made]["scene"] == "578a06f6-3be5-4dcb-bda5-5f0673a1c42a", m.media[made]
edit_reply = g.Watcher()
edit_reply.feed(manual[0]["body"].replace('"YhhmEf"', '"jIps6"'))
assert edit_reply.new_clip(set(), "") == made and edit_reply.credits == 1046
assert g.wire_models(manual[0]["request"]) == ["abra_t2v_4s_360p"], g.wire_models(manual[0]["request"])
for item in manual[1:]:
    m.feed(item["body"])
assert m.media[made]["status"] == g.DONE and m.media[made]["duration"] == 4, m.media[made]
assert m.media[made]["url"].startswith("https://flow-content.google/video/" + made + "?"), m.media[made]
assert m.reply_credits == 1046 and w.reply_credits is None, (m.reply_credits, w.reply_credits)
assert m.new_clips(set()) == [made] and m.new_clips({made}) == []

extend = json.load(open(sys.argv[2].replace("flow-traffic", "flow-extend-traffic")))
grown = "35421d3f-d466-4934-9bbe-bb9574baf259"
x = g.Watcher()
x.feed(extend[0]["body"])
assert extend[0]["kind"] in g.GENERATE_RPCS and x.reply_credits == 980, x.reply_credits
assert x.new_clips(set()) == [grown] and x.media[grown]["scene"] == "efb47411-41f5-4c30-a34f-26dbb0c49436", x.media
assert x.media[grown]["model"].startswith("models/veo-3.1-lite"), x.media[grown]
assert g.wire_models(extend[0]["request"]) == ["veo_3_1_extension_lite"], g.wire_models(extend[0]["request"])
for item in extend[1:]:
    x.feed(item["body"])
assert x.media[grown]["status"] == g.DONE and x.reply_credits == 980, x.media[grown]

inner = json.dumps([[[None, None, [[[["drift"]]]]], "abra_t2v_4s_360p", 2, None, [None, "2C08"]]])
body = "f.req=" + urllib.parse.quote_plus(json.dumps([[["YhhmEf", inner, None, "generic"]]])) + "&at=x"
assert g.wire_models(body) == ["abra_t2v_4s_360p"], g.wire_models(body)
assert g.wire_models("f.req=veo_3_1_i2v_s_fast+veo_3_1_i2v_s_fast") == ["veo_3_1_i2v_s_fast"]

assert w.blocked() is None
flagged = g.Watcher()
flagged.feed(""")]}'\n\n192\n[["wrb.fr","YhhmEf",null,null,null,[7,null,[["type.googleapis.com/google.rpc.ErrorInfo",["PUBLIC_ERROR_UNUSUAL_ACTIVITY"]]]],"generic"]]\n""")
failure = flagged.blocked()
assert failure and failure.code == 3 and failure.extra["wall_s"] == g.BLOCK_WALL_SECONDS, failure
old_tile = g.Watcher()
old_tile.feed(""")]}'\n[["wrb.fr","jwpduf","[null,1050,[[\\"m-old\\",null,\\"PUBLIC_ERROR_UNUSUAL_ACTIVITY\\"]]]",null,null,null,"generic"]]\n""")
assert old_tile.blocked() is None and old_tile.media["m-old"]["error"] == "PUBLIC_ERROR_UNUSUAL_ACTIVITY", old_tile.media
EOF

assert python3 - "$ROOT/share" "$FRAME" "$CLIP" <<'EOF'
import argparse, sys
sys.path.insert(0, sys.argv[1])
import gemini_web as g
frame, clip = sys.argv[2], sys.argv[3]

def plan(**kw):
    base = dict(model="fast", duration=8, aspect="16:9", resolution="720p", first_frame=None,
                last_frame=None, ref=[], edit=None, count=1, extend=None)
    return g.make_plan(argparse.Namespace(**{**base, **kw}))

def refused(**kw):
    try:
        plan(**kw)
    except g.Failure as failure:
        return failure.code == 2
    return False

p = plan()
assert (p["cost"], p["mode"], p["label"], p["duration"]) == (20, "Frames", "Veo 3.1 - Fast", 8), p
assert plan(model="omni", duration=4, resolution="360p")["cost"] == 4
assert plan(model="quality")["cost"] == 100
p = plan(model="omni", duration=10, first_frame=frame, last_frame=frame)
assert (p["cost"], p["mode"]) == (15, "Frames"), p
p = plan(ref=[frame, frame, frame])
assert (p["cost"], p["mode"]) == (20, "Ingredients"), p
p = plan(model="omni", edit=clip, ref=[frame])
assert (p["cost"], p["mode"], p["duration"], p["upscale"]) == (20, "Ingredients", None, None), p
p = plan(resolution="1080p")
assert (p["cost"], p["resolution"], p["upscale"]) == (20, "720p", "1080p"), p
p = plan(model="omni", edit=clip, resolution="1080p")
assert (p["cost"], p["resolution"], p["upscale"]) == (20, "720p", "1080p"), p
assert refused(model="omni", duration=4, resolution="4k")
assert refused(ref=[frame] * 4)
assert refused(model="omni", ref=[frame] * 5)
assert refused(first_frame=frame, ref=[frame])
assert refused(last_frame=frame, edit=clip, model="omni")
assert refused(resolution="360p")
assert refused(edit=clip)
assert refused(model="omni", edit=clip, resolution="360p")
assert refused(model="omni", duration=5)
assert refused(ref=["/nonexistent.png"])
assert refused(model="nope")
p = plan(model="omni", duration=4, resolution="360p", count=3)
assert (p["cost"], p["count"], p["what"]) == (12, 3, "Omni 1.1 Flash 360p 4s x3"), p
assert plan(model="omni", edit=clip, count=2)["cost"] == 40
assert refused(count=5) and refused(count=0)
assert plan()["count"] == 1 and plan()["extend"] is None
EOF

GW="$WORK/gemini-web-root"
mkdir -p "$GW/profiles/walled/Default" "$GW/profiles/rich/Default" "$GW/profiles/nologin" "$GW/accounts"
mkdir -p "$GEMINIB_PROFILES_DIR/walled" "$GEMINIB_PROFILES_DIR/rich" "$GEMINIB_PROFILES_DIR/nologin"
: >"$GW/profiles/walled/Default/Cookies"
: >"$GW/profiles/rich/Default/Cookies"
printf '{"email": "w@example.com", "credits": 900}' >"$GW/accounts/walled.json"
printf '{"email": "r@example.com", "credits": 40}' >"$GW/accounts/rich.json"
printf '{"walled": %s}' "$(($(date +%s) + 3600))" >"$GW/walls.json"
assert env GEMINI_WEB_DIR="$GW" python3 - "$ROOT/share" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import gemini_web as g
assert g.rotation(20) == ["rich"], g.rotation(20)
assert g.bound_accounts() == ["rich", "walled"], g.bound_accounts()
g.set_wall("walled", None)
g.write_meta("rich", generation_started_at=100)
g.write_meta("walled", generation_started_at=200)
assert g.rotation(20) == ["rich", "walled"], "the richer balance went first, not the least recently started"
g.write_meta("walled", generation_started_at=50)
assert g.rotation(20) == ["walled", "rich"], g.rotation(20)
assert g.least_recent(["rich", "fresh"]) == ["fresh", "rich"], "a never-used account went after a used one"
import argparse, io, contextlib, time
started = []
real_render_on, g.render_on = g.render_on, lambda account, *rest: started.append(account) or {"ok": True}
def stamp(account, extend=None, dry=False):
    before = g.read_meta(account).get("generation_started_at")
    g.generate_on(account, {"extend": extend}, argparse.Namespace(dest="/tmp/x.mp4", dry_run=dry))
    return before, g.read_meta(account).get("generation_started_at")
assert stamp("rich", extend={"account": "rich"}) == (100, 100), "an extend stamped a new generation"
assert stamp("rich", dry=True) == (100, 100), "a dry run stamped a new generation"
before, after = stamp("rich")
assert after >= time.time() - 60 and started == ["rich"] * 3, (before, after, started)
g.write_meta("rich", generation_started_at=100)
g.render_on = real_render_on
tried = []
def fake_generate_on(account, plan, args):
    tried.append(account)
    if account == "walled":
        raise g.Failure(3, "flagged", wall_s=g.BLOCK_WALL_SECONDS)
    return {"ok": True, "account": account}
g.generate_on = fake_generate_on
args = argparse.Namespace(model="fast", duration=8, aspect="16:9", resolution="720p", first_frame=None,
                          last_frame=None, ref=[], edit=None, account=None, count=1, extend=None)
out = io.StringIO()
with contextlib.redirect_stdout(out):
    g.cmd_generate(args)
assert tried == ["walled", "rich"] and '"account": "rich"' in out.getvalue(), (tried, out.getvalue())
assert g.walls()["walled"] > time.time() + g.WALL_SECONDS, g.walls()
EOF

# The gemini roster the menubar lists bounds every pick: a signed-in, bound Flow profile it does not list
# (an account removed in the menu, or main behind its removal marker) is never rotated and refused by name.
GWX="$WORK/gemini-web-offroster"
for name in rich blocked main; do
  mkdir -p "$GWX/profiles/$name/Default" "$GWX/accounts"
  : >"$GWX/profiles/$name/Default/Cookies"
  printf '{"email": "%s@example.com", "credits": 5000}' "$name" >"$GWX/accounts/$name.json"
done
: >"$LLM_LIMITS_GEMINI_REMOVED"
assert env GEMINI_WEB_DIR="$GWX" python3 - "$ROOT/share" <<'EOF'
import argparse, sys
sys.path.insert(0, sys.argv[1])
import gemini_web as g
assert "blocked" not in g.roster() and "main" not in g.roster() and "rich" in g.roster(), g.roster()
assert g.bound_accounts() == ["rich"], g.bound_accounts()
assert g.rotation(20) == ["rich"], g.rotation(20)
tried = []
g.generate_on = lambda account, plan, args: tried.append(account) or {"ok": True, "account": account}
for name in ("blocked", "main"):
    args = argparse.Namespace(model="fast", duration=8, aspect="16:9", resolution="720p", first_frame=None,
                              last_frame=None, ref=[], edit=None, account=name, count=1, extend=None)
    try:
        g.cmd_generate(args)
        raise AssertionError(f"{name} off the roster was run")
    except g.Failure as failure:
        assert failure.code == 2 and f"unknown account: {name}" in failure.reason, failure.reason
    try:
        with g.browser(name):
            raise AssertionError(f"a browser opened on {name} off the roster")
    except g.Failure as failure:
        assert failure.code == 2, failure.reason
assert tried == [], tried
EOF
assert test "$(GEMINI_WEB_DIR="$GWX" GEMINI_WEB_CHROME="$WORK/no-chrome.app" python3 "$ROOT/share/gemini_web.py" login ghost >/dev/null 2>&1; echo $?)" = 2
assert test ! -e "$GWX/profiles/ghost"
assert test -e "$GWX/profiles/blocked/Default/Cookies"
rm -f "$LLM_LIMITS_GEMINI_REMOVED"

# Flow credit totals: a refill jump starts the cycle, and its balance is the cycle's total.
assert env GEMINI_WEB_DIR="$GW" python3 - "$ROOT/share" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import gemini_web as g

g.write_meta("totals", credits=828)
g.note_credits("totals", 700)
assert "credits_refilled_at" not in g.read_meta("totals") and "credits_total" not in g.read_meta("totals"), \
    "a spend counted as a refill"
g.note_credits("totals", 1050)
meta = g.read_meta("totals")
assert meta["credits_total"] == 1050 and meta["credits_renews_at"] == g.month_after(meta["credits_refilled_at"]), meta
g.note_credits("totals", 1000)
g.note_credits("totals", 1040)
meta = g.read_meta("totals")
assert (meta["credits"], meta["credits_total"]) == (1040, 1050), "a spend or the daily top-up moved the cycle's total"
g.note_credits("totals", None)
assert g.read_meta("totals")["credits"] == 1040
assert not hasattr(g, "read_allowance"), "one.google.com states no Flow allowance; opening it only unhides Chrome"
assert g.month_after(1769817600) == 1772236800, g.month_after(1769817600)
EOF

# Rotation by cached balance gate and least recent start, past a sign-in step, and inside the gemini worker pool; the clone stays while in use.
assert env GEMINI_WEB_DIR="$GW" python3 - "$ROOT/share" "$GEMINIB_PROFILES_DIR/.geminib/disabled" <<'EOF'
import argparse, contextlib, fcntl, io, os, sys, time
sys.path.insert(0, sys.argv[1])
import gemini_web as g
disabled = sys.argv[2]
g.set_wall("walled", None)
now = int(time.time())
g.write_meta("walled", credits=0, credits_at=now - 2 * g.WALL_SECONDS)
g.write_meta("rich", credits=5, credits_at=now)
assert g.rotation(4) == ["walled", "rich"], g.rotation(4)
assert g.rotation(20) == ["walled"], g.rotation(20)
g.write_meta("walled", credits=0, credits_at=now)
assert g.rotation(20) == [], g.rotation(20)
args = argparse.Namespace(model="fast", duration=8, aspect="16:9", resolution="720p", first_frame=None,
                          last_frame=None, ref=[], edit=None, account=None, count=1, extend=None)

def run(**kw):
    try:
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            g.cmd_generate(argparse.Namespace(**{**vars(args), **kw}))
    except g.Failure as failure:
        return failure.code, failure.reason
    return 0, out.getvalue()

code, reason = run()
assert code == 3 and "holds under 20 credits" in reason, reason
g.write_meta("walled", credits=900, credits_at=now)
g.write_meta("rich", credits=40, credits_at=now)
tried = []
def short(account, plan, args):
    tried.append(account)
    if account == "walled":
        raise g.Failure(3, "walled has 5 Flow credits; a clip costs 20", credits=5)
    raise g.Failure(4, "rich shows Gemini's notice; it needs the owner's one-time Agree")
g.generate_on = short
code, reason = run()
assert code == 3 and tried == ["walled", "rich"] and "rich: rich shows" in reason, (code, tried, reason)
assert "walled" not in g.walls(), g.walls()
tried.clear()
def signed_out(account, plan, args):
    tried.append(account)
    if account == "walled":
        raise g.Failure(4, "Google signed walled out; run: geminib web walled")
    return {"ok": True, "account": account}
g.generate_on = signed_out
assert run()[0] == 0 and tried == ["walled", "rich"], tried
tried.clear()
open(disabled, "w").write("walled\n")
g._pool = None
assert g.rotation(20) == ["rich"] and run()[0] == 0 and tried == ["rich"], tried
code, reason = run(account="walled")
assert code == 4 and "out of the gemini worker pool" in reason and tried == ["rich"], (code, reason)
open(disabled, "w").write("walled\nrich\n")
g._pool = None
code, reason = run()
assert code == 4 and "every signed-in Flow account is out of the gemini worker pool" in reason, reason
open(os.environ["WORKER_PICK_CONFIG_FILE"], "w").write("gemini" + "_profile=walled\n")
g._pool = None
assert g.rotation(20) == ["walled"], g.rotation(20)
os.chmod(disabled, 0)
g._pool = None
assert g.rotation(20) == ["walled"] and not g.in_pool("rich")
os.chmod(disabled, 0o644)
open(os.environ["WORKER_PICK_CONFIG_FILE"], "w").write("")
open(disabled, "w").write("")
g._pool = None

app = g.ROOT / "chrome" / "Google Chrome.app"
(app / "Contents").mkdir(parents=True)
plist = '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>'
(app / "Contents" / "Info.plist").write_text(plist % "2")
g.SOURCE_APP = app
(g.CLONE_APP / "Contents").mkdir(parents=True)
(g.CLONE_APP / "Contents" / "Info.plist").write_text(plist % "1")
real_build, built = g.build_clone, []
g.build_clone = lambda: built.append(1)
with open(g.ROOT / ".clone-use.lock", "w") as other:
    fcntl.flock(other, fcntl.LOCK_SH)
    with g.chrome_clone() as clone:
        assert clone == g.CLONE_APP and built == []
with g.chrome_clone():
    assert built == [1]
(g.CLONE_APP / "Contents" / "Info.plist").write_text(plist % "2")
with g.chrome_clone():
    assert built == [1, 1], "a clone of the current Chrome that still carries its GoogleUpdater was kept"

import subprocess as sp
helpers = app / "Contents" / "Frameworks" / "Google Chrome Framework.framework" / "Versions" / "2" / "Helpers"
(helpers / "GoogleUpdater.app" / "Contents").mkdir(parents=True)
(helpers / "app_mode_loader").write_text("x")
(app / "Contents" / "Library" / "LaunchServices").mkdir(parents=True)
(app / "Contents" / "Library" / "LaunchServices" / "com.google.Chrome.UpdaterPrivilegedHelper").write_text("x")
real_run = g.subprocess.run
g.subprocess.run = lambda argv, **kw: real_run(argv, **kw) if argv[0] == "cp" else sp.CompletedProcess(argv, 0)
real_build()
g.subprocess.run = real_run
clone_helpers = g.CLONE_APP / helpers.relative_to(app)
assert not (clone_helpers / "GoogleUpdater.app").exists() and (clone_helpers / "app_mode_loader").exists()
assert not (g.CLONE_APP / "Contents" / "Library" / "LaunchServices").exists()
assert g.clone_current("2") and not g.clone_current("3")
EOF

VEO="$OUT/veo.mp4"
OMNI="$OUT/omni.mp4"
EDITED="$OUT/edited.mp4"
cp "$CLIP" "$VEO"
cp "$CLIP" "$OMNI"
cp "$CLIP" "$EDITED"
bytes=$(wc -c <"$CLIP" | tr -d ' ')
{
  printf '{"account": "rich", "media_id": "m-veo", "project": "p-1", "dest": "%s", "state": "queued"}\n' "$VEO"
  printf 'not json\n'
  printf '{"account": "rich", "media_id": "m-veo", "dest": "%s", "state": "saved", "model": "fast", "scene": "s-veo", "bytes": %s}\n' "$VEO" "$bytes"
  printf '{"account": "rich", "media_id": "m-omni", "project": "p-1", "dest": "%s", "state": "queued"}\n' "$OMNI"
  printf '{"account": "rich", "media_id": "m-omni", "dest": "%s", "state": "saved", "model": "omni", "scene": "s-omni", "bytes": %s}\n' "$OMNI" "$bytes"
  printf '{"account": "rich", "media_id": "m-old", "project": "p-0", "dest": "%s", "state": "queued"}\n' "$EDITED"
  printf '{"account": "rich", "media_id": "m-old", "dest": "%s", "state": "saved", "model": "fast", "bytes": 1}\n' "$EDITED"
  printf '{"account": "walled", "media_id": "m-w", "project": "p-2", "dest": "%s/walled.mp4", "state": "queued"}\n' "$OUT"
  printf '{"account": "walled", "media_id": "m-w", "dest": "%s/walled.mp4", "state": "saved"}\n' "$OUT"
  printf '{"account": "rich", "media_id": "m-ext", "project": "p-1", "dest": "%s/grown.mp4", "state": "queued", "model": "extend"}\n' "$OUT"
  printf '{"account": "rich", "media_id": "m-ext", "dest": "%s/grown.mp4", "state": "saved", "scene": "s-ext"}\n' "$OUT"
} >"$GW/jobs.jsonl"
cp "$CLIP" "$OUT/walled.mp4"
cp "$CLIP" "$OUT/grown.mp4"
printf '{"walled": %s}' "$(($(date +%s) + 3600))" >"$GW/walls.json"
assert env GEMINI_WEB_DIR="$GW" python3 - "$ROOT/share" "$VEO" "$OMNI" "$EDITED" "$OUT/walled.mp4" "$CLIP" "$FRAME" "$OUT/grown.mp4" <<'EOF'
import argparse, contextlib, io, sys
sys.path.insert(0, sys.argv[1])
import gemini_web as g
veo, omni, edited, walled, clip, frame, grown = sys.argv[2:9]

def ns(**kw):
    base = dict(model="fast", duration=8, aspect="16:9", resolution="720p", first_frame=None, last_frame=None,
                ref=[], edit=None, count=1, extend=veo, account=None)
    return argparse.Namespace(**{**base, **kw})

def refusal(**kw):
    try:
        g.make_plan(ns(**kw))
    except g.Failure as failure:
        return failure.code, failure.reason
    return None

p = g.make_plan(ns())
assert (p["model"], p["cost"], p["duration"], p["mode"], p["count"]) == ("extend", 10, 7, "Extend", 1), p
assert {k: p["extend"][k] for k in ("account", "media_id", "project", "scene", "model")} == \
    {"account": "rich", "media_id": "m-veo", "project": "p-1", "scene": "s-veo", "model": "fast"}, p["extend"]
assert refusal(resolution="1080p")[0] == 2 and g.make_plan(ns())["upscale"] is None
code, reason = refusal(extend=grown)
assert code == 2 and "itself an extension" in reason, reason
code, reason = refusal(extend=omni)
assert code == 2 and "made on omni" in reason and "video-chain last-frame" in reason, reason
code, reason = refusal(extend=edited)
assert code == 2 and "changed since gemini-video saved it" in reason, reason
code, reason = refusal(extend=clip)
assert code == 2 and "not a clip gemini-video saved" in reason, reason
assert refusal(ref=[frame])[0] == 2 and refusal(edit=clip)[0] == 2 and refusal(count=2)[0] == 2
assert refusal(resolution="360p")[0] == 2
code, reason = refusal(extend=veo.replace("veo", "missing"))
assert code == 2 and "not a file" in reason, reason

def run(**kw):
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            g.cmd_generate(ns(**kw))
    except g.Failure as failure:
        return failure.code, failure.reason
    return 0, ""

tried = []
def fake_generate_on(account, plan, args):
    tried.append(account)
    return {"ok": True, "account": account}
g.generate_on = fake_generate_on
until = g.walls()["walled"]
g.set_wall("walled", None)
g.write_meta("walled", generation_started_at=1)
g.write_meta("rich", generation_started_at=2)
assert g.rotation(10)[0] == "walled", g.rotation(10)
assert run() == (0, "") and tried == ["rich"], tried
g.set_wall("walled", until)
assert run(account="walled")[0] == 2 and tried == ["rich"]
code, reason = run(extend=walled)
assert code == 3 and "the only account holding walled.mp4" in reason and tried == ["rich"], (code, reason)
def poor(account, plan, args):
    raise g.Failure(3, "rich has 5 Flow credits")
g.generate_on = poor
assert run()[0] == 3 and g.walls().get("rich"), g.walls()

g.ledger({"account": "rich", "media_id": "m-up", "project": "p-9", "state": "queued"})
assert g.job_project("rich", "m-up") == "p-9" and g.job_project("rich", "m-none") == g.read_meta("rich").get("project")


class Download:
    def __init__(self, url):
        self.url, self.cancelled, self.saved = url, False, None

    def cancel(self):
        self.cancelled = True

    def save_as(self, path):
        self.saved = path
        Path(path).write_bytes(b"\0\0\0\x18ftypmp42")


class Clickable:
    def __init__(self, on_click=lambda: None):
        self.on_click = on_click

    def click(self, timeout=None):
        self.on_click()


class Editor:
    """A clip editor whose 1080p item either hands the page a blob link (`caught`) or starts a Chrome download."""

    def __init__(self, url, caught=None, body=b""):
        self.download, self.context, self.caught, self.body = Download(url), "ctx", None, body
        self.link, self.listeners, self.reads = caught, [], 0

    def on(self, event, listener):
        listener._pw_impl_instance_ = self
        self.listeners.append(listener)

    def remove_listener(self, event, listener):
        self.listeners.remove(listener)

    def item(self):
        if self.link:
            self.caught = self.link
        else:
            for listener in self.listeners:
                listener(self.download)

    def get_by_role(self, role, name, exact=True):
        return Clickable(self.item if role == "menuitem" else lambda: None)

    def evaluate(self, script, args=None):
        if script is g.CATCH_DOWNLOAD:
            self.caught = None
        elif script is g.CAUGHT:
            return self.caught
        elif script is g.READ_CHUNK:
            self.reads += 1
            url, start, size = args
            assert url == self.link, url
            return [len(self.body), base64.b64encode(self.body[start:start + size]).decode()]

    def wait_for_timeout(self, ms):
        pass


import base64
import tempfile
from pathlib import Path
hd = Path(tempfile.mkdtemp())
g.goto_flow = lambda page, path: None
g.close_promos = lambda page, account="-", keep=(): 0
fetched = []
g.save_video = lambda context, url, dest: fetched.append((context, url, str(dest))) or 7
editor = Editor("https://labs.google/fx/api/upscaled?x=1")
assert g.save_upscaled(editor, "p-1", "s-1", hd / "hd.mp4") == 7
assert editor.download.cancelled and editor.download.saved is None, vars(editor.download)
assert fetched == [("ctx", "https://labs.google/fx/api/upscaled?x=1", str(hd / "hd.mp4"))], fetched
blob = Editor("blob:https://labs.google/abc")
assert g.save_upscaled(blob, "p-1", "s-1", hd / "hd2.mp4") > 0 and not blob.download.cancelled and len(fetched) == 1
assert blob.download.saved and blob.listeners == [], (vars(blob.download), blob.listeners)
clip = b"\0\0\0\x18ftypmp42" + bytes(range(256)) * 40
page_link = Editor("blob:https://labs.google/abc", caught="blob:https://labs.google/hd", body=clip)
assert g.save_upscaled(page_link, "p-1", "s-1", hd / "hd3.mp4") == len(clip), vars(page_link)
assert (hd / "hd3.mp4").read_bytes() == clip and page_link.download.saved is None, vars(page_link.download)
g.read_caught(page_link, "blob:https://labs.google/hd", hd / "chunks.part", chunk=1000)
assert (hd / "chunks.part").read_bytes() == clip and page_link.reads == 1 + 11, page_link.reads

import types
launches = []


@contextlib.contextmanager
def fake_browser(account, visible=False):
    launches.append(account)
    yield types.SimpleNamespace(pages=["page"])


crashes = [True]


def flaky(page, project, scene, path):
    if crashes and crashes.pop():
        error = g.drift("the 1080p upscaled download (TargetClosedError: x)")
        error.extra["crashed"] = True
        raise error
    return 11


g.browser, g.save_upscaled = fake_browser, flaky
variant = {"media_id": "m-hd", "bytes": None}
late = [{"variant": variant, "scene": "s-hd", "path": hd / "late.mp4"}]
with contextlib.redirect_stderr(io.StringIO()):
    g.upscale_later("rich", "p-1", late, "fast")
assert launches == ["rich", "rich"] and variant["bytes"] == 11, (launches, variant)
dead = []


def dies_after_crash(page, project, scene, path):
    if len(launches) in dead:
        raise RuntimeError("TargetClosedError: the page died with its Chrome")
    try:
        return flaky(page, project, scene, path)
    except g.Failure:
        dead.append(len(launches))
        raise


crashes[:], launches[:] = [True], []
g.save_upscaled = dies_after_crash
pair = [{"variant": {"media_id": m, "bytes": None}, "scene": m, "path": hd / f"{m}.mp4"} for m in ("m-1", "m-2")]
with contextlib.redirect_stderr(io.StringIO()):
    g.upscale_later("rich", "p-1", pair, "fast")
assert dead == [1] and [u["variant"]["bytes"] for u in pair] == [11, 11] and len(launches) == 2, (dead, pair)
g.save_upscaled = flaky
crashes[:], launches[:] = [True] * 3, []
try:
    with contextlib.redirect_stderr(io.StringIO()):
        g.upscale_later("rich", "p-1", late, "fast")
    raise AssertionError("a Chrome that crashed on every launch passed")
except g.Failure as failure:
    assert "3 launches" in failure.reason and "m-hd --dest" in failure.reason and len(launches) == 2, failure.reason

import fcntl
(g.ROOT / "locks").mkdir(parents=True, exist_ok=True)
with open(g.ROOT / "locks" / "beta.lock", "w") as held:
    fcntl.flock(held, fcntl.LOCK_EX)
    assert g.busy("beta") and not g.busy("alpha") and not g.busy("never-locked")
    assert g.free_first(["beta", "alpha", "gamma"]) == ["alpha", "gamma", "beta"]
assert g.free_first(["beta", "alpha", "gamma"]) == ["beta", "alpha", "gamma"]
EOF
engine_rc() { GEMINI_WEB_DIR="$GW" python3 "$ROOT/share/gemini_web.py" "$@" >"$WORK/engine.out" 2>"$WORK/engine.err"; printf '%s' "$?"; }
assert test "$(engine_rc generate --prompt x --dest "$OUT/x.mp4" --duration 6 --model fast)" = 2
assert test "$(engine_rc generate --prompt x --dest "$OUT/x.mp4" --aspect 4:3)" = 2
assert test "$(engine_rc generate --prompt x --dest "$OUT/x.mp4" --resolution 360p)" = 2
assert test "$(engine_rc generate --prompt x --dest "$OUT/x.mp4" --first-frame "$FRAME" --ref "$FRAME")" = 2
assert test "$(engine_rc generate --prompt x --dest "$OUT/x.mp4" --count 7)" = 2
assert test "$(engine_rc generate --prompt x --dest "$OUT/x.mp4" --extend "$CLIP")" = 2
assert jq -e '.reason | test("not a clip gemini-video saved")' "$WORK/engine.out" >/dev/null
assert test "$(engine_rc generate --prompt x --dest "$OUT/x.mp4" --account nologin)" = 4
assert jq -e '.code == 4 and (.reason | test("geminib web nologin"))' "$WORK/engine.out" >/dev/null
assert grep -q '^BROWSER_FAILURE route=flow account=nologin code=4 shot=- reason=.*geminib web nologin' "$WORK/engine.err"
EMPTY="$WORK/empty-root"
mkdir -p "$EMPTY"
assert test "$(GEMINI_WEB_DIR="$EMPTY" python3 "$ROOT/share/gemini_web.py" generate --prompt x --dest "$OUT/x.mp4" >/dev/null 2>&1; printf '%s' "$?")" = 4

assert jq -e '.video.models | to_entries | all(.value.label and .value.refs_max and (.value.costs | length > 0))' "$MANIFEST" >/dev/null
assert jq -e '.video as $v | $v.durations | all(tostring as $d | $v.model_by_duration[$d] as $m
  | $m != null and $v.models[$m].costs[$v.resolution_default][$d] != null)' "$MANIFEST" >/dev/null
assert jq -e '.video as $v | ([$v.models[].refs_max] | max) == $v.refs_max
  and ([$v.models[].costs | keys[]] | unique) == ($v.resolutions - ($v.upscale | keys) | sort)
  and ($v.upscale | to_entries | all(.value as $r | $v.resolutions | index($r)))
  and ([$v.models[].wire[], $v.extend.wire[]] | all(. as $p | "x" | test($p) or true))
  and ($v.extend.resolutions | all(. as $r | $v.resolutions | index($r)))
  and ($v.extend.sources | all($v.models[.] != null))
  and ($v.counts | index(1))' "$MANIFEST" >/dev/null

echo "PASS: $asserts asserts; manifest gates refused before any spend (frames vs ingredients, refs per model, resolution, edit source length), 1080p as a 720p render plus upscale, manifest-driven model choice, lone --ref as first frame, refs and --edit passed through, the measured footer with wire-pattern freshness, exit 3 kept to credit walls and exit 4 to unsigned profiles, the engine's media readers on real Flow traffic (the new clip from the generation reply, else by prompt and freshness), the generation request's wire key, the engine's plan and costs, pre-browser engine gates, flagged-account detection (a whole failed envelope, never an old tile) and walled-account rotation least recently started first (a new generation stamps it, an extend or dry run never), --extend found through the job ledger (Veo sources only, untouched files, never an extension, pinned to its account and its walls, 720p) with the extend reply read from real traffic, --count variants priced and listed, a charge that differs from the manifest reported, and the manifest's model/duration/resolution/extend coverage"
