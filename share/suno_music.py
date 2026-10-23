# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Songs and speech from Suno (suno.com) on the free plan: v6-mini, two clips a generation, edits of a library song
or an uploaded file, files through the official download.

Same hidden Chrome, profiles, locks and job ledger as gemini_web. The create form is driven the way a person would;
the new clips are read from the page's own replies (generate/v2-web, the edit actions), their progress and the
balance from the endpoints the page itself reads, with the page's own session. A file comes from the song's Download
dialog while the song is unlocked or the account holds an unlock (spent the first time a song is downloaded), else it
is recorded as the page plays it; the player's stream is encrypted and never read. Prints one JSON line; exit 0 ok,
2 usage, 3 out of credits, 4 signed out or an owner step, 1 other.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import json
import math
import re
import secrets
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import caps_checks  # noqa: E402
import gemini_web as gw  # noqa: E402

gw.ROUTE = "suno"

SITE = "https://suno.com"
MANIFEST = Path(__file__).resolve().parent / "image-caps" / "suno.json"
WALLS = "suno-walls.json"
NOTICES = "notices.json"
NOTICE_KEY = "agreed_suno"
UPLOAD_NOTICE = "By uploading anything"
# Reverse and Speed answer with the new clip itself rather than an edit action
CLIP_EDITS = ("clips/reverse-clip/", "clips/adjust-speed/")
# Suno asks a birthday once at sign-up and shows it nowhere; any adult date passes its age gate.
BIRTHDAY = (("Month", "January"), ("Day", "1"), ("Year", "1990"))
MAGIC = {"mp3": lambda b: b[:3] == b"ID3" or b[:1] == b"\xff", "m4a": lambda b: b[4:8] == b"ftyp"}
MENUS = """() => [...document.querySelectorAll('[role=menu]')].map(m => [...m.querySelectorAll('[role=menuitem]')]
  .filter(i => i.closest('[role=menu]') === m).map(i => i.innerText.split('\\n')[0].trim()))"""
# The audio condition picker is no [role=menu]: its lines are read from the box that holds both headers.
CONDITION_MENU = """() => {
  const boxes = [...document.querySelectorAll('div')].filter(d => d.getBoundingClientRect().width > 0
    && /^REMIX\\n/.test(d.innerText || '') && /\\nEDIT\\n/.test(d.innerText || ''));
  boxes.sort((a, b) => a.innerText.length - b.innerText.length);
  return boxes.length ? boxes[0].innerText.split('\\n').map(l => l.trim()).filter(Boolean) : [];
}"""
FETCH = """async ([path, token, body]) => {
  // A fetch with no deadline hung a run for 36 min (superman, 2026-10-23): status 0 is a timeout or a network error.
  const init = {method: body === null ? 'GET' : 'POST', headers: {Authorization: 'Bearer ' + token},
                signal: AbortSignal.timeout(30000)};
  if (body !== null) { init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(body); }
  let response;
  try { response = await fetch(path, init); } catch (error) { return [0, String(error)]; }
  let data = null;
  try { data = await response.json(); } catch (error) {}
  return [response.status, data];
}"""
# With no unlock left a song is recorded as the page plays it, in real time (Egor 2026-10-23: the harness must hear
# what Suno made, and a free account may download a handful of songs ever). Every <audio> is routed into a recorder
# before anything plays, so nothing reaches the speakers; the encrypted stream itself is never read or decrypted.
TAP = """() => {
  const ctx = new AudioContext(), sink = ctx.createMediaStreamDestination(), tapped = new Set();
  for (const a of document.querySelectorAll('audio')) { ctx.createMediaElementSource(a).connect(sink); tapped.add(a); }
  window.__sunoTap = {ctx, sink, tapped};
  return tapped.size;
}"""
RECORD = """async (limit) => {
  const {ctx, sink, tapped} = window.__sunoTap;
  await ctx.resume();
  const loaded = Date.now() + 30000;
  let a;
  while (!(a = [...document.querySelectorAll('audio')].find(e => e.src.startsWith('blob:') && e.duration > 0))) {
    if (Date.now() > loaded) return {error: 'the player loaded no song within 30 s'};
    await new Promise(r => setTimeout(r, 200));
  }
  if (!tapped.has(a)) return {error: 'the player plays through an <audio> the recorder does not hear'};
  let parts, rec, stopped, started;
  for (let tries = 0; ; tries++) {
    a.pause();
    a.currentTime = 0;
    parts = [];
    rec = new MediaRecorder(sink.stream, {mimeType: 'audio/webm;codecs=opus', audioBitsPerSecond: 256000});
    rec.ondataavailable = e => parts.push(e.data);
    stopped = new Promise(r => rec.onstop = r);
    rec.start(1000);
    started = performance.now();
    try { await a.play(); break; } catch (error) {
      rec.stop();
      await stopped;
      // The page's own player can pause the element just after its Play click (2026-10-23): settle, start over.
      if (error.name !== 'AbortError' || tries >= 4) return {error: `the player would not play: ${error.message}`};
      await new Promise(r => setTimeout(r, 1000));
    }
  }
  const ended = new Promise(r => a.addEventListener('ended', () => r(true), {once: true}));
  const done = await Promise.race([ended, new Promise(r => setTimeout(() => r(false), limit * 1000))]);
  rec.stop();
  await stopped;
  if (!done) return {error: `the song had not ended after ${limit} s of playing`};
  const bytes = new Uint8Array(await new Blob(parts).arrayBuffer());
  let text = '';
  for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode(...bytes.subarray(i, i + 32768));
  return {b64: btoa(text), duration: a.duration, wall: (performance.now() - started) / 1000};
}"""
ENCODE = {"mp3": ["-c:a", "libmp3lame", "-q:a", "0"], "m4a": ["-c:a", "aac", "-b:a", "256k"]}
SEEN: dict[str, list[str]] = {}


def caps() -> dict:
    return json.loads(MANIFEST.read_text())


def drift(what: str) -> gw.Failure:
    return gw.Failure(1, f"Suno UI drift: {what}")


def walls() -> dict:
    try:
        return json.loads((gw.ROOT / WALLS).read_text())
    except (OSError, ValueError):
        return {}


def set_wall(account: str, until: float) -> None:
    gw.update_json(WALLS, lambda data: data.update({account: int(until)}))


def signed_out(account: str) -> gw.Failure:
    gw.write_meta(account, suno_signed_in=False)
    return gw.Failure(4, f"Suno shows {account} signed out; sign it in once: suno-music login --account {account}",
                      account=account)


def api(page, account: str, path: str, body=None) -> tuple[int, object]:
    """A read of an endpoint the page reads itself, with its own session: the clips' progress and the balance."""
    token = next((c["value"] for c in page.context.cookies(SITE) if c["name"] == "__session"), None)
    if not token:
        raise signed_out(account)
    status, data = page.evaluate(FETCH, [f"/a/api/{path}", token, body])
    if status == 401:
        raise signed_out(account)
    return status, data


def downloads_left(info: dict) -> int:
    usage = info.get("download_usage") or {}
    period = int(usage.get("current_period_downloads_limit") or 0) - int(usage.get("current_period_downloads_used") or 0)
    return max(0, period) + int(usage.get("additional_download_remaining") or 0)


def billing(page, account: str) -> dict:
    status, info = api(page, account, "billing/info/")
    if status != 200 or not isinstance(info, dict) or "total_credits_left" not in info:
        raise drift(f"billing/info answered HTTP {status} without total_credits_left")
    rate = info.get("credit_rate_limit") or {}
    gw.write_meta(account, suno_signed_in=True, suno_credits=int(info["total_credits_left"]),
                  suno_credits_limit=int(info.get("monthly_limit") or 0), suno_downloads=downloads_left(info),
                  suno_rate_credits=rate.get("available_credits"), suno_at=int(time.time()))
    SEEN["models"] = [m.get("name") for m in info.get("models") or [] if m.get("can_use")]
    return info


