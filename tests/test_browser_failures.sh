#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The hidden-Chrome routes report every failed attempt as a BROWSER_ line; llm-doctor turns those lines into
# browser words and doctor-fix sends their fixer to the engine. Fixture stores only, under a temp HOME.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }

export HOME="$WORK/home" GEMINI_WEB_DIR="$WORK/home/.gemini-web" PYTHONDONTWRITEBYTECODE=1
export WORKER_STATS_DIR="$HOME/stats" WORKER_RUN_DIR="$HOME/runs" LLM_DOCTOR_DIR="$HOME/doctor"
export IMAGE_LEG_LOG="$HOME/image-legs/legs.jsonl" LLM_DOCTOR_LEDGER="$WORK/ledger.json"
export GEMINIB_CACHE_DIR="$WORK/geminib" LLM_DOCTOR_REBOOTS=""
unset REVIEW_DEBT_DIR
mkdir -p "$HOME/image-legs" "$GEMINIB_CACHE_DIR" "$GEMINI_WEB_DIR" "$WORK/bin"
printf '{"fetched_at": 1, "attempted_at": 1, "families": []}\n' >"$GEMINIB_CACHE_DIR/models.json"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/bin/review-anchors"
chmod +x "$WORK/bin/review-anchors"
export PATH="$WORK/bin:$PATH"
NOW=$(( $(date +%s) / 60 * 60 ))
export LLM_DOCTOR_NOW="$NOW"
printf '{"owner": "LLM owner", "owners": {"reviewers": "R", "workers": "W", "light": "L", "image": "Image owner"}, "rows": [], "blind_spots": []}\n' \
  >"$LLM_DOCTOR_LEDGER"

# The engine's own lines, snapshot included, written into the image-leg log the way image-leg.sh records them.
assert python3 - "$ROOT" "$IMAGE_LEG_LOG" "$NOW" <<'PY'
import contextlib, importlib.machinery, importlib.util, io, json, os, re, sys
root, log, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
sys.path.insert(0, os.path.join(root, "share"))
import gemini_web as gw
loader = importlib.machinery.SourceFileLoader("doctor", os.path.join(root, "bin", "llm-doctor"))
spec = importlib.util.spec_from_loader("doctor", loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)


class Page:
    url = "https://gemini.google.com/app/abc?hl=en"

    def is_closed(self):
        return False

    def screenshot(self, path, timeout):
        open(path, "wb").write(b"\x89PNG")

    def evaluate(self, script):
        assert "dialogs" in script
        return {"title": "Gemini", "dialogs": ["Creating content from images and files"], "toasts": [],
                "buttons": ["Agree", "Upload files"], "body": "page text"}


class Context:
    pages = [Page()]


def captured(call):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        call()
    return err.getvalue()


error = gw.Failure(1, "Upload files opened no file chooser")
error.shot = gw.snapshot(Context(), "egbogd", gw.failure_text(error))
error.route = gw.route_of(Context.pages[0].url)
assert error.route == "gemini-app" and gw.route_of("https://flow.google.com/project/x") == "flow"
assert gw.route_of("https://flowmusic.app/") == "flow-music" and gw.route_of("https://evil.example/flow.google.com") == gw.ROUTE
assert error.shot.endswith(".png") and os.path.exists(error.shot), error.shot
dump = open(error.shot[:-4] + ".txt").read()
assert "reason: Upload files opened no file chooser" in dump and "url: https://gemini.google.com/app/abc" in dump
assert "  Creating content from images and files" in dump and "  Agree" in dump and dump.rstrip().endswith("page text")
upload = captured(lambda: gw.report("egbogd", error))
assert re.fullmatch(r"BROWSER_FAILURE route=gemini-app account=egbogd code=1 shot=\S+\.png "
                    r"reason=Upload files opened no file chooser\n", upload), upload
assert captured(lambda: gw.report("egbogd", gw.Failure(1, "Upload files opened no file chooser"))) == ""

timeout = Exception('Timeout 30000ms exceeded.\nCall log:\n  - waiting for get_by_role("button", name="Short")')
assert gw.failure_text(timeout) == 'Exception: Timeout 30000ms exceeded. (- waiting for get_by_role("button", name="Short"))'
notice = captured(lambda: gw.report("locomthebest", gw.Failure(4, "locomthebest shows Gemini's notice \"A reminder\"; "
                                                                  "it needs the owner's one-time Agree")))
