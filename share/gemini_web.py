# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""Google Flow (flow.google.com) video on a subscription account, through a hidden Chrome clone.

One Chrome profile per geminib account under GEMINI_WEB_DIR. The owner signs each one in once
(`login`); everything else runs the clone off-screen with no Dock icon. A generation goes through
Flow's manual composer the way a person would: the page mints its own reCAPTCHA for every call, and
the composer's own credit quote is checked against the manifest before anything is spent.
Every command prints one JSON line; exit 0 ok, 2 usage, 3 out of credits, 4 login needed, 5 account busy (its
lock not free within --lock-wait), 1 other.
"""
from __future__ import annotations

import argparse
import base64
import calendar
import contextlib
import datetime
import faulthandler
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path

import account_roster

faulthandler.register(signal.SIGTERM, all_threads=True, chain=True)

ROOT = Path(os.environ.get("GEMINI_WEB_DIR", "~/.gemini-web")).expanduser()
SOURCE_APP = Path(os.environ.get("GEMINI_WEB_CHROME", "/Applications/Google Chrome.app"))
# Engines that keep their store elsewhere (chatgpt_web) rebind ROOT but share this one clone.
CLONE_ROOT = ROOT
CLONE_APP = CLONE_ROOT / "Gemini Web Automation.app"
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
LISTING_RPC = "Zzl0ze"
ORIGINAL_SIZE = re.compile(r"^\d+p Original size$")
DONE = 3
CARDS_SCAN_S = 3
GENERATION_FAILED = "flow_generation_failed (not charged)"
# Flow's "Failed / Sorry, this image (video) failed to generate / You have not been charged" card and its
# Retry button. Cards on the page before the send belong to earlier jobs: "mark" remembers them, "count" and
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


class Failure(Exception):
    def __init__(self, code: int, reason: str, **extra):
        super().__init__(reason)
        self.code, self.reason, self.extra = code, reason, extra


STARTED = time.monotonic()
PHASES: dict[str, float] = {}
LOADS: dict[str, float] = {}
TIMED = False
LOCK_WAIT_S = 900.0
lock_waited = 0.0
SETTLE_MS = 100


def phase(name: str) -> None:
    PHASES[name] = round(time.monotonic() - STARTED, 2)
    LOADS[name] = round(os.getloadavg()[0], 1)


def timing(failed: bool = False) -> dict:
    """What a generate-like command's result, failure and ledger rows carry: its job, the seconds since the
    engine started at each phase reached with the 1-minute load average then, the time spent waiting for
    account locks, and on failure whether the prompt went out."""
    if not TIMED:
        return {}
    out = {"job": os.environ.get("IMAGE_JOB_ID") or None, "phases": dict(PHASES), "load": dict(LOADS),
           "lock_wait_s": round(lock_waited, 2)}
    if failed:
        out["sent"] = "sent" in PHASES
    return out


def lock_wait_arg(parser) -> None:
    parser.add_argument("--lock-wait", type=float, default=LOCK_WAIT_S, metavar="SECONDS",
                        help="how long to wait for a busy account before exit 5")


def settle(page, ms: int, done=None) -> None:
    """Up to ms, back as soon as done() holds; without done it sleeps the whole ms."""
    if done is None:
        page.wait_for_timeout(ms)
        return
    for _ in range(max(1, ms // SETTLE_MS)):
        with contextlib.suppress(Exception):
            if done():
                return
        page.wait_for_timeout(SETTLE_MS)


FAILURES_KEEP_S = 14 * 86400
LOGIN_POLL_S = 1.5
TEARDOWN_S = 45
ROUTES = (("flow.google.com", "flow"), ("labs.google", "flow"), ("gemini.google.com", "gemini-app"),
          ("flowmusic.app", "flow-music"), ("chatgpt.com", "chatgpt-web"), ("openai.com", "chatgpt-web"))
ROUTE = "flow"
TOOL = "gemini-web"
_reported: set[tuple[str, str]] = set()
DIALOGS = "[role=dialog],[role=alertdialog],mat-dialog-container"
TOASTS = "[role=alert],[role=status],mat-snack-bar-container,simple-snack-bar"
PAGE_DUMP = """() => {
  const seen = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const texts = sel => [...document.querySelectorAll(sel)].filter(seen).map(e => e.innerText.trim()).filter(Boolean);
  return {title: document.title,
          dialogs: texts('""" + DIALOGS + """'),
          toasts: texts('""" + TOASTS + """'),
          buttons: [...document.querySelectorAll('button,[role=button],[role=menuitem]')].filter(seen)
            .map(b => (b.getAttribute('aria-label') || b.innerText || '').trim().slice(0, 60)).filter(Boolean).slice(0, 80),
          body: (document.body ? document.body.innerText : '').slice(0, 4000)};
}"""


# A toast that came and went during a run that still succeeded leaves no failure note, so every page
# keeps the texts it showed; sessionStorage outlives the run's own navigations.
TOAST_LOG = """(() => {
  const sel = '""" + TOASTS + """';
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


def mask_email(email: str | None) -> str | None:
    if not email or "@" not in email:
        return email
    local, domain = email.split("@", 1)
    return f"{local[:2]}…@{domain}"


def emit(payload: dict) -> None:
    print(json.dumps({**payload, **timing(payload.get("ok") is False)}), flush=True)


def fail(code: int, reason: str, **extra) -> None:
    emit({"ok": False, "code": code, "reason": reason, **extra})
    sys.exit(code)


def valid_account(account: str) -> bool:
    return bool(re.fullmatch(r"[a-z0-9][a-z0-9-]*", account or ""))


def account_arg(value: str) -> str:
    if not valid_account(value):
        raise argparse.ArgumentTypeError(f"needs a profile name matching ^[a-z0-9][a-z0-9-]*$, got {value!r}")
    return value


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
    if str(path) in _held:
        yield
        return
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


_held: dict[str, object] = {}


def lock_path(account: str) -> Path:
    return ROOT / "locks" / f"{account}.lock"


def try_lock(account: str) -> bool:
    path = lock_path(account)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = open(path, "a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return False
    _held[str(path)] = handle
    return True


def release(account: str) -> None:
    handle = _held.pop(str(lock_path(account)), None)
    if handle:
        handle.close()


def claim(accounts: list[str], wait_s: float) -> str:
    """The first account in order whose lock is free, now held by this run; with all of them busy, whichever
    frees first within wait_s, else exit 5. A busy probe and then a blocking lock let two runs pick the same
    idle account."""
    global lock_waited
    started = time.monotonic()
    try:
        account = next((name for name in accounts if try_lock(name)), None)
        while account is None and time.monotonic() - started < wait_s:
            time.sleep(min(0.5, max(0.0, wait_s - (time.monotonic() - started))))
            account = next((name for name in accounts if try_lock(name)), None)
    finally:
        lock_waited += time.monotonic() - started
    if account is None:
        raise Failure(5, f"account busy: timed out waiting for {accounts[0]}.lock after {wait_s:.0f}s")
    phase("lock")
    return account


def claimed(accounts: list[str], wait_s: float):
    """(account, None) with its lock held until the caller moves on, in claim order; (account, Failure 5) for
    each one still busy after the wait, which a failover passes like a wall. Close it (contextlib.closing)."""
    left = list(accounts)
    while left:
        try:
            account = claim(left, wait_s)
        except Failure:
            for account in left:
                yield account, Failure(5, f"account busy: timed out waiting for {account}.lock after {wait_s:.0f}s")
            return
        left.remove(account)
        try:
            yield account, None
        finally:
            release(account)


def busy(account: str) -> bool:
    with contextlib.suppress(OSError), open(lock_path(account), "a") as handle:
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


def note_started(account: str) -> None:
    write_meta(account, generation_started_at=int(time.time()))


def least_recent(accounts: list[str]) -> list[str]:
    """The owner's rule (2026-10-01): the account that least recently started a new generation goes first."""
    return sorted(accounts, key=lambda name: read_meta(name).get("generation_started_at", 0))


@contextlib.contextmanager
def chrome_clone():
    if not SOURCE_APP.exists():
        raise Failure(1, f"Google Chrome not found at {SOURCE_APP}")
    want = app_version(SOURCE_APP)
    CLONE_ROOT.mkdir(parents=True, exist_ok=True)
    with open(CLONE_ROOT / ".clone-use.lock", "w") as use:
        with file_lock(CLONE_ROOT / ".clone.lock"):
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


def chrome_pid(profile: Path) -> int | None:
    lock = profile / "SingletonLock"
    if not lock.is_symlink():
        return None
    try:
        pid = int(os.readlink(lock).rsplit("-", 1)[-1])
    except (OSError, ValueError):
        return None
    try:
        os.kill(pid, 0)
    except PermissionError:
        return pid
    except OSError:
        return None
    return pid


def profile_in_use(profile: Path) -> bool:
    return chrome_pid(profile) is not None


def has_login(account: str) -> bool:
    return (profile_dir(account) / "Default" / "Cookies").exists()


@contextlib.contextmanager
def browser(account: str, visible: bool = False):
    refuse_off_roster(account)
    from playwright.sync_api import sync_playwright

    profile = profile_dir(account)
    if not has_login(account):
        raise Failure(4, f"account {account} has no browser login; run: {TOOL} login {account}")
    if profile_in_use(profile):
        raise Failure(1, f"profile {account} is open in another Chrome (the login window?); close it")
    flags = [*COMMON_FLAGS, "--window-size=1440,1000", "--disable-renderer-backgrounding",
             "--disable-backgrounding-occluded-windows", "--disable-background-timer-throttling"]
    if not visible:
        # Off-screen, not headless: headless Chrome is served a different, bot-checked page.
        flags.append("--window-position=-30000,-30000")
    reset_exit_type(account, profile)
    threading.Thread(target=sweep_code_sign_clones, daemon=True).start()
    with chrome_clone() as clone, sync_playwright() as pw:
        context = pw.chromium.launch_persistent_context(
            str(profile), executable_path=quiet_chrome(chrome_binary(clone), account), headless=False, args=flags,
            ignore_default_args=["--enable-automation"],
            viewport=None, accept_downloads=True, locale="en-US")
        with contextlib.suppress(Exception):
            context.add_init_script(TOAST_LOG)
        pid = chrome_pid(profile)
        driver = parent_pid(pid)
        if parent_pid(driver) != os.getpid():
            driver = None
        if not visible:
            for page in context.pages:
                park_window(account, context, page)
            context.on("page", lambda page: park_window(account, context, page))
        phase("browser")
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
            closing = time.monotonic()
            with bounded(account, "closing the browser", pid, driver, TEARDOWN_S):
                with contextlib.suppress(Exception):
                    note_toasts(context, account)
                with contextlib.suppress(Exception), reap_after_flush(profile, pid):
                    context.close()
            if TIMED:
                with contextlib.suppress(OSError):
                    ledger({"kind": "teardown", "account": account, "route": ROUTE,
                            "close_s": round(time.monotonic() - closing, 2)})


# Chrome hands its stdout/stderr to the GoogleUpdater --wake-all it spawns mid-run (the user-level one in
# ~/Library/Application Support/Google/GoogleUpdater, which stripping the clone's own does not reach), and
# Playwright's close waits for EOF on those pipes: two runs at once both hung 10 min (2026-10-02).
def quiet_chrome(binary: str, account: str) -> str:
    logs = ROOT / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    script = logs / f"{account}-chrome.sh"
    body = (f'#!/bin/sh\nexec {shlex.quote(binary)} "$@" '
            f'>{shlex.quote(str(logs / f"{account}-chrome.log"))} 2>&1 </dev/null\n')
    if not script.is_file() or script.read_text() != body:
        part = script.with_name(f".{script.name}.{os.getpid()}")
        part.write_text(body)
        part.chmod(0o755)
        part.replace(script)
    return str(script)


def parent_pid(pid: int | None) -> int | None:
    if not pid:
        return None
    with contextlib.suppress(OSError, subprocess.SubprocessError, ValueError):
        return int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True,
                                  timeout=5).stdout)
    return None


# Chrome writes the profile (cookies, prefs, site storage) within its shutdown's first second, then mostly
# sits until its own teardown watchdog terminates it ~10 s later; what that hang still writes is HSTS,
# network hints, GPU caches and metrics (12 traced closes, 2026-10-03; median close was 11 s). So once
# Cookies and Preferences are rewritten Chrome gets FLUSH_GRACE_S more, then its process group is killed.
FLUSH_GRACE_S = 1.0


@contextlib.contextmanager
def reap_after_flush(profile: Path, chrome: int | None):
    done = threading.Event()
    begun = time.time()
    flushed = [profile / "Default" / "Cookies", profile / "Default" / "Preferences"]

    def watch():
        while not done.wait(0.1):
            with contextlib.suppress(OSError):
                if all(path.stat().st_mtime >= begun for path in flushed):
                    break
        if not done.wait(FLUSH_GRACE_S):
            with contextlib.suppress(OSError):
                os.killpg(chrome, signal.SIGKILL)

    if chrome:
        threading.Thread(target=watch, daemon=True).start()
    try:
        yield
    finally:
        done.set()


# A killed Chrome (by reap_after_flush, bounded or its own watchdog) never runs the helper that deletes its
# per-launch code-sign clone of the app; 326 had piled up by 2026-10-03. A running browser maps its clone's
# executable (lsof), and one younger than CLONE_SWEEP_MIN_AGE_S may belong to a launch not yet mapped.
CLONE_SWEEP_MIN_AGE_S = 600


def sweep_code_sign_clones() -> None:
    """At most once per CLONE_SWEEP_MIN_AGE_S machine-wide (a stamp beside the clone both engines share):
    every launch used to run ps and an lsof over every running Chrome."""
    stamp = CLONE_ROOT / ".clone-sweep.stamp"
    with contextlib.suppress(OSError):
        if time.time() - stamp.stat().st_mtime < CLONE_SWEEP_MIN_AGE_S:
            return
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        CLONE_ROOT.mkdir(parents=True, exist_ok=True)
        stamp.touch()
        temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True,
                              timeout=10).stdout.strip()
        if not temp:
            return
        cutoff = time.time() - CLONE_SWEEP_MIN_AGE_S
        old = [path for path in (Path(temp).parent / "X" / f"{CLONE_ID}.code_sign_clone").glob("code_sign_clone.*")
               if path.stat().st_mtime < cutoff]
        if not old:
            return
        listing = subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True, timeout=10).stdout
        browsers = [line.split(None, 1)[0] for line in listing.splitlines()
                    if str(CLONE_APP) in line and "--type=" not in line]
        mapped = ""
        if browsers:
            mapped = subprocess.run(["lsof", "-a", "-p", ",".join(browsers), "-d", "txt", "-Fn"],
                                    capture_output=True, text=True, timeout=60).stdout
            if "code_sign_clone." not in mapped:
                return
        stale = [str(path) for path in old if f"/{path.name}/" not in mapped]
        if stale:
            subprocess.Popen(["rm", "-rf", "--", *stale], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)


