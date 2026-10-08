#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# gemini-speech (AI Studio Generate speech): wrapper flags, outputs and exits on a fake engine, then the
# engine's plan, rotation, walls, first-use terms, Run and player read on fakes. Fixture stores only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
export HOME="$WORK/home" TMPDIR="$WORK/tmp" GEMINI_WEB_DIR="$WORK/home/.gemini-web" PYTHONDONTWRITEBYTECODE=1
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl" FAKE_CALLS="$WORK/calls" GEMINI_SPEECH_ENGINE="$WORK/engine"
export VENDOR_CLI_UPDATE_STATE_DIR="$WORK/vendor-cli-update"
mkdir -p "$HOME" "$TMPDIR" "$WORK/out" "$GEMINI_WEB_DIR"
ffmpeg -v error -f lavfi -i 'sine=frequency=220:sample_rate=24000:duration=1' -ac 1 -c:a pcm_s16le "$WORK/take.wav" || exit 1
export FAKE_WAV="$WORK/take.wav"
cat >"$GEMINI_SPEECH_ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_CALLS"
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in --out-dir) out=$2; shift 2 ;; *) shift ;; esac
done
case "${FAKE_ENGINE_MODE:-ok}" in
  limit) printf '{"ok": false, "reason": "AI Studio refused com: quota exceeded"}\n'; exit 3 ;;
  busy) printf '{"ok": false, "reason": "com is busy", "account": "com"}\n'; exit 5 ;;
  login) printf '{"ok": false, "reason": "AI Studio shows com signed out"}\n'; exit 4 ;;
  dry) printf '{"ok": true, "dry_run": true, "account": "com", "controls": {"blocks": 2}}\n'; exit 0 ;;
esac
cp "$FAKE_WAV" "$out/take1.wav"
jq -cn --arg a "$out/take1.wav" '{ok: true, account: "com", takes: [{audio: $a, account: "com",
  model: "gemini-3.8-flash-tts", speakers: ["Speaker 1 - Puck", "Speaker 2 - Kore"]}]}'
EOF
chmod +x "$GEMINI_SPEECH_ENGINE"
: >"$FAKE_CALLS"
: >"$WORK/err"

speech() { bash "$ROOT/bin/gemini-speech" "$@" >"$WORK/stdout" 2>"$WORK/err"; }
expect_rc() {
  local expected=$1 result=0
  shift
  speech "$@" || result=$?
  assert test "$result" -eq "$expected"
}

# Refusals happen before an engine starts.
out="$WORK/out/voice.wav"
printf '   \n' >"$WORK/blank.txt"
expect_rc 2 --text hi
expect_rc 2 --dest relative.wav --text hi
expect_rc 2 --dest "$WORK/out/voice.ogg" --text hi
expect_rc 2 --dest "$out"
expect_rc 2 --dest "$out" --text hi --line 'Puck: hi'
expect_rc 2 --dest "$out" --text hi --text-file "$WORK/blank.txt"
expect_rc 2 --dest "$out" --text-file "$WORK/blank.txt"
expect_rc 2 --dest "$out" --text hi --temperature warm
expect_rc 2 --dest "$out" --text hi --language ru
assert grep -q 'detect the language from the text' "$WORK/err"
assert test ! -s "$FAKE_CALLS"

# --list-voices reads the manifest: 70 voices on the 3.8 models, the 30 older ones elsewhere.
assert speech --list-voices
assert test "$(wc -l <"$WORK/stdout")" -eq 70
assert grep -qE '^Fola	.*\(default\)$' "$WORK/stdout"
assert speech --list-voices --model 2.5-pro
assert test "$(wc -l <"$WORK/stdout")" -eq 30
assert grep -qE '^Zephyr	.*\(default\)$' "$WORK/stdout"
assert test ! -s "$FAKE_CALLS"