def spendable(info: dict) -> int:
    rate = (info.get("credit_rate_limit") or {}).get("available_credits")
    return min(int(info["total_credits_left"]), int(rate)) if rate is not None else int(info["total_credits_left"])


def rotation(price: int) -> list[str]:
    now, own = time.time(), walls()

    def ready(name: str) -> bool:
        meta = gw.read_meta(name)
        if meta.get("suno_signed_in") is not True:
            return False
        fresh = now - meta.get("suno_at", 0) <= gw.WALL_SECONDS
        if fresh and price and (meta.get("suno_credits") or 0) < price:
            return False
        return own.get(name, 0) <= now and gw.in_pool(name)

    ready_ones = [name for name in gw.bound_accounts() if ready(name)]
    return sorted(ready_ones, key=lambda name: gw.read_meta(name).get("suno_started_at", 0))


def reject_cookies(page) -> None:
    button = page.get_by_role("button", name="Deny all optional cookies")
    with contextlib.suppress(Exception):
        if button.count() and button.first.is_visible():
            button.first.click(timeout=3000)
            page.wait_for_timeout(500)


def open_page(page, account: str, path: str, timeout_s: float = 45.0) -> None:
    page.goto(SITE + path, wait_until="domcontentloaded", timeout=timeout_s * 1000)
    ready = page.get_by_role("tab", name="Songs", exact=True) if path.startswith("/create") else \
        page.get_by_role("button", name="More options")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        url = page.url
        # /auth/session-recovery is Suno refreshing a live session on the way back to the page, not a sign-out.
        if "/sign-in" in url or "accounts.google.com" in url or "/onboarding" in url or \
                ("/auth/" in url and "/auth/session-recovery" not in url):
            raise signed_out(account)
        if ready.count() and ready.first.is_visible():
            reject_cookies(page)
            gw.close_promos(page, account, keep=(UPLOAD_NOTICE,))
            return
        # A promo over the page (the v6 «Meet your new creative toolkit», 2026-10-23) hides the form from the role tree.
        gw.close_promos(page, account, keep=(UPLOAD_NOTICE,))
        page.wait_for_timeout(300)
    raise gw.Failure(1, f"Suno did not load {path} within {timeout_s:.0f}s ({page.url})")


def page_caps() -> list[str]:
    """`suno.json` is the only place a caller learns the models and modes, so what a run sees is compared with it:
    an added model, condition mode or song-menu item shows as `caps=stale`, not only a removed one."""
    c = caps()
    known = {"models": list(c["models"]), "condition": c["condition_menu"], **c["menus"]}
    lines = [line for part, live in sorted(SEEN.items()) for line in gw.caps_drift(part, live, known.get(part, []))]
    if SEEN:
        caps_checks.record("suno", "suno", bool(lines), "; ".join(lines))
    return lines


class Traffic:
    """The page's own replies after the Create click: the generation's clip ids, an edit action's clip id, the
    upload's library clip and the refusals Suno answers with."""

    def __init__(self, page):
        self.pending: list = []
        self.armed = False
        self.clips: list[str] = []
        self.action: str | None = None
        self.errors: list[tuple[int, str]] = []
        self.upload_clip: str | None = None
        self.media: dict[str, str] = {}
        page.on("response", lambda response: self.pending.append(response))

    def arm(self) -> None:
        self.poll()
        self.armed = True
        self.clips, self.action, self.errors = [], None, []

    def poll(self) -> None:
        while self.pending:
            response = self.pending.pop(0)
            path = urllib.parse.urlparse(response.url).path
            if not path.startswith("/a/api/"):
                continue
            path = path[len("/a/api/"):]
            with contextlib.suppress(Exception):
                if path.startswith("uploads/audio/") and path.endswith("/initialize-clip/"):
                    self.upload_clip = response.json().get("clip_id")
                elif re.fullmatch(r"uploads/image/[0-9a-f-]+/upload-finish/", path):
                    status = response.json().get("moderation_status")
                    self.media["image"] = "ok" if status == "approved" else f"moderation {status}"
                elif re.fullmatch(r"uploads/video/[0-9a-f-]+/", path):
                    status = response.json().get("status")
                    if status == "complete" or status in ("error", "failed", "rejected"):
                        self.media["video"] = "ok" if status == "complete" else status
                elif not self.armed or response.request.method != "POST":
                    continue
                elif path in ("generate/v2-web/", *CLIP_EDITS) or path.startswith("edit/"):
                    body = response.json()
                    if response.status != 200:
                        self.errors.append((response.status, str(body.get("detail") or body)[:300]))
                    elif path == "generate/v2-web/":
                        self.clips = [clip["id"] for clip in body.get("clips") or []]
                    elif path in CLIP_EDITS:
                        self.clips = [body["id"]]
                    elif body.get("action_clip_id"):
                        self.clips, self.action = [body["action_clip_id"]], path.split("/")[1]


def clock(seconds: float) -> str:
    return f"{int(seconds) // 60:02d}:{seconds - 60 * (int(seconds) // 60):04.1f}"


def seconds_of(text: str) -> float:
    minutes, seconds = text.strip().split(":")
    return int(minutes) * 60 + float(seconds)


def visible(page, selector: str):
    return page.locator(f"{selector} >> visible=true").first


def submenu_pick(page, parent: str, name: str) -> None:
    """Suno's submenus open on a pointer that moves over the item; a synthetic hover is caught by the menu's inert
    overlay, so the pointer is moved there like a hand."""
    trigger = page.get_by_role("menuitem", name=parent, exact=True).first
    box = trigger.bounding_box(timeout=8000)
    page.mouse.move(box["x"] + 5, box["y"] + box["height"] / 2)
    page.mouse.move(box["x"] + 20, box["y"] + box["height"] / 2)
    page.wait_for_timeout(800)
    with contextlib.suppress(Exception):
        menus = page.evaluate(MENUS)
        SEEN["More options"], SEEN[parent] = menus[0], menus[-1]
    page.get_by_role("menuitem", name=name, exact=True).first.click(timeout=8000)


def song_menu(page, record: bool = True) -> None:
    """The song's own ⋯ is the first More options on its page; the Similar list's follow it. A preview's menu hides
    Add to Playlist, so only a song's is compared with the manifest."""
    page.get_by_role("button", name="More options").first.click(timeout=15000)
    page.wait_for_timeout(800)
    if record:
        with contextlib.suppress(Exception):
            SEEN["More options"] = page.evaluate(MENUS)[0]


def is_preview(clip: dict) -> bool:
    """The free plan's generations sometimes come back with two extra v6 previews: not remixable, saved like a song."""
    return (clip.get("metadata") or {}).get("type") == "preview"


def answer_notice(page, account: str) -> bool:
    dialog = page.get_by_role("dialog").filter(has_text=UPLOAD_NOTICE)
    if not (dialog.count() and dialog.first.is_visible()):
        return False
    try:
        agreed = json.loads((gw.ROOT / NOTICES).read_text()).get(NOTICE_KEY, [])
    except (OSError, ValueError):
        agreed = []
    if account not in agreed:
        raise gw.Failure(4, f"{account} shows Suno's upload terms (\"{UPLOAD_NOTICE}…\"); it needs the owner's one-time "
                            f"Agree to Terms: with his yes, add {account} to \"{NOTICE_KEY}\" in {gw.ROOT / NOTICES}")
    dialog.first.get_by_role("button", name="Agree to Terms").click(timeout=8000)
    gw.ledger({"kind": "suno", "event": "notice-agreed", "account": account})
    return True


