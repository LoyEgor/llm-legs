# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Images from Google Flow (flow.google.com, Nano Banana) for `gemini-image --route flow`.

Same hidden Chrome, profiles, locks, walls, rotation and job ledger as gemini_web (Flow video). The project
composer is switched to Image and driven the way a person would; the new images are read from the page's own
generation reply (ogiZ0b), the 1K original from its signed URL, the 2K upscale through the image editor's
Download menu. A resume types the new prompt into an earlier image's editor (What do you want to change?).
Prints one JSON line; exit 0 ok, 2 usage, 3 walled or flagged, 4 signed out or an owner step, 5 account busy (its
lock not free within --lock-wait), 1 other. A --count run whose sibling takes never came back delivers the ones
that did, with "failed" counting the rest.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import json
import math
import os
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gemini_web as gw  # noqa: E402

IMAGE_RPCS = {"ogiZ0b"}
KIND = "flow-image"
CARDS_SCAN_S = 3
GENERATION_FAILED = "flow_generation_failed (not charged)"
# No quota-shaped code has been seen live (2026-10-04: AUDIO_FILTERED, UNSAFE_GENERATION, UNUSUAL_ACTIVITY only);
# one is a limit to move past, not a refusal of the prompt that would cost the whole job.
QUOTA_ERROR = re.compile(r"PUBLIC_ERROR_\w*(?:QUOTA|LIMIT|EXHAUSTED)\w*")
# Flow's "Failed / Sorry, this image failed to generate / You have not been charged" card and its Retry
# button. Cards on the page before the send belong to earlier jobs: "mark" remembers them, "count" and
# "retry" see only the rest.
FAILED_CARDS = """(op) => {
    const old = globalThis.__llmFlowFailedOld ||= new WeakSet();
    const retryOf = (card) => [...card.querySelectorAll('button')].filter(b =>
        /(^|\\s)Retry$/.test((b.getAttribute('aria-label') || b.innerText || '').trim()));
    const cards = [];
    for (const node of document.querySelectorAll('body *')) {
        if (![...node.childNodes].some(t => t.nodeType === 3 && /failed to generate/i.test(t.textContent))) continue;
        let card = node;
        while (card && retryOf(card).length !== 1) card = retryOf(card).length > 1 ? null : card.parentElement;
        if (card && !cards.includes(card)) cards.push(card);
    }
    if (op === 'mark') { cards.forEach(c => old.add(c)); return cards.length; }
    const fresh = cards.filter(c => !old.has(c));
    return op === 'retry' ? fresh.map(c => retryOf(c)[0]) : fresh.length;
}"""


def caps() -> dict:
    return json.loads(gw.MANIFEST.read_text())["flow_image"]


def is_image(head: bytes) -> bool:
    return head[:3] == b"\xff\xd8\xff" or head[:8] == b"\x89PNG\r\n\x1a\n" or (head[:4] == b"RIFF" and head[8:12] == b"WEBP")


def suffix_of(head: bytes) -> str:
    return ".png" if head[:4] == b"\x89PNG" else ".webp" if head[:4] == b"RIFF" else ".jpg"


def image_url(node, media_id: str) -> str | None:
    found = re.search(r"https://flow-content\.google/image/" + re.escape(media_id) + r"\?[^\"\\]+", json.dumps(node))
    return found.group(0) if found else None


def wire_models(post_data: str) -> list[str]:
    """The image model key of each request in a generation call (GEM_PIX_2 for Nano Banana Pro)."""
    found = []
    with contextlib.suppress(Exception):
        call = json.loads(urllib.parse.parse_qs(post_data)["f.req"][0])[0][0]
        for request in json.loads(call[1])[1]:
            if isinstance(request, list) and len(request) > 5 and isinstance(request[5], str):
                found.append(request[5])
    return list(dict.fromkeys(found))


class Images(gw.Watcher):
    """The page's own generation replies; it never issues a request."""

    def __init__(self, page=None):
        self.images: dict[str, dict] = {}
        self.models: list[str] = []
        super().__init__(page)

    def _on_response(self, response) -> None:
        if "rpcids=" not in response.url:
            return
        if re.search(r"rpcids=(" + "|".join(IMAGE_RPCS) + r")\b", response.url):
            with contextlib.suppress(Exception):
                self.models += wire_models(response.request.post_data or "")
        try:
            body = response.text()
        except Exception:
            return
        self.feed(body)

    def feed(self, body: str) -> None:
        self.errors |= gw.envelope_errors(body)
        for rpcid, payload in gw.batch_payloads(body):
            if rpcid in IMAGE_RPCS and isinstance(payload, list) and payload and isinstance(payload[0], list):
                for entry in payload[0]:
                    self._on_image(entry)

    def _on_image(self, entry) -> None:
        if not (isinstance(entry, list) and entry and isinstance(entry[0], str)):
            return
        record = self.images.setdefault(entry[0], {"media_id": entry[0]})
        if len(entry) > 2 and isinstance(entry[2], str):
            record["id"] = entry[2]
        url = image_url(entry, entry[0])
        if url:
            record["url"] = url
        size = entry[-1]
        if isinstance(size, list) and len(size) == 2 and all(isinstance(n, int) for n in size):
            record["size"] = size
        error = re.search(r"PUBLIC_ERROR_[A-Z_]+", json.dumps(entry))
        if error:
            record["error"] = error.group(0)

    def new_images(self, known: set[str]) -> list[dict]:
        return [record for key, record in self.images.items() if key not in known]


