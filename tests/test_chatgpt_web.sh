#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The ChatGPT web image route: share/chatgpt_web.py on gemini_web's hidden-Chrome core, and
# `codex-image --route web` in front of it. Playwright is faked; fixture stores only, under a temp HOME.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() {
  echo "FAIL: $*" >&2
  [ -z "${IMAGE_ERR:-}" ] || sed -n '1,40p' "$IMAGE_ERR" >&2
  exit 1
}
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then fail "assert $asserts unexpectedly succeeded: $*"; fi
}

REAL_MAGICK=$(command -v magick) || fail "magick is required for this suite"
UV_CACHE_DIR=${UV_CACHE_DIR:-$(uv cache dir 2>/dev/null)}
export UV_CACHE_DIR
export HOME="$WORK/home" PYTHONDONTWRITEBYTECODE=1
export CHATGPT_WEB_DIR="$WORK/home/.chatgpt-web" GEMINI_WEB_DIR="$WORK/home/.gemini-web"
export GEMINI_WEB_CHROME="$WORK/no-chrome.app"
export CODEX_PROFILES_DIR="$WORK/codex-profiles" CODEXB_PROFILES_DIR="$WORK/codex-profiles"
export WORKER_PICK_CONFIG_FILE="$WORK/pins" WORKER_CLAIMS_DIR="$WORK/claims" IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
mkdir -p "$HOME/.codex" "$CODEX_PROFILES_DIR"/{alpha,beta,gamma,acct} "$CODEX_PROFILES_DIR/.codexb" "$CHATGPT_WEB_DIR"
: >"$WORKER_PICK_CONFIG_FILE"

# --- the engine on a faked page ---------------------------------------------------------------------
assert python3 - "$ROOT/share" <<'EOF'
import argparse, base64, contextlib, io, json, os, re, sys, time, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import chatgpt_web as cw
import gemini_web
gw = cw.gw
chat_root, gemini_root = Path(os.environ["CHATGPT_WEB_DIR"]), Path(os.environ["GEMINI_WEB_DIR"])

# One hidden-Chrome core: the module, the clone app, its locks, the hide watcher, the snapshot path.
assert gw is gemini_web and gw.ROOT == chat_root and gw.ROUTE == "chatgpt-web"
assert gw.CLONE_ROOT == gemini_root and gw.CLONE_APP.parent == gemini_root, gw.CLONE_APP
app = Path(os.environ["HOME"]) / "Chrome.app"
(app / "Contents").mkdir(parents=True)
(app / "Contents" / "Info.plist").write_text('<?xml version="1.0"?><plist version="1.0"><dict>'
                                             '<key>CFBundleShortVersionString</key><string>9</string></dict></plist>')
gw.SOURCE_APP, built, real_build = app, [], gw.build_clone
gw.build_clone = lambda: built.append(1)
with gw.chrome_clone() as clone:
    assert clone == gw.CLONE_APP and built == [1]
assert (gemini_root / ".clone-use.lock").exists() and not (chat_root / ".clone-use.lock").exists()
assert not list(chat_root.glob("*.app")), list(chat_root.iterdir())
gw.build_clone = real_build
launched, real_popen = [], gw.subprocess.Popen
gw.subprocess.Popen = lambda argv, **kw: launched.append(argv) or "watcher"
assert gw.keep_hidden("alpha", 4242) == "watcher" and launched == [["osascript", "-e", gw.HIDE_WATCH, "4242"]]
gw.subprocess.Popen = real_popen
source = open(cw.__file__).read()
for own in ("def build_clone", "def chrome_clone", "HIDE_WATCH =", "TOAST_LOG =", "def snapshot", "def browser",
            "def keep_hidden", "CLONE_ID =", "launch_persistent_context"):
    assert own not in source, f"chatgpt_web.py carries its own {own}"
assert gw.route_of("https://chatgpt.com/c/x") == "chatgpt-web" and gw.route_of("https://auth.openai.com/") == "chatgpt-web"
assert gw.route_of("https://flow.google.com/x") == "flow"


class ShotPage:
    url = "https://chatgpt.com/c/0"
    def is_closed(self): return False
    def screenshot(self, path, timeout): open(path, "wb").write(b"\x89PNG")
    def evaluate(self, script): return {"title": "ChatGPT", "body": "text"}


shot = gw.snapshot(types.SimpleNamespace(pages=[ShotPage()]), "alpha", "x")
assert shot.startswith(str(chat_root / "failures") + "/"), shot

# The roster is the codex roster the menubar lists (share/account-roster.sh); a name outside it never gets a profile.
assert gw.roster() == ["main", "acct", "alpha", "beta", "gamma"], gw.roster()
try:
    cw.known_account("ghost")
    raise AssertionError("an account outside the codex roster was accepted")
except gw.Failure as failure:
    assert failure.code == 2 and "not on the codex roster" in failure.reason, failure.reason

# The image-limit text is a wall with its own end; text without a limit is none.
now = 1_790_000_000.0
assert cw.limit_until("You've hit the plus plan limit for image generations requests. You can create more images "
                      "when the limit resets in 23 hours and 21 minutes.", now) == now + 23 * 3600 + 21 * 60
assert cw.limit_until("Image generation limit reached. Please try again in 40 minutes.", now) == now + 2400
at = cw.limit_until("You've hit your image limit. Try again after 4:30 PM.", now)
local = time.localtime(at)
assert (local.tm_hour, local.tm_min) == (16, 30) and now < at <= now + 86400, local
assert cw.limit_until("You've reached your image generation limit. Try again later.", now) == now + gw.WALL_SECONDS
assert cw.limit_until("Here is your image with a speed limit sign.", now) is None
assert cw.limit_until("Here is the image you asked for.", now) is None
assert cw.mask_email("locomthebest@gmail.com") == "lo…@gmail.com" and cw.mask_email(None) is None
session = cw.Session(types.SimpleNamespace(on=lambda event, listener: None))
session.feed_plan({"accounts": [{"account_id": "x", "plan_type": "pro"}]})
assert session.plan == "pro", "the wham/accounts/check list shape"

# A team seat beside a free personal account: v4 keys the personal one "default", yet the page runs in
# the workspace its own requests name, and the plan is that one's, as the page displays it.
WS, PERSONAL = "ws-0001", "personal-0001"
wham = {"accounts": [{"id": WS, "structure": "workspace", "plan_type": "team"},
                     {"id": PERSONAL, "structure": "personal", "plan_type": "free"}], "default_account_id": WS}
v4 = {"accounts": {WS: {"account": {"account_id": WS, "plan_type": "team", "plan_display_name": "Business"}},
                   PERSONAL: {"account": {"account_id": PERSONAL, "plan_type": "free", "plan_display_name": "Free"}},
                   "default": {"account": {"account_id": PERSONAL, "plan_type": "free", "plan_display_name": "Free"}}}}
listeners = {}
session = cw.Session(types.SimpleNamespace(on=lambda event, listener: listeners.setdefault(event, listener)))
session.feed_plan(v4)
assert session.plan is None, session.plan
listeners["request"](types.SimpleNamespace(headers={"chatgpt-account-id": WS}))
listeners["request"](types.SimpleNamespace(headers={}))
assert session.plan == "business", session.plan
session = cw.Session(types.SimpleNamespace(on=lambda event, listener: None))
session.feed_plan(wham)
session.feed_plan(v4)
assert session.plan == "business", session.plan
session = cw.Session(types.SimpleNamespace(on=lambda event, listener: listeners.update({event: listener})))
session.feed_plan(v4)
session.feed_plan(wham)
listeners["request"](types.SimpleNamespace(headers={"chatgpt-account-id": PERSONAL}))
assert session.plan == "free", session.plan

PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 64
NEW_CHAT = "0b6f1d2e-1111-4222-8333-944455556666"
OLD_CHAT = "1c7a2b3d-aaaa-4bbb-8ccc-ddddeeeeffff"
KEY = {selector: key for key, selector in cw.SELECTORS.items()}


class Response:
    def __init__(self, url, body=None, status=200, raw=b""):
        self.url, self.body_json, self.status, self.raw = url, body, status, raw
    def json(self): return self.body_json
    def body(self): return self.raw


