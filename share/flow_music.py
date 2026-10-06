# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Music from Google Flow Music (flowmusic.app): Lyria 3.5 or Lyria 3 Pro, M4A/MP3/WAV, split stems.

Same hidden Chrome, profiles, locks and job ledger as gemini_web (Flow). The compose panel is driven the way
a person would; the song is read from the page's own traffic (the stream's tool return, /__api/clips) and
downloaded through the song's menu, caught from the page's download link. Prints one JSON line; exit 0 ok,
2 usage, 3 out of credits or walled, 4 signed out or an owner step, 1 other.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gemini_web as gw  # noqa: E402

gw.ROUTE = "flow-music"

SITE = gw.FLOW_MUSIC
WALLS = "flow-music-walls.json"
NOTICES = "notices.json"
NOTICE_KEY = "agreed_flow_music"
START_S = 90
MAGIC = {"wav": lambda b: b[:4] == b"RIFF", "mp3": lambda b: b[:3] == b"ID3" or b[:1] == b"\xff",
         "m4a": lambda b: b[4:8] == b"ftyp"}


def caps() -> dict:
    return json.loads(gw.MANIFEST.read_text())["flow_music"]


def drift(what: str) -> gw.Failure:
    return gw.Failure(1, f"Flow Music UI drift: {what}")


def walls() -> dict:
    try:
        return json.loads((gw.ROOT / WALLS).read_text())
    except (OSError, ValueError):
        return {}


def set_wall(account: str, until: float) -> None:
    gw.update_json(WALLS, lambda data: data.update({account: int(until)}))


def grant_cycle(grants: list) -> dict:
    refills = sorted(g["created_at"] for g in grants if g.get("type") == "subscription-refill" and g.get("created_at"))
    if not refills:
        return {}
    since = refills[-1]
    started = gw.datetime.datetime.fromisoformat(since.replace("Z", "+00:00")).timestamp()
    total = sum(int(g.get("credits") or 0) for g in grants if (g.get("created_at") or "")[:10] >= since[:10])
    return {"music_credits_total": total, "music_credits_renews_at": gw.month_after(started),
            "music_credits_total_source": f"grants since the subscription refill of {since[:10]}"}


def note_balance(account: str, credits: int | None, grants: list | None = None) -> None:
    if credits is not None:
        gw.write_meta(account, music_signed_in=True, music_credits=credits, music_credits_at=int(time.time()),
                      **grant_cycle(grants or []))


def rotation(price: int) -> list[str]:
    now, flow_walls, own = time.time(), gw.walls(), walls()

    def ready(name: str) -> bool:
        meta = gw.read_meta(name)
        if meta.get("music_signed_in") is False:
            return False
        fresh = now - meta.get("music_credits_at", 0) <= gw.WALL_SECONDS
        if fresh and (meta.get("music_credits") or 0) < price:
            return False
        return flow_walls.get(name, 0) <= now and own.get(name, 0) <= now and gw.in_pool(name)

    return gw.least_recent([name for name in gw.bound_accounts() if ready(name)])


class Traffic:
    """The page's own replies, read where the page asked for them; nothing is requested from outside. The
    message streams are never read: a Producer stream can stay open, and its body would block the run."""

    def __init__(self, page):
        self.pending: list = []
        self.balance: int | None = None
        self.grants: list = []
        self.clips: dict = {}
        self.errors: list[str] = []
        self.out_of_credits = False
        self.sent = False
        self.started = False
        self.armed = False
        self.chat = False
        self.jobs: set[str] = set()
        self.upload: dict | None = None
        page.on("response", lambda response: self.pending.append(response))

    def arm(self, chat: bool) -> None:
        self.poll()
        self.armed, self.chat = True, chat

    def poll(self) -> None:
        while self.pending:
            response = self.pending.pop(0)
            path = urllib.parse.urlparse(response.url).path
            if not path.startswith("/__api/"):
                continue
            if response.status == 402:
                self.out_of_credits = True
            with contextlib.suppress(Exception):
                if path == "/__api/billing/credits":
                    body = response.json()
                    self.balance = int(body["data"]["credits_remaining"])
                    self.grants = [g for g in body.get("add_token_transactions") or [] if isinstance(g, dict)]
                elif path == "/__api/clips":
                    self.clips.update(response.json().get("clips") or {})
                elif path.endswith("/upload-check-status"):
                    self.upload = response.json()
                elif not self.armed:
                    continue
                elif path == "/__api/producer/tool-call":
                    self.sent = True
                    self.jobs.add(response.json()["job_id"])
                elif path.endswith("/stream"):
                    self.sent = self.sent or self.chat or path.split("/")[-2] in self.jobs
                elif path.startswith("/__api/audio-create-song-status/"):
                    self.started = True
                    status = response.json()
                    if status.get("error_type") or status.get("error_message"):
                        self.errors.append(f"{status.get('error_type')}: {status.get('error_message')}")


