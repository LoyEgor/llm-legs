#!/usr/bin/env python3
"""Regenerates every table in docs/analysis/review-latency-2026-08-24.md from the bench store.

Usage: python3 docs/analysis/review-latency-stats.py [--benches DIR]
           [--section A|B|C|D|recent-cases|ratchet|retry|stall-buffered|tiers|overlap|caps|all]
Read-only. The panel's own rules (cell_status, watchdog_killed, cell_pass_duration, the derived
caps, the LATE line) are imported from share/rbench rather than restated here — so the "current"
cap columns of the older sections now print the rules shipped on 2026-08-24, and `--section caps`
is their replay over the last CAP_WINDOW_DAYS.
"""
import argparse
import json
import math
import re
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from itertools import combinations
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "share"))

from rbench import catalog as _catalog  # noqa: E402
from rbench import launch as _launch  # noqa: E402
from rbench import panel as _panel  # noqa: E402
from rbench import raters as _raters  # noqa: E402
from rbench import report as _report  # noqa: E402
from rbench import store as _store  # noqa: E402

DEFAULT_BENCHES = Path.home() / ".claude-profiles/.claudeb/worker-stats/benches"
RECENT_DAYS = 14
NOW = datetime(2026, 8, 24, tzinfo=timezone.utc)
RECENT_CUTOFF = NOW - timedelta(days=RECENT_DAYS)
OVERLAP_CUTOFF = datetime(2026, 8, 13, 23, tzinfo=ZoneInfo("Europe/Kyiv"))
AGY_OVERLAP_CELLS = (
    "agy-flash35-medium-skill",
    "agy-flash35-high-skill",
    "agy-flash36-medium-skill",
    "agy-flash36-high-skill",
    "agy-flash37-medium-skill",
    "agy-flash37-high-skill",
    "agy-flash37-low-skill",
    "agy-pro-high-skill",
)


def pct(values, q):
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    pos = (len(ordered) - 1) * q
    low = math.floor(pos)
    high = math.ceil(pos)
    if low == high:
        return float(ordered[low])
    return ordered[low] + (ordered[high] - ordered[low]) * (pos - low)


def median(values):
    return statistics.median(values) if values else None


def fmt(value, unit="s", width=7):
    if value is None:
        return "-".rjust(width)
    if unit == "s":
        return f"{value / 1000:.0f}".rjust(width)
    return f"{value:.0f}".rjust(width)


def table(header, rows, aligns=None):
    columns = list(zip(*([header] + rows))) if rows else [[h] for h in header]
    widths = [max(len(str(cell)) for cell in column) for column in columns]
    aligns = aligns or ["<"] + [">"] * (len(header) - 1)
    out = []

    def line(cells):
        return "| " + " | ".join(
            f"{str(cell):{align}{width}}" for cell, align, width in zip(cells, aligns, widths)
        ) + " |"

    out.append(line(header))
    out.append("|" + "|".join(
        ("-" * (width + 2)) if align == "<" else (("-" * (width + 1)) + ":")
        for align, width in zip(aligns, widths)
    ) + "|")
    out.extend(line(row) for row in rows)
    return "\n".join(out)


class Cell:
    __slots__ = (
        "run", "rater", "model", "effort", "side", "pair", "status", "pass_ms", "total_ms",
        "passes", "quiet_ms", "stalled_s", "stalled_retry_s", "watchdog", "timeout_s",
        "killed_cap_s", "findings", "confirmed", "confirmed_keys", "stderr", "started_at",
        "finished_at", "superseded_ms", "attempts",
    )

    def __init__(self, **kwargs):
        for key, value in kwargs.items():
            setattr(self, key, value)

    @property
    def wall_ms(self):
        if self.total_ms is not None:
            return self.total_ms
        return self.pass_ms

    @property
    def completed(self):
        return self.status == "completed"


class Run:
    __slots__ = ("run_id", "started", "finished", "tier", "commit", "repo", "cells", "triaged",
                 "triaged_at", "mtime", "max_scheme")

    @property
    def wall_ms(self):
        if self.started and self.finished:
            return (self.finished - self.started).total_seconds() * 1000
        return None


def attempt_view(row):
    return {
        "duration_ms": row.get("duration_ms"),
        "status": _panel.cell_status(row),
        "watchdog": _panel.watchdog_killed(row),
        "stalled_s": row.get("stalled_s"),
        "cap_s": _panel.timeout_seconds_from_row(row),
        "findings": row.get("findings") if isinstance(row.get("findings"), int) else 0,
    }


def cell_tag(cell_or_attempt):
    if cell_or_attempt["stalled_s"]:
        return "stall"
    if cell_or_attempt["watchdog"]:
        return "cap"
    return {"completed": "ok", "not_run": "skip"}.get(cell_or_attempt["status"], "err")


def confirmed_by_rater(run_dir):
    """(rater -> confirmed count, rater -> Counter of (file, line) keys) for a triaged run: two
    confirmed findings on one line are two catches, and a cut that loses both loses two."""
    rows = None
    reported = run_dir / "reported.json"
    if reported.exists():
        try:
            rows = json.loads(reported.read_text()).get("rows") or []
        except (OSError, ValueError):
            rows = None
    if rows is None and (run_dir / "verdicts.jsonl").exists():
        try:
            rows = _store.read_jsonl(run_dir / "verdicts.jsonl")
        except (OSError, ValueError):
            rows = None
    if rows is None:
        return None, None
    counts = Counter()
    keys = defaultdict(Counter)
    findings = {}
    for row in rows:
        if not isinstance(row, dict) or row.get("verdict") != "confirmed":
            continue
        rater, idx = row.get("rater"), row.get("idx")
        if not rater or not isinstance(idx, int) or isinstance(idx, bool):
            continue
        counts[rater] += 1
        if rater not in findings:
            findings[rater] = _store.finding_rows(run_dir, rater)
        if 0 <= idx < len(findings[rater]):
            finding = findings[rater][idx]
            keys[rater][(str(finding.get("file") or ""), finding.get("line"))] += 1
        else:
            keys[rater][(rater, idx)] += 1
    return counts, keys


def triaged_at(run_dir):
    for name in ("reported.json", "verdicts.jsonl"):
        try:
            return datetime.fromtimestamp((run_dir / name).stat().st_mtime, tz=timezone.utc)
        except OSError:
            continue
    return None


def load(benches):
    runs = []
    if not benches.is_dir():
        return runs
    for directory in sorted(benches.iterdir()):
        meta_path = directory / "meta.json"
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text())
        except (OSError, ValueError):
            continue
        rows = list(meta.get("rater_runs", ()))
        if not rows:
            continue
        run = Run()
        run.run_id = meta.get("run_id") or directory.name
        run.started = _panel.run_started_at(directory, meta)
        run.finished = _panel.run_finished_at(meta)
        run.tier = meta.get("tier") or ""
        run.commit = meta.get("commit") or ""
        run.repo = meta.get("repo") or ""
        run.mtime = meta_path.stat().st_mtime
        run.max_scheme = bool(meta.get("max"))
        counts, keys = confirmed_by_rater(directory)
        run.triaged = counts is not None
        run.triaged_at = triaged_at(directory) if run.triaged else None
        final, attempts = _panel.cell_attempt_rows(rows)
        durations = meta.get("durations") or {}
        run.cells = []
        for row in final:
            rater = row.get("rater") or ""
            pair = _panel.panel_cell_key(row)
            if pair is None:
                continue
            total = row.get("duration_ms")
            if not isinstance(total, (int, float)) or isinstance(total, bool) or total < 0:
                total = durations.get(rater)
            superseded = sum(
                attempt.get("duration_ms") or 0 for attempt in attempts.get(rater, ())
            )
            run.cells.append(Cell(
                run=run,
                rater=rater,
                model=pair[0],
                effort=pair[1],
                side=row.get("side") or _raters.rater_side(rater),
                pair=pair,
                status=_panel.cell_status(row),
                pass_ms=_panel.cell_pass_duration(row),
                total_ms=total if isinstance(total, (int, float)) else None,
                passes=row.get("passes") if isinstance(row.get("passes"), int) else 1,
                quiet_ms=row.get("max_quiet_ms"),
                stalled_s=row.get("stalled_s"),
                stalled_retry_s=row.get("stalled_retry_s"),
                watchdog=_panel.watchdog_killed(row),
                timeout_s=_panel.timeout_seconds_from_row(row),
                killed_cap_s=row.get("killed_cap_s"),
                findings=row.get("findings") if isinstance(row.get("findings"), int) else 0,
                confirmed=(counts or {}).get(rater, 0),
                confirmed_keys=(keys or {}).get(rater, Counter()),
                stderr=row.get("stderr") or "",
                started_at=_store.parse_iso_timestamp(row.get("started_at")),
                finished_at=_store.parse_iso_timestamp(row.get("finished_at")),
                superseded_ms=superseded,
                attempts=[attempt_view(att) for att in attempts.get(rater, ())]
                + [attempt_view(row)],
            ))
        runs.append(run)
    return runs


def recent(run):
    return run.started is not None and run.started >= RECENT_CUTOFF


# ---------------------------------------------------------------- A: per-cell duration

def section_a(runs, out):
    by_pair = defaultdict(list)
    side_of = {}
    for run in runs:
        for cell in run.cells:
            by_pair[cell.pair].append(cell)
            side_of[cell.pair] = cell.side

    # The LATE line's own reference: max(3x median, 120s) against the pair's median completion.
    pair_median = {
        pair: median([c.pass_ms for c in cells if c.completed and c.pass_ms is not None])
        for pair, cells in by_pair.items()
    }

    rows = []
    for pair, cells in by_pair.items():
        done = [c.pass_ms for c in cells if c.completed and c.pass_ms is not None]
        if not done:
            continue
        med = pair_median[pair]
        late = sum(
            1 for c in cells
            if c.completed and c.pass_ms is not None
            and _report.late_review_line(c.rater, c.pass_ms, med)
        )
        rows.append((
            f"{pair[0]}-{pair[1] or 'off'}",
            side_of[pair],
            len(done),
            fmt(med), fmt(pct(done, 0.9)), fmt(max(done)),
            f"{100 * late / len(done):.0f}%",
            sum(1 for c in cells if c.stalled_s or c.stalled_retry_s),
            sum(1 for c in cells if c.watchdog),
            sum(1 for c in cells if not c.completed and not c.watchdog and not c.stalled_s),
        ))
    rows.sort(key=lambda row: (row[1], -row[2]))
    out.append("### A. Per-cell duration (completions, per invocation)\n")
    out.append(table(
        ["pair", "side", "n", "med s", "p90 s", "max s", "LATE", "stall", "cap", "err"],
        rows,
    ))

    split = []
    for pair, cells in by_pair.items():
        new = [c.pass_ms for c in cells if recent(c.run) and c.completed and c.pass_ms is not None]
        old = [c.pass_ms for c in cells
               if not recent(c.run) and c.completed and c.pass_ms is not None]
        if len(new) < 4 or len(old) < 4:
            continue
        ratio = median(new) / median(old)
        split.append((
            f"{pair[0]}-{pair[1] or 'off'}",
            side_of[pair],
            len(old), fmt(median(old)), fmt(pct(old, 0.9)),
            len(new), fmt(median(new)), fmt(pct(new, 0.9)),
            f"{ratio:.2f}x",
        ))
    split.sort(key=lambda row: -float(row[-1][:-1]))
    out.append(f"\n### A2. Last {RECENT_DAYS} days vs earlier (pairs with n>=4 both sides)\n")
    out.append(table(
        ["pair", "side", "n old", "med", "p90", "n new", "med", "p90", "med ratio"],
        split,
    ))

    # Kill/error rate by side and window, since a killed cell has no duration to median.
    windows = []
    for side in sorted({c.side for run in runs for c in run.cells}):
        for label, keep in (("earlier", lambda r: not recent(r)), ("recent", recent)):
            cells = [c for run in runs if keep(run) for c in run.cells if c.side == side]
            if not cells:
                continue
            windows.append((
                side, label, len(cells),
                f"{100 * sum(1 for c in cells if c.completed) / len(cells):.0f}%",
                f"{100 * sum(1 for c in cells if c.watchdog) / len(cells):.0f}%",
                f"{100 * sum(1 for c in cells if c.stalled_s or c.stalled_retry_s) / len(cells):.1f}%",
            ))
    out.append("\n### A3. Outcome mix by side and window\n")
    out.append(table(["side", "window", "cells", "completed", "cap-killed", "stalled"], windows))


