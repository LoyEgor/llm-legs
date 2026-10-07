"""A limiter that holds work says so: docs/harness-doctor-design.md §12. Copy it; it needs nothing of
llm-legs but the path. path = hold_raise(limiter, what, why, until=None, key=None); hold_clear(path) journals
the hold's wait (wait_note: every wait, normal ones too, is a row the Harness doctor's Wait classes read).
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


def hold_clear(path, allowed=None, held=None, reason=None):
    try:
        if path:
            with open(path) as handle:
                record = json.load(handle)
            wait_note(record["limiter"], (record.get("held") or {}).get("what") or "", record["since"],
                      allowed=allowed, held=held, reason=reason)
    except Exception:
        pass
    try:
        if path:
            os.unlink(path)
    except OSError:
        pass


def wait_dir():
    return os.environ.get("HARNESS_WAITS_DIR") or os.path.join(
        os.environ.get("HARNESS_DOCTOR_DIR") or os.path.expanduser("~/.cache/harness-doctor"), "waits")


def wait_note(cls, source, started, seconds=None, allowed=None, held=None, reason=None):
    try:
        started = float(started)
        seconds = round(time.time() - started if seconds is None else float(seconds), 3)
        if not (math.isfinite(started) and math.isfinite(seconds)) or seconds < 0:
            return
        row = {"class": re.sub(r"[^A-Za-z0-9_.-]", "_", cls), "source": str(source), "started": round(started, 3),
               "seconds": seconds, "pid": os.getpid()}
        if cls in ("night-workers", "run-suites") or reason is not None:
            row.update(allowed=allowed, held=held, reason=reason)
        caller = os.environ.get("WORKER_RUN_ID") or os.environ.get("CLAUDE_CODE_SESSION_ID")
        if caller:
            row["caller"] = re.sub(r"[^A-Za-z0-9_.-]", "_", caller)
        os.makedirs(wait_dir(), exist_ok=True)
        with open(os.path.join(wait_dir(), time.strftime("%Y-%m-%d", time.localtime(started)) + ".jsonl"), "a") as handle:
            handle.write(json.dumps(row) + "\n")
    except Exception:
        pass
