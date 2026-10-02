#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
refute() { asserts=$((asserts + 1)); ! "$@" || fail "refute $asserts: $*"; }
export HOME="$WORK/home" TMPDIR="$WORK/tmp" GEMINI_WEB_DIR="$WORK/gemini-web"
export FAKE_ENGINE_CALLS="$WORK/calls" GEMINI_MUSIC_ENGINE="$WORK/engine"
mkdir -p "$HOME" "$TMPDIR" "$WORK/media" "$WORK/out"
mkdir -p "$HOME/.gemini-profiles"/{alpha,beta,gamma,delta}
M=$WORK/media
ffmpeg -v error -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=3' -ac 2 -c:a libmp3lame -b:a 192k "$M/take.mp3" || exit 1
ffmpeg -v error -f lavfi -i color=c=black:size=64x64:rate=1 -i "$M/take.mp3" -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac "$M/take.mp4" || exit 1
ffmpeg -v error -f lavfi -i testsrc2=size=64x48 -frames:v 1 "$M/cover.png" || exit 1
cp "$M/take.mp4" "$M/scene.mp4"
printf 'GIF89a' >"$M/cover.gif"
export FAKE_TAKE_MP3="$M/take.mp3" FAKE_TAKE_MP4="$M/take.mp4"
cat >"$GEMINI_MUSIC_ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_ENGINE_CALLS"
out='' count=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) out=$2; shift 2 ;;
    --count) count=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "${FAKE_ENGINE_MODE:-ok}" in
  limit) printf '{"ok": false, "reason": "fakeacct is out of Gemini music generations: limit reached"}\n'; exit 3 ;;
  login) printf '{"ok": false, "reason": "Google signed fakeacct out; run: geminib web fakeacct"}\n'; exit 4 ;;
  usage) printf '{"ok": false, "reason": "bad plan"}\n'; exit 2 ;;
  crash) printf 'noise\nBROWSER_FAILURE route=gemini-app account=fakeacct code=1 shot=- reason=Gemini app UI drift: no Length chip\n' >&2
    printf '{"ok": false, "reason": "Gemini app UI drift: no Length chip in the music composer"}\n'; exit 1 ;;
  garbage) printf 'Traceback: boom\n' >&2; exit 1 ;;
  dry) printf '{"ok": true, "dry_run": true, "account": "fakeacct", "chips": [["Length", "Short"]]}\n'; exit 0 ;;
  short) cp "$FAKE_TAKE_MP3" "$out/take1.mp3"; cp "$FAKE_TAKE_MP3" "$out/take2.mp3"
    jq -cn --arg a "$out/take1.mp3" --arg b "$out/take2.mp3" '{ok: true, account: "fakeacct", short: "2 of 3 takes; the next one failed: limit",
      takes: [{audio: $a, account: "fakeacct", url: "u1", description: "", text: ""},
              {audio: $b, account: "other", url: "u2", description: "", text: ""}]}'; exit 0 ;;
esac
takes='[]'
for take in $(seq 1 "$count"); do
  cp "$FAKE_TAKE_MP3" "$out/take$take.mp3"
  video=null
  [ "${FAKE_ENGINE_MODE:-ok}" = novideo ] || { cp "$FAKE_TAKE_MP4" "$out/take$take.mp4"; video="\"$out/take$take.mp4\""; }
  takes=$(jq -c --arg a "$out/take$take.mp3" --argjson v "$video" --arg n "$take" \
    '. + [{audio: $a, video: $v, chat: "c_\($n)", url: "https://gemini.google.com/app/\($n)", model: "lyria_3_5_fullsong/0.0.1",
           description: "bpm: 120.0\n[[A0]]\n[0.0:] opening\n[24.0:] build", text: "Here is your track."}]' <<<"$takes")
done
jq -cn --argjson t "$takes" '{ok: true, account: "fakeacct", takes: $t}'
EOF
chmod +x "$GEMINI_MUSIC_ENGINE"
: >"$FAKE_ENGINE_CALLS"
: >"$WORK/err"

music() { bash "$ROOT/bin/gemini-music" "$@" >"$WORK/stdout" 2>"$WORK/err"; }
expect_rc() {
  local expected=$1 result=0
  shift
  music "$@" || result=$?
  assert test "$result" -eq "$expected"
}
seconds() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