walled = captured(lambda: gw.report("com", gw.Failure(3, "com is out of Gemini music generations: try tomorrow")))
hide = captured(lambda: gw.warn("com", "could not hide the automation Chrome: not allowed"))
drift = captured(lambda: gw.report("-", timeout))
assert hide.startswith("BROWSER_WARNING route=flow account=com code=0 shot=- reason=could not hide"), hide
assert drift.startswith("BROWSER_FAILURE route=flow account=- code=1 shot=- reason=Exception: Timeout 30000ms"), drift
# chatgpt-web rebinds gemini_web's globals on import, so it comes after every gemini line and they are put back.
saved = {name: getattr(gw, name) for name in ("ROOT", "ROUTE", "TOOL", "POOL_VENDOR", "LOGIN_URL")}
import chatgpt_web as cw


class ChatPage(Page):
    url = "https://chatgpt.com/c/0a0b0c0d-1111-2222-3333-444455556666"


class ChatContext:
    pages = [ChatPage()]


chat_error = cw.drift("the composer never took the prompt")
chat_error.route = gw.route_of(ChatContext.pages[0].url)
chat_error.shot = gw.snapshot(ChatContext(), "work4", gw.failure_text(chat_error))
chat = captured(lambda: gw.report("work4", chat_error))
assert re.fullmatch(r"BROWSER_FAILURE route=chatgpt-web account=work4 code=1 shot=\S+/\.chatgpt-web/failures/\S+\.png "
                    r"reason=ChatGPT UI drift: the composer never took the prompt\n", chat), chat
for name, value in saved.items():
    setattr(gw, name, value)

legs = [(now - 600, "gemini-music", "audio", 0, "", notice + walled + "music.mp3 saved\n"),
        (now - 500, "gemini-music", "audio", 1, "", upload + "gemini-music: Upload files opened no file chooser\n"),
        (now - 400, "gemini-video", "video", 1, "egbogd", drift + "gemini-video: Flow UI drift\n"),
        (now - 300, "gemini-video", "video", 4, "", notice),
        (now - 200, "gemini-video", "video", 0, "com", hide),
        (now - 100, "codex-image", "image", 4, "", "codex-image: not set up"),
        (now - 50, "codex-image", "image", 1, "", chat + "chatgpt-web: ChatGPT UI drift: the composer never took the prompt\n")]
with open(log, "w") as handle:
    for ts, tool, kind, rc, account, err in legs:
        handle.write(json.dumps({"ts": ts, "tool": tool, "kind": kind, "rc": rc, "seconds": 30, "queued": 0,
                                 "size": 1, "account": account, "served": "", "err": err}) + "\n")
# Every reason either engine can raise lands on a named browser step; an unnamed one is a new word to add.
literal = re.compile(r"""(?:Failure\((\d),|fail\((\d),|drift\()\s*f?(["'])(.+?)\3""")
for name in ("gemini_web.py", "gemini_music.py", "flow_music.py", "chatgpt_web.py"):
    for match in literal.finditer(open(os.path.join(root, "share", name)).read()):
        code = int(match.group(1) or match.group(2) or 1)
        reason = re.sub(r"\{[^}]*\}", "7", match.group(4))
        if code == 2 or reason in ("7: 7", "7"):
            continue
        verdict = doctor.classify_browser(code, ("Flow UI drift: " if match.group(0).startswith("drift") else "") + reason)
        assert verdict[1] != doctor.BROWSER_OTHER, (name, reason, verdict)
        assert verdict[0] == ("walled" if code == 3 else "failed"), (name, reason, verdict)
assert doctor.classify_browser(1, "clip download failed (HTTP 503, 0 bytes)")[3] == "theirs"
assert doctor.classify_browser(1, "clip download failed (HTTP 404, 10 bytes)")[1] == "browser download"
assert doctor.classify_browser(1, "something nobody named")[1] == doctor.BROWSER_OTHER
for said in ("gemini-sfx: the soundtrack of take.mp4 is silent (-inf LUFS)", "gemini-sfx: Flow returned take.mp4 without a soundtrack",
             "gemini-sfx: the loudness of take-2.mp4 could not be measured"):
    assert doctor.classify_image(1, said)[1:] == ("bad output", "bad output", "ours"), (said, doctor.classify_image(1, said))


class Button:
    def __init__(self, dialog, name):
        self.dialog, self.name, self.first = dialog, name, self

    def count(self):
        return int(self.name in self.dialog.buttons)

    def is_visible(self):
        return True

    def click(self, timeout=None):
        self.dialog.page.pressed.append(self.name)
        self.dialog.open = False


