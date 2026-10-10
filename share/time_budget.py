"""The harness time budget (docs/handoffs/2026-10-05-harness-time-budget.md): where the wall time of chats and
workers goes, plain Claude Code against each class the harness adds, with each class's usual band, the holes named
(test time is share/test_health.py's), an honest one-line-per-night ledger with its 7-night trend and the doctors' daily
problem counts. Measurement only: it reads existing journals and gates nothing.

  time_budget.py day [--hours H] [--json]       the last H hours (24), its bands, holes, tests and levers
  time_budget.py night <worker-run> <night.json> the night's ledger line, its time split and the 7-night trend
  time_budget.py table <worker-run> <night.json> the night against the two previous finished nights with jobs
"""

import argparse
import collections
import glob
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

CLASSES = (("suite_run", "suites running"), ("suite_wait", "suite slot wait"), ("slot", "worker slot queue"),
           ("wrapup", "worker wrap-up"), ("retries", "retries and relaunches"), ("dead", "dead worker runs"),
           ("hung", "watchdog-killed idle tails"), ("hooks", "hooks"), ("stop", "stop hooks"),
           ("refusal", "gate refusal recovery"), ("locks", "locks and polls"), ("walled", "usage-wall relaunches"),
           ("compaction", "compaction"), ("other", "unmeasured"))
LABEL = dict(CLASSES)
ROWS = (("tests", (("running", "suite_run"), ("queued", "suite_wait"))),
        ("delegation", (("worker queue", "slot"), ("wrap-up", "wrapup"), ("retries", "retries"),
                        ("dead, hung", "dead", "hung"))),
        ("harness rules", (("hooks", "hooks", "stop"), ("gate refusals", "refusal"), ("locks", "locks"))),
        ("usage walls", (("usage walls", "walled"),)), ("compaction", (("compaction", "compaction"),)),
        ("unmeasured", (("unmeasured", "other"),)))
UNPLACED = ("compaction", "other")
WATCHDOG_KILLS = ("idle", "silent")
WAIT_CLASSES = ("lock", "poll")
GATE_REFUSALS = ("denied", "relay-refused")
REFUSAL_CAP_S = 300
# A gate's recovery seconds a day swing to 0 and back on unchanged code (p5 of mean(3 days)/mean(5 before) is 0 over
# the events of 2026-10-01..09), so only a gate that cost nothing for a week after the night proves.
REFUSAL_PROOF_RATIO, REFUSAL_PROOF_DAYS = 0.0, 7
HISTORY_DAYS = 6
TREND_DAYS = 7
BUDGET_VERSION = 2
DEAD_LINE = re.compile(r"(?:(?:Failed to authenticate|Not logged in|You've hit your \w+ limit|API Error|Execution error|"
                       r"Request timed out|[A-Z]+_(?:FAILED|USAGE_LIMIT|UNAVAILABLE))\b|Error:)")
DEAD_LINE_MAX = 300
RESUME = re.compile(r"(?m)^RESUME ([0-9a-f][0-9a-f-]{7,})")
BENCH_WORKDIR = re.compile(r"/logo-vectorizer-bench(/|$)")
NIGHT_GAIN_MIN_DAY = 5
ROI_DAYS = 3
IMPROVEMENT_RULES = ("opportunity", "regression", "time_floor", spend_block.RULE, suite_audit.RULE)
# (unit, samples a side needs, the after/before ratio proving it, the gain's daily unit, units in one of it): the
# ratio is p5 of median(N)/median(the samples before) on unchanged code over the journals of 2026-09-29..10-07, so a
# lower ratio is no noise.
UNITS = {"suite_run": ("wall-s/run", suite_audit.PROOF_RUNS, suite_audit.PROOF_RATIO, "suite-min/day", 60.0),
         "hooks": ("ms/call", 50, 0.55, "min/day", 60000.0), "stop": ("ms/call", 50, 0.55, "min/day", 60000.0),
         "suite_wait": ("s/wait", 20, 0.4, "min/day", 60.0), "slot": ("s/wait", 20, 0.4, "min/day", 60.0),
         "locks": ("s/wait", 20, 0.4, "min/day", 60.0), "refusal": ("s/day", REFUSAL_PROOF_DAYS, REFUSAL_PROOF_RATIO, "min/day", 60.0)}
