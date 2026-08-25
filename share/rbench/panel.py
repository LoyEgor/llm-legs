import json
import re
import math
import statistics
from collections import Counter, defaultdict

from . import store as _store
from . import catalog as _catalog
from . import raters as _raters

def review_counts(rows):
    counts = Counter()
    for row in rows:
        rater = row.get("rater")
        if not rater:
            model = row.get("rater_model")
            effort = row.get("rater_effort")
            if model and effort:
                rater = f"{model}-{effort}"
        if rater:
            counts[_raters.normalize_legacy_rater(rater)] += 1
    return counts


def cell_pass_duration(row):
    """What ONE invocation of this cell took, or None where the row records no usable duration.

    A chunked cell runs its passes one after another under one name and records their sum, so the
    readers that price an invocation — the watchdog cap, the duration median, the late line — must
    divide it back out or read the cell as a rater that suddenly got N times slower.
    """
    duration = row.get("duration_ms")
    if (
        not isinstance(duration, (int, float))
        or isinstance(duration, bool)
        or duration < 0
    ):
        return None
    passes = row.get("passes")
    if isinstance(passes, int) and not isinstance(passes, bool) and passes > 1:
        return duration / passes
    return duration


def review_duration_medians(rows):
    durations = defaultdict(list)
    for row in rows:
        rater = row.get("rater")
        duration = cell_pass_duration(row)
        if isinstance(rater, str) and rater and duration is not None:
            durations[_raters.normalize_legacy_rater(rater)].append(duration)
    return {
        rater: statistics.median(values)
        for rater, values in durations.items()
    }


def expected_review_durations(cells, medians):
    return {
        cell: medians[_raters.normalize_legacy_rater(cell)]
        for cell in cells
        if _raters.normalize_legacy_rater(cell) in medians
    }


def panel_cell_key(row):
    """The watchdog's key for one cell: its model and effort, which is what decides how long a
    panel takes. Keyed on the cell spec instead, a family that gained an effort inherited nothing
    from the effort beside it and every new spelling started from the floor again.
    """
    model = str(row.get("model") or "")
    if not model:
        return None
    return model, str(row.get("effort") or "")


def watchdog_killed(row):
    """Whether the watchdog itself cut this cell off, which `rater_timeout` marks with exit 124.

    An agy cell is the one side the watchdog does not kill itself: its cap is handed to geminib as
    `--print-timeout`, which expires first and exits 1 with a timeout of its own wording. Read on
    exit 124 alone, that side never records a breach at all and stays pinned at the floor for ever.
    Nowhere else the wording: `cell_status` also reads a provider's own `gateway timeout` as a
    timeout, and that says nothing about the cap the cell was given.

    A stall kill is not a duration breach: it shares the exit code, and counting it here would
    let one hung cell raise its pair's duration cap for ever.
    """
    if row.get("stalled_s"):
        return False
    # The marker as well as the code: a chunked cell whose other passes came back carries the kill
    # of the one that hung under an exit 0 of its own, and read on the code alone that hang reaches
    # neither the run's `timed_out` nor the cap it fired at.
    if row.get("exit_code") == 124 or row.get("killed") == "watchdog":
        return True
    side = row.get("side") or _raters.rater_side(row.get("rater"))
    return side == "agy" and cell_status(row) == "timed_out"