def refusal(codes) -> gw.Failure:
    code = 3 if any(QUOTA_ERROR.fullmatch(error) for error in codes) else 1
    return gw.Failure(code, f"Flow refused the image: {', '.join(sorted(set(codes)))}")


def rotation(price: int = 0) -> list[str]:
    return gw.rotation(price)


def resume_project(account: str, image_id: str) -> str:
    rows = [r for r in gw.job_rows() if isinstance(r, dict) and r.get("kind") == KIND and r.get("account") == account
            and r.get("id") == image_id and r.get("project")]
    project = rows[-1]["project"] if rows else gw.read_meta(account).get("project")
    if not project:
        raise gw.Failure(2, f"no Flow project is known on {account} for image {image_id}")
    return project


def model_item(label: str) -> re.Pattern:
    return re.compile(r"^\W*" + re.escape(label) + r"$")


def settings(page, plan: dict, editor: bool) -> str:
    """Sets the popover to the plan (the editor's has no mode or count) and checks Flow's own quote."""
    trigger = page.get_by_role("button", name="Settings trigger", exact=True).last
    family = page.get_by_role("button", name="Select model family")
    if not (family.count() and family.last.is_visible()):
        trigger.click()
    try:
        family.last.wait_for(timeout=8000)
        if not editor:
            gw.choose(page, "Image")
        def chosen() -> str:
            return " ".join(family.last.inner_text().replace("arrow_drop_down", "").split())

        if not model_item(plan["label"]).match(chosen()):
            family.last.click()
            page.get_by_role("menuitem", name=model_item(plan["label"])).click(timeout=5000)
            gw.settle(page, 600, lambda: model_item(plan["label"]).match(chosen()))
        if not model_item(plan["label"]).match(chosen()):
            raise gw.drift(f"the model family reads {chosen()!r}, not {plan['label']!r}")
        if plan["aspect"]:
            gw.choose(page, plan["aspect"])
        if not editor:
            gw.choose(page, f"x{plan['count']}")
        quote = page.get_by_role("link", name=re.compile(r"^\d+ credits?$")).last
        cost = int(re.match(r"\d+", quote.inner_text(timeout=5000)).group(0))
    except gw.Failure:
        raise
    except Exception as exc:
        raise gw.drift(f"image settings ({exc.__class__.__name__}: {(str(exc).strip().splitlines() or [''])[0][:120]})")
    finally:
        if family.count() and family.last.is_visible():
            trigger.click()
            gw.settle(page, 500, lambda: not family.last.is_visible())
        gw.close_overlays(page)
    if cost != plan["price"]:
        raise gw.Failure(1, f"Flow quotes {cost} credits for {plan['label']} x{plan['count']}, the manifest says "
                            f"{plan['price']}; nothing spent", quote=cost)
    chip = " ".join(trigger.inner_text().split())
    if plan["label"] not in chip or (not editor and not chip.endswith(f"x{plan['count']}")):
        raise gw.drift(f"the composer reads {chip!r} after setup, expected {plan['label']} x{plan['count']}")
    return chip


def open_editor(page, account: str, project: str, image_id: str, wait_s: float = 30.0) -> bool:
    """A fresh image's editor opens black (Download disabled, no prompt box) until Flow settles it, so it is reloaded."""
    deadline = time.time() + wait_s
    while True:
        gw.goto_flow(page, f"/project/{project}/edit/{image_id}")
        try:
            page.get_by_text("What do you want to change?", exact=True).wait_for(timeout=20000)
            gw.close_promos(page, account)
            return True
        except Exception:
            if time.time() >= deadline:
                return False


def save_upscaled(page, account: str, project: str, image_id: str, dest: Path, item: str) -> int:
    def prepare():
        if not open_editor(page, account, project, image_id, wait_s=150):
            raise gw.drift(f"the editor of image {image_id} stayed empty, so no {item} download")

    def trigger():
        page.get_by_role("button", name="Download media", exact=True).click(timeout=30000)
        page.get_by_role("menuitem", name=item, exact=True).click(timeout=10000)

    return gw.save_caught(page, trigger, dest, item, "an image", is_image,
                          lambda url, dest: gw.save_video(page.context, url, dest, is_image, "image"),
                          prepare=prepare, timeout_s=180)