@contextlib.contextmanager
def bounded(account: str, what: str, chrome: int | None, driver: int | None, seconds: float):
    """Past `seconds` the stacks go to stderr and Chrome's process group and the Playwright driver are
    killed, so the blocked Playwright call raises instead of waiting forever."""
    def expire():
        warn(account, f"{what} still running after {seconds:.0f}s; killing Chrome and the Playwright driver")
        faulthandler.dump_traceback(all_threads=True)
        for kill, target in ((os.killpg, chrome), (os.kill, driver)):
            if target:
                with contextlib.suppress(OSError):
                    kill(target, signal.SIGKILL)

    timer = threading.Timer(seconds, expire)
    timer.daemon = True
    timer.start()
    try:
        yield
    finally:
        timer.cancel()


# The clone is LSBackgroundOnly, which macOS never hides (System Events reads `visible` false while its
# window is on screen), so off-screen is the only hiding left. Playwright opens its window at the screen's
# top left whatever --window-position says, so park_window moves each page's window off over CDP (Chrome
# still keeps 40 px on screen); a Crashed exit_type would add a "Restore pages?" bubble that stays on
# screen beside the parked window. Before this, whole runs sat in plain sight (2026-10-03).
def reset_exit_type(account: str, profile: Path) -> None:
    path = profile / "Default" / "Preferences"
    try:
        prefs = json.loads(path.read_text())
    except FileNotFoundError:
        return
    except (OSError, ValueError) as error:
        warn(account, f"could not mark the profile's last exit clean: {error}")
        return
    if not isinstance(prefs, dict) or not isinstance(prefs.get("profile"), dict) \
            or prefs["profile"].get("exit_type") in (None, "Normal"):
        return
    prefs["profile"]["exit_type"] = "Normal"
    part = path.with_name(f".{path.name}.{os.getpid()}")
    try:
        part.write_text(json.dumps(prefs))
        part.replace(path)
    except OSError as error:
        warn(account, f"could not mark the profile's last exit clean: {error}")


