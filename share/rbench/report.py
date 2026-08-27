import fcntl
import json
import os
import shutil
import math
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from chat_names import worker_session_launchers

from . import store as _store
from . import catalog as _catalog
from . import raters as _raters
from . import panel as _panel
from . import prompts as _prompts
from . import round as _round

def report_frame_header(word, width=_round.REPORT_FRAME_WIDTH):
    """The word centered in '=' to exactly `width`, one space each side. Its consumers key on the
    shape (`^=+ [a-z]+ =+$`) rather than on the wording, so the same frame carries other kinds of
    report elsewhere without any of them agreeing on a marker string. A word with no room left
    for padding widens the line past `width` instead of losing it: an edge without its '=' stops
    matching that shape, and the block it opens stops being found at all.
    """
    fill = max(2, width - len(word) - 2)
    left = fill // 2
    return f"{'=' * left} {word} {'=' * (fill - left)}"


REVIEW_LATE_MULTIPLIER = 3
REVIEW_LATE_FLOOR_S = 120


def append_review_log(event):
    path = _store.state_dir() / "review-log.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, payload)
    finally:
        os.close(fd)


def log_review_event(event, run_dir, meta):
    try:
        append_review_log(_panel.review_log_event(event, run_dir, meta))
    except Exception as exc:
        print(f"warning: could not write review log: {exc}", file=sys.stderr)


def estimated_tokens_text(tokens):
    if tokens < 1000:
        return f"~{tokens} tok"
    return f"~{math.floor(tokens / 1000 + 0.5)}k tok"


def aligned_report_lines(rows):
    width = max((len(label) for label, _ in rows), default=0)
    lines = []
    for label, value in rows:
        if not value:
            lines.append(label)
            continue
        # A row whose value runs to several lines keeps them under the value column: written flush
        # left they read as rows of their own with the label missing.
        head, *rest = str(value).split("\n")
        lines.append(f"{label:<{width}}  {head}")
        lines.extend(f"{'':<{width}}  {line}" for line in rest)
    return lines


SIDE_LEG_NAME = {"claude": "CLAUDE", "codex": "CODEX", "agy": "GEMINI", "opencode": "OPENCODE"}
# The column every value in a report block starts at, wrapped continuations included. Fixed rather
# than measured off the labels, so the same row sits under the same column in every run's block.
REPORT_LABEL_WIDTH = 14
REPORT_WIDTH_FALLBACK = 100
# Under half a minute a duration is noise in a block read for where the time went.
REPORT_DURATION_FLOOR_MS = 30000
# The share of a tier's own budget that may go unaccounted for before the header shouts about it,
# and the ceiling that share is capped at: past five minutes of nobody's time the tier no longer
# decides whether it matters.
REPORT_LOST_SHARE = 3
REPORT_LOST_CAP_S = 300


def report_width():
    """The width a report block is laid out to: the terminal's, `COLUMNS` included, or 100 where
    there is no terminal — a block rendered into a hook's capture has no width of its own."""
    return shutil.get_terminal_size((REPORT_WIDTH_FALLBACK, 20)).columns


def report_ms(value):
    """A duration read back out of someone else's JSON, or 0 where none was recorded."""
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
        return 0.0
    return float(value)


def report_minutes(ms):
    """Every duration a report block prints, in the one unit it prints them in."""
    return f"{report_ms(ms) / 60000:.1f} min"


def report_cell_name(spec, scheme=None):
    """`kimi·2` for the second instance of one cell in a panel. `#2` is how the store spells an
    instance, and a report is not read in the store's spelling."""
    base, _, instance = str(spec or "").partition("#")
    name = _raters.human_cell_name(base, scheme)
    return f"{name}·{instance}" if instance else name


def report_block_lines(rows, width=None):
    """The rows of a report block, each `(label, value, wrappable)`, at one value column.

    A wrappable value breaks between its ` · ` items and never inside one: the pairs these rows
    are made of — `name n/m`, `killed · cap` — say nothing once they are split over two lines.
    Continuations carry no label and sit under the value column, or they read as rows of their own
    with the label missing.
    """
    width = report_width() if width is None else width
    label_width = max(
        REPORT_LABEL_WIDTH, max((len(label) for label, _, _ in rows), default=0) + 1
    )
    room = max(20, width - label_width)
    lines = []
    for label, value, wrappable in rows:
        body, current = [], ""
        for item in str(value).split(" · ") if wrappable else [str(value)]:
            candidate = item if not current else f"{current} · {item}"
            if current and len(candidate) > room:
                body.append(current)
                current = item
            else:
                current = candidate
        body.append(current)
        for index, line in enumerate(body):
            lines.append(f"{(label if index == 0 else ''):<{label_width}}{line}".rstrip())
    return lines


def report_frame_word(run_dir, meta, state=None, summary=None):
    """The word this run's frame carries, which is the only place the block states its own STATE.

    One word, in the order the reader's next move goes: a round whose fixing pass stopped is
    Egor's to decide whatever else is true of it, an empty panel says nothing about fixes, and a
    stale block is only worth naming while the rest of it is ordinary.
    """
    if not _panel.tier_from_meta(meta):
        return _round.REPORT_BENCH_WORD
    # Which round this is, before any state: it is the block's own identity — a reader who cannot
    # see it at the top has to reach the `before:` row to know which of the two he is holding.
    word = _round.round_frame_word(_round.review_round(run_dir, meta))
    state = _round.round_state(run_dir) if state is None else state
    if state == "blocked":
        return f"{word} · {_round.REPORT_BLOCKED_SUFFIX}"
    cells = (summary if summary is not None else _panel.bench_summary(run_dir, meta))["cells"]
    if not any(cell["status"] == "completed" for cell in cells):
        return f"{word} · {_round.REPORT_NO_PANEL_SUFFIX}"
    # Undated it would say a block is old and refuse to say how old. In the reader's own zone,
    # because his clock is what he compares it against — the record keeps UTC.
    finished = _panel.run_finished_at(meta)
    if finished and _store.utc_now() - finished > timedelta(hours=_round.REPORT_STALE_HOURS):
        local = finished.astimezone()
        return f"{word} · {_round.REPORT_STALE_SUFFIX} · {local.day} {local.strftime('%b')}"
    return word