UNIT_STAT = {"refusal": statistics.mean}
MEASURERS = ("bin/harness-doctor", "bin/speed-doctor", "share/suite_audit.py", "share/time_budget.py")
WAIT_OF = {"suite_wait": ("run-suites",), "slot": ("workers", "review-cells"), "locks": WAIT_CLASSES}
UNIT_BEFORE_DAYS = 7
SETTLE_S = 24 * 3600
KEEP_DAYS = 35
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


def refusal_rows(lo, hi):
    rows = [r for r in night_spend.rows(gates_path()) if r.get("decision") in GATE_REFUSALS
            and lo <= (num(r.get("at")) or 0) < hi]
    journal = collections.defaultdict(list)
    for r in rows:
        journal[str(r.get("sid") or "")[:8]].append(r)
    seen = set()
    for path, (session, _) in handoffs.transcripts(lo).items():
        sid = session[:8]
        try:
            with open(path, errors="replace") as handle:
                for line in handle:
                    blocking = '"hook_blocking_error"' in line
                    if not blocking and ("PreToolUse:" not in line or "hook error:" not in line):
                        continue
                    try:
                        entry = json.loads(line)
                        at = night_spend.dt.datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00")).timestamp()
                    except (ValueError, KeyError, TypeError):
                        continue
                    if not lo <= at < hi:
                        continue
                    item = entry.get("attachment") if blocking else None
                    if isinstance(item, dict) and item.get("type") == "hook_blocking_error":
                        event = str(item.get("hookEvent") or "")
                        key = entry.get("uuid") or (sid, at, event)
                        if event == "PreToolUse" or key in seen:
                            continue
                        seen.add(key)
                        error = item.get("blockingError")
                        text = error.get("blockingError") if isinstance(error, dict) else error
                        match = re.match(r"\[([^\]]+)\]", text if isinstance(text, str) else "")
                        rows.append({"at": at, "sid": sid, "tool_use_id": "", "decision": "blocked", "event": event,
                                     "gate": os.path.basename(match[1]) if match else
                                     "unknown-%s-hook" % (event.lower() or "blocking")})
                        continue
                    content = (entry.get("message") or {}).get("content")
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_result" or not block.get("is_error"):
                            continue
                        body = block.get("content")
                        if isinstance(body, list):
                            body = "\n".join(b.get("text", "") for b in body if isinstance(b, dict))
                        if not isinstance(body, str):
                            continue
                        match = re.match(r"^PreToolUse:[\w]+ hook error: (?:\[([^\]]+)\])?", body)
                        if not match:
                            continue
                        tid = str(block.get("tool_use_id") or "")[-10:]
                        key = (sid, tid or at)
                        if key in seen:
                            continue
                        seen.add(key)
                        duplicates = [r for r in journal[sid] if not r.get("tool_use_id")
                                      and abs((num(r["at"]) or 0) - at) <= 2]
                        if duplicates:
                            min(duplicates, key=lambda r: abs(float(r["at"]) - at))["tool_use_id"] = tid
                            continue
                        gate = os.path.basename(match[1]) if match[1] else "unknown-hook"
                        rows.append({"at": at, "sid": sid, "tool_use_id": tid, "gate": gate, "decision": "denied"})
        except OSError:
            continue
    return rows


def refusal_cost(lo, hi, events, rows=None):
    """Recovery from each refusal (a PreToolUse denial, a Stop or PostToolUse block) to the session's next accepted
    call, else the end of the owner turn it fell in, capped; the next refusal of the session ends it too. Each gate's
    seconds and the total are unions of these spans, so a window several sessions or gates share counts once."""
    rows = refusal_rows(lo - REFUSAL_CAP_S, hi) if rows is None else rows
    calls, turns, refused = collections.defaultdict(list), collections.defaultdict(list), collections.defaultdict(set)
    for c in events.get("c", ()):
        calls[str(c[8])[:8]].append(c)
    for t in events.get("t", ()):
        turns[str(t[2])[:8]].append(t)
    denied = {(str(r.get("sid") or "")[:8], str(r.get("tool_use_id") or "")[-10:]) for r in rows}
    for r in rows:
        refused[str(r.get("sid") or "")[:8]].add(num(r.get("at")) or 0)
    by, missing, seen = collections.defaultdict(list), collections.Counter(), set()
    measured = 0
    for r in sorted(rows, key=lambda r: (num(r.get("at")) or 0, str(r.get("gate") or ""))):
        gate, at = r.get("gate") or "unknown", num(r.get("at")) or 0
        sid = str(r.get("sid") or "")[:8]
        following = [c[1] for c in calls[sid] if at < c[1] <= at + REFUSAL_CAP_S and (sid, c[7]) not in denied]
        turn = next((t[3] for t in turns[sid] if t[1] <= at < t[3]), None)
        ends = [x for x in (min(following) if following else None, turn) if x is not None]
        if not sid or not ends:
            if lo <= at < hi:
                missing[gate] += 1
            continue
        if (sid, at) in seen:
            continue
        seen.add((sid, at))
        ends += [a for a in refused[sid] if a > at] + [at + REFUSAL_CAP_S]
        by[gate] += clip([(at, min(ends))], lo, hi)
        measured += 1
    spans = union(x for v in by.values() for x in v)
    by_gate = sorted(((length(union(v)), gate) for gate, v in by.items()), key=lambda x: (-x[0], x[1]))
    return {"seconds": length(spans), "spans": spans, "by_gate_s": {gate: secs for secs, gate in by_gate},
            "measured": measured, "count": sum(lo <= r["at"] < hi for r in rows),
            "unmeasured_by_gate": dict(missing), "cap_s": REFUSAL_CAP_S}


