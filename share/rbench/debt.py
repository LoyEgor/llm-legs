import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from chat_names import chat_label, store_names, worker_run_launchers, worker_session_launchers

from . import store as _store
from . import accounts as _accounts
from . import scope as _scope
from . import panel as _panel
from . import round as _round

# The reason the commit gate prints in its paste-ready waive command. A caller that pastes it
# unedited records the placeholder as the decision, which is a waiver saying nothing at all — so it
# is the one reason this tool refuses. Held equal to the gate's own literal by
# docs/shared-invariants.md.
WAIVE_PLACEHOLDER_REASON = "WHY THIS GOES UNREVIEWED"
# Above this many diff lines a `--debt` review launches nothing until the caller names the size.
# The mode computes its own scope, so nobody chooses it and nobody reads it before the panel does:
# one chat took a sweep of 11.9k lines for an 84-line edit and spent forty minutes on twenty
# findings in code it had never touched (live case 2026-08-24). The number is not a ceiling on what
# may be reviewed — `--scope-lines <n>` matching what this printed proceeds — it is what turns a
# sweep into a decision somebody made. Held equal to its docs/shared-invariants.md row by
# tests/test_consistency.sh.
DEBT_SCOPE_LINES_MAX = 3000
# How much of an over-size scope the refusal itemises. The list is there to be READ before the
# number is typed back, and a hundred rows is a scroll nobody reads.
DEBT_SCOPE_ROWS_SHOWN = 20
# The ledger claude-setup's two report hooks write and read, and the only record that a round's
# report ever reached Egor: one key per line under `$XDG_CACHE_HOME/claude/review-delivery`, of
# which `run:<id>:<state>` is the one a run can be looked up by. Read-only here — a diagnostic
# that wrote a key would retire a report nobody has seen. Held equal to the hooks' own spelling by
# docs/shared-invariants.md.
DELIVERY_LEDGER_DIR = ("claude", "review-delivery")
DELIVERY_LEDGER_SUFFIX = ".emitted"
DELIVERY_LEDGER_KEY = "run:{run_id}:{state}"
# How long each of `doctor`'s aged anomalies must have stood before it is one, spelled once and
# nowhere else. Every one of them is a silence: a record some mechanism should have moved on and
# did not, and the age is what tells a mechanism that failed from one still working. The two
# classes with no entry here — debt nobody owns, a panel that completed nothing and was never
# marked killed — are answered by their shape alone and have no clock to run.
DOCTOR_AGES_S = {
    # Well past the Stop gate's three asks, so what stands here is a triage nobody will do.
    "untriaged": 18 * 3600,
    # The triage gate's own window, derived from it and never respelled: past it no hook will ever
    # hand that report over, so a literal here would go on asking after the window had moved.
    "undelivered": _store.TRIAGE_GATE_HOURS * 3600,
    "stuck_fixes": 48 * 3600,
}
# How far back the RUN-level classes above look. Their subject is a record somebody could still
# act on: nobody triages a panel from last month, delivers its report or fixes its round, and a
# count that only ever grows is not a statistic — it says the same thing every time it is read,
# including about mechanisms that did not exist when those runs were written. The two classes
# about the tree as it stands now — debt in front of the reader, a panel that produced nothing —
# are not bounded by it and never go quiet on their own.
DOCTOR_WINDOW_S = 14 * 24 * 3600
# How long a QUEUED report stays owed before `settle-delivery` writes it off. Queueing hands a
# round to the launching chat's next stop, and a chat that never stops again — closed, but with its
# transcript still on disk, which is the state `session_transcript_exists` cannot tell from a live
# one — holds it for ever: 24 rounds from a nine-day span sat `queued` and undelivered through the
# whole doctor window (live 2026-08-24). The round stays readable under `doctor --lapsed` exactly
# as one whose transcript is already gone.
DELIVERY_QUEUE_LAPSE_S = 7 * 24 * 3600
DOCTOR_CLASSES = (
    "untriaged", "undelivered", "stuck_fixes", "orphan_debt", "kill_asymmetry",
)
# A line and never a sixth class: the five above are the menubar's whole vocabulary
# (docs/shared-invariants.md row `av`), and a round past the budget is not a silence somebody is
# late on — it is the launcher's refusal having failed, which no age and no count can qualify.
DOCTOR_ROUND_OVERFLOW = "rounds_past_two"
# The document the collector writes and the menubar reads; its schema is fixed by
# docs/shared-invariants.md, because the renderer has no other way to learn a class name.
DOCTOR_SNAPSHOT = "doctor-snapshot.json"
DOCTOR_DETAIL_LINES = 10
DOCTOR_AGENT_LABEL = "com.llm-legs.review-doctor"
DOCTOR_AGENT_INTERVAL_S = 6 * 3600
# What launchd is pointed at. A LaunchAgent's visible program is what macOS Login Items names it
# by, so it is a wrapper carrying a descriptive name of its own, exactly as llm-selfcheck's is —
# never a bare interpreter, and never the PATH symlink a human types.
DOCTOR_AGENT_WRAPPER = (".local", "libexec", "review-doctord")
RUN_CONFIRMED_COUNTS = {}
# Per repository, the paths review debt is never asked about: gitignore-style patterns, committed
# with the checkout, because what is worth a panel's minutes is a property of the project and not
# of whoever is looking. Never priced, never listed, never in a `--debt` scope. Held to one
# spelling by docs/shared-invariants.md.
DEBT_IGNORE_FILE = ".claude/review-debt-ignore"
# How many lines of debt a path carries, keyed by the two contents that decide it and nothing else,
# so an entry can never answer for a pair it was not measured on. It is what keeps `debt --split`
# inside the statusline's budget: without it every render diffs every debt path afresh.
DEBT_LINE_CACHE_FILE = "debt-lines.json"
# Trimmed to the newest half when it grows past this: entries are keyed by content and nothing ever
# invalidates one, so a checkout edited for months would otherwise carry every blob it ever held.
DEBT_LINE_CACHE_MAX = 4096
# Written out every this many fresh measurements and not at the end alone: the gate asks this under
# a timeout, and a first pass over a cold cache killed before its last path would otherwise persist
# nothing at all and start again from zero on the render after it.
DEBT_LINE_CACHE_BATCH = 32
# How far BEFORE a journal stamp the commit it records may sit. The debt journal is appended by the
# post-commit hook, so its epoch follows its own commit by however long that hook takes — asked from
# the stamp exactly, the pricing below missed the very commit the record is about (live 2026-08-24:
# a stamp 4 seconds late read a committed contract file as 0 lines of debt).
JOURNAL_STAMP_GRACE_S = 600
DEBT_LINE_CACHE = None
def cmd_settle_delivery(args):
    """Put every deliverable round no ledger names back in front of the chat that launched it, and
    write off the ones whose chat is gone.

    The delivery window is a bound on reports nobody has looked at; it is not a verdict that an
    older one is not owed. A chat whose stop never came inside it — it was closed, it was
    compacting, the mechanism did not exist yet — leaves its round marked `done` on disk and
    delivered nowhere, which is the count `doctor` reports as `undelivered` (18 of them, some 12
    days old, when this was written). Each is settled one of two ways and never a third: queued,
    so the launching chat's next stop hands it over whatever its age, or lapsed with the instant,
    because the transcript that stop reads is gone — or because the queue itself has stood past
    `DELIVERY_QUEUE_LAPSE_S`, which is the same dead chat wearing a transcript nobody deleted.
    Nothing is dropped silently — a lapsed round keeps its own listing under `doctor --lapsed`.
    """
    # At no window: the scan's fortnight is a bound on what a reader is asked to look at, and the
    # rounds this command exists for are precisely the ones that outlived it — 18 of them, some 12
    # days old, when it was written. Windowed, they would fall out of reach two days later and be
    # neither queued nor written off, which is the silence the docstring above promises to end.
    findings = doctor_scan(undelivered_window=float("inf"))
    benches = _store.state_dir() / "benches"
    queued, lapsed = [], []
    for row in findings["undelivered"]:
        run_id, state = row["what"].split()[:2]
        run_dir = benches / run_id
        try:
            session = str(json.loads((run_dir / "meta.json").read_text()).get("session") or "")
        except (OSError, ValueError):
            continue
        # A queue that has already stood a week is the same dead end a missing transcript is: the
        # chat kept its file and never stopped again, so requeueing it says `undelivered` for ever.
        # The queued instant is kept beside the write-off — it is the record of how long the round
        # was actually owed, and the listing is the only place anybody reads it now.
        held = _round.delivery_mark(run_dir)
        standing = held.get("state") == state and str(held.get("session") or "") == session
        queued_at = held.get("queued") if standing else None
        queued_on = _store.parse_iso_timestamp(queued_at)
        stale = queued_on is not None and \
            (_store.utc_now() - queued_on).total_seconds() > DELIVERY_QUEUE_LAPSE_S
        alive = _round.session_transcript_exists(session) and not stale
        mark = {"state": state, "session": session}
        mark["queued" if alive else "lapsed"] = _store.iso_now()
        # The instant a queue began is the ROUND's, never this pass's. This command runs from every
        # stop, so restamping a standing queue here would hold it permanently seconds old and no
        # round would ever reach `DELIVERY_QUEUE_LAPSE_S`.
        if queued_at is not None:
            mark["queued"] = queued_at
        (queued if alive else lapsed).append((run_id, state, session))
        if not args.dry_run:
            (run_dir / _store.DELIVERY_MARK).write_text(json.dumps(mark, sort_keys=True) + "\n")
    for label, rows in (("queued", queued), ("lapsed", lapsed)):
        verb = ("would queue" if label == "queued" else "would lapse") if args.dry_run else label
        for run_id, state, session in rows:
            print(f"{verb} {run_id} {state} {session}{_store.chat_suffix(session)}")
    prefix = "would settle" if args.dry_run else "settled"
    print(f"{prefix}: {len(queued)} queued, {len(lapsed)} lapsed")
    return 0


def waiver_file(repo):
    name = _store.receipt_file_name(repo)
    return None if not name else _store.state_dir() / _store.WAIVER_DIR / name


def waiver_files(repo):
    """Every waiver file of this repository's FAMILY. A waiver names one checkout in the hash
    after its first field, so a waiver a worktree recorded answers for the main checkout like any
    other artifact — but the first field is only a directory NAME, which unrelated clones share,
    so membership is decided by the family each file records, never by the glob that found it.
    This checkout's own file needs no record: its name is derived from this very path.
    """
    directory = _store.state_dir() / _store.WAIVER_DIR
    identity = _store.repo_identity(str(repo))
    if not identity or not directory.is_dir():
        return []
    family = _store.repo_family(str(repo))
    own = waiver_file(repo)
    files = []
    for path in sorted(directory.glob(f"{identity}__*.json")):
        if own is not None and path == own:
            files.append(path)
            continue
        if family is None:
            continue
        try:
            stored = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        recorded = stored.get("family") if isinstance(stored, dict) else None
        if recorded == str(family):
            files.append(path)
    return files


def read_waivers(repo):
    rows = []
    for path in waiver_files(repo):
        try:
            stored = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        entries = stored.get("waivers") if isinstance(stored, dict) else None
        rows.extend(row for row in entries or () if isinstance(row, dict))
    return rows


