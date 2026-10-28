"""Cache keepalive pings (claude-setup hooks/cache-keepalive.py) against the cold re-reads they saved.

The hook journals each ping with the chat's transcript and its size at that moment; this reads only what came
after: the turn the ping opened (its cost) and the chat's next real turn. A return inside the hour after the ping
that read its context warm, while the last real request was over an hour old, saved a 1-hour cache write of that
context. Prices are fresh-input equivalents (1-hour write 2.0, read 0.1, output 5): both sides are the same chat's
model, so the ratio needs no model weight.

A miss is the other way the hook can fail: an interactive chat re-read 110K or more cold after an hour idle (tokenmap's
`expired (1h+ idle)`) with no journal line in that stretch that explains it (a ping, a skip, a closed window, a
compaction).
"""
import datetime
import json
import os
import sqlite3
import time

SUMMARY = "<summary>cache keepalive</summary>"  # the hook entry's rewakeSummary
TTL = 3600
WINDOW = 7 * 86400
MIN_PINGS = 5  # fewer settle nothing
READ_CAP = 64 << 20
WRITE, READ, OUTPUT = 2.0, 0.1, 5.0
ACTIVE_SINCE = "2026-10-25T16:21:00+00:00"  # the hook's Stop entry went live (claude-setup 745c775)
MISSED = 2  # one unexplained cold re-read may be a killed terminal; two are a pattern
COLD_CONTEXT = 110_000  # the hook's 100K, read on tokenmap's slightly different count
COLDS = """SELECT r.session_id, r.ts, r.gap_seconds FROM requests r JOIN sessions s ON s.session_id = r.root_session
  WHERE r.day >= ? AND r.waste_cause = 'expired (1h+ idle)' AND r.vendor = 'claude' AND r.is_sidechain = 0
    AND COALESCE(r.agent_id, '') = '' AND s.kind = 'chat' AND s.entrypoint = 'cli' AND r.prev_ctx >= ?"""
_memo = {}


def journal_path():
    state = os.environ.get("CLAUDE_KEEPALIVE_DIR") or os.path.expanduser("~/.cache/claude/keepalive")
    return os.path.join(state, "journal.jsonl")


def db_path():
    return os.environ.get("TOKENMAP_DB") or os.path.expanduser("~/.local/share/tokenmap/tokenmap.sqlite3")


def changed(path):
    try:
        found = os.stat(path)
        return path, found.st_mtime_ns, found.st_size
    except OSError:
        return path, None, None


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


def outcome(row, now=None):
    """One ping: {"cost", "value", "kind"}; kind saved (a warm return the hour had expired for), cold (the return
    re-read anyway), compacted (an idle compaction came first), warm anyway (back within the hour of the last
    request), no return (none within the hour or the next ping came first, nothing compacted), pending (no return yet, its hour still runs),
    unread (the ping's turn is not in the transcript: it landed mid-task)."""
    at, last = epoch(row.get("ts")), epoch(row.get("ts"))
    if at is None:
        return {"cost": 0.0, "value": 0.0, "kind": "unread"}
    last -= float(row.get("since") or 0)
    cost, seen, phase, compacted, chained = 0.0, set(), "before", False, False
    for entry in lines(row.get("transcript") or "", int(row.get("offset") or 0)):
        kind, content = entry.get("type"), json.dumps((entry.get("message") or {}).get("content"))
        if kind == "system" and entry.get("subtype") == "compact_boundary" and phase != "before":
            compacted = True
        if kind == "user" and not entry.get("isMeta") and '"tool_result"' not in content[:4000]:
            if phase == "before" and SUMMARY in content:
                phase = "ping"
                continue
            if phase == "ping" and SUMMARY in content:
                chained = True
                break  # the chain's next ping: its own row prices its turn
            if phase == "ping":
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
    if phase == "ping" and not compacted and not chained and (time.time() if now is None else now) - at <= TTL:
        return {"cost": cost, "value": 0.0, "kind": "pending"}
    return {"cost": cost, "value": 0.0,
            "kind": "unread" if phase == "before" else "compacted" if compacted else "no return"}


