"""Test health: what suites cost and which are sick, from run-suites' journal (every runner), a window (the last 24 h)
against the median of the 7 days before it. The section is Speed's `tests` key: its block sits in Lost time, its
findings become Speed's `test-health/...` opportunities in min/day, its lines over their usual become regression rows,
and its dead or pinned suites are candidates for share/suite_audit.py's queue. Measurement only: nothing here edits or
deletes a test.

  test_health.py [--from T] [--to T] [--json]   T in epoch seconds or ISO; default the last 24 h
"""

import argparse
import bisect
import collections
import datetime
import glob
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import limit_hit  # noqa: E402
import night_spend  # noqa: E402
import suite_audit  # noqa: E402
import test_catches  # noqa: E402
import time_budget  # noqa: E402
from time_budget import num  # noqa: E402

STATS_D = 7
USUAL_D = 7
DEAD_D = 30
TOP = 10
SHOWN = 5
BAND = 1.5
IDLE_RATIO, IDLE_MIN_S, IDLE_RUNS = 2.0, 10.0, 5
RED_SHARE = 0.25
HEAVY_MIN_DAY = 15.0
PIN_MIN, PIN_EDITS, PIN_REDS = 5, 2, 2
NIGHT_OPEN_H = 16
FULL_SCOPES = ("full", "all")
TARGETED = ("named", "changed")
WORKTREES = "/.claude/worktrees/"
SLOW = os.path.join("tests", "slow-suites")
# share/affected-suites.sh live_suite
LIVE = ("e2e_surfaces.sh", "test_instruction_rates_live.sh")
ROOT_VAR = r"\$\{?(?:ROOT|ROOT_DIR|REPO_ROOT)\}?/"
ROOT_REF = re.compile(ROOT_VAR + r"([\w.@+-]+(?:/[\w.@+-]+)*)")
HEREDOC = re.compile(r"<<-?\s*(?:(['\"])(\w+)\1|\\(\w+))")
MADE = re.compile(r"(?:!\s*-[a-zA-Z]\s+\"?|>>?\s*\"?)$|\b(?:mkdir|touch|tee|ln|cp|mv|rm|install)\b")
PIN = re.compile(r"\bgrep\b[^|;&<>\n]*?\s\"?" + ROOT_VAR + r"([\w.@+${}/-]+)\"?[ \t]*(?:$|[;)\]&|`])", re.M)
RUN = re.compile(r"[\w.+-]+")
WORD = re.compile(r"\w+")
WAITS = ("wait_chat", "wait_worker", "wait_night", "wait_terminal")
# (key, label, unit, smallest delta that may read red)
LINES = (("wait_chat", "wait · chats", "min/day", 30), ("wait_worker", "wait · workers", "w-min/day", 60),
         ("wait_night", "wait · the night", "w-min/day", 60), ("wait_terminal", "wait · no caller", "min/day", 30),
         ("retests", "retests", "min/day", 30), ("per_change", "runs per landed change", "runs", 10),
         ("targeted", "suites per targeted run", "suites", 5), ("idle", "idle in suites", "min/day", 30),
         ("pole", "long pole and serial runs", "min/day", 30), ("red", "red runs", "%", 10),
         ("contention", "wall per CPU second", "×", 1.0), ("queue", "slot queue", "% of wait", 10))


def cache_path():
    return os.path.join(time_budget.harness_dir(), "test-health.json")


def git(top, *args, stdin=None):
    try:
        out = subprocess.run(["git", "-C", top] + list(args), capture_output=True, text=True, timeout=10, input=stdin)
    except (OSError, subprocess.SubprocessError) as error:
        limit_hit.expired("probe.git", error, "its answer in %s: read as no answer" % top,
                          'share/test_health.py:["git", "-C", top] + list(args)')
        return None
    return out.stdout if out.returncode == 0 else None


def epoch(text):
    try:
        return float(text)
    except ValueError:
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


# ---------------------------------------------------------------- the journal


def nights(hi):
    """The night-run windows from the nights journal, an unfinished one open NIGHT_OPEN_H hours at most."""
    spans = []
    for path in glob.glob(os.path.join(time_budget.night_churn.doctors_dir(), "nights", "*.json")):
        night = time_budget.read_json(path, {})
        try:
            start = epoch(night["started_at"])
            end = epoch(night["finished_at"]) if night.get("finished_at") else min(hi, start + NIGHT_OPEN_H * 3600)
        except (KeyError, TypeError, ValueError):
            continue
        spans.append((start, max(start, end)))
    return time_budget.union(spans)


def inside(spans, t):
    i = bisect.bisect_right([a for a, _ in spans], t) - 1
    return i >= 0 and t < spans[i][1]


