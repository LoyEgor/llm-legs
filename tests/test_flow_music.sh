#!/usr/bin/env bash
# The Flow Music route of gemini-music: wrapper flags and outputs on a fake engine, then the engine's own
# controls, download catch, credit meta, walls, fan-out and failure words on fakes. Fixture stores only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
export HOME="$WORK/home" TMPDIR="$WORK/tmp" GEMINI_WEB_DIR="$WORK/home/.gemini-web" PYTHONDONTWRITEBYTECODE=1
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl" FAKE_CALLS="$WORK/calls"
export FLOW_MUSIC_ENGINE="$WORK/flow-engine" GEMINI_MUSIC_ENGINE="$WORK/app-engine"
mkdir -p "$HOME" "$TMPDIR" "$WORK/media" "$WORK/out" "$GEMINI_WEB_DIR"
M=$WORK/media
ffmpeg -v error -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' -ac 2 -c:a pcm_s16le "$M/take.wav" || exit 1
printf 'ID3fake' >"$M/ref.mp3"
printf 'not audio' >"$M/ref.txt"
export FAKE_WAV="$M/take.wav"
cat >"$FLOW_MUSIC_ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_CALLS"
out='' format=mp3 stems=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) out=$2; shift 2 ;;
    --format) format=$2; shift 2 ;;
    --stems) stems=true; shift ;;
    *) shift ;;
  esac
done
take() { # index account
  cp "$FAKE_WAV" "$out/take$1.$format"
  local stems_json='{}'
  if [ "$stems" = true ]; then
    for stem in drums vocals; do cp "$FAKE_WAV" "$out/take$1-$stem.$format"; done
    stems_json=$(jq -cn --arg d "$out/take$1-drums.$format" --arg v "$out/take$1-vocals.$format" '{drums: $d, vocals: $v}')
  fi
  jq -cn --arg a "$out/take$1.$format" --arg acct "$2" --argjson s "$stems_json" --arg n "$1" \
    '{audio: $a, stems: $s, account: $acct, url: "https://www.flowmusic.app/session/s\($n)", model: "lyria-3-pro",
      charged: 5, stems_charged: 0, credits: 10520, notes: "Model: lyria-3-pro (Lyria 3 Pro)\nTitle: t-\($n)"}'
}
case "${FAKE_ENGINE_MODE:-ok}" in
  limit) printf '{"ok": false, "reason": "flowacct is out of Flow Music credits"}\n'; exit 3 ;;
  login) printf '{"ok": false, "reason": "Flow Music shows flowacct signed out; the owner signs in once at flowmusic.app"}\n'; exit 4 ;;
  crash) printf 'BROWSER_FAILURE route=flow-music account=flowacct code=1 shot=- reason=Flow Music UI drift: no compose panel\n' >&2
    printf '{"ok": false, "reason": "Flow Music UI drift: no compose panel (Toggle compose panel)"}\n'; exit 1 ;;
  dry) printf '{"ok": true, "dry_run": true, "account": "flowacct", "controls": {"model": "Lyria 3 Pro", "length": "1:15"}}\n'; exit 0 ;;
  fan) jq -cn --argjson a "$(take 1 flowacct)" --argjson b "$(take 2 otheracct)" \
    '{ok: true, account: "flowacct", takes: [$a, $b], short: "2 of 3 accounts delivered; thirdacct: flowacct is out of Flow Music credits"}'; exit 0 ;;
esac
jq -cn --argjson a "$(take 1 flowacct)" '{ok: true, account: "flowacct", takes: [$a]}'
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >>"$FAKE_CALLS"\nprintf "{\\"ok\\": false, \\"reason\\": \\"app\\"}\\n"; exit 1\n' >"$GEMINI_MUSIC_ENGINE"
chmod +x "$FLOW_MUSIC_ENGINE" "$GEMINI_MUSIC_ENGINE"
: >"$FAKE_CALLS"
: >"$WORK/err"

music() { bash "$ROOT/bin/gemini-music" "$@" >"$WORK/stdout" 2>"$WORK/err"; }
expect_rc() {
  local expected=$1 result=0
  shift
  music "$@" || result=$?
  assert test "$result" -eq "$expected"
}