def fix_coverage_artifact(run_dir, repo, family=None):
    """The artifact a clean round's done receipt is for `repo`, or None where it covers nothing
    there.

    The receipt's own `covers` block: the fix-step bytes that round wrote, at the shas they stood
    at when it was recorded, so the next edit over them is debt again exactly as it is over a
    waiver's. Read through `round_state` and never off the receipt's raw state — a re-adjudication
    that leaves the receipt answering another triage takes its coverage back with it. Against the
    recorded fingerprint as well, because `round_state` calls a round with nothing confirmed done
    whoever answered it: re-adjudicated to all false positives, a round would otherwise keep the
    coverage its first triage bought.

    `covering` answers too: the leg that landed carried its bytes in a commit, and read as
    unfinished they came back as debt the moment they landed.
    """
    record = _round.read_fix_status(run_dir)
    if not isinstance(record, dict):
        return None
    named = [
        (entry, str(entry.get("repo") or ""))
        for entry in record.get("covers") or () if isinstance(entry, dict)
    ]
    # The exact working tree first, exactly as `run_repo_record` matches a merged panel's members:
    # a family sibling's entry read in file order would cover this checkout with the member that
    # read the other one.
    entry = next(
        (entry for entry, recorded_repo in named
         if recorded_repo and _store.resolved_repo_path(recorded_repo) == repo),
        None,
    ) or next(
        (entry for entry, recorded_repo in named
         if recorded_repo and family is not None
         and _store.repo_family(recorded_repo) == family),
        None,
    )
    if entry is None:
        return None
    shas = entry.get("paths")
    rows = _round.recorded_verdict_rows(run_dir)
    if not isinstance(shas, dict) or not shas or \
            _round.round_state(run_dir, rows) not in ("done", "covering"):
        return None
    if record.get("triage") != _round.triage_digest(rows):
        return None
    recorded = _store.parse_iso_timestamp(record.get("recorded_at"))
    return {
        "kind": "fixes", "id": f"{run_dir.name}+fixes", "dir": run_dir,
        "epoch": int(recorded.timestamp()) if recorded else _store.run_id_epoch(run_dir.name),
        "shas": {
            path: sha for path, sha in shas.items()
            if isinstance(path, str) and isinstance(sha, str)
        },
    }


def repo_artifacts(repo):
    """Everything that answers for a path of this working tree, oldest first: the snapshot of every
    triaged run that read it, every waiver recorded against it, and the fix bytes of every round
    that closed under the gate's thresholds.

    One kind of answer out of three sources — a review read the content, a chat said out loud that
    it is going unreviewed and why, or a round nobody will review again wrote it while answering
    findings that were reviewed. Nothing here reads git history: a shared checkout takes commits
    from other chats continuously, and a history-shaped answer retires a live review over work it
    never read.

    Gathered across the whole checkout FAMILY, and answering for every checkout of it.
    """
    artifacts = []
    benches = _store.state_dir() / "benches"
    resolved = _store.resolved_repo_path(repo)
    # Why family-wide: a review launched in a worktree records that worktree as its repository,
    # while the paths it read are repository-relative and are the main checkout's own files once
    # the branch lands. Read per checkout, main compared those files against its own older run and
    # reported 11k ghost debt lines over code a worktree panel had read (live, 2026-08-23).
    family = _store.repo_family(repo)
    for run_dir in sorted(benches.iterdir()) if benches.exists() else ():
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            # The bench directory is shared and pruned while this walks it, and the answer must
            # not turn on which unrelated run was half-written at the time.
            continue
        if not isinstance(meta, dict):
            continue
        record = _store.run_repo_record(resolved, meta, family=family)
        if record is None or not _store.run_triaged(run_dir):
            continue
        reviewed = record.get("reviewed")
        # A run holding no snapshot read committed code: nothing in the working tree is anchored to
        # it, so it answers for no path at all.
        if not (isinstance(reviewed, dict) and reviewed):
            continue
        artifacts.append({
            "kind": "run", "id": run_dir.name, "epoch": _store.run_id_epoch(run_dir.name), "dir": run_dir,
            "shas": {
                path: sha for path, sha in reviewed.items()
                if isinstance(path, str) and isinstance(sha, str)
            },
        })
        covered = fix_coverage_artifact(run_dir, resolved, family)
        if covered:
            artifacts.append(covered)
    for waiver in read_waivers(repo):
        shas = waiver.get("paths")
        if not isinstance(shas, dict):
            continue
        artifacts.append({
            "kind": "waiver", "id": str(waiver.get("id") or ""),
            "epoch": _store.counted_int(waiver.get("epoch")), "dir": None,
            "session": str(waiver.get("session") or ""),
            "reason": str(waiver.get("reason") or ""),
            "shas": {
                path: sha for path, sha in shas.items()
                if isinstance(path, str) and isinstance(sha, str)
            },
        })
    artifacts.sort(key=lambda item: (item["epoch"], item["id"]))
    return artifacts


def artifact_owes_second_round(artifact):
    """Whether a round 2 is owed over this round, so its whole scope re-enters the `--debt` diff.

    One record answers it: the DECISION. `simplify`, `cut` and `redesign` each name a second pass
    over the full original scope plus the fixes; `fix` names none, and a round still owing its
    decision names none either — no fixing pass may start before it is recorded, so nothing has
    moved that a second pass would read.
    """
    if not artifact or artifact["kind"] != "run":
        return False
    if _round.round_budget_spent(artifact["dir"]):
        return False
    decision = _round.read_fork(artifact["dir"])
    return bool(decision) and decision["choice"] != _round.BAND_FIX


def reopened_round_stands(repo, path, artifact):
    """Whether a round a decision reopened still holds `path` back.

    A path that is GONE is held by nothing: no snapshot a later run writes can hold it, and a
    fixing pass that deletes a file it reviewed — which is what `cut` names — would otherwise wedge
    that round open over a path no review could ever answer for again.
    """
    return artifact_owes_second_round(artifact) and os.path.lexists(Path(repo) / path)


def reopened_round_released(repo, reopened, artifact):
    """Whether `artifact` takes a path back from the round `reopened` reopened.

    A RUN does so only by being the second pass itself — holding every path of that round's scope
    that still stands in the working tree — because a one-path rerun answering for a corner of it
    would retire the full second review the decision named. A waiver does so path by path: it is a
    chat saying out loud that this content goes unreviewed and why, which is the one other answer a
    scope can have, and refused here it would be recorded, reported as `waived N path(s)` and then
    silently disregarded by the very scope it was written to shrink.
    """
    if artifact["kind"] == "waiver":
        return True
    if artifact["kind"] != "run":
        return False
    surviving = {path for path in reopened["shas"] if os.path.lexists(Path(repo) / path)}
    return surviving <= set(artifact["shas"])


def covering_artifacts(repo, ignoring=(), artifacts=None):
    """The newest artifact holding each path — the one thing a path's current content is compared
    against.

    `ignoring` names run ids whose own answer must not be read, which is how a second round re-
    enters the full scope of the round that owed it (`debt_review_scope`). Nothing outside that
    scope passes it: the debt every other reader sees is the debt as the artifacts left it.

    A round a decision reopened is the exception, and it is released WHOLE or not at all — see
    `reopened_round_released`.
    """
    covering = {}
    for artifact in repo_artifacts(repo) if artifacts is None else artifacts:
        if artifact["id"] in ignoring:
            continue
        for path in artifact["shas"]:
            standing = covering.get(path)
            if reopened_round_stands(repo, path, standing) and not reopened_round_released(
                repo, standing, artifact
            ):
                continue
            covering[path] = artifact
    return covering


def reviewed_shas(artifacts, repo):
    """Every content these artifacts still answer for, under whatever path each read it: a file
    somebody moved carries its review with it, and the deleted-path sha is nothing at all.

    Per path, the NEWEST record alone — a sha an older artifact read and a later one moved past is
    superseded content, current nowhere. And never the empty blob: every empty file is
    byte-identical, so one reviewed `__init__.py` would answer for placeholders no panel ever saw.
    """
    newest = {}
    for artifact in artifacts:
        for path, sha in artifact["shas"].items():
            newest[path] = sha
    empty = _store.content_blob_sha(repo, b"")
    return {sha for sha in newest.values() if sha and sha != empty}


def path_holders(artifacts):
    """Every content any of these artifacts recorded UNDER EACH PATH, as `{path: {sha, ...}}`.

    Not `reviewed_shas`, which keeps the newest record per path and drops the path itself: the
    question here is whether some artifact of the family read THIS path at THIS content, which the
    newest record alone cannot answer once two checkouts of one family stand at different content.
    """
    holders = {}
    for artifact in artifacts:
        for path, sha in artifact["shas"].items():
            if sha:
                holders.setdefault(path, set()).add(sha)
    return holders


def haunted_paths(repo, candidates):
    """The candidates that are not this checkout's debt to begin with: one that is GONE from the
    working tree, since a removal leaves nothing for a panel to read, and one under another
    checkout of the family, whose own reader answers for it.

    Both are what a removed worktree leaves behind for ever — five journal records naming a tree
    nobody can open, in this repository's own `debt --list` (live, 2026-08-23). A deleted file is
    the same shape of unanswerable: priced whole against what it used to hold, three deletions in
    one worktree stood as 1952 lines of debt no review could ever read (audit, 2026-08-26).
    """
    return {
        str(path) for path in candidates
        if str(path).startswith(_store.WORKTREE_PATH_PREFIX)
        or not os.path.lexists(Path(repo) / path)
    }


def bracket_expression(pattern, index):
    r"""gitignore's `[...]` starting at `pattern[index]`, as `(regex, index past it)`, or None when
    it never closes and the `[` is the character itself.

    Read here rather than handed to `re` with its metacharacters doubled: `\` escapes inside a
    class too, so `[a\-c]` names three characters and doubled became the range `\`..`c`, which
    ignored most of the alphabet; `[\]]` ended at its own escaped bracket; and `[!-%]`, whose `-`
    is a literal, built the range `/`..`%` and raised `re.error` out of every reader of the file
    (audit, 2026-08-26). No class ever takes a separator, exactly as `*` does not.
    """
    close = index + 1
    negated = close < len(pattern) and pattern[close] in "!^"
    if negated:
        close += 1
    items = []
    while close < len(pattern):
        # A `]` first in the class is that character and not the end of it, gitignore's own
        # reading of POSIX.
        if pattern[close] == "]" and items:
            break
        low = pattern[close]
        if low == "\\" and close + 1 < len(pattern):
            low = pattern[close + 1]
            close += 2
        else:
            close += 1
        # `a-c` is a range; a `-` last in the class is the character itself.
        if close + 1 < len(pattern) and pattern[close] == "-" and pattern[close + 1] != "]":
            close += 1
            high = pattern[close]
            if high == "\\" and close + 1 < len(pattern):
                high = pattern[close + 1]
                close += 1
            close += 1
            items.append((low, high))
        else:
            items.append((low, None))
    if close >= len(pattern) or not items:
        return None
    body = []
    for low, high in items:
        if high is None:
            body.append(re.escape(low))
        elif low <= high:
            body.append(re.escape(low) + "-" + re.escape(high))
        # A descending range matches nothing in gitignore, and `re` refuses to compile one at all.
    if negated:
        return "[^/" + "".join(body) + "]", close + 1
    if not body:
        return "(?!)", close + 1
    # The lookahead is the separator rule: a class spelled as a range may hold `/` without naming
    # it, and `[.-z]` would then match across components.
    return "(?!/)[" + "".join(body) + "]", close + 1