# ---------------------------------------------------------------- B: OpenCode concurrency

def gate_schedule(cells, limit=_launch.OPENCODE_MAX_CONCURRENCY):
    """Replays PriorityGate over one run's OpenCode cells: admission order is longest-EXPECTED
    first (gate_admission_key), and a cell holds its slot for its own wall. Returns
    rater -> (queue position, concurrent-at-start, wait_ms, finish_ms).
    """
    ordered = sorted(
        cells,
        key=lambda c: (-_launch.opencode_expected_s({"model": c.model, "effort": c.effort}),
                       c.rater),
    )
    running = []  # finish times of admitted cells
    schedule = {}
    clock = 0.0
    for position, cell in enumerate(ordered):
        if len(running) >= limit:
            running.sort()
            clock = max(clock, running.pop(0))
        duration = cell.wall_ms or 0
        schedule[cell.rater] = (position, min(position, limit - 1) if position < limit
                                else limit, clock, clock + duration)
        running.append(clock + duration)
    return schedule


def section_b(runs, out):
    measured = []
    for run in runs:
        for cell in run.cells:
            if cell.side != "opencode" or not cell.started_at or not cell.finished_at:
                continue
            wall = (cell.finished_at - cell.started_at).total_seconds() * 1000
            # A run that stamped each chunk pass as its own row holds the LAST pass's window
            # beside the summed duration (the B7 filter): its wait would come out negative.
            if wall + 1000 < (cell.wall_ms or 0):
                continue
            measured.append((run, cell, wall, wall - (cell.wall_ms or 0)))
    waits = [row[3] for row in measured]
    out.append("### B1. Measured gate wait (rows carrying started_at/finished_at)\n")
    if waits:
        out.append(table(
            ["oc cells", "med wait s", "p90 wait s", "max wait s", "> 5s wait"],
            [[len(waits), fmt(median(waits)), fmt(pct(waits, 0.9)), fmt(max(waits)),
              f"{100 * sum(1 for w in waits if w > 5000) / len(waits):.0f}%"]],
        ))
    out.append(
        "\nduration_ms is the process wall only: the gate is acquired before the clock starts "
        "(launch.py run_opencode), so a queued cell's wait shows up in started_at..finished_at "
        "minus duration_ms and nowhere else. The stamps are the final attempt's own, so a "
        "superseded attempt's time is not in the window and is not subtracted."
    )

    by_position = defaultdict(list)
    panel_size = defaultdict(list)
    for run in runs:
        oc = [c for c in run.cells if c.side == "opencode" and c.wall_ms]
        if not oc:
            continue
        schedule = gate_schedule(oc)
        for cell in oc:
            position, conc, wait, _ = schedule[cell.rater]
            if not cell.completed or cell.pass_ms is None:
                continue
            by_position[min(position, 8)].append(cell.pass_ms)
            panel_size[min(len(oc), 8)].append(cell.pass_ms)

    out.append("\n### B2. Simulated admission position vs duration (completions)\n")
    out.append(table(
        ["position", "n", "med s", "p90 s"],
        [[str(p) + ("+" if p == 8 else ""), len(v), fmt(median(v)), fmt(pct(v, 0.9))]
         for p, v in sorted(by_position.items())],
    ))
    out.append("\n### B3. OpenCode cells in the panel vs duration (completions)\n")
    out.append(table(
        ["oc cells in run", "n", "med s", "p90 s"],
        [[str(k) + ("+" if k == 8 else ""), len(v), fmt(median(v)), fmt(pct(v, 0.9))]
         for k, v in sorted(panel_size.items())],
    ))

    markers = (
        ("5xx retry+backoff", "retrying in"),
        ("buffered->stream escalation", "streaming instead"),
        ("reasoning-off fallback", "falling back to"),
    )
    rows = []
    oc_cells = [c for run in runs for c in run.cells if c.side == "opencode"]
    for label, needle in markers:
        hit = [c for c in oc_cells if needle in c.stderr]
        clean = [c for c in oc_cells if needle not in c.stderr and c.completed and c.pass_ms]
        done = [c.pass_ms for c in hit if c.completed and c.pass_ms]
        rows.append([
            label, len(hit),
            f"{100 * len(hit) / max(1, len(oc_cells)):.0f}%",
            fmt(median(done)), fmt(median([c.pass_ms for c in clean])),
            f"{100 * sum(1 for c in hit if c.completed) / max(1, len(hit)):.0f}%",
        ])
    out.append("\n### B4. Client-side retry markers on OpenCode cells\n")
    out.append(table(
        ["marker", "cells", "share", "med s hit", "med s clean", "completed"], rows,
    ))

    # Failure streaks per model walked per RUN, the "15 runs in a row" claim: a run fails for a
    # model when none of its cells of that model completed, and every column reads that one
    # predicate.
    streaks = []
    for model in sorted({c.model for c in oc_cells}):
        series = []
        for run in sorted(runs, key=lambda run: run.run_id):
            cells = [c for c in run.cells if c.model == model and c.side == "opencode"]
            if cells:
                series.append(all(not c.completed for c in cells))
        best = current = 0
        for failed in series:
            current = current + 1 if failed else 0
            best = max(best, current)
        fails = sum(series)
        if series:
            streaks.append([
                model, len(series), fails,
                f"{100 * fails / len(series):.0f}%", best,
            ])
    streaks.sort(key=lambda row: -row[4])
    out.append("\n### B5. OpenCode failure streaks by model, per run (all history)\n")
    out.append(table(
        ["model", "runs", "failed runs", "fail %", "longest fail streak (runs)"], streaks,
    ))

    # Buffered-ness: a cell whose silence equals its whole run cannot be stall-cut.
    rows = []
    for model in sorted({c.model for c in oc_cells}):
        ratios = [
            c.quiet_ms / c.pass_ms for c in oc_cells
            if c.model == model and c.completed and c.pass_ms and c.quiet_ms is not None
            and c.pass_ms > 0
        ]
        if ratios:
            rows.append([model, len(ratios), f"{median(ratios):.2f}", f"{max(ratios):.2f}",
                         "yes" if model in _catalog.OPENCODE_STREAM_MODELS else "no"])
    out.append("\n### B6. Silence-to-duration ratio per OpenCode model (completions)\n")
    out.append(table(["model", "n", "med gap/dur", "max gap/dur", "--stream"], rows))

    # A cell holds a gate slot from started_at to finished_at, but records only its process wall.
    # Every chunk pass re-acquires the gate, so a chunked cell queues once per pass.
    rows = []
    dropped = 0
    for side in ("opencode", "agy", "codex", "claude"):
        stamped = []
        for run in runs:
            for cell in run.cells:
                if cell.side != side or not cell.started_at or not cell.finished_at:
                    continue
                # A run that records every chunk pass as its own row stamps the cell with the LAST
                # pass's window while duration_ms holds the sum, so its occupancy is unreadable.
                span = (cell.finished_at - cell.started_at).total_seconds() * 1000
                if span + 1000 < (cell.wall_ms or 0):
                    dropped += 1
                    continue
                stamped.append(cell)
        if not stamped:
            continue
        overhead = [
            (c.finished_at - c.started_at).total_seconds() * 1000 - (c.wall_ms or 0)
            for c in stamped
        ]
        occupancy = [(c.finished_at - c.started_at).total_seconds() * 1000 for c in stamped]
        rows.append([
            side, len(stamped), fmt(median([c.wall_ms or 0 for c in stamped])),
            fmt(median(occupancy)), fmt(median(overhead)), fmt(pct(overhead, 0.9)),
            fmt(max(overhead)),
        ])
    out.append("\n### B7. Recorded duration vs slot occupancy (rows carrying timestamps)\n")
    out.append(table(
        ["side", "n", "med duration s", "med occupancy s", "med hidden s", "p90 hidden s",
         "max hidden s"],
        rows,
    ))
    out.append(
        f"\n{dropped} stamped rows dropped: their run recorded each chunk pass as its own row, so "
        "the cell's window and its summed duration do not describe the same thing."
    )
    worst = sorted(
        (
            ((c.finished_at - c.started_at).total_seconds() * 1000 - (c.wall_ms or 0), run, c)
            for run in runs for c in run.cells
            if c.started_at and c.finished_at and c.side == "opencode"
        ),
        key=lambda item: item[0], reverse=True,
    )[:8]
    out.append("\n### B8. The largest hidden OpenCode waits on record\n")
    out.append(table(
        ["run", "cell", "duration s", "occupancy s", "hidden s", "exit"],
        [[run.run_id[:16], cell.rater, fmt(cell.wall_ms),
          fmt((cell.finished_at - cell.started_at).total_seconds() * 1000), fmt(hidden),
          cell.status]
         for hidden, run, cell in worst],
    ))


# ---------------------------------------------------------------- C: stall / streaming

def handed_caps(watchdog_caps, pair):
    """The duration cap the launch hands a pair, as `T0-T1/T2-T3` where the agy ceiling splits it."""
    low = _panel.cell_timeout_seconds(watchdog_caps, pair, "T1")
    high = _panel.cell_timeout_seconds(watchdog_caps, pair, "T2")
    return f"{low:.0f}" if low == high else f"{low:.0f}/{high:.0f}"