# Flag matrix: every refusal happens before an engine starts.
out="$WORK/out/song.wav"
for flags in "--format wav" "--lyrics la" "--bpm 90" "--seed 3" "--stems" "--ref-audio $M/ref.mp3" "--accounts 2" \
  "--route app --model lyria-3-pro" "--model lyria-9" "--route web"; do
  # shellcheck disable=SC2086
  expect_rc 2 --dest "$out" --prompt 'a theme' $flags
done
expect_rc 2 --dest "$out" --prompt 'a theme' --duration 75
assert grep -q -- '--length short.*--route flow takes --duration' "$WORK/err"
expect_rc 2 --dest "$out" --prompt 'a theme' --stems
assert grep -q -- '--stems runs on --route flow (Google Flow Music)' "$WORK/err"
for flags in "--route flow --dest $WORK/out/song.mp4" "--route flow --dest $out --format mp3" \
  "--route flow --dest $out --duration 30" "--route flow --dest $out --duration 181" "--route flow --dest $out --duration 1:30" \
  "--route flow --dest $out --duration 90 --length short" "--route flow --dest $out --lyrics la --instrumental" \
  "--route flow --dest $out --bpm fast" "--route flow --dest $out --ref-audio relative.mp3" \
  "--route flow --dest $out --ref-audio $M/missing.mp3" "--route flow --dest $out --ref-audio $M/ref.txt" \
  "--route flow --dest $out --ref-image $M/ref.mp3" "--route flow --dest $out --accounts 5" \
  "--route flow --dest $out --accounts 0" "--route flow --dest $out --accounts 2 --account com"; do
  # shellcheck disable=SC2086
  expect_rc 2 --prompt 'a theme' $flags
done
assert test ! -s "$FAKE_CALLS"
music --dest "$out" --prompt x --bogus || true
for flag in --route --model --format --duration --lyrics --bpm --seed --ref-audio --stems --accounts; do
  assert grep -q -- "$flag" "$WORK/err"
done

# lyria-3-pro picks the flow route; every flag reaches the flow engine and its outputs land next to the dest.
assert music --dest "$out" --prompt 'a lo-fi beat' --model lyria-3-pro --duration 75 --lyrics 'la la' --bpm 84 --seed 7 \
  --genre Lo-fi --vocals --ref-audio "$M/ref.mp3" --stems
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- '--format wav --title song --accounts 1 --model lyria-3-pro --duration 75 --lyrics la la --bpm 84 --seed 7' <<<"$calls"
assert grep -q -- "--ref-audio $M/ref.mp3 --stems" <<<"$calls"
assert grep -q -- '--vocals on --genre Lo-fi' <<<"$calls"
assert cmp -s "$M/take.wav" "$out"
assert cmp -s "$M/take.wav" "$WORK/out/song-drums.wav"
assert grep -qx "stem=$WORK/out/song-drums.wav" "$WORK/stdout"
assert grep -qx "stem=$WORK/out/song-vocals.wav" "$WORK/stdout"
assert grep -qx 'Title: t-1' "$out.txt"
assert grep -qx 'model=lyria-3-pro' "$WORK/stdout"
assert grep -qx 'format=wav' "$WORK/stdout"
assert grep -qx 'credits=5 charged from the Flow Music pool; left: flowacct 10520' "$WORK/stdout"
assert test -z "$(ls "$TMPDIR")"
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -c '[.tool, .kind, .rc, .account, .served]')" = \
  '["gemini-music","audio",0,"flowacct","lyria-3-pro"]'

# Fan-out: every take is a numbered file, a short run still exits 0 and names what failed.
: >"$FAKE_CALLS"
FAKE_ENGINE_MODE=fan assert music --route flow --dest "$WORK/out/fan.m4a" --prompt 'a pad' --accounts 3
assert grep -qx -- '--accounts' "$FAKE_CALLS"
assert grep -qx -- '3' "$FAKE_CALLS"
assert test -s "$WORK/out/fan.m4a"
assert test -s "$WORK/out/fan-2.m4a"
assert grep -q "^variant=$WORK/out/fan-2.m4a duration=[0-9.]* chat=https://www.flowmusic.app/session/s2 account=otheracct$" "$WORK/stdout"
assert grep -q '^short=2 of 3 accounts delivered; thirdacct: ' "$WORK/stdout"
assert grep -q 'credits=10 charged from the Flow Music pool; left: flowacct 10520, otheracct 10520' "$WORK/stdout"
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -r '.size')" = 3

