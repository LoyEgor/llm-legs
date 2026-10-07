# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Speech from Gemini TTS in Google AI Studio (aistudio.google.com/generate-speech), free on the signed-in accounts.

Same hidden Chrome, profiles, locks and job ledger as gemini_web (Flow). The speech composer is driven the way a
person would: the model by the page's own ?model= link, one speech block per turn, each speaker's voice from the
speaker panel, the style fields, then Run; the WAV is read from the page's own player. Prints one JSON line; exit 0 ok,
1 failed, 2 usage, 3 a quota answer or walled, 4 signed out or an owner step, 5 account busy.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime
import json
import re
import sys
import time
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
import caps_checks  # noqa: E402
import gemini_web as gw  # noqa: E402

gw.ROUTE = "aistudio"

SITE = "https://aistudio.google.com"
WALLS = "aistudio-walls.json"
REST = "flow-rest.json"
TERMS = re.compile(r"^I acknowledge that I am at least 18")
TERMS_BUTTONS = ("Accept terms of service", "Continue")
WELCOME = re.compile(r"Welcome to AI Studio|Gemini API Additional Terms")
LIMIT = re.compile(r"quota|rate.?limit|limit of requests|resource.?exhausted|too many requests|reached your .{0,20}limit", re.I)
AUDIO_CHUNK = re.compile(r'"audio/[^"]*","([A-Za-z0-9+/=]+)"')
WAV_HEADER = 44
PER_MINUTE = re.compile(r"per minute|a minute|RPM", re.I)
MINUTE_WALL_S = 900
SEND_WAIT_S = 12
STOP = re.compile(r"(^|\s)Stop$|^Cancel generation")
LINE = re.compile(r"^\s*([A-Za-z][\w-]*)\s*(?:\(([^)]*)\))?\s*:\s*(.*\S)\s*$", re.S)
TTS_ID = re.compile(r"^[a-z0-9][a-z0-9.-]*-tts(-[a-z0-9.-]+)?$")
VOICE_COUNT = re.compile(r'- text: (.+)\n\s*- button "View all (\d+)"')
VOICE_NAME = re.compile(r'^\s*- button "([A-Z][\w-]*)(?: \(Current\))?":', re.M)
DIRECTOR = {"delivery": "Style", "pace": "Pace", "accent": "Accent"}
RIFF = lambda head: head[:4] == b"RIFF"  # noqa: E731


def caps() -> dict:
    return json.loads(gw.MANIFEST.read_text())["speech"]


def drift(what: str) -> gw.Failure:
    return gw.Failure(1, f"AI Studio UI drift: {what}")


def usage(reason: str) -> gw.Failure:
    return gw.Failure(2, reason)


def walls() -> dict:
    try:
        return json.loads((gw.ROOT / WALLS).read_text())
    except (OSError, ValueError):
        return {}


def set_wall(account: str, until: float) -> None:
    gw.update_json(WALLS, lambda data: data.update({account: int(until)}))


def resting(now: float | None = None) -> set[str]:
    """Accounts the owner rests (the flow-rest experiment): never driven while its `until` is ahead."""
    try:
        rest = json.loads((gw.ROOT / REST).read_text())
    except (OSError, ValueError):
        return set()
    return set(rest.get("accounts") or []) if rest.get("until", 0) > (now or time.time()) else set()


def rotation() -> list[str]:
    now, own, rest = time.time(), walls(), resting()
    ready = [name for name in gw.bound_accounts() if name not in rest and own.get(name, 0) <= now and gw.in_pool(name)
             and gw.read_meta(name).get("aistudio_signed_in") is not False]
    return gw.least_recent(ready)