def park_window(account: str, context, page) -> None:
    try:
        cdp = context.new_cdp_session(page)
        window = cdp.send("Browser.getWindowForTarget")["windowId"]
        cdp.send("Browser.setWindowBounds", {"windowId": window, "bounds": {"left": -30000, "top": -30000}})
        cdp.detach()
    except Exception as error:
        warn(account, f"could not move the automation Chrome off screen: {' '.join(str(error).split())[:200]}")


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
            raise Failure(4, "Google signed this profile out; run: geminib web <account>")
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
                       wall_s=BLOCK_WALL_SECONDS, flagged=True)

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


def click_if_visible(page, role: str, name: str, exact: bool = True, done=None) -> bool:
    target = page.get_by_role(role, name=name, exact=exact)
    for index in range(target.count()):
        item = target.nth(index)
        with contextlib.suppress(Exception):
            if item.is_visible():
                item.click(timeout=3000)
                settle(page, 600, done)
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
    for name in ("Get started", re.compile(r"^Got it\b"), "Dismiss", "No thanks"):
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


REFILL_JUMP = 200


def month_after(epoch: float) -> int:
    day = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    year, month = (day.year + 1, 1) if day.month == 12 else (day.year, day.month + 1)
    last = calendar.monthrange(year, month)[1]
    return int(day.replace(year=year, month=month, day=min(day.day, last)).timestamp())


