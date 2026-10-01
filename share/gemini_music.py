# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Music from the Gemini app's Create music tool (Lyria 3.5) on a subscription account.

Same hidden Chrome, profiles, locks and job ledger as gemini_web (Flow). The app composer is driven
the way a person would; the finished track is read from the page's own StreamGenerate reply and
downloaded with the profile's cookies. Prints one JSON line; exit 0 ok, 2 usage, 3 limit, 4 the
account has no music tool or no login, 1 other.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gemini_web as gw  # noqa: E402

gw.ROUTE = "gemini-app"

APP = "https://gemini.google.com/app?hl=en"
WALLS = "music-walls.json"
WALL_SECONDS = 6 * 3600
LIMIT_TEXT = re.compile(r"\b(limit|quota)\b|try again (later|tomorrow)|come back (later|tomorrow)", re.I)


def caps() -> dict:
    return json.loads(gw.MANIFEST.read_text())["music"]


def music_walls() -> dict:
    try:
        return json.loads((gw.ROOT / WALLS).read_text())
    except (OSError, ValueError):
        return {}


def set_music_wall(account: str, until: float) -> None:
    gw.update_json(WALLS, lambda data: data.update({account: int(until)}))


def last_music_use() -> dict:
    used: dict[str, int] = {}
    try:
        lines = (gw.ROOT / "jobs.jsonl").read_text().splitlines()
    except OSError:
        return used
    for line in lines:
        try:
            with_ts = json.loads(line)
        except ValueError:
            continue
        if not isinstance(with_ts, dict):
            continue
        if with_ts.get("kind") == "music" and with_ts.get("account"):
            used[with_ts["account"]] = with_ts.get("ts", 0)
    return used


def rotation() -> list[str]:
    now = time.time()
    flow_walls, walls_now, used = gw.walls(), music_walls(), last_music_use()
    # A Flow wall can be an "unusual activity" flag; music stays off that account too.
    ready = [n for n in gw.bound_accounts()
             if flow_walls.get(n, 0) <= now and walls_now.get(n, 0) <= now and gw.in_pool(n)]
    return sorted(ready, key=lambda n: used.get(n, 0))


def stream_chunks(body: str) -> list:
    text = body.split("\n", 1)[1] if body.startswith(")]}'") else body
    decoder, pos, chunks = json.JSONDecoder(), 0, []
    length = re.compile(r"\s*\d+\s*")
    while pos < len(text):
        match = length.match(text, pos)
        if not match:
            break
        try:
            frame, pos = decoder.raw_decode(text, match.end())
        except ValueError:
            break
        for item in frame if isinstance(frame, list) else []:
            if isinstance(item, list) and len(item) > 2 and item[0] == "wrb.fr" and isinstance(item[2], str):
                try:
                    chunks.append(json.loads(item[2]))
                except ValueError:
                    pass
    return chunks


def nodes(value):
    yield value
    if isinstance(value, list):
        for item in value:
            yield from nodes(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from nodes(item)


def uploaded(url: str) -> bool:
    """The reply also lists the files the prompt attached; their storage key says request_data."""
    token = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("c", [""])[0]
    try:
        return b"request_data" in base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))
    except ValueError:
        return False


def media_of(chunk, mime: str) -> dict | None:
    for node in nodes(chunk):
        if isinstance(node, list) and len(node) > 11 and node[11] == mime and isinstance(node[7], list):
            urls = [u for u in node[7] if isinstance(u, str) and u.startswith("https://")]
            direct = [u for u in urls if "contribution.usercontent.google.com/download" in u]
            if any(uploaded(u) for u in direct):
                continue
            seconds = None
            if len(node) > 17 and isinstance(node[17], list) and node[17] and isinstance(node[17][0], list):
                whole, nanos = (node[17][0] + [0, 0])[:2]
                seconds = (whole or 0) + (nanos or 0) / 1e9
            return {"url": (direct or urls or [None])[0], "name": node[2], "seconds": seconds}
    return None


