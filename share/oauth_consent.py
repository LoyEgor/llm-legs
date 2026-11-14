# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.61.0"]
# ///
"""The click of a CLI's browser sign-in, in the account's own hidden Chrome (gemini_web's clone, parked off screen):
the authorize URL a waiting `codex login` / `grok login` / `agy` printed opens in the profile that already holds
the account's session, and the page's own buttons are pressed until the sign-in hands back. bin/relogin runs it
for a node's login; nothing here types a password, code or passkey, and any page asking for one stops the run.

  oauth_consent.py <vendor> <account> --url-file F --email E [--code-file C] [--look | --drop] [--lock-wait S]
  oauth_consent.py <vendor> <account> --identity

The profile: codex accounts sign in through chatgpt_web's clone profile of the account, gemini (agy) and grok
accounts through gemini_web's, whose Google session also carries the xAI sign-in. --identity prints that profile
and the email its store records (exit 4 when either is missing), opening nothing.
--code-file: a vendor whose sign-in ends on a page that shows a code to paste (agy: antigravity.google's
oauth-callback) gets that code written there (0600) and the page is never rendered, so no screenshot holds it.
--look opens the URL, prints what the page shows (emails masked) and clicks nothing.
Prints one JSON line. Exit 0 done, 1 failed (a page it could not read through), 2 usage, 4 the page wants a person
(password, code, captcha, passkey, another account), 5 the profile is busy.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

EMAIL = re.compile(r"[\w.+-]+@[\w-]+(\.[\w-]+)+")
# Words of a page that wants a person: never answered here.
PERSON = re.compile(r"\b(password|passkey|verification code|captcha|verify it'?s you|2-step|two-factor|"
                    r"security key|confirm your identity|check your (email|phone))\b", re.I)
# Where each vendor's sign-in hands back. codex: its loopback (127.0.0.1:1455, carried to the node by the ssh
# forward); agy: Google's redirect to antigravity.google, a page that shows the code to paste; grok's device flow
# has no hand-back, its last page says the device is signed in.
CALLBACKS = {"codex": re.compile(r"^http://(127\.0\.0\.1|localhost):1455/auth/callback\?"),
             "gemini": re.compile(r"^https://antigravity\.google/oauth-callback\?")}
DEVICE_DONE = re.compile(r"(device (is |has been )?(connected|authori[sz]ed|approved|signed in)|you('re| are) (all set|signed in)|"
                         r"you can (now )?close|return to your (terminal|device|cli)|successfully (signed|logged|"
                         r"authorized|connected)|sign-?in (complete|successful))", re.I)
# The buttons that move a consent on, most specific first; "Use another account" and "Create account" never.
FORWARD = ("Continue with Google", "Sign in with Google", "Login with Google", "Log in with Google", "Authorize",
           "Allow", "Approve", "Confirm", "Continue", "Sign in")
LOCK_WAIT_S = 120
STEP_S = 90
WALK_S = 150


def engine(vendor: str):
    """gemini_web as the vendor's profile store binds it: chatgpt_web rebinds its ROOT to its own store."""
    if vendor == "codex":
        import chatgpt_web
        return chatgpt_web.gw
    import gemini_web
    return gemini_web


def masked(gw, text: str) -> str:
    return EMAIL.sub(lambda m: gw.mask_email(m.group(0)), " ".join((text or "").split()))[:200]


def describe(gw, page) -> dict:
    """What the page shows a person: where it is, its headings and the buttons it offers, emails masked."""
    split = urllib.parse.urlsplit(page.url)
    seen = page.evaluate("""() => {
        const shown = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
        const text = e => (e.innerText || e.value || e.getAttribute('aria-label') || '').trim();
        const pick = sel => [...document.querySelectorAll(sel)].filter(shown).map(text).filter(Boolean).slice(0, 20);
        return {title: document.title, headings: pick('h1, h2, h3, [role=heading]'),
                buttons: pick('button, [role=button], input[type=submit], a[role=link], [data-identifier], li[role=link]'),
                inputs: [...document.querySelectorAll('input')].filter(shown).map(e => e.type + ':' + (e.name || e.id)),
                body: (document.body && document.body.innerText || '').slice(0, 1500)};
    }""")
    return {"url": f"{split.scheme}://{split.netloc}{split.path}", "title": masked(gw, seen["title"]),
            "headings": [masked(gw, h) for h in seen["headings"]],
            "buttons": [masked(gw, b) for b in seen["buttons"]], "inputs": seen["inputs"],
            "body": masked(gw, seen["body"])}