def upload_audio(page, traffic: Traffic, account: str, path: Path, about: str, wait_s: float) -> str:
    """Audio → Upload, the terms and the describe step; the upload becomes a library song ("UPLOAD"), which the form
    does not always attach, so the caller attaches it from its own page like any library song."""
    traffic.poll()
    traffic.upload_clip = None
    try:
        visible(page, '[aria-label="Add audio - Browse, upload, or record audio"]').click(timeout=8000)
        page.wait_for_timeout(600)
        with page.expect_file_chooser(timeout=10000) as chooser:
            page.get_by_text("Upload", exact=True).first.click(timeout=8000)
        chooser.value.set_files(str(path))
    except Exception as error:  # noqa: BLE001
        raise drift("no Upload under Add audio, or it opened no file chooser") from error
    describe = page.get_by_placeholder(re.compile(r"^e\.g\. Short piano"))
    deadline = time.time() + wait_s
    while time.time() < deadline:
        page.wait_for_timeout(1000)
        traffic.poll()
        if answer_notice(page, account):
            continue
        if describe.count() and describe.first.is_visible():
            describe.first.fill(about[:300])
            proceed = page.get_by_role("dialog").get_by_role("button", name="Continue", exact=True).first
            if not proceed.is_enabled():
                page.get_by_role("dialog").get_by_text("Full Song", exact=True).first.click(timeout=8000)
            proceed.click(timeout=8000)
            page.wait_for_timeout(3000)
            continue
        refusal = page.get_by_role("dialog").filter(has_text=re.compile(r"(?i)couldn.t|failed|not allowed|copyright"))
        if refusal.count() and refusal.first.is_visible():
            raise gw.Failure(1, f"Suno refused the upload of {path.name}: {' '.join(refusal.first.inner_text().split())[:200]}")
        dialogs = page.get_by_role("dialog").locator("visible=true")
        if traffic.upload_clip and not dialogs.count():
            return traffic.upload_clip
    gw.limit_hit.hit("suno.upload-wait", wait_s, "s", "kill", f"the upload of {path.name}: it never reached the form",
                     "share/suno_music.py:def upload_audio(")
    raise gw.Failure(1, f"the upload of {path.name} did not reach the form within {wait_s:.0f}s")


def attach_clip(page, account: str, clip: str) -> None:
    """A library song is attached from its own page: ⋯ → Remix → Cover lands on /create with it as the condition."""
    open_page(page, account, f"/song/{clip}")
    try:
        song_menu(page)
        submenu_pick(page, "Remix", "Cover")
        page.get_by_role("button", name=re.compile(r"^Change condition type from ")).first.wait_for(timeout=20000)
    except Exception as error:  # noqa: BLE001
        raise drift(f"the song {clip} did not attach through ⋯ → Remix → Cover") from error
    reject_cookies(page)
    gw.close_promos(page, account, keep=(UPLOAD_NOTICE,))


def set_mode(page, mode: str) -> None:
    label = caps()["modes"][mode]["label"]
    current = page.get_by_role("button", name=re.compile(r"^Change condition type from ")).first
    try:
        if (current.get_attribute("aria-label", timeout=8000) or "").endswith(f" from {label}"):
            return
        current.click(timeout=8000)
        page.wait_for_timeout(800)
        with contextlib.suppress(Exception):
            SEEN["condition"] = page.evaluate(CONDITION_MENU)
        page.get_by_text(caps()["modes"][mode]["menu"], exact=True).first.click(timeout=8000)
        page.wait_for_timeout(1200)
        shown = current.get_attribute("aria-label", timeout=8000) or ""
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {label} in the audio condition picker") from error
    if not shown.endswith(f" from {label}"):
        raise drift(f"the condition shows {shown!r}, not {label}")


def time_fields(page, label: str):
    return page.locator(f"xpath=//span[@contenteditable='true'][starts-with(normalize-space(..), '{label}')]") \
        .locator("visible=true")


def set_window(page, mode: str, start: float | None, end: float | None) -> str:
    """The start goes first: Suno keeps a window's length, so an end typed first moved with the start."""
    label = caps()["modes"][mode]["window"]
    fields = time_fields(page, label)
    try:
        fields.first.wait_for(timeout=8000)
        for index, value in ((0, start), (1, end)):
            if value is None:
                continue
            field = fields.nth(index)
            field.click(timeout=8000)
            page.keyboard.press("Meta+a")
            page.keyboard.type(clock(value))
            page.keyboard.press("Enter")
            page.wait_for_timeout(400)
        shown = [fields.nth(i).inner_text().strip() for i in range(fields.count())]
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {label!r} time fields in the {mode} panel") from error
    want = [clock(value) for value in (start, end) if value is not None]
    got = [shown[i] for i, value in enumerate((start, end)) if value is not None and i < len(shown)]
    if got != want:
        raise gw.Failure(2, f"Suno set the {mode} window to {' – '.join(shown)}, not {' – '.join(want)} (it lies inside "
                            f"the song; Suno clamps it to the song's length)")
    return " – ".join(shown)


def set_speed(page, speed: float, keep_pitch: bool) -> str:
    """The speed control is a bare drag bar, 0.25x to 4.00x in semitone steps (2^(n/12), n -24..24): the asked speed
    snaps to the nearest step and the pointer is pressed along the bar, halving the gap until its label reads it."""
    want = f"{2 ** (round(12 * math.log2(speed)) / 12):.2f}x"
    try:
        label = page.get_by_text(re.compile(r"^\d\.\d{2}x$")).locator("visible=true").first
        box = label.locator("xpath=following-sibling::div[1]").first.bounding_box(timeout=8000)
        y = box["y"] + box["height"] / 2
        low, high = box["x"], box["x"] + box["width"]
        x = low + box["width"] * (math.log2(speed) + 2) / 4
        shown = label.inner_text().strip()
        for _ in range(30):
            page.mouse.move(x, y)
            page.mouse.down()
            page.mouse.move(x + 0.01, y)
            page.mouse.up()
            page.wait_for_timeout(150)
            shown = label.inner_text().strip()
            if abs(float(shown[:-1]) - float(want[:-1])) <= 0.011:  # the label rounds the step its own way
                break
            low, high = (x, high) if float(shown[:-1]) < float(want[:-1]) else (low, x)
            x = (low + high) / 2
    except Exception as error:  # noqa: BLE001
        raise drift("no speed bar in the Speed panel") from error
    if abs(float(shown[:-1]) - float(want[:-1])) > 0.011:
        raise gw.Failure(1, f"the Speed bar stops at {shown}, not {want}")
    gw.set_switch(page, "Keep Pitch", keep_pitch, drift, "the Speed panel")
    return f"{shown}{' keep pitch' if keep_pitch else ''}"


def mashup_with(page, account: str, clip: str) -> str:
    """The second song comes from the picker's library list, found by its link (titles repeat: a generation's two
    clips share one); the search box narrows the list to its title when it is not among the first rows."""
    status, body = api(page, account, f"clip/{clip}")
    if status != 200 or not isinstance(body, dict):
        raise gw.Failure(2, f"--with {clip}: no Suno song {clip} on {account}")
    title = body.get("title") or ""
    try:
        visible(page, '[aria-label="Add another song to mashup"]').click(timeout=8000)
        dialog = page.get_by_role("dialog").filter(has_text="Add a song to mashup").first
        dialog.wait_for(timeout=10000)
        link = dialog.locator(f'a[href="/song/{clip}"]')
        if not link.count() and title:
            dialog.get_by_placeholder(re.compile(r"^Search for a song")).fill(title)
            page.wait_for_timeout(2500)
        link.first.wait_for(timeout=15000)
        link.first.locator("xpath=ancestor::*[@role='button'][1]").locator('[aria-label$=" to mashup"]').first \
            .click(timeout=8000)
        page.wait_for_timeout(1500)
    except Exception as error:  # noqa: BLE001
        raise gw.Failure(1, f"the mashup picker on {account} does not list {clip} ({title!r})") from error
    return title or clip