out="$WORK/out/score.wav"
expect_rc 2 --dest "$out"
expect_rc 2 --prompt 'a theme'
expect_rc 2 --dest relative.wav --prompt 'a theme'
expect_rc 2 --dest "$WORK/out/score.flac" --prompt 'a theme'
expect_rc 2 --dest "$out" --prompt 'a theme' --duration 46
assert grep -q -- '--length short' "$WORK/err"
expect_rc 2 --dest "$out" --prompt 'a theme' --ref-audio "$M/take.mp3"
assert grep -q 'Google Flow Music' "$WORK/err"
expect_rc 2 --dest "$out" --prompt 'a theme' --stems
expect_rc 2 --dest "$out" --prompt 'a theme' --length long
expect_rc 2 --dest "$out" --prompt 'a theme' --genre Polka
expect_rc 2 --dest "$out" --prompt 'a theme' --count 4
expect_rc 2 --dest "$out" --prompt 'a theme' --instrumental --vocals
expect_rc 2 --dest "$out" --prompt 'a theme' --ref-image "$M/cover.gif"
expect_rc 2 --dest "$out" --prompt 'a theme' --video "$M/missing.mp4"
expect_rc 2 --dest "$out" --prompt 'a theme' --video relative.mp4
expect_rc 2 --dest "$out" --prompt 'a theme' --account 'bad name'
assert test ! -s "$FAKE_ENGINE_CALLS"

assert music --dest "$out" --prompt 'a driving string theme' --length short --instrumental --genre Cinematic \
  --ref-image "$M/cover.png" --video "$M/scene.mp4"
calls=$(tr '\n' ' ' <"$FAKE_ENGINE_CALLS")
assert grep -q -- '--length short --vocals instrumental --genre Cinematic' <<<"$calls"
assert grep -q -- "--attach $M/cover.png --attach $M/scene.mp4" <<<"$calls"
assert grep -q -- '--prompt a driving string theme --count 1' <<<"$calls"
assert test "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$out")" = 'pcm_s16le,48000,2'
assert grep -qx "dest=$out" "$WORK/stdout"
assert grep -qx "duration=$(seconds "$out" | awk '{ printf "%.2f", $1 }')" "$WORK/stdout"
assert grep -qx 'format=wav' "$WORK/stdout"
assert grep -qx 'chat=https://gemini.google.com/app/1' "$WORK/stdout"
assert grep -qx 'account=fakeacct' "$WORK/stdout"
assert grep -qx 'model=lyria_3_5_fullsong/0.0.1' "$WORK/stdout"
assert grep -q '^credits=unmetered' "$WORK/stdout"
assert grep -qE '^seconds=[0-9]+$' "$WORK/stdout"
assert grep -qx 'Model: lyria_3_5_fullsong/0.0.1' "$out.txt"
assert grep -qx '\[24.0:\] build' "$out.txt"
assert grep -qx 'Here is your track.' "$out.txt"
assert test -z "$(ls "$TMPDIR")"
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -c '[.tool, .kind, .rc, .account, .served, .size]')" = \
  '["gemini-music","audio",0,"fakeacct","lyria_3_5_fullsong/0.0.1",1]'

: >"$FAKE_ENGINE_CALLS"
assert music --dest "$WORK/out/theme.mp3" --prompt 'a theme' --vocals --count 2
assert grep -qx -- '--vocals' "$FAKE_ENGINE_CALLS"
assert grep -qx 'on' "$FAKE_ENGINE_CALLS"
assert cmp -s "$M/take.mp3" "$WORK/out/theme.mp3"
assert cmp -s "$M/take.mp3" "$WORK/out/theme-2.mp3"
assert grep -q "^variant=$WORK/out/theme-2.mp3 duration=[0-9.]* chat=https://gemini.google.com/app/2$" "$WORK/stdout"
assert test -s "$WORK/out/theme-2.mp3.txt"

assert music --dest "$WORK/out/cover.mp4" --prompt 'a theme'
assert cmp -s "$M/take.mp4" "$WORK/out/cover.mp4"
FAKE_ENGINE_MODE=novideo expect_rc 1 --dest "$WORK/out/none.mp4" --prompt 'a theme'
assert grep -q 'without its mp4' "$WORK/err"