def note_credits(account: str, credits: int | None) -> None:
    if credits is None:
        return
    meta, now = read_meta(account), int(time.time())
    fields = {"credits": credits, "credits_at": now,
              "credits_total": meta.get("credits_total") or max(video_caps()["credits"]["monthly"], credits)}
    previous = meta.get("credits")
    if isinstance(previous, int) and credits - previous >= REFILL_JUMP:
        fields.update(credits_refilled_at=now, credits_renews_at=month_after(now), credits_total=credits)
    write_meta(account, **fields)


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
        shown = backdrop.count()
        if not shown:
            return
        backdrop.last.click(position={"x": 5, "y": 5})
        settle(page, 500, lambda shown=shown: backdrop.count() < shown)


def close_settings(page, trigger, family) -> None:
    """An open model menu's backdrop takes the trigger's click, so the menu closes first."""
    close_overlays(page)
    if family.count() and family.last.is_visible():
        trigger.click(timeout=5000)
        settle(page, 500, lambda: not family.last.is_visible())
    close_overlays(page)


def manual_composer(page) -> None:
    """Agent toggle off, nothing left in the prompt box from an earlier run."""
    agent = page.get_by_role("button", name="Agent", exact=True)
    box = page.locator("[contenteditable=true]").last
    if not (agent.count() and agent.last.is_visible()):
        click_if_visible(page, "button", "Close", done=lambda: agent.count() and agent.last.is_visible())
    try:
        agent.last.wait_for(timeout=10000)
    except Exception:
        raise drift("no Agent toggle on the composer")
    if agent.last.get_attribute("aria-pressed") == "true":
        agent.last.click()
        settle(page, 800, lambda: agent.last.get_attribute("aria-pressed") != "true")
    if agent.last.get_attribute("aria-pressed") == "true":
        raise drift("the Agent toggle stays on")
    click_if_visible(page, "button", "Clear prompt", done=lambda: not box.inner_text().strip())
    if box.inner_text().strip():
        raise drift("the prompt box kept earlier text after Clear prompt")


def choose(page, name) -> None:
    radio = page.get_by_role("radio", name=name, exact=isinstance(name, str)).last
    radio.click(timeout=5000)
    settle(page, 300, radio.is_checked)
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
        raise drift(f"composer settings ({failure_text(exc)[:300]})")
    finally:
        close_settings(page, trigger, family)
    return cost, " ".join(trigger.inner_text().split())


def upload(page, paths: list[Path], stem: str, suffix: str, wait_s: float) -> list:
    """Uploads through the open picker in one batch; returns each path's finished asset option, in order."""
    # The asset list is account-wide, so names carry the content hash: an earlier upload of the same bytes is
    # picked instead of sent again (Flow spends ~6 s on each), and one still at "Uploading" is waited for,
    # never attached half-sent.
    def named(name: str, prefix: str = ""):
        return page.get_by_role("option", name=re.compile(
            "^" + prefix + re.escape(name) + r"(\.\w+)?" + re.escape(suffix) + "$"))

    names = [f"{stem}-{hashlib.sha256(path.read_bytes()).hexdigest()[:16]}" for path in paths]
    options = [named(name) for name in names]
    uploading = [named(name, "Uploading ") for name in names]
    staging = Path(tempfile.mkdtemp(prefix="gemini-web-"))
    try:
        send = {}
        for path, name, option, busy in zip(paths, names, options, uploading):
            if not option.count() and not busy.count() and name not in send:
                send[name] = staging / f"{name}{path.suffix.lower()}"
                shutil.copyfile(path, send[name])
        if send:
            with page.expect_file_chooser(timeout=15000) as chooser:
                page.get_by_role("button", name="Upload media", exact=True).last.click()
            chooser.value.set_files([str(staged) for staged in send.values()])
        deadline = time.time() + wait_s + 30 * len(send)
        while any(not option.count() or busy.count() for option, busy in zip(options, uploading)):
            if time.time() > deadline:
                raise drift(f"the upload of {', '.join(path.name for path in paths)} never finished in the asset list")
            click_if_visible(page, "button", "I agree")
            page.wait_for_timeout(SETTLE_MS)
        return [option.first for option in options]
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def fill_frame(page, slot: str, image: Path) -> None:
    empty = page.get_by_role("button", name=slot, exact=True)
    empty.last.click()
    page.get_by_role("heading", name="Select a frame image").wait_for(timeout=10000)
    upload(page, [image], slot.lower(), "", 180)[0].click()
    page.wait_for_timeout(800)
    if empty.count():
        click_if_visible(page, "button", "Add to prompt")
    deadline = time.time() + 15
    while empty.count():
        if time.time() > deadline:
            raise drift(f"the {slot} frame slot never took {image.name}")
        page.wait_for_timeout(500)
    close_overlays(page)


