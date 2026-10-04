"""Open handoffs of the sweep repositories: `docs/handoffs/*.md` whose first `Status:` line reads open.
Each becomes a night job (`bin/night-run carry`); the LLM doctor's debt row names one open past STALE_S.
A handoff addressed (its To/For paragraph) to a chat («name») that is live right now is that chat's, never a night job.
`python3 share/handoffs.py` prints them as JSON lines."""
import datetime
import glob
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

STALE_S = 60 * 3600
HEAD_LINES = 20
STATUS_RE = re.compile(r"^\**Status:?\**\s*(.*)", re.I)
NAME_RE = re.compile(r"«([^»]+)»")
ADDRESS_RE = re.compile(r"^\**(To|For)\b", re.I)


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


if __name__ == "__main__":
    for handoff in open_handoffs():
        print(json.dumps(handoff, ensure_ascii=False))