def panel_cell_history(benches):
    """Per (model, effort) pair over every recorded run: the longest it has ever taken to COMPLETE,
    the highest cap the watchdog killed it at since its last completion together with how many
    kills in a row that is, the longest a completion ever went without producing a byte, and the
    highest stall cap a cell of the pair was ever killed at.

    Completions are the only evidence about the work — feeding a hang's duration or silence back
    in would let one hang raise its own cap forever — while the kills are the only evidence a pair
    whose real behaviour is past its cap ever produces: with nothing but completions it would be
    killed at the same cap on every later run, for ever. A kill BEHIND the pair's last completion
    says nothing about what it needs now, so a completion clears the kill record; runs are walked
    in run-id order for exactly that reading.
    """
    maxima, breached, quiet, stall_breached, kill_streaks = {}, {}, {}, {}, {}
    for directory in sorted(benches.iterdir()) if benches.exists() else ():
        meta_path = directory / "meta.json"
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text())
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        run_kills, run_retry_kills, run_done = {}, {}, set()
        rows = list(meta.get("rater_runs", ()))
        # Which rows an in-run retry superseded: the LAST row of a spec is the cell's answer and
        # every earlier one is an attempt it replaced (`cell_attempt_rows` reads them the same way).
        final_index = {row.get("rater"): index for index, row in enumerate(rows)}
        for index, row in enumerate(rows):
            key = panel_cell_key(row)
            if key is None:
                continue
            superseded_row = index != final_index.get(row.get("rater"))
            # A retried kill rides on whatever row the retry produced — the row itself still
            # counts as what it is (a completion feeds maxima and quiet, an error nothing).
            retried = row.get("stalled_retry_s")
            if isinstance(retried, (int, float)) and not isinstance(retried, bool) and retried > 0:
                stall_breached[key] = max(float(retried), stall_breached.get(key, 0.0))
            stalled = row.get("stalled_s")
            if isinstance(stalled, (int, float)) and not isinstance(stalled, bool) and stalled > 0:
                stall_breached[key] = max(float(stalled), stall_breached.get(key, 0.0))
                continue
            if watchdog_killed(row):
                cap = timeout_seconds_from_row(row)
                if cap:
                    target = run_retry_kills if superseded_row else run_kills
                    target[key] = max(cap, target.get(key, cap))
                continue
            if cell_status(row) != "completed":
                continue
            # A completion whose duration lives only in the legacy top-level map still clears
            # the kill record; only the maxima need the number.
            run_done.add(key)
            duration = cell_pass_duration(row)
            if duration is None:
                continue
            maxima[key] = max(duration, maxima.get(key, duration))
            gap = row.get("max_quiet_ms")
            if isinstance(gap, (int, float)) and not isinstance(gap, bool) and gap >= 0:
                quiet[key] = max(gap, quiet.get(key, gap))
        # Strikes are counted in RUNS, not rows: a T2 panel holds three cells of one pair, and a
        # single bad run must cost one strike, not the whole escalation probe. A pair that also
        # completed in the run proved it works — those kills clear with the rest.
        for key in run_done:
            breached.pop(key, None)
            kill_streaks.pop(key, None)
        for key, cap in run_kills.items():
            if key in run_done:
                continue
            if kill_streaks.get(key, 0) + 1 >= CHRONIC_FAILURE_STREAK:
                # The third strike ends the probe EPISODE, not the pair's right to probe: kept, the
                # record pinned a pair with no completion at the floor for ever — its streak could
                # only clear on a completion the floor cap itself prevented. Cleared, the next kill
                # opens a fresh episode: a dead cell costs one grace per run on average, and a
                # merely slow one still meets a cap two graces up every third run.
                breached.pop(key, None)
                kill_streaks.pop(key, None)
                continue
            breached[key] = max(cap, breached.get(key, cap))
            kill_streaks[key] = kill_streaks.get(key, 0) + 1
        # A cap kill the retry replaced outlives it, exactly as a stall kill does: cleared with the
        # completion the retry produced, a cap that is merely too tight escalates on no run at all
        # and the pair pays the same kill for ever. It raises the cap and costs no strike — the
        # retry is the proof the cell works, and a run holding no completion for the pair has no
        # such proof: applied there, a cell killed in the attempt AND the retry re-entered
        # `breached` the strike loop had just popped and never returned to the floor at all.
        for key, cap in run_retry_kills.items():
            if key not in run_done:
                continue
            breached[key] = max(cap, breached.get(key, cap))
    return maxima, breached, quiet, stall_breached, kill_streaks


def panel_duration_maxima(benches):
    return panel_cell_history(benches)[0]


# Three, because two in a row happens to every cell on a capacity weather day: below this the
# report would carry a streak on cells that are merely unlucky, and the watchdog would cut a
# pair's escalation probe short for the same bad luck.
CHRONIC_FAILURE_STREAK = 3
CHRONIC_STREAK_WALK_RUNS = 30