def timed_cells(cells):
    return [cell for cell in cells if isinstance(cell.get("duration_ms"), (int, float))
            and not isinstance(cell.get("duration_ms"), bool) and cell["duration_ms"] >= 0]


def cell_verify_ms(cell):
    """Of a cell's verification, the part that held the RUN open — its whole duration on a record
    written before verification started overlapping the panel.
    """
    if cell.get("verify_wall_ms") is not None:
        return report_ms(cell["verify_wall_ms"])
    return report_ms(cell.get("verify_ms"))


def cell_chain_ms(cell):
    """How long one cell held its slot of the run open: what it ran, what the retry it earned ran,
    and the verification of its findings, which starts when the cell itself is done and so may
    run beside other cells — of which only the part that outlived the panel is this cell's own
    stretch of the wall.

    The queue it waited in is deliberately outside this. That time is what the header's LOST names,
    and folded in here it would read as the cell's own cost and vanish from the block entirely.
    """
    return (
        report_ms(cell.get("duration_ms"))
        + cell_verify_ms(cell)
        + sum(report_ms(attempt.get("duration_ms")) for attempt in cell.get("attempts") or ())
    )


def report_lost_cause(cells, meta, lost_ms):
    """What filled the wall clock the longest chain does not account for, where the run recorded
    enough to say: the cell that waited longest before it started, named by the side it waited on.

    Below half the lost time it is not the cause of anything and the header keeps the bare number:
    a queue named over time it did not hold sends the reader at the wrong leg.
    """
    started = _store.parse_iso_timestamp(meta.get("started") or meta.get("started_at"))
    if started is None or lost_ms <= 0:
        return None
    delays = []
    for cell in cells:
        # The retry overwrites `started_at`, so a retried cell's wait read off the final row
        # swallows the first attempt's whole runtime — time `cell_chain_ms` already counts — and
        # names a queue on a leg that never held it.
        starts = [_store.parse_iso_timestamp(cell.get("started_at"))]
        starts += [_store.parse_iso_timestamp(attempt.get("started_at"))
                   for attempt in cell.get("attempts") or ()]
        starts = [stamp for stamp in starts if stamp is not None]
        if starts:
            delays.append(((min(starts) - started).total_seconds(), cell))
    if not delays:
        return None
    delay, cell = max(delays, key=lambda entry: entry[0])
    if delay * 1000 < lost_ms / 2:
        return None
    return f"{SIDE_LEG_NAME.get(cell.get('side'), str(cell.get('side') or '?')).lower()} queue"


def report_header_value(summary, meta, scheme):
    """The one line that prices the run: its wall clock, the longest chain inside it, and whatever
    of the wall clock that chain does not account for.

    The chain and not the slowest cell, because a cell whose verification or retry ran after it
    held the panel open for all of it — and the difference between the two is the whole point of
    the row: it is the time nothing in the block below can be blamed for.
    """
    wall_s = summary["wall_seconds"]
    value = "unknown time" if wall_s is None else f"{wall_s / 60:.1f} min"
    candidates = timed_cells(summary["cells"])
    if candidates:
        chain = max(candidates, key=cell_chain_ms)
        # The chain the row is named for, minus the verification printed beside it: shown as the
        # final attempt alone, the components of a retried cell no longer add up to the wall.
        chain_verify_ms = cell_verify_ms(chain)
        held_ms = cell_chain_ms(chain) - chain_verify_ms
        value += f" / {report_minutes(held_ms)} {report_cell_name(chain['rater'], scheme)}"
        if chain.get("stalled_s") or _panel.watchdog_killed(chain):
            value += " killed"
        if chain_verify_ms >= REPORT_DURATION_FLOOR_MS:
            value += f" + {report_minutes(chain_verify_ms)} verify"
        if wall_s is not None:
            # The panel's own stretch is the chain minus its verification, and the verification
            # of the whole run is one span, not a sum: cells verify side by side, so subtracting
            # each remainder on its own prices one shared span once per cell and drove this
            # negative. A record written before the overlap carries no span and verified serially.
            after_panel_ms = summary.get("verify_after_panel_ms")
            if after_panel_ms is None:
                after_panel_ms = sum(
                    report_ms(cell.get("verify_ms")) for cell in summary["cells"]
                )
            lost_ms = (wall_s * 1000 - (cell_chain_ms(chain) - chain_verify_ms)
                       - report_ms(after_panel_ms))
            # `T1 max` is the tier plus its composition, and only the tier has a budget: read
            # whole, every max run falls back to the flat cap and loses the share of its own.
            budget_min = _catalog.REVIEW_TIERS.get(
                str(summary["tier"] or "").split(" ")[0], {}
            ).get("budget_min")
            # Only what is worth a reader's attention: a run always loses some minutes to its own
            # scheduling, and a number printed on every header is one nobody reads any more. The
            # threshold is a share of the tier's own budget, so the same lost minute is loud on a
            # T0 and beneath notice on a T3.
            loud_s = min(
                REPORT_LOST_CAP_S,
                budget_min * 60 / REPORT_LOST_SHARE if budget_min else REPORT_LOST_CAP_S,
            )
            if lost_ms >= loud_s * 1000:
                cause = report_lost_cause(summary["cells"], meta, lost_ms)
                value += f" · {report_minutes(lost_ms)} {cause or 'LOST'}"
    members = [entry for entry in meta.get("repos") or () if isinstance(entry, dict)]
    if members:
        value += " · " + ", ".join(
            str(entry.get("label") or Path(str(entry.get("repo"))).name) for entry in members
        )
    # A chunked round attests only the chunks its cells read, so a block that hides the count
    # reads as a panel that saw the whole diff. In the value and not the label, which every row's
    # value column is aligned to.
    if meta.get("chunks"):
        value += f" · {len(meta['chunks'])} chunks"
    return value