def section(page, name: str = "More Options") -> None:
    """More Options (Advanced on the Speech tab) folds without unmounting: its rows stay "visible" while covered, so
    its header's aria-expanded decides. A header lists what is set below its name."""
    header = page.locator("[role=button][aria-expanded]").filter(has_text=re.compile(rf"^\s*{name}")) \
        .locator("visible=true").first
    try:
        if header.get_attribute("aria-expanded", timeout=8000) != "true":
            header.click(timeout=8000)
            page.wait_for_timeout(800)
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {name} section") from error


def row_buttons(page, label: str):
    return page.locator(f"xpath=//span[normalize-space()='{label}']/ancestor::div[2]").locator("visible=true").first


def pill(row, name: str):
    """The More Options pills are out of the accessibility tree (no role query finds them): matched by their text."""
    return row.locator("button").filter(has_text=re.compile(rf"^\s*{re.escape(name)}\s*$")).first


def pressed(button) -> bool:
    return button.evaluate("b => b.getAttribute('data-selected') === 'true' || b.getAttribute('aria-pressed') === 'true'",
                           timeout=8000)


def choose(page, label: str, option: str | None, options: tuple[str, ...]) -> None:
    """A row of pill buttons (data-selected on Songs, aria-pressed on Speech); None leaves every pill off, which a
    selected pill's click undoes."""
    row = row_buttons(page, label)
    try:
        for name in options:
            if pressed(pill(row, name)) != (name == option):
                pill(row, name).click(timeout=8000)
                page.wait_for_timeout(300)
        picked = [n for n in options if pressed(pill(row, n))]
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {label} row ({'/'.join(options)})") from error
    if picked != ([option] if option else []):
        raise drift(f"the {label} row shows {picked or 'nothing'}, not {option or 'nothing'}")


def slide(page, name: str, value: int, step: int = 1) -> int:
    slider = page.locator(f'[role=slider][aria-label="{name}"]').locator("visible=true").first
    try:
        now = float(slider.get_attribute("aria-valuenow", timeout=8000))
        slider.focus()
        presses = round((value - now) / step)
        for _ in range(abs(presses)):
            page.keyboard.press("ArrowRight" if presses > 0 else "ArrowLeft")
        page.wait_for_timeout(200)
        shown = float(slider.get_attribute("aria-valuenow"))
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {name} slider") from error
    if round(shown) != value:
        raise drift(f"the {name} slider shows {shown}, not {value}")
    return value


def set_duration(page, seconds: int) -> int:
    """Custom swaps the Custom/Auto pills for a 10-360 s slider with a typeable m:ss box beside it."""
    box = visible(page, 'input[aria-label="Duration"]')
    try:
        if not box.count():
            pill(row_buttons(page, "Duration"), "Custom").click(timeout=8000)
        box.click(timeout=8000)
        page.keyboard.press("Meta+a")
        page.keyboard.type(f"{seconds // 60}:{seconds % 60:02d}")
        page.keyboard.press("Enter")
        page.wait_for_timeout(400)
        shown = float(visible(page, '[role=slider][aria-label="Duration"]').get_attribute("aria-valuenow", timeout=8000))
    except Exception as error:  # noqa: BLE001
        raise drift("no Duration slider after Custom") from error
    if round(shown) != seconds:
        raise drift(f"the Duration slider shows {shown:.0f} s, not {seconds}")
    return seconds


def styles_box(page):
    return page.locator("xpath=//div[starts-with(normalize-space(),'Styles')]/following::textarea[1]") \
        .locator("visible=true").first


def clear_form(page) -> None:
    """Suno keeps the last form (lyrics, styles, pills, sliders) across visits; its own Clear resets it whole. The
    Clear button is missing or disabled while nothing is set (2026-10-23), so such a form is already pristine."""
    try:
        styles_box(page).wait_for(timeout=15000)
    except Exception as error:  # noqa: BLE001
        raise drift("no Styles box on the Advanced form") from error
    page.wait_for_timeout(1000)
    button = page.get_by_role("button", name="Clear all form inputs").locator("visible=true")
    failed = None
    for _ in range(2):
        if not button.count() or not button.first.is_enabled():
            return
        # A panel left open from the last visit (the Lyricist, «Help me write lyrics», 2026-10-23) covers the button.
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)
        try:
            button.first.click(timeout=8000)
            page.get_by_role("alertdialog").get_by_role("button", name="Confirm", exact=True).click(timeout=8000)
            page.wait_for_timeout(800)
            return
        except Exception as error:  # noqa: BLE001
            failed = error
    raise drift("no Clear all form inputs, or no Confirm after it") from failed


def fill_lyrics(page, lyrics: str) -> None:
    editor = page.get_by_role("textbox", name="Lyrics editor").locator("visible=true").first
    try:
        editor.click(timeout=8000)
        page.keyboard.press("Meta+a")
        page.keyboard.press("Backspace")
        for index, line in enumerate(lyrics.splitlines()):
            if index:
                page.keyboard.press("Enter")
            if line:
                page.keyboard.insert_text(line)
        shown = editor.inner_text()
    except Exception as error:  # noqa: BLE001
        raise drift("no Lyrics editor") from error
    if re.sub(r"\s+", "", shown) != re.sub(r"\s+", "", lyrics):
        raise drift(f"the Lyrics editor holds {len(shown)} characters, not the {len(lyrics)} typed")