# Failure shapes are the app route's.
FAKE_ENGINE_MODE=limit expect_rc 3 --route flow --dest "$out" --prompt 'a theme'
assert grep -qx 'GEMINI_USAGE_LIMIT' "$WORK/err"
FAKE_ENGINE_MODE=login expect_rc 4 --route flow --dest "$out" --prompt 'a theme'
assert grep -q 'signed out' "$WORK/err"
FAKE_ENGINE_MODE=crash expect_rc 1 --route flow --dest "$out" --prompt 'a theme'
assert grep -qx 'BROWSER_FAILURE route=flow-music account=flowacct code=1 shot=- reason=Flow Music UI drift: no compose panel' "$WORK/err"
FAKE_ENGINE_MODE=dry assert music --route flow --dest "$out" --prompt 'a theme' --dry-run
assert grep -qx 'controls={"model":"Lyria 3 Pro","length":"1:15"}' "$WORK/stdout"

# The engine on fakes.
cat >"$WORK/child" <<'EOF'
#!/usr/bin/env python3
import json, sys
argv = sys.argv[1:]
account = argv[argv.index("--account") + 1]
open(sys.argv[0] + ".calls", "a").write(" ".join(argv) + "\n")
code = {"good": 0, "dry": 0, "poor": 3, "gone": 4, "flaky": 1}[account]
if code:
    print(json.dumps({"ok": False, "reason": f"{account} failed with {code}"}))
elif "--dry-run" in argv:
    print(json.dumps({"ok": True, "dry_run": True, "account": account, "controls": {"model": "Lyria 3.5"}}))
else:
    print(json.dumps({"ok": True, "account": account, "takes": [{"audio": "/x.mp3", "account": account}]}))
sys.exit(code)
EOF
chmod +x "$WORK/child"
export FLOW_MUSIC_CHILD="$WORK/child"
assert python3 - "$ROOT" "$WORK" <<'PY'
import base64, contextlib, importlib.machinery, importlib.util, io, json, os, re, subprocess, sys, time
root, work = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "share"))
import gemini_web as gw
import flow_music as fm
gw._pool = (set(), set())
loader = importlib.machinery.SourceFileLoader("doctor", os.path.join(root, "bin", "llm-doctor"))
spec = importlib.util.spec_from_loader("doctor", loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)


class Loc:
    def __init__(self, page, key):
        self.page, self.key, self.first = page, key, self

    def nth(self, index):
        return self

    def count(self):
        return int(self.page.exists(self.key))

    def is_visible(self, timeout=None):
        return self.page.exists(self.key)

    def is_enabled(self):
        return True

    def wait_for(self, timeout=None):
        if not self.page.exists(self.key):
            raise TimeoutError(str(self.key))

    def element_handle(self, timeout=None):
        return self

    def locator(self, selector):
        return Loc(self.page, ("field", self.key[1]))

    def get_attribute(self, name, timeout=None):
        assert name == "aria-checked", name
        return "true" if self.page.switches[self.key[2]] else "false"

    def click(self, timeout=None):
        self.page.act("click", self.key)

    def hover(self):
        self.page.act("hover", self.key)

    def focus(self, timeout=None):
        self.page.focused = self.key

    def fill(self, value, timeout=None):
        self.page.values[self.name()] = value

    def press_sequentially(self, value):
        self.page.values[self.name()] += value

    type = press_sequentially

    def press(self, key):
        self.page.act("press " + key, self.key)

    def input_value(self):
        return self.page.values.get(self.name(), "")

    def inner_text(self, timeout=None):
        return self.page.model if self.key[1] == "button" else ""

    def name(self):
        return self.key[1] if self.key[0] == "field" else str(self.key[2])


class Keyboard:
    def __init__(self, page):
        self.page = page

    def press(self, key):
        self.page.act("key " + key, self.page.focused)


