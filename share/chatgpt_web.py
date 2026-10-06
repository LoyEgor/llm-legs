# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Images from chatgpt.com on the owner's ChatGPT subscription accounts, through gemini_web's hidden Chrome.

One Chrome profile per codex account under CHATGPT_WEB_DIR; the clone app, its off-screen parking, the toast log
and the failure snapshots are gemini_web's own. A generation goes through the chat composer the way a person
would and the image is saved from the URL the page itself shows; no ChatGPT endpoint is ever called from here.
Prints one JSON line; exit 0 ok, 2 usage, 3 image limit (walled), 4 signed out or never signed in, 5 account busy
(its lock not free within --lock-wait), 1 other.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime
import json
import os
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gemini_web as gw  # noqa: E402

gw.ROOT = Path(os.environ.get("CHATGPT_WEB_DIR", "~/.chatgpt-web")).expanduser()
gw.ROUTE = gw.TOOL = "chatgpt-web"
gw.POOL_VENDOR = "codex"

SITE = "https://chatgpt.com"
gw.LOGIN_URL = SITE + "/auth/login"
ME_PATH = "/backend-api/me"
PLAN_PATHS = ("/backend-api/accounts/check/v4-2023-04-27", "/backend-api/wham/accounts/check")
CHAT_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SIGNED_OUT_HOSTS = ("auth.openai.com", "chatgpt.com/auth")
KIND = "chatgpt-image"
MIN_EDGE = 256
QUIET_S = 30
STALL_S = 90
# Pack takes render side by side and land within ~11 s of each other; one still blank this long after a sibling
# landed is a page that missed its image (13 of 92 pack takes stalled, 0 of 56 lone ones below load 200; the reload
# showed it 3-5 s later), so it is reloaded now instead of at its own stall clock.
SIBLING_S = 20
# The latest a stalled take landed after its last sibling was 128 s (2026-10-03); a dead one held its pack 600 s.
STRAGGLER_S = 180
LOAD_S = 45
POLL_MS = 500
PROJECT = "Images"
PROJECT_RETRY_S = 86400
PROJECT_PATH = re.compile(r"/g/g-p-[0-9a-f]+[^/]*/project")
LOGIN_BUTTON, LOGIN_TEXT = "button[data-testid=login-button]", "Log in"
OUTSIDE_CHAT = ":not(nav *, [data-message-author-role] *)"

SELECTORS = {
    "chat_mode": "Chat",
    "composer": "div[contenteditable='true'][aria-label='Ask ChatGPT'], div[contenteditable='true'][aria-label='Add instructions'], "
                "#prompt-textarea, div[contenteditable='true'].ProseMirror, "
                "div[contenteditable='true'][aria-label^='New chat in']",
    "add_files": "Add files and more",
    "project_create": "button[aria-label='Add new project']",
    "upload": "Add photos & files",
    "decline": "Not now",
    "attachment": "form [data-testid*=attachment], form img[alt]",
    "send": "form button[aria-label='Send'], button[data-testid=send-button], button[aria-label='Send prompt']",
    "stop": "form button[aria-label^='Stop'], button[data-testid=stop-button]",
    "idle": "form button[aria-label='Start Voice'], form button[aria-label='Send']",
    "remove": "form button[aria-label^='Remove']",
    "login": f"{LOGIN_BUTTON}, button:text-is('{LOGIN_TEXT}'){OUTSIDE_CHAT}, a:text-is('{LOGIN_TEXT}'){OUTSIDE_CHAT}",
    "assistant": "[data-turn-key] [data-chatgpt-search-message-ids]:not([data-chatgpt-search-unit-key$=':user']), "
                 "[data-message-author-role=assistant]",
    "user": "[data-chatgpt-search-unit-key$=':user'], [data-message-author-role=user]",
    "image": "main [data-testid=generated-image-gallery] img, main img[alt^='Generated image']",
    "alerts": "[role=alert], [role=status], [data-testid*=toast]",
    "preview": "[data-testid=generated-image-preview]",
    "editor_image": "img[class*=ZoomableImage]",
    "menu_item": "[data-radix-popper-content-wrapper] [role^=menuitem], [role=menu] [role^=menuitem]",
    "comment_text": "input[name=image-comment-instruction]",
    "comment_pin": "button[aria-label^='Edit comment ']",
}
EDITOR = {"markup": "Markup", "canvas": "Draw on image", "undo": "Undo", "resize": "Resize", "close": "Close viewer",
          "comment": "Comment", "comment_surface": "Image comment surface", "tools": "Image editing tools",
          "send": "Send", "remove_bg": "Remove BG"}
IMAGE_SRC = r"^blob:https://chatgpt\.com/|/backend-api/estuary/content|oaiusercontent\.com|/files/"
LIMIT = re.compile(r"(?:image|images|generation|request)[^.\n]{0,80}\blimit\b|\blimit\b[^.\n]{0,80}image", re.I)
LIMIT_CUE = re.compile(r"try again|again later|resets?\b|upgrade|your plan|plan limit|wait until", re.I)
LIMIT_WHEN = re.compile(r"(?:try again|available again|resets?|create more images)[^.\n]{0,60}?\b(in|after|at)\s+"
                        r"([^.\n]{1,60})", re.I)

PAGE_PROBE = """(sel) => {
  const seen = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const pattern = new RegExp(sel.image_src);
  const images = [...document.querySelectorAll(sel.image)]
    .filter(img => !img.closest(sel.user) && pattern.test(img.currentSrc || img.src))
    .map(img => ({src: img.currentSrc || img.src, width: img.naturalWidth, height: img.naturalHeight,
                  done: img.complete}));
  return {replies: [...document.querySelectorAll(sel.assistant)].map(e => (e.innerText || '').trim()),
          alerts: [...document.querySelectorAll(sel.alerts)].filter(seen).map(e => (e.innerText || '').trim())
            .filter(Boolean),
          images, streaming: [...document.querySelectorAll(sel.stop)].some(seen)
            || ![...document.querySelectorAll(sel.idle)].some(seen)};
}"""
SEEN = """const seen = el => { const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'; };
  const ready = sel => { const b = document.querySelector(sel);
    return !!b && seen(b) && !b.disabled && !b.closest('[aria-disabled=true]'); };"""