def cell_failure_streaks(benches, run_id, raters):
    """How many runs in a row each named cell has been failing, this run counted as the first.

    Runs that never held the cell are passed over rather than ending the streak: a cell absent from
    a T0 panel is not evidence it recovered there.
    """
    wanted = {rater for rater in raters if rater}
    if not wanted or not benches.exists():
        return {}
    # Newest first, metas read one at a time: the history grows without bound and is walked per
    # report, so the walk stops the moment every named cell has met a completion — and at a hard
    # window regardless, because a cell with no completion anywhere in the store (the chronic case
    # this row exists for) would otherwise send every report through the whole history. A streak
    # deeper than the window reads as the window: the row needs "3+ fails in a row", not the true
    # depth of a months-long hole.
    names = sorted(
        (entry.name for entry in benches.iterdir()
         if entry.name < run_id and entry.is_dir()),
        reverse=True,
    )[:CHRONIC_STREAK_WALK_RUNS]
    streaks = dict.fromkeys(wanted, 1)
    broken = set()
    for name in names:
        try:
            meta = json.loads((benches / name / "meta.json").read_text())
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        outcomes = {}
        for row in meta.get("rater_runs", ()):
            rater = row.get("rater")
            status = cell_status(row) if rater in wanted and rater not in broken else None
            if status and status != "not_run":
                outcomes[rater] = status != "completed"
        for rater, failed in outcomes.items():
            if failed:
                streaks[rater] += 1
            else:
                broken.add(rater)
        if len(broken) == len(wanted):
            break
    return streaks


def watchdog_timeout_seconds(duration_ms):
    if duration_ms is None:
        return _catalog.WATCHDOG_FLOOR_S
    return max(
        _catalog.WATCHDOG_FLOOR_S, math.ceil(float(duration_ms) / 1000) + _catalog.WATCHDOG_GRACE_S
    )


def panel_watchdog_timeouts(benches):
    maxima, breached, _, _, _ = panel_cell_history(benches)
    timeouts = {}
    for key in set(maxima) | set(breached):
        timeout = watchdog_timeout_seconds(maxima.get(key))
        if key in breached:
            # A cap a pair has already been killed at is a cap it needs more than: the next run
            # gives it one grace more, up to the ceiling every cell used to share, so a slow model
            # climbs out instead of being killed at the floor on every run it ever gets. The climb
            # is a probe with three strikes, not a right — the history drops a pair's kill record
            # on its third kill in a row, which is why a breach standing here always escalates: a
            # genuinely dead cell was buying one grace more per run and walked every panel's wall
            # from 15 toward 30 minutes in one night (2026-08-16).
            timeout = max(timeout, min(_catalog.RATER_TIMEOUT_S,
                                       math.ceil(breached[key]) + _catalog.WATCHDOG_GRACE_S))
        timeouts[key] = timeout
    return timeouts


def panel_stall_timeouts(benches):
    """The stall cap per (model, effort) pair: the longest gap a completion of the pair ever went
    silent for, plus grace. Only for pairs whose gaps stay well under their runtimes — the evidence
    the pair streams at all: a buffered side shows gaps the size of its whole runs and gets no cap,
    so a cell that is quiet the way its shape always is can never be killed for it, and a pair with
    no gap history gets none either. A cap a pair was already killed at grows by one grace per
    run, so a wrong kill corrects itself instead of repeating — unbounded, unlike the duration
    cap's three-strike probe: a stall kill costs the run one in-cell retry, not its wall, and the
    duration cap still bounds the cell either way.
    """
    maxima, _, quiet, stall_breached, _ = panel_cell_history(benches)
    caps = {}
    for key, gap_ms in quiet.items():
        duration = maxima.get(key)
        if not duration or gap_ms >= _catalog.STALL_STREAM_RATIO * duration:
            continue
        cap = max(_catalog.STALL_FLOOR_S, math.ceil(gap_ms / 1000) + _catalog.STALL_GRACE_S)
        if key in stall_breached:
            cap = max(cap, math.ceil(stall_breached[key]) + _catalog.STALL_GRACE_S)
        caps[key] = cap
    return caps


