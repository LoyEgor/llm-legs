#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/elevenlabs_media.py: what the API refused on the first live calls (2026-10-05) is settled before a
# request. Fixture keys and a dead API host: a request that slips through fails on the network, never bills.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
export ELEVENLABS_KEYS="$WORK/keys.txt" ELEVENLABS_API_BASE="http://127.0.0.1:9" IMAGE_LEG_LOG="$WORK/legs.jsonl" VENDOR_CLI_UPDATE_STATE_DIR="$WORK/vendor-cli-update"
# The shared key state (transcriptions-gpt's keystate) the daemon reads: never the live one.
export KEY_STATE="$WORK/key-state.json" LIMIT_HITS_LOG="$WORK/hits.jsonl"
printf 'fixture-key trimmed\n' >"$ELEVENLABS_KEYS"
el() { python3 "$ROOT/share/elevenlabs_media.py" "$@" >"$WORK/out" 2>"$WORK/err"; }
python3 -c 'import sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(2 * 16000 * 27 // 10))' "$WORK/short.wav"

# Text to speech refuses pcm_44100 below the Pro tier (HTTP 403 output_format_not_allowed): a .wav is no raw PCM.
assert el speech --dest "$WORK/a.wav" --text hi --voice abcdefghij0123456789 --dry-run
assert python3 -c 'import json, sys; fmt = json.load(open(sys.argv[1]))["output_format"]; assert not fmt.startswith("pcm_"), fmt' "$WORK/out"

# Isolation refuses audio under 4.6 s (HTTP 400 invalid_audio_duration): exit 2 before any request.
el isolate --in "$WORK/short.wav" --dest "$WORK/iso.wav"
assert test $? -eq 2
assert grep -q 'isolation takes at least 4.6 s' "$WORK/err"

# An srt needs diarization on (HTTP 400 invalid_parameters).
assert el transcribe --in "$WORK/short.wav" --dest "$WORK/t.srt" --dry-run
assert python3 -c 'import json, sys; assert ["diarize", "true"] in json.load(open(sys.argv[1]))["fields"]' "$WORK/out"

# A dialogue runs the one speech model (eleven_v4 reached Text to Dialogue on 2026-09-28; the v3 pin went with it).
assert el speech --dest "$WORK/d.mp3" --line 'abcdefghij0123456789: hi' --line 'bbcdefghij0123456789: [laughs] yes' --dry-run
assert python3 -c 'import json, sys; got = json.load(open(sys.argv[1])); assert got["POST"] == "/v1/text-to-dialogue" and got["body"]["model_id"] == json.load(open(sys.argv[2]))["speech"]["model"], got' "$WORK/out" "$ROOT/share/image-caps/elevenlabs.json"

# --speed is refused where the API would drop it: eleven_v4 has no speed slider and dialogue settings carry
# stability only; a model with the slider still sends it.
el speech --dest "$WORK/a.mp3" --text hi --voice abcdefghij0123456789 --speed 1.1 --dry-run
assert test $? -eq 2
el speech --dest "$WORK/d.mp3" --line 'abcdefghij0123456789: hi' --model eleven_v3 --speed 1.1 --dry-run
assert test $? -eq 2
assert el speech --dest "$WORK/a.mp3" --text hi --voice abcdefghij0123456789 --model eleven_v3 --speed 1.1 --dry-run
assert python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["body"]["voice_settings"] == {"speed": 1.1}' "$WORK/out"

# Instant Soundtracks ride on video-to-music: separate tracks imply the sfx layer and need an .mp3 dest; none of the
# three scores a prompt alone.
printf 'x' >"$WORK/clip.mp4"
assert el music --for-video "$WORK/clip.mp4" --dest "$WORK/m.mp3" --separate-tracks --audio-reference --dry-run
assert python3 -c 'import json, sys; f = json.load(open(sys.argv[1]))["fields"]; assert all([k, "true"] in f for k in ("add_sfx", "separate_tracks", "use_audio_as_reference")), f' "$WORK/out"
el music --for-video "$WORK/clip.mp4" --dest "$WORK/m.wav" --separate-tracks --dry-run
assert test $? -eq 2
el music --prompt calm --dest "$WORK/m.mp3" --add-sfx --dry-run
assert test $? -eq 2
assert python3 - "$ROOT/share" "$WORK" <<'PY'
import contextlib, io, sys, zipfile
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import elevenlabs_media as m

