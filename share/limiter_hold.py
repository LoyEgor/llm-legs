"""A limiter that holds work says so: docs/harness-doctor-design.md §12. Copy it; it needs nothing of
llm-legs but the path. path = hold_raise(limiter, what, why, until=None, key=None); hold_clear(path).
Threads of one process that wait at once each pass their own key, e.g. key=threading.get_ident(); I/O never raises."""
import json
import math
import os
import re
import time


def hold_dir():
    return os.environ.get("HARNESS_HOLDS_DIR") or os.path.join(
        os.environ.get("HARNESS_DOCTOR_DIR") or os.path.expanduser("~/.cache/harness-doctor"), "holds")


def hold_raise(limiter, what, why, until=None, key=None):
    name = re.sub(r"[^A-Za-z0-9_.-]", "_", limiter)
    path = os.path.join(hold_dir(), "%s-%d%s.json" % (name, os.getpid(), "-%s" % key if key is not None else ""))
    try:
        finite = isinstance(until, (int, float)) and not isinstance(until, bool) and math.isfinite(until)
        held = {"what": what, "session": os.environ.get("CLAUDE_CODE_SESSION_ID"), "cwd": os.getcwd()}
        record = {"limiter": name, "pid": os.getpid(), "held": held, "since": int(time.time()), "why": why,
                  "until": until if finite else None}
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "w") as handle:
            json.dump(record, handle, allow_nan=False)
        os.replace(path + ".tmp", path)
    except Exception:
        hold_clear(path + ".tmp")
        return None
    return path


def hold_clear(path):
    try:
        if path:
            os.unlink(path)
    except OSError:
        pass