def fill(target, value: str, what: str) -> None:
    try:
        target.fill(value, timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {what} field") from error


def check_model(page) -> str:
    chip = page.get_by_role("button", name=re.compile(r"^v\d")).locator("visible=true").first
    try:
        shown = chip.inner_text(timeout=8000).strip()
    except Exception as error:  # noqa: BLE001
        raise drift("no model chip on the create form") from error
    if shown not in caps()["models"]:
        raise drift(f"the model chip shows {shown!r}, not one of {', '.join(caps()['models'])}")
    return shown


def title_field(page):
    return visible(page, 'input[placeholder="Song Title (Optional)"]')


def song_form(page, traffic: Traffic, account: str, plan: dict, title: str) -> dict:
    """Advanced (custom) for an exact styles box and lyrics, Simple for a description, a video or an image."""
    gw.click_if_visible(page, "tab", "Songs")
    gw.click_if_visible(page, "tab", "Advanced")
    clear_form(page)
    controls: dict = {"title": title, "model": check_model(page)}
    if plan["describe"] is not None:
        gw.click_if_visible(page, "tab", "Simple")
        page.wait_for_timeout(600)
        chips = page.locator('button[aria-label^="Remove "]').locator("visible=true")
        for _ in range(6):  # Clear leaves an attached video behind
            if not chips.count():
                break
            chips.first.click(timeout=8000)
            page.wait_for_timeout(400)
        box = page.locator("textarea").locator("visible=true").first
        fill(box, plan["describe"], "Simple description")
        for kind in ("video", "image"):
            if plan[kind]:
                attach_media(page, traffic, account, plan, kind)
                controls[kind] = Path(plan[kind]).name
        controls["describe"] = plan["describe"]
        return controls
    gw.click_if_visible(page, "tab", "Advanced")
    page.wait_for_timeout(600)
    fill(title_field(page), title, "Song Title")
    fill_lyrics(page, plan["lyrics"])
    fill(styles_box(page), plan["styles"], "Styles")
    section(page)
    choose(page, "Vocal Gender", plan["gender"], ("Male", "Female"))
    if plan["duration"]:
        controls["duration"] = set_duration(page, plan["duration"])
    choose(page, "Max Mode", "Off", ("Off", "On"))
    choose(page, "Personalize", "Off", ("Off", "On"))
    for flag, name in (("weirdness", "Weirdness"), ("style_influence", "Style Influence"),
                       ("audio_influence", "Audio Influence"), ("variety", "Variety")):
        if plan[flag] is not None:
            controls[flag] = slide(page, name, plan[flag])
    controls.update(styles=plan["styles"], lyrics=plan["lyrics"] or "instrumental", gender=plan["gender"] or "auto")
    return controls


def attach_media(page, traffic: Traffic, account: str, plan: dict, kind: str) -> None:
    """Add → Image or Video on the Simple form; Suno moderates an image and transcodes a video before it counts."""
    name = Path(plan[kind]).name
    traffic.poll()
    traffic.media.pop(kind, None)
    try:
        page.get_by_role("button", name="Add", exact=True).locator("visible=true").first.click(timeout=8000)
        page.wait_for_timeout(600)
        with page.expect_file_chooser(timeout=10000) as chooser:
            page.get_by_role("menuitem", name=kind.capitalize(), exact=True).first.click(timeout=8000)
        chooser.value.set_files(plan[kind])
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {kind.capitalize()} under the Simple form's Add menu") from error
    wait_s = caps()["upload_wait_s"]
    deadline = time.time() + wait_s
    while time.time() < deadline:
        page.wait_for_timeout(1000)
        traffic.poll()
        answer_notice(page, account)
        state = traffic.media.get(kind)
        if state == "ok":
            return
        if state:
            raise gw.Failure(1, f"Suno refused the {kind} {name}: {state}")
    gw.limit_hit.hit("suno.upload-wait", wait_s, "s", "kill", f"the {kind} {name}: Suno never finished it",
                     "share/suno_music.py:def attach_media(")
    raise gw.Failure(1, f"Suno did not finish the {kind} {name} within {wait_s:.0f}s")


def speech_form(page, plan: dict, title: str) -> dict:
    """The Speech tab has no Clear and no title: every control is set, the clip is titled by Suno."""
    gw.click_if_visible(page, "tab", "Speech")
    page.wait_for_timeout(800)
    fill(page.get_by_role("textbox", name="Script").locator("visible=true").first, plan["script"], "Script")
    fill(page.get_by_role("textbox", name="Tone").locator("visible=true").first, plan["tone"] or "", "Tone")
    section(page, "Advanced")
    choose(page, "Vocal Gender", plan["gender"], ("Male", "Female"))
    choose(page, "Background music", "On" if plan["music"] else "Off", ("Off", "On"))
    controls = {"title": title, "tone": plan["tone"] or "-", "music": plan["music"], "gender": plan["gender"] or "auto",
                "variety": slide(page, "Variety", 1 if plan["variety"] is None else plan["variety"])}
    return controls


def edit_form(page, traffic: Traffic, account: str, plan: dict, title: str) -> dict:
    mode = plan["mode"]
    gw.click_if_visible(page, "tab", "Songs")
    gw.click_if_visible(page, "tab", "Advanced")
    set_mode(page, mode)
    controls: dict = {"mode": mode, "source": plan["source"], "title": title, "model": check_model(page)}
    if mode == "mashup":
        controls["with"] = mashup_with(page, account, plan["with"])
    if caps()["modes"][mode].get("window"):
        controls["window"] = set_window(page, mode, plan["from_s"], plan["to_s"])
    if mode == "speed":
        controls["speed"] = set_speed(page, plan["speed"], plan["keep_pitch"])
    if caps()["modes"][mode]["generates"]:
        if plan["lyrics"] is not None:
            fill_lyrics(page, plan["lyrics"])
        if plan["styles"] is not None:
            fill(styles_box(page), plan["styles"], "Styles")
        section(page)
        choose(page, "Vocal Gender", plan["gender"], ("Male", "Female"))
        for flag, name in (("weirdness", "Weirdness"), ("style_influence", "Style Influence"),
                           ("audio_influence", "Audio Influence"), ("variety", "Variety")):
            if plan[flag] is not None:
                controls[flag] = slide(page, name, plan[flag])
        controls.update(styles=plan["styles"] or "(the source's)", lyrics=plan["lyrics"] or "(the source's)")
    with contextlib.suppress(Exception):
        title_field(page).fill(title, timeout=5000)
    return controls


def press_create(page, traffic: Traffic, account: str, plan: dict, timeout_s: float = 90.0) -> list[str]:
    button = page.get_by_role("button", name="Create speech" if plan["script"] else "Create song") \
        .locator("visible=true").first
    traffic.arm()
    try:
        button.click(timeout=15000)
    except Exception as error:  # noqa: BLE001
        raise drift("the Create button stays disabled") from error
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        page.wait_for_timeout(500)
        traffic.poll()
        if traffic.clips:
            return traffic.clips
        if traffic.errors:
            status, detail = traffic.errors[0]
            low = detail.lower()
            if status == 402 or "credit" in low:
                raise gw.Failure(3, f"{account} lacks the Suno credits this costs: {detail}", account=account)
            if status == 429 or "rate" in low or "too many" in low:
                raise gw.Failure(3, f"Suno rate-limits {account}: {detail}", account=account, wall_s=1800)
            raise gw.Failure(1, f"Suno refused the generation on {account} (HTTP {status}): {detail}")
        challenge = page.locator("iframe[src*='hcaptcha'][title*='challenge']").locator("visible=true")
        if challenge.count():
            raise gw.Failure(4, f"Suno asks a captcha on {account}; its owner solves it once: suno-music login "
                                f"--account {account} --hand, then Create anything there", account=account)
    raise gw.Failure(1, f"the Create click on {account} started nothing within {timeout_s:.0f}s ({page.url})")


def wait_clips(page, account: str, ids: list[str], action: str | None, timeout_s: float) -> list[dict]:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if action:
            status, body = api(page, account, f"edit/action/{ids[0]}/")
            state = (body or {}).get("status") if isinstance(body, dict) else None
            if state == "complete":
                status, clip = api(page, account, f"clip/{ids[0]}")
                if status == 200 and isinstance(clip, dict):
                    return [clip]
            elif state not in (None, "processing", "queued", "submitted"):
                raise gw.Failure(1, f"Suno's {action} on {account} ended {state}: {body}")
        else:
            status, body = api(page, account, "feed/v3", {"filters": {"ids": {"presence": "True", "clipIds": ids}},
                                                           "limit": len(ids)})
            clips = {clip["id"]: clip for clip in (body or {}).get("clips") or []} if isinstance(body, dict) else {}
            states = [clips.get(i, {}).get("status") for i in ids]
            failed = [clips[i] for i in ids if clips.get(i, {}).get("status") == "error"]
            if failed:
                meta = failed[0].get("metadata") or {}
                raise gw.Failure(1, f"Suno failed the clip {failed[0]['id']} on {account}: "
                                    f"{meta.get('error_message') or meta.get('error_type') or 'no reason given'}")
            if states and all(state == "complete" for state in states):
                return [clips[i] for i in ids]
        page.wait_for_timeout(5000)
    gw.limit_hit.hit("suno.clip-wait", timeout_s, "s", "kill", f"Suno clips {', '.join(ids)} on {account}: never complete",
                     "share/suno_music.py:def wait_clips(")
    raise gw.Failure(1, f"Suno's clips {', '.join(ids)} were not complete after {timeout_s:.0f}s on {account}; fetch them "
                        f"later: suno-music --fetch {ids[0]} --account {account} --dest <abs .mp3>")


def format_rows(dialog) -> dict:
    return dialog.evaluate("""d => Object.fromEntries([...d.querySelectorAll('button')]
      .filter(b => /^(M4A|MP3|WAV|MP4 video asset)$/.test(b.innerText.trim()))
      .map(b => [b.innerText.trim(), !!b.querySelector('svg')]))""")


def download(page, account: str, clip: str, fmt: str, dest: Path, downloads: int,
             preview: bool = False) -> tuple[int, bool]:
    """⋯ → Download, only `fmt` ticked (the rows are toggles), then Download — or Unlock & Download, which spends one
    of the account's download unlocks the first time a song is downloaded."""
    state: dict = {}

    def prepare() -> None:
        open_page(page, account, f"/song/{clip}")
        song_menu(page, record=not preview)
        page.get_by_role("menuitem", name="Download", exact=True).first.click(timeout=8000)
        # An account with no unlock left gets Out of Downloads instead, for a song never downloaded (2026-10-23)
        dialog = page.get_by_role("dialog").filter(has_text=re.compile(r"^\s*(Download|Out of Downloads)")).last
        dialog.wait_for(timeout=10000)
        if dialog.inner_text().lstrip().startswith("Out of Downloads"):
            page.keyboard.press("Escape")
            raise NoUnlock(1, f"{account} has no Suno download unlock left for {clip}")
        for label, ticked in format_rows(dialog).items():
            if ticked != (label.lower() == fmt):
                dialog.get_by_role("button", name=label, exact=True).first.click(timeout=8000)
                page.wait_for_timeout(300)
        rows = format_rows(dialog)
        if [label for label, ticked in rows.items() if ticked] != [fmt.upper()]:
            raise drift(f"the Download dialog ticks {rows}, not only {fmt.upper()}")
        button = dialog.get_by_role("button", name=re.compile(r"^(Unlock & Download|Download)$")).last
        state["unlock"] = button.inner_text().strip() == "Unlock & Download"
        if state["unlock"] and downloads < 1:
            raise NoUnlock(1, f"{account} has no Suno download unlock left for {clip}")
        state["button"] = button

    size = gw.save_caught(page, lambda: state["button"].click(timeout=8000), dest, fmt, f"a {fmt} file", MAGIC[fmt],
                          lambda url, path: gw.save_video(page.context, url, path, MAGIC[fmt], fmt),
                          of=f" of {clip}", fail=drift, timeout_s=180, prepare=prepare)
    with contextlib.suppress(Exception):
        page.keyboard.press("Escape")
    return size, bool(state.get("unlock"))


class NoUnlock(gw.Failure):
    """The song needs an unlock the account no longer holds; a Failure, so save_caught lets it through."""


def record(page, account: str, clip: dict, fmt: str, dest: Path) -> int:
    """The song as the page plays it, routed into a recorder instead of the speakers (TAP, RECORD)."""
    length = float((clip.get("metadata") or {}).get("duration") or caps()["ranges"]["duration"]["max"])
    open_page(page, account, f"/song/{clip['id']}")
    if not page.evaluate(TAP):
        raise drift(f"the song page of {clip['id']} holds no <audio> to record")
    page.get_by_role("button", name="Play", exact=True).first.click(timeout=8000)
    taken = page.evaluate(RECORD, math.ceil(length) + 60)
    if taken.get("error"):
        raise drift(f"recording {clip['id']}: {taken['error']}")
    if taken["wall"] > taken["duration"] + 3:
        raise gw.Failure(1, f"the recording of {clip['id']} stalled: {taken['wall']:.0f} s of playing for a "
                            f"{taken['duration']:.0f} s song")
    raw = dest.with_name(f".{dest.name}.webm")
    raw.write_bytes(base64.b64decode(taken["b64"]))
    try:
        encoded = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), *ENCODE[fmt], str(dest)],
                                 capture_output=True, text=True, timeout=300)
        if encoded.returncode != 0:
            raise gw.Failure(1, f"ffmpeg could not encode the recording of {clip['id']}: {encoded.stderr.strip()[:200]}")
        level = subprocess.run(["ffmpeg", "-i", str(dest), "-af", "volumedetect", "-f", "null", "-"],
                               capture_output=True, text=True, timeout=300).stderr
    finally:
        raw.unlink(missing_ok=True)
    peak = re.search(r"max_volume: (-?[0-9.]+) dB", level)
    if not peak or float(peak.group(1)) < -60:
        raise drift(f"the recording of {clip['id']} is silent: the player no longer plays through a tapped <audio>")
    return dest.stat().st_size