class Page:
    url = "https://www.flowmusic.app/session"

    def __init__(self):
        self.log, self.values, self.focused, self.model, self.panel = [], {}, None, "Lyria 3.5", False
        self.switches = {"Toggle instrumental mode": False, "Toggle advanced sound mode": False}
        self.keyboard, self.listeners, self.evaluated, self.caught, self.mode = Keyboard(self), {}, [], None, "blob"
        self.blob = b"RIFF" + b"\0" * 9000

    def get_by_role(self, role, name=None, exact=False):
        name = name.pattern if isinstance(name, re.Pattern) else name
        return Loc(self, ("role", role, name))

    def get_by_text(self, text, exact=False):
        return Loc(self, ("text", text))

    def exists(self, key):
        if key[:2] == ("role", "textbox") and key[2] == "Sound description":
            return self.panel
        if key[:2] == ("role", "menuitem") and key[2] in ("WAV", "MP3", "M4A"):
            return ("hover", ("role", "menuitem", "Download")) in self.log
        return key != ("role", "button", "Expand Details section") or not self.panel_details

    panel_details = False

    def act(self, what, key):
        self.log.append((what, key))
        if what == "click" and key == ("role", "button", "Toggle compose panel"):
            self.panel = True
        elif what == "click" and key[1] == "switch":
            self.switches[key[2]] = not self.switches[key[2]]
        elif what == "click" and key == ("role", "button", "Expand Details section"):
            self.panel_details = True
        elif what == "click" and key[:2] == ("role", "menuitem") and key[2].startswith("^Lyria\\ 3\\ Pro"):
            self.model = "Lyria 3 Pro"
        elif what == "key Enter" and key[:2] == ("role", "menuitem") and key[2] in ("WAV", "MP3", "M4A"):
            if self.mode == "blob":
                self.caught = "blob:https://www.flowmusic.app/1"
            elif self.mode == "http":
                self.listeners["download"](Download("https://storage.example/clip.wav"))

    def wait_for_timeout(self, ms):
        pass

    def on(self, event, handler):
        self.listeners[event] = handler

    def remove_listener(self, event, handler):
        self.listeners.pop(event, None)

    def evaluate(self, script, arg=None):
        self.evaluated.append(script)
        if script == gw.CAUGHT:
            return self.caught
        if script == gw.READ_CHUNK:
            url, start, size = arg
            return [len(self.blob), base64.b64encode(self.blob[start:start + size]).decode()]
        return None

    @property
    def context(self):
        return self

    @property
    def request(self):
        return self

    def get(self, url, timeout=None):
        return Response(self.blob)


class Download:
    def __init__(self, url):
        self.url = url

    def cancel(self):
        pass


class Response:
    status = 200

    def __init__(self, body):
        self._body = body

    def body(self):
        return self._body


# Controls: every field is set and read back, the model through its menu, the panel opened first.
page = Page()
page.values = {"Lyrics": "old words", "BPM": "120", "Length": "", "Seed": "9", "Sound description": ""}
plan = {"lyrics": "", "instrumental": True, "sound": "Jazz. a lo-fi beat", "bpm": "84", "length": "1:15", "seed": "",
        "model_label": "Lyria 3 Pro", "title": "song-ab12"}
controls = fm.compose(page, plan)
assert controls == {"model": "Lyria 3 Pro", "instrumental": True, "length": "1:15", "bpm": "84", "seed": "Auto",
                    "title": "song-ab12"}, controls
assert page.values["Lyrics"] == "" and page.values["Sound description"] == "Jazz. a lo-fi beat", page.values
assert page.switches == {"Toggle instrumental mode": True, "Toggle advanced sound mode": True}, page.switches
assert page.log[0] == ("click", ("role", "button", "Toggle compose panel")), page.log[0]
assert ("click", ("role", "menuitem", "^Lyria\\ 3\\ Pro ")) in page.log
broken = Page()
broken.values = dict(page.values, Length="")
broken.panel = True
broken.switches["Toggle advanced sound mode"] = True
original = Loc.press_sequentially
Loc.press_sequentially = lambda self, value: None
Loc.type = Loc.press_sequentially
try:
    fm.compose(broken, plan)
    raise AssertionError("a Length that did not take must fail")
except gw.Failure as failure:
    assert failure.reason.startswith("Flow Music UI drift: the Length field shows ''"), failure.reason
