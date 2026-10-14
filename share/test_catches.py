"""Which suites catch defects. An episode is a suite's red run and the next green run of it by the same caller in the
same repository; it is a catch when the caller edited code between them, tests alongside or not. Not catches: a red of
a suite the caller wrote or edited earlier in its session (`own`), a green on the same tree (`same`: nothing changed,
or flaky), test-only edits (`test`), no edit of the caller's own (`none`). Callers without a Claude transcript (other
vendors, the night script) are `unread`. Settled days fold once into test-catches.json, so the 90-day rule (Egor,
2026-10-14: a suite that caught nothing in UNCAUGHT_D days, counted from its first journaled day, is deleted whole)
outlives the transcripts and the journal."""

import collections
import datetime
import json
import os
import re

import chat_names
import night_spend
import time_budget
from time_budget import num

VERSION = 1
UNCAUGHT_D = 90
SETTLE_S = 3600
LOOKBACK_D = 3
CLASSES = ("caught", "own", "same", "test", "none", "unread")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
SEGMENT = re.compile(r"&&|\|\||[;|\n]")
REDIRECT = re.compile(r"(?<![0-9&<>])>>?\s*['\"]?([^\s;&|<>()'\"]+)")
WRITER = re.compile(r"\bsed\s+-[a-zA-Z]*i|\bperl\s+-[a-zA-Z]*i|\btee\b|open\([^)]*['\"][wa]b?['\"]|write_text|"
                    r"\b(?:cp|mv|install|rm|trash|patch)\b|\bgit\s+(?:rm|mv|checkout|restore|apply)\b")
PATHISH = re.compile(r"[\w.~/@+-]*[\w-]\.(?:py|sh|lua|js|mjs|ts|tsx|json|jsonl|md|toml|ya?ml|plist|jq|rb|go|rs|swift|"
                     r"txt|html|css)\b|(?:[\w.-]+/)*(?:bin|tests|share|hooks|lib|launchd)/[\w.@+-]+")
TEMP = ("/tmp/", "/private/", "/var/folders/", "/dev/", "~/.cache/", "/.cache/")
VARIABLE = re.compile(r"\$\{?\w+\}?[^\s;&|<>()'\"]*|%s")
TEST_NAME = re.compile(r"^test_|_test\.|\.test\.|\.spec\.")
WORKER_ID = re.compile(r"^[a-z]+-\d{10}-\d+-[0-9a-f]{4}$")
WORKER_RUN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "worker-run")


def ledger_path():
    return os.path.join(time_budget.harness_dir(), "test-catches.json")


def is_test(path):
    parts = path.split("/")
    return "tests" in parts[:-1] or "test" in parts[:-1] or bool(TEST_NAME.search(parts[-1]))


def bash_paths(command):
    command = VARIABLE.sub(" ", command)
    out = REDIRECT.findall(command)
    for segment in SEGMENT.split(command) if not re.search(r"<<", command) else [command]:
        if WRITER.search(segment):
            out += PATHISH.findall(segment)
    return out