FAKE_ENGINE_MODE=dry assert music --dest "$out" --prompt 'a theme' --length short --dry-run
assert grep -qx -- '--dry-run' "$FAKE_ENGINE_CALLS"
assert grep -qx 'dry_run=ok' "$WORK/stdout"
FAKE_ENGINE_MODE=limit expect_rc 3 --dest "$out" --prompt 'a theme'
assert grep -qx 'GEMINI_USAGE_LIMIT' "$WORK/err"
assert grep -q 'out of Gemini music generations' "$WORK/err"
FAKE_ENGINE_MODE=login expect_rc 4 --dest "$out" --prompt 'a theme'
assert grep -q 'geminib web fakeacct' "$WORK/err"
FAKE_ENGINE_MODE=usage expect_rc 2 --dest "$out" --prompt 'a theme'
FAKE_ENGINE_MODE=crash expect_rc 1 --dest "$out" --prompt 'a theme'
assert grep -q 'UI drift' "$WORK/err"
assert grep -qx 'BROWSER_FAILURE route=gemini-app account=fakeacct code=1 shot=- reason=Gemini app UI drift: no Length chip' "$WORK/err"
assert test "$(tail -n 1 "$IMAGE_LEG_LOG" | jq -r '.err | test("^BROWSER_FAILURE route=gemini-app"; "m")')" = true
refute grep -q '^noise' "$WORK/err"
FAKE_ENGINE_MODE=short assert music --dest "$WORK/out/short.mp3" --prompt 'a theme' --count 3
assert cmp -s "$M/take.mp3" "$WORK/out/short-2.mp3"
assert grep -qx 'short=2 of 3 takes; the next one failed: limit' "$WORK/stdout"
assert grep -q "^variant=$WORK/out/short-2.mp3 duration=[0-9.]* chat=u2 account=other$" "$WORK/stdout"
assert grep -qx 'gemini-music: only 2 of 3 takes; the next one failed: limit' "$WORK/err"
FAKE_ENGINE_MODE=garbage expect_rc 1 --dest "$out" --prompt 'a theme'
assert grep -q 'printed no result' "$WORK/err"
assert test -z "$(ls "$TMPDIR")"

mkdir -p "$GEMINI_WEB_DIR"
assert python3 - "$ROOT/share" "$ROOT/tests/fixtures/gemini-music" <<'EOF'
import base64, json, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import gemini_music as m
import gemini_web as g

fixtures = Path(sys.argv[2])
saved = m.read_reply([(fixtures / "saved.txt").read_text()])
assert saved["chat"] == "c_0123456789abcdef", saved["chat"]
assert saved["states"] == [1, 1, 4], saved["states"]
assert saved["model"] == "lyria_3_5_fullsong/0.0.1", saved["model"]
assert "filename=music.mp3" in saved["audio"]["url"] and saved["audio"]["url"].startswith("https://contribution.usercontent.google.com/download?"), saved["audio"]
assert "filename=output.mp4" in saved["video"]["url"] and abs(saved["video"]["seconds"] - 58.383) < 0.01, saved["video"]
assert "bpm: 80.0" in saved["description"] and "[0.0:]" in saved["description"], saved["description"][:200]
assert saved["text"].startswith("I have generated"), saved["text"]
assert m.verdict(saved, "acct") is None

broken = m.read_reply([(fixtures / "no-track.txt").read_text()])
assert broken["states"] == [1, 1, 4] and broken["audio"] is None, broken
failure = m.verdict(broken, "acct")
assert failure.code == 1 and "returned no track on acct" in failure.reason and "went wrong" in failure.reason, failure.reason

limited = {"text": "You've reached your music generation limit. Try again tomorrow.", "states": [1, 4], "audio": None}
assert m.verdict(limited, "acct").code == 3
silent = {"text": "Sure, here are some ideas for a theme.", "states": [], "audio": None}
assert "without running the music tool" in m.verdict(silent, "acct").reason
assert m.stream_chunks(")]}'\nnot a frame") == [] and m.stream_chunks("") == []
assert m.read_reply(["garbage"])["audio"] is None


def link(kind):
    token = base64.urlsafe_b64encode(b"\n\x0cbard_storage\x12\x0e\x12\x0c" + kind).decode().rstrip("=")
    return "https://contribution.usercontent.google.com/download?c=%s&filename=x" % token


def media(name, kind):
    node = [None] * 18
    node[2], node[7], node[11] = name, [link(kind)], "video/mp4"
    return node