class Locator:
    def __init__(self, page, selector, index=None):
        self.page, self.key, self.index = page, KEY.get(selector, selector), index
    @property
    def first(self): return self
    @property
    def last(self): return self
    def nth(self, index): return Locator(self.page, self.key, index)
    def filter(self, has_text=None, visible=None):
        if has_text is None:
            return self
        return Locator(self.page, self.key, next(i for i, text in enumerate(self.page.menu) if has_text in text))
    def inner_text(self): return self.page.menu[self.index]
    def wait_for(self, timeout=None):
        if not self.count():
            raise TimeoutError(self.key)
    def bounding_box(self): return {"x": 100, "y": 100, "width": 400, "height": 300}
    def evaluate(self, script, arg):
        assert script is cw.ON_CANVAS and self.key in ("role:Draw on image", "role:Image comment surface"), script
        (x0, y0, x1, y1), (x, y) = self.page.overlay or (0, 0, 0, 0), arg
        return 100 <= x <= 500 and 100 <= y <= 400 and not (x0 <= x <= x1 and y0 <= y <= y1)
    def count(self):
        if self.key == "attachment":
            return len(self.page.files) + len(self.page.stale)
        if self.key == "remove":
            return len(self.page.stale)
        if self.key == "menu_item":
            return len(self.page.menu) if self.page.menu_open else 0
        if self.key == "comment_text":
            return int(self.page.comment_open)
        if self.key == "comment_pin":
            return len(self.page.pins)
        if self.key.startswith("role:"):
            return int(self.page.viewer)
        return int(self.page.shown.get(self.key, False))
    def get_attribute(self, name):
        return self.page.pressed if self.key == "chat_mode" and name == "aria-pressed" else None
    def hover(self, timeout=None): pass
    def is_visible(self): return self.page.viewer if self.key.startswith("role:") else self.page.shown.get(self.key, False)
    def is_enabled(self): return self.page.strokes > 0 if self.key == "role:Undo" else True
    def get_by_role(self, role, name=None, exact=False):
        assert (self.key, role, name, exact) == ("role:Image editing tools", "button", "Send", True), (role, name)
        return Locator(self.page, "role:Send")
    def set_input_files(self, path, timeout=None):
        self.page.events.append(("dead input", path))
    def click(self, timeout=None, force=False):
        self.page.events.append(("click", self.key) if self.index is None else ("pick", self.page.menu[self.index]))
        if self.key in ("preview", "attachment"):
            self.page.viewer = True
        if self.key == "role:Resize":
            self.page.menu_open = True
        if self.key == "role:Comment":
            self.page.commenting = True
        if self.key == "role:Send" or self.key == "role:Remove BG" and self.page.remove_bg_starts:
            self.page.sent = True
        if self.index is not None:
            self.page.sent = True
        if self.key == "remove":
            self.page.stale.pop()
        if self.key == "chat_mode":
            self.page.pressed = "true"
        if self.key == "add_files":
            self.page.upload_menu = True
        if self.key == "upload" and self.page.upload_menu and self.page.chooser_opens:
            self.page.upload_menu, self.page.chooser = False, Chooser(self.page)
        if self.key == "send":
            self.page.sent = True
            if "/c/" not in self.page.url:
                self.page.url = f"{cw.SITE}/c/{NEW_CHAT}"


class Chooser:
    def __init__(self, page): self.page = page
    def set_files(self, path, timeout=None):
        self.page.events.append(("file", path))
        self.page.files.append(path)


class Keyboard:
    def __init__(self, page): self.page = page
    def insert_text(self, text):
        self.page.events.append(("type", text))
        self.page.typed = text
    def press(self, key):
        self.page.events.append(("key", key))
        if key == "Enter" and self.page.comment_open:
            self.page.pins.append((self.page.pin_at, self.page.typed))
            self.page.comment_open = False


class Mouse:
    def __init__(self, page): self.page, self.down_at = page, None
    def move(self, x, y):
        self.page.points.append((round(x), round(y)))
    def click(self, x, y):
        self.page.events.append(("pin", (round(x), round(y))))
        if self.page.commenting and self.page.comment_opens:
            self.page.comment_open, self.page.pin_at = True, (round(x), round(y))
    def down(self): self.down_at = len(self.page.points)
    def up(self):
        self.page.events.append(("stroke", self.page.points[self.down_at - 1:]))
        self.page.strokes += int(self.page.draws)


class Page:
    def __init__(self, me=None, after=None, url_after_goto=None, me_status=200):
        self.url, self.events, self.files, self.sent, self.listeners = "about:blank", [], [], False, []
        self.stale, self.pressed = [], "true"
        self.upload_menu, self.chooser, self.chooser_opens = False, None, True
        self.shown = {"composer": True, "send": True, "chat_mode": True}
        self.me = {"email": "alpha@example.com", "name": "a"} if me is None else me
        self.me_status = me_status
        self.after = after or [{"replies": ["Here it is."], "images": [{"src": "https://chatgpt.com/backend-api/"
                                "estuary/content?id=file_new", "width": 1024, "height": 1024, "done": True}]}]
        self.url_after_goto, self.probes = url_after_goto, 0
        self.keyboard, self.mouse = Keyboard(self), Mouse(self)
        self.viewer, self.menu, self.menu_open, self.points, self.strokes, self.draws = False, [], False, [], 0, True
        self.overlay = None
        self.commenting, self.comment_opens, self.comment_open, self.pins, self.typed = False, True, False, [], None
        self.remove_bg_starts = True
    def on(self, event, listener): self.listeners.append(listener)
    def goto(self, url, **kw):
        self.events.append(("goto", url))
        self.url = self.url_after_goto or url
        for listener in self.listeners:
            listener(Response(f"{cw.SITE}/backend-api/conversation/init", {"x": 1}))
            listener(Response(f"{cw.SITE}/backend-api/me", self.me, status=self.me_status))
            listener(Response(f"{cw.SITE}/backend-api/accounts/check/v4-2023-04-27",
                              {"accounts": {"p1": {"account": {"account_id": "p1", "plan_type": "plus"}},
                                            "default": {"account": {"account_id": "p1", "plan_type": "plus"}}}}))
    def locator(self, selector): return Locator(self, selector)
    def get_by_role(self, role, name=None, exact=False):
        if (role, name) == ("button", cw.SELECTORS["chat_mode"]):
            return Locator(self, "chat_mode")
        if (role, name, exact) == ("button", cw.SELECTORS["add_files"], True):
            return Locator(self, "add_files")
        assert name in cw.EDITOR.values() and (exact or role in ("application", "toolbar")), (role, name)
        return Locator(self, f"role:{name}")
    def get_by_text(self, text, exact=False):
        assert (text, exact) == (cw.SELECTORS["upload"], True), (text, exact)
        return Locator(self, "upload")
    @contextlib.contextmanager
    def expect_file_chooser(self, timeout=None):
        self.chooser, event = None, types.SimpleNamespace()
        yield event
        if self.chooser is None:
            raise TimeoutError("no file chooser")
        event.value = self.chooser
    def wait_for_timeout(self, ms): pass
    def evaluate(self, script, arg=None):
        if script is cw.BLOB_READ:
            self.events.append(("blob", arg))
            return base64.b64encode(PNG).decode()
        assert script is cw.PAGE_PROBE and arg["image_src"] == cw.IMAGE_SRC, script
        old = {"src": "https://chatgpt.com/backend-api/estuary/content?id=file_old", "width": 1024, "height": 1024,
               "done": True}
        base = {"replies": ["an older reply"], "alerts": [], "images": [old], "streaming": False}
        if not self.sent:
            return base
        self.probes += 1
        step = self.after[min(self.probes, len(self.after)) - 1]
        return {**base, "replies": base["replies"] + step.get("replies", []), "alerts": step.get("alerts", []),
                "images": base["images"] + step.get("images", []), "streaming": step.get("streaming", False)}


class Request:
    def __init__(self): self.got = []
    def get(self, url, timeout=None):
        self.got.append(url)
        return Response(url, status=200, raw=PNG)


def fake_browser(page):
    context = types.SimpleNamespace(pages=[page], request=Request())

    @contextlib.contextmanager
    def browser(account, visible=False):
        page.context = context
        yield context
    return browser, context