def edits(path):
    """[(epoch, path)] of every file the transcript's own tool calls wrote, renamed or deleted."""
    out = []
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None
    with handle:
        for line in handle:
            if '"tool_use"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            try:
                at = datetime.datetime.fromisoformat(str(row.get("timestamp")).replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
            content = (row.get("message") or {}).get("content")
            for item in content if isinstance(content, list) else ():
                if not isinstance(item, dict) or item.get("type") != "tool_use":
                    continue
                given = item.get("input") if isinstance(item.get("input"), dict) else {}
                if item.get("name") in EDIT_TOOLS:
                    target = given.get("file_path") or given.get("notebook_path")
                    out.append((at, str(target or "")))
                elif item.get("name") == "Bash":
                    out += [(at, p) for p in bash_paths(str(given.get("command") or ""))]
    return [(at, p) for at, p in out if p and not any(t in p for t in TEMP)]


def transcripts(callers):
    """{caller: Claude transcript path or None}: chats by session id, claudeb workers through `worker-run transcript`;
    other vendors' runs are None."""
    out = {c: None for c in callers}
    runs = [c for c in callers if c.startswith("claudeb-")]
    for c in callers:
        if not WORKER_ID.match(c):
            found = chat_names.transcript_path(c)
            out[c] = str(found) if found else None
    if runs and os.access(WORKER_RUN, os.X_OK):
        out.update({r: p or None for r, p in night_spend.transcripts(WORKER_RUN, runs).items()})
    return out


def episodes(rows):
    """[(caller, root, suite, red_row, green_row)]: per caller, repository and suite, the first red after its last
    green and the next green."""
    seq = collections.defaultdict(list)
    for r in rows:
        caller = r.get("worker_run") or r.get("session")
        if not caller or r.get("signal") is not None or not isinstance(r.get("suites"), dict):
            continue
        root = str(r.get("repo_root") or r.get("repo") or "").rstrip("/")
        for name, s in r["suites"].items():
            if isinstance(s, dict) and isinstance(s.get("rc"), int):
                seq[(caller, root, name)].append((r, s["rc"] == 0))
    out = []
    for (caller, root, name), runs in seq.items():
        red = None
        for r, ok in runs:
            if not ok and red is None:
                red = r
            elif ok and red is not None:
                out.append((caller, root, name, red, r))
                red = None
    return out


def judge(name, red, green, wrote):
    if wrote is None:
        return "unread"
    red_end, green_start = num(red.get("ended_at")), num(green.get("started_at")) or num(green.get("ended_at"))
    if any(at <= red_end and os.path.basename(p) == name for at, p in wrote):
        return "own"
    if red.get("tree") and red.get("tree") == green.get("tree"):
        return "same"
    between = [p for at, p in wrote if red_end <= at <= green_start]
    if any(not is_test(p) for p in between):
        return "caught"
    return "test" if between else "none"


def key(root, name):
    return "%s/%s" % (os.path.basename(root), os.path.splitext(name)[0])


def fold(now, journal, write=False):
    """The ledger with every settled day folded in: {days: {day: {class: episodes, catches: {suite: n}}},
    suites: {suite: {first, last}}, through}."""
    held = time_budget.read_json(ledger_path(), {})
    if not isinstance(held, dict) or held.get("version") != VERSION:
        held = {"version": VERSION, "days": {}, "suites": {}, "through": None}
    rows = None
    day = None
    if held.get("through"):
        day = time_budget.local_day(time_budget.day_bounds(held["through"])[1] + 1)
    else:
        for r in night_spend.rows(journal, keep=True):
            if num(r.get("ended_at")) is not None:
                day = time_budget.local_day(r["ended_at"])
                break
    pending = []
    while day and time_budget.day_bounds(day)[1] + SETTLE_S <= now:
        pending.append(day)
        day = time_budget.local_day(time_budget.day_bounds(day)[1] + 1)
    if not pending:
        return held
    lo, hi = time_budget.day_bounds(pending[0])[0], time_budget.day_bounds(pending[-1])[1]
    rows = [r for r in night_spend.rows(journal, keep=True)
            if lo - LOOKBACK_D * 86400 <= (num(r.get("ended_at")) or 0) < hi]
    for r in rows:
        end = num(r.get("ended_at")) or 0
        if end >= lo and isinstance(r.get("suites"), dict):
            seen = time_budget.local_day(end)
            for name in r["suites"]:
                s = held["suites"].setdefault(key(str(r.get("repo_root") or r.get("repo") or "").rstrip("/"), name), {})
                s["first"] = min(s.get("first") or seen, seen)
    found = [e for e in episodes(rows) if lo <= num(e[4].get("ended_at")) < hi]
    paths = transcripts(sorted({e[0] for e in found}))
    wrote = {}
    for caller, root, name, red, green in found:
        if caller not in wrote:
            wrote[caller] = edits(paths[caller]) if paths.get(caller) else None
        cls = judge(name, red, green, wrote[caller])
        d = held["days"].setdefault(time_budget.local_day(green["ended_at"]), {"catches": {}})
        d[cls] = d.get(cls, 0) + 1
        if cls == "caught":
            k = key(root, name)
            d["catches"][k] = d["catches"].get(k, 0) + 1
            s = held["suites"].setdefault(k, {"first": time_budget.local_day(green["ended_at"])})
            s["last"] = max(s.get("last") or "", time_budget.local_day(green["ended_at"]))
    for d in pending:
        held["days"].setdefault(d, {"catches": {}})
    held["days"] = {d: v for d, v in held["days"].items() if d >= time_budget.local_day(now - 2 * UNCAUGHT_D * 86400)}
    held["through"] = pending[-1]
    if write:
        time_budget.write_json(ledger_path(), held)
    return held


def summary(held, now, days):
    """(class counts, {suite: catches}) over the last `days` folded days."""
    cut = time_budget.local_day(now - days * 86400)
    counts, caught = collections.Counter(), collections.Counter()
    for day, d in held.get("days", {}).items():
        if day > cut:
            counts.update({c: d.get(c, 0) for c in CLASSES})
            caught.update(d.get("catches") or {})
    return counts, caught


def uncaught(held, suites, now):
    """{suite key: {reason, since, top, path, kind}}: a current suite whose last catch, or first journaled day when it
    never caught, lies UNCAUGHT_D days back."""
    out = {}
    for (repo, name), (top, path) in suites.items():
        k = "%s/%s" % (repo, os.path.splitext(name)[0])
        s = held.get("suites", {}).get(k)
        if not s or not s.get("first"):
            continue
        since = time_budget.day_bounds(max(s["first"], s.get("last") or ""))[0] + UNCAUGHT_D * 86400
        if since <= now:
            out[k] = {"reason": "caught nothing in %d days" % UNCAUGHT_D, "since": since, "top": top, "path": path,
                      "kind": "uncaught"}
    return out


def next_due(held, suites):
    current = {"%s/%s" % (r, os.path.splitext(n)[0]) for r, n in suites}
    dates = [max(s["first"], s.get("last") or "") for k, s in held.get("suites", {}).items()
             if s.get("first") and k in current]
    if not dates:
        return None
    return time_budget.local_day(time_budget.day_bounds(min(dates))[0] + UNCAUGHT_D * 86400 + 43200)