assert m.uploaded(link(b"request_data")) and not m.uploaded(link(b"response_data")) and not m.uploaded("https://x/?c=%%%")
assert m.media_of([media("picture.mp4", b"request_data")], "video/mp4") is None
assert m.media_of([media("picture.mp4", b"request_data"), media("output.mp4", b"temp_data")], "video/mp4")["name"] == "output.mp4"


class Clicked(Exception):
    pass


class Node:
    def __init__(self, page, text):
        self.page, self.text = page, text
        self.first = self

    def count(self):
        return 1 if self.text else 0

    def filter(self, has_text):
        return Node(self.page, self.text if has_text in self.text else "")

    def inner_text(self):
        return self.text

    def get_by_text(self, name, exact=False):
        assert name == "Agree" and exact
        return self

    def click(self, timeout=None):
        self.page.clicked += 1


class Page:
    def __init__(self, text):
        self.text, self.clicked = text, 0

    def locator(self, selector):
        assert selector == "mat-dialog-container"
        return Node(self, self.text)


reminder = "A reminder about creating videos\n\nMake sure you have the rights to any content you upload."
page = Page(reminder)
try:
    m.answer_notice(page, "stranger")
    raise AssertionError("an account without the owner's yes was agreed")
except g.Failure as refused:
    assert refused.code == 4 and "stranger" in refused.reason and "A reminder about creating videos" in refused.reason, refused.reason
assert page.clicked == 0
(g.ROOT / m.AGREED).write_text(json.dumps({"agreed": ["friend"]}))
assert m.answer_notice(page, "friend") is True and page.clicked == 1
rows = [json.loads(line) for line in (g.ROOT / "jobs.jsonl").read_text().splitlines()]
assert rows[-1]["event"] == "notice-agreed" and rows[-1]["account"] == "friend", rows[-1]
upload = Page("Creating content from images and files\nMake sure you have the necessary rights to any images")
assert m.answer_notice(upload, "friend") is True and upload.clicked == 1
assert m.answer_notice(Page(""), "stranger") is False


class Card:
    def __init__(self, page, shown):
        self.page, self.shown = page, shown

    def count(self):
        return int(self.shown)

    def nth(self, index):
        return self

    def is_visible(self):
        return self.shown

    def click(self, timeout=None):
        self.page.closed += 1


class AppPage:
    def __init__(self, shown):
        self.shown, self.closed = shown, 0

    def get_by_text(self, text, exact=False):
        return Card(self, self.shown and text == "Keep in mind" and exact)

    def get_by_role(self, role, name, exact=True):
        return Card(self, self.shown and (role, name) == ("button", "Got it"))

    def wait_for_timeout(self, ms):
        pass


card = AppPage(True)
assert m.close_disclaimer(card) is True and card.closed == 1
assert m.close_disclaimer(AppPage(False)) is False


class Chip:
    def __init__(self, page):
        self.page, self.first = page, self

    def wait_for(self, timeout=None):
        if self.page.picked < self.page.sticks_on:
            raise TimeoutError("no Length chip")


class Composer:
    def __init__(self, sticks_on):
        self.sticks_on, self.picked = sticks_on, 0

    def get_by_role(self, role, name, exact=True):
        assert (role, name) == ("button", "Length"), (role, name)
        return Chip(self)


real_pick = m.pick_music
m.pick_music = lambda page, account: setattr(page, "picked", page.picked + 1)
composer = Composer(2)
m.open_music(composer, "alpha")
assert composer.picked == 2, composer.picked
try:
    m.open_music(Composer(3), "alpha")
    raise AssertionError("a composer without the music tool passed")
except g.Failure as stuck:
    assert stuck.code == 1 and "did not stay selected" in stuck.reason, stuck.reason
m.pick_music = real_pick
assert m.answer_notice(Page("Some other dialog"), "stranger") is False

for name, email in (("alpha", "a@x"), ("beta", "b@x"), ("gamma", "c@x"), ("delta", "d@x"), ("blocked", "x@x")):
    (g.ROOT / "profiles" / name / "Default").mkdir(parents=True)
    (g.ROOT / "profiles" / name / "Default" / "Cookies").write_text("")
    g.meta_path(name).parent.mkdir(parents=True, exist_ok=True)
    g.meta_path(name).write_text(json.dumps({"email": email}))