def args(**kw):
    base = dict(prompt="a round blue badge", dest=str(chat_root / "out.png"), ref=[], resume=None, account=None,
                timeout=30, region=None, aspect=None, tool="generate", point=[])
    return types.SimpleNamespace(**{**base, **kw})


def render(page, meta=None, **kw):
    gw.browser, context = fake_browser(page)
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            return cw.render_on("alpha", args(**kw), meta or {"email": "alpha@example.com"}), context
    except gw.Failure as failure:
        return failure, context


def ledger():
    return [json.loads(line) for line in (chat_root / "jobs.jsonl").read_text().splitlines()]


# A new chat: the home page, the prompt typed and sent, the image saved from the src the page shows.
page = Page()
result, context = render(page)
assert page.events[0] == ("goto", cw.SITE + "/"), page.events
assert page.events[1:] == [("click", "composer"), ("key", "ControlOrMeta+A"), ("key", "Backspace"),
                           ("type", "a round blue badge"), ("click", "send")], page.events
assert result["chat"] == NEW_CHAT and result["url"] == f"{cw.SITE}/c/{NEW_CHAT}", result
assert result["format"] == "png" and (chat_root / "out.png").read_bytes() == PNG and result["plan"] == "plus", result
assert context.request.got == ["https://chatgpt.com/backend-api/estuary/content?id=file_new"], context.request.got
saved = ledger()[-1]
assert (saved["event"], saved["account"], saved["chat"], saved["resume"]) == ("saved", "alpha", NEW_CHAT, False), saved
assert gw.read_meta("alpha").get("plan") == "plus"

# Resume opens that chat itself, and the older image already in it is never taken for the new one.
page = Page(after=[{"streaming": True}, {"replies": ["Done."]}, {"images": [{"src": "https://chatgpt.com/"
            "backend-api/estuary/content?id=file_2", "width": 1536, "height": 1024, "done": True}]}])
result, context = render(page, resume=OLD_CHAT)
assert page.events[0] == ("goto", f"{cw.SITE}/c/{OLD_CHAT}"), page.events
assert result["chat"] == OLD_CHAT and context.request.got == ["https://chatgpt.com/backend-api/estuary/content?id=file_2"]
assert ledger()[-1]["resume"] is True and ledger()[-1]["chat"] == OLD_CHAT
page = Page(url_after_goto=cw.SITE + "/")
failure, _ = render(page, resume=OLD_CHAT)
assert isinstance(failure, gw.Failure) and failure.code == 1 and "is not on alpha any more" in failure.reason, failure

# The live gallery shows a blob: src; it is read inside the page, never fetched off it.
page = Page(after=[{"images": [{"src": "blob:https://chatgpt.com/3e515360-27fe-41b1-b637-e16f8f456583",
                                "width": 1374, "height": 1145, "done": True}]}])
result, context = render(page)
assert result["format"] == "png" and context.request.got == [], (result, context.request.got)
assert ("blob", "blob:https://chatgpt.com/3e515360-27fe-41b1-b637-e16f8f456583") in page.events, page.events

# Work mode is switched to Chat before anything is typed; Chat mode already on is left alone.
page = Page()
page.pressed = "false"
result, _ = render(page)
assert page.events[1] == ("click", "chat_mode") and result["ok"], page.events
assert ("click", "chat_mode") not in Page().events

# References go in one by one, in the caller's order, all before the prompt, after a stale draft is removed.
refs = [str(chat_root / f"ref-{index}.png") for index in (2, 1, 3)]
page = Page()
page.stale = ["left by a crashed run"]
result, _ = render(page, ref=refs)
assert [e[1] for e in page.events if e[0] == "file"] == refs and not page.stale, page.events
assert page.events.index(("click", "remove")) < page.events.index(("file", refs[0])), page.events
order = [e[0] for e in page.events]
assert order.index("type") > max(i for i, e in enumerate(order) if e == "file"), order
assert ledger()[-1]["refs"] == 3
# Each ref goes through the chooser the composer's own "+" menu opens; its image/* inputs drop a file set on them.
assert [e for e in page.events if e[0] == "dead input"] == [], page.events
assert all(page.events[i - 2:i] == [("click", "add_files"), ("click", "upload")]
           for i, e in enumerate(page.events) if e[0] == "file"), page.events
page = Page()
page.chooser_opens = False
failure, _ = render(page, ref=refs[:1])
assert isinstance(failure, gw.Failure) and "'Add photos & files' chooser" in failure.reason and not page.sent, failure

# The image-limit message is exit 3 with its own end, and the chat is still recorded for a resume.
page = Page(after=[{"replies": ["You've hit the plus plan limit for image generations requests. You can create more "
                                "images when the limit resets in 2 hours."]}])
before = time.time()
failure, _ = render(page)
assert isinstance(failure, gw.Failure) and failure.code == 3 and "image limit on alpha" in failure.reason, failure
assert before + 7200 - 5 <= failure.extra["until"] <= time.time() + 7200 + 5, failure.extra
assert ledger()[-1]["event"] == "failed" and ledger()[-1]["chat"] == NEW_CHAT and ledger()[-1]["code"] == 3
page = Page(after=[{"alerts": ["You've reached our image generation limit. Please try again later."]}])
failure, _ = render(page)
assert failure.code == 3, failure

# Signed out: /backend-api/me refused, the login page, or a Log in button is exit 4.
for page in (Page(me_status=403), Page(me_status=401), Page(url_after_goto="https://auth.openai.com/log-in")):
    failure, _ = render(page)
    assert isinstance(failure, gw.Failure) and failure.code == 4 and "codexb web alpha" in failure.reason, failure
page = Page()
page.shown["login"] = True
failure, _ = render(page)
assert failure.code == 4, failure
assert not any(e[0] == "type" for e in page.events), page.events
# has-text is a case-insensitive substring: a chat titled 'Log into Gmail' read as signed out.
login = cw.SELECTORS["login"]
assert "has-text" not in login and login.count(":text-is('Log in'):not(nav *, [data-message-author-role] *)") == 2, login

# A profile signed in as someone else is refused before anything is sent, without the full email.
page = Page()
failure, _ = render(page, meta={"email": "beta@example.com"})
assert failure.code == 1 and "al…@example.com" in failure.reason and "alpha@example.com" not in failure.reason, failure
assert not page.sent

# Only a refusal signs out: a 200 without an email or another status mid-load keeps the known login (live).
me = f"{cw.SITE}/backend-api/me"
session = cw.Session(types.SimpleNamespace(on=lambda event, listener: None))
session.pending = [Response(me, {"email": "alpha@example.com"}), Response(me, {}), Response(me, None, status=500)]
session.poll()
assert session.email == "alpha@example.com", session.email
session.pending = [Response(me, None, status=401)]
session.poll()
assert session.seen and session.email is None

# --region: the chat's last image opened in the viewer, a Markup outline drawn inside the canvas (never on
# its resizer edge), then the prompt typed into the composer Markup opened.
page = Page()
result, _ = render(page, resume=OLD_CHAT, region=(0.0, 0.5, 1.0, 0.5), prompt="recolor the table")
assert isinstance(result, dict), result.reason
clicks = [e for e in page.events if e[0] in ("click", "stroke", "type")]
assert clicks[:2] == [("click", "preview"), ("click", "role:Markup")], clicks
stroke = next(e[1] for e in page.events if e[0] == "stroke")
assert {stroke[0], max(stroke), min(stroke)} == {(116, 254), (484, 384)}, stroke
assert all(116 <= x <= 484 and 116 <= y <= 384 for x, y in stroke), stroke
assert page.events.index(("type", "recolor the table")) > max(i for i, e in enumerate(page.events) if e[0] == "stroke")
# A full-width image puts the Stroke width slider over a left corner: the stroke starts inward of it.
page = Page()
page.overlay = (100, 230, 150, 330)
result, _ = render(page, resume=OLD_CHAT, region=(0.0, 0.5, 1.0, 0.5), prompt="recolor the table")
stroke = next(e[1] for e in page.events if e[0] == "stroke")
assert isinstance(result, dict) and stroke[0] == (156, 254) and (116, 384) in stroke, stroke
page = Page()
page.draws = False
failure, _ = render(page, resume=OLD_CHAT, region=(0.0, 0.5, 1.0, 0.5))
assert failure.code == 1 and "took no stroke" in failure.reason and not page.sent, failure
page = Page()
result, _ = render(page, ref=[str(chat_root / "r.png")], region=(0.2, 0.2, 0.3, 0.3))
assert ("click", "attachment") in page.events and ("click", "preview") not in page.events, page.events
for bad in ("0,0,1", "0.5,0,0.6,1", "a,b,c,d", "0,0,0,1"):
    try:
        cw.region_arg(bad)
        raise AssertionError(bad)
    except argparse.ArgumentTypeError:
        pass