# Every flag reaches the engine; the WAV lands at the dest and the footer names voices and account.
printf 'Read from a file.\n' >"$WORK/line.txt"
assert speech --dest "$out" --line 'Puck: Did you lock it?' --line 'Kore (calm): Of course.' --style warm \
  --model flash --temperature 0.7 --filler-words --account com --lock-wait 30
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- '^generate --line Puck: Did you lock it? --line Kore (calm): Of course. --style warm --model flash --temperature 0.7 --account com --lock-wait 30 --filler-words --out-dir ' <<<"$calls"
assert cmp -s "$WORK/take.wav" "$out"
assert grep -qx 'voices=Puck,Kore' "$WORK/stdout"
assert grep -qx 'account=com' "$WORK/stdout"
assert grep -qx 'model=gemini-3.8-flash-tts' "$WORK/stdout"
assert grep -qx 'duration=1.00' "$WORK/stdout"
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -c '[.tool, .kind, .rc, .account, .served, .route]')" = \
  '["gemini-speech","audio",0,"com","gemini-3.8-flash-tts","aistudio"]'
: >"$FAKE_CALLS"
assert speech --dest "$WORK/out/voice.mp3" --text-file "$WORK/line.txt" --model 2.5-flash --scene harbour \
  --context dusk --delivery Whisper --pace 'The Drift' --accent 'British (RP)' --voice Charon
calls=$(tr '\n' ' ' <"$FAKE_CALLS")
assert grep -q -- '^generate --text Read from a file. --voice Charon --model 2.5-flash --scene harbour --context dusk --delivery Whisper --pace The Drift --accent British (RP) --out-dir ' <<<"$calls"
assert test "$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$WORK/out/voice.mp3")" = mp3
assert test -z "$(ls "$TMPDIR")"

# Exits: a limit, a busy account, a sign-in and a dry run.
FAKE_ENGINE_MODE=limit expect_rc 3 --dest "$out" --text hi
assert grep -qx 'GEMINI_USAGE_LIMIT' "$WORK/err"
FAKE_ENGINE_MODE=busy expect_rc 5 --dest "$out" --text hi
assert grep -qx 'ACCOUNT_BUSY account=com' "$WORK/err"
FAKE_ENGINE_MODE=login expect_rc 4 --dest "$out" --text hi
assert grep -q 'signed out' "$WORK/err"
FAKE_ENGINE_MODE=dry expect_rc 0 --dest "$out" --text hi --dry-run
assert grep -qx 'controls={"blocks":2}' "$WORK/stdout"
assert grep -qx -- '--dry-run' "$FAKE_CALLS"
mkdir -p "$WORK/no-ffprobe"
printf '#!/bin/sh\nexit 127\n' >"$WORK/no-ffprobe/ffprobe"
chmod +x "$WORK/no-ffprobe/ffprobe"
PATH="$WORK/no-ffprobe:$PATH" expect_rc 0 --dest "$out" --text hi
assert grep -qx 'duration=0.00' "$WORK/stdout"

# The engine on fakes.
assert python3 - "$ROOT" <<'PY'
import base64, datetime, io, json, os, re, sys, time, types
from zoneinfo import ZoneInfo
sys.path.insert(0, os.path.join(sys.argv[1], "share"))
import gemini_web as gw
import aistudio_speech as s
gw._pool = (set(), set())


def args(**kw):
    base = dict(text=None, line=None, voice=None, style=None, model=None, temperature=None, filler_words=False,
                scene=None, context=None, delivery=None, pace=None, accent=None, out_dir="/x", dry_run=False)
    return types.SimpleNamespace(**{**base, **kw})


def refused(**kw):
    try:
        s.make_plan(args(**kw), warn=lambda text: None)
    except gw.Failure as failure:
        assert failure.code == 2, failure.reason
        return failure.reason
    raise AssertionError(f"accepted {kw}")


plan = s.make_plan(args(text=" Hello. "))
assert (plan["model_id"], plan["family"], plan["turns"]) == \
    ("gemini-3.8-flash-tts", "design", [{"voice": "Fola", "style": "", "text": "Hello."}]), plan
plan = s.make_plan(args(line=["puck: One.", "Puck: Two.", "Kore (dry): Three.", "Puck: Four."], style="warm"))
assert plan["turns"] == [{"voice": "Puck", "style": "warm", "text": "One. Two."},
                         {"voice": "Kore", "style": "dry", "text": "Three."},
                         {"voice": "Puck", "style": "warm", "text": "Four."}], plan["turns"]
