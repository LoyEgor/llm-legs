"""One row per doctor collector run in ${DOCTORS_DIR:-~/.cache/doctors}/collector-runs.jsonl
(docs/shared-invariants.md row `ea`): {doctor, start, wall_s, cpu_s, trigger}."""

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


def record(doctor, started, command=None):
    row = {"doctor": doctor, "start": round(started, 3), "wall_s": round(time.time() - started, 3),
           "cpu_s": round(max(0.0, cpu_total() - CPU_BASE), 3), "trigger": trigger_word(command)}
    folder = os.environ.get("DOCTORS_DIR") or os.path.join(os.path.expanduser("~"), ".cache", "doctors")
    try:
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "collector-runs.jsonl"), "a") as handle:
            handle.write(json.dumps(row) + "\n")
    except OSError:
        pass
