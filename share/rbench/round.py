import hashlib
import json
import shlex
import subprocess
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from chat_names import transcript_path, worker_session_launchers

from . import store as _store
from . import catalog as _catalog
from . import scope as _scope
from . import panel as _panel
from . import prompts as _prompts

# The sides whose findings the verifier is measured on, and the only ones it is allowed to
# filter. agy joined on 2026-08-05: on the agy leg's own adjudicated claims deepseek-v4-flash
# kept 6 of 6 real defects and dropped 11 of 24 false ones with nothing left unverified.
VERIFIED_SIDES = ("opencode", "agy")
REPORT_FRAME_WIDTH = 50
REPORT_FRAME_WORD = "review"


# The frame word carries the run's STATE and no row below it does, so a reader who sees only the
# header knows whether the block in front of them is finished, hung, empty or old. Every one of
# them rides the same frame rather than a marker of its own, because the review consumers narrow
# the header to this word: a spelling only one side knows is a report Egor never sees
# (docs/shared-invariants.md as).
# A round whose fixing pass STOPPED at the P1 threshold. A pass that has not answered YET keeps
# the plain word — reading the loud one off "no fixes recorded" is what put NOT FINISHED in front
# of Egor over a round whose fixes were landing at that moment (2026-08-20).
REPORT_BLOCKED_WORD = f"{REPORT_FRAME_WORD} · NOT FINISHED"
# No cell completed: there is no panel behind the rows, whatever they say. A run the watchdog
# killed states that on the `failed:` rows of the cells it killed and nowhere else — coverage is
# the triage receipt's to answer for, and a whole panel that came back with a kill in it is
# already NO PANEL.
REPORT_NO_PANEL_WORD = f"{REPORT_FRAME_WORD} · NO PANEL"
# Not about the tree in front of the reader: the block was never handed over at the moment it was
# recorded, or the content it priced has moved since. Neither of those is a clock, and a clock was
# the wrong question — a report read five minutes after a rewrite of the files it read is already
# about something else, and one delivered the instant it was recorded stays current at any age. It
# carries the run's own date, which is the only thing that says how far off it is.
REPORT_STALE_WORD = f"{REPORT_FRAME_WORD} · STALE"
# A worker may run an hour and the fixing pass another: a report older than this is not about the
# tree in front of the reader, whatever else is true of it. Deliberately a clock and nothing else.
REPORT_STALE_HOURS = 3
# A panel nobody asked for by tier — an explicit `--raters` bench. It is not a review round: it
# settles no debt and owes no fixes, so it wears a word of its own instead of the review one.
REPORT_BENCH_WORD = "bench"
REPORT_FRAME_WORDS = (
    REPORT_FRAME_WORD, REPORT_BLOCKED_WORD, REPORT_NO_PANEL_WORD,
    REPORT_STALE_WORD, REPORT_BENCH_WORD,
)
REPORT_END = "=" * REPORT_FRAME_WIDTH
# What the NOT FINISHED frame owes beyond the reason on the receipt: the pass stopped, and which
# way the round goes from there is not the fixer's to decide. `fork` hands it to the model that
# has to act on it rather than the block spending six lines on it at Egor, who does not read it.
# It asserts no reason of its own —
# `--blocked` takes whichever one the pass actually had, and a fork naming the P1 threshold over
# a round that stopped for something else tells Egor a thing nobody recorded.
REPORT_BLOCKED_FORK = (
    "the fixing pass stopped over this round's findings, for the reason\n"
    "on its `fixes:` row. Which way the round goes from here —\n"
    "fixing them as they stand, reworking the code they cluster in,\n"
    "or cutting the scope — is Egor's decision and not the fixer's,\n"
    "and it reaches him with the P1 list and the reasoning before\n"
    "anybody acts on it."
)

# A run without verdicts has no report to print: the triage that decides what to fix is what
# makes one. It gets this line instead, and the hooks key on it to demand the missing pass —
# the marked block used to be printed either way, and a list of cells was what reached Egor.
TRIAGE_PENDING = "REVIEW-TRIAGE-PENDING"
# The two FINAL states a round settles in — the only ones `settle-delivery` may queue. The Stop
# net's line vocabulary adds `triaged` and `fork` (docs/shared-invariants.md as): one line each,
# never queued.
DELIVERY_STATES = ("done", "blocked")
# Confirmed P1s at which the fixing pass stops instead of starting: past it the round is not a
# list of defects to patch but a fork Egor decides, and a worker that patched its way through one
# spent that decision for him.
HANDOFF_P1_STOP = 3
# Rounds one scope may be reviewed in. The second one's report offers no third: a scope that came
# back twice is answered by fixing what is confirmed and writing the rest into the false-positive
# doctrine, not by a panel pricing the same code again.
ROUND_BUDGET = 2
# How long an earlier fixed round keeps answering for its scope. A round and the round that reads
# its fixes are one piece of work, and that pass runs over an uncommitted tree — days at the
# outside. Without the bound the path test below is not enough on its own: a full-repository scope
# reads a superset of every earlier one, so a single fixed round would price every later review of
# that checkout as its second forever, taking the escalation fork and the waiver lock with it.
ROUND_LINEAGE_MAX_HOURS = 72
ROUND_BUDGET_SPENT = (
    "second round over this scope — the budget of two is spent, and there is no third:\n"
    "- fix what is confirmed and leave it uncommitted;\n"
    "- fold what is left into the false-positive doctrine rather than reviewing this scope again."
)
TRIAGE_NUDGED = "report-nudged"
# The same counter over the other thing a run can owe at a stop: the debt its own scope still
# carries once its round budget is spent. Its own file, because a round asked three times for its
# triage has spent nothing of what it owes after the fixes land.
SETTLE_NUDGED = "settle-nudged"
# Stamped by `worker-run` when the brief it launches carries this run's `record` command: the
# triage is that worker's, and a Stop gate nagging the chat meanwhile asks for the same work twice.
DELEGATED_STAMP = "delegated"
# How far the stamped supervisor's own start may sit from the launch instant recorded beside its
# pid before the number belongs to a different process. Held equal to the slack the review hooks
# judge the same supervisors by (shared-invariants row `ar`, `RJ_PID_SLACK`).
DELEGATED_PID_SLACK = 30
# How long the Agent-spawn hook's `claimed <session> <epoch>` stamp stands in for the pid
# `worker-run` writes about a minute later; past it the stamp reads dead exactly as a gone pid.
DELEGATED_CLAIM_SECONDS = 600
FORK_RECORD = "fork.json"
FORK_CHOICES = ("fix", "simplify", "re-review")
FORK_WHY_MIN_CHARS = 80
# How many times a run may be asked for its report before the gate gives up. Not once: a stop
# hook also fires when the turn is interrupted, and a single ask was spent there instead of at the
# end of the turn it was meant to gate (seen live 2026-07-31). Still bounded, because a triage
# that genuinely cannot be done must not block every stop that follows.
TRIAGE_GATE_ASKS = 3
ROUND_BUDGET_SPENT_CACHE = {}
ESCALATION_GATE = Path.home() / ".claude/hooks/review-flow-gate.sh"
ESCALATION_UNKNOWN = (
    "unknown — the commit gate could not be asked; attempt the commit for the verdict"
)
# The gate's fork opens on this line; everything above it is the verdict itself.
ESCALATION_FORK_LEAD = "Pick one and carry it out"


def escalation_headline(earned):
    """A verdict of the gate's as ONE report row: its opening sentence, without the fork it hands
    the model. Never a sentence of this file's own — the P1 verdict withholds the waiver over this
    work and the tally verdict leaves `waive` open, and one hardcoded row said the same thing for
    both.
    """
    head = (earned or "").strip().splitlines()[0].strip()
    lead = head.find(ESCALATION_FORK_LEAD)
    if lead > 0:
        head = head[:lead]
    return head.strip().rstrip(".;:— -")


