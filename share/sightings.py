"""What the doctors saw over the last SEEN_DAYS days, so a night after a gap still finds a problem a window rule has
forgotten, and ranks each by its loss over those days (Egor 2026-11-07: nights are irregular; the biggest problem still
standing goes first, one gone for two weeks never). docs/doctors-contract.md "Sightings".

  sightings.py record          every doctor's live window problems into the store (Harness runs it every 5 minutes)
  sightings.py show [doctor]   the store's problems with their SEEN_DAYS average, as JSON
"""

import datetime
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

SEEN_DAYS = 14
# The Code doctor judges the code as it stands, never a window: what it no longer lists is gone.
DOCTORS = ("llm", "harness", "updater", "system")
LIVE = ("new", "open", "regressed")
# A ledger row of one of these is not ours to fix; an open one rides the night as a known, quiet row already.
NOT_OURS = ("not-a-bug", "weather")


def fixture():
    return any(os.environ.get(name.upper() + "_DOCTOR_DIR") for name in DOCTORS + ("code",))


def store_path():
    """None under a fixture doctor directory with no DOCTORS_DIR of its own: a test never reads or writes the live store."""
    if os.environ.get("DOCTORS_DIR"):
        return os.path.join(os.environ["DOCTORS_DIR"], "sightings.json")
    return None if fixture() else os.path.expanduser("~/.cache/doctors/sightings.json")


def doc_path(doctor):
    """The doctor's latest.json; under fixtures only a doctor with a fixture directory of its own."""
    import night_priority

    if fixture() and not os.environ.get(doctor.upper() + "_DOCTOR_DIR"):
        return None
    return night_priority.doctor_path(doctor)


def epoch(stamp):
    if isinstance(stamp, (int, float)) and not isinstance(stamp, bool):
        return float(stamp)
    try:
        return datetime.datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def local_day(at):
    return time.strftime("%Y-%m-%d", time.localtime(at))


def window(now):
    """The SEEN_DAYS local days ending today."""
    return {local_day(now - back * 86400) for back in range(SEEN_DAYS)}


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


_STORE = {}


def load():
    path = store_path()
    if not path:
        return {}
    try:
        stat = os.stat(path)
        stamp = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
    except OSError:
        return {}
    if _STORE.get(path, (None,))[0] != stamp:
        found = read_json(path, {})
        _STORE[path] = (stamp, found if isinstance(found, dict) else {})
    return _STORE[path][1]


def windowed(problem):
    """A rule over a time window forgets an event once the window passes it; a state rule's problem gone is resolved."""
    hours = problem.get("window_h")
    return isinstance(hours, (int, float)) and not isinstance(hours, bool) and hours > 0


def record(now=None):
    """Each doctor's new, open and regressed window problems on its document's day: the day's highest wall-min/day
    (night_priority.wall_min_day, null when the rule has no wall price), the latest event time, the problem as read."""
    import night_priority

    path = store_path()
    if not path:
        return None
    now = time.time() if now is None else now
    days = window(now)
    store = read_json(path, {})
    store = store if isinstance(store, dict) else {}
    for doctor in DOCTORS:
        path_of = doc_path(doctor)
        if not path_of:
            continue
        doc = read_json(path_of, None)
        kept = store.get(doctor) if isinstance(store.get(doctor), dict) else {}
        kept = {"covered": [d for d in kept.get("covered") or () if d in days],
                "problems": {pid: dict(seen, days={d: v for d, v in (seen.get("days") or {}).items() if d in days})
                             for pid, seen in (kept.get("problems") or {}).items() if isinstance(seen, dict)}}
        at = epoch(doc.get("as_of")) if isinstance(doc, dict) else None
        if at and doc.get("status") in ("ok", "problems") and local_day(at) in days:
            day = local_day(at)
            kept["covered"] = sorted(set(kept["covered"]) | {day})
            for problem in doc.get("problems") or ():
                if not isinstance(problem, dict) or not problem.get("id") or problem.get("state") not in LIVE \
                        or not windowed(problem):
                    continue
                seen = kept["problems"].setdefault(str(problem["id"]), {"days": {}})
                value, before = night_priority.wall_min_day(problem), seen["days"].get(day)
                seen["days"][day] = value if before is None else before if value is None else max(before, value)
                last = epoch(problem.get("last_seen")) or at
                if last >= (seen.get("last") or 0):
                    seen["last"], seen["problem"] = last, problem
        kept["problems"] = {pid: seen for pid, seen in kept["problems"].items() if seen["days"]}
        store[doctor] = kept
    temporary = "%s.tmp.%d" % (path, os.getpid())
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(store, handle, ensure_ascii=False, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)
    return store


def min_day(doctor, pid, now=None):
    """The problem's wall-min/day over the store's covered days of the last SEEN_DAYS, a day it was not seen counting
    zero; None without a priced sighting."""
    part = load().get(doctor) or {}
    days = window(time.time() if now is None else now)
    seen = (part.get("problems") or {}).get(str(pid)) or {}
    values = [v for d, v in (seen.get("days") or {}).items() if d in days and isinstance(v, (int, float))]
    covered = [d for d in part.get("covered") or () if d in days]
    return round(sum(values) / max(len(covered), 1), 2) if values else None


def missing(doctor, live, rows, now=None):
    """The problems the doctor saw in the last SEEN_DAYS days and its document lists no longer, biggest first: each as
    it was last read, its fact led by when it was last seen. Left out: a live id, a row not ours or open (the night takes
    open rows as known, quiet), a row whose last fix came after the problem was last seen."""
    now = time.time() if now is None else now
    part, days, out = load().get(doctor) or {}, window(now), []
    covered = len([d for d in part.get("covered") or () if d in days])
    for pid, seen in (part.get("problems") or {}).items():
        problem, last = seen.get("problem"), seen.get("last")
        if pid in live or not isinstance(problem, dict) or not last or not any(d in days for d in seen.get("days") or {}):
            continue
        row = rows.get(problem.get("ledger")) or rows.get(pid) or {}
        status = row.get("status")
        fixed = max([t for t in (epoch(f.get("at")) for f in row.get("fixes") or () if isinstance(f, dict)) if t] or [0])
        if status in NOT_OURS or status == "open" or status in ("fixed", "fixed-pending") and fixed >= last:
            continue
        average = min_day(doctor, pid, now)
        priced = "" if average is None else " · %.1f min/day over %d days" % (average, covered)
        stamp = datetime.datetime.fromtimestamp(last).astimezone().isoformat(timespec="seconds")
        out.append(dict(problem, fact="not seen since %s%s · %s" % (time.strftime("%b %d", time.localtime(last)), priced,
                                                                    problem.get("fact")),
                        evidence=problem.get("evidence") or [{"at": stamp, "ref": "sightings:%s" % pid}],
                        seen={"last": stamp, "days": len(seen["days"]), "min_day": average}))
    return sorted(out, key=lambda p: (-(p["seen"]["min_day"] or 0), -epoch(p["seen"]["last"])))


def main(argv):
    if argv[:1] == ["record"]:
        return 0 if record() is not None or not store_path() else 1
    if argv[:1] == ["show"]:
        store = load()
        print(json.dumps({doctor: {pid: {"days": seen.get("days"), "min_day": min_day(doctor, pid)}
                                   for pid, seen in ((store.get(doctor) or {}).get("problems") or {}).items()}
                          for doctor in (argv[1:2] or DOCTORS)}, indent=1, ensure_ascii=False))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