def read_reply(bodies: list[str]) -> dict:
    """What the music tool answered, from every StreamGenerate body of the turn."""
    reply = {"chat": None, "text": "", "states": [], "model": None, "description": "", "audio": None, "video": None}
    for body in bodies:
        for chunk in stream_chunks(body):
            if not isinstance(chunk, list):
                continue
            if len(chunk) > 1 and isinstance(chunk[1], list) and chunk[1] and isinstance(chunk[1][0], str):
                reply["chat"] = chunk[1][0]
            for node in nodes(chunk):
                if isinstance(node, dict) and isinstance(node.get("7"), list) and len(node["7"]) > 1:
                    tool = node["7"][1]
                    if isinstance(tool, list) and tool and tool[0] == "music_gen" and isinstance(tool[-1], int):
                        reply["states"].append(tool[-1])
                if isinstance(node, list) and node and isinstance(node[0], str) and node[0].startswith("bard/llm/lyria"):
                    reply["model"] = node[0].removeprefix("bard/llm/")
                    texts = [t for t in node[1:] if isinstance(t, str)]
                    reply["description"] = max(texts, key=len, default="")
            if len(chunk) > 4 and isinstance(chunk[4], list) and chunk[4] and isinstance(chunk[4][0], list):
                candidate = chunk[4][0]
                if len(candidate) > 1 and isinstance(candidate[1], list) and candidate[1] and isinstance(candidate[1][0], str):
                    reply["text"] = candidate[1][0]
            reply["audio"] = media_of(chunk, "audio/mpeg") or reply["audio"]
            reply["video"] = media_of(chunk, "video/mp4") or reply["video"]
    return reply


def verdict(reply: dict, account: str) -> gw.Failure | None:
    if reply["audio"] and reply["audio"]["url"]:
        return None
    said = " ".join(reply["text"].split())[:300]
    if LIMIT_TEXT.search(said):
        return gw.Failure(3, f"{account} is out of Gemini music generations: {said}", account=account)
    if not reply["states"]:
        return gw.Failure(1, f"Gemini answered without running the music tool: {said or 'no text'}")
    return gw.Failure(1, f"the Gemini music tool returned no track on {account}: {said or 'no text'}")


def drift(what: str) -> gw.Failure:
    return gw.Failure(1, f"Gemini app UI drift: {what}")