assert plan["speakers"] == ["Puck", "Kore"]
assert "at most 2 speakers" in refused(line=["Puck: a", "Kore: b", "Fola: c"])
assert "need one style" in refused(line=["Puck: a", "Puck (dry): b"])
assert "older models take --style" in refused(model="2.5-flash", line=["Puck (dry): a", "Kore: b"])
assert "Gemini 3.8 voice" in refused(model="2.5-pro", text="a", voice="Fola")
assert "unknown voice" in refused(text="a", voice="Nobody")
assert "<tag>" in refused(text="[laughs] a")
assert "[tag]" in refused(model="2.5-flash", text="<laughs> a")
assert "--scene" in refused(text="a", scene="harbour")
assert "two-speaker" in refused(text="a", filler_words=True)
assert "--filler-words" in refused(model="2.5-flash", line=["Puck: a", "Kore: b"], filler_words=True)
assert "Accent" not in refused(model="2.5-flash", text="a", accent="Martian") and \
    "British (RP)" in refused(model="2.5-flash", text="a", accent="Martian")
for bad in (0.33, 2.05, -0.05):
    assert "--temperature" in refused(text="a", temperature=bad)
assert s.make_plan(args(text="a", temperature=0.35))["temperature"] == 0.35
plan = s.make_plan(args(model="gemini-2.5-pro-preview-tts", text="[whispers] a", delivery="whisper", pace="the drift"))
assert (plan["model"], plan["director"]) == ("2.5-pro", {"delivery": "Whisper", "pace": "The Drift"}), plan
notes = []
s.make_plan(args(text="<laughs> <sighs> a"), warn=notes.append)
assert notes == ["tags not in the composer's list (sent as written): laughs"], notes

# Rotation: rest, own walls and a known sign-out keep an account out; least recently started first.
names = ["com", "egbogd", "rawilimo", "walled", "gone"]
gw.bound_accounts = lambda: list(names)
gw.roster = lambda: list(names)
gw.ROOT.mkdir(parents=True, exist_ok=True)
(gw.ROOT / "flow-rest.json").write_text(json.dumps({"accounts": ["rawilimo"], "until": time.time() + 3600}))
(gw.ROOT / s.WALLS).write_text(json.dumps({"walled": time.time() + 3600, "com": time.time() - 5}))
gw.write_meta("gone", aistudio_signed_in=False)
gw.write_meta("egbogd", generation_started_at=1)
gw.write_meta("com", generation_started_at=2)
assert s.rotation() == ["egbogd", "com"], s.rotation()
(gw.ROOT / "flow-rest.json").write_text(json.dumps({"accounts": ["rawilimo"], "until": time.time() - 1}))
assert "rawilimo" in s.rotation()
(gw.ROOT / "flow-rest.json").write_text(json.dumps({"accounts": ["rawilimo"], "until": time.time() + 3600}))
for pinned, word in (("rawilimo", "resting"), ("walled", "walled until")):
    try:
        s.take_accounts(pinned)
        raise AssertionError(pinned)
    except gw.Failure as failure:
        assert failure.code == 3 and word in failure.reason, failure.reason
assert s.take_accounts("gone") == ["gone"]
s.set_wall("egbogd", time.time() + 60)
assert "egbogd" not in s.rotation()
noon = datetime.datetime(2026, 10, 6, 12, 0, tzinfo=ZoneInfo("America/Los_Angeles")).timestamp()
assert s.limit_wall_s("Resource exhausted: quota exceeded", noon) == 12 * 3600
assert s.limit_wall_s("rate limit: requests per minute", noon) == s.MINUTE_WALL_S


class Loc:
    def __init__(self, page, key):
        self.page, self.key, self.first = page, key, self

    def count(self):
        return int(self.page.shown(self.key))

    def is_visible(self):
        return self.page.shown(self.key)

    def is_enabled(self):
        return True

    def is_checked(self):
        return self.key in self.page.checked

    def check(self, timeout=None):
        self.page.checked.add(self.key)

    def filter(self, has_text=None):
        return Loc(self.page, ("dialog", has_text.pattern))

    def inner_text(self, timeout=None):
        return self.page.texts.get(self.key, "")

    def click(self, timeout=None):
        self.page.clicks.append(self.key)
        self.page.on_click(self.key)


