# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Google Flow (flow.google.com) video on a subscription account, through a hidden Chrome clone.

One Chrome profile per geminib account under GEMINI_WEB_DIR. The owner signs each one in once
(`login`); everything else runs the clone off-screen with no Dock icon. A generation goes through
Flow's manual composer the way a person would: the page mints its own reCAPTCHA for every call, and
the composer's own credit quote is checked against the manifest before anything is spent.
Every command prints one JSON line; exit 0 ok, 2 usage, 3 out of credits, 4 login needed, 1 other.
"""
from __future__ import annotations

import argparse
import base64
import calendar
import contextlib
import datetime
import fcntl
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

ROOT = Path(os.environ.get("GEMINI_WEB_DIR", "~/.gemini-web")).expanduser()
SOURCE_APP = Path(os.environ.get("GEMINI_WEB_CHROME", "/Applications/Google Chrome.app"))
CLONE_APP = ROOT / "Gemini Web Automation.app"
CLONE_ID = "com.google.Chrome.gemini-web"
MANIFEST = Path(__file__).resolve().parent / "image-caps" / "gemini.json"
REPO = Path(__file__).resolve().parent.parent
FLOW = "https://flow.google.com"
LOGIN_URL = "https://accounts.google.com/ServiceLogin?continue=" + FLOW + "/"
WALL_SECONDS = 6 * 3600
BLOCK_WALL_SECONDS = 24 * 3600
BLOCK_ERRORS = {"PUBLIC_ERROR_UNUSUAL_ACTIVITY"}
# One generation rpc per composer mode: text, frames, ingredients, video edit, extend.
GENERATE_RPCS = {"YhhmEf", "nprQif", "MZZa6b", "jIps6", "fZytfe"}
DONE = 3


class Failure(Exception):
    def __init__(self, code: int, reason: str, **extra):
        super().__init__(reason)
        self.code, self.reason, self.extra = code, reason, extra


FAILURES_KEEP_S = 14 * 86400
ROUTES = (("flow.google.com", "flow"), ("labs.google", "flow"), ("gemini.google.com", "gemini-app"),
          ("flowmusic.app", "flow-music"))
ROUTE = "flow"
_reported: set[tuple[str, str]] = set()
DIALOGS = "[role=dialog],[role=alertdialog],mat-dialog-container"
PAGE_DUMP = """() => {
  const seen = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const texts = sel => [...document.querySelectorAll(sel)].filter(seen).map(e => e.innerText.trim()).filter(Boolean);
  return {title: document.title,
          dialogs: texts('""" + DIALOGS + """'),
          toasts: texts('[role=alert],[role=status],mat-snack-bar-container,simple-snack-bar'),
          buttons: [...document.querySelectorAll('button,[role=button],[role=menuitem]')].filter(seen)
            .map(b => (b.getAttribute('aria-label') || b.innerText || '').trim().slice(0, 60)).filter(Boolean).slice(0, 80),
          body: (document.body ? document.body.innerText : '').slice(0, 4000)};
}"""


# A toast that came and went during a run that still succeeded leaves no failure note, so every page
# keeps the texts it showed; sessionStorage outlives the run's own navigations.
TOAST_LOG = """(() => {
  const sel = '[role=alert],[role=status],mat-snack-bar-container,simple-snack-bar';
  let queued = false;
  const scan = () => {
    queued = false;
    let kept;
    try { kept = JSON.parse(sessionStorage.getItem('gwToasts') || '[]'); } catch (e) { return; }
    for (const el of document.querySelectorAll(sel)) {
      const text = (el.innerText || '').trim().replace(/\\s+/g, ' ').slice(0, 200);
      if (/[a-z]{3}/i.test(text) && !kept.includes(text) && kept.length < 20) kept.push(text);
    }
    try { sessionStorage.setItem('gwToasts', JSON.stringify(kept)); } catch (e) {}
  };
  new MutationObserver(() => { if (!queued) { queued = true; setTimeout(scan, 500); } })
    .observe(document, {subtree: true, childList: true, characterData: true});
})()"""


def note_toasts(context, account: str) -> None:
    texts = []
    for page in list(context.pages):
        with contextlib.suppress(Exception):
            texts += [text for text in page.evaluate("() => JSON.parse(sessionStorage.getItem('gwToasts') || '[]')")
                      if text not in texts]
    if texts:
        ledger({"account": account, "event": "toasts", "route": route_of(context.pages[-1].url), "texts": texts})


def route_of(url: str) -> str:
    host = urllib.parse.urlparse(url or "").netloc
    return next((name for domain, name in ROUTES if host == domain or host.endswith("." + domain)), ROUTE)


def failure_text(error: BaseException) -> str:
    if isinstance(error, Failure):
        return error.reason
    lines = [line.strip() for line in str(error).strip().splitlines() if line.strip()]
    waiting = next((line for line in lines[1:] if "waiting for" in line), "")
    return f"{error.__class__.__name__}: {lines[0] if lines else ''}" + (f" ({waiting})" if waiting else "")


def snapshot(context, account: str, reason: str) -> str:
    """The page as the failure left it: a screenshot plus its dialogs, toasts, buttons and text."""
    pages = [page for page in getattr(context, "pages", []) if not page.is_closed()]
    if not pages:
        return ""
    page, folder = pages[-1], ROOT / "failures"
    base = folder / f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{account}-{os.getpid()}"
    try:
        folder.mkdir(parents=True, exist_ok=True)
        old_files = list(folder.iterdir())
    except OSError:
        return ""
    for old in old_files:
        with contextlib.suppress(OSError):
            if old.stat().st_mtime < time.time() - FAILURES_KEEP_S:
                old.unlink()
    shot = base.with_suffix(".png")
    with contextlib.suppress(Exception):
        page.screenshot(path=str(shot), timeout=8000)
    try:
        dump = page.evaluate(PAGE_DUMP)
    except Exception as error:
        dump = {"error": failure_text(error)}
    lines = [f"reason: {reason}", f"url: {page.url}"]
    for key in ("title", "error"):
        if dump.get(key):
            lines.append(f"{key}: {dump[key]}")
    for key in ("dialogs", "toasts", "buttons"):
        lines += [f"{key}:"] + [f"  {' '.join(str(item).split())[:300]}" for item in dump.get(key) or []]
    lines += ["body:", str(dump.get("body") or "")]
    with contextlib.suppress(OSError):
        base.with_suffix(".txt").write_text("\n".join(lines) + "\n")
    return str(shot if shot.exists() else base.with_suffix(".txt"))


def report(account: str, error: BaseException, kind: str = "FAILURE", route: str | None = None) -> None:
    """One stderr line per failed browser attempt; the image-leg log keeps it and llm-doctor reads it."""
    reason = failure_text(error)
    if (account, reason) in _reported:
        return
    _reported.add((account, reason))
    code = error.code if isinstance(error, Failure) else (0 if kind == "WARNING" else 1)
    shot = getattr(error, "shot", "") or "-"
    print(f"BROWSER_{kind} route={route or getattr(error, 'route', '') or ROUTE} account={account or '-'} "
          f"code={code} shot={shot} reason={' '.join(reason.split())[:300]}", file=sys.stderr, flush=True)


def warn(account: str, reason: str, route: str | None = None) -> None:
    report(account, Failure(0, reason), kind="WARNING", route=route)


def emit(payload: dict) -> None:
    print(json.dumps(payload), flush=True)


def fail(code: int, reason: str, **extra) -> None:
    emit({"ok": False, "code": code, "reason": reason, **extra})
    sys.exit(code)


def valid_account(account: str) -> bool:
    return bool(re.fullmatch(r"[a-z0-9][a-z0-9-]*", account or ""))


def profile_dir(account: str) -> Path:
    if not valid_account(account):
        raise Failure(2, f"bad account name {account!r}")
    return ROOT / "profiles" / account


def meta_path(account: str) -> Path:
    return ROOT / "accounts" / f"{account}.json"


def read_meta(account: str) -> dict:
    try:
        return json.loads(meta_path(account).read_text())
    except (OSError, ValueError):
        return {}


def write_meta(account: str, **fields) -> dict:
    meta = {**read_meta(account), **fields}
    path = meta_path(account)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(meta, indent=1))
    tmp.replace(path)
    return meta


def app_version(app: Path) -> str:
    with open(app / "Contents" / "Info.plist", "rb") as f:
        return plistlib.load(f)["CFBundleShortVersionString"]


# The clone's GoogleUpdater (--wake-all) holds Chrome's stdio, so context.close waited ~10 min for it (5 of 22
# bench runs, 2026-10-01). A clone built before build_clone stripped it lacks this mark and is rebuilt.
CLONE_RECIPE = "no-updater"


def clone_current(want: str) -> bool:
    try:
        with open(CLONE_APP / "Contents" / "Info.plist", "rb") as f:
            info = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        return False
    return info.get("CFBundleShortVersionString") == want and info.get("GeminiWebCloneRecipe") == CLONE_RECIPE


@contextlib.contextmanager
def file_lock(path: Path, wait_s: float | None = None):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as handle:
        deadline = None if wait_s is None else time.time() + wait_s
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | (fcntl.LOCK_NB if deadline else 0))
                break
            except BlockingIOError:
                if time.time() > deadline:
                    raise Failure(1, f"timed out waiting for {path.name}")
                time.sleep(1)
        yield


def busy(account: str) -> bool:
    with contextlib.suppress(OSError), open(ROOT / "locks" / f"{account}.lock", "a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


def free_first(accounts: list[str]) -> list[str]:
    """One Chrome per profile, so a run behind another on its account waits up to 15 min: idle accounts go
    first, each group in the rotation's own order."""
    return sorted(accounts, key=busy)