class Dialog:
    def __init__(self, page, text, buttons):
        self.page, self.text, self.buttons, self.open = page, text, buttons, True

    def is_visible(self):
        return self.open

    def inner_text(self, timeout=None):
        return self.text

    def get_by_role(self, role, name, exact=True):
        assert role == "button" and exact, (role, exact)
        return Button(self, name)


class Dialogs:
    def __init__(self, items):
        self.items = items

    def count(self):
        return len(self.items)

    def nth(self, index):
        return self.items[index]


class Keyboard:
    def __init__(self, page):
        self.page = page

    def press(self, key):
        self.page.pressed.append(key)
        for dialog in self.page.dialogs:
            if dialog.open and not dialog.buttons:
                dialog.open = False


class PromoPage:
    url = "https://gemini.google.com/app?hl=en"

    def __init__(self):
        self.pressed, self.keyboard = [], Keyboard(self)
        self.dialogs = [Dialog(self, "Connect your apps\nYouTube, Google Drive and more", ["Connect", "Not now"]),
                        Dialog(self, "Make sure you have the necessary rights to any images", ["Agree", "Close"]),
                        Dialog(self, "Try Gemini in Chrome", [])]

    def locator(self, selector):
        assert selector == gw.DIALOGS, selector
        return Dialogs(self.dialogs)

    def wait_for_timeout(self, ms):
        pass


promo = PromoPage()
said = captured(lambda: gw.close_promos(promo, "egbogd"))
assert promo.pressed == ["Escape", "Not now"] and promo.dialogs[1].open, promo.pressed
assert "gemini-web: closed a dialog on egbogd: Connect your apps YouTube, Google Drive and more\n" in said, said
rows = [json.loads(line) for line in (gw.ROOT / "jobs.jsonl").read_text().splitlines()]
assert [(r["kind"], r["event"], r["account"], r["route"]) for r in rows[-2:]] == [
    ("dialog", "closed", "egbogd", "gemini-app")] * 2, rows[-2:]
assert gw.close_promos(promo, "egbogd") == 0 and promo.pressed == ["Escape", "Not now"]

import subprocess, tempfile, time
class CDP:
    def __init__(self, fail=None): self.sent, self.fail, self.detached = [], fail, False
    def send(self, method, params=None):
        if method == self.fail:
            raise RuntimeError("Target closed\n  details")
        self.sent.append((method, params))
        return {"windowId": 7} if method == "Browser.getWindowForTarget" else {}
    def detach(self): self.detached = True


class ParkContext:
    def __init__(self, cdp): self.cdp, self.pages = cdp, []
    def new_cdp_session(self, page):
        self.pages.append(page)
        return self.cdp


warned, real_warn = [], gw.warn
gw.warn = lambda account, reason, route=None: warned.append((account, reason))
cdp = CDP()
gw.park_window("com", ParkContext(cdp), "page-1")
assert cdp.sent == [("Browser.getWindowForTarget", None),
                    ("Browser.setWindowBounds", {"windowId": 7, "bounds": {"left": -30000, "top": -30000}})], cdp.sent
assert cdp.detached and warned == [], warned
gw.park_window("com", ParkContext(CDP(fail="Browser.setWindowBounds")), "page-2")
assert warned == [("com", "could not move the automation Chrome off screen: Target closed details")], warned
with tempfile.TemporaryDirectory() as scratch:
    prefs_path = gw.Path(scratch) / "Default" / "Preferences"
    gw.reset_exit_type("com", gw.Path(scratch))
    prefs_path.parent.mkdir()
    prefs = {"profile": {"exit_type": "Crashed", "name": "x"},
             "browser": {"window_placement": {"left": -1242, "top": 30, "right": 40, "bottom": 876}}}
    prefs_path.write_text(json.dumps(prefs))
    gw.reset_exit_type("com", gw.Path(scratch))
    after = json.loads(prefs_path.read_text())
    assert after["profile"] == {"exit_type": "Normal", "name": "x"} and after["browser"] == prefs["browser"], after
    assert sorted(p.name for p in prefs_path.parent.iterdir()) == ["Preferences"]
    stamp = prefs_path.stat().st_mtime_ns
    gw.reset_exit_type("com", gw.Path(scratch))
    assert prefs_path.stat().st_mtime_ns == stamp, "a clean profile was rewritten"
    prefs_path.write_text("{not json")
    gw.reset_exit_type("com", gw.Path(scratch))
    assert warned[-1][0] == "com" and warned[-1][1].startswith("could not mark the profile's last exit clean"), warned