def section_c(runs, benches, out):
    by_pair = defaultdict(list)
    side_of = {}
    for run in runs:
        for cell in run.cells:
            side_of[cell.pair] = cell.side
            if cell.completed and cell.pass_ms and cell.quiet_ms is not None:
                by_pair[cell.pair].append(cell)
    watchdog_caps, stall_caps = _panel.panel_cap_timeouts(benches, now=NOW)
    rows = []
    for pair, cells in sorted(by_pair.items()):
        gaps = [c.quiet_ms for c in cells]
        ratios = [c.quiet_ms / c.pass_ms for c in cells if c.pass_ms]
        cap = stall_caps.get(pair)
        durations = [c.pass_ms for c in cells]
        rows.append([
            f"{pair[0]}-{pair[1] or 'off'}", side_of[pair],
            len(gaps), fmt(median(gaps)), fmt(pct(gaps, 0.95)), fmt(max(gaps)),
            f"{median(ratios):.2f}", f"{max(ratios):.2f}",
            f"{median(gaps) / median(durations):.2f}",
            f"{cap:.0f}" if cap else "none",
            f"{pct(gaps, 0.95) / 1000 + 60:.0f}",
            handed_caps(watchdog_caps, pair),
        ])
    rows.sort(key=lambda row: (row[1], row[0]))
    out.append("### C1. Longest silent gap per pair, and the caps derived from it\n")
    out.append(table(
        ["pair", "side", "n", "med gap s", "p95 gap s", "max gap s", "med gap/dur",
         "max gap/dur", "medgap/meddur", "stall cap s", "p95+60 s", "dur cap s"],
        rows,
    ))
    streaming = [row for row in rows if row[-3] != "none"]
    out.append(f"\n{len(streaming)} of {len(rows)} pairs carry a stall cap.")

    kills = [
        (run, cell) for run in runs for cell in run.cells
        if cell.stalled_s or cell.stalled_retry_s
    ]
    rows = []
    for run, cell in sorted(kills, key=lambda item: item[0].run_id):
        rows.append([
            run.run_id[:16], cell.rater,
            f"{cell.stalled_retry_s or cell.stalled_s:.0f}",
            cell.status, cell.findings, cell.confirmed,
            "retried" if cell.stalled_retry_s else "final",
        ])
    out.append("\n### C2. Every stall kill on record\n")
    out.append(table(
        ["run", "cell", "cap s", "final status", "findings", "confirmed", "kind"], rows,
    ))
    retried = [c for _, c in kills if c.stalled_retry_s]
    out.append(
        f"\n{len(retried)} stall kills were followed by an in-cell retry; "
        f"{sum(1 for c in retried if c.completed)} of those retries completed, "
        f"{sum(1 for c in retried if c.findings)} with findings, "
        f"{sum(1 for c in retried if c.confirmed)} with a confirmed finding."
    )


# ---------------------------------------------------------------- D: cap simulation

def panel_wall(run, value_of):
    """The panel's wall in ms when each cell costs value_of(cell): every non-gated cell starts at
    t=0 in its own thread, OpenCode cells replay `PriorityGate`.
    """
    finishes = panel_finishes(run, value_of)
    return max(finishes.values()) if finishes else 0.0


def panel_finishes(run, value_of):
    """rater -> the ms at which the cell finishes under `panel_wall`'s model."""
    finishes = {cell.rater: value_of(cell) for cell in run.cells if cell.side != "opencode"}
    oc = sorted(
        (cell for cell in run.cells if cell.side == "opencode"),
        key=lambda cell: (-_launch.opencode_expected_s(
            {"model": cell.model, "effort": cell.effort}), cell.rater),
    )
    running = []
    clock = 0.0
    for cell in oc:
        if len(running) >= _launch.OPENCODE_MAX_CONCURRENCY:
            running.sort()
            clock = max(clock, running.pop(0))
        running.append(clock + value_of(cell))
        finishes[cell.rater] = clock + value_of(cell)
    return finishes


def modelled_wall(run, cap_of=None, retry_ms=None):
    """Panel wall in ms under a cap policy: every non-gated cell runs from t=0 in its own thread,
    OpenCode cells replay the gate. cap_of(cell) -> seconds or None.

    `cell_retry_cause` spends the cell's one retry on a watchdog kill, so a cut cell costs its cap
    PLUS whatever the retry then takes. retry_ms(cell, limit) prices that second attempt: None
    means the cap kill ends the cell.
    """
    def capped(cell):
        wall = cell.wall_ms or 0
        cap = cap_of(cell) if cap_of else None
        if cap is None:
            return wall, False
        limit = cap * 1000 * max(1, cell.passes)
        if wall > limit:
            return (limit + (retry_ms(cell, limit) if retry_ms else 0), True)
        return (wall, False)

    walls = []
    oc = []
    killed = []
    for cell in run.cells:
        value, cut = capped(cell)
        if cut:
            killed.append(cell)
        if cell.side == "opencode":
            oc.append((cell, value))
        else:
            walls.append(value)
    if oc:
        ordered = sorted(
            oc,
            key=lambda item: (-_launch.opencode_expected_s(
                {"model": item[0].model, "effort": item[0].effort}), item[0].rater),
        )
        running = []
        clock = 0.0
        for cell, value in ordered:
            if len(running) >= _launch.OPENCODE_MAX_CONCURRENCY:
                running.sort()
                clock = max(clock, running.pop(0))
            running.append(clock + value)
            walls.append(clock + value)
    return (max(walls) if walls else 0.0), killed


def unique_lost(cut_keys, survivors):
    """Catches on cut cells that no surviving cell repeats: the cut cells' keys are pooled
    first, so a defect two cut copies both caught is lost once, and counted per catch."""
    return sum(count for key, count in cut_keys.items() if key not in survivors)


def critical_path(runs, out, label):
    owners = Counter()
    margins = defaultdict(list)
    for run in runs:
        wall, _ = modelled_wall(run)
        if not wall:
            continue
        # The owner is the cell that FINISHES last behind the gate, not the longest raw one.
        finishes = panel_finishes(run, lambda c: c.wall_ms or 0)
        slowest = max(run.cells, key=lambda c: finishes[c.rater])
        others = sorted(finishes[c.rater] for c in run.cells if c is not slowest)
        owners[(slowest.side, slowest.pair)] += 1
        margins[(slowest.side, slowest.pair)].append(wall - (others[-1] if others else 0))
    rows = []
    total = sum(owners.values())
    for (side, pair), count in owners.most_common(12):
        rows.append([
            f"{pair[0]}-{pair[1] or 'off'}", side, count,
            f"{100 * count / total:.0f}%", fmt(median(margins[(side, pair)])),
        ])
    out.append(f"### D0. Who owns the panel wall ({label}, {total} runs)\n")
    out.append(table(
        ["slowest cell", "side", "runs", "share", "med lead over 2nd s"], rows,
    ))


def policy_table(runs, benches, out):
    by_pair = defaultdict(list)
    by_side = defaultdict(list)
    for run in runs:
        for cell in run.cells:
            if cell.completed and cell.pass_ms is not None:
                by_pair[cell.pair].append(cell.pass_ms)
                by_side[cell.side].append(cell.pass_ms)

    derived, stall_caps = _panel.panel_cap_timeouts(benches, now=NOW)

    def pair_cap(quantile=None, multiple=None, floor=0):
        def cap_of(cell):
            done = by_pair.get(cell.pair)
            if not done:
                return None
            if quantile is not None:
                value = pct(done, quantile)
            else:
                value = multiple * median(done)
            return max(floor, value / 1000)
        return cap_of

    def side_cap(quantile, floor=0):
        caps = {side: pct(values, quantile) / 1000 for side, values in by_side.items()}
        return lambda cell: max(floor, caps.get(cell.side, 0)) or None

    def flat(seconds):
        return lambda cell: seconds

    def current(cell):
        return _panel.cell_timeout_seconds(derived, cell.pair, cell.run.tier or None)

    def late_rule(ceiling=None):
        """The report's own LATE line promoted to a cap: max(3 x median, 120s), which adds no
        constant the panel does not already print."""
        def cap_of(cell):
            done = by_pair.get(cell.pair)
            if not done:
                return None
            value = max(
                _report.REVIEW_LATE_MULTIPLIER * median(done),
                _report.REVIEW_LATE_FLOOR_S * 1000,
            ) / 1000
            return min(value, ceiling) if ceiling else value
        return cap_of

    def late_with_side_ceiling(ceilings):
        base = late_rule()

        def cap_of(cell):
            value = base(cell)
            ceiling = ceilings.get(cell.side)
            if value is None:
                return ceiling
            return min(value, ceiling) if ceiling else value
        return cap_of

    def side_ceiling_only(ceilings):
        """A flat ceiling on the two cheap, fast sides and the panel's own derived cap everywhere
        else, so the sides that produce the confirmed findings keep their long tail."""
        def cap_of(cell):
            return ceilings.get(cell.side) or current(cell)
        return cap_of

    def stall_then_cap(cell):
        cap = stall_caps.get(cell.pair)
        p95 = pct(by_pair.get(cell.pair) or [], 0.95)
        candidates = [value for value in (cap, (p95 / 1000) if p95 else None) if value]
        return max(60, min(candidates)) if candidates else _catalog.DURATION_CAP_DEFAULT_S

    policies = [
        ("current derived", current),
        ("pair p95 (>=60s)", pair_cap(quantile=0.95, floor=60)),
        ("pair p90 (>=60s)", pair_cap(quantile=0.90, floor=60)),
        ("pair 3x median (>=60s)", pair_cap(multiple=3, floor=60)),
        ("pair 2x median (>=60s)", pair_cap(multiple=2, floor=60)),
        ("side p95", side_cap(0.95)),
        ("flat 300s", flat(300)),
        ("flat 600s", flat(600)),
        ("LATE rule (3x med, >=120s)", late_rule()),
        ("LATE rule, <=600s ceiling", late_rule(600)),
        ("LATE rule, <=450s ceiling", late_rule(450)),
        ("LATE + agy/oc <=300s", late_with_side_ceiling({"agy": 300, "opencode": 300})),
        ("LATE + agy/oc <=240s", late_with_side_ceiling({"agy": 240, "opencode": 240})),
        ("LATE + agy/oc <=300s, sol/opus <=900s",
         late_with_side_ceiling({"agy": 300, "opencode": 300, "codex": 900, "claude": 900})),
        ("stall-or-p95", stall_then_cap),
        ("agy/oc <=300s, rest derived", side_ceiling_only({"agy": 300, "opencode": 300})),
        ("agy/oc <=240s, rest derived", side_ceiling_only({"agy": 240, "opencode": 240})),
        ("agy 300s, oc 120s, rest derived",
         side_ceiling_only({"agy": 300, "opencode": 120})),
    ]
    recommended = side_ceiling_only({"agy": 300, "opencode": 120})

    base_walls = {}
    for run in runs:
        base_walls[run.run_id], _ = modelled_wall(run)

    total_cells = sum(len(run.cells) for run in runs)
    all_confirmed = sum(c.confirmed for run in runs for c in run.cells)
    rows = []
    for label, cap_of in policies:
        killed_cells = 0
        killed_with_confirmed = 0
        confirmed_on_killed = 0
        lost_unique = 0
        after = []
        before = []
        saved_runs = 0
        for run in runs:
            wall, killed = modelled_wall(run, cap_of)
            before.append(base_walls[run.run_id])
            after.append(wall)
            if wall < base_walls[run.run_id] - 1000:
                saved_runs += 1
            survivors = set()
            for cell in run.cells:
                if cell not in killed:
                    survivors |= set(cell.confirmed_keys)
            cut_keys = Counter()
            for cell in killed:
                killed_cells += 1
                if cell.confirmed_keys:
                    killed_with_confirmed += 1
                confirmed_on_killed += cell.confirmed
                cut_keys += cell.confirmed_keys
            lost_unique += unique_lost(cut_keys, survivors)
        rows.append([
            label,
            f"{killed_cells} ({100 * killed_cells / total_cells:.1f}%)",
            f"{saved_runs} ({100 * saved_runs / len(runs):.0f}%)",
            killed_with_confirmed,
            confirmed_on_killed,
            f"{lost_unique} ({100 * lost_unique / max(1, all_confirmed):.1f}%)",
            fmt(median(before)), fmt(median(after)),
            fmt(pct(before, 0.9)), fmt(pct(after, 0.9)),
            f"{(median(after) / median(before) - 1) * 100:+.0f}%",
        ])
    out.append(
        f"### D. Cap policies over {len(runs)} runs, {total_cells} cells, "
        f"{all_confirmed} confirmed findings\n"
    )
    out.append(table(
        ["policy", "cells cut", "runs faster", "cut cells w/ confirmed", "confirmed on cut",
         "unique lost", "wall med", "-> med", "wall p90", "-> p90", "med saving"],
        rows,
    ))

    # 8 of the 9 cap-kill retries on record completed, most of them fast, so the honest middle
    # prices the retry at the pair's median completion; the cap itself is the worst case.
    def retry_at_median(cell, limit):
        done = by_pair.get(cell.pair)
        return min(limit, median(done)) if done else limit

    def retry_at_cap(cell, limit):
        return limit

    retry_rows = []
    before = [base_walls[run.run_id] for run in runs]
    for label, cap_of in policies:
        cells = []
        for name, retry_ms in (("no retry", None), ("retry at median", retry_at_median),
                               ("retry at cap", retry_at_cap)):
            after = [modelled_wall(run, cap_of, retry_ms=retry_ms)[0] for run in runs]
            cells.append((fmt(median(after)), fmt(pct(after, 0.9))))
        retry_rows.append([label, fmt(median(before)), fmt(pct(before, 0.9))]
                          + [value for pair in cells for value in pair])
    out.append(
        "\n#### D1b. What the cell's automatic retry does to each policy "
        "(`cell_retry_cause` spends one retry on a cap kill)\n"
    )
    out.append(table(
        ["policy", "wall med", "wall p90", "cut med", "cut p90", "+retry med", "+retry p90",
         "+cap med", "+cap p90"],
        retry_rows,
    ))

    per_side = defaultdict(lambda: [0, 0, 0, 0])
    for run in runs:
        _, killed = modelled_wall(run, recommended)
        survivors = set()
        cut_keys = defaultdict(Counter)
        for cell in run.cells:
            if cell not in killed:
                survivors |= set(cell.confirmed_keys)
        for cell in run.cells:
            entry = per_side[cell.side]
            entry[0] += 1
            if cell in killed:
                entry[1] += 1
                entry[2] += cell.confirmed
                cut_keys[cell.side] += cell.confirmed_keys
        for side, keys in cut_keys.items():
            per_side[side][3] += unique_lost(keys, survivors)
    out.append("\n#### D1. The recommended policy, per side\n")
    out.append(table(
        ["side", "cells", "cut", "cut %", "confirmed on cut", "unique lost"],
        [[side, total, cut, f"{100 * cut / max(1, total):.1f}%", found, lost]
         for side, (total, cut, found, lost) in sorted(per_side.items())],
    ))