def verifier_verdict_counts(run_dir):
    """Per verifier model: how many findings it judged, and how many of them it rejected. Read off
    the audit rows because the run's own tally records neither of them per model."""
    checked, rejected = Counter(), Counter()
    for path in sorted(run_dir.glob("verified-*.jsonl")):
        for row in _store.read_jsonl(path):
            model = row.get("verifier")
            if not model:
                continue
            checked[str(model)] += 1
            if row.get("kept") is False:
                rejected[str(model)] += 1
    return checked, rejected


def verifier_report_value(run_dir, summary, scheme=None):
    """The `verifier:` value, or None where the panel held no cell the verifier is allowed to
    touch. Anywhere else the row stays, the silent case included: a run nobody checked and one
    where every claim survived read alike without it.
    """
    # Cells that COMPLETED: a leg that never ran offered the verifier nothing, and `off` printed
    # over it reads as a check that was skipped rather than one that had nothing to check.
    eligible = [
        cell for cell in summary["cells"]
        if cell["side"] in _round.VERIFIED_SIDES and cell["status"] == "completed"
    ]
    if not eligible:
        return None
    checked, rejected = verifier_verdict_counts(run_dir)
    # A run recorded before the audit rows carried a model name has no per-model tally at all, and
    # the run's own totals are then the only record of what was judged.
    audited_total = sum(checked.values()) or max(
        summary["verifier_audited"], summary["verifier_dropped"])
    rejected_total = sum(rejected.values()) if checked else summary["verifier_dropped"]
    # What no audit row covers, whichever record knows it: a verifier that walled part-way is the
    # only one that records its own unchecked count, and one that never ran records nothing — so a
    # row reading the tally alone reports a panel nobody checked as a panel with nothing to check.
    # The findings count is POST-filter — a rejected claim is already gone from it — while the
    # audit rows include the rejections: subtracting all of them let a run with both rejections
    # and fail-open verifier rows report nothing unchecked.
    unchecked = max(
        summary["verifier_unverified"],
        sum(_store.counted_int(cell["findings"]) for cell in eligible)
        - (audited_total - rejected_total),
    )
    if not checked:
        # `off` is the SWITCH and not the outcome: a verifier that RAN and walled on every claim,
        # and one from before the audit rows carried a model name, both leave no per-model row and
        # neither is off. The reader is owed the name of the model to look at either way — the
        # run's own totals where it has them, the wall where it has none.
        ran = bool(audited_total or summary["verifier_unverified"]
                   or any(cell["verifier_ran"] for cell in eligible))
        if not (ran and summary["verifier"]):
            return f"off · {unchecked} unchecked"
        name = _raters.human_cell_name(summary["verifier"], scheme)
        parts = [f"{name} {audited_total}/{rejected_total}" if audited_total
                 else f"{name} walled"]
        if unchecked:
            parts.append(f"{unchecked} unchecked")
        return " · ".join(parts)
    parts = [
        f"{_raters.human_cell_name(model, scheme)} {count}/{rejected[model]}"
        for model, count in checked.most_common()
    ]
    if unchecked:
        parts.append(f"{unchecked} unchecked")
    return " · ".join(parts)


def report_failed_rows(run_dir, summary, meta, scheme):
    """The `failed:` rows: one per family and cause, and one CAPS row for a whole side the panel
    never launched at all.

    A side with nothing launched is one fact and not eight — the reader's next move is the leg
    itself — and naming every cell of it buries the cells that did fail. A not-run instance whose
    sibling of the same family failed inherits that sibling's cause: they are one cell asked for
    twice, and a `not run` row beside the failure it was skipped for says nothing.
    """
    cells = summary["cells"]
    failed = [cell for cell in cells if cell["status"] != "completed"]
    if not failed:
        return []
    by_side = defaultdict(list)
    for cell in cells:
        by_side[cell.get("side")].append(cell)
    recorded = {
        str(entry.get("rater")): str(entry.get("state") or "")
        for entry in meta.get("skipped") or () if isinstance(entry, dict)
    }
    legs = {
        side for side, members in by_side.items()
        if side and all(member["status"] == "not_run" for member in members)
    }
    rows = []
    for side in sorted(legs):
        states = {recorded.get(member["rater"], "") for member in by_side[side]}
        # `off` is a switch nobody closed unless a record says so: as the default it named a leg
        # spent on walls — or one from before `skipped` was recorded — as one Egor turned off.
        word = next(
            (state for state in ("walled", "cooling", "off") if state in states), "not run"
        )
        rows.append((f"{SIDE_LEG_NAME.get(side, str(side).upper())} LEG {word.upper()}", "", ""))
    failed = [cell for cell in failed if cell.get("side") not in legs]
    if not failed:
        return rows
    streaks = _panel.cell_failure_streaks(
        run_dir.parent, run_dir.name, [cell["rater"] for cell in failed]
    )
    family_cause = {}
    for cell in failed:
        if cell["status"] != "not_run":
            family_cause.setdefault(_raters.rater_family(cell["rater"]), _panel.cell_failure_reason(cell))
    groups = {}
    for cell in failed:
        family = _raters.rater_family(cell["rater"])
        cause = (
            family_cause.get(family, _panel.STATUS_REASONS["not_run"])
            if cell["status"] == "not_run" else _panel.cell_failure_reason(cell)
        )
        groups.setdefault((family, cause), []).append(cell)
    for (family, cause), members in groups.items():
        # One instance of a family whose sibling completed must keep its `·2`: printed as the
        # bare family it reads as the sibling standing in `found:`.
        name = (
            f"{_raters.human_cell_name(family, scheme)} ×{len(members)}" if len(members) > 1
            else report_cell_name(members[0]["rater"], scheme)
        )
        streak = max(
            (streaks.get(cell["rater"]) or 0
             for cell in members if cell["status"] != "not_run"),
            default=0,
        )
        if streak >= _panel.CHRONIC_FAILURE_STREAK:
            cause += f" · {streak} runs in a row"
        duration = max((report_ms(cell.get("duration_ms")) for cell in members), default=0)
        rows.append((
            name, cause,
            report_minutes(duration) if duration >= REPORT_DURATION_FLOOR_MS else "",
        ))
    return rows