@contextlib.contextmanager
def chrome_clone():
    if not SOURCE_APP.exists():
        raise Failure(1, f"Google Chrome not found at {SOURCE_APP}")
    want = app_version(SOURCE_APP)
    ROOT.mkdir(parents=True, exist_ok=True)
    with open(ROOT / ".clone-use.lock", "w") as use:
        with file_lock(ROOT / ".clone.lock"):
            try:
                fcntl.flock(use, fcntl.LOCK_EX | fcntl.LOCK_NB)
                idle = True
            except BlockingIOError:
                idle = False
            # Running Chromes execute from the clone, so a Chrome update waits for the last of them.
            if idle and not clone_current(want):
                build_clone()
            fcntl.flock(use, fcntl.LOCK_SH)
        yield CLONE_APP


def build_clone() -> None:
    staging = CLONE_APP.with_name(f".clone-{os.getpid()}.app")
    shutil.rmtree(staging, ignore_errors=True)
    try:
        subprocess.run(["cp", "-Rc", str(SOURCE_APP), str(staging)], check=True, timeout=300)
        for updater in staging.glob("Contents/Frameworks/*/Versions/*/Helpers/GoogleUpdater.app"):
            shutil.rmtree(updater)
        shutil.rmtree(staging / "Contents" / "Library" / "LaunchServices", ignore_errors=True)
        info_path = staging / "Contents" / "Info.plist"
        with open(info_path, "rb") as f:
            info = plistlib.load(f)
        # LSUIElement makes Chromium treat itself as a helper and crash before loading ICU data.
        info.pop("LSUIElement", None)
        info["LSBackgroundOnly"] = True
        info["CFBundleIdentifier"] = CLONE_ID
        info["CFBundleName"] = info["CFBundleDisplayName"] = "Gemini Web Automation"
        info["GeminiWebCloneRecipe"] = CLONE_RECIPE
        with open(info_path, "wb") as f:
            plistlib.dump(info, f)
        subprocess.run(["xattr", "-cr", str(staging)], check=True, timeout=120)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(staging)],
                       check=True, timeout=600, capture_output=True)
        shutil.rmtree(CLONE_APP, ignore_errors=True)
        staging.replace(CLONE_APP)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def chrome_binary(app: Path) -> str:
    return str(app / "Contents" / "MacOS" / "Google Chrome")


# Every launch, the owner's login included, runs with the mock keychain: cookies are then encrypted
# with one fixed key, so no keychain prompt ever blocks an unattended run and a rebuilt (re-signed)
# clone still reads the cookies the real Chrome wrote at login.
# AutomationControlled sets navigator.webdriver, and with it every Gemini-app music generation fails.
COMMON_FLAGS = ["--use-mock-keychain", "--no-first-run", "--no-default-browser-check",
                "--disable-features=Translate,MediaRouter", "--lang=en-US",
                "--disable-blink-features=AutomationControlled"]


def profile_in_use(profile: Path) -> bool:
    lock = profile / "SingletonLock"
    if not lock.is_symlink():
        return False
    pid = os.readlink(lock).rsplit("-", 1)[-1]
    try:
        os.kill(int(pid), 0)
        return True
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True


def has_login(account: str) -> bool:
    return (profile_dir(account) / "Default" / "Cookies").exists()


@contextlib.contextmanager
def browser(account: str, visible: bool = False):
    from playwright.sync_api import sync_playwright

    profile = profile_dir(account)
    if not has_login(account):
        raise Failure(4, f"account {account} has no browser login; run: gemini-web login {account}")
    if profile_in_use(profile):
        raise Failure(1, f"profile {account} is open in another Chrome (the login window?); close it")
    flags = [*COMMON_FLAGS, "--window-size=1440,1000", "--disable-renderer-backgrounding",
             "--disable-backgrounding-occluded-windows", "--disable-background-timer-throttling"]
    if not visible:
        # Off-screen, not headless: headless Chrome is served a different, bot-checked page.
        flags.append("--window-position=-30000,-30000")
    with chrome_clone() as clone, sync_playwright() as pw:
        context = pw.chromium.launch_persistent_context(
            str(profile), executable_path=chrome_binary(clone), headless=False, args=flags,
            ignore_default_args=["--enable-automation"],
            viewport=None, accept_downloads=True, locale="en-US")
        with contextlib.suppress(Exception):
            context.add_init_script(TOAST_LOG)
        watcher = None
        if not visible:
            hide_clone(account)
            context.on("page", lambda page: hide_clone(account))
            watcher = keep_hidden(account)
        try:
            yield context
        except Exception as error:
            with contextlib.suppress(Exception):
                pages = [page for page in context.pages if not page.is_closed()]
                error.route = route_of(pages[-1].url) if pages else ROUTE
                error.shot = snapshot(context, account, failure_text(error))
            report(account, error)
            raise
        finally:
            with contextlib.suppress(Exception):
                note_toasts(context, account)
            with contextlib.suppress(Exception):
                context.close()
            if watcher:
                watcher.terminate()


# Chrome brings itself forward on a new window, a download or a dialog. One osascript polls for the
# whole run: an osascript spawned every 3 s left the page up long enough for the owner to read it.
# It quits once no clone runs, so a killed run cannot leave it polling forever.
HIDE_WATCH = """on run argv
  set bundleId to item 1 of argv
  repeat
    tell application "System Events"
      if not (exists (first process whose bundle identifier is bundleId)) then return
      try
        set visible of (every process whose bundle identifier is bundleId and visible is true) to false
      end try
    end tell
    delay 0.2
  end repeat
end run"""


