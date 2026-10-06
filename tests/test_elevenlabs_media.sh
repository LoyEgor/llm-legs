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
printf '#!/bin/sh\nsleep 2\n' >"$WORK/slow-python"
chmod +x "$WORK/slow-python"
ELEVENLABS_PYTHON="$WORK/slow-python" "$ROOT/bin/elevenlabs-sfx" >/dev/null 2>&1 &
sleep 0.5
kill -TERM $!
wait $!
assert jq -e 'select(.tool == "elevenlabs-sfx" and .rc == 143)' "$IMAGE_LEG_LOG" >/dev/null

# The balance skips only a key without the read permission; a revoked or unpaid key exits 1 so the menubar keeps
# its last reading.
assert python3 - "$ROOT/share" "$WORK" <<'PY'
import contextlib, io, sys
sys.path.insert(0, sys.argv[1])
import elevenlabs_balance as b
import elevenlabs_media as m

b.accounts, b.reserves, b.labels = lambda: {"one": "k1", "two": "k2"}, lambda: {}, lambda: {}
sub = {"character_count": 5, "character_limit": 10}
for refused, code, rc in (("missing_permissions", 401, 0), ("invalid_api_key", 401, 1), ("api_key_disabled", 401, 1),
                          ("paid_plan_required", 402, 1), ("", 401, 1)):
    def answer(self, method, path, **kwargs):
        if self.account == "two":
            raise self.classify(code, refused, "no")
        return sub
    m.Client.json = b.Client.json = answer
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        assert b.main() == rc, refused
    assert rc or '"account": "one"' in out.getvalue(), out.getvalue()
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
del os.environ["ELEVENLABS_MIRRORS"]
assert s.mirrors() == []
PY

echo "PASS test_elevenlabs_media ($asserts asserts)"