def confirmed_tally(severities, total, docs):
    """The `confirmed:` row and the one-line `triaged` delivery read this one call, so the two
    can never disagree."""
    if not total:
        return "0"
    return " · ".join([
        *(f"{level} {severities[level]}" for level in _prompts.LENS_SEVERITIES),
        f"{total - docs} total",
        *([f"{docs} in docs"] if docs else []),
    ])


def triaged_line(run_dir, meta):
    summary = _panel.bench_summary(run_dir, meta, _round.recorded_verdict_rows(run_dir))
    tally = confirmed_tally(summary["severities"], summary["confirmed"], summary["docs"])
    return f"{_round.REPORT_FRAME_WORD} {run_dir.name} · triaged: {tally} — fixing pass next"


def fork_line(run_dir):
    """The one line a recorded decision reaches the chat as. The reason is deliberately not in it:
    it is the length of a paragraph, it is already on disk, and a confirmation is read for what was
    decided and what happens next.
    """
    fork = _round.read_fork(run_dir)
    if fork is None:
        raise ValueError(f"run {run_dir.name} has no decision on record")
    follows = "no round 2" if fork["choice"] == _round.BAND_FIX else "round 2"
    return f"review {run_dir.name} · decision: {fork['choice']} → {follows}"


def round_fork_text(run_dir, meta, verdicts=None):
    """The whole of what a round's report does NOT say: which way it goes from here.

    Egor does not read it — the model that has to act on it does, so `review-bench fork` hands it
    to the hook instead of the block spending eight lines on it. Empty is the ordinary answer: the
    round is in the `fix` band, or its decision is already on disk.
    """
    rows = verdicts if verdicts is not None else _round.recorded_verdict_rows(run_dir)
    parts = []
    state = _round.fix_status(run_dir, _round.confirmed_count(rows), rows)[1]
    if _round.review_round(run_dir, meta) >= _round.ROUND_BUDGET:
        # Only while that round still owes its fixing pass. `pending` is the whole of that: a round
        # with nothing confirmed, or one whose pass has answered, is closed, and telling the model
        # to fix what is confirmed and leave it uncommitted is work nobody asked for. A pass that
        # STOPPED is spoken for by the blocked text below instead.
        if state == "pending":
            parts.append(_round.ROUND_BUDGET_SPENT)
    elif _round.fork_missing(run_dir, meta, rows or []):
        p1, total = _round.escalation_numbers(run_dir, meta, rows or [])
        parts.append(round_decision_ask(p1, total))
    if state == "blocked":
        parts.append(_round.REPORT_BLOCKED_FORK)
    return "\n".join(parts)


def round_decision_ask(p1, total):
    """What a round owing a decision is told, in the four words and nothing else."""
    band = _round.round_band(p1, total)
    lead = (
        f"{p1} confirmed P1s, {total} confirmed findings: this round is a decision and not a list"
        if band == _round.BAND_HARD else
        f"{total} confirmed findings in one round: the way through it is a decision"
    )
    reason = (
        " — and `fix` here has to say why the code is worth keeping as it stands"
        if band == _round.BAND_HARD else ""
    )
    return (
        f"{lead}. Pick one of {_round.DECISION_MENU} and record it{reason}.\n"
        "fix closes on the commit that carries the fixes and runs no round 2; simplify, cut and "
        "redesign each run round 2 over the full original scope plus the fixes, and round 2 is "
        "the last round there is."
    )


def round_one_of(run_dir, meta):
    """A round 2's own round 1, as `(run_dir, meta)`, or None where the link names nothing this
    store still holds."""
    return next(iter(_round.chain_rounds(run_dir, meta)), None)


def round_one_tally(run_dir, meta):
    """Round 1's `confirmed:` value, rendered by the same call that wrote it, so the `before:` row
    beneath it is the very line that round's own block carried."""
    rows = _round.recorded_verdict_rows(run_dir)
    if rows is None:
        return ""
    summary = _panel.bench_summary(run_dir, meta, rows)
    return confirmed_tally(summary["severities"], summary["confirmed"], summary["docs"])


def fixes_row_value(run_dir, meta, verdicts, number):
    """What the round still owes, in the contract's three answers and no fourth.

    A non-fix decision moves the obligation to `next:` instead of describing that choice as a fix.
    """
    line, state = _round.fix_status(run_dir, _round.confirmed_count(verdicts), verdicts)
    # A pass that stopped, or a receipt answering for a triage this round no longer carries: both
    # are news about THIS round's fixes and outrank what would otherwise close it.
    if state == "blocked" or (state == "pending" and line):
        return line
    if number >= _round.ROUND_BUDGET:
        return "fix — the commit closes both rounds"
    if _round.fork_missing(run_dir, meta, verdicts):
        return f"decision first — {_round.DECISION_MENU}"
    decided = _round.read_fork(run_dir)
    if decided and decided["choice"] != _round.BAND_FIX:
        return None
    return "fix — the commit closes"