class Reply:
    def __init__(self, status, body):
        self.status, self._body = status, body
        self.url = "https://alkalimakersuite-pa.clients6.google.com/$rpc/MakerSuiteService/GenerateContent"
        self.request = types.SimpleNamespace(url=self.url)

    def body(self):
        return self._body.encode()


class FakePage:
    def __init__(self, shown=(), reply=None, swallow=0, finish_after=0, player=(), reply_after=0):
        self.visible, self.checked, self.clicks, self.handlers, self.texts = set(shown), set(), [], {}, {}
        self.reply, self.swallow, self.finish_after, self.player, self.ticks, self.dialogs, self.reply_after = \
            reply, swallow, finish_after, list(player), 0, [], reply_after

    def key(self, role, name):
        return (role, name.pattern if isinstance(name, re.Pattern) else name)

    def shown(self, key):
        return key in self.visible

    def get_by_role(self, role, name=None, exact=False):
        return Loc(self, self.key(role, name))

    def locator(self, selector):
        return Loc(self, ("dialogs", selector))

    def on(self, event, handler):
        self.handlers.setdefault(event, []).append(handler)

    def on_click(self, key):
        if key[1] in ("Continue", "Accept terms of service"):
            self.visible -= {k for k in self.visible if k[0] in ("checkbox", "dialog")}
        if key[1] == r"^Run\b":
            if self.shown(("button", s.STOP.pattern)):
                raise TimeoutError("Run is Stop while generating")
            if self.swallow:
                self.swallow -= 1
                return
            if self.reply_after:
                self.visible.add(("button", s.STOP.pattern))
                return
            self.answer()

    def answer(self):
        self.visible.discard(("button", s.STOP.pattern))
        for handler in self.handlers["response"]:
            handler(self.reply)
        self.visible.add(("button", "Download"))

    def wait_for_timeout(self, ms):
        self.ticks += 1
        if self.ticks == self.reply_after:
            self.answer()
        if self.ticks == self.finish_after:
            for handler in self.handlers["requestfinished"]:
                handler(self.reply.request)
        time.sleep(0.001)

    def evaluate(self, script):
        if script == gw.PAGE_DUMP:
            return {"dialogs": self.dialogs, "toasts": []}
        assert script == s.PLAYER, script
        return self.player.pop(0) if len(self.player) > 1 else self.player[0]


# First-use terms: only the required box is ticked; the welcome dialog takes Continue alone.
terms = ("checkbox", s.TERMS.pattern)
page = FakePage(shown=[terms, ("checkbox", "Get e-mails"), ("button", "Continue")])
assert s.accept_terms(page, "egbogd") is True
assert page.checked == {terms} and page.clicks == [("button", "Continue")], (page.checked, page.clicks)
assert gw.read_meta("egbogd")["aistudio_terms_accepted_at"] > 0
page = FakePage(shown=[("dialog", s.WELCOME.pattern), ("button", "Continue")])
assert s.accept_terms(page, "com") is True and page.checked == set() and page.clicks == [("button", "Continue")]
assert s.accept_terms(FakePage(shown=[("button", "Continue")]), "com") is False
rows = [json.loads(line) for line in open(gw.ROOT / "jobs.jsonl")]
assert [(r["account"], r["form"]) for r in rows if r.get("event") == "terms-accepted"] == \
    [("egbogd", "checkbox"), ("com", "welcome")], rows

# Run: a swallowed first click is pressed again; the wait ends only when the streamed reply has finished.
chunk = base64.b64encode(b"\1\0" * 600).decode()
body = json.dumps([[[None, None, ["audio/l16; rate=24000; channels=1", chunk]]], [[None, None, ["audio/l16; rate=24000", chunk]]]],
                  separators=(",", ":"))
assert s.pcm_bytes(body) == 2400
s.SEND_WAIT_S = 0.05
page = FakePage(reply=Reply(200, body), swallow=1, finish_after=5)
replies = s.Replies(page)
assert s.run_and_wait(page, replies, "com", 5) == 2400
assert page.clicks.count(("button", r"^Run\b")) == 2, page.clicks
page = FakePage(reply=Reply(200, body), finish_after=4)
assert s.run_and_wait(page, s.Replies(page), "com", 5) == 2400 and page.ticks == 4, page.ticks
page = FakePage(reply=Reply(200, body), reply_after=200, finish_after=205)
assert s.run_and_wait(page, s.Replies(page), "com", 5) == 2400
assert page.clicks.count(("button", r"^Run\b")) == 1 and page.ticks == 205, (page.clicks, page.ticks)
page = FakePage(reply=Reply(429, "Resource has been exhausted (e.g. check quota)."), finish_after=1)
try:
    s.run_and_wait(page, s.Replies(page), "com", 5)
    raise AssertionError("429 passed")