def add_ingredients(page, paths: list[Path], kind: str) -> None:
    chips = page.get_by_role("button", name=re.compile(r"ingredient$", re.IGNORECASE))
    options = None
    for index, path in enumerate(paths):
        before = chips.count()
        page.get_by_role("button", name="Add ingredients to the prompt box", exact=True).click()
        page.get_by_role("button", name="Upload media", exact=True).last.wait_for(timeout=10000)
        if options is None:
            options = upload(page, paths, kind.lower(), f" {kind}", 300 if kind == "Video" else 180)
        options[index].click()
        settle(page, 800, lambda: chips.count() != before)
        if chips.count() == before:
            click_if_visible(page, "button", "Add to prompt", done=lambda: chips.count() != before)
        deadline = time.time() + 15
        while chips.count() == before:
            if time.time() > deadline:
                raise drift(f"{path.name} never showed up as a prompt ingredient")
            page.wait_for_timeout(SETTLE_MS)
        close_overlays(page)


def compose(page, plan: dict) -> tuple[int, str]:
    manual_composer(page)
    cost, chip = settings(page, plan, full=True)
    if plan["first_frame"]:
        fill_frame(page, "Start", Path(plan["first_frame"]))
    if plan["last_frame"]:
        fill_frame(page, "End", Path(plan["last_frame"]))
    add_ingredients(page, [Path(ref) for ref in plan["refs"]], "Image")
    if plan["edit"]:
        add_ingredients(page, [Path(plan["edit"])], "Video")
    if plan["first_frame"] or plan["last_frame"] or plan["refs"] or plan["edit"]:
        cost, chip = settings(page, plan, full=False)
    tokens = chip.split()
    want = [plan["resolution"], f"x{plan['count']}"] + ([f"{plan['duration']}s"] if plan["duration"] else [])
    if not tokens or tokens[0] != "Video" or any(w not in tokens for w in want):
        raise drift(f"the composer reads {chip!r} after setup, expected {' '.join(want)}")
    return cost, chip


def extend_composer(page, source: dict, label: str) -> str:
    """The source clip's editor in extend mode; Flow shows no credit quote there."""
    if source.get("scene"):
        goto_flow(page, f"/project/{source['project']}/edit/{source['scene']}")
    else:
        open_clip(page, source["project"], source["media_id"], source.get("account", "-"))
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


POOL_VENDOR = "gemini"
POOL_READ = ('. "$0/share/worker-model.sh" && . "$0/share/worker-pool.sh" && '
             'worker_pool_disabled_json "$(worker_pool_dir "$1")" && echo && { worker_model_pins "$1" || true; }')
_pool: tuple | None = None


def pool() -> tuple[set[str] | None, set[str]]:
    """The POOL_VENDOR worker pool's exclusions (None: unreadable, so every account is out) and its pins."""
    global _pool
    if _pool is None:
        try:
            out = subprocess.run(["bash", "-c", POOL_READ, str(REPO), POOL_VENDOR], capture_output=True,
                                 text=True, timeout=30, check=True).stdout
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
        raise Failure(4, f"{account} is out of the {POOL_VENDOR} worker pool, so no headless run may use it. Turn "
                         '"In pool" back on for it, or pin it in ~/.claude/worker-model.')


def roster() -> list[str]:
    try:
        return account_roster.roster(POOL_VENDOR)
    except account_roster.Unreadable as exc:
        raise Failure(1, str(exc)) from exc


def refuse_off_roster(account: str) -> None:
    if account not in roster():
        raise Failure(2, f"unknown account: {account} (not on the {POOL_VENDOR} roster the menubar lists: "
                         f"{', '.join(roster()) or 'none'})")


def bound_accounts() -> list[str]:
    return [n for n in sorted(roster()) if valid_account(n) and (ROOT / "profiles" / n).is_dir() and has_login(n)
            and read_meta(n).get("email")]


def rotation(cost: int) -> list[str]:
    now, walled = time.time(), walls()

    def balance(name: str) -> int:
        credits = read_meta(name).get("credits")
        return cost if credits is None else credits

    # A balance read within WALL_SECONDS stands in for a wall that only this price would hit.
    def affordable(name: str) -> bool:
        return balance(name) >= cost or now - read_meta(name).get("credits_at", 0) > WALL_SECONDS

    ready = [n for n in bound_accounts() if walled.get(n, 0) <= now and in_pool(n) and affordable(n)]
    return least_recent(ready)


def refuse_walled(account: str) -> None:
    until = walls().get(account, 0)
    if until > time.time():
        raise Failure(3, f"{account} is walled until {time.strftime('%Y-%m-%d %H:%M', time.localtime(until))} "
                         "(walls.json); nothing was sent", account=account, until=until)


def take_accounts(pinned: str | None, rotated, walled: str) -> list[str]:
    if pinned:
        refuse_off_roster(pinned)
        refuse_out_of_pool(pinned)
        refuse_walled(pinned)
        return [pinned]
    # Idle first only for a fan-out, which hands accounts[:n] to child runs; a failover claims by try-lock.
    accounts = free_first(rotated())
    if not accounts:
        bound = bound_accounts()
        if not bound:
            fail(4, "no Gemini account is signed in; run: geminib web <account>")
        if not any(in_pool(name) for name in bound):
            fail(4, 'every signed-in Gemini account is out of the gemini worker pool; turn "In pool" back on '
                    "for one, or pin it in ~/.claude/worker-model")
        fail(3, walled)
    return accounts


