"""Test health: what suites cost and which are sick, from run-suites' journal (every runner), a window (the last 24 h)
against the median of the 7 days before it. The section is Speed's `tests` key: its block sits in Lost time, its
findings become Speed's `test-health/...` opportunities in min/day, and its dead suites are candidates for
share/suite_audit.py's queue. Measurement only: nothing here edits or deletes a test.

  test_health.py [--from T] [--to T] [--json]   T in epoch seconds or ISO; default the last 24 h
"""

import argparse
import collections
import datetime
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import night_spend  # noqa: E402
import suite_audit  # noqa: E402
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
FULL_SCOPES = ("full", "all")
TARGETED = ("named", "changed")
WORKTREES = "/.claude/worktrees/"
# share/affected-suites.sh live_suite
LIVE = ("e2e_surfaces.sh", "test_instruction_rates_live.sh")
ROOT_REF = re.compile(r"\$\{?(?:ROOT|ROOT_DIR|REPO_ROOT)\}?/([\w.@+-]+(?:/[\w.@+-]+)*)")
RUN = re.compile(r"[\w.+-]+")
WORD = re.compile(r"\w+")
# (key, label, unit, smallest delta that may read red)
LINES = (("wait_chat", "wait · chats", "min/day", 30), ("wait_worker", "wait · workers", "w-min/day", 60),
         ("retests", "retests", "min/day", 30), ("per_change", "runs per landed change", "runs", 10),
         ("targeted", "suites per targeted run", "suites", 5), ("idle", "idle in suites", "min/day", 30),
         ("red", "red runs", "%", 10), ("contention", "wall per CPU second", "×", 1.0),
         ("queue", "slot queue", "% of wait", 10))


def cache_path():
    return os.path.join(time_budget.harness_dir(), "test-health.json")