now = time.time()
(g.ROOT / "walls.json").write_text(json.dumps({"delta": now + 3600}))
m.set_music_wall("gamma", now + 3600)
g.write_meta("alpha", generation_started_at=int(now) - 5)
g.write_meta("beta", generation_started_at=int(now) - 10)
with open(g.ROOT / "jobs.jsonl", "a") as ledger:
    ledger.write(json.dumps({"ts": now, "kind": "music", "event": "saved", "account": "beta"}) + "\n")
assert m.rotation() == ["beta", "alpha"], "music ordered by its ledger, not the Flow family's least recent start"
g.write_meta("beta", generation_started_at=int(now) - 1)
assert m.rotation() == ["alpha", "beta"], m.rotation()

import contextlib
real_browser, real_take = g.browser, m.one_take
g.browser = lambda account: contextlib.nullcontext()
m.one_take = lambda context, account, plan, take: {"ok": True, "take": take, **({"dry_run": True} if plan["dry_run"] else {})}
m.generate_on("alpha", {"count": 1, "dry_run": True})
assert g.read_meta("alpha")["generation_started_at"] == int(now) - 5, "a dry run stamped a new generation"
m.generate_on("alpha", {"count": 1, "dry_run": False})
assert g.read_meta("alpha")["generation_started_at"] >= int(now), "a new song did not stamp its start"
assert m.rotation() == ["beta", "alpha"], m.rotation()
g.browser, m.one_take = real_browser, real_take

import contextlib, io, os, types
home = Path(os.environ["HOME"])
pool = home / ".gemini-profiles" / ".geminib"
pool.mkdir(parents=True)
(pool / "disabled").write_text("beta\n")
os.environ["WORKER_PICK_CONFIG_FILE"] = str(home / "pins")
g._pool = None
assert m.rotation() == ["alpha"], m.rotation()
(home / "pins").write_text("gemini" + "_profile=beta\n")
g._pool = None
assert m.rotation() == ["beta", "alpha"], m.rotation()
(home / "pins").write_text("")
g._pool = None


def run(**overrides):
    args = types.SimpleNamespace(length=None, vocals=None, genre=None, attach=None, count=3, out_dir="/o",
                                 dry_run=False, prompt="p", account=None)
    vars(args).update(overrides)
    out = io.StringIO()
    code = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        try:
            m.cmd_generate(args)
        except SystemExit as exit:
            code = exit.code
        except g.Failure as failure:
            return failure.code, {"reason": failure.reason}
    return code, json.loads(out.getvalue().strip().splitlines()[-1])


code, result = run(account="beta")
assert code == 4 and "out of the gemini worker pool" in result["reason"], result
real_generate_on, launched = m.generate_on, []
m.generate_on = lambda account, plan: launched.append(account) or {"ok": True, "account": account, "takes": []}
code, result = run(account="blocked")
assert code == 2 and "unknown account: blocked" in result["reason"] and launched == [], (result, launched)
m.generate_on = real_generate_on
assert "blocked" not in g.bound_accounts(), g.bound_accounts()
calls = []
def takes(account, plan):
    calls.append((account, plan["first_take"], plan["count"]))
    done = [{"audio": f"take{n}.mp3", "account": account} for n in range(plan["first_take"], plan["first_take"] + plan["count"])]
    if account == "alpha":
        error = g.Failure(3, "alpha is out of Gemini music generations")
        error.takes = done[:1]
        raise error
    return {"ok": True, "account": account, "takes": done}
m.generate_on = takes
m.set_music_wall = lambda account, until: None
(pool / "disabled").write_text("")
g._pool = None
m.rotation = lambda: ["alpha", "beta"]
code, result = run()
assert code == 0 and calls == [("alpha", 1, 3), ("beta", 2, 2)], calls
assert [(t["audio"], t["account"]) for t in result["takes"]] == [("take1.mp3", "alpha"), ("take2.mp3", "beta"), ("take3.mp3", "beta")], result
assert result["account"] == "alpha" and "short" not in result, result
m.rotation = lambda: ["alpha"]
code, result = run()
assert code == 0 and result["short"] == "1 of 3 takes; the next one failed: alpha is out of Gemini music generations", result
assert [t["audio"] for t in result["takes"]] == ["take1.mp3"], result
m.rotation = lambda: []
g.bound_accounts = lambda: []
code, result = run()
assert code == 4 and "geminib web" in result["reason"], result
EOF

printf 'PASS test_gemini_music (%s asserts)\n' "$asserts"