def compile_debt_ignore(pattern):
    r"""One `.claude/review-debt-ignore` line as `(negated, regex)`, in gitignore's grammar: `!`
    negates, a trailing `/` matches a directory's contents, a `/` anywhere else anchors the pattern
    at the repository root, and `*` stops at a separator while `**` crosses them.

    `**` is gitignore's own: a whole path COMPONENT and nothing else. A leading `**/` matches in
    every directory rather than anchoring the rest at the root, `/**/` stands for zero directories
    as well as for many, and asterisks INSIDE a component (`a**b`) are the ordinary kind — read as
    crossing separators they dropped paths the project never named.

    `[...]` is a bracket expression and `\` escapes the character after it, both of them the
    grammar the docstring above promises: escaped wholesale instead, `*.py[cod]` compiled to a
    literal `[cod]` and a rule written in gitignore syntax silently ignored nothing at all
    (audit, 2026-08-26). `bracket_expression` reads the class itself, separator rule included.
    """
    negated = pattern.startswith("!")
    if negated:
        pattern = pattern[1:]
    directory = pattern.endswith("/")
    pattern = pattern.rstrip("/")
    anchored = "/" in pattern
    pattern = pattern.lstrip("/")
    while pattern.startswith("**/"):
        pattern = pattern[3:]
        anchored = False
    body = []
    index = 0
    while index < len(pattern):
        if pattern.startswith("**", index) and (index == 0 or pattern[index - 1] == "/") \
                and (index + 2 == len(pattern) or pattern[index + 2] == "/"):
            if index + 2 < len(pattern):
                # `a/**/b` names `a/b` as well, so the crossing swallows its own trailing separator.
                body.append("(?:.*/)?")
                index += 3
            else:
                body.append(".*")
                index += 2
        elif pattern[index] == "*":
            body.append("[^/]*")
            index += 1
        elif pattern[index] == "?":
            body.append("[^/]")
            index += 1
        elif pattern[index] == "\\" and index + 1 < len(pattern):
            body.append(re.escape(pattern[index + 1]))
            index += 2
        elif pattern[index] == "[":
            expression = bracket_expression(pattern, index)
            if expression is None:
                body.append(re.escape(pattern[index]))
                index += 1
            else:
                body.append(expression[0])
                index = expression[1]
        else:
            body.append(re.escape(pattern[index]))
            index += 1
    head = "" if anchored else "(?:.*/)?"
    tail = "/.*" if directory else "(?:/.*)?"
    return negated, re.compile(head + "".join(body) + tail + r"\Z")


def debt_ignore_rules(repo):
    """This checkout's `.claude/review-debt-ignore`, compiled in file order, or nothing.

    Read per call rather than memoized: the file is committed with the tree and a reader holding
    yesterday's copy would go on pricing what the project has since said it does not review.
    """
    try:
        text = (Path(repo) / DEBT_IGNORE_FILE).read_text()
    except OSError:
        return []
    rules = []
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            try:
                rules.append(compile_debt_ignore(line))
            except re.error:
                # A line `re` refuses is one rule this file does not get; it is never the reason
                # the statusline, `debt --list` and every panel behind them stop answering.
                continue
    return rules


def debt_ignored(repo, candidates, rules=None):
    """Which of `candidates` this repository's ignore file drops, as a set of path strings.

    Last matching pattern wins, as gitignore's does, so a `!` line after a broad one takes its
    paths back.
    """
    rules = debt_ignore_rules(repo) if rules is None else rules
    if not rules:
        return set()
    dropped = set()
    for path in candidates:
        name = str(path)
        verdict = False
        for negated, regex in rules:
            if regex.match(name):
                verdict = not negated
        if verdict:
            dropped.add(name)
    return dropped


def priceless_paths(repo, debt, shas=None, bases=None):
    """The debt paths a review could read nothing in: the base every price and every panel is built
    from is the very content standing there, so the diff is empty.

    A journal or a run record names a path, no artifact holds it, and `debt_base_blobs` resolves
    base == current — so `debt` counted it, `--list` printed it, and a panel scoped to it would be
    handed nothing. 131 such paths stood across four checkouts on the night this was written, and
    they are why the count never reached zero even where every line had been answered (audit,
    2026-08-26).

    Told by the two SHAS and not by a line count: a binary and a path `.gitattributes` marks
    `-diff` both price zero lines while holding content nobody has read, and dropped on the number
    a minified bundle would escape review by being unreadable.

    `bases` is filled with the base of every path examined, for the caller that prices those same
    paths next: base resolution runs `git log --first-parent` plus a `git rev-parse` per clean
    path, no cache covers it, and spelled twice the statusline paid for it once here and once more
    in `debt_line_counts` on every render.
    """
    if not debt:
        return set()
    currents = {}
    for path, _ in debt:
        name = str(path)
        current = (shas or {}).get(name)
        currents[name] = _store.path_blob_sha(repo, path) if current is None else current
    resolved = debt_base_blobs(repo, debt, shas=currents)
    if bases is not None:
        bases.update(resolved)
    return {name for name, base in resolved.items() if base == currents[name]}


def repo_debt(repo, paths=None, covering=None, shas=None, claims=None, dirty=None, reviewed=None,
              holders=None, ignored=None, bases=None):
    """The paths whose working-tree content differs from what the newest artifact holding them
    recorded, each with that artifact, as `(path, artifact)` pairs.

    `shas` is filled with the working-tree sha of every path examined, `ignored` with the
    candidates `.claude/review-debt-ignore` dropped, and `bases` with the base each debt path is
    priced from, for a caller that needs any of those answers next: this reads and hashes the file,
    resolves every base, and the debt of a repository is priced on the statusline's own path.

    Commit-agnostic while a path still stands: committing neither creates debt nor settles it,
    and only a review or a waiver does. A path that is GONE owes nothing at all — there is no
    content left to read — which is the `haunted_paths` question below. A path no artifact ever
    held is in debt whole while it exists — a run that never read it holds no content to compare,
    so covering it would be a blanket over files born after the panel read the tree.

    Two whole classes are never anybody's debt and are answered before ownership is: what the
    repository's own ignore file names, and what prices ZERO lines against the base a panel would
    read it from. Both are held out HERE and not at each printer, or the count on the statusline,
    the list `--list` prints and the scope a `--debt` review computes would each mean something
    different by the same word.

    `reviewed` is every content the family's artifacts read, and a path NO artifact holds standing
    at one of them is current: a file that moved keeps the review its bytes earned. A path some
    artifact does hold is answered by that artifact alone. `haunted_paths` drops what is nobody's
    debt here at all.

    The universe a repository-wide question asks about is what somebody RECORDED work on, and the
    worker run records are one of those stores: a run's own file list, and the dirt its workdir
    gained while it ran where the run says that list cannot be complete. Read out of the journals
    alone, work a worker did through the shell was in no count, in no `--list` and in no `--debt`
    scope until some later commit swept the run — and a merged panel scoped straight past two
    rewritten files with nothing anywhere saying it had (live case 2026-08-21). `claims` and
    `dirty` come from a caller that has already read those records, which is the whole store.
    """
    if covering is None or reviewed is None or holders is None:
        artifacts = repo_artifacts(repo)
        covering = covering_artifacts(repo, artifacts=artifacts) if covering is None else covering
        reviewed = reviewed_shas(artifacts, repo) if reviewed is None else reviewed
        holders = path_holders(artifacts) if holders is None else holders
    if claims is None:
        claims = _store.run_record_claims(repo)
    if dirty is None:
        dirty = _store.run_dirty_paths(repo)
    named = _store.journal_paths(repo) | set(claims) | set(dirty)
    candidates = list(paths) if paths else sorted(set(covering) | named)
    haunted = haunted_paths(repo, candidates)
    # Asked over what is this checkout's debt at all: run over every candidate the `ignored: N`
    # note counted deleted files and other checkouts' paths the ignore file never took out of any
    # list, and said the project's own file had removed them.
    dropped = debt_ignored(repo, [path for path in candidates if str(path) not in haunted])
    if ignored is not None:
        ignored |= dropped
    debt = []
    # Every sha this loop hashes, whether or not the CALLER asked for them: `priceless_paths` needs
    # the same answer for every path it is handed, and left to look them up itself it re-read and
    # re-hashed the whole debt of the repository on the statusline's own path.
    measured = {}
    for path in candidates:
        if str(path) in haunted or str(path) in dropped:
            continue
        artifact = covering.get(path)
        sha = _store.path_blob_sha(repo, path)
        measured[str(path)] = sha
        if shas is not None:
            shas[str(path)] = sha
        if artifact is None:
            # Only a path NOTHING holds may escape on content read elsewhere: a held one is
            # answered by its own artifact.
            if sha and sha in reviewed:
                continue
            if sha or path in named:
                debt.append((path, None))
            continue
        if sha != artifact["shas"].get(path, ""):
            # The artifacts are the checkout FAMILY's, and a family holds ONE name per path at as
            # many contents as it has checkouts: a worktree on a feature branch and its main
            # checkout each recorded this path at their own bytes, and the newer of the two
            # displaces the other's exact-match artifact here. Compared against it alone, every
            # cross-branch delta was priced as fresh debt in BOTH directions and each checkout's
            # own waiver re-opened its sibling the moment it was written (live 2026-08-24).
            # So a content some artifact of the family actually READ is not debt, wherever it was
            # read. Line pricing is untouched — a path that IS in debt still prices against the
            # newest artifact.
            if sha and sha in holders.get(path, ()):
                continue
            debt.append((path, artifact))
    priceless = priceless_paths(repo, debt, shas=measured, bases=bases)
    return [(path, artifact) for path, artifact in debt if str(path) not in priceless]


def debt_line_cache():
    """The line counts this machine has already measured, read once per process."""
    global DEBT_LINE_CACHE
    if DEBT_LINE_CACHE is None:
        try:
            loaded = json.loads((_store.state_dir() / DEBT_LINE_CACHE_FILE).read_text())
        except (OSError, ValueError):
            loaded = None
        DEBT_LINE_CACHE = {
            key: value for key, value in loaded.items()
            if isinstance(key, str) and isinstance(value, int) and not isinstance(value, bool)
        } if isinstance(loaded, dict) else {}
    return DEBT_LINE_CACHE


def save_debt_line_cache():
    """Last writer wins, and losing is free: an entry is a measurement of two contents, so a
    concurrent render's file holds the same numbers for whatever keys it shares.
    """
    entries = debt_line_cache()
    if len(entries) > DEBT_LINE_CACHE_MAX:
        for key in list(entries)[:-(DEBT_LINE_CACHE_MAX // 2)]:
            del entries[key]
    path = _store.state_dir() / DEBT_LINE_CACHE_FILE
    tmp = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
        tmp.write_text(json.dumps(entries))
        os.replace(tmp, path)
        tmp = None
    except OSError:
        pass
    finally:
        if tmp is not None:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass


def diff_suppressed_paths(repo, paths):
    """The paths this repository's attributes take out of line counting — `-diff`, which the review
    target header prices as a binary file and gives no lines at all.

    Attributes are matched against the path IN this repository, and the comparison below is of two
    files outside it, which no `.gitattributes` pattern can ever name: asked there, a minified
    bundle marked binary comes back counted as text. Their answer is also the one thing here that
    is never cached, since it belongs to a repository while the cache is keyed by content across
    every checkout on this machine.
    """
    wanted = [path for path in paths if path and "\0" not in path]
    if not wanted:
        return set()
    proc = subprocess.run(
        ["git", "check-attr", "--stdin", "-z", "diff"], cwd=repo,
        input=b"\0".join(os.fsencode(path) for path in wanted), capture_output=True,
    )
    if proc.returncode != 0:
        return set()
    fields = proc.stdout.split(b"\0")
    return {
        os.fsdecode(fields[index]) for index in range(0, len(fields) - 2, 3)
        if fields[index + 2] == b"unset"
    }


def journal_epochs(repo):
    """The EARLIEST epoch either journal recorded for each path, as `{path: epoch}`.

    It dates the first edit somebody stamped and nobody has answered for since, so every commit
    from there on is unreviewed work. A record carrying no epoch dates nothing and is left out
    rather than read as the beginning of time, which would price a file's whole history as debt.
    """
    epochs = {}
    for _, epoch, path in _store.journal_rows(repo):
        if epoch is None:
            continue
        if path not in epochs or epoch < epochs[path]:
            epochs[path] = epoch
    return epochs


def unreviewed_parent_blob(repo, path, epoch):
    """What stood under `path` before the commits nobody has read: the blob its OLDEST commit
    reaching HEAD at or after `epoch`, less the stamp grace, had in its parent. None where no such
    commit exists — nothing then says which commits are unreviewed, so the caller keeps HEAD — and
    the empty string where that commit is a root or its parent held no such path, which prices the
    file whole.

    First-parent only: a merge brings a side branch's commits in under one date, and walking into
    them would price work that landed with the branch rather than with the stamped edit.
    """
    listed = subprocess.run(
        ["git", "log", "--first-parent", "--format=%H", f"--since=@{int(epoch) - JOURNAL_STAMP_GRACE_S}", "HEAD", "--",
         *_scope.literal_pathspecs([path])],
        cwd=repo, capture_output=True, text=True,
    )
    if listed.returncode != 0 or not listed.stdout.split():
        return None
    oldest = listed.stdout.split()[-1]
    found = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"{oldest}^:{path}"],
        cwd=repo, capture_output=True, text=True,
    )
    return found.stdout.strip() if found.returncode == 0 else ""


