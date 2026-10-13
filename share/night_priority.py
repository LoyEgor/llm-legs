"""Night jobs' direction and priority from the measured value of their rows, and their admission paced by the Claude
accounts' room (docs/night-run.md, Priority and admission).

  night_priority.py job <kind> <ref>                       {direction, priority, value} of a night job, as JSON
  night_priority.py admit <night.json> <ref> <vendor> <pid>  one admission decision, the night file rewritten:
                                                           prints `admit|wait|defer<TAB>why`; the accounts' readings on stdin
  night_priority.py backlog                                {"p12": open P1+P2 rows, "by": {direction: n}} over the doctors
  night_priority.py replay <night.json> <readings.json>    the jobs a launch burst would start, by priority
"""

import glob
import json
import os
import re
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

DIRECTIONS = ("speed", "tests", "cpu", "spend", "legacy", "fit", "bugs", "logs", "harness", "updater", "pool")
PRIORITIES = ("P1", "P2", "P3")
DOCTORS = ("llm", "harness", "updater", "code", "system")

WALL_P1_MIN_DAY = 15.0
WALL_P2_MIN_DAY = 1.0
CPU_P2_MIN_DAY = 30.0
SPEND_P1_SHARE = 0.5
SPEND_P2_SHARE = 0.1
BUGS_STABLE_DAYS = 7

RUN_COST_PCT_PER_MTOK = 10.0
DEFAULT_RUN_COST_PCT = 7.0
COST_HISTORY_DAYS = 7
COST_MIN_SAMPLES = 3
WEEK_DAYS = 7.0
EXPIRY_MIN_PCT = 5.0

KINDS = {"vendor": ("updater", "P1"), "leftover": ("harness", "P1"), "trade": ("harness", "P1"),
         "suite": ("tests", "P1"), "debt": ("fit", "P1"), "handoff": ("harness", "P2"), "owner-chat": ("harness", "P2"),
         "coverage": ("fit", "P3"), "vendor-watch": ("updater", "P2"), "tool-ideas": ("harness", "P2")}
WALL_DAY_S_RULES = ("test_daily_cost", "wait_class")
SPEED_ROWS = ("opportunity", "suite_audit", "cpu_audit", "spend_audit")


