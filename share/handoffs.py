"""Open handoffs of the sweep repositories: `docs/handoffs/*.md` whose first `Status:` line reads open.
Each becomes a night job (`bin/night-run carry`); the LLM doctor's debt row names one open past STALE_S.
A handoff addressed (its To/For paragraph) to a chat («name») that is live right now is that chat's, never a night job.
`owner_batches` groups them by owner chat (the ledger row naming the file, else the first addressee) for
`night-run carry`: an owner with a decision section or two or more handoffs, its chat found by exact name.
`python3 share/handoffs.py [--batches]` prints handoffs, or those batches, as JSON lines."""
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

STALE_S = 60 * 3600
HEAD_LINES = 20
STATUS_RE = re.compile(r"^\**Status:?\**\s*(.*)", re.I)
NAME_RE = re.compile(r"«([^»]+)»")
ADDRESS_RE = re.compile(r"^\**(To|For)\b", re.I)
DECIDE_RE = re.compile(r"^#+\s.*(yours to decide|decision)", re.I | re.M)
NAMED_RE = re.compile(r"handoffs/([A-Za-z0-9_.-]+?\.md)")


def sweep_repos():
    path = os.environ.get("NIGHT_RUN_SWEEP_REPOS") or os.path.expanduser("~/.claude/sweep-repos")
    try:
        with open(path) as handle:
            return [line.strip() for line in handle if line.strip()]
    except OSError:
        return []


def written_at(path):
    found = re.match(r"(\d{4}-\d{2}-\d{2})-", os.path.basename(path))
    if found:
        try:
            return time.mktime(datetime.datetime.strptime(found.group(1), "%Y-%m-%d").timetuple())
        except ValueError:
            pass
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def head(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return [handle.readline() for _ in range(HEAD_LINES)]
    except OSError:
        return []


def addressees(lines):
    names, inside = set(), False
    for line in lines:
        inside = bool(ADDRESS_RE.match(line)) or inside and bool(line.strip())
        if inside:
            names.update(n.strip() for n in NAME_RE.findall(line))
    return sorted(names)


def live_chats():
    import chat_names
    names = set()
    for path in chat_names.session_store_files():
        try:
            with open(path) as handle:
                record = json.load(handle)
            os.kill(int(record["pid"]), 0)
        except (OSError, ValueError, KeyError, TypeError):
            continue
        name = chat_names.chat_name(str(record.get("sessionId") or ""))
        if name:
            names.add(name.strip().lower())
    return names


def open_handoffs(repos=None, now=None, live=None):
    now = time.time() if now is None else now
    out = []
    for repo in sweep_repos() if repos is None else repos:
        for path in sorted(glob.glob(os.path.join(repo, "docs", "handoffs", "*.md"))):
            lines = head(path)
            status = next((m.group(1) for m in map(STATUS_RE.match, lines) if m), "")
            if not status.lower().startswith("open"):
                continue
            to = addressees(lines)
            at = written_at(path)
            out.append({"repo": repo, "path": path, "rel": os.path.relpath(path, repo),
                        "slug": os.path.basename(path)[:-3], "at": at,
                        "age_s": None if at is None else int(now - at), "to": to})
    if out and any(h["to"] for h in out):
        names = live_chats() if live is None else {n.lower() for n in live}
        for handoff in out:
            handoff["live"] = [n for n in handoff["to"] if n.lower() in names]
    for handoff in out:
        handoff.setdefault("live", [])
    return out


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def ledger_owners(repos):
    named = {}
    for repo in repos:
        for path in sorted(glob.glob(os.path.join(repo, "share", "*-ledger.json"))):
            try:
                with open(path) as handle:
                    ledger = json.load(handle)
            except (OSError, ValueError):
                continue
            for row in ledger.get("rows") or []:
                owner = (ledger.get("owners") or {}).get(row.get("block")) or ledger.get("owner")
                if not owner:
                    continue
                for name in {n for text in strings(row) for n in NAMED_RE.findall(text)}:
                    counts = named.setdefault(name, {})
                    counts[owner] = counts.get(owner, 0) + 1
    return named


def recent_chats():
    try:
        out = subprocess.run(["chat-find", "--recent", "--json"], capture_output=True, text=True, timeout=120).stdout
        return json.loads(out or "[]")
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def decides(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return bool(DECIDE_RE.search(handle.read()))
    except OSError:
        return False


def slugify(name, fallback):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or fallback[:8]


def owner_batches(handoffs, repos=None, chats=None, live=None):
    named = ledger_owners(sweep_repos() if repos is None else repos)
    groups = {}
    for handoff in handoffs:
        counts = named.get(os.path.basename(handoff["path"]), {})
        owner = max(counts, key=lambda o: counts[o]) if counts else (handoff["to"] or [None])[0]
        if owner:
            groups.setdefault(owner, []).append(handoff)
    groups = {o: hs for o, hs in groups.items() if len(hs) >= 2 or any(decides(h["path"]) for h in hs)}
    if not groups:
        return []
    chats = recent_chats() if chats is None else chats
    names = live_chats() if live is None else {n.lower() for n in live}
    out = []
    for owner, batch in groups.items():
        chat = next((c for c in chats if c.get("name") == owner and c.get("session")), None)
        if chat is None:
            continue
        out.append({"owner": owner, "slug": slugify(owner, chat["session"]), "session": chat["session"],
                    "cwd": chat.get("cwd") or "", "live": owner.lower() in names,
                    "at": min((h["at"] for h in batch if h["at"] is not None), default=None),
                    "handoffs": [h["path"] for h in batch], "repos": sorted({h["repo"] for h in batch})})
    return sorted(out, key=lambda b: (b["at"] is None, b["at"] or 0, b["owner"]))


if __name__ == "__main__":
    found = open_handoffs()
    for item in owner_batches(found) if sys.argv[1:] == ["--batches"] else found:
        print(json.dumps(item, ensure_ascii=False))