SEND_READY = "(sel) => { " + SEEN + " return ready(sel.send); }"
RESIZE_STARTED = "(sel) => { " + SEEN + """
  const any = s => [...document.querySelectorAll(s)].some(seen);
  return any(sel.stop) || !any(sel.idle) ? 'streaming' : ready(sel.send) && 'send';
}"""
# One round trip per open_chat tick; the Playwright role and text-is lookups it stands in for still decide
# before open_chat returns or gives up.
OPEN_PROBE = "(sel) => { " + SEEN + r"""
  const text = el => (el.textContent || '').replace(/\s+/g, ' ').trim();
  const named = name => [...document.querySelectorAll('button, [role=button]')]
    .filter(el => (el.getAttribute('aria-label') || text(el)) === name);
  const chat = named(sel.chat_mode);
  return {composer: [...document.querySelectorAll(sel.composer)].some(seen),
          login: [...document.querySelectorAll(sel.login_button)].some(seen)
            || [...document.querySelectorAll('button, a')].some(el => seen(el) && text(el) === sel.login_text
                 && !(el.parentElement && el.parentElement.closest('nav, [data-message-author-role]'))),
          work_mode: chat.length === 1 && seen(chat[0]) && chat[0].getAttribute('aria-pressed') === 'false',
          offer: named(sel.decline).some(seen)};
}"""


def drift(what: str) -> gw.Failure:
    return gw.Failure(1, f"ChatGPT UI drift: {what}")


mask_email = gw.mask_email


def known_account(account: str) -> None:
    if not gw.valid_account(account):
        raise gw.Failure(2, f"bad account name {account!r}")
    gw.refuse_off_roster(account)


def jobs() -> list[dict]:
    return [row for row in gw.job_rows() if isinstance(row, dict) and row.get("kind") == KIND]


def chat_owner(chat: str) -> str | None:
    owners = [row["account"] for row in jobs() if row.get("chat") == chat and row.get("account")]
    return owners[-1] if owners else None


def rotation() -> list[str]:
    return gw.rotation(0)


def limit_until(text: str, now: float) -> float | None:
    """The end of an image-limit wall the page states, else None; a limit with no readable time walls
    for gw.WALL_SECONDS."""
    if not (LIMIT.search(text) and LIMIT_CUE.search(text)):
        return None
    found = LIMIT_WHEN.search(text)
    if not found:
        return now + gw.WALL_SECONDS
    preposition, when = found[1].lower(), found[2].strip().lower()
    if preposition == "in":
        spans = re.findall(r"(\d+)\s*(day|hour|hr|minute|min|second|sec)", when)
        seconds = sum(int(n) * {"day": 86400, "hour": 3600, "hr": 3600, "minute": 60, "min": 60}.get(unit, 1)
                      for n, unit in spans)
        return now + seconds if seconds else now + gw.WALL_SECONDS
    clock = re.search(r"(\d{1,2})(?::(\d\d))?\s*([ap])\.?m\.?", when) or re.search(r"\b(\d{1,2}):(\d\d)\b()", when)
    if not clock:
        return now + gw.WALL_SECONDS
    hour, minute = int(clock[1]) % (12 if clock[3] else 24), int(clock[2] or 0)
    if clock[3] == "p":
        hour += 12
    local = datetime.datetime.fromtimestamp(now)
    at = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if at.timestamp() <= now:
        at += datetime.timedelta(days=1)
    return at.timestamp()


class Session:
    """The signed-in user as the page's own replies name it; read after the page asked, never asked."""

    def __init__(self, page):
        self.pending: list = []
        self.seen = False
        self.email: str | None = None
        self.plans: dict[str, str] = {}
        self.default: str | None = None
        self.active: str | None = None
        page.on("response", lambda response: self.pending.append(response))
        page.on("request", self.note_account)

    # accounts/check v4 keys its PERSONAL account as "default" even when the page works in a team
    # workspace: only the account id the page's own requests carry names the plan it runs on.
    def note_account(self, request) -> None:
        with contextlib.suppress(Exception):
            self.active = request.headers.get("chatgpt-account-id") or self.active

    @property
    def plan(self) -> str | None:
        chosen = self.active or self.default
        if chosen in self.plans:
            return self.plans[chosen]
        return next(iter(self.plans.values())) if len(self.plans) == 1 else None

    def poll(self) -> None:
        while self.pending:
            response = self.pending.pop(0)
            path = urllib.parse.urlparse(response.url).path
            # Only a refusal means signed out: a 200 or another status mid-load came after a good reply live.
            if path == ME_PATH and response.status in (401, 403):
                self.feed(None)
            elif path == ME_PATH and response.status == 200:
                with contextlib.suppress(Exception):
                    body = response.json()
                    if isinstance(body, dict) and body.get("email"):
                        self.feed(body)
            elif path in PLAN_PATHS:
                with contextlib.suppress(Exception):
                    self.feed_plan(response.json())

    def feed(self, body) -> None:
        self.seen = True
        self.email = (body.get("email") or None) if isinstance(body, dict) else None

    def feed_plan(self, body) -> None:
        body = body if isinstance(body, dict) else {}
        accounts = body.get("accounts")
        if isinstance(accounts, dict):
            accounts = list(accounts.values())
        self.default = body.get("default_account_id") or self.default
        for entry in accounts if isinstance(accounts, list) else []:
            entry = entry if isinstance(entry, dict) else {}
            account = entry.get("account") if isinstance(entry.get("account"), dict) else entry
            ident = account.get("account_id") or account.get("id")
            named = (account.get("plan_display_name") or "").lower() or account.get("plan_type")
            if ident and named and (account.get("plan_display_name") or ident not in self.plans):
                self.plans[ident] = named


def visible(page, selector: str) -> bool:
    target = page.locator(selector)
    with contextlib.suppress(Exception):
        return any(target.nth(index).is_visible() for index in range(target.count()))
    return False


def probe(page) -> dict:
    return page.evaluate(PAGE_PROBE, {**SELECTORS, "image_src": IMAGE_SRC})


def signed_out(page, session: Session, login: bool | None = None) -> bool:
    host_path = page.url.split("://", 1)[-1]
    if host_path.startswith(SIGNED_OUT_HOSTS):
        return True
    return (session.seen and not session.email) or (visible(page, SELECTORS["login"]) if login is None else login)