def next_row_value(run_dir, meta, verdicts, number):
    """Whether another round follows this one, which is the whole of what makes a chain finite: a
    round 2 says so itself, and every other answer is read off the decision on disk.
    """
    if number >= _round.ROUND_BUDGET:
        return "none — last round"
    band = _round.round_band(*_round.escalation_numbers(run_dir, meta, verdicts))
    decided = _round.read_fork(run_dir)
    if decided and decided["choice"] != _round.BAND_FIX and band == _round.BAND_HARD:
        return (
            f"round 2 required (P1 ≥ {_round.HANDOFF_P1_STOP}, "
            f"confirmed ≥ {_round.ROUND_HARD_MIN})"
        )
    if (decided and decided["choice"] != _round.BAND_FIX) or (
        not decided and band != _round.BAND_FIX
    ):
        return "round 2 by decision"
    return "none"


def report_lines(run_dir, meta, verdicts=None):
    """The block a review round is read in: what it cost, what it confirmed, and which cell every
    one of those answers came from.

    No panel cell is unaccounted for: every one of them stands in `found:`, `noise:`, `quiet:`,
    `echoed:`, `untriaged:` or `failed:` — a leg the panel never launched collapsed into one row
    of the last — because the cell that broke silently is the one nobody goes looking for, and a
    cell missing from all of them is invisible. Not a partition: a cell is listed per confirmed
    finding and per rejected one, so one holding both stands in `found:` and `noise:` alike.
    """
    summary = _panel.bench_summary(run_dir, meta, verdicts)
    scheme = _raters.report_name_scheme([
        *(row.get("rater") for row in summary["cells"]),
        *summary["verifier_by_model"],
        summary["verifier"],
    ])
    completed = [row for row in summary["cells"] if row["status"] == "completed"]
    confirmed_by = summary["confirmed_by"]
    false_by = summary["false_by"]
    total = summary["confirmed"]
    tier = summary["tier"] or "untiered"
    members = [entry for entry in meta.get("repos") or () if isinstance(entry, dict)]
    rows = [(
        f"{tier} · {len(members)} rep:" if members else f"{tier}:",
        report_header_value(summary, meta, scheme), True,
    )]
    if meta.get("lens"):
        dropped = meta.get("lens_panel_dropped") or []
        # Its own row, never beside the tier: the severities below were awarded by another
        # methodology, and a reader who priced them as the tool's own read a lens run as a review.
        rows.append((
            "lens:",
            str(meta["lens"]) + (f" · {len(dropped)} cells dropped" if dropped else ""),
            True,
        ))
    rows.append((
        "confirmed:",
        confirmed_tally(summary["severities"], total, summary["docs"]),
        True,
    ))
    verdict_rows = verdicts if verdicts is not None else (_round.recorded_verdict_rows(run_dir) or [])
    number = _round.review_round(run_dir, meta)
    parent = round_one_of(run_dir, meta) if number >= _round.ROUND_BUDGET else None
    if parent is not None:
        # What this round is read against, in the same columns as the row above it. A round 2 whose
        # predecessor's tally cannot be read prints no row rather than a zero, which would read as
        # a first round that found nothing.
        before = round_one_tally(*parent)
        if before:
            rows.append(("before:", before, True))
        decided = _round.read_fork(parent[0])
        if decided:
            rows.append(("decision:", f"{decided['choice']} (round 1)", True))
    fixes_state = _round.fix_status(run_dir, total, verdict_rows)[1]
    record = _round.read_fix_status(run_dir) or {}
    unanswered = fixes_state != "done" or (
        total and _store.counted_int(record.get("fixed"))
        + _store.counted_int(record.get("false_positives")) < total
    )
    if summary["tier"]:
        fixes = fixes_row_value(run_dir, meta, verdict_rows, number) if unanswered else None
        if fixes:
            rows.append(("fixes:", fixes, True))
        rows.append(("next:", next_row_value(run_dir, meta, verdict_rows, number), True))
    verifier_value = verifier_report_value(run_dir, summary, scheme)
    if verifier_value:
        rows.append(("verifier:", verifier_value, True))
    rejected = [
        (kind, count) for kind, count in
        (("duplicate", summary["duplicate"]), ("false", summary["false_positive"])) if count
    ]
    if rejected:
        tokens = [
            estimated_tokens_text(count * _catalog.ADJUDICATION_TOK_ESTIMATE[
                "false_positive" if kind == "false" else kind
            ])
            for kind, count in rejected
        ]
        count_width = max(len(str(count)) for _, count in rejected)
        kind_width = max(len(kind) for kind, _ in rejected)
        token_width = max(len(token) for token in tokens)
        for index, ((kind, count), token) in enumerate(zip(rejected, tokens)):
            rows.append((
                "rejected:" if index == 0 else "",
                f"{count:>{count_width}} {kind:<{kind_width}}  {token:>{token_width}}",
                False,
            ))
    # Priced on what survived triage rather than on what was claimed: the question this row is read
    # with is which cells earned their place in the next panel. A cell that found nothing is in
    # `quiet:` instead — listed here as 0/n it would read as a cell worth keeping.
    found = sorted(
        (cell for cell in completed if confirmed_by.get(cell["rater"])),
        key=lambda cell: (-confirmed_by[cell["rater"]], -_store.counted_int(cell.get("findings"))),
    )
    if found:
        name_width = max(len(report_cell_name(cell["rater"], scheme)) for cell in found)
        for index, cell in enumerate(found):
            rows.append((
                "found:" if index == 0 else "",
                f"{report_cell_name(cell['rater'], scheme):<{name_width}}  "
                f"{confirmed_by[cell['rater']]}/{_store.counted_int(cell.get('findings'))}",
                False,
            ))
    # Collapsed onto the family, because this row is read for which MODEL is expensive to believe
    # and two instances of one model are one answer to that. `found:` beside it stays per instance:
    # there the question is which cell to keep, and the instances answer it differently.
    noise_by_family = Counter()
    noisy_instances = Counter()
    for spec, count in false_by.items():
        noise_by_family[_raters.rater_family(spec) or spec] += count
        noisy_instances[_raters.rater_family(spec) or spec] += 1
    noise = sorted(noise_by_family.items(), key=lambda item: (-item[1], item[0]))
    if noise:
        rows.append((
            "noise:",
            " · ".join(
                report_cell_name(family, scheme)
                + (f" ×{noisy_instances[family]}" if noisy_instances[family] > 1 else "")
                + f" {count}"
                for family, count in noise
            ),
            True,
        ))
    # The INSTANCE's own verdicts, not its family's: a second instance that found nothing while the
    # first produced noise is a cell that said nothing, and folding it into its family's row would
    # leave it accounted for nowhere.
    judged_by = summary["judged_by"]
    uncredited = [
        cell for cell in completed
        if not confirmed_by.get(cell["rater"]) and not false_by.get(cell["rater"])
    ]
    # Three different cells, and one row read `quiet` over all of them: one that claimed nothing,
    # one whose every claim another cell had already made, and one nobody judged at all — which is
    # the whole panel of an untriaged `--raters` run, reported as having found nothing.
    quiet = [cell for cell in uncredited if not _store.counted_int(cell.get("findings"))]
    echoed = [
        cell for cell in uncredited
        if _store.counted_int(cell.get("findings")) and judged_by.get(cell["rater"])
    ]
    untriaged = [
        cell for cell in uncredited
        if _store.counted_int(cell.get("findings")) and not judged_by.get(cell["rater"])
    ]
    for label, group in (("quiet:", quiet), ("echoed:", echoed), ("untriaged:", untriaged)):
        if group:
            rows.append((label, f"{len(group)} cells", True))
    failed_rows = report_failed_rows(run_dir, summary, meta, scheme)
    if failed_rows:
        cell_rows = [row for row in failed_rows if row[1]]
        name_width = max((len(name) for name, _, _ in cell_rows), default=0)
        cause_width = max((len(cause) for _, cause, _ in cell_rows), default=0)
        for index, (name, cause, duration) in enumerate(failed_rows):
            rows.append((
                "failed:" if index == 0 else "",
                f"{name:<{name_width}}  {cause:<{cause_width}}  {duration:>8}".rstrip(),
                False,
            ))
    # Last, and the CHAIN's rather than this run's: the two rounds are one piece of work, and an id
    # is what a reader types back into a command — one of them, never two to pick between.
    rows.append(("id:", _round.chain_id(run_dir, meta), False))
    return report_block_lines(rows)