def num(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def read_json(path, default=None):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def doctors_dir():
    return os.environ.get("DOCTORS_DIR") or os.path.expanduser("~/.cache/doctors")


def worker_runs_dir():
    return os.environ.get("WORKER_RUN_DIR") or os.path.expanduser("~/.cache/claude-worker-runs")


def doctor_path(name):
    root = os.environ.get("%s_DOCTOR_DIR" % name.upper()) or os.path.expanduser("~/.cache/%s-doctor" % name)
    return os.path.join(root, "latest.json")


_DOCS = {}


def doctor_doc(name, default=None):
    path = doctor_path(name)
    try:
        stat = os.stat(path)
        stamp = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
    except OSError:
        stamp = None
    if _DOCS.get(path, (False,))[0] != stamp:
        _DOCS[path] = (stamp, read_json(path, None))
    doc = _DOCS[path][1]
    return doc if isinstance(doc, dict) else ({} if default is None else default)


def direction(doctor, problem):
    import time_budget

    rule = str(problem.get("rule") or "")
    if doctor == "llm":
        return "pool"
    if doctor == "updater":
        return "updater"
    if doctor == "system":
        return "cpu"
    if doctor == "code":
        return "legacy" if problem.get("group") in ("dead", "duplicate") else "fit"
    if rule == "suite_audit" or rule.startswith("test_") or rule == "suites_at_once":
        return "tests"
    if rule == "cpu_audit":
        return "cpu"
    if rule == "spend_audit":
        return "spend"
    if rule == "log_audit":
        return "logs"
    if problem.get("severity") and rule.startswith("bug"):
        return "bugs"
    if rule in time_budget.IMPROVEMENT_RULES or problem.get("speed") or rule.startswith(("hook_", "wait_", "floor")):
        return "tests" if time_budget.improvement_class(rule, str(problem.get("id") or "")) in (
            "suite_run", "suite_wait") else "speed"
    return "harness"


def wall_min_day(problem):
    import time_budget

    gain = time_budget.expected_gain(problem)
    if gain is not None:
        return gain
    om = num((problem.get("opportunity") or {}).get("om_day"))
    if om is not None:
        return om
    value, unit = num(problem.get("value")), str(problem.get("unit") or "")
    window = num(problem.get("window_h")) or 24.0
    if value is None:
        return None
    if "min/day" in unit:
        return value
    if unit == "min":
        return value * 24.0 / window
    if unit == "s" and problem.get("rule") in WALL_DAY_S_RULES:
        return value / 60.0 * 24.0 / window
    if unit == "ms" and num(problem.get("exposure")):
        return value * num(problem.get("exposure")) / 60000.0 * 24.0 / window
    return None


def tier(value, p1, p2):
    if value is None:
        return "P2", 1.0
    return ("P1" if p1 is not None and value >= p1 else "P2" if value >= p2 else "P3"), value / (p1 or 2 * p2)


def priority(doctor, problem):
    """(direction, priority, value, unit, norm): norm is the value over its direction's P1 bar, the order inside a tier."""
    way, rule = direction(doctor, problem), problem.get("rule")
    if way in ("pool", "updater"):
        return way, "P1", None, None, 1.0
    if way in ("legacy", "fit", "harness"):
        return way, "P2", None, None, 1.0
    if way == "bugs":
        stable = (num(problem.get("stable_days")) or 0) >= BUGS_STABLE_DAYS
        return way, "P2" if stable and problem.get("severity") == "critical" else "P3", None, None, 0.5
    if way == "cpu":
        if doctor == "system":
            return way, "P2" if problem.get("severity") == "heavy" else "P3", None, None, 0.5
        value = num((problem.get("cpu") or {}).get("cpu_min_day"))
        level, norm = tier(value, None, CPU_P2_MIN_DAY)
        return way, level, value, "CPU-min/day", norm
    if way == "spend":
        level, norm = tier(num(problem.get("value")), SPEND_P1_SHARE, SPEND_P2_SHARE)
        return way, level, num(problem.get("value")), "% of spend", norm
    if rule == "test_hang":
        return way, "P1", None, None, 1.0
    value = wall_min_day(problem)
    level, norm = tier(value, WALL_P1_MIN_DAY, WALL_P2_MIN_DAY)
    return way, level, None if value is None else round(value, 2), "wall-min/day", norm


def best(rows):
    return min(rows, key=lambda r: (PRIORITIES.index(r[1]), -r[4]))


def from_fact(entry):
    """A row its doctor no longer lists, priced from the numbers its fact quoted at launch."""
    found = re.search(r"([0-9.]+) (wall-min/day|CPU-min/day|% of spend)", str(entry.get("fact") or ""))
    if not found:
        return entry
    value = float(found.group(1))
    if found.group(2) == "CPU-min/day":
        return dict(entry, cpu={"cpu_min_day": value})
    return dict(entry, value=value, unit=found.group(2))


def run_job(ref):
    """A fixer run's rows looked up in its doctor's document, else as the run recorded them; the best one decides."""
    run = read_json(os.path.join(doctors_dir(), "runs", ref + ".json"), {}) or {}
    doctor = run.get("doctor") or ref.split("-", 1)[0]
    live = {p.get("id"): p for p in doctor_doc(doctor).get("problems") or () if isinstance(p, dict)}
    rows = [priority(doctor, live.get(p.get("id")) or from_fact(p)) for p in run.get("problems") or () if isinstance(p, dict)]
    return best(rows) if rows else (direction(doctor, {}), "P2", None, None, 1.0)


def job(kind, ref):
    if kind == "fixer":
        way, level, value, unit, norm = run_job(ref)
    else:
        way, level = KINDS.get(kind, ("harness", "P2"))
        if kind == "coverage" and ref.startswith("coverage-legacy"):
            way = "legacy"
        value, unit, norm = None, None, 1.0
    return {"direction": way, "priority": level,
            "value": {"n": value, "unit": unit, "norm": round(norm, 3)}}


def backlog():
    by, split = {}, {}
    for doctor in DOCTORS:
        doc = doctor_doc(doctor, False)
        if doc is False:
            return {"p12": None, "by": by, "open": None}
        for problem in doc.get("problems") or ():
            if not isinstance(problem, dict) or problem.get("state") == "fixed-pending" or problem.get(
                    "state") == "watch" and not (problem.get("speed") and problem.get("rule") in SPEED_ROWS):
                continue
            way, level = priority(doctor, problem)[:2]
            if level != "P3":
                by[way] = by.get(way, 0) + 1
                split.setdefault(way, [0, 0])[PRIORITIES.index(level)] += 1
    return {"p12": sum(by.values()), "by": by, "open": split}


# ---------------------------------------------------------------- admission


def run_direction(ref):
    run = read_json(os.path.join(doctors_dir(), "runs", ref + ".json"), None)
    if not isinstance(run, dict):
        return None
    doctor = run.get("doctor") or ""
    rows = [direction(doctor, p) for p in run.get("problems") or () if isinstance(p, dict)]
    return rows[0] if rows else direction(doctor, {})


def costs(now):
    """Expected 5h-window % of one Claude night run by direction: the median tokens of finished, unwalled night runs."""
    by = {}
    low = now - COST_HISTORY_DAYS * 86400
    for meta_path in glob.glob(os.path.join(worker_runs_dir(), "claudeb-*", "meta.json")):
        directory = os.path.dirname(meta_path)
        stamp = os.path.basename(directory).split("-")[1]
        if not stamp.isdigit() or int(stamp) < low or glob.glob(os.path.join(directory, "wall-reset.*")):
            continue
        meta = read_json(meta_path, {}) or {}
        base = os.path.basename(str(meta.get("workdir") or ""))
        if not base.startswith("night-"):
            continue
        try:
            with open(os.path.join(directory, "tokens")) as handle:
                tokens = int(handle.read().strip())
        except (OSError, ValueError):
            continue
        if tokens <= 0:
            continue
        parts = base.split("-", 3)
        way = run_direction(parts[3]) if len(parts) == 4 else None
        by.setdefault(way or "*", []).append(tokens)
        if way:
            by.setdefault("*", []).append(tokens)
    out = {way: round(statistics.median(v) / 1e6 * RUN_COST_PCT_PER_MTOK, 2) for way, v in by.items()
           if len(v) >= COST_MIN_SAMPLES}
    out.setdefault("*", DEFAULT_RUN_COST_PCT)
    return out


def room(readings, now):
    """(5h room, the part of it P3 may spend): per account min(5h ceiling - 5h, 100 - week), and the weekly % its
    burn so far leaves unused at its reset."""
    five = spare = 0.0
    for a in readings:
        h5, wk = num(a.get("h5")), num(a.get("wk"))
        if h5 is None or wk is None:
            continue
        here = max(0.0, min((num(a.get("ceiling")) or 80.0) - h5, 100.0 - wk))
        five += here
        left = num(a.get("days_left"))
        if left is None:
            continue
        burn = wk / max(WEEK_DAYS - left, 1.0)
        unused = 100.0 - wk - burn * left
        if unused >= EXPIRY_MIN_PCT:
            spare += min(here, unused)
    return five, spare


def alive(pid):
    try:
        os.kill(int(pid), 0)
    except (OSError, ValueError, TypeError):
        return False
    return True


def rank(j, cost):
    level = j.get("priority") or "P2"
    norm = num((j.get("value") or {}).get("norm"))
    return (PRIORITIES.index(level) if level in PRIORITIES else 1, -((1.0 if norm is None else norm) / max(cost, 0.01)),
            (j.get("admission") or {}).get("since") or 0)


def decide(night, ref, vendor, pid, readings, now, prices, live=alive):
    """The verdict for job `ref` and the night with its admission recorded. Strict order: a waiter that does not fit
    holds back every one behind it; nothing running and some room always lets the head in."""
    jobs = night.get("jobs") or []
    me = next((j for j in jobs if j.get("ref") == ref), None)
    if me is None:
        return "admit", "not a job of this night", night
    if vendor != "claudeb" or not readings:
        me["admission"] = {"state": "admitted", "pid": pid, "at": now, "cost": 0.0, "vendor": vendor}
        return "admit", "no Claude room to pace" if vendor == "claudeb" else "not a Claude run", night
    cost = lambda j: prices.get(j.get("direction") or "", prices["*"])
    seat = me.get("admission") or {}
    if seat.get("state") == "admitted" and seat.get("pid") == pid:
        return "admit", "already admitted", night
    me["admission"] = {"state": "waiting", "pid": pid, "since": seat.get("since") if seat.get("pid") == pid and
                       seat.get("state") == "waiting" else now, "vendor": vendor}
    running = [j for j in jobs if (j.get("admission") or {}).get("state") == "admitted" and j.get("state") == "pending"
               and (j["admission"].get("cost") or 0) > 0 and live(j["admission"].get("pid"))]
    waiting = sorted((j for j in jobs if j is me or (j.get("admission") or {}).get("state") == "waiting"
                      and j.get("state") == "pending" and live(j["admission"].get("pid"))), key=lambda j: rank(j, cost(j)))
    five, spare = room(readings, now)
    if me.get("priority") == "P3" and spare <= 0:
        why = "P3: no weekly room expires unused before a reset"
        me["admission"] = {"state": "deferred", "at": now, "reason": why}
        return "defer", why, night
    used = sum(j["admission"]["cost"] for j in running)
    used3 = sum(j["admission"]["cost"] for j in running if j.get("priority") == "P3")
    for j in waiting:
        c, p3 = cost(j), j.get("priority") == "P3"
        fits = used + c <= five or (not running and used == 0 and five > 0)
        if p3 and fits:
            fits = used3 + c <= spare or (used3 == 0 and spare > 0)
        if not fits:
            break
        if j is me:
            me["admission"] = {"state": "admitted", "pid": pid, "at": now, "cost": c, "vendor": vendor,
                               "room": round(five - used, 1)}
            return "admit", "%s %s · %.1f %% of %.1f %% 5h room" % (me.get("priority") or "P2", me.get("direction") or "?",
                                                                      c, five - used), night
        used += c
        used3 += c if p3 else 0
    return "wait", "%d ahead · %.1f %% of %.1f %% 5h room held by %d runs" % (
        waiting.index(me), sum(j["admission"]["cost"] for j in running), five, len(running)), night


def admit(path, ref, vendor, pid):
    night = read_json(path, None)
    if not isinstance(night, dict):
        print("admit\tno night file")
        return
    try:
        readings = json.loads(sys.stdin.read() or "[]")
    except ValueError:
        readings = []
    now = time.time()
    store = night.setdefault("admission", {})
    if not isinstance(store.get("cost"), dict) or now - (store.get("cost_at") or 0) > 3600:
        store["cost"], store["cost_at"] = costs(now), now
    verdict, why, night = decide(night, ref, vendor, int(pid), readings, now, store["cost"])
    tmp = path + ".admit.%d" % os.getpid()
    with open(tmp, "w") as handle:
        json.dump(night, handle, indent=1)
    os.replace(tmp, path)
    print("%s\t%s" % (verdict, why))


def replay(path, readings_path):
    """The jobs a burst of every pending fixer would start at once under admission: counts by priority."""
    night = read_json(path, {}) or {}
    readings = read_json(readings_path, []) or []
    jobs = [dict(j, **job(j.get("kind"), j.get("ref")), admission=None, state="pending") for j in night.get("jobs") or ()
            if j.get("kind") == "fixer"]
    trial = {"jobs": jobs}
    prices = costs(time.time())
    started = []
    for i, j in enumerate(sorted(jobs, key=lambda j: rank(j, prices.get(j["direction"], prices["*"])))):
        verdict = decide(trial, j["ref"], "claudeb", 10 ** 6 + i, readings, time.time(), prices,
                         live=lambda pid: pid is not None and pid >= 10 ** 6)[0]
        if verdict == "admit":
            started.append(j)
    count = lambda rows: {p: sum(1 for j in rows if j["priority"] == p) for p in PRIORITIES}
    print(json.dumps({"jobs": count(jobs), "started": count(started), "cost": prices, "room": room(readings, time.time())}))


def main(argv):
    if argv[:1] == ["job"] and len(argv) == 3:
        print(json.dumps(job(argv[1], argv[2])))
    elif argv[:1] == ["admit"] and len(argv) == 5:
        admit(*argv[1:])
    elif argv == ["backlog"]:
        print(json.dumps(backlog()))
    elif argv[:1] == ["replay"] and len(argv) == 3:
        replay(argv[1], argv[2])
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