def chat_mode(page) -> None:
    """chatgpt.com may open in Work mode, whose composer cannot make images."""
    button = page.get_by_role("button", name=SELECTORS["chat_mode"], exact=True)
    with contextlib.suppress(Exception):
        if button.count() == 1 and button.is_visible() and button.get_attribute("aria-pressed") == "false":
            button.click(timeout=5000)


def decline_offers(page) -> None:
    """A connector offer (Google Drive, Notion) pops over the composer at random and swallows its clicks (live 2026-10-03)."""
    for _ in range(3):
        if not gw.click_if_visible(page, "button", SELECTORS["decline"]):
            return


def open_chat(page, session: Session, account: str, chat: str | None, navigate: bool = True,
              home: str = "/") -> None:
    if navigate:
        page.goto(f"{SITE}/c/{chat}" if chat else f"{SITE}{home}", wait_until="domcontentloaded",
                  timeout=LOAD_S * 1000)
    out = gw.Failure(4, f"ChatGPT shows {account} signed out; run: codexb web {account}")
    names = {"composer": SELECTORS["composer"], "login_button": LOGIN_BUTTON, "login_text": LOGIN_TEXT,
             "chat_mode": SELECTORS["chat_mode"], "decline": SELECTORS["decline"]}
    deadline = time.time() + LOAD_S
    while time.time() < deadline:
        session.poll()
        state = {}
        with contextlib.suppress(Exception):
            state = page.evaluate(OPEN_PROBE, names)
        if signed_out(page, session, bool(state.get("login"))):
            raise out
        if state.get("work_mode"):
            chat_mode(page)
        if state.get("offer"):
            decline_offers(page)
        if session.email and state.get("composer"):
            chat_mode(page)
            decline_offers(page)
            if signed_out(page, session):
                raise out
            if chat and chat not in page.url:
                raise gw.Failure(1, f"chat {chat} is not on {account} any more (the page went to {page.url})")
            return
        page.wait_for_timeout(250)
    if signed_out(page, session):
        raise out
    raise gw.Failure(1, f"chatgpt.com did not load within {LOAD_S}s ({page.url})")


def find_project(page) -> str | None:
    page.locator(SELECTORS["project_create"]).first.wait_for(state="attached", timeout=15000)
    row = page.locator(f"[data-app-action-sidebar-project-label='{PROJECT}']")
    found = row.first.get_attribute("data-app-action-sidebar-project-id", timeout=5000) if row.count() else None
    return f"/g/{found}/project" if found else None


def create_project(page) -> tuple[str, str]:
    add = page.locator(SELECTORS["project_create"]).first
    # The sidebar's section header lies over this button until the row is hovered.
    add.hover(force=True, timeout=5000)
    add.click(force=True, timeout=10000)
    dialog = page.get_by_role("dialog")
    dialog.locator("input[name='project-name']").fill(PROJECT, timeout=5000)
    with contextlib.suppress(Exception):
        dialog.get_by_role("button", name="Default memory", exact=True).click(timeout=5000)
        page.get_by_text("Project-only memory", exact=True).first.click(timeout=5000)
    memory = ""
    with contextlib.suppress(Exception):
        memory = dialog.locator("button").filter(has_text="memory").first.inner_text(timeout=3000).strip()
    dialog.get_by_role("button", name="Create project", exact=True).click(timeout=5000)
    page.wait_for_url(PROJECT_PATH, timeout=20000)
    return urllib.parse.urlparse(page.url).path, memory


def project_home(page, session: Session, account: str, meta: dict) -> str:
    """The path a new chat opens at: the account's Images project, so generations stay off the owner's chat list.
    Created once with project-only memory: its chats neither read his other chats nor feed them. Without one
    (creation failed, retried daily) it is the home page."""
    if meta.get("project"):
        return meta["project"]
    if time.time() - meta.get("project_failed", 0) < PROJECT_RETRY_S:
        return "/"
    try:
        open_chat(page, session, account, None)
        found = find_project(page)
        path, memory = (found, None) if found else create_project(page)
    except Exception as error:  # noqa: BLE001
        gw.write_meta(account, project_failed=int(time.time()))
        gw.ledger({"kind": KIND, "event": "project_failed", "account": account,
                   "reason": gw.failure_text(error)[:200]})
        return "/"
    gw.write_meta(account, project=path)
    gw.ledger({"kind": KIND, "event": "project", "account": account, "project": path, "created": not found,
               "memory": memory})
    return path


def open_new(page, session: Session, account: str, home: str, navigate: bool = True) -> None:
    """A new chat on `home`; a project the owner deleted is forgotten and the chat opens on the home page."""
    try:
        open_chat(page, session, account, None, navigate=navigate, home=home)
        if home == "/" or home.split("/")[2] in page.url:
            return
    except gw.Failure as failure:
        if home == "/" or failure.code != 1:
            raise
    gw.write_meta(account, project=None)
    gw.ledger({"kind": KIND, "event": "project_gone", "account": account, "project": home})
    open_chat(page, session, account, None)


def clear_drafts(page) -> None:
    attached, stale = page.locator(SELECTORS["attachment"]), page.locator(SELECTORS["remove"])
    for _ in range(20):
        if not stale.count():
            return
        with contextlib.suppress(Exception):
            attached.first.hover(timeout=2000)
            stale.first.click(timeout=5000, force=True)
        page.wait_for_timeout(500)
    raise drift("a draft attachment left in the composer cannot be removed")


def await_more(page, items, more_than: int, wait_s: float, what: str) -> None:
    try:
        items.nth(more_than).wait_for(state="attached", timeout=wait_s * 1000)
    except Exception as error:  # noqa: BLE001
        raise drift(what) from error


def in_order(page, refs: list[str]) -> bool:
    """The composer's thumbnails name the refs in the caller's order."""
    with contextlib.suppress(Exception):
        names = page.locator(SELECTORS["attachment"]).evaluate_all(
            "els => els.map(e => e.getAttribute('alt') || e.getAttribute('aria-label') || e.innerText || '')")
        found = [next((i for i, name in enumerate(names) if Path(ref).name in name), -1) for ref in refs]
        return -1 not in found and found == sorted(found)
    return False