finally:
    Loc.press_sequentially = Loc.type = original
plan_args = fm.make_plan(type("A", (), dict(duration=75, length=None, genre="Jazz", prompt="a beat", lyrics=None,
                                            vocals="instrumental", bpm=None, seed=3, model="lyria-3-pro", format="wav",
                                            stems=True, ref_audio=None, count=1, out_dir="/o", dry_run=False,
                                            title="My Song!.v2"))())
assert (plan_args["length"], plan_args["sound"], plan_args["seed"], plan_args["model_label"], plan_args["title"],
        plan_args["price"]) == ("1:15", "Jazz. a beat", "3", "Lyria 3 Pro", "My-Song-v2", 5), plan_args

# Download: the page's blob link is caught and read out of the page, never saved through Chrome.
dest = os.path.join(work, "caught.wav")
page = Page()
size = fm.download(page, "song-ab12", "wav", fm.Path(dest))
assert size == len(page.blob) and open(dest, "rb").read() == page.blob, size
assert page.evaluated[0] == gw.CATCH_DOWNLOAD and gw.READ_CHUNK in page.evaluated
assert ("click", ("role", "button", "More options for song-ab12")) in page.log
page = Page()
page.mode = "http"
assert fm.download(page, "song-ab12", "wav", fm.Path(dest)) == len(page.blob)
page = Page()
page.blob = b"<html>expired</html>"
try:
    fm.download(page, "song-ab12", "wav", fm.Path(dest + "2"))
    raise AssertionError("a non-wav download must fail")
except gw.Failure as failure:
    assert failure.reason == "the wav download of song-ab12 is not a wav file", failure.reason
assert not os.path.exists(dest + "2") and not os.path.exists(os.path.join(work, ".caught.wav2.part"))

# Credit meta, walls and the rotation built from them.
for name in ("good", "poor", "gone", "walled", "flagged", "fresh", "dry"):
    os.makedirs(os.path.join(gw.ROOT, "profiles", name, "Default"), exist_ok=True)
    open(os.path.join(gw.ROOT, "profiles", name, "Default", "Cookies"), "w").close()
    gw.write_meta(name, email=name + "@example.com")
now = int(time.time())
fm.note_balance("good", 10520)
assert {k: v for k, v in gw.read_meta("good").items() if k.startswith("music")} == \
    {"music_signed_in": True, "music_credits": 10520, "music_credits_at": gw.read_meta("good")["music_credits_at"]}
assert gw.read_meta("good")["music_credits_at"] >= now and "credits" not in gw.read_meta("good")
fm.note_balance("good", None)
assert gw.read_meta("good")["music_credits"] == 10520
gw.write_meta("poor", music_credits=3, music_credits_at=now)
gw.write_meta("gone", music_signed_in=False)
gw.write_meta("dry", music_credits=2, music_credits_at=now - gw.WALL_SECONDS - 60)
fm.set_wall("walled", now + 3600)
gw.set_wall("flagged", now + 3600)
gw.ledger({"kind": "flow-music", "event": "saved", "account": "good"})
gw.write_meta("fresh", music_credits=900, music_credits_at=now)
assert fm.rotation(5) == ["dry", "fresh", "good"], fm.rotation(5)

# The single-account run walls an account out of credits and moves on; a named account is never walled.
calls = []


def fake_generate(account, plan):
    calls.append(account)
    if account == "dry":
        raise gw.Failure(3, "dry holds 0 Flow Music credits, under the 5 a song costs", account=account)
    return {"ok": True, "account": account, "takes": [{"audio": "/a.mp3", "account": account}]}


fm.generate_on = fake_generate
args = type("A", (), dict(prompt="p", out_dir=work, model="lyria-3.5", format="mp3", lyrics=None, vocals=None,
                          genre=None, duration=None, length=None, bpm=None, seed=None, ref_audio=None, stems=False,
                          title="t", count=1, accounts=1, account=None, fanned=False, dry_run=False))()
out = io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
    fm.cmd_generate(args)