def load(path, lo, night=()):
    """Every suite exec of a row ended after lo, and the rows themselves; a row ended inside a night-run window is the
    night's whoever ran it."""
    rows, execs = [], []
    for r in night_spend.rows(path, keep=True):
        end, queued = num(r.get("ended_at")), num(r.get("queued_at"))
        if end is None or end < lo or not isinstance(r.get("suites"), dict):
            continue
        start = num(r.get("started_at")) or queued or end
        root = str(r.get("repo_root") or r.get("repo") or "").rstrip("/")
        caller = r.get("worker_run") or r.get("session")
        who = "worker" if r.get("worker_run") else "chat" if caller else None
        row = {"start": start, "end": end, "queued": min(queued or start, start), "caller": caller, "who": who,
               "group": "night" if inside(night, end) else who or "terminal", "repo": os.path.basename(root),
               "kind": r.get("kind"), "scope": r.get("scope"), "j": num(r.get("j")) or 1, "n": 0, "execs": []}
        rows.append(row)
        for name, s in r["suites"].items():
            if not isinstance(s, dict) or num(s.get("secs")) is None:
                continue
            row["n"] += 1
            e = {"repo": row["repo"], "root": root, "checkout": str(r.get("repo") or root), "name": name,
                 "start": start, "end": end, "secs": s["secs"], "cpu": num(s.get("cpu_s")),
                 "sleep": num(s.get("sleep_s")), "ok": s.get("rc") == 0,
                 "killed": r.get("signal") is not None or r.get("complete") is False and r.get("reason") != "repeat-red",
                 "who": who,
                 "tree": r.get("tree") or None, "head": r.get("head") or None, "scope": r.get("scope"), "row": row}
            row["execs"].append(e)
            execs.append(e)
    execs.sort(key=lambda e: (e["start"], e["end"]))
    return rows, execs


def first_end(path):
    """The journal's oldest row end: it is appended in order."""
    for r in night_spend.rows(path, keep=True):
        if num(r.get("ended_at")) is not None:
            return r["ended_at"]
    return None


def label(execs):
    """Marks each exec: `repeat` (a green run of its suite on the same repository content, its `tree`, ended before
    it started, whichever checkout ran it; a profiled run, which journals what a plain one cannot, only after a profiled
    green), `post` (a repeat a chat or the night ran in a worker's worktree after that worker's own green run of the
    content) and `flaky` (a red run a later green run of the same tree passed; without a tree, two every-suite runs of
    one head). A run of new content, the night's landing rerun after a rebase included, is neither."""
    green, profiled, worker_green = {}, {}, {}
    for e in execs:
        key = (e["repo"], e["tree"], e["name"])
        e["repeat"] = bool(e["tree"]) and (green if e["sleep"] is None else profiled).get(key, float("inf")) <= e["start"]
        e["post"] = e["repeat"] and e["who"] != "worker" and WORKTREES in e["checkout"] \
            and worker_green.get((e["checkout"],) + key, float("inf")) <= e["start"]
        if e["ok"] and e["tree"]:
            green[key] = min(green.get(key, float("inf")), e["end"])
            if e["sleep"] is not None:
                profiled[key] = min(profiled.get(key, float("inf")), e["end"])
            if e["who"] == "worker":
                worker_green[(e["checkout"],) + key] = min(worker_green.get((e["checkout"],) + key, float("inf")),
                                                           e["end"])
    later = {}
    for e in reversed(execs):
        key = (e["repo"], "tree", e["tree"], e["name"]) if e["tree"] else \
            (e["checkout"], "head", e["head"], e["name"]) if e["head"] and e["scope"] in FULL_SCOPES else None
        e["flaky"] = bool(key) and not e["ok"] and not e["killed"] and key in later
        if key and e["ok"]:
            later[key] = e["start"]


# ---------------------------------------------------------------- per suite, over the stats window