def failed_cards(page) -> int:
    return int(page.evaluate(FAILED_CARDS, "count") or 0)


def retry_failed(page) -> int:
    buttons = page.evaluate_handle(FAILED_CARDS, "retry")
    clicked = 0
    for handle in buttons.get_properties().values():
        element = handle.as_element()
        if element:
            element.click(timeout=5000)
            clicked += 1
    return clicked


def await_takes(page, watcher: Images, plan: dict, known: set, account: str, project: str) -> tuple[list, int]:
    """(images back, takes lost). A Failed card gets Flow's own Retry once; a failure after it is a lost take."""
    deadline = time.time() + plan["timeout_s"]
    retried, floor, failed, scanned = False, 0, 0, None
    while True:
        if watcher.blocked():
            raise watcher.blocked()
        images = watcher.new_images(known)
        done = [i for i in images if i.get("url") or i.get("error")]
        if scanned is None or time.time() - scanned >= CARDS_SCAN_S:
            failed, scanned = failed_cards(page), time.time()
        if failed and not retried:
            gw.ledger({"kind": KIND, "event": "retried", "account": account, "project": project, "failed": failed,
                       "resume_of": plan["resume"]})
            if not retry_failed(page):
                raise gw.Failure(1, f"{GENERATION_FAILED}: Flow showed its Failed card with no Retry on {account}")
            retried, floor, deadline, scanned = True, failed, time.time() + plan["timeout_s"], None
            page.wait_for_timeout(1500)
            continue
        floor = min(floor, failed)
        lost = failed - floor if retried else 0
        if len(done) + lost >= plan["count"]:
            if not done:
                raise gw.Failure(1, f"{GENERATION_FAILED}: Flow's Failed card came back after its own Retry on "
                                    f"{account}")
            return done[:plan["count"]], lost
        if watcher.errors and not images:
            raise refusal(watcher.errors)
        if time.time() > deadline:
            if done:
                missing = plan["count"] - len(done)
                gw.warn(account, f"{missing} of {plan['count']} takes never came back within {plan['timeout_s']}s; "
                                 f"delivering the {len(done)} that did (a late one lands in project {project})")
                return done, missing
            if retried and failed:
                raise gw.Failure(1, f"{GENERATION_FAILED}: Flow's Retry did not take on {account}")
            raise gw.Failure(1, f"sent, but {len(done)} of {plan['count']} images came back within "
                                f"{plan['timeout_s']}s on {account}; any late one lands in project {project}")
        page.wait_for_timeout(500)


def render_on(account: str, plan: dict, meta: dict, started: float) -> dict:
    with gw.browser(account) as context:
        page = context.pages[0] if context.pages else context.new_page()
        watcher = Images(page)
        if plan["resume"]:
            project = resume_project(account, plan["resume"])
            if not open_editor(page, account, project, plan["resume"]):
                raise gw.Failure(2, f"Flow shows no editor for image {plan['resume']} on {account}; resume an id "
                                    "this account's gemini-image --route flow printed")
        else:
            project = gw.open_project(page, account)
            gw.manual_composer(page)
        state = gw.page_state(page)
        if state["email"] != meta["email"]:
            raise gw.Failure(1, f"profile {account} is signed in as {state['email']}, bound to {meta['email']}")
        gw.phase("page")
        chip = settings(page, plan, editor=bool(plan["resume"]))
        gw.add_ingredients(page, [Path(ref) for ref in plan["refs"]], "Image")
        if plan["refs"]:
            chip = settings(page, plan, editor=False)
        button = page.get_by_role("button", name="Start generation", exact=True).last
        page.locator("[contenteditable=true]").last.click()
        page.keyboard.insert_text(plan["prompt"])
        gw.settle(page, 400, button.is_enabled)
        if not button.is_enabled():
            raise gw.drift("Start generation stays disabled after setup")
        if plan["dry_run"]:
            gw.click_if_visible(page, "button", "Clear prompt")
            return {"ok": True, "dry_run": True, "account": account, "project": project, "chip": chip,
                    "build": state["build"]}
        known = set(watcher.images)
        page.evaluate(FAILED_CARDS, "mark")
        gw.ledger({"kind": KIND, "event": "queued", "account": account, "project": project, "model": plan["model"],
                   "resume_of": plan["resume"], "prompt": plan["prompt"][:500]})
        watcher.errors &= gw.BLOCK_ERRORS
        button.click()
        sent = time.time()
        gw.phase("sent")
        done, lost = await_takes(page, watcher, plan, known, account, project)
        rendered = time.time()
        gw.phase("media")
        takes, refused, unsaved = [], [], []
        for index, image in enumerate(done):
            if image.get("error"):
                refused.append({"media_id": image["media_id"], "error": image["error"]})
                continue
            part = Path(plan["out_dir"]) / f"take{index + 1}"
            try:
                if plan["upscale"]:
                    size = save_upscaled(page, account, project, image["id"], part, caps()["upscale"][plan["upscale"]])
                else:
                    size = gw.save_video(context, image["url"], part, is_image, "image")
            except gw.Failure as failure:
                unsaved.append(failure)
                continue
            path = part.with_suffix(suffix_of(part.read_bytes()[:12]))
            part.replace(path)
            takes.append({"path": str(path), "media_id": image["media_id"], "id": image.get("id"),
                          "size": image.get("size"), "bytes": size, "account": account})
            gw.ledger({"kind": KIND, "event": "saved", "account": account, "project": project, "id": image.get("id"),
                       "media_id": image["media_id"], "model": plan["model"], "upscale": plan["upscale"],
                       "resume_of": plan["resume"], "bytes": size})
        if not takes and unsaved:
            raise unsaved[0]
        if not takes:
            raise refusal(r["error"] for r in refused)
        finished = time.time()
        gw.phase("saved")
        return {"ok": True, "account": account, "project": project, "takes": takes, "refused": refused, "failed": lost,
                "unsaved": [failure.reason for failure in unsaved],
                "model": (watcher.models or [None])[-1], "model_name": plan["model"], "label": plan["label"],
                "chip": chip, "build": state["build"],
                "seconds": {"render": round(rendered - sent, 1), "total": round(finished - started, 1)}}