def tier_cell_counter(cells):
    counts = Counter()
    for cell in cells:
        for rater in _raters.parse_raters(cell):
            family = _raters.rater_family(rater["spec"])
            family = _catalog.EXCLUDED_CELL_REPLACEMENTS.get(family, family)
            counts[family] += 1
    return counts


def completed_raters_from_meta(meta):
    if "completed_raters" in meta:
        return list(meta.get("completed_raters") or ())
    rows = [row for row in meta.get("rater_runs", ()) if row.get("rater")]
    if rows:
        return [row["rater"] for row in rows if cell_status(row) == "completed"]
    return list(meta.get("raters", ()))


def rater_specs_counter(specs):
    counts = Counter()
    for spec in specs:
        family = _raters.rater_family(spec)
        family = _catalog.EXCLUDED_CELL_REPLACEMENTS.get(family, family)
        counts[family] += 1
    return counts


def legacy_tier_match(actual):
    matches = set()
    # Recorded specs are read leniently and tier specs strictly: a cell retired since the run
    # was written would otherwise make parse_rater refuse the whole report, and a run stays
    # readable long after its cells stop being runnable. The tiers below come from
    # REVIEW_TIERS, which is validated at import, so nothing there can fail to parse.
    actual_sides = {
        side for side in (_raters.rater_side(family) for family in actual) if side
    }
    for tier_name, tier in _catalog.REVIEW_TIERS.items():
        for composition in ("cells", "cells_max"):
            expected = tier_cell_counter(tier[composition])
            if expected == actual:
                matches.add((tier_name, composition))
                continue
            missing = expected - actual
            if actual - expected or not missing:
                continue
            missing_sides = {
                _raters.parse_rater(family)["side"]
                for family in missing
            }
            if len(missing_sides) == 1 and missing_sides.isdisjoint(actual_sides):
                matches.add((tier_name, composition))
    tiers = {tier_name for tier_name, _ in matches}
    if len(tiers) != 1:
        return None
    tier_name = next(iter(tiers))
    compositions = {composition for _, composition in matches}
    return f"{tier_name} max" if compositions == {"cells_max"} else tier_name


def tier_from_meta(meta):
    explicit = meta.get("tier")
    if explicit in _catalog.REVIEW_TIERS:
        return f"{explicit} max" if bool(meta.get("max")) else explicit
    specs = list(meta.get("raters", ()))
    if "completed_raters" not in meta:
        attempts = [
            row.get("rater") for row in meta.get("rater_runs", ())
            if row.get("rater")
        ]
        if attempts:
            specs = attempts
    return legacy_tier_match(rater_specs_counter(specs)) if specs else None


def cell_status(row):
    if row.get("not_run"):
        return "not_run"
    stderr = str(row.get("stderr") or "")
    if row.get("exit_code") == 0 and not row.get("errored"):
        return "completed"
    if re.search(r"\bserved\b.+\binstead of\b", stderr, re.IGNORECASE | re.DOTALL):
        return "model_mismatch"
    if row.get("exit_code") == 124 or re.search(
        r"\btime(?:d|out|out waiting)\b|timeout", stderr, re.IGNORECASE
    ):
        return "timed_out"
    return "nonzero_exit" if row.get("exit_code") not in (None, 0) else "errored"


FAILURE_REASONS = (
    # Ordered by how specific the wording is, not by how often the cause occurs: a pool-empty
    # message quotes the error of the last account it tried, so any later pattern would claim it.
    ("pool empty", re.compile(r"has no \w+ account left", re.IGNORECASE)),
    ("walled", re.compile(
        r"GoUsageLimitError|limitName|usage limit|out of credits|usage balance exhaust"
        r"|402 Payment Required|Individual quota reached|RESOURCE_EXHAUSTED"
        r"|exhausted your capacity on this model|walled off while", re.IGNORECASE)),
    ("throttled", re.compile(
        r"provider_rate_limit_exceeded|rate_limit_error|provider rate limit"
        r"|rate limit exceeded|too many requests", re.IGNORECASE)),
    # Kept apart from a throttle on purpose: a bare 429 is equally a spent plan, and the code
    # that stopped retiring accounts over one would be undone by a table that calls it a throttle.
    ("bare 429", re.compile(r"\b429\b")),
    ("bad output", re.compile(
        r"no parseable finding|malformed (?:Markdown|JSON)|no explicit no-issues"
        r"|did not declare a clean review|stopped before reviewing|returned empty content",
        re.IGNORECASE)),
    ("capacity", re.compile(r"at capacity|temporarily unavailable|overloaded", re.IGNORECASE)),
    ("server error", re.compile(_catalog.HTTP_SERVER_STATUS)),
    ("root commit", re.compile(r"root commit", re.IGNORECASE)),
    ("permission", re.compile(r"tool required the .command. permission", re.IGNORECASE)),
    ("bad command", re.compile(r"cannot be used with", re.IGNORECASE)),
    ("stalled", re.compile(r"rater stalled", re.IGNORECASE)),
    ("timeout", re.compile(r"timed out|timeout", re.IGNORECASE)),
    ("crashed", re.compile(
        r"rater task crashed|account lookup failed|codex_core::", re.IGNORECASE)),
    ("auth", re.compile(r"not logged in|unauthor|forbidden|\b40[13]\b", re.IGNORECASE)),
)