def upload(page, refs: list[str], index: int, batch: bool) -> tuple[int, list[str]]:
    decline_offers(page)
    before, files = page.locator(SELECTORS["attachment"]).count(), [refs[index]]
    # The composer's image/* file inputs stay in the page but ignore a file set on them (live 2026-10-02):
    # only the chooser its own menu opens takes the upload.
    try:
        page.get_by_role("button", name=SELECTORS["add_files"], exact=True).first.click(timeout=10000)
        with page.expect_file_chooser(timeout=10000) as chooser:
            page.get_by_text(SELECTORS["upload"], exact=True).first.click(timeout=5000)
        if batch and chooser.value.is_multiple():
            files = refs
        chooser.value.set_files(files if len(files) > 1 else files[0], timeout=15000)
    except Exception as error:  # noqa: BLE001
        raise drift(f"no '{SELECTORS['upload']}' chooser in the composer for {Path(refs[index]).name}") from error
    return before, files


def begin_attach(page, refs: list[str]) -> tuple[int, list[str]] | None:
    """Starts the first upload and returns at once, so the tabs of one pack upload side by side; attach() ends it."""
    clear_drafts(page)
    return upload(page, refs, 0, len(refs) > 1) if refs else None


def attach(page, refs: list[str], wait_s: float = 120, begun: tuple[int, list[str]] | None = None) -> None:
    """All refs in one chooser change when it takes several and the thumbnails then read in the caller's order,
    otherwise one file per change, each awaited."""
    attached = page.locator(SELECTORS["attachment"])
    if not begun:
        clear_drafts(page)
    batch, index = len(refs) > 1, 0
    while index < len(refs):
        before, files = begun or upload(page, refs, index, batch)
        begun = None
        last = index + len(files) - 1
        await_more(page, attached, before + len(files) - 1, wait_s,
                   f"the upload of reference {last + 1} ({Path(refs[last]).name}) never showed in the composer")
        batch = False
        if len(files) > 1 and not in_order(page, refs):
            clear_drafts(page)
            continue
        index += len(files)


def send(page, prompt: str, wait_s: float = 120) -> None:
    composer = page.locator(SELECTORS["composer"]).first
    decline_offers(page)
    try:
        composer.click(timeout=10000)
    except Exception as error:  # noqa: BLE001
        raise drift("no composer") from error
    page.keyboard.press("ControlOrMeta+A")
    page.keyboard.press("Backspace")
    page.keyboard.insert_text(prompt)
    button = page.locator(SELECTORS["send"]).first
    stuck = f"the send button stays disabled for {wait_s:.0f}s (an upload still running?)"
    try:
        page.wait_for_function(SEND_READY, arg=SELECTORS, timeout=wait_s * 1000, polling=100)
    except Exception as error:  # noqa: BLE001
        raise drift(stuck) from error
    button.click(timeout=10000)


def editor_button(page, name: str):
    return page.get_by_role("button", name=EDITOR[name], exact=True).first


def open_editor(page, on_ref: bool) -> None:
    """The viewer of the image to edit: the attached ref's thumbnail, else the chat's last generated image."""
    target = page.locator(SELECTORS["attachment"] if on_ref else SELECTORS["preview"])
    try:
        (target.first if on_ref else target.last).click(timeout=10000)
        editor_button(page, "close").wait_for(timeout=15000)
    except Exception as error:  # noqa: BLE001
        raise drift("the image viewer did not open") from error


def stroke(page, points: list[tuple[float, float]], steps: int = 12) -> None:
    # Live, a burst of moves with no pause between them left the Markup canvas without a stroke.
    page.mouse.move(*points[0])
    page.wait_for_timeout(100)
    page.mouse.down()
    page.wait_for_timeout(100)
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        for step in range(1, steps + 1):
            page.mouse.move(x0 + (x1 - x0) * step / steps, y0 + (y1 - y0) * step / steps)
            page.wait_for_timeout(30)
    page.mouse.up()
    page.wait_for_timeout(1000)


ON_CANVAS = "(canvas, [x, y]) => { const hit = document.elementFromPoint(x, y); return !!hit && canvas.contains(hit); }"


def clear_point(canvas, x: float, y: float, dx: int, dy: int) -> tuple[float, float]:
    """The corner moved inward off the viewer's overlays (the Stroke width slider sits on a full-width image)."""
    for sx, sy in ((dx, 0), (0, dy)):
        for step in range(40):
            if canvas.evaluate(ON_CANVAS, [x + sx * 8 * step, y + sy * 8 * step]):
                return x + sx * 8 * step, y + sy * 8 * step
    return x, y


# The viewer panel's left edge is a resizer: a stroke or click starting there drags the panel, draws nothing.
def inside(value: float, start: float, size: float) -> float:
    return min(max(value, start + 16), start + size - 16)


def mark_region(page, region: tuple[float, float, float, float]) -> None:
    """The region outlined with the Markup pen; the prompt then goes into the composer Markup opens."""
    try:
        editor_button(page, "markup").click(timeout=10000)
        canvas = page.get_by_role("application", name=EDITOR["canvas"]).first
        canvas.wait_for(timeout=10000)
        frame = canvas.bounding_box()
        box = page.locator(SELECTORS["editor_image"]).filter(visible=True).first.bounding_box()
    except Exception as error:  # noqa: BLE001
        raise drift("no Markup canvas in the image viewer") from error
    x, y, w, h = region
    left = inside(box["x"] + x * box["width"] + 4, frame["x"], frame["width"])
    right = inside(box["x"] + (x + w) * box["width"] - 4, frame["x"], frame["width"])
    top = inside(box["y"] + y * box["height"] + 4, frame["y"], frame["height"])
    bottom = inside(box["y"] + (y + h) * box["height"] - 4, frame["y"], frame["height"])
    for _ in range(2):
        # Live, a stroke drawn the moment the canvas appeared was dropped.
        page.wait_for_timeout(2000)
        corners = [clear_point(canvas, left, top, 1, 1), clear_point(canvas, right, top, -1, 1),
                   clear_point(canvas, right, bottom, -1, -1), clear_point(canvas, left, bottom, 1, -1)]
        stroke(page, corners + corners[:1])
        if editor_button(page, "undo").is_enabled():
            return
    raise drift("the Markup canvas took no stroke")