assert json.loads(out.getvalue())["takes"][0]["account"] == "fresh" and calls == ["dry", "fresh"], (out.getvalue(), calls)
assert fm.walls().get("dry", 0) > now + gw.WALL_SECONDS - 60, fm.walls()
args.account = "dry"
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    try:
        fm.set_wall("dry", 0)
        fm.cmd_generate(args)
    except SystemExit as stop:
        assert stop.code == 3, stop.code
assert fm.walls()["dry"] == 0, fm.walls()

# Fan-out: one process per account, all takes kept, exit 0 while any account delivered.
engine = os.path.join(root, "share", "flow_music.py")
env = dict(os.environ)


def fan(*accounts, extra=()):
    for name in os.listdir(gw.ROOT):
        if name == fm.WALLS:
            os.unlink(os.path.join(gw.ROOT, name))
    for name in ("good", "poor", "gone", "walled", "flagged", "fresh", "dry", "flaky"):
        gw.write_meta(name, music_signed_in=name in accounts, music_credits=100, music_credits_at=int(time.time()))
    run = subprocess.run([sys.executable, engine, "generate", "--prompt", "p", "--out-dir", os.path.join(work, "fan"),
                          "--title", "fan", "--accounts", str(len(accounts)), *extra],
                         capture_output=True, text=True, env=env, timeout=60)
    return run.returncode, json.loads(run.stdout.strip().splitlines()[-1])


for name in ("flaky",):
    os.makedirs(os.path.join(gw.ROOT, "profiles", name, "Default"), exist_ok=True)
    open(os.path.join(gw.ROOT, "profiles", name, "Default", "Cookies"), "w").close()
    gw.write_meta(name, email=name + "@example.com")
open(os.path.join(work, "child.calls"), "w").close()
code, result = fan("good", "poor")
assert code == 0 and result["ok"] and [t["account"] for t in result["takes"]] == ["good"], (code, result)
assert result["short"] == "1 of 2 accounts delivered; poor: poor failed with 3", result
child_calls = open(os.path.join(work, "child.calls")).read().splitlines()
assert len(child_calls) == 2 and all("--fanned" in c and "--title fan" in c for c in child_calls), child_calls
assert {c.split("--account ")[1].split()[0] for c in child_calls} == {"good", "poor"}, child_calls
code, result = fan("poor", "gone")
assert code == 3 and not result["ok"] and "poor: poor failed with 3" in result["reason"], (code, result)
code, result = fan("gone", "flaky")
assert code == 1, (code, result)
code, result = fan("good", "dry", extra=("--dry-run",))
assert code == 0 and result["dry_run"] and len(result["runs"]) == 2, (code, result)

# The wait after Generate: a second Generate when no song shows within START_S, a fast failure after it, and only
# our own job's stream counts as sent.
class Reply:
    status = 200

    def __init__(self, path, body=None):
        self.url, self.body = fm.SITE + path, body or {}

    def json(self):
        return self.body


class WaitPage:
    url = "https://www.flowmusic.app/session/w"

    def __init__(self, on_generate=()):
        self.clock, self.clicks, self.on_generate, self.handler = 1000.0, 0, list(on_generate), None

    def on(self, event, handler):
        self.handler = handler

    def locator(self, selector):
        return self

    def count(self):
        return 0

    def get_by_text(self, text, exact=False):
        return self

    def get_by_role(self, role, name=None, exact=False):
        assert (role, name) == ("button", "Generate"), (role, name)
        return self

    def click(self, timeout=None):
        self.clicks += 1
        for reply in (self.on_generate.pop(0) if self.on_generate else []):
            self.handler(reply)

    def wait_for_timeout(self, ms):
        self.clock += ms / 1000


song_clip = {"c1": {"id": "c1", "title": "w-1", "audio_url": "https://x/c1",
                    "duration": {"status": "completed", "value": "61.5"}}}
wait_plan = {"ref_audio": None, "timeout_s": 600}
library_calls = []
saved = (fm.time, fm.library_row)
fm.library_row = lambda page, traffic, account, title: library_calls.append(page.clock) or None


def use_clock(page):
    fm.time = type("Clock", (), {"time": staticmethod(lambda: page.clock)})


def wait(page):
    use_clock(page)
    traffic = fm.Traffic(page)
    fm.send(page, traffic, wait_plan)
    return traffic, fm.wait_song(page, traffic, "com", wait_plan, "w-1", page.clock)