def emit_report(run_dir, meta, verdicts=None):
    # A record missing the launch's round stamp is asked the store once, here: every row that says
    # which round this is reads `meta`, and rendered off a bare record a second pass prints as a
    # first round with nothing before it.
    meta = dict(meta, **_round.recovered_round_stamp(run_dir, meta))
    # The markers are what the report hook keys on, so only a triaged run may carry them. Printed
    # either way, they made a list of cells look like a report, and that is what reached Egor.
    if verdicts is None and not (run_dir / "verdicts.jsonl").exists():
        # `record --no-corpus` stores no verdicts.jsonl; its receipt rows are then the only copy
        # of the triage, and without them every re-render of a real report — the report hook's
        # recovery of a capture whose tail the tool-output window cut — answered "pending".
        # An empty rows list is a CLEAN triage, not a missing one: `or None` here sent exactly
        # the clean review back to "pending".
        verdicts = _round.receipt_verdict_rows(run_dir)
    if verdicts is None and not (run_dir / "verdicts.jsonl").exists():
        for line in _round.pending_lines(run_dir, meta):
            print(line)
        return
    # One read of the triage for both: the frame word and the rows are the same run's answer, and
    # re-read for the rows they can disagree with the frame around them.
    resolved = verdicts if verdicts is not None else _store.read_jsonl(run_dir / "verdicts.jsonl")
    print(report_frame_header(
        report_frame_word(run_dir, meta, _round.round_state(run_dir, resolved))
    ))
    for line in report_lines(run_dir, meta, resolved):
        print(line)
    print(_round.REPORT_END)


def cmd_report(args):
    if bool(args.run_id) == bool(args.last):
        raise ValueError("give exactly one of run-id or --last")
    benches = _store.state_dir() / "benches"
    run_dir = _store.newest_run_dir(benches) if args.last else benches / args.run_id
    if run_dir is None or not (run_dir / "meta.json").exists():
        target = "last run" if args.last else f"run id {args.run_id}"
        raise ValueError(f"unknown {target}")
    meta = json.loads((run_dir / "meta.json").read_text())
    # The delivery hooks print this rendering to Egor unasked, so `--session` is what keeps a chat
    # from framing another chat's review as its own: a run reached by id says nothing about who
    # launched it, and the report he reads IS the indicator that HIS review finished (2026-08-22).
    refuse_foreign_chat(run_dir, meta, str(getattr(args, "session", "") or "").strip())
    line = getattr(args, "line", None)
    if line == "triaged":
        print(triaged_line(run_dir, meta))
    elif line == "fork":
        print(fork_line(run_dir))
    else:
        emit_report(run_dir, meta)
    return 0


def refuse_foreign_chat(run_dir, meta, asking):
    """A run is its launcher's: an empty `asking` (the harness named no chat) passes, any other
    chat is refused by name. A worker's launch answers to the chat that sent it, the fold
    `caller_chat` makes.
    """
    launcher = str(meta.get("session") or "")
    if (asking and launcher and launcher != asking
            and worker_session_launchers().get(launcher) != asking):
        raise ValueError(
            f"run {run_dir.name} belongs to chat {launcher}{_store.chat_suffix(launcher)}"
        )