except gw.Failure as failure:
    assert failure.code == 3 and failure.extra["wall_s"] > 0, failure.reason
page = FakePage(reply=Reply(200, '[["no audio here"]]'), finish_after=1)
try:
    s.run_and_wait(page, s.Replies(page), "com", 5)
    raise AssertionError("audio-less reply passed")
except gw.Failure as failure:
    assert failure.code == 1 and "without audio" in failure.reason, failure.reason
page = FakePage(swallow=9)
page.reply = Reply(200, body)
try:
    s.run_and_wait(page, s.Replies(page), "com", 5)
    raise AssertionError("unsent Run passed")
except gw.Failure as failure:
    assert "Run sent nothing" in failure.reason, failure.reason

# Director's note items: a slash in a title is escaped for Playwright's /…/ selector; the menu must show the pick.
assert s.title("Promo/Hype").pattern == r"^Promo\/Hype(\s|$)"
assert s.title("Promo/Hype").match("Promo/Hype High energy, punchy consonants") and not s.title("Promo").match("Promo/Hype")
page = FakePage()
page.texts[("button", "Style")] = "discover_tune Promo/Hype arrow_drop_down"
s.pick_menu(page, page, "Style", "Promo/Hype")
assert page.clicks == [("button", "Style"), ("menuitem", r"^Promo\/Hype(\s|$)")], page.clicks
page.texts[("button", "Style")] = "discover_tune Whisper arrow_drop_down"
try:
    s.pick_menu(page, page, "Style", "Promo/Hype")
    raise AssertionError("an unshown pick passed")
except gw.Failure as failure:
    assert "shows 'discover_tune Whisper arrow_drop_down'" in failure.reason, failure.reason

# The player: a WAV cut at the first chunk is not saved; the full one is.
def wav(pcm):
    head = b"RIFF" + (36 + pcm).to_bytes(4, "little") + b"WAVE" + b"\0" * 32
    return "data:audio/wav;base64," + base64.b64encode(head + b"\1" * pcm).decode()


import pathlib, tempfile
dest = pathlib.Path(tempfile.mkdtemp()) / "take1.wav"
page = FakePage(player=[None, wav(100), wav(100), wav(2400)])
assert s.save_wav(page, dest, 2400) == 44 + 2400 and dest.stat().st_size == 2444
try:
    s.save_wav(FakePage(player=[wav(100)]), dest, 2400, wait_s=0.05)
    raise AssertionError("a cut WAV passed")
except gw.Failure as failure:
    assert "holds 144 bytes" in failure.reason, failure.reason
print("engine checks ok")
PY

# The engine's comparison of the page with `.speech` is the footer's caps= line, on a take and on a dry run.
cat >"$WORK/caps-engine" <<'EOF'
#!/usr/bin/env bash
out='' dry=false
while [ "$#" -gt 0 ]; do case "$1" in --out-dir) out=$2; shift 2 ;; --dry-run) dry=true; shift ;; *) shift ;; esac; done
[ "$dry" = false ] || { jq -cn --argjson c "$FAKE_CAPS" '{ok: true, dry_run: true, account: "com", controls: {}, caps: $c}'; exit 0; }
cp "$FAKE_WAV" "$out/take1.wav"
jq -cn --arg a "$out/take1.wav" --argjson c "$FAKE_CAPS" '{ok: true, account: "com", caps: $c,
  takes: [{audio: $a, account: "com", model: "gemini-3.8-flash-tts", speakers: ["Speaker 1 - Fola"]}]}'
EOF
chmod +x "$WORK/caps-engine"
GEMINI_SPEECH_ENGINE="$WORK/caps-engine" FAKE_CAPS='[]' expect_rc 0 --dest "$out" --text hi
assert test "$(tail -n 1 "$WORK/stdout")" = caps=fresh
GEMINI_SPEECH_ENGINE="$WORK/caps-engine" FAKE_CAPS='["models: +gemini-4-flash-tts", "tags: -yawn"]' \
  expect_rc 0 --dest "$out" --text hi --dry-run