def section_d(runs, benches, out):
    critical_path(runs, out, "all history")
    windowed = [run for run in runs if recent(run)]
    out.append("")
    critical_path(windowed, out, f"last {RECENT_DAYS} days")
    out.append("")
    policy_table(runs, benches, out)
    if windowed:
        out.append(f"\n#### D2. Same policies, last {RECENT_DAYS} days only\n")
        policy_table(windowed, benches, out)

    measured = [
        (run, (run.finished - run.started).total_seconds() * 1000)
        for run in runs if run.started and run.finished
    ]
    modelled = [(run, modelled_wall(run)[0]) for run, _ in measured]
    ratios = [
        model / real for (_, real), (_, model) in zip(measured, modelled) if real > 1000
    ]
    out.append("\n#### D3. Wall model vs recorded run wall\n")
    out.append(table(
        ["runs", "med recorded s", "med modelled s", "med model/recorded", "p10", "p90"],
        [[len(measured), fmt(median([value for _, value in measured])),
          fmt(median([value for _, value in modelled])),
          f"{median(ratios):.2f}", f"{pct(ratios, 0.1):.2f}", f"{pct(ratios, 0.9):.2f}"]],
    ))


# ---------------------------------------------------------------- recent cases

def occupancy_ms(cell):
    return (cell.wall_ms or 0) + (cell.superseded_ms or 0)


def attempt_chain(cell):
    return ">".join(cell_tag(attempt) for attempt in cell.attempts)


def cause_phrase(cell):
    kills = [a for a in cell.attempts if a["watchdog"] or a["stalled_s"]]
    minutes = occupancy_ms(cell) / 60000
    if kills:
        legs = ", ".join(
            f"{(attempt['duration_ms'] or 0) / 60000:.1f}m {cell_tag(attempt)}"
            for attempt in cell.attempts
        )
        return f"{cell.rater}: {legs} = {minutes:.1f}m"
    if cell.completed:
        return f"{cell.rater} completed in {minutes:.1f}m, no cap fired"
    return f"{cell.rater} {_panel.failure_reason(cell.stderr)} after {minutes:.1f}m"


def section_recent_cases(runs, out, limit=20):
    latest = sorted(runs, key=lambda run: run.mtime)[-limit:]
    rows = []
    for run in latest:
        wall = run.wall_ms if run.wall_ms is not None else modelled_wall(run)[0]
        ranked = sorted(run.cells, key=occupancy_ms, reverse=True)[:3]
        slowest = " / ".join(
            f"{cell.rater} {occupancy_ms(cell) / 60000:.1f}m {attempt_chain(cell)}"
            for cell in ranked
        )
        tier = run.tier + ("+max" if run.max_scheme else "")
        rows.append([
            run.run_id[:24], tier or "?", len(run.cells),
            f"{wall / 60000:.1f}",
            f"{_catalog.REVIEW_TIERS.get(run.tier, {}).get('budget_min', '-')}",
            slowest, cause_phrase(ranked[0]) if ranked else "-",
        ])
    out.append(f"### R. The last {len(latest)} runs by mtime\n")
    out.append(table(
        ["run", "tier", "cells", "wall m", "budget m", "3 slowest cells", "cause of the wall"],
        rows, aligns=["<", "<", ">", ">", ">", "<", "<"],
    ))
    over = [
        run for run in latest
        if run.wall_ms and _catalog.REVIEW_TIERS.get(run.tier, {}).get("budget_min")
        and run.wall_ms / 60000 > _catalog.REVIEW_TIERS[run.tier]["budget_min"]
    ]
    out.append(
        f"\n{len(over)} of {len(latest)} ran over their tier's budget; "
        f"median overshoot {median([run.wall_ms / 60000 / _catalog.REVIEW_TIERS[run.tier]['budget_min'] for run in over]) or 0:.1f}x."
    )


# ---------------------------------------------------------------- cap ratchet

def week_index(run, weeks=3):
    """0 = the most recent 7 days, 1 = the 7 before that, ... None = older than `weeks` weeks."""
    if not run.started:
        return None
    age = max(0, (NOW - run.started).days)
    index = age // 7
    return index if index < weeks else None


def section_ratchet(runs, out, weeks=3):
    caps = defaultdict(lambda: defaultdict(list))
    done = defaultdict(lambda: defaultdict(list))
    for run in runs:
        index = week_index(run, weeks)
        if index is None:
            continue
        for cell in run.cells:
            if cell.timeout_s:
                caps[cell.pair][index].append(cell.timeout_s)
            if cell.completed and cell.pass_ms is not None:
                done[cell.pair][index].append(cell.pass_ms)
    rows = []
    for pair in sorted(caps, key=lambda key: -sum(len(v) for v in caps[key].values())):
        windows = []
        for index in range(weeks - 1, -1, -1):
            window_caps = caps[pair].get(index) or []
            window_done = done[pair].get(index) or []
            windows.append((
                fmt(median(window_done)) if window_done else "      -",
                f"{max(window_caps):.0f}" if window_caps else "-",
            ))
        overall = [value for values in done[pair].values() for value in values]
        if not overall or sum(len(v) for v in caps[pair].values()) < 10:
            continue
        med = median(overall)
        last = max(caps[pair].get(0) or [0])
        rows.append(
            [f"{pair[0]}-{pair[1] or 'off'}"]
            + [value for window in windows for value in window]
            + [
                f"{last / (med / 1000):.1f}x" if med and last else "-",
                f"{max(120, 3 * med / 1000):.0f}",
                f"{max(120, 2 * med / 1000):.0f}",
            ]
        )
    out.append(f"### RA. Cap vs median, by week (week 0 = last 7 days, {weeks} weeks)\n")
    out.append(table(
        ["pair", "w2 med s", "w2 cap s", "w1 med s", "w1 cap s", "w0 med s", "w0 cap s",
         "cap / med", "3x med", "2x med"],
        rows,
    ))
    out.append(
        "\ncap = the highest `timeout_s` the panel actually handed a cell of the pair that week, "
        "which is the derived cap as it stood then. It is recorded per row, so nothing here is "
        "re-derived."
    )


# ---------------------------------------------------------------- retry after kill

def section_retry(runs, out):
    buckets = Counter()
    added = []
    for run in runs:
        for cell in run.cells:
            if len(cell.attempts) < 2:
                continue
            first = cell.attempts[0]
            cause = "stall" if first["stalled_s"] else ("cap" if first["watchdog"] else "other")
            if cell.stalled_s or cell.watchdog:
                outcome = "killed again"
            elif cell.completed and cell.confirmed:
                outcome = "completed, confirmed"
            elif cell.completed and cell.findings:
                outcome = "completed, findings"
            elif cell.completed:
                outcome = "completed, nothing"
            else:
                outcome = "errored"
            buckets[(cause, outcome)] += 1
        first_only = panel_wall(
            run, lambda cell: (cell.attempts[0]["duration_ms"] or 0) if cell.attempts
            else (cell.wall_ms or 0)
        )
        with_retries = panel_wall(run, occupancy_ms)
        if any(len(cell.attempts) > 1 for cell in run.cells):
            added.append(with_retries - first_only)
    causes = sorted({cause for cause, _ in buckets})
    outcomes = ["completed, confirmed", "completed, findings", "completed, nothing",
                "killed again", "errored"]
    out.append("### RB. What the in-cell retry produced, by what killed the first attempt\n")
    out.append(table(
        ["first attempt"] + outcomes + ["total"],
        [[cause] + [buckets[(cause, outcome)] for outcome in outcomes]
         + [sum(buckets[(cause, outcome)] for outcome in outcomes)] for cause in causes],
    ))
    out.append("\n#### RB2. Wall the retries added, per run that had one (0 where the retry sat "
               "off the panel's slowest path)\n")
    out.append(table(
        ["runs with a retry", "med added m", "p90 added m", "max added m", "total added m"],
        [[len(added),
          f"{(median(added) or 0) / 60000:.1f}", f"{(pct(added, 0.9) or 0) / 60000:.1f}",
          f"{(max(added) if added else 0) / 60000:.1f}", f"{sum(added) / 60000:.0f}"]],
    ))
    by_count = defaultdict(list)
    for run in runs:
        for cell in run.cells:
            by_count[(cell.side, min(len(cell.attempts), 5))].append(cell.superseded_ms or 0)
    rows = []
    for side in sorted({key[0] for key in by_count}):
        counts = [key[1] for key in by_count if key[0] == side]
        if not counts:
            continue
        total = sum(len(by_count[(side, count)]) for count in counts)
        rows.append([
            side, total,
            *[f"{len(by_count.get((side, count), ()))}" for count in range(1, 6)],
            f"{sum(sum(by_count.get((side, count), ())) for count in counts) / 60000:.0f}",
        ])
    out.append("\n#### RB3. Attempts per cell (the account-pool walk, not just the one retry)\n")
    out.append(table(
        ["side", "cells", "1", "2", "3", "4", "5+", "wall m in non-final attempts"], rows,
    ))

    # A stall retry's first attempt is missing from rater_runs on every run but one, so its cost
    # can only be bounded from below: the attempt ran at least as long as the cap that killed it.
    bounds = []
    for run in runs:
        killed = [
            cell.stalled_retry_s for cell in run.cells
            if cell.stalled_retry_s and len(cell.attempts) < 2
        ]
        if killed:
            bounds.append(max(killed) * 1000)
    if bounds:
        out.append(
            f"\nStall retries whose first attempt was never written as a row: {len(bounds)} runs, "
            f"each at least {(median(bounds) or 0) / 60000:.1f}m of extra wall "
            f"(max {max(bounds) / 60000:.1f}m) — a lower bound, since the killed attempt ran at "
            "least to its stall cap. Only 3 rows in the whole store carry `stalled_s`, so RB's "
            "`stall` line counts one cell where C2 counts 42 kills."
        )