work, buf = Path(sys.argv[2]), io.BytesIO()
with zipfile.ZipFile(buf, "w") as archive:
    archive.writestr("music.mp3", b"ID3m")
    archive.writestr("sfx.mp3", b"ID3s")
run = m.Run("music", None)
m.probe = lambda path: ("", "")
m.unzip_tracks(buf.getvalue(), work, "score", run)
assert (work / "score.music.mp3").read_bytes() == b"ID3m" and (work / "score.sfx.mp3").read_bytes() == b"ID3s"
assert f"dest={work / 'score.sfx.mp3'}" in run.lines, run.lines
PY

# A transcript edit rides in the transcription call as transcript_edit; its answer is untimed text, so no .srt, and
# the API takes at most 2000 chars.
assert el transcribe --in "$WORK/short.wav" --dest "$WORK/t.txt" --edit 'Spell the names right' --dry-run
assert python3 -c 'import json, sys; assert ["transcript_edit", "Spell the names right"] in json.load(open(sys.argv[1]))["fields"]' "$WORK/out"
el transcribe --in "$WORK/short.wav" --dest "$WORK/t.srt" --edit 'Spell the names right' --dry-run
assert test $? -eq 2
el transcribe --in "$WORK/short.wav" --dest "$WORK/t.txt" --edit "$(printf 'x%.0s' $(seq 2001))" --dry-run
assert test $? -eq 2
assert grep -q 'at most 2000' "$WORK/err"

# Both results of an edit are read: the edited text lands in the .txt and the whole answer in its .json; an edit error
# in its place exits 1 with the unedited transcript delivered, never a second paid call.
assert python3 - "$ROOT/share" "$WORK" <<'PY'
import contextlib, http.server, io, json, os, sys, threading
sys.path.insert(0, sys.argv[1])
import elevenlabs_media as m

work, posts = sys.argv[2], []
answer = {"text": "eggor said hi", "language_code": "en", "words": [{"text": "eggor", "type": "word"}]}


class Fake(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"character_count": 1, "character_limit": 10}')

    def do_POST(self):
        posts.append(self.rfile.read(int(self.headers["Content-Length"])))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps(answer).encode())

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
m.API = f"http://127.0.0.1:{server.server_port}"
m.models_check = lambda account: "model_caps=fresh"
dest = os.path.join(work, "edit.txt")


def transcribe():
    with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
        rc = m.main(["transcribe", "--in", os.path.join(work, "short.wav"), "--dest", dest, "--edit", "Egor, not eggor"])
    return rc, out.getvalue() + err.getvalue()


answer["edited_transcript"] = {"kind": "transcript", "text": "Egor said hi.", "edited_text": "Egor said hi."}
rc, said = transcribe()
assert rc == 0 and "edit=done" in said, said
assert open(dest).read() == "Egor said hi.\n" and json.load(open(dest + ".json"))["text"] == "eggor said hi"
assert b'name="transcript_edit"\r\n\r\nEgor, not eggor' in posts[-1], posts[-1][:400]
answer["edited_transcript"] = {"kind": "error", "error_type": "edit_failed", "message": "edit timed out"}
rc, said = transcribe()
assert rc == 1 and "edit timed out" in said and open(dest).read() == "eggor said hi\n" and len(posts) == 2, said
del answer["edited_transcript"]
rc, said = transcribe()
assert rc == 1 and "no edited_transcript" in said, said
PY

# Lip-sync needs a Pro plan (HTTP 402 paid_plan_required): no kind runs it.
el lipsync --dest "$WORK/l.mp4"
assert test $? -eq 2

# Every kind is one script under its own name, logged through share/image-leg.sh like the other media legs.
assert test -L "$ROOT/bin/elevenlabs-isolate"
: >"$IMAGE_LEG_LOG"
"$ROOT/bin/elevenlabs-isolate" --in "$WORK/short.wav" --dest "$WORK/iso.wav" >"$WORK/out" 2>"$WORK/err"
assert test $? -eq 2
assert jq -e 'select(.tool == "elevenlabs-isolate" and .kind == "audio" and .rc == 2 and .route == "api"
  and (.job | startswith("elevenlabs-isolate-")) and (.err | test("4.6 s")))' "$IMAGE_LEG_LOG" >/dev/null
