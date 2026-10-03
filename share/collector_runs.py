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


def record(doctor, started, command=None):
    times = os.times()
    row = {"doctor": doctor, "start": round(started, 3), "wall_s": round(time.time() - started, 3),
           "cpu_s": round(times.user + times.system + times.children_user + times.children_system, 3),
           "trigger": trigger_word(command)}
    folder = os.environ.get("DOCTORS_DIR") or os.path.join(os.path.expanduser("~"), ".cache", "doctors")
    try:
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "collector-runs.jsonl"), "a") as handle:
            handle.write(json.dumps(row) + "\n")
    except OSError:
        pass