# ---------------------------------------------------------------- buffered sides


def agy_log_gaps(benches, limit=40):
    """Silent gaps in the geminib log run_agy already watches as this side's heartbeat."""
    pattern = re.compile(r"[IWE]\d{4} (\d\d):(\d\d):(\d\d)\.")
    rows = []
    logs = sorted(benches.glob("*/agy-*.log"), key=lambda path: path.stat().st_mtime)[-limit:]
    for path in logs:
        stamps = []
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        day = 0
        for match in pattern.finditer(text):
            hour, minute, second = (int(value) for value in match.groups())
            stamp = day + hour * 3600 + minute * 60 + second
            if stamps and stamp < stamps[-1]:
                day += 86400
                stamp += 86400
            stamps.append(stamp)
        if len(stamps) < 3:
            continue
        gaps = [max(0, stamps[i + 1] - stamps[i]) for i in range(len(stamps) - 1)]
        rows.append((path.name, len(stamps), stamps[-1] - stamps[0], median(gaps),
                     pct(gaps, 0.95), max(gaps)))
    return rows


def section_stall_buffered(runs, benches, out):
    watchdog_caps, stall_caps = _panel.panel_cap_timeouts(benches, now=NOW)
    by_pair = defaultdict(list)
    side_of = {}
    for run in runs:
        for cell in run.cells:
            side_of[cell.pair] = cell.side
            if cell.completed and cell.pass_ms and cell.quiet_ms is not None:
                by_pair[cell.pair].append(cell)
    rows = []
    for pair, cells in sorted(by_pair.items(), key=lambda item: (side_of[item[0]], item[0])):
        gaps = [c.quiet_ms for c in cells]
        durations = [c.pass_ms for c in cells]
        rows.append([
            f"{pair[0]}-{pair[1] or 'off'}", side_of[pair], len(gaps),
            f"{median(gaps) / median(durations):.2f}",
            "yes" if pair in stall_caps else "NO",
            f"{stall_caps.get(pair, 0):.0f}" if pair in stall_caps else "-",
            handed_caps(watchdog_caps, pair),
            f"{(pct(gaps, 0.95) or 0) / 1000 + 60:.0f}",
        ])
    out.append("### RC. Which pairs have a stall cap at all, and what it would be on p95 gaps\n")
    out.append(table(
        ["pair", "side", "n", "med gap / med dur", "stall cap?", "cap s", "dur cap s (T0-T1/T2-T3)",
         "p95 gap + 60s"],
        rows,
    ))
    capless = [row for row in rows if row[4] == "NO"]
    out.append(
        f"\n{len(capless)} of {len(rows)} measured pairs have NO stall cap: "
        + ", ".join(f"{row[0]} ({row[1]})" for row in capless)
        + ". Their only cutoff is the duration cap in the column beside it."
    )
    log_rows = agy_log_gaps(benches)
    if log_rows:
        spans = [row[2] * 1000 for row in log_rows]
        meds = [row[3] * 1000 for row in log_rows]
        p95s = [row[4] * 1000 for row in log_rows]
        maxs = [row[5] * 1000 for row in log_rows]
        out.append("\n#### RC2. The geminib log as a heartbeat (last "
                   f"{len(log_rows)} agy logs)\n")
        out.append(table(
            ["logs", "med span s", "med gap s", "med p95 gap s", "med max gap s",
             "logs with a gap > 180s"],
            [[len(log_rows), fmt(median(spans)), fmt(median(meds)), fmt(median(p95s)),
              fmt(median(maxs)), sum(1 for row in log_rows if row[5] > 180)]],
        ))
        worst = sorted(log_rows, key=lambda row: -row[5])[:5]
        out.append("\n" + table(
            ["log", "lines", "span s", "med gap s", "p95 gap s", "max gap s"],
            [[row[0][:52], row[1], f"{row[2]:.0f}", f"{row[3]:.0f}", f"{row[4]:.0f}",
              f"{row[5]:.0f}"] for row in worst],
        ))


# ---------------------------------------------------------------- tiers

def section_tiers(runs, out, days=21):
    cutoff = NOW - timedelta(days=days)
    rows = []
    for tier, spec in _catalog.REVIEW_TIERS.items():
        budget = spec["budget_min"] * 60000
        recent_walls = [
            run.wall_ms for run in runs
            if run.tier == tier and run.started and run.started >= cutoff
            and run.wall_ms is not None
        ]
        older = [
            run.wall_ms for run in runs
            if run.tier == tier and run.started and run.started < cutoff
            and run.wall_ms is not None
        ]
        if not recent_walls and not older:
            continue
        rows.append([
            tier, spec["budget_min"], len(older),
            f"{(median(older) or 0) / 60000:.1f}" if older else "-",
            len(recent_walls),
            f"{(median(recent_walls) or 0) / 60000:.1f}" if recent_walls else "-",
            f"{(pct(recent_walls, 0.9) or 0) / 60000:.1f}" if recent_walls else "-",
            f"{(median(recent_walls) or 0) / budget:.1f}x" if recent_walls else "-",
            f"{100 * sum(1 for value in recent_walls if value > budget) / len(recent_walls):.0f}%"
            if recent_walls else "-",
        ])
    out.append(f"### RD. Tier budget vs observed wall (last {days} days vs earlier)\n")
    out.append(table(
        ["tier", "budget m", "n old", "old med m", "n new", "new med m", "new p90 m",
         "med / budget", "over budget"],
        rows,
    ))
    out.append(
        "\nbudget = `REVIEW_TIERS[tier][\"budget_min\"]` (catalog.py), the minutes the tier was "
        "sized for; `board_tier` classifies a wall by exactly this number."
    )


def overlap_name(rater):
    name = _raters.normalize_legacy_rater(rater)
    if name.startswith("agy-"):
        name = name[4:]
    return name.removesuffix("-skill")


def instance_number(rater):
    match = re.search(r"#(\d+)$", rater)
    return int(match.group(1)) if match else 1


def triage_rows(run_dir):
    reported = run_dir / "reported.json"
    if reported.exists():
        try:
            return json.loads(reported.read_text()).get("rows") or []
        except (OSError, ValueError):
            return []
    verdicts = run_dir / "verdicts.jsonl"
    return _store.read_jsonl(verdicts) if verdicts.exists() else []


def finding_key(finding):
    return str(finding.get("file") or ""), finding.get("line")


def panel_confirmed_catches(run_dir):
    defects_path = run_dir / "defects.jsonl"
    if defects_path.exists():
        defects = set()
        catches = defaultdict(set)
        for row in _store.read_jsonl(defects_path):
            # Two confirmed defects on one line are two: the id is the key wherever one exists.
            key = row.get("defect_id") or finding_key(row)
            defects.add(key)
            for rater in row.get("caught_by") or ():
                catches[rater].add(key)
        return defects, catches, "linked"

    rows = triage_rows(run_dir)
    findings = {}
    canonical = set()
    keyed = []
    for row in rows:
        if not isinstance(row, dict) or row.get("verdict") not in {"confirmed", "duplicate"}:
            continue
        rater, idx = row.get("rater"), row.get("idx")
        if not rater or not isinstance(idx, int) or isinstance(idx, bool):
            continue
        if rater not in findings:
            findings[rater] = _store.finding_rows(run_dir, rater)
        if not 0 <= idx < len(findings[rater]):
            continue
        key = finding_key(findings[rater][idx])
        keyed.append((row["verdict"], rater, key))
        if row["verdict"] == "confirmed":
            canonical.add(key)
    catches = defaultdict(set)
    for verdict, rater, key in keyed:
        if verdict == "confirmed" or key in canonical:
            catches[rater].add(key)
    return canonical, catches, "file-line"


def overlap_records(runs, benches):
    records = []
    for run in runs:
        if not run.triaged or not run.started or run.started < OVERLAP_CUTOFF:
            continue
        defects, exact, source = panel_confirmed_catches(benches / run.run_id)
        raw_confirmed = Counter(
            _raters.normalize_legacy_rater(row.get("rater"))
            for row in triage_rows(benches / run.run_id)
            if isinstance(row, dict) and row.get("rater") and row.get("verdict") == "confirmed"
        )
        family = defaultdict(set)
        for rater, keys in exact.items():
            family[_raters.normalize_legacy_rater(rater)].update(keys)
        present = defaultdict(list)
        for cell in run.cells:
            present[_raters.normalize_legacy_rater(cell.rater)].append(cell)
        for cells in present.values():
            cells.sort(key=lambda cell: instance_number(cell.rater))
        records.append({
            "run": run,
            "defects": defects,
            "exact": exact,
            "family": family,
            "present": present,
            "raw_confirmed": raw_confirmed,
            "source": source,
        })
    return records


def fraction(found, total):
    return f"{found}/{total} ({100 * found / total:.0f}%)" if total else "- (n=0)"


def repeat_spec_counts(specs):
    counts = Counter()
    for spec in specs:
        match = re.fullmatch(r"(.+) x([2-9])", spec)
        if match:
            counts[match.group(1)] += int(match.group(2))
        else:
            counts[spec] += 1
    return counts


def selected_raters(record, counts):
    selected = []
    for base, needed in counts.items():
        cells = record["present"].get(base, ())
        if len(cells) < needed:
            return None
        selected.extend(cell.rater for cell in cells[:needed])
    return selected


def side_keys(record, sides):
    found = set()
    for rater, keys in record["exact"].items():
        if _raters.rater_side(rater) in sides:
            found.update(keys)
    return found