# Re-aspect: only a ratio the viewer's Resize lists is picked (a generation); any other is exit 2 with the list.
MENU = ["Square\n1:1", "Portrait\n3:4", "Story\n9:16", "Landscape\n4:3", "Widescreen\n16:9"]
page = Page()
page.menu = MENU
result, _ = render(page, resume=OLD_CHAT, prompt=None, aspect="9:16", tool="resize")
assert result["ok"] and ("pick", "Story\n9:16") in page.events, page.events
assert not any(e[0] == "type" for e in page.events), page.events
page = Page()
page.menu = MENU
failure, _ = render(page, resume=OLD_CHAT, prompt=None, aspect="2:3", tool="resize")
assert failure.code == 2 and failure.extra["offered"] == ["1:1", "3:4", "9:16", "4:3", "16:9"], failure
assert "1:1, 3:4, 9:16, 4:3, 16:9, not 2:3" in failure.reason and not page.sent, failure

# Point edits: Comment on, one pin per point placed off the resizer edge, each given its text and kept with
# Enter before the next, then the Comment toolbar's Send, the composer untouched.
POINTS = [(0.5, 0.2, "make the helmet orange"), (0.0, 1.0, "make the top green")]
page = Page()
result, _ = render(page, resume=OLD_CHAT, prompt=None, tool="comment", point=POINTS)
assert isinstance(result, dict), result.reason
steps = [e for e in page.events if e[0] in ("click", "pin", "type", "key") and e[1] != "role:Close viewer"]
assert steps == [("click", "preview"), ("click", "role:Comment"), ("pin", (300, 160)), ("type", "make the helmet orange"),
                 ("key", "Enter"), ("pin", (116, 384)), ("type", "make the top green"), ("key", "Enter"),
                 ("click", "role:Send")], steps
assert page.pins == [((300, 160), "make the helmet orange"), ((116, 384), "make the top green")], page.pins
# The toolbar over the image's foot: a pin there moves up off it, never clicks the toolbar.
page = Page()
page.overlay = (100, 370, 500, 400)
result, _ = render(page, resume=OLD_CHAT, prompt=None, tool="comment", point=[(0.5, 1.0, "the shoes red")])
assert isinstance(result, dict) and page.pins == [((300, 368), "the shoes red")], page.pins
page = Page()
page.comment_opens = False
failure, _ = render(page, resume=OLD_CHAT, prompt=None, tool="comment", point=POINTS)
assert failure.code == 1 and "comment 1 opened no text box" in failure.reason and not page.sent, failure
page = Page()
result, _ = render(page, ref=[str(chat_root / "r.png")], prompt=None, tool="comment", point=POINTS)
assert ("click", "attachment") in page.events and ("click", "preview") not in page.events, page.events
assert cw.point_arg("0.25,1=  the sky  ") == (0.25, 1.0, "the sky")
for bad in ("0.5,0.5", "0.5,0.5=", "1.1,0=x", "a,b=x", "0.5=x"):
    try:
        cw.point_arg(bad)
        raise AssertionError(bad)
    except argparse.ArgumentTypeError:
        pass

# Remove BG: one click in the viewer of the chat's last image or the one ref, nothing typed (it drops a draft).
page = Page()
result, _ = render(page, resume=OLD_CHAT, prompt=None, tool="remove-bg")
assert isinstance(result, dict) and ("click", "role:Remove BG") in page.events, page.events
assert page.events.index(("click", "preview")) < page.events.index(("click", "role:Remove BG")), page.events
assert not any(e[0] in ("type", "pin") for e in page.events), page.events
page = Page()
result, _ = render(page, ref=[str(chat_root / "r.png")], prompt=None, tool="remove-bg")
assert isinstance(result, dict) and ("click", "attachment") in page.events, page.events
page = Page()
page.remove_bg_starts = False
page.viewer = True
try:
    cw.remove_background(page, cw.probe(page), wait_s=0.3)
    raise AssertionError("a Remove BG that started nothing passed")
except gw.Failure as failure:
    assert failure.code == 1 and "Remove BG started nothing" in failure.reason, failure
EOF

# --- bounded teardown: Chrome's stdio off Playwright's pipes, a hung close killed, stacks on SIGTERM -----
assert python3 - "$ROOT/share" <<'EOF'
import contextlib, os, signal, subprocess, sys, tempfile, threading, time, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import chatgpt_web as cw
gw = cw.gw
work = Path(tempfile.mkdtemp())