def keep_hidden(account: str) -> subprocess.Popen | None:
    try:
        return subprocess.Popen(["osascript", "-e", HIDE_WATCH, CLONE_ID],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as error:
        warn(account, f"could not keep the automation Chrome hidden: {error}")
        return None


# macOS Chrome pulls --window-position back until 40 px of the window are on screen, so only hiding
# the app (what Cmd-H does) keeps the window out of the owner's sight; the page stays "visible".
def hide_clone(account: str = "-") -> None:
    script = ('tell application "System Events" to set visible of '
              f'(every process whose bundle identifier is "{CLONE_ID}") to false')
    try:
        result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        warn(account, f"could not hide the automation Chrome: {error}")
        return
    if result.returncode:
        warn(account, f"could not hide the automation Chrome: {result.stderr.strip()[:200]}")


def page_state(page) -> dict:
    return page.evaluate("""() => {
        const wiz = globalThis.WIZ_global_data || {};
        return {url: location.href, email: wiz.oPEP7c || null, has_at: !!wiz.SNlM0e,
                build: wiz.cfb2h || null};
    }""")


def signed_out(state: dict) -> bool:
    host_path = state["url"].split("://", 1)[-1]
    return host_path.startswith("accounts.google.com") or host_path.startswith("flow.google.com/about")


def goto_flow(page, path: str = "/", timeout_s: float = 45.0) -> dict:
    page.goto(f"{FLOW}{path}?hl=en", wait_until="domcontentloaded", timeout=timeout_s * 1000)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        state = page_state(page)
        if signed_out(state):
            raise Failure(4, "Google signed this profile out; run: gemini-web login <account>")
        if state["has_at"]:
            return state
        page.wait_for_timeout(250)
    raise Failure(1, f"Flow did not load within {timeout_s:.0f}s ({page.url})")


def batch_payloads(text: str):
    """(rpcid, decoded payload) of every `wrb.fr` envelope in a batchexecute body."""
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("[["):
            continue
        try:
            chunk = json.loads(line)
        except ValueError:
            continue
        for envelope in chunk:
            if isinstance(envelope, list) and len(envelope) > 2 and envelope[0] == "wrb.fr" \
                    and isinstance(envelope[2], str):
                with contextlib.suppress(ValueError):
                    yield envelope[1], json.loads(envelope[2])


def envelope_errors(text: str) -> set[str]:
    """PUBLIC_ERROR codes of envelopes that failed whole; a media entry's own error is not one."""
    codes = set()
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("[["):
            continue
        try:
            chunk = json.loads(line)
        except ValueError:
            continue
        for envelope in chunk:
            if isinstance(envelope, list) and len(envelope) > 5 and envelope[0] == "wrb.fr" \
                    and envelope[2] is None:
                codes.update(re.findall(r"PUBLIC_ERROR_[A-Z_]+", json.dumps(envelope[5])))
    return codes


def video_url(node, media_id: str) -> str | None:
    found = re.search(r"https://flow-content\.google/video/" + re.escape(media_id) + r"\?[^\"\\]+",
                      json.dumps(node))
    return found.group(0) if found else None


def wire_models(post_data: str) -> list[str]:
    """Model keys (veo_3_1_t2v_fast, abra_t2v_4s_360p, veo_3_1_extension_lite) in a generation request."""
    found = re.findall(r"[a-z][a-z0-9_]*_(?:[a-z]2v|extension)[a-z0-9_]*",
                       urllib.parse.unquote_plus(post_data))
    return list(dict.fromkeys(found))


class Watcher:
    """Collects the page's own media polls and generation calls; it never issues a request."""

    def __init__(self, page=None):
        self.media: dict[str, dict] = {}
        self.credits: int | None = None
        self.reply_credits: int | None = None
        self.errors: set[str] = set()
        self.submitted: list[str] = []
        if page is not None:
            page.on("response", self._on_response)

    def _on_response(self, response) -> None:
        if "rpcids=" not in response.url:
            return
        if re.search(r"rpcids=(" + "|".join(GENERATE_RPCS) + r")\b", response.url):
            with contextlib.suppress(Exception):
                self.submitted += wire_models(response.request.post_data or "")
        try:
            body = response.text()
        except Exception:
            return
        self.feed(body)

    def feed(self, body: str) -> None:
        self.errors |= envelope_errors(body)
        for rpcid, payload in batch_payloads(body):
            if rpcid in ("jwpduf", "as29s") or rpcid in GENERATE_RPCS:
                self._on_media(rpcid, payload)

    def _on_media(self, rpcid: str, payload) -> None:
        if not isinstance(payload, list):
            return
        if rpcid == "jwpduf" or rpcid in GENERATE_RPCS:
            if len(payload) > 1 and isinstance(payload[1], int):
                self.credits = payload[1]
                if rpcid in GENERATE_RPCS:
                    self.reply_credits = payload[1]
            slot = 2 if rpcid == "jwpduf" else 3
            entries = payload[slot] if len(payload) > slot and isinstance(payload[slot], list) else []
        else:
            entries = [payload]
        for entry in entries:
            if not (isinstance(entry, list) and entry and isinstance(entry[0], str)):
                continue
            new = entry[0] not in self.media
            record = self.media.setdefault(entry[0], {})
            with contextlib.suppress(IndexError, TypeError):
                record["status"] = entry[5][8][0]
            with contextlib.suppress(IndexError, TypeError):
                if isinstance(entry[5][1], str):
                    record["prompt"] = entry[5][1]
            with contextlib.suppress(IndexError, TypeError):
                if isinstance(entry[5][6][1][0][0], str):
                    record["model"] = entry[5][6][1][0][0]
            url = video_url(entry, entry[0])
            if url:
                record["url"] = url
            flat = json.dumps(entry)
            error = re.search(r"PUBLIC_ERROR_[A-Z_]+", flat)
            if error:
                record["error"] = error.group(0)
            duration = re.search(r"\[null,\s*null,\s*\[(\d+)\]\]", flat)
            if duration:
                record["duration"] = int(duration.group(1))
            if new:
                record["fresh"] = record.get("status") != DONE and not record.get("url")
            if len(entry) > 2 and isinstance(entry[2], str):
                record["scene"] = entry[2]
            if rpcid in GENERATE_RPCS:
                record["created"] = True

    def blocked(self) -> Failure | None:
        codes = self.errors & BLOCK_ERRORS
        if not codes:
            return None
        return Failure(3, f"Flow flagged this account ({', '.join(sorted(codes))}); nothing was charged",
                       wall_s=BLOCK_WALL_SECONDS)

    def new_clips(self, known: set[str]) -> list[str]:
        return [k for k, r in self.media.items() if k not in known and r.get("created")]

    def new_clip(self, known: set[str], prompt: str) -> str | None:
        """The clip a send created: named in the generation reply, else first seen after the send,
        still rendering and carrying our prompt."""
        created = self.new_clips(known)
        if created:
            return created[-1]
        fresh = [k for k, r in self.media.items() if k not in known and r.get("fresh")]
        same = [k for k in fresh if (self.media[k].get("prompt") or "").strip() == prompt.strip()]
        if same:
            return same[0]
        return fresh[0] if len(fresh) == 1 else None


def click_if_visible(page, role: str, name: str, exact: bool = True) -> bool:
    target = page.get_by_role(role, name=name, exact=exact)
    for index in range(target.count()):
        item = target.nth(index)
        with contextlib.suppress(Exception):
            if item.is_visible():
                item.click(timeout=3000)
                page.wait_for_timeout(600)
                return True
    return False


RIGHTS_NOTICES = ("necessary rights", "A reminder about creating")
DECLINE = ("No thanks", "Not now", "Maybe later", "Dismiss", "Skip", "Close")
_closed: set[tuple[str, str]] = set()


def close_promos(page, account: str = "-", keep: tuple = RIGHTS_NOTICES) -> int:
    """Gemini and Flow open promos over the composer (connect YouTube, Drive, other Google apps). Only a declining
    button or Escape closes one, so nothing is ever accepted; a rights notice (`keep`) is the music engine's to answer."""
    closed = 0
    dialogs = page.locator(DIALOGS)
    for index in reversed(range(dialogs.count())):
        dialog = dialogs.nth(index)
        with contextlib.suppress(Exception):
            if not dialog.is_visible():
                continue
            text = " ".join(dialog.inner_text(timeout=2000).split())
            if any(marker in text for marker in keep):
                continue
            buttons = (dialog.get_by_role("button", name=name, exact=True) for name in DECLINE)
            button = next((b.first for b in buttons if b.count() and b.first.is_visible()), None)
            if button is None:
                page.keyboard.press("Escape")
            else:
                button.click(timeout=3000)
            page.wait_for_timeout(600)
            closed += 1
            if (account, text[:160]) not in _closed:
                _closed.add((account, text[:160]))
                ledger({"kind": "dialog", "event": "closed", "account": account, "route": route_of(page.url),
                        "text": text[:500]})
                print(f"gemini-web: closed a dialog on {account}: {text[:160]}", file=sys.stderr, flush=True)
    return closed


def dismiss_dialogs(page, account: str = "-") -> None:
    close_promos(page, account)
    for name in ("Get started", "Got it", "Dismiss", "No thanks"):
        click_if_visible(page, "button", name)


def composer_ready(page, account: str = "-", timeout_s: float = 45.0) -> None:
    button = page.get_by_role("button", name="Start generation", exact=True)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        dismiss_dialogs(page, account)
        if button.count() and button.last.is_visible():
            return
        page.wait_for_timeout(500)
    raise Failure(1, "Flow UI drift: no 'Start generation' composer on the project page")


def open_project(page, account: str) -> str:
    project = read_meta(account).get("project")
    if project:
        goto_flow(page, f"/project/{project}")
        if f"/project/{project}" in page.url:
            composer_ready(page, account)
            return project
    goto_flow(page, "/")
    new = page.get_by_role("button", name="New project", exact=True)
    try:
        new.wait_for(timeout=30000)
        new.click()
        page.wait_for_url(re.compile(r"/project/[0-9a-f-]{36}"), timeout=30000)
    except Exception as exc:
        raise Failure(1, f"Flow UI drift: could not create a project ({exc.__class__.__name__})")
    project = re.search(r"/project/([0-9a-f-]{36})", page.url).group(1)
    write_meta(account, project=project)
    composer_ready(page, account)
    return project


ALLOWANCE_URL = "https://one.google.com/ai/activity"
ALLOWANCE_TEXT = re.compile(r"([\d,]+) Google Flow credits are included as part of your Google AI plan and refresh (\w+)")
REFILL_JUMP = 200
ALLOWANCE_EVERY_S = 24 * 3600


def month_after(epoch: float) -> int:
    day = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    year, month = (day.year + 1, 1) if day.month == 12 else (day.year, day.month + 1)
    last = calendar.monthrange(year, month)[1]
    return int(day.replace(year=year, month=month, day=min(day.day, last)).timestamp())


def note_credits(account: str, credits: int | None) -> None:
    if credits is None:
        return
    meta, now = read_meta(account), int(time.time())
    fields = {"credits": credits, "credits_at": now}
    previous = meta.get("credits")
    if isinstance(previous, int) and credits - previous >= REFILL_JUMP:
        fields.update(credits_refilled_at=now, credits_renews_at=month_after(now),
                      credits_renews_source="refill observed")
        if meta.get("credits_total_source") != "site":
            fields.update(credits_total=credits, credits_total_source="balance after refill")
    write_meta(account, **fields)


def read_allowance(context, account: str) -> None:
    if time.time() - read_meta(account).get("credits_total_at", 0) < ALLOWANCE_EVERY_S:
        return
    page = context.new_page()
    try:
        page.goto(ALLOWANCE_URL, wait_until="domcontentloaded", timeout=30000)
        found = None
        for _ in range(20):
            found = ALLOWANCE_TEXT.search(" ".join(page.locator("body").inner_text(timeout=5000).split()))
            if found:
                break
            page.wait_for_timeout(500)
        if found and found[2] == "monthly":
            write_meta(account, credits_total=int(found[1].replace(",", "")), credits_total_source="site",
                       credits_total_at=int(time.time()))
    except Exception as error:  # noqa: BLE001
        warn(account, f"could not read the Flow credit allowance: {str(error)[:120]}")
    finally:
        with contextlib.suppress(Exception):
            page.close()


def read_credits(page) -> int | None:
    if not click_if_visible(page, "button", "Account details"):
        return None
    try:
        link = page.get_by_role("link", name=re.compile(r"[\d,]+ Google Flow credits"))
        link.first.wait_for(timeout=8000)
        return int(re.search(r"([\d,]+)", link.first.inner_text()).group(1).replace(",", ""))
    except Exception:
        return None
    finally:
        click_if_visible(page, "button", "Close account panel")


def drift(what: str) -> Failure:
    return Failure(1, f"Flow UI drift: {what}")


def close_overlays(page) -> None:
    backdrop = page.locator(".cdk-overlay-backdrop")
    for _ in range(3):
        if not backdrop.count():
            return
        backdrop.last.click(position={"x": 5, "y": 5})
        page.wait_for_timeout(500)


def manual_composer(page) -> None:
    """Agent toggle off, nothing left in the prompt box from an earlier run."""
    agent = page.get_by_role("button", name="Agent", exact=True)
    if not (agent.count() and agent.last.is_visible()):
        click_if_visible(page, "button", "Close")
    try:
        agent.last.wait_for(timeout=10000)
    except Exception:
        raise drift("no Agent toggle on the composer")
    if agent.last.get_attribute("aria-pressed") == "true":
        agent.last.click()
        page.wait_for_timeout(800)
    if agent.last.get_attribute("aria-pressed") == "true":
        raise drift("the Agent toggle stays on")
    click_if_visible(page, "button", "Clear prompt")
    if page.locator("[contenteditable=true]").last.inner_text().strip():
        raise drift("the prompt box kept earlier text after Clear prompt")


def choose(page, name) -> None:
    radio = page.get_by_role("radio", name=name, exact=isinstance(name, str)).last
    radio.click(timeout=5000)
    page.wait_for_timeout(300)
    if not radio.is_checked():
        raise drift(f"the {getattr(name, 'pattern', name)} setting does not stick")


def settings(page, plan: dict, full: bool) -> tuple[int, str]:
    """Sets the composer popover to the plan and returns Flow's own credit quote and chip text."""
    trigger = page.get_by_role("button", name="Settings trigger", exact=True).last
    family = page.get_by_role("button", name="Select model family")
    if not (family.count() and family.last.is_visible()):
        trigger.click()
    try:
        family.last.wait_for(timeout=8000)
        if full:
            choose(page, "Video")
            family.last.click()
            page.get_by_role("menuitem", name=plan["label"], exact=True).click(timeout=5000)
            page.wait_for_timeout(600)
            choose(page, plan["mode"])
        choose(page, plan["aspect"])
        resolution = page.get_by_role("radio", name=re.compile("^" + plan["resolution"]))
        if resolution.count():
            choose(page, re.compile("^" + plan["resolution"]))
        if plan["duration"] and page.get_by_role("radio", name=f"{plan['duration']}s", exact=True).count():
            choose(page, f"{plan['duration']}s")
        choose(page, f"x{plan['count']}")
        quote = page.get_by_role("link", name=re.compile(r"^\d+ credits?$")).last
        cost = int(re.match(r"\d+", quote.inner_text(timeout=5000)).group(0))
    except Failure:
        raise
    except Exception as exc:
        raise drift(f"composer settings ({exc.__class__.__name__}: "
                    f"{(str(exc).strip().splitlines() or [''])[0][:120]})")
    finally:
        if family.count() and family.last.is_visible():
            trigger.click()
            page.wait_for_timeout(500)
        close_overlays(page)
    return cost, " ".join(trigger.inner_text().split())


def upload(page, path: Path, stem: str, suffix: str, wait_s: float):
    """Uploads through the open picker; returns the finished asset's option."""
    # A unique upload name: the asset list is account-wide, so an older upload of the same file
    # would match first, and one still at "Uploading" would be attached half-sent.
    staged = Path(tempfile.mkdtemp(prefix="gemini-web-")) / f"{stem}-{time.time_ns()}{path.suffix.lower()}"
    shutil.copyfile(path, staged)
    try:
        with page.expect_file_chooser(timeout=15000) as chooser:
            page.get_by_role("button", name="Upload media", exact=True).last.click()
        chooser.value.set_files(str(staged))
        # Images keep their extension in the asset list, videos lose it.
        name = re.escape(staged.stem) + r"(\.\w+)?" + re.escape(suffix) + "$"
        option = page.get_by_role("option", name=re.compile("^" + name))
        uploading = page.get_by_role("option", name=re.compile("^Uploading " + name))
        deadline = time.time() + wait_s
        while not option.count() or uploading.count():
            if time.time() > deadline:
                raise drift(f"the upload of {path.name} never finished in the asset list")
            click_if_visible(page, "button", "I agree")
            page.wait_for_timeout(500)
        return option.first
    finally:
        shutil.rmtree(staged.parent, ignore_errors=True)


def fill_frame(page, slot: str, image: Path) -> None:
    empty = page.get_by_role("button", name=slot, exact=True)
    empty.last.click()
    page.get_by_role("heading", name="Select a frame image").wait_for(timeout=10000)
    upload(page, image, slot.lower(), "", 180).click()
    page.wait_for_timeout(800)
    if empty.count():
        click_if_visible(page, "button", "Add to prompt")
    deadline = time.time() + 15
    while empty.count():
        if time.time() > deadline:
            raise drift(f"the {slot} frame slot never took {image.name}")
        page.wait_for_timeout(500)
    close_overlays(page)


def add_ingredient(page, path: Path, kind: str) -> None:
    chips = page.get_by_role("button", name=re.compile(r"ingredient$", re.IGNORECASE))
    before = chips.count()
    page.get_by_role("button", name="Add ingredients to the prompt box", exact=True).click()
    page.get_by_role("button", name="Upload media", exact=True).last.wait_for(timeout=10000)
    upload(page, path, kind.lower(), f" {kind}", 300 if kind == "Video" else 180).click()
    page.wait_for_timeout(800)
    if chips.count() == before:
        click_if_visible(page, "button", "Add to prompt")
    deadline = time.time() + 15
    while chips.count() == before:
        if time.time() > deadline:
            raise drift(f"{path.name} never showed up as a prompt ingredient")
        page.wait_for_timeout(500)
    close_overlays(page)


def compose(page, plan: dict) -> tuple[int, str]:
    manual_composer(page)
    settings(page, plan, full=True)
    if plan["first_frame"]:
        fill_frame(page, "Start", Path(plan["first_frame"]))
    if plan["last_frame"]:
        fill_frame(page, "End", Path(plan["last_frame"]))
    for ref in plan["refs"]:
        add_ingredient(page, Path(ref), "Image")
    if plan["edit"]:
        add_ingredient(page, Path(plan["edit"]), "Video")
    cost, chip = settings(page, plan, full=False)
    tokens = chip.split()
    want = [plan["resolution"], f"x{plan['count']}"] + ([f"{plan['duration']}s"] if plan["duration"] else [])
    if not tokens or tokens[0] != "Video" or any(w not in tokens for w in want):
        raise drift(f"the composer reads {chip!r} after setup, expected {' '.join(want)}")
    return cost, chip


def extend_composer(page, source: dict, label: str) -> str:
    """The source clip's editor in extend mode; Flow shows no credit quote there."""
    scene = source.get("scene")
    if not scene:
        entry = media_entry(page, source["media_id"])
        scene = entry[2] if entry and len(entry) > 2 and isinstance(entry[2], str) else None
        if not scene:
            raise Failure(1, f"Flow no longer lists clip {source['media_id']} on this account")
    goto_flow(page, f"/project/{source['project']}/edit/{scene}")
    item = page.get_by_role("menuitem", name=label, exact=True)
    try:
        page.get_by_role("button", name="Add clip", exact=True).last.click(timeout=30000)
        item.wait_for(timeout=10000)
    except Exception as exc:
        raise drift(f"no Add clip > {label} item in the clip editor ({exc.__class__.__name__})")
    if item.is_disabled() or item.get_attribute("disabled") is not None:
        tip = page.evaluate("(id) => { const e = id && document.getElementById(id); "
                            "return e ? e.textContent.trim() : ''; }", item.get_attribute("aria-describedby"))
        raise Failure(2, f"Flow will not extend this clip ({tip or 'Extend is disabled'}); chain it from "
                         "its last frame instead: video-chain last-frame")
    item.click()
    chip = page.get_by_role("button", name="Exit extend mode", exact=True)
    try:
        chip.wait_for(timeout=15000)
    except Exception:
        raise drift("the extend composer never opened")
    return " ".join(chip.inner_text().split())


def video_caps() -> dict:
    return json.loads(MANIFEST.read_text())["video"]


def walls() -> dict:
    try:
        return json.loads((ROOT / "walls.json").read_text())
    except (OSError, ValueError):
        return {}


def update_json(name: str, change) -> None:
    with file_lock(ROOT / f".{name}.lock"):
        try:
            data = json.loads((ROOT / name).read_text())
        except (OSError, ValueError):
            data = {}
        change(data)
        tmp = ROOT / f"{name}.tmp"
        tmp.write_text(json.dumps(data))
        tmp.replace(ROOT / name)


def set_wall(account: str, until: float | None) -> None:
    if until is None and account not in walls():
        return
    update_json("walls.json", lambda data: data.pop(account, None) if until is None
                else data.update({account: int(until)}))


POOL_READ = ('. "$0/share/worker-model.sh" && . "$0/share/worker-pool.sh" && '
             'worker_pool_disabled_json "$(worker_pool_dir gemini)" && echo && { worker_model_pins gemini || true; }')
_pool: tuple | None = None


def pool() -> tuple[set[str] | None, set[str]]:
    """The gemini worker pool's exclusions (None: unreadable, so every account is out) and its pins."""
    global _pool
    if _pool is None:
        try:
            out = subprocess.run(["bash", "-c", POOL_READ, str(REPO)], capture_output=True, text=True,
                                 timeout=30, check=True).stdout
            excluded, end = json.JSONDecoder().raw_decode(out.lstrip())
            _pool = (set(excluded) if isinstance(excluded, list) else None, set(out.lstrip()[end:].split()))
        except (OSError, subprocess.SubprocessError, ValueError):
            _pool = (None, set())
    return _pool


def in_pool(account: str) -> bool:
    excluded, pins = pool()
    return account in pins or (excluded is not None and account not in excluded)


def refuse_out_of_pool(account: str) -> None:
    if not in_pool(account):
        raise Failure(4, f"{account} is out of the gemini worker pool, so no headless run may use it. Turn "
                         '"In pool" back on for it, or pin it in ~/.claude/worker-model.')


def bound_accounts() -> list[str]:
    profiles = ROOT / "profiles"
    names = sorted(p.name for p in profiles.iterdir() if p.is_dir()) if profiles.exists() else []
    return [n for n in names if valid_account(n) and has_login(n) and read_meta(n).get("email")]


def rotation(cost: int) -> list[str]:
    now, walled = time.time(), walls()

    def balance(name: str) -> int:
        credits = read_meta(name).get("credits")
        return cost if credits is None else credits

    # A balance read within WALL_SECONDS stands in for a wall that only this price would hit.
    def affordable(name: str) -> bool:
        return balance(name) >= cost or now - read_meta(name).get("credits_at", 0) > WALL_SECONDS

    ready = [n for n in bound_accounts() if walled.get(n, 0) <= now and in_pool(n) and affordable(n)]
    return sorted(ready, key=lambda n: -balance(n))


def save_or_defer(page, account: str, project: str, upscale: dict, model: str) -> bool:
    """False when Chrome died under the 1080p download: the clip is rendered and its upscale is free, so a fresh
    Chrome takes it over (upscale_later)."""
    variant = upscale["variant"]
    try:
        variant["bytes"] = save_upscaled(page, project, upscale["scene"], upscale["path"])
    except Failure as failure:
        if failure.extra.get("crashed"):
            report(account, failure)
            return False
        raise Failure(failure.code, f"{failure.reason}; recover: {upscale_hint(account, [upscale])}",
                      media_id=variant["media_id"]) from failure
    ledger({"account": account, "media_id": variant["media_id"], "dest": str(upscale["path"]), "state": "saved",
            "model": model, "scene": upscale["scene"], "bytes": variant["bytes"]})
    return True


def upscale_hint(account: str, upscales: list) -> str:
    return "; ".join(f"gemini-web fetch {account} {u['variant']['media_id']} --dest {u['path']} --resolution 1080p"
                     for u in upscales)


def upscale_later(account: str, project: str, upscales: list, model: str, relaunches: int = 2) -> None:
    for _ in range(relaunches):
        with browser(account) as context:
            page = context.pages[0] if context.pages else context.new_page()
            left: list = []
            for upscale in upscales:
                if left or not save_or_defer(page, account, project, upscale, model):
                    left.append(upscale)
            upscales = left
        if not upscales:
            return
    raise Failure(1, f"Chrome crashed on every 1080p upscaled download ({relaunches + 1} launches); the clip is "
                     f"rendered, recover: {upscale_hint(account, upscales)}",
                  media_id=upscales[0]["variant"]["media_id"])


def job_rows() -> list:
    rows = []
    with contextlib.suppress(OSError):
        for line in (ROOT / "jobs.jsonl").read_text().splitlines():
            with contextlib.suppress(ValueError):
                rows.append(json.loads(line))
    return rows


def ledger(entry: dict) -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    with open(ROOT / "jobs.jsonl", "a") as f:
        f.write(json.dumps({"ts": int(time.time()), **entry}) + "\n")


def save_video(context, url: str, dest: Path) -> int:
    response = context.request.get(url, timeout=120000)
    body = response.body()
    if response.status != 200 or body[4:8] != b"ftyp":
        raise Failure(1, f"clip download failed (HTTP {response.status}, {len(body)} bytes)")
    part = dest.with_name(f".{dest.name}.part")
    part.write_bytes(body)
    part.replace(dest)
    return len(body)


CATCH_DOWNLOAD = """() => {
  if (!window.__gwCatch) {
    const catcher = window.__gwCatch = {blobs: new Map(), caught: null};
    const create = URL.createObjectURL;
    URL.createObjectURL = function (object) {
      const url = create.call(URL, object);
      if (object instanceof Blob) catcher.blobs.set(url, object);
      return url;
    };
    const wanted = (a) => a && a.hasAttribute('download') && /^(blob|data):/.test(a.href);
    const click = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () {
      if (!wanted(this)) return click.call(this);
      catcher.caught = this.href;
    };
    document.addEventListener('click', (event) => {
      const a = event.target.closest && event.target.closest('a');
      if (wanted(a)) { event.preventDefault(); catcher.caught = a.href; }
    }, true);
  }
  window.__gwCatch.caught = null;
}"""
CAUGHT = "() => window.__gwCatch && window.__gwCatch.caught"
READ_CHUNK = """async ([url, start, size]) => {
  const blobs = window.__gwCatch.blobs;
  if (!blobs.has(url)) blobs.set(url, await (await fetch(url)).blob());
  const blob = blobs.get(url);
  const bytes = new Uint8Array(await blob.slice(start, start + size).arrayBuffer());
  let text = '';
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return [blob.size, btoa(text)];
}"""


def wait_download(page, downloads: list, timeout_s: float = 600.0) -> str | None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if downloads:
            return None
        caught = page.evaluate(CAUGHT)
        if caught:
            return caught
        page.wait_for_timeout(500)
    raise TimeoutError(f"no 1080p download within {timeout_s:.0f}s")


def read_caught(page, url: str, part: Path, chunk: int = 4 << 20) -> None:
    with part.open("wb") as out:
        start, size = 0, 1
        while start < size:
            size, text = page.evaluate(READ_CHUNK, [url, start, chunk])
            data = base64.b64decode(text)
            if not data:
                break
            out.write(data)
            start += len(data)


def save_upscaled(page, project: str, scene: str, dest: Path) -> int:
    """Flow's own 1080p upscaled download from the clip's editor (free on PRO, 2026-10-01). The hidden Chrome
    segfaults inside its own download manager (10 crashes on 2026-10-01, all in Download.save_as), so the file is
    caught from the page's download link and read out of the page; Chrome's download is the fallback only."""
    part = dest.with_name(f".{dest.name}.part")
    downloads: list = []

    def listener(download):
        downloads.append(download)

    try:
        goto_flow(page, f"/project/{project}/edit/{scene}")
        close_promos(page)
        page.evaluate(CATCH_DOWNLOAD)
        page.on("download", listener)
        page.get_by_role("button", name="Download media", exact=True).click(timeout=30000)
        page.get_by_role("menuitem", name="1080p Upscaled", exact=True).click(timeout=10000)
        caught = wait_download(page, downloads)
        if caught:
            read_caught(page, caught, part)
        elif downloads[0].url.startswith("http"):
            url = downloads[0].url
            with contextlib.suppress(Exception):
                downloads[0].cancel()
            return save_video(page.context, url, dest)
        else:
            print(f"gemini-web: the 1080p file went through Chrome's download ({downloads[0].url.split(':')[0]})",
                  file=sys.stderr, flush=True)
            downloads[0].save_as(str(part))
    except Failure:
        raise
    except Exception as exc:
        error = drift(f"the 1080p upscaled download ({exc.__class__.__name__}: "
                      f"{(str(exc).strip().splitlines() or [''])[0][:120]})")
        error.extra["crashed"] = exc.__class__.__name__ == "TargetClosedError"
        raise error from exc
    finally:
        with contextlib.suppress(Exception):
            page.remove_listener("download", listener)
    if part.read_bytes()[4:8] != b"ftyp":
        part.unlink()
        raise Failure(1, "the 1080p upscaled download is not an mp4")
    part.replace(dest)
    return dest.stat().st_size


def media_entry(page, media_id: str) -> list | None:
    """Flow's own read-only media lookup (as29s), issued from the page; reads carry no reCAPTCHA."""
    text = page.evaluate("""async (mediaId) => {
        const wiz = globalThis.WIZ_global_data || {};
        const freq = JSON.stringify([[["as29s", JSON.stringify([mediaId]), null, "generic"]]]);
        const url = "/_/AiSandboxAngularFrontend/data/batchexecute?rpcids=as29s" +
          `&source-path=${encodeURIComponent(location.pathname)}&bl=${encodeURIComponent(wiz.cfb2h || "")}` +
          `&f.sid=${encodeURIComponent(wiz.FdrFJe || "")}&hl=en&_reqid=${100000 + Math.floor(Math.random() * 900000)}&rt=c`;
        const resp = await fetch(url, {method: "POST", credentials: "include",
          headers: {"content-type": "application/x-www-form-urlencoded;charset=UTF-8", "x-same-domain": "1"},
          body: new URLSearchParams({"f.req": freq, at: wiz.SNlM0e || ""})});
        return await resp.text();
    }""", media_id)
    for _, payload in batch_payloads(text):
        if isinstance(payload, list) and payload[:1] == [media_id]:
            return payload
    return None


def media_url(page, media_id: str) -> str | None:
    entry = media_entry(page, media_id)
    return video_url(entry, media_id) if entry else None


def extend_source(path: str, ext: dict) -> dict:
    """The Flow clip gemini-video saved at `path`, read back from the job ledger."""
    target = str(Path(path).resolve())
    rows = job_rows()
    saved = [r for r in rows if isinstance(r, dict) and r.get("state") == "saved" and r.get("dest")
             and str(Path(r["dest"]).resolve()) == target]
    if not saved:
        raise Failure(2, f"{path} is not a clip gemini-video saved from Flow, and Flow extends only its own "
                         "Veo clips; chain it from its last frame instead: video-chain last-frame")
    source = {"path": target}
    for row in rows:
        if isinstance(row, dict) and row.get("media_id") == saved[-1].get("media_id"):
            source.update({k: row[k] for k in ("account", "media_id", "project", "scene", "model", "bytes")
                           if row.get(k)})
    if not source.get("project") or not source.get("account"):
        raise Failure(2, f"the job ledger has no Flow project for {path}")
    if source.get("model") == "extend":
        raise Failure(2, f"{path} is itself an extension, and Flow's editor cannot extend one again; chain it "
                         "from its last frame instead: video-chain last-frame")
    if source.get("model") and source["model"] not in ext["sources"]:
        raise Failure(2, f"{path} was made on {source['model']}, and Flow extends only Veo clips; chain it "
                         "from its last frame instead: video-chain last-frame")
    if source.get("bytes") and Path(path).stat().st_size != source["bytes"]:
        raise Failure(2, f"{path} changed since gemini-video saved it, and Extend continues Flow's original "
                         f"clip {source['media_id']}; pass the untouched clip")
    return source


def variant_path(dest: Path, index: int) -> Path:
    return dest if index == 0 else dest.with_name(f"{dest.stem}-{index + 1}{dest.suffix}")


def recover_hint(account: str, clips: list[str], dest: Path) -> str:
    return "; ".join(f"gemini-web fetch {account} {m} --dest {variant_path(dest, i)}"
                     for i, m in enumerate(clips))



def generate_on(account: str, plan: dict, args) -> dict:
    started = time.time()
    if not has_login(account):
        raise Failure(4, f"account {account} has no browser login; run: gemini-web login {account}")
    meta = read_meta(account)
    if not meta.get("email"):
        raise Failure(4, f"account {account} is not bound to a Google account; run: gemini-web status {account}")
    dest = Path(args.dest)
    with file_lock(ROOT / "locks" / f"{account}.lock", wait_s=900):
        return render_on(account, plan, args, meta, dest, started)


def render_on(account: str, plan: dict, args, meta: dict, dest: Path, started: float) -> dict:
    cost, count = plan["cost"], plan["count"]
    with browser(account) as context:
        sent = None
        clips: list[str] = []
        try:
            page = context.pages[0] if context.pages else context.new_page()
            watcher = Watcher(page)
            project = open_project(page, account)
            state = page_state(page)
            if state["email"] != meta["email"]:
                raise Failure(1, f"profile {account} is signed in as {state['email']}, bound to {meta['email']}")
            credits = read_credits(page)
            note_credits(account, credits)
            read_allowance(context, account)
            if credits is not None and credits < cost:
                raise Failure(3, f"{account} has {credits} Flow credits; {plan['what']} costs {cost}",
                              credits=credits)
            if plan["extend"]:
                project, quote = plan["extend"]["project"], None
                chip = extend_composer(page, plan["extend"], plan["label"])
            else:
                quote, chip = compose(page, plan)
                if quote != cost:
                    raise Failure(1, f"Flow quotes {quote} credits for {plan['what']} ({chip}), the manifest "
                                     f"says {cost}; nothing spent", quote=quote, chip=chip)
            page.locator("[contenteditable=true]").last.click()
            page.keyboard.insert_text(args.prompt)
            page.wait_for_timeout(400)
            button = page.get_by_role("button", name="Start generation", exact=True).last
            if not button.is_enabled():
                raise drift("Start generation stays disabled after setup")
            if args.dry_run:
                click_if_visible(page, "button", "Clear prompt")
                return {"ok": True, "dry_run": True, "account": account, "project": project,
                        "quote": quote, "chip": chip, "credits": credits, "build": state["build"],
                        "seconds": {"total": round(time.time() - started, 1)}}
            known = set(watcher.media)
            button.click()
            sent = time.time()
            deadline = sent + args.timeout
            while len(clips) < count:
                if watcher.blocked():
                    raise watcher.blocked()
                clips = watcher.new_clips(known) if count > 1 else \
                    [c for c in [watcher.new_clip(known, args.prompt)] if c]
                if len(clips) < count and time.time() > sent + 120:
                    seen = f"only {len(clips)} of {count} clips" if clips else "no new clip"
                    raise Failure(1, f"sent, but {seen} showed up in the project within 120s; it may still "
                                     "land there")
                if len(clips) < count:
                    page.wait_for_timeout(500)
            clips = clips[:count]
            for index, media_id in enumerate(clips):
                ledger({"account": account, "media_id": media_id, "project": project,
                        "dest": str(variant_path(dest, index)), "state": "queued", "model": plan["model"]})
            while time.time() < deadline:
                records = [watcher.media.get(m, {}) for m in clips]
                if watcher.blocked():
                    raise watcher.blocked()
                flagged = [r["error"] for r in records if r.get("error") in BLOCK_ERRORS]
                if flagged:
                    watcher.errors.add(flagged[0])
                    raise watcher.blocked()
                if all(r.get("error") or r.get("url") or r.get("status") == DONE for r in records):
                    break
                page.wait_for_timeout(1000)
            else:
                raise Failure(1, f"not ready after {args.timeout}s; recover later: "
                                 f"{recover_hint(account, clips, dest)}", media_id=clips[0])
            rendered = time.time()
            saved, refused, later = [], [], []
            for media_id in clips:
                record = watcher.media[media_id]
                if record.get("error"):
                    refused.append({"media_id": media_id, "error": record["error"]})
                    continue
                path = variant_path(dest, len(saved))
                saved.append({"dest": str(path), "media_id": media_id, "bytes": None,
                              "duration": record.get("duration"), "model": record.get("model")})
                if plan["upscale"]:
                    if not record.get("scene"):
                        raise drift(f"clip {media_id} came without a scene id for the 1080p download")
                    upscale = {"variant": saved[-1], "scene": record["scene"], "path": path}
                    if later or not save_or_defer(page, account, project, upscale, plan["model"]):
                        later.append(upscale)
                    continue
                url = record.get("url") or media_url(page, media_id)
                if not url:
                    raise Failure(1, f"clip {media_id} finished but Flow gave no video URL", media_id=media_id)
                saved[-1]["bytes"] = save_video(context, url, path)
                ledger({"account": account, "media_id": media_id, "dest": str(path), "state": "saved",
                        "model": plan["model"], "scene": record.get("scene"), "bytes": saved[-1]["bytes"]})
            if not saved:
                raise Failure(1, f"Flow refused the clip: {refused[0]['error']}", media_id=refused[0]["media_id"])
            finished = time.time()
            charged = credits - watcher.reply_credits \
                if credits is not None and watcher.reply_credits is not None else None
            after = watcher.credits if watcher.credits is not None else \
                (credits - cost if credits is not None else None)
            note_credits(account, after)
            first = saved[0]
            result = {"ok": True, "account": account, "email": meta["email"], "dest": first["dest"],
                    "model": first["model"] or (watcher.submitted or [None])[-1],
                    "model_name": plan["model"], "mode": plan["mode"], "chip": chip,
                    "upscaled": plan["upscale"], "duration": first["duration"],
                    "media_id": first["media_id"], "project": project, "variants": saved,
                    "refused": refused, "cost": cost, "charged": charged, "credits": after,
                    "bytes": first["bytes"], "build": state["build"],
                    "seconds": {"harness": round((sent - started) + (finished - rendered), 1),
                                "render": round(rendered - sent, 1),
                                "total": round(finished - started, 1)}}
        except Failure:
            raise
        except Exception as exc:
            if sent is None:
                where = "before anything was spent"
            elif clips:
                where = f"after sending; recover: {recover_hint(account, clips, dest)}"
            else:
                where = "after sending; the clip may still land in the Flow project"
            detail = (str(exc).strip().splitlines() or [""])[0][:200]
            raise Failure(1, f"Flow UI drift {where}: {exc.__class__.__name__}: {detail}",
                          media_id=clips[0] if clips else None)
    if later:
        upscale_later(account, project, later, plan["model"])
    result["bytes"] = result["variants"][0]["bytes"]
    return result


def extend_plan(args, caps: dict) -> dict:
    ext = caps["extend"]
    if args.first_frame or args.last_frame or args.ref or args.edit:
        raise Failure(2, "--extend continues a Flow clip from its own ending; it takes no frames, --ref or --edit")
    if args.count != 1:
        raise Failure(2, "--extend makes one continuation per send; drop --count")
    if not Path(args.extend).is_file():
        raise Failure(2, f"--extend {args.extend} is not a file")
    if args.resolution not in ext["resolutions"]:
        raise Failure(2, f"{ext['label']} renders {', '.join(ext['resolutions'])}, not {args.resolution}: Flow "
                         "has no upscaled download of an extension; video-chain join scales it to the chain")
    return {"model": "extend", "label": ext["label"], "cost": ext["cost"],
            "what": f"an {ext['label']} of {Path(args.extend).name}", "mode": "Extend", "aspect": None,
            "resolution": args.resolution, "upscale": None,
            "duration": ext["seconds"], "first_frame": None, "last_frame": None, "refs": [], "edit": None,
            "count": 1, "extend": extend_source(args.extend, ext)}


def make_plan(args) -> dict:
    caps = video_caps()
    if args.count not in caps["counts"]:
        raise Failure(2, f"Flow makes {', '.join(map(str, caps['counts']))} clips per send, not {args.count}")
    if args.extend:
        return extend_plan(args, caps)
    model = caps["models"].get(args.model)
    if model is None:
        raise Failure(2, f"unknown model {args.model!r}; known: {', '.join(caps['models'])}")
    label = model["label"]
    if args.aspect not in caps["aspects"]:
        raise Failure(2, f"aspect {args.aspect} not in {caps['aspects']}")
    for flag, path in [("--first-frame", args.first_frame), ("--last-frame", args.last_frame),
                       ("--edit", args.edit), *[("--ref", ref) for ref in args.ref]]:
        if path and not Path(path).is_file():
            raise Failure(2, f"{flag} {path} is not a file")
    if (args.first_frame or args.last_frame) and (args.ref or args.edit):
        raise Failure(2, "frames and ingredients are separate Flow modes: pass --first/--last-frame "
                         "or --ref/--edit, not both")
    if len(args.ref) > model["refs_max"]:
        raise Failure(2, f"{label} takes at most {model['refs_max']} --ref images")
    resolution = caps.get("upscale", {}).get(args.resolution, args.resolution)
    costs = model["costs"].get(resolution)
    if costs is None:
        raise Failure(2, f"{label} renders {', '.join(model['costs'])}, not {args.resolution}")
    if args.edit:
        cost = model.get("edit_costs", {}).get(resolution)
        if cost is None:
            raise Failure(2, f"{label} cannot edit a video at {resolution}")
        duration, what = None, f"a {label} {resolution} edit"
    else:
        cost = costs.get(str(args.duration))
        if cost is None:
            raise Failure(2, f"{label} takes {', '.join(costs)}s at {resolution}, not {args.duration}s")
        duration, what = args.duration, f"{label} {resolution} {args.duration}s"
    if args.count > 1:
        what += f" x{args.count}"
    return {"model": args.model, "label": label, "cost": cost * args.count, "what": what,
            "mode": "Ingredients" if args.ref or args.edit else "Frames", "aspect": args.aspect,
            "resolution": resolution, "upscale": args.resolution if resolution != args.resolution else None,
            "duration": duration, "first_frame": args.first_frame, "last_frame": args.last_frame,
            "refs": args.ref, "edit": args.edit, "count": args.count, "extend": None}


def cmd_generate(args) -> None:
    plan = make_plan(args)
    source = plan["extend"]
    if source and args.account and args.account != source["account"]:
        raise Failure(2, f"{args.extend} lives on Flow account {source['account']}, not {args.account}")
    pinned = args.account or (source or {}).get("account")
    if source and walls().get(pinned, 0) > time.time():
        raise Failure(3, f"{pinned}, the only account holding {Path(args.extend).name}, is walled; chain "
                         "from its last frame instead: video-chain last-frame")
    if pinned:
        refuse_out_of_pool(pinned)
    candidates = [pinned] if pinned else free_first(rotation(plan["cost"]))
    if not candidates:
        bound = bound_accounts()
        if not bound:
            raise Failure(4, "no Flow account is signed in; run: gemini-web login <account>")
        if not any(in_pool(name) for name in bound):
            raise Failure(4, 'every signed-in Flow account is out of the gemini worker pool; turn "In pool" '
                             "back on for one, or pin it in ~/.claude/worker-model")
        raise Failure(3, f"every signed-in Flow account is walled (walls.json) or holds under {plan['cost']} "
                         "credits by its last balance read")
    skipped: list[tuple[str, Failure]] = []
    for account in candidates:
        try:
            result = generate_on(account, plan, args)
        except Failure as failure:
            report(account, failure)
            # A short balance is skipped by its cached credits; a wall would also refuse cheaper jobs.
            if failure.code == 3 and not args.account and "credits" not in failure.extra:
                set_wall(account, time.time() + failure.extra.get("wall_s", WALL_SECONDS))
            if failure.code not in (3, 4) or pinned:
                raise Failure(failure.code, failure.reason, account=account, **failure.extra)
            skipped.append((account, failure))
            continue
        set_wall(account, None)
        emit(result)
        return
    raise Failure(3 if any(failure.code == 3 for _, failure in skipped) else 4,
                  "no signed-in Flow account could take the job ("
                  + "; ".join(f"{account}: {failure.reason}" for account, failure in skipped) + ")")


def cmd_status(args) -> None:
    started = time.time()
    with browser(args.account, args.visible) as context:
        page = context.pages[0] if context.pages else context.new_page()
        state = goto_flow(page, "/")
        meta = read_meta(args.account)
        if not meta.get("email"):
            meta = write_meta(args.account, email=state["email"])
        page.get_by_role("button", name="New project", exact=True).wait_for(timeout=30000)
        dismiss_dialogs(page, args.account)
        credits = read_credits(page)
        note_credits(args.account, credits)
        read_allowance(context, args.account)
        bound = state["email"] == meta.get("email")
        emit({"ok": bound, "account": args.account, "email": state["email"],
              "bound_to": meta.get("email"), "credits": credits, "build": state["build"],
              "seconds": round(time.time() - started, 1)})
        sys.exit(0 if bound else 1)


def job_project(account: str, media_id: str) -> str | None:
    rows = job_rows()
    known = [r["project"] for r in rows if isinstance(r, dict) and r.get("media_id") == media_id and r.get("project")]
    return known[-1] if known else read_meta(account).get("project")


def cmd_fetch(args) -> None:
    with browser(args.account) as context:
        page = context.pages[0] if context.pages else context.new_page()
        goto_flow(page, "/")
        entry = media_entry(page, args.media_id)
        url = video_url(entry, args.media_id) if entry else None
        if not url:
            raise Failure(1, f"no finished video {args.media_id} on {args.account}")
        if args.resolution == "1080p":
            project = job_project(args.account, args.media_id)
            if not (project and len(entry) > 2 and entry[2]):
                raise Failure(1, f"no project or scene known for the 1080p download of {args.media_id}; "
                              "fetch it without --resolution")
            size = save_upscaled(page, project, entry[2], Path(args.dest))
        else:
            size = save_video(context, url, Path(args.dest))
        ledger({"account": args.account, "media_id": args.media_id, "dest": str(Path(args.dest)),
                "state": "saved", "scene": entry[2] if len(entry) > 2 else None, "bytes": size})
        emit({"ok": True, "account": args.account, "dest": args.dest, "media_id": args.media_id,
              "bytes": size})


def cmd_login(args) -> None:
    profile = profile_dir(args.account)
    if profile_in_use(profile):
        raise Failure(1, f"profile {args.account} is already open")
    profile.mkdir(parents=True, exist_ok=True)
    os.chmod(profile.parent, 0o700)
    subprocess.Popen(
        [chrome_binary(SOURCE_APP), f"--user-data-dir={profile}", *COMMON_FLAGS, "--new-window",
         LOGIN_URL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    emit({"ok": True, "account": args.account, "profile": str(profile),
          "next": f"sign in in the window that opened, quit it (Cmd+Q), then: gemini-web status {args.account}"})


def cmd_accounts(args) -> None:
    profiles = ROOT / "profiles"
    rows = []
    for p in sorted(profiles.iterdir()) if profiles.exists() else []:
        if p.is_dir() and valid_account(p.name):
            meta = read_meta(p.name)
            rows.append({"account": p.name, "login": has_login(p.name), "email": meta.get("email"),
                         "credits": meta.get("credits"), "walled_until": walls().get(p.name)})
    emit({"ok": True, "accounts": rows})


def main() -> None:
    parser = argparse.ArgumentParser(prog="gemini-web")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("login", help="open a visible Chrome to sign an account in once")
    p.add_argument("account")
    p.set_defaults(func=cmd_login)
    p = sub.add_parser("status", help="free check: signed in, bound email, credits")
    p.add_argument("account")
    p.add_argument("--visible", action="store_true")
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("accounts", help="profiles with their cached email, credits and walls")
    p.set_defaults(func=cmd_accounts)
    p = sub.add_parser("generate")
    p.add_argument("--account")
    p.add_argument("--prompt", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--first-frame")
    p.add_argument("--last-frame")
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--edit")
    p.add_argument("--extend", help="continue a Veo clip gemini-video saved from Flow")
    p.add_argument("--count", type=int, default=1)
    p.add_argument("--duration", type=int, default=8)
    p.add_argument("--aspect", default="16:9")
    p.add_argument("--resolution", default="720p")
    p.add_argument("--model", default="fast")
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--dry-run", action="store_true",
                   help="set the composer up and read Flow's credit quote, send nothing")
    p.set_defaults(func=cmd_generate)
    p = sub.add_parser("fetch", help="download an already generated clip by media id")
    p.add_argument("account")
    p.add_argument("media_id")
    p.add_argument("--dest", required=True)
    p.add_argument("--resolution", choices=("720p", "1080p"), default="720p",
                   help="1080p downloads Flow's own upscale from the clip's editor")
    p.set_defaults(func=cmd_fetch)
    args = parser.parse_args()
    try:
        args.func(args)
    except Failure as failure:
        if failure.code != 2:
            report(getattr(args, "account", None) or failure.extra.get("account") or "-", failure)
        fail(failure.code, failure.reason, **failure.extra)
    except Exception as exc:
        report(getattr(args, "account", None) or "-", exc)
        fail(1, f"{exc.__class__.__name__}: {(str(exc).strip().splitlines() or [''])[0][:200]}")


if __name__ == "__main__":
    main()