def open_page(page, traffic: Traffic, account: str, path: str, timeout_s: float = 45.0) -> None:
    traffic.balance = None
    page.goto(f"{SITE}{path}", wait_until="domcontentloaded", timeout=timeout_s * 1000)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        traffic.poll()
        if traffic.balance is not None:
            gw.close_promos(page, account)
            return
        host_path = page.url.split("://", 1)[-1]
        if (host_path.startswith("accounts.google.com") or "/login" in host_path
                or page.get_by_text("Continue with Google").count()
                or (page.get_by_role("button", name="Log in", exact=True).count()
                    and page.get_by_role("button", name="Sign up", exact=True).count())):
            gw.write_meta(account, music_signed_in=False)
            raise gw.Failure(4, f"Flow Music shows {account} signed out; the owner signs in once at flowmusic.app "
                                "(Continue with Google)")
        page.wait_for_timeout(300)
    raise gw.Failure(1, f"Flow Music did not load within {timeout_s:.0f}s ({page.url})")


def field(page, label: str):
    return page.get_by_text(label, exact=True).locator("xpath=following::input[1]").first


def set_switch(page, name: str, on: bool) -> None:
    switch = page.get_by_role("switch", name=name, exact=True)
    try:
        if (switch.get_attribute("aria-checked", timeout=8000) == "true") != on:
            switch.click(timeout=8000)
            page.wait_for_timeout(400)
        ok = (switch.get_attribute("aria-checked") == "true") == on
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {name!r} toggle in the compose panel") from error
    if not ok:
        raise drift(f"the {name!r} toggle does not stick")


def fill(page, target, value: str, what: str) -> None:
    try:
        target.fill("", timeout=8000)
        if value:
            (target.press_sequentially if hasattr(target, "press_sequentially") else target.type)(value)
        target.press("Tab")
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {what} field in the compose panel") from error


def pick_model(page, label: str) -> None:
    current = page.get_by_role("button", name=re.compile(r"^Lyria ")).first
    try:
        if current.inner_text(timeout=8000).strip() != label:
            current.click()
            page.get_by_role("menuitem", name=re.compile("^" + re.escape(label) + " ")).first.click(timeout=8000)
            page.wait_for_timeout(500)
        chosen = current.inner_text().strip()
    except Exception as error:  # noqa: BLE001
        raise drift(f"no menu item for the model {label!r}") from error
    if chosen != label:
        raise drift(f"the model chip shows {chosen!r}, not {label!r}")