try:
    tool_call = Reply("/__api/producer/tool-call", {"job_id": "j1"})
    retry_page = WaitPage([[tool_call], [Reply("/__api/producer/tool-call", {"job_id": "j2"}),
                                         Reply("/__api/clips", {"clips": song_clip})]])
    traffic, song = wait(retry_page)
    assert song == {"id": "c1", "seconds": 61.5} and retry_page.clicks == 2 and not library_calls, (song, retry_page.clicks)
    assert 1090 < retry_page.clock < 1100 and traffic.jobs == {"j1", "j2"}, (retry_page.clock, traffic.jobs)
    rows = [json.loads(line) for line in open(gw.ROOT / "jobs.jsonl")]
    assert [r["event"] for r in rows if r.get("kind") == "flow-music" and r.get("title") == "w-1"] == ["regenerate"], rows

    dead_page = WaitPage([[tool_call], [tool_call]])
    try:
        wait(dead_page)
        raise AssertionError("a Generate that starts no song must fail fast")
    except gw.Failure as failure:
        assert failure.reason.startswith("no track started on com: Flow Music made no song within 90s"), failure.reason
        assert doctor.classify_browser(1, failure.reason)[1:4:2] == ("browser no output", "ours"), \
            doctor.classify_browser(1, failure.reason)
    assert dead_page.clicks == 2 and 1180 < dead_page.clock < 1190 and library_calls == [dead_page.clock], \
        (dead_page.clicks, dead_page.clock, library_calls)

    stray_page = WaitPage([[Reply("/__api/messages/old-job/stream")]])
    use_clock(stray_page)
    traffic = fm.Traffic(stray_page)
    traffic.pending.append(Reply("/__api/messages/j1/stream"))
    fm.send(stray_page, traffic, wait_plan)
    traffic.poll()
    assert not traffic.sent and stray_page.clicks == 1, traffic.sent
    try:
        fm.wait_song(stray_page, traffic, "com", wait_plan, "w-1", stray_page.clock)
        raise AssertionError("another job's stream must not count as sent")
    except gw.Failure as failure:
        assert failure.reason.startswith("the prompt was never sent on com"), failure.reason
    traffic.pending += [Reply("/__api/producer/tool-call", {"job_id": "j9"}), Reply("/__api/messages/j9/stream")]
    traffic.poll()
    assert traffic.sent and traffic.jobs == {"j9"}, traffic.jobs
    chat = fm.Traffic(WaitPage())
    chat.arm(chat=True)
    chat.pending.append(Reply("/__api/messages/m1/stream"))
    chat.poll()
    assert chat.sent, "the reference-audio chat has no tool call; its stream is the send"
finally:
    fm.time, fm.library_row = saved


# The reference upload: the newest chooser gets the file, upload-check-status decides, and a dropped chip is a refusal.
class Chooser:
    def __init__(self):
        self.files = None

    def set_files(self, files):
        self.files = files


class UploadPage(WaitPage):
    def __init__(self, keep_chip, toasts=(), flags=None):
        super().__init__()
        self.keep_chip, self.toasts, self.flags, self.choosers, self.set_at = keep_chip, list(toasts), flags or {}, [], None
        self.handlers = {}

    def on(self, event, handler):
        self.handlers[event] = handler

    def get_by_role(self, role, name=None, exact=False):
        self.asked = (role, name)
        return self

    @property
    def first(self):
        return self

    def click(self, timeout=None):
        if self.asked[0] == "menuitem":
            for _ in range(2):
                self.choosers.append(Chooser())
                self.handlers["filechooser"](self.choosers[-1])

    def count(self):
        if getattr(self, "asked", None) == ("button", "Remove ref.mp3"):
            done = self.set_at is not None and self.clock - self.set_at > 3
            return int(self.keep_chip or not done)
        return 0

    def evaluate(self, script, arg=None):
        assert script == gw.PAGE_DUMP, script
        return {"toasts": self.toasts if self.clock - self.set_at > 3 else []}

    def wait_for_timeout(self, ms):
        super().wait_for_timeout(ms)
        if self.set_at is None and any(c.files for c in self.choosers):
            self.set_at = self.clock
        if self.set_at is not None:
            done = self.clock - self.set_at > 3
            body = {"status": "complete", **self.flags} if done else {"status": "pending"}
            self.handlers["response"](Reply("/__api/producer/upload-audio/u1/upload-check-status", body))