def take_accounts(pinned: str | None) -> list[str]:
    if not pinned:
        return gw.take_accounts(None, rotation, "every AI Studio account is walled (aistudio-walls.json) or resting")
    gw.refuse_off_roster(pinned)
    gw.refuse_out_of_pool(pinned)
    if pinned in resting():
        raise gw.Failure(3, f"{pinned} is resting ({gw.ROOT / REST}); nothing was sent", account=pinned)
    until = walls().get(pinned, 0)
    if until > time.time():
        raise gw.Failure(3, f"{pinned} is walled until {time.strftime('%Y-%m-%d %H:%M', time.localtime(until))} "
                            f"({WALLS}); nothing was sent", account=pinned)
    return [pinned]


def limit_wall_s(text: str, now: float | None = None) -> float:
    """A per-minute limit walls briefly; any other quota answer is the free tier's daily one, reset at Pacific midnight."""
    now = now or time.time()
    if PER_MINUTE.search(text):
        return MINUTE_WALL_S
    here = datetime.datetime.fromtimestamp(now, ZoneInfo("America/Los_Angeles"))
    midnight = (here + datetime.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return max(60.0, midnight.timestamp() - now)


def model_of(name: str, c: dict) -> tuple[str, dict]:
    for key, model in c["models"].items():
        if name in (key, model["id"]):
            return key, model
    raise usage(f"--model is one of: {', '.join(c['models'])} (or its id)")


def family_voices(family: str, c: dict) -> list[str]:
    return sorted(c["voices"]) if c["families"][family]["voices"] == "all" else list(c["classic_voices"])


def canonical_voice(name: str, family: str, c: dict) -> str:
    voices = family_voices(family, c)
    match = next((v for v in voices if v.lower() == name.lower()), None)
    if match is None:
        if name.lower() in (v.lower() for v in c["voices"]):
            raise usage(f"{name} is a Gemini 3.8 voice; the {family} models take: {', '.join(voices)}")
        raise usage(f"unknown voice {name!r}; --list-voices lists the {len(voices)} free voices")
    return match


def check_tags(text: str, family: dict, warn) -> None:
    opened, closed = family["tag_open"], family["tag_close"]
    other = ("[", "]") if opened == "<" else ("<", ">")
    wrong = re.findall(re.escape(other[0]) + r"([a-z][a-z -]*)" + re.escape(other[1]), text)
    if wrong:
        raise usage(f"this model reads expression tags as {opened}tag{closed}, not {other[0]}{wrong[0]}{other[1]}")
    unknown = [t for t in re.findall(re.escape(opened) + r"([^" + re.escape(opened + closed) + r"]+)" + re.escape(closed), text)
               if t.strip() not in family["tags"]]
    if unknown:
        warn(f"tags not in the composer's list (sent as written): {', '.join(sorted(set(unknown)))}")


def make_turns(text: str | None, lines: list[str], voice: str | None, style: str, family: str, c: dict) -> list[dict]:
    if bool(text) == bool(lines):
        raise usage("give --text/--text-file for one voice or --line '<voice>: <text>' (repeated) for a dialogue")
    if text:
        return [{"voice": canonical_voice(voice or c["families"][family]["default_voice"], family, c),
                 "style": style, "text": text.strip()}]
    if voice:
        raise usage("--voice names the voice of --text; a dialogue names one in each --line")
    turns: list[dict] = []
    for line in lines:
        match = LINE.match(line)
        if not match:
            raise usage(f"--line needs '<voice>: <text>' or '<voice> (<style>): <text>', not {line!r}")
        who, own, said = match.group(1), (match.group(2) or "").strip(), match.group(3)
        if own and family != "design":
            raise usage("a per-line (style) is the Gemini 3.8 composer's; the older models take --style for each speaker")
        turn = {"voice": canonical_voice(who, family, c), "style": own or style, "text": said.strip()}
        if turns and turns[-1]["voice"] == turn["voice"]:
            if turns[-1]["style"] != turn["style"]:
                raise usage(f"two lines of {turn['voice']} in a row need one style: the composer alternates the speakers "
                            "block by block")
            turns[-1]["text"] += " " + turn["text"]
            continue
        turns.append(turn)
    speakers = list(dict.fromkeys(t["voice"] for t in turns))
    if len(speakers) > c["speakers_max"]:
        raise usage(f"AI Studio voices at most {c['speakers_max']} speakers in one take; this dialogue has "
                    f"{', '.join(speakers)}")
    return turns


def make_plan(args, warn=lambda text: print(f"gemini-speech: {text}", file=sys.stderr, flush=True)) -> dict:
    c = caps()
    key, model = model_of(args.model or c["default_model"], c)
    family = model["family"]
    fam = c["families"][family]
    turns = make_turns(args.text, args.line or [], args.voice, (args.style or "").strip(), family, c)
    for turn in turns:
        check_tags(turn["text"], fam, warn)
    speakers = list(dict.fromkeys(t["voice"] for t in turns))
    director = {name: getattr(args, name) for name in ("delivery", "pace", "accent") if getattr(args, name)}
    if family == "design":
        for flag in ("scene", "context", *director):
            if getattr(args, flag):
                raise usage(f"--{flag} is the older models' field (--model {', '.join(k for k, m in c['models'].items() if m['family'] == 'classic')}); "
                            "the Gemini 3.8 composer takes --style")
    else:
        if args.filler_words:
            raise usage("--filler-words is the Gemini 3.8 composer's switch")
        for name, value in director.items():
            options = fam["director"][name]
            match = next((o for o in options if o.lower() == value.lower()), None)
            if match is None:
                raise usage(f"--{name} is one of: {', '.join(options)}")
            director[name] = match
    if args.filler_words and len(speakers) < 2:
        raise usage("--filler-words is a two-speaker switch; give two voices with --line")
    temp = c["temperature"]
    temperature = temp["default"] if args.temperature is None else args.temperature
    steps = round((temperature - temp["min"]) / temp["step"])
    if not temp["min"] <= temperature <= temp["max"] or abs(steps * temp["step"] + temp["min"] - temperature) > 1e-9:
        raise usage(f"--temperature is {temp['min']} to {temp['max']} in steps of {temp['step']}")
    return {"model": key, "model_id": model["id"], "family": family, "turns": turns, "speakers": speakers,
            "style": (args.style or "").strip(), "scene": args.scene or "", "context": args.context or "",
            "director": director, "filler_words": bool(args.filler_words), "temperature": temperature,
            "out_dir": args.out_dir, "dry_run": args.dry_run, "timeout_s": c["timeout_s"]}


def accept_terms(page, account: str) -> bool:
    """Egor's yes (2026-10-06) covers AI Studio's first-use terms (a checkbox page or dialog) and its plan welcome
    (Continue only): only the required age/developer box is ticked, never the e-mail opt-in."""
    box = page.get_by_role("checkbox", name=TERMS)
    welcome = page.locator(gw.DIALOGS).filter(has_text=WELCOME)
    ticked = bool(box.count()) and box.first.is_visible()
    if not ticked and not (welcome.count() and welcome.first.is_visible()):
        return False
    try:
        if ticked and not box.first.is_checked():
            box.first.check(timeout=8000)
        button = next((b.first for b in (page.get_by_role("button", name=n, exact=True) for n in TERMS_BUTTONS)
                       if b.count() and b.first.is_enabled()), None)
        if button is None:
            raise drift("the first-use terms show no enabled Continue")
        button.click(timeout=8000)
        deadline = time.time() + 15
        while time.time() < deadline and (box.count() and box.first.is_visible()
                                          or welcome.count() and welcome.first.is_visible()):
            page.wait_for_timeout(500)
    except gw.Failure:
        raise
    except Exception as error:  # noqa: BLE001
        raise drift("the first-use terms (I acknowledge … Continue)") from error
    gw.write_meta(account, aistudio_terms_accepted_at=int(time.time()))
    gw.ledger({"kind": "aistudio-speech", "event": "terms-accepted", "account": account,
               "form": "checkbox" if ticked else "welcome"})
    print(f"gemini-speech: accepted AI Studio's first-use terms on {account}", file=sys.stderr, flush=True)
    return True


def open_composer(page, account: str, model_id: str, timeout_s: float = 60.0) -> bool:
    """A fresh dialog on every take: a reload drops the last run's blocks, voices and director's notes."""
    url = f"{SITE}/generate-speech?model={model_id}"
    page.goto(url, wait_until="domcontentloaded", timeout=timeout_s * 1000)
    accepted = False
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        host_path = page.url.split("://", 1)[-1]
        if host_path.startswith("accounts.google.com") or page.get_by_role("button", name="Sign in", exact=True).count():
            gw.write_meta(account, aistudio_signed_in=False)
            raise gw.Failure(4, f"AI Studio shows {account} signed out; the owner signs in once: geminib web {account}")
        if accept_terms(page, account):
            accepted = True
            if "/onboarding" in page.url or "generate-speech" not in page.url:
                page.goto(url, wait_until="domcontentloaded", timeout=timeout_s * 1000)
            continue
        gw.click_if_visible(page, "button", "Close guided tour")
        gw.close_promos(page, account, keep=(*gw.RIGHTS_NOTICES, "I acknowledge that I am at least 18",
                                                    "Welcome to AI Studio", "Gemini API Additional Terms"))
        if gw.click_if_visible(page, "button", "Create new dialog"):
            continue
        box = page.get_by_role("textbox", name="Speech block text")
        if box.count() and box.first.is_visible():
            try:
                page.get_by_text(model_id, exact=True).first.wait_for(timeout=15000)
            except Exception as error:  # noqa: BLE001
                raise drift(f"the run settings do not show {model_id}") from error
            gw.write_meta(account, aistudio_signed_in=True)
            return accepted
        page.wait_for_timeout(500)
    raise drift(f"no speech composer within {timeout_s:.0f}s ({page.url})")


def blocks(page):
    return page.get_by_role("region", name="Speech block")


def chip(block):
    return block.get_by_role("button", name=re.compile(r"^Speaker \d"))


def chip_text(block) -> str:
    return " ".join(chip(block).first.inner_text(timeout=8000).replace("arrow_drop_down", "").split())


def panel(page):
    return page.locator(".cdk-overlay-pane").filter(has=page.get_by_role("textbox", name="Search voices")).last


def close_panel(page) -> None:
    with contextlib.suppress(Exception):
        panel(page).get_by_role("button", name="Close panel").click(timeout=5000)
    page.wait_for_timeout(500)


def name_pattern(text: str, tail: str) -> re.Pattern:
    """Playwright writes a regex name into its selector as /…/, so an unescaped slash (Promo/Hype) is an
    InvalidSelectorError."""
    return re.compile("^" + re.escape(text).replace("/", r"\/") + tail)


def title(text: str) -> re.Pattern:
    """An item whose accessible name starts with text."""
    return name_pattern(text, r"(\s|$)")


def read_part(page, read):
    try:
        return read()
    except Exception:  # noqa: BLE001
        with contextlib.suppress(Exception):
            page.keyboard.press("Escape")
        return None


def live_models(page, model_id: str) -> list[str]:
    page.get_by_role("button", name=re.compile(re.escape(model_id))).first.click(timeout=8000)
    pane = page.locator(".cdk-overlay-pane").filter(has=page.get_by_role("region", name="Model carousel")).last
    try:
        pane.get_by_role("button", name="Audio", exact=True).click(timeout=8000)
        page.wait_for_timeout(800)
        lines = pane.evaluate("(el) => [...el.querySelectorAll('button')].flatMap(b => b.innerText.split('\\n'))")
    finally:
        with contextlib.suppress(Exception):
            pane.get_by_role("button", name="Close panel").click(timeout=5000)
    return sorted({line.strip() for line in lines if TTS_ID.match(line.strip())})


def live_tags(page, block) -> list[str]:
    toggle = block.get_by_role("button", name=re.compile(r"Expression$"))
    toggle.click(timeout=8000)
    try:
        bar = page.get_by_role("toolbar", name="Expression tags").first
        bar.wait_for(timeout=8000)
        return [" ".join(t.split()) for t in bar.get_by_role("button").all_inner_texts()]
    finally:
        with contextlib.suppress(Exception):
            toggle.click(timeout=5000)


def live_voices(page, block, classic: bool) -> dict:
    """The 3.8 panel shows each use case's count and its first three voices; the older models' panel lists all."""
    chip(block).first.click(timeout=8000)
    pane = panel(page)
    try:
        region = pane.get_by_role("region", name="Available voices")
        region.wait_for(timeout=8000)
        page.wait_for_timeout(500)
        snap = region.aria_snapshot()
        shown = {"counts": [f"{use} {n}" for use, n in VOICE_COUNT.findall(snap)], "names": VOICE_NAME.findall(snap)}
        for key, label in DIRECTOR.items() if classic else ():
            def menu(label=label):
                pane.get_by_role("button", name=label, exact=True).first.click(timeout=8000)
                items = page.get_by_role("menuitem")
                items.first.wait_for(timeout=8000)
                options = [t.split("\n")[0].strip() for t in items.all_inner_texts()]
                page.keyboard.press("Escape")
                page.wait_for_timeout(300)
                return options
            shown[key] = read_part(page, menu)
        return shown
    finally:
        close_panel(page)


def page_caps(page, plan: dict) -> list[str]:
    """`.speech` is the only place a caller learns the options, so each take compares what the composer offers with
    it before composing: an added model, voice, tag or director option shows as `caps=stale`, not only a removed one."""
    c = caps()
    fam = c["families"][plan["family"]]
    block = blocks(page).first
    classic = plan["family"] == "classic"
    drift = gw.caps_drift("models", read_part(page, lambda: live_models(page, plan["model_id"])),
                          [m["id"] for m in c["models"].values()])
    drift += gw.caps_drift("tags", read_part(page, lambda: live_tags(page, block)), fam["tags"])
    shown = read_part(page, lambda: live_voices(page, block, classic)) or {}
    roster = family_voices(plan["family"], c)
    if classic:
        drift += gw.caps_drift("voices", shown.get("names"), roster)
        for key, label in DIRECTOR.items():
            drift += gw.caps_drift(f"director {label}", shown.get(key), fam["director"][key])
    else:
        uses: dict[str, int] = {}
        for name in roster:
            uses[c["voices"][name][3]] = uses.get(c["voices"][name][3], 0) + 1
        drift += gw.caps_drift("voice counts", shown.get("counts"), [f"{use} {n}" for use, n in uses.items()])
        drift += gw.caps_drift("voices", shown.get("names"), roster, gone=False)
    caps_checks.record("gemini", "speech", bool(drift), "; ".join(drift))
    return drift


def pick_menu(page, scope, name: str, item: str) -> None:
    button = scope.get_by_role("button", name=name, exact=True).first
    try:
        button.click(timeout=8000)
        page.wait_for_timeout(600)
        page.get_by_role("menuitem", name=title(item)).first.click(timeout=8000)
        page.wait_for_timeout(600)
        shown = " ".join(button.inner_text(timeout=8000).split())
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {item!r} in the {name} menu") from error
    if item not in shown:
        raise drift(f"the {name} menu shows {shown!r} after picking {item!r}")


def set_speaker(page, block, number: int, voice: str, plan: dict) -> None:
    """The speaker panel sets that speaker's voice in every block; on the older models it also holds the speaker's
    Audio Profile and director's notes."""
    want = f"Speaker {number} - {voice}"
    classic = plan["family"] == "classic"
    shown = chip_text(block)
    if shown == want and not (classic and (plan["style"] or plan["director"])):
        return
    try:
        chip(block).first.click(timeout=8000)
        page.wait_for_timeout(1000)
        pane = panel(page)
        if shown != want:
            pane.get_by_role("textbox", name="Search voices").fill(voice, timeout=8000)
            page.wait_for_timeout(1200)
            pane.get_by_role("button", name=name_pattern(voice, r"( \(Current\))?$")).first.click(timeout=8000)
            page.wait_for_timeout(800)
        if classic:
            pane.get_by_role("textbox", name=re.compile("^Describe the voice persona")).fill(plan["style"], timeout=8000)
            for name, item in plan["director"].items():
                pick_menu(page, pane, DIRECTOR[name], item)
    except gw.Failure:
        raise
    except Exception as error:  # noqa: BLE001
        raise drift(f"the speaker panel did not take {voice}") from error
    finally:
        close_panel(page)
    shown = chip_text(block)
    if shown != want:
        raise drift(f"the speaker chip shows {shown!r}, not {want!r}")


def set_style(page, block, style: str) -> None:
    try:
        block.get_by_role("button", name="Style", exact=True).first.click(timeout=8000)
        page.wait_for_timeout(600)
        field = page.get_by_role("textbox", name="Describe the voice style")
        field.fill(style, timeout=8000)
        field.press("Enter")
        page.wait_for_timeout(500)
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)
        shown = block.get_by_role("button", name="Style", exact=True).first.inner_text(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift("no Style field on the speech block") from error
    if " ".join(style.split())[:30] not in " ".join(shown.split()):
        raise drift(f"the block's Style shows {shown.strip()!r}, not the style asked")


def set_temperature(page, value: float) -> None:
    box = page.get_by_role("spinbutton")
    try:
        if not (box.count() and box.first.is_visible()):
            page.get_by_role("button", name="Expand or collapse Model settings").first.click(timeout=8000)
            page.wait_for_timeout(600)
        box.first.fill(f"{value:g}", timeout=8000)
        box.first.press("Tab")
        page.wait_for_timeout(300)
        shown = float(box.first.input_value())
    except Exception as error:  # noqa: BLE001
        raise drift("no Temperature field in the model settings") from error
    if abs(shown - value) > 1e-9:
        raise drift(f"the Temperature field shows {shown:g}, not {value:g}")


def compose(page, plan: dict) -> dict:
    if plan["family"] == "classic":
        for label, value in (("Scene", plan["scene"]), ("Sample Context", plan["context"])):
            try:
                page.get_by_role("textbox", name=label, exact=True).fill(value, timeout=8000)
            except Exception as error:  # noqa: BLE001
                raise drift(f"no {label} field") from error
    for index, turn in enumerate(plan["turns"]):
        if index:
            try:
                page.mouse.move(5, 5)
                page.get_by_role("button", name="Add speech block").first.click(timeout=8000)
                page.wait_for_timeout(800)
            except Exception as error:  # noqa: BLE001
                raise drift("no Add speech block button") from error
        block = blocks(page).nth(index)
        number = plan["speakers"].index(turn["voice"]) + 1
        if not chip_text(block).startswith(f"Speaker {number} "):
            raise drift(f"block {index + 1} belongs to {chip_text(block)!r}, not Speaker {number}")
        try:
            block.get_by_role("textbox", name="Speech block text").fill(turn["text"], timeout=8000)
        except Exception as error:  # noqa: BLE001
            raise drift("no Speech block text field") from error
        if plan["family"] == "design" and turn["style"]:
            set_style(page, block, turn["style"])
    for number, voice in enumerate(plan["speakers"], 1):
        index = next(i for i, t in enumerate(plan["turns"]) if t["voice"] == voice)
        set_speaker(page, blocks(page).nth(index), number, voice, plan)
    if plan["family"] == "design" and len(plan["speakers"]) == 2:
        gw.set_switch(page, "Filler words", plan["filler_words"], drift, "the run settings")
    set_temperature(page, plan["temperature"])
    return {"model": plan["model_id"], "speakers": [chip_text(blocks(page).nth(
                next(i for i, t in enumerate(plan["turns"]) if t["voice"] == v))) for v in plan["speakers"]],
            "blocks": blocks(page).count(), "temperature": plan["temperature"]}


class Replies:
    """GenerateContent replies the page itself receives; nothing is requested from outside."""

    def __init__(self, page):
        self.seen: list = []
        self.finished: list = []
        page.on("response", lambda response: self.seen.append(response)
                if response.url.endswith("/GenerateContent") else None)
        page.on("requestfinished", lambda request: self.finished.append(request)
                if request.url.endswith("/GenerateContent") else None)

    def mark(self) -> int:
        return len(self.seen)


def page_text(page) -> str:
    try:
        dump = page.evaluate(gw.PAGE_DUMP)
    except Exception:  # noqa: BLE001
        return ""
    return " ".join(" ".join(dump.get("dialogs") or []).split() + " ".join(dump.get("toasts") or []).split())


def reply_text(reply) -> str:
    with contextlib.suppress(Exception):
        return reply.body().decode("utf-8", "replace")
    return ""


def pcm_bytes(body: str) -> int:
    return sum(len(base64.b64decode(chunk)) for chunk in AUDIO_CHUNK.findall(body))


def generating(page) -> bool:
    stop = page.get_by_role("button", name=STOP)
    return bool(stop.count()) and stop.first.is_visible()


def run_and_wait(page, replies: Replies, account: str, timeout_s: float) -> int:
    """The first Run after typing can be swallowed by the field's blur, so a Run that starts neither a request nor
    the Stop button within SEND_WAIT_S is pressed once more; 2.5 Pro shows Stop for a minute or more before its
    first reply. The reply streams: the player and its Download show after the first chunk (a 0.08 s WAV), so only
    the finished request ends the wait; it returns the reply's PCM byte count."""
    start = replies.mark()
    run = page.get_by_role("button", name=re.compile(r"^Run\b")).first
    for attempt in range(2):
        try:
            run.click(timeout=8000)
        except Exception as error:  # noqa: BLE001
            raise drift("the Run button stays disabled") from error
        deadline = time.time() + SEND_WAIT_S
        while len(replies.seen) == start and not generating(page) and time.time() < deadline:
            page.wait_for_timeout(500)
        if len(replies.seen) > start or generating(page):
            break
    else:
        raise gw.Failure(1, f"Run sent nothing on {account}: no GenerateContent within {SEND_WAIT_S}s of 2 clicks")
    gw.phase("sent")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        said = page_text(page)
        reply = replies.seen[-1] if len(replies.seen) > start else None
        if LIMIT.search(said) or reply is not None and reply.status != 200:
            body = reply_text(reply) if reply is not None and reply.status != 200 else ""
            words = " ".join(f"{said} {body}".split())[:300] or f"HTTP {reply.status}"
            if reply is not None and reply.status == 429 or LIMIT.search(words):
                raise gw.Failure(3, f"AI Studio refused {account}: {words}", account=account, wall_s=limit_wall_s(words))
            raise gw.Failure(1, f"AI Studio returned no speech on {account}: {words}")
        download = page.get_by_role("button", name="Download", exact=True)
        if reply is not None and reply.request in replies.finished and download.count() and download.first.is_visible():
            body = reply_text(reply)
            size = pcm_bytes(body)
            if not size:
                raise gw.Failure(1, f"AI Studio answered without audio on {account}: {' '.join(body.split())[:200]}")
            return size
        page.wait_for_timeout(500)
    raise gw.Failure(1, f"no speech after {timeout_s:.0f}s on {account}")


PLAYER = "() => { const a = document.querySelector('audio'); return a && a.src.startsWith('data:audio/') ? a.src : null; }"


def save_wav(page, dest: Path, pcm: int, wait_s: float = 30.0) -> int:
    """Not the Download button: it builds the WAV in a sandboxed frame it creates at click time, out of reach of
    a catcher, and hands it to Chrome's download manager, which crashed the hidden Chrome twice (2026-10-06). The
    player's data: URL holds the same bytes (cmp-identical to a caught Download). The page fills it a second or
    two after the reply ends, so it counts only once it holds a WAV header plus every PCM byte of the reply."""
    part = dest.with_name(f".{dest.name}.part")
    deadline = time.time() + wait_s
    audio = b""
    while time.time() < deadline:
        data = page.evaluate(PLAYER)
        audio = base64.b64decode(data.split(",", 1)[1]) if data else b""
        if len(audio) >= WAV_HEADER + pcm:
            break
        page.wait_for_timeout(500)
    else:
        raise drift(f"the player holds {len(audio)} bytes, not the reply's {WAV_HEADER + pcm}")
    part.write_bytes(audio)
    if not RIFF(part.read_bytes()[:12]):
        part.unlink()
        raise gw.Failure(1, "the player's audio is not a WAV")
    part.replace(dest)
    return dest.stat().st_size


def one_take(context, account: str, plan: dict) -> dict:
    page = context.new_page()
    replies = Replies(page)
    accepted = open_composer(page, account, plan["model_id"])
    drift = page_caps(page, plan)
    controls = compose(page, plan)
    if plan["dry_run"]:
        return {"ok": True, "dry_run": True, "account": account, "controls": controls, "terms_accepted": accepted,
                "caps": drift}
    gw.note_started(account)
    gw.ledger({"kind": "aistudio-speech", "event": "queued", "account": account, "model": plan["model_id"],
               "speakers": plan["speakers"], "chars": sum(len(t["text"]) for t in plan["turns"])})
    started = time.time()
    pcm = run_and_wait(page, replies, account, plan["timeout_s"])
    render_s = round(time.time() - started, 1)
    audio = Path(plan["out_dir"]) / "take1.wav"
    size = save_wav(page, audio, pcm)
    gw.write_meta(account, aistudio_speech_at=int(time.time()))
    gw.ledger({"kind": "aistudio-speech", "event": "saved", "account": account, "model": plan["model_id"],
               "bytes": size, "render_s": render_s})
    page.close()
    return {"audio": str(audio), "account": account, "model": plan["model_id"], "speakers": controls["speakers"],
            "bytes": size, "render_s": render_s, "terms_accepted": accepted, "url": f"{SITE}/generate-speech",
            "caps": drift}


def generate_on(account: str, plan: dict) -> dict:
    with gw.file_lock(gw.ROOT / "locks" / f"{account}.lock", wait_s=900), gw.browser(account) as context:
        result = one_take(context, account, plan)
    if result.get("dry_run"):
        return result
    return {"ok": True, "account": account, "takes": [result], "caps": result.pop("caps")}


def cmd_generate(args) -> None:
    plan = make_plan(args)
    gw.TIMED = True
    accounts = take_accounts(args.account)
    gw.take_failover(accounts, plan, generate_on, set_wall, bool(args.account), lock_wait=args.lock_wait)


def main() -> None:
    parser = argparse.ArgumentParser(prog="aistudio-speech-engine")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("generate")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--text")
    p.add_argument("--line", action="append")
    p.add_argument("--voice")
    p.add_argument("--style")
    p.add_argument("--model")
    p.add_argument("--temperature", type=float)
    p.add_argument("--filler-words", action="store_true")
    p.add_argument("--scene")
    p.add_argument("--context")
    p.add_argument("--delivery")
    p.add_argument("--pace")
    p.add_argument("--accent")
    p.add_argument("--account", type=gw.account_arg)
    gw.lock_wait_arg(p)
    p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        cmd_generate(args)
    except gw.Failure as failure:
        if failure.code != 2:
            gw.report(args.account or failure.extra.get("account") or "-", failure)
        gw.fail(failure.code, failure.reason)
    except Exception as error:  # noqa: BLE001
        gw.report(args.account or "-", error)
        gw.fail(1, gw.failure_text(error)[:300])


if __name__ == "__main__":
    main()