def head_path_blobs(repo, paths):
    """The blob HEAD holds under each of `paths`, as `{path: sha}` — a path HEAD does not hold is
    absent from the answer rather than empty in it. One tree read for every path that needs one.
    """
    if not paths:
        return {}
    try:
        entries = _scope.tree_path_entries(
            repo, _scope.head_tree_hash(repo), paths, literal=True
        )
    except RuntimeError:
        return {}
    return {path: entry[1] for path, entry in entries.items()}


def debt_base_blobs(repo, debt, shas=None):
    """The LEFT side of every debt path, as `{path: sha}`, and the empty string where nothing
    readable stands behind it and the file is worth reading whole.

    The ONE answer both the price and the panel are built from: `debt_line_counts` measures the
    drift across this base and `debt_snapshot_commit` seals it as a review's base, so a panel reads
    exactly the lines the statusline counts. Spelled twice they diverged — the price was an 84-line
    edit while the base fell back to the whole file, and the round read 11.9k lines of untouched
    code and reported twenty findings in it (live 2026-08-24).

    A recorded blob this store can READ is that side. Where it cannot — nothing ever recorded the
    path, or the sha its artifact named is gone from this store — where the unreviewed work stands
    decides. A path DIRTY in the working tree owes its edit and not the history under it, so HEAD
    is the base. A CLEAN path has all of its unreviewed work in commits, so HEAD IS that work
    rather than the base for it: the base is the parent of the oldest commit reaching HEAD at or
    after the earliest epoch the journals stamped for the path. With no epoch stamped and no commit
    under one, HEAD stands and the path owes nothing, since nothing on record says which commits
    went unreviewed. A path HEAD does not hold has no base at all and is read whole, which is what
    a file nobody has ever seen is worth.

    A recorded EMPTY sha stands as itself: a run that READ the path as absent recorded that.
    """
    readable = _scope.reachable_blobs(
        repo, [artifact["shas"].get(path, "") for path, artifact in debt if artifact]
    )
    recorded_sides = {}
    for path, artifact in debt:
        held = artifact["shas"].get(path) if artifact else None
        if held == "" or (held and held in readable):
            recorded_sides[str(path)] = held
    heads = head_path_blobs(
        repo, [str(path) for path, _ in debt if str(path) not in recorded_sides]
    )
    epochs = None
    bases = {}
    for path, _ in debt:
        name = str(path)
        if name in recorded_sides:
            bases[name] = recorded_sides[name]
            continue
        recorded = heads.get(name, "")
        if recorded:
            current = (shas or {}).get(name)
            if current is None:
                current = _store.path_blob_sha(repo, path)
            if recorded == current:
                # Asked per path and only here: a clean path with no readable side is the one case
                # where HEAD is the unreviewed work instead of the base for it.
                if epochs is None:
                    epochs = journal_epochs(repo)
                epoch = epochs.get(name)
                before = None if epoch is None else unreviewed_parent_blob(repo, name, epoch)
                if before is not None:
                    recorded = before
        bases[name] = recorded
    return bases


def debt_line_counts(repo, debt, shas=None, bases=None):
    """How many lines each debt path is in debt by, as `{path: lines}`: the diff between the
    content something last stood behind it with — `debt_base_blobs`, the same base the review's
    own diff is built over — and the content standing there now, counted by the same differ the
    review target header prints its `N file(s) · M line(s)` with.

    Both sides are handed to git as files, because neither is reliably an object this repository
    holds: uncommitted working-tree bytes are in no store at all, and hashing them into one would
    make a statusline render write into the repository it is only reading.

    A held path that is gone has no current side and counts the content it lost.

    The key spells the sha actually compared, HEAD's included, or a number measured where the
    recorded blob is missing would answer for the checkout whose store still holds it.

    `bases` is the answer `repo_debt` already resolved for these same paths, taken as given: it is
    uncached git work per clean path, and the statusline calls both in one render.
    """
    cache = debt_line_cache()
    counts = {}
    pending = []
    suppressed = diff_suppressed_paths(repo, [str(path) for path, _ in debt])
    priced = [(path, artifact) for path, artifact in debt if str(path) not in suppressed]
    currents = {}
    for path, _ in priced:
        name = str(path)
        current = (shas or {}).get(name)
        currents[name] = _store.path_blob_sha(repo, path) if current is None else current
    if bases is None or any(str(path) not in bases for path, _ in priced):
        bases = debt_base_blobs(repo, priced, shas=currents)
    for path, _ in debt:
        name = str(path)
        if name in suppressed:
            counts[name] = 0
            continue
        key = f"{bases[name]}:{currents[name]}"
        if key in cache:
            counts[name] = cache[key]
        else:
            pending.append((name, bases[name]))
    if not pending:
        return counts
    measured = 0
    with tempfile.TemporaryDirectory(prefix="review-bench-debt-") as scratch:
        left = Path(scratch) / "recorded"
        right = Path(scratch) / "current"
        for name, recorded in pending:
            recorded_bytes = _store.blob_bytes(repo, recorded) if recorded else b""
            current_bytes = _store.path_content_bytes(repo, name)
            left.write_bytes(recorded_bytes)
            right.write_bytes(current_bytes or b"")
            try:
                changes, _ = _scope.diff_numstat(repo, [str(left), str(right)], no_index=True)
            except RuntimeError:
                # An error is not a measurement. Written down it would answer for these two
                # contents for as long as both of them stand, long after whatever failed here.
                counts[name] = 0
                continue
            counts[name] = sum(changes.values())
            # Keyed by the bytes this actually compared and never by a sha read a moment earlier:
            # the file may have been written to since, and an entry filed under the content it no
            # longer holds is a wrong number for the content it does. Absence spells itself the
            # empty string, exactly as the lookup above spells it: hashed as an empty file instead,
            # a deleted path writes a key nothing can ever ask for and misses on every render.
            current_now = "" if current_bytes is None else _store.content_blob_sha(repo, current_bytes)
            # `debt_base_blobs` vetted the recorded sha, but a store can lose the object between
            # that read and this one, and an empty answer is how the loss looks — told from a
            # genuinely empty blob, which caches like any other, by the sha of what came back.
            if not recorded or _store.content_blob_sha(repo, recorded_bytes) == recorded:
                cache[f"{recorded}:{current_now}"] = counts[name]
                measured += 1
                if measured % DEBT_LINE_CACHE_BATCH == 0:
                    save_debt_line_cache()
    save_debt_line_cache()
    return counts


def debt_ownership(repo, debt, session, claims=None, records=None):
    """Each debt path sorted by whose it is: `{"own", "foreign", "orphaned", "authors"}`.

    The one rule three readers switch on — the split's line counts, the one-liner's owner word and
    the scope a `--debt` review computes — so a path counted foreign on the statusline cannot be
    the one a review of the same repository silently reads.
    """
    records = _store.worker_run_dirs() if records is None else records
    claims = _store.run_record_claims(repo, records) if claims is None else claims
    authors = debt_path_authors(repo, debt)
    mine = _store.session_run_paths(repo, session, claims=claims) if session else set()
    buckets = {"own": set(), "foreign": set(), "orphaned": set(), "authors": authors}
    for path, _ in debt:
        path = str(path)
        if session and (session in authors.get(path, ()) or path in mine):
            buckets["own"].add(path)
        elif authors.get(path) or claims.get(path):
            buckets["foreign"].add(path)
        else:
            buckets["orphaned"].add(path)
    return buckets


def debt_split(repo, paths=None, session=""):
    """This repository's debt in DIFF LINES, split three ways for the statusline: `(own, foreign,
    orphaned)`.

    `own` is the debt of paths the asking chat answers for, folded exactly as the verdict line's
    owner word folds them — its journal entries plus the runs it launched (row `am`). `foreign` is
    another chat's, by the same evidence read the other way round.

    `orphaned` is neither, and it is the reason this is three numbers and not two: a path no
    journal entry names and no run record claims belongs to NOBODY, and counted as the asking
    chat's it reports work that chat never did as its own to answer for. It is a co-tenant's to
    every reader outside — the gate folds it into `foreign` — but a reader asking the store
    directly can tell how much of what it is looking at is owned by no one at all. A path known
    only from a run's workdir dirt lands here by construction: nothing recorded who wrote it.
    """
    shas = {}
    bases = {}
    records = _store.worker_run_dirs()
    claims = _store.run_record_claims(repo, records)
    debt = repo_debt(repo, paths, shas=shas, claims=claims,
                     dirty=_store.run_dirty_paths(repo, records), bases=bases)
    if not debt:
        return 0, 0, 0
    lines = debt_line_counts(repo, debt, shas=shas, bases=bases)
    buckets = debt_ownership(repo, debt, session, claims=claims, records=records)
    return tuple(
        sum(lines.get(path, 0) for path in buckets[name])
        for name in ("own", "foreign", "orphaned")
    )


def unread_artifact(path):
    """An artifact standing for nothing ever having answered for `path`: an empty left side, which
    is what a review of a file nobody has read is a diff against.

    A reopened round's paths are the one scope that carries this. Left as None they would fall to
    `debt_base_blobs`' rule for an unreadable side and be read against HEAD — right for an ordinary
    debt path, whose edit is what it owes, and wrong here: the fork's ruling is that the second pass
    rereads the FULL original scope plus the fixes, and against HEAD it would see the fixes alone
    the moment the first round's work was committed.
    """
    return {"id": "", "shas": {path: ""}}


def debt_review_scope(repo):
    """Every path a `--debt` review of `repo` must read, each with the artifact its content is
    compared against, as `(path, artifact)` pairs — the same shape `repo_debt` answers in.

    The debt itself, WIDENED to every surviving path of any round a decision reopened. A path still
    sitting at the sha that round recorded is by definition NOT in debt — so a scope made of the
    debt alone can never carry the very round it exists to answer, and the review the contract
    demands would have to be widened by hand every time, by the one reader with no way to know what
    that round read.

    A round whose decision named a second pass is REOPENED here, and it is looked for among
    every artifact standing over this repository rather than among the ones some path is in debt
    against: a round whose reviewed bytes nobody has touched since — the threshold stop that fixed
    nothing being exactly that round — puts no path in debt at all, and read off the debt its
    mandatory second pass could never be scoped (live, 2026-08-22). Its own receipt is not read,
    so every path it holds compares against whatever answered for that path before it and its full
    scope re-enters as a real diff. That is the ruling the fork has always printed — a re-review
    reruns the full original scope plus the fixes, never the fixes alone, because a fresh pass over
    old code finds new defects — and the mechanics said otherwise: the round before it had recorded
    those very shas, so a scope built off the newest artifact saw only the fixing pass's own bytes
    and a live second round read 258 lines of fixes and nothing else (2026-08-22).

    Bounded by the round budget: there is no round 3, so a round 2's receipt answers for its scope
    like any other.
    """
    artifacts = repo_artifacts(repo)
    covering = covering_artifacts(repo, artifacts=artifacts)
    debt = repo_debt(repo, covering=covering, reviewed=reviewed_shas(artifacts, repo),
                     holders=path_holders(artifacts))
    standing = {}
    for artifact in covering.values():
        standing.setdefault(artifact["id"], artifact)
    reopened = {
        run_id: artifact for run_id, artifact in standing.items()
        if artifact_owes_second_round(artifact)
    }
    if reopened:
        # The round's own fix-bytes artifact goes with it: same round, same answer. Out of the
        # content set too, or its scope comes back current on the shas it recorded itself.
        ignoring = {key for run_id in reopened for key in (run_id, f"{run_id}+fixes")}
        artifacts = [artifact for artifact in artifacts if artifact["id"] not in ignoring]
        covering = covering_artifacts(repo, artifacts=artifacts)
        debt = repo_debt(repo, covering=covering, reviewed=reviewed_shas(artifacts, repo),
                         holders=path_holders(artifacts))
    scope = dict(debt)
    widened = [path for artifact in reopened.values() for path in artifact["shas"]]
    ignored = debt_ignored(repo, widened)
    for artifact in reopened.values():
        for path in artifact["shas"]:
            if not os.path.lexists(Path(repo) / path):
                continue
            if str(path).startswith(_store.WORKTREE_PATH_PREFIX) or str(path) in ignored:
                continue
            if scope.get(path) is None:
                scope[path] = covering.get(path) or unread_artifact(path)
    return sorted(scope.items())


