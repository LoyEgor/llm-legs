"""mail-find: look for a letter in Apple Mail (every account, All Mail/Inbox and Spam), honest about how fresh Mail is.

  mail-find <words or from:addr...> [--since 3h|2d] [--account <mailbox>] [--limit N] [--body N] [--json]

Words match a letter's subject or sender, `from:` its sender alone, all of them case-insensitively; a hit line is the
date, sender, subject and account/folder, never the body or a link unless `--body N` asks for the Nth hit. Every
run ends with one `FRESH:` line per account: whether Mail was running and the newest letter it holds there. Mail not
running is started in the background and asked to check for new mail. When the question is about recent mail and
Mail found nothing (a window of 6 h or less, Mail just started, or its newest letter older than the window), the
last line is `NEXT:`, the web read that settles it: the Chrome profile `worker-run browse` binds to that address, or
Egor's open Dia tab of that mailbox. Exit 0 with hits, 1 with none, 2 on bad arguments, 3 when Mail cannot be read.
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
# A window up to this long asks about mail Mail may not have fetched yet (Egor 2026-11-11: a fresh letter is
# checked on the web).
RECENT = timedelta(hours=6)
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
    if args.since <= RECENT or not row.get("newest"):
        return True
    return local(row["newest"]) < now - args.since


def next_line(row, accounts, tabs):
    addresses = row.get("addresses") or []
    profile = profile_for(addresses, accounts)
    tab = dia_tab_for(addresses, tabs)
    head = "NEXT: Mail may be behind for this window; read Gmail on the web: "
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
    rows, hits = found.get("accounts") or [], found.get("hits") or []
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
    state = "Mail was running" if was_running else "Mail was closed: started it in the background, asked it to check " \
        "for new mail just now"
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


if __name__ == "__main__":
    sys.exit(main())