def git(top, *args):
    try:
        out = subprocess.run(["git", "-C", top] + list(args), capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


# ---------------------------------------------------------------- the journal


def load(path, lo):
    """Every suite exec of a row ended after lo, and the rows themselves."""
    rows, execs = [], []
    for r in night_spend.rows(path):
        end, queued = num(r.get("ended_at")), num(r.get("queued_at"))
        if end is None or end < lo or not isinstance(r.get("suites"), dict):
            continue
        start = num(r.get("started_at")) or queued or end
        root = str(r.get("repo_root") or r.get("repo") or "").rstrip("/")
        caller = r.get("worker_run") or r.get("session")
        row = {"start": start, "end": end, "queued": min(queued or start, start), "caller": caller,
               "who": "worker" if r.get("worker_run") else "chat" if caller else None,
               "kind": r.get("kind"), "scope": r.get("scope"), "n": 0}
        rows.append(row)
        for name, s in r["suites"].items():
            if not isinstance(s, dict) or num(s.get("secs")) is None:
                continue
            row["n"] += 1
            execs.append({"repo": os.path.basename(root), "root": root, "checkout": str(r.get("repo") or root),
                          "name": name, "start": start, "end": end, "secs": s["secs"], "cpu": num(s.get("cpu_s")),
                          "ok": s.get("rc") == 0, "killed": r.get("signal") is not None or r.get("complete") is False,
                          "who": row["who"], "tree": r.get("tree") or None, "head": r.get("head") or None,
                          "scope": r.get("scope")})
    execs.sort(key=lambda e: (e["start"], e["end"]))
    return rows, execs


def first_end(path):
    """The journal's oldest row end: it is appended in order."""
    for r in night_spend.rows(path):
        if num(r.get("ended_at")) is not None:
            return r["ended_at"]
    return None


def label(execs):
    """Marks each exec: `repeat` (a green run of its suite already ended on the same checkout and tree), `post` (a
    chat or the night ran it in a worker's worktree after that worker's last suite run there) and `flaky` (a red
    run a later green run of the same tree passed; without a tree, two every-suite runs of one head)."""
    green, last = {}, {}
    for e in execs:
        if e["who"] == "worker":
            last[e["checkout"]] = max(last.get(e["checkout"], 0.0), e["end"])
    for e in execs:
        key = (e["checkout"], e["tree"], e["name"])
        e["repeat"] = bool(e["tree"]) and green.get(key, float("inf")) <= e["start"]
        if e["ok"] and e["tree"]:
            green[key] = min(green.get(key, float("inf")), e["end"])
        e["post"] = not e["repeat"] and e["who"] != "worker" and WORKTREES in e["checkout"] \
            and e["checkout"] in last and e["start"] >= last[e["checkout"]]
    later = {}
    for e in reversed(execs):
        key = (e["root"], "tree", e["tree"], e["name"]) if e["tree"] else \
            (e["checkout"], "head", e["head"], e["name"]) if e["head"] and e["scope"] in FULL_SCOPES else None
        e["flaky"] = bool(key) and not e["ok"] and not e["killed"] and key in later
        if key and e["ok"]:
            later[key] = e["start"]


# ---------------------------------------------------------------- per suite, over the stats window


def per_suite(execs):
    by = collections.defaultdict(list)
    for e in execs:
        by[(e["repo"], e["name"])].append(e)
    out = {}
    for key, runs in by.items():
        judged = [e for e in runs if not e["killed"]]
        passing = sorted((e for e in runs if e["ok"]), key=lambda e: e["secs"])
        wall = sum(e["secs"] for e in runs)
        s = {"repo": key[0], "name": key[1], "label": os.path.splitext(key[1])[0], "runs": len(runs),
             "wall_s": wall, "avg_s": wall / len(runs), "red": sum(1 for e in judged if not e["ok"]),
             "judged": len(judged), "flaky": sum(1 for e in runs if e["flaky"]),
             "flaky_s": sum(e["secs"] for e in runs if e["flaky"]),
             "p50_s": passing[len(passing) // 2]["secs"] if passing else None, "idle_s": 0.0,
             "days": len({time_budget.local_day(e["end"]) for e in runs}),
             "cpu_share": sum(e["cpu"] for e in runs if e["cpu"]) / sum(e["secs"] for e in runs if e["cpu"])
             if any(e["cpu"] for e in runs) else None}
        timed = [e for e in passing if e["cpu"] is not None]
        if len(timed) >= IDLE_RUNS:
            fast = timed[:max(1, len(timed) // 10)]
            p10 = timed[len(timed) // 10]["secs"]
            floor = statistics.median(e["cpu"] for e in fast)
            if p10 >= IDLE_RATIO * floor and p10 - floor >= IDLE_MIN_S:
                s.update(idle_s=p10 - floor, p10_s=p10, floor_s=floor)
        out[key] = s
    return out


# ---------------------------------------------------------------- one window


def spans(rows, lo, hi, who):
    by = collections.defaultdict(list)
    for r in rows:
        if r["who"] == who and r["end"] > lo and r["queued"] < hi:
            by[r["caller"]].append((r["queued"], r["end"]))
    return sum(time_budget.length(time_budget.clip(time_budget.union(v), lo, hi)) for v in by.values())


def measure(rows, execs, suites, landed, lo, hi):
    """The window's class values, each in its line's unit; None where nothing was measured."""
    days = (hi - lo) / 86400.0
    inside = [e for e in execs if lo <= e["end"] < hi]
    ended = [r for r in rows if lo <= r["end"] < hi]
    judged = [e for e in inside if not e["killed"]]
    timed = [e for e in inside if e["cpu"]]
    waited = sum(r["end"] - r["queued"] for r in ended if r["kind"] == "suites")
    targeted = [r["n"] for r in ended if r["kind"] == "suites" and r["scope"] in TARGETED and r["n"]]
    commits = sum(1 for t in landed if lo <= t < hi)
    retest = [e for e in inside if e["repeat"] or e["post"]]
    return {"runs": len(inside),
            "wait_chat": spans(rows, lo, hi, "chat") / 60.0 / days,
            "wait_worker": spans(rows, lo, hi, "worker") / 60.0 / days,
            "retests": sum(e["secs"] for e in retest) / 60.0 / days,
            "retests_worker": sum(e["secs"] for e in retest if e["who"] == "worker") / 60.0 / days,
            "repeats": sum(1 for e in inside if e["repeat"]), "posts": sum(1 for e in inside if e["post"]),
            "post_h": sum(e["secs"] for e in inside if e["post"]) / 3600.0,
            "trees": sum(1 for e in inside if e["tree"]), "landed": commits,
            "per_change": len(inside) / commits if commits else None,
            "targeted": statistics.mean(targeted) if targeted else None,
            "idle": sum((suites.get((e["repo"], e["name"])) or {}).get("idle_s", 0.0) for e in inside) / 60.0 / days,
            "red": 100.0 * sum(1 for e in judged if not e["ok"]) / len(judged) if judged else None,
            "flaky": sum(1 for e in inside if e["flaky"]),
            "contention": sum(e["secs"] for e in timed) / sum(e["cpu"] for e in timed) if timed else None,
            "queue": 100.0 * sum(r["start"] - r["queued"] for r in ended if r["kind"] == "suites") / waited
            if waited else None}


def usual(rows, execs, suites, landed, hi):
    """Median of each value over the USUAL_D local days before hi's day that ran any suite."""
    found, day = [], time_budget.local_day(hi)
    for back in range(1, USUAL_D + 1):
        lo, end = time_budget.day_bounds(time_budget.local_day(time_budget.day_bounds(day)[0] - back * 86400 + 3600))
        m = measure(rows, execs, suites, landed, lo, end)
        if m["runs"]:
            found.append(m)
    out = {}
    for key, _, _, _ in LINES:
        values = [m[key] for m in found if m[key] is not None]
        out[key] = statistics.median(values) if values else None
    return out, len(found)


# ---------------------------------------------------------------- fan-out: tests/affected, cached by blob


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


def repo_scan(top):
    """{"suites": {suite: [names it covers]}, "helpers", "invariants", "dead": {suite: [paths]}} as share/affected-
    suites.sh reads tests/, over every repo file basename."""
    folder = os.path.join(top, "tests")
    try:
        entries = sorted(os.listdir(folder))
    except OSError:
        return None
    files = [n for n in entries if os.path.isfile(os.path.join(folder, n))]
    helpers = {n: candidates(read(os.path.join(folder, n))) for n in files if not n.startswith(("test_", "e2e_"))}
    listed = git(top, "ls-files")
    known = set(listed.split("\n")) if listed is not None else set()
    names = {os.path.basename(p) for p in known if p}
    out = {"suites": {}, "dead": {}, "invariants": []}
    for name in files:
        if not (name.startswith("test_") and name.endswith((".sh", ".py")) or name.startswith("e2e_") and
                name.endswith(".sh")) or name in LIVE:
            continue
        text = read(os.path.join(folder, name))
        seen = candidates(text)
        for helper, words in helpers.items():
            if helper in text:
                seen |= words
        out["suites"][name] = sorted(seen & names | {name})
        gone = sorted({p.rstrip(".") for p in ROOT_REF.findall(text)
                       if p.rstrip(".") not in known and not os.path.exists(os.path.join(top, p.rstrip(".")))})
        if gone:
            out["dead"][name] = gone
    invariants = os.path.join(top, "docs", "shared-invariants.md")
    if os.path.isfile(invariants) and os.path.isfile(os.path.join(folder, "test_consistency.sh")):
        out["invariants"] = sorted(candidates(read(invariants)) & names)
    return out


def scans(tops, cache, write):
    """{top: repo_scan}, reused while `git ls-files -s` of the repo (every blob) is unchanged."""
    out, changed = {}, False
    for top in tops:
        listed = git(top, "ls-files", "-s")
        if listed is None:
            continue
        key = hashlib.sha1(listed.encode()).hexdigest()
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


def covering(scan):
    """{basename: [suites]} from a scan."""
    out = collections.defaultdict(set)
    for suite, names in scan["suites"].items():
        for name in names:
            out[name].add(suite)
    for name in scan["invariants"]:
        out[name].add("test_consistency.sh")
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


def fan_out(tops, scanned, suites, hi):
    """The changed files whose tests/affected pull costs the most suite minutes a day, and every commit time."""
    files, landed = [], []
    for top in tops:
        stamps, paths = changes(top, hi - STATS_D * 86400)
        landed += stamps
        scan = scanned.get(top)
        if not scan:
            continue
        repo, cover = os.path.basename(top.rstrip("/")), covering(scan)
        for path, count in paths.items():
            pulled = sorted(cover.get(os.path.basename(path), ()))
            if not pulled or not os.path.exists(os.path.join(top, path)):
                continue
            wall = sum((suites.get((repo, s)) or {}).get("p50_s") or 0.0 for s in pulled)
            files.append({"repo": repo, "top": top, "path": path, "changes": count, "suites": len(pulled),
                          "suite_min": round(wall / 60.0, 1),
                          "min_day": round(count * wall / 60.0 / STATS_D, 1)})
    files.sort(key=lambda f: (-f["min_day"], -f["suites"], f["path"]))
    return files, landed


# ---------------------------------------------------------------- dead suites


def dead(tops, scanned, execs, journal_lo, hi):
    """{repo/label: {reason, since, top, path}}: a suite naming a $ROOT path the repo no longer has, or, once the
    journal covers DEAD_D days, one no runner ran in them."""
    out = {}
    ran = {(e["repo"], e["name"]) for e in execs if e["end"] >= hi - DEAD_D * 86400}
    covered = journal_lo is not None and journal_lo <= hi - DEAD_D * 86400
    for (repo, name), (top, path) in suite_audit.suites(tops).items():
        key = "%s/%s" % (repo, os.path.splitext(name)[0])
        gone = ((scanned.get(top) or {}).get("dead") or {}).get(name)
        if gone:
            out[key] = {"reason": "names $ROOT/%s, gone from the repo" % gone[0], "top": top, "path": path,
                        "since": float((git(top, "log", "-1", "--format=%ct", "--", gone[0]) or "0").strip() or 0)}
        elif covered and (repo, name) not in ran:
            out[key] = {"reason": "no run in %d days" % DEAD_D, "top": top, "path": path,
                        "since": hi - DEAD_D * 86400}
    return out


# ---------------------------------------------------------------- findings and the block


def finding(cls, target, min_day, worker_min_day, exposure, days, fact, files):
    return {"class": cls, "target": "test-health/" + target, "min_day": round(min_day, 2),
            "worker_min_day": round(worker_min_day, 2), "exposure": exposure, "days": days, "fact": fact,
            "files": files}


def findings(execs, suites, files, lo, hi):
    out = []
    window = [e for e in execs if lo <= e["end"] < hi]
    retest = [e for e in window if e["repeat"] or e["post"]]
    if retest:
        out.append(finding("retests", "retests", sum(e["secs"] for e in retest) / 60.0 / STATS_D,
                           sum(e["secs"] for e in retest if e["who"] == "worker") / 60.0 / STATS_D, len(retest),
                           len({time_budget.local_day(e["end"]) for e in retest}),
                           "%d suite runs on work already tested: %d on a tree already green, %d in a worktree after "
                           "its worker's last run" % (len(retest), sum(1 for e in retest if e["repeat"]),
                                                       sum(1 for e in retest if e["post"])),
                           ["llm-legs/share/run-suites.sh", "llm-legs/bin/worker-run"]))
    for s in sorted(suites.values(), key=lambda s: -s["idle_s"] * s["runs"]):
        if s["idle_s"]:
            out.append(finding("idle", "idle/%s/%s" % (s["repo"], s["label"]), s["idle_s"] * s["runs"] / 60.0 / STATS_D,
                               0.0, s["runs"], s["days"],
                               "%s · %s: p10 wall %d s on %d s CPU, idle %d s a run" % (
                                   s["label"], s["repo"], s["p10_s"], s["floor_s"], s["idle_s"]),
                               ["%s/tests/%s" % (s["repo"], s["name"])]))
    for s in sorted(suites.values(), key=lambda s: -s["flaky_s"]):
        if s["flaky"]:
            out.append(finding("flaky", "flaky/%s/%s" % (s["repo"], s["label"]), s["flaky_s"] / 60.0 / STATS_D, 0.0,
                               s["flaky"], s["days"], "%s · %s: %d red runs a later run of the same code passed" % (
                                   s["label"], s["repo"], s["flaky"]), ["%s/tests/%s" % (s["repo"], s["name"])]))
    for f in files[:3]:
        out.append(finding("fan-out", "fan-out/%s/%s" % (f["repo"], f["path"]), f["min_day"], 0.0, f["changes"],
                           STATS_D, "%s · %s: %d suites, %s suite-min a change, %d changes in %d days" % (
                               f["path"], f["repo"], f["suites"], f["suite_min"], f["changes"], STATS_D),
                           ["llm-legs/share/affected-suites.sh", "%s/%s" % (f["repo"], f["path"])]))
    return out


def fmt(value):
    if value is None:
        return "–"
    return "%+.1f" % value if 0 < abs(value) < 10 and value != round(value) else "%+d" % round(value)


def plain(value):
    return "–" if value is None else "%.1f" % value if abs(value) < 10 else "%d" % round(value)


def red_line(key, now, normal, least):
    return now is not None and normal is not None and now > BAND * normal and now - normal >= least


def block(now, normal, stats, files, dead_found, hours):
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
    heavy = sorted(stats.values(), key=lambda s: -s["wall_s"])[:TOP]
    sick = [s for s in heavy if s["judged"] and s["red"] / s["judged"] >= RED_SHARE]
    waited = (now["wait_chat"] or 0) + (now["wait_worker"] or 0)
    emit(0, "Test health: %s min + %s w-min/day on suites · %d of %d lines over their usual · %d heavy suites red "
         "· %d dead" % (plain(now["wait_chat"]), plain(now["wait_worker"]), red, len(LINES), len(sick),
                        len(dead_found)), "", red)
    for text, hot, key in body:
        emit(1, text, "", hot)
        if key == "retests":
            emit(2, "%5d runs on a tree already green" % now["repeats"] + (
                "" if now["trees"] else " · no run journaled its tree yet"), "d")
            emit(2, "%5d runs in a worktree after its worker's last run · %.1f wall-h" % (now["posts"], now["post_h"]),
                 "d")
        elif key == "per_change":
            emit(2, "%5d changes landed in %d h" % (now["landed"], round(hours)), "d")
        elif key == "targeted" and files:
            emit(2, "suites  suite-min  changes  min/day  file · %d days" % STATS_D, "d")
            for f in files[:SHOWN]:
                emit(2, "%6d %10s %8d %8s  %s · %s" % (f["suites"], plain(f["suite_min"]), f["changes"],
                                                       plain(f["min_day"]), f["path"], f["repo"]), "d")
        elif key == "idle":
            idle = sorted((s for s in stats.values() if s["idle_s"]), key=lambda s: -s["idle_s"] * s["runs"])
            if idle:
                emit(2, "min/day  p10 wall s  CPU s  suite · %d days" % STATS_D, "d")
            for s in idle[:SHOWN]:
                emit(2, "%7s %11d %6d  %s · %s" % (plain(s["idle_s"] * s["runs"] / 60.0 / STATS_D), s["p10_s"],
                                                   s["floor_s"], s["label"], s["repo"]), "d")
        elif key == "red":
            reds = sorted((s for s in stats.values() if s["red"]), key=lambda s: (-s["red"], s["label"]))
            emit(2, "%5d flaky: red, then green on the same code" % now["flaky"], "d")
            if reds:
                emit(2, "red runs  red %  flaky  suite · " + "%d days" % STATS_D, "d")
            for s in reds[:SHOWN]:
                emit(2, "%8d %6d %6d  %s · %s" % (s["red"], round(100.0 * s["red"] / s["judged"]), s["flaky"],
                                                  s["label"], s["repo"]), "d")
    emit(1, "  wall h   runs  avg min  red %  CPU/wall  heaviest suites · " + "%d days" % STATS_D, "d")
    for s in heavy:
        share = s["red"] / s["judged"] if s["judged"] else 0.0
        emit(1, "%8.1f %6d %8.1f %6d %9s  %s · %s" % (
            s["wall_s"] / 3600.0, s["runs"], s["avg_s"] / 60.0, round(100 * share),
            "–" if s["cpu_share"] is None else "%.2f" % s["cpu_share"], s["label"], s["repo"]), "", share >= RED_SHARE)
    if dead_found:
        emit(1, "%d dead suites, queued for their audit" % len(dead_found), "d")
        for key, d in sorted(dead_found.items())[:SHOWN]:
            emit(2, "%s · %s" % (key, d["reason"]), "d")
    return menu


def collect(now, journal, tops=None, write=False, lo=None):
    """The `tests` section over [lo, now) (the last 24 h) against the USUAL_D days before it: `menu`, `findings`
    (min/day over STATS_D days), `candidates` (dead suites for suite_audit) and the class values."""
    started = time.monotonic()
    lo = now - 86400 if lo is None else lo
    tops = suite_audit.repos() if tops is None else tops
    first = min(lo, time_budget.day_bounds(time_budget.local_day(now))[0] - (USUAL_D + 1) * 86400,
                now - STATS_D * 86400)
    rows, execs = load(journal, min(first, now - DEAD_D * 86400))
    out = {"status": "nodata", "as_of_s": int(now), "window": {"from_s": int(lo), "to_s": int(now)},
           "findings": [], "candidates": {}, "menu": [], "head": "no suite run in run-suites' journal"}
    if not execs:
        return out
    journal_lo = first_end(journal)
    label(execs)
    recent = [e for e in execs if e["end"] >= first]
    stats = per_suite([e for e in recent if now - STATS_D * 86400 <= e["end"] < now])
    cache = time_budget.read_json(cache_path(), {})
    scanned = scans(tops, cache if isinstance(cache, dict) else {}, write)
    files, landed = fan_out(tops, scanned, stats, now)
    current = measure(rows, recent, stats, landed, lo, now)
    normal, days = usual(rows, recent, stats, landed, now)
    dead_found = dead(tops, scanned, execs, journal_lo, now)
    out.update(status="watch" if any(red_line(k, current[k], normal[k], m) for k, _, _, m in LINES) else "ok",
               now=current, usual=normal, usual_days=days, findings=findings(recent, stats, files,
                                                                             now - STATS_D * 86400, now),
               heavy=[{k: s[k] for k in ("repo", "label", "runs", "wall_s", "avg_s", "red", "judged", "flaky", "cpu_share")}
                      for s in sorted(stats.values(), key=lambda s: -s["wall_s"])[:TOP]],
               fan_out=files[:SHOWN], candidates=dead_found,
               journal_days=round((now - (journal_lo or now)) / 86400.0, 1))
    out["menu"] = block(current, normal, stats, files, dead_found, (now - lo) / 3600.0)
    out["head"] = out["menu"][0][3].split(": ", 1)[1]
    out["collector_s"] = round(time.monotonic() - started, 2)
    return out


def epoch(text):
    try:
        return float(text)
    except ValueError:
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--from", dest="lo", type=epoch)
    parser.add_argument("--to", dest="hi", type=epoch)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    hi = args.hi or time_budget.now_s()
    found = collect(hi, time_budget.suites_path(), lo=args.lo)
    if args.json:
        print(json.dumps(found, indent=1, ensure_ascii=False))
    else:
        print("\n".join("  " * depth + text for depth, _, _, text in found["menu"]) or found["head"])
        print("collector %.2f s" % found.get("collector_s", 0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