def save_song(page, account: str, clip: dict, fmt: str, dest: Path, downloads: int) -> tuple[int, bool, bool]:
    """(bytes, unlocked, recorded): Suno's own file while the song is unlocked or the account holds an unlock, else
    a recording."""
    try:
        return (*download(page, account, clip["id"], fmt, dest, downloads, is_preview(clip)), False)
    except NoUnlock:
        return record(page, account, clip, fmt, dest), False, True


def model_of(clip: dict, fallback: str | None = None) -> str | None:
    """The manifest's name of the model a clip was made with (chirp-goose → v6-mini)."""
    wire = clip.get("model_name")
    names = {**{spec["wire"]: name for name, spec in caps()["models"].items()},
             **{w: name for name, w in caps()["pro_models"].items()}}
    return names.get(wire, wire) or fallback


def clip_notes(clip: dict, account: str, plan: dict, controls: dict, charged: int | None, info: dict,
               others: list[dict], recorded: bool = False) -> str:
    meta = clip.get("metadata") or {}
    lines = [f"Model: {model_of(clip, controls.get('model')) or '-'}{' preview' if is_preview(clip) else ''} "
             f"({clip.get('model_name') or '-'})",
             f"Song: {SITE}/song/{clip['id']}", f"Clip: {clip['id']}", f"Title: {clip.get('title') or controls['title']}",
             f"Account: {account}", f"Length: {float(meta.get('duration') or 0):.1f} s"]
    if plan["mode"]:
        lines.append(f"Edit: {plan['mode']} of {plan['source']}" + "".join(
            f", {key} {controls[key]}" for key in ("window", "speed", "with") if key in controls))
    lines.append(f"Credits: {charged if charged is not None else '?'} charged, {info['total_credits_left']} left; "
                 f"download unlocks left: {downloads_left(info)}")
    if recorded:
        lines.append("File: recorded as the page played it (no download unlock left), not Suno's own file")
    for other in others:
        kind = f"{model_of(other)} preview, not remixable" if is_preview(other) else model_of(other)
        lines.append(f"Other clip: {SITE}/song/{other['id']} ({kind}; in the library; its file, an unlock or a recording: "
                     f"suno-music --fetch {other['id']} --account {account} --dest <abs .mp3>)")
    lines += ["", f"Styles: {meta.get('tags') or '-'}", "", "Lyrics:", meta.get("prompt") or "-"]
    if meta.get("gpt_description_prompt"):
        lines += ["", "Description:", meta["gpt_description_prompt"]]
    return "\n".join(lines) + "\n"


