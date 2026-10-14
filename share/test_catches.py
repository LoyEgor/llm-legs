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

VERSION = 2
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
PATH = re.compile(r"^[\w~./@+-]*[A-Za-z][\w~./@+-]*$")
SYSTEM = re.compile(r"^(?:/usr|/bin|/sbin|/opt|/System|/Library)?/?(?:usr/)?(?:s?bin|lib)/(?:bash|sh|zsh|env|python3?)$|^/(?:usr|opt|System)/")
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
    heredoc = "<<" in command
    out = [p for p in REDIRECT.findall(command.split("\n", 1)[0] if heredoc else command) if PATH.match(p)]
    for segment in [command] if heredoc else SEGMENT.split(command):
        if WRITER.search(segment):
            out += [p for p in PATHISH.findall(segment) if not SYSTEM.match(p)]
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
    """(class, the code paths edited between the red and the green)."""
    if wrote is None:
        return "unread", []
    red_end, green_start = num(red.get("ended_at")), num(green.get("started_at")) or num(green.get("ended_at"))
    if any(at <= red_end and os.path.basename(p) == name for at, p in wrote):
        return "own", []
    if red.get("tree") and red.get("tree") == green.get("tree"):
        return "same", []
    between = [p for at, p in wrote if red_end <= at <= green_start]
    code = [p for p in between if not is_test(p)]
    return ("caught", code) if code else ("test" if between else "none", [])


def in_repo(root, path):
    """The path relative to the repository root, a worktree of it included; None outside it."""
    if not path.startswith("/"):
        rel = path[2:] if path.startswith("./") else path
    elif path.startswith(root + "/"):
        rel = path[len(root) + 1:]
        rel = rel.split("/", 3)[3] if rel.startswith(".claude/worktrees/") and rel.count("/") >= 3 else rel
    else:
        return None
    return None if rel.startswith((".claude/", ".git/")) else rel


def key(root, name):
    return "%s/%s" % (os.path.basename(root), os.path.splitext(name)[0])


def fold(now, journal, write=False):
    """The ledger with every settled day folded in: {days: {day: {class: episodes, catches: {suite: n},
    fixed: {suite: {path: n}}}},
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
        cls, code = judge(name, red, green, wrote[caller])
        d = held["days"].setdefault(time_budget.local_day(green["ended_at"]), {"catches": {}, "fixed": {}})
        d[cls] = d.get(cls, 0) + 1
        if cls == "caught":
            k = key(root, name)
            d["catches"][k] = d["catches"].get(k, 0) + 1
            fixed = d.setdefault("fixed", {}).setdefault(k, {})
            rels = {in_repo(root, p) for p in code} - {None}
            for rel in rels:
                fixed[rel] = round(fixed.get(rel, 0) + 1.0 / len(rels), 3)
            s = held["suites"].setdefault(k, {"first": time_budget.local_day(green["ended_at"])})
            s["last"] = max(s.get("last") or "", time_budget.local_day(green["ended_at"]))
    for d in pending:
        held["days"].setdefault(d, {"catches": {}, "fixed": {}})
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


def fixers(held, now, days):
    """{(repo, path): {suite key: credit}}: the suites whose red a code edit of that file fixed, over `days`; an
    episode's one catch is shared evenly among the code files edited in it."""
    cut = time_budget.local_day(now - days * 86400)
    out = collections.defaultdict(collections.Counter)
    for day, d in held.get("days", {}).items():
        if day > cut:
            for k, paths in (d.get("fixed") or {}).items():
                for rel, n in paths.items():
                    out[(k.split("/", 1)[0], rel)][k] += n
    return out


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