def escalation_verdict(p1, total):
    """What this round earned, in the commit gate's own words, or None when it is closed.

    Asked of the gate rather than answered here: the thresholds and the three-way wording — the
    weak-component verdict included, which sends the fixer to redesign the piece instead of
    reviewing it a second time — are one rule, and a copy of it in this file is a copy that drifts.
    The gate speaks only at a commit attempt, which needs Egor's permission to reach, so a round
    that earned another one was settled in silence while the report said nothing (2026-08-08).

    A gate that cannot be reached says so out loud: silence here is the very failure this exists to
    end, so the caller prints the unknown rather than a clean bill.
    """
    try:
        done = subprocess.run(
            [str(ESCALATION_GATE), "escalation-verdict", str(p1), str(total)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ESCALATION_UNKNOWN
    if done.returncode == 0:
        return done.stdout.strip() or None
    if done.returncode == 1:
        return None
    return ESCALATION_UNKNOWN


def verdict_scratch_path(run_id):
    return f"/tmp/review-bench-{run_id}-verdicts.jsonl"


def triage_command(run_id, findings):
    command = f"review-bench record {shlex.quote(run_id)} --no-corpus"
    if findings:
        command += f" --verdicts {shlex.quote(verdict_scratch_path(run_id))}"
    return command


def pending_lines(run_dir, meta):
    """Two lines an un-triaged run gets in place of a report: how much there is to judge, and the
    command that prints the real block once it is judged."""
    summary = _panel.bench_summary(run_dir, meta)
    run_id = run_dir.name
    findings = summary["findings"]
    incomplete = sum(1 for row in summary["cells"] if row["status"] != "completed")
    head = f"{TRIAGE_PENDING} {run_id} · {findings} finding(s) to triage"
    if incomplete:
        head += f" · {incomplete} cell(s) did not complete"
    return [head, f"report with: {triage_command(run_id, findings)}"]


def write_report_receipt(run_dir, verdicts, severities=None, docs=0):
    # The severity tally is the one number the commit gate prices its next round on, and it is
    # written here rather than derived there because `--no-corpus` leaves no verdicts.jsonl to
    # derive it from: this receipt is the only record that triage ever happened. The rows go with
    # it for the same reason — the tally beside them is the whole run's, the way the report block
    # printed it, and a merged run's members each need their own share of it.
    (run_dir / _store.REPORT_RECEIPT).write_text(json.dumps({
        "reported_at": _store.iso_now(),
        "verdicts": len(verdicts),
        "confirmed": sum(
            1 for row in verdicts if row.get("verdict") == "confirmed"
        ) - _store.counted_int(docs),
        "confirmed_by_severity": {
            level: _store.counted_int((severities or {}).get(level)) for level in _prompts.LENS_SEVERITIES
        },
        "docs": _store.counted_int(docs),
        "rows": [
            {"rater": row.get("rater"), "idx": row.get("idx"), "verdict": row.get("verdict")}
            for row in verdicts
        ],
    }) + "\n")


def read_decree(run_dir):
    """Egor's recorded unlock of this round, or None.

    The only thing that discharges a P1 lock without the second review it demands, and it exists
    because the lock has no other door: the round is locked until a full second panel runs, and
    when Egor decides that panel is not worth its tokens nothing on disk could say so. A model
    never writes one on its own judgment — that would be the round forgiving itself — so every
    surface that would have named the lock names the decree instead: the reason itself wherever
    there is room for a sentence, and the bare `decreed` word where the answer is one machine-read
    line, loudly enough that a decree nobody authorised is visible in the same block Egor reads the
    findings in and never as a round nothing ever withheld.
    """
    try:
        stored = json.loads((run_dir / _store.DECREE_RECEIPT).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(stored, dict) or not str(stored.get("reason") or "").strip():
        return None
    return stored


def read_fix_status(run_dir):
    try:
        stored = json.loads((run_dir / _store.FIX_RECEIPT).read_text())
    except (OSError, ValueError):
        return None
    return stored if isinstance(stored, dict) else None


def receipt_verdict_rows(run_dir):
    """The verdict rows a run's report receipt kept, or None where it holds none. An empty list is
    a CLEAN triage, not a missing one.
    """
    try:
        rows = json.loads((run_dir / _store.REPORT_RECEIPT).read_text()).get("rows")
    except (OSError, ValueError):
        return None
    return rows if isinstance(rows, list) else None


def recorded_verdict_rows(run_dir):
    """The triage on record for a run, from whichever copy of it survives: `record --no-corpus`
    stores no verdicts.jsonl, and its receipt rows are then the only one.
    """
    if (run_dir / "verdicts.jsonl").exists():
        return _store.read_jsonl(run_dir / "verdicts.jsonl")
    return receipt_verdict_rows(run_dir)


def confirmed_count(verdicts):
    """The confirmed verdicts of a row list, counted the way `bench_summary` counts them, so the
    frame's header and the `fixes:` row underneath it can never disagree about the same run."""
    return sum(
        1 for row in verdicts or ()
        if isinstance(row, dict) and row.get("rater") and row.get("verdict") == "confirmed"
    )


def triage_digest(verdicts):
    """A fingerprint of the confirmed rows a receipt answers for.

    The count alone cannot tell a re-adjudication that swapped one confirmed finding for another
    from the triage the receipt was written against, and the finding nobody fixed then reads as
    done on the strength of a pass that never saw it.
    """
    rows = sorted(
        f"{row.get('rater')}\x00{row.get('idx')}"
        for row in verdicts or ()
        if isinstance(row, dict) and row.get("rater") and row.get("verdict") == "confirmed"
    )
    return hashlib.sha256("\n".join(rows).encode()).hexdigest()[:16]


def fix_status(run_dir, confirmed, verdicts=None):
    """The report's `fixes:` value and what the round's fixing pass answered: `done`, `blocked`
    (a receipt naming why the pass stopped) or `pending` — no receipt at all, or one that answers
    a triage this run no longer carries.

    Carried in every state, because a line printed only sometimes is one whose absence reads as
    "applied": a round is finished when somebody recorded that it is, never by default. The three
    are kept apart here rather than collapsed into "not done", because the frame word is picked
    off this answer and a stopped round and a running one are not the same news.
    """
    record = read_fix_status(run_dir)
    if not confirmed:
        return "nothing to fix", "done"
    state = str((record or {}).get("state") or "")
    if state in ("done", "blocked"):
        # A receipt answers for the triage it was written against, whichever way it answered. A
        # re-adjudication replaces a run's verdicts and leaves the receipt where it is, so a round
        # that came back with more confirmed findings than anybody fixed would read as finished on
        # the strength of the older pass — and a stopped one would go on offering Egor the fork
        # over a P1 list that is no longer the one it stopped over.
        stale = stale_fix_receipt(record, confirmed, verdicts)
        if stale:
            return stale, "pending"
    if state == "done":
        return (
            f"done — {_store.counted_int(record.get('fixed'))} fixed, "
            f"{_store.counted_int(record.get('false_positives'))} false positives"
        ), "done"
    reason = " ".join(str((record or {}).get("reason") or "").split())
    if state == "blocked":
        return f"NOT APPLIED — {reason or 'blocked'}", "blocked"
    return f"NOT APPLIED — {reason or 'pending'}", "pending"


def stale_fix_receipt(record, confirmed, verdicts):
    """The `fixes:` line for a receipt written against a triage the run no longer carries, or None
    where it still answers for the one in front of it.

    Only a receipt carrying the field can be asked — the ones written before either of them went
    in keep their own answer rather than reading unfinished for want of a field.
    """
    against = record.get("confirmed")
    if isinstance(against, int) and not isinstance(against, bool) and against != confirmed:
        return (
            f"NOT APPLIED — recorded against a triage of {against} confirmed, "
            f"and this one has {confirmed}"
        )
    # And answers for those findings, not merely for how many there were: a re-adjudication that
    # confirms a different finding in place of the old one leaves the count where it was.
    stamped = record.get("triage")
    if (isinstance(stamped, str) and stamped and verdicts is not None
            and stamped != triage_digest(verdicts)):
        return (
            f"NOT APPLIED — recorded against a different triage of the same {confirmed} confirmed"
        )
    return None


def round_state(run_dir, verdicts=None):
    """Which state a round is in: `done` once its fixing pass answered, `blocked` where a receipt
    says that pass stopped, `pending` while it still owes an answer.

    The frame word and the delivery key are read from this one answer, so a report delivered
    under one state and framed in another cannot happen. Age is deliberately not an input: a
    round nobody ever answered for is `pending` at any age, not a state of its own.
    """
    rows = verdicts if verdicts is not None else recorded_verdict_rows(run_dir)
    return fix_status(run_dir, confirmed_count(rows), rows)[1]


def run_scope_key(meta):
    """What two runs must share to be rounds over one scope: the tree each read and the paths it
    was narrowed to, every member of a merged panel included. Resolved, because the same checkout
    reaches a run under more than one spelling and two spellings are not two scopes.
    """
    def entry(record):
        recorded = str(record.get("repo") or "")
        # A debt review's scope is the repository's whole open question at the moment it ran, not a
        # narrowing anybody chose — and the second round of one piece of work computes a different
        # path set from the first, since the fixes moved what is owed. Keyed on those paths the two
        # rounds would be two scopes, the budget would never bind, and the fork would go on
        # demanding a third pass for ever.
        scope = () if record.get("debt") else tuple(
            sorted(str(item) for item in record.get("scope") or ())
        )
        return (str(_store.resolved_repo_path(recorded) or recorded) if recorded else "", scope)

    members = tuple(sorted(
        entry(record) for record in meta.get("repos") or () if isinstance(record, dict)
    ))
    # A merged panel's own `repo` is the workspace built for that one run — a path derived from the
    # snapshot it read, so two rounds over the very same repositories never share it and the budget
    # would never bind for a merged review at all. Its members ARE the scope.
    return members or (entry(meta),)


def run_reviewed_paths(meta):
    """Every path a run recorded reading, in one namespace.

    A merged panel records a map per member as well as its own, and only the members' hold a debt
    review's zero-diff survivors: the workspace map is that snapshot's diff, which by definition
    shows nothing for a path standing exactly where the locked round recorded it. Read off the
    workspace alone, the run that discharges a lock reads as one that never held those paths.
    """
    held = set()
    reviewed = meta.get("reviewed")
    if isinstance(reviewed, dict):
        held |= set(reviewed)
    for record in meta.get("repos") or ():
        if not isinstance(record, dict):
            continue
        member = record.get("reviewed")
        if isinstance(member, dict):
            label = str(record.get("label") or "")
            held |= {f"{label}/{path}" if label else str(path) for path in member}
    return held


def recorded_seal_instant(sha):
    """When a run already on record sealed `sha`, or None where none did.

    A rerun is pinned to a snapshot an earlier run sealed and reads exactly the tree that seal
    froze, so a seal stamped from its own clock dates that content to now: every fixes receipt
    written since would read as lineage the panel could have seen, and a rerun of the PRE-FIX
    snapshot would spend the scope's round budget and open its lock over a pass that saw none of
    them. The snapshot commit cannot answer this itself — every commit object review-bench writes
    carries one fixed clock, so the same input always answers with the same sha.
    """
    benches = _store.state_dir() / "benches"
    for run_dir in sorted(benches.iterdir()) if benches.exists() else ():
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict) or str(meta.get("commit") or "") != str(sha):
            continue
        recorded = _store.parse_iso_timestamp(meta.get("sealed_at"))
        if recorded is not None:
            return recorded
    return None


def review_round(run_dir, meta):
    """Which round of its scope this run is: the second once an earlier run of the same scope has
    its fixes done on record and this run reads everything that one read, the first otherwise.

    Read off the runs on disk rather than off a flag, because the caller that would have to pass
    the flag is exactly the one a spent round budget exists to argue with — and a round nobody
    ever fixed is not a round the scope has spent, which is why a `blocked` receipt is not one
    either: the fork it stopped for is what the next round is.

    Held to the paths as well as to the scope key, because that key alone is a repository: every
    later review of the same checkout — a different commit, months on — would read as the round
    answering for this one and lose the escalation fork for good. The second round is the run a
    lock demands, so it is recognised by what discharges a lock: reading the whole of what the
    round before it read.

    And held to `ROUND_LINEAGE_MAX_HOURS` as well as to the paths, because the path test does not
    settle that on its own: a full-repository scope reads a SUPERSET of every earlier round of the
    same checkout, and a run whose meta carries no `reviewed` map at all — every commit-point and
    ranged run — offers the empty set, which is a subset of anything. Either way one fixed round
    would answer for every later review of that repository, forever. Two rounds of one piece of
    work sit days apart at the outside; a round nothing has answered in longer is history.
    """
    key = run_scope_key(meta)
    held = run_reviewed_paths(meta)
    # Measured against this run's own finish and never against the clock: a round's number is
    # printed into its report and read back by every later `debt`, and one computed from `now`
    # would answer differently every time the same block was re-rendered.
    since = _store.parse_iso_timestamp(meta.get("finished") or meta.get("finished_at")) or _store.utc_now()
    floor = since - timedelta(hours=ROUND_LINEAGE_MAX_HOURS)
    # When this run SEALED its tree, which is the instant it stopped being able to read a fix — and
    # never its finish, hours later for a T2 panel. Only the receipts before it are lineage. The
    # launch stamp is the fallback for runs written before the seal instant was recorded; it is
    # minutes late, and late here spends the scope's budget over fixes the panel never read.
    sealed = _store.parse_iso_timestamp(
        meta.get("sealed_at") or meta.get("started") or meta.get("started_at")
    ) or since
    benches = run_dir.parent
    for other in sorted(benches.iterdir()) if benches.exists() else ():
        if other.name >= run_dir.name:
            break
        record = read_fix_status(other)
        if not record or record.get("state") != "done":
            continue
        # The receipt as the REPORT reads it and never its raw field: a re-adjudication replaces a
        # run's verdicts and leaves the receipt standing, and a round the report itself calls
        # pending must not spend the scope's budget of two.
        if round_state(other) != "done":
            continue
        try:
            earlier = json.loads((other / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(earlier, dict) or run_scope_key(earlier) != key:
            continue
        finished = _store.parse_iso_timestamp(earlier.get("finished") or earlier.get("finished_at"))
        if finished is None or finished < floor:
            continue
        # A round is the second one over fixes it could actually read: a receipt recorded after
        # this run sealed its tree answers for work that landed later, and taken as lineage it
        # spends the budget and releases the lock over a pass that saw none of it. Receipts from
        # before the field went in carry no instant and keep their own answer.
        recorded = _store.parse_iso_timestamp(record.get("recorded_at"))
        if recorded is not None and recorded > sealed:
            continue
        if run_reviewed_paths(earlier) <= held:
            return ROUND_BUDGET
    return 1


def round_budget_spent(run_dir):
    """Whether the run in `run_dir` is the second round over its scope, so the contract owes no
    third pass over it. Memoized like every other per-run tally the covering reader asks for once
    per path a run holds; a round's own number never changes while a process runs.
    """
    key = str(run_dir)
    if key not in ROUND_BUDGET_SPENT_CACHE:
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            return False
        ROUND_BUDGET_SPENT_CACHE[key] = (
            isinstance(meta, dict) and review_round(run_dir, meta) >= ROUND_BUDGET
        )
    return ROUND_BUDGET_SPENT_CACHE[key]


def member_finding_prefix(meta, commit):
    """The prefix a merged run's findings carry for the repository whose snapshot is `commit`, or
    "" when the run read one repository. A merged review names the merged workspace's commit and
    holds every repository under its own label, so this is the only thing that says which of its
    findings are about the repository asking.
    """
    member = next(
        (entry for entry in meta.get("repos") or ()
         if isinstance(entry, dict) and str(entry.get("commit") or "") == commit
         and isinstance(entry.get("label"), str) and entry["label"]),
        None,
    )
    return f"{member['label']}/" if member else ""


def severity_tallies(run_dir, verdicts, prefixes=("",)):
    """The confirmed findings of `verdicts` counted by severity, once per prefix asked for — the
    empty one being the whole panel and a merged member's being its own share. The same join
    `bench_summary` makes, and made once: every prefix is counted out of one read of the findings,
    because the reader on the commit gate's path asks for two of them.
    """
    findings_by_rater = {}
    counted = {prefix: Counter() for prefix in prefixes}
    for row in verdicts:
        if not isinstance(row, dict) or row.get("verdict") != "confirmed":
            continue
        rater = row.get("rater")
        idx = row.get("idx")
        if not rater or not isinstance(idx, int) or isinstance(idx, bool):
            continue
        if rater not in findings_by_rater:
            findings_by_rater[rater] = _store.finding_rows(run_dir, rater)
        rows = findings_by_rater[rater]
        if not 0 <= idx < len(rows):
            continue
        finding = rows[idx]
        if _panel.docs_finding(finding) or finding.get("severity") not in _catalog.WEIGHTS:
            continue
        path = str(finding.get("file") or "")
        for prefix in prefixes:
            if not prefix or path.startswith(prefix):
                counted[prefix][finding["severity"]] += 1
    return {
        prefix: {level: counted[prefix][level] for level in _prompts.LENS_SEVERITIES}
        for prefix in prefixes
    }


def escalation_numbers(run_dir, meta, verdicts, repo=None):
    """The two numbers the commit gate prices a round on, counted the way IT counts them: the P1s of
    one repository and the whole round's confirmed total.

    Both halves matter separately because the gate's two thresholds are either-or: a round earns a
    second pass on its P1s alone or on its whole tally alone. Handed the whole panel's
    P1s instead, a merged review claims a round no member's gate would ask for; handed a raw count
    of confirmed verdict rows instead of the severity sum, a row whose finding cannot be joined
    counts towards a threshold the gate never sees it in.

    `repo` names the member to answer for. Without one — the report block, which is written once
    for the whole round — the strictest member answers, because that is the commit that will be
    blocked.
    """
    labels = {}
    for entry in meta.get("repos") or ():
        if isinstance(entry, dict) and isinstance(entry.get("label"), str) and entry["label"]:
            labels[f"{entry['label']}/"] = entry.get("repo")
    tallies = severity_tallies(run_dir, verdicts, ("", *labels))
    whole = tallies[""]
    own = whole["P1"]
    if labels and repo is None:
        own = max(tallies[prefix]["P1"] for prefix in labels)
    elif labels:
        common = _store.git_common_dir(repo)
        own = next(
            (tallies[prefix]["P1"] for prefix, path in labels.items()
             if path and common and _store.git_common_dir(path) == common),
            whole["P1"],
        )
    return own, sum(whole.values())


def pid_elapsed_seconds(pid):
    """How long the process wearing `pid` has been running, or None where `ps` lists nothing.

    `ps` and never `kill -0` (shared-invariants row `ar`): a live process owned by another user
    answers EPERM to the signal probe and reads as dead, while `ps` lists it.
    """
    try:
        proc = subprocess.run(["ps", "-p", str(pid), "-o", "etime="],
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    raw = proc.stdout.strip()
    if not raw:
        return None
    fields = raw.replace("-", ":").split(":")
    multipliers = (1, 60, 3600, 86400)
    if len(fields) > len(multipliers):
        return None
    try:
        numbers = [int(field) for field in fields]
    except ValueError:
        return None
    return sum(value * scale for value, scale in zip(reversed(numbers), multipliers))


def triage_delegated(run_dir):
    """Whether a live worker holds this run's triage.

    The stamp's first line is the pid `worker-run` supervises and the instant that pid began,
    judged by `pid_still_running`: a pid that is gone hands the run straight back to the gate, a
    worker that died mid-triage being exactly what the nag is for.
    """
    try:
        stamped = (run_dir / DELEGATED_STAMP).read_text().split("\n", 1)[0].split()
    except (OSError, UnicodeDecodeError):
        return False
    if not stamped:
        return False
    if stamped[0] == "claimed":
        try:
            claimed = int(stamped[2])
        except (IndexError, ValueError):
            return False
        return int(_store.utc_now().timestamp()) - claimed <= DELEGATED_CLAIM_SECONDS
    return pid_still_running(stamped[0], stamped[1] if len(stamped) > 1 else None)


def pid_still_running(pid, began):
    """Whether the process wearing `pid` is the one that started at `began`.

    The pid-reuse rule of shared-invariants row `ar`, in one place because two readers judge the
    same processes by it: a run's delegated triage stamp, and a worker run's own record. A stamp
    carrying no instant is answered on the bare pid — records written before the field went in must
    not start reading dead — and so is a `ps` that cannot answer at all, which is only ever told
    apart from death by asking it for a pid that must exist.
    """
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    elapsed = pid_elapsed_seconds(pid)
    if elapsed is None:
        # Pid 1 and never this process: a sandbox hiding every process but our own still lists our
        # own, and a foreign supervisor would then read gone.
        return pid_elapsed_seconds(1) is None
    if began is None:
        return True
    try:
        began = int(began)
    except (TypeError, ValueError):
        return True
    return abs(int(_store.utc_now().timestamp()) - elapsed - began) <= DELEGATED_PID_SLACK


def read_fork(run_dir):
    try:
        record = json.loads((run_dir / FORK_RECORD).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(record, dict) or record.get("choice") not in FORK_CHOICES:
        return None
    return record


def fork_owed(run_dir, meta, verdicts=None):
    """Asked of the gate through `escalation_verdict` like every other reader (row af); a gate
    that cannot be asked owes nothing here, since the report already says so out loud."""
    rows = verdicts if verdicts is not None else recorded_verdict_rows(run_dir)
    if rows is None:
        return False
    earned = escalation_verdict(*escalation_numbers(run_dir, meta, rows))
    return bool(earned) and earned != ESCALATION_UNKNOWN


def fork_missing(run_dir, meta, verdicts=None):
    return fork_owed(run_dir, meta, verdicts) and read_fork(run_dir) is None


def fork_command(run_id):
    return (
        f"review-bench fork {shlex.quote(run_id)} --choice fix|simplify|re-review "
        f"--why '<the strategic reason for the choice, {FORK_WHY_MIN_CHARS}+ chars>'"
    )


def fork_refusal(run_id):
    return f"review run {run_id} crossed a threshold and has no fork on record; record it first: {fork_command(run_id)}"


def triage_pending_run(repo=None, session=None):
    """The newest worktree run of `repo` if it still owes its triaged report, else None.

    Only the newest one is ever asked for: an older run judged a diff that has since moved, and a
    queue of them would block turns with nothing to do with the review.

    Scoped to one repository because the state directory is shared by every chat: unscoped, a
    session in another project answers for this run, spends its asks, and the session that owes
    the report is never asked at all.

    `session` is asked of that newest run and refuses it, never skipped past, because one repository
    is shared by every co-tenant chat too: a run another chat launched is that chat's to report, and
    asking this one spends the run's asks where they can do nothing — but walking on to an older run
    of the same repository hands over exactly the moved diff the newest-only rule exists to refuse.
    A run recording no session at all still matches, since a daemon launch or an older build owes
    its report to whoever is here rather than to nobody.
    """
    benches = _store.state_dir() / "benches"
    common = _store.git_common_dir(repo) if repo else None
    for run_dir in sorted(benches.iterdir(), reverse=True) if benches.exists() else ():
        meta_path = run_dir / "meta.json"
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text())
        except json.JSONDecodeError:
            continue
        if meta.get("worktree") is not True:
            continue
        if repo is not None:
            # Same rule as the review receipt: a git worktree of the repository is the repository,
            # and an unresolvable path on either side is not a match, so the gate stays quiet
            # rather than blocking a session over somebody else's review. A merged review is owed
            # its report in every repository it read, whichever one the turn is happening in.
            reviewed = [meta.get("repo")] + [
                entry.get("repo") for entry in meta.get("repos") or ()
                if isinstance(entry, dict)
            ]
            if common is None or not any(
                _store.git_common_dir(candidate) == common for candidate in reviewed if candidate
            ):
                continue
        launcher = str(meta.get("session") or "")
        if session and launcher and launcher != session:
            return None
        if (run_dir / "verdicts.jsonl").exists() or (run_dir / _store.REPORT_RECEIPT).exists():
            if not fork_missing(run_dir, meta):
                return None
        if triage_delegated(run_dir):
            return None
        finished = _store.parse_iso_timestamp(meta.get("finished") or meta.get("finished_at"))
        if finished is None:
            return None
        if (datetime.now(timezone.utc) - finished).total_seconds() > _store.TRIAGE_GATE_HOURS * 3600:
            return None
        return run_dir, meta
    return None


def review_outcome(repo, receipt):
    """What the run behind this receipt produced: the confirmed count it was adjudicated to and,
    for a worktree run — which the corpus refuses, so it can never have one — the findings its
    panel wrote. Both readers of a receipt need this to tell a review that provoked work from one
    that found nothing, and neither should derive it a second time.
    """
    # Aggregated over every run of the receipt's commit, not the receipt's run alone: a
    # targeted rerun of one errored cell rewrites the receipt, and reading only that run
    # would score a panel that found defects as a review that found nothing.
    sd = _store.state_dir()
    commit = str(receipt.get("commit") or "")
    # Only what was measured the way this receipt was: a lens run of the same commit answers a
    # different question, and counting it would let one declare an ordinary review's work done.
    lens = receipt.get("lens")
    # Full-sha equality, never a prefix: reviews.jsonl spans every repository, and two repos
    # sharing seven hex characters would import each other's confirmed counts.
    confirmed = sum(
        row["confirmed"] for row in _prompts.lens_rows(_store.read_jsonl(sd / "reviews.jsonl"), lens)
        if (row.get("run_id") == receipt["run_id"]
            or (commit and str(row.get("commit") or "") == commit))
        and isinstance(row.get("confirmed"), int)
        and not isinstance(row.get("confirmed"), bool)
    )
    worktree = _scope.is_worktree_snapshot(repo, commit)
    findings = 0
    if worktree:
        benches = sd / "benches"
        for run_dir in sorted(benches.iterdir()) if benches.exists() else []:
            meta_path = run_dir / "meta.json"
            meta = {}
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text())
                except (OSError, json.JSONDecodeError):
                    # An unreadable run proves nothing; counting its findings files would
                    # trust exactly the raters its meta may have marked errored.
                    continue
            if meta.get("lens") != lens:
                continue
            # A merged review names the merged workspace's commit, never this repository's own
            # snapshot: the run that read this receipt's tree is the one whose members include it,
            # and only the findings under that member's prefix are about this repository.
            prefix = member_finding_prefix(meta, commit)
            meta_commit = str(meta.get("commit") or "")
            # The run_id fallback exists for artifacts with no commit stamped at all; a run
            # that NAMES a different commit is a different review, whatever its directory.
            if not prefix:
                if meta_commit:
                    if meta_commit != commit:
                        continue
                elif (meta.get("run_id") or run_dir.name) != receipt.get("run_id"):
                    continue
            # The FINAL attempt of each cell answers for it: a retry's superseded row keeps its
            # own `errored`, and reading every row dropped the findings of cells that went on to
            # complete — the very cells whose retry is why the panel has anything to count.
            final_runs, _ = _panel.cell_attempt_rows(list(meta.get("rater_runs", ())))
            errored = {
                entry.get("rater") for entry in final_runs
                if entry.get("errored") and entry.get("rater")
            }
            findings += sum(
                sum(1 for row in _store.read_jsonl(path)
                    if str(row.get("file") or "").startswith(prefix))
                for path in sorted(run_dir.glob("findings-*.jsonl"))
                if path.name[len("findings-"):-len(".jsonl")] not in errored
            )
            # A commit-point round never enters the corpus, so reviews.jsonl holds no row for it
            # and the sum above is 0 whatever its triage confirmed: the receipt of a round that
            # provoked a whole fixing pass read as a review that found nothing (live case
            # 2026-08-22). The triage is on record in the report receipt, and this is the same
            # tally the frame printed, narrowed to the member this repository is.
            confirmed += triaged_confirmed(run_dir, prefix)
    return worktree, confirmed, findings


def triaged_confirmed(run_dir, prefix=""):
    """How many findings a run's triage confirmed in the member `prefix` names, off whichever copy
    of that triage survives. Counted through the findings themselves, because a merged panel's
    tally spans every repository it read and a member's receipt answers only for its own.
    """
    rows = recorded_verdict_rows(run_dir)
    if not rows:
        return 0
    if not prefix:
        return confirmed_count(rows)
    findings = {}
    total = 0
    for row in rows:
        if not isinstance(row, dict) or row.get("verdict") != "confirmed":
            continue
        rater = row.get("rater")
        idx = row.get("idx")
        if not rater or not isinstance(idx, int) or isinstance(idx, bool):
            continue
        if rater not in findings:
            findings[rater] = _store.finding_rows(run_dir, rater)
        if idx < len(findings[rater]) and str(
            findings[rater][idx].get("file") or ""
        ).startswith(prefix):
            total += 1
    return total


def cmd_receipt(args):
    """Print this repository's review receipt as JSON: the run behind it, the tree it read, and the
    confirmed-defect count it was adjudicated to.

    `--lens` and `--scope` print those runs' own receipts. Neither read what the plain one answers
    for — a lens ran a methodology this tool did not write, a scoped run read part of the tree — so
    they are named explicitly or not read at all.
    """
    repo = _store.resolve_repo_arg(args.repo) or Path(args.repo).resolve()
    # Resolved rather than taken as typed: the receipt was written under the canonical slug,
    # and a former slug is exactly what a reader still has in hand.
    lens = _prompts.resolve_lens(args.lens)["name"] if getattr(args, "lens", "") else None
    scope = _scope.normalize_scope_paths(repo, args.scope) if getattr(args, "scope", None) else None
    receipt = _store.review_receipt(repo, lens, scope)
    if not receipt:
        return 1
    worktree, confirmed, findings = review_outcome(repo, receipt)
    extra = {"worktree": worktree}
    if worktree:
        extra["findings"] = findings
    print(json.dumps(dict(receipt, confirmed=confirmed, **extra)))
    return 0


def gate_asks_spent(marker, mark, state=""):
    """Whether this ask is one the Stop gate has already made, counting this one where `mark` says to.

    One appended `<iso> <state>` line per ask, counted back. A number read, incremented and
    rewritten loses an increment whenever two stop hooks fire together — Egor runs several chats at
    once — and the allowance quietly stretches. A marker that cannot be read counts as spent: a gate
    blind to its own state must go quiet rather than block a stop it can never release.

    The `state` is the QUESTION, not the run: asked once and answered by nobody, repeating it at
    every Stop is nagging, but a state that has moved — another path in the residual, a run that has
    since been triaged and now owes a fork — is a different question and gets its own ask. The count
    stays as the loop guard for a state that flaps. A marker line from before this format carries no
    state, which no real question equals, so it costs one ask and no more.
    """
    try:
        lines = [line for line in marker.read_text().splitlines() if line.strip()]
    except FileNotFoundError:
        lines = []
    except (OSError, UnicodeDecodeError):
        return True
    if state and lines:
        _, _, last = lines[-1].strip().partition(" ")
        if last == state:
            return True
    if len(lines) >= TRIAGE_GATE_ASKS:
        return True
    if mark:
        with marker.open("a") as handle:
            handle.write(f"{_store.iso_now()} {state}\n")
    return False


def cmd_pending_report(args):
    session = getattr(args, "session", "") or None
    pending = triage_pending_run(args.repo, session)
    if pending is None:
        # Nothing here owes a triage, which is where the other thing a stop may not sleep on
        # begins: a round whose budget is spent while its own scope is still in debt.
        return unsettled_report(args.repo, session, args.mark)
    run_dir, meta = pending
    triaged = _store.run_triaged(run_dir)
    if gate_asks_spent(
        run_dir / TRIAGE_NUDGED, args.mark, f"{run_dir.name} {'fork' if triaged else 'record'}"
    ):
        return 1
    if triaged:
        print(f"{run_dir.name} {confirmed_count(recorded_verdict_rows(run_dir))}")
        print(fork_command(run_dir.name))
        return 0
    findings = _panel.bench_summary(run_dir, meta)["findings"]
    print(f"{run_dir.name} {findings}")
    print(triage_command(run_dir.name, findings))
    return 0


def unsettled_round(repo, session):
    """The newest round of `session` over `repo` whose round budget is spent while its own scope is
    still in debt, as `(run_dir, diff lines, paths)`, or None.

    A closed budget may not sleep on unsettled debt. The contract owes no third pass over a scope
    whose second round is done, and none over a round nothing further is owed — so nothing left in
    the flow will ever come back to those paths: no lock stands over them, no fork demands a round,
    and the commit notice speaks once, at a commit that may never come. Left there, 252 diff lines
    of one chat's own fixing pass sat in debt with no waiver and nothing asking for one (live case
    2026-08-24). The two answers are the two the commit notice prints, and this asks for them at the
    one moment the chat is deciding it is done.

    A round still owed a follow-up is passed over: the fork and the lock speak for those, and a
    second demand over the same round would ask for a waiver the lock refuses. So is a round whose
    fixing pass has not answered — its bytes are still landing — and one whose snapshot this
    repository is not in.

    `paths` is this session's OWN debt and nothing else, and the line count is over those same
    paths, or the demand names a number no command it prints can settle. A co-tenant's residual is
    that chat's round to ask for and a waiver `waive` refuses by their name. Orphaned residual is
    nobody's to waive on a demand made of whoever happened to stop here — no record names it for
    this chat, and this gate may not turn "nobody's" into "yours" by asking. It stays where a
    question nobody is being asked belongs: the statusline's third number, `doctor`, and
    `review --debt --all`.
    """
    from . import debt as _debt  # here and not at module top: debt imports this module at load
    resolved = _store.resolve_repo_arg(repo) if repo else None
    if resolved is None or not session:
        return None
    family = _store.repo_family(str(resolved))
    benches = _store.state_dir() / "benches"
    inputs = None
    for run_dir in sorted(benches.iterdir(), reverse=True) if benches.exists() else ():
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict) or str(meta.get("session") or "") != session:
            continue
        record = _store.run_repo_record(resolved, meta, family=family)
        if record is None or not _store.run_triaged(run_dir):
            continue
        reviewed = record.get("reviewed")
        if not isinstance(reviewed, dict) or not reviewed:
            continue
        if round_state(run_dir) != "done":
            continue
        artifact = {"kind": "run", "id": run_dir.name, "dir": run_dir}
        if _debt.artifact_owes_second_round(artifact):
            continue
        if inputs is None:
            # Read at the first round that reaches here rather than before the loop: this runs at
            # every Stop, and most of them have no finished round of their own to pay for a walk of
            # the whole run store and every artifact of the family.
            records = _store.worker_run_dirs()
            artifacts = _debt.repo_artifacts(resolved)
            inputs = (
                records,
                _store.run_record_claims(resolved, records),
                _store.run_dirty_paths(resolved, records),
                _debt.covering_artifacts(resolved, artifacts=artifacts),
                _debt.reviewed_shas(artifacts, resolved),
                _debt.path_holders(artifacts),
            )
        records, claims, dirty, covering, reviewed_shas, holders = inputs
        shas = {}
        bases = {}
        debt = _debt.repo_debt(
            resolved, paths=sorted(reviewed), covering=covering, shas=shas, claims=claims,
            dirty=dirty, reviewed=reviewed_shas, holders=holders, bases=bases,
        )
        if not debt:
            continue
        buckets = _debt.debt_ownership(resolved, debt, session, claims=claims, records=records)
        paths = [path for path, _ in debt if path in buckets["own"]]
        if not paths:
            continue
        lines = _debt.debt_line_counts(resolved, debt, shas=shas, bases=bases)
        return run_dir, sum(lines.get(path, 0) for path in paths), paths
    return None


def live_round_reads(repo, session, paths):
    """Whether a review this chat has IN FLIGHT already reads every one of `paths`.

    The demand's own answer is a review of those paths, and while one is running it is being given:
    asking for it again burns the allowance against a panel that is about to settle the very debt
    named (three asks against a live panel, 2026-08-24). Live is the one signal the statusline's
    review anchor uses — a progress document of this chat whose process is alive — and the scope is
    the run's own `reviewed` snapshot, written at launch. A run of ANOTHER chat silences nothing: its
    scope is not this chat's to wait on. A run that dies without recording leaves nothing alive, so
    the next Stop asks as before.
    """
    resolved = _store.resolve_repo_arg(repo) if repo else None
    if resolved is None or not session or not paths:
        return False
    demanded = set(paths)
    benches = _store.state_dir() / "benches"
    family = _store.repo_family(str(resolved))
    for run_id in live_progress_run_ids(session):
        try:
            meta = json.loads((benches / run_id / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict):
            continue
        record = _store.run_repo_record(resolved, meta, family=family)
        if record is None:
            continue
        reviewed = record.get("reviewed")
        if isinstance(reviewed, dict) and demanded <= set(reviewed):
            return True
    return False


def live_worker_run(repo, session):
    """Whether a worker run THIS chat launched is still writing inside this repository's family.

    The other half of the situation `live_round_reads` reads: the demand prices CONTENT, and while
    a worker of this chat is mid-edit there is no content to answer for yet — the ask went out over
    18056 lines of two half-written files and spent the allowance on a scope that was gone a minute
    later (2026-08-24). A worker a chat spawned IS that chat (shared-invariants row `am`), so this
    is the chat waiting for itself; another chat's run silences nothing, and neither does a run
    standing in some other repository, whose edits this demand would never name.

    No path matching, deliberately: a run's file list is written at its end, and the vendors that
    keep none never write one at all — where the run STANDS is the only thing on disk while it
    still runs. Liveness is the pid rule row `ar` binds every reader of these records to, so an
    abandoned supervisor silences nothing: a run that died mid-write would otherwise hold the ask
    off for as long as its record sits there.
    """
    resolved = _store.resolve_repo_arg(repo) if repo else None
    if resolved is None or not session:
        return False
    family = _store.repo_family(str(resolved))
    if family is None:
        return False
    for directory in _store.worker_run_dirs():
        if (directory / "exit_code").exists():
            continue
        try:
            launcher = (directory / "launcher").read_text().strip()
        except (OSError, UnicodeDecodeError):
            continue
        if launcher != session:
            continue
        try:
            meta = json.loads((directory / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict):
            continue
        workdir = meta.get("workdir")
        if not isinstance(workdir, str) or not workdir:
            continue
        if _store.repo_family(workdir) != family:
            continue
        if pid_still_running(meta.get("pid"), meta.get("pid_started_at")):
            return True
    return False


def unsettled_report(repo, session, mark):
    """The settle demand as the Stop gate reads it: `<run-id> <diff lines>`, then the two commands
    that answer it — the waiver over exactly those paths, and the review that scopes itself.

    The hook relays; nothing here is a judgment it makes. The waiver's reason is the placeholder the
    commit notice prints in the same position, which `waive` itself refuses, so the chat has to say
    why in its own words.
    """
    from . import debt as _debt  # here and not at module top: debt imports this module at load
    found = unsettled_round(repo, session)
    if found is None:
        return 1
    run_dir, lines, paths = found
    # Before the counter, never after: a demand already being answered — or not yet askable,
    # because the content it would price is still being written — must cost nothing.
    if live_round_reads(repo, session, paths):
        return 1
    if live_worker_run(repo, session):
        return 1
    # shlex.join, not a plain space: the state is ONE path set, and space-joined it is not — a path
    # spelled `a b` reads back as the pair `a`, `b` and buys that other question's silence.
    if gate_asks_spent(run_dir / SETTLE_NUDGED, mark, shlex.join(sorted(paths))):
        return 1
    print(f"{run_dir.name} {lines}")
    print(shlex.join([
        "review-bench", "waive", "--reason", _debt.WAIVE_PLACEHOLDER_REASON, "--paths",
        *(f"./{path}" for path in paths),
    ]))
    print(_debt.debt_chat_review_command(session, [repo]))
    return 0


def run_record_window(directory):
    """`(start epoch, end epoch)` a worker run occupied, or None where its record cannot place it.

    The end is the `exit_code` file's own mtime — the instant `worker-run` wrote the run's last
    word — and a run still writing ends at now, since its edits are still landing.
    """
    try:
        started = json.loads((directory / "meta.json").read_text()).get("started_at")
    except (OSError, ValueError):
        return None
    if not isinstance(started, int) or isinstance(started, bool):
        return None
    exit_code = directory / "exit_code"
    try:
        return started, int(exit_code.stat().st_mtime)
    except OSError:
        return started, int(time.time())


def blind_fix_runs(repo, session, window, records=None):
    """What the run records say about paths a fixing pass may have written without recording
    which, as `(named, foreign, mine, theirs)`: the paths this chat's own blind runs DID name, the
    ones a co-tenant's did, whether any run of this chat could have written into `repo` unrecorded
    inside `window`, and whether any other chat's could.

    A codex or gemini worker runs no journal hook of ours, and its file listing is exact only
    when its vendor transcript named every mutating target (else `UNKNOWN:`), so a listless fix
    pass delegated to one reaches every store as nothing at all — the journals, the file
    listing and the artifacts alike (live case 2026-08-22). Its record still says three things:
    which chat launched it, which repository it stood in, and that its own listing cannot be
    complete. Where that is the ONLY actor any store places on a scope path inside the window,
    it is the pass that wrote it; where a co-tenant ran one too, nothing here can tell the two
    apart and the path stays in debt, which is what every other guard here does with an
    ambiguity.

    The two FLAGS answer only for a run whose dirt record cannot be read per path — one written
    before `dirty-before-shas` existed, whose already-dirty paths all read as untouched however
    the run rewrote them. That is the whole of what a flag standing over the repository can say:
    a run whose dirt record DOES answer per path has named its own work in `named`, and a flag
    beside it would cover every unjournalled scope path on no evidence about that path at all —
    an editor edit outside this machine's hooks, made while the pass ran, retired from debt as
    though the pass had answered for it.

    `named` and its foreign twin are the dirt records, which are about CONTENT and never
    authorship — read here only through the launcher of the run that recorded them, and only
    inside the window, which is the one reading where the two questions coincide.
    """
    named, foreign, mine, theirs = set(), set(), False, False
    start, end = window
    launchers = worker_session_launchers()
    for directory in (_store.worker_run_dirs() if records is None else records):
        try:
            launcher = (directory / "launcher").read_text().strip()
        except OSError:
            continue
        if not launcher:
            continue
        own = launcher == session or launchers.get(launcher) == session
        span = run_record_window(directory)
        if span is None or span[1] < start or span[0] > end:
            continue
        dirt = set(_store.run_record_paths(repo, directory, listing="dirty"))
        if own:
            named |= dirt
        else:
            # A co-tenant's blind run naming the path is the parallel edit a co-tenant's journal
            # entry is, in the one store that holds it while nothing has swept the run.
            foreign |= dirt
        try:
            listing = (directory / "files").read_text()
        except OSError:
            listing = ""
        if not listing:
            continue
        # A `WORKDIR:` this repository does not hold places the run in another checkout entirely;
        # `run_record_paths` answers empty for both that and a listing of no paths, so the workdir
        # line is read here rather than inferred from the paths.
        workdir = next(
            (line[len("WORKDIR: "):] for line in listing.splitlines()
             if line.startswith("WORKDIR: ")), "",
        )
        if not workdir or _store.scope_path_relative(repo, workdir) is None:
            continue
        # Line-anchored, the way `run_record_paths` and `record_workdir_dirt` read the same two
        # markers: a filename holding one of these tokens is a path, and a second spelling of one
        # record's grammar is how the readings come to disagree about it.
        if not any(line.startswith(("UNKNOWN: ", "PARTIAL: ")) for line in listing.splitlines()):
            continue
        # A record whose dirt reading predates the content shas answers for no path of its own.
        if (directory / "dirty-before-shas").exists():
            continue
        if own:
            mine = True
        else:
            theirs = True
    return named, foreign, mine, theirs


def fix_written_paths(repo, scope, session, window):
    """The paths of `scope` whose every journalled edit inside `window` is the fixing session's
    own, at the shas they held when this reading began.

    Every refusal here leaves the path in debt where it belongs. A path the window names nobody
    for holds no fix bytes at all, and covering it would blanket the round's whole scope. A record
    with no timestamp cannot be placed inside the window, one stamped AFTER its end is bytes the
    sha below holds and the window never checked, and one naming another chat — or a co-tenant's
    worker run the journals have not swept yet — is an edit this pass never made: either way the
    file holds bytes nobody has answered for.

    A worker a chat spawned IS that chat, so its own journal entries fold into the launcher exactly
    as `debt` folds them (docs/shared-invariants.md row `am`). A vendor whose worker journals
    nothing at all leaves a path with no entry either way, and `blind_fix_runs` is the evidence
    that stands in for one.
    """
    start, end = window
    # The shas BEFORE the two record stores and never after them: an edit landing between the
    # readings stands in a sha taken last while the record read past it names nobody, and the
    # receipt would settle a co-tenant's bytes with no entry to disqualify them. Read first, those
    # bytes are simply not in the sha this covers, and the path is in debt at its next reading.
    # Written into the store as they are read: this receipt's coverage is an artifact, and
    # what it records is diffed as content by every later pricing of these paths.
    shas = _store.stored_path_blob_shas(repo, scope)
    records = {}
    for entry, epoch, path in _store.journal_rows(repo):
        if path in scope:
            records.setdefault(path, []).append((entry, epoch))
    launchers = worker_session_launchers()
    claims = _store.run_record_claims(repo)
    blind_named, blind_foreign, blind_mine, blind_theirs = blind_fix_runs(repo, session, window)
    covered = {}
    for path in scope:
        rows = records.get(path, ())
        # The run records read raw and never through `foreign_run_claims`, which drops a path this
        # chat's own run wrote too: right for a waiver over the launcher's own output, wrong here,
        # where the co-tenant's bytes stand in the very sha this receipt would settle. Raw is not
        # unfolded, though — a run a worker of this chat spawned is this chat's (row `am`), the way
        # the journal entries below fold, or the pass's own nested worker reads as a co-tenant.
        if any(launcher != session and launchers.get(launcher) != session
               for _, launcher in claims.get(path, ())):
            continue
        if path in blind_foreign:
            continue
        if any(epoch is None or epoch > end for _, epoch in rows):
            continue
        inside = [entry for entry, epoch in rows if start <= epoch <= end]
        if inside:
            if not all(entry == session or launchers.get(entry) == session for entry in inside):
                continue
        elif not (path in blind_named or (blind_mine and not blind_theirs)):
            continue
        covered[path] = shas[path]
    return covered


def round_covers_its_fixes(run_dir, meta, rows):
    """Whether this round's own fixing pass settles the bytes it wrote, or a second pass owes them.

    The gate's answer and never a count taken here, so the two dials keep living in one place
    (docs/shared-invariants.md row `af`): a round the gate CLOSED is one nothing will read again,
    and a round it escalated owes its fixes to the pass it is sending the chat back for.

    With ONE exception, which is a hole and not a policy: a scope whose round budget is spent has
    no further pass to owe. `artifact_owes_second_round` already refuses to reopen such a round, so
    escalated-and-spent covered nothing and owed nothing at once, and its fix bytes could be
    answered by no review that exists — only by a waiver somebody had to know to write (audit,
    2026-08-26). The dials do not move; only the question of who reads these lines does.
    """
    if escalation_verdict(*escalation_numbers(run_dir, meta, rows)) is None:
        return True
    return round_budget_spent(run_dir)


def commit_paths(repo, commit):
    """The paths a commit carried, against its first parent, as `{path: blob sha}`.

    The sha is the one the COMMIT holds and never the working tree's: what this covers is the
    content that landed, so an edit made after the commit is debt again at the next reading,
    exactly as an edit after a waiver is. A path the commit DELETED holds no blob and is left out
    — a removal has nothing for a later review to read.
    """
    listed = subprocess.run(
        ["git", "log", "-1", "--format=", "--name-only", "--first-parent", "-z", commit],
        cwd=repo, capture_output=True, text=True,
    )
    if listed.returncode != 0:
        return {}
    names = [name for name in listed.stdout.split("\0") if name]
    if not names:
        return {}
    try:
        entries = _scope.tree_path_entries(repo, f"{commit}^{{tree}}", names, literal=True)
    except RuntimeError:
        return {}
    return {path: entry[1] for path, entry in entries.items() if entry[1]}


def commit_fix_coverage(run_dir, repo, commit, landed=None, meta=None):
    """What a commit closes of this round: the `covers` entries for every path the commit carried
    that this round's own scope holds, at the shas the commit left them standing at.

    The commit IS the evidence, which is the whole of the mechanism. `fix_written_paths` asks the
    journals instead, and they answer only where a debt row happened to be stamped inside the
    fixing window naming the fixing session — which is not when they are written: the row goes down
    at COMMIT time, after the receipt, so 51 of 71 done receipts in a three-week window carried no
    coverage at all and their own fix bytes read back as fresh debt (audit, 2026-08-26). A commit
    needs no such luck: it names its paths, it names its contents, and the chat that made it is the
    chat this is being asked on behalf of.

    Bounded by `set(reviewed)` like every other coverage: a fix that touched a file no cell was
    ever shown is new work, and no panel read the content this would settle it at.

    `landed` is the commit's own path map, for a caller closing several rounds with one commit: the
    paths are the COMMIT's and not the round's, so asking git once per round asks it the same
    question over and over inside the hook the commit is waiting on. `meta` is the round's own
    record where the caller already parsed it, for the same reason.
    """
    if meta is None:
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            return []
    if not isinstance(meta, dict):
        return []
    landed = commit_paths(repo, commit) if landed is None else landed
    if not landed:
        return []
    resolved = _store.resolved_repo_path(repo)
    family = _store.repo_family(repo)
    covers = []
    for entry in [meta] + [row for row in meta.get("repos") or () if isinstance(row, dict)]:
        recorded = str(entry.get("repo") or "")
        reviewed = entry.get("reviewed")
        if not recorded or not isinstance(reviewed, dict) or not reviewed:
            continue
        # `family is not None` exactly as `run_repo_record` reads it: two repositories neither of
        # which HAS a family are not one repository, and matched on that shared None an unrelated
        # round's scope took this commit's shas for its own coverage.
        if _store.resolved_repo_path(recorded) != resolved and not (
                family is not None and _store.repo_family(recorded) == family):
            continue
        paths = {path: sha for path, sha in landed.items() if path in reviewed}
        if paths:
            covers.append({"repo": recorded, "paths": paths})
    return covers


def merge_fix_coverage(existing, fresh):
    """One round's `covers` block with a commit's entries folded in, per repository.

    A path already covered takes the NEW sha: coverage follows the bytes the same pass wrote, and
    a second commit over a path this receipt already answers for is that pass still working — read
    against the older sha it came back as debt the moment it landed (audit, 2026-08-26).
    """
    merged = [dict(entry, paths=dict(entry.get("paths") or {}))
              for entry in existing or () if isinstance(entry, dict)]
    for entry in fresh:
        standing = next(
            (row for row in merged
             if _store.resolved_repo_path(str(row.get("repo") or ""))
             == _store.resolved_repo_path(entry["repo"])),
            None,
        )
        if standing is None:
            merged.append({"repo": entry["repo"], "paths": dict(entry["paths"])})
        else:
            standing["paths"].update(entry["paths"])
    return merged


def round_within_fixing_window(meta, now=None):
    """Whether this round is still close enough to its own fixing pass for a commit to close it.

    `ROUND_LINEAGE_MAX_HOURS` is the same doctrine the lineage reads it by: a round and the pass
    that fixes it are one piece of work, days at the outside. Without it every commit in this
    checkout re-prices every round the store has ever held, for ever. A round that stamped no
    instant at all is kept rather than dropped: a bound nobody can evaluate must not close a door
    silently, and `fixes --done` is the answer for a pass that ran later than this.
    """
    stamped = _store.parse_iso_timestamp(
        meta.get("finished") or meta.get("finished_at") or meta.get("sealed_at"))
    if stamped is None:
        return True
    now = _store.utc_now() if now is None else now
    return (now - stamped) <= timedelta(hours=ROUND_LINEAGE_MAX_HOURS)


def coverable_runs(repo, session, commit, run_id=None):
    """Every round of `session` over `repo` whose fixing pass this commit may close, newest first.

    A worker a chat spawned IS that chat (docs/shared-invariants.md row `am`), so a round that
    worker launched is folded into its launcher here exactly as debt folds it — otherwise a review
    dispatched to a worker could be closed by nobody's commit.

    Refused, in order: a round nobody triaged, since a receipt is an answer to confirmed findings;
    a round whose pass recorded `--blocked`, since a stop is a record and a commit does not undo
    it; a round the gate escalated over a scope with budget left, since the pass it owes reads the
    fixes itself; and a round holding NO confirmed finding, which has no fixing pass at all for a
    commit to be the evidence of — `fix_status` already calls it done ("nothing to fix") whoever
    commits next, and covered by a commit anyway it retired that commit's own bytes as reviewed
    work no panel had read (a clean round plus a commit rewriting a reviewed file wrote
    `covers={f.txt: <the new sha>}`; audit, 2026-08-26). The tally path refuses the same case with
    `if not fixed`.

    This runs inside a commit hook, so it is bounded twice: the commit's paths are read from git
    ONCE for every round it may close, and a round outside the fixing window above is dropped
    before anything reads its verdicts or asks the gate about it. `run_id` names the single round
    a caller already has in hand, which is the rest of the store not walked at all.
    """
    launchers = worker_session_launchers()
    resolved = _store.resolved_repo_path(repo)
    family = _store.repo_family(repo)
    benches = _store.state_dir() / "benches"
    landed = commit_paths(repo, commit)
    if not landed:
        return []
    rounds = []
    if run_id is not None:
        named = benches / run_id
        candidates = (named,) if named.parent == benches and named.is_dir() else ()
    elif benches.exists():
        candidates = sorted(benches.iterdir(), reverse=True)
    else:
        candidates = ()
    for run_dir in candidates:
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict):
            continue
        owner = str(meta.get("session") or "")
        if owner != session and launchers.get(owner) != session:
            continue
        if _store.run_repo_record(resolved, meta, family) is None:
            continue
        if not round_within_fixing_window(meta):
            continue
        if not _store.run_triaged(run_dir):
            continue
        record = read_fix_status(run_dir)
        if isinstance(record, dict) and record.get("state") == "blocked":
            continue
        rows = recorded_verdict_rows(run_dir)
        if rows is None or not confirmed_count(rows):
            continue
        if not round_covers_its_fixes(run_dir, meta, rows):
            continue
        covers = commit_fix_coverage(run_dir, repo, commit, landed=landed, meta=meta)
        if covers:
            rounds.append((run_dir, meta, rows, record, covers))
    return rounds


def fix_coverage(run_dir, session, recorded, rows, fixed):
    """What a done receipt covers besides the run's own snapshot: the bytes this round's OWN fixing
    pass wrote, per repository of the run, as `covers` entries.

    A round the gate closed is one nothing will ever read again — no second pass is owed over it —
    so its fixes left in debt are a waiver every later chat has to know to write, over work this
    very receipt accounts for. A round the gate escalated covers nothing: the pass it owes reads
    the fixes itself, and so does the mandatory one a locked round demands. Priced by asking the
    gate rather than by counting here, so the two dials keep living in one place
    (docs/shared-invariants.md row `af`) — and an unreachable gate covers nothing, which is the
    behaviour of every round written before this receipt held coverage at all.

    The window opens at the SEAL and not at the finish: that is the instant the panel stopped being
    able to read the tree, and the recorded seal is inherited by a rerun of the same snapshot, so a
    rerun covers the same lineage the run it repeats does. A run predating the seal stamp covers
    nothing rather than falling back to its launch: the launch is minutes EARLIER, and every one of
    those minutes is time the panel could still read a file this window would then settle.

    A pass that fixed nothing wrote no fix bytes to cover, and a triage nothing can read prices no
    round at all — an all-false-positive round and a corrupt receipt both leave the scope's post-
    seal edits as ordinary unreviewed work.
    """
    try:
        meta = json.loads((run_dir / "meta.json").read_text())
    except (OSError, ValueError):
        return []
    if not session or not isinstance(meta, dict):
        return []
    if not fixed or rows is None:
        return []
    if not round_covers_its_fixes(run_dir, meta, rows):
        return []
    sealed = _store.parse_iso_timestamp(meta.get("sealed_at"))
    if sealed is None:
        return []
    window = (int(sealed.timestamp()), int(recorded.timestamp()))
    covers = []
    members = [row for row in meta.get("repos") or () if isinstance(row, dict)]
    for entry in [meta] + members:
        repo = str(entry.get("repo") or "")
        reviewed = entry.get("reviewed")
        # The round's own scope and nothing wider: a fix that touched a file no cell was ever
        # shown is new work, and no panel read the content a receipt would settle it at.
        if not repo or not isinstance(reviewed, dict) or not reviewed:
            continue
        paths = fix_written_paths(repo, set(reviewed), session, window)
        if paths:
            covers.append({"repo": repo, "paths": paths})
    return covers


def cover_receipt(run_dir, meta, rows, record, covers, commit, session):
    """The done receipt a commit writes for one round, with that commit's coverage folded in.

    The tally is the triage's own where nobody typed one: the counts are what the report PRINTS,
    and no reader of the debt engine has ever read them (`repo_debt` takes `covers` and nothing
    else). Making them the price of coverage is what left 51 of 71 receipts covering nothing.

    Stamped against the triage standing NOW, because that is the triage this commit answers: a
    receipt carrying an older fingerprint is one `fix_coverage_artifact` reads as stale, so it
    would record coverage no reader would ever honour.
    """
    confirmed = confirmed_count(rows)
    digest = triage_digest(rows)
    standing = record if isinstance(record, dict) and record.get("state") == "done" else {}
    # The tally is kept only where it answers THIS triage. Carried across a re-adjudication it
    # stands beside a `confirmed` restamped from the new rows, and the report prints a pair that
    # belongs to neither triage. The COVERAGE is kept either way: it records which bytes a pass
    # wrote, which no later judging of the findings can take back.
    tally = standing if standing.get("triage") == digest else {}
    fixed = tally.get("fixed")
    written = {
        "state": "done",
        "fixed": confirmed if not isinstance(fixed, int) else fixed,
        "false_positives": tally.get("false_positives") if isinstance(
            tally.get("false_positives"), int) else 0,
        "confirmed": confirmed,
        "triage": digest,
        # NOW and never the standing receipt's: this stamp is the fixes artifact's epoch
        # (`debt.fix_coverage_artifact`) and the instant `review_round` weighs against a later
        # round's seal, so shas that advanced under a timestamp that did not lost to artifacts
        # written between the two commits.
        "recorded_at": _store.iso_now(),
        "covers": merge_fix_coverage(standing.get("covers"), covers),
        # Which commits closed this pass, in order. Nothing reads it back — the coverage is in the
        # shas — and it is the only place a reader can see WHY a round it never typed a receipt for
        # is closed.
        "closed_by": list(dict.fromkeys(list(standing.get("closed_by") or ()) + [commit])),
    }
    owner = session or _store.round_session(run_dir) or ""
    if owner:
        written["session"] = owner
    (run_dir / _store.FIX_RECEIPT).write_text(json.dumps(written, indent=2, sort_keys=True) + "\n")
    return written


def cmd_fixes_cover(args):
    """Close every fixing pass this commit finished, and cover what it landed.

    A review was done and its fixes landed: those two are ONE thing, so the commit that carries the
    fixes is what ends the round (Egor, 2026-08-25). No second command a model can forget stands
    between them — `fixes --done` remains for the tally the report prints and gates nothing.

    One commit may close several rounds, and a round is closed once: the coverage is a map of path
    to sha, so a later commit over the same path re-stamps it rather than adding a second answer.
    """
    commit = str(getattr(args, "commit", "") or "").strip()
    if not commit:
        raise ValueError("--cover needs --commit <sha>: the commit is the evidence it writes from")
    repo = _store.resolve_repo_arg(getattr(args, "repo", None) or ".")
    if repo is None:
        # Silent and exit 0: this runs from a commit hook, and a repository it cannot resolve is a
        # commit that landed somewhere this tool has nothing to say about.
        return 0
    session = str(getattr(args, "session", "") or "") or _store.caller_chat()
    if not session:
        return 0
    if args.run_id:
        run_dir = _store.state_dir() / "benches" / args.run_id
        if not (run_dir / "meta.json").exists():
            raise ValueError(f"unknown run id: {args.run_id}")
        # Walked for that run alone, and said out loud when it is not this commit's to close: a
        # caller who named a round is owed an answer about THAT round, and exit 0 with nothing on
        # stdout reads as a round that was closed.
        rounds = coverable_runs(repo, session, commit, run_id=args.run_id)
        if not rounds:
            raise ValueError(
                f"{args.run_id} is not a round this commit closes: it is another chat's or "
                f"another repository's, untriaged, blocked, escalated with budget left, outside "
                f"the {ROUND_LINEAGE_MAX_HOURS}h fixing window, holds no confirmed finding for a "
                f"fixing pass to answer, or {commit[:7]} carried none of the paths it reviewed"
            )
    else:
        rounds = coverable_runs(repo, session, commit)
    for run_dir, meta, rows, record, covers in rounds:
        cover_receipt(run_dir, meta, rows, record, covers, commit, session)
        covered = sum(len(entry["paths"]) for entry in covers)
        print(f"{run_dir.name} fixes: closed by {commit[:7]}; {covered} fixed path(s) covered")
    return 0


def cmd_fixes(args):
    """Record what happened to a triaged round's confirmed findings, so the report can say it.

    Three forms and no fourth: the commit that carried the fixes closed the pass (`--cover`), the
    work was done with the two counts the report prints, or it was not, with the reason it was not.
    A round with nothing on record is none of them — it reads as pending, which is what an
    interrupted fixing pass actually leaves behind.
    """
    if getattr(args, "cover", False):
        return cmd_fixes_cover(args)
    if not args.run_id:
        raise ValueError("fixes needs a run id; only --cover resolves its own rounds")
    run_dir = _store.state_dir() / "benches" / args.run_id
    if not (run_dir / "meta.json").exists():
        raise ValueError(f"unknown run id: {args.run_id}")
    # A receipt is an answer to confirmed findings, and an untriaged run has none: taken here it
    # would spend the scope's round budget over a pass nobody judged, while the run's own report
    # still asks for the triage.
    if not _store.run_triaged(run_dir):
        raise ValueError(
            f"{args.run_id} has no triage on record: record the verdicts before the fixes"
        )
    if args.blocked is not None:
        if args.fixed is not None or args.fp is not None:
            raise ValueError("--fixed and --fp belong to --done; a blocked round fixed nothing")
        reason = " ".join(str(args.blocked).split())
        if not reason:
            raise ValueError("--blocked must carry the reason the fixes were not applied")
        rows = recorded_verdict_rows(run_dir)
        record = {
            "state": "blocked", "reason": reason,
            # Which triage the pass stopped over, stamped exactly as a done receipt stamps it: the
            # fork this receipt puts in front of Egor is over THESE confirmed findings, and a
            # re-adjudication replacing them leaves a stop nobody recorded over the new ones.
            "confirmed": confirmed_count(rows), "triage": triage_digest(rows),
        }
        line = f"NOT APPLIED — {reason}"
    else:
        rows = recorded_verdict_rows(run_dir)
        confirmed = confirmed_count(rows)
        # The tally is what the report PRINTS and nothing else — the debt engine reads `covers`
        # alone — so a pass that answered every confirmed finding may say so without counting them
        # again. A number typed by hand still binds, and the checks below are what bind it.
        if args.fixed is None and args.fp is None:
            args.fixed, args.fp = confirmed, 0
        elif args.fixed is None or args.fp is None:
            raise ValueError("--fixed and --fp are one answer: give both numbers or neither")
        if args.fixed < 0 or args.fp < 0:
            raise ValueError("--fixed and --fp count findings, so neither can be negative")
        docs = _panel.docs_confirmed_count(run_dir, rows)
        split = f" ({confirmed - docs} in code, {docs} in docs)" if docs else ""
        # A done receipt says the round's confirmed findings were answered, and the two counts are
        # the answer: fewer between them than the triage confirmed is a pass that stopped, which
        # has its own form. Unchecked, `--done --fixed 0 --fp 0` retired the loud frame and spent
        # the scope's round budget over work nobody did.
        if args.fixed + args.fp < confirmed:
            raise ValueError(
                f"--fixed {args.fixed} and --fp {args.fp} answer for fewer findings than the "
                f"{confirmed} this triage confirmed{split}: a pass that left some of them "
                "standing is --blocked with the reason, not done"
            )
        # And bounded from above by the same triage, or the shortfall check below is the only
        # thing standing between a typo and a round retired for good on a tally its own verdicts
        # cannot account for: nothing can be fixed that nobody confirmed, and no receipt answers
        # for more findings than the panel produced.
        if args.fixed > confirmed:
            raise ValueError(
                f"--fixed {args.fixed} names more findings than the {confirmed} this triage "
                f"confirmed{split}: a pass cannot fix what nobody confirmed"
            )
        if args.fixed + args.fp > confirmed:
            raise ValueError(
                f"--fixed {args.fixed} and --fp {args.fp} answer for more findings than the "
                f"{confirmed} this triage confirmed{split}: the counts are outcomes for confirmed "
                "findings, and a receipt naming others is a record of no fixing pass at all"
            )
        record = {
            "state": "done", "fixed": args.fixed, "false_positives": args.fp,
            # Which triage this answers for. Counted off the same rows the report counts, so a
            # receipt written over one pass is recognised as stale the moment a re-adjudication
            # replaces it — and never merely because the two read different copies of one triage.
            # The fingerprint beside the count is what catches a re-adjudication of the same size.
            "confirmed": confirmed,
            "triage": triage_digest(rows),
        }
        line = f"done — {args.fixed} fixed, {args.fp} false positives"
    recorded = _store.utc_now()
    record["recorded_at"] = recorded.isoformat()
    session = _store.round_session(run_dir)
    if session:
        record["session"] = session
    if record["state"] == "done":
        covers = fix_coverage(run_dir, session, recorded, rows, args.fixed)
        # Folded into what the COMMIT already covered, never written over it: this tally is the
        # optional line after the commit closed the round, and rebuilt from scratch it erased that
        # commit's `covers` and `closed_by` — the fixed bytes then read back as fresh debt, which
        # is the very hole the commit receipt was written to close.
        standing = read_fix_status(run_dir)
        standing = standing if isinstance(standing, dict) and standing.get("state") == "done" \
            else {}
        covers = merge_fix_coverage(standing.get("covers"), covers)
        closed_by = list(dict.fromkeys(standing.get("closed_by") or ()))
        if closed_by:
            record["closed_by"] = closed_by
        if covers:
            record["covers"] = covers
            line += f"; {sum(len(entry['paths']) for entry in covers)} fixed path(s) covered"
    (run_dir / _store.FIX_RECEIPT).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    print(f"{args.run_id} fixes: {line}")
    return 0


def triage_instant(run_dir):
    """When this run's triage went on record, off the report receipt `record` writes, or None
    where no receipt is readable. Verdicts alone carry no instant of their own: a corpus
    adjudication is a benchmark row, not a round, and the pre-receipt runs are exactly the ones
    the delivery window must never re-open."""
    try:
        recorded = json.loads((run_dir / _store.REPORT_RECEIPT).read_text()).get("reported_at")
    except (OSError, ValueError, AttributeError):
        return None
    return _store.parse_iso_timestamp(recorded)


def delivery_state(run_dir):
    """What state a triaged round's report would be delivered in, or None where no hook may hand
    it to Egor.

    Read through `round_state` and never off the receipt's raw field, so the state a report is
    delivered under is the state its frame was rendered in: a receipt the report has already
    rejected for answering another triage reads `pending` here too, and queued as `done` it would
    spend the one ledger key the finished report is ever delivered under.

    A `pending` round — verdicts on record, fixing pass unanswered — is `triaged` while that
    triage is younger than the gate window: the counts Egor waited twelve minutes of triage for
    reached him only after the fixing pass, from the orchestrator's prose (2026-08-23). Past the
    window it is None at ANY age — an old triage is about a diff that has since moved, and the
    pre-receipt backlog must never re-enter the queue.

    A round with nothing confirmed is `done` at its triage: no fixing pass will ever record a
    receipt for it, and a report held back for one would never be delivered at all.
    """
    state = round_state(run_dir)
    if state != "pending":
        return state
    recorded = triage_instant(run_dir)
    if recorded is None:
        return None
    if _store.utc_now() - recorded > timedelta(hours=_store.TRIAGE_GATE_HOURS):
        return None
    return "triaged"


def delivery_mark(run_dir):
    """What `settle-delivery` recorded about this round's report, as a dict — empty where it has
    never been asked about."""
    try:
        mark = json.loads((run_dir / _store.DELIVERY_MARK).read_text())
    except (OSError, ValueError):
        return {}
    return mark if isinstance(mark, dict) else {}


def session_transcript_exists(session):
    """Whether the chat a report is owed to is still on disk to receive it.

    The Stop hook that delivers reads the transcript the harness hands it, so a session with none
    left has no stop to reach: a report queued for it would be owed for ever by a reader that can
    never run.

    Through the one resolver that names a chat (row `aw`) and never a glob of this reader's own:
    every chat on this machine runs under a claudeb PROFILE, whose transcripts live outside
    `~/.claude/projects` entirely, so a reading that knew only the default root would write off
    every round there is as owed to a chat that is gone — which is the silence this command exists
    to end.
    """
    try:
        return transcript_path(str(session or "")) is not None
    except OSError:
        return False


def cmd_pending_delivery(args):
    """Every run this chat launched whose report is ready to deliver, newest last, as
    `<run-id> <state>`.

    A run a headless worker triaged left no command output in this chat to carry its block, so the
    report the delivery gate exists to hand Egor has nothing to find; this is the only thing that
    names one. The STATE is half the answer: the gate keys its ledger on it, so a round delivers
    once per state rather than once per run — `triaged` the moment its triage is on record, then
    the finished one, with the blocked round Egor forks on in between where the pass stopped.

    A finished round is named only inside the window `pending-report` asks in, because an old
    run's report is about a diff that has since moved. A `triaged` one is named only while its
    TRIAGE is that young — `delivery_state`'s own window — and a round whose pass never answered
    past it is named at NO age: a fallback that promoted such rounds is what handed the Stop gate
    39 pre-fixes-mechanism runs in a single message (2026-08-20). Such a run is reported only when
    the model asks for it by hand.

    Read-only — nothing is marked here — but the gate's own ledger is honoured: a `(run, state)`
    it already names reached Egor and is pending nowhere, this listing and the statusline anchor
    built on it included.
    """
    session = str(args.session or "").strip()
    if not session:
        raise ValueError("--session names the chat whose runs to answer for")
    for run_dir, state in pending_delivery_rows(session):
        print(f"{run_dir.name} {state}")
    return 0


def pending_delivery_rows(session):
    """`cmd_pending_delivery`'s answer as `(run_dir, state)` pairs, in print order."""
    from . import debt as _debt  # here and not at module top: debt imports this module at load
    ledgers = {}
    rows = []
    benches = _store.state_dir() / "benches"
    now = datetime.now(timezone.utc)
    for run_dir in sorted(benches.iterdir()) if benches.exists() else ():
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict) or str(meta.get("session") or "") != session:
            continue
        if not _store.run_triaged(run_dir):
            continue
        finished = _store.parse_iso_timestamp(meta.get("finished") or meta.get("finished_at"))
        if finished is None:
            continue
        forked = _store.parse_iso_timestamp((read_fork(run_dir) or {}).get("at"))
        if forked is not None and (now - forked).total_seconds() <= _store.TRIAGE_GATE_HOURS * 3600:
            rows.append((run_dir, "fork"))
        state = delivery_state(run_dir)
        # A pass that has not answered is left alone whatever its age: the fixer may be mid-pass
        # and the report is about to change, and past that it is a report about a diff that moved.
        if state is None:
            continue
        # A triaged round rides `delivery_state`'s window on the triage instant, and NO queued
        # mark ever exempts it: promoted past a window, 39 pre-fixes-mechanism runs rendered into
        # one message at once (2026-08-20).
        if state == "triaged":
            rows.append((run_dir, state))
            continue
        mark = delivery_mark(run_dir)
        # A queued round is named at ANY age. The window is a bound on runs nobody has looked at:
        # once `settle-delivery` has established that this report was never handed over and that
        # the chat it is owed to still exists, its age is the reason to deliver it, not to stop.
        # The mark answers for the STATE it was written against: a re-adjudication moves a round
        # back through `pending`, and the report it reaches next is not the one settled there.
        # A round written off as lapsed is out of the queue whatever else the mark says. It keeps
        # the queued instant it was owed under — that is the record of how long nobody took it —
        # so read on `queued` alone a queue that RAN OUT would go on exempting its round from the
        # window for ever, which is the silence `DELIVERY_QUEUE_LAPSE_S` exists to end.
        queued = (mark.get("queued") and mark.get("state") == state
                  and not mark.get("lapsed"))
        if not queued and (now - finished).total_seconds() > _store.TRIAGE_GATE_HOURS * 3600:
            continue
        # The net discards outright any line whose state is not one it knows, so a state this loop
        # could name and that vocabulary does not hold would be delivered to nobody at all.
        if state not in DELIVERY_STATES:
            continue
        rows.append((run_dir, state))
    # The ledger is the one record a report reached Egor (docs/shared-invariants.md row `au`):
    # unread, a delivered `triaged` round stayed "pending" for the rest of its window and the
    # anchor held the statusline on a finished review.
    return [
        (run_dir, state) for run_dir, state in rows
        if not _debt.ledger_delivered(session, run_dir.name, state, ledgers)
    ]


def run_repos(meta):
    """The repositories a run read: a merged panel's members, else the run's own."""
    members = [
        str(entry.get("repo")) for entry in meta.get("repos") or ()
        if isinstance(entry, dict) and entry.get("repo")
    ]
    return members or [str(meta.get("repo") or "")]


def live_progress_run_ids(session):
    """Run ids with a progress document this chat launched whose process is still alive."""
    directory = _store.state_dir() / _store.PROGRESS_DIR
    now = time.time()
    run_ids = set()
    for path in directory.iterdir() if directory.is_dir() else ():
        try:
            document = json.loads(path.read_text())
            if not isinstance(document, dict):
                continue
            # Row `an`'s precedence, the same one the statusline reader applies: the recorded
            # session first, the pid walk only for a document written before a session was
            # recorded — else a run this chat started is dropped from this chat's own counter.
            recorded = document.get("session")
            if recorded:
                if recorded != session:
                    continue
            elif _store.walk_launching_session(int(document["pid"])) != session:
                continue
            mtime = path.stat().st_mtime
            if now - mtime > 7200:
                continue
            # The statusline reader's liveness rule, on triage_delegated's machinery (`ps`, never
            # a signal probe — shared-invariants row `ar`): the pid must be alive AND its process
            # must have started no later than the file's last write, which a pid recycled after
            # the run died cannot satisfy. `ps` failing on every pid is a sandbox, not death.
            elapsed = pid_elapsed_seconds(int(document["pid"]))
            if elapsed is None:
                if pid_elapsed_seconds(1) is not None:
                    continue
            elif now - elapsed > mtime + DELEGATED_PID_SLACK:
                continue
        except (OSError, ValueError, TypeError, KeyError):
            continue
        if document.get("run_id"):
            run_ids.add(str(document["run_id"]))
    return run_ids


def session_anchor_run(session):
    """The run this chat still has in front of it: the newest one in flight — a live run outranks
    any merely-pending one, since the counter rendering beside the folder is its — else the newest
    whose round is unanswered (`pending-report` / `pending-delivery` name it). None when the chat
    owes nothing.
    """
    benches = _store.state_dir() / "benches"
    live = live_progress_run_ids(session)
    pending = {run_dir.name for run_dir, _ in pending_delivery_rows(session)}
    fallback = None
    for run_dir in sorted(benches.iterdir(), reverse=True) if benches.exists() else ():
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict):
            continue
        launcher = str(meta.get("session") or "")
        if launcher:
            if launcher != session:
                continue
        # Meta stamps the session from the environment alone, while the progress writer also
        # walks the pid chain (shared-invariants row `an`: recorded session first, walk as the
        # fallback): a run whose meta names nobody is still this chat's where its live progress
        # document says so — and, having no recorded launcher to answer for it, nobody else's.
        elif run_dir.name not in live:
            continue
        if run_dir.name in live:
            return run_dir, meta
        if fallback is None:
            if run_dir.name in pending:
                fallback = (run_dir, meta)
            else:
                owed = triage_pending_run(run_repos(meta)[0], session)
                if owed is not None and owed[0] == run_dir:
                    fallback = (run_dir, meta)
    return fallback


def cmd_review_anchor(args):
    """Print the repository the statusline's folder segment must show for this chat: `<repo>`,
    or `<repo> +N` for a merged panel, where the member equal to `--cwd`'s repository wins and the
    first member stands otherwise. Exit 1 when no review is in front of the chat.
    """
    session = str(args.session or "").strip()
    if not session:
        raise ValueError("--session names the chat whose review to anchor on")
    found = session_anchor_run(session)
    if found is None:
        return 1
    repos = run_repos(found[1])
    anchor = repos[0]
    cwd_common = _store.git_common_dir(args.cwd) if args.cwd else None
    if cwd_common is not None:
        for candidate in repos:
            if _store.git_common_dir(candidate) == cwd_common:
                anchor = candidate
                break
    print(anchor if len(repos) == 1 else f"{anchor} +{len(repos) - 1}")
    return 0


def handoff(run_id, paths, members=None, worktree=False, fixable=True):
    verdict_path = verdict_scratch_path(run_id)
    # A commit-point review is handed the reporting command and nothing else. The corpus form
    # printed beside it is what a chat copied — the run then went to the corpus, and with it to
    # the two-judge contract that belongs to a benchmark and not to a round of fixes.
    command = (
        f"review-bench record {shlex.quote(run_id)}"
        + (" --no-corpus" if worktree else "")
        + f" --verdicts {shlex.quote(verdict_path)}"
    )
    fixes_blocked = (
        f"review-bench fixes {shlex.quote(run_id)} --blocked {shlex.quote('P1 threshold')}"
    )
    print("\nADJUDICATION HANDOFF — STEP 1 of 2: blind triage. Fix nothing in this pass; the "
          "fixing pass is dispatched separately, off the brief `record` prints when the verdicts "
          "land.")
    print("Orchestrator: hand this brief to a FRESH worker session, never the one that authored "
          "the changes under review — a session judging its own work confirms nothing.")
    print("Read these files without revealing one rater's output to another:")
    for path in paths:
        print(f"  {path}")
    if members:
        print("This review spans several repositories: each finding names its own in a repo field, "
              "and its path starts with the same prefix.")
        for member in members:
            print(f"  {member['label']}/ = {member['repo']}")
    print("Merge and deduplicate the findings blind. Write one verdict per zero-based finding "
          "index as {rater, idx, verdict}, where verdict is confirmed, false_positive, or duplicate.")
    print("Raters overlap: the same file plus the same function or defect is ONE defect however "
          "many of them reported it — confirm it once and mark every other rater's copy duplicate.")
    print(f"Record exactly with: {command}")
    if not fixable:
        # A durable bench run judged a snapshot the checkout is already past — a historical commit,
        # a range that ended before HEAD. Its confirmed findings are about content nobody is
        # standing on, so a step 2 over them edits whatever the current tree holds at those paths.
        print("\nThat is the whole round: this run reviewed a snapshot the checkout has moved "
              "past, so its findings are not about the code in front of you. No fixing pass "
              "follows, and no fix status is recorded.")
        return
    # Counted per repository for a merged panel, the way the gate that prices the round counts them
    # (`escalation_numbers`): handed the whole panel's P1s, three findings spread over three
    # repositories would stop the pass over a threshold no member reached.
    stop_scope = " in ANY ONE of the repositories above" if members else ""
    print(f"\nTHRESHOLD STOP — {HANDOFF_P1_STOP} or more confirmed P1s{stop_scope}: record the "
          f"verdicts as above, record the fix status as blocked with `{fixes_blocked}`, then stop "
          "and report back with the P1 list — no fixing pass is dispatched. At that count the "
          "second review is mandatory and the waiver over this work is withheld until it runs; a "
          "round that earns one on its tally alone instead is owed it by default and may be "
          "waived with a reason on record.")
    # Asked of the CHAT and not of this round's members: one panel per chat is a rule about what
    # gets launched, and a round telling a chat to run the bare command in each repository is a
    # split panel arranged by the very surface that forbids it.
    from . import debt as _debt  # here and not at module top: debt imports this module at load
    second = _debt.debt_chat_review_command(
        _store.caller_chat(), [member["repo"] for member in members] if members else ()
    )
    print(f"Run that second review once with `{second}` (raise the tier if the work deserves "
          "it): it computes its own scope, which is this round's full "
          "scope plus the fixes — the round that owed it is reopened, so its whole scope re-enters "
          "the diff and nothing is picked by hand.")
    print("Orchestrator: at that threshold the next move is Egor's fork decision. A session "
          "running in maximum autonomy never pauses for it — it takes the decision itself.")
    print("\nSTEP 2 is a pass of its own, briefed by `record`: fix the confirmed findings and "
          "COMMIT — the commit closes the pass and covers what it carried, so there is no second "
          "command to remember. The brief naming what it fixes cannot be written before the "
          "triage says what survived.")


def round_fixable(meta):
    """Whether a fixing pass over this round's confirmed findings edits the code the panel read.

    The same question the panel's own handoff asks before it offers a step 2, asked again at
    `record` because that is where the fixing brief is written now.
    """
    worktree = meta.get("worktree") is True
    members = [row for row in meta.get("repos") or () if isinstance(row, dict)]
    if members:
        targets = [(Path(str(row.get("repo") or ".")), str(row.get("commit") or ""),
                    worktree and not row.get("head")) for row in members]
    else:
        repo = Path(str(meta.get("repo") or "."))
        sha = str(meta.get("commit") or "")
        # A sealed range wears the worktree flag — it is sealed the same way — and the flag alone
        # would answer this yes without asking, offering a fixing pass over commits the checkout
        # has moved past. The exclusion `cmd_run` makes when it stamps receipts, made again here;
        # a repository that cannot be asked fails open, exactly as the reader below does.
        try:
            ranged = _scope.is_range_snapshot(repo, sha)
        except OSError:
            ranged = False
        targets = [(repo, sha, worktree and not ranged)]
    return all(_store.reviews_current_tree(repo, sha, flag) for repo, sha, flag in targets)


def fix_worker_recommendation(severities):
    """One line on what shape of worker the confirmed findings are: priced on severity, which is
    the only thing on record about them, and left as a recommendation because the reader has the
    findings themselves in front of it."""
    if _store.counted_int(severities.get("P1")):
        return ("recommend a strong worker: a confirmed P1 is a judgment call about the design "
                "under it, and a fast model reproduces the defect inside its own fix")
    if _store.counted_int(severities.get("P2")):
        return ("recommend a fast worker, after reading the P2s: they are usually mechanical, and "
                "the ones that turn out to be design calls are worth a strong one")
    return "recommend a fast worker: P3 findings are mechanical edits"


def fix_handoff_lines(run_dir, meta, verdicts):
    """The round's second brief: what survived triage, under which constraints it gets fixed, and
    where the outcome is recorded.

    Printed by `record` and never by the panel. The panel cannot write it — it does not know what
    survived, and a fixing brief handed out beside raw findings names a count nobody has judged.
    Two briefs also make the two passes two dispatches, which is the point: the blind pass must not
    be the pass that fixes what it just confirmed.

    A round with nothing confirmed gets none of it: there is nothing to fix, and its fix status
    goes straight to done with no receipt to record.
    """
    confirmed = confirmed_count(verdicts)
    if not confirmed or round_state(run_dir, verdicts) == "done" or not round_fixable(meta):
        return []
    run_id = run_dir.name
    severities = _panel.bench_summary(run_dir, meta, verdicts)["severities"]
    tally = " · ".join(
        f"{level} {severities[level]}" for level in ("P1", "P2", "P3") if severities.get(level)
    )
    p1s, _ = escalation_numbers(run_dir, meta, verdicts)
    head = f"\nFIX HANDOFF — STEP 2 of 2: {confirmed} confirmed"
    lines = [f"{head} ({tally})" if tally else head]
    if p1s >= HANDOFF_P1_STOP:
        lines.append(
            f"THRESHOLD STOP — {p1s} confirmed P1s: fix NOTHING and dispatch no fixing pass. "
            "Record the stop with: "
            f"review-bench fixes {shlex.quote(run_id)} --blocked {shlex.quote('P1 threshold')}"
        )
        from . import debt as _debt  # here and not at module top: debt imports this module at load
        lines.append(
            "Then report back with the P1 list: the second review over the full original scope "
            "plus the fixes is mandatory, the waiver over this work is withheld until it runs, "
            f"and it is `{_debt.debt_chat_review_command(_store.round_session(run_dir), run_repos(meta))}`. "
            "Run that command once for the round."
        )
        return lines
    lines.append("Orchestrator: this is a dispatch of its own, not the triage pass above.")
    lines.append(
        "Fix every confirmed finding. Run the test suites covering what you touched in every "
        "repository. Mutation-verify each new test assert: revert the code it guards, confirm the "
        "assert fails, restore it. Neither commit nor stage anything — leave the work in the tree."
    )
    lines.append(
        "Nothing else is recorded: the COMMIT that later carries these fixes is what closes the "
        "round and covers what it landed. A tally for the report is optional — "
        f"review-bench fixes {shlex.quote(run_id)} --done --fixed <N> --fp <M>"
    )
    lines.append(fix_worker_recommendation(severities))
    return lines


def emit_fix_handoff(run_dir, meta, verdicts):
    for line in fix_handoff_lines(run_dir, meta, verdicts):
        print(line)


def commit_mode_command(args):
    tier = getattr(args, "tier", None)
    if tier:
        command = ["review-bench", "review", "HEAD", "--tier", tier]
        if getattr(args, "max", False):
            command.append("--max")
        # No --foreground: a review detaches its own panel, so the flag is the test harness's way
        # back in-process and never advice to a caller who has to type this line.
        if args.verify:
            command += ["--verify", args.verify]
        # A refusal the reproduce line cannot express is a refusal it ignores: replaying without
        # it verifies findings the run it claims to reproduce reported raw.
        elif getattr(args, "no_verify", False):
            command.append("--no-verify")
    else:
        command = ["review-bench", "run", "HEAD"]
        if args.raters:
            command += ["--raters", args.raters]
        elif args.auto:
            command += ["--auto", str(args.auto)]
        elif args.leg:
            command.append("--leg")
        if getattr(args, "foreground", False):
            command.append("--foreground")
    for path, spec in _scope.repo_sources(args):
        if path == "." and not spec:
            continue
        command += ["--repo", str(Path(path).resolve()) + (f"@{spec}" if spec else "")]
    if args.focus:
        command += ["--focus", args.focus]
    if getattr(args, "lens", ""):
        command += ["--lens", args.lens]
    return shlex.join(command)