def take_failover(accounts: list[str], plan: dict, generate_on, set_wall, pinned: bool,
                  wall_pinned: bool = True, lock_wait: float = LOCK_WAIT_S) -> None:
    """Takes left over by a failed account move on to the next one; a credit wall (3), a dead login (4) or an
    account still busy after the lock wait (5) skips to the next account unless one was pinned."""
    done: list[dict] = []
    last: Failure | None = None
    with contextlib.closing(claimed(accounts, lock_wait)) as picks:
        for account, refusal in picks:
            try:
                if refusal:
                    raise refusal
                result = generate_on(account, {**plan, "first_take": len(done) + 1,
                                               "count": plan.get("count", 1) - len(done)})
            except Exception as error:
                done += getattr(error, "takes", [])
                if not isinstance(error, Failure):
                    if not done:
                        raise
                    report(account, error)
                    last = Failure(1, failure_text(error)[:300])
                    break
                report(account, error)
                last = error
                if error.code == 3 and (wall_pinned or not pinned or error.extra.get("flagged")):
                    set_wall(account, time.time() + error.extra.get("wall_s", WALL_SECONDS))
                if error.code in (3, 4, 5) and not pinned:
                    continue
                if done:
                    break
                fail(error.code, error.reason, account=account)
            else:
                if result.get("dry_run"):
                    emit(result)
                    return
                emit({**result, "account": done[0]["account"] if done else account, "takes": done + result["takes"]})
                return
    if done:
        emit({"ok": True, "account": done[0]["account"], "takes": done,
              "short": f"{len(done)} of {plan.get('count', 1)} takes; the next one failed: {last.reason}"})
        return
    fail(last.code if last else 3, last.reason if last else "no account")


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
        f.write(json.dumps({"ts": int(time.time()), **entry, **timing(entry.get("event") == "failed")}) + "\n")


def is_mp4(head: bytes) -> bool:
    return head[4:8] == b"ftyp"


def save_video(context, url: str, dest: Path, is_kind=is_mp4, what: str = "clip") -> int:
    response = context.request.get(url, timeout=120000)
    body = response.body()
    if response.status != 200 or not is_kind(body[:12]):
        raise Failure(1, f"{what} download failed (HTTP {response.status}, {len(body)} bytes)")
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


def save_caught(page, trigger, dest: Path, what: str, kind: str, is_kind, fetch, of: str = "", fail=None,
                timeout_s: float = 600.0, prepare=None) -> int:
    """`prepare()` opens the page (a navigation drops the catcher), `trigger()` makes the page download a file. The hidden Chrome segfaults inside its own download manager
    (10 crashes on 2026-10-01, all in Download.save_as), so the file is caught from the page's download link and
    read out of the page; an http link goes to `fetch(url, dest)`, Chrome's own download is the fallback only."""
    part = dest.with_name(f".{dest.name}.part")
    downloads: list = []

    def listener(download):
        downloads.append(download)

    try:
        if prepare:
            prepare()
        page.evaluate(CATCH_DOWNLOAD)
        page.on("download", listener)
        trigger()
        try:
            caught = wait_download(page, downloads, timeout_s)
        except TimeoutError as exc:
            raise Failure(1, f"no {what} download{of} within {timeout_s:.0f}s") from exc
        if caught:
            read_caught(page, caught, part)
        elif downloads[0].url.startswith("http"):
            url = downloads[0].url
            with contextlib.suppress(Exception):
                downloads[0].cancel()
            return fetch(url, dest)
        else:
            print(f"{ROUTE}: the {what} download{of} went through Chrome's download ({downloads[0].url.split(':')[0]})",
                  file=sys.stderr, flush=True)
            downloads[0].save_as(str(part))
    except Failure:
        raise
    except OSError as exc:
        raise Failure(1, f"the {what} download{of} could not be written to {part.parent}: {exc}") from exc
    except Exception as exc:
        error = (fail or drift)(f"the {what} download{of} ({exc.__class__.__name__}: "
                                f"{(str(exc).strip().splitlines() or [''])[0][:120]})")
        error.extra["crashed"] = exc.__class__.__name__ == "TargetClosedError"
        raise error from exc
    finally:
        with contextlib.suppress(Exception):
            page.remove_listener("download", listener)
    if not is_kind(part.read_bytes()[:12]):
        part.unlink()
        raise Failure(1, f"the {what} download{of} is not {kind}")
    part.replace(dest)
    return dest.stat().st_size


def save_from_editor(page, prepare, dest: Path, upscaled: bool) -> int:
    item, what = ("1080p Upscaled", "1080p upscaled") if upscaled else (ORIGINAL_SIZE, "original size")

    def trigger():
        page.get_by_role("button", name="Download media", exact=True).click(timeout=30000)
        page.get_by_role("menuitem", name=item, exact=True).click(timeout=10000)

    return save_caught(page, trigger, dest, what, "an mp4", is_mp4,
                       lambda url, dest: save_video(page.context, url, dest), prepare=prepare)


def save_from_scene(page, project: str, scene: str, dest: Path, upscaled: bool) -> int:
    """Flow's own download from the clip's editor; its 1080p upscale is free on PRO (2026-10-01)."""
    def prepare():
        goto_flow(page, f"/project/{project}/edit/{scene}")
        close_promos(page)

    return save_from_editor(page, prepare, dest, upscaled)


def save_upscaled(page, project: str, scene: str, dest: Path) -> int:
    return save_from_scene(page, project, scene, dest, upscaled=True)