def menu_pick(page, name: str) -> None:
    item = page.get_by_role("menuitemradio", name=name, exact=True).or_(
        page.get_by_role("menuitem", name=name, exact=True))
    try:
        item.first.click(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift(f"no menu item {name!r}") from error


def close_disclaimer(page) -> bool:
    """The first-visit "Keep in mind" card keeps the music tool from opening. It grants nothing, unlike the
    rights notices that wait for the owner's yes in notices.json."""
    if not page.get_by_text("Keep in mind", exact=True).count():
        return False
    return gw.click_if_visible(page, "button", "Got it")


def open_music(page, account: str) -> None:
    page.goto(APP, wait_until="domcontentloaded", timeout=60000)
    tools = page.get_by_role("button", name="Upload & tools")
    deadline = time.time() + 45
    while time.time() < deadline:
        if page.url.split("://", 1)[-1].startswith("accounts.google.com"):
            raise gw.Failure(4, f"Google signed {account} out; run: gemini-web login {account}")
        if tools.count():
            break
        page.wait_for_timeout(500)
    else:
        raise drift("the Gemini app shows no Upload & tools button")
    close_disclaimer(page)
    tools.first.click()
    page.get_by_text("More tools", exact=True).first.click(timeout=8000)
    music = page.get_by_text("Create music", exact=True)
    try:
        music.first.wait_for(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise gw.Failure(4, f"the Gemini app offers {account} no Create music tool") from error
    music.first.click()
    page.get_by_role("textbox").first.wait_for(timeout=15000)


def set_chip(page, chip: str, value: str) -> None:
    try:
        page.get_by_role("button", name=chip, exact=True).first.click(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift(f"no {chip} chip in the music composer") from error
    menu_pick(page, value)
    try:
        page.get_by_role("button", name=value).first.wait_for(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift(f"the {chip} chip did not change to {value!r}") from error


NOTICES = ("necessary rights", "A reminder about creating")
AGREED = "notices.json"


def answer_notice(page, account: str) -> bool:
    """Gemini's one-time rights notices (file upload, video in the prompt) block the composer until
    agreed; only an account the owner said yes for is agreed on his behalf."""
    for marker in NOTICES:
        notice = page.locator("mat-dialog-container").filter(has_text=marker)
        if not notice.count():
            continue
        title = " ".join(notice.first.inner_text().split())[:90]
        try:
            agreed = json.loads((gw.ROOT / AGREED).read_text()).get("agreed", [])
        except (OSError, ValueError):
            agreed = []
        if account not in agreed:
            raise gw.Failure(4, f"{account} shows Gemini's notice \"{title}\"; it needs the owner's one-time Agree: "
                                f"with his yes, add {account} to \"agreed\" in {gw.ROOT / AGREED}")
        notice.first.get_by_text("Agree", exact=True).first.click(timeout=8000)
        gw.ledger({"kind": "music", "event": "notice-agreed", "account": account, "notice": title})
        return True
    return False


SPINNING = """() => [...document.querySelectorAll('mat-spinner, mat-progress-spinner, mat-progress-bar, [role=progressbar]')]
    .some(e => e.getBoundingClientRect().width > 0)"""
TOASTS = "() => [...document.querySelectorAll('simple-snack-bar, .mat-mdc-snack-bar-label')].map(e => e.innerText.trim())"


def attach(page, account: str, paths: list[Path], wait_s: float) -> None:
    choosers: list = []
    page.on("filechooser", lambda chooser: choosers.append(chooser))
    page.get_by_role("button", name="Upload & tools").first.click()
    try:
        page.get_by_role("menuitem", name="Upload files").first.click(timeout=8000)
    except Exception as error:  # noqa: BLE001
        raise drift("no Upload files item under Upload & tools") from error
    deadline = time.time() + 10
    while not choosers and time.time() < deadline:
        if answer_notice(page, account):
            page.wait_for_timeout(1500)
            if not choosers:
                page.get_by_role("button", name="Upload & tools").first.click()
                page.get_by_role("menuitem", name="Upload files").first.click(timeout=8000)
        page.wait_for_timeout(250)
    if not choosers:
        raise drift("Upload files opened no file chooser")
    choosers[0].set_files([str(path) for path in paths])
    deadline = time.time() + wait_s
    while time.time() < deadline:
        page.wait_for_timeout(1000)
        toasts = [t for t in page.evaluate(TOASTS) if t]
        if toasts:
            raise gw.Failure(1, f"Gemini refused the upload: {toasts[0][:200]}")
        if page.locator("uploader-file-preview").count() >= len(paths) and not page.evaluate(SPINNING):
            return
    raise gw.Failure(1, f"{len(paths)} file(s) did not finish uploading within {wait_s:.0f}s")


def save(context, url: str, dest: Path, kind: str) -> int:
    response = context.request.get(url, timeout=180000)
    body = response.body()
    good = body[4:8] == b"ftyp" if kind == "video" else (body[:3] == b"ID3" or body[:1] == b"\xff")
    if response.status != 200 or not good:
        raise gw.Failure(1, f"{kind} download failed (HTTP {response.status}, {len(body)} bytes)")
    part = dest.with_name(f".{dest.name}.part")
    part.write_bytes(body)
    part.replace(dest)
    return len(body)


def finished(page) -> bool:
    last = page.locator("model-response").last
    if not page.locator("model-response").count():
        return False
    return bool(last.get_by_role("button", name="Download track").count()
                or last.get_by_role("button", name="Good response").count())


def generate_on(account: str, plan: dict) -> dict:
    takes: list[dict] = []
    first = plan.get("first_take", 1)
    with gw.file_lock(gw.ROOT / "locks" / f"{account}.lock", wait_s=900), gw.browser(account) as context:
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


def one_take(context, account: str, plan: dict, take: int) -> dict:
    out_dir = Path(plan["out_dir"])
    page = context.new_page()
    bodies: list = []
    page.on("response", lambda r: bodies.append(r) if "StreamGenerate" in r.url else None)
    open_music(page, account)
    for chip, value in plan["chips"]:
        set_chip(page, chip, value)
    if plan["attach"]:
        attach(page, account, [Path(path) for path in plan["attach"]], plan["upload_wait_s"])
    if plan["dry_run"]:
        return {"ok": True, "dry_run": True, "account": account, "chips": plan["chips"]}
    page.get_by_role("textbox").first.click()
    page.keyboard.insert_text(plan["prompt"])
    started = time.time()
    gw.ledger({"kind": "music", "event": "queued", "account": account, "take": take,
               "prompt": plan["prompt"][:500], "chips": plan["chips"]})
    page.get_by_role("button", name="Send message").first.click()
    page.wait_for_timeout(3000)
    while not finished(page):
        answer_notice(page, account)
        if time.time() - started > plan["timeout_s"]:
            gw.ledger({"kind": "music", "event": "timeout", "account": account, "url": page.url})
            sent = "/app/" in page.url
            raise gw.Failure(1, f"no track after {plan['timeout_s']}s on {account} "
                                f"({page.url if sent else 'the prompt was never sent: no chat opened'})")
        page.wait_for_timeout(2000)
    page.wait_for_timeout(1500)
    reply = read_reply([r.text() for r in bodies])
    failure = verdict(reply, account)
    if failure:
        gw.ledger({"kind": "music", "event": "failed", "account": account, "chat": reply["chat"],
                   "code": failure.code, "reason": failure.reason, "states": reply["states"]})
        raise failure
    audio = out_dir / f"take{take}.mp3"
    size = save(context, reply["audio"]["url"], audio, "audio")
    video, video_error = None, None
    if reply["video"] and reply["video"]["url"]:
        video = out_dir / f"take{take}.mp4"
        # The cover-art mp4 is rendered after the reply ends; its link 404s for a while.
        for attempt in range(6):
            try:
                save(context, reply["video"]["url"], video, "video")
                video_error = None
                break
            except gw.Failure as failure:
                video_error = failure.reason
                if attempt < 5:
                    page.wait_for_timeout(10000)
        if video_error:
            video = None
            gw.warn(account, f"the cover-art mp4 did not download: {video_error}", route="gemini-app")
    gw.ledger({"kind": "music", "event": "saved", "account": account, "chat": reply["chat"],
               "model": reply["model"], "bytes": size, "seconds": reply["video"] and reply["video"]["seconds"],
               "video_error": video_error})
    result = {"audio": str(audio), "video": str(video) if video else None, "video_error": video_error,
              "chat": reply["chat"], "account": account,
              "url": page.url, "model": reply["model"], "description": reply["description"],
              "text": reply["text"], "render_s": round(time.time() - started, 1)}
    page.close()
    return result


def cmd_generate(args) -> None:
    c = caps()
    chips = []
    if args.length:
        chips.append(("Length", c["lengths"][args.length]["label"]))
    if args.vocals:
        chips.append(("Vocals", c["vocals"][args.vocals]))
    if args.genre:
        chips.append(("Genre", args.genre))
    plan = {"prompt": args.prompt, "chips": chips, "attach": args.attach or [], "count": args.count,
            "out_dir": args.out_dir, "dry_run": args.dry_run, "timeout_s": c["timeout_s"],
            "upload_wait_s": c["upload_wait_s"]}
    if args.account:
        gw.refuse_out_of_pool(args.account)
    accounts = [args.account] if args.account else rotation()
    if not accounts:
        bound = gw.bound_accounts()
        if not bound:
            gw.fail(4, "no Gemini account is signed in; run: gemini-web login <account>")
        if not any(gw.in_pool(name) for name in bound):
            gw.fail(4, 'every signed-in Gemini account is out of the gemini worker pool; turn "In pool" back on '
                       "for one, or pin it in ~/.claude/worker-model")
        gw.fail(3, "no signed-in account is free of music and Flow walls")
    done: list[dict] = []
    last: gw.Failure | None = None
    for account in accounts:
        try:
            result = generate_on(account, {**plan, "first_take": len(done) + 1, "count": plan["count"] - len(done)})
        except Exception as error:
            done += getattr(error, "takes", [])
            if not isinstance(error, gw.Failure):
                if not done:
                    raise
                gw.report(account, error)
                last = gw.Failure(1, gw.failure_text(error)[:300])
                break
            gw.report(account, error)
            last = error
            if error.code == 3 and not args.account:
                set_music_wall(account, time.time() + WALL_SECONDS)
                continue
            if error.code == 4 and not args.account:
                continue
            if done:
                break
            gw.fail(error.code, error.reason, account=account)
        else:
            if result.get("dry_run"):
                gw.emit(result)
                return
            gw.emit({"ok": True, "account": done[0]["account"] if done else account, "takes": done + result["takes"]})
            return
    if done:
        gw.emit({"ok": True, "account": done[0]["account"], "takes": done,
                 "short": f"{len(done)} of {plan['count']} takes; the next one failed: {last.reason}"})
        return
    gw.fail(last.code if last else 3, last.reason if last else "no account")


def main() -> None:
    parser = argparse.ArgumentParser(prog="gemini-music-engine")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("generate")
    p.add_argument("--prompt", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--length", choices=["short", "standard"])
    p.add_argument("--vocals", choices=["custom", "on", "instrumental"])
    p.add_argument("--genre")
    p.add_argument("--attach", action="append")
    p.add_argument("--count", type=int, default=1)
    p.add_argument("--account")
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
