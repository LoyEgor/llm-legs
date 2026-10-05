"""One row per doctor collector run in ${DOCTORS_DIR:-~/.cache/doctors}/collector-runs.jsonl
(docs/shared-invariants.md row `ea`): {doctor, start, wall_s, cpu_s, trigger}; and one row per doctor per local
day in problem-days.jsonl (row `ee`): {day, doctor, count, max, status, at}."""

import fcntl
import json
import os
import sys
import time


def trigger_word(command=None):
    source = os.environ.get("DOCTOR_TRIGGER")
    if not source:
        try:
            source = "tty" if sys.stdin is not None and sys.stdin.isatty() else "background"
        except (OSError, ValueError):
            source = "background"
    return "%s:%s" % (source, command) if command else source


CPU_BASE_ENV = "DOCTOR_CPU_BASE"


def cpu_total():
    times = os.times()
    return times.user + times.system + times.children_user + times.children_system


# os.times() survives execv: a doctor exec'd by another (harness -> speed) inherits the caller's CPU,
# which the caller hands over here to be subtracted; popped so no grandchild subtracts it again.
try:
    CPU_BASE = float(os.environ.pop(CPU_BASE_ENV, "") or 0)
except ValueError:
    CPU_BASE = 0.0


KEEP_DAYS = 35


def folder():
    return os.environ.get("DOCTORS_DIR") or os.path.join(os.path.expanduser("~"), ".cache", "doctors")


def problem_day(doctor, document, own_env, now=None):
    """The day's row of a persisted document: its latest problem_count and the day's max; never fails its caller.
    A fixture doctor directory (own_env set) with no DOCTORS_DIR of its own never reaches the live journal."""
    count = document.get("problem_count") if isinstance(document, dict) else None
    if not isinstance(count, int) or isinstance(count, bool) or os.environ.get(own_env) and not os.environ.get(
            "DOCTORS_DIR"):
        return
    now = time.time() if now is None else now
    day = time.strftime("%Y-%m-%d", time.localtime(now))
    path = os.path.join(folder(), "problem-days.jsonl")
    try:
        os.makedirs(folder(), exist_ok=True)
        with open(path + ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            rows = problem_days(None)
            old = next((r for r in rows if r["day"] == day and r["doctor"] == doctor), {})
            row = {"day": day, "doctor": doctor, "count": count, "max": max(count, old.get("max", count)),
                   "status": document.get("status"), "at": int(now)}
            cutoff = time.strftime("%Y-%m-%d", time.localtime(now - KEEP_DAYS * 86400))
            rows = [r for r in rows if r is not old and r["day"] >= cutoff] + [row]
            with open(path + ".tmp", "w") as handle:
                handle.write("".join(json.dumps(r) + "\n" for r in rows))
            os.replace(path + ".tmp", path)
    except OSError:
        pass


def problem_days(since):
    out = []
    try:
        with open(os.path.join(folder(), "problem-days.jsonl")) as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and isinstance(row.get("day"), str) and (since is None or row["day"] >= since):
                    out.append(row)
    except OSError:
        pass
    return out


def record(doctor, started, command=None):
    if os.environ.get(doctor.upper() + "_DOCTOR_DIR") and not os.environ.get("DOCTORS_DIR"):
        return
    row = {"doctor": doctor, "start": round(started, 3), "wall_s": round(time.time() - started, 3),
           "cpu_s": round(max(0.0, cpu_total() - CPU_BASE), 3), "trigger": trigger_word(command)}
    try:
        os.makedirs(folder(), exist_ok=True)
        with open(os.path.join(folder(), "collector-runs.jsonl"), "a") as handle:
            handle.write(json.dumps(row) + "\n")
    except OSError:
        pass