def decision_refusal(run_dir, meta):
    """Why this run takes no decision, in whichever of `fork_owed`'s three answers is the true one.

    A refusal naming the band over a round 2 or an untriaged run sends its reader to re-count
    findings that were never the reason.
    """
    if _round.recorded_verdict_rows(run_dir) is None:
        return (
            f"run {run_dir.name} has no triage on record; there is nothing to decide over until "
            "the verdicts are"
        )
    if _round.review_round(run_dir, meta) >= _round.ROUND_BUDGET:
        return (
            f"run {run_dir.name} is round 2, the last round there is; it takes no decision — fix "
            "what it confirmed and commit, and that closes both rounds"
        )
    return f"run {run_dir.name} is in the fix band; it takes no decision"


def cmd_fork(args):
    """Print the fork a round's report deliberately does not carry, for the hook that hands the
    model its context. Silent where nothing is owed: the report says the round is closed, and a
    fork printed over it is work nobody asked for.
    """
    run_dir = _store.state_dir() / "benches" / args.run_id
    if not (run_dir / "meta.json").exists():
        raise ValueError(f"unknown run id: {args.run_id}")
    meta = json.loads((run_dir / "meta.json").read_text())
    if getattr(args, "check", False):
        if _round.fork_missing(run_dir, meta):
            print(_round.fork_refusal(run_dir.name), file=sys.stderr)
            return 3
        return 0
    choice = getattr(args, "choice", None)
    why = " ".join(str(getattr(args, "why", "") or "").split())
    if choice or why:
        if not (choice and why):
            raise ValueError("--choice and --why go together")
        if len(why) < _round.FORK_WHY_MIN_CHARS:
            raise ValueError(
                f"--why is the strategic reason for the choice and needs at least "
                f"{_round.FORK_WHY_MIN_CHARS} characters; got {len(why)}"
            )
        if not _round.fork_owed(run_dir, meta):
            raise ValueError(decision_refusal(run_dir, meta))
        # The record is the launching chat's alone: a co-tenant chat (a worker the gate refused
        # a fixing pass to included) must not write the fork that unblocks its own gate. The
        # asking chat is the environment's unless the caller names one, never argv alone.
        asking = str(getattr(args, "session", "") or "").strip() or _store.launching_session() or ""
        if meta.get("session") and not asking:
            raise ValueError(
                f"run {run_dir.name} belongs to chat {meta['session']}"
                f"{_store.chat_suffix(meta['session'])}; name yours with --session"
            )
        refuse_foreign_chat(run_dir, meta, asking)
        record = {"choice": choice, "why": why, "session": asking, "at": _store.iso_now()}
        (run_dir / _round.FORK_RECORD).write_text(json.dumps(record) + "\n")
        print(fork_line(run_dir))
        return 0
    text = round_fork_text(run_dir, meta)
    if text:
        print(text)
    return 0


HEALTH_DEFAULT_RUNS = 20
HEALTH_WORST_CELLS = 12


def run_health(run_dir, meta):
    """One run reduced to why its cells failed, counted the way the report counts them."""
    by_side = defaultdict(Counter)
    by_cell = defaultdict(Counter)
    accounts = defaultdict(Counter)
    summary = _panel.bench_summary(run_dir, meta)
    # Every ATTEMPT, not every cell: this view is read to see whether the pool is still rotating,
    # and an attempt that walled one account before the retry cleared on another is precisely the
    # rotation it is read for. The report answers for the final attempt; this does not.
    for cell in [entry for row in summary["cells"] for entry in (*row["attempts"], row)]:
        side = cell.get("side") or "?"
        reason = "ok" if cell["status"] == "completed" else _panel.cell_failure_reason(cell)
        by_side[side][reason] += 1
        by_cell[_raters.rater_family(cell.get("rater")) or "?"][reason] += 1
        if cell.get("account"):
            accounts[(side, cell["account"])]["ok" if reason == "ok" else "failed"] += 1
    return {"by_side": by_side, "by_cell": by_cell, "accounts": accounts}