def debt_foreign_skipped(repo, debt, session, buckets=None, claims=None, records=None,
                         covering=None):
    """The debt paths a `--debt` review of this repository will NOT read: another chat's, less
    whatever a reopened round puts back.

    One rule, two readers — the scope `debt_scope` computes and the count `debt`'s own line prints
    beside it. A line quoting a number the scope never left out is the same lie as a scope that
    dropped a path silently: the count is what a chat reads BEFORE it decides. With no session
    nothing is foreign to anybody, so the review reads the whole of it and this is empty.

    A path of a round some decision reopened is never foreign: the second pass reads that round's
    whole scope whoever has touched those paths since, and named as skipped it would be counted out
    of a scope that in fact holds it.
    """
    if not session:
        return set()
    if buckets is None:
        buckets = debt_ownership(repo, debt, session, claims=claims, records=records)
    if covering is None:
        covering = covering_artifacts(repo)
    reopened = {
        path for artifact in covering.values() if artifact_owes_second_round(artifact)
        for path in artifact["shas"]
    }
    return set(buckets["foreign"]) - reopened


def debt_scope(repo, session="", include_foreign=False):
    """A `--debt` review's scope and what it left out, as `(pairs, skipped)`.

    Another chat's live work is a moving target: reviewing it prices a diff that changes under the
    panel, and the round it produces answers for content the chat that wrote it never saw. So the
    default scope is this chat's own debt plus the debt nobody owns, and `--all` is the ask that
    widens it. What is left out is NAMED by the caller and never silently dropped — a review that
    reads six of nine files while its one-liner says nine is how a chat told Egor work had been
    reviewed clean that no rater ever opened (live case 2026-08-22).

    What an OPEN round of this chat already read is out of the scope whoever asks
    (`round_covered_paths`): those bytes are that round's fixing pass answering its own findings,
    and a second panel over them is a chat paying to be told the same things while the round it is
    standing on stays open. What is left is the delta — the work done after the review — which is
    exactly what a chat that worked on past its own round still owes.
    """
    pairs = debt_review_scope(repo)
    if not session:
        return pairs, []
    covered = _round.round_covered_paths(repo, session)
    if covered:
        pairs = [(path, artifact) for path, artifact in pairs if str(path) not in covered]
    if include_foreign:
        return pairs, []
    artifacts = repo_artifacts(repo)
    covering = covering_artifacts(repo, artifacts=artifacts)
    debt = repo_debt(repo, covering=covering, reviewed=reviewed_shas(artifacts, repo),
                     holders=path_holders(artifacts))
    owed = {str(path) for path, _ in debt}
    foreign = debt_foreign_skipped(repo, debt, session, covering=covering)
    kept = [(path, artifact) for path, artifact in pairs if str(path) not in foreign]
    skipped = sorted(path for path in foreign if path in owed)
    return kept, skipped


def debt_review_command(repos=(), tier="", include_foreign=False, scope_lines=None,
                        this_repo_only=""):
    """The one command a chat is handed when a review is owed, carrying whatever this call has to
    add to it — and `DEBT_REVIEW_COMMAND` itself where nothing does.

    Every printer builds it here. Spelled by hand at each site, a chat owing two repositories was
    handed the bare form by the commit notice and the merged one by the tool, ran the bare one, and
    the second repository's debt sat unreviewed behind a panel that reported clean.
    """
    command = _store.DEBT_REVIEW_COMMAND
    if tier:
        command = command.replace(_store.DEBT_REVIEW_TIER, tier)
    for repo in repos:
        command += " --repo " + shlex.quote(str(repo))
    if include_foreign:
        command += " --all"
    if this_repo_only:
        command += " --this-repo-only --reason " + shlex.quote(this_repo_only)
    if scope_lines is not None:
        command += f" --scope-lines {scope_lines}"
    return command


def debt_chat_review_command(session, repos=(), tier=""):
    """The `--debt` command to hand THIS chat: merged over every repository it owes when there is
    more than one, and the bare `DEBT_REVIEW_COMMAND` otherwise.

    One panel per chat is a rule about what gets LAUNCHED, and a one-liner printed in the bare form
    is what a chat launches. So every surface that hands the command over — the commit notice, the
    settle ask, the adjudication handoff, the waiver's refusal — asks here rather than spelling it,
    or the tool refuses the very command the gate just told the chat to run.
    """
    owed = debt_owed_repos(session, named=repos) if session else []
    return debt_review_command(owed if len(owed) > 1 else (), tier)


def debt_owed_repos(session, include_foreign=False, named=()):
    """Every repository `session` currently owes a `--debt` review in, as sorted absolute paths.

    The candidates are the trees this chat's own calls reached (`chat_call_repos`) plus the ones
    the command already names; each is asked the same question the review itself asks, so a
    repository listed here is one the review would have something to read in.
    """
    candidates = list(dict.fromkeys([str(repo) for repo in named] + _store.chat_call_repos(session)))
    owed = []
    for candidate in candidates:
        repo = _store.resolve_repo_arg(candidate)
        if repo is None or str(repo) in owed:
            continue
        if _scope.merged_manifest(repo) is not None:
            continue
        pairs, _ = debt_scope(repo, session, include_foreign)
        if pairs:
            owed.append(str(repo))
    return sorted(owed)


def debt_one_panel_guard(repos, session, include_foreign, tier, waived):
    """RULE: one debt panel per chat, not one per repository. Refuse a round answering for some of
    the repositories this chat owes while leaving the rest standing.

    A `--debt` round settles the repository it read and nothing else, so a chat owing three of them
    that runs three rounds pays three panels and triages three reports for one piece of work — and
    the merged mode exists precisely to read them under one panel. The refusal names the merged
    command rather than describing it, and `--this-repo-only` with a reason on record is the way
    past it: a decision somebody made, never a bare override.

    With no asking chat there is nothing to enumerate and nothing to refuse.
    """
    if not session or waived:
        return
    owed = debt_owed_repos(session, include_foreign, named=repos)
    if len(owed) < 2 or set(owed) <= {str(repo) for repo in repos}:
        return
    raise ValueError(
        f"this chat owes a review in {len(owed)} repositories and this command reads "
        f"{len(repos)}; a round settles only what it read, so the rest would stand unreviewed "
        "behind a panel that came back clean. Launching nothing. Read them under ONE panel:\n"
        f"{debt_review_command(owed, tier, include_foreign)}\n"
        "or say why this one goes alone, which is recorded with the run: add --this-repo-only "
        "--reason '...'"
    )


def debt_scope_price(scoped):
    """What a `--debt` round is about to read, as `(files, lines, rows)`: `debt_line_counts` over
    every path of every repository in `scoped`, which is the differ the statusline prices the same
    debt with and the one the target header counts its own `N file(s) · M line(s)` by.

    `rows` is `(name, lines)` largest first, the name carrying its repository wherever more than one
    is being read.
    """
    scoped = list(scoped)
    rows = []
    for repo, pairs in scoped:
        counts = debt_line_counts(repo, pairs)
        for path, _ in pairs:
            name = str(path) if len(scoped) == 1 else f"{repo}/{path}"
            rows.append((name, counts.get(str(path), 0)))
    rows.sort(key=lambda row: (-row[1], row[0]))
    return len(rows), sum(lines for _, lines in rows), rows


def debt_scope_gate(scoped, allowed, tier="", include_foreign=False, repos=(),
                    this_repo_only=""):
    """RULE: a sweep needs an explicit number. Print what this round is about to read, and above
    `DEBT_SCOPE_LINES_MAX` launch nothing until the caller has named that size back.

    `--debt` is the one target nobody spells, so its size is the one thing a chat never sees before
    the panel has already read it. `allowed` is the `--scope-lines` the caller typed, and it has to
    EQUAL what this prints: a flag that merely disabled the check would be a bare override, while a
    number that has to match is a size somebody read.
    """
    files, lines, rows = debt_scope_price(scoped)
    print(f"scope: {files} file(s) · {lines} line(s)")
    if lines <= DEBT_SCOPE_LINES_MAX or allowed == lines:
        return
    shown = [row for row in rows if row[1]][:DEBT_SCOPE_ROWS_SHOWN]
    listing = "".join(f"\n  {count} line(s)  {name}" for name, count in shown)
    hidden = len([row for row in rows if row[1]]) - len(shown)
    if hidden > 0:
        listing += f"\n  ... and {hidden} more path(s)"
    named = (
        f", not the {allowed} this command named" if allowed is not None else ""
    )
    retry = debt_review_command(
        repos=repos, tier=tier, include_foreign=include_foreign, scope_lines=lines,
        this_repo_only=this_repo_only,
    )
    raise ValueError(
        f"this --debt round would read {lines} line(s) across {files} file(s){named}, past the "
        f"{DEBT_SCOPE_LINES_MAX} a sweep may take unread. Launching nothing. The largest of it:"
        f"{listing}\n"
        "Read that, then run the same command naming the size you read:\n"
        f"{retry}"
    )


def debt_skipped_line(repo, skipped):
    """The one sentence a review owes about the debt it is not reading: how much of it there is,
    whose it is, and the flag that includes it."""
    if not skipped:
        return ""
    debt = repo_debt(repo, skipped)
    lines = sum(debt_line_counts(repo, debt).values())
    authors = debt_path_authors(repo, debt)
    launchers, store = worker_run_launchers(), store_names()
    # The run records beside the journals, because a path is foreign by EITHER store: debt a
    # co-tenant's worker run claims and no journal has swept yet has an owner written down, and a
    # sentence promising whose it is that names nobody is the one reading this line came for.
    claims = _store.run_record_claims(repo)
    owners = sorted({
        chat_label(owner, launchers=launchers, store=store)
        for path in {str(path) for path, _ in debt}
        for owner in (*(authors.get(path) or ()),
                      *(row[1] for row in claims.get(path, ())))
    })
    whose = f" (chat {', '.join(owners)})" if owners else ""
    return (f"skipped foreign: {len(skipped)} path(s), {lines} line(s){whose} "
            "— include with --all")


def debt_member_scopes(repos, session="", include_foreign=False, skipped=None):
    """Each repository of a merged debt review with its own open question, as
    `(label, repo, pairs)` — computed and not yet sealed, so the round can be priced before it
    writes an object into any of them.

    `skipped` collects each member's own skipped-foreign sentence: the scope is per repository, so
    a merged panel owes that answer once per member and not once for the run.
    """
    scopes = []
    for label, repo in zip(_scope.merged_repo_labels(repos), repos):
        scope, left_out = debt_scope(repo, session, include_foreign)
        if left_out and skipped is not None:
            skipped.append(f"  {label}/ = {repo}: " + debt_skipped_line(repo, left_out))
        if not scope:
            raise ValueError(
                f"--repo {repo} owes no review — "
                + (debt_skipped_line(repo, left_out) if left_out else
                   "nothing in it is in debt")
                + ", so a merged debt review of it would read an empty half; drop that --repo"
            )
        scopes.append((label, repo, scope))
    return scopes


