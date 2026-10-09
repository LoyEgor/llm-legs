"""The harness time budget (docs/handoffs/2026-10-05-harness-time-budget.md): where the wall time of chats and
workers goes, plain Claude Code against each class the harness adds, with each class's usual band, the holes named,
test time as its own budget, an honest one-line-per-night ledger with its 7-night trend and the doctors' daily
problem counts. Measurement only: it reads existing journals and gates nothing.

  time_budget.py day [--hours H] [--json]       the last H hours (24), its bands, holes, tests and levers
  time_budget.py night <worker-run> <night.json> the night's ledger line, its time split and the 7-night trend
  time_budget.py table <worker-run> <night.json> the night against the two previous finished nights with jobs
"""

import argparse
import collections
import glob
import heapq
import itertools
import json
import os
import re
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collector_runs  # noqa: E402
import handoffs  # noqa: E402
import limiter_hold  # noqa: E402
import night_churn  # noqa: E402
import night_spend  # noqa: E402
import spend as spend_block  # noqa: E402
from spend import read_json  # noqa: E402
import suite_audit  # noqa: E402

CLASSES = (("model", "model turns", "plain"), ("tools", "tool execution", "plain"),
           ("compaction", "compaction", "plain"), ("hooks", "hooks", "harness"), ("stop", "stop hooks", "harness"),
           ("suite_run", "suites running", "harness"), ("suite_wait", "suite slot wait", "harness"),
           ("slot", "worker slot queue", "harness"), ("retries", "retries and relaunches", "harness"),
           ("walled", "usage-wall relaunches", "other"), ("review", "review rounds", "harness"),
           ("bench", "bench workers", "other"), ("locks", "locks and polls", "harness"),
           ("other", "other / unmeasured", "other"))
KIND = {key: kind for key, _, kind in CLASSES}
LABEL = {key: label for key, label, _ in CLASSES}
TURN_PART = {"gen": "model", "tool": "tools", "media": "tools", "compact": "compaction", "hook": "hooks",
             "stop": "stop", "test": "suite_run", "resid": "other"}
TURN_AWAY = ("dark", "ask")
WAIT_CLASSES = ("lock", "poll")
GATE_REFUSALS = ("denied", "relay-refused")
BAND_DAYS = 7
BAND_RATIO = 2.0
BAND_MIN_S = 15 * 60
ACTIVE_FLOOR = 0.30
FLOORS = {"hooks": 0, "stop": 0, "suite_wait": 0, "slot": "slots lent during suites", "retries": 0, "locks": 0,
          "suite_run": "uncontended p10 wall"}
BENCH_WORKDIR = re.compile(r"/logo-vectorizer-bench(/|$)")
FLOOR_ROW_MIN_DAY = 30
ROI_DAYS = 3
IMPROVEMENT_RULES = ("opportunity", "regression", "time_floor", spend_block.RULE, suite_audit.RULE)
# (unit, samples a side needs, the after/before ratio proving it, the gain's daily unit, units in one of it): the
# ratio is p5 of median(N)/median(the samples before) on unchanged code over the journals of 2026-09-29..10-07, so a
# lower ratio is no noise.
UNITS = {"suite_run": ("CPU-s/run", suite_audit.PROOF_RUNS, suite_audit.PROOF_RATIO, "CPU-min/day", 60.0),
         "hooks": ("ms/call", 50, 0.55, "min/day", 60000.0), "stop": ("ms/call", 50, 0.55, "min/day", 60000.0),
         "suite_wait": ("s/wait", 20, 0.4, "min/day", 60.0), "slot": ("s/wait", 20, 0.4, "min/day", 60.0),
         "locks": ("s/wait", 20, 0.4, "min/day", 60.0)}
MEASURERS = ("bin/harness-doctor", "bin/speed-doctor", "share/suite_audit.py", "share/time_budget.py")
WAIT_OF = {"suite_wait": ("run-suites",), "slot": ("workers", "review-cells"), "locks": WAIT_CLASSES}
UNIT_BEFORE_DAYS = 7
SETTLE_S = 24 * 3600
KEEP_DAYS = 35
TOP_SUITES = 10
UNMEASURED = "unmeasured"


def home(*parts):
    return os.path.join(os.environ.get("HOME") or os.path.expanduser("~"), *parts)


def env_path(name, *default):
    return os.environ.get(name) or home(*default)


def harness_dir():
    return env_path("HARNESS_DOCTOR_DIR", ".cache", "harness-doctor")


def worker_runs_path():
    stats = os.environ.get("WORKER_STATS_DIR") or os.path.join(
        env_path("CLAUDEB_DIR", ".claude-profiles", ".claudeb"), "worker-stats")
    return os.path.join(stats, "runs.jsonl")


def suites_path():
    return os.environ.get("RUN_SUITES_JOURNAL") or os.path.join(os.path.dirname(
        os.environ.get("RUN_SUITES_TIMES") or os.path.join(os.environ.get("XDG_CACHE_HOME") or home(".cache"), "run-suites", "times.tsv")), "runs.jsonl")


def gates_path():
    return os.path.join(env_path("INSTRUCTION_WATCH_STATE", ".cache", "claude-instruction-watch"), "gates.jsonl")


def now_s():
    return float(os.environ.get("TIME_BUDGET_NOW") or time.time())


def local_day(t):
    return time.strftime("%Y-%m-%d", time.localtime(t))


def day_bounds(day):
    lo = time.mktime(time.strptime(day, "%Y-%m-%d"))
    return lo, time.mktime(time.strptime(local_day(lo + 30 * 3600), "%Y-%m-%d"))


def write_json(path, value):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "w") as handle:
            json.dump(value, handle, separators=(",", ":"))
        os.replace(path + ".tmp", path)
    except OSError:
        pass