def per_day(parts, now, born=None):
    """Seconds a day: the median of the STATS_D trailing 24 h days' sums of (end, seconds), so one or three heavy days
    never set a suite's cost; a 3-day mean would still carry a third of one. A suite first journaled (born) inside
    them takes the median of the days since, zero days included, so a new heavy suite never hides for four days."""
    days = [0.0] * STATS_D
    for end, secs in parts:
        back = int((now - end) // 86400)
        if 0 <= back < STATS_D:
            days[back] += secs
    if born is not None and born > now - STATS_D * 86400:
        days = days[:max(1, int((now - born) // 86400) + 1)]
    return statistics.median(days)


def first_runs(execs):
    """{(repo, suite): the end of its first journaled run}."""
    out = {}
    for e in execs:
        key = (e["repo"], e["name"])
        out[key] = min(out.get(key, e["end"]), e["end"])
    return out


def per_suite(execs, now, born):
    by = collections.defaultdict(list)
    for e in execs:
        by[(e["repo"], e["name"])].append(e)
    out = {}
    for key, runs in by.items():
        judged = [e for e in runs if not e["killed"]]
        passing = sorted((e for e in runs if e["ok"]), key=lambda e: e["secs"])
        wall = sum(e["secs"] for e in runs)
        s = {"repo": key[0], "name": key[1], "label": os.path.splitext(key[1])[0], "runs": len(runs),
             "wall_s": wall, "avg_s": wall / len(runs),
             "day_s": per_day(((e["end"], e["secs"]) for e in runs), now, born.get(key)),
             "red": sum(1 for e in judged if not e["ok"]),
             "judged": len(judged), "flaky": sum(1 for e in runs if e["flaky"]),
             "p50_s": passing[len(passing) // 2]["secs"] if passing else None, "idle_s": 0.0,
             "days": len({time_budget.local_day(e["end"]) for e in runs}),
             "cpu_share": sum(e["cpu"] for e in runs if e["cpu"] and e["secs"]) /
             sum(e["secs"] for e in runs if e["cpu"] and e["secs"]) if any(e["cpu"] and e["secs"] for e in runs)
             else None}
        timed = [e for e in passing if e["cpu"] is not None]
        if len(timed) >= IDLE_RUNS:
            fast = timed[:max(1, len(timed) // 10)]
            p10 = timed[len(timed) // 10]["secs"]
            floor = statistics.median(e["cpu"] for e in fast)
            slept = [e["sleep"] for e in passing if e["sleep"] is not None]
            idle = min(p10 - floor, statistics.median(slept)) if slept else p10 - floor
            if p10 >= IDLE_RATIO * floor and idle >= IDLE_MIN_S:
                s.update(idle_s=idle, p10_s=p10, floor_s=floor, slept_runs=len(slept))
        out[key] = s
    return out


def allocate(rows, suites, usual_j):
    """Splits each row's wall, queued to end, into one class per minute: a retest or flaky exec takes its share
    whole; else its idle part, the run's long-pole or serial slack (to the pole suite, or `serial`) and the rest as
    `work`. A share is the exec's suite seconds over the row's, so concurrent suites never add up past the wall."""
    for row in rows:
        execs = row["execs"]
        total = sum(e["secs"] for e in execs)
        wall, ran = row["end"] - row["queued"], row["end"] - row["start"]
        pole, slack, serial = None, 0.0, False
        if len(execs) >= 2 and total > 0 and row["kind"] == "suites":
            pole = max(execs, key=lambda e: e["secs"])
            if row["j"] <= 1 and usual_j > 1:
                slack, serial = max(0.0, min(ran, total) - max(pole["secs"], total / usual_j)), True
            else:
                slack = max(0.0, min(ran, pole["secs"]) - total / min(row["j"], len(execs)))
        slack = min(slack, wall)
        for e in execs:
            share = (wall - slack) * e["secs"] / total if total > 0 else wall / len(execs)
            whole = "retests" if e["repeat"] else "flaky" if e["flaky"] else None
            extra = slack if e is pole else 0.0
            if whole:
                e["cost"] = {whole: share + extra}
                continue
            idle = (suites.get((e["repo"], e["name"])) or {}).get("idle_s", 0.0)
            idle = share * min(idle, e["secs"]) / e["secs"] if e["secs"] > 0 else 0.0
            e["cost"] = {"idle": idle, "work": share - idle}
            if extra:
                e["cost"]["serial" if serial else "pole"] = extra


def cost(execs, cls, who=None):
    return sum(e["cost"].get(cls, 0.0) for e in execs if who is None or e["who"] == who)


# ---------------------------------------------------------------- one window


def spans(rows, lo, hi, group):
    by = collections.defaultdict(list)
    for r in rows:
        if r["group"] == group and r["end"] > lo and r["queued"] < hi:
            by[r["caller"]].append((r["queued"], r["end"]))
    return sum(time_budget.length(time_budget.clip(time_budget.union(v), lo, hi)) for v in by.values())


def measure(rows, execs, landed, lo, hi):
    """The window's class values, each in its line's unit; None where nothing was measured. Every line reads every
    caller; the wait lines split them: chats and workers by day, the night's window whoever ran, and no caller."""
    days = (hi - lo) / 86400.0
    window = [e for e in execs if lo <= e["end"] < hi]
    ended = [r for r in rows if lo <= r["end"] < hi]
    judged = [e for e in window if not e["killed"]]
    timed = [e for e in window if e["cpu"]]
    waited = sum(r["end"] - r["queued"] for r in ended if r["kind"] == "suites")
    targeted = [r["n"] for r in ended if r["kind"] == "suites" and r["scope"] in TARGETED and r["n"]]
    commits = sum(1 for t in landed if lo <= t < hi)
    out = {key: spans(rows, lo, hi, key[5:]) / 60.0 / days for key in WAITS}
    out.update({"runs": len(window),
                "retests": cost(window, "retests") / 60.0 / days,
                "retests_worker": cost(window, "retests", "worker") / 60.0 / days,
                "repeats": sum(1 for e in window if e["repeat"]), "posts": sum(1 for e in window if e["post"]),
                "post_h": sum(e["cost"]["retests"] for e in window if e["post"]) / 3600.0,
                "trees": sum(1 for e in window if e["tree"]), "landed": commits,
                "per_change": len(window) / commits if commits else None,
                "targeted": statistics.mean(targeted) if targeted else None,
                "idle": cost(window, "idle") / 60.0 / days,
                "pole": (cost(window, "pole") + cost(window, "serial")) / 60.0 / days,
                "red": 100.0 * sum(1 for e in judged if not e["ok"]) / len(judged) if judged else None,
                "flaky": sum(1 for e in window if e["flaky"]),
                "contention": sum(e["secs"] for e in timed) / sum(e["cpu"] for e in timed) if timed else None,
                "queue": 100.0 * sum(r["start"] - r["queued"] for r in ended if r["kind"] == "suites") / waited
                if waited else None,
                "suite_min": sum(r["end"] - r["queued"] for r in ended) / 60.0 / days,
                "targeted_min": sum(r["end"] - r["queued"] for r in ended if r["kind"] == "suites"
                                    and r["scope"] in TARGETED) / 60.0 / days})
    groups = collections.Counter(e["row"]["group"] for e in window)
    work = dict({key: groups[key[5:]] for key in WAITS}, retests=out["trees"], idle=len(window), pole=len(window))
    out["work"] = {key: n / days for key, n in work.items()}
    out["per_run"] = {key: out[key] / out["work"][key] if n else None for key, n in work.items()}
    return out


def usual(rows, execs, landed, hi, current):
    """Median of each value over the USUAL_D local days before hi's day that ran any suite; a minutes line's is its
    median minutes a suite run of its class (`per_run`) times the current window's runs, so a busier or quieter day is
    no regression and a day with none of the class (a tree not yet journaled) is unmeasured."""
    found, day = [], time_budget.local_day(hi)
    for back in range(1, USUAL_D + 1):
        lo, end = time_budget.day_bounds(time_budget.local_day(time_budget.day_bounds(day)[0] - back * 86400 + 3600))
        m = measure(rows, execs, landed, lo, end)
        if m["runs"]:
            found.append(m)
    out = {}
    for key, _, _, _ in LINES:
        per = key in current["per_run"]
        values = [v for v in (m["per_run"][key] if per else m[key] for m in found) if v is not None]
        out[key] = statistics.median(values) * (current["work"][key] if per else 1) if values else None
    return out, len(found)


def excess(key, unit, now, normal):
    """A line's minutes a day over its usual: its own unit, or its ratio applied to the window's suite, targeted-run
    or wait minutes."""
    if unit.endswith("min/day"):
        return now[key] - normal[key]
    if key == "red":
        return now["suite_min"] * (now[key] - normal[key]) / 100.0
    if key == "queue":
        return sum(now[k] for k in WAITS) * (now[key] - normal[key]) / 100.0
    base = now["targeted_min"] if key == "targeted" else now["suite_min"]
    return base * (1.0 - normal[key] / now[key]) if now[key] else 0.0


def regressions(now, normal):
    return [{"key": key, "label": text, "unit": unit, "now": round(now[key], 2), "usual": round(normal[key], 2),
             "min_day": round(excess(key, unit, now, normal), 1)}
            for key, text, unit, least in LINES if red_line(key, now[key], normal[key], least)]


# ---------------------------------------------------------------- repository scans


def candidates(text):
    """Every string `grep -w` could match in text: runs of word segments joined by . + or -."""
    out = set()
    for run in set(RUN.findall(text)):
        out.add(run)
        segs = [(m.start(), m.end()) for m in WORD.finditer(run)][:12]
        for i, (a, _) in enumerate(segs):
            for _, b in segs[i:]:
                out.add(run[a:b])
    return out


def read(path):
    try:
        with open(path, errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def gone_refs(top, text, known):
    """The $ROOT paths a suite reads that the repo lacks, past ones it creates, removes or asserts absent, ignored
    ones a run makes and single-quoted or quoted-heredoc ones the shell never expands."""
    found, end = set(), None
    for line in text.splitlines():
        if end is not None:
            end = None if line.strip() == end else end
            continue
        quoted = HEREDOC.search(line)
        end = (quoted.group(2) or quoted.group(3)) if quoted else None
        for m in ROOT_REF.finditer(line):
            path, before = m.group(1).rstrip("."), line[:m.start()]
            if path not in known and before.count("'") % 2 == 0 and not MADE.search(before.rstrip("\"")) \
                    and not os.path.exists(os.path.join(top, path)):
                found.add(path)
    if not found:
        return []
    ignored = git(top, "check-ignore", "--stdin", "--no-index", stdin="\n".join(sorted(found)) + "\n") or ""
    return sorted(found - set(ignored.split("\n")))


def pins(text, invariants):
    """Asserts that grep a repo file's literal text rather than behaviour; one on a file shared-invariants.md lists
    guards a cross-implementation invariant and is no pin."""
    return sum(1 for m in PIN.finditer(text) if os.path.basename(m.group(1)) not in invariants)


def repo_scan(top):
    """{"suites": [suites], "invariants": [basenames shared-invariants.md holds], "dead": {suite: [paths]},
    "pins": {suite: n}, "slow": [suites]} of a repo's tests/."""
    folder = os.path.join(top, "tests")
    try:
        entries = sorted(os.listdir(folder))
    except OSError:
        return None
    files = [n for n in entries if os.path.isfile(os.path.join(folder, n))]
    listed = git(top, "ls-files")
    known = set(listed.split("\n")) if listed is not None else set()
    names = {os.path.basename(p) for p in known if p}
    out = {"suites": [], "dead": {}, "invariants": [], "pins": {},
           "slow": sorted(set(read(os.path.join(top, SLOW)).split()))}
    invariants = os.path.join(top, "docs", "shared-invariants.md")
    if os.path.isfile(invariants) and os.path.isfile(os.path.join(folder, "test_consistency.sh")):
        out["invariants"] = sorted(candidates(read(invariants)) & names)
    for name in files:
        if not (name.startswith("test_") and name.endswith((".sh", ".py")) or name.startswith("e2e_") and
                name.endswith(".sh")) or name in LIVE:
            continue
        text = read(os.path.join(folder, name))
        out["suites"].append(name)
        gone = gone_refs(top, text, known)
        if gone:
            out["dead"][name] = gone
        pinned = pins(text, set(out["invariants"]))
        if pinned:
            out["pins"][name] = pinned
    return out


def scans(tops, cache, write):
    """{top: repo_scan}, reused while this reader, the repo's path list and the blobs repo_scan reads (tests/,
    shared-invariants.md, the .gitignore files check-ignore reads) are unchanged: an edit elsewhere never rescans."""
    out, changed = {}, False
    reader = read(os.path.abspath(__file__))
    for top in tops:
        listed = git(top, "ls-files", "-s")
        if listed is None:
            continue
        lines = [line if path.startswith("tests/") or path == "docs/shared-invariants.md"
                 or os.path.basename(path) == ".gitignore" else path
                 for line in listed.split("\n") for path in [line.partition("\t")[2]]]
        key = hashlib.sha1((reader + "\n".join(lines)).encode()).hexdigest()
        held = cache.get(top)
        if isinstance(held, dict) and held.get("key") == key and isinstance(held.get("scan"), dict):
            out[top] = held["scan"]
            continue
        scan = repo_scan(top)
        if scan is not None:
            out[top], cache[top], changed = scan, {"key": key, "scan": scan}, True
    if changed and write:
        time_budget.write_json(cache_path(), {k: v for k, v in cache.items() if k in out})
    return out


def changes(top, lo):
    """([commit time], {path: commits}) of the commits on the checkout's HEAD since lo."""
    stamps, paths = [], collections.Counter()
    for line in (git(top, "log", "--since=@%d" % lo, "--format=@%ct", "--name-only", "HEAD") or "").splitlines():
        if line.startswith("@") and line[1:].isdigit():
            stamps.append(float(line[1:]))
        elif line.strip():
            paths[line.strip()] += 1
    return stamps, paths


# ---------------------------------------------------------------- dead and pinned suites


def dead(tops, scanned, execs, journal_lo, hi):
    """{repo/label: {reason, since, top, path}}: a suite naming a $ROOT path the repo no longer has, or, once the
    journal covers DEAD_D days, one no runner ran in them; a live or tests/slow-suites one runs on demand and is
    never judged unrun."""
    out = {}
    ran = {(e["repo"], e["name"]) for e in execs if e["end"] >= hi - DEAD_D * 86400}
    covered = journal_lo is not None and journal_lo <= hi - DEAD_D * 86400
    for (repo, name), (top, path) in suite_audit.suites(tops).items():
        key = "%s/%s" % (repo, os.path.splitext(name)[0])
        scan = scanned.get(top) or {}
        gone = (scan.get("dead") or {}).get(name)
        on_demand = name in LIVE or name in (scan.get("slow") or ()) or os.path.splitext(name)[0].endswith("_live")
        if gone:
            out[key] = {"reason": "names $ROOT/%s, gone from the repo" % gone[0], "top": top, "path": path,
                        "since": float((git(top, "log", "-1", "--format=%ct", "--", gone[0]) or "0").strip() or 0)}
        elif covered and not on_demand and (repo, name) not in ran:
            out[key] = {"reason": "no run in %d days" % DEAD_D, "top": top, "path": path,
                        "since": hi - DEAD_D * 86400}
    return out


def pinned(tops, scanned, stats, edits):
    """{repo/label: {reason, since, top, path, kind}}: a suite with PIN_MIN source-text pins, edited in PIN_EDITS
    commits over STATS_D days while PIN_REDS of its runs were red, for its audit to judge."""
    out = {}
    for (repo, name), (top, path) in suite_audit.suites(tops).items():
        count = ((scanned.get(top) or {}).get("pins") or {}).get(name, 0)
        rel = os.path.relpath(path, top)
        edited, red = (edits.get(top) or {}).get(rel, 0), (stats.get((repo, name)) or {}).get("red", 0)
        if count >= PIN_MIN and edited >= PIN_EDITS and red >= PIN_REDS:
            out["%s/%s" % (repo, os.path.splitext(name)[0])] = {
                "kind": "pins", "top": top, "path": path,
                "reason": "%d source-text pins, its suite edited in %d commits over %d days with %d red runs" % (
                    count, edited, STATS_D, red),
                "since": float((git(top, "log", "-1", "--format=%ct", "--", rel) or "0").strip() or 0)}
    return out


# ---------------------------------------------------------------- findings and the block


def finding(cls, target, day_s, worker_day_s, exposure, days, fact, files, confidence=None):
    out = {"class": cls, "target": "test-health/" + target, "min_day": round(day_s / 60.0, 2),
           "worker_min_day": round(worker_day_s / 60.0, 2), "exposure": exposure, "days": days, "fact": fact,
           "files": files}
    if confidence:
        out["confidence"] = confidence
    return out


def per_class(window, cls, now, born):
    """{(repo, suite): (seconds a day, worker seconds a day, execs carrying it)} of one class, by per_day."""
    by = collections.defaultdict(list)
    for e in window:
        if e["cost"].get(cls, 0.0) > 0:
            by[(e["repo"], e["name"])].append(e)
    return {key: (per_day(((e["end"], e["cost"][cls]) for e in runs), now, born.get(key)),
                  per_day(((e["end"], e["cost"][cls]) for e in runs if e["who"] == "worker"), now, born.get(key)),
                  runs)
            for key, runs in by.items()}


def cpu_run(execs):
    timed = [e["cpu"] for e in sorted(execs, key=lambda e: e["end"]) if e["ok"] and e["cpu"]][-suite_audit.RECENT_RUNS:]
    return statistics.median(timed) if len(timed) >= suite_audit.SIDE_RUNS else None


def same_work(history, key, cut, runs):
    """Whether a heavy suite's CPU a run since its own fix landed stays under BAND times the runs' before it: its wall
    since is contention, nothing a suite audit cuts."""
    if not cut:
        return False
    before = cpu_run(e for e in history if (e["repo"], e["name"]) == key and e["end"] < cut)
    after = cpu_run(runs)
    return bool(before and after) and after < BAND * before


def findings(window, suites, now, born, since=lambda target: None, history=()):
    """Each minute of the window's suite wall in at most one finding: retests, flaky, idle, long pole, serial,
    heavy suites (their work at HEAVY_MIN_DAY or more). A suite's finding is charged only
    for its runs from since(its target) on, the time its own fix landed; a heavy one returns only on more CPU a run
    than before that fix (same_work over history, every run loaded)."""
    out = []
    days = lambda runs: len({time_budget.local_day(e["end"]) for e in runs})
    retest = [e for e in window if e["repeat"]]
    if retest:
        out.append(finding("retests", "retests", cost(retest, "retests") / STATS_D,
                           cost(retest, "retests", "worker") / STATS_D,
                           len(retest), days(retest),
                           "%d suite runs on content already green (same tree), %d of them a chat or the night after "
                           "its worker's green run" % (len(retest), sum(1 for e in retest if e["post"])),
                           ["llm-legs/share/run-suites.sh", "llm-legs/bin/worker-run"]))
    keys = {(e["repo"], e["name"]) for e in window}
    for cls in ("flaky", "idle", "pole", "work"):
        cuts = {k: since("test-health/%s/%s/%s" % ("heavy" if cls == "work" else cls, k[0], os.path.splitext(k[1])[0]))
                for k in keys}
        found = per_class([e for e in window if e["end"] >= (cuts[(e["repo"], e["name"])] or 0)], cls, now,
                          {**born, **{k: max(born.get(k) or 0, cut) for k, cut in cuts.items() if cut}})
        for (repo, name), (secs, worker, runs) in sorted(found.items(), key=lambda kv: (-kv[1][0], kv[0])):
            s, files_of = suites.get((repo, name)) or {}, ["%s/tests/%s" % (repo, name)]
            short = os.path.splitext(name)[0]
            if cls == "flaky":
                secs, worker = cost(runs, "flaky") / STATS_D, cost(runs, "flaky", "worker") / STATS_D
                out.append(finding("flaky", "flaky/%s/%s" % (repo, short), secs, worker, len(runs), days(runs),
                                   "%s · %s: %d red runs a later run of the same code passed" % (short, repo, len(runs)),
                                   files_of))
            elif cls == "idle" and s.get("idle_s"):
                slept = s.get("slept_runs")
                out.append(finding("idle", "idle/%s/%s" % (repo, short), secs, worker, len(runs), days(runs),
                                   "%s · %s: p10 wall %d s on %d s CPU, idle %d s a run%s" % (
                                       short, repo, s["p10_s"], s["floor_s"], s["idle_s"],
                                       ", bounded by the sleeps %d profiled runs journaled" % slept if slept else
                                       ", any wait (sleep, I/O, subprocess); no profiled run bounds it"), files_of,
                                   "measured" if slept else "estimated"))
            elif cls == "pole" and secs / 60.0 >= time_budget.GAIN_MIN_DAY:
                out.append(finding("pole", "pole/%s/%s" % (repo, short), secs, worker, len(runs), days(runs),
                                   "%s · %s: the long pole of %d runs, the other slots idle while it runs" % (
                                       short, repo, len(runs)), files_of))
            elif cls == "work" and secs / 60.0 >= HEAVY_MIN_DAY and not same_work(history, (repo, name),
                                                                                  cuts[(repo, name)], runs):
                out.append(finding("heavy", "heavy/%s/%s" % (repo, short), secs, worker, len(runs), days(runs),
                                   "%s · %s: %d runs, %s wall-min a run after retests, flakes, idle and its pole; audit: "
                                   "legacy checks, over-complicated, splittable, sleeps" % (
                                       short, repo, len(runs), plain(cost(runs, "work") / 60.0 / len(runs))), files_of))
    serial = [e for e in window if e["cost"].get("serial")]
    if serial and cost(serial, "serial") / 60.0 / STATS_D >= time_budget.GAIN_MIN_DAY:
        out.append(finding("serial", "serial", cost(serial, "serial") / STATS_D, cost(serial, "serial", "worker") / STATS_D,
                           len({id(e["row"]) for e in serial}), days(serial),
                           "%d multi-suite runs on one slot, their suites one after another" % len(
                               {id(e["row"]) for e in serial}), ["llm-legs/share/run-suites.sh"]))
    return out


def fmt(value):
    if value is None:
        return "–"
    return "%+.1f" % value if 0 < abs(value) < 10 and value != round(value) else "%+d" % round(value)


def plain(value):
    return "–" if value is None else "%.1f" % value if abs(value) < 10 else "%d" % round(value)


def red_line(key, now, normal, least):
    return now is not None and normal is not None and now > BAND * normal and now - normal >= least


def block(now, normal, stats, found, queued, hours, catches):
    """[depth, flags, red, text] lines: the head, one line per class in one unit against its usual, the heavy table."""
    menu, red = [], 0

    def emit(depth, text, flags="", hot=False):
        menu.append([depth, flags, bool(hot), text])

    width = max(len(l) for _, l, _, _ in LINES)
    body = []
    for key, text, unit, least in LINES:
        hot = red_line(key, now[key], normal[key], least)
        red += hot
        body.append((("%-*s %7s %-10s usual %6s  Δ %6s" % (
            width, text, plain(now[key]), unit, plain(normal[key]),
            fmt(None if now[key] is None or normal[key] is None else now[key] - normal[key]))).rstrip(), hot, key))
    heavy = sorted(stats.values(), key=lambda s: (-s["day_s"], -s["wall_s"]))[:TOP]
    sick = [s for s in heavy if s["judged"] and s["red"] / s["judged"] >= RED_SHARE]
    rows = collections.defaultdict(list)
    for f in found:
        rows[f["class"]].append(f)
    emit(0, "Test health: %s min + %s w-min/day by day, %s w-min/day at night · %d of %d lines over their usual · "
         "%d heavy suites red · %d dead or pinned" % (
             plain(now["wait_chat"] + now["wait_terminal"]), plain(now["wait_worker"]), plain(now["wait_night"]), red,
             len(LINES), len(sick), len(queued)), "", red)
    for text, hot, key in body:
        emit(1, text, "", hot)
        if key == "retests":
            emit(2, "%5d runs on content already green" % now["repeats"] + (
                "" if now["trees"] else " · no run journaled its tree yet"), "d")
            emit(2, "%5d of them a chat or the night after its worker's green run · %.1f wall-h" % (
                now["posts"], now["post_h"]), "d")
        elif key == "per_change":
            emit(2, "%5d changes landed in %d h" % (now["landed"], round(hours)), "d")
        elif key in ("idle", "pole"):
            shown = sorted(rows["idle"] if key == "idle" else rows["pole"] + rows["serial"], key=lambda f: -f["min_day"])
            if shown:
                emit(2, "min/day  runs  suite · median day of %d" % STATS_D, "d")
            for f in shown[:SHOWN]:
                emit(2, "%7s %5d  %s" % (plain(f["min_day"]), f["exposure"], f["target"].split("/", 1)[1]), "d")
        elif key == "red":
            reds = sorted((s for s in stats.values() if s["red"]), key=lambda s: (-s["red"], s["label"]))
            emit(2, "%5d flaky: red, then green on the same code" % now["flaky"], "d")
            if reds:
                emit(2, "red runs  red %  flaky  suite · " + "%d days" % STATS_D, "d")
            for s in reds[:SHOWN]:
                emit(2, "%8d %6d %6d  %s · %s" % (s["red"], round(100.0 * s["red"] / s["judged"]), s["flaky"],
                                                  s["label"], s["repo"]), "d")
    counts, caught, due = catches
    wall = sum(s["wall_s"] for s in stats.values())
    hit = sum(s["wall_s"] for s in stats.values() if "%s/%s" % (s["repo"], s["label"]) in caught)
    emit(1, "%5d of %d red runs fixed by a code edit · %d suites · %d %% of suite time · %d days" % (
        counts["caught"], sum(counts.values()), len(caught), round(100.0 * hit / wall) if wall else 0, STATS_D), "d")
    emit(2, "%5d own new test · %d nothing changed · %d tests edited · %d no own edit · %d unread" % (
        counts["own"], counts["same"], counts["test"], counts["none"], counts["unread"]), "d")
    for k, n in caught.most_common(SHOWN):
        emit(2, "%5d  %s" % (n, k), "d")
    emit(2, "uncaught %d days: deleted whole · next due %s" % (test_catches.UNCAUGHT_D, due or "–"), "d")
    priced = {f["target"].split("/", 2)[2]: f["min_day"] for f in rows["heavy"]}
    emit(1, "min/day   mean   runs  avg min  red %%  CPU/wall   priced  heaviest suites · median day of %d, mean of "
         "them" % STATS_D, "d")
    for s in heavy:
        share = s["red"] / s["judged"] if s["judged"] else 0.0
        emit(1, "%7s %6s %6d %8.1f %6d %9s %8s  %s · %s" % (
            plain(s["day_s"] / 60.0), plain(s["wall_s"] / 60.0 / STATS_D), s["runs"], s["avg_s"] / 60.0,
            round(100 * share),
            "–" if s["cpu_share"] is None else "%.2f" % s["cpu_share"],
            plain(priced.get("%s/%s" % (s["repo"], s["label"]))), s["label"], s["repo"]), "", share >= RED_SHARE)
    if queued:
        emit(1, "%d dead or pinned suites, queued for their audit" % len(queued), "d")
        for key, d in sorted(queued.items())[:SHOWN]:
            emit(2, "%s · %s" % (key, d["reason"]), "d")
    return menu


def collect(now, journal, tops=None, write=False, lo=None, since=lambda target: None):
    """The `tests` section over [lo, now) (the last 24 h) against the USUAL_D days before it: `menu`, `findings`
    (min/day over STATS_D days), `regressions` (lines over their usual, in min/day), `candidates` (dead and pinned
    suites for suite_audit) and the class values."""
    started = time.monotonic()
    lo = now - 86400 if lo is None else lo
    tops = suite_audit.repos() if tops is None else tops
    first = min(lo, time_budget.day_bounds(time_budget.local_day(now))[0] - (USUAL_D + 1) * 86400,
                now - STATS_D * 86400)
    rows, execs = load(journal, min(first, now - DEAD_D * 86400), nights(now))
    out = {"status": "nodata", "as_of_s": int(now), "window": {"from_s": int(lo), "to_s": int(now)},
           "findings": [], "regressions": [], "candidates": {}, "menu": [], "head": "no suite run in run-suites' journal"}
    if not execs:
        return out
    journal_lo = first_end(journal)
    label(execs)
    recent = [e for e in execs if e["end"] >= first]
    rows = [r for r in rows if r["end"] >= first]
    stats_lo = now - STATS_D * 86400
    window = [e for e in recent if stats_lo <= e["end"] < now]
    born = first_runs(execs)
    stats = per_suite(window, now, born)
    multi = [r["j"] for r in rows if r["n"] >= 2 and r["j"] > 1 and r["end"] >= stats_lo]
    allocate(rows, stats, statistics.median(multi) if multi else 1)
    cache = time_budget.read_json(cache_path(), {})
    scanned = scans(tops, cache if isinstance(cache, dict) else {}, write)
    held = test_catches.fold(now, journal, write)
    landed, edits = [], {}
    for top in tops:
        stamps, edits[top] = changes(top, stats_lo)
        landed += stamps
    current = measure(rows, recent, landed, lo, now)
    normal, days = usual(rows, recent, landed, now, current)
    listed = suite_audit.suites(tops)
    queued = dict(test_catches.uncaught(held, listed, now), **pinned(tops, scanned, stats, edits))
    queued.update(dead(tops, scanned, execs, journal_lo, now))
    counts, caught = test_catches.summary(held, now, STATS_D)
    found = findings(window, stats, now, born, since, execs)
    out.update(status="watch" if any(red_line(k, current[k], normal[k], m) for k, _, _, m in LINES) else "ok",
               now=current, usual=normal, usual_days=days, findings=found, regressions=regressions(current, normal),
               heavy=[dict({k: s[k] for k in ("repo", "label", "runs", "wall_s", "avg_s", "red", "judged", "flaky",
                                              "cpu_share")}, min_day=round(s["day_s"] / 60.0, 1),
                           usual_min_day=round(s["wall_s"] / 60.0 / STATS_D, 1))
                      for s in sorted(stats.values(), key=lambda s: (-s["day_s"], -s["wall_s"]))[:TOP]],
               candidates=queued,
               catches={"days": STATS_D, "episodes": dict(counts), "suites": dict(caught),
                        "next_due": test_catches.next_due(held, listed)},
               journal_days=round((now - (journal_lo or now)) / 86400.0, 1))
    out["menu"] = block(current, normal, stats, found, queued, (now - lo) / 3600.0,
                        (counts, caught, out["catches"]["next_due"]))
    out["head"] = out["menu"][0][3].split(": ", 1)[1]
    out["collector_s"] = round(time.monotonic() - started, 2)
    return out


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--from", dest="lo", type=epoch)
    parser.add_argument("--to", dest="hi", type=epoch)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    hi = args.hi or time_budget.now_s()
    found = collect(hi, time_budget.suites_path(), lo=args.lo)
    if args.json:
        print(json.dumps(found, indent=1, ensure_ascii=False, default=str))
    else:
        print("\n".join("  " * depth + text for depth, _, _, text in found["menu"]) or found["head"])
        print("collector %.2f s" % found.get("collector_s", 0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