def place_comments(page, points: list[tuple[float, float, str]], wait_s: float = 10) -> None:
    """One Comment pin per point, each given its own text and kept with Enter before the next is placed."""
    try:
        editor_button(page, "comment").click(timeout=10000)
        surface = editor_button(page, "comment_surface")
        surface.wait_for(timeout=10000)
        box = surface.bounding_box()
    except Exception as error:  # noqa: BLE001
        raise drift("no Comment surface in the image viewer") from error
    text_box, pins = page.locator(SELECTORS["comment_text"]), page.locator(SELECTORS["comment_pin"])
    for index, (x, y, text) in enumerate(points, 1):
        # Off an earlier pin and the toolbar lying over the image's foot: a click there would edit or miss.
        spot = clear_point(surface, inside(box["x"] + x * box["width"], box["x"], box["width"]),
                           inside(box["y"] + y * box["height"], box["y"], box["height"]),
                           1 if x < 0.5 else -1, 1 if y < 0.5 else -1)
        page.mouse.click(*spot)
        try:
            text_box.first.wait_for(timeout=5000)
        except Exception as error:  # noqa: BLE001
            raise drift(f"comment {index} opened no text box") from error
        page.keyboard.insert_text(text)
        page.keyboard.press("Enter")
        deadline = time.time() + wait_s
        while pins.count() < index or text_box.count():
            if time.time() > deadline:
                raise drift(f"comment {index} was not kept on the image")
            page.wait_for_timeout(250)


def send_comments(page) -> None:
    """Only the pins go: this Send drops a composer draft, and the composer's own send drops the pins (live)."""
    try:
        page.get_by_role("toolbar", name=EDITOR["tools"]).get_by_role("button", name=EDITOR["send"], exact=True) \
            .first.click(timeout=10000)
    except Exception as error:  # noqa: BLE001
        raise drift("no Send on the Comment toolbar") from error


def remove_background(page, before: dict, wait_s: float = 20) -> None:
    """One click sends the viewer's own fixed prompt: no text field, and a composer draft is not sent with it."""
    try:
        editor_button(page, "remove_bg").click(timeout=10000)
    except Exception as error:  # noqa: BLE001
        raise drift("no Remove BG in the image viewer") from error
    deadline = time.time() + wait_s
    while time.time() < deadline:
        state = probe(page)
        if state["streaming"] or len(state["replies"]) > len(before["replies"]) or state["images"] != before["images"]:
            return
        page.wait_for_timeout(500)
    raise drift(f"Remove BG started nothing within {wait_s:.0f}s")


def resize_options(page) -> list[str]:
    items = page.locator(SELECTORS["menu_item"])
    try:
        editor_button(page, "resize").click(timeout=10000)
        items.first.wait_for(timeout=5000)
    except Exception as error:  # noqa: BLE001
        raise drift("no Resize menu in the image viewer") from error
    return [(items.nth(index).inner_text().split() or [""])[-1] for index in range(items.count())]


def pick_resize(page, aspect: str, wait_s: float = 10) -> None:
    """Resize starts a generation; should it only stage one in the composer, the staged request is sent."""
    page.locator(SELECTORS["menu_item"]).filter(has_text=aspect).first.click(timeout=10000)
    button = page.locator(SELECTORS["send"]).first
    with contextlib.suppress(Exception):
        if page.wait_for_function(RESIZE_STARTED, arg=SELECTORS, timeout=wait_s * 1000,
                                  polling=100).json_value() == "send":
            button.click(timeout=10000)


def chat_of(url: str) -> str | None:
    found = re.search(r"/c/(" + CHAT_ID.pattern + ")", url or "")
    return found[1] if found else None


class Watch:
    """One sent request's reply, read one probe at a time: step() is the new image's src once the reply stopped
    streaming with a full-size image in it, else None; a limit or an answer without an image raises.
    With `reload_s` (a new chat only: a reload can re-issue an old chat's image srcs, read then as new) the page is
    reloaded after that long without an image: the image often lands server-side while the page never shows it."""

    def __init__(self, page, account: str, before: dict, reload_s: float | None = None):
        self.page, self.account = page, account
        self.known = {image["src"] for image in before["images"]}
        self.replies = len(before["replies"])
        self.started = self.quiet_since = self.reloaded = time.time()
        self.chat, self.settled, self.reload_s, self.reloads, self.nudged = None, 0, reload_s, 0, False

    def reload_by(self, at: float) -> None:
        if self.reload_s and at - self.reload_s < self.reloaded:
            self.reloaded, self.nudged = at - self.reload_s, True

    def step(self) -> str | None:
        page = self.page
        self.chat = self.chat or chat_of(page.url)
        if self.reload_s and self.chat and time.time() - self.reloaded >= self.reload_s:
            self.reloaded = self.quiet_since = time.time()
            self.reloads += 1
            gw.ledger({"kind": KIND, "event": "reloaded", "account": self.account, "chat": self.chat,
                       "after_s": round(self.reloaded - self.started), "cause": "sibling" if self.nudged else "stall"})
            self.nudged = False
            with contextlib.suppress(Exception):
                page.reload(wait_until="domcontentloaded", timeout=LOAD_S * 1000)
        state = probe(page)
        said = " ".join(state["replies"][self.replies:] + state["alerts"])
        fresh = [image for image in state["images"] if image["src"] not in self.known and image["done"]
                 and min(image["width"], image["height"]) >= MIN_EDGE]
        until = None if fresh else limit_until(said, time.time())
        if until:
            raise gw.Failure(3, f"ChatGPT image limit on {self.account}: {' '.join(said.split())[:200]}",
                             until=int(until), chat=self.chat)
        if state["streaming"]:
            self.quiet_since, self.settled = time.time(), 0
        elif fresh:
            self.settled += 1
            if self.settled >= 2:
                self.chat = self.chat or chat_of(page.url)
                return fresh[-1]["src"]
        elif state["replies"][self.replies:] and not self.reloads and time.time() - self.quiet_since > QUIET_S:
            raise gw.Failure(1, f"ChatGPT answered without an image: {' '.join(said.split())[:200]}", chat=self.chat)
        return None

    def late(self, timeout_s: float) -> gw.Failure | None:
        if time.time() - self.started < timeout_s:
            return None
        return gw.Failure(1, f"no image after {timeout_s:.0f}s; it may still land in chat {self.chat or 'unknown'}",
                          chat=self.chat)


