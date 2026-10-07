"""Every media-route comparison of a manifest section with the live vendor, one JSON line each in
${VENDOR_CLI_UPDATE_STATE_DIR:-~/.cache/vendor-cli-update}/caps-checks.jsonl (docs/shared-invariants.md row `ek`):
{at, vendor, section, state: fresh|stale, what}. bin/updater-doctor folds it into `caps-stale`. Never fails a run.

    python3 share/caps_checks.py record <vendor> <section> fresh|stale [what]"""

import fcntl
import json
import os
import re
import sys
import time

FILE = "caps-checks.jsonl"
MAX_BYTES = 256 << 10
KEEP_PER_KEY = 20
WHAT_MAX = 500
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
STATES = ("fresh", "stale")


def path():
    base = os.environ.get("VENDOR_CLI_UPDATE_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".cache", "vendor-cli-update")
    return os.path.join(base, FILE)


def parse(raw):
    try:
        row = json.loads(raw)
    except ValueError:
        return None
    if not (isinstance(row, dict) and isinstance(row.get("at"), int) and not isinstance(row["at"], bool)
            and all(isinstance(row.get(k), str) and NAME.match(row[k]) for k in ("vendor", "section"))
            and row.get("state") in STATES):
        return None
    row["what"] = row["what"] if isinstance(row.get("what"), str) else ""
    return row


def read(target=None):
    rows = []
    try:
        with open(target or path(), encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                row = parse(raw)
                if row:
                    rows.append(row)
    except OSError:
        pass
    return rows


def trim(target):
    """Per key the last KEEP_PER_KEY lines, plus the first stale line since the last fresh one: the doctor's first_seen."""
    rows = read(target)
    keep, streak = set(), {}
    for index, row in enumerate(rows):
        key = (row["vendor"], row["section"])
        if row["state"] == "fresh":
            streak.pop(key, None)
        else:
            streak.setdefault(key, index)
    keep.update(streak.values())
    seen = {}
    for index in range(len(rows) - 1, -1, -1):
        key = (rows[index]["vendor"], rows[index]["section"])
        seen[key] = seen.get(key, 0) + 1
        if seen[key] <= KEEP_PER_KEY:
            keep.add(index)
    with open(target + ".tmp", "w", encoding="utf-8") as handle:
        handle.write("".join(json.dumps(rows[i], ensure_ascii=False) + "\n" for i in sorted(keep)))
    os.replace(target + ".tmp", target)


def record(vendor, section, stale, what=""):
    try:
        if not (isinstance(vendor, str) and NAME.match(vendor) and isinstance(section, str) and NAME.match(section)):
            return
        what = " ".join(str(what or "").split())
        line = json.dumps({"at": int(time.time()), "vendor": vendor, "section": section,
                           "state": "stale" if stale else "fresh",
                           "what": what if len(what) <= WHAT_MAX else what[: WHAT_MAX - 1] + "…"},
                          ensure_ascii=False) + "\n"
        target = path()
        os.makedirs(os.path.dirname(target), exist_ok=True)
        # Appends hold the lock too: a line written between trim's read and its replace would be lost.
        with open(target + ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            descriptor = os.open(target, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
            try:
                os.write(descriptor, line.encode("utf-8"))
                size = os.fstat(descriptor).st_size
            finally:
                os.close(descriptor)
            if size > MAX_BYTES:
                trim(target)
    except Exception:  # noqa: BLE001
        pass


def main(argv):
    if len(argv) >= 4 and argv[0] == "record" and argv[3] in STATES:
        record(argv[1], argv[2], argv[3] == "stale", " ".join(argv[4:]))
    return 0


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception:  # noqa: BLE001
        pass
    sys.exit(0)