"$ROOT/bin/elevenlabs-speech" --dest "$WORK/a.wav" --text hi --voice abcdefghij0123456789 --dry-run >"$WORK/out" 2>"$WORK/err"
"$ROOT/bin/elevenlabs-speech" --help >"$WORK/out" 2>"$WORK/err"
assert test "$(wc -l <"$IMAGE_LEG_LOG")" -eq 1
printf '#!/bin/sh\nexec sleep 30\n' >"$WORK/slow-python"
chmod +x "$WORK/slow-python"
ELEVENLABS_PYTHON="$WORK/slow-python" "$ROOT/bin/elevenlabs-sfx" >/dev/null 2>&1 &
sleep 0.5
# The wrapper's TERM trap runs only once its foreground vendor ends, so the vendor is ended after it.
kill -TERM $!
pkill -TERM -P $!
wait $!
assert jq -e 'select(.tool == "elevenlabs-sfx" and .rc == 143)' "$IMAGE_LEG_LOG" >/dev/null

# The balance skips only a key without the read permission; any other failure is that key's row alone, its last
# reading plus `error`, never a failed section. A key read less than 300 s ago or held with a known end is not
# asked again; a read lands in the shared key state.
assert python3 - "$ROOT/share" "$WORK" <<'PY'
import contextlib, io, json, os, sys, threading, time
sys.path.insert(0, sys.argv[1])
import elevenlabs_balance as b
import elevenlabs_media as m
from key_state import keystate

b.accounts, b.reserves, b.labels = lambda: {"one": "k1", "two": "k2"}, lambda: {}, lambda: {}
sub = {"character_count": 5, "character_limit": 10, "next_character_count_reset_unix": int(time.time()) + 86400}
for refused, code in (("missing_permissions", 401), ("invalid_api_key", 401), ("api_key_disabled", 401),
                      ("paid_plan_required", 402), ("", 401)):
    def answer(self, method, path, **kwargs):
        if self.account == "two":
            raise self.classify(code, refused, "no")
        return sub
    m.Client.json = b.Client.json = answer
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        assert b.main() == 0, refused
    rows = {r["account"]: r for r in json.loads(out.getvalue())["accounts"]}
    assert rows["one"]["used"] == 5 and rows["one"]["limit"] == 10 and "error" not in rows["one"], rows
    assert ("two" not in rows) if refused == "missing_permissions" else (
        rows["two"]["used"] is None and refused in rows["two"]["error"]), (refused, rows)

asked = []
def answer(self, method, path, **kwargs):
    asked.append(self.account)
    if self.account == "two":
        raise m.Fail(1, "network: refused")
    return {"character_count": 7, "character_limit": 10, "next_character_count_reset_unix": int(time.time()) + 86400}
m.Client.json = b.Client.json = answer
b.accounts = lambda: {"fresh": "kf", "spent": "ks", "stale": "kt", "two": "k2", "unread": "ku"}
now = time.time()
keystate.observe("elevenlabs", "kf", 9, 10, now + 86400, now - 10)
keystate.observe("elevenlabs", "ks", 0, 10, now + 5 * 86400, now - 1000)
keystate.observe("elevenlabs", "kt", 9, 10, now + 86400, now - 400)
keystate.observe("elevenlabs", "k2", 4, 10, now + 86400, now - 400)
keystate.hold("elevenlabs", "ku", "quota", now + 86400)
out = io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
    assert b.main() == 0
rows = {r["account"]: r for r in json.loads(out.getvalue())["accounts"]}
assert sorted(asked) == ["stale", "two", "unread"], asked
assert rows["fresh"]["used"] == 1 and "held_until" not in rows["fresh"], rows["fresh"]
assert rows["spent"]["used"] == 10 and rows["spent"]["why"] == "quota" and rows["spent"]["held_until"] == int(now + 5 * 86400), rows
assert rows["stale"]["used"] == 7 and keystate.entry("elevenlabs", "kt")["left"] == 3 and rows["stale"]["as_of"] >= int(now), rows
assert rows["two"]["used"] == 6 and rows["two"]["error"] == "network: refused", rows["two"]
# A quota hold with no reading behind it is read for its reset; credits left lift it.
assert rows["unread"]["used"] == 7 and "held_until" not in rows["unread"], rows["unread"]
os.remove(os.environ["KEY_STATE"])
b.accounts = lambda: {"one": "k1", "two": "k2"}