gw.warn = real_warn
assert not hasattr(gw, "keep_hidden") and not hasattr(gw, "hide_clone") and not hasattr(gw, "HIDE_WATCH")

import time
killed, real_killpg, real_grace = [], gw.os.killpg, gw.FLUSH_GRACE_S
gw.os.killpg = lambda pid, sig: killed.append((pid, sig, time.time()))
gw.FLUSH_GRACE_S = 0.3
with tempfile.TemporaryDirectory() as scratch:
    profile = gw.Path(scratch)
    (profile / "Default").mkdir()
    flushed = [profile / "Default" / "Cookies", profile / "Default" / "Preferences"]
    def stale():
        for path in flushed:
            path.write_text("x")
            os.utime(path, (time.time() - 60, time.time() - 60))
    stale()
    with gw.reap_after_flush(profile, 4242):
        pass
    with gw.reap_after_flush(profile, None):
        flushed[0].touch(); flushed[1].touch()
        time.sleep(0.6)
    stale()
    with gw.reap_after_flush(profile, 4242):
        time.sleep(0.15)
        flushed[0].touch()
        time.sleep(0.6)
    time.sleep(0.2)
    assert killed == [], "killed before the close finished, without a flush, or with no pid: %r" % killed
    stale()
    with gw.reap_after_flush(profile, 4242):
        time.sleep(0.15)
        flushed[0].touch(); flushed[1].touch()
        touched = time.time()
        time.sleep(1.0)
    assert [k[:2] for k in killed] == [(4242, gw.signal.SIGKILL)], killed
    assert killed[0][2] - touched >= 0.3, "killed inside the grace"
gw.os.killpg, gw.FLUSH_GRACE_S = real_killpg, real_grace

real_run, real_popen = gw.subprocess.run, gw.subprocess.Popen
with tempfile.TemporaryDirectory() as scratch:
    clones = gw.Path(scratch) / "X" / f"{gw.CLONE_ID}.code_sign_clone"
    for name, age in (("code_sign_clone.OLD1", 3600), ("code_sign_clone.MAPPED", 3600), ("code_sign_clone.NEW", 60)):
        (clones / name).mkdir(parents=True)
        os.utime(clones / name, (time.time() - age, time.time() - age))
    browser = f"{gw.CLONE_APP}/Contents/MacOS/Google Chrome"
    calls, removed = [], []
    def fake_run(argv, **kw):
        calls.append(argv[0])
        out = {"getconf": f"{scratch}/T/\n",
               "ps": f"123 {browser} --user-data-dir=a\n124 {browser} --type=renderer\n999 /bin/zsh\n",
               "lsof": lsof_out}[argv[0]]
        if argv[0] == "lsof":
            assert argv[argv.index("-p") + 1] == "123", argv
        return gw.subprocess.CompletedProcess(argv, 0, out, "")
    gw.subprocess.run = fake_run
    gw.subprocess.Popen = lambda argv, **kw: removed.append(argv)
    stamp = gw.CLONE_ROOT / ".clone-sweep.stamp"
    stamp.unlink(missing_ok=True)
    lsof_out = f"p123\nn/private{clones}/code_sign_clone.MAPPED/Gemini Web Automation.app.bundle/Contents/MacOS/Google Chrome\n"
    gw.sweep_code_sign_clones()
    assert removed == [["rm", "-rf", "--", str(clones / "code_sign_clone.OLD1")]], removed
    calls.clear()
    removed.clear()
    gw.sweep_code_sign_clones()
    assert calls == [] and removed == [], ("swept again inside CLONE_SWEEP_MIN_AGE_S", calls, removed)
    os.utime(stamp, (time.time() - gw.CLONE_SWEEP_MIN_AGE_S - 5,) * 2)
    lsof_out = "p123\nn/usr/lib/dyld\n"
    gw.sweep_code_sign_clones()
    assert "lsof" in calls and removed == [], ("swept while a running browser's clone was unreadable", calls, removed)
    assert time.time() - stamp.stat().st_mtime < 60, "the sweep left its stamp aged"
    browser = "/Applications/Other.app/Contents/MacOS/Other"
    calls.clear()
    stamp.unlink()
    gw.sweep_code_sign_clones()
    assert "lsof" not in calls and len(removed) == 1 and removed[0][:3] == ["rm", "-rf", "--"] \
        and sorted(removed[0][3:]) == [str(clones / "code_sign_clone.MAPPED"), str(clones / "code_sign_clone.OLD1")], removed