ref = fm.Path(work) / "ref.mp3"
try:
    good = UploadPage(keep_chip=True)
    use_clock(good)
    fm.attach_audio(good, fm.Traffic(good), "com", ref, 30)
    assert [c.files for c in good.choosers] == [None, str(ref)] and good.clock - good.set_at < 6, \
        ([c.files for c in good.choosers], good.clock)
    vocal = "This track contains vocals. Uploading tracks with vocals is not available in your region."
    for page, said in ((UploadPage(False, ["Notification Error" + vocal]), vocal),
                       (UploadPage(False, flags={"has_vocals": True, "has_cid_match": False}), "has_vocals")):
        use_clock(page)
        try:
            fm.attach_audio(page, fm.Traffic(page), "com", ref, 30)
            raise AssertionError("a dropped chip must fail the upload")
        except gw.Failure as failure:
            assert failure.reason == "Flow Music refused the reference audio upload: " + said, failure.reason
            assert doctor.classify_browser(1, failure.reason)[1] == "browser upload", doctor.classify_browser(1, failure.reason)
        assert page.clock - page.set_at < 6, page.clock
finally:
    fm.time = saved[0]

# Every failure the route raises lands on a named llm-doctor word.
words = {"Flow Music UI drift: no compose panel (Toggle compose panel)": "browser drift",
         "Flow Music did not load within 45s (https://www.flowmusic.app/session)": "browser drift",
         "no track after 600s on com (https://www.flowmusic.app/session/x)": "browser no output",
         "Flow Music returned no track on com: GENERATION_FAILED: blocked": "browser no output",
         "the prompt was never sent on com: no generation call within 60s": "browser not sent",
         "no wav download of song-ab12 within 180s": "browser download",
         "the wav download of song-ab12 is not a wav file": "browser download",
         "the reference audio upload did not finish within 300s": "browser upload",
         "the stem split returned no take on com within 600s": "browser no output",
         "com: Flow Music UI drift: the library lists no song 'x'; egbogd: no track after 600s": "browser no output"}
for reason, word in words.items():
    assert doctor.classify_browser(1, reason)[1] == word, (reason, doctor.classify_browser(1, reason))
assert doctor.classify_browser(3, "com is out of Flow Music credits")[0] == "walled"
assert doctor.classify_browser(4, "Flow Music shows com signed out; the owner signs in once")[1] == doctor.BROWSER_OWNER_STEP
print("engine checks ok")


class Shown:
    def __init__(self, page, key):
        self.page, self.key, self.first = page, key, self

    def count(self):
        return int(self.key in self.page.shown)

    def is_visible(self, timeout=None):
        return self.key in self.page.shown

    def click(self, timeout=None):
        self.page.clicked.append(self.key)


class NoticePage:
    def __init__(self, *shown):
        self.shown, self.clicked = set(shown), []

    def get_by_role(self, role, name=None, exact=False):
        return Shown(self, (role, name))

    def get_by_text(self, text, exact=False):
        return Shown(self, ("text", text))

    def locator(self, selector):
        raise AssertionError("the upload notice has no dialog container to look in")


consent = ("button", "I agree"), ("text", "necessary rights")
(gw.ROOT / fm.NOTICES).write_text(json.dumps({fm.NOTICE_KEY: ["com"]}))
assert fm.answer_notice(NoticePage(), "com") is False
assert fm.answer_notice(NoticePage(consent[0]), "com") is False
agreed = NoticePage(*consent)
assert fm.answer_notice(agreed, "com") is True and agreed.clicked == [("button", "I agree")], agreed.clicked
stranger = NoticePage(*consent)
try:
    fm.answer_notice(stranger, "abel")
    raise AssertionError("an account without the owner's yes agreed to the upload notice")
except gw.Failure as failure:
    assert failure.code == 4 and "agreed_flow_music" in failure.reason and not stranger.clicked, failure.reason
PY

printf 'PASS: test_flow_music (%s asserts)\n' "$asserts"