def run_session(run):
    for name in ("session", "worker-session"):
        text = run_file(run, name)
        if text:
            return text.splitlines()[0][:8]
    return None


def run_file(run, name):
    try:
        with open(os.path.join(night_spend.RUNS, str(run), name), errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return None


def resumers(since):
    """{session prefix: [(start, run)]} of the runs touched since `since` that resumed it: a RESUME line in the
    brief or meta.json's resume."""
    out = collections.defaultdict(list)
    try:
        entries = list(os.scandir(night_spend.RUNS))
    except OSError:
        return out
    for entry in entries:
        try:
            touched = entry.stat().st_mtime
        except OSError:
            continue
        if touched < since:
            continue
        meta = read_json(os.path.join(entry.path, "meta.json"), {})
        meta = meta if isinstance(meta, dict) else {}
        named = RESUME.findall(run_file(entry.name, "brief") or "")
        if isinstance(meta.get("resume"), str) and meta["resume"]:
            named.append(meta["resume"])
        at = num(meta.get("pid_started_at")) or num(meta.get("started_at")) or touched
        for session in named:
            out[session[:8]].append((at, entry.name))
    return out


def dead_runs(runs):
    """Failed runs whose wall left nothing: no later run resumed their session, their files record names no path
    and no unknown or partial listing, nothing written outside it or produced, HEAD unmoved, and their result empty
    or only error and limit lines. A missing record is no proof."""
    failed = [r for r in runs if r.get("status") not in (None, "done") and not r.get("round")
              and not BENCH_WORKDIR.search(str(r.get("workdir") or ""))]
    if not failed:
        return set()
    starts = {r.get("run"): num(r.get("pid_started_at")) or num(r.get("started_at")) or 0.0 for r in failed}
    later, out = resumers(min(starts.values())), set()
    for r in failed:
        run = str(r.get("run"))
        sessions = {(run_file(run, name) or "")[:8] for name in ("session", "worker-session")} - {""}
        if any(at > starts[r.get("run")] and name != run for s in sessions for at, name in later.get(s, ())):
            continue
        files = run_file(run, "files")
        if files is None or any(not line.startswith("WORKDIR: ") for line in files.splitlines() if line):
            continue
        if run_file(run, "files-external") or run_file(run, "produced"):
            continue
        if run_file(run, "head-before") != run_file(run, "head-after"):
            continue
        result = [line.strip() for line in (run_file(run, "result") or "").splitlines() if line.strip()]
        if all(len(line) <= DEAD_LINE_MAX and DEAD_LINE.match(line) for line in result):
            out.add(run)
    return out


# ---------------------------------------------------------------- the split


def run_split(run, lo, hi, suites, calls):
    """One worker run's spans inside [lo, hi) per class: launch -> first CLI start is the slot queue, earlier attempts
    are retries, or a walled run's usage-wall relaunches (weather, neither work nor retries); the last CLI's exit -> the
    run's end is its wrap-up (file attribution, anchors, the result); the last attempt is split into the idle tail a
    watchdog killed it after, its own suites (slot wait apart), its tool calls and the rest, which is model time, or is
    dead whole for a run `dead_runs` marked; a run with no session file names no calls, so its rest is `other`. A bench
    worker (the owner's benchmark) is its own class whole. `started_at` is restamped by the slot wait, so the run starts
    at its pid."""
    start = num(run.get("pid_started_at")) or num(run.get("started_at"))
    end = num(run.get("ended_at"))
    out = collections.defaultdict(list)
    if start is None or end is None or end <= start:
        return out
    clis = [num(c) for c in run.get("cli_starts") or () if num(c)] or [num(run.get("started_at")) or start]
    first, last = max(start, min(clis[0], end)), max(start, min(clis[-1], end))
    if BENCH_WORKDIR.search(str(run.get("workdir") or "")):
        out["bench"] = clip([(start, end)], lo, hi)
        return out
    out["slot"] = clip([(start, first)], lo, hi)
    out["walled" if run.get("walled") else "retries"] = clip([(first, last)], lo, hi)
    secs = run.get("attempt_secs") or ()
    exited = min(end, max(last, last + num(secs[-1]))) if len(secs) == len(clis) and num(secs[-1]) else end
    out["wrapup"] = clip([(exited, end)], lo, hi)
    work = clip([(last, exited)], lo, hi)
    if run.get("dead"):
        out["dead"] = work
        return out
    kill = (run_file(run.get("run"), "killed") or "").split() if run.get("reason") in WATCHDOG_KILLS else []
    if kill and kill[0] in WATCHDOG_KILLS:
        idle = float(kill[1]) if kill[0] == "idle" and kill[1:2] and kill[1].isdigit() else None
        if kill[0] == "silent" or idle:
            out["hung"] = clip([(last if kill[0] == "silent" else exited - idle, exited)], lo, hi)
            work = minus(work, out["hung"])
    mine = [s for s in suites if s.get("worker_run") == run.get("run")]
    ran = union((max(s["started_at"], s["queued_at"]), s["ended_at"]) for s in mine if num(s.get("started_at")))
    queued = minus([(s["queued_at"], num(s.get("started_at")) or s["ended_at"]) for s in mine], ran)
    out["suite_run"] = [x for w in work for x in clip(ran, *w)]
    out["suite_wait"] = [x for w in work for x in clip(queued, *w)]
    rest = minus(work, ran + queued)
    session = run_session(run.get("run"))
    if session is None:
        out["other"] = rest
        return out
    out["tools"] = [x for w in rest for x in clip([(c[1], c[1] + c[5]) for c in calls if c[8] == session], *w)]
    out["model"] = minus(rest, out["tools"])
    return out


def budget(lo, hi, events=None):
    """Overhead over [lo, hi) as wall-clock seconds: each class is the union of its spans, so parallel runs count once.
    Suites come from run-suites' journal for every caller, hooks from Harness's hook rows and a turn's Stop seconds
    at its end, refusals from `refusal_cost`, locks and polls from the waits a chat or worker paid, and the rest from
    each worker run's split. A turn's compaction and unexplained seconds have no position, so they add to the union.
    `active_s` is the union of owner turns, worker runs and suites; a bench worker is in neither."""
    events = events if events is not None else event_rows(lo, hi)
    runs = worker_runs(lo, hi)
    suites = suite_rows(min([lo] + [num(r.get("pid_started_at")) or num(r.get("started_at")) or lo for r in runs]),
                        hi + 86400)
    spans, unplaced, active, dead = collections.defaultdict(list), collections.Counter(), [], dead_runs(runs)
    for run in runs:
        split = run_split(dict(run, dead=run.get("run") in dead), lo, hi, suites, ())
        if "bench" not in split:
            active += [x for v in split.values() for x in v]
            for key in ("slot", "retries", "walled", "wrapup", "dead", "hung", "other"):
                spans[key] += split.get(key, ())
    for t in events.get("t", ()):
        if t[3] > lo and t[1] < hi and t[3] > t[1]:
            parts, share = t[9] or {}, (min(t[3], hi) - max(t[1], lo)) / (t[3] - t[1])
            active.append((t[1], t[3]))
            spans["stop"].append((t[3] - parts.get("stop", 0), t[3]))
            unplaced["compaction"] += parts.get("compact", 0) * share
            unplaced["other"] += parts.get("resid", 0) * share
    for r in suites:
        started = num(r.get("started_at"))
        active.append((r["queued_at"], r["ended_at"]))
        spans["suite_wait"].append((r["queued_at"], started or r["ended_at"]))
        if started:
            spans["suite_run"].append((max(started, r["queued_at"]), r["ended_at"]))
    by_hook = collections.defaultdict(list)
    for h in events.get("h", ()):
        family = "stop" if h[3] == "Stop" else "hooks"
        spans[family].append((h[1], h[1] + h[5] / 1000.0))
        by_hook["%s/%s" % (family, hook_key(str(h[4])))].append((h[1], h[1] + h[5] / 1000.0))
    spans["locks"] = [(w["started"], w["started"] + w["seconds"]) for w in wait_rows(lo, hi)
                      if w.get("class") in WAIT_CLASSES and w.get("caller")]
    recovery = refusal_cost(lo, hi, events)
    spans["refusal"] = recovery.pop("spans")
    spans = {k: clip(v, lo, hi) for k, v in spans.items()}

    def seconds(keys):
        return round(length(union(x for k in keys for x in spans.get(k, ()))) + sum(unplaced[k] for k in keys), 1)

    hooks = sorted(((length(clip(v, lo, hi)), k) for k, v in by_hook.items()), key=lambda x: (-x[0], x[1]))
    return {"lo": lo, "hi": hi, "version": BUDGET_VERSION, "seconds": {k: seconds((k,)) for k in LABEL},
            "overhead_s": seconds(LABEL), "active_s": round(length(clip(active, lo, hi)), 1),
            "rows": {row: seconds([k for part in parts for k in part[1:]]) for row, parts in ROWS},
            "parts": {part[0]: seconds(part[1:]) for _, parts in ROWS for part in parts},
            "hooks_by_hook": {k: round(v, 1) for v, k in hooks[:20] if v}, "runs": len(runs),
            "dead_runs": sorted(dead), "refusals": recovery["count"], "refusal_cost": recovery}


# ---------------------------------------------------------------- days


def day_cache_path(day):
    return os.path.join(harness_dir(), "budget-days", day + ".json")


def day_budget(day, now, store):
    """A day's budget, stored once the day ended a day ago (worker rows land when the run ends) and recomputed when
    its BUDGET_VERSION is older."""
    lo, hi = day_bounds(day)
    cached = read_json(day_cache_path(day), None)
    if isinstance(cached, dict) and cached.get("settled") and cached.get("version") == BUDGET_VERSION:
        return cached
    found = budget(lo, min(hi, now))
    found["settled"] = now >= hi + SETTLE_S
    if found["settled"] and store:
        write_json(day_cache_path(day), found)
    return found


def measured(b):
    """No recorded time is no measurement, never a zero day."""
    return (b.get("active_s") or 0) > 0


def prune_days(now):
    cutoff = local_day(now - KEEP_DAYS * 86400)
    for path in glob.glob(os.path.join(harness_dir(), "budget-days", "????-??-??.json")):
        if os.path.basename(path)[:10] < cutoff:
            try:
                os.unlink(path)
            except OSError:
                pass


def history(now, store, today):
    """{day: overhead minutes} of the HISTORY_DAYS days before today, each its whole day's value, and today's latest."""
    out, day = {}, local_day(now)
    for back in range(HISTORY_DAYS, 0, -1):
        prior = local_day(day_bounds(day)[0] - back * 86400 + 3600)
        b = day_budget(prior, now, store)
        if measured(b):
            out[prior] = round(b["overhead_s"] / 60.0, 1)
    if today is not None:
        out[day] = today
    return out


def pct(part, whole):
    return round(100.0 * part / whole) if whole else 0


# ---------------------------------------------------------------- the day document


def problem_trend(now):
    rows = collector_runs.problem_days(local_day(now - (TREND_DAYS - 1) * 86400))
    out = collections.defaultdict(dict)
    for r in rows:
        out[r["doctor"]][r["day"]] = r["count"]
    return {d: dict(sorted(v.items())) for d, v in sorted(out.items())}


def document(now, hours=24.0, write=True):
    lo = now - hours * 3600
    b = budget(lo, now)
    scale = lambda secs, digits=1: round(secs / 60.0 * 24.0 / hours, digits)
    gates = list(b["refusal_cost"]["by_gate_s"].items())
    rows = [[scale(b["overhead_s"]), "overhead", []]]
    for row, parts in ROWS:
        sub = []
        for part in parts if len(parts) > 1 else ():
            sub.append([scale(b["parts"][part[0]]), part[0]])
            if part[1] == "refusal":
                sub += [[scale(s), "  " + gate] for gate, s in gates[:5] if scale(s) >= 1]
        hooks = [[scale(s), key.split("/", 1)[1]] for key, s in list(b["hooks_by_hook"].items())[:5] if scale(s) >= 1]
        if row == "harness rules" and hooks:
            sub += ["-"] + hooks
        rows.append([scale(b["rows"][row]), row, sub])
    rows.append([scale(b["active_s"]), "system active", []])
    doc = {"window_h": hours, "as_of_s": int(now), "lost_min_day": scale(b["overhead_s"]) if measured(b) else None,
           "rows": rows, "classes_min_day": {k: scale(v) for k, v in b["seconds"].items()},
           "hooks_by_hook_min_day": {k: scale(v, 2) for k, v in b["hooks_by_hook"].items()},
           "worker_runs": b["runs"], "dead_runs": b["dead_runs"], "refusals": b["refusals"],
           "refusal_cost": dict(b["refusal_cost"], min_day=scale(b["refusal_cost"]["seconds"], 2),
                                by_gate_min_day={k: scale(v, 2) for k, v in gates}),
           "problems_by_day": problem_trend(now)}
    doc["lost_min_day_by_day"] = history(now, write, doc["lost_min_day"])
    if write:
        prune_days(now)
    doc["lines"] = ["%d min/day %s" % (round(v), label) + "".join(
        " · %s %d" % (part[0], round(scale(b["parts"][part[0]]))) for part in dict(ROWS).get(label, ()) if label != part[0])
        for v, label, _ in rows] if doc["lost_min_day"] is not None else ["Lost time: nothing measured in the last %d h" % hours]
    return doc


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
    print("gates · %d refusals · %.2f min/day measured recovery" % (doc["refusals"], doc["refusal_cost"]["min_day"]))
    for doctor, days in doc["problems_by_day"].items():
        print("problems · %s · %s" % (doctor, " ".join("%s:%s" % (d[5:], n) for d, n in days.items())))
    print("days · " + " ".join("%s:%s" % (d[5:], v) for d, v in doc["lost_min_day_by_day"].items()))


# ---------------------------------------------------------------- nights


def night_split(night):
    """Wall and its split over the worker runs the night's sessions launched (night_spend's selection)."""
    low, high, sessions = night_spend.window(night)
    runs = []
    for run, _, meta, _ in night_spend.night_runs(low, high, sessions):
        runs.append(dict(meta, run=run, round=meta.get("review_round"), walled=meta.get("walled_accounts")))
    hi = max([num(r.get("ended_at")) or 0 for r in runs] + [high])
    calls = [c for c in event_rows(low, hi, ("c",)).get("c", ()) if c[6] == "w"]
    suites = suite_rows(low, hi + 86400)
    split = collections.Counter()
    for run in runs:
        for key, spans in run_split(run, low, hi, suites, calls).items():
            split[key] += length(spans)
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


def night_speed_skip(problem, problems=()):
    fields = problem.get("opportunity") or {}
    if problem.get("class", fields.get("class")) == "measurement fix":
        blind_for = problem.get("blind_for", fields.get("blind_for")) or []
        if any(p.get("id") in blind_for and p.get("class", (p.get("opportunity") or {}).get("class")) != "measurement fix"
               and not night_speed_skip(p) for p in problems):
            return None
        return "measurement fix without a >=5 min/day blind opportunity"
    gain = expected_gain(problem)
    return None if gain is not None and gain >= NIGHT_GAIN_MIN_DAY else "expected gain <5 min/day or unpriced"


def expected_gain(problem):
    fields = problem.get("opportunity") or {}
    gain = num(problem.get("expected_min_day"))
    if gain is None:
        gain = num(fields.get("recoverable_min_day", fields.get("saving")))
    return gain


def improvement_class(rule, pid):
    """The time class a Speed or time row's fix should shrink; None measures the harness total."""
    ident = pid.split(":", 1)[1] if ":" in pid else ""
    if rule == spend_block.RULE:
        return pid
    if rule == "time_floor" or ident.startswith("time/"):
        key = ident[5:] if ident.startswith("time/") else ident
        return key if key in LABEL else None
    if ident.startswith(("chat/hooks", "hooks/")):
        return "hooks"
    if ident.startswith(("stop/", "refusal/")):
        return ident.split("/", 1)[0]
    if ident.startswith(("chat/tests", "tests/", "test-health/")) or rule.startswith("test_") or rule == suite_audit.RULE:
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
            found = re.fullmatch(r"(?:test_\w+|%s):([\w.-]+):([\w.-]+)|opportunity:(?:tests|test-health/[\w-]+)/"
                                 r"([\w.-]+)/(.+)" % suite_audit.RULE, str(ident))
            if found:
                named.add("%s/%s" % (found.group(1) or found.group(3), found.group(2) or found.group(4)))
        elif item["class"] in ("hooks", "stop", "refusal"):
            found = re.fullmatch(r"\w+:(?:hooks|stop|refusal)/(.+)", str(ident))
            if found:
                named.add(found.group(1))
    return named


def counted(item):
    """A test-health fix that cuts runs or reorders them (retests, serial runs, flaky reruns, the suites a file pulls)
    leaves a run's wall as it was: only the class's day totals can prove it."""
    return item["class"] == "suite_run" and any(re.match(
        r"opportunity:test-health/(?:retests|serial|flaky|fan-out)(?:/|$)", str(i)) for i in item.get("ids") or ())


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


def class_day(day, key, now):
    b = day_budget(day, now, True)
    if not b.get("settled") or not measured(b):
        return None
    return (b["seconds"].get(key, 0) if key else b["overhead_s"]), b["active_s"]


def saved_min_day(item, landed, now):
    """Minutes per day the class lost after a full day of the change against as many measured days before it (up to
    ROI_DAYS): its seconds per active second on each side times the active seconds a day before it, so a quieter or
    busier day after reads as no gain. None while pending, UNMEASURED once settled days exist but no measured one on a
    side, a number otherwise (<= 0 is spend without result)."""
    day = local_day(landed)
    before = [class_day(local_day(day_bounds(day)[0] - back * 86400 + 3600), item["class"], now)
              for back in range(1, ROI_DAYS + 1)]
    after, start = [], day_bounds(day)[1]
    while len(after) < ROI_DAYS and start + 86400 + SETTLE_S <= now:
        after.append(class_day(local_day(start + 3600), item["class"], now))
        start += 86400
    if not after:
        return None
    before, after = [v for v in before if v is not None], [v for v in after if v is not None]
    if not after or not before:
        return UNMEASURED
    n = min(len(before), len(after))
    before, after = before[:n], after[:n]
    share = [sum(v[0] for v in side) / sum(v[1] for v in side) for side in (before, after)]
    return round((share[0] - share[1]) * sum(v[1] for v in before) / n / 60.0, 1)


def unit_samples(item, lo, hi):
    """{key: [values]} of the class's natural unit in [lo, hi): per suite (repo/label), per hook (its script's base
    name and arguments), per gate (its recovery seconds in each whole day back from hi, 0 on a day it refused nothing,
    so fewer refusals prove as well as faster recoveries), per wait class."""
    if item["class"] == "suite_run":
        return suite_audit.samples(suites_path(), lo, hi)
    out = collections.defaultdict(list)
    if item["class"] == "refusal":
        rows, events, days = refusal_rows(lo - REFUSAL_CAP_S, hi), event_rows(lo, hi, ("c", "t")), []
        while hi - 86400 * (len(days) + 1) >= lo:
            end = hi - 86400 * len(days)
            days.append(refusal_cost(end - 86400, end, events, rows)["by_gate_s"])
        for gate in set(unit_names(item)).union(*days) if days else ():
            out[gate] = [d.get(gate, 0.0) for d in reversed(days)]
        return out
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
    per key (the keys its ids name, else every suite, hook script, gate's day or wait class) the median of the first M
    samples after the night against the newest M before it, M the smaller side, weighted by M, so a changed mix of
    suites or hooks reads as no gain. No load is recorded beside a sample, so none is matched. A proven gain sums, over
    the keys proven on their own (`keys`), the key's delta times its samples a day in the UNIT_BEFORE_DAYS before the
    night. No sample or a zero median before the night, or a fix that cuts runs (`counted`), keeps the day totals; a
    named unit that no longer exists is `gone`."""
    unit = UNITS.get(item["class"])
    if not unit or counted(item):
        return None
    label, need, ratio, daily, scale = unit
    named = unit_names(item)
    before = unit_samples(item, started - UNIT_BEFORE_DAYS * 86400, started)
    after = unit_samples(item, ended, now)
    if named:
        if unit_gone(item, named, after, need, ended, now):
            return {"proven": False, "gone": True, "text": "%s no longer exists" % ", ".join(sorted(named))}
        before, after = ({k: v for k, v in d.items() if k in named} for d in (before, after))
    stat = UNIT_STAT.get(item["class"], statistics.median)
    before = {k: v for k, v in before.items() if v and stat(v) > 0}
    if not before:
        return None
    keys = [k for k, v in after.items() if len(v) >= need and before.get(k)]
    if not keys:
        return {"proven": None, "text": "%s: %d of %d since" % (
            label, max((len(v) for v in after.values()), default=0), need)}
    weight = {k: min(len(after[k]), len(before[k])) for k in keys}
    pair = {k: (stat(before[k][-weight[k]:]), stat(after[k][:weight[k]])) for k in keys}
    total = float(sum(weight.values()))
    was = sum(weight[k] * pair[k][0] for k in keys) / total
    now_ = sum(weight[k] * pair[k][1] for k in keys) / total
    proven = now_ <= ratio * was
    gains = {k: (pair[k][0] - pair[k][1]) * len(before[k]) / UNIT_BEFORE_DAYS / scale for k in keys
             if pair[k][1] <= ratio * pair[k][0]} if proven else {}
    gain = round(sum(gains.values()), 1)
    span = "%s → %s %s" % (suite_audit.fmt(was), suite_audit.fmt(now_), label)
    return {"proven": proven, "before": round(was, 2), "after": round(now_, 2), "samples": int(total), "span": span,
            "gain": gain, "daily": daily, "gains": gains,
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
    and stays out of the minute totals. A gain is claimed once over the trend: the earliest positive claim of a key
    (a proven suite, hook or wait class, or a whole class from the day totals) takes it, a later one gains only its
    unclaimed keys and names the owner as `shared with`."""
    out, total_spend, total_saved, total_proven, measured, proofs = [], 0.0, 0.0, 0, 0, None
    total_other, claims = collections.Counter(), {}

    def claim(item, keys):
        taken = {key: ref for (cls, key), ref in claims.items() if cls == item["class"]}
        overlap = [k for k in taken if k == "*" or "*" in keys or k in keys]
        free = [] if "*" in taken or "*" in keys and taken else [k for k in keys if k not in taken]
        claims.update(((item["class"], k), item["ref"]) for k in free)
        return free, taken[overlap[0]] if overlap else None

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
                    free, owner = claim(item, list(shown.get("gains") or ()))
                    if owner:
                        gain = round(sum(shown["gains"][k] for k in free), 1)
                        shown = dict(shown, gain=gain, text="%s · proven · %sshared with %s" % (
                            shown["span"], "%.1f %s · " % (gain, shown["daily"]) if free else "", owner[:40]))
                    if shown["daily"] == "min/day":
                        saved += shown["gain"]
                    else:
                        other[shown["daily"]] += shown["gain"]
                if row is rows[-1]:
                    out.append("roi · %s · %s · %.1fM · %+d/-%d · %s" % (
                        item["ref"][:40], what, item["spend_m"], item["lines"][0], item["lines"][1], shown["text"]))
                continue
            gain = saved_min_day(item, ended, now) if item["merged"] else None
            owner = claim(item, ["*"])[1] if gain not in (None, UNMEASURED) and gain > 0 else None
            if gain == UNMEASURED:
                unmeasured += 1
            else:
                spend += item["spend_m"]
            if gain is None:
                pending += item["merged"]
            elif gain != UNMEASURED:
                saved += 0 if owner else gain
                measured += 1
            if row is rows[-1]:
                out.append("roi · %s · %s · %.1fM · %+d/-%d lines · %s" % (
                    item["ref"][:40], what, item["spend_m"], item["lines"][0],
                    item["lines"][1], "not landed" if not item["merged"] else "pending a full day" if gain is None
                    else "unmeasured before or after it" if gain == UNMEASURED
                    else "shared with %s" % owner[:40] if owner
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
            "spend_unit": night_spend.UNIT, "improvements": improvements(night, path, worker_run),
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
        if row.get("spend_unit") != night_spend.UNIT:
            spent = night_spend.spend(night, worker_run)
            fresh = {i["ref"]: i["spend_m"] for i in improvements(night, path, worker_run)}
            for item in row.get("improvements") or ():
                item["spend_m"] = fresh.get(item["ref"], 0.0)
            row.update(spend_m=round(spent["total"] / 1e6, 1), spend_kinds=spend_kinds(spent),
                       spend_unit=night_spend.UNIT)
            write_json(ledger_cache(night["id"], path), row)
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
    trend = [cached_row(worker_run, p) for _, p, _ in nights_upto(path)[-TREND_DAYS:]]
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