def generate_on(account: str, plan: dict) -> dict:
    started = time.time()
    if not gw.has_login(account):
        raise gw.Failure(4, f"account {account} has no browser login; run: geminib web {account}")
    meta = gw.read_meta(account)
    if not meta.get("email"):
        raise gw.Failure(4, f"account {account} is not bound to a Google account; run: gemini-web status {account}")
    if not (plan["resume"] or plan["dry_run"]):
        gw.note_started(account)
    return render_on(account, plan, meta, started)


def make_plan(args) -> dict:
    c = caps()
    model = c["models"].get(args.model)
    if model is None:
        raise gw.Failure(2, f"--model is one of: {', '.join(c['models'])}")
    if args.aspect and args.aspect not in c["aspects"]:
        raise gw.Failure(2, f"Flow takes aspect {'|'.join(c['aspects'])}, not {args.aspect}")
    if args.count not in c["counts"]:
        raise gw.Failure(2, f"Flow makes {', '.join(map(str, c['counts']))} images per send, not {args.count}")
    if len(args.ref) > c["refs_max"]:
        raise gw.Failure(2, f"Flow takes at most {c['refs_max']} --ref images")
    if args.upscale and args.upscale not in c["upscale"]:
        raise gw.Failure(2, f"--upscale is {'|'.join(c['upscale'])}")
    for ref in args.ref:
        if not Path(ref).is_file():
            raise gw.Failure(2, f"--ref {ref} is not a file")
    if args.resume:
        if not args.account:
            raise gw.Failure(2, "--resume needs --account: the image lives on the account that made it")
        if args.count != 1 or args.ref:
            raise gw.Failure(2, "--resume edits one image in its editor; it takes no --count or --ref")
    return {"prompt": args.prompt, "model": args.model, "label": model["label"], "aspect": args.aspect,
            "count": args.count, "refs": args.ref, "upscale": args.upscale, "resume": args.resume,
            "out_dir": args.out_dir, "dry_run": args.dry_run, "price": c["price"],
            "timeout_s": args.timeout or c["timeout_s"]}


def cmd_generate(args) -> None:
    plan = make_plan(args)
    accounts = gw.take_accounts(args.account, lambda: rotation(plan["price"]),
                                "every signed-in Flow account is walled (walls.json)")
    gw.take_failover(accounts, plan, lambda account, plan: generate_on(account, plan), gw.set_wall, bool(args.account),
                     lock_wait=args.lock_wait)


TOOL_VIEWPORT = {"width": 2200, "height": 1400}
LAYER = "div.absolute.select-none.group"
TOOL_ERROR = "[class*='bg-red-500/90']"
TOOL_BUSY = ("Removing background", "Downloading model", "Initializing AI", "Preparing background remover")


def tool_caps() -> dict:
    return caps()["tools"]


def editor_accounts() -> list[str]:
    return [n for n in rotation() if gw.read_meta(n).get("image_editor")]