# A child that outlives Chrome (GoogleUpdater --wake-all) keeps no pipe of the launcher's open.
fake = work / "chrome"
fake.write_text('#!/bin/sh\necho "$$ $*" >"$0.pid"\necho noise; echo noise >&2\nsleep 8 &\nexit 0\n')
fake.chmod(0o755)
wrapper = gw.quiet_chrome(str(fake), "alpha")
assert wrapper == str(gw.ROOT / "logs" / "alpha-chrome.sh"), wrapper
proc = subprocess.Popen([wrapper, "--flag", "two words"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
started = time.time()
out, err = proc.communicate(timeout=10)
assert time.time() - started < 5 and out == b"" and err == b"", (time.time() - started, out, err)
assert (work / "chrome.pid").read_text().split(" ", 1) == [str(proc.pid), "--flag two words\n"]
assert (gw.ROOT / "logs" / "alpha-chrome.log").read_text() == "noise\nnoise\n"
assert gw.quiet_chrome(str(fake), "alpha") == wrapper and os.access(wrapper, os.X_OK)

killed, launches, hang = [], [], threading.Event()
released = threading.Event()


class Context:
    pages = []
    def add_init_script(self, script): pass
    def on(self, event, listener): pass
    def close(self):
        if hang.is_set():
            if not released.wait(5):
                raise SystemExit("teardown unbounded: context.close was never released")
            raise RuntimeError("Connection closed")


class Chromium:
    def launch_persistent_context(self, profile, executable_path, **kw):
        launches.append(executable_path)
        return Context()


@contextlib.contextmanager
def sync_playwright():
    yield types.SimpleNamespace(chromium=Chromium())


api = types.ModuleType("playwright.sync_api")
api.sync_playwright = sync_playwright
sys.modules["playwright"], sys.modules["playwright.sync_api"] = types.ModuleType("playwright"), api


class Watcher:
    def __init__(self): self.calls = []
    def terminate(self): self.calls.append("terminate")
    def kill(self): self.calls.append("kill")
    def wait(self, timeout):
        self.calls.append("wait")
        if "kill" not in self.calls:
            raise subprocess.TimeoutExpired("osascript", timeout)


watchers = []
gw.refuse_off_roster = lambda account: None
gw.has_login = lambda account: True
gw.profile_in_use = lambda profile: False
gw.chrome_clone = lambda: contextlib.nullcontext(work / "Clone.app")
gw.chrome_pid = lambda profile: 4242
gw.parent_pid = lambda pid: {4242: 777, 777: os.getpid()}.get(pid)
gw.hide_clone = lambda *args: None
gw.keep_hidden = lambda account, pid: watchers.append(Watcher()) or watchers[-1]
gw.TEARDOWN_S = 0.3
real_kill, real_killpg = os.kill, os.killpg


def fake_kill(name):
    def kill(pid, sig):
        killed.append((name, pid, sig))
        if name == "kill" and pid == 777:
            released.set()
    return kill


os.kill, os.killpg = fake_kill("kill"), fake_kill("killpg")
saved, captured = os.dup(2), tempfile.TemporaryFile()
os.dup2(captured.fileno(), 2)
try:
    with gw.browser("alpha"):
        pass
    time.sleep(0.6)
    calm = list(killed)
    hang.set()
    started = time.time()
    with gw.browser("alpha"):
        pass
    took = time.time() - started
finally:
    os.dup2(saved, 2)
    os.kill, os.killpg = real_kill, real_killpg
captured.seek(0)
err = captured.read().decode()
assert launches == [str(gw.ROOT / "logs" / "alpha-chrome.sh")] * 2, launches
assert calm == [], f"a prompt close still killed {calm}"
assert took < 3, f"a hung close held the run {took:.1f}s"
assert ("killpg", 4242, signal.SIGKILL) in killed and ("kill", 777, signal.SIGKILL) in killed, killed
assert "BROWSER_WARNING" in err and "closing the browser still running" in err, err
assert "in browser" in err and "File " in err, err
assert [w.calls for w in watchers] == [["terminate", "wait", "kill", "wait"]] * 2, [w.calls for w in watchers]

# A SIGTERM-killed engine names where it hung, and still dies by the signal.
probe = subprocess.Popen([sys.executable, "-c", f"""
import sys, time
sys.path.insert(0, {sys.argv[1]!r})
import gemini_web
def hung_teardown():
    print("ready", flush=True)
    time.sleep(30)
hung_teardown()
"""], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert probe.stdout.readline() == "ready\n"
probe.send_signal(signal.SIGTERM)
_, err = probe.communicate(timeout=10)
assert probe.returncode == -signal.SIGTERM and "hung_teardown" in err, (probe.returncode, err)
EOF

# --- rotation, walls, resume ownership --------------------------------------------------------------
assert python3 - "$ROOT/share" "$CODEXB_PROFILES_DIR/.codexb/disabled" <<'EOF'
import argparse, contextlib, fcntl, io, json, os, sys, time
sys.path.insert(0, sys.argv[1])
import chatgpt_web as cw
gw = cw.gw
disabled = sys.argv[2]
for name in ("alpha", "beta", "gamma", "stray"):
    (gw.ROOT / "profiles" / name / "Default").mkdir(parents=True, exist_ok=True)
    (gw.ROOT / "profiles" / name / "Default" / "Cookies").write_text("")
for name in ("alpha", "beta", "stray"):
    gw.write_meta(name, email=f"{name}@example.com")
(gw.ROOT / "jobs.jsonl").unlink(missing_ok=True)
assert gw.bound_accounts() == ["alpha", "beta"], gw.bound_accounts()
gw.ledger({"kind": cw.KIND, "event": "saved", "account": "beta", "chat": "c-b"})
real_render_on, cw.render_on = cw.render_on, lambda account, args, meta: {"ok": True, "account": account}
cw.generate_on("alpha", argparse.Namespace(resume="c-a"))
assert "generation_started_at" not in gw.read_meta("alpha"), "a resume stamped a new generation"
cw.generate_on("alpha", argparse.Namespace(resume=None))
assert gw.read_meta("alpha")["generation_started_at"] >= time.time() - 60, gw.read_meta("alpha")
cw.render_on = real_render_on
assert cw.rotation() == ["beta", "alpha"], "ordered by the jobs ledger, not the least recent start"
gw.set_wall("beta", time.time() + 3600)
assert cw.rotation() == ["alpha"], cw.rotation()
gw.set_wall("beta", None)
(gw.ROOT / "locks").mkdir(exist_ok=True)
with open(gw.ROOT / "locks" / "beta.lock", "w") as held:
    fcntl.flock(held, fcntl.LOCK_EX)
    assert cw.rotation() == ["alpha", "beta"], cw.rotation()
open(disabled, "w").write("alpha\n")
gw._pool = None
assert cw.rotation() == ["beta"], cw.rotation()
open(disabled, "w").write("")
gw._pool = None

CHAT = "0b6f1d2e-1111-4222-8333-944455556666"
tried = []


def run(behaviour, **kw):
    tried.clear()

    def fake(account, args):
        tried.append(account)
        return behaviour(account)
    cw.generate_on = fake
    ns = argparse.Namespace(**{**dict(prompt="x", dest=str(gw.ROOT / "o.png"), ref=[], resume=None, account=None,
                                      timeout=30, region=None, tool="generate", point=[]), **kw})
    try:
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            cw.cmd_generate(ns)
    except gw.Failure as failure:
        return failure.code, failure.reason
    return 0, json.loads(out.getvalue())


def ok(account):
    return {"ok": True, "account": account, "chat": CHAT}


until = int(time.time()) + 5000


def first_walled(account):
    if account == "beta":
        raise gw.Failure(3, "ChatGPT image limit on beta: try again in 1 hour", until=until)
    return ok(account)


code, out = run(first_walled)
assert code == 0 and tried == ["beta", "alpha"] and out["account"] == "alpha", (code, tried, out)
assert gw.walls()["beta"] == until, gw.walls()
code, out = run(ok)
assert tried == ["alpha"], tried
gw.set_wall("beta", None)


def signed_out(account):
    raise gw.Failure(4, f"ChatGPT shows {account} signed out; run: codexb web {account}")


code, reason = run(signed_out)
assert code == 4 and tried == ["beta", "alpha"] and not gw.walls().get("beta"), (code, tried, gw.walls())


def all_walled(account):
    raise gw.Failure(3, f"ChatGPT image limit on {account}")


code, reason = run(all_walled)
assert code == 3 and tried == ["beta", "alpha"] and gw.walls().get("alpha", 0) > time.time() + gw.WALL_SECONDS - 60
code, reason = run(ok)
assert code == 3 and tried == [] and "walled by its image limit" in reason, (code, reason)
code, reason = run(ok, account="alpha")
assert code == 3 and tried == [] and "alpha is walled" in reason, (code, reason)
gw.set_wall("alpha", None)
gw.set_wall("beta", None)

code, reason = run(ok, account="ghost")
assert code == 2 and tried == [], reason
code, reason = run(ok, resume="not-a-chat")
assert code == 2 and "chat=" in reason, reason
code, reason = run(ok, resume=CHAT)
assert code == 2 and "pass --account" in reason and tried == [], reason
gw.ledger({"kind": cw.KIND, "event": "saved", "account": "beta", "chat": CHAT})
code, out = run(ok, resume=CHAT)
assert code == 0 and tried == ["beta"], (code, tried)
code, reason = run(ok, resume=CHAT, account="alpha")
assert code == 2 and "lives on beta" in reason and tried == [], reason
code, reason = run(ok, ref=["relative.png"])
assert code == 2 and tried == [], reason
for tool in ("comment", "remove-bg"):
    code, reason = run(ok, tool=tool)
    assert code == 2 and f"{tool} edits one image" in reason and tried == [], reason
    code, reason = run(ok, tool=tool, resume=CHAT, ref=[str(gw.ROOT / "o.png")])
    assert code == 2 and tried == [], reason

open(disabled, "w").write("alpha\nbeta\n")
gw._pool = None
code, reason = run(ok)
assert code == 4 and "out of the codex worker pool" in reason, reason
code, reason = run(ok, account="alpha")
assert code == 4 and "out of the codex worker pool" in reason and tried == [], reason
open(disabled, "w").write("")
gw._pool = None
for name in ("alpha", "beta"):
    os.unlink(gw.ROOT / "accounts" / f"{name}.json")
code, reason = run(ok)
assert code == 4 and "no ChatGPT account is signed in" in reason, reason
EOF

engine_rc() { python3 "$ROOT/share/chatgpt_web.py" "$@" >"$WORK/engine.out" 2>"$WORK/engine.err"; printf '%s' "$?"; }
assert test "$(engine_rc generate --prompt x --dest "$WORK/x.png" --account nologin)" = 2
assert test "$(engine_rc generate --prompt x --dest "$WORK/x.png" --account acct)" = 4
assert jq -e '.code == 4 and (.reason | test("codexb web acct"))' "$WORK/engine.out" >/dev/null
assert grep -q '^BROWSER_FAILURE route=chatgpt-web account=acct code=4 ' "$WORK/engine.err"
for sub in "generate --prompt x" "resize --resume c1 --aspect 1:1" "comment --point 0.5,0.5=x" "remove-bg"; do
  assert test "$(engine_rc $sub --dest "$WORK/x.png" --account "")" = 2
  assert grep -q "needs a profile name" "$WORK/engine.err"
  assert test ! -s "$WORK/engine.out"
done
assert test "$(engine_rc login ghost)" = 2
assert test ! -e "$CHATGPT_WEB_DIR/profiles/ghost"
# A signed-in, bound profile the codex roster does not list is refused by name, never run.
assert test "$(engine_rc generate --prompt x --dest "$WORK/x.png" --account stray)" = 2
assert jq -e '.code == 2 and (.reason | test("unknown account: stray"))' "$WORK/engine.out" >/dev/null
assert test "$(engine_rc status stray)" = 2
# Removing codex main writes its marker; main leaves the roster with ~/.codex still on disk.
: >"$HOME/.llm-limits-codex.json.removed"
assert test "$(engine_rc generate --prompt x --dest "$WORK/x.png" --account main)" = 2
assert jq -e '.reason | test("unknown account: main")' "$WORK/engine.out" >/dev/null
assert test -d "$HOME/.codex"
rm -f "$HOME/.llm-limits-codex.json.removed"
assert test "$(engine_rc accounts)" = 0
assert jq -e '[.accounts[].account] == ["main", "acct", "alpha", "beta", "gamma"]' "$WORK/engine.out" >/dev/null
assert_fails grep -q '@example.com' "$WORK/engine.out"

# --- login --wait, the step `<vendor>b web` holds on (both engines, one gw.cmd_login) -----------------
# The fake Chrome exits at once and leaves its profile lock with a process that lives 3 s, as a real
# one handing its window to a running Chrome does: the wait ends only when that process is gone.
LOGIN_APP="$WORK/login-chrome.app"
mkdir -p "$LOGIN_APP/Contents/MacOS"
cat >"$LOGIN_APP/Contents/MacOS/Google Chrome" <<'EOF'
#!/usr/bin/env bash
profile=${1#--user-data-dir=}
sleep 3 </dev/null >/dev/null 2>&1 &
ln -sfn "host-$!" "$profile/SingletonLock"
EOF
chmod +x "$LOGIN_APP/Contents/MacOS/Google Chrome"
for engine in "gemini_web main" "chatgpt_web alpha"; do
  set -- $engine
  started=$SECONDS
  login_out=$(GEMINI_WEB_CHROME="$LOGIN_APP" python3 "$ROOT/share/$1.py" login --wait "$2" 2>"$WORK/login.err")
  assert test "$?" -eq 0
  assert test "$((SECONDS - started))" -ge 3
  assert jq -e --arg account "$2" '.ok and .account == $account and (.login | type) == "boolean"' <<<"$login_out" >/dev/null
  assert grep -q "sign $2 in in the Chrome window that opened, then quit it with Cmd+Q" "$WORK/login.err"
done

# --- codex-image --route web ------------------------------------------------------------------------
FAKE_WEB="$WORK/fake-chatgpt-web"
WEB_CALLS="$WORK/web-calls"
CLI_CALLS="$WORK/cli-calls"
export WEB_CALLS CLI_CALLS REAL_MAGICK
cat >"$FAKE_WEB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$WEB_CALLS"
dest=''
while [ "$#" -gt 0 ]; do case "$1" in --dest) dest=$2; shift 2 ;; *) shift ;; esac; done
chat=0b6f1d2e-1111-4222-8333-944455556666
case "${WEB_MODE:-ok}" in
  ok) "$REAL_MAGICK" -size 64x48 'xc:#00FF00' -fill blue -draw 'circle 32,24 32,10' "PNG24:$dest" ;;
  alpha) "$REAL_MAGICK" -size 64x48 xc:none -fill blue -draw 'circle 32,24 32,10' "PNG32:$dest" ;;
  limit) printf '{"ok": false, "code": 3, "reason": "ChatGPT image limit on alpha: resets in 2 hours", "account": "alpha"}\n'; exit 3 ;;
  login) printf '{"ok": false, "code": 4, "reason": "no ChatGPT account is signed in; run: codexb web <account>"}\n'; exit 4 ;;
  usage) printf '{"ok": false, "code": 2, "reason": "chat x lives on beta, not alpha"}\n'; exit 2 ;;
  drift) printf '{"ok": false, "code": 1, "reason": "ChatGPT UI drift: no composer", "account": "alpha"}\n'; exit 1 ;;
  empty) printf '{"ok": true, "account": "alpha", "chat": "%s"}\n' "$chat"; exit 0 ;;
  offers) printf '{"ok": false, "code": 2, "reason": "the viewer'"'"'s Resize offers 1:1, 3:4, 9:16, 4:3, 16:9, not 2:3"}\n'; exit 2 ;;