def debt_members(scopes):
    """Each repository of a merged debt review, sealed exactly as a solo one seals itself: the
    scope is that repository's own open question, so a panel spanning two checkouts still owes each
    of them the receipt it would have earned alone.
    """
    members = []
    for label, repo, scope in scopes:
        commit = _scope.debt_snapshot_commit(repo, scope)
        members.append({
            "label": label, "repo": str(repo), "commit": commit,
            "base": _scope.diff_base(repo, commit), "scope": [path for path, _ in scope],
            # A rerun is pinned to the merged commit and carries no flags; the manifest is where
            # each member's mode has to survive, or the rerun writes the scoped receipt instead of
            # the repository's own and settles nothing.
            "debt": True,
        })
    return members


def owners_of(session, launchers=None):
    """A session and the chat that launched it: a worker a chat spawned IS that chat (row `am`)."""
    launcher = (worker_session_launchers() if launchers is None else launchers).get(session)
    return {session, launcher} if launcher else {session}


def debt_path_authors(repo, debt):
    """Which chats each debt path belongs to: the debt journal a commit's own gate appends to, plus
    the commit journal for work still uncommitted. A record naming no session belongs to nobody and
    makes no chat an author of it.

    A chat answers for a path only through a record that NAMES it — nothing is inferred from a
    workdir, a window or a run's dirt. Takes the `(path, artifact)` pairs debt comes as, because a
    debt-journal record standing at or below the epoch of the artifact covering its path is a
    SETTLED episode's leftover: it answers for the content that artifact already read and never for
    the work done since. A path whose every record is spent that way has no author and is nobody's
    — the reader says `orphaned` rather than name a chat for another chat's later work on the same
    file (live case 2026-08-25: three co-tenants' commits read back as one chat's own debt). A
    record whose epoch is unreadable is kept, and the commit journal is never filtered: its records
    are pruned the moment a path is clean, so what stands there is present-tense by construction.
    """
    authors = {str(path): set() for path, _ in debt}
    floors = {
        str(path): artifact["epoch"]
        for path, artifact in debt
        if isinstance(artifact, dict) and artifact.get("epoch")
    }
    directory = _store.journal_dir(repo)
    if directory is None:
        return authors
    # A worker a chat spawned IS that chat, so the launcher is an author of every record its worker
    # session left. Both stand there, never one instead of the other: the worker's own gate asks
    # this same question under the worker's id while the run is going, and answered `other` it would
    # refuse that session a waiver over the work it just did.
    launchers = worker_session_launchers()
    for session, epoch, path in _store.journal_entries(directory / _store.DEBT_JOURNAL):
        if not session or path not in authors:
            continue
        floor = floors.get(path)
        if floor and epoch is not None and epoch <= floor:
            continue
        authors[path].update(owners_of(session, launchers))
    for session, _, path in _store.journal_entries(directory / _store.COMMIT_JOURNAL):
        if not session or path not in authors:
            continue
        authors[path].update(owners_of(session, launchers))
    return authors


def debt_authors(repo, debt):
    """Which chats this debt belongs to, as one set over all of its paths."""
    return {
        session
        for sessions in debt_path_authors(repo, debt).values()
        for session in sessions
    }


def run_confirmed_counts(run_dir):
    """`(confirmed P1s, confirmed findings)` of a triaged run — CODE findings on both halves
    (`docs_finding`) — read from its report receipt where one was written and from the verdicts
    otherwise, the receipt being the only record a `--no-corpus` round leaves, or None where
    neither could be read at all.

    Memoized because the covering reader asks the same run for its tally once per path it holds,
    and a triaged run's counts are written once. Only an answer is remembered: a run half-written
    while this walks it reads as no tally, and caching that would hold the run unreadable for the
    rest of the process after the file lands.
    """
    key = str(run_dir)
    if key not in RUN_CONFIRMED_COUNTS:
        counts = read_run_confirmed_counts(run_dir)
        if counts is None:
            return None
        RUN_CONFIRMED_COUNTS[key] = counts
    return RUN_CONFIRMED_COUNTS[key]


def read_run_confirmed_counts(run_dir):
    try:
        receipt = json.loads((run_dir / _store.REPORT_RECEIPT).read_text())
    except (OSError, ValueError):
        receipt = None
    if isinstance(receipt, dict):
        severities = receipt.get("confirmed_by_severity")
        return (
            _store.counted_int((severities if isinstance(severities, dict) else {}).get("P1")),
            _store.counted_int(receipt.get("confirmed")),
        )
    verdicts_path = run_dir / "verdicts.jsonl"
    if not verdicts_path.exists():
        return None
    try:
        verdicts = _store.read_jsonl(verdicts_path)
    except (OSError, ValueError):
        return None
    total = sum(1 for row in verdicts if row.get("verdict") == "confirmed")
    return (
        _round.severity_tallies(run_dir, verdicts)[""]["P1"],
        total - _panel.docs_confirmed_count(run_dir, verdicts),
    )


def session_timeout_run(repo, session):
    """The run of `session` a watchdog killed, while it is still the newest thing that chat has to
    say. An untriaged run standing on top of a kill says nothing, so it must not speak over it; a
    later triaged run does, and takes the answer back — as does the killed run's own triage: a kill
    whose findings were judged left nothing to wait on, and shouted anyway it outlives its answer.
    """
    for run_dir, meta, record in _store.session_runs(repo, session):
        if meta.get("timed_out") and not _store.run_triaged(run_dir):
            return run_dir.name
        reviewed = record.get("reviewed")
        if _store.run_triaged(run_dir) and isinstance(reviewed, dict) and reviewed:
            return None
    return None


def print_ledger(repo):
    """Name the file this answer was read out of, on stderr.

    Never stdout: `--list` is a path per line and `--split` is one machine-read line, and both are
    parsed by the claude-setup gate, which discards stderr wholesale. The line exists because the
    same question used to be answered from two files — a per-worktree ledger and the family's —
    and neither surface named which one it had opened (live case 2026-08-26).
    """
    directory = _store.journal_dir(repo)
    if directory is not None:
        print(f"ledger: {directory / _store.DEBT_JOURNAL}", file=sys.stderr)


def cmd_debt(args):
    """What this repository owes a review, in one line and nothing else.

    Always exit 0: the gate reads a failure as no answer and falls silent, so a repository it
    cannot resolve has to come back as `none` rather than as an error code the reader turns into a
    clean bill.
    """
    listing = bool(getattr(args, "list", False))
    split = bool(getattr(args, "split", False))
    repo = _store.resolve_repo_arg(args.repo)
    if repo is None:
        if split:
            print("split 0 0 0")
        elif getattr(args, "command", False):
            print(_store.DEBT_REVIEW_COMMAND)
        elif not listing:
            print("none")
        return 0
    # The asking chat, and where nobody named one the chat whose shell is asking. Answered as the
    # empty string it was, every path fell into foreign/orphaned by construction and `--split` came
    # back `own 0` over a checkout the caller owed all of — read as "you owe nothing" by a live
    # chat and by two workers (2026-08-24). `waive` already refuses outright rather than answer
    # silently in this same situation; this is the same refusal, answered instead of refused.
    session = str(getattr(args, "session", "") or "") or _store.caller_chat()
    if getattr(args, "command", False):
        # The one-liner itself, for a surface that hands it over rather than acting on it: the
        # commit notice is the first place a chat is told what to run, and one that names this
        # repository alone arranges the split panel the review would then refuse.
        print(debt_chat_review_command(session, [repo]))
        return 0
    paths = _store.debt_query_paths(repo, getattr(args, "paths", None))
    if split:
        # One shape whatever the answer is, including nothing owed: the statusline's translator
        # switches on the counts and never on which of two lines came back.
        print("split %d %d %d" % debt_split(repo, paths, session))
        print_ledger(repo)
        return 0
    records = _store.worker_run_dirs()
    claims = _store.run_record_claims(repo, records)
    ignored = set()
    debt = repo_debt(repo, paths, claims=claims, dirty=_store.run_dirty_paths(repo, records),
                     ignored=ignored)
    # The line the commit door prices a commit on, so what an open round of this chat READ is left
    # out here too (`round_covered_paths`): counted as debt, a fixing pass's own bytes were fresh
    # unreviewed work and the gate refused the very commit that was about to close the round.
    covered = _round.round_covered_paths(repo, session) if session else set()
    if covered:
        debt = [(path, artifact) for path, artifact in debt if str(path) not in covered]
    if listing:
        for path, _ in debt:
            print(path)
        # What the repository's own file took out of the list, so the count is explainable rather
        # than merely smaller than the reader expected. Never stdout: `--list` is a path per line
        # and the gate reads it straight into an array, where this sentence becomes a file nobody
        # can open.
        if ignored:
            print(f"ignored: {len(ignored)} path(s) by {DEBT_IGNORE_FILE}", file=sys.stderr)
        print_ledger(repo)
        return 0
    # Before the kill and never after it: a hung review over content some artifact has since
    # settled demands nothing, and reported anyway it is a red statusline no later artifact clears.
    if not debt:
        print("none")
        return 0
    if session:
        hung = session_timeout_run(repo, session)
        if hung:
            print(f"timed-out {hung}")
            return 0
    buckets = debt_ownership(repo, debt, session, claims=claims, records=records)
    owned = len(buckets["own"])
    if not session:
        # With no asker there is no MINE or OTHER, but `unknown` over debt the records DO name an
        # owner for is the wrong word: it stands over the unowned part alone and drops entirely
        # where there is none, so a reader must test for the word rather than count to field three.
        # The count stays the debt's own, whatever the word does: it is the field every reader
        # prices this repository by, and a line answering `0` over work nobody has read is the one
        # thing it may never say. No foreign share rides it either — nothing is asking, so
        # `debt_foreign_skipped` leaves nothing out and a count of an exclusion that never happens
        # names a scope no review of this line will take.
        foreign = len(buckets["foreign"])
        unowned = len(debt) - foreign
        word = " unknown" if unowned or not foreign else ""
        print(f"debt {len(debt)}{word}")
        return 0
    owner = "mine" if owned else "other"
    # A chat owning one path of ten reads `debt 10 mine` and answers for all ten. The word keeps
    # its meaning for every reader switching on it; the count beside it is the new fact.
    share = f" {owned}" if 0 < owned < len(debt) else ""
    # The part of that count a `--debt` review will not read, named here rather than left for the
    # reader to infer from a number this line does not print: the one-liner is what a chat sees
    # before it decides, and one that said `debt 7` over a scope of one is how six files went to
    # Egor as reviewed clean (live case 2026-08-22).
    # Withheld only where the owner word already says it: `other` is the chat owning NONE of this
    # debt, and a count repeating that adds nothing.
    others = len(debt_foreign_skipped(repo, debt, session, buckets=buckets))
    foreign = f" (+{others} foreign)" if others and others < len(debt) else ""
    print(f"debt {len(debt)} {owner}{share}{foreign}")
    return 0


