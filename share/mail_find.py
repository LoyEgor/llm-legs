"""mail-find: look for an older letter in Apple Mail (every account, All Mail/Inbox and Spam); today's mail is read on the web.

  mail-find <words or from:addr...> [--since 3h|2d] [--account <mailbox>] [--limit N] [--body N] [--json]

Mail is closed as a rule and so behind (Egor 2026-11-11): a letter of today, a window of `--since` 1d or less, is
never looked for there; Mail is not opened and the answer is the `NEXT:` web read for each mailbox. An older letter
is looked for in Mail: a closed Mail is started hidden, fetches new mail while it is read, and is quit after.
Words match a letter's subject or sender, `from:` its sender alone, all of them case-insensitively; a hit line is the
date, sender, subject and account/folder, never the body or a link unless `--body N` asks for the Nth hit. A Mail
read ends with one `FRESH:` line per account: whether Mail was running and the newest letter it holds there. When
Mail found nothing and may be behind (it was closed, or its newest letter is older than the window), the last line
is `NEXT:`, the web read that settles it: the Chrome profile `worker-run browse` binds to that address, or Egor's
open Dia tab of that mailbox. Exit 0 with hits, 1 with none, 2 on bad arguments, 3 when Mail cannot be read.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPT = os.path.join(HERE, "mail_find.js")
MAILBOXES = os.environ.get("MAIL_FIND_MAILBOXES") or os.path.expanduser("~/.cache/mail-find/mailboxes.json")
# A window up to this long asks about today's mail, which a mostly closed Mail has not fetched: it is read on the
# web and Mail is left closed (Egor 2026-11-11).
TODAY = timedelta(days=1)
SPAN = re.compile(r"^(\d+)([mhd])$")
UNIT = {"m": "minutes", "h": "hours", "d": "days"}
START_WAIT_S = 90


def env(name, default):
    return os.environ.get(name) or default


def span(text):
    match = SPAN.match(text.strip().lower())
    if not match or int(match.group(1)) == 0:
        raise argparse.ArgumentTypeError(f"'{text}' is no window: <n>m, <n>h or <n>d, e.g. 3h")
    return timedelta(**{UNIT[match.group(2)]: int(match.group(1))})


def parse(argv):
    parser = argparse.ArgumentParser(prog="mail-find", description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("terms", nargs="*", help="words in the subject or sender, or from:<address>")
    parser.add_argument("--since", type=span, help="only letters received in this window: 30m, 3h, 2d")
    parser.add_argument("--account", help="one mailbox: its address, Mail account name or a pool account (com, notcom)")
    parser.add_argument("--limit", type=int, default=20, help="hits printed (default 20)")
    parser.add_argument("--body", type=int, metavar="N", help="print the body of hit N")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if not args.terms and not args.since:
        parser.error("name words, from:<address> or --since")
    if args.body is not None and args.body < 1:
        parser.error("--body counts hits from 1")
    args.words = [t for t in args.terms if not t.lower().startswith("from:")]
    args.senders = [t[5:] for t in args.terms if t.lower().startswith("from:") and t[5:]]
    return args


def registry():
    """worker-run browse's registry: pool account -> {email, chrome_profile, status} (docs/browser-runs.md)."""
    path = os.path.join(env("WORKER_RUN_DIR", os.path.expanduser("~/.cache/claude-worker-runs")), "browse",
                        "accounts.json")
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def profile_for(addresses, accounts):
    """The pool account whose Chrome profile `worker-run browse` binds to one of these addresses, or None."""
    lower = {a.lower() for a in addresses}
    return next((name for name, row in sorted(accounts.items())
                 if isinstance(row, dict) and str(row.get("email", "")).lower() in lower), None)


def known_mailboxes():
    """Mail's accounts as of its last read ({name, addresses}); the pool registry's addresses before any."""
    try:
        with open(MAILBOXES, encoding="utf-8") as handle:
            rows = json.load(handle)
        if isinstance(rows, list) and rows:
            return rows
    except (OSError, ValueError):
        pass
    return [{"name": row["email"], "addresses": [row["email"]]} for _, row in sorted(registry().items())
            if isinstance(row, dict) and row.get("email")]


def remember_mailboxes(rows):
    try:
        os.makedirs(os.path.dirname(MAILBOXES), exist_ok=True)
        with open(MAILBOXES, "w", encoding="utf-8") as handle:
            json.dump([{"name": r["name"], "addresses": r.get("addresses") or []} for r in rows], handle)
    except OSError:
        pass