esac
printf '{"ok": true, "account": "alpha", "chat": "%s", "format": "png"}\n' "$chat"
EOF
chmod +x "$FAKE_WEB"
cat >"$WORK/fake-codex" <<'EOF'
#!/usr/bin/env bash
printf 'cli\n' >>"$CLI_CALLS"
cat >"$CLI_CALLS.prompt"
exit 1
EOF
chmod +x "$WORK/fake-codex"
OUT="$WORK/out"
mkdir -p "$OUT"
printf 'r\n' >"$WORK/r1.png"
printf 'r\n' >"$WORK/r2.png"
IMAGE_OUT="$WORK/image.out"
IMAGE_ERR="$WORK/image.err"
image_rc() {
  rm -f "$WEB_CALLS" "$CLI_CALLS"
  env CODEX_IMAGE_WEB="$FAKE_WEB" CODEX_IMAGE_CODEX="$WORK/fake-codex" TMPDIR="$WORK" \
    bash "$ROOT/bin/codex-image" "$@" >"$IMAGE_OUT" 2>"$IMAGE_ERR"
  printf '%s' "$?"
}

assert test "$(image_rc --dest "$OUT/a.png" --prompt badge --route nope)" = 2
assert test ! -e "$WEB_CALLS"
assert test "$(image_rc --dest "$OUT/a.png" --prompt badge --route web --resume my-thread)" = 2
assert test ! -e "$WEB_CALLS"
assert test "$(image_rc --dest "$OUT/a.png" --prompt badge --account acct)" = 1
assert test -s "$CLI_CALLS"
assert test ! -e "$WEB_CALLS"
assert jq -se '.[-1] | .tool == "codex-image" and .route == "cli"' "$IMAGE_LEG_LOG" >/dev/null

CHAT=1c7a2b3d-aaaa-4bbb-8ccc-ddddeeeeffff
assert test "$(image_rc --route web --dest "$OUT/a.png" --prompt 'a round badge' --ref "$WORK/r1.png" \
  --ref "$WORK/r2.png" --resume "$CHAT" --account alpha --size 512x512)" = 0
assert test ! -e "$CLI_CALLS"
assert test "$(sed -n 1p "$WEB_CALLS")" = generate
assert test "$(grep -n -x -- --ref "$WEB_CALLS" | wc -l | tr -d ' ')" = 2
assert test "$(grep -A1 -x -- --ref "$WEB_CALLS" | grep -v -x -- --ref | grep -v -x -- -- | tr '\n' ' ')" = "$WORK/r1.png $WORK/r2.png "
assert grep -A1 -x -- --resume "$WEB_CALLS" | grep -qx "$CHAT"
assert grep -A1 -x -- --account "$WEB_CALLS" | grep -qx alpha
assert grep -qx 'Make the image exactly 512x512 pixels.' "$WEB_CALLS"
assert grep -qx 'a round badge' "$WEB_CALLS"
assert grep -qx "dest=$OUT/a.png" "$IMAGE_OUT"
assert grep -qx 'size=64x48' "$IMAGE_OUT"
assert grep -qx 'account=alpha' "$IMAGE_OUT"
assert grep -qx 'session=0b6f1d2e-1111-4222-8333-944455556666' "$IMAGE_OUT"
assert grep -qx 'route=web' "$IMAGE_OUT"
assert grep -q '^model=' "$IMAGE_OUT"
assert_fails grep -q '^caps=' "$IMAGE_OUT"
assert jq -se '.[-1] | .tool == "codex-image" and .route == "web" and .rc == 0 and .account == "alpha" and .size == 3' \
  "$IMAGE_LEG_LOG" >/dev/null