def health_runs(benches, limit=0):
    """Recorded runs, oldest last, as (name, health) pairs.

    Run directories are named by start time, so sorting them by name is already chronological
    and the window can be cut before any metadata is read.
    """
    directories = sorted(
        path for path in (benches.iterdir() if benches.exists() else ())
        if (path / "meta.json").exists()
    )
    if limit > 0:
        directories = directories[-limit:]
    runs = []
    for directory in directories:
        try:
            meta = json.loads((directory / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not meta.get("rater_runs") and not meta.get("raters"):
            continue
        runs.append((directory.name, run_health(directory, meta)))
    return runs


def health_tally(counts):
    total = sum(counts.values())
    failed = total - counts["ok"]
    share = f"{100 * failed / total:3.0f}%" if total else "   -"
    # Never ' · ': the vocabulary itself carries that separator (`killed · cap`, `killed · stalled`)
    # and joined with it one cause reads as two — `killed · cap 2 · walled 1 · killed · stalled 1`.
    detail = ", ".join(
        f"{reason} {count}" for reason, count in counts.most_common() if reason != "ok"
    )
    return f"{failed:>3}/{total:<3} {share}  {detail}".rstrip()


def health_lines(runs):
    if not runs:
        return ["no recorded runs"]
    by_side = defaultdict(Counter)
    by_cell = defaultdict(Counter)
    accounts = defaultdict(Counter)
    per_run = []
    everything = Counter()
    for name, health in runs:
        counts = Counter()
        for side, side_counts in health["by_side"].items():
            by_side[side] += side_counts
            counts += side_counts
        for cell, cell_counts in health["by_cell"].items():
            by_cell[cell] += cell_counts
        for key, key_counts in health["accounts"].items():
            accounts[key] += key_counts
        everything += counts
        per_run.append((name, health_tally(counts)))
    per_run.append(("all runs", health_tally(everything)))
    lines = [f"per run (newest last, {len(runs)} runs)"]
    lines += aligned_report_lines(per_run)

    ranked_sides = sorted(
        by_side.items(), key=lambda item: -(sum(item[1].values()) - item[1]["ok"])
    )
    lines += ["", "by side"]
    lines += aligned_report_lines([(side, health_tally(counts)) for side, counts in ranked_sides])

    account_rows = []
    for side, _ in ranked_sides:
        entries = sorted(
            ((account, counts) for (row_side, account), counts in accounts.items()
             if row_side == side),
            key=lambda item: (-sum(item[1].values()), item[0]),
        )
        if entries:
            account_rows.append((side, " · ".join(
                f"{account} {counts['failed']}/{sum(counts.values())}"
                for account, counts in entries
            )))
    if account_rows:
        # Every account that was tried, the ones that never failed included: a pool that handed
        # all its cells to a single account reads as a single row, and that is the thing to see.
        lines += ["", "by account (failed/attempts)"]
        lines += aligned_report_lines(account_rows)

    health_scheme = _raters.report_name_scheme(by_cell)
    worst = [
        (_raters.human_cell_name(cell, health_scheme), health_tally(counts))
        for cell, counts in sorted(
            by_cell.items(), key=lambda item: -(sum(item[1].values()) - item[1]["ok"])
        )
        if sum(counts.values()) > counts["ok"]
    ][:HEALTH_WORST_CELLS]
    if worst:
        lines += ["", "worst cells"]
        lines += aligned_report_lines(worst)
    return lines


FINDINGS_SUMMARY_CHARS = 300
SEVERITY_ORDER = {"P1": 0, "P2": 1, "P3": 2}


def line_sort_key(text):
    """One panel writes a line number as a number and as a string, so the group key holds it as
    text — which orders line 10 ahead of line 2 unless the digits are read back out.
    """
    return (0, int(text), "") if text.isdigit() else (1, 0, text)


def findings_lines(run_dir):
    """One entry per place the panel pointed at, the cells that pointed there named.

    Grouped because a reader who takes the per-cell files as they are reads the same claim once
    per cell that made it — a third of them on the runs recorded so far — and pays for every
    repeat. Agreement first, since a place several cells reached independently is where a real
    defect usually is; strictly by file and line, because merging neighbours on a similarity
    score is how two distinct defects become one entry nobody looks at twice.
    """
    rows = []
    for path in sorted(run_dir.glob("findings-*.jsonl")):
        cell = _raters.rater_family(path.name[len("findings-"):-len(".jsonl")])
        for row in _store.read_jsonl(path):
            rows.append((cell, row))
    if not rows:
        return ["no findings recorded"]
    places = defaultdict(list)
    for cell, row in rows:
        places[(str(row.get("file") or "?"), str(row.get("line")))].append((cell, row))
    ordered = sorted(
        places.items(),
        # By how many distinct cells reached the place, not how many rows landed on it: one cell
        # repeated, or one that made two claims about the same line, is not corroboration.
        key=lambda item: (-len({cell for cell, _ in item[1]}), item[0][0],
                          line_sort_key(item[0][1])),
    )
    cells = {cell for cell, _ in rows}
    lines = [
        f"{len(rows)} findings from {len(cells)} cells at {len(places)} places"
    ]
    for (path, line), entries in ordered:
        # The worst severity claimed here, and the summary of whoever claimed it. Taking the
        # first entry hands both to whichever cell's filename sorted first, so a P1 shows as a
        # P3 because of a name.
        cell_names = sorted({cell for cell, _ in entries})
        row = min(
            (row for _, row in entries),
            key=lambda row: SEVERITY_ORDER.get(row.get("severity"), len(SEVERITY_ORDER)),
        )
        lines.append("")
        # ×N is the agreement, so the claim count comes back whenever a cell said more than one
        # thing here: only one summary is printed, and without it the rest are invisible.
        agreement = f"×{len(cell_names)}"
        if len(entries) > len(cell_names):
            agreement += f" ({len(entries)} claims)"
        lines.append(
            f"{row.get('severity') or '??'} {agreement}  {path}:{line}  "
            f"{', '.join(cell_names)}"
        )
        summary = " ".join(str(row.get("summary") or "").split())
        lines.append(f"    {summary[:FINDINGS_SUMMARY_CHARS]}")
    return lines


def cmd_findings(args):
    if bool(args.run_id) == bool(args.last):
        raise ValueError("give exactly one of run-id or --last")
    benches = _store.state_dir() / "benches"
    run_dir = _store.newest_run_dir(benches) if args.last else benches / args.run_id
    if run_dir is None or not (run_dir / "meta.json").exists():
        raise ValueError(f"unknown {'last run' if args.last else f'run id {args.run_id}'}")
    for line in findings_lines(run_dir):
        print(line)
    return 0


def cmd_health(args):
    if args.limit < 0:
        raise ValueError("--limit cannot be negative")
    for line in health_lines(health_runs(_store.state_dir() / "benches", args.limit)):
        print(line)
    return 0


def late_review_line(spec, duration_ms, median_ms):
    values = (duration_ms, median_ms)
    if any(
        not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0
        for value in values
    ):
        return None
    threshold_ms = max(
        REVIEW_LATE_MULTIPLIER * median_ms,
        REVIEW_LATE_FLOOR_S * 1000,
    )
    if duration_ms <= threshold_ms:
        return None
    return (
        f"LATE: {spec} took {duration_ms / 1000:g}s "
        f"against a {median_ms / 1000:g}s median"
    )


def report_late_review(spec, duration_ms, median_ms):
    line = late_review_line(spec, duration_ms, median_ms)
    if line:
        print(line)
    return line