def section_overlap_matrix(records, out):
    header = ["row cell"] + [overlap_name(cell) for cell in AGY_OVERLAP_CELLS]
    rows = []
    for left in AGY_OVERLAP_CELLS:
        row = [overlap_name(left)]
        for right in AGY_OVERLAP_CELLS:
            if left == right:
                row.append("-")
                continue
            eligible = [r for r in records if left in r["present"] and right in r["present"]]
            denominator = sum(len(r["family"].get(left, ())) for r in eligible)
            shared = sum(
                len(r["family"].get(left, set()) & r["family"].get(right, set()))
                for r in eligible
            )
            row.append(fraction(shared, denominator))
        rows.append(row)
    out.append("### O1. Directional pairwise overlap among agy cells\n")
    out.append(table(header, rows, aligns=["<"] + [">"] * len(AGY_OVERLAP_CELLS)))
    out.append(
        "\nEach cell is `shared / row-cell confirmed defects` over runs where both cells were "
        "present. Copies are folded into their model x effort family."
    )

    summary = []
    for cell in AGY_OVERLAP_CELLS:
        eligible = [r for r in records if cell in r["present"]]
        total = sum(len(r["family"].get(cell, ())) for r in eligible)
        overlap = Counter()
        runs_with_catches = 0
        for record in eligible:
            own = record["family"].get(cell, set())
            if own:
                runs_with_catches += 1
            other_agy = set().union(*(
                keys for family, keys in record["family"].items()
                if family != cell and _raters.rater_side(family) == "agy"
            ), set())
            opus = side_keys(record, {"claude"})
            sol = side_keys(record, {"codex"})
            oc = side_keys(record, {"opencode"})
            other = set().union(*(
                keys for family, keys in record["family"].items() if family != cell
            ), set())
            overlap["agy"] += len(own & other_agy)
            overlap["opus"] += len(own & opus)
            overlap["sol"] += len(own & sol)
            overlap["oc"] += len(own & oc)
            overlap["non_agy"] += len(own & (opus | sol | oc))
            overlap["nobody"] += len(own - other)
        summary.append([
            overlap_name(cell), len(eligible),
            sum(len(record["present"][cell]) for record in eligible),
            sum(record["raw_confirmed"][cell] for record in eligible),
            runs_with_catches, total,
            fraction(overlap["agy"], total), fraction(overlap["opus"], total),
            fraction(overlap["sol"], total), fraction(overlap["oc"], total),
            fraction(overlap["non_agy"], total), fraction(overlap["nobody"], total),
        ])
    out.append("\n### O2. Who else caught each agy cell's confirmed defects\n")
    out.append(table(
        ["agy cell", "n runs", "n instances", "raw confirmed", "n runs hit",
         "n caught defects", "another agy", "opus-*", "sol-*", "OpenCode", "any non-agy",
         "nobody else"],
        summary,
    ))


def section_leg_coverage(records, out):
    covered = [record for record in records if record["defects"]]
    total = sum(len(record["defects"]) for record in covered)
    summary = [[
        "all non-empty runs", len(covered), total,
        fraction(sum(len(side_keys(record, {"agy"})) for record in covered), total),
        fraction(sum(len(side_keys(record, {"claude", "codex"})) for record in covered), total),
        fraction(sum(len(side_keys(record, {"opencode"})) for record in covered), total),
    ]]
    for tier, specs in _catalog.REVIEW_TIER_AGY.items():
        counts = repeat_spec_counts(specs)
        eligible = [
            record for record in covered
            if record["run"].tier == tier and selected_raters(record, counts) is not None
        ]
        tier_total = sum(len(record["defects"]) for record in eligible)
        selected = [(record, selected_raters(record, counts)) for record in eligible]
        summary.append([
            f"{tier} current agy composition", len(eligible), tier_total,
            fraction(sum(
                len(set().union(*(record["exact"].get(rater, set()) for rater in raters), set()))
                for record, raters in selected
            ), tier_total),
            fraction(sum(len(side_keys(record, {"claude", "codex"})) for record in eligible), tier_total),
            fraction(sum(len(side_keys(record, {"opencode"})) for record in eligible), tier_total),
        ])
    out.append("\n### O3a. Side and current-tier micro-summary\n")
    out.append(table(
        ["population", "n runs", "n defects", "agy", "opus + sol", "OpenCode"], summary,
    ))

    rows = [[
        f"ALL (n={len(covered)} runs)", "-", total,
        fraction(sum(len(side_keys(record, {"agy"})) for record in covered), total),
        fraction(sum(len(side_keys(record, {"claude", "codex"})) for record in covered), total),
        fraction(sum(len(side_keys(record, {"opencode"})) for record in covered), total),
    ]]
    for record in covered:
        total = len(record["defects"])
        agy = side_keys(record, {"agy"})
        claude = side_keys(record, {"claude", "codex"})
        oc = side_keys(record, {"opencode"})
        rows.append([
            record["run"].run_id, record["run"].tier or "?", total,
            fraction(len(agy), total), fraction(len(claude), total), fraction(len(oc), total),
        ])
    out.append("\n### O3. Per-run coverage if only one side survived\n")
    out.append(table(
        ["run", "tier", "n defects", "agy union", "opus + sol", "OpenCode"], rows,
    ))

    single = []
    for cell in AGY_OVERLAP_CELLS:
        eligible = [r for r in records if cell in r["present"] and r["defects"]]
        total = sum(len(r["defects"]) for r in eligible)
        found = sum(len(r["family"].get(cell, ())) for r in eligible)
        single.append([overlap_name(cell), len(eligible), total, fraction(found, total)])
    out.append("\n### O4. One agy cell alone\n")
    out.append(table(["agy cell", "n runs", "n defects", "coverage"], single))

    tiers = []
    for tier, specs in _catalog.REVIEW_TIER_AGY.items():
        counts = repeat_spec_counts(specs)
        eligible = []
        for record in records:
            if record["run"].tier != tier or not record["defects"]:
                continue
            selected = selected_raters(record, counts)
            if selected is not None:
                eligible.append((record, selected))
        total = sum(len(record["defects"]) for record, _ in eligible)
        agy = sum(
            len(set().union(*(record["exact"].get(rater, set()) for rater in selected), set()))
            for record, selected in eligible
        )
        claude = sum(len(side_keys(record, {"claude", "codex"})) for record, _ in eligible)
        oc = sum(len(side_keys(record, {"opencode"})) for record, _ in eligible)
        tiers.append([
            tier, len(eligible), total, fraction(agy, total), fraction(claude, total),
            fraction(oc, total), ", ".join(
                f"{overlap_name(cell)} x{count}" if count > 1 else overlap_name(cell)
                for cell, count in counts.items()
            ),
        ])
    out.append("\n### O5. Current agy tier composition as the only surviving side\n")
    out.append(table(
        ["tier", "n runs", "n defects", "current agy", "opus + sol", "OpenCode",
         "agy composition"],
        tiers,
    ))


def section_in_panel_repeats(records, out):
    bases = sorted({
        base for record in records for base, cells in record["present"].items()
        if len(cells) >= 2 and instance_number(cells[1].rater) == 2
    })
    rows = []
    for base in bases:
        samples = []
        for record in records:
            cells = record["present"].get(base, ())
            if len(cells) < 2 or instance_number(cells[1].rater) != 2:
                continue
            first, second = cells[0].rater, cells[1].rater
            added = record["exact"].get(second, set()) - record["exact"].get(first, set())
            rest = set().union(*(
                keys for rater, keys in record["exact"].items() if rater != second
            ), set())
            samples.append((len(added), len(added - rest)))
        if not samples:
            continue
        rows.append([
            overlap_name(base), len(samples),
            fraction(sum(added > 0 for added, _ in samples), len(samples)),
            f"{statistics.mean(added for added, _ in samples):.2f}",
            fraction(sum(unique > 0 for _, unique in samples), len(samples)),
            f"{statistics.mean(unique for _, unique in samples):.2f}",
            sum(added for added, _ in samples), sum(unique for _, unique in samples),
        ])
    out.append("\n### O6. In-panel second-copy gain\n")
    out.append(table(
        ["cell", "n runs", "#2 adds >=1", "mean added", "#2 adds panel-unique",
         "mean unique", "added total", "unique total"],
        rows,
    ))


def section_repeat_wall(runs, out):
    recent = [run for run in runs if run.started and run.started >= OVERLAP_CUTOFF]
    by_base = defaultdict(list)
    for run in recent:
        present = defaultdict(list)
        for cell in run.cells:
            present[_raters.normalize_legacy_rater(cell.rater)].append(cell)
        for base, cells in present.items():
            cells.sort(key=lambda cell: instance_number(cell.rater))
            if len(cells) < 2 or instance_number(cells[1].rater) != 2:
                continue
            first, second = cells[:2]
            d1, d2 = occupancy_ms(first), occupancy_ms(second)
            other = max((occupancy_ms(cell) for cell in run.cells if cell is not second), default=0)
            slowest = d2 >= max((occupancy_ms(cell) for cell in run.cells), default=0)
            by_base[base].append((slowest, max(0, d2 - d1), max(0, d2 - other)))
    rows = []
    for base, samples in sorted(by_base.items()):
        panel_stretches = [panel for _, _, panel in samples]
        positive = [value for value in panel_stretches if value > 0]
        rows.append([
            overlap_name(base), len(samples), fraction(sum(slow for slow, _, _ in samples), len(samples)),
            fraction(sum(over > 0 for _, over, _ in samples), len(samples)),
            f"{statistics.mean(over for _, over, _ in samples) / 60000:.2f}",
            f"{statistics.mean(panel_stretches) / 60000:.2f}",
            f"{statistics.mean(positive) / 60000:.2f}" if positive else "0.00",
            f"{max(panel_stretches) / 60000:.2f}",
        ])
    out.append("\n### O7. Second-copy max-tail wall cost\n")
    out.append(table(
        ["cell", "n runs", "#2 panel slowest", "#2 slower than #1", "mean +m vs #1",
         "mean panel +m", "mean +m when >0", "max panel +m"],
        rows,
    ))
    out.append(
        "\nDurations include superseded pool attempts. `panel +m` is the max-tail delta after "
        "removing #2, with every cell treated as parallel as requested; it does not model the "
        "OpenCode admission queue."
    )


def corpus_attempts(runs, defect_dir, review_repos=None):
    """(corpus defects per (repo, commit), the cells that attempted each, run ids that matched
    no corpus file). A run whose reviewed path is gone from disk resolves its repository through
    the corpus row it wrote, as cli.py does; one that never wrote a row is counted, not dropped.
    """
    defects = {}
    for path in sorted(defect_dir.glob("*.jsonl")) if defect_dir.exists() else []:
        rows = _store.read_jsonl(path)
        if not rows:
            continue
        repo = str(rows[0].get("repo") or "")
        commit = str(rows[0].get("commit") or "")
        defects[(repo, commit)] = rows
    attempts = defaultdict(lambda: defaultdict(list))
    unmatched = []
    for run in runs:
        if not run.started or run.started < OVERLAP_CUTOFF:
            continue
        repo = _store.repo_identity(run.repo) or (review_repos or {}).get(run.run_id) or ""
        key = (repo, run.commit)
        if key not in defects:
            unmatched.append(run.run_id)
            continue
        for cell in run.cells:
            base = _raters.normalize_legacy_rater(cell.rater)
            attempts[key][base].append((run.run_id, cell.rater))
    return defects, attempts, unmatched


def expected_attempt_coverage(hit_sets, k, defect_count):
    attempts = len(hit_sets)
    if attempts < k or not defect_count:
        return None
    expected = 0.0
    for defect in range(defect_count):
        hits = sum(defect in found for found in hit_sets)
        missed = math.comb(attempts - hits, k) / math.comb(attempts, k) if attempts - hits >= k else 0
        expected += 1 - missed
    return expected / defect_count