assert test "$(image_rc --route web --dest "$OUT/b.jpg" --prompt badge)" = 0
assert grep -qx 'format=jpeg' "$IMAGE_OUT"
assert_fails grep -qx -- --account "$WEB_CALLS"
assert_fails grep -qx -- --resume "$WEB_CALLS"
assert test "$(WEB_MODE=alpha image_rc --route web --dest "$OUT/t.png" --prompt 'a transparent badge' --transparent)" = 0
assert grep -q 'genuinely transparent background' "$WEB_CALLS"
assert grep -q 'Only if real transparency is impossible' "$WEB_CALLS"
assert test "$("$REAL_MAGICK" "$OUT/t.png" -alpha extract -format '%[fx:minima]' info:)" = 0

assert test "$(WEB_MODE=limit image_rc --route web --dest "$OUT/l.png" --prompt badge)" = 3
assert grep -qx CODEX_USAGE_LIMIT "$IMAGE_ERR"
assert grep -q 'resets in 2 hours' "$IMAGE_ERR"
assert test "$(WEB_MODE=login image_rc --route web --dest "$OUT/l.png" --prompt badge)" = 4
assert grep -q 'codexb web' "$IMAGE_ERR"
assert test "$(WEB_MODE=usage image_rc --route web --dest "$OUT/l.png" --prompt badge)" = 2
assert test "$(WEB_MODE=drift image_rc --route web --dest "$OUT/l.png" --prompt badge)" = 1
assert_fails grep -q CODEX_USAGE_LIMIT "$IMAGE_ERR"
assert test "$(WEB_MODE=empty image_rc --route web --dest "$OUT/l.png" --prompt badge)" = 1
assert grep -q 'saved no image' "$IMAGE_ERR"
assert test ! -e "$OUT/l.png"

# One sentence builder: --aspect and --transparent reach both routes in the same words.
assert test "$(image_rc --route web --dest "$OUT/p.png" --prompt badge --aspect 16:9 --transparent)" = 0
awk 'f && /^--dest$/ {exit} f {print} /^$/ {f=1}' "$WEB_CALLS" >"$WORK/web-sentences"
assert grep -qx 'Make the image a 16:9 landscape frame: its width to height ratio exactly 16:9.' "$WORK/web-sentences"
assert grep -q '^Give it a genuinely transparent background' "$WORK/web-sentences"
assert test "$(image_rc --dest "$OUT/p.png" --prompt badge --aspect 16:9 --transparent --account acct)" = 1
while IFS= read -r sentence; do
  assert grep -Fqx -- "$sentence" "$CLI_CALLS.prompt"
done <"$WORK/web-sentences"
assert test "$(image_rc --route web --dest "$OUT/p.png" --prompt badge --aspect 2.39:1)" = 0
assert grep -qx 'Make the image a 2.39:1 landscape frame: its width to height ratio exactly 2.39:1.' "$WEB_CALLS"

# The delivered ratio is checked and printed; a miss is reported, the image kept as generated (64x48).
assert test "$(image_rc --route web --dest "$OUT/p.png" --prompt badge --aspect 4:3)" = 0
assert grep -qx 'aspect=4:3 achieved=1.333 fit=ok' "$IMAGE_OUT"
assert test "$(image_rc --route web --dest "$OUT/p.png" --prompt badge --aspect 16:9)" = 0
assert grep -qx 'aspect=16:9 achieved=1.333 fit=miss' "$IMAGE_OUT"
assert grep -qx 'size=64x48' "$IMAGE_OUT"
assert grep -q 'kept as generated' "$IMAGE_ERR"
assert test "$(image_rc --route web --dest "$OUT/p.png" --prompt badge --aspect 16:9 --size 64x48)" = 2

# --region is web-only, never prose on the CLI; on the web it edits one image (a chat's last or one ref).
assert test "$(image_rc --dest "$OUT/p.png" --prompt badge --resume "$CHAT" --region 0,0.5,1,0.5 --account acct)" = 2
assert grep -q 'web-only.*pass --route web' "$IMAGE_ERR"
assert test "$(wc -l <"$IMAGE_ERR" | tr -d ' ')" = 1
assert test ! -e "$CLI_CALLS"
assert test "$(image_rc --route web --dest "$OUT/p.png" --prompt badge --region 0,0.5,1,0.5)" = 2
assert test "$(image_rc --route web --dest "$OUT/p.png" --prompt badge --resume "$CHAT" --region 0,0.6,1,0.5)" = 2
assert test ! -e "$WEB_CALLS"
assert test "$(image_rc --route web --dest "$OUT/p.png" --prompt 'recolor the table' --resume "$CHAT" --region 0,0.5,1,0.5)" = 0
assert grep -A1 -x -- --region "$WEB_CALLS" | grep -qx 0,0.5,1,0.5
assert grep -q '^Change only the area outlined in red' "$WEB_CALLS"

# Re-aspect (--resume + --aspect, no --prompt) goes to the viewer's Resize on the web only; a ratio it does
# not list comes back as exit 2 with the list.
assert test "$(image_rc --dest "$OUT/p.png" --resume "$CHAT" --aspect 1:1 --account acct)" = 2
assert grep -q 'web-only' "$IMAGE_ERR"
assert test ! -e "$CLI_CALLS"
assert test "$(image_rc --route web --dest "$OUT/p.png" --resume "$CHAT" --aspect 1:1)" = 0
assert test "$(sed -n 1p "$WEB_CALLS")" = resize
assert grep -A1 -x -- --aspect "$WEB_CALLS" | grep -qx 1:1
assert_fails grep -qx -- --prompt "$WEB_CALLS"
assert test "$(WEB_MODE=offers image_rc --route web --dest "$OUT/p.png" --resume "$CHAT" --aspect 2:3)" = 2
assert grep -q 'offers 1:1, 3:4, 9:16, 4:3, 16:9, not 2:3' "$IMAGE_ERR"
assert test "$(image_rc --route web --dest "$OUT/p.png" --resume "$CHAT" --aspect 1:1 --composite)" = 2
assert grep -q 'a re-aspect changes the canvas.*no --composite' "$IMAGE_ERR"
assert test ! -e "$WEB_CALLS"

# --point: Comment pins, web-only like --region; every point reaches the engine in order, a note only if given.
assert test "$(image_rc --dest "$OUT/p.png" --resume "$CHAT" --point '0.5,0.2=orange helmet' --account acct)" = 2
assert grep -q -- '--point is web-only.*pass --route web' "$IMAGE_ERR"
assert test "$(wc -l <"$IMAGE_ERR" | tr -d ' ')" = 1
assert test ! -e "$CLI_CALLS"
assert test "$(image_rc --route web --dest "$OUT/p.png" --point '0.5,0.2=orange helmet')" = 2
assert test "$(image_rc --route web --dest "$OUT/p.png" --resume "$CHAT" --point '0.5,1.2=x')" = 2
assert test "$(image_rc --route web --dest "$OUT/p.png" --resume "$CHAT" --point '0.5,0.2=')" = 2
for extra in "--region 0,0,1,1" "--prompt keep" "--aspect 1:1" "--size 64x64" "--transparent"; do
  assert test "$(image_rc --route web --dest "$OUT/p.png" --resume "$CHAT" --point '0.5,0.2=x' $extra)" = 2
  assert grep -q 'sends its pins alone' "$IMAGE_ERR"
done
assert test ! -e "$WEB_CALLS"
assert test "$(image_rc --route web --dest "$OUT/p.png" --resume "$CHAT" --point '0.5,0.2=orange helmet' \
  --point '0,1=green top')" = 0
assert test "$(sed -n 1p "$WEB_CALLS")" = comment
assert test "$(grep -A1 -x -- --point "$WEB_CALLS" | grep -v -x -e --point -e -- | tr '\n' '|')" = '0.5,0.2=orange helmet|0,1=green top|'
assert_fails grep -qx -- --prompt "$WEB_CALLS"
assert grep -qx 'route=web' "$IMAGE_OUT"
assert test "$(image_rc --route web --dest "$OUT/p.png" --ref "$WORK/r1.png" --point '0.5,0.5=x')" = 0
assert grep -A1 -x -- --ref "$WEB_CALLS" | grep -qx "$WORK/r1.png"

