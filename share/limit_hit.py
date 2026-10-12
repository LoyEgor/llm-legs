"""One line per threshold hit in ${LIMIT_HITS_LOG:-~/.cache/limits/hits.jsonl}; names live in limits.json.
WHERE is `file:line` or `file:ANCHOR`, the first line of that repo file holding ANCHOR.

python3 share/limit_hit.py NAME VALUE UNIT ACTION LOST WHERE [--observed N] [--usual N] [--session ID]
"""
import json
import os
import sys
import time

REPO = "llm-legs"
ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
MAX_LINE = 3500
UNITS = ("s", "bytes", "rows", "count", "chars", "pct")
ACTIONS = ("kill", "drop", "trim", "skip", "fallback", "break", "expire", "defer", "retry-exhausted")


def log_path():
    return os.environ.get("LIMIT_HITS_LOG") or os.path.join(os.path.expanduser("~"), ".cache", "limits", "hits.jsonl")


def number(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    return int(value) if value.is_integer() and abs(value) < 2 ** 53 else round(value, 3)


def located(where):
    """`file:ANCHOR` -> `file:N`, N the first line of the repo file holding ANCHOR; anything else as given."""
    path, _, anchor = str(where or "").rpartition(":")
    if not path or not anchor or anchor.isdigit():
        return where
    try:
        with open(os.path.join(ROOT, path), errors="replace") as handle:
            for number, text in enumerate(handle, 1):
                if anchor in text:
                    return "%s:%d" % (path, number)
    except OSError:
        pass
    return where


def line(name, value, unit, action, lost, where, observed=None, usual=None, session=None, now=None):
    where = located(where)
    record = {"ts": round(time.time() if now is None else now, 3), "limit": name if ":" in name else "%s:%s" % (REPO, name),
              "value": number(value), "unit": unit, "observed": number(observed), "usual": number(usual),
              "action": action, "lost": str(lost or ""), "where": where,
              "run": os.environ.get("WORKER_RUN_ID") or None,
              "session": session or os.environ.get("CLAUDE_SESSION_ID") or None}
    text = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
    while len(text.encode()) + 1 > MAX_LINE and record["lost"]:
        record["lost"] = record["lost"][:max(0, len(record["lost"]) - (len(text.encode()) + 1 - MAX_LINE) - 3)] + "..."
        if len(record["lost"]) <= 3:
            record["lost"] = ""
        text = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
    return text + "\n"


def hit(name, value, unit, action, lost, where, observed=None, usual=None, session=None):
    try:
        path = log_path()
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line(name, value, unit, action, lost, where, observed, usual, session).encode())
        finally:
            os.close(fd)
    except Exception as exc:
        try:
            sys.stderr.write("limit_hit: %s not journaled: %s\n" % (name, exc))
        except Exception:
            pass


def main(argv):
    args, opts = [], {}
    it = iter(argv)
    for arg in it:
        if arg in ("--observed", "--usual", "--session"):
            opts[arg[2:]] = next(it, None)
        else:
            args.append(arg)
    if len(args) != 6:
        sys.stderr.write(__doc__.strip().splitlines()[-1] + "\n")
        return 2
    hit(*args, **opts)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
