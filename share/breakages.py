"""The Breakages metric (docs/directions/breakages.md § Metric), read off the doctors' own day journal
${DOCTORS_DIR:-~/.cache/doctors}/problem-ids/<day>.json (collector_runs.problem_ids):
new distinct problems per 100 units of work and repeats, per window.

  python3 share/breakages.py [--ids] [FROM TO]...   (default: the last 7 whole days and the 7 before)

A new problem: an id first shown `new` in the journal, on that local day, counted once. Its rule counts in the sum
when the doctor had it on 2026-10-02 (`git log -S` of its quoted name in the doctor), else on the `later` line.
Repeats: ids shown `regressed` in the window, distinct. Both drop the excluded rules. Units: chat + workers units of
the Harness budget days (share/time_budget.py)."""

import argparse
import datetime
import glob
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collector_runs  # noqa: E402
import time_budget  # noqa: E402
from spend import read_json  # noqa: E402

DOCTORS = ("harness", "llm", "updater")
RULE_DAY = "2026-10-02"
EXCLUDED = {"log_audit", "suites_at_once", "floor", "statusline", "menu_build", "collector", "worker_orphans", "load",
            "opportunity", "regression", "time_floor", "tool_idea", "dig", "store_size", "ledger", "event-waiting"}
EXCLUDED_PREFIXES = ("test_", "hook_", "wait", "growth-", "debt-")  # wait: Speed's Waits section, wait_* too
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_BORN = {}


def excluded(rule):
    rule = rule or ""
    return rule in EXCLUDED or rule.startswith(EXCLUDED_PREFIXES) or rule.endswith("_audit")


def born(doctor, rule):
    """The day the rule's quoted name first entered bin/<doctor>-doctor; None when git never saw it."""
    if (doctor, rule) not in _BORN:
        out = subprocess.run(["git", "-C", REPO, "log", "--format=%ad", "--date=short", "--reverse", "-S", '"%s"' % rule,
                              "--", "bin/%s-doctor" % doctor], capture_output=True, text=True).stdout.split()
        _BORN[doctor, rule] = out[0] if out else None
    return _BORN[doctor, rule]


def journal():
    """[(day, {doctor: {id: [rule, [states]]}})] oldest first."""
    days = sorted(os.path.basename(p)[:10] for p in glob.glob(collector_runs.ids_path("????-??-??")))
    return [(day, collector_runs.ids_day(day)) for day in days]


def units(day):
    strata = (read_json(time_budget.day_cache_path(day), None) or {}).get("strata") or {}
    return sum((strata.get(s) or {}).get("units") or 0 for s in ("chat", "workers")) if strata else None


def window(days, lo, hi):
    first, repeats = {}, {d: set() for d in DOCTORS}
    for day, found in days:
        for doctor in DOCTORS:
            for pid, (rule, states) in (found.get(doctor) or {}).items():
                if excluded(rule):
                    continue
                if "new" in states:
                    first.setdefault((doctor, pid), (day, rule))
                if "regressed" in states and lo <= day <= hi:
                    repeats[doctor].add(pid)
    new = {d: [] for d in DOCTORS}
    for (doctor, pid), (day, rule) in sorted(first.items()):
        if lo <= day <= hi:
            later = (born(doctor, rule) or "9999") > RULE_DAY
            new[doctor].append((day, pid, rule, later))
    span = [lo]
    while span[-1] < hi:
        span.append((datetime.date.fromisoformat(span[-1]) + datetime.timedelta(days=1)).isoformat())
    per_day = {day: units(day) for day in span}
    return new, repeats, sum(u or 0 for u in per_day.values()), [d for d, u in per_day.items() if u is None]


def per100(count, total):
    return "%.2f" % (100.0 * count / total) if total else "–"


def report(lo, hi, ids):
    new, repeats, total, unmeasured = window(journal(), lo, hi)
    lines = ["%s…%s  %s units%s" % (lo, hi, format(total, ","), "  (no units: %s)" % ", ".join(unmeasured)
                                    if unmeasured else ""),
             "%-8s %4s %7s %6s %8s" % ("", "new", "/100", "later", "repeats")]
    sums = [0, 0, 0]
    for doctor in DOCTORS:
        counted = sum(1 for row in new[doctor] if not row[3])
        row = (counted, len(new[doctor]) - counted, len(repeats[doctor]))
        sums = [a + b for a, b in zip(sums, row)]
        lines.append("%-8s %4d %7s %6d %8d" % (doctor, row[0], per100(row[0], total), row[1], row[2]))
    lines.append("%-8s %4d %7s %6d %8d" % ("total", sums[0], per100(sums[0], total), sums[1], sums[2]))
    if ids:
        for doctor in DOCTORS:
            lines += ["  %s %s %s%s" % (day, doctor, pid, "  (later rule)" if later else "")
                      for day, pid, _, later in new[doctor]]
            lines += ["  repeat %s %s" % (doctor, pid) for pid in sorted(repeats[doctor])]
    return "\n".join(lines)


def main(argv):
    parser = argparse.ArgumentParser(prog="breakages")
    parser.add_argument("--ids", action="store_true")
    parser.add_argument("days", nargs="*", metavar="FROM TO")
    args = parser.parse_args(argv)
    if len(args.days) % 2:
        parser.error("windows are FROM TO pairs")
    windows = list(zip(args.days[::2], args.days[1::2]))
    if not windows:
        today = datetime.date.today()
        windows = [((today - datetime.timedelta(days=back + 6)).isoformat(),
                    (today - datetime.timedelta(days=back)).isoformat()) for back in (8, 1)]
    print("\n\n".join(report(lo, hi, args.ids) for lo, hi in windows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