both = threading.Barrier(2, timeout=10)
def answer(self, method, path, **kwargs):
    both.wait()
    return {"character_count": len(self.account), "character_limit": 10}
m.Client.json = b.Client.json = answer
out = io.StringIO()
with contextlib.redirect_stdout(out):
    assert b.main() == 0
assert [a["account"] for a in json.loads(out.getvalue())["accounts"]] == ["one", "two"], out.getvalue()
PY

# The account's own model list is compared with `served_models` at most once a day: a dead host is unknown and
# never fails the run, a new model is stale and named, one of a newer generation than its kind's default doubly.
assert grep -qx 'elevenlabs-speech: model_caps=unknown' <(python3 "$ROOT/share/elevenlabs_media.py" speech \
  --dest "$WORK/a.wav" --text hi --voice abcdefghij0123456789 --dry-run 2>&1 >/dev/null)
assert python3 - "$ROOT/share" "$WORK" <<'PY'
import contextlib, http.server, io, json, os, sys, threading, time
sys.path.insert(0, sys.argv[1])
import elevenlabs_media as m

served = [{"model_id": i, "can_do_text_to_speech": "sts" not in i, "can_do_voice_conversion": "sts" in i}
          for i in m.caps()["served_models"]]
answer, asked = {"models": served}, []


class Fake(http.server.BaseHTTPRequestHandler):
    def reply(self, body, headers=()):
        self.send_response(200)
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        asked.append(self.path)
        if self.path == "/v1/models":
            self.reply(json.dumps(answer["models"]).encode())
        else:
            self.reply(json.dumps({"character_count": 1, "character_limit": 10}).encode())

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.reply(b"ID3fake", [("character-cost", "2")])

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
m.API = f"http://127.0.0.1:{server.server_port}"
cache = m.KEYS.parent / "models-check.json"
with contextlib.suppress(FileNotFoundError):
    cache.unlink()


def speech():
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        assert m.main(["speech", "--dest", os.path.join(sys.argv[2], "s.mp3"), "--text", "hi",
                       "--voice", "abcdefghij0123456789"]) == 0
    return out.getvalue().splitlines()


lines = speech()
assert lines[-1] == "model_caps=fresh" and "model=eleven_v4" in lines, lines
assert asked.count("/v1/models") == 1 and json.loads(cache.read_text())["account"] == "trimmed", asked
answer["models"] = [x for x in served if x["model_id"] != "eleven_flash_v2"] + [
    {"model_id": "eleven_v5", "can_do_text_to_speech": True},
    {"model_id": "eleven_sts_v3", "can_do_voice_conversion": True}, {"model_id": "eleven_v4_flash", "can_do_text_to_speech": True}]
assert m.models_check("trimmed") == "model_caps=fresh" and asked.count("/v1/models") == 1, asked
cache.write_text(json.dumps({**json.loads(cache.read_text()), "at": int(time.time()) - m.MODELS_CHECK_S - 60}))
speech_stale = ("models: +eleven_v5 +eleven_sts_v3 +eleven_v4_flash -eleven_flash_v2; "
                "newer=eleven_v5>eleven_v4,eleven_sts_v3>eleven_multilingual_sts_v2")
assert speech()[-1] == "model_caps=stale " + speech_stale, asked
assert asked.count("/v1/models") == 2, asked
cache.unlink()
m.API = "http://127.0.0.1:9"
assert m.models_check("trimmed") == "model_caps=unknown" and not cache.exists()
import caps_checks
rows = [(r["state"], r["what"]) for r in caps_checks.read() if (r["vendor"], r["section"]) == ("elevenlabs", "served_models")]
assert rows == [("fresh", ""), ("fresh", ""), ("stale", speech_stale)], rows
PY

# Every kind spends the key file's lines in order; a spent quota, a plan or key refusal or a voice the account lacks
# moves to the next line, any other failure stops.
assert python3 - "$ROOT/share" "$WORK" <<'PY'
import contextlib, io, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import elevenlabs_media as m