def listed_thumbs(body: str) -> dict[str, str]:
    """media id -> the thumbnail token its project-grid tile shows, from Flow's own project listing."""
    thumbs = {}
    for rpcid, payload in batch_payloads(body):
        if rpcid != LISTING_RPC or not (isinstance(payload, list) and len(payload) > 2
                                        and isinstance(payload[2], list)):
            continue
        for entry in payload[2]:
            token = re.search(r"/asb/([A-Za-z0-9_-]+)", json.dumps(entry))
            if isinstance(entry, list) and entry and isinstance(entry[0], str) and token:
                thumbs[entry[0]] = token.group(1)
    return thumbs


def open_clip(page, project: str, media_id: str, account: str = "-", timeout_s: float = 120.0) -> str:
    """Opens the clip's editor from its tile in the project grid and returns its scene. A video tile carries
    no media id, only a thumbnail, so the page's own listing reply says which thumbnail is the clip's."""
    thumbs: dict[str, str] = {}

    def listener(response):
        if f"rpcids={LISTING_RPC}" in response.url:
            with contextlib.suppress(Exception):
                thumbs.update(listed_thumbs(response.text()))

    page.on("response", listener)
    try:
        goto_flow(page, f"/project/{project}")
        close_promos(page, account)
        settle(page, 30000, lambda: media_id in thumbs)
        if media_id not in thumbs:
            raise Failure(1, f"Flow no longer lists clip {media_id} in project {project} on {account}" if thumbs
                          else f"project {project} on {account} never listed its media")
        tiles = page.locator("flow-grid-tile-container")
        tile = tiles.filter(has=page.locator(f'img[src*="{thumbs[media_id]}"]'))
        thumbnails = tiles.locator("img")
        deadline, still = time.monotonic() + timeout_s, 0
        while not tile.count():
            shown = thumbnails.evaluate_all("imgs => imgs.map(i => i.src)")
            if not shown or still >= 5 or time.monotonic() > deadline:
                raise Failure(1, f"clip {media_id} is listed in project {project} on {account} but no tile in "
                                 "its grid shows it")
            tiles.last.hover()
            page.mouse.wheel(0, 800)
            page.wait_for_timeout(400)
            still = still + 1 if thumbnails.evaluate_all("imgs => imgs.map(i => i.src)") == shown else 0
        tile.first.click(timeout=30000)
        page.wait_for_url(lambda url: "/edit/" in url, timeout=30000)
    except Failure:
        raise
    except Exception as exc:
        raise drift(f"the tile of clip {media_id} in project {project} ({exc.__class__.__name__})") from exc
    finally:
        with contextlib.suppress(Exception):
            page.remove_listener("response", listener)
    close_promos(page, account)
    return re.search(r"/edit/([^/?#]+)", page.url).group(1)


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


def failed_cards(page) -> int:
    return int(page.evaluate(FAILED_CARDS, "count") or 0)


def press_generate(page, button) -> None:
    """Every Failed card already on the page is an earlier job's; unmarked, it would end this one at once."""
    page.evaluate(FAILED_CARDS, "mark")
    button.click()


def await_clips(page, watcher, clips: list[str], deadline: float, timeout_s: float, account: str, dest: Path) -> None:
    """Back once every clip is done, refused or lost. Flow's Failed card names no clip: n fresh cards are the n clips
    left once the rest are done, marked GENERATION_FAILED so they count as refused (a failed video sat out --timeout,
    900 s, before, 2026-10-05)."""
    scanned = failed = 0
    while time.time() < deadline:
        records = [watcher.media.setdefault(m, {}) for m in clips]
        if watcher.blocked():
            raise watcher.blocked()
        flagged = [r["error"] for r in records if r.get("error") in BLOCK_ERRORS]
        if flagged:
            watcher.errors.add(flagged[0])
            raise watcher.blocked()
        pending = [r for r in records if not (r.get("error") or r.get("url") or r.get("status") == DONE)]
        if time.time() - scanned >= CARDS_SCAN_S:
            failed, scanned = failed_cards(page), time.time()
        if failed >= len(pending):
            for record in pending:
                record["error"] = GENERATION_FAILED
            return
        page.wait_for_timeout(1000)
    raise Failure(1, f"not ready after {timeout_s}s; recover later: {recover_hint(account, clips, dest)}",
                  media_id=clips[0], statuses=[watcher.media.get(m, {}).get("status") for m in clips])