def applet(page, timeout_s: float = 45.0):
    """The tool's sandboxed frame; the editor's own UI lives there, Flow's pickers stay on the page."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        for frame in page.frames:
            if "usercontent.goog" in frame.url:
                with contextlib.suppress(Exception):
                    if "Layers (" in frame.locator("body").inner_text(timeout=1500):
                        return frame
        page.wait_for_timeout(500)
    raise gw.drift("the Image Editor tool never showed its layer panel")


def open_editor_tool(page, account: str, project: str):
    """Opens the account's own copy from My Tools; never Templates, where a click saves a new remix. The frame
    sometimes keeps the window's old size, a squashed canvas every drag then misses: reopened once."""
    for attempt in range(2):
        frame = open_editor_once(page, account, project)
        width = frame.frame_element().bounding_box()["width"]
        if width > TOOL_VIEWPORT["width"] * 0.7:
            return frame
    raise gw.drift(f"the Image Editor frame stays {round(width)} px wide in a {TOOL_VIEWPORT['width']} px window")


def open_editor_once(page, account: str, project: str):
    page.set_viewport_size(TOOL_VIEWPORT)
    gw.goto_flow(page, f"/project/{project}/tools")
    gw.dismiss_dialogs(page, account)
    try:
        page.get_by_role("radio", name="My Tools", exact=True).click(timeout=20000)
    except Exception as exc:
        raise gw.drift(f"no My Tools tab on the tools page ({exc.__class__.__name__})")
    tile = page.get_by_role("main").get_by_text(re.compile(re.escape(tool_caps()["editor"]) + "$"))
    with contextlib.suppress(Exception):
        tile.first.wait_for(timeout=15000)
    if not tile.count():
        raise gw.Failure(4, f"Flow's {tool_caps()['editor']} is not in My Tools on {account}; open Tools > Templates > "
                            f"{tool_caps()['editor']} there once (Flow saves a remix), then pass --account {account}")
    tile.first.click()
    frame = applet(page)
    gw.write_meta(account, image_editor=True)
    return frame


def pick(page, frame, label: str, value: str) -> None:
    button = frame.get_by_role("button", name=re.compile("^" + re.escape(label)))
    if value not in button.inner_text():
        button.click()
        page.wait_for_timeout(400)
        frame.get_by_text(value, exact=True).last.click(timeout=5000)
        page.wait_for_timeout(400)
    if value not in button.inner_text():
        raise gw.drift(f"the {label} picker reads {button.inner_text()!r}, not {value!r}")


def layer_count(frame) -> int:
    found = re.search(r"Layers \((\d+)\)", frame.locator("body").inner_text())
    return int(found.group(1)) if found else 0


def set_canvas(page, frame, width: int, height: int) -> None:
    boxes = frame.get_by_role("spinbutton")
    for box, value in ((boxes.nth(0), width), (boxes.nth(1), height)):
        box.fill(str(value))
        box.press("Tab")
        page.wait_for_timeout(300)
    got = (boxes.nth(0).input_value(), boxes.nth(1).input_value())
    if got != (str(width), str(height)):
        raise gw.drift(f"the canvas reads {'x'.join(got)}, not {width}x{height}")


def add_layer(page, frame, image: Path) -> None:
    before = layer_count(frame)
    frame.get_by_role("button", name="Add Image", exact=True).click()
    page.wait_for_timeout(500)
    frame.get_by_role("button", name="Gallery", exact=True).click()
    page.get_by_role("button", name="Upload media", exact=True).last.wait_for(timeout=15000)
    gw.upload(page, [image], "edit", "", 180)[0].click()
    page.wait_for_timeout(600)
    gw.click_if_visible(page, "button", "Add media")
    deadline = time.time() + 45
    while layer_count(frame) == before:
        if time.time() > deadline:
            raise gw.drift(f"{image.name} never became a layer in the Image Editor")
        page.wait_for_timeout(500)


def layer_rect(frame) -> tuple[float, float, float, float]:
    style = frame.locator(LAYER).last.get_attribute("style") or ""
    v = {k: float(re.search(k + r": ([-\d.]+)px", style).group(1)) for k in ("left", "top", "width", "height")}
    return v["left"] - v["width"] / 2, v["top"] - v["height"] / 2, v["width"], v["height"]


def drag(page, start: tuple[float, float], end: tuple[float, float]) -> None:
    page.mouse.move(*start)
    page.mouse.down()
    page.mouse.move((start[0] + end[0]) / 2, (start[1] + end[1]) / 2, steps=6)
    page.mouse.move(*end, steps=6)
    page.mouse.up()
    page.wait_for_timeout(400)