# --remove-bg: web-only, alone, no instruction (the viewer drops one), a .png that must come back with alpha.
assert test "$(image_rc --dest "$OUT/n.png" --resume "$CHAT" --remove-bg --account acct)" = 2
assert grep -q -- '--remove-bg is web-only.*pass --route web' "$IMAGE_ERR"
assert test "$(wc -l <"$IMAGE_ERR" | tr -d ' ')" = 1
assert test ! -e "$CLI_CALLS"
assert test "$(image_rc --route web --dest "$OUT/n.png" --resume "$CHAT" --remove-bg --prompt 'keep the person')" = 2
assert grep -q 'takes no --prompt' "$IMAGE_ERR"
assert test "$(image_rc --route web --dest "$OUT/n.jpg" --resume "$CHAT" --remove-bg)" = 2
assert test "$(image_rc --route web --dest "$OUT/n.png" --resume "$CHAT" --remove-bg --transparent)" = 2
assert test "$(image_rc --route web --dest "$OUT/n.png" --remove-bg)" = 2
assert test ! -e "$WEB_CALLS"
assert test "$(WEB_MODE=alpha image_rc --route web --dest "$OUT/n.png" --ref "$WORK/r1.png" --remove-bg)" = 0
assert test "$(sed -n 1p "$WEB_CALLS")" = remove-bg
assert_fails grep -qx -- --prompt "$WEB_CALLS"
assert test "$("$REAL_MAGICK" "$OUT/n.png" -alpha extract -format '%[fx:minima]' info:)" = 0
rm -f "$OUT/n.png"
assert test "$(image_rc --route web --dest "$OUT/n.png" --resume "$CHAT" --remove-bg)" = 1
assert grep -q 'Remove BG returned no transparency' "$IMAGE_ERR"
assert test ! -e "$OUT/n.png"

# Composite: on by default for --region/--point, against the input snapshot; the fake paints a blue
# circle over x 18..46 of 64 onto green, so the green input shows wherever the mask did not reach.
WEB_CHAT=0b6f1d2e-1111-4222-8333-944455556666
"$REAL_MAGICK" -size 64x48 'xc:#00FF00' "PNG24:$WORK/green.png"
pixel_at() { "$REAL_MAGICK" "$1" -depth 8 -format "%[pixel:p{$2}]" info:; }
assert test "$(image_rc --route web --dest "$OUT/c1.png" --prompt 'blue corner' --ref "$WORK/green.png" --region 0,0,0.2,0.2)" = 0
assert grep -Eq '^composite=region changed=' "$IMAGE_OUT"
assert test "$(pixel_at "$OUT/c1.png" 32,24)" = 'srgb(0,255,0)'
assert test "$(tail -n 1 "$IMAGE_OUT")" = "edit_depth=1 root=$WORK/green.png"
assert test "$(jq -r '.edits[0].region' "$OUT/c1.png.edit.json")" = 0,0,0.2,0.2
assert test "$(image_rc --route web --dest "$OUT/c2.png" --prompt 'blue left' --resume "$WEB_CHAT" --region 0,0,0.5,1)" = 0
assert grep -Eq '^composite=region changed=' "$IMAGE_OUT"
assert test "$(pixel_at "$OUT/c2.png" 24,24)" = 'srgb(0,0,255)'
assert test "$(pixel_at "$OUT/c2.png" 42,24)" = 'srgb(0,255,0)'
assert test "$(tail -n 1 "$IMAGE_OUT")" = "edit_depth=2 root=$WORK/green.png"
assert test "$(image_rc --route web --dest "$OUT/c3.png" --ref "$OUT/c2.png" --point '0.5,0.5=blue dot')" = 0
assert grep -Eq '^composite=points changed=' "$IMAGE_OUT"
assert test "$(tail -n 1 "$IMAGE_OUT")" = "edit_depth=3 root=$WORK/green.png"
assert test "$(jq -c '.edits[2] | [.points, .route, .vendor]' "$OUT/c3.png.edit.json")" = '[["0.5,0.5=blue dot"],"web","codex"]'
assert test "$(image_rc --route web --dest "$OUT/c9.png" --prompt 'blue corner' --ref "$WORK/green.png" --region 0,0,0.2,0.2)" = 0
assert test "$(image_rc --route web --dest "$OUT/c9.png" --prompt 'blue left' --resume "$WEB_CHAT" --region 0,0,0.5,1)" = 0
assert test "$(pixel_at "$OUT/c9.png" 42,24)" = 'srgb(0,255,0)'
assert test "$(image_rc --route web --dest "$OUT/c4.png" --prompt 'blue corner' --ref "$WORK/green.png" --region 0,0,0.2,0.2 --no-composite)" = 0
assert_fails grep -q '^composite=' "$IMAGE_OUT"
assert test "$(pixel_at "$OUT/c4.png" 32,24)" = 'srgb(0,0,255)'
assert test "$(image_rc --route web --dest "$OUT/c5.png" --prompt 'blue corner' --ref "$WORK/green.png" --region 0,0,0.2,0.2 --transparent)" = 0
assert_fails grep -q '^composite=' "$IMAGE_OUT"
assert test "$(image_rc --route web --dest "$OUT/c6.png" --prompt 'blue dot' --ref "$WORK/green.png" --composite=0.5,0,0.5,1)" = 0
assert grep -Eq '^composite=region changed=' "$IMAGE_OUT"
assert test "$(pixel_at "$OUT/c6.png" 24,24)" = 'srgb(0,255,0)'
assert test "$(jq -r '.edits[0].region' "$OUT/c6.png.edit.json")" = 0.5,0,0.5,1
assert test "$(image_rc --route web --dest "$OUT/c7.png" --prompt 'blue dot' --ref "$WORK/green.png" --composite)" = 0
assert grep -Eq '^composite=auto changed=' "$IMAGE_OUT"
for refused in "--ref $WORK/green.png --composite --no-composite" "--ref $WORK/green.png --composite=0.5,0.5,0.6,0.1" \
  "--ref $WORK/green.png --composite --transparent" "--resume $CHAT --composite"; do
  assert test "$(image_rc --route web --dest "$OUT/c8.png" --prompt x $refused)" = 2
  assert test ! -e "$WEB_CALLS"
done
assert test "$(image_rc --route web --dest "$OUT/c8.png" --ref "$WORK/green.png" --remove-bg --composite)" = 2
assert grep -q 'never runs with --remove-bg or --transparent' "$IMAGE_ERR"
assert test "$(image_rc --dest "$OUT/c8.png" --prompt x --ref "$WORK/green.png" --composite --account acct)" = 1
assert test -s "$CLI_CALLS"

# Every web-only tool in the manifest is one this suite drives and the CLI refuses.
assert test "$(jq -c '.web_only | keys' "$ROOT/share/image-caps/codex.json")" = '["point","reaspect","region","remove_bg"]'

echo "PASS: $asserts asserts; one hidden-Chrome core (gemini_web's module, clone app and its locks, hide watcher, snapshot path, no second copy), the codex roster, image-limit text read as a wall with its end and nothing else, the live session and plan replies, Work mode switched to Chat, new chat vs resume (the older image never taken), the gallery blob read in-page, a stale draft removed and refs uploaded one by one in order before the prompt, limit -> 3 with the chat kept for a resume, signed out -> 4, a profile bound to another login refused unsent with its email masked, rotation least recently started first (a resume never stamps) with walls, busy locks and the codex pool, resume pinned to its owner, and codex-image --route web: dispatch, flags, prompt mapping, the CLI route's output block, exit codes and the image-leg route; one sentence builder words --aspect/--size/--transparent/--region identically on both routes, the aspect= fit line (a miss kept, never cropped), --region web-only through a clamped Markup stroke that must take, re-aspect only through the viewer's Resize (exit 2 with the offered ratios), --point as Comment pins alone (each kept before the next, off the toolbar, no other text), --remove-bg as one Remove BG click with no instruction and delivered only with alpha, composite on by default for --region/--point (opt-out, explicit on either route, never with --remove-bg/--transparent) with lineage through --resume and --ref, every web-only flag refused by the CLI naming --route web, and a signed-out verdict only on 401/403"