def cmd_waive(args):
    """Record that this chat is not reviewing these paths, and why.

    The waiver is content-keyed like every other artifact: it holds the shas standing there when it
    was written, so the very next edit is debt again. A skipped review that keeps covering whatever
    replaces it is not a decision anybody made.
    """
    repo = _store.resolve_repo_arg(args.repo)
    if repo is None:
        print("waive: not a repository")
        return 1
    reason = " ".join(str(getattr(args, "reason", "") or "").split())
    if not reason:
        print("waive: --reason must say why this work is going unreviewed")
        return 1
    if reason == WAIVE_PLACEHOLDER_REASON:
        print(
            f"waive: refused — '{WAIVE_PLACEHOLDER_REASON}' is the placeholder the commit gate "
            "prints in the command it hands you, not a reason. The waiver has to carry your own "
            "words for why this work is going unreviewed."
        )
        return 1
    session = _store.launching_session() or ""
    if not session:
        print(
            "waive: refused — nothing here names the chat recording this waiver, so it would "
            "stand over the work with no one to ask about it. Run it from the chat that owns "
            "the work."
        )
        return 1
    supplied = [str(raw) for raw in getattr(args, "paths", None) or ()]
    explicit = _store.debt_query_paths(repo, supplied)
    if supplied and not explicit:
        # Every spelling was rejected — outside the repository, or the repository root itself.
        # Falling through here would run the pathless form instead, widening a waiver aimed at
        # named paths into the repository's own question, which is the opposite of what was asked.
        print(
            "waive: refused — none of the paths named resolve inside this repository: "
            + ", ".join(repr(raw) for raw in supplied)
            + ". Spell them against the repository root."
        )
        return 1
    debt = repo_debt(repo, explicit)
    if not debt:
        print("waive: nothing here is in debt")
        return 1
    # The repository is shared, and a waiver signs for one chat. Debt the journals hand to another
    # chat is that chat's to answer for, spelled out or not; debt they hand to nobody is what a
    # session may still take on, which is what keeps a legacy record waivable at all — unless a
    # co-tenant's worker run has claimed it, which is where that ownership lives until the commit
    # journal sweeps it.
    authors = debt_path_authors(repo, debt)
    claims = _store.foreign_run_claims(repo, session)
    mine = _store.session_run_paths(repo, session)
    # A journaled path whose file is gone and whose recorded side holds no bytes either prices
    # nothing: there is no content for its owner to answer for, and the owner-only refusal over it
    # leaves residue no chat in the repository can ever clear — the owner's chat is usually the one
    # that ended. Asked of the BYTES and never of a line count, which is also 0 for a binary file,
    # for a path the repository's attributes take out of diffing, and for a measurement that
    # failed: a deleted binary asset another chat owns is real content, and a zero there would hand
    # its waiver to any chat at all.
    weightless = {
        path for path, artifact in debt
        if not os.path.lexists(Path(repo) / path)
        and not _store.blob_bytes(repo, artifact["shas"].get(path, "") if artifact else "")
    }
    # Both whole-store readings once for the whole refusal: named per path, every path in debt
    # would walk the run records and re-read every session file again.
    launchers, store = worker_run_launchers(), store_names()

    def name_of(owner):
        return chat_label(owner, launchers=launchers, store=store)

    def foreign_owner(path):
        """Who else's this path is, or None where this chat is one of its owners. Ownership is the
        UNION of the two stores, the way `cmd_debt` counts it: one command calling a path this
        chat's while the other refuses to sign for it is the repository answering itself twice.
        """
        if path in weightless:
            return None
        sessions = authors.get(path) or ()
        if session in sessions or path in mine:
            return None
        if sessions:
            return ", ".join(sorted({name_of(owner) for owner in sessions}))
        claim = claims.get(path)
        return None if claim is None else f"run {claim[0]}, launched by {name_of(claim[1])}"

    if explicit:
        foreign = {
            path: owner for path, owner in ((row[0], foreign_owner(row[0])) for row in debt)
            if owner
        }
        if foreign:
            named = "; ".join(f"{path} ({owner})" for path, owner in sorted(foreign.items()))
            print(
                f"waive: refused — this chat ({name_of(session)}) is not who the record names "
                f"for {named}. A waiver signs for the chat that owns the work, so those paths are "
                "theirs to waive or to review."
            )
            return 1
    else:
        debt = [row for row in debt if foreign_owner(row[0]) is None]
        if not debt:
            print(
                f"waive: refused — every path in this repository's debt belongs to another chat, "
                f"not to this one ({name_of(session)}), and a waiver naming no path would "
                "settle their work under it. Name what you are not reviewing with --paths."
            )
            return 1
    path = waiver_file(repo)
    if path is None:
        print("waive: the repository identity is unavailable")
        return 1
    entry = {
        "id": f"waiver-{int(time.time())}-{hashlib.sha1(reason.encode()).hexdigest()[:7]}",
        "epoch": int(time.time()),
        "session": session,
        "reason": reason,
        # The writing variant: a waiver is a command, and the shas it records are read back
        # as CONTENT by every later pricing of these paths. Recorded without their objects,
        # the whole file read as debt on the very next edit (live 2026-08-24).
        "paths": _store.stored_path_blob_shas(repo, [name for name, _ in debt]),
    }
    with _accounts.wall_file_lock(path, _store.WAIVER_LOCK):
        try:
            stored = json.loads(path.read_text())
        except (OSError, ValueError):
            stored = {}
        if not isinstance(stored, dict) or not isinstance(stored.get("waivers"), list):
            stored = {"waivers": []}
        family = _store.repo_family(str(repo))
        if family is not None:
            stored["family"] = str(family)
        stored["waivers"].append(entry)
        path.parent.mkdir(parents=True, exist_ok=True)
        scratch = path.with_name(f".{path.name}.{os.getpid()}")
        scratch.write_text(json.dumps(stored, indent=2, sort_keys=True) + "\n")
        os.replace(scratch, path)
    # Nobody chose these paths one by one, so the line has to show which ones the waiver took, and
    # which of them no journal hands to this chat at all.
    signed = "" if explicit else " [" + ", ".join(
        name + ("" if authors.get(name) else " (no journal author)") for name, _ in debt
    ) + "]"
    print(f"waived {len(debt)} path(s): {reason}{signed}")
    return 0


def doctor_ledger_keys(session, cache):
    """The delivery keys claude-setup's report hooks recorded for `session`.

    A chat with no ledger file has delivered nothing, and that is not the same as having had
    nothing to deliver: whether its Stop gate ever ran is unreadable from here, so the age
    threshold is what keeps a chat that simply has not reached its stop out of the count.
    """
    session = str(session or "")
    if session not in cache:
        keys = set()
        # The hooks refuse a session id of any other shape, so one this scan would build a path
        # out of is one no ledger was ever written under.
        if re.fullmatch(r"[A-Za-z0-9._-]+", session):
            ledger = (
                Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
                .joinpath(*DELIVERY_LEDGER_DIR) / f"{session}{DELIVERY_LEDGER_SUFFIX}"
            )
            try:
                keys = set(ledger.read_text(encoding="utf-8", errors="replace").split())
            except OSError:
                keys = set()
        cache[session] = keys
    return cache[session]


def ledger_delivered(session, run_id, state, cache):
    """Whether the hooks' ledger says this round's report reached Egor in this `state`. Read-only,
    like every reading of the ledger on this side; the key shape is spelled here and nowhere else.
    """
    return DELIVERY_LEDGER_KEY.format(run_id=run_id, state=state) in doctor_ledger_keys(session, cache)


def round_fixes_stuck(run_dir, meta):
    """Whether a triaged round's fixing pass is still waiting on somebody to run a command.

    Below the fork thresholds the pass closes ITSELF: the commit carrying the fixes covers the
    round, so a round with no receipt is a round whose optional tally nobody typed, not one nobody
    finished — counted here, that was a class measuring bookkeeping. What is left is the two states
    only a person can clear: a round whose decision named a second pass nobody ran, and one whose
    receipt says the pass STOPPED.

    Neither can hide a second round that already ran. A round is only ever succeeded by one once
    its own fixes are `done` on record, which is a state this function has already excluded, and a
    stopped round is answered by its decision and not by a later panel.
    """
    rows = _round.recorded_verdict_rows(run_dir)
    state = _round.round_state(run_dir, rows)
    if state == "blocked":
        return True
    return state == "pending" and not _round.round_covers_its_fixes(run_dir, meta, rows)


def doctor_triage_instant(run_dir):
    """When somebody stood behind this run's findings, or None where nobody has. A run triaged
    before the report receipt existed left only its verdicts file, whose mtime is the closest
    thing on disk to the instant.
    """
    try:
        receipt = json.loads((run_dir / _store.REPORT_RECEIPT).read_text())
    except (OSError, ValueError):
        receipt = None
    recorded = _store.parse_iso_timestamp(
        receipt.get("reported_at") if isinstance(receipt, dict) else None
    )
    if recorded is not None:
        return recorded
    try:
        return datetime.fromtimestamp((run_dir / "verdicts.jsonl").stat().st_mtime, timezone.utc)
    except OSError:
        return None


def doctor_row(what, repo, age=None, session=""):
    row = {"what": str(what), "repo": str(repo or ""), "age_s": None if age is None else int(age)}
    # The chat and not its id: nothing takes this line back as an argument, and a reader deciding
    # whose round has been sitting for two days needs the conversation's name.
    if session:
        row["chat"] = _store.chat_display(session)
    return row


def doctor_orphan_debt(repo, covering=None, reviewed=None, holders=None):
    """Debt paths no chat answers for: every journal record naming them is the original bare-path
    format, or there is no record at all. Nobody will be asked to review or waive these, so they
    sit in the count for ever while the gate stays silent about whose they are.

    Both channels the gate itself answers `mine` out of, or a path a chat's own worker wrote and
    no sweep has reached yet is counted as nobody's while that chat is being asked about it.
    """
    records = _store.worker_run_dirs()
    claimed = _store.run_record_claims(repo, records)
    debt = repo_debt(repo, covering=covering, reviewed=reviewed, claims=claimed,
                     dirty=_store.run_dirty_paths(repo, records), holders=holders)
    if not debt:
        return []
    authors = debt_path_authors(repo, debt)
    return [
        doctor_row(path, repo) for path, _ in debt
        if not authors.get(str(path)) and not claimed.get(str(path))
    ]