def place_layer(page, frame, canvas: tuple[int, int], want: tuple[float, float, float, float]) -> None:
    """A new layer lands at 80% of the canvas; dragged like a person: its corner snaps to the canvas corner,
    the corner handle stretches it to `want` (aspect locked), and a move snaps it onto the centre line."""
    board = frame.locator("#canvas-bg").bounding_box()
    zoom = board["width"] / canvas[0]

    def centre():
        box = frame.locator(LAYER).last.bounding_box()
        return box["x"] + box["width"] / 2, box["y"] + box["height"] / 2, box

    cx, cy, box = centre()
    drag(page, (cx, cy), (cx + board["x"] - box["x"], cy + board["y"] - box["y"]))
    handles = frame.locator("[style*='nwse-resize']")
    corner = max((handles.nth(i).bounding_box() for i in range(handles.count())), key=lambda b: b["x"])
    drag(page, (corner["x"] + corner["width"] / 2, corner["y"] + corner["height"] / 2),
         (board["x"] + want[2] * zoom + 0.4, board["y"] + want[3] * zoom + 0.4))
    if want[0] or want[1]:
        cx, cy, _ = centre()
        drag(page, (cx, cy), (cx + want[0] * zoom, cy + want[1] * zoom))
    got = layer_rect(frame)
    if any(abs(a - b) > 2 for a, b in zip(got, want)):
        raise gw.drift(f"the layer sits at {tuple(round(n, 1) for n in got)}, not {want}")


def region_strokes(region: tuple, width: int, height: int, brush: int) -> list[list[tuple[float, float]]]:
    x, y, w, h = region
    rx, ry = min(brush / 2, w * width / 2), min(brush / 2, h * height / 2)
    left, right = x * width + rx, (x + w) * width - rx
    top, bottom = y * height + ry, (y + h) * height - ry
    rows = max(2, math.ceil((bottom - top) / (brush * 0.6)) + 1)
    path = []
    for row in range(rows):
        ty = top + (bottom - top) * row / (rows - 1)
        path += [(left, ty), (right, ty)] if row % 2 == 0 else [(right, ty), (left, ty)]
    return [path]


def point_strokes(point: tuple, width: int, height: int, brush: int) -> list[list[tuple[float, float]]]:
    cx, cy = point[0] * width, point[1] * height
    ring = [(cx + r * math.cos(a * math.pi / 6), cy + r * math.sin(a * math.pi / 6))
            for r in (brush / 3, brush * 2 / 3) for a in range(13)]
    return [[(cx, cy), *ring]]


def paint(page, frame, strokes: list, width: int, height: int) -> None:
    overlay = frame.locator("canvas.touch-none").last
    try:
        overlay.wait_for(timeout=10000)
    except Exception:
        raise gw.drift("Inpaint opened no painting overlay")
    box = overlay.bounding_box()
    sx, sy = box["width"] / width, box["height"] / height
    for path in strokes:
        points = [(box["x"] + px * sx, box["y"] + py * sy) for px, py in path]
        page.mouse.move(*points[0])
        page.mouse.down()
        for point in points[1:]:
            page.mouse.move(*point, steps=8)
        page.mouse.up()
        page.wait_for_timeout(200)


def tool_error(frame) -> str:
    box = frame.locator(TOOL_ERROR)
    return " ".join(box.first.inner_text().split()) if box.count() and box.first.is_visible() else ""


def await_render(page, frame, watcher: Images, known: set, plan: dict, account: str) -> dict:
    deadline = time.time() + plan["timeout_s"]
    while True:
        if watcher.blocked():
            raise watcher.blocked()
        done = [i for i in watcher.new_images(known) if i.get("url") or i.get("error")]
        if done:
            if done[0].get("error"):
                raise refusal([done[0]["error"]])
            return done[0]
        if watcher.errors:
            raise refusal(watcher.errors)
        error = tool_error(frame)
        if error:
            raise gw.Failure(1, f"the Image Editor's {plan['op']} failed: {error[:200]}")
        if time.time() > deadline:
            raise gw.Failure(1, f"the Image Editor's {plan['op']} brought no image within {plan['timeout_s']}s on "
                                f"{account}")
        page.wait_for_timeout(500)


def cutout(page, frame, plan: dict, console: list) -> str:
    before = frame.locator(LAYER + " img").last.get_attribute("src")
    frame.get_by_role("button", name="Cutout", exact=True).click()
    gw.phase("sent")
    deadline = time.time() + plan["timeout_s"]
    while True:
        page.wait_for_timeout(1000)
        src = frame.locator(LAYER + " img").last.get_attribute("src") or ""
        busy = any(word in frame.locator("body").inner_text() for word in TOOL_BUSY)
        if src != before and src.startswith("data:image/png") and not busy:
            return src
        error = tool_error(frame)
        if error:
            detail = f" ({console[-1].splitlines()[0][:500]})" if console else ""
            raise gw.Failure(1, f"the Image Editor's cutout failed: {error[:200]}{detail}")
        if time.time() > deadline:
            raise gw.Failure(1, f"the Image Editor's cutout gave no layer within {plan['timeout_s']}s")