def generate_on(account: str, plan: dict, args) -> dict:
    started = time.time()
    if not has_login(account):
        raise Failure(4, f"account {account} has no browser login; run: geminib web {account}")
    meta = read_meta(account)
    if not meta.get("email"):
        raise Failure(4, f"account {account} is not bound to a Google account; run: gemini-web status {account}")
    if not (plan["extend"] or args.dry_run):
        note_started(account)
    return render_on(account, plan, args, meta, Path(args.dest), started)


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
            phase("page")
            credits = read_credits(page)
            note_credits(account, credits)
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
            press_generate(page, button)
            sent = time.time()
            phase("sent")
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
            await_clips(page, watcher, clips, deadline, args.timeout, account, dest)
            rendered = time.time()
            phase("media")
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
                if record.get("url"):
                    saved[-1]["bytes"] = save_video(context, record["url"], path)
                elif record.get("scene"):
                    saved[-1]["bytes"] = save_from_scene(page, project, record["scene"], path, upscaled=False)
                else:
                    raise Failure(1, f"clip {media_id} finished but Flow gave no video URL and no scene for it; "
                                     f"recover: {recover_hint(account, [media_id], path)}",
                                  media_id=media_id)
                ledger({"account": account, "media_id": media_id, "dest": str(path), "state": "saved",
                        "model": plan["model"], "scene": record.get("scene"), "bytes": saved[-1]["bytes"]})
            if not saved:
                error = refused[0]["error"]
                raise Failure(1, error if error == GENERATION_FAILED else f"Flow refused the clip: {error}",
                              media_id=refused[0]["media_id"])
            finished = time.time()
            if not later:
                phase("saved")
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
        phase("saved")
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
        refuse_off_roster(pinned)
        refuse_out_of_pool(pinned)
        refuse_walled(pinned)
    candidates = [pinned] if pinned else rotation(plan["cost"])
    if not candidates:
        bound = bound_accounts()
        if not bound:
            raise Failure(4, "no Flow account is signed in; run: geminib web <account>")
        if not any(in_pool(name) for name in bound):
            raise Failure(4, 'every signed-in Flow account is out of the gemini worker pool; turn "In pool" '
                             "back on for one, or pin it in ~/.claude/worker-model")
        raise Failure(3, f"every signed-in Flow account is walled (walls.json) or holds under {plan['cost']} "
                         "credits by its last balance read")
    skipped: list[tuple[str, Failure]] = []
    with contextlib.closing(claimed(candidates, args.lock_wait)) as picks:
        for account, refusal in picks:
            try:
                if refusal:
                    raise refusal
                result = generate_on(account, plan, args)
            except Failure as failure:
                report(account, failure)
                # A short balance is skipped by its cached credits; a wall would also refuse cheaper jobs.
                if failure.code == 3 and "credits" not in failure.extra:
                    set_wall(account, time.time() + failure.extra.get("wall_s", WALL_SECONDS))
                if failure.code not in (3, 4, 5) or pinned:
                    raise Failure(failure.code, failure.reason, account=account, **failure.extra)
                skipped.append((account, failure))
                continue
            set_wall(account, None)
            emit(result)
            return
    raise Failure(min(failure.code for _, failure in skipped),
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
        bound = state["email"] == meta.get("email")
        emit({"ok": bound, "account": args.account, "email": mask_email(state["email"]),
              "bound_to": mask_email(meta.get("email")), "credits": credits, "build": state["build"],
              "seconds": round(time.time() - started, 1)})
        sys.exit(0 if bound else 1)


def job_project(media_id: str) -> str | None:
    known = [r["project"] for r in job_rows()
             if isinstance(r, dict) and r.get("media_id") == media_id and r.get("project")]
    return known[-1] if known else None


def cmd_fetch(args) -> None:
    project = job_project(args.media_id)
    if not project:
        raise Failure(1, f"the job ledger ({ROOT / 'jobs.jsonl'}) has no Flow project for clip {args.media_id}, "
                         "so its tile cannot be found")
    with browser(args.account) as context:
        page = context.pages[0] if context.pages else context.new_page()
        opened = {}

        def prepare():
            opened["scene"] = open_clip(page, project, args.media_id, args.account)

        size = save_from_editor(page, prepare, Path(args.dest), args.resolution == "1080p")
        ledger({"account": args.account, "media_id": args.media_id, "dest": str(Path(args.dest)),
                "state": "saved", "scene": opened["scene"], "bytes": size})
        emit({"ok": True, "account": args.account, "dest": args.dest, "media_id": args.media_id,
              "bytes": size})


def cmd_login(args) -> None:
    refuse_off_roster(args.account)
    profile = profile_dir(args.account)
    if profile_in_use(profile):
        raise Failure(1, f"profile {args.account} is already open")
    profile.mkdir(parents=True, exist_ok=True)
    os.chmod(profile.parent, 0o700)
    chrome = subprocess.Popen(
        [chrome_binary(SOURCE_APP), f"--user-data-dir={profile}", *COMMON_FLAGS, "--new-window",
         LOGIN_URL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    if getattr(args, "wait", False):
        print(f"{TOOL}: sign {args.account} in in the Chrome window that opened, then quit it with Cmd+Q; "
              "waiting for it to close…", file=sys.stderr, flush=True)
        # The launched process can hand the window to another one, so the profile lock decides too.
        while chrome.poll() is None or profile_in_use(profile):
            time.sleep(LOGIN_POLL_S)
        emit({"ok": True, "account": args.account, "login": has_login(args.account)})
        return
    emit({"ok": True, "account": args.account, "profile": str(profile),
          "next": f"sign in in the window that opened, quit it (Cmd+Q), then: {TOOL} status {args.account}"})


def cmd_accounts(args) -> None:
    profiles = ROOT / "profiles"
    rows = []
    for p in sorted(profiles.iterdir()) if profiles.exists() else []:
        if p.is_dir() and valid_account(p.name):
            meta = read_meta(p.name)
            rows.append({"account": p.name, "roster": p.name in roster(), "login": has_login(p.name),
                         "email": meta.get("email"), "credits": meta.get("credits"),
                         "walled_until": walls().get(p.name), "last_used": meta.get("generation_started_at")})
    emit({"ok": True, "accounts": rows})


def main() -> None:
    parser = argparse.ArgumentParser(prog="gemini-web")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("login", help="open a visible Chrome to sign an account in once")
    p.add_argument("account")
    p.add_argument("--wait", action="store_true", help="return only once that Chrome has quit")
    p.set_defaults(func=cmd_login)
    p = sub.add_parser("status", help="free check: signed in, bound email, credits")
    p.add_argument("account")
    p.add_argument("--visible", action="store_true")
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("accounts", help="profiles with their cached email, credits and walls")
    p.set_defaults(func=cmd_accounts)
    p = sub.add_parser("generate")
    p.add_argument("--account", type=account_arg)
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
    lock_wait_arg(p)
    p.set_defaults(func=cmd_generate)
    p = sub.add_parser("fetch", help="download an already generated clip by media id")
    p.add_argument("account")
    p.add_argument("media_id")
    p.add_argument("--dest", required=True)
    p.add_argument("--resolution", choices=("720p", "1080p"), default="720p",
                   help="1080p downloads Flow's own upscale from the clip's editor")
    p.set_defaults(func=cmd_fetch)
    args = parser.parse_args()
    global TIMED
    TIMED = hasattr(args, "lock_wait")
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