class Stop(Exception):
    def __init__(self, code: int, reason: str):
        super().__init__(reason)
        self.code, self.reason = code, reason


def visible(locator) -> bool:
    with contextlib.suppress(Exception):
        return locator.is_visible() and locator.is_enabled()
    return False


def person_wall(page) -> str:
    """Why the page wants a person (a password, a code, a captcha, a passkey), or ''."""
    found = page.evaluate("""() => {
        const shown = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
        const inputs = [...document.querySelectorAll('input')].filter(shown);
        if (inputs.some(e => e.type === 'password')) return 'a password field';
        // A device page's code boxes come filled from its URL (xAI): only an empty one wants a person.
        if (inputs.some(e => (e.autocomplete || '').includes('one-time-code') && !e.value)) return 'a one-time code field';
        if ([...document.querySelectorAll('iframe')].some(f => shown(f) && /captcha|challenge/i.test(f.src || '')))
            return 'a captcha';
        const heads = [...document.querySelectorAll('h1, h2, [role=heading]')].filter(shown).map(e => e.innerText);
        return heads.join(' ');
    }""")
    if found in ("a password field", "a one-time code field", "a captcha"):
        return found
    match = PERSON.search(found or "")
    return f"a page asking for {match.group(0).lower()}" if match else ""


def choose_account(gw, page, email: str, steps: list) -> bool:
    """An account chooser: the target email clicked, or Stop when the chooser offers only others. OpenAI's own
    chooser is passed by: its remembered account leads to a password page, its log-in page to Google's chooser."""
    if urllib.parse.urlsplit(page.url).path.endswith("/choose-an-account"):
        other = page.get_by_text("Use another account", exact=True)
        if other.count() and visible(other.first):
            other.first.click(timeout=5000)
            steps.append("Use another account")
            return True
    google = page.locator(f'[data-identifier="{email}" i]')
    for index in range(google.count()):
        if visible(google.nth(index)):
            google.nth(index).click(timeout=5000)
            steps.append(f"account {gw.mask_email(email)}")
            return True
    named = page.get_by_role("button", name=re.compile(re.escape(email), re.I))
    for index in range(named.count()):
        if visible(named.nth(index)):
            named.nth(index).click(timeout=5000)
            steps.append(f"account {gw.mask_email(email)}")
            return True
    split = urllib.parse.urlsplit(page.url)
    chooser = "accountchooser" in split.path or "choose-an-account" in split.path
    if chooser:
        raise Stop(4, f"the account chooser at {split.netloc}{split.path} offers no {gw.mask_email(email)}")
    return False


def press_forward(page, steps: list) -> bool:
    """The page's own button that moves the sign-in on; a cookie notice is turned down first."""
    for name in ("Reject All", "Reject all"):
        target = page.get_by_role("button", name=name, exact=True)
        if target.count() and visible(target.first):
            target.first.click(timeout=5000)
            steps.append(name)
            return True
    for name in FORWARD:
        # A provider button's accessible name carries its logo's alt text ("Google logo Continue with Google").
        wanted = re.compile(re.escape(name), re.I) if "Google" in name else name
        for role in ("button", "link"):
            target = page.get_by_role(role, name=wanted, exact=wanted is name)
            for index in range(target.count()):
                if visible(target.nth(index)):
                    target.nth(index).click(timeout=5000)
                    steps.append(name)
                    return True
    return False


def walk(gw, page, args, state: dict) -> None:
    """Clicks through until the sign-in hands back (state["done"]) or the page wants a person."""
    deadline, idle, last, same, steps = time.monotonic() + WALK_S, 0, None, 0, state["steps"]
    while time.monotonic() < deadline:
        if state.get("done"):
            return
        with contextlib.suppress(Exception):
            page.wait_for_load_state("domcontentloaded", timeout=10000)
        if state.get("done"):
            return
        try:
            text = page.evaluate("() => document.body ? document.body.innerText.slice(0, 3000) : ''")
        except Exception:  # navigating: read again
            page.wait_for_timeout(500)
            continue
        if args.vendor == "grok" and DEVICE_DONE.search(text or ""):
            state["done"] = "device"
            return
        wall = person_wall(page)
        if wall:
            raise Stop(4, f"{urllib.parse.urlsplit(page.url).netloc} shows {wall}; sign in by hand")
        if re.search(r"(this browser or app may not be secure|access (blocked|denied)|disallowed_useragent|"
                     r"something went wrong|an error occurred)", text or "", re.I):
            raise Stop(1, f"{urllib.parse.urlsplit(page.url).netloc} says: {masked(gw, text)[:160]}")
        acted = choose_account(gw, page, args.email, steps) or press_forward(page, steps)
        if not acted:
            idle += 1
            if idle > 20:
                raise Stop(1, f"no step to take on {describe(gw, page)}")
            page.wait_for_timeout(1000)
            continue
        idle = 0
        page.wait_for_timeout(1500)
        now = (page.url.split("?")[0], tuple(steps[-1:]))
        same = same + 1 if now == last else 0
        last = now
        if same >= 3:
            raise Stop(1, f"the same step repeats on {describe(gw, page)}")
    raise Stop(1, f"no hand-back within {WALK_S}s on {describe(gw, page)}")