def doctor_scan(now=None, undelivered_window=DOCTOR_WINDOW_S):
    """Every anomaly the review system's own records can be asked about, as
    `{class: [row, ...]}`.

    `undelivered_window` is the one bound a caller may move, because it is the one class whose
    bound is about ATTENTION and not about the record: `settle-delivery` asks the same question
    with no window at all, an older report being no less owed than a recent one.

    Pull-only and read-only: nothing here marks a record, speaks to a vendor or costs a token, and
    the answer is a count per class with the records behind it rather than a verdict about any one
    run. The classes are the ways this system has been seen to go quiet — a panel nobody judged, a
    report nobody delivered, a triage nobody answered, debt nobody owns, and a panel that completed
    nothing.
    """
    now = now or _store.utc_now()
    findings = {name: [] for name in (*DOCTOR_CLASSES, DOCTOR_ROUND_OVERFLOW)}
    benches = _store.state_dir() / "benches"
    # Resolved, because every path it is tested against is: under a symlinked state dir — macOS
    # `/tmp` and `/var/folders`, every WORKER_STATS_DIR fixture — an unresolved root shares no
    # prefix with anything and the workspace one panel read is scanned as a checkout of Egor's.
    merged_root = _store.resolved_repo_path(_store.state_dir() / _scope.MERGED_DIR)
    ledgers = {}
    repos = {}

    def remember(recorded):
        # The merged workspace a run was built in is a repository too, and by the time anybody
        # asks it holds no work of Egor's — only the copy one panel read.
        resolved = _store.resolved_repo_path(recorded) if recorded else None
        if resolved is None or resolved == merged_root or merged_root in resolved.parents:
            return
        repos.setdefault(resolved, None)

    # Never the cwd, however close to hand the tree in front of the reader is: this scan is the
    # collector's, and one that answered differently depending on where it was invoked from would
    # write a different snapshot every six hours off an unchanged store.
    for run_dir in sorted(benches.iterdir()) if benches.exists() else ():
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(meta, dict):
            continue
        # Before the finish stamp is asked for: a checkout is a repository whatever became of the
        # panel that named it, and the tree-level classes below are the two this system has no
        # other way to reach.
        for record in [meta] + [row for row in meta.get("repos") or () if isinstance(row, dict)]:
            remember(str(record.get("repo") or ""))
        # Not a class and not aged: the launcher refuses a round 3, so a run wearing one says the
        # mechanics broke rather than that anybody is late. It rides beside the classes because the
        # five are the menubar's whole vocabulary (docs/shared-invariants.md row `av`).
        if _round.review_round(run_dir, meta) > _round.ROUND_BUDGET:
            findings[DOCTOR_ROUND_OVERFLOW].append(doctor_row(
                f"{run_dir.name} round {_round.review_round(run_dir, meta)}",
                meta.get("repo"), None, meta.get("session"),
            ))
        finished = _store.parse_iso_timestamp(meta.get("finished") or meta.get("finished_at"))
        # A launch document carries no finish stamp. Every RUN class below is about a record
        # nobody moved on after it stopped being written to, so a panel still running is none.
        if finished is None:
            continue
        age = (now - finished).total_seconds()
        recent = age <= DOCTOR_WINDOW_S
        # The two round classes below ask only about runs carrying a report receipt, because that
        # receipt is what a ROUND is: `record --no-corpus` writes it and nothing else does, so a
        # benchmark row adjudicated into verdicts.jsonl — which owes Egor no report and will never
        # have a fixing pass — cannot sit in either count for ever.
        reported = (run_dir / _store.REPORT_RECEIPT).exists()
        if not _store.run_triaged(run_dir):
            # And `untriaged` asks what the Stop gate asks: a worktree run. A commit-point panel
            # nobody scored is a benchmark backlog, not a review that went unanswered.
            if recent and meta.get("worktree") is True and age >= DOCTOR_AGES_S["untriaged"]:
                findings["untriaged"].append(doctor_row(
                    run_dir.name, meta.get("repo"), age, meta.get("session")
                ))
        elif reported:
            state = _round.delivery_state(run_dir)
            session = str(meta.get("session") or "")
            # A run no chat launched has no ledger to be missing from: it was never anybody's to
            # deliver, and counted here it would be a permanent finding no action clears.
            if (age <= undelivered_window and state in _round.DELIVERY_STATES and session
                    and age >= DOCTOR_AGES_S["undelivered"]):
                key = DELIVERY_LEDGER_KEY.format(run_id=run_dir.name, state=state)
                mark = _round.delivery_mark(run_dir)
                settled = mark.get("state") == state
                # A round written off as lapsed is not a silence any mechanism will break: the
                # chat it was owed to is gone from disk. It leaves this count for `--lapsed`,
                # where it stays readable, rather than standing here for ever.
                if key not in doctor_ledger_keys(session, ledgers) and not (
                    settled and mark.get("lapsed")
                ):
                    findings["undelivered"].append(doctor_row(
                        f"{run_dir.name} {state}"
                        + (" queued" if settled and mark.get("queued") else ""),
                        meta.get("repo"), age, session,
                    ))
            if recent and round_fixes_stuck(run_dir, meta):
                triaged_at = doctor_triage_instant(run_dir)
                stuck = None if triaged_at is None else (now - triaged_at).total_seconds()
                if stuck is not None and stuck >= DOCTOR_AGES_S["stuck_fixes"]:
                    findings["stuck_fixes"].append(
                        doctor_row(run_dir.name, meta.get("repo"), stuck, session)
                    )
        # Every panel that came back with nothing, however it died. Coverage no longer turns on
        # the kill marking, so the two code paths have one consequence and the asymmetry this
        # class was named for is gone; what is left is a diagnostic — a review whose whole panel
        # produced nothing is a silence whatever killed it, and a triaged one covers its scope
        # like any other round. Through the same reader every other surface uses, or a record
        # written before the field existed is counted as a panel that completed nothing.
        if recent and meta.get("raters") and not _panel.completed_raters_from_meta(meta):
            findings["kill_asymmetry"].append(doctor_row(
                run_dir.name, meta.get("repo"), age, meta.get("session")
            ))
    for repo in sorted(repos):
        # A checkout that is gone, or was never a git working tree, answers neither question.
        if _store.journal_dir(repo) is None:
            continue
        # Built once and handed to both: each of them otherwise walks the whole benches directory
        # for the same answer, and this scan is over every checkout the store has ever recorded.
        artifacts = repo_artifacts(repo)
        covering = covering_artifacts(repo, artifacts=artifacts)
        findings["orphan_debt"].extend(
            doctor_orphan_debt(repo, covering, reviewed_shas(artifacts, repo),
                               path_holders(artifacts))
        )
    return findings


def doctor_lapsed():
    """Every round `settle-delivery` wrote off, oldest first: its id and state, the repository it
    read, and when it was written off. Unbounded by the scan window above — the whole point of the
    class is that these reports are owed to nobody and will never be delivered, so the list has to
    stay readable for as long as the records do rather than go quiet after a fortnight.
    """
    benches = _store.state_dir() / "benches"
    rows = []
    for run_dir in sorted(benches.iterdir()) if benches.exists() else ():
        mark = _round.delivery_mark(run_dir)
        if not mark.get("lapsed"):
            continue
        try:
            repo = json.loads((run_dir / "meta.json").read_text()).get("repo")
        except (OSError, ValueError):
            repo = ""
        session = str(mark.get("session") or "")
        rows.append({
            "what": f"{run_dir.name} {mark.get('state') or ''}".strip(),
            "repo": str(repo or ""), "lapsed": str(mark.get("lapsed")),
            "session": session, "chat": _store.chat_display(session),
        })
    return rows


def doctor_age_text(seconds):
    seconds = max(0, int(seconds))
    days, rest = divmod(seconds, 86400)
    return f"{days}d {rest // 3600}h" if days else f"{rest // 3600}h"


def doctor_lines(findings):
    """One line per class that found something, its rows indented beneath it, and the quiet
    classes named together at the end — a reader has to be able to tell "asked and clean" from
    "not asked at all", and a class printed only when it fires cannot say which it was.
    """
    lines = []
    for name in (*DOCTOR_CLASSES, DOCTOR_ROUND_OVERFLOW):
        rows = findings.get(name) or []
        if not rows:
            continue
        lines.append(f"{name}: {len(rows)}")
        for row in rows[:DOCTOR_DETAIL_LINES]:
            age = "" if row["age_s"] is None else f"  {doctor_age_text(row['age_s'])}"
            chat = f"  {row['chat']}" if row.get("chat") else ""
            lines.append(f"  {row['what']}  {row['repo']}{age}{chat}")
        # Named rather than dropped: a cut list that says nothing reads as the whole of it.
        if len(rows) > DOCTOR_DETAIL_LINES:
            lines.append(f"  … {len(rows) - DOCTOR_DETAIL_LINES} more not printed")
    clean = [name for name in (*DOCTOR_CLASSES, DOCTOR_ROUND_OVERFLOW) if not findings.get(name)]
    if clean:
        lines.append("ok: " + ", ".join(clean))
    return lines


def doctor_snapshot_document(findings, now):
    counts = {name: len(findings[name]) for name in DOCTOR_CLASSES}
    return {"as_of": int(now.timestamp()), "anomalies": counts, "total": sum(counts.values())}


def write_doctor_snapshot(findings, now, directory=None):
    """Atomically, because the menubar reads this on every render: a half-written document is a
    menu line that vanishes for as long as the write takes.
    """
    path = (Path(directory) if directory else _store.state_dir()) / DOCTOR_SNAPSHOT
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    temporary.write_text(json.dumps(doctor_snapshot_document(findings, now)) + "\n")
    temporary.replace(path)
    return path


def doctor_wrapper_exec_line():
    """One spelling for the line install writes and uninstall recognises, so a wrapper pointing
    anywhere else is never deleted as ours.
    """
    return f"exec {shlex.quote(str(_store.BIN_DIR / 'review-bench'))} doctor --snapshot"


def doctor_agent_paths(home):
    home = Path(home)
    return {
        "plist": home / "Library" / "LaunchAgents" / f"{DOCTOR_AGENT_LABEL}.plist",
        "wrapper": home.joinpath(*DOCTOR_AGENT_WRAPPER),
        "logs": home / ".claude-profiles" / ".claudeb",
    }


def doctor_agent_plist(paths):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{DOCTOR_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{paths["wrapper"]}</string>
  </array>
  <key>StartInterval</key>
  <integer>{DOCTOR_AGENT_INTERVAL_S}</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:{paths["logs"].parent.parent}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>{paths["logs"]}/review-doctor.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>{paths["logs"]}/review-doctor.stderr.log</string>
</dict>
</plist>
"""


def write_doctor_agent(home):
    """The wrapper and the plist, and nothing that talks to launchd: the tests exercise exactly
    this against a fixture HOME, and a load hidden inside it would install a real agent on the
    machine running them.
    """
    paths = doctor_agent_paths(home)
    for directory in (paths["plist"].parent, paths["wrapper"].parent, paths["logs"]):
        directory.mkdir(parents=True, exist_ok=True)
    temporary = paths["wrapper"].with_name(f"{paths['wrapper'].name}.tmp.{os.getpid()}")
    temporary.write_text(f"#!/usr/bin/env bash\n{doctor_wrapper_exec_line()}\n")
    temporary.chmod(0o755)
    temporary.replace(paths["wrapper"])
    paths["plist"].write_text(doctor_agent_plist(paths))
    return paths


def remove_doctor_agent(home):
    paths = doctor_agent_paths(home)
    paths["plist"].unlink(missing_ok=True)
    try:
        ours = doctor_wrapper_exec_line() in paths["wrapper"].read_text()
    except OSError:
        ours = False
    if ours:
        paths["wrapper"].unlink(missing_ok=True)
    return paths


def doctor_launchctl(plist, load):
    """What launchd made of the plist: the empty string where it loaded, its complaint where it
    did not. A failed load is invisible from every other surface — an absent snapshot renders no
    menu line by design — so a caller that dropped this would print "Installed" over a collector
    that will never run once.
    """
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", domain, str(plist)], capture_output=True, check=False)
    if not load:
        return ""
    attempts = [["launchctl", "bootstrap", domain, str(plist)],
                ["launchctl", "load", "-w", str(plist)]]
    complaint = ""
    for command in attempts:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if not result.returncode:
            return ""
        complaint = (result.stderr or result.stdout or "").strip() or f"exit {result.returncode}"
    return complaint


def cmd_doctor(args):
    """The SCAN always exits 0. It is a diagnostic and never a gate: a review system with an
    anomaly in it is still a review system, and a nonzero exit here would make one a wall
    somewhere. Installing the collector is the other thing this command does, and a job launchd
    refused is a plain failure of the thing that was asked for.
    """
    if args.install_agent:
        paths = write_doctor_agent(Path.home())
        complaint = doctor_launchctl(paths["plist"], True)
        if complaint:
            print(f"Wrote {paths['plist']}, but launchd refused to load it: {complaint}. "
                  f"{DOCTOR_AGENT_LABEL} will take no snapshot until it does.", file=sys.stderr)
            return 1
        print(f"Installed {DOCTOR_AGENT_LABEL}, snapshot every "
              f"{DOCTOR_AGENT_INTERVAL_S // 3600}h through {paths['wrapper']}.")
        return 0
    if args.uninstall_agent:
        paths = doctor_agent_paths(Path.home())
        doctor_launchctl(paths["plist"], False)
        remove_doctor_agent(Path.home())
        print(f"Uninstalled {DOCTOR_AGENT_LABEL}.")
        return 0
    if getattr(args, "lapsed", False):
        rows = doctor_lapsed()
        for row in rows:
            chat = f"  {row['chat']}" if row.get("chat") else ""
            print(f"  {row['what']}  {row['repo']}  {row['lapsed']}{chat}")
        print(f"lapsed: {len(rows)}")
        return 0
    now = _store.utc_now()
    findings = doctor_scan(now)
    if args.snapshot:
        # Never stdout: `--json` promises ONE object there, and the collector that wants both
        # forms in one scan is exactly the caller that would have to strip this line off first.
        print(f"snapshot: {write_doctor_snapshot(findings, now)}", file=sys.stderr)
    if args.json:
        document = doctor_snapshot_document(findings, now)
        # The five classes plus the overflow LINE: the counts above are the snapshot's fixed
        # schema, while a machine reading the details is owed everything the text output says.
        document["details"] = {
            name: findings.get(name) or []
            for name in (*DOCTOR_CLASSES, DOCTOR_ROUND_OVERFLOW)
        }
        print(json.dumps(document, indent=2))
    else:
        for line in doctor_lines(findings):
            print(line)
    return 0