def compose(page, plan: dict) -> dict:
    """Every control is set on each take: the panel keeps the last session's values."""
    sound = page.get_by_role("textbox", name="Sound description", exact=True)
    try:
        if not sound.is_visible():
            page.get_by_role("button", name="Toggle compose panel", exact=True).click(timeout=8000)
        sound.wait_for(timeout=10000)
    except Exception as error:  # noqa: BLE001
        raise drift("no compose panel (Toggle compose panel)") from error
    fill(page, page.get_by_role("textbox", name="Lyrics", exact=True), plan["lyrics"], "Lyrics")
    set_switch(page, "Toggle instrumental mode", plan["instrumental"])
    fill(page, sound, plan["sound"], "Sound description")
    set_switch(page, "Toggle advanced sound mode", True)
    for label in ("BPM", "Length", "Seed"):
        fill(page, field(page, label), plan[label.lower()], label)
    if plan["length"] and field(page, "Length").input_value() != plan["length"]:
        raise drift(f"the Length field shows {field(page, 'Length').input_value()!r}, not {plan['length']!r}")
    pick_model(page, plan["model_label"])
    details = page.get_by_role("button", name="Expand Details section", exact=True)
    if details.count():
        details.click()
    # The anchor text is the empty field's placeholder and vanishes once typed into, so the field is pinned first.
    try:
        title = page.get_by_text("Add title (optional)", exact=True).locator("xpath=following::textarea[1]").first \
            .element_handle(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift("no title field in the compose panel") from error
    fill(page, title, plan["title"], "title")
    return {"model": page.get_by_role("button", name=re.compile(r"^Lyria ")).first.inner_text().strip(),
            "instrumental": plan["instrumental"], "length": field(page, "Length").input_value() or "Auto",
            "bpm": field(page, "BPM").input_value() or "Auto", "seed": field(page, "Seed").input_value() or "Auto",
            "title": plan["title"]}


def answer_notice(page, account: str) -> bool:
    """The upload consent notice is no [role=dialog] (the page dump lists no dialog), so it is found by its own
    I agree button beside its text."""
    agree = page.get_by_role("button", name="I agree", exact=True)
    text = page.get_by_text("necessary rights", exact=False)
    if not (agree.count() and agree.first.is_visible() and text.count() and text.first.is_visible()):
        return False
    try:
        agreed = json.loads((gw.ROOT / NOTICES).read_text()).get(NOTICE_KEY, [])
    except (OSError, ValueError):
        agreed = []
    if account not in agreed:
        raise gw.Failure(4, f"{account} shows Flow Music's upload notice (\"necessary rights\"); it needs the owner's "
                            f"one-time I agree: with his yes, add {account} to \"{NOTICE_KEY}\" in {gw.ROOT / NOTICES}")
    agree.first.click(timeout=8000)
    gw.ledger({"kind": "flow-music", "event": "notice-agreed", "account": account})
    return True


def attach_audio(page, traffic: Traffic, account: str, path: Path, wait_s: float) -> None:
    choosers: list = []
    page.on("filechooser", lambda chooser: choosers.append(chooser))

    def open_menu() -> None:
        page.get_by_role("button", name="Add audio or image").first.click(timeout=8000)
        page.get_by_role("menuitem", name=re.compile(r"^Audio")).first.click(timeout=8000)

    try:
        open_menu()
    except Exception as error:  # noqa: BLE001
        raise drift("no Audio item under Add audio or image") from error
    deadline = time.time() + 10
    while not choosers and time.time() < deadline:
        if answer_notice(page, account):
            page.wait_for_timeout(1000)
            if not choosers:
                open_menu()
        page.wait_for_timeout(250)
    if not choosers:
        raise gw.Failure(1, "the Audio upload opened no file chooser")
    traffic.poll()
    traffic.upload = None
    choosers[-1].set_files(str(path))
    chip = page.get_by_role("button", name=f"Remove {path.name}", exact=True)
    deadline = time.time() + wait_s
    while time.time() < deadline:
        page.wait_for_timeout(1000)
        traffic.poll()
        if (traffic.upload or {}).get("status") in (None, "pending"):
            continue
        # A refused upload (vocals, a copyright match) also reports "complete"; the page then drops the chip.
        errors = []
        for _ in range(6):
            page.wait_for_timeout(250)
            errors += [" ".join(t.split()) for t in page.evaluate(gw.PAGE_DUMP)["toasts"] if "Error" in t]
        if chip.count():
            return
        flags = [k for k in ("has_vocals", "has_cid_match", "lyrics_moderation_failed") if traffic.upload.get(k)]
        said = re.sub(r"^Notification\s*Error\s*", "", errors[-1]) if errors else ", ".join(flags) or "no reason shown"
        raise gw.Failure(1, f"Flow Music refused the reference audio upload: {said[:200]}")
    raise gw.Failure(1, f"the reference audio upload did not finish within {wait_s:.0f}s")


def chat_opening(plan: dict) -> str:
    if not plan.get("mode"):
        return f"Make a song with my uploaded audio as the reference track. Sound: {plan['sound']}"
    span = f"{clock(plan['from_s'] or 0)}-{clock(plan['to_s'] or 0)}"
    asked = {"cover": "Make a cover of my uploaded audio", "variation": "Make a variation of my uploaded audio",
             "extend": f"Extend my uploaded audio until {clock(plan['to_s'] or 0)}",
             "replace": f"Replace {span} of my uploaded audio", "trim": f"Trim my uploaded audio to {span}"}
    return f"{asked[plan['mode']]}. Title the result \"{plan['title']}\". {plan['sound']}".strip()


def send(page, traffic: Traffic, plan: dict) -> None:
    traffic.arm(chat=bool(plan["ref_audio"]))
    if plan["ref_audio"]:
        words = [chat_opening(plan)]
        if plan["lyrics"]:
            words.append(f"Lyrics:\n{plan['lyrics']}")
        elif plan["instrumental"]:
            words.append("Instrumental, no vocals.")
        if plan["length"]:
            words.append(f"Length {plan['length']}.")
        box = page.get_by_role("textbox", name="Chat message").or_(page.get_by_placeholder("Ask Producer...")).first
        box.click(timeout=8000)
        page.keyboard.insert_text("\n".join(words))
        page.get_by_role("button", name="Send message").first.click(timeout=8000)
        return
    try:
        page.get_by_role("button", name="Generate", exact=True).click(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift("the Generate button stays disabled") from error


def library_row(page, traffic: Traffic, account: str, title: str) -> dict | None:
    open_page(page, traffic, account, "/library/my-songs")
    row = page.get_by_role("button", name=f"Open details for {title}", exact=True)
    with contextlib.suppress(Exception):
        row.first.wait_for(timeout=5000)
    if not row.count():
        return None
    # The last m:ss is the length: a trimmed song's title carries its own times.
    lengths = re.findall(r"\b(\d+):(\d\d)\b", row.first.inner_text())
    if not lengths:
        return None
    minutes, seconds = lengths[-1]
    href = page.get_by_role("link", name=title, exact=True).first.get_attribute("href") or ""
    return {"id": href.rsplit("/", 1)[-1], "seconds": int(minutes) * 60 + int(seconds)}


def wait_song(page, traffic: Traffic, account: str, plan: dict, title: str, started: float) -> dict:
    checked = 0.0
    generated, retried = started, False
    while True:
        traffic.poll()
        gw.close_promos(page, account)
        if traffic.out_of_credits or page.get_by_text("You're out of credits").count():
            raise gw.Failure(3, f"{account} is out of Flow Music credits", account=account)
        if traffic.errors:
            raise gw.Failure(1, f"Flow Music returned no track on {account}: {traffic.errors[0][:200]}")
        for clip in traffic.clips.values():
            if clip.get("title") != title:
                continue
            traffic.started = True
            if clip.get("audio_url") and (clip.get("duration") or {}).get("status") == "completed":
                return {"id": clip["id"], "seconds": float(clip["duration"]["value"])}
        now = time.time()
        elapsed = now - started
        if not traffic.sent and elapsed > 60:
            raise gw.Failure(1, f"the prompt was never sent on {account}: no generation call within 60s")
        # Until a song shows in traffic the page stays on the session: the library check navigates away.
        waiting = not plan["ref_audio"] and not traffic.started
        if waiting and now - generated > START_S:
            if retried:
                song = library_row(page, traffic, account, title)
                if song:
                    return song
                gw.ledger({"kind": "flow-music", "event": "no-song", "account": account, "title": title})
                raise gw.Failure(1, f"no track started on {account}: Flow Music made no song within {START_S}s of "
                                    f"either of 2 Generate clicks ({page.url})")
            gw.ledger({"kind": "flow-music", "event": "regenerate", "account": account, "title": title})
            send(page, traffic, plan)
            generated, retried = time.time(), True
        elif not waiting and traffic.sent and elapsed > 30 and elapsed - checked >= 20:
            checked = elapsed
            song = library_row(page, traffic, account, title)
            if song:
                return song
        if elapsed > plan["timeout_s"]:
            gw.ledger({"kind": "flow-music", "event": "timeout", "account": account, "url": page.url})
            raise gw.Failure(1, f"no track after {plan['timeout_s']}s on {account} ({page.url})")
        page.wait_for_timeout(1000)


def submenu_pick(page, parent: str, name: str) -> None:
    """A pointer click on a Radix submenu item lands on <html> once the submenu sits left of its menu, so the
    item is focused and chosen with Enter."""
    target = page.get_by_role("menuitem", name=name, exact=True)
    trigger = page.get_by_role("menuitem", name=parent, exact=True).first
    trigger.hover()
    page.wait_for_timeout(500)
    if not target.count() or not target.first.is_visible():
        trigger.focus()
        page.keyboard.press("ArrowRight")
        page.wait_for_timeout(500)
    target.first.focus(timeout=8000)
    page.keyboard.press("Enter")


def song_menu(page, title: str):
    page.get_by_role("button", name=f"More options for {title}", exact=True).first.click(timeout=30000)
    page.wait_for_timeout(500)


def to_library(page, traffic: Traffic, account: str, title: str) -> None:
    if "/library/my-songs" not in page.url:
        open_page(page, traffic, account, "/library/my-songs")
    try:
        page.get_by_role("button", name=f"More options for {title}", exact=True).first.wait_for(timeout=30000)
    except Exception as error:  # noqa: BLE001
        raise drift(f"the library lists no song {title!r}") from error


def download(page, title: str, fmt: str, dest: Path) -> int:
    def trigger():
        song_menu(page, title)
        submenu_pick(page, "Download", fmt.upper())

    try:
        return gw.save_caught(page, trigger, dest, fmt, f"a {fmt} file", MAGIC[fmt],
                              lambda url, dest: gw.save_video(page.context, url, dest, MAGIC[fmt], fmt),
                              of=f" of {title}", fail=drift, timeout_s=180)
    finally:
        with contextlib.suppress(Exception):
            page.keyboard.press("Escape")


def split_stems(page, traffic: Traffic, account: str, title: str, names: list[str], timeout_s: float) -> list[str]:
    """The split runs as a Producer chat whose stream can stay open, so the stems are awaited as library rows."""
    song_menu(page, title)
    page.get_by_role("menuitem", name="Split stems", exact=True).first.focus(timeout=8000)
    page.keyboard.press("Enter")
    page.wait_for_timeout(5000)
    started = time.time()
    while time.time() - started < timeout_s:
        open_page(page, traffic, account, "/library/my-songs")
        listed = [name for name in names if page.get_by_role(
            "button", name=f"More options for {title} - {name}", exact=True).count()]
        if len(listed) == len(names):
            return listed
        page.wait_for_timeout(15000)
    raise gw.Failure(1, f"the stem split returned no take on {account} within {timeout_s:.0f}s")


EDIT_MENU = {"cover": "Cover", "extend": "Extend", "replace": "Replace", "variation": "Use prompt", "trim": "Trim"}


def clock(seconds: int) -> str:
    return f"{seconds // 60}:{seconds % 60:02d}"


def set_clock(page, box, seconds: int, what: str) -> None:
    try:
        box.click(timeout=8000)
        box.press("Meta+a")
        box.type(clock(seconds))
        box.press("Enter")
        page.wait_for_timeout(300)
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {what} field") from error


def open_edit(page, traffic: Traffic, account: str, plan: dict) -> list[str]:
    to_library(page, traffic, account, plan["edit"])
    trimmed = trimmed_titles(page, plan["edit"])
    song_menu(page, plan["edit"])
    try:
        submenu_pick(page, "Remix", EDIT_MENU[plan["mode"]])
    except Exception as error:  # noqa: BLE001
        raise drift(f"no Remix → {EDIT_MENU[plan['mode']]} menu item for {plan['edit']!r}") from error
    page.wait_for_timeout(2000)
    return trimmed


def edit_window(page, plan: dict) -> str:
    """Extend and Replace take their window in the Settings popover; Flow moves an Extend start to keep the
    extension 30-150 s long, so the label it shows afterwards is the truth."""
    mode, start_s = plan["mode"], plan["from_s"]
    try:
        if start_s is None:
            length = page.get_by_role("button", name="Copy duration timestamp", exact=True).first.inner_text(timeout=8000)
            minutes, seconds = re.fullmatch(r"(\d+):(\d\d)(?:\.\d+)?", length.strip()).groups()
            start_s = int(minutes) * 60 + int(seconds)
        page.get_by_role("button", name="Settings", exact=True).first.click(timeout=8000)
        page.wait_for_timeout(500)
        boxes = page.locator("[role=dialog]").last.get_by_role("textbox")
        boxes.nth(1).wait_for(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {mode} Settings popover") from error
    set_clock(page, boxes.nth(0), start_s, f"{mode} start")
    set_clock(page, boxes.nth(1), plan["to_s"], f"{mode} end")
    page.keyboard.press("Escape")
    page.wait_for_timeout(400)
    label = page.get_by_text(re.compile(r"^(Extend|Replace) \d+:\d\d-\d+:\d\d$")).first
    shown = label.inner_text().split(" ", 1)[1] if label.count() else "nothing"
    start = clock(start_s)
    if shown != f"{start}-{clock(plan['to_s'])}":
        raise gw.Failure(2, f"Flow Music set the {mode} window to {shown}, not {start}-{clock(plan['to_s'])} "
                            f"(an extension is 30-150 s and starts at most at the song's end; a replaced part lies "
                            f"inside the song)")
    return shown


def set_strength(page, value: float) -> None:
    slider = page.get_by_role("slider").first
    try:
        slider.focus(timeout=8000)
        page.keyboard.press("Home")
        for _ in range(round(value * 100)):
            page.keyboard.press("ArrowRight")
        now = float(slider.get_attribute("aria-valuenow") or -1)
    except Exception as error:  # noqa: BLE001
        raise drift("no Strength slider in the Cover panel") from error
    if abs(now - value) > 0.005:
        raise drift(f"the Strength slider shows {now}, not {value}")


def edit_lyrics(page, lyrics: str) -> None:
    """Edit Lyrics turns the new text into a diff written into the Instruction box."""
    dialog = page.get_by_role("dialog", name="Edit Lyrics")
    try:
        page.get_by_role("button", name="Edit Lyrics", exact=True).first.click(timeout=8000)
        box = dialog.get_by_role("textbox").nth(1)
        box.click(timeout=8000)
        page.keyboard.press("Meta+a")
        page.keyboard.insert_text(lyrics)
        dialog.get_by_role("button", name="Done", exact=True).click(timeout=8000)
        page.wait_for_timeout(1000)
    except Exception as error:  # noqa: BLE001
        raise drift("no Edit Lyrics dialog in the edit panel") from error


def panel_title(page):
    return page.get_by_role("button", name="Generate", exact=True).first.locator("xpath=ancestor::*[2]") \
        .locator("textarea").last


def edit_panel(page, plan: dict, title: str) -> dict:
    controls = {"mode": plan["mode"], "source": plan["edit"], "title": title}
    if plan["mode"] in ("extend", "replace"):
        controls["window"] = edit_window(page, plan)
    if plan["mode"] == "cover" and plan["strength"] is not None:
        set_strength(page, plan["strength"])
        controls["strength"] = plan["strength"]
    if plan["mode"] != "variation":
        if plan["lyrics"]:
            edit_lyrics(page, plan["lyrics"])
        instruction = page.get_by_role("textbox", name="Instruction", exact=True)
        try:
            words = "\n".join(filter(None, [instruction.input_value(timeout=8000), plan["sound"]]))
            instruction.fill(words)
        except Exception as error:  # noqa: BLE001
            raise drift(f"no Instruction box in the {plan['mode']} panel") from error
        controls["instruction"] = words
        if plan["seed"]:
            page.get_by_role("button", name="Expand Advanced section", exact=True).first.click(timeout=8000)
            fill(page, field(page, "Seed"), plan["seed"], "Seed")
            controls["seed"] = field(page, "Seed").input_value()
    details = page.get_by_role("button", name="Expand Details section", exact=True)
    if details.count():
        details.first.click()
    fill(page, panel_title(page), title, "title")
    return controls


def trim_window(page, plan: dict) -> dict:
    dialog = page.get_by_role("dialog", name="Trim Song")
    boxes = dialog.get_by_role("textbox")
    try:
        boxes.nth(1).wait_for(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift("no Trim Song dialog") from error
    # The end goes first: an end typed while the start reads 0:00 pulls the start to 10 s before it.
    set_clock(page, boxes.nth(1), plan["to_s"], "trim end")
    set_clock(page, boxes.nth(0), plan["from_s"], "trim start")
    shown = [boxes.nth(i).input_value() for i in (0, 1)]
    if [re.sub(r"\.0$", "", value) for value in shown] != [clock(plan["from_s"]), clock(plan["to_s"])]:
        raise gw.Failure(2, f"Flow Music set the trim to {shown[0]}-{shown[1]}, not "
                            f"{clock(plan['from_s'])}-{clock(plan['to_s'])} (the trim lies inside the song)")
    return {"mode": "trim", "source": plan["edit"], "window": "-".join(shown)}


def trimmed_titles(page, source: str) -> list[str]:
    # "Open details for" also names the row's draggable wrapper, which has no aria-label of its own.
    rows = page.get_by_role("button", name=re.compile("^More options for " + re.escape(f"{source} (trim ")))
    return [(rows.nth(i).get_attribute("aria-label") or "")[len("More options for "):] for i in range(rows.count())]


def press_trim(page, traffic: Traffic, account: str, plan: dict, before: list[str], timeout_s: float = 60) -> str:
    """Trim saves "<source> (trim <start>-<end>)" at once and for free; the new row is the title whose count grew.
    `before` is read ahead of the dialog, whose modal hides the rows behind it."""
    page.get_by_role("dialog", name="Trim Song").get_by_role("button", name="Trim", exact=True).click(timeout=8000)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        page.wait_for_timeout(3000)
        to_library(page, traffic, account, plan["edit"])
        after = trimmed_titles(page, plan["edit"])
        grown = [title for title in dict.fromkeys(after) if after.count(title) > before.count(title)]
        if grown:
            return grown[0]
    raise gw.Failure(1, f"the trim made no track on {account} within {timeout_s:.0f}s")


def save_song(page, traffic: Traffic, account: str, title: str, plan: dict, take: int, split: bool) -> tuple:
    out_dir = Path(plan["out_dir"])
    to_library(page, traffic, account, title)
    audio = out_dir / f"take{take}.{plan['format']}"
    size = download(page, title, plan["format"], audio)
    stems: dict[str, str] = {}
    if plan["stems"]:
        names = caps()["stems"]
        if split:
            names = split_stems(page, traffic, account, title, names, plan["timeout_s"])
        for name in names:
            path = out_dir / f"take{take}-{name}.{plan['format']}"
            to_library(page, traffic, account, f"{title} - {name}")
            download(page, f"{title} - {name}", plan["format"], path)
            stems[name] = str(path)
    return audio, size, stems


def one_take(context, account: str, plan: dict, take: int) -> dict:
    page = context.new_page()
    traffic = Traffic(page)
    open_page(page, traffic, account, "/library/my-songs" if plan["edit"] else "/session")
    before = traffic.balance
    note_balance(account, before, traffic.grants)
    if before < plan["price"]:
        raise gw.Failure(3, f"{account} holds {before} Flow Music credits, under the {plan['price']} a "
                            f"{plan['mode'] or 'song'} costs", account=account)
    title = f"{plan['title']}-{secrets.token_hex(2)}"
    if plan["edit"]:
        trimmed = open_edit(page, traffic, account, plan)
        controls = trim_window(page, plan) if plan["mode"] == "trim" else edit_panel(page, plan, title)
    else:
        controls = compose(page, {**plan, "title": title})
    if plan["ref_audio"]:
        attach_audio(page, traffic, account, Path(plan["ref_audio"]), plan["upload_wait_s"])
    if plan["dry_run"]:
        return {"ok": True, "dry_run": True, "account": account, "controls": controls, "credits": before}
    started = time.time()
    gw.ledger({"kind": "flow-music", "event": "queued", "account": account, "take": take, "model": plan["model"],
               "prompt": plan["sound"][:500], "title": title, "mode": plan["mode"], "source": plan["edit"]})
    session = page.url
    if plan["mode"] == "trim" and plan["edit"]:
        title = press_trim(page, traffic, account, plan, trimmed)
        song = library_row(page, traffic, account, title)
        if not song:
            raise gw.Failure(1, f"the trim made no track on {account}: the library lists {title!r} without a length")
    else:
        send(page, traffic, {**plan, "title": title})
        session = page.url
        song = wait_song(page, traffic, account, plan, title, started)
        session = page.url if "/session/" in page.url else session
    render_s = round(time.time() - started, 1)
    open_page(page, traffic, account, "/library/my-songs")
    after = traffic.balance
    note_balance(account, after, traffic.grants)
    charged = before - after
    audio, size, stems = save_song(page, traffic, account, title, plan, take, split=True)
    stems_charged = after - traffic.balance if plan["stems"] else None
    note_balance(account, traffic.balance, traffic.grants)
    seconds = song["seconds"]
    model = f"flow-music-{plan['mode']}" if plan["mode"] else plan["model"]
    gw.ledger({"kind": "flow-music", "event": "saved", "account": account, "clip": song["id"], "model": model,
               "bytes": size, "seconds": round(seconds, 1), "charged": charged, "credits": traffic.balance,
               "stems": sorted(stems), "stems_charged": stems_charged, "render_s": render_s, "mode": plan["mode"]})
    head = f"Session: {session}\nSong: {SITE}/song/{song['id']}\nTitle: {title}\nAccount: {account}\n"
    tail = f"Credits: {charged} charged, {traffic.balance} left\n"
    if plan["mode"]:
        notes = (f"Model: {model}\n{head}Source: {plan['edit'] or plan['ref_audio']}\nLength: {seconds:.1f} s"
                 + "".join(f", {key} {controls[key]}" for key in ("window", "strength", "seed") if key in controls)
                 + f"\n{tail}\nInstruction:\n{controls.get('instruction') or plan['sound'] or '-'}")
    else:
        notes = (f"Model: {plan['model']} ({controls['model']})\n{head}Length: {seconds:.1f} s (asked "
                 f"{controls['length']}), BPM {controls['bpm']}, seed {controls['seed']}\n{tail}\nSound:\n"
                 f"{plan['sound']}\n\nLyrics:\n{plan['lyrics'] or ('instrumental' if plan['instrumental'] else '-')}")
    page.close()
    return {"audio": str(audio), "stems": stems, "account": account, "url": session, "song": f"{SITE}/song/{song['id']}",
            "clip": song["id"], "model": model, "duration": seconds, "charged": charged,
            "stems_charged": stems_charged, "credits": traffic.balance, "title": title, "notes": notes,
            "render_s": render_s}


def generate_on(account: str, plan: dict) -> dict:
    takes: list[dict] = []
    first = plan.get("first_take", 1)
    with gw.file_lock(gw.ROOT / "locks" / f"{account}.lock", wait_s=900), gw.browser(account) as context:
        if not plan["dry_run"]:
            gw.note_started(account)
        for take in range(first, first + plan["count"]):
            try:
                result = one_take(context, account, plan, take)
            except Exception as error:
                error.takes = takes
                raise
            if result.get("dry_run"):
                return result
            takes.append(result)
    return {"ok": True, "account": account, "takes": takes}


def child_command() -> list[str]:
    override = os.environ.get("FLOW_MUSIC_CHILD")
    return shlex.split(override) if override else [sys.executable, str(Path(__file__).resolve())]


def child_argv(args, account: str, out_dir: Path) -> list[str]:
    argv = ["generate", "--prompt", args.prompt, "--out-dir", str(out_dir), "--account", account, "--fanned",
            "--model", args.model, "--format", args.format, "--count", str(args.count)]
    for flag in ("lyrics", "vocals", "genre", "duration", "length", "bpm", "seed", "ref_audio", "title"):
        value = getattr(args, flag)
        if value is not None:
            argv += ["--" + flag.replace("_", "-"), str(value)]
    for flag, value in (("--edit", args.edit), ("--mode", args.mode), ("--from", args.from_s), ("--to", args.to_s),
                        ("--strength", args.strength)):
        if value is not None:
            argv += [flag, str(value)]
    return argv + (["--stems"] if args.stems else []) + (["--dry-run"] if args.dry_run else [])


def last_json(text: str) -> dict:
    for line in reversed(text.splitlines()):
        with contextlib.suppress(ValueError):
            value = json.loads(line)
            if isinstance(value, dict):
                return value
    return {}


def fan_out(args, accounts: list[str]) -> None:
    runs = []
    for account in accounts:
        out_dir = Path(args.out_dir) / account
        out_dir.mkdir(parents=True, exist_ok=True)
        runs.append((account, subprocess.Popen([*child_command(), *child_argv(args, account, out_dir)],
                                               stdout=subprocess.PIPE, text=True)))
    takes, failed = [], []
    for account, run in runs:
        out, _ = run.communicate()
        result = last_json(out)
        if result.get("ok") and result.get("dry_run"):
            takes.append({"account": account, "dry_run": True, "controls": result.get("controls")})
        elif result.get("ok"):
            takes += result.get("takes") or []
        else:
            failed.append((account, run.returncode or 1, result.get("reason") or f"exit {run.returncode}"))
    if args.dry_run and takes:
        gw.emit({"ok": True, "dry_run": True, "account": takes[0]["account"], "runs": takes})
        return
    summary = "; ".join(f"{account}: {reason}" for account, _, reason in failed)
    if takes:
        result = {"ok": True, "account": takes[0]["account"], "takes": takes}
        if failed:
            result["short"] = f"{len(accounts) - len(failed)} of {len(accounts)} accounts delivered; {summary}"
        gw.emit(result)
        return
    codes = {code for _, code, _ in failed}
    gw.fail(3 if 3 in codes else 4 if codes == {4} else min(codes - {3, 4}, default=1), summary)


def make_plan(args) -> dict:
    c = caps()
    length = None
    if args.duration is not None:
        length = f"{args.duration // 60}:{args.duration % 60:02d}"
    elif args.length:
        length = c["lengths"][args.length]
    sound = f"{args.genre}. {args.prompt}" if args.genre else args.prompt
    upload = args.edit if args.edit and args.edit.startswith("/") else None
    return {"sound": sound, "lyrics": args.lyrics or "", "instrumental": args.vocals == "instrumental",
            "bpm": str(args.bpm) if args.bpm else "", "length": length or "", "seed": "" if args.seed is None else str(args.seed),
            "model": args.model, "model_label": c["models"][args.model], "format": args.format, "stems": args.stems,
            "ref_audio": upload or args.ref_audio, "edit": None if upload else args.edit, "mode": args.mode,
            "from_s": args.from_s, "to_s": args.to_s, "strength": args.strength, "count": args.count,
            "out_dir": args.out_dir, "dry_run": args.dry_run, "timeout_s": c["timeout_s"],
            "price": c["edit"][args.mode]["price"] if args.mode else c["price_per_song"], "upload_wait_s": c["upload_wait_s"],
            "title": re.sub(r"[^A-Za-z0-9-]+", "-", args.title or "take").strip("-")[:40] or "take"}


def cmd_generate(args) -> None:
    if bool(args.edit) != bool(args.mode):
        raise gw.Failure(2, "--edit and --mode go together")
    if args.edit and not args.edit.startswith("/") and not args.account:
        raise gw.Failure(2, f"--edit {args.edit!r} is a library title, which lives on one account: add --account")
    plan = make_plan(args)
    accounts = gw.take_accounts(args.account, lambda: rotation(plan["price"]),
                                "no Flow Music account is free of walls and holds a song's credits")
    if args.accounts > 1 and not args.account:
        fan_out(args, accounts[:args.accounts])
        return
    gw.take_failover(accounts, plan, generate_on, set_wall, bool(args.account), wall_pinned=args.fanned)


def cmd_status(args) -> None:
    with gw.file_lock(gw.ROOT / "locks" / f"{args.account}.lock", wait_s=900), gw.browser(args.account) as context:
        page = context.new_page()
        traffic = Traffic(page)
        open_page(page, traffic, args.account, "/settings")
        note_balance(args.account, traffic.balance, traffic.grants)
        gw.emit({"ok": True, "account": args.account, "music_credits": traffic.balance})


def cmd_fetch(args) -> None:
    plan = {"out_dir": args.out_dir, "format": args.format, "stems": args.stems, "timeout_s": caps()["timeout_s"]}
    Path(args.out_dir).mkdir(parents=True, exist_ok=True)
    with gw.file_lock(gw.ROOT / "locks" / f"{args.account}.lock", wait_s=900), gw.browser(args.account) as context:
        page = context.new_page()
        traffic = Traffic(page)
        open_page(page, traffic, args.account, "/library/my-songs")
        audio, size, stems = save_song(page, traffic, args.account, args.title, plan, 1, split=False)
        gw.emit({"ok": True, "account": args.account, "takes": [
            {"audio": str(audio), "stems": stems, "account": args.account, "title": args.title, "bytes": size,
             "credits": traffic.balance}]})


def main() -> None:
    c = caps()
    parser = argparse.ArgumentParser(prog="flow-music-engine")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("generate")
    p.add_argument("--prompt", default="")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--model", choices=sorted(c["models"]), default=c["default_model"])
    p.add_argument("--format", choices=sorted(c["formats"]), default="mp3")
    p.add_argument("--lyrics")
    p.add_argument("--vocals", choices=["on", "instrumental"])
    p.add_argument("--genre")
    p.add_argument("--duration", type=int)
    p.add_argument("--length", choices=sorted(c["lengths"]))
    p.add_argument("--bpm", type=int)
    p.add_argument("--seed", type=int)
    p.add_argument("--ref-audio")
    p.add_argument("--stems", action="store_true")
    p.add_argument("--edit")
    p.add_argument("--mode", choices=sorted(c["edit"]))
    p.add_argument("--from", dest="from_s", type=int)
    p.add_argument("--to", dest="to_s", type=int)
    p.add_argument("--strength", type=float)
    p.add_argument("--title")
    p.add_argument("--count", type=int, default=1)
    p.add_argument("--accounts", type=int, default=1)
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--fanned", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("status")
    s.add_argument("--account", required=True, type=gw.account_arg)
    f = sub.add_parser("fetch")
    f.add_argument("--account", required=True, type=gw.account_arg)
    f.add_argument("--title", required=True)
    f.add_argument("--out-dir", required=True)
    f.add_argument("--format", choices=sorted(c["formats"]), default="mp3")
    f.add_argument("--stems", action="store_true")
    args = parser.parse_args()
    account = getattr(args, "account", None)
    try:
        {"status": cmd_status, "fetch": cmd_fetch, "generate": cmd_generate}[args.command](args)
    except gw.Failure as failure:
        if failure.code != 2:
            gw.report(account or failure.extra.get("account") or "-", failure)
        gw.fail(failure.code, failure.reason)
    except Exception as error:  # noqa: BLE001
        gw.report(account or "-", error)
        gw.fail(1, gw.failure_text(error)[:300])


if __name__ == "__main__":
    main()