def repeat_curves(runs, defect_dir, review_repos=None):
    """(per-cell coverage curves, run ids no corpus file answered for)."""
    defects, attempts, unmatched = corpus_attempts(runs, defect_dir, review_repos)
    per_cell = defaultdict(list)
    for key, rows in defects.items():
        caught = [
            {(str(catch.get("run_id") or ""), str(catch.get("rater") or ""))
             for catch in row.get("catches") or ()}
            for row in rows
        ]
        for cell, ids in attempts.get(key, {}).items():
            hit_sets = [
                {idx for idx, defect_catches in enumerate(caught) if attempt in defect_catches}
                for attempt in ids
            ]
            per_cell[cell].append((key, hit_sets, len(rows)))

    curves = {}
    for cell, commits in per_cell.items():
        points = {}
        marginals = {}
        for k in (1, 2, 3):
            eligible = [(hits, total) for _, hits, total in commits if len(hits) >= k]
            values = [expected_attempt_coverage(hits, k, total) for hits, total in eligible]
            points[k] = {
                "coverage": statistics.mean(values) if values else None,
                "commits": len(eligible),
                "attempts": sum(len(hits) for hits, _ in eligible),
                "defects": sum(total for _, total in eligible),
            }
            if k > 1 and eligible:
                prior = [expected_attempt_coverage(hits, k - 1, total) for hits, total in eligible]
                marginals[k] = statistics.mean(
                    value - before for value, before in zip(values, prior)
                )
            else:
                marginals[k] = None
        curves[cell] = {"points": points, "marginals": marginals}
    return curves, unmatched


def curve_cell(value):
    if value["coverage"] is None:
        return "- (c=0,a=0,d=0)"
    return (
        f"{100 * value['coverage']:.1f}% "
        f"(c={value['commits']},a={value['attempts']},d={value['defects']})"
    )


def section_corpus_repeats(runs, benches, out):
    review_repos = {
        str(row.get("run_id")): str(row.get("repo"))
        for row in _store.read_jsonl(benches.parent / "reviews.jsonl")
        if isinstance(row, dict) and row.get("run_id") and row.get("repo")
    }
    curves, unmatched = repeat_curves(runs, benches.parent / "defects", review_repos)
    cells = sorted(
        set(AGY_OVERLAP_CELLS)
        | {cell for cell, data in curves.items() if data["points"][1]["commits"]}
    )
    rows = []
    for cell in cells:
        data = curves.get(cell, {
            "points": {k: {"coverage": None, "commits": 0, "attempts": 0, "defects": 0}
                       for k in (1, 2, 3)},
            "marginals": {2: None, 3: None},
        })
        second = data["marginals"].get(2)
        third = data["marginals"].get(3)
        if second is None:
            reading = "too thin"
        elif second >= 0.05:
            reading = "low self-overlap; repeat pays"
        elif second <= 0.01:
            reading = "repeat adds almost nothing"
        else:
            reading = "mixed"
        rows.append([
            overlap_name(cell), curve_cell(data["points"][1]), curve_cell(data["points"][2]),
            curve_cell(data["points"][3]),
            f"{100 * second:.1f}" if second is not None else "-",
            f"{100 * third:.1f}" if third is not None else "-", reading,
        ])
    out.append("\n### O8. Same-commit coverage from one, two, or three attempts\n")
    out.append(
        f"{len(unmatched)} run(s) in the overlap window matched no corpus file — a repository "
        "neither on disk nor named by a reviews.jsonl row, or a commit no corpus holds — and are "
        "not in these curves.\n"
    )
    out.append(table(
        ["cell", "1 attempt", "2 attempts", "3 attempts", "+2nd pp", "+3rd pp", "reading"],
        rows,
    ))
    out.append(
        "\nEach point averages that commit's expected known-defect coverage over commits with at "
        "least k observed attempts. `c/a/d` is commits / observed attempts / known defects in "
        "that point's cohort. Marginals re-score the same >=k cohort at k-1, so they do not mix "
        "different commit populations. Failed attempts remain zero-hit attempts."
    )
    return curves


def optimization_rows(records):
    bases = (
        "agy-flash35-medium-skill",
        "agy-flash35-high-skill",
        "agy-flash36-medium-skill",
        "agy-flash36-high-skill",
        "agy-flash37-medium-skill",
        "agy-pro-high-skill",
    )
    required = Counter({base: 1 for base in bases})
    required["agy-flash36-high-skill"] = 2
    eligible = [
        record for record in records
        if record["defects"] and selected_raters(record, required) is not None
    ]
    candidates = []
    for size in range(1, len(bases) + 1):
        for subset in combinations(bases, size):
            choices = (False, True) if "agy-flash36-high-skill" in subset else (False,)
            for repeat in choices:
                counts = Counter({base: 1 for base in subset})
                if repeat:
                    counts["agy-flash36-high-skill"] = 2
                total = found = 0
                walls = []
                for record in eligible:
                    raters = selected_raters(record, counts)
                    total += len(record["defects"])
                    found += len(set().union(*(
                        record["exact"].get(rater, set()) for rater in raters
                    ), set()))
                    selected_cells = [
                        cell for base, count in counts.items()
                        for cell in record["present"][base][:count]
                    ]
                    walls.append(max(occupancy_ms(cell) for cell in selected_cells) / 60000)
                coverage = 100 * found / total if total else 0
                wall = median(walls) or 0
                candidates.append({
                    "counts": counts, "coverage": coverage, "found": found, "total": total,
                    "wall": wall, "efficiency": coverage / wall if wall else 0,
                    "runs": len(eligible),
                })
    return sorted(candidates, key=lambda row: (-row["efficiency"], -row["coverage"])), eligible


def section_optimization(records, out):
    ranked, eligible = optimization_rows(records)
    rows = []
    for row in ranked[:5]:
        composition = ", ".join(
            f"{overlap_name(cell)} x{count}" if count > 1 else overlap_name(cell)
            for cell, count in row["counts"].items()
        )
        rows.append([
            composition, row["runs"], row["total"], fraction(row["found"], row["total"]),
            f"{row['wall']:.2f}", f"{row['efficiency']:.2f}",
        ])
    out.append("\n### O9. Agy-only compositions ranked by coverage per median wall-minute\n")
    out.append(table(
        ["composition", "n runs", "n defects", "coverage", "median wall m", "coverage pp/m"],
        rows,
    ))
    out.append(
        "\nThe fixed cohort requires all six established cells plus flash36-high #2 in the same "
        f"run (n={len(eligible)} runs). All subsets therefore use the same confirmed-defect "
        "denominator. Flash37-high and flash37-low are excluded from this ranking because their "
        "common-run n is too thin; Flash37-high's separate seven-commit sweep supports one copy "
        "but cannot supply an honest combined coverage/wall score."
    )


def section_recommendations(records, runs, curves, out):
    copy_bases = set()
    for run in runs:
        if not run.started or run.started < OVERLAP_CUTOFF:
            continue
        counts = Counter(_raters.normalize_legacy_rater(cell.rater) for cell in run.cells)
        copy_bases.update(base for base, count in counts.items() if count >= 2)
    cells = list(AGY_OVERLAP_CELLS) + sorted(copy_bases - set(AGY_OVERLAP_CELLS))
    decisions = {
        "agy-flash36-high-skill": "2 copies",
        "agy-flash37-high-skill": "1 copy",
        "agy-flash37-low-skill": "1 copy",
        "oc-kimik3": "2 copies",
        "oc-grok45-low": "drop",
        "sol-high-bare": "2 copies",
    }
    rows = []
    for base in cells:
        eligible = [record for record in records if base in record["present"]]
        confirmed = sum(len(record["family"].get(base, ())) for record in eligible)
        repeats = []
        for record in eligible:
            instances = record["present"][base]
            if len(instances) < 2 or instance_number(instances[1].rater) != 2:
                continue
            first, second = instances[:2]
            added = record["exact"].get(second.rater, set()) - record["exact"].get(first.rater, set())
            rest = set().union(*(
                keys for rater, keys in record["exact"].items() if rater != second.rater
            ), set())
            repeats.append((len(added), len(added - rest)))
        curve_commits = curves.get(base, {}).get("points", {}).get(2, {}).get("commits", 0)
        thin = len(eligible) < 10 or (repeats and len(repeats) < 10)
        rows.append([
            overlap_name(base), len(eligible),
            sum(len(record["present"][base]) for record in eligible),
            sum(record["raw_confirmed"][base] for record in eligible), confirmed, len(repeats),
            fraction(sum(added > 0 for added, _ in repeats), len(repeats)),
            fraction(sum(unique > 0 for _, unique in repeats), len(repeats)),
            curve_commits, decisions.get(base, "1 copy"), "thin" if thin else "usable",
        ])
    out.append("\n### O10. Copy recommendation by cell\n")
    out.append(table(
        ["cell", "n runs", "n instances", "raw confirmed", "n caught defects", "n #2 runs",
         "#2 adds", "#2 unique", "corpus n>=2 commits", "recommendation", "evidence"],
        rows,
    ))
    out.append(
        "\nThe only robust two-copy wins are flash36-high, oc-kimik3, and sol-high-bare. "
        "Flash37-high stays at one copy: #2 adds in 4/15 runs but is the panel tail in 7/15. "
        "Flash37-low also stays at one: its second attempt adds only 0.7 coverage points in the "
        "seven-commit corpus. oc-dsv4flash's and oc-grok45-low's second copies stay off the "
        "panel: the `#2 unique` column above is their evidence."
    )


def section_overlap(runs, benches, out):
    records = overlap_records(runs, benches)
    linked = sum(record["source"] == "linked" for record in records)
    observed_through = max(record["run"].started for record in records).astimezone(
        OVERLAP_CUTOFF.tzinfo
    )
    out.append(
        "### O0. Scope and identity\n\n"
        f"Window: {OVERLAP_CUTOFF.isoformat()}..{observed_through.isoformat()}; "
        f"n={len(records)} triaged runs, n={sum(len(r['defects']) for r in records)} "
        f"run-local confirmed defects. Explicit duplicate attribution from `defects.jsonl` is "
        f"available in n={linked} runs; the rest use exact `(file, line)` equality."
    )
    section_overlap_matrix(records, out)
    section_leg_coverage(records, out)
    section_in_panel_repeats(records, out)
    section_repeat_wall(runs, out)
    curves = section_corpus_repeats(runs, benches, out)
    section_optimization(records, out)
    section_recommendations(records, runs, curves, out)

# ---------------------------------------------------------------- shipped caps, replayed

def cap_samples_before(ordered, run, window):
    """The samples the launch would have read for `run`: every completion of the `window` before
    its start, keyed the way `panel_cap_samples` keys them."""
    samples = {}
    for other in ordered:
        if other.started >= run.started:
            break
        if other.started < run.started - window:
            continue
        # Causal: a run still going, or triaged only later, had nothing on disk to read yet.
        if (other.finished or other.started) > run.started:
            continue
        triaged = other.triaged_at is not None and other.triaged_at <= run.started
        for cell in other.cells:
            if not cell.completed or cell.pass_ms is None or cell.watchdog or cell.stalled_s:
                continue
            _panel.add_cap_sample(samples.setdefault(cell.pair, _panel.empty_cap_samples()), {
                "duration_s": cell.pass_ms / 1000,
                "confirmed": triaged and cell.confirmed > 0,
                "gap_s": None if cell.quiet_ms is None else cell.quiet_ms / 1000,
            })
    return samples


