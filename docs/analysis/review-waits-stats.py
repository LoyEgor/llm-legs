#!/usr/bin/env python3
"""Prints every table in docs/analysis/review-waits-2026-08-24.md from the bench store.

Usage: python3 docs/analysis/review-waits-stats.py [--benches DIR] [--top N]
Read-only. Panel rules (cell_status, cell_attempt_rows) are imported from share/rbench.

excess = panel wall (meta started..finished) minus the slowest completed cell's total
duration_ms. Attribution reads what the store records: verify_ms (the serial post-cell
verifier phase), per-attempt started_at/finished_at stamps (gate wait + backoff sleeps =
span - duration), superseded attempt rows (retries and pool walks), and the `retrying in`
marker opencode-go leaves on stderr during its in-gate 5xx backoff.
"""
import argparse
import json
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "share"))

from rbench import panel as _panel  # noqa: E402

DEFAULT_BENCHES = Path.home() / ".claude-profiles/.claudeb/worker-stats/benches"
GATE_LIMIT = 5


def ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def fold(spec):
    return spec.split("#", 1)[0]


def med(values):
    return statistics.median(values) if values else 0


def pct(values, share):
    ordered = sorted(values)
    return ordered[int(share * (len(ordered) - 1))] if ordered else 0


def table(header, rows):
    columns = list(zip(*([header] + [[str(c) for c in r] for r in rows])))
    widths = [max(len(str(c)) for c in col) for col in columns]
    aligns = ["<"] + [">"] * (len(header) - 1)
    def line(cells):
        return "| " + " | ".join(
            f"{str(c):{a}{w}}" for c, a, w in zip(cells, aligns, widths)) + " |"
    sep = "|" + "|".join(
        "-" * (w + 2) if a == "<" else "-" * (w + 1) + ":" for a, w in zip(aligns, widths)) + "|"
    return "\n".join([line(header), sep] + [line(r) for r in rows])


def load_runs(benches):
    if not benches.is_dir():
        raise SystemExit(f"no bench store at {benches}: pass --benches DIR")
    runs = []
    for run_dir in sorted(benches.iterdir()):
        meta_path = run_dir / "meta.json"
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text())
        except (OSError, ValueError):
            continue
        started, finished = ts(meta.get("started")), ts(meta.get("finished"))
        rows = meta.get("rater_runs") or []
        if not started or not finished or not rows:
            continue
        runs.append((run_dir.name, meta, started, finished, rows))
    return runs


def cell_views(rows, run_started):
    """One view per cell: final row, its superseded attempts, spans where stamped."""
    final, attempts = _panel.cell_attempt_rows(rows)
    views = []
    for row in final:
        spec = row.get("rater")
        chain = (attempts.get(spec) or []) + [row]
        durations = [r.get("duration_ms") or 0 for r in chain]
        first_start = next((ts(r.get("started_at")) for r in chain if ts(r.get("started_at"))), None)
        last_end = ts(row.get("finished_at"))
        span_s = (last_end - first_start).total_seconds() if first_start and last_end else None
        end_offset_s = (last_end - run_started).total_seconds() if last_end else None
        stderrs = " ".join((r.get("stderr") or "") for r in chain)
        views.append({
            "spec": spec, "side": row.get("side"), "row": row,
            "completed": _panel.cell_status(row) == "completed",
            "duration_s": (row.get("duration_ms") or 0) / 1000,
            "chain_s": sum(durations) / 1000,
            "superseded_n": len(chain) - 1,
            "superseded_s": sum(durations[:-1]) / 1000,
            # Per attempt and not per chain: a cell that rotated accounts failed on the ones it
            # left, and crediting the whole chain to the row that finally answered reads as the
            # answering account's failure.
            "attempt_accounts": [
                (r.get("account"), (r.get("duration_ms") or 0) / 1000) for r in chain[:-1]
            ],
            "span_s": span_s, "end_offset_s": end_offset_s,
            "verify_s": (row.get("verify_ms") or 0) / 1000,
            "backoff_marker": "retrying in" in stderrs,
            "account": row.get("account"),
        })
    return views