def mail_running():
    return subprocess.run([env("MAIL_FIND_PGREP", "/usr/bin/pgrep"), "-x", "Mail"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def start_mail():
    """Mail in the background, hidden; waits until its process exists (its first Apple event then waits for it)."""
    subprocess.run([env("MAIL_FIND_OPEN", "/usr/bin/open"), "-g", "-j", "-a", "Mail"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + START_WAIT_S
    while not mail_running() and time.monotonic() < deadline:
        time.sleep(0.5)


def quit_mail():
    subprocess.run([env("MAIL_FIND_OSASCRIPT", "/usr/bin/osascript"), "-e", 'tell application id "com.apple.mail" to quit'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ask_mail(query):
    run = subprocess.run([env("MAIL_FIND_OSASCRIPT", "/usr/bin/osascript"), "-l", "JavaScript", SCRIPT,
                          json.dumps(query)], capture_output=True, text=True)
    if run.returncode != 0:
        raise RuntimeError((run.stderr or run.stdout).strip() or f"osascript exited {run.returncode}")
    return json.loads(run.stdout)


def dia_tabs():
    """Egor's open Dia tabs as (id, url, title); none when Dia is not running."""
    try:
        run = subprocess.run([env("MAIL_FIND_DIA_JS", os.path.join(os.path.dirname(HERE), "bin", "dia-js")), "--list"],
                             capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return []
    tabs = []
    for line in run.stdout.splitlines() if run.returncode == 0 else []:
        parts = line.split("\t")
        if len(parts) >= 4:
            tabs.append((parts[0], parts[2], parts[3]))
    return tabs


def dia_tab_for(addresses, tabs):
    lower = [a.lower() for a in addresses]
    return next((tab for tab, url, title in tabs
                 if "mail.google.com" in url and any(a in title.lower() for a in lower)), None)


def age(delta):
    minutes = int(delta.total_seconds() // 60)
    if minutes < 60:
        return f"{max(minutes, 0)} min"
    if minutes < 48 * 60:
        return f"{minutes // 60} h" + (f" {minutes % 60:02d} min" if minutes % 60 else "")
    return f"{minutes // 1440} d"


def local(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone()


def behind(row, args, was_running, now):
    """Mail may not hold a letter of this window for the account yet."""
    if not was_running:
        return True
    if not args.since:
        return False
    if not row.get("newest"):
        return True
    return local(row["newest"]) < now - args.since


def next_line(row, accounts, tabs, head="NEXT: Mail may be behind for this window; read Gmail on the web: "):
    addresses = row.get("addresses") or []
    profile = profile_for(addresses, accounts)
    tab = dia_tab_for(addresses, tabs)
    if profile and tab:
        return f"{head}ACCOUNT: {profile} BROWSER: chrome, or Egor's open Dia tab: dia-js --tab-id {tab}"
    if profile:
        return f"{head}ACCOUNT: {profile} BROWSER: chrome"
    if tab:
        return f"{head}Egor's open Dia tab: dia-js --tab-id {tab}"
    return None


def main(argv=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    accounts = registry()
    wanted = []
    if args.account:
        row = accounts.get(args.account)
        wanted = [row["email"]] if isinstance(row, dict) and row.get("email") else [args.account]
    if args.since and args.since <= TODAY:
        return web_only(args, accounts, wanted)
    was_running = mail_running()
    if not was_running:
        start_mail()
    now = datetime.now(timezone.utc).astimezone()
    query = {"words": args.words, "from": args.senders, "accounts": wanted, "check": not was_running,
             "since_ms": int((now - args.since).timestamp() * 1000) if args.since else None, "body": args.body}
    try:
        found = ask_mail(query)
    except (RuntimeError, ValueError) as err:
        print(f"mail-find: Apple Mail could not be read: {err}", file=sys.stderr)
        return 3
    finally:
        if not was_running:
            quit_mail()
    rows, hits = found.get("accounts") or [], found.get("hits") or []
    if not args.account and rows:
        remember_mailboxes(rows)
    if args.account and not rows:
        print(f"mail-find: Mail has no account '{args.account}'", file=sys.stderr)
        return 2
    lines = []
    if not hits:
        lines.append("no letter matches" + (f" in the last {age(args.since)}" if args.since else ""))
    for n, hit in enumerate(hits[:args.limit], 1):
        lines.append(f"{n:>2}. {local(hit['date']):%Y-%m-%d %H:%M}  {hit['sender']}  {hit['subject']}  "
                     f"[{hit['account']}/{hit['mailbox']}]")
    if len(hits) > args.limit:
        lines.append(f"    … {len(hits) - args.limit} more (--limit)")
    if args.body is not None:
        body = found.get("body")
        lines.append(f"--- body of hit {args.body} ---\n{body}" if body is not None
                     else f"no hit {args.body}: {len(hits)} found")
    state = "Mail was running" if was_running else "Mail was closed: started it hidden, it fetched new mail while " \
        "read and was quit after; letters of the last days may be missing"
    for row in rows:
        newest = row.get("newest")
        held = f"newest letter {local(newest):%Y-%m-%d %H:%M} ({age(now - local(newest))} ago)" if newest \
            else "no letter held"
        lines.append(f"FRESH: {row['name']}: {state}; {held}")
    nexts = []
    if not hits:
        late = [row for row in rows if behind(row, args, was_running, now)]
        tabs = dia_tabs() if late else []
        nexts = [line for line in (next_line(row, accounts, tabs) for row in late) if line]
        if args.account and late and not nexts:
            nexts = [f"NEXT: Mail may be behind for this window; read {args.account} on the web: no Chrome profile "
                     "of `worker-run browse` and no Dia tab holds it"]
    if args.json:
        print(json.dumps({"hits": hits, "accounts": rows, "mail_was_running": was_running, "body": found.get("body"),
                          "next": nexts}, ensure_ascii=False, indent=1))
    else:
        print("\n".join(lines + nexts))
    return 0 if hits else 1


def web_only(args, accounts, wanted):
    """Today's mail: Mail stays closed, each mailbox's web read is the answer."""
    rows = known_mailboxes()
    if wanted:
        lower = {w.lower() for w in wanted}
        rows = [r for r in rows if r["name"].lower() in lower or lower & {a.lower() for a in r["addresses"]}] or \
            [{"name": wanted[0], "addresses": wanted}]
    head = f"NEXT: a letter of the last {age(args.since)} is read on the web, Mail is not opened for it: "
    tabs = dia_tabs()
    nexts = [line for line in (next_line(row, accounts, tabs, head) for row in rows) if line] or \
        [f"{head}no Chrome profile of `worker-run browse` and no Dia tab holds "
         f"{', '.join(r['name'] for r in rows) or 'a mailbox'}"]
    if args.json:
        print(json.dumps({"hits": [], "accounts": rows, "mail_was_running": None, "body": None, "next": nexts},
                         ensure_ascii=False, indent=1))
    else:
        print("\n".join(nexts))
    return 1


if __name__ == "__main__":
    sys.exit(main())