assert grep -qx 'caps=stale what=models: +gemini-4-flash-tts; tags: -yawn' "$WORK/stdout"

# The engine compares models, tags, the voice roster and the director's menus with `.speech`; what it cannot
# read is stale too.
assert python3 - "$ROOT" <<'PY'
import os, sys, types
sys.path.insert(0, os.path.join(sys.argv[1], "share"))
import gemini_web as gw
import aistudio_speech as s

c = s.caps()
ids = [m["id"] for m in c["models"].values()]
classic = c["families"]["classic"]


def uses(roster):
    counts = {}
    for name in roster:
        counts[c["voices"][name][3]] = counts.get(c["voices"][name][3], 0) + 1
    return [f"{use} {n}" for use, n in counts.items()]


class Page:
    keyboard = types.SimpleNamespace(press=lambda key: None)

    def get_by_role(self, role, name=None, exact=False):
        return types.SimpleNamespace(first=None)


def check(family, models=ids, tags=None, voices=None):
    s.live_models = models if callable(models) else lambda page, model_id: models
    s.live_tags = lambda page, block: c["families"][family]["tags"] if tags is None else tags
    s.live_voices = lambda page, block, older: voices
    return s.page_caps(Page(), {"family": family, "model_id": ids[0]})


design_voices = {"counts": uses(sorted(c["voices"])), "names": ["Bodi", "Fola", "Achernar"]}
assert check("design", voices=design_voices) == []
tags = [t for t in c["families"]["design"]["tags"] if t != "yawn"] + ["hum"]
drift = check("design", models=[*ids, "gemini-4-flash-tts"], tags=tags,
              voices={"counts": [*design_voices["counts"][1:], "Narrator 3"], "names": ["Bodi", "Nova"]})
first = design_voices["counts"][0]
assert drift == ["models: +gemini-4-flash-tts", "tags: +hum -yawn", f"voice counts: +Narrator 3 -{first}",
                 "voices: +Nova"], drift
older = {"names": list(c["classic_voices"]), **{k: list(v) for k, v in classic["director"].items()}}
assert check("classic", voices=older) == []
drift = check("classic", voices={**older, "names": older["names"][:-1], "accent": [*older["accent"], "Irish"]})
assert drift == [f"voices: -{older['names'][-1]}", "director Accent: +Irish"], drift


def unread(page, model_id):
    raise TimeoutError("no model panel")


assert check("classic", models=unread, voices=None) == ["models: unread", "voices: unread", "director Style: unread",
                                                         "director Pace: unread", "director Accent: unread"]
import caps_checks
rows = [(r["state"], r["what"]) for r in caps_checks.read() if (r["vendor"], r["section"]) == ("gemini", "speech")]
assert [state for state, _ in rows] == ["fresh", "stale", "fresh", "stale", "stale"], rows
assert rows[3] == ("stale", "; ".join(drift)) and rows[0] == ("fresh", ""), rows
assert gw.caps_drift("tags", list("abcdefgh"), []) == ["tags: +a +b +c +d +e +f …2 more"]

# The page's own words: the model panel's id lines and the voice panel's aria snapshot.
assert [x for x in ("gemini-3.8-flash-tts", "gemini-3.1-flash-tts-preview", "gemini-3.5-transcribe", "lyria-3.5",
                    "Gemini 3.8 Flash TTS") if s.TTS_ID.match(x)] == ["gemini-3.8-flash-tts", "gemini-3.1-flash-tts-preview"]
snap = '''- text: Tutor
- button "View all 7"
- button "Bodi": Bodi Quiet and intimate. · Low pitch
- button "Favorite Bodi"
- button "Play voice sample"
- text: Call Center
- button "View all 7"
- button "Fola (Current)": Fola Current Clear and friendly. · Medium pitch'''
assert s.VOICE_COUNT.findall(snap) == [("Tutor", "7"), ("Call Center", "7")]
assert s.VOICE_NAME.findall(snap) == ["Bodi", "Fola"]
PY

printf 'PASS: test_gemini_speech (%s asserts)\n' "$asserts"
