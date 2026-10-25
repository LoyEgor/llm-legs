"""Cache keepalive pings (claude-setup hooks/cache-keepalive.py) against the cold re-reads they saved.

The hook journals each ping with the chat's transcript and its size at that moment; this reads only what came
after: the turn the ping opened (its cost) and the chat's next real turn. A return inside the hour after the ping
that read its context warm, while the last real request was over an hour old, saved a 1-hour cache write of that
context. Prices are fresh-input equivalents (1-hour write 2.0, read 0.1, output 5): both sides are the same chat's
model, so the ratio needs no model weight.
"""
import datetime
import json
import os

SUMMARY = "<summary>cache keepalive</summary>"  # the hook entry's rewakeSummary
TTL = 3600
WINDOW = 7 * 86400
MIN_PINGS = 5  # fewer settle nothing
READ_CAP = 64 << 20
WRITE, READ, OUTPUT = 2.0, 0.1, 5.0


def journal_path():
    state = os.environ.get("CLAUDE_KEEPALIVE_DIR") or os.path.expanduser("~/.cache/claude/keepalive")
    return os.path.join(state, "journal.jsonl")


def epoch(text):
    try:
        return datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def price(usage):
    return ((usage.get("input_tokens") or 0) + READ * (usage.get("cache_read_input_tokens") or 0)
            + WRITE * (usage.get("cache_creation_input_tokens") or 0) + OUTPUT * (usage.get("output_tokens") or 0))


def lines(path, offset):
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            for raw in f.read(READ_CAP).splitlines():
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(entry, dict) and not entry.get("isSidechain"):
                    yield entry
    except OSError:
        return


def outcome(row):
    """One ping: {"cost", "value", "kind"}; kind saved (a warm return the hour had expired for), cold (the return
    re-read anyway), compacted (an idle compaction came first), warm anyway (back within the hour of the last
    request), no return (none within the hour, nothing compacted), unread (the ping's turn is not in the transcript:
    it landed mid-task)."""
    at, last = epoch(row.get("ts")), epoch(row.get("ts"))
    if at is None:
        return {"cost": 0.0, "value": 0.0, "kind": "unread"}
    last -= float(row.get("since") or 0)
    cost, seen, phase, compacted = 0.0, set(), "before", False
    for entry in lines(row.get("transcript") or "", int(row.get("offset") or 0)):
        kind, content = entry.get("type"), json.dumps((entry.get("message") or {}).get("content"))
        if kind == "system" and entry.get("subtype") == "compact_boundary" and phase != "before":
            compacted = True
        if kind == "user" and not entry.get("isMeta") and '"tool_result"' not in content[:4000]:
            if phase == "before" and SUMMARY in content:
                phase = "ping"
                continue
            if phase == "ping" and SUMMARY not in content:
                back = epoch(entry.get("timestamp"))
                if back is None or back - at > TTL:
                    break
                phase = "return"
                continue
        if kind != "assistant" or phase == "before":
            continue
        usage = (entry.get("message") or {}).get("usage") or {}
        key = (entry.get("message") or {}).get("id") or entry.get("requestId")
        if not usage or key in seen:
            continue
        seen.add(key)
        if phase == "ping":
            cost += price(usage)
            continue
        read, wrote = usage.get("cache_read_input_tokens") or 0, usage.get("cache_creation_input_tokens") or 0
        if compacted:
            return {"cost": cost, "value": 0.0, "kind": "compacted"}
        if back - last <= TTL:
            return {"cost": cost, "value": 0.0, "kind": "warm anyway"}
        if read < wrote:
            return {"cost": cost, "value": 0.0, "kind": "cold"}
        return {"cost": cost, "value": (WRITE - READ) * read, "kind": "saved"}
    return {"cost": cost, "value": 0.0,
            "kind": "unread" if phase == "before" else "compacted" if compacted else "no return"}


def summary(now, path=None):
    """Pings of the last 7 days: their count, each outcome's count, cost and value; ratio is value over cost."""
    rows = []
    try:
        with open(path or journal_path()) as f:
            for raw in f:
                try:
                    row = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get("decision") == "ping" and (epoch(row.get("ts")) or 0) > now - WINDOW:
                    rows.append(row)
    except OSError:
        pass
    out = {"pings": len(rows), "kinds": {}, "cost": 0.0, "value": 0.0, "last": max((r["ts"] for r in rows), default=None)}
    for row in rows:
        found = outcome(row)
        out["kinds"][found["kind"]] = out["kinds"].get(found["kind"], 0) + 1
        out["cost"] += found["cost"]
        out["value"] += found["value"]
    out["ratio"] = round(out["value"] / out["cost"], 1) if out["cost"] else None
    return out


def text(found):
    kinds = found["kinds"]
    return "%d pings · %d warm returns · %d no return · saves %s its cost" % (
        found["pings"], kinds.get("saved", 0), kinds.get("no return", 0),
        "–" if found["ratio"] is None else "×%.1f" % found["ratio"])


def menu_line(now, path=None):
    found = summary(now, path)
    return "cache keepalive · 7 days · " + text(found) if found["pings"] else None


def component(now, path=None):
    """A Spend component while the week's pings cost more than they saved (MIN_PINGS or more); None otherwise."""
    found = summary(now, path)
    if found["pings"] < MIN_PINGS or found["ratio"] is None or found["ratio"] >= 1:
        return None
    return {"key": "keepalive", "label": "Cache keepalive pings cost more than the cold re-reads they saved",
            "sources": [], "share": 0.0, "basis": 0.0, "delta": text(found), "last": found["last"]}