def colds(since):
    """(session, request time, idle seconds before it) of each tokenmap cold re-read the hook should have covered."""
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % db_path(), uri=True)
        try:
            rows = conn.execute(COLDS, (time.strftime("%Y-%m-%d", time.gmtime(since - 86400)), COLD_CONTEXT)).fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return []
    out = []
    for session, ts, gap in rows:
        at = epoch(ts)
        if at is not None and gap and at - float(gap) >= since:
            out.append((session, at, float(gap)))
    return sorted(out, key=lambda c: c[1])


def explains(row):
    return row.get("decision") in ("ping", "skip", "closed") or (
        row.get("decision") == "silent" and row.get("reason") in ("compacting", "compacted"))


def missed(rows, since):
    """Each cold re-read with no journal line of its chat in the idle stretch before it that explains it; why names
    the stretch's last line (silent:late, silent:lifetime) or its absence."""
    out = []
    for session, at, gap in colds(since):
        lines_in = [r for r in rows if r.get("session") == session and at - gap - 5 <= (epoch(r.get("ts")) or 0) <= at]
        if not any(explains(r) for r in lines_in):
            last = lines_in[-1] if lines_in else {}
            out.append({"session": session[:8], "at": datetime.datetime.fromtimestamp(at).astimezone().isoformat(
                timespec="seconds"), "why": "%s:%s" % (last["decision"], last.get("reason") or "") if last
                else "no journal line"})
    return out


def summary(now, path=None):
    """The last 7 days: pings, each outcome's count, their cost and value (ratio is value over cost), and the misses."""
    key = (int(now) // 60, changed(path or journal_path()), changed(db_path()))
    if key in _memo:
        return _memo[key]
    since = max(now - WINDOW, epoch(ACTIVE_SINCE))
    rows = []
    try:
        with open(path or journal_path()) as f:
            for raw in f:
                try:
                    row = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(row, dict) and (epoch(row.get("ts")) or 0) > now - WINDOW:
                    rows.append(row)
    except OSError:
        pass
    pings = [r for r in rows if r.get("decision") == "ping"]
    out = {"pings": len(pings), "kinds": {}, "cost": 0.0, "value": 0.0, "missed": missed(rows, since),
           "last": max((r["ts"] for r in pings), default=None)}
    for row in pings:
        found = outcome(row, now)
        out["kinds"][found["kind"]] = out["kinds"].get(found["kind"], 0) + 1
        out["cost"] += found["cost"]
        out["value"] += found["value"]
    out["ratio"] = round(out["value"] / out["cost"], 1) if out["cost"] else None
    _memo.clear()
    _memo[key] = out
    return out


def text(found):
    kinds = found["kinds"]
    return "%d pings · %d warm returns · %d no return · saves %s its cost · %d missed" % (
        found["pings"], kinds.get("saved", 0), kinds.get("no return", 0),
        "–" if found["ratio"] is None else "×%.1f" % found["ratio"], len(found["missed"]))


def menu_line(now, path=None):
    found = summary(now, path)
    return "cache keepalive · 7 days · " + text(found) if found["pings"] or found["missed"] else None


def components(now, path=None):
    """Spend components: `keepalive` while the week's pings cost more than they saved (MIN_PINGS or more),
    `keepalive:missed` while MISSED or more cold re-reads went unexplained."""
    found = summary(now, path)
    out = []
    if found["pings"] >= MIN_PINGS and found["ratio"] is not None and found["ratio"] < 1:
        out.append({"key": "keepalive", "label": "Cache keepalive pings cost more than the cold re-reads they saved",
                    "sources": [], "share": 0.0, "basis": 0.0, "delta": text(found), "last": found["last"]})
    if len(found["missed"]) >= MISSED:
        whys = {}
        for miss in found["missed"]:
            whys[miss["why"]] = whys.get(miss["why"], 0) + 1
        out.append({"key": "keepalive:missed", "label": "Cache keepalive did not ping chats that then re-read cold",
                    "sources": [], "share": 0.0, "basis": 0.0, "last": max(m["at"] for m in found["missed"]),
                    "delta": "%d missed: %s · last %s %s" % (len(found["missed"]), ", ".join(
                        "%d %s" % (n, why) for why, n in sorted(whys.items(), key=lambda kv: -kv[1])),
                        found["missed"][-1]["session"], found["missed"][-1]["at"])})
    return out