def one_run(context, account: str, plan: dict) -> dict:
    page = context.new_page()
    traffic = Traffic(page)
    open_page(page, account, "/create")
    before = billing(page, account)
    if spendable(before) < plan["price"]:
        raise gw.Failure(3, f"{account} holds {before['total_credits_left']} Suno credits ({spendable(before)} spendable "
                            f"now), under the {plan['price']} this costs", account=account)
    title = f"{plan['title']}-{secrets.token_hex(2)}"
    if plan["mode"]:
        gw.click_if_visible(page, "tab", "Songs")
        gw.click_if_visible(page, "tab", "Advanced")
        clear_form(page)
        if plan["source_file"]:
            plan["source"] = upload_audio(page, traffic, account, Path(plan["source_file"]), plan["about"],
                                          caps()["upload_wait_s"])
            gw.ledger({"kind": "suno", "event": "uploaded", "account": account, "clip": plan["source"],
                       "file": Path(plan["source_file"]).name})
        attach_clip(page, account, plan["source"])
        controls = edit_form(page, traffic, account, plan, title)
    elif plan["script"]:
        controls = speech_form(page, plan, title)
    else:
        controls = song_form(page, traffic, account, plan, title)
    if plan["dry_run"]:
        page.close()
        return {"ok": True, "dry_run": True, "account": account, "controls": controls,
                "credits": before["total_credits_left"], "downloads": downloads_left(before)}
    gw.write_meta(account, suno_started_at=int(time.time()))
    started = time.time()
    gw.ledger({"kind": "suno", "event": "queued", "account": account, "title": title, "mode": plan["mode"],
               "source": plan["source"], "prompt": (plan["styles"] or plan["describe"] or plan["script"] or "")[:500]})
    ids = press_create(page, traffic, account, plan)
    clips = sorted(wait_clips(page, account, ids, traffic.action, caps()["timeout_s"]), key=is_preview)
    render_s = round(time.time() - started, 1)
    after = billing(page, account)
    charged = int(before["total_credits_left"]) - int(after["total_credits_left"])
    gw.ledger({"kind": "suno", "event": "rendered", "account": account, "clips": ids, "charged": charged,
               "credits": after["total_credits_left"], "render_s": render_s, "mode": plan["mode"]})
    takes = []
    out_dir = Path(plan["out_dir"])
    for index, clip in enumerate(clips[:plan["takes"]], start=1):
        audio = out_dir / f"take{index}.{plan['format']}"
        size, unlocked, recorded = save_song(page, account, clip, plan["format"], audio, downloads_left(after))
        after = billing(page, account)
        gw.ledger({"kind": "suno", "event": "saved", "account": account, "clip": clip["id"], "bytes": size,
                   "unlocked": unlocked, "recorded": recorded, "downloads": downloads_left(after)})
        takes.append({"audio": str(audio), "clip": clip["id"], "unlocked": unlocked, "recorded": recorded})
    library = [{"clip": c["id"], "song": f"{SITE}/song/{c['id']}", "title": c.get("title") or title,
                "duration": float((c.get("metadata") or {}).get("duration") or 0)} for c in clips]
    for take in takes:
        clip = next(c for c in clips if c["id"] == take["clip"])
        others = [c for c in clips if c["id"] not in {t["clip"] for t in takes}]
        take.update(account=account, song=f"{SITE}/song/{clip['id']}", title=clip.get("title") or title,
                    duration=float((clip.get("metadata") or {}).get("duration") or 0),
                    model=model_of(clip, controls.get("model")), charged=charged,
                    credits=after["total_credits_left"], downloads=downloads_left(after), render_s=render_s,
                    notes=clip_notes(clip, account, plan, controls, charged, after, others, take["recorded"]))
    page.close()
    return {"takes": takes, "library": library, "charged": charged, "credits": after["total_credits_left"],
            "downloads": downloads_left(after), "controls": controls}


def generate_on(account: str, plan: dict) -> dict:
    with gw.file_lock(gw.ROOT / "locks" / f"{account}.lock", wait_s=900), gw.browser(account) as context:
        result = one_run(context, account, plan)
    if result.get("dry_run"):
        return {**result, "caps": page_caps()}
    return {"ok": True, "account": account, **result, "caps": page_caps()}


def source_of(value: str | None) -> tuple[str | None, str | None]:
    """(library clip id, uploaded file) of --source: a file a suno run saved names its clip in <file>.txt."""
    if not value:
        return None, None
    if not value.startswith("/"):
        return value, None
    notes = Path(value + ".txt")
    if notes.is_file():
        found = dict(re.findall(r"^(Clip|Account): (\S+)$", notes.read_text(), re.M))
        if found.get("Clip"):
            return found["Clip"], None
    return None, value


def owner_of(value: str | None) -> str | None:
    if value and value.startswith("/") and Path(value + ".txt").is_file():
        found = dict(re.findall(r"^(Clip|Account): (\S+)$", Path(value + ".txt").read_text(), re.M))
        return found.get("Account")
    return None


def make_plan(args) -> dict:
    c = caps()
    clip, upload = source_of(args.source)
    price = c["modes"][args.mode]["price"] if args.mode else c["price"]["speech" if args.script else "song"]
    return {"styles": args.prompt, "lyrics": args.lyrics, "gender": args.gender, "duration": args.duration,
            "weirdness": args.weirdness, "style_influence": args.style_influence,
            "audio_influence": args.audio_influence, "variety": args.variety, "describe": args.describe,
            "video": args.video, "image": args.image, "script": args.script, "tone": args.tone,
            "music": args.music != "off", "mode": args.mode, "source": clip, "source_file": upload,
            "about": args.about or (Path(upload).stem if upload else ""),
            "with": source_of(args.with_song)[0] if args.with_song else None, "from_s": args.from_s, "to_s": args.to_s, "speed": args.speed,
            "keep_pitch": args.keep_pitch, "format": args.format, "takes": args.takes, "out_dir": args.out_dir,
            "dry_run": args.dry_run, "price": price, "count": 1,
            "title": re.sub(r"[^A-Za-z0-9-]+", "-", args.title or "take").strip("-")[:40] or "take"}


def cmd_generate(args) -> None:
    plan = make_plan(args)
    pinned = args.account or owner_of(args.source)
    if args.account and owner_of(args.source) and args.account != owner_of(args.source):
        raise gw.Failure(2, f"--source {args.source} is a Suno song on {owner_of(args.source)}, not {args.account}")
    if plan["source"] and not pinned:
        raise gw.Failure(2, f"--source {plan['source']} is a library song, which lives on one account: add --account")
    accounts = gw.take_accounts(pinned, lambda: rotation(plan["price"]),
                                "no Suno account is signed in, free of walls and holding the credits this needs "
                                "(suno-music --accounts lists them)", WALLS)
    gw.take_failover(accounts, plan, generate_on, set_wall, bool(pinned), lock_wait=args.lock_wait, walls_name=WALLS)


def cmd_fetch(args) -> None:
    Path(args.out_dir).mkdir(parents=True, exist_ok=True)
    with gw.file_lock(gw.ROOT / "locks" / f"{args.account}.lock", wait_s=900), gw.browser(args.account) as context:
        page = context.new_page()
        open_page(page, args.account, "/create")
        info = billing(page, args.account)
        status, clip = api(page, args.account, f"clip/{args.clip}")
        if status != 200 or not isinstance(clip, dict) or clip.get("status") != "complete":
            raise gw.Failure(1, f"no complete Suno song {args.clip} on {args.account} (HTTP {status})")
        audio = Path(args.out_dir) / f"take1.{args.format}"
        size, unlocked, recorded = save_song(page, args.account, clip, args.format, audio, downloads_left(info))
        info = billing(page, args.account)
        gw.ledger({"kind": "suno", "event": "saved", "account": args.account, "clip": args.clip, "bytes": size,
                   "unlocked": unlocked, "recorded": recorded, "downloads": downloads_left(info)})
        plan = {"mode": None, "source": None}
        controls = {"title": clip.get("title") or args.clip, "model": model_of(clip)}
        gw.emit({"ok": True, "account": args.account, "charged": 0, "credits": info["total_credits_left"],
                 "downloads": downloads_left(info), "takes": [{
            "audio": str(audio), "clip": args.clip, "account": args.account, "song": f"{SITE}/song/{args.clip}",
            "title": controls["title"], "duration": float((clip.get("metadata") or {}).get("duration") or 0),
            "model": controls["model"], "charged": 0, "credits": info["total_credits_left"],
            "downloads": downloads_left(info), "unlocked": unlocked, "recorded": recorded,
            "notes": clip_notes(clip, args.account, plan, controls, 0, info, [], recorded)}],
            "library": [], "caps": page_caps()})