def outpaint_layout(size: tuple[int, int], aspect: str) -> tuple[tuple[int, int], tuple[float, float, float, float]]:
    """The canvas of `aspect` that holds the image at its own size, and where the image sits in it."""
    width, height = size
    a, b = (int(n) for n in aspect.split(":"))
    if width * b < height * a:
        canvas = (round(height * a / b), height)
    else:
        canvas = (width, round(width * b / a))
    return canvas, ((canvas[0] - width) / 2, (canvas[1] - height) / 2, width, height)


def tool_on(account: str, plan: dict, meta: dict, started: float) -> dict:
    c = tool_caps()
    with gw.browser(account) as context:
        page = context.pages[0] if context.pages else context.new_page()
        watcher = Images(page)
        console: list[str] = []
        page.on("console", lambda message: message.type == "error" and console.append(message.text))
        project = gw.open_project(page, account)
        state = gw.page_state(page)
        if state["email"] != meta["email"]:
            raise gw.Failure(1, f"profile {account} is signed in as {state['email']}, bound to {meta['email']}")
        gw.phase("page")
        credits = gw.read_credits(page)
        gw.note_credits(account, credits)
        frame = open_editor_tool(page, account, project)
        if plan["op"] == "cutout":
            pick(page, frame, "Background removal", c["bg_models"][plan["bg_model"]])
        else:
            pick(page, frame, "Image Model", plan["label"])
        size = tuple(plan["size"])
        canvas, want = outpaint_layout(size, plan["aspect"]) if plan["op"] == "outpaint" else (size, (0, 0, *size))
        set_canvas(page, frame, *canvas)
        add_layer(page, frame, Path(plan["image"]))
        if plan["op"] != "cutout":
            place_layer(page, frame, canvas, want)
        if plan["dry_run"]:
            return {"ok": True, "dry_run": True, "account": account, "project": project, "op": plan["op"],
                    "canvas": list(canvas), "layer": [round(n, 1) for n in layer_rect(frame)], "build": state["build"],
                    "credits_before": credits}
        gw.ledger({"kind": KIND, "event": "queued", "account": account, "project": project, "op": plan["op"],
                   "model": plan["model"], "prompt": plan["prompt"][:500]})
        out = Path(plan["out_dir"]) / "take1"
        sent = time.time()
        if plan["op"] == "cutout":
            src = cutout(page, frame, plan, console)
            gw.phase("media")
            out = out.with_suffix(".png")
            out.write_bytes(base64.b64decode(src.split(",", 1)[1]))
            gw.phase("saved")
            gw.ledger({"kind": KIND, "event": "saved", "account": account, "project": project, "op": "cutout",
                       "bg_model": plan["bg_model"], "bytes": out.stat().st_size})
            return {"ok": True, "account": account, "project": project, "op": "cutout", "bg_model": plan["bg_model"],
                    "takes": [{"path": str(out), "id": None, "bytes": out.stat().st_size, "account": account}],
                    "build": state["build"], "credits_before": credits,
                    "seconds": {"render": round(time.time() - sent, 1), "total": round(time.time() - started, 1)}}
        known = set(watcher.images)
        if plan["op"] == "inpaint":
            frame.get_by_role("button", name="Inpaint", exact=True).click()
            page.wait_for_timeout(800)
            strokes = (region_strokes(plan["region"], *size, c["brush_px"]) if plan["region"] else
                       [s for p in plan["points"] for s in point_strokes(p, *size, c["brush_px"])])
            paint(page, frame, strokes, *size)
            box = frame.get_by_role("textbox", name="What should appear in the painted area?")
        else:
            frame.get_by_role("button", name="Outpaint", exact=True).click()
            page.wait_for_timeout(800)
            box = frame.get_by_role("textbox", name=re.compile("^Describe what to generate around"))
        box.click(timeout=10000)
        if plan["prompt"]:
            page.keyboard.insert_text(plan["prompt"])
            page.wait_for_timeout(300)
        watcher.errors &= gw.BLOCK_ERRORS
        frame.get_by_role("button", name="Enter", exact=True).click(timeout=10000)
        gw.phase("sent")
        image = await_render(page, frame, watcher, known, plan, account)
        rendered = time.time()
        gw.phase("media")
        size_bytes = gw.save_video(context, image["url"], out, is_image, "image")
        gw.phase("saved")
        path = out.with_suffix(suffix_of(out.read_bytes()[:12]))
        out.replace(path)
        gw.ledger({"kind": KIND, "event": "saved", "account": account, "project": project, "id": image.get("id"),
                   "media_id": image["media_id"], "model": plan["model"], "op": plan["op"], "bytes": size_bytes})
        return {"ok": True, "account": account, "project": project, "op": plan["op"],
                "takes": [{"path": str(path), "media_id": image["media_id"], "id": image.get("id"),
                           "size": image.get("size"), "bytes": size_bytes, "account": account}],
                "model": (watcher.models or [None])[-1], "model_name": plan["model"], "label": plan["label"],
                "build": state["build"], "credits_before": credits,
                "seconds": {"render": round(rendered - sent, 1), "total": round(time.time() - started, 1)}}