def num(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


# ---------------------------------------------------------------- intervals


def union(spans):
    out = []
    for a, b in sorted((a, b) for a, b in spans if b > a):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def clip(spans, lo, hi):
    return union((max(a, lo), min(b, hi)) for a, b in spans)


def length(spans):
    return sum(b - a for a, b in spans)


def minus(spans, cut):
    out, cut = [], union(cut)
    for a, b in union(spans):
        for c, d in cut:
            if d <= a or c >= b:
                continue
            if c > a:
                out.append([a, c])
            a = max(a, d)
            if a >= b:
                break
        if a < b:
            out.append([a, b])
    return out


# ---------------------------------------------------------------- journals


_DAYS = {}


def event_day(day):
    path = os.path.join(harness_dir(), "events", day + ".jsonl")
    try:
        key = (path, os.stat(path).st_size)
    except OSError:
        return {}
    if key not in _DAYS:
        out = collections.defaultdict(list)
        with open(path, "rb") as handle:
            for line in handle:
                if line[2:3] in (b"t", b"c", b"h", b"s") and line[3:5] == b'",':
                    try:
                        out[line[2:3].decode()].append(json.loads(line))
                    except ValueError:
                        continue
        _DAYS[key] = out
    return _DAYS[key]


def event_rows(lo, hi, kinds=("t", "c", "h")):
    """Harness's derived event rows (`t` owner turns, `c` tool calls, `h` hook runs, `s` CLI starts) of the local
    days the window touches; a turn or call is filed under its start day, so the day before is read too."""
    out = collections.defaultdict(list)
    day, last = local_day(lo - 86400), local_day(hi)
    while day <= last:
        for kind, rows in event_day(day).items():
            if kind in kinds:
                out[kind] += rows
        day = local_day(day_bounds(day)[1] + 1)
    return out


def worker_runs(lo, hi):
    return [r for r in night_spend.rows(worker_runs_path())
            if (num(r.get("ended_at")) or 0) > lo and (num(r.get("pid_started_at")) or num(r.get("started_at")) or hi) < hi]


def suite_rows(lo, hi):
    return [r for r in night_spend.rows(suites_path())
            if num(r.get("queued_at")) and num(r.get("ended_at")) and r["ended_at"] > lo and r["queued_at"] < hi]


def wait_rows(lo, hi):
    out = []
    day = local_day(lo)
    while day <= local_day(hi):
        out += [r for r in night_spend.rows(os.path.join(limiter_hold.wait_dir(), day + ".jsonl"))
                if num(r.get("started")) is not None and num(r.get("seconds")) is not None]
        day = local_day(day_bounds(day)[1] + 1)
    return [r for r in out if lo <= r["started"] < hi]


def refusals(lo, hi):
    return sum(1 for r in night_spend.rows(gates_path())
               if r.get("decision") in GATE_REFUSALS and lo <= (num(r.get("at")) or 0) < hi)


def run_session(run):
    text = night_spend.read(os.path.join(night_spend.RUNS, str(run), "session"))
    return text.splitlines()[0][:8] if text else None


# ---------------------------------------------------------------- the split


def run_split(run, lo, hi, suites, calls, hooks):
    """One worker run's wall inside [lo, hi): launch -> first CLI start is the slot queue, earlier attempts are
    retries, or a walled run's usage-wall relaunches (weather, neither work nor retries); the last attempt is split
    into its own suites (slot wait apart), tool calls, hooks inside them, and the rest, which is model time. A review
    round or a bench worker (the owner's benchmark, sleeping on its own jobs) is its own class whole. `started_at`
    is restamped by the slot wait, so the run starts at its pid."""
    start = num(run.get("pid_started_at")) or num(run.get("started_at"))
    end = num(run.get("ended_at"))
    out = collections.Counter()
    if start is None or end is None or end <= start:
        return out
    clis = [num(c) for c in run.get("cli_starts") or () if num(c)] or [num(run.get("started_at")) or start]
    first, last = max(start, min(clis[0], end)), max(start, min(clis[-1], end))
    whole = "review" if run.get("round") else "bench" if BENCH_WORKDIR.search(str(run.get("workdir") or "")) else None
    if whole:
        out[whole] = length(clip([(start, end)], lo, hi))
        return out
    out["slot"] = length(clip([(start, first)], lo, hi))
    out["walled" if run.get("walled") else "retries"] = length(clip([(first, last)], lo, hi))
    work = clip([(last, end)], lo, hi)
    mine = [s for s in suites if s.get("worker_run") == run.get("run")]
    ran = union((max(s["started_at"], s["queued_at"]), s["ended_at"]) for s in mine if num(s.get("started_at")))
    queued = minus([(s["queued_at"], num(s.get("started_at")) or s["ended_at"]) for s in mine], ran)
    out["suite_run"] = length([x for w in work for x in clip(ran, *w)])
    out["suite_wait"] = length([x for w in work for x in clip(queued, *w)])
    rest = minus(work, ran + queued)
    session = run_session(run.get("run"))
    if session is None:
        out["other"] = length(rest)
        return out
    own = [c for c in calls if c[8] == session]
    tools = [x for w in rest for x in clip([(c[1], c[1] + c[5]) for c in own], *w)]
    tids = {c[7] for c in own if any(clip([(c[1], c[1] + c[5])], *w) for w in rest)}
    hook_s = min(length(tools), sum(h[5] for h in hooks if h[7] in tids and h[7]) / 1000.0)
    out["hooks"] = hook_s
    out["tools"] = length(tools) - hook_s
    out["model"] = length(rest) - length(tools)
    return out


def turn_split(row, lo, hi):
    out = collections.Counter()
    start, end = row[1], row[3]
    if end <= start:
        return out
    share = max(0.0, min(end, hi) - max(start, lo)) / (end - start)
    for key, secs in (row[9] or {}).items():
        if key not in TURN_AWAY:
            out[TURN_PART.get(key, "other")] += secs * share
    return out


def budget(lo, hi, events=None):
    """Seconds per class over [lo, hi) for owner chats (Harness turn rows) and worker runs (worker-stats runs). A
    lock or poll wait comes out of tool time only when a chat or worker paid it (its row names a `caller`)."""
    events = events if events is not None else event_rows(lo, hi)
    runs, jobs = worker_runs(lo, hi), []
    suites = suite_rows(min([lo] + [num(r.get("pid_started_at")) or num(r.get("started_at")) or lo for r in runs]),
                        hi + 86400)
    calls = [c for c in events.get("c", ()) if c[6] == "w"]
    chats, workers = collections.Counter(), collections.Counter()
    for row in events.get("t", ()):
        if row[3] > lo and row[1] < hi:
            chats += turn_split(row, lo, hi)
    for run in runs:
        workers += run_split(run, lo, hi, suites, calls, events.get("h", ()))
        if not run.get("round"):
            own = run_split(run, float("-inf"), float("inf"), suites, (), ())
            start = num(run.get("pid_started_at")) or num(run.get("started_at"))
            jobs.append([start, start + own["slot"], run["ended_at"], own["suite_run"] + own["suite_wait"]])
    ids = {r.get("run") for r in runs}
    paid = [(min(r["seconds"], max(0.0, hi - r["started"])), r["caller"] in ids) for r in wait_rows(lo, hi)
            if r.get("class") in WAIT_CLASSES and r.get("caller")]
    total = chats + workers
    total["locks"] = min(sum(s for s, _ in paid), total["tools"])
    total["tools"] -= total["locks"]
    workers["locks"] = min(sum(s for s, worker in paid if worker), workers["tools"], total["locks"])
    workers["tools"] -= workers["locks"]
    hooks_by = collections.Counter()
    for h in events.get("h", ()):
        if lo <= h[1] < hi:
            hooks_by[h[3] + (":" + h[6] if h[6] else "")] += h[5] / 1000.0
    return {"lo": lo, "hi": hi, "seconds": {k: round(total[k], 1) for k, _, _ in CLASSES},
            "chat_s": round(sum(chats.values()), 1), "worker_s": round(sum(workers.values()), 1),
            "worker": {k: round(v, 1) for k, v in workers.items() if v}, "runs": len(runs), "jobs": jobs,
            "hooks_by": {k: round(v, 1) for k, v in hooks_by.most_common(8)}, "refusals": refusals(lo, hi)}


def shares(b):
    total = sum(b["seconds"].values())
    harness = sum(v for k, v in b["seconds"].items() if KIND[k] == "harness")
    return total, harness, (harness / total if total else 0.0)


# ---------------------------------------------------------------- tests


def tests_budget(lo, hi):
    """Suite hours by caller, slot wait against running, and the slowest suites by median seconds."""
    rows = suite_rows(lo, hi)
    by, wait, ran, per = collections.Counter(), 0.0, 0.0, collections.defaultdict(list)
    for r in rows:
        started = num(r.get("started_at")) or r["queued_at"]
        caller = "workers" if r.get("worker_run") else "chats" if r.get("session") else "night and others"
        w = max(0.0, min(started, hi) - max(r["queued_at"], lo))
        x = max(0.0, min(r["ended_at"], hi) - max(started, lo))
        by[caller] += w + x
        wait, ran = wait + w, ran + x
        for name, suite in (r.get("suites") or {}).items():
            if isinstance(suite, dict) and num(suite.get("secs")) is not None:
                per[name].append(suite["secs"])
    slow = sorted(((statistics.median(v), len(v), sum(v), k) for k, v in per.items()), reverse=True)[:TOP_SUITES]
    return {"runs": len(rows), "hours": round((wait + ran) / 3600.0, 2), "wait_h": round(wait / 3600.0, 2),
            "run_h": round(ran / 3600.0, 2), "wait_share": round(wait / (wait + ran), 3) if wait + ran else 0.0,
            "by_caller_h": {k: round(v / 3600.0, 2) for k, v in by.most_common()},
            "slowest": [{"suite": k, "median_s": round(m), "runs": n, "total_min": round(t / 60.0)} for m, n, t, k in slow]}


# ---------------------------------------------------------------- levers


def levers(events, lo, hi):
    """Where plain Claude Code itself could go faster, measured where the journals hold the data."""
    cw = cr = 0
    for row in events.get("t", ()):
        if lo <= row[1] < hi:
            for use in (row[10] or {}).values():
                cw, cr = cw + use[3], cr + use[4]
    by_session = collections.defaultdict(list)
    for c in events.get("c", ()):
        if lo <= c[1] < hi:
            by_session[c[8]].append((c[1], c[1] + c[5]))
    calls = overlapped = 0
    for spans in by_session.values():
        spans.sort()
        reach = float("-inf")
        for i, (a, b) in enumerate(spans):
            calls += 1
            if a < reach or (i + 1 < len(spans) and spans[i + 1][0] < b):
                overlapped += 1
            reach = max(reach, b)
    starts = [s for s in event_rows(lo, hi, ("s",)).get("s", ()) if lo <= s[1] < hi]
    out = [{"lever": "prompt-cache hits", "measured": bool(cw + cr),
            "value": "%d %% of cached input read from cache" % round(100.0 * cr / (cw + cr)) if cw + cr else None},
           {"lever": "parallel tool calls", "measured": bool(calls),
            "value": "%d %% of %d tool calls ran beside another" % (round(100.0 * overlapped / calls), calls) if calls else None},
           {"lever": "fewer process starts", "measured": bool(starts),
            "value": "%d CLI starts, %.1f min launching" % (len(starts), sum(num(s[4]) or 0 for s in starts) / 60.0)
            if starts else None},
           {"lever": "smaller context per turn", "measured": False, "value": None},
           {"lever": "fewer hook processes per tool call", "measured": False, "value": None}]
    return out


# ---------------------------------------------------------------- days, bands, holes


def day_cache_path(day):
    return os.path.join(harness_dir(), "budget-days", day + ".json")


def day_budget(day, now, store):
    """A day's budget, stored once the day ended a day ago: worker rows land when the run ends."""
    lo, hi = day_bounds(day)
    cached = read_json(day_cache_path(day), None)
    if isinstance(cached, dict) and cached.get("settled"):
        return cached
    found = budget(lo, min(hi, now))
    found.pop("jobs")
    found["settled"] = now >= hi + SETTLE_S
    if found["settled"] and store:
        write_json(day_cache_path(day), found)
    return found


def measured(b):
    """Days before measurement started are stored as zeros: no recorded time is no measurement, never a zero day."""
    return sum(b["seconds"].values()) > 0


def prune_days(now):
    cutoff = local_day(now - KEEP_DAYS * 86400)
    for path in glob.glob(os.path.join(harness_dir(), "budget-days", "????-??-??.json")):
        if os.path.basename(path)[:10] < cutoff:
            try:
                os.unlink(path)
            except OSError:
                pass


def usual(now, store):
    """Median seconds per class over the BAND_DAYS closed days before today that hold any time."""
    days, day = [], local_day(now)
    for back in range(1, BAND_DAYS + 1):
        b = day_budget(local_day(day_bounds(day)[0] - back * 86400 + 3600), now, store)
        if measured(b):
            days.append(b)
    med = {k: statistics.median([d["seconds"].get(k, 0) for d in days]) for k, _, _ in CLASSES} if days else {}
    return med, len(days)


def holes(b, med):
    """Named rows: workers under ACTIVE_FLOOR model time, and any class past BAND_RATIO x its usual day."""
    out = []
    w = b["worker"]
    wall = worker_wall(w)
    if wall >= BAND_MIN_S and w.get("model", 0) < ACTIVE_FLOOR * wall:
        tests = w.get("suite_run", 0) + w.get("suite_wait", 0)
        out.append("workers worked %d %% of their time; %d %% went to their own tests, %d %% to the slot queue"
                   % (pct(w.get("model", 0), wall), pct(tests, wall), pct(w.get("slot", 0), wall)))
    for key, label, kind in CLASSES:
        value, normal = b["seconds"].get(key, 0), med.get(key)
        if kind != "plain" and normal is not None and value >= BAND_MIN_S + normal and value > BAND_RATIO * normal:
            out.append("%s: %s, usually %s" % (label, minutes(value), minutes(normal)))
    return out


def worker_wall(worker):
    return sum(v for k, v in worker.items() if k not in ("bench", "walled"))


def suite_secs(r):
    repo = os.path.basename(str(r.get("repo_root") or r.get("repo") or "").rstrip("/"))
    return [((repo, name), s["secs"]) for name, s in (r.get("suites") or {}).items()
            if isinstance(s, dict) and num(s.get("secs"))]


def suite_floor(lo, hi):
    """{"chat"|"worker": the share of that caller's suite seconds in [lo, hi) left with every suite at its p10 wall
    over suite_audit's window, the cost a covering suite keeps on a quiet machine; its passing runs only, as a failed
    one may stop at its first check}."""
    walls, secs, floor = collections.defaultdict(list), collections.Counter(), collections.Counter()
    for r in suite_rows(hi - suite_audit.WINDOW_D * 86400, hi):
        for key, s in suite_secs(r):
            if r["suites"][key[1]].get("rc") == 0:
                walls[key].append(s)
    p10 = {k: sorted(v)[len(v) // 10] for k, v in walls.items()}
    for r in suite_rows(lo, hi):
        who = "worker" if r.get("worker_run") else "chat" if r.get("session") else None
        for key, s in suite_secs(r) if who else ():
            secs[who] += s
            floor[who] += min(s, p10.get(key, s))
    return {who: floor[who] / secs[who] for who in secs}


def burst_gain(burst):
    """Seconds sooner a burst of worker runs [start, first CLI start, end, own suite s] ends when a slot is held only
    outside the run's own suites: FIFO replays at the burst's peak concurrency, held against lent."""
    edges = sorted([(j[1], 1) for j in burst] + [(j[2], -1) for j in burst])
    slots = max(1, max(itertools.accumulate(d for _, d in edges)))
    ends = []
    for lent in (False, True):
        free, last = [float("-inf")] * slots, float("-inf")
        for start, first, end, suites in burst:
            at = max(start, heapq.heappop(free))
            heapq.heappush(free, at + end - first - (suites if lent else 0.0))
            last = max(last, at + end - first)
        ends.append(last)
    return max(0.0, ends[0] - ends[1])


def slot_gain(jobs):
    gain, burst = 0.0, []
    for job in sorted(jobs):
        if burst and job[0] >= max(j[2] for j in burst):
            gain, burst = gain + burst_gain(burst), []
        burst.append(job)
    return gain + (burst_gain(burst) if burst else 0.0)


def recoverable(b, lo, hi):
    """{class: (chat s, worker s)} over the class's floor: plain Claude Code has none of a harness class, suites keep
    their uncontended p10 wall, and the slot queue counts only the wall-clock lending slots during suites moves."""
    w = b["worker"]
    out = {k: (max(0.0, b["seconds"].get(k, 0) - w.get(k, 0)), w.get(k, 0)) for k in FLOORS}
    share = suite_floor(lo, hi)
    chat, worker = out["suite_run"]
    out["suite_run"] = (chat * (1 - share.get("chat", 1.0)), worker * (1 - share.get("worker", 1.0)))
    out["slot"] = (0.0, min(w.get("slot", 0), slot_gain(b["jobs"])))
    return out


def worker_floor(worker, rec, days):
    """Workers' model share of their wall (bench aside) against the share left once every part is at its floor; the
    parent's recoverable is the sum of its parts."""
    wall, model = worker_wall(worker), worker.get("model", 0)
    over = sum(w for _, w in rec.values())
    return {"share": round(model / wall, 3) if wall else None,
            "floor_share": round(model / (wall - over), 3) if wall > over else None,
            "recoverable_min_day": round(over / 60.0 / days, 1),
            "parts": {k: round(w / 60.0 / days, 1) for k, (_, w) in rec.items() if w}}


def floors_of(b, rec, days):
    return [{"class": k, "label": LABEL[k], "floor_min_day": FLOORS[k],
             "actual_min_day": round(b["seconds"].get(k, 0) / 60.0 / days, 1),
             "recoverable_min_day": round(sum(rec[k]) / 60.0 / days, 1),
             "chat_min_day": round(rec[k][0] / 60.0 / days, 1), "worker_min_day": round(rec[k][1] / 60.0 / days, 1)}
            for k in FLOORS]


def last_night():
    """The newest finished night's worker wall against its model time, from its cached ledger row when there is one."""
    nights = [read_json(p, {}) for p in glob.glob(os.path.join(night_churn.doctors_dir(), "nights", "*.json"))]
    nights = sorted((n for n in nights if n.get("finished_at") and n.get("started_at") and n.get("id")),
                    key=lambda n: (n["started_at"], n["id"]))
    if not nights:
        return None
    night = nights[-1]
    row = read_json(ledger_cache(night["id"]), None)
    split = row["split_s"] if isinstance(row, dict) and row.get("finished") and "split_s" in row else night_split(night)[1]
    wall, model = worker_wall(split), split.get("model", 0)
    return {"id": night["id"], "wall_s": round(wall), "model_s": round(model),
            "share": round(model / wall, 3) if wall else None}


def pct(part, whole):
    return round(100.0 * part / whole) if whole else 0


def minutes(secs, worker=False):
    m, (hour, minute) = secs / 60.0, ("w-h", "w-min") if worker else ("h", "min")
    return "%.1f %s" % (m / 60.0, hour) if m >= 120 else "%d %s" % (round(m), minute)


# ---------------------------------------------------------------- the day document


def problem_trend(now):
    rows = collector_runs.problem_days(local_day(now - (BAND_DAYS - 1) * 86400))
    out = collections.defaultdict(dict)
    for r in rows:
        out[r["doctor"]][r["day"]] = r["count"]
    return {d: dict(sorted(v.items())) for d, v in sorted(out.items())}


def document(now, hours=24.0, write=True):
    lo = now - hours * 3600
    events = event_rows(lo, now)
    b = budget(lo, now, events)
    med, covered = usual(now, write)
    med = {k: v * hours / 24.0 for k, v in med.items()}
    if write:
        prune_days(now)
    total, harness, share = shares(b)
    rows = [{"class": k, "label": label, "kind": kind, "min": round(b["seconds"][k] / 60.0, 1),
             "share": round(b["seconds"][k] / total, 3) if total else 0.0,
             "usual_min": round(med[k] / 60.0, 1) if k in med else None} for k, label, kind in CLASSES]
    doc = {"window_h": hours, "as_of_s": int(now), "total_min": round(total / 60.0, 1),
           "chat_min": round(b["chat_s"] / 60.0, 1), "worker_min": round(worker_wall(b["worker"]) / 60.0, 1),
           "bench_min": round(b["worker"].get("bench", 0) / 60.0, 1),
           "harness_min": round(harness / 60.0, 1), "harness_share": round(share, 3), "classes": rows,
           "hooks_by_min": {k: round(v / 60.0, 1) for k, v in b["hooks_by"].items()}, "refusals": b["refusals"],
           "worker_runs": b["runs"], "band_days": covered, "holes": holes(b, med),
           "tests": tests_budget(lo, now), "levers": levers(events, lo, now), "problems_by_day": problem_trend(now)}
    days, rec = hours / 24.0, recoverable(b, lo, now) if measured(b) else {}
    doc["floors"] = floors_of(b, rec, days) if rec else []
    doc["lost_min_day"] = round(sum(sum(v) for v in rec.values()) / 60.0 / days, 1) if rec else None
    doc["workers_active"] = worker_floor(b["worker"], rec, days)
    doc["last_night"] = last_night()
    doc["lines"] = plain_lines(doc)
    return doc


def plain_lines(doc):
    """The compact block in plain words the menu can show; its first line is the headline."""
    if not doc["total_min"]:
        return ["Harness time: nothing measured in the last %d h" % doc["window_h"]]
    top = sorted((r for r in doc["classes"] if r["kind"] == "harness" and r["min"] >= 1), key=lambda r: -r["min"])[:4]
    lines = ["Without the harness ≈ %d %% faster: %s of %s in %d h" % (
        round(100 * doc["harness_share"]), minutes(doc["harness_min"] * 60), minutes(doc["total_min"] * 60),
        doc["window_h"]),
        "Chats %s · workers %s" % (minutes(doc["chat_min"] * 60), minutes(doc["worker_min"] * 60, True))
        + (" · bench %s" % minutes(doc["bench_min"] * 60, True) if doc["bench_min"] else "")]
    gaps = sorted((f for f in doc["floors"] if f["chat_min_day"] >= 1), key=lambda f: -f["chat_min_day"])
    lines.append("Over the floor: chats %s/day" % minutes(sum(f["chat_min_day"] for f in doc["floors"]) * 60)
                 + "".join(" · %s %s" % (f["label"], minutes(f["chat_min_day"] * 60)) for f in gaps[:3]))
    active = doc["workers_active"]
    if active["share"] is not None:
        parts = sorted(((v, LABEL[k]) for k, v in active["parts"].items() if v >= 1), reverse=True)
        lines.append("Workers active %d %% of their wall (floor %s) · over it %s/day" % (
            round(100 * active["share"]), "–" if active["floor_share"] is None else "%d %%" % round(
                100 * active["floor_share"]), minutes(active["recoverable_min_day"] * 60, True))
            + "".join(" · %s %s" % (label, minutes(v * 60, True)) for v, label in parts[:3]))
    if top:
        lines.append("Harness: " + " · ".join("%s %s%s" % (r["label"], minutes(r["min"] * 60), "" if r["usual_min"] is None
                                                             else " (usually %s)" % minutes(r["usual_min"] * 60))
                                             for r in top))
    plain = [r for r in doc["classes"] if r["kind"] == "plain" and r["min"] >= 1]
    if plain:
        lines.append("Claude Code itself: " + " · ".join("%s %s" % (r["label"], minutes(r["min"] * 60)) for r in plain))
    t = doc["tests"]
    if t["runs"]:
        lines.append("Tests: %.1f h in %d suite runs, %d %% waiting for a slot" % (
            t["hours"], t["runs"], round(100 * t["wait_share"])))
    lines += ["Hole: " + h for h in doc["holes"]]
    return lines


def section(now, write=True):
    """The Harness document's `budget` key and budget.txt, the block the menu can show."""
    try:
        doc = document(now, write=write)
    except Exception as exc:  # noqa: BLE001 - measurement never fails the doctor that carries it
        return {"error": "%s: %s" % (type(exc).__name__, str(exc)[:200])}
    if write:
        write_block(doc)
    return doc


def write_block(doc):
    try:
        os.makedirs(harness_dir(), exist_ok=True)
        with open(os.path.join(harness_dir(), "budget.txt.tmp"), "w") as handle:
            handle.write("\n".join(doc["lines"]) + "\n")
        os.replace(os.path.join(harness_dir(), "budget.txt.tmp"), os.path.join(harness_dir(), "budget.txt"))
    except OSError:
        pass


def print_day(doc):
    print("\n".join(doc["lines"]))
    print("classes · " + " · ".join("%s %s (%d %%)" % (r["label"], minutes(r["min"] * 60), round(100 * r["share"]))
                                     for r in doc["classes"] if r["min"]))
    if doc["hooks_by_min"]:
        print("hooks by event · " + " · ".join("%s %s" % (k, minutes(v * 60)) for k, v in doc["hooks_by_min"].items()))
    print("gates · %d refusals (their time is inside hooks and the turns after)" % doc["refusals"])
    for s in doc["tests"]["slowest"]:
        print("slow suite · %s · median %d s · %d runs · %d min" % (s["suite"], s["median_s"], s["runs"], s["total_min"]))
    for lever in doc["levers"]:
        print("lever · %s · %s" % (lever["lever"], lever["value"] if lever["measured"] else "idea, not measured"))
    for doctor, days in doc["problems_by_day"].items():
        print("problems · %s · %s" % (doctor, " ".join("%s:%s" % (d[5:], n) for d, n in days.items())))


# ---------------------------------------------------------------- nights


def night_split(night):
    """Wall and its split over the worker runs the night's sessions launched (night_spend's selection)."""
    low, high, sessions = night_spend.window(night)
    runs = []
    for run, _, meta, _ in night_spend.night_runs(low, high, sessions):
        runs.append(dict(meta, run=run, round=meta.get("review_round"), walled=meta.get("walled_accounts")))
    hi = max([num(r.get("ended_at")) or 0 for r in runs] + [high])
    events = event_rows(low, hi, ("c", "h"))
    suites = suite_rows(low, hi + 86400)
    calls = [c for c in events.get("c", ()) if c[6] == "w"]
    split = collections.Counter()
    for run in runs:
        split += run_split(run, low, hi, suites, calls, events.get("h", ()))
    return len(runs), split


def lines_of(night):
    """Code and test lines of the night's job commits, and of other commits landed on the sweep repos' HEAD in the
    night's window."""
    low, high, _ = night_spend.window(night)
    jobs = {(night_churn.repo_dir(c.get("repo") or ""), str(c.get("hash") or "")[:7])
            for j in night.get("jobs") or () for c in j.get("commits") or ()}
    out = {"jobs": [0, 0, 0, 0], "other": [0, 0, 0, 0], "unreadable": 0}
    for repo in handoffs.sweep_repos():
        found = subprocess.run(["git", "-C", repo, "log", "--no-merges", "--first-parent", "--format=@%h",
                                "--numstat", "--since=@%d" % low, "--until=@%d" % high, "HEAD"],
                               capture_output=True, text=True, errors="replace")
        if found.returncode != 0:
            continue
        which = None
        for line in found.stdout.splitlines():
            if line.startswith("@"):
                which = "jobs" if (repo, line[1:8]) in jobs else "other"
                continue
            parts = line.split("\t")
            if which and len(parts) == 3 and parts[0] != "-":
                test = is_test(parts[2])
                out[which][2 * test] += int(parts[0])
                out[which][2 * test + 1] += int(parts[1])
    for j in night.get("jobs") or ():
        for c in j.get("commits") or ():
            if night_churn.repo_dir(c.get("repo") or "") is None:
                out["unreadable"] += 1
    return out


def is_test(path):
    return "/tests/" in "/" + path or os.path.basename(path).startswith("test_")


def improvement_class(rule, pid):
    """The time class a Speed or time row's fix should shrink; None measures the harness total."""
    ident = pid.split(":", 1)[1] if ":" in pid else ""
    if rule == spend_block.RULE:
        return pid
    if rule == "time_floor" or ident.startswith("time/"):
        key = ident[5:] if ident.startswith("time/") else ident
        return key if key in FLOORS else None
    if ident.startswith(("chat/hooks", "hooks/")):
        return "hooks"
    if ident.startswith(("chat/tests", "tests/")) or rule.startswith("test_") or rule == suite_audit.RULE:
        return "suite_run"
    return "suite_wait" if ident.startswith("chat/queue") else None


def improvements(night, path, worker_run):
    """Fixer jobs whose problem is a Speed or time row, with their weighted spend and changed lines."""
    found = night_churn.fixer_spend(night, path, worker_run)
    if not found:
        return []
    jobs, records, spend, _ = found
    out = []
    for job in jobs:
        rows = [p for p in (records.get(job["ref"]) or {}).get("problems") or () if isinstance(p, dict)
                and (p.get("rule") in IMPROVEMENT_RULES or str(p.get("rule") or "").startswith("test_"))]
        if not rows:
            continue
        lines, files = job_changes(job)
        out.append({"ref": job["ref"], "ids": [p.get("id") for p in rows],
                    "class": improvement_class(str(rows[0].get("rule") or ""), str(rows[0].get("id") or "")),
                    "spend_m": round(night_spend.weighted(spend[job["ref"]]) / 1e6, 1), "lines": lines,
                    "files": files, "merged": job.get("state") == "merged"})
    return out


def job_changes(job):
    """The +/- lines of a job's commits and the [repo, path] of each file they changed, None once a commit is
    unreadable."""
    lines, files = [0, 0], []
    for commit in job.get("commits") or ():
        repo = night_churn.repo_dir(commit.get("repo") or "")
        shown = subprocess.run(["git", "-C", repo, "show", "--format=", "--numstat", str(commit.get("hash"))],
                               capture_output=True, text=True, errors="replace") if repo else None
        if not shown or shown.returncode != 0:
            files = None
            continue
        for line in shown.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 3:
                files = None if files is None else files + [[commit.get("repo"), parts[2]]]
                if parts[0] != "-":
                    lines = [lines[0] + int(parts[0]), lines[1] + int(parts[1])]
    return lines, files


def unit_names(item):
    """The suites (repo/label) or hooks a fix's problem ids name; none measures its whole class."""
    named = set()
    for ident in item.get("ids") or ():
        if item["class"] == "suite_run":
            found = re.fullmatch(r"(?:test_\w+|%s):([\w.-]+):([\w.-]+)|opportunity:tests/([\w.-]+)/([\w.-]+)"
                                 % suite_audit.RULE, str(ident))
            if found:
                named.add("%s/%s" % (found.group(1) or found.group(3), found.group(2) or found.group(4)))
        elif item["class"] in ("hooks", "stop"):
            found = re.fullmatch(r"\w+:hooks/(.+)", str(ident))
            if found:
                named.add(found.group(1))
    return named


def hook_key(command):
    word, _, rest = command.partition(" ")
    return (os.path.basename(word) + " " + rest).strip()


def runtime_change(item):
    """Whether a fix's commits changed code its measured unit runs: never by ledgers, docs, the measurers (their
    baselines and windows) or tests, save a suite unit's own suite and test helpers; None when its files are unknown.
    A unit's measurer is runtime only for that measurer's own suite."""
    files = item.get("files")
    if files is None:
        return None
    suites = {k.split("/", 1)[1] for k in unit_names(item)} if item["class"] == "suite_run" else set()
    for _, path in files:
        base = os.path.basename(path)
        stem = os.path.splitext(base)[0]
        if path.endswith(".md") or path.startswith("docs/") or (base.endswith(".json") and "ledger" in base):
            continue
        if path in MEASURERS and "test_" + stem.replace("-", "_") not in suites:
            continue
        if is_test(path) and (item["class"] != "suite_run" or suites and base.startswith("test_")
                              and stem not in suites):
            continue
        return True
    return False


def class_min_day(day, key, now):
    b = day_budget(day, now, True)
    if not b.get("settled") or not measured(b):
        return None
    seconds = b["seconds"].get(key, 0) if key else sum(v for k, v in b["seconds"].items() if KIND.get(k) == "harness")
    return seconds / 60.0


def saved_min_day(item, landed, now):
    """Minutes per day the class lost after a full day of the change against up to ROI_DAYS days before it:
    None while pending, UNMEASURED once settled days exist but no measured one on a side, a number otherwise
    (<= 0 is spend without result)."""
    day = local_day(landed)
    before = [class_min_day(local_day(day_bounds(day)[0] - back * 86400 + 3600), item["class"], now)
              for back in range(1, ROI_DAYS + 1)]
    after, start = [], day_bounds(day)[1]
    while len(after) < ROI_DAYS and start + 86400 + SETTLE_S <= now:
        after.append(class_min_day(local_day(start + 3600), item["class"], now))
        start += 86400
    if not after:
        return None
    before, after = [v for v in before if v is not None], [v for v in after if v is not None]
    if not after or not before:
        return UNMEASURED
    return round(statistics.mean(before) - statistics.mean(after), 1)


def unit_samples(item, lo, hi):
    """{key: [values]} of the class's natural unit in [lo, hi): per suite (repo/label), per hook (its script's base
    name and arguments), per wait class."""
    if item["class"] == "suite_run":
        return suite_audit.samples(suites_path(), lo, hi)
    out = collections.defaultdict(list)
    if item["class"] in ("hooks", "stop"):
        for h in event_rows(lo, hi, ("h",)).get("h", ()):
            if len(h) > 5 and lo <= h[1] < hi and num(h[5]) is not None and (h[3] == "Stop") == (item["class"] == "stop"):
                out[hook_key(str(h[4]))].append(h[5])
    for w in wait_rows(lo, hi) if item["class"] in WAIT_OF else ():
        if w.get("class") in WAIT_OF[item["class"]]:
            out[w["class"]].append(w["seconds"])
    return out


def unit_gone(item, named, after, need, ended, now):
    """A named suite whose file left its repository, or a named hook absent a full day after the night while others
    ran."""
    if item["class"] == "suite_run":
        for key in named:
            repo = night_churn.repo_dir(key.split("/", 1)[0])
            if not repo or any(os.path.isfile(os.path.join(repo, "tests", key.split("/", 1)[1] + ext))
                               for ext in (".sh", ".py")):
                return False
        return True
    return (now - ended >= 86400 and not any(after.get(k) for k in named)
            and sum(len(v) for v in after.values()) >= need)


def unit_proof(item, started, ended, now):
    """A landed improvement whose class has a natural unit, proven from the journals once N samples follow the night:
    the medians per key (the keys its ids name, else every suite, hook script or wait class) before the night and
    after it, weighted by the samples after it, so a changed mix of suites or hooks reads as no gain. A proven gain
    sums, over the keys proven on their own, the key's delta times its daily exposure since the night. No sample
    before the night keeps the day totals; a named unit that no longer exists is `gone`."""
    unit = UNITS.get(item["class"])
    if not unit:
        return None
    label, need, ratio, daily, scale = unit
    named = unit_names(item)
    before = unit_samples(item, started - UNIT_BEFORE_DAYS * 86400, started)
    after = unit_samples(item, ended, now)
    if named:
        if unit_gone(item, named, after, need, ended, now):
            return {"proven": False, "gone": True, "text": "%s no longer exists" % ", ".join(sorted(named))}
        before, after = ({k: v for k, v in d.items() if k in named} for d in (before, after))
    if not any(before.values()):
        return None
    keys = [k for k, v in after.items() if len(v) >= need and before.get(k)]
    if not keys:
        return {"proven": None, "text": "%s: %d of %d since" % (
            label, max((len(v) for v in after.values()), default=0), need)}
    weight = {k: len(after[k]) for k in keys}
    total = float(sum(weight.values()))
    was = sum(weight[k] * statistics.median(before[k]) for k in keys) / total
    now_ = sum(weight[k] * statistics.median(after[k]) for k in keys) / total
    proven = now_ <= ratio * was
    days = max(1.0, (now - ended) / 86400.0)
    gain = round(sum((statistics.median(before[k]) - statistics.median(after[k])) * weight[k] for k in keys
                     if statistics.median(after[k]) <= ratio * statistics.median(before[k])) / days / scale,
                 1) if proven else 0.0
    span = "%s → %s %s" % (suite_audit.fmt(was), suite_audit.fmt(now_), label)
    return {"proven": proven, "before": round(was, 2), "after": round(now_, 2), "samples": int(total), "span": span,
            "gain": gain, "daily": daily,
            "text": "%s · %s" % (span, "proven · %.1f %s" % (gain, daily) if proven else "not proven")}


def spend_proofs():
    doc = read_json(os.path.join(harness_dir(), "latest.json"), None)
    found = (((doc or {}).get("speed") or {}).get("spend") or {}).get("proofs") if isinstance(doc, dict) else None
    return found if isinstance(found, dict) else {}


def timed(row):
    return [i for i in row.get("improvements") or () if not (i["class"] or "").startswith("spend:")]


def gained(minutes, other):
    """Wall minutes a day, then each gain in its own unit (CPU-min/day), never folded into the minutes."""
    return "gained %.1f min/day" % minutes + "".join(" · %.1f %s" % (v, k) for k, v in sorted(other.items()) if v)


def plural(n, word, many):
    return " · %d %s" % (n, word if n == 1 else many) if n else ""


def roi_lines(rows, now):
    """Per improvement job of the night, per night, and cumulative over the trend: weighted spend against the
    minutes per day saved once the change ran a full day, or, for a class with a natural unit, its per-unit proof
    times the unit's daily exposure since the night, in the unit's own daily measure. A fix that changed no code its
    unit runs (`runtime_change`), or whose named unit no longer exists, is a measurement fix and never a gain. No gain
    reads 'spend without result', never a revert. A Spend audit reads its proof from Harness's latest.json instead
    and stays out of the minute totals."""
    out, total_spend, total_saved, total_proven, measured, proofs = [], 0.0, 0.0, 0, 0, None
    total_other = collections.Counter()
    for row in (r for r in rows if r):
        spend = saved = 0.0
        pending = unmeasured = proven = fixes = 0
        other = collections.Counter()
        for item in row.get("improvements") or ():
            if (item["class"] or "").startswith("spend:"):
                if row is rows[-1]:
                    if proofs is None:
                        proofs = spend_proofs()
                    out.append("roi · %s · %s · %.1fM · %+d/-%d lines · %s" % (
                        item["ref"][:40], item["class"][6:], item["spend_m"], item["lines"][0], item["lines"][1],
                        spend_block.proof_text(proofs.get(item["class"][6:]))
                        if item["merged"] else "not landed"))
                continue
            ended = row.get("ended") or row["started"] + row["hours"] * 3600
            what = ", ".join(sorted(unit_names(item))) or LABEL.get(item["class"], "harness total")
            change = runtime_change(item) if item["merged"] else None
            shown = unit_proof(item, row["started"], ended, now) if item["merged"] else None
            if change is False or shown and shown.get("gone") and not change:
                spend, fixes = spend + item["spend_m"], fixes + 1
                if row is rows[-1]:
                    out.append("roi · %s · %s · %.1fM · %+d/-%d lines · %smeasurement fix" % (
                        item["ref"][:40], what, item["spend_m"], item["lines"][0], item["lines"][1],
                        shown["span"] + " · " if shown and "span" in shown else ""))
                continue
            if shown and not shown.get("gone"):
                if shown["proven"] is None:
                    pending += 1
                else:
                    spend, measured, proven = spend + item["spend_m"], measured + 1, proven + shown["proven"]
                    if shown["daily"] == "min/day":
                        saved += shown["gain"]
                    else:
                        other[shown["daily"]] += shown["gain"]
                if row is rows[-1]:
                    out.append("roi · %s · %s · %.1fM · %+d/-%d · %s" % (
                        item["ref"][:40], what, item["spend_m"], item["lines"][0], item["lines"][1], shown["text"]))
                continue
            gain = saved_min_day(item, ended, now) if item["merged"] else None
            if gain == UNMEASURED:
                unmeasured += 1
            else:
                spend += item["spend_m"]
            if gain is None:
                pending += item["merged"]
            elif gain != UNMEASURED:
                saved += gain
                measured += 1
            if row is rows[-1]:
                out.append("roi · %s · %s · %.1fM · %+d/-%d lines · %s" % (
                    item["ref"][:40], what, item["spend_m"], item["lines"][0],
                    item["lines"][1], "not landed" if not item["merged"] else "pending a full day" if gain is None
                    else "unmeasured before or after it" if gain == UNMEASURED
                    else "saves %.1f min/day" % gain if gain > 0 else "spend without result"))
        if row is rows[-1] and timed(row):
            out.append("roi · night: improvements %.1fM · %s%s%s%s%s" % (
                spend, gained(saved, other), plural(proven, "proven per unit", "proven per unit"),
                plural(fixes, "measurement fix", "measurement fixes"),
                " · %d pending" % pending if pending else "", " · %d unmeasured" % unmeasured if unmeasured else ""))
        total_spend, total_saved, total_proven = total_spend + spend, total_saved + saved, total_proven + proven
        total_other.update(other)
    if any(r and timed(r) for r in rows):
        out.append("roi · last %d nights: improvements %.1fM · %s%s" % (
            len([r for r in rows if r]), total_spend, gained(total_saved, total_other),
            "" if not total_spend and not total_saved
            else " · nothing measured yet" if not measured
            else " · %d proven per unit" % total_proven if total_proven and not total_saved
            else " · spend without result so far" if not total_saved
            else " · %.1f min/day per 1M" % (total_saved / total_spend) if total_spend else ""))
    return out


def ledger_row(worker_run, path, night):
    low, high, _ = night_spend.window(night)
    n_runs, split = night_split(night)
    wall = sum(split.values())
    touched = night_churn.problem_counts(night, path)
    rewrite = night_churn.rewrite_counts(night)
    states = night.get("doctor_states_after") or {}
    debt = [j for j in night.get("jobs") or () if j.get("kind") == "debt"]
    spent = night_spend.spend(night, worker_run)
    return {"id": night.get("id"), "started": low, "ended": high, "hours": round((high - low) / 3600.0, 1),
            "finished": bool(night.get("finished_at")), "runs": n_runs, "wall_s": round(wall),
            "split_s": {k: round(v) for k, v in split.items() if v},
            "lines": lines_of(night),
            "rewrite": list(rewrite[:2]) if rewrite else None,
            "problems": [sum(v for v in (night.get("doctors_before") or {}).values() if isinstance(v, int)),
                         sum(v for v in (night.get("doctors_after") or {}).values() if isinstance(v, int))
                         if night.get("doctors_after") else None],
            "proved": sum((s or {}).get("proved", 0) for s in states.values()),
            "regressed": sum((s or {}).get("regressed", 0) for s in states.values()),
            "touched_unproven": len(touched[0]) if touched else 0,
            "spend_m": round(spent["total"] / 1e6, 1), "spend_kinds": spend_kinds(spent),
            "improvements": improvements(night, path, worker_run),
            "deferred": "no debt round" if not debt else (
                "debt round %s" % debt[0].get("state") if all(j.get("state") != "merged" for j in debt) else None)}


def ledger_cache(id_, night_path=None):
    return os.path.join(night_churn.doctors_dir(night_path), "night-ledger", id_ + ".json")


def cached_row(worker_run, path):
    night = read_json(path, {})
    if not night.get("id") or not night.get("started_at"):
        return None
    row = read_json(ledger_cache(night["id"], path), None)
    if isinstance(row, dict) and row.get("finished"):
        stale = [i for i in row.get("improvements") or () if "files" not in i]
        if stale:
            jobs = {j.get("ref"): j for j in night.get("jobs") or ()}
            for item in stale:
                item["files"] = job_changes(jobs.get(item["ref"]) or {"commits": [{}]})[1]
            write_json(ledger_cache(night["id"], path), row)
        return row
    row = ledger_row(worker_run, path, night)
    if row["finished"]:
        write_json(ledger_cache(night["id"], path), row)
    return row


def model_share(row):
    return "%d %%" % pct(row["split_s"].get("model", 0), row["wall_s"]) if row["wall_s"] else "?"


def ledger_lines(row):
    """The night's ledger, each line under the report's 100 columns."""
    s = {k: v / 3600.0 for k, v in row["split_s"].items()}
    tests = s.get("suite_run", 0) + s.get("suite_wait", 0)
    jobs, other = row["lines"]["jobs"], row["lines"]["other"]
    probs = row["problems"]
    out = ["night %s · %.1f h" % (row["id"], row["hours"]),
           "workers %.1f h wall · model %.1f h (%s) · queued %.1f h · own tests %.1f h" % (
               row["wall_s"] / 3600.0, s.get("model", 0), model_share(row), s.get("slot", 0), tests)
           if row["wall_s"] else "workers %d runs, not timed" % row["runs"],
           "lines by jobs: code +%d/-%d · tests +%d/-%d · outside jobs +%d/-%d" % (
               tuple(jobs) + (other[0] + other[2], other[1] + other[3]))]
    if row["rewrite"]:
        out.append("rewrote %d of %d week-old lines" % tuple(row["rewrite"]))
    out.append("problems %s → %s · proved %d · regressed %d · touched again without proof %d" % (
        probs[0], "?" if probs[1] is None else probs[1], row["proved"], row["regressed"], row["touched_unproven"]))
    out.append("spend %.1fM" % row["spend_m"] + (" · deferred: %s" % row["deferred"] if row["deferred"] else ""))
    return ["ledger · " + line for line in out]


def trend_lines(rows):
    rows = [r for r in rows if r]
    if not rows:
        return []
    out = ["trend · last %d nights · oldest first" % len(rows)]
    for r in rows:
        probs = r["problems"]
        out.append("trend · %s · %.1f h · workers %s model · problems %s → %s · spend %.1fM%s" % (
            time.strftime("%d %b", time.localtime(r["started"])), r["hours"], model_share(r),
            probs[0], "?" if probs[1] is None else probs[1], r["spend_m"], " · deferred" if r["deferred"] else ""))
    moved = [r for r in rows if r["problems"][0] is not None and r["problems"][1] is not None]
    if moved:
        first, last = moved[0]["problems"][0], moved[-1]["problems"][1]
        out.append("trend · problems %d → %d over %d nights · %s" % (
            first, last, len(moved), "moving forward" if last < first else "treading water" if last == first
            else "going back"))
    return out


def nights_upto(path):
    """(started_at, path, night) of each night up to the one at path, oldest first."""
    night = read_json(path, {})
    out = []
    for other in sorted(glob.glob(os.path.join(os.path.dirname(path), "*.json"))):
        candidate = read_json(other, {})
        if candidate.get("started_at") and (candidate["started_at"], candidate.get("id", "")) <= (
                night.get("started_at", ""), night.get("id", "")):
            out.append((candidate["started_at"], other, candidate))
    return sorted(out, key=lambda n: n[:2])


def night_report(worker_run, path):
    trend = [cached_row(worker_run, p) for _, p, _ in nights_upto(path)[-BAND_DAYS:]]
    if trend and trend[-1]:
        print("\n".join(ledger_lines(trend[-1])))
    for line in trend_lines(trend) + roi_lines(trend, now_s()):
        print(line)


def spend_kinds(spent):
    return {kind: round(night_spend.weighted(total) / 1e6, 1) for kind, total in spent["kinds"].items()}


def table_column(worker_run, path, night):
    """(label, value) of each comparison row; a value with no source is a dash."""
    dash = "\u2013"
    row = cached_row(worker_run, path) or {}
    kinds = row.get("spend_kinds")
    if row and kinds is None:
        live = night_spend.spend(night, worker_run)
        kinds = spend_kinds(live) if round(live["total"] / 1e6, 1) == row.get("spend_m") else {}
    kinds = kinds or {}
    states = collections.Counter(j.get("state") for j in night.get("jobs") or ())
    split, wall, runs = row.get("split_s") or {}, row.get("wall_s") or 0, row.get("runs")
    timed = row and (wall or not runs)
    hours = lambda s: "%.1f h" % (s / 3600.0) if timed else dash
    before, after = night.get("doctors_before") or {}, night.get("doctors_after") or {}
    jobs_lines = (row.get("lines") or {}).get("jobs")
    suites = night.get("suites") or {}
    repos = suites.get("repos") or []
    show = lambda v, f="%s": dash if v is None else f % v
    doctors = ("llm", "harness", "updater", "code", "system")
    problems = row.get("problems") or [None, None]
    return [
        ("duration", show(row.get("hours"), "%.1f h")),
        ("spend", show(row.get("spend_m"), "%.1fM")),
        ("  fixers", show(kinds.get("fixers"), "%.1fM")),
        ("  reviews", show(kinds.get("reviews"), "%.1fM")),
        ("  night chat", show(kinds.get("orchestrator"), "%.1fM")),
        ("landed", str(states["merged"])),
        ("left", str(states["left"])),
        ("needs Egor", str(states["blocked-on-egor"])),
        ("worker runs", show(runs)),
        ("worker wall", hours(wall)),
        ("model active", "%d %%" % pct(split.get("model", 0), wall) if wall else dash),
        ("slot queue", hours(split.get("slot", 0))),
        ("own tests", hours(split.get("suite_run", 0) + split.get("suite_wait", 0))),
        ("problems", dash if problems == [None, None]
         else "%s \u2192 %s" % (show(problems[0]), show(problems[1]))),
    ] + [
        ("  " + d, dash if before.get(d) is None and after.get(d) is None
         else "%s \u2192 %s" % (show(before.get(d)), show(after.get(d))))
        for d in doctors
    ] + [
        ("job lines", "+%d/-%d" % (jobs_lines[0] + jobs_lines[2], jobs_lines[1] + jobs_lines[3])
         if jobs_lines else dash),
        ("rewrote 7d", show((row.get("rewrite") or [None])[0])),
        ("suites \u2713/\u2717", "%d/%d" % (sum(r["passed"] for r in repos), sum(len(r.get("failed") or ()) for r in repos))
         if suites.get("finished_at") and all(isinstance(r.get("passed"), int) for r in repos) else dash),
    ]


def table_lines(worker_run, path):
    """This night against the two previous finished nights with jobs, oldest left, a column per night."""
    *older, current = nights_upto(path)
    nights = [n for n in older if n[2].get("finished_at") and n[2].get("jobs")][-2:] + [current]
    day = lambda n, f: time.strftime(f, time.localtime(night_spend.epoch(n[0]))).lstrip("0")
    heads = [day(n, "%d %b") for n in nights]
    if len(set(heads)) < len(heads):
        heads = [day(n, "%d %b %H:%M") for n in nights]
    columns = [table_column(worker_run, p, night) for _, p, night in nights]
    labels = [label for label, _ in columns[0]]
    width = max(len(label) for label in labels)
    widths = [max([len(head)] + [len(v) for _, v in column]) for head, column in zip(heads, columns)]
    out = [" " * width + "".join("   " + head.rjust(w) for head, w in zip(heads, widths))]
    for i, label in enumerate(labels):
        out.append(label.ljust(width) + "".join("   " + column[i][1].rjust(w) for column, w in zip(columns, widths)))
    return out


def main(argv):
    parser = argparse.ArgumentParser(prog="time_budget.py")
    sub = parser.add_subparsers(dest="command", required=True)
    day = sub.add_parser("day")
    day.add_argument("--hours", type=float, default=24.0)
    day.add_argument("--json", action="store_true")
    night = sub.add_parser("night")
    night.add_argument("worker_run")
    night.add_argument("path")
    table = sub.add_parser("table")
    table.add_argument("worker_run")
    table.add_argument("path")
    args = parser.parse_args(argv)
    if args.command == "night":
        night_report(args.worker_run, args.path)
        return 0
    if args.command == "table":
        print("\n".join(table_lines(args.worker_run, args.path)) + "\n")
        return 0
    doc = document(now_s(), args.hours, write=False)
    if args.json:
        print(json.dumps(doc, ensure_ascii=False, indent=1))
    else:
        print_day(doc)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