def attribute(run_id, meta, started, finished, rows):
    wall_s = (finished - started).total_seconds()
    views = cell_views(rows, started)
    completed = [v for v in views if v["completed"]]
    if not completed:
        return None
    slowest = max(completed, key=lambda v: v["duration_s"])
    excess_s = wall_s - slowest["duration_s"]
    verify_s = sum(v["verify_s"] for v in views)
    oc_n = sum(1 for v in views if v["side"] == "opencode")
    buckets = Counter()
    remaining = max(0.0, excess_s)
    take = min(remaining, verify_s)
    buckets["verify phase (serial, after cells)"] = take
    remaining -= take
    # A failed or killed cell that ran longer than every completed one held the panel by itself.
    longest = max(views, key=lambda v: v["chain_s"])
    failed_over = max(0.0, longest["chain_s"] - slowest["duration_s"])
    if remaining > 0 and failed_over > 0 and not longest["completed"]:
        row = longest["row"]
        killed = row.get("killed") or ("timeout" if row.get("exit_code") == 124 else "")
        key = ("timed-out cell held the panel" if killed
               else "failed cell held the panel")
        take = min(remaining, failed_over)
        buckets[key] += take
        remaining -= take
    superseded_s = sum(v["superseded_s"] for v in views)
    if remaining > 0 and superseded_s > 0:
        take = min(remaining, superseded_s)
        buckets["recorded retries / pool walk"] += take
        remaining -= take
    oc_failed_5xx = any(v["side"] == "opencode" and not v["completed"] and v["backoff_marker"]
                        for v in views)
    if remaining > 0 and oc_n > GATE_LIMIT:
        key = ("oc gate queue + failed-cell 5xx walk (inferred)" if oc_failed_5xx
               else "oc gate queue (inferred)")
        buckets[key] += remaining
        remaining = 0
    elif remaining > 0 and oc_failed_5xx:
        buckets["oc failed-cell 5xx walk, unrecorded (inferred)"] += remaining
        remaining = 0
    elif remaining > 0:
        buckets["unattributed"] += remaining
        remaining = 0
    stamped = [v for v in views if v["end_offset_s"] is not None]
    dominant = buckets.most_common(1)[0][0] if buckets else "none"
    return {
        "run_id": run_id, "tier": meta.get("tier"), "wall_s": wall_s,
        "slowest_spec": slowest["spec"], "slowest_s": slowest["duration_s"],
        "excess_s": excess_s, "buckets": buckets, "dominant": dominant,
        "oc_n": oc_n, "stamped": bool(stamped) and len(stamped) == len(views),
        "verify_s": verify_s, "views": views,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--benches", type=Path, default=DEFAULT_BENCHES)
    parser.add_argument("--top", type=int, default=10)
    args = parser.parse_args()
    runs = [attribute(*run) for run in load_runs(args.benches)]
    runs = [r for r in runs if r]
    with_excess = [r for r in runs if r["excess_s"] > 5]
    total_excess_min = sum(r["excess_s"] for r in with_excess) / 60

    print(f"runs with wall+cells recorded: {len(runs)}; "
          f"runs where the panel outlived its slowest cell by >5s: {len(with_excess)} "
          f"({total_excess_min:.0f} excess minutes total); "
          f"fully stamped (per-attempt started_at/finished_at): "
          f"{sum(1 for r in runs if r['stamped'])}")
    print()

    print("## Mechanisms, by total excess minutes")
    mech_min = Counter()
    mech_runs = Counter()
    for r in with_excess:
        for key, seconds in r["buckets"].items():
            if seconds > 0:
                mech_min[key] += seconds / 60
                mech_runs[key] += 1
    rows = [[k, mech_runs[k], f"{v:.1f}", f"{100 * v / total_excess_min:.0f}%"]
            for k, v in mech_min.most_common()]
    print(table(["mechanism", "runs", "minutes", "share of excess"], rows))
    print()

    print(f"## Top {args.top} excess runs")
    top = sorted(with_excess, key=lambda r: -r["excess_s"])[:args.top]
    rows = [[r["run_id"], r["tier"] or "-", f"{r['wall_s'] / 60:.1f}",
             f"{r['slowest_spec']} {r['slowest_s'] / 60:.1f}m",
             f"{r['excess_s'] / 60:.1f}", r["dominant"]] for r in top]
    print(table(["run", "tier", "wall m", "slowest cell", "excess m", "dominant mechanism"], rows))
    print()

    print("## Excess distribution")
    excesses = sorted(r["excess_s"] for r in runs)
    share = [r for r in runs if r["excess_s"] > max(60, 0.5 * r["slowest_s"])]
    print(f"excess seconds: median {med(excesses):.0f}, p90 {pct(excesses, 0.9):.0f}, "
          f"max {max(excesses, default=0):.0f}; "
          f"runs where excess > max(60s, half the slowest cell): {len(share)}")
    print()

    print("## Verify phase (serial, after every cell)")
    verify = [r["verify_s"] for r in runs if r["verify_s"] > 0]
    print(f"runs with a verifier: {len(verify)}; verify wall per run: "
          f"median {med(verify):.0f}s, p90 {pct(verify, 0.9):.0f}s, "
          f"max {max(verify, default=0):.0f}s, total {sum(verify) / 60:.0f} min")
    print()

    print("## OpenCode leg: model time vs waiting vs failing, per folded cell")
    per_cell = defaultdict(lambda: {"attempts": 0, "completed": 0, "failed": 0,
                                    "model_s": 0.0, "fail_s": 0.0, "wait_s": 0.0,
                                    "wait_n": 0, "backoff": 0})
    per_account = defaultdict(lambda: {"attempts": 0, "failed": 0, "fail_s": 0.0})
    for r in runs:
        for v in r["views"]:
            if v["side"] != "opencode":
                continue
            entry = per_cell[fold(v["spec"])]
            entry["attempts"] += 1 + v["superseded_n"]
            entry["completed"] += 1 if v["completed"] else 0
            entry["failed"] += (0 if v["completed"] else 1) + v["superseded_n"]
            entry["model_s"] += v["duration_s"] if v["completed"] else 0.0
            entry["fail_s"] += (0.0 if v["completed"] else v["duration_s"]) + v["superseded_s"]
            entry["backoff"] += 1 if v["backoff_marker"] else 0
            if v["span_s"] is not None:
                entry["wait_s"] += max(0.0, v["span_s"] - v["chain_s"])
                entry["wait_n"] += 1
            acct = per_account[v["account"] or "?"]
            acct["attempts"] += 1
            acct["failed"] += 0 if v["completed"] else 1
            acct["fail_s"] += 0.0 if v["completed"] else v["duration_s"]
            for account, duration_s in v["attempt_accounts"]:
                superseded = per_account[account or "?"]
                superseded["attempts"] += 1
                superseded["failed"] += 1
                superseded["fail_s"] += duration_s
    rows = []
    for spec, e in sorted(per_cell.items(), key=lambda kv: -(kv[1]["fail_s"] + kv[1]["model_s"])):
        total = e["model_s"] + e["fail_s"] + e["wait_s"]
        rows.append([
            spec, e["attempts"], f"{100 * e['failed'] / max(1, e['attempts']):.0f}%",
            f"{e['model_s'] / 60:.1f}", f"{e['fail_s'] / 60:.1f}",
            f"{e['wait_s'] / 60:.1f} (n={e['wait_n']})",
            f"{100 * e['fail_s'] / total if total else 0:.0f}%", e["backoff"],
        ])
    print(table(["cell", "attempts", "fail rate", "model min", "failing min",
                 "waiting min (stamped)", "failing share", "5xx-backoff cells"], rows))
    print()
    rows = [[acct, e["attempts"], e["failed"], f"{e['fail_s'] / 60:.1f}"]
            for acct, e in sorted(per_account.items(), key=lambda kv: -kv[1]["fail_s"])]
    print(table(["account", "attempts", "failed", "failing min"], rows))
    print()

    print("## Panels selecting more OpenCode cells than the gate admits")
    over = [r for r in runs if r["oc_n"] > GATE_LIMIT]
    print(f"runs with >{GATE_LIMIT} OpenCode cells: {len(over)} of {len(runs)}; "
          f"their excess minutes: {sum(r['excess_s'] for r in over) / 60:.0f}")


if __name__ == "__main__":
    main()