def tool_plan(args) -> dict:
    c, t = caps(), tool_caps()
    op = args.op
    if args.model not in t["models"]:
        raise gw.Failure(2, f"the Image Editor runs --model {'|'.join(t['models'])}")
    if args.bg_model and args.bg_model not in t["bg_models"]:
        raise gw.Failure(2, f"--bg-model is one of: {', '.join(t['bg_models'])}")
    if not Path(args.image).is_file():
        raise gw.Failure(2, f"--image {args.image} is not a file")
    try:
        size = [int(n) for n in args.size.split("x")]
        assert len(size) == 2 and min(size) > 0
    except (AssertionError, ValueError):
        raise gw.Failure(2, f"--size is WxH, not {args.size}")
    region = tuple(float(n) for n in args.region.split(",")) if args.region else None
    points = [tuple(float(n) for n in p.partition("=")[0].split(",")) for p in args.point]
    if op == "inpaint" and not (region or points) or op != "inpaint" and (region or points):
        raise gw.Failure(2, "--region or --point goes with --op inpaint, and inpaint needs one of them")
    if op == "inpaint" and not args.prompt:
        raise gw.Failure(2, "inpaint needs a --prompt for the painted area")
    if op == "outpaint" and args.aspect not in t["aspects"]:
        raise gw.Failure(2, f"outpaint takes --aspect {'|'.join(t['aspects'])}")
    return {"op": op, "image": args.image, "size": size, "prompt": args.prompt or "", "region": region,
            "points": points, "aspect": args.aspect, "model": args.model, "label": c["models"][args.model]["label"],
            "bg_model": args.bg_model or t["default_bg_model"], "out_dir": args.out_dir, "dry_run": args.dry_run,
            "timeout_s": args.timeout or t["timeout_s"]}


def cmd_tool(args) -> None:
    plan = tool_plan(args)

    def run(account: str, plan: dict) -> dict:
        started = time.time()
        if not gw.has_login(account):
            raise gw.Failure(4, f"account {account} has no browser login; run: geminib web {account}")
        meta = gw.read_meta(account)
        if not meta.get("email"):
            raise gw.Failure(4, f"account {account} is not bound to a Google account; run: gemini-web status {account}")
        if plan["op"] != "cutout" and not plan["dry_run"]:
            gw.note_started(account)
        return tool_on(account, plan, meta, started)

    if not (args.account or any(gw.read_meta(n).get("image_editor") for n in gw.bound_accounts())):
        raise gw.Failure(4, f"no free Flow account has the {tool_caps()['editor']} in My Tools; open Tools > Templates "
                            f"> {tool_caps()['editor']} once on one, then pass --account <it>")
    accounts = gw.take_accounts(args.account, editor_accounts, "every Flow account with the Image Editor is walled")
    gw.take_failover(accounts, plan, run, gw.set_wall, bool(args.account), lock_wait=args.lock_wait)


def main() -> None:
    c = caps()
    parser = argparse.ArgumentParser(prog="flow-image-engine")
    sub = parser.add_subparsers(dest="command", required=True)
    t = sub.add_parser("tool")
    t.add_argument("--op", required=True, choices=["inpaint", "outpaint", "cutout"])
    t.add_argument("--image", required=True)
    t.add_argument("--size", required=True)
    t.add_argument("--out-dir", required=True)
    t.add_argument("--prompt")
    t.add_argument("--region")
    t.add_argument("--point", action="append", default=[])
    t.add_argument("--aspect")
    t.add_argument("--model", default=c["default_model"])
    t.add_argument("--bg-model")
    t.add_argument("--account", type=gw.account_arg)
    t.add_argument("--timeout", type=int)
    t.add_argument("--dry-run", action="store_true")
    gw.lock_wait_arg(t)
    p = sub.add_parser("generate")
    p.add_argument("--prompt", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--model", default=c["default_model"])
    p.add_argument("--aspect")
    p.add_argument("--count", type=int, default=1)
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--upscale")
    p.add_argument("--resume")
    p.add_argument("--account", type=gw.account_arg)
    p.add_argument("--timeout", type=int)
    p.add_argument("--dry-run", action="store_true")
    gw.lock_wait_arg(p)
    args = parser.parse_args()
    gw.TIMED = True
    try:
        (cmd_tool if args.command == "tool" else cmd_generate)(args)
    except gw.Failure as failure:
        if failure.code != 2:
            gw.report(args.account or failure.extra.get("account") or "-", failure)
        gw.fail(failure.code, failure.reason, **failure.extra)
    except Exception as error:  # noqa: BLE001
        gw.report(args.account or "-", error)
        gw.fail(1, gw.failure_text(error)[:300])


if __name__ == "__main__":
    main()