def failure_reason(stderr):
    """The cause a failure's own text names, in the one word a report column can hold.

    This reads the text after the fact and never decides control flow; the side-specific wall
    and transient predicates do that. Separating the two is what lets this name causes those
    predicates deliberately refuse to tell apart, a bare 429 above all.
    """
    text = stderr or ""
    for reason, pattern in FAILURE_REASONS:
        if pattern.search(text):
            return reason
    return "unclassified" if text.strip() else "no output"


# One vocabulary for every surface that names a cause, the report first: a word spelled here and
# respelled anywhere else is a cause the reader has to translate. The kills say what ended them —
# our cap or our silence watch — because a cell the panel stopped and one that died on its own are
# not the same news.
STATUS_REASONS = {
    "not_run": "not run", "timed_out": "killed · cap", "model_mismatch": "mismatch",
}
CELL_STALL_REASON = "killed · stalled"


def cell_failure_reason(cell):
    """Why one cell that did not complete failed, in the report's own vocabulary."""
    # A stall kill shares the timeout's exit code; the reader deciding whether to trust the panel
    # needs to know the cell was silent, not slow.
    if cell.get("stalled_s"):
        return CELL_STALL_REASON
    status = cell.get("status")
    # `killed · cap` names OUR watchdog and nothing else: `cell_status` reads a provider's own
    # timeout wording as a timeout too, and blamed on the panel's cap it sends the reader to raise
    # a cap that never operated.
    if status == "timed_out" and not watchdog_killed(cell):
        return failure_reason(cell.get("stderr"))
    if status in STATUS_REASONS:
        return STATUS_REASONS[status]
    return failure_reason(cell.get("stderr"))


def timeout_seconds_from_row(row):
    timeout = row.get("timeout_s")
    if isinstance(timeout, (int, float)) and not isinstance(timeout, bool) and timeout > 0:
        return float(timeout)
    text = f"{row.get('command') or ''}\n{row.get('stderr') or ''}"
    match = re.search(r"--print-timeout\s+['\"]?(\d+(?:\.\d+)?)([sm])", text)
    if not match:
        match = re.search(r"timed out after\s+(\d+(?:\.\d+)?)s", text, re.IGNORECASE)
        return float(match.group(1)) if match else None
    value = float(match.group(1))
    return value * 60 if match.group(2) == "m" else value


def run_finished_at(meta):
    """When the run itself ended. `finished_at` is the older spelling, still on stored runs."""
    return _store.parse_iso_timestamp(meta.get("finished") or meta.get("finished_at"))


def cell_attempt_rows(rows):
    """One row per cell, and the attempts an in-run retry superseded hung under it.

    A retried cell recorded both attempts under one spec, and the report answers for the final
    one alone: counted twice, one cell would sit in `failed:` and in `found:` at once and the
    panel would read as holding a member it never had. The superseded rows stay reachable because
    what they cost is part of the cell's own stretch of the wall clock, and because the kill one
    of them may carry is what teaches the next run's cap.
    """
    grouped = {}
    for row in rows:
        grouped.setdefault(row.get("rater"), []).append(row)
    final = []
    attempts = {}
    for rater, group in grouped.items():
        final.append(group[-1])
        if len(group) > 1:
            attempts[rater] = group[:-1]
    return final, attempts