def wait_image(page, account: str, before: dict, timeout_s: float,
               reload_s: float | None = None) -> tuple[str, str | None]:
    watch = Watch(page, account, before, reload_s)
    while not watch.late(timeout_s):
        src = watch.step()
        if src:
            return src, watch.chat
        page.wait_for_timeout(POLL_MS)
    raise watch.late(timeout_s)


def image_format(body: bytes) -> str | None:
    if body[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if body[:3] == b"\xff\xd8\xff":
        return "jpg"
    if body[:4] == b"RIFF" and body[8:12] == b"WEBP":
        return "webp"
    return None


BLOB_READ = """async (src) => {
  const bytes = new Uint8Array(await (await fetch(src)).arrayBuffer());
  let text = '';
  for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode(...bytes.subarray(i, i + 32768));
  return btoa(text);
}"""


def save_image(context, page, src: str, dest: Path) -> tuple[int, str]:
    if src.startswith("blob:"):
        status, body = 200, base64.b64decode(page.evaluate(BLOB_READ, src))
    else:
        response = context.request.get(src, timeout=120000)
        status, body = response.status, response.body()
    fmt = image_format(body)
    if status != 200 or not fmt:
        raise gw.Failure(1, f"image download failed (HTTP {status}, {len(body)} bytes)")
    part = dest.with_name(f".{dest.name}.part")
    part.write_bytes(body)
    part.replace(dest)
    return len(body), fmt


def bind(account: str, session: Session, meta: dict) -> None:
    if not meta.get("email"):
        raise gw.Failure(4, f"account {account} is not bound to a ChatGPT login yet; run: chatgpt-web status {account}")
    if session.email != meta["email"]:
        raise gw.Failure(1, f"profile {account} is signed in as {mask_email(session.email)}, bound to "
                            f"{mask_email(meta['email'])}")


def take_counts() -> list[int]:
    return json.loads((gw.MANIFEST.parent / "codex.json").read_text())["web"]["counts"]


def take_failure(error: Exception) -> gw.Failure:
    return error if isinstance(error, gw.Failure) else gw.Failure(1, gw.failure_text(error)[:300])


def render_takes(context, account: str, args, meta: dict, started: float, home: str = "/",
                 first: Session | None = None) -> dict:
    """--count N: N new chats of one request in N tabs of this one browser, all loading at once, each composed and
    sent in tab order (each tab's Session listens before its first request), then every pending tab read in one
    poll loop. A take that fails while another delivers is reported in `failed`; with
    none delivered the run fails as one take would, a limit first. Saved in delivery order: the first to --dest."""
    dest, tabs, failures, delivered, session, opened, sessions = Path(args.dest), [], [], [], None, [], []
    for index in range(args.count):
        page = context.pages[0] if not index and context.pages else context.new_page()
        sessions.append(first if not index and first else Session(page))
        opened.append(page)
        with contextlib.suppress(Exception):
            page.goto(f"{SITE}{home}", wait_until="commit", timeout=LOAD_S * 1000)
    begun, ready = [], len(opened)
    for index, page in enumerate(opened):
        try:
            page.bring_to_front()
            tab_session = sessions[index]
            open_new(page, tab_session, account, home, navigate=not page.url.startswith(SITE))
            bind(account, tab_session, meta)
            gw.phase("page")
            gw.close_promos(page, account)
            begun.append(begin_attach(page, args.ref))
        except Exception as error:  # noqa: BLE001
            if not index:
                raise
            failure = take_failure(error)
            failures += [(tab, failure, None) for tab in range(index + 1, args.count + 1)]
            ready = index
            break
    for index, page in enumerate(opened[:ready]):
        try:
            page.bring_to_front()
            tab_session = sessions[index]
            attach(page, args.ref, begun=begun[index])
            before = probe(page)
            send(page, args.prompt)
        except Exception as error:  # noqa: BLE001
            if not index:
                raise
            failure = take_failure(error)
            failures += [(tab, failure, None) for tab in range(index + 1, ready + 1)]
            break
        session = session or tab_session
        gw.phase("sent")
        gw.ledger({"kind": KIND, "event": "sent", "account": account, "chat": None, "refs": len(args.ref),
                   "resume": False, "tab": index + 1})
        tabs.append((index + 1, page, Watch(page, account, before, STALL_S)))
    sent = time.time()
    pending, straggle_until = list(tabs), None
    while pending:
        for tab, page, watch in list(pending):
            try:
                src = watch.step()
                if not src:
                    if watch.late(args.timeout):
                        raise watch.late(args.timeout)
                    if straggle_until and time.time() > straggle_until:
                        raise gw.Failure(1, f"no image {STRAGGLER_S:.0f}s after the last sibling take landed; it may "
                                            f"still land in chat {watch.chat or 'unknown'}", chat=watch.chat)
                    continue
                gw.phase("media")
                path = gw.variant_path(dest, len(delivered))
                size, fmt = save_image(context, page, src, path)
                gw.phase("saved")
            except Exception as error:  # noqa: BLE001
                failure = take_failure(error)
                chat = failure.extra.get("chat") or watch.chat or chat_of(page.url)
                pending.remove((tab, page, watch))
                failures.append((tab, failure, chat))
                gw.ledger({"kind": KIND, "event": "failed", "account": account, "chat": chat, "code": failure.code,
                           "tab": tab})
                continue
            pending.remove((tab, page, watch))
            delivered.append({"path": str(path), "chat": watch.chat, "bytes": size, "format": fmt, "tab": tab})
            gw.ledger({"kind": KIND, "event": "saved", "account": account, "chat": watch.chat, "dest": str(path),
                       "bytes": size, "format": fmt, "refs": len(args.ref), "resume": False, "tab": tab})
            straggle_until = time.time() + STRAGGLER_S
            for _, _, other in pending:
                other.reload_by(time.time() + SIBLING_S)
        if pending:
            pending[0][1].wait_for_timeout(POLL_MS)
    for page in opened[1:]:
        with contextlib.suppress(Exception):
            page.close()
    failures.sort(key=lambda row: row[0])
    limits = [failure for _, failure, _ in failures if failure.code == 3]
    if not delivered:
        raise max(limits, key=lambda failure: failure.extra["until"]) if limits else failures[0][1]
    if session.plan and session.plan != meta.get("plan"):
        gw.write_meta(account, plan=session.plan)
    first = delivered[0]
    return {"ok": True, "account": account, "chat": first["chat"],
            "url": f"{SITE}/c/{first['chat']}" if first["chat"] else None, "dest": first["path"],
            "format": first["format"], "bytes": first["bytes"], "plan": session.plan, "count": args.count,
            "takes": delivered, "failed": len(failures),
            "failures": [{"tab": tab, "code": failure.code, "reason": failure.reason, "chat": chat}
                         for tab, failure, chat in failures],
            **({"walled_until": max(failure.extra["until"] for failure in limits)} if limits else {}),
            "seconds": {"harness": round(sent - started, 1), "render": round(time.time() - sent, 1),
                        "total": round(time.time() - started, 1)}}


def render_on(account: str, args, meta: dict) -> dict:
    started = time.time()
    dest = Path(args.dest)
    with gw.browser(account) as context:
        page = context.pages[0] if context.pages else context.new_page()
        session = Session(page)
        home = "/" if args.resume else project_home(page, session, account, meta)
        if args.count > 1:
            return render_takes(context, account, args, meta, started, home, session)
        if args.resume:
            open_chat(page, session, account, args.resume)
        else:
            open_new(page, session, account, home)
        bind(account, session, meta)
        gw.phase("page")
        gw.close_promos(page, account)
        attach(page, args.ref)
        if args.tool != "generate" or args.region:
            open_editor(page, on_ref=bool(args.ref))
        if args.tool == "resize":
            offered = resize_options(page)
            if args.aspect not in offered:
                raise gw.Failure(2, f"the viewer's Resize offers {', '.join(offered) or 'nothing'}, not {args.aspect}",
                                 offered=offered)
            before = probe(page)
            pick_resize(page, args.aspect)
        elif args.tool == "remove-bg":
            before = probe(page)
            remove_background(page, before)
        else:
            if args.region:
                mark_region(page, args.region)
            if args.point:
                place_comments(page, args.point)
            before = probe(page)
            if args.point:
                send_comments(page)
            else:
                send(page, args.prompt)
        sent = time.time()
        gw.phase("sent")
        gw.ledger({"kind": KIND, "event": "sent", "account": account, "chat": args.resume,
                   "refs": len(args.ref), "resume": bool(args.resume)})
        try:
            fresh = not args.resume and args.tool == "generate" and not args.region and not args.point
            src, chat = wait_image(page, account, before, args.timeout, STALL_S if fresh else None)
            rendered = time.time()
            gw.phase("media")
            size, fmt = save_image(context, page, src, dest)
            gw.phase("saved")
        except gw.Failure as failure:
            gw.ledger({"kind": KIND, "event": "failed", "account": account,
                       "chat": failure.extra.get("chat") or chat_of(page.url) or args.resume, "code": failure.code})
            raise
        chat = chat or args.resume
        with contextlib.suppress(Exception):
            if editor_button(page, "close").is_visible():
                editor_button(page, "close").click(timeout=5000)
        gw.ledger({"kind": KIND, "event": "saved", "account": account, "chat": chat, "dest": str(dest),
                   "bytes": size, "format": fmt, "refs": len(args.ref), "resume": bool(args.resume)})
        if session.plan and session.plan != meta.get("plan"):
            gw.write_meta(account, plan=session.plan)
        return {"ok": True, "account": account, "chat": chat, "url": f"{SITE}/c/{chat}" if chat else None,
                "dest": str(dest), "format": fmt, "bytes": size, "plan": session.plan,
                "seconds": {"harness": round(sent - started, 1), "render": round(rendered - sent, 1),
                            "total": round(time.time() - started, 1)}}


def generate_on(account: str, args) -> dict:
    if not gw.has_login(account):
        raise gw.Failure(4, f"account {account} has no browser login; run: codexb web {account}")
    meta = gw.read_meta(account)
    if not meta.get("email"):
        raise gw.Failure(4, f"account {account} is not bound to a ChatGPT login yet; run: chatgpt-web status {account}")
    if not args.resume:
        gw.note_started(account)
    return render_on(account, args, meta)


def region_arg(text: str) -> tuple[float, float, float, float]:
    try:
        x, y, w, h = (float(value) for value in text.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError(f"x,y,w,h fractions, not {text}") from None
    if not (x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= 1 and y + h <= 1):
        raise argparse.ArgumentTypeError(f"{text} is not inside the image (fractions 0..1)")
    return x, y, w, h


def point_arg(text: str) -> tuple[float, float, str]:
    spot, _, note = text.partition("=")
    try:
        x, y = (float(value) for value in spot.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError(f"x,y=<text> with x,y fractions, not {text}") from None
    if not (0 <= x <= 1 and 0 <= y <= 1 and note.strip()):
        raise argparse.ArgumentTypeError(f"{text} is not a point inside the image (fractions 0..1) with a text")
    return x, y, note.strip()


def check_args(args) -> None:
    dest = Path(args.dest)
    if not dest.is_absolute() or not dest.parent.is_dir():
        raise gw.Failure(2, f"--dest must be an absolute path in an existing directory, not {args.dest}")
    for ref in args.ref:
        if not (Path(ref).is_absolute() and Path(ref).is_file()):
            raise gw.Failure(2, f"--ref {ref} is not an absolute path to a file")
    if args.resume and not CHAT_ID.fullmatch(args.resume):
        raise gw.Failure(2, f"--resume takes the chat id printed as chat=, not {args.resume}")
    edit = "--region" if args.region else args.tool
    if edit in ("--region", "comment", "remove-bg") and not (args.resume and not args.ref or len(args.ref) == 1):
        raise gw.Failure(2, f"{edit} edits one image: the chat's last one (--resume) or a single --ref")
    counts = take_counts()
    if args.count not in counts:
        raise gw.Failure(2, f"--count is {min(counts)}-{max(counts)}, not {args.count}")
    if args.count > 1 and (args.resume or args.region or args.point or args.tool != "generate"):
        raise gw.Failure(2, "--count renders new chats of one generate request: no --resume, --region, --point, "
                            "resize, comment or remove-bg")
    if args.account:
        known_account(args.account)


def cmd_generate(args) -> None:
    check_args(args)
    pinned = args.account
    if args.resume:
        owner = chat_owner(args.resume)
        if owner and pinned and owner != pinned:
            raise gw.Failure(2, f"chat {args.resume} lives on {owner}, not {pinned}")
        pinned = pinned or owner
        if not pinned:
            raise gw.Failure(2, f"chat {args.resume} is not in {gw.ROOT / 'jobs.jsonl'}; pass --account")
    if pinned:
        gw.refuse_out_of_pool(pinned)
        until = gw.walls().get(pinned, 0)
        if until > time.time():
            raise gw.Failure(3, f"{pinned} is walled by its ChatGPT image limit until "
                                f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(until))}", account=pinned)
    candidates = [pinned] if pinned else rotation()
    if not candidates:
        bound = gw.bound_accounts()
        if not bound:
            raise gw.Failure(4, "no ChatGPT account is signed in; run: codexb web <account>")
        if not any(gw.in_pool(name) for name in bound):
            raise gw.Failure(4, 'every signed-in ChatGPT account is out of the codex worker pool; turn "In pool" '
                                "back on for one, or pin it in ~/.claude/worker-model")
        raise gw.Failure(3, "every signed-in ChatGPT account is walled by its image limit (walls.json)")
    skipped: list[tuple[str, gw.Failure]] = []
    with contextlib.closing(gw.claimed(candidates, args.lock_wait)) as picks:
        for account, refusal in picks:
            try:
                if refusal:
                    raise refusal
                result = generate_on(account, args)
            except gw.Failure as failure:
                if failure.code != 2:
                    gw.report(account, failure)
                if failure.code == 3:
                    gw.set_wall(account, failure.extra.get("until") or time.time() + gw.WALL_SECONDS)
                if failure.code not in (3, 4, 5) or pinned:
                    raise gw.Failure(failure.code, failure.reason, account=account, **failure.extra)
                skipped.append((account, failure))
                continue
            gw.set_wall(account, result.get("walled_until"))
            gw.emit(result)
            return
    raise gw.Failure(min(failure.code for _, failure in skipped),
                     "no signed-in ChatGPT account could take the job ("
                     + "; ".join(f"{account}: {failure.reason}" for account, failure in skipped) + ")")


def cmd_status(args) -> None:
    known_account(args.account)
    started = time.time()
    with gw.file_lock(gw.ROOT / "locks" / f"{args.account}.lock", wait_s=900), \
            gw.browser(args.account, args.visible) as context:
        page = context.pages[0] if context.pages else context.new_page()
        session = Session(page)
        open_chat(page, session, args.account, None)
        meta = gw.read_meta(args.account)
        if not meta.get("email"):
            meta = gw.write_meta(args.account, email=session.email)
        if session.plan:
            gw.write_meta(args.account, plan=session.plan)
        bound = session.email == meta.get("email")
        gw.emit({"ok": bound, "account": args.account, "signed_in": True, "email": mask_email(session.email),
                 "bound_to": mask_email(meta.get("email")), "plan": session.plan,
                 "walled_until": gw.walls().get(args.account), "seconds": round(time.time() - started, 1)})
        sys.exit(0 if bound else 1)


def cmd_accounts(args) -> None:
    walled, rows = gw.walls(), []
    used = {row.get("account"): row.get("ts") for row in jobs()}
    for name in filter(gw.valid_account, gw.roster()):
        meta = gw.read_meta(name)
        rows.append({"account": name, "login": gw.has_login(name), "email": mask_email(meta.get("email")),
                     "plan": meta.get("plan"), "walled_until": walled.get(name), "last_used": used.get(name)})
    gw.emit({"ok": True, "accounts": rows})


def main() -> None:
    parser = argparse.ArgumentParser(prog="chatgpt-web")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("login", help="open a visible Chrome to sign an account in once")
    p.add_argument("account")
    p.add_argument("--wait", action="store_true", help="return only once that Chrome has quit")
    p.set_defaults(func=gw.cmd_login)
    p = sub.add_parser("status", help="free check: signed in, bound email, plan")
    p.add_argument("account")
    p.add_argument("--visible", action="store_true")
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("accounts", help="codex profiles with their login, bound email, plan and walls")
    p.set_defaults(func=cmd_accounts)
    p = sub.add_parser("generate")
    p.add_argument("--prompt", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--resume", help="continue the chat printed as chat= by an earlier run")
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--region", type=region_arg, help="x,y,w,h fractions of the image, outlined with Markup")
    p.add_argument("--count", type=int, default=1, help=f"{min(take_counts())}-{max(take_counts())} takes as new chats in tabs of one browser")
    p.add_argument("--timeout", type=int, default=600)
    gw.lock_wait_arg(p)
    p.set_defaults(func=cmd_generate, tool="generate", aspect=None, point=[])
    p = sub.add_parser("resize", help="re-aspect a chat's last image through the viewer's Resize (a generation)")
    p.add_argument("--resume", required=True)
    p.add_argument("--aspect", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--timeout", type=int, default=600)
    gw.lock_wait_arg(p)
    p.set_defaults(func=cmd_generate, tool="resize", prompt=None, ref=[], region=None, point=[],
                   count=1)
    p = sub.add_parser("comment", help="point edits: Comment pins on one image, each with its text, sent as one edit")
    p.add_argument("--point", action="append", required=True, type=point_arg, help="x,y=<text>, fractions of the image")
    p.add_argument("--dest", required=True)
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--resume")
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--timeout", type=int, default=600)
    gw.lock_wait_arg(p)
    p.set_defaults(func=cmd_generate, tool="comment", prompt=None, region=None, aspect=None, count=1)
    p = sub.add_parser("remove-bg", help="the viewer's Remove BG on one image (a generation; it takes no instruction)")
    p.add_argument("--dest", required=True)
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--resume")
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--timeout", type=int, default=600)
    gw.lock_wait_arg(p)
    p.set_defaults(func=cmd_generate, tool="remove-bg", prompt=None, region=None, point=[], aspect=None,
                   count=1)
    args = parser.parse_args()
    gw.TIMED = hasattr(args, "lock_wait")
    try:
        args.func(args)
    except gw.Failure as failure:
        if failure.code != 2:
            gw.report(getattr(args, "account", None) or failure.extra.get("account") or "-", failure)
        gw.fail(failure.code, failure.reason, **failure.extra)
    except Exception as exc:  # noqa: BLE001
        gw.report(getattr(args, "account", None) or "-", exc)
        gw.fail(1, gw.failure_text(exc)[:300])


if __name__ == "__main__":
    main()