gw.subprocess.run, gw.subprocess.Popen = real_run, real_popen
with tempfile.TemporaryDirectory() as scratch:
    lockdir = gw.Path(scratch)
    assert gw.chrome_pid(lockdir) is None
    (lockdir / "SingletonLock").symlink_to(f"host.local-{os.getpid()}")
    assert gw.chrome_pid(lockdir) == os.getpid() and gw.profile_in_use(lockdir)

# All candidates busy: an unpinned claim takes whichever frees first, not only the first in order; after a
# timed-out wait over all of them, each is refused without waiting again.
import fcntl, threading
def hold(*names):
    handles = {}
    for name in names:
        gw.lock_path(name).parent.mkdir(parents=True, exist_ok=True)
        handles[name] = open(gw.lock_path(name), "w")
        fcntl.flock(handles[name], fcntl.LOCK_EX)
    return handles
held = hold("busy-a", "busy-b")
threading.Timer(0.6, held["busy-b"].close).start()
started = time.monotonic()
picks = gw.claimed(["busy-a", "busy-b"], 8)
account, refusal = next(picks)
assert account == "busy-b" and refusal is None and time.monotonic() - started < 3, \
    (account, refusal, time.monotonic() - started)
picks.close()
assert not gw.busy("busy-b") and gw.busy("busy-a")
held = {**held, **hold("busy-b")}
waited = gw.lock_waited
refused = [(name, refusal.code) for name, refusal in gw.claimed(["busy-a", "busy-b"], 1.0)]
assert refused == [("busy-a", 5), ("busy-b", 5)] and gw.lock_waited - waited < 1.8, (refused, gw.lock_waited - waited)
for handle in held.values():
    handle.close()

class ToastPage:
    def __init__(self, url, texts): self.url, self.texts = url, texts
    def evaluate(self, script):
        assert "gwToasts" in script, script
        if self.texts is None: raise RuntimeError("Target page, context or browser has been closed")
        return self.texts
class ToastContext:
    def __init__(self, pages): self.pages = pages
before = len((gw.ROOT / "jobs.jsonl").read_text().splitlines())
gw.note_toasts(ToastContext([ToastPage("https://labs.google/fx/tools/flow", ["Not enough AI credits on this plan", "Copied"]),
                             ToastPage("about:blank", None),
                             ToastPage("https://labs.google/fx/tools/flow/project/x", ["Copied", "Video ready"])]), "egbogd")
gw.note_toasts(ToastContext([ToastPage("https://labs.google/fx/tools/flow", [])]), "egbogd")
logged = [json.loads(line) for line in (gw.ROOT / "jobs.jsonl").read_text().splitlines()][before:]
assert len(logged) == 1 and logged[0]["event"] == "toasts" and logged[0]["account"] == "egbogd" \
    and logged[0]["route"] == "flow" \
    and logged[0]["texts"] == ["Not enough AI credits on this plan", "Copied", "Video ready"], logged
assert "sessionStorage.setItem('gwToasts'" in gw.TOAST_LOG and "[role=alert]" in gw.TOAST_LOG
PY

assert python3 - "$ROOT" "$NOW" "$HOME" <<'PY'
import importlib.machinery, importlib.util, os, sys
root, now, home = sys.argv[1], int(sys.argv[2]), sys.argv[3]
loader = importlib.machinery.SourceFileLoader("doctor", os.path.join(root, "bin", "llm-doctor"))
spec = importlib.util.spec_from_loader("doctor", loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)
legs, _ = doctor.image_legs(now - 86400, now)
got = [(leg["model"], leg["attempt"], leg["class"], leg["reason"], leg["account"]) for leg in legs]
assert got == [
    ("gemini-music", "superseded", "failed", "browser owner step", "locomthebest"),
    ("gemini-music", "superseded", "walled", "walled", "com"),
    ("gemini-music", "final", None, "", ""),
    ("gemini-music", "final", "failed", "browser upload", "egbogd"),
    ("gemini-video", "final", "failed", "browser drift", "egbogd"),
    ("gemini-video", "final", "failed", "browser owner step", "locomthebest"),
    ("gemini-video", "superseded", "failed", "browser hide", "com"),
    ("gemini-video", "final", None, "", "com"),
    ("codex-image", "final", "failed", "browser drift", "work4")], got
