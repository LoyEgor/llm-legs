# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Images from chatgpt.com on the owner's ChatGPT subscription accounts, through gemini_web's hidden Chrome.

One Chrome profile per codex account under CHATGPT_WEB_DIR; the clone app, its hide watcher, the toast log
and the failure snapshots are gemini_web's own. A generation goes through the chat composer the way a person
would and the image is saved from the URL the page itself shows; no ChatGPT endpoint is ever called from here.
Prints one JSON line; exit 0 ok, 2 usage, 3 image limit (walled), 4 signed out or never signed in, 1 other.
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
LOAD_S = 45

SELECTORS = {
    "chat_mode": "Chat",
    "composer": "div[contenteditable='true'][aria-label='Ask ChatGPT'], div[contenteditable='true'][aria-label='Add instructions'], "
                "#prompt-textarea, div[contenteditable='true'].ProseMirror",
    "add_files": "Add files and more",
    "upload": "Add photos & files",
    "attachment": "form [data-testid*=attachment], form img[alt]",
    "send": "form button[aria-label='Send'], button[data-testid=send-button], button[aria-label='Send prompt']",
    "stop": "form button[aria-label^='Stop'], button[data-testid=stop-button]",
    "idle": "form button[aria-label='Start Voice'], form button[aria-label='Send']",
    "remove": "form button[aria-label^='Remove']",
    "login": "button[data-testid=login-button], button:text-is('Log in'):not(nav *, [data-message-author-role] *), "
             "a:text-is('Log in'):not(nav *, [data-message-author-role] *)",
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
    return gw.free_first(gw.rotation(0))


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


def signed_out(page, session: Session) -> bool:
    host_path = page.url.split("://", 1)[-1]
    if host_path.startswith(SIGNED_OUT_HOSTS):
        return True
    return (session.seen and not session.email) or visible(page, SELECTORS["login"])


def chat_mode(page) -> None:
    """chatgpt.com may open in Work mode, whose composer cannot make images."""
    button = page.get_by_role("button", name=SELECTORS["chat_mode"], exact=True)
    with contextlib.suppress(Exception):
        if button.count() == 1 and button.is_visible() and button.get_attribute("aria-pressed") == "false":
            button.click(timeout=5000)


def open_chat(page, session: Session, account: str, chat: str | None) -> None:
    page.goto(f"{SITE}/c/{chat}" if chat else f"{SITE}/", wait_until="domcontentloaded", timeout=LOAD_S * 1000)
    deadline = time.time() + LOAD_S
    while time.time() < deadline:
        session.poll()
        if signed_out(page, session):
            raise gw.Failure(4, f"ChatGPT shows {account} signed out; run: codexb web {account}")
        chat_mode(page)
        if session.email and visible(page, SELECTORS["composer"]):
            if chat and chat not in page.url:
                raise gw.Failure(1, f"chat {chat} is not on {account} any more (the page went to {page.url})")
            return
        page.wait_for_timeout(250)
    raise gw.Failure(1, f"chatgpt.com did not load within {LOAD_S}s ({page.url})")


def attach(page, refs: list[str], wait_s: float = 120) -> None:
    """One file per input change, each awaited, so the chat receives the refs in the caller's order."""
    attached = page.locator(SELECTORS["attachment"])
    stale = page.locator(SELECTORS["remove"])
    for _ in range(20):
        if not stale.count():
            break
        with contextlib.suppress(Exception):
            attached.first.hover(timeout=2000)
            stale.first.click(timeout=5000, force=True)
        page.wait_for_timeout(500)
    else:
        raise drift("a draft attachment left in the composer cannot be removed")
    for index, ref in enumerate(refs):
        before = attached.count()
        # The composer's image/* file inputs stay in the page but ignore a file set on them (live 2026-10-02):
        # only the chooser its own menu opens takes the upload.
        try:
            page.get_by_role("button", name=SELECTORS["add_files"], exact=True).first.click(timeout=10000)
            with page.expect_file_chooser(timeout=10000) as chooser:
                page.get_by_text(SELECTORS["upload"], exact=True).first.click(timeout=5000)
            chooser.value.set_files(ref, timeout=15000)
        except Exception as error:  # noqa: BLE001
            raise drift(f"no '{SELECTORS['upload']}' chooser in the composer for {Path(ref).name}") from error
        deadline = time.time() + wait_s
        while attached.count() <= before:
            if time.time() > deadline:
                raise drift(f"the upload of reference {index + 1} ({Path(ref).name}) never showed in the composer")
            page.wait_for_timeout(500)


def send(page, prompt: str, wait_s: float = 120) -> None:
    composer = page.locator(SELECTORS["composer"]).first
    try:
        composer.click(timeout=10000)
    except Exception as error:  # noqa: BLE001
        raise drift("no composer") from error
    page.keyboard.press("ControlOrMeta+A")
    page.keyboard.press("Backspace")
    page.keyboard.insert_text(prompt)
    button = page.locator(SELECTORS["send"]).first
    deadline = time.time() + wait_s
    while True:
        with contextlib.suppress(Exception):
            if button.is_visible() and button.is_enabled():
                break
        if time.time() > deadline:
            raise drift(f"the send button stays disabled for {wait_s:.0f}s (an upload still running?)")
        page.wait_for_timeout(500)
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
    deadline = time.time() + wait_s
    while time.time() < deadline:
        if probe(page)["streaming"]:
            return
        with contextlib.suppress(Exception):
            if button.is_visible() and button.is_enabled():
                button.click(timeout=10000)
                return
        page.wait_for_timeout(500)


def chat_of(url: str) -> str | None:
    found = re.search(r"/c/(" + CHAT_ID.pattern + ")", url or "")
    return found[1] if found else None


def wait_image(page, account: str, before: dict, timeout_s: float) -> tuple[str, str | None]:
    """The new image's src and the chat id, once the reply stopped streaming with a full-size image in it."""
    known = {image["src"] for image in before["images"]}
    replies = len(before["replies"])
    started = quiet_since = time.time()
    chat, settled = None, 0
    while time.time() - started < timeout_s:
        chat = chat or chat_of(page.url)
        state = probe(page)
        said = " ".join(state["replies"][replies:] + state["alerts"])
        fresh = [image for image in state["images"] if image["src"] not in known and image["done"]
                 and min(image["width"], image["height"]) >= MIN_EDGE]
        until = None if fresh else limit_until(said, time.time())
        if until:
            raise gw.Failure(3, f"ChatGPT image limit on {account}: {' '.join(said.split())[:200]}", until=int(until),
                             chat=chat)
        if state["streaming"]:
            quiet_since, settled = time.time(), 0
        elif fresh:
            settled += 1
            if settled >= 2:
                return fresh[-1]["src"], chat or chat_of(page.url)
        elif state["replies"][replies:] and time.time() - quiet_since > QUIET_S:
            raise gw.Failure(1, f"ChatGPT answered without an image: {' '.join(said.split())[:200]}", chat=chat)
        page.wait_for_timeout(1000)
    raise gw.Failure(1, f"no image after {timeout_s:.0f}s; it may still land in chat {chat or 'unknown'}", chat=chat)


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


def render_on(account: str, args, meta: dict) -> dict:
    started = time.time()
    dest = Path(args.dest)
    with gw.browser(account) as context:
        page = context.pages[0] if context.pages else context.new_page()
        session = Session(page)
        open_chat(page, session, account, args.resume)
        bind(account, session, meta)
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
        gw.ledger({"kind": KIND, "event": "sent", "account": account, "chat": args.resume,
                   "refs": len(args.ref), "resume": bool(args.resume)})
        try:
            src, chat = wait_image(page, account, before, args.timeout)
            rendered = time.time()
            size, fmt = save_image(context, page, src, dest)
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
    with gw.file_lock(gw.ROOT / "locks" / f"{account}.lock", wait_s=900):
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
    for account in candidates:
        try:
            result = generate_on(account, args)
        except gw.Failure as failure:
            if failure.code != 2:
                gw.report(account, failure)
            if failure.code == 3:
                gw.set_wall(account, failure.extra.get("until") or time.time() + gw.WALL_SECONDS)
            if failure.code not in (3, 4) or pinned:
                raise gw.Failure(failure.code, failure.reason, account=account, **failure.extra)
            skipped.append((account, failure))
            continue
        gw.set_wall(account, None)
        gw.emit(result)
        return
    raise gw.Failure(3 if any(failure.code == 3 for _, failure in skipped) else 4,
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
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(func=cmd_generate, tool="generate", aspect=None, point=[])
    p = sub.add_parser("resize", help="re-aspect a chat's last image through the viewer's Resize (a generation)")
    p.add_argument("--resume", required=True)
    p.add_argument("--aspect", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(func=cmd_generate, tool="resize", prompt=None, ref=[], region=None, point=[])
    p = sub.add_parser("comment", help="point edits: Comment pins on one image, each with its text, sent as one edit")
    p.add_argument("--point", action="append", required=True, type=point_arg, help="x,y=<text>, fractions of the image")
    p.add_argument("--dest", required=True)
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--resume")
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(func=cmd_generate, tool="comment", prompt=None, region=None, aspect=None)
    p = sub.add_parser("remove-bg", help="the viewer's Remove BG on one image (a generation; it takes no instruction)")
    p.add_argument("--dest", required=True)
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--resume")
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(func=cmd_generate, tool="remove-bg", prompt=None, region=None, point=[], aspect=None)
    args = parser.parse_args()
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