def cmd_status(args) -> None:
    with gw.file_lock(gw.ROOT / "locks" / f"{args.account}.lock", wait_s=900), gw.browser(args.account) as context:
        page = context.new_page()
        open_page(page, args.account, "/create")
        info = billing(page, args.account)
        gw.emit({"ok": True, "account": args.account, "credits": info["total_credits_left"],
                 "credits_limit": info.get("monthly_limit"), "spendable": spendable(info),
                 "downloads": downloads_left(info)})


def cmd_accounts(args) -> None:
    rows = []
    for name in gw.roster():
        if not gw.valid_account(name) or not gw.profile_dir(name).is_dir():
            continue
        meta = gw.read_meta(name)
        rows.append({"account": name, "login": meta.get("suno_signed_in"), "credits": meta.get("suno_credits"),
                     "credits_limit": meta.get("suno_credits_limit"), "downloads": meta.get("suno_downloads"),
                     "as_of": meta.get("suno_at"), "walled_until": walls().get(name)})
    gw.emit({"ok": True, "accounts": rows})


def google_step(page, account: str) -> None:
    """Continue with Google → the profile's own Google account → Continue; a Google re-check is the owner's."""
    email = gw.read_meta(account).get("email")
    reject_cookies(page)
    page.get_by_role("button", name="Continue with Google").first.click(timeout=10000)
    deadline = time.time() + 90
    while time.time() < deadline:
        page.wait_for_timeout(1500)
        url = page.url
        if url.startswith(SITE):
            return
        text = page.evaluate("() => document.body ? document.body.innerText : ''")
        if "/challenge/" in url or "Verify it" in text or "Подтвердите" in text:
            raise gw.Failure(4, f"Google asks {account}'s owner to verify the account before Suno signs in; run "
                                f"suno-music login --account {account} --hand, finish the sign-in in that window and "
                                f"quit it")
        if "accountchooser" in url and email:
            with contextlib.suppress(Exception):
                page.get_by_text(email, exact=True).first.click(timeout=5000)
            continue
        consent = page.get_by_role("button", name=re.compile(r"^(Continue|Продолжить|Allow|Разрешить)$"))
        with contextlib.suppress(Exception):
            if "oauth" in url and consent.count() and consent.last.is_enabled():
                consent.last.click(timeout=5000)
    raise gw.Failure(1, f"Google's sign-in for Suno did not come back within 90s ({page.url[:120]})")


def onboard(page, account: str) -> None:
    """Birthday, the profile steps (skipped) and the plan choice (Free)."""
    for _ in range(12):
        page.wait_for_timeout(2500)
        reject_cookies(page)
        url = page.url
        if "/auth/birthday" in url:
            for placeholder, value in BIRTHDAY:
                box = page.get_by_placeholder(placeholder, exact=True)
                box.click(timeout=8000)
                box.press_sequentially(value, delay=60)
                page.wait_for_timeout(400)
                page.keyboard.press("Enter")
            page.get_by_role("button", name="Continue", exact=True).click(timeout=8000)
        elif "/onboarding" in url:
            free = page.get_by_text("Continue with Free", exact=True)
            skip = page.get_by_text("Skip", exact=True)
            if free.count():
                free.first.click(timeout=8000)
            elif skip.count():
                skip.first.click(timeout=8000)
        elif url.startswith(SITE + "/create"):
            return
    raise gw.Failure(1, f"Suno's sign-up steps did not end on /create ({page.url[:120]})")


def cmd_login(args) -> None:
    if args.hand:
        gw.LOGIN_URL, gw.LOGIN_TABS = SITE + "/sign-in", ()
        gw.LOGIN_STEPS = " (Continue with Google, any check Google asks, then Suno's birthday and Continue with Free)"
        gw.cmd_login(argparse.Namespace(account=args.account, wait=True))
        return
    with gw.file_lock(gw.ROOT / "locks" / f"{args.account}.lock", wait_s=900), gw.browser(args.account) as context:
        page = context.new_page()
        page.goto(SITE + "/create", wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(5000)
        if "/sign-in" in page.url:
            google_step(page, args.account)
        onboard(page, args.account)
        open_page(page, args.account, "/create")
        info = billing(page, args.account)
        gw.ledger({"kind": "suno", "event": "signed-in", "account": args.account})
        gw.emit({"ok": True, "account": args.account, "credits": info["total_credits_left"],
                 "downloads": downloads_left(info)})


def main() -> None:
    c = caps()
    parser = argparse.ArgumentParser(prog="suno-music-engine")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("generate")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--prompt", help="the Styles box")
    p.add_argument("--lyrics", default="")
    p.add_argument("--describe", help="the Simple form: Suno writes the lyrics and styles")
    p.add_argument("--video")
    p.add_argument("--image")
    p.add_argument("--script", help="the Speech tab's script")
    p.add_argument("--tone")
    p.add_argument("--music", choices=["on", "off"], default="on")
    p.add_argument("--gender", choices=["Male", "Female"])
    p.add_argument("--duration", type=int)
    p.add_argument("--weirdness", type=int)
    p.add_argument("--style-influence", type=int)
    p.add_argument("--audio-influence", type=int)
    p.add_argument("--variety", type=int)
    p.add_argument("--source")
    p.add_argument("--about", help="what an uploaded source is, for Suno's upload form")
    p.add_argument("--mode", choices=sorted(c["modes"]))
    p.add_argument("--with", dest="with_song")
    p.add_argument("--from", dest="from_s", type=float)
    p.add_argument("--to", dest="to_s", type=float)
    p.add_argument("--speed", type=float)
    p.add_argument("--keep-pitch", action="store_true")
    p.add_argument("--format", choices=sorted(MAGIC), default="mp3")
    p.add_argument("--takes", type=int, default=1)
    p.add_argument("--title")
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--dry-run", action="store_true")
    gw.lock_wait_arg(p)
    f = sub.add_parser("fetch")
    f.add_argument("--account", required=True, type=gw.account_arg)
    f.add_argument("--clip", required=True)
    f.add_argument("--out-dir", required=True)
    f.add_argument("--format", choices=sorted(MAGIC), default="mp3")
    s = sub.add_parser("status")
    s.add_argument("--account", required=True, type=gw.account_arg)
    sub.add_parser("accounts")
    login = sub.add_parser("login")
    login.add_argument("--account", required=True, type=gw.account_arg)
    login.add_argument("--hand", action="store_true", help="a plain Chrome window for the owner")
    args = parser.parse_args()
    account = getattr(args, "account", None)
    try:
        {"generate": cmd_generate, "fetch": cmd_fetch, "status": cmd_status, "accounts": cmd_accounts,
         "login": cmd_login}[args.command](args)
    except gw.Failure as failure:
        if failure.code != 2:
            gw.report(account or failure.extra.get("account") or "-", failure)
        gw.fail(failure.code, failure.reason)
    except Exception as error:  # noqa: BLE001
        gw.report(account or "-", error)
        gw.fail(1, gw.failure_text(error)[:300])


if __name__ == "__main__":
    main()