m.KEYS = Path(sys.argv[2]) / "order.txt"
m.KEYS.write_text("# note\nk1 alena reserve=5\nk2 free1\nk3 com\n")
assert m.pool_for("transcribe", None) == m.pool_for("music", None) == ["alena", "free1", "com"]
m.Client.balance = lambda self: (0, 100)
for first, second, fails, reached in ((m.Fail(4, "plan", "paid_plan_required"), None, False, ["alena", "free1"]),
                                      (m.Fail(2, "no voice", "voice_missing"), m.Fail(3, "quota"), False,
                                       ["alena", "free1", "com"]),
                                      (m.Fail(1, "network"), None, True, ["alena"])):
    seen = []
    def work(client):
        seen.append(client.account)
        error = {1: first, 2: second}.get(len(seen))
        if error:
            raise error
        return client.account
    run = m.Run("speech", None)
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            got = run.attempt(work)
            assert not fails and got == reached[-1], got
        except m.Fail:
            assert fails
    assert seen == reached, seen
PY

# The shared key state decides the pool with the dictation daemon: a held key is skipped (a pinned one fails at once
# with the hold's why and end), a busy 429 holds the key for its stated wait and moves on with no sleep on it, a
# spent quota holds it until the subscription's reset. Only when every key answered busy does the run wait the
# shortest stated wait (at most 10 s) and try the pool once more; a POST that timed out is never sent again.
assert python3 - "$ROOT/share" "$WORK" <<'PY'
import contextlib, http.server, io, json, os, sys, threading, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import elevenlabs_media as m
from key_state import keystate

m.KEYS = Path(sys.argv[2]) / "shared.txt"
m.KEYS.write_text("ka alpha\nkb beta reserve=5\n")
answers, posts, gets = {}, [], []


class Fake(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        gets.append(self.headers["xi-api-key"])
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"character_count": 1, "character_limit": 100}')

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"] or 0))
        key = self.headers["xi-api-key"]
        posts.append(key)
        status, body, headers = answers.get(key, (200, b"ID3", {}))
        if status == "slow":
            time.sleep(1.5)
            status = 200
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
m.API = f"http://127.0.0.1:{server.server_port}"
sleeps, real_sleep = [], m.time.sleep
m.time.sleep = sleeps.append
busy = json.dumps({"detail": {"status": "system_busy", "message": "busy"}}).encode()
spent = json.dumps({"detail": {"status": "quota_exceeded", "message": "no credits"}}).encode()


def run(pin=None, timeout=900):
    def work(client):
        client.call("POST", "/v1/sound-generation", body={}, timeout=timeout)
        return client.account
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            return m.Run("sfx", pin).attempt(work)
        except m.Fail as error:
            return error


def fresh(**case):
    with contextlib.suppress(FileNotFoundError):
        os.remove(os.environ["KEY_STATE"])
    answers.clear()
    answers.update(case)
    posts.clear()
    gets.clear()
    sleeps.clear()


now = time.time()
fresh()
keystate.hold("elevenlabs", "ka", "quota", now + 3600)
keystate.observe("elevenlabs", "kb", 50, 100, now + 86400, now - 10)
assert run() == "beta" and posts == ["kb"] and gets == [], (posts, gets)
got = run("alpha")
assert isinstance(got, m.Fail) and got.rc == 3 and "held for quota until" in got.message and posts == ["kb"], got

fresh(ka=(429, busy, {"Retry-After": "7"}))
assert run() == "beta" and posts == ["ka", "kb"] and sleeps == [], (posts, sleeps)
held = keystate.held("elevenlabs", "ka")
assert held["why"] == "rate" and now + 6 < held["until"] < time.time() + 8 and gets == ["kb"], (held, gets)

fresh(ka=(429, spent, {}))
keystate.observe("elevenlabs", "ka", 10, 100, now + 5 * 86400, now - 1000)
assert run() == "beta" and posts == ["ka", "kb"] and sleeps == [], posts
held = keystate.held("elevenlabs", "ka")
assert held["why"] == "quota" and held["until"] == now + 5 * 86400, held