def cell_record(row, run_dir, durations, attempts=()):
    """One recorded attempt as the shape everything downstream reads a cell in.

    The superseded attempts of a retried cell are built the same way and hung under it: `health`
    prices the pool per ACCOUNT, and an attempt that walled one account before the retry cleared
    on another is the whole of what that view exists to show.
    """
    rater = row.get("rater")
    findings = row.get("findings")
    if (not isinstance(findings, int) or isinstance(findings, bool)) and rater:
        findings = len(_store.finding_rows(run_dir, rater))
    if not isinstance(findings, int) or isinstance(findings, bool):
        findings = 0
    duration = row.get("duration_ms")
    if (
        not isinstance(duration, (int, float))
        or isinstance(duration, bool)
        or duration < 0
    ):
        duration = durations.get(rater)
    return {
        "rater": rater,
        "duration_ms": duration,
        "status": cell_status(row),
        "started_at": row.get("started_at"),
        "finished_at": row.get("finished_at"),
        "verify_ms": row.get("verify_ms"),
        "verify_wall_ms": row.get("verify_wall_ms"),
        "attempts": list(attempts),
        "findings": findings,
        "verifier_dropped": _store.counted_int(row.get("verifier_dropped")),
        "verifier_unverified": _store.counted_int(row.get("verifier_unverified")),
        "verifier_audited": _store.counted_int(row.get("verifier_audited")),
        "verifier_ran": row.get("verify_ms") is not None,
        "verifier_by_model": {
            str(model): _store.counted_int(count)
            for model, count in (row.get("verifier_by_model") or {}).items()
        } if isinstance(row.get("verifier_by_model"), dict) else {},
        "exit_code": row.get("exit_code"),
        "timeout_s": timeout_seconds_from_row(row),
        "stalled_s": row.get("stalled_s"),
        "killed": row.get("killed"),
        "killed_cap_s": row.get("killed_cap_s"),
        "max_quiet_ms": row.get("max_quiet_ms"),
        "stderr": row.get("stderr"),
        "side": row.get("side") or _raters.rater_side(rater),
        "account": row.get("account"),
    }


def docs_finding(finding):
    """Whether this finding is about prose rather than about code.

    A `.md` finding is confirmed like any other and the fixing pass fixes it, but it carries no P
    weight: prose is something an LLM may never read, while code executes on every run — so a
    round's severities, its total and both of the gate's dials price code alone.
    """
    return str((finding or {}).get("file") or "").endswith(".md")


def docs_confirmed_count(run_dir, verdicts):
    """How many of a triage's confirmed findings are prose, for the readers that hold no summary of
    their own."""
    findings_by_rater = {}
    total = 0
    for row in verdicts or ():
        if not isinstance(row, dict) or row.get("verdict") != "confirmed":
            continue
        rater = row.get("rater")
        idx = row.get("idx")
        if not rater or not isinstance(idx, int) or isinstance(idx, bool):
            continue
        if rater not in findings_by_rater:
            findings_by_rater[rater] = _store.finding_rows(run_dir, rater)
        rows = findings_by_rater[rater]
        if 0 <= idx < len(rows) and docs_finding(rows[idx]):
            total += 1
    return total