def main() -> None:
    parser = argparse.ArgumentParser(prog="oauth_consent.py")
    parser.add_argument("vendor", choices=("codex", "gemini", "grok"))
    parser.add_argument("account")
    parser.add_argument("--url-file")
    parser.add_argument("--email")
    parser.add_argument("--identity", action="store_true")
    parser.add_argument("--code-file")
    parser.add_argument("--look", action="store_true")
    parser.add_argument("--drop", action="store_true", help="the hand-back is answered here and goes nowhere")
    parser.add_argument("--lock-wait", type=int, default=LOCK_WAIT_S, help="seconds to wait for a busy profile")
    try:
        args = parser.parse_args()
    except SystemExit:
        sys.exit(2)
    gw = engine(args.vendor)
    if not gw.valid_account(args.account):
        sys.exit(2)
    if args.identity:
        profile, email = gw.profile_dir(args.account), gw.read_meta(args.account).get("email") or ""
        found = profile.is_dir() and bool(email)
        print(json.dumps({"ok": True, "email": email, "profile": str(profile)} if found else
                         {"ok": False, "reason": f"no hidden clone profile with an email for {args.account} ({profile})"}))
        sys.exit(0 if found else 4)
    if not (args.url_file and args.email):
        sys.exit(2)
    url = Path(args.url_file).read_text().strip().splitlines()[0]
    started, state = time.time(), {"steps": []}

    def hand_back(route, request) -> None:
        if args.vendor == "gemini":
            code = (urllib.parse.parse_qs(urllib.parse.urlsplit(request.url).query).get("code") or [""])[0]
            if code and args.code_file and not args.drop:
                fd = os.open(args.code_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w") as handle:
                    handle.write(code + "\n")
            state["done"] = ("dropped" if args.drop else "code") if code else "no-code"
            route.fulfill(status=200, content_type="text/plain", body="Signed in.")
        elif args.drop:
            state["done"] = "dropped"
            route.fulfill(status=200, content_type="text/plain", body="Dropped.")
        else:
            state["done"] = "callback"
            route.continue_()

    code = 0
    try:
        with gw.file_lock(gw.lock_path(args.account), wait_s=args.lock_wait), gw.browser(args.account) as context:
            if args.vendor in CALLBACKS:
                context.route(CALLBACKS[args.vendor], hand_back)
            page = context.pages[0] if context.pages else context.new_page()
            page.goto(url, wait_until="domcontentloaded", timeout=STEP_S * 1000)
            if args.look:
                with contextlib.suppress(Exception):
                    page.wait_for_load_state("networkidle", timeout=15000)
                result = {"ok": True, "look": describe(gw, page)}
            else:
                walk(gw, page, args, state)
                if state["done"] == "callback":  # the node's login answers through the forward
                    with contextlib.suppress(Exception):
                        page.wait_for_load_state("load", timeout=30000)
                result = {"ok": state["done"] != "no-code", "done": state["done"]}
                if state["done"] == "no-code":
                    code = 1
    except Stop as stop:
        code, result = stop.code, {"ok": False, "reason": stop.reason}
    except gw.Failure as failure:
        busy = "timed out waiting" in failure.reason or "open in another Chrome" in failure.reason
        code, result = (5 if busy else failure.code if failure.code in (2, 4) else 1), \
            {"ok": False, "reason": failure.reason}
    result.update(steps=state["steps"], seconds=round(time.time() - started, 1))
    print(json.dumps(result), flush=True)
    sys.exit(code)


if __name__ == "__main__":
    main()