assert doctor.excerpt_of(legs[-1]).startswith("browser route=chatgpt-web account=work4 shot=~/.chatgpt-web/failures/")
assert doctor.excerpt_of(legs[-1]).endswith(".png reason=ChatGPT UI drift: the composer never took the prompt")
upload = legs[3]
assert upload["ref"] == "image:%d/gemini-music/egbogd" % (now - 500) and legs[0]["ref"].endswith("/locomthebest#1")
assert upload["detail"] == "Upload files opened no file chooser"
excerpt = doctor.excerpt_of(upload)
assert excerpt.startswith("browser route=gemini-app account=egbogd shot=~/") and excerpt.endswith(
    "reason=Upload files opened no file chooser") and home not in excerpt, excerpt
PY

assert "$ROOT/bin/llm-doctor" --dry-run --json >"$WORK/doc.json"
assert jq -e '[.problems[] | select(.id | startswith("leg-failure:image/browser")) | .id] | sort
  == ["leg-failure:image/browser drift", "leg-failure:image/browser owner step", "leg-failure:image/browser upload"]' "$WORK/doc.json" >/dev/null
assert jq -e '.problems[] | select(.id == "leg-failure:image/browser upload")
  | .state == "new" and (.evidence[0].excerpt | test("shot=~/.*[.]png reason=Upload files"))' "$WORK/doc.json" >/dev/null
assert jq -e '[.problems[] | select(.id == "leg-failure:image/browser owner step") | .recovered] == [1]' "$WORK/doc.json" >/dev/null
# A ChatGPT drift joins the Flow one under the same cause, and its evidence names the snapshot the fixer opens.
assert jq -e '.problems[] | select(.id == "leg-failure:image/browser drift")
  | .value == 2 and ([.evidence[].excerpt | select(test("^browser route=chatgpt-web account=work4 shot=~/[.]chatgpt-web/failures/[^ ]+[.]png reason=ChatGPT UI drift"))] | length) == 1' \
  "$WORK/doc.json" >/dev/null
assert jq -e '[.problems[] | select(.id | startswith("leg-failure:image/browser")) | .group] == ["image", "image", "image"]
  and .groups.image == ([.problems[] | select(.group == "image" and (.state | IN("new", "open", "regressed")))] | length)
  and ([.groups[]] | add) == .problem_count' "$WORK/doc.json" >/dev/null
assert jq -e '[.problems[] | select(.id | test("codex-image|walled"))] == []' "$WORK/doc.json" >/dev/null

# The fixer of a browser word is sent to the engine that drives the page, not to the leg recorder.
export DOCTORS_DIR="$WORK/doctors" DOCTOR_FIX_PROJECTS="$WORK/projects" LLM_DOCTOR_REPOS="$WORK/projects" \
  DOCTOR_FIX_OPENER="$WORK/bin/opener" DOCTOR_FIX_WORKER_PICK="$WORK/bin/worker-pick" DOCTOR_FIX_DOCS="$WORK/docs"
mkdir -p "$WORK/projects" "$WORK/docs/handoffs" "$LLM_DOCTOR_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/bin/opener"
printf '#!/usr/bin/env bash\nprintf "acct-b\\n"\n' >"$WORK/bin/worker-pick"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/bin/claudeb"
chmod +x "$WORK/bin/opener" "$WORK/bin/worker-pick" "$WORK/bin/claudeb"
jq '.as_of_s = (now | floor) | .contract = 1' "$WORK/doc.json" >"$LLM_DOCTOR_DIR/latest.json"
assert bash "$ROOT/bin/doctor-fix" launch llm >"$WORK/fix.out"
run=$(sed -n 's/^llm fixer opened: run \(llm-[a-z]*-[0-9TZ]*-[0-9a-f]*\),.*/\1/p' "$WORK/fix.out")
assert test -n "$run"
assert jq -e --arg p "$WORK/projects" '.problems[] | select(.id == "leg-failure:image/browser upload") | .component
  | .files == ([$p + "/llm-legs/share/chatgpt_web.py", $p + "/llm-legs/share/flow_music.py", $p + "/llm-legs/share/gemini_music.py", $p + "/llm-legs/share/gemini_web.py", $p + "/llm-legs/share/image-leg.sh"])
    and (.what | startswith("hidden-Chrome route (Flow, the Gemini app, Flow Music, ChatGPT), step upload · image block"))' "$DOCTORS_DIR/runs/$run.json" >/dev/null

printf 'PASS: test_browser_failures (%s asserts)\n' "$asserts"