fresh(ka=(429, busy, {"Retry-After": "30"}), kb=(429, busy, {"Retry-After": "4"}))
got = run()
assert isinstance(got, m.Fail) and got.rc == 1 and "busy" in got.message, got
assert posts == ["ka", "kb", "ka", "kb"] and sleeps == [4.0], (posts, sleeps)
hits = [json.loads(line) for line in open(os.environ["LIMIT_HITS_LOG"])]
assert hits[-1]["limit"].endswith("elevenlabs.busy-retries") and hits[-1]["action"] == "retry-exhausted", hits[-1]
fresh(ka=(429, busy, {"Retry-After": "30"}), kb=(429, busy, {"Retry-After": "30"}))
run()
assert sleeps == [10.0], sleeps
fresh(ka=(429, busy, {}))
assert run("alpha").rc == 1 and posts == ["ka", "ka"] and sleeps == [10.0], (posts, sleeps)

fresh(ka=("slow", b"ID3", {}))
m.time.sleep = real_sleep
got = run(timeout=0.5)
assert isinstance(got, m.Fail) and got.rc == 1 and posts == ["ka"] and keystate.held("elevenlabs", "ka") is None, (got, posts)
PY

# The key sync copies the master over each mirror: a key the master dropped leaves, a key added only in the mirror
# stays at the end, an unchanged mirror is not rewritten.
assert python3 - "$ROOT/share" "$WORK" <<'PY'
import contextlib, io, os, sys
from pathlib import Path
work = Path(sys.argv[2])
os.environ["ELEVENLABS_KEYS"], os.environ["ELEVENLABS_MIRRORS"] = str(work / "master.txt"), str(work / "mirror.txt")
sys.path.insert(0, sys.argv[1])
import elevenlabs_keys_sync as s

master, mirror = work / "master.txt", work / "mirror.txt"
master.write_text("# master notes\nsk_aaaa1111 alena reserve=100\nsk_bbbb2222 com\n")
mirror.write_text("sk_oldold99\nsk_mine3333 reserve=7\n")
err = io.StringIO()
with contextlib.redirect_stderr(err):
    assert s.main() == 0
lines = mirror.read_text().splitlines()
assert lines[0].startswith("# elevenlabs-keys-sync") and lines[1:] == [
    "sk_aaaa1111 alena reserve=100", "sk_bbbb2222 com", "sk_oldold99", "sk_mine3333 reserve=7"], lines
assert "sk_oldold…ld99" in err.getvalue() and oct(mirror.stat().st_mode)[-3:] == "600"
master.write_text("sk_bbbb2222 com\nsk_oldold99 old\n")
with contextlib.redirect_stderr(io.StringIO()):
    s.main()
assert mirror.read_text().splitlines()[1:] == ["sk_bbbb2222 com", "sk_oldold99 old", "sk_mine3333 reserve=7"]
os.utime(mirror, (1, 1))
with contextlib.redirect_stderr(io.StringIO()):
    s.main()
assert mirror.stat().st_mtime == 1
master.write_text("sk_bbbb2222 com\n")
with contextlib.redirect_stderr(io.StringIO()):
    s.main()
assert mirror.read_text().splitlines()[1:] == ["sk_bbbb2222 com", "sk_mine3333 reserve=7"]
modes, real_replace = [], os.replace
def failing_replace(source, target):
    modes.append(oct(os.stat(source).st_mode)[-3:])
    raise OSError("disk full")
s.os.replace = failing_replace
master.write_text("sk_cccc3333 new\n")
try:
    with contextlib.redirect_stderr(io.StringIO()):
        s.main()
    raise AssertionError("a failed replace passed")
except OSError:
    pass
finally:
    s.os.replace = real_replace
assert modes == ["600"] and sorted(p.name for p in work.glob(".mirror.txt.sync-*")) == [], modes
del os.environ["ELEVENLABS_MIRRORS"]
assert s.mirrors() == []
PY
assert grep -qF "[ \"\$write_cache\" = 1 ] || elevenlabs_sync=''" "$ROOT/llm-limits.sh"
assert grep -qF 'run on every writing `llm-limits.sh` poll' "$ROOT/docs/image-vendors/elevenlabs.md"

echo "PASS test_elevenlabs_media ($asserts asserts)"