def replay_cell(cell, caps, stall_caps, chunk_band="cut"):
    """One cell under the shipped rules: (ms it would have held the panel, why its answer was
    lost or None). Attempts are walked in order, at most CELL_ATTEMPTS_MAX per pass, each under
    the duration cap; a kill of ours — the cap firing, or a recorded kill, the final attempt's
    included — ends the cell. The answer survives only if the final attempt is reached, uncut,
    unkilled, and its silence stayed under the stall cap. The cap is per pass and the store
    holds each attempt's SUM over its passes: a sum past passes x cap is a certain kill, one past
    a single cap but under that is a pass that may have been, counted as cut under its own
    label since it cannot be replayed (`chunk_band="cut"`), or left to run for the lower bound
    (`chunk_band="survive"`)."""
    cap = _panel.cell_timeout_seconds(caps, cell.pair, cell.run.tier)
    stall = stall_caps.get(cell.pair)
    stall = stall if stall and stall < cap else None
    limit = cap * 1000
    passes = max(1, cell.passes)
    held = 0.0
    final_index = len(cell.attempts) - 1
    reached = False
    lost = None
    for index, attempt in enumerate(cell.attempts[:_launch.CELL_ATTEMPTS_MAX * passes]):
        duration = attempt["duration_ms"] or 0
        if duration > limit * passes:
            held += limit * passes
            lost = "cap" if index == final_index else "kill ends the cell"
            break
        held += duration
        if passes > 1 and duration > limit and chunk_band == "cut":
            lost = "cap (chunk bound)" if index == final_index else "kill ends the cell"
            break
        if attempt["watchdog"] or attempt["stalled_s"]:
            lost = "killed as recorded" if index == final_index else "kill ends the cell"
            break
        if index == final_index:
            reached = True
            break
    else:
        lost = "attempts"
    if reached and stall and cell.quiet_ms is not None and cell.quiet_ms > stall * 1000:
        lost = "stall"
    return held, lost


def lower_bound(run, caps, stall_caps, lower):
    """The same replay with the chunk band surviving: per-side lost and unique lost added to
    `lower`, and the run's panel-unique loss returned."""
    outcome = {
        cell.rater: replay_cell(cell, caps, stall_caps, chunk_band="survive")
        for cell in run.cells
    }
    survivors_keys = set()
    cut_keys = defaultdict(Counter)
    for cell in run.cells:
        if outcome[cell.rater][1] is None:
            survivors_keys |= set(cell.confirmed_keys)
        else:
            cut_keys[cell.side] += cell.confirmed_keys
            lower[cell.side]["lost"] += cell.confirmed
    unique = 0
    for side, keys in cut_keys.items():
        side_unique = unique_lost(keys, survivors_keys)
        lower[side]["unique lost"] += side_unique
        unique += side_unique
    return unique


def section_caps(runs, out, days=_catalog.CAP_WINDOW_DAYS):
    ordered = sorted((run for run in runs if run.started), key=lambda run: run.started)
    window = timedelta(days=days)
    cutoff = NOW - window
    replayed = [run for run in ordered if run.started >= cutoff]
    side_rows = defaultdict(Counter)
    tier_walls = defaultdict(lambda: {"before": [], "after": [], "agy_after": []})
    agy_by_tier = defaultdict(Counter)
    panel_confirmed = 0
    panel_unique_lost = 0
    lower = defaultdict(Counter)
    lower_unique = 0
    for run in replayed:
        samples = cap_samples_before(ordered, run, window)
        caps = {pair: _panel.duration_cap_seconds(pair_samples)
                for pair, pair_samples in samples.items()}
        stall_caps = {}
        for pair, pair_samples in samples.items():
            cap = _panel.stall_cap_seconds(pair_samples)
            if cap is not None:
                stall_caps[pair] = cap
        outcome = {cell.rater: replay_cell(cell, caps, stall_caps) for cell in run.cells}
        lower_unique += lower_bound(run, caps, stall_caps, lower)
        survivors_keys = set()
        cut_keys = defaultdict(Counter)
        for cell in run.cells:
            if outcome[cell.rater][1] is None:
                survivors_keys |= set(cell.confirmed_keys)
            else:
                cut_keys[cell.side] += cell.confirmed_keys
        for side, keys in cut_keys.items():
            unique = unique_lost(keys, survivors_keys)
            side_rows[side]["unique lost"] += unique
            panel_unique_lost += unique
        for cell in run.cells:
            held, lost = outcome[cell.rater]
            row = side_rows[cell.side]
            row["cells"] += 1
            row["confirmed"] += cell.confirmed
            panel_confirmed += cell.confirmed
            if cell.side == "agy":
                agy_by_tier[run.tier or "?"]["confirmed"] += cell.confirmed
            if lost:
                row[f"cut: {lost}"] += 1
                row["lost"] += cell.confirmed
                if cell.side == "agy":
                    agy_by_tier[run.tier or "?"]["lost"] += cell.confirmed
        before = panel_wall(run, occupancy_ms)
        after = panel_wall(run, lambda cell: outcome[cell.rater][0])
        walls = tier_walls[run.tier or "?"]
        walls["before"].append(before)
        walls["after"].append(after)
        agy_after = [outcome[cell.rater][0] for cell in run.cells if cell.side == "agy"]
        if agy_after:
            walls["agy_after"].append(max(agy_after))
    out.append(f"### CAPS. The shipped caps replayed over the last {days} days "
               f"({len(replayed)} runs, {sum(len(run.cells) for run in replayed)} cells)\n")
    out.append(
        "Per run, the caps are what its pairs earned from the "
        f"{days} days before it (`duration_cap_seconds`, `stall_cap_seconds`, "
        "`cell_timeout_seconds` with the run's tier), a kill ends the cell, and a pass makes at "
        f"most {_launch.CELL_ATTEMPTS_MAX} attempts. `lost` counts confirmed findings on cells "
        "whose answer would not have arrived; `unique lost` those no surviving cell of the same "
        "run also found (file+line), the cut cells' catches pooled first. A sample is read only "
        "from a run that had finished, and counts as confirmed only if it was triaged, before "
        "the replayed run started. Before = every attempt as recorded; a stall cut is counted "
        "as lost but its wall is left as recorded, since the store does not say when the "
        "silence fell. `killed as recorded` is a final attempt the old rules killed under "
        "today's cap, whose answer never existed; `cap (chunk bound)` a chunked cell whose "
        "summed duration passed one pass's cap but not passes x cap — the store holds no "
        "per-pass durations, so it is counted as cut.\n"
    )
    cut_kinds = sorted({key for row in side_rows.values() for key in row if key.startswith("cut: ")})
    rows = []
    for side in sorted(side_rows):
        row = side_rows[side]
        rows.append([
            side, row["cells"], *[row[kind] for kind in cut_kinds], row["confirmed"],
            row["lost"], f"{100 * row['lost'] / row['confirmed']:.1f}%" if row["confirmed"] else "-",
            row["unique lost"],
        ])
    out.append(table(
        ["side", "cells", *[kind[5:] for kind in cut_kinds], "confirmed", "lost", "% of leg",
         "unique lost"],
        rows,
    ))
    out.append(
        f"\nPanel level: {panel_unique_lost} of {panel_confirmed} confirmed findings "
        f"({100 * panel_unique_lost / panel_confirmed:.2f}%) caught by nobody else are lost."
        if panel_confirmed else "\nNo confirmed findings in the window."
    )
    if panel_confirmed:
        per_side = ", ".join(
            f"{side} {lower[side]['lost']} of {side_rows[side]['confirmed']}"
            f" ({100 * lower[side]['lost'] / side_rows[side]['confirmed']:.1f}%,"
            f" unique {lower[side]['unique lost']})"
            for side in sorted(side_rows) if side_rows[side]["confirmed"]
        )
        out.append(
            f"\nLower bound, the chunk band surviving: {per_side}; panel-unique {lower_unique} "
            f"of {panel_confirmed} ({100 * lower_unique / panel_confirmed:.2f}%). The truth "
            "sits between the two, and the band is where the store keeps no per-pass duration."
        )
    out.append("\n#### CAPS2. The agy leg per tier\n")
    out.append(table(
        ["tier", "confirmed", "lost", "% of leg"],
        [[tier, row["confirmed"], row["lost"],
          f"{100 * row['lost'] / row['confirmed']:.1f}%" if row["confirmed"] else "-"]
         for tier, row in sorted(agy_by_tier.items())],
    ))
    out.append("\n#### CAPS3. Panel wall per tier, before -> after (modelled, minutes)\n")
    out.append(table(
        ["tier", "runs", "med before", "med after", "p90 before", "p90 after",
         "agy slowest med after", "agy slowest p90 after"],
        [[tier, len(walls["before"]),
          f"{median(walls['before']) / 60000:.1f}", f"{median(walls['after']) / 60000:.1f}",
          f"{pct(walls['before'], 0.9) / 60000:.1f}", f"{pct(walls['after'], 0.9) / 60000:.1f}",
          f"{median(walls['agy_after']) / 60000:.1f}" if walls["agy_after"] else "-",
          f"{pct(walls['agy_after'], 0.9) / 60000:.1f}" if walls["agy_after"] else "-"]
         for tier, walls in sorted(tier_walls.items())],
    ))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--benches", type=Path, default=DEFAULT_BENCHES)
    parser.add_argument("--section", default="all", choices=[
        "A", "B", "C", "D", "recent-cases", "ratchet", "retry", "stall-buffered", "tiers",
        "overlap", "caps", "all",
    ])
    args = parser.parse_args()
    runs = load(args.benches)
    if not runs:
        print(f"no readable runs under {args.benches}")
        return
    out = [
        f"Runs: {len(runs)}  cells: {sum(len(r.cells) for r in runs)}  "
        f"triaged runs: {sum(1 for r in runs if r.triaged)}  "
        f"window: {min(r.run_id for r in runs)[:8]}..{max(r.run_id for r in runs)[:8]}\n"
    ]
    if args.section in ("A", "all"):
        section_a(runs, out)
    if args.section in ("B", "all"):
        out.append("")
        section_b(runs, out)
    if args.section in ("C", "all"):
        out.append("")
        section_c(runs, args.benches, out)
    if args.section in ("D", "all"):
        out.append("")
        section_d(runs, args.benches, out)
    if args.section in ("recent-cases", "all"):
        out.append("")
        section_recent_cases(runs, out)
    if args.section in ("ratchet", "all"):
        out.append("")
        section_ratchet(runs, out)
    if args.section in ("retry", "all"):
        out.append("")
        section_retry(runs, out)
    if args.section in ("stall-buffered", "all"):
        out.append("")
        section_stall_buffered(runs, args.benches, out)
    if args.section in ("tiers", "all"):
        out.append("")
        section_tiers(runs, out)
    if args.section in ("overlap", "all"):
        out.append("")
        section_overlap(runs, args.benches, out)
    if args.section in ("caps", "all"):
        out.append("")
        section_caps(runs, out)
    print("\n".join(out))


if __name__ == "__main__":
    main()