def bench_summary(run_dir, meta, verdicts=None):
    cells = []
    recorded = [dict(row) for row in meta.get("rater_runs", ()) if isinstance(row, dict)]
    rows, superseded = cell_attempt_rows(recorded)
    seen = {row.get("rater") for row in rows if row.get("rater")}
    successful = set(completed_raters_from_meta(meta))
    for rater in (*meta.get("raters", ()), *meta.get("durations", {})):
        if rater and rater not in seen:
            row = {"rater": rater}
            if rater in successful:
                row["exit_code"] = 0
            else:
                row["not_run"] = True
            rows.append(row)
            seen.add(rater)
    durations = meta.get("durations", {})
    for row in rows:
        rater = row.get("rater")
        if rater in successful and "exit_code" not in row and not row.get("errored"):
            row["exit_code"] = 0
        cells.append(cell_record(row, run_dir, durations, [
            cell_record(attempt, run_dir, durations)
            for attempt in superseded.get(rater, ())
        ]))
    verdict_path = run_dir / "verdicts.jsonl"
    # Verdicts handed in rather than read back are a triage that is deliberately not recorded:
    # reporting it must leave no file behind, or the run reads as half-adjudicated to `list`,
    # `cluster` and the receipt logic, each of which decides on what is on disk.
    adjudicated = True if verdicts is not None else verdict_path.exists()
    supplied = verdicts if verdicts is not None else (
        _store.read_jsonl(verdict_path) if verdict_path.exists() else []
    )
    verdicts = [
        row for row in supplied
        if row.get("rater") and row.get("verdict") in _catalog.VERDICTS
    ]
    verdict_counts = Counter(row["verdict"] for row in verdicts)
    severities = Counter()
    docs = 0
    false_by = Counter()
    confirmed_by = Counter()
    judged_by = Counter()
    findings_by_rater = {}
    for row in verdicts:
        judged_by[row["rater"]] += 1
        if row["verdict"] == "false_positive":
            # Per cell INSTANCE, the way the confirmed counter beside it counts: keyed by family
            # here, an instance that produced no noise of its own could not be told from one that
            # did, and the report's `quiet:` row is read off exactly that. The `noise:` row does
            # the collapsing itself.
            false_by[row["rater"]] += 1
        if row["verdict"] != "confirmed":
            continue
        confirmed_by[row["rater"]] += 1
        rater = row["rater"]
        if rater not in findings_by_rater:
            findings_by_rater[rater] = _store.finding_rows(run_dir, rater)
        idx = row.get("idx")
        if isinstance(idx, int) and 0 <= idx < len(findings_by_rater[rater]):
            finding = findings_by_rater[rater][idx]
            if docs_finding(finding):
                docs += 1
            elif finding.get("severity") in _catalog.WEIGHTS:
                severities[finding["severity"]] += 1
    rejected_tokens = sum(
        verdict_counts[verdict] * estimate
        for verdict, estimate in _catalog.ADJUDICATION_TOK_ESTIMATE.items()
    )
    started = _store.parse_iso_timestamp(meta.get("started") or meta.get("started_at"))
    finished = _store.parse_iso_timestamp(meta.get("finished") or meta.get("finished_at"))
    return {
        "tier": tier_from_meta(meta),
        "cells": cells,
        "findings": sum(cell["findings"] for cell in cells),
        "verifier": str(meta.get("verifier") or ""),
        "verify_after_panel_ms": meta.get("verify_after_panel_ms"),
        "verifier_dropped": sum(cell["verifier_dropped"] for cell in cells),
        "verifier_unverified": sum(cell["verifier_unverified"] for cell in cells),
        "verifier_audited": sum(cell["verifier_audited"] for cell in cells),
        "verifier_by_model": dict(sum(
            (Counter(cell["verifier_by_model"]) for cell in cells), Counter()
        )),
        "adjudicated": adjudicated,
        "confirmed": verdict_counts["confirmed"],
        "duplicate": verdict_counts["duplicate"],
        "false_positive": verdict_counts["false_positive"],
        "severities": severities,
        "docs": docs,
        "false_by": false_by,
        "confirmed_by": confirmed_by,
        "judged_by": judged_by,
        "token_estimate": rejected_tokens,
        "wall_seconds": max(0, (finished - started).total_seconds())
        if started and finished else None,
    }


def review_log_event(event, run_dir, meta):
    summary = bench_summary(run_dir, meta)
    payload = {
        "event": event,
        "run_id": meta.get("run_id") or run_dir.name,
        "ts": _store.iso_now(),
        "started": meta.get("started") or meta.get("started_at"),
        "finished": meta.get("finished") or meta.get("finished_at"),
        "cells": summary["cells"],
        "findings": summary["findings"],
        "confirmed": summary["confirmed"],
        "duplicate": summary["duplicate"],
        "false_positive": summary["false_positive"],
        "token_estimate": summary["token_estimate"],
    }
    if summary["tier"]:
        payload["tier"] = summary["tier"]
    return payload


