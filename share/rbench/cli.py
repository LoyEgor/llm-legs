import argparse
import concurrent.futures
import contextlib
import fcntl
import io
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

from . import store as _store
from . import catalog as _catalog
from . import raters as _raters
from . import accounts as _accounts
from . import scope as _scope
from . import panel as _panel
from . import prompts as _prompts
from . import launch as _launch
from . import verify as _verify
from . import round as _round
from . import debt as _debt
from . import report as _report
from . import stats as _stats

SCOPE_FLAG_HELP = (
    "Review only the changes under these pathspecs — of the working tree with --worktree, of the "
    "range with --range or --repo PATH@BASE..HEAD; the run answers to a receipt of its own and "
    "never marks the repository reviewed. With several --repo, each pathspec starts with the "
    "repository's own prefix as it appears in the diff (repo/path), and a repository none of them "
    "names keeps its whole change"
)
DEBT_FLAG_HELP = (
    "Review everything this repository owes a review and nothing else: every path whose current "
    "content nothing that read it stands behind, widened to every surviving path of any round a "
    "decision reopened, each read from the content its newest artifact recorded — so work "
    "reviewed, committed and edited again is one diff across the commit. The scope is computed, "
    "not given, so it takes no target and no --paths. It reads this chat's own debt and the debt "
    "nobody owns; another chat's is named on the target line and left out, since a co-tenant's "
    "live work is a diff that moves under the panel"
)
DEBT_ALL_FLAG_HELP = (
    "Widen that scope to the debt of every chat, not this one's own and the unowned. For an "
    "explicit ask to review what a co-tenant left behind, which is not a gate's business"
)
DEBT_SCOPE_LINES_HELP = (
    "The size of the computed scope, in diff lines, as the run itself printed it. Only a --debt "
    "round past its line ceiling asks for one, and only a number EQUAL to what it printed proceeds "
    "— a flag that merely disabled the ceiling would be a bare override; a number that has to "
    "match is a size somebody read"
)
DEBT_ALONE_FLAG_HELP = (
    "Read this repository's debt alone while this chat owes others, with --reason saying why. One "
    "round settles what it read and nothing else, so the rest stand unreviewed behind a panel that "
    "came back clean; the reason is recorded with the run the way a waiver's is"
)
REPO_FLAG_HELP = (
    "The repository to review, as PATH or PATH@BASE..HEAD to review a range of its commits "
    "instead of its working tree. Repeatable: one run then reads every named repository as a "
    "single change, with each repository's paths under its own top-level prefix, and stamps "
    "every one of them. Where one of several repositories is named without a range, --worktree "
    "is what says its half is read from its working tree"
)
RANGE_FLAG_HELP = (
    "Review everything between two commits as one change, A excluded and B included — a branch, a "
    "series of fixes, work already pushed. The panel reads the range as a single diff and the "
    "receipt is written against it, so a change spread over several commits costs one review "
    "rather than one per commit"
)
def tier_table_vendor_cells(cells):
    grouped = {side: Counter() for side in ("opencode", "agy", "codex", "claude")}
    for cell in cells:
        for rater in _raters.parse_raters(cell):
            base = _raters.normalize_legacy_rater(rater["spec"])
            grouped[rater["side"]][base] += 1
    columns = []
    for side in ("opencode", "agy", "codex", "claude"):
        values = []
        for spec, count in grouped[side].items():
            label = _raters.short_cell_name(_raters.parse_rater(spec))
            values.append(f"{label} x{count}" if count > 1 else label)
        columns.append(", ".join(values) or "—")
    return columns


def cmd_tiers_table():
    rows = []
    for tier_name, tier in _catalog.REVIEW_TIERS.items():
        variants = ("eco", "max") if tier["cells_max"] != tier["cells"] else ("eco",)
        for variant in variants:
            cells = tier["cells" if variant == "eco" else "cells_max"]
            vendors = tier_table_vendor_cells(cells)
            rows.append([
                tier_name if variant == "eco" else f"{tier_name} max",
                *vendors,
                f"{tier['coverage_pct'][variant]}%",
                # Every side but OpenCode: a Gemini cell bills its own account's window like a
                # Claude or Codex one does, and the tiers modulate that spend, so a column that
                # counted only the other two would price two differently-sized Gemini panels
                # the same.
                str(sum(
                    1 for cell in cells
                    for rater in _raters.parse_raters(cell)
                    if rater["side"] != "opencode"
                )),
            ])
    headers = ["tier", "OpenCode", "Gemini", "Codex", "Claude", "cover", "paid runs"]
    widths = [
        max(len(header), *(len(row[index]) for row in rows))
        for index, header in enumerate(headers)
    ]
    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(value.ljust(widths[index]) for index, value in enumerate(row)))


def cmd_tiers(args):
    if getattr(args, "table", False):
        cmd_tiers_table()
    else:
        for tier_name, tier in _catalog.REVIEW_TIERS.items():
            print(f"{tier_name} ({tier['budget_min']} min)")
            print(f"  when: {tier['when']}")
            print(f"  eco (default): {', '.join(tier['cells'])}")
            print(f"  max: {', '.join(tier['cells_max'])}")
    print("\nexcluded:")
    for cell, reason in _catalog.EXCLUDED_CELLS.items():
        print(f"  {cell}: {reason}")
    return 0


def owner_named(panel, now=None):
    """Whether Egor named this panel recently enough for `review-owner-gate.sh` to have left its
    marker there. A marker only unblocks — nothing in this tool ever proposes these panels — so
    it needs no content, no spending and no shape to validate: its mtime is the whole permission.
    """
    now = time.time() if now is None else now
    try:
        # No lower bound: a marker stamped a moment ahead of this clock — the gate touching it
        # while `now` was already read, a filesystem whose timestamps run fine-grained — is fresh
        # by any reading, and refusing it would deny the panel Egor just named.
        return now - (_store.owner_grant_dir() / panel).stat().st_mtime <= _store.OWNER_GRANT_TTL_S
    except OSError:
        return False


def under_agent_runtime():
    """Claude Code exports CLAUDECODE into every command it runs, so a pseudo-terminal an agent
    opens for itself is not mistaken for Egor's own."""
    return bool(os.environ.get("CLAUDECODE") or os.environ.get("CLAUDE_CODE_ENTRYPOINT"))


def launcher_at_keyboard(pid):
    """Whether the process that started this panel holds a terminal of its own, asked of the
    LAUNCHER: the panel runs on DEVNULL in a session of its own and has no controlling terminal
    left to answer with."""
    try:
        line = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)],
                              capture_output=True, text=True, check=False).stdout.strip()
    except OSError:
        return False
    return bool(line) and line not in ("?", "??", "-")


def owner_at_keyboard():
    """Egor's own shell: a terminal on both ends, and no agent runtime around it."""
    if under_agent_runtime():
        return False
    return all(
        getattr(stream, "isatty", lambda: False)()
        for stream in (sys.stdin, sys.stdout)
        if stream is not None
    ) and None not in (sys.stdin, sys.stdout)


def panel_owner_child():
    """Whether this process is the detached child of a launcher that put the owner question to the
    keyboard it still had, AND had one.

    The two environment variables are not the evidence — anything may export them, and exported by
    hand they started an owner tier this gate exists to refuse (audit, 2026-08-26). Neither is the
    rendezvous alone: a shell can make its own directory under `panel_handle_root()`, write its own
    pid into it and run this command itself, and every structural test here passed for it. So the
    launcher's answer is carried in `PANEL_GRANT` and RE-DERIVED against that launcher — the
    terminal it holds, and the environment this child inherited from it. A forged rendezvous now
    buys exactly what its forger could already claim by standing at a keyboard with no agent
    runtime around it, which is the gate itself.

    Only the keyboard answer travels this way. A grant Egor named through `review-owner-gate.sh`
    leaves a marker that outlives the launch, and `guard_tier_owner` reads that marker directly.
    """
    handle = os.environ.get(PANEL_HANDLE_ENV) or ""
    if not handle or os.environ.get(PANEL_OWNER_ENV) != "1":
        return False
    directory = Path(handle)
    try:
        if not directory.is_dir():
            return False
        if directory.parent.resolve() != panel_handle_root().resolve():
            return False
        launcher = (directory / PANEL_LAUNCHER).read_text().strip()
        grant = (directory / PANEL_GRANT).read_text().strip()
    except OSError:
        return False
    if grant != PANEL_GRANT_KEYBOARD:
        return False
    if not (launcher.isdigit() and int(launcher) == os.getppid()):
        return False
    return not under_agent_runtime() and launcher_at_keyboard(os.getppid())


def guard_tier_owner(tier_name, use_max):
    wanted = {"t3"} if tier_name in _store.OWNER_TIERS else set()
    if use_max:
        wanted.add("max")
    if not wanted:
        return
    # The detached panel is this same command in a child with no stdin and a log for stdout, where
    # `owner_at_keyboard` can only ever answer no: its launcher put this question to the keyboard
    # it still had, and the panel re-derives that answer against the launcher itself.
    if panel_owner_child():
        return
    if owner_at_keyboard():
        return
    if all(owner_named(panel) for panel in wanted):
        return
    asked = " and ".join(
        sorted(
            {"t3": tier_name, "max": "--max"}[scope] for scope in wanted
        )
    )
    raise ValueError(
        f"{asked} is the owner's to start: it runs only after Egor has asked for it by name. "
        f"Run a lighter panel, and if this change looks worth more, ask him in one line."
    )


def guard_tier_foreground(args, tier_name):
    if tier_name and tier_name not in _catalog.REVIEW_TIERS:
        raise ValueError(f"unknown tier {tier_name!r}")
    if (
        tier_name
        and _catalog.REVIEW_TIERS[tier_name]["budget_min"] >= 10
        and not os.isatty(1)
        and not getattr(args, "foreground", False)
    ):
        budget = _catalog.REVIEW_TIERS[tier_name]["budget_min"]
        raise ValueError(
            f"{tier_name} runs ~{budget} min; foreground harness commands are killed at 10 — "
            "relaunch this exact command as a background task (run_in_background) and add "
            "--foreground: the flag asserts your runner has no 10-minute kill window, and a "
            "background task is exactly that."
        )


def guard_verifier_scope(args, tier_name):
    """The verifier belongs to the review product and to nothing else. A bench row is what the
    rater said; a row the verifier already filtered measures the pair, and a corpus holding both
    kinds compares cells against each other on numbers that never meant the same thing.

    `--no-verify` stays accepted on a bench run as the no-op it now is: reproduce lines printed
    by older runs spell it, and a reproduce line that no longer replays is no reproduce line.
    """
    if tier_name or not getattr(args, "verify", None):
        return
    raise ValueError(
        "--verify is a tier review's flag: a bench row records what the rater said, and one the "
        "verifier filtered measures the pair rather than the cell. Review with "
        "`review-bench review <target> --tier <tier>`, or drop the flag and bench the raters raw."
    )


def guard_review_armed(args):
    """A review that reads the working tree — `--worktree` or `--debt` — runs when Egor asked for
    one by name, and mid-work panels are what this closes.

    `REVIEW_ASKED=1` is taken at face value here because the flow gate checks that claim against
    the session transcript before the command ever runs, and a second flag saying the same thing
    would be one the caller grants itself unchecked.
    """
    if not (getattr(args, "worktree", False) or getattr(args, "debt", False)) \
            or os.environ.get("REVIEW_ASKED") == "1":
        return
    raise ValueError(
        "reviews are commit-triggered — prefix with REVIEW_ASKED=1 (Egor's commit permission "
        "counts as the ask; reviews ride commits)"
    )


PANEL_HANDLE_ENV = "REVIEW_BENCH_PANEL_HANDLE"
PANEL_OWNER_ENV = "REVIEW_BENCH_PANEL_OWNER"
PANEL_LOG = "panel.log"
# The launcher's own pid, written into the rendezvous before the child is started: it is what tells
# the detached panel from any other process holding the same two environment variables.
PANEL_LAUNCHER = "launcher.pid"
# How the launcher passed the owner gate, written only when it passed at a keyboard: the panel
# re-derives that answer rather than taking it, so the file is a claim to check and never a grant.
PANEL_GRANT = "launcher.grant"
PANEL_GRANT_KEYBOARD = "keyboard"
PANEL_PID = "panel.pid"
PANEL_HANDOFF = "panel.handoff"
PANEL_EXIT = "panel.exit"
PANEL_RUN_ID = "run-id"
# How long the launcher waits for the panel to name its run before it stops speaking for it. Every
# refusal ahead of the run directory — a clean tree, an unarmed review, the one-panel rule — is
# reached in seconds; past this the panel is alive and the launcher has nothing to add.
PANEL_ANNOUNCE_S = 600
PANEL_POLL_S = 2.0
PANEL_DEAD_TAIL_LINES = 40
# How long a rendezvous directory may sit before the next launch takes it away. A launcher that
# stopped waiting — killed at its harness's ten minutes, or past PANEL_ANNOUNCE_S — leaves one
# behind that nothing else would ever remove, and its panel writes a run id into a directory no
# reader has left; well past the announce window, so a handle in use is never swept.
PANEL_HANDLE_STALE_S = 24 * 3600


def panel_handle_root():
    root = _store.state_dir() / "panels"
    root.mkdir(parents=True, exist_ok=True)
    return root


def reap_panel_handles(root, now=None):
    """Every rendezvous nobody is waiting on any more, removed. Best effort: a handle that cannot
    be read or removed costs a directory, and never a launch."""
    now = time.time() if now is None else now
    try:
        stale = list(root.iterdir())
    except OSError:
        return
    for directory in stale:
        try:
            if directory.is_dir() and now - directory.stat().st_mtime > PANEL_HANDLE_STALE_S:
                shutil.rmtree(directory, ignore_errors=True)
        except OSError:
            continue


def claim_panel_handle(run_dir):
    """Furnish the rendezvous the detached launcher is waiting on.

    The run id lands last and through a rename: it is the one file the launcher polls, and a
    reader handed a run id has to find the panel's log and pid already beside the run.
    """
    handle = os.environ.pop(PANEL_HANDLE_ENV, "")
    if not handle:
        return
    directory = Path(handle)
    try:
        os.replace(directory / PANEL_LOG, run_dir / PANEL_LOG)
    except OSError:
        pass
    elapsed = _round.pid_elapsed_seconds(os.getpid()) or 0
    (run_dir / PANEL_PID).write_text(
        f"{os.getpid()} {int(_store.utc_now().timestamp()) - elapsed}\n"
    )
    fresh = directory / (PANEL_RUN_ID + ".new")
    fresh.write_text(run_dir.name + "\n")
    os.replace(fresh, directory / PANEL_RUN_ID)


def panel_pid_stamp(run_dir):
    try:
        fields = (run_dir / PANEL_PID).read_text().split()
    except OSError:
        return None
    if not fields:
        return None
    return fields[0], (fields[1] if len(fields) > 1 else None)


def panel_still_running(run_dir):
    stamp = panel_pid_stamp(run_dir)
    if stamp is None:
        return False
    return _round.pid_still_running(*stamp)


def await_panel_run_id(handle, child):
    marker = handle / PANEL_RUN_ID
    deadline = time.time() + PANEL_ANNOUNCE_S
    while True:
        if marker.exists():
            return marker.read_text().strip()
        exited = child.poll() is not None
        # Read once more after the exit: the panel can name its run and die inside one tick, and
        # a launcher that missed it would report a run that is running fine as a failed launch.
        if exited:
            return marker.read_text().strip() if marker.exists() else None
        if time.time() > deadline:
            return None
        time.sleep(0.2)


def cmd_review_detached(args):
    """Start the panel in a session of its own and hand back its run id.

    A tier runs for tens of minutes; the harness that types the command is killed at ten and
    takes its whole process group with it, so a panel that shares that group dies with orphaned
    cells. `--foreground` is the way back in-process, for tests and for a runner with no kill
    window, and it is what the detached child itself is given.
    """
    if getattr(args, "foreground", False):
        return cmd_review(args)
    tier_name = getattr(args, "tier", None)
    use_max = bool(getattr(args, "max", False))
    if use_max and not tier_name:
        raise ValueError("--max requires --tier")
    # Asked HERE, where the terminal Egor typed into still is: the child runs on DEVNULL and a log,
    # so `owner_at_keyboard` answers no for every launch, and his own T3 came back refused.
    guard_tier_owner(tier_name, use_max)
    root = panel_handle_root()
    reap_panel_handles(root)
    handle = Path(tempfile.mkdtemp(prefix="panel-", dir=root))
    (handle / PANEL_LAUNCHER).write_text(f"{os.getpid()}\n")
    if owner_at_keyboard():
        (handle / PANEL_GRANT).write_text(f"{PANEL_GRANT_KEYBOARD}\n")
    log_path = handle / PANEL_LOG
    environment = dict(os.environ)
    environment[PANEL_HANDLE_ENV] = str(handle)
    environment[PANEL_OWNER_ENV] = "1"
    # Ahead of any `--`, never appended after one: argparse hands everything past that separator to
    # the positionals, so the flag would reach the panel as a commitish and kill the launch.
    forwarded = list(sys.argv[1:])
    at = forwarded.index("--") if "--" in forwarded else len(forwarded)
    forwarded.insert(at, "--foreground")
    with open(log_path, "w") as log:
        child = subprocess.Popen(
            [sys.executable, os.path.abspath(sys.argv[0])] + forwarded,
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True, env=environment,
        )
    run_id = await_panel_run_id(handle, child)
    if run_id:
        shutil.rmtree(handle, ignore_errors=True)
        run_dir = _store.state_dir() / "benches" / run_id
        print(f"run id: {run_id}")
        print(f"panel detached as pid {child.pid}; its output goes to {run_dir / PANEL_LOG}")
        print(f"wait with: review-bench wait {run_id}")
        return 0
    # No run means the panel never launched one: everything it printed is a refusal the caller
    # asked for, so it is theirs, on the stream refusals come out of.
    try:
        # errors="replace": the log carries whatever the cells printed, and a rater that emitted
        # one non-UTF-8 byte would cost the caller the whole refusal it is waiting to read.
        sys.stderr.write(log_path.read_text(errors="replace"))
    except OSError:
        pass
    code = child.poll()
    if code is None:
        print(f"panel has not named a run in {PANEL_ANNOUNCE_S}s; it is still running as pid "
              f"{child.pid} and its output goes to {log_path}, which moves to that run's own "
              f"directory as {PANEL_LOG} the moment the panel names it", file=sys.stderr)
        return 1
    shutil.rmtree(handle, ignore_errors=True)
    return code


def cmd_wait(args):
    run_dir = _store.state_dir() / "benches" / args.run_id
    if not (run_dir / "meta.json").exists():
        raise ValueError(f"unknown run id: {args.run_id}")
    # The handoff below is the report frame the delivery hooks key on, headers and REPORT_END
    # markers included, so waiting on a foreign run id frames another chat's review as this one's.
    # The same refusal `report` already makes over the same text.
    try:
        meta = json.loads((run_dir / "meta.json").read_text())
    except (OSError, ValueError):
        meta = {}
    _report.refuse_foreign_chat(
        run_dir, meta if isinstance(meta, dict) else {},
        str(getattr(args, "session", "") or "").strip() or _store.caller_chat(),
    )
    while panel_still_running(run_dir):
        time.sleep(PANEL_POLL_S)
    closing = run_dir / PANEL_HANDOFF
    if closing.exists():
        sys.stdout.write(closing.read_text(errors="replace"))
        try:
            return int((run_dir / PANEL_EXIT).read_text().strip())
        except (OSError, ValueError):
            # The exit code is written BEFORE the handoff, so a handoff without one is a torn
            # record and never a run that ended well: read as 0 it reports a failed panel as clean.
            print(f"panel {args.run_id} handed over without an exit code in "
                  f"{run_dir / PANEL_EXIT}", file=sys.stderr)
            return 1
    log = run_dir / PANEL_LOG
    try:
        tail = log.read_text(errors="replace").splitlines()[-PANEL_DEAD_TAIL_LINES:]
    except OSError:
        tail = []
    for line in tail:
        print(line, file=sys.stderr)
    print(f"panel {args.run_id} died before it reported: nothing handed anything over, and the "
          f"lines above are the tail of {log}. `review-bench doctor` names what it left behind "
          f"and how to clear it.", file=sys.stderr)
    return 1


def resolve_round_stamp(targets, session):
    """Which round of its chain this launch is, and which chain, for the run's own record.

    A round 2 is one thing and nothing else: a sweep over a scope whose newest open round already
    carries a DECISION. That record is what says a second pass was chosen, so the number is
    settled by the store rather than by a flag the caller passes — and by asking once, at launch,
    every later reader is spared re-deriving it and disagreeing.

    There is no round 3, and the chain is asked rather than the parent: a round 2 carries no
    decision of its own — `fork` refuses to record one over a spent budget — so the round 1 whose
    decision reopened the scope goes on answering `chain_parent` after its second pass has run.
    The refusal is the second round ALREADY ON that chain, still open, and it is raised here before
    a snapshot commit is written: the third pass over one scope is the loop this contract exists to
    end, and the answer to a round 2 that is still open is to finish it. One a commit has closed
    ends the chain instead — the next sweep over that scope starts one of its own.

    Every member of a merged launch is asked, and the whole launch takes ONE stamp: members that
    reopen two different chains are refused, since a stamp can name only one of them and the other
    round 1 would stay open with no second pass to close it. A member starting a chain of its own
    beside them is not — a merged round is priced as one round, and its fresh member rides it.
    """
    stamp = None
    for repo, paths in targets:
        found = _round.chain_parent(repo, paths, session)
        if found is None:
            continue
        parent, parent_meta = found
        second = _round.chain_second_round(parent, parent_meta)
        if second is not None:
            if not _round.round_closed(second):
                raise ValueError(
                    f"{second.name} is already round 2 over this scope and no commit has closed "
                    "it; there is no round 3 — fix what it confirmed and commit, and that closes "
                    "both rounds"
                )
            continue
        if _round.review_round(parent, parent_meta) >= _round.ROUND_BUDGET:
            raise ValueError(
                f"{parent.name} is already round 2 over this scope and no commit has closed it; "
                "there is no round 3 — fix what it confirmed and commit, and that closes both "
                "rounds"
            )
        chain = _round.chain_id(parent, parent_meta)
        if stamp is not None and stamp["chain"] != chain:
            raise ValueError(
                f"this launch reopens two chains at once — {stamp['chain']} and {chain} — and one "
                "run carries one round: give each its own second pass with --this-repo-only"
            )
        stamp = {"round": _round.ROUND_BUDGET, "chain": chain}
    return stamp or {}


def cmd_review(args):
    tier_name = getattr(args, "tier", None)
    use_max = bool(getattr(args, "max", False))
    if use_max and not tier_name:
        raise ValueError("--max requires --tier")
    guard_tier_owner(tier_name, use_max)
    guard_tier_foreground(args, tier_name)
    guard_review_armed(args)
    args.raters = ",".join(
        _catalog.REVIEW_TIERS[tier_name]["cells_max" if use_max else "cells"]
    )
    args.auto = None
    args.leg = False
    return cmd_run(args)


def cmd_run(args):
    tier_name = getattr(args, "tier", None)
    use_max = bool(getattr(args, "max", False))
    lens = _prompts.resolve_lens(args.lens) if getattr(args, "lens", "") else None
    if use_max and not tier_name:
        raise ValueError("--max requires --tier")
    guard_tier_owner(tier_name, use_max)
    guard_tier_foreground(args, tier_name)
    guard_verifier_scope(args, tier_name)
    if tier_name:
        args.raters = ",".join(
            _catalog.REVIEW_TIERS[tier_name]["cells_max" if use_max else "cells"]
        )
    sources = []
    for path, spec in _scope.repo_sources(args):
        resolved = _store.resolve_repo_arg(path)
        if resolved is None:
            raise ValueError(f"not a git repository: {Path(path).resolve()}")
        if resolved in [source for source, _ in sources]:
            raise ValueError(f"--repo names one repository twice: {resolved}")
        sources.append((resolved, spec))
    repos = [source for source, _ in sources]
    repo = repos[0]
    worktree_mode = bool(getattr(args, "worktree", False))
    commitish = getattr(args, "commitish", None)
    range_spec = getattr(args, "range", None)
    # A repository named with a range of its own names this run's target as surely as --range does,
    # so the target flags are checked against what the --repo lines already said.
    inline_ranges = [spec for _, spec in sources if spec]
    all_ranged = bool(inline_ranges) and len(inline_ranges) == len(sources)
    # `--debt` is a target of its own, and the one nobody spells: it reads what the artifacts say
    # is unanswered for, from the content they recorded. Every other target flag names a scope the
    # caller chose, which is exactly the choice this mode exists to take away, so they are refused
    # rather than combined.
    debt_mode = bool(getattr(args, "debt", False))
    if debt_mode:
        given = [name for name, present in (
            ("a commitish", bool(commitish)), ("--range", bool(range_spec)),
            ("--worktree", worktree_mode), ("--paths", bool(getattr(args, "paths", None))),
            ("--repo PATH@BASE..HEAD", bool(inline_ranges)),
        ) if present]
        if given:
            raise ValueError(
                "--debt computes its own target and its own scope — every path nothing that read "
                "it stands behind, widened to what a reopened round still holds — so it takes no "
                "other target: drop " + " and ".join(given)
            )
    if getattr(args, "all", False) and not debt_mode:
        raise ValueError(
            "--all widens the scope --debt computes to every chat's debt; every other target "
            "names its own paths already"
        )
    if getattr(args, "this_repo_only", False):
        if not debt_mode:
            raise ValueError(
                "--this-repo-only answers the one-panel rule --debt computes its repositories by; "
                "every other target reads the repositories it was given"
            )
        if not str(getattr(args, "reason", "") or "").strip():
            raise ValueError(
                "--this-repo-only needs --reason '...': leaving this chat's other repositories "
                "unreviewed is a decision, and it is recorded with the run like a waiver's"
            )
    elif str(getattr(args, "reason", "") or "").strip():
        # Warned and not refused: the flag names no decision here, but it is spelled beside a
        # review somebody is about to run, and a refusal cost them the whole launch over a word
        # the run can simply carry (`reason` on the meta).
        print(
            "--reason records the decision --this-repo-only makes; with none to record it is kept "
            "on the run's meta and answers for nothing. The review runs.",
            file=sys.stderr,
        )
    if getattr(args, "scope_lines", None) is not None and not debt_mode:
        raise ValueError(
            "--scope-lines names the size of the scope --debt computes; every other target names "
            "its own paths already"
        )
    if inline_ranges and (commitish or range_spec):
        raise ValueError(
            "--repo PATH@BASE..HEAD names its own range, so the run's target is already given; "
            "drop the " + ("commitish" if commitish else "--range")
        )
    if all_ranged and worktree_mode:
        raise ValueError(
            "every --repo names a range of commits, so no working tree is read by this review; "
            "drop --worktree"
        )
    if inline_ranges and not all_ranged and not worktree_mode:
        raise ValueError(
            "a --repo named without a range of its own is read from its working tree, so this "
            "review reads both: add --worktree, or give every repository a range"
        )
    if not inline_ranges and not debt_mode:
        named = [name for name, given in
                 (("commitish", bool(commitish)), ("--range", bool(range_spec)),
                  ("--worktree", worktree_mode)) if given]
        if len(named) != 1:
            raise ValueError(
                "exactly one of commitish, --range, --worktree and --debt must be given"
                + (f"; got {' and '.join(named)}" if named else "")
            )
    # One repository named with a range is that repository's own --range run: the merged workspace
    # exists to hold several checkouts under one commit, and building it around one would cost the
    # rerun and the receipt their plain shape for nothing.
    if len(sources) == 1 and sources[0][1]:
        range_spec = sources[0][1]
    requested_scope = list(getattr(args, "paths", None) or [])
    if requested_scope and not (worktree_mode or range_spec or all_ranged):
        raise ValueError(
            "--paths narrows a working tree or a range of commits; a single commitish is already "
            "one fixed set of paths"
        )
    if len(repos) > 1 and not (worktree_mode or all_ranged or debt_mode):
        raise ValueError(
            "a merged review reads the working trees of every --repo it is given; one commitish "
            "or range cannot name a change in more than one repository"
        )
    # Set for a merged review, and it is what makes the run answer to every repository it read
    # rather than to the workspace it read them out of.
    members = None
    inherited_seal = None
    debt_skipped = []
    # The range's own right end, kept for the target line: what gets sealed is a commit of the
    # tool's own making, and naming that in place of the commit the caller asked about is how a
    # target line stops answering the question it exists for.
    range_head = None
    debt_all = bool(getattr(args, "all", False))
    debt_asker = _store.caller_chat() or ""
    debt_alone = str(getattr(args, "reason", "") or "") if getattr(args, "this_repo_only", False) else ""
    # A `--reason` naming no `--this-repo-only` decision: warned about above and kept here, so the
    # word the caller wrote is on the record rather than dropped by a run that accepted it.
    free_reason = "" if debt_alone else str(getattr(args, "reason", "") or "").strip()
    debt_lines = getattr(args, "scope_lines", None)
    debt_retry_repos = repos if getattr(args, "repo", None) else ()
    if debt_mode:
        # Both before anything is sealed: a snapshot commit is an object written into the caller's
        # repository, and a round refused after writing one has already spent what it refused.
        _debt.debt_one_panel_guard(repos, debt_asker, debt_all, tier_name, debt_alone)
    # Beside it and for the same reason: an open round of this chat here owes a step of its own,
    # and a panel launched over it settles nothing that round was waiting for.
    if debt_mode or worktree_mode or range_spec or all_ranged:
        _round.round_open_guard(repos, debt_asker, chainable=debt_mode)
    # Round 1 unless the store itself says otherwise, and settled BEFORE anything is sealed: a
    # round refused after writing a snapshot commit has already spent what it refused.
    round_stamp = {}
    if debt_mode and len(repos) > 1:
        scopes = _debt.debt_member_scopes(repos, debt_asker, debt_all, debt_skipped)
        _debt.debt_scope_gate([(repo, pairs) for _, repo, pairs in scopes], debt_lines,
                              tier_name, debt_all, debt_retry_repos, debt_alone)
        round_stamp = resolve_round_stamp(
            [(member, [path for path, _ in pairs]) for _, member, pairs in scopes], debt_asker
        )
        members = _debt.debt_members(scopes)
        repo, sha = _scope.merged_snapshot_workspace(members)
        scope = []
    elif debt_mode:
        if _scope.merged_manifest(repo) is not None:
            raise ValueError(
                f"{repo} is a merged review's workspace and owes no review of its own; name the "
                "repositories it was built from instead"
            )
        owed, left_out = _debt.debt_scope(repo, debt_asker, debt_all)
        if left_out:
            debt_skipped.append(_debt.debt_skipped_line(repo, left_out))
        if not owed:
            # An open round of this chat is the usual reason there is nothing left to read, and
            # naming it is what tells the chat the next step is the COMMIT rather than another
            # panel: the scope leaves out what that round already read (`round_covered_paths`), so
            # an empty scope here is the round covering everything pending.
            standing = _round.session_open_round(repo, debt_asker)
            if standing is not None and standing[2] == _round.ROUND_STEP_READY:
                raise ValueError(
                    f"round {standing[0].name} of this chat is open in {repo} and covers "
                    "everything pending: the commit that carries its fixes closes it. There is no "
                    "review to run"
                )
            raise ValueError(
                f"nothing in {repo} is in review debt for this chat: "
                + (_debt.debt_skipped_line(repo, left_out) if left_out else
                   "every path an artifact holds stands at the content it recorded, and the "
                   "journals name no other")
                + ". There is no review to run"
            )
        _debt.debt_scope_gate([(repo, owed)], debt_lines, tier_name, debt_all,
                              debt_retry_repos, debt_alone)
        scope = [path for path, _ in owed]
        round_stamp = resolve_round_stamp([(repo, scope)], debt_asker)
        sha = _scope.debt_snapshot_commit(repo, owed)
    elif len(repos) > 1:
        members = _scope.merged_members(sources, requested_scope)
        repo, sha = _scope.merged_snapshot_workspace(members)
        scope = []
    elif worktree_mode or range_spec:
        if worktree_mode and _scope.merged_manifest(repo) is not None:
            raise ValueError(
                f"{repo} is a merged review's workspace and has no working tree to seal; name the "
                "repositories it was built from instead"
            )
        scope = _scope.normalize_scope_paths(repo, requested_scope) if requested_scope else []
        sha, range_head = _scope.sealed_target(
            repo, range_spec, scope=scope, clean_command=_round.commit_mode_command(args),
        )
    else:
        scope = []
        sha = _store.resolve_commit(repo, commitish)
        document = _scope.merged_manifest(repo)
        members = document["repos"] if document and document["merged"] == sha else None
        # A rerun is pinned to a seal an earlier run made, and its own clock would date that
        # content to now. The instant already on record is the one this tree stopped changing at.
        inherited_seal = (
            _round.recorded_seal_instant(sha) if _scope.is_worktree_snapshot(repo, sha) else None
        )
    # The instant the content stopped being able to change under this run, which is what
    # `review_round` weighs a fixes receipt against. `started` below is minutes later — an
    # availability sweep and a possible limits refresh sit between them — and a receipt landing in
    # that gap answers for work no cell of this panel ever read, while counting as its lineage.
    sealed_at = inherited_seal or _store.utc_now()
    worktree_mode = worktree_mode or _scope.is_worktree_snapshot(repo, sha)
    # A rerun arrives as the sealed sha and no flags at all, so the mode is read back out of what
    # was sealed: the seal's own subject for one repository, each member's record for a merged
    # panel. Without it the rerun writes a scoped receipt where the run it repeats wrote the
    # repository's own, and the debt the first pass settled comes back.
    debt_mode = debt_mode or (
        any(isinstance(member, dict) and member.get("debt") for member in members) if members
        else worktree_mode and _scope.is_debt_snapshot(repo, sha)
    )
    # A range is sealed the way a worktree snapshot is, and everything that treats those as
    # synthetic rather than as commits of the repository is right to. What it is NOT is a review of
    # the current state: a run over old or pushed commits would otherwise stamp the repository's
    # receipt with a tree nobody is standing on, and every later coverage answer measures against that
    # receipt (found by panel, 2026-08-07). Recognised from the sealed commit itself, so a rerun
    # pinned to the sha is the same kind of run as the one that made it.
    range_ends = _scope.range_snapshot_ends(repo, sha) if worktree_mode else None
    range_mode = bool(range_spec) or range_ends is not None or bool(all_ranged)
    # A rerun carries no `--range`, so without reading the seal back the target line would name the
    # sealed sha there — the tool's own commit, and the very output naming a range's own ends exists
    # to stop (found by panel, 2026-08-07).
    if range_head is None and range_ends:
        range_head = range_ends[1]
    # A rerun names the snapshot sha and no paths at all, so its scope exists only in the
    # snapshot's trailers; without this the rerun of a scoped lens run would write the pure-lens
    # receipt and declare the whole tree read by that lens. A merged snapshot carries no scope of
    # its own — each member's is its own business, and the manifest is where it is written down.
    if worktree_mode and not members and not scope:
        scope = _scope.snapshot_scope_paths(repo, sha)
    # What the run answers for when it finishes: every member of a merged review, each against its
    # own snapshot, so no participating repository is left without the receipt a solo run leaves.
    # A member sealed from a range is not a review of the tree anybody is standing on, so it
    # answers for its own repository only where its right end IS that tree — the same rule a
    # single-repository range run follows, asked per member because one panel now holds both kinds.
    # A debt review answers to no receipt of its own: its scope is not a corner of the repository's
    # question but the whole of it, computed rather than chosen, so it stamps the plain receipt the
    # way an unscoped worktree run does.
    receipt_targets = [
        (Path(member["repo"]), member["commit"],
         [] if member.get("debt") else list(member.get("scope") or []),
         worktree_mode and not member.get("head"))
        for member in members
    ] if members else [
        (repo, sha, [] if debt_mode else scope, worktree_mode and not range_mode)
    ]
    # Before the panel is picked, because the chunk count is what the panel is multiplied by: a
    # cell reads one chunk, and the run answers for the commit only if every rater reads them all.
    chunk_forced = bool(getattr(args, "chunk", False))
    chunks = _scope.diff_chunks(repo, sha, force=chunk_forced)
    scope_price = _scope.announce_review_target(repo, sha, scope, members, head_label=range_head,
                           chunks=len(chunks))
    for line in debt_skipped:
        print(line, file=sys.stderr)
    reviews_path = _store.state_dir() / "reviews.jsonl"
    # The corpus that picks `--auto` cells and prices how long they take, and it is the tool's
    # own reviews even when this run carries a lens: a cell is chosen for how it performs at
    # the methodology the panel is built around, not at whichever lens ran most recently.
    review_rows = _prompts.lens_rows(_store.read_jsonl(reviews_path))
    verify_model = args.verify
    if verify_model:
        verify_model = _verify.verifier_model(verify_model)
    if args.raters or args.leg:
        requested = _raters.parse_raters(args.raters or ",".join(_catalog.OPENCODE_REVIEW_LEG))
        available = {
            "opencode": True, "agy": True,
            "codex": False, "claude": False,
        }
        # Asked for every side the pool staffs, gemini included: its availability was overridden
        # here with a bare True, so a panel launched eight cells the pool had already said it could
        # not staff and reported them as errored (Egor, 2026-08-08).
        if any(rater["side"] in _accounts.SIDE_POOL_VENDOR for rater in requested):
            available.update(_accounts.affordability())
        elif any(rater["side"] == "opencode" for rater in requested):
            # A panel of nothing but OpenCode cells never reaches affordability(), so its wall is
            # read here instead; asking for a side the panel does not hold spends pool queries on
            # answers nothing consumes.
            available["opencode"] = _accounts.opencode_pool_free()
        raters = [rater for rater in requested if _accounts.cell_available(available, rater)]
        skipped = []
        skip_states = {}
        for rater in requested:
            if _accounts.cell_available(available, rater):
                continue
            skipped.append((rater["spec"], _accounts.unaffordable_reason(rater["side"])))
            skip_states[rater["spec"]] = _accounts.skip_state(rater["side"])
        if not raters:
            # A wait with a date on it, not a malformed request: a bare refusal sends the reader
            # looking for a fault in what they asked for.
            reasons = list(dict.fromkeys(reason for _, reason in skipped))
            raise RuntimeError("no affordable requested raters: " + "; ".join(reasons))
        counts = _panel.review_counts(review_rows)
        # Cells this panel asked for and did not get. `--auto`'s skips are candidates it never
        # picked, so only an explicit request leaves a hole the run has to carry into its meta.
        panel_skipped = list(skipped)
    else:
        available = _accounts.affordability()
        raters, counts, skipped = _verify.auto_pick(
            args.auto or 2, review_rows, available,
            {side: f"{side} side is out of a lens's reach" for side in _prompts.LENS_EXCLUDED_SIDES}
            if lens else None,
        )
        panel_skipped = []
        skip_states = {}
    lens_dropped = []
    if lens:
        raters, lens_dropped = _prompts.lens_panel(raters, lens)
        skipped = list(skipped) + lens_dropped
        for rater in raters:
            rater["lens"] = lens
    _accounts.refuse_retired_cells(raters, lens=lens)
    raters, cooling_skipped = _accounts.apply_gateway_cooldown(raters)
    skipped = list(skipped) + cooling_skipped
    panel_skipped = list(panel_skipped) + cooling_skipped
    skip_states.update({spec: "cooling" for spec, _ in cooling_skipped})
    # Only the composition nobody chose cell by cell: a hand-written `--raters` is the bench's
    # ungated surface (DIAGNOSTICS.md), and measuring seven copies of one cell is what it is for.
    gate_skipped = []
    if tier_name:
        raters, gate_skipped = _launch.cap_opencode_panel(raters)
    skipped = list(skipped) + gate_skipped
    panel_skipped = list(panel_skipped) + gate_skipped
    skip_states.update({spec: "gate" for spec, _ in gate_skipped})
    # Carried into the run's own record rather than printed and forgotten: the report's leg row is
    # read hours later, and a side nobody launched reads as a side nobody wanted without it.
    skip_records = [
        {"rater": spec, "reason": reason, "state": skip_states.get(spec, "walled")}
        for spec, reason in panel_skipped
    ]
    # A verifiable cell is a cell the pool staffed, so its own side is the account the verifier
    # runs on: agy leads with Gemini's transport, and an OpenCode cell only launches while the
    # OpenCode pool is free. Nothing beyond this is left to ask about the verifier's reach.
    has_verifiable = any(rater["side"] in _round.VERIFIED_SIDES for rater in raters)
    if verify_model and not has_verifiable:
        walled = "" if available.get("opencode") else f" — {_accounts.unaffordable_reason('opencode')}"
        raise RuntimeError(
            "--verify checks OpenCode and agy findings only (docs/verifier-tuning.md measured "
            "no other side); this run has no cell the verifier reaches" + walled
        )
    # On unless refused, in a tier review and nowhere else, and only once the composition is
    # known, since asking for it where it cannot apply is an error rather than a default. Every
    # failure path of the verifier keeps the finding, so the worst it costs a review is a minute
    # and a run identical to the one without it; what it buys is the claims that cite code as it
    # is not, dropped before a reader spends context on them. A bench run buys nothing by it and
    # pays with the measurement, so it stays raw (Egor, 2026-08-14).
    if (
        not verify_model and tier_name and has_verifiable
        and not getattr(args, "no_verify", False)
    ):
        verify_model = _verify.verifier_model(_catalog.OPENCODE_VERIFIER)
    if chunks:
        why = ("--chunk" if chunk_forced else
               f"diff over {_scope.DIFF_CHUNK_THRESHOLD_BYTES} byte(s)")
        print(f"diff split into {len(chunks)} chunk(s) of at most "
              f"{_scope.DIFF_CHUNK_TARGET_LINES} line(s) ({why}); each cell reads them one after "
              f"another, so the panel keeps its {len(raters)} cell(s)")
    print("selected raters:")
    for rater in raters:
        count = counts[_raters.normalize_legacy_rater(rater["spec"])]
        print(f"  {rater['spec']}: {count} recorded bench row(s)")
    for spec, reason in skipped:
        print(f"skipped {spec}: {reason}")

    if any(rater["side"] == "claude" for rater in raters):
        claude_acct = available["claude_account"]
        if _accounts.check_limits_staleness(claude_acct):
            print(f"limits data for {claude_acct} is stale; refreshing")
            _accounts.refresh_limits(claude_acct)
            available = _accounts.affordability()
            if available["claude"]:
                claude_acct = available["claude_account"]
            else:
                raise RuntimeError("account no longer affordable after limits refresh")

    started = _store.utc_now()
    # From the main thread, which is the only one the SIGTERM half installs from.
    _launch.install_cell_reaper()
    # Every side, not the Antigravity leg alone: a hung cell of any vendor holds the panel open
    # with nothing to report, and the run it belongs to is what the report flow and `doctor` raise.
    watchdog, stall_caps = _panel.panel_cap_timeouts(_store.state_dir() / "benches")
    for rater in raters:
        key = _panel.panel_cell_key(rater)
        rater["timeout_s"] = _panel.cell_timeout_seconds(watchdog, key, tier_name)
        # Only under the duration cap: a stall cap above it never fires, and carrying it would
        # report a limit the cell cannot reach.
        if key in stall_caps and stall_caps[key] < rater["timeout_s"]:
            rater["stall_s"] = stall_caps[key]
    run_id = f"{started.strftime('%Y%m%dT%H%M%SZ')}-{sha[:7]}"
    run_dir = _store.state_dir() / "benches" / run_id
    if run_dir.exists():
        run_id += f"-{os.getpid()}"
        run_dir = _store.state_dir() / "benches" / run_id
    run_dir.mkdir(parents=True)
    os.chmod(run_dir, 0o700)
    requested_raters = [rater["spec"] for rater in raters]
    # Carried beside the launched cells so a panel that lost a whole leg to a wall cannot read as
    # complete: nothing writes a rater_run for them, and every surface turns a spec without one
    # into a not-run cell. The lens's own drops stay out — the scope line already names them.
    requested_raters += [
        spec for spec, _ in panel_skipped if spec not in requested_raters
    ]
    launch_meta = {
        "run_id": run_id, "commit": sha, "repo": str(repo), **round_stamp,
        "raters": requested_raters, "completed_raters": [],
        "rater_runs": [], "durations": {},
        "started": started.isoformat(), "sealed_at": sealed_at.isoformat(),
        "focus": args.focus or "",
        "verifier": verify_model or "",
        "scope_price": scope_price,
        # The corpus spans both epochs: a run's findings are comparable to another's only where
        # both read the repository under the same toolchain rule, and nothing else on record says
        # which of the two this run was.
        "toolchain_shims": _launch.active_shim_names(),
        **_store.session_stamp(),
    }
    if worktree_mode:
        launch_meta["worktree"] = True
        if scope:
            launch_meta["scope"] = scope
        if debt_mode and not members:
            launch_meta["debt"] = True
        # A debt review answers for its whole scope and not for the part of it that produced a
        # diff: a locked round's survivor standing at exactly the sha that round recorded shows
        # nothing, and a run that fails to HOLD it discharges no lock and settles nothing.
        reviewed = _scope.reviewed_blobs(repo, scope, sha, paths=scope if debt_mode else None)
        launch_meta["reviewed"] = reviewed
    if debt_alone:
        launch_meta["this_repo_only"] = debt_alone
    if free_reason:
        launch_meta["reason"] = free_reason
    if members:
        for member in members:
            # A ranged member has no working tree to drift: its content is committed already.
            if not member.get("head"):
                member["reviewed"] = _scope.reviewed_blobs(
                    member["repo"], member["scope"], member["commit"],
                    paths=member["scope"] if member.get("debt") else None,
                )
        launch_meta["repos"] = [dict(member) for member in members]
    if chunks:
        launch_meta["chunks"] = [
            {"index": chunk["index"], "paths": chunk["paths"]} for chunk in chunks
        ]
    if skip_records:
        launch_meta["skipped"] = skip_records
    if tier_name:
        launch_meta["tier"] = tier_name
        launch_meta["max"] = use_max
    # Recorded once, at launch: the registry can be edited while a run is in flight, and the
    # slug alone does not say which text the cells were given.
    lens_meta = {} if lens is None else {
        "lens": lens["name"],
        "lens_hash": lens["hash"],
        "lens_source_status": _prompts.lens_source_status(lens),
        # Named cells, because the tier beside them names a composition this run did not launch.
        "lens_panel_dropped": [spec for spec, _ in lens_dropped],
    }
    launch_meta.update(lens_meta)
    (run_dir / "meta.json").write_text(json.dumps(launch_meta, indent=2) + "\n")
    # After the meta and not after the mkdir: the launcher prints this run id the moment it
    # appears, and every reader it sends here — `wait` first — asks the run what it is.
    claim_panel_handle(run_dir)
    diff = "" if chunks else (_store.commit_diff(repo, sha) if any(
        rater["side"] in ("claude", "opencode") or rater["bare"]
        for rater in raters) else "")

    submitted_raters = sorted(raters, key=_launch.gate_admission_key)
    expected_durations = _panel.expected_review_durations(
        [rater["spec"] for rater in submitted_raters],
        _panel.review_duration_medians(review_rows),
    )
    # One document per repository the panel is reading, because every surface that shows a run in
    # flight looks for the one belonging to the tree in front of it: a merged review that wrote a
    # single document would be invisible in every repository but one.
    progress_documents = []
    progress_warned = False
    # Resolved once, here: the launcher's parent chain is alive at run start and gone by the time
    # a statusline asks, and every document of a merged review names the same chat.
    progress_session = _store.launching_session()

    def warn_progress(exc):
        nonlocal progress_warned
        if not progress_warned:
            print(f"warning: could not update review progress: {exc}", file=sys.stderr)
            progress_warned = True

    tree = _verify.repo_tree(repo, sha)

    def extract_findings(rater, result):
        rc, _, text, _, _ = result
        is_error = rc != 0 or (rc == 0 and text and _accounts.is_429_error(text))
        # Nothing is read out of a dead cell: a killed stream's partial events parse as findings
        # the model withdrew, and the findings file is what the report globs.
        findings = [] if is_error else _prompts.normalize_findings(text, rater["spec"])
        findings = [
            dict(row, file=_verify.canonical_finding_path(row.get("file"), tree))
            for row in findings
        ]
        # Named on the finding as well as carried in its path: the adjudicator merges rows from
        # several raters and has to weigh two claims about one repository against two halves of
        # one contract, and a prefix it has to parse out of a path is a fact it can miss.
        if members:
            findings = [
                dict(row, repo=_scope.merged_finding_label(row.get("file"), members))
                for row in findings
            ]
        unusable = "" if is_error else _prompts.unusable_review(text, findings)
        return findings, is_error, unusable

    def timed_verify(spec, findings, side):
        verify_started = time.monotonic()
        kept, audit = _verify.verify_findings(findings, repo, sha, verify_model, tree, side)
        verify_spans[spec] = (verify_started, time.monotonic())
        return kept, audit, round((verify_spans[spec][1] - verify_started) * 1000)

    def verify_wall_ms(spec):
        """Of one cell's verification, the part that actually held the run open.

        A verification that ran while other cells were still going added nothing to the wall,
        and the report subtracts this — not the whole duration — when it prices the time
        nothing in the block accounts for.
        """
        span = verify_spans.get(spec)
        if span is None or panel_closed is None:
            return None
        return round(max(0.0, span[1] - max(span[0], panel_closed)) * 1000)

    def verify_after_panel_ms():
        """The whole run's post-panel verification as WALL CLOCK: overlaps counted once.

        Cells verify side by side, so their remainders are not additive — a per-cell sum prices
        one shared span once per cell and drives the report's own remainder negative.
        """
        if panel_closed is None:
            return None
        total = 0.0
        reached = panel_closed
        for start, end in sorted(verify_spans.values()):
            if end <= reached:
                continue
            total += end - max(start, reached)
            reached = end
        return round(total * 1000)

    # Verification starts the moment its cell lands, not after the whole panel: run serially
    # after the slowest cell it added a median 26s and a p90 115s of wall per run (28% of all
    # measured excess), all of it spent while other cells were still running anyway. The gate
    # still prefers rater cells — a verifier enters it at priority zero.
    verify_pool = None
    verify_futures = {}
    verify_spans = {}
    panel_closed = None
    extracted = {}

    try:
        try:
            directory = _store.state_dir() / _store.PROGRESS_DIR
            for progress_repo in [Path(member["repo"]) for member in members] if members else [repo]:
                progress_name = _store.progress_file_name(progress_repo)
                if progress_name is None:
                    continue
                progress = _store.review_progress_document(
                    progress_repo, run_id, getattr(args, "tier", None),
                    "range" if range_mode else ("worktree" if worktree_mode else sha[:7]),
                    [rater["spec"] for rater in submitted_raters],
                    started=started.isoformat(),
                    started_epoch=started.timestamp(),
                    max_panel=bool(getattr(args, "max", False)),
                    expected=expected_durations,
                    session=progress_session,
                )
                _store.prune_review_progress(progress_repo, directory)
                progress_documents.append((directory / progress_name, progress))
                _store.persist_review_progress(directory / progress_name, progress)
            if not progress_documents:
                raise RuntimeError("repository identity is unavailable")
        except Exception as exc:
            warn_progress(exc)

        results = []
        slots = Counter()
        for rater in submitted_raters:
            rater["slot"] = slots[rater["side"]]
            slots[rater["side"]] += 1
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(submitted_raters)) as pool:
            # The OpenCode gate prefers the longest job, but only among the cells already
            # queued on it, so the first cells to reach it would otherwise be decided by
            # thread scheduling. Submitting slowest-first makes the whole order its own.
            futures = {
                pool.submit(
                    _launch.run_rater_chunks, rater, repo, sha, args.focus or "", run_dir,
                    diff, chunks,
                ): rater
                for rater in submitted_raters
            }
            for future in concurrent.futures.as_completed(futures):
                rater = futures[future]
                try:
                    result = future.result()
                    results.append(result)
                    cell_failed = result[2][0] != 0
                except Exception as exc:
                    results.append((rater, None, (1, 0, "", f"task exception: {exc}", [])))
                    cell_failed = True
                else:
                    if verify_model and rater["side"] in _round.VERIFIED_SIDES:
                        triple = extract_findings(rater, result[2])
                        extracted[rater["spec"]] = triple
                        findings, is_error, unusable = triple
                        if findings and not is_error and not unusable:
                            if verify_pool is None:
                                verify_pool = concurrent.futures.ThreadPoolExecutor(
                                    max_workers=_launch.OPENCODE_MAX_CONCURRENCY
                                )
                            verify_futures[rater["spec"]] = verify_pool.submit(
                                timed_verify, rater["spec"], findings, rater["side"]
                            )
                for progress_path, progress in progress_documents:
                    try:
                        _store.complete_review_progress(progress, rater["spec"], cell_failed)
                        _store.persist_review_progress(progress_path, progress)
                    except Exception as exc:
                        warn_progress(exc)

        panel_closed = time.monotonic()

        result_by_spec = {}
        for rater, account, result in results:
            result_by_spec[rater["spec"]] = (rater, account, result)

        for spec in [r["spec"] for r in raters]:
            if spec not in result_by_spec:
                results.append((next(r for r in raters if r["spec"] == spec), None,
                               (1, 0, "", f"rater {spec} missing from results", [])))
                result_by_spec[spec] = (next(r for r in raters if r["spec"] == spec), None,
                                       (1, 0, "", f"rater {spec} missing from results", []))

        paths = []
        rater_meta = []
        errored_raters = set()
        gateway_down = set()
        failed = False
        for requested in raters:
            rater, account, result = result_by_spec[requested["spec"]]
            rc, duration, text, stderr, command = result
            model_resolved = _launch.resolved_model_from_envelope(
                _scope.cell_envelope(run_dir, rater["spec"])
            )
            findings, is_error, unusable = (
                extracted.get(rater["spec"]) or extract_findings(rater, result)
            )
            if unusable:
                is_error = True
                stderr = "\n".join(part for part in ((stderr or "").rstrip(), unusable) if part)
            elif is_error and rater["side"] in _accounts.GATEWAY_SIDES and _accounts.gateway_outage(
                rater["side"], rc, stderr
            ):
                gateway_down.add(rater["spec"])
            dropped = 0
            unverified = 0
            verify_ms = None
            audited = 0
            verified_by = {}
            # The verifier's error rate is measured on the OpenCode and agy legs
            # (docs/verifier-tuning.md); other sides' findings pass unverified until measured.
            if verify_model and findings and not is_error and rater["side"] in _round.VERIFIED_SIDES:
                pending = verify_futures.get(rater["spec"])
                if pending is not None:
                    kept, audit, verify_ms = pending.result()
                else:
                    kept, audit, verify_ms = timed_verify(
                        rater["spec"], findings, rater["side"]
                    )
                _store.write_jsonl(run_dir / f"verified-{rater['spec']}.jsonl", audit)
                dropped = len(findings) - len(kept)
                unverified = sum(1 for row in audit if row.get("walled"))
                audited = len(audit)
                verified_by = _verify.verifier_tally(audit, verify_model)
                findings = kept
                print(f"{rater['spec']}: verifier kept {len(kept)} of {len(audit)} finding(s)")
                if unverified:
                    print(f"{rater['spec']}: {unverified} finding(s) went unverified — "
                          "the verifier's plan walled off mid-run")
            path = run_dir / f"findings-{rater['spec']}.jsonl"
            _store.write_jsonl(path, findings)

            if is_error:
                errored_raters.add(rater["spec"])
                run_meta = {
                    "rater": rater["spec"], "model": rater["model"], "effort": rater["effort"],
                    "side": rater["side"], "account": account, "duration_ms": duration,
                    "findings": 0, "exit_code": rc, "stderr": stderr[-2000:] if stderr else "",
                    "command": _launch.redact_command(rater, command),
                    "errored": True, "timeout_s": rater["timeout_s"],
                    "started_at": rater.get("started_at"),
                    "finished_at": rater.get("finished_at"),
                }
                if chunks:
                    run_meta["chunks_read"] = list(rater.get("chunks_read") or ())
                    run_meta["passes"] = rater.get("passes") or len(chunks)
                # The stall record is what the next run's caps learn from: the kill marks the cap
                # it fired at, and a completion's longest silent gap prices the cap itself.
                if rater.get("stalled_s"):
                    run_meta["stalled_s"] = rater["stalled_s"]
                if rater.get("max_quiet_ms") is not None:
                    run_meta["max_quiet_ms"] = rater["max_quiet_ms"]
                if rater.get("killed"):
                    run_meta["killed"] = rater["killed"]
                    run_meta["killed_cap_s"] = rater["killed_cap_s"]
                if model_resolved:
                    run_meta["model_resolved"] = model_resolved
                if rater.get("retry_of"):
                    run_meta["retry_of"] = rater["retry_of"]
                # In attempt order and under the same spec: every surface that counts cells reads
                # the last row of one, so the retry has to be the last row there is.
                rater_meta.extend(rater.get("superseded") or ())
                rater_meta.append(run_meta)
                print(f"ERRORED (not recorded): {rater['spec']}")
            else:
                failed = failed or rc != 0
                paths.append(path)
                run_meta = {
                    "rater": rater["spec"], "model": rater["model"], "effort": rater["effort"],
                    "side": rater["side"], "account": account, "duration_ms": duration,
                    "findings": len(findings), "exit_code": rc,
                    "stderr": stderr[-2000:] if stderr else "",
                    "command": _launch.redact_command(rater, command),
                    "verifier_dropped": dropped, "verifier_unverified": unverified,
                    "timeout_s": rater["timeout_s"],
                    "started_at": rater.get("started_at"),
                    "finished_at": rater.get("finished_at"),
                }
                if chunks:
                    run_meta["chunks_read"] = list(rater.get("chunks_read") or ())
                    run_meta["passes"] = rater.get("passes") or len(chunks)
                # A kill in one chunk of a cell whose other chunks came back is recorded on the
                # completed cell, and the caps never sample a row that carries the kill.
                if rater.get("stalled_s"):
                    run_meta["stalled_s"] = rater["stalled_s"]
                if rater.get("killed"):
                    run_meta["killed"] = rater["killed"]
                    run_meta["killed_cap_s"] = rater["killed_cap_s"]
                if rater.get("max_quiet_ms") is not None:
                    run_meta["max_quiet_ms"] = rater["max_quiet_ms"]
                if verify_ms is not None:
                    run_meta["verify_ms"] = verify_ms
                    run_meta["verify_wall_ms"] = verify_wall_ms(rater["spec"])
                    run_meta["verifier_audited"] = audited
                    run_meta["verifier_by_model"] = verified_by
                if model_resolved:
                    run_meta["model_resolved"] = model_resolved
                if rater.get("retry_of"):
                    run_meta["retry_of"] = rater["retry_of"]
                # In attempt order and under the same spec: every surface that counts cells reads
                # the last row of one, so the retry has to be the last row there is.
                rater_meta.extend(rater.get("superseded") or ())
                rater_meta.append(run_meta)
                print(f"{rater['spec']}: {len(findings)} finding(s), {duration} ms, exit {rc}")
            _report.report_late_review(
                rater["spec"], _panel.cell_pass_duration(run_meta),
                expected_durations.get(rater["spec"])
            )

        _accounts.note_gateway_outcome(raters, errored_raters, gateway_down)
        meta = {
            "run_id": run_id, "commit": sha, "repo": str(repo), **round_stamp,
            "raters": requested_raters,
            "completed_raters": [
                rater["spec"] for rater in raters
                if rater["spec"] not in errored_raters
            ],
            "rater_runs": rater_meta,
            "durations": {row["rater"]: row["duration_ms"] for row in rater_meta},
            "started": started.isoformat(), "sealed_at": sealed_at.isoformat(),
            "finished": _store.iso_now(), "focus": args.focus or "",
            # The finished record is written from scratch, so the launch's own pricing is carried
            # into it: recomputed here it would answer for the tree the panel has been reading.
            "scope_price": scope_price,
            "verifier": verify_model or "",
            "toolchain_shims": launch_meta["toolchain_shims"],
            "verify_after_panel_ms": verify_after_panel_ms(),
            # Rewritten from scratch when the run ends, and the triage nag reads the finished
            # document: dropped here, the launching chat would be forgotten exactly when it is asked.
            **_store.session_stamp(),
        }
        # Every path a chunk no cell came back from held. The snapshot below attests what was
        # read and nothing else, so those paths stay in debt while the rest of the scope is
        # covered exactly as an unchunked round covers it.
        unread = _scope.unread_chunk_paths(chunks, raters, errored_raters)
        if worktree_mode:
            meta["worktree"] = True
            if scope:
                meta["scope"] = scope
            if debt_mode and not members:
                meta["debt"] = True
            # The launch snapshot, carried rather than retaken: the finished document is rewritten
            # from scratch, and a second `hash-object` here would anchor the run to the tree the
            # fixes already moved.
            meta["reviewed"] = _scope.attested_paths(reviewed, unread)
        if debt_alone:
            meta["this_repo_only"] = debt_alone
        if free_reason:
            meta["reason"] = free_reason
        if members:
            meta["repos"] = [
                dict(member, reviewed=_scope.attested_paths(
                    member["reviewed"], unread, f"{member['label']}/"
                )) if isinstance(member.get("reviewed"), dict) else dict(member)
                for member in members
            ]
        if chunks:
            meta["chunks"] = launch_meta["chunks"]
        if skip_records:
            meta["skipped"] = skip_records
        if tier_name:
            meta["tier"] = tier_name
            meta["max"] = use_max
        # One breached cell marks the whole run: nothing else says a review hung, and the report
        # flow and `debt`'s own timed-out line read this key. It is a diagnostic and nothing more —
        # whether a round covers its scope turns on its triage receipt alone, so a kill costs the
        # round no coverage an errored cell would have kept. The watchdog's own kills alone: a
        # provider answering `gateway timeout` is an ordinary failed cell. A cell whose retry
        # stalled too is that same hung review, killed earlier: `watchdog_killed` excludes it only
        # to keep a stall out of the duration reading, not to keep the run quiet. Over the cells'
        # FINAL rows: a superseded attempt is not the cell's answer.
        if any(_panel.watchdog_killed(row) or row.get("stalled_s")
               for row in _panel.cell_attempt_rows(rater_meta)[0]):
            meta["timed_out"] = True
        # Read once, while the vendor still has the transcript: it is pruned on its own schedule,
        # and a report drawn after that would say the escape never happened.
        escapes = [list(hit) for hit in _panel.clone_escapes(run_dir, meta)]
        if escapes:
            meta["clone_escapes"] = escapes
        for rater, account, excerpt in escapes:
            print(f"escaped: {rater} · {account} · {excerpt}")
        meta.update(lens_meta)
        (run_dir / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        _report.log_review_event("run", run_dir, meta)
        if meta["completed_raters"]:
            for target, target_sha, target_scope, target_worktree in receipt_targets:
                _store.write_review_receipt(target, target_sha, run_id, len(errored_raters),
                                     panel=len(raters),
                                     worktree=target_worktree,
                                     lens=lens["name"] if lens else None,
                                     scope=target_scope)
        # Kept as well as printed. A detached panel's stdout is a log holding every cell's noise,
        # and `wait` owes its caller exactly what a foreground run said once the panel was over.
        closing = io.StringIO()
        code = 1 if (failed or errored_raters) else 0
        # Handed over whatever happens: the handoff and the exit code are the only thing `wait`
        # has, and a report that raised took the run id, the rerun line and the whole review with
        # it — `wait` then called a finished round a panel that died before it reported.
        try:
            with contextlib.redirect_stdout(closing):
                if errored_raters:
                    errored = [rater for rater in raters if rater["spec"] in errored_raters]
                    rerun = ",".join(
                        _raters.collapse_rater_attempts(rater["spec"] for rater in errored)
                    )
                    # Always the sha, even for --worktree: the tree can drift before the rerun, and
                    # only the snapshot commit pins the errored cells to what the others reviewed.
                    rerun_command = ["review-bench", "run", sha, "--raters", rerun]
                    # The merged commit lives in the workspace and nowhere else, so the rerun has
                    # to be pointed at it; the workspace answers for the same repositories this
                    # run did.
                    if members:
                        rerun_command += ["--repo", str(repo)]
                    if chunk_forced:
                        rerun_command += ["--chunk"]
                    # A rerun without the lens completes a lens run with a stock review of the cell.
                    if lens:
                        rerun_command += ["--lens", lens["name"]]
                    # No verifier flag of any spelling: the rerun is a bench run, and a bench run
                    # reports what the rater said. A tier's errored cell is completed raw, which is
                    # the same answer the reader would get by asking the cell again by hand.
                    print(f"rerun: {shlex.join(rerun_command)}")
                print(f"run id: {run_id}")
                _round.handoff(run_id, paths, members, worktree=worktree_mode, fixable=all(
                    _store.reviews_current_tree(target, target_sha, target_worktree)
                    for target, target_sha, _, target_worktree in receipt_targets
                ))
                _report.emit_report(run_dir, meta)
        except Exception as error:
            code = 1
            closing.write(f"the report this run owed could not be printed: {error}\n")
            raise
        finally:
            # The exit code lands FIRST: `wait` takes the handoff for the whole record, and a
            # reader arriving between the two writes read a missing code as a clean run.
            (run_dir / PANEL_EXIT).write_text(f"{code}\n")
            (run_dir / PANEL_HANDOFF).write_text(closing.getvalue())
            sys.stdout.write(closing.getvalue())
        return code
    finally:
        if verify_pool is not None:
            # Joined, not detached: its threads are joined at interpreter exit anyway, and a
            # shutdown that claims otherwise hides a failed run's wait for a live verifier.
            verify_pool.shutdown(wait=True, cancel_futures=True)
        for progress_path, _ in progress_documents:
            try:
                progress_path.unlink(missing_ok=True)
            except Exception as exc:
                warn_progress(exc)


def append_review_records(sd, records, replace_run=None):
    """Append rows the corpus lacks, or replace a whole run's rows when told to.

    Replacement rewrites the file, so it goes through a temp file and a rename: a crash
    mid-write would otherwise truncate the only durable record of every bench ever run.
    """
    sd.mkdir(parents=True, exist_ok=True)
    with open(sd / ".reviews.lock", "w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        path = sd / "reviews.jsonl"
        existing = _store.read_jsonl(path)
        if replace_run:
            kept = [row for row in existing if row.get("run_id") != replace_run]
            dropped = len(existing) - len(kept)
            tmp = path.with_suffix(".jsonl.tmp")
            with open(tmp, "w") as stream:
                for row in kept + records:
                    stream.write(json.dumps(row) + "\n")
            os.replace(tmp, path)
            return records, dropped
        keys = {(row.get("run_id"), row.get("rater")) for row in existing}
        fresh = [row for row in records if (row["run_id"], row["rater"]) not in keys]
        if fresh:
            with open(path, "a") as stream:
                for record in fresh:
                    stream.write(json.dumps(record) + "\n")
    return fresh, 0


def cmd_record(args):
    sd = _store.state_dir()
    run_dir = sd / "benches" / args.run_id
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        raise ValueError(f"unknown run id: {args.run_id}")
    meta = json.loads(meta_path.read_text())
    worktree = meta.get("worktree") is True
    if getattr(args, "bench", False) and not worktree:
        raise ValueError(
            "--bench is the opt-in a worktree run needs to keep its verdicts; a durable run "
            f"already stores them — record {shlex.quote(args.run_id)} without it"
        )
    # Every commit-point review is a worktree run, and no worktree run has ever been a corpus row:
    # the corpus is a benchmark instrument judged by two sealed judges on durable commits. What
    # the plain command does reach is durable adjudication state, and it is the one a chat copies
    # at the end of a round — storing the fixer's own triage and sending the round to a judging
    # contract nobody asked for.
    if worktree and not getattr(args, "no_corpus", False) and not getattr(args, "bench", False):
        raise ValueError(
            "a commit-point review never enters the corpus — report with "
            f"`review-bench record {shlex.quote(args.run_id)} --no-corpus`; no corpus row is "
            "written either way, and --bench is the opt-in that additionally stores this run's "
            "verdicts in verdicts.jsonl, for benchmark workflows Egor asked for by name"
        )
    record_raters = _panel.completed_raters_from_meta(meta)
    # A run nobody found anything in still owes a report, and demanding an empty file for it is
    # the friction that got the whole pass skipped. Coverage below still refuses a missing file
    # the moment there is one finding to judge.
    verdict_rows = [
        row for row in _store.read_jsonl(Path(args.verdicts))
        if "rater" in row
    ] if args.verdicts else []
    verdict_map = {}
    for row in verdict_rows:
        rater = row.get("rater")
        idx = row.get("idx")
        verdict = row.get("verdict")
        if (
            rater not in record_raters
            or not isinstance(idx, int)
            or idx < 0
            or verdict not in _catalog.VERDICTS
        ):
            raise ValueError(f"invalid verdict row: {row}")
        key = (rater, idx)
        if key in verdict_map:
            raise ValueError(f"duplicate verdict for {rater} index {idx}")
        verdict_map[key] = verdict

    findings = {rater: _store.finding_rows(run_dir, rater) for rater in record_raters}
    if not args.verdicts:
        total = sum(len(rows) for rows in findings.values())
        if total:
            raise ValueError(f"--verdicts is required: {total} finding(s) to judge")
    for rater, rows in findings.items():
        expected = {(rater, idx) for idx in range(len(rows))}
        supplied = {key for key in verdict_map if key[0] == rater}
        if supplied != expected:
            missing = sorted(expected - supplied)
            extra = sorted(supplied - expected)
            raise ValueError(f"verdict coverage mismatch for {rater}: missing={missing}, extra={extra}")

    canonical = sorted(
        key for key, verdict in verdict_map.items() if verdict == "confirmed"
    )
    normalized_verdicts = [
        {"rater": rater, "idx": idx, "verdict": verdict}
        for (rater, idx), verdict in sorted(verdict_map.items())
    ]
    verdict_path = run_dir / "verdicts.jsonl"
    verdict_existed = verdict_path.exists()
    stored = [row for row in _store.read_jsonl(verdict_path) if "rater" in row]
    verdicts_changed = not verdict_existed or stored != normalized_verdicts
    # The fixer's own triage is what makes the report readable at the end of a round, and it is
    # not what the corpus is for: judged against a checkout that already holds the fixes, it is a
    # different ruler from the two sealed judges reviews.jsonl is built on. It is reported and
    # then dropped, because every state between pending and adjudicated is read by something:
    # a verdict file alone leaves `list` calling the run pending, `cluster` refusing its whole
    # commit for the missing defects.jsonl, and the receipt logic scoring it as a review that
    # found nothing — while a later ordinary record finds the file already matching and skips
    # the corpus row it owes.
    if getattr(args, "no_corpus", False):
        # One sentence that holds in every state, because narrating the run's state here was
        # wrong three review rounds running: pending or adjudicated, worktree or durable, the
        # fact this line owes the reader is which store the triage went into and which it did
        # not. "Recorded nothing" was read as "not triaged" by two workers and an orchestrator
        # (2026-08-24) over a run whose report renders and whose debt settles.
        print(
            f"--no-corpus: {len(normalized_verdicts)} verdict(s) triaged into this run's "
            "report receipt; no corpus row written"
        )
        # The one thing it does leave: proof the report was printed, so the stop gate stops
        # asking. Nothing reads this name but the gate, which is why it can exist without
        # putting the run into the half-adjudicated state the comment above refuses.
        no_corpus_summary = _panel.bench_summary(run_dir, meta, normalized_verdicts)
        _round.write_report_receipt(
            run_dir, normalized_verdicts,
            no_corpus_summary["severities"], no_corpus_summary["docs"],
        )
        _report.emit_report(run_dir, meta, normalized_verdicts)
        _round.emit_fix_handoff(run_dir, meta, normalized_verdicts)
        return 0
    if worktree:
        if verdicts_changed:
            _store.write_jsonl(verdict_path, normalized_verdicts)
            _report.log_review_event("adjudicated", run_dir, meta)
        print(
            "recorded worktree adjudication; corpus skipped because worktree snapshots "
            "are not durable corpus commits"
        )
        _report.emit_report(run_dir, meta)
        _round.emit_fix_handoff(run_dir, meta, normalized_verdicts)
        return 0
    caught_by = {key: {key[0]} for key in canonical}
    for key, verdict in verdict_map.items():
        if verdict != "duplicate" or not canonical:
            continue
        source = findings[key[0]][key[1]]
        target = max(
            canonical,
            key=lambda candidate: _store.finding_similarity(
                source, findings[candidate[0]][candidate[1]]
            ),
        )
        caught_by[target].add(key[0])
    meta_by_rater = {row["rater"]: row for row in meta.get("rater_runs", [])}
    repo_name = _store.repo_identity(meta.get("repo"))
    if not repo_name:
        # A run whose meta names a sealed copy that has since been deleted still has a known
        # repository in the corpus, and re-adjudication replaces its rows: resolving to
        # nothing here is what would quietly strip an already-established one.
        repo_name = next(
            (row["repo"] for row in _store.read_jsonl(sd / "reviews.jsonl")
             if row.get("run_id") == args.run_id and row.get("repo")),
            None,
        )
    if not repo_name:
        print(f"warning: {args.run_id} reviewed {meta.get('repo') or 'an unrecorded repository'}, "
              f"which no longer resolves; its rows cannot be traced back to code")
    records = []
    for rater in record_raters:
        # A run stored under the pre-rename id must stay adjudicable; review_counts already
        # credits those rows, and refusing them here is what strands the run entirely.
        parsed = _raters.recorded_rater(rater)
        rows = findings[rater]
        values = [verdict_map[(rater, idx)] for idx in range(len(rows))]
        counts = Counter(values)
        priorities = Counter(
            rows[idx].get("severity") for idx, verdict in enumerate(values)
            if verdict == "confirmed"
        )
        unique_catches = sum(
            key[0] == rater and len(accounts) == 1
            for key, accounts in caught_by.items()
        )
        caught = sum(rater in accounts for accounts in caught_by.values())
        duration = meta_by_rater.get(rater, {}).get(
            "duration_ms", meta.get("durations", {}).get(rater)
        )
        verify_ms = meta_by_rater.get(rater, {}).get("verify_ms")
        record = {
            "run_id": args.run_id, "ts": _store.iso_now(), "commit": meta["commit"],
            "rater": rater, "rater_model": parsed["model"], "rater_effort": parsed["effort"],
            "findings": len(rows), "p1": priorities["P1"], "p2": priorities["P2"],
            "p3": priorities["P3"], "confirmed": counts["confirmed"],
            "false_positive": counts["false_positive"], "duplicate": counts["duplicate"],
            "confirmed_pct": (counts["confirmed"] / len(rows) * 100)
            if rows else 0.0,
            "fp_pct": (counts["false_positive"] / len(rows) * 100) if rows else 0.0,
            "unique_catches": unique_catches, "misses": len(canonical) - caught,
            "weighted_score": sum(priorities[p] * weight for p, weight in _catalog.WEIGHTS.items()),
            "duration_ms": duration,
        }
        passes = meta_by_rater.get(rater, {}).get("passes")
        if passes:
            record["passes"] = passes
        if verify_ms is not None:
            record["verify_ms"] = verify_ms
        model_resolved = meta_by_rater.get(rater, {}).get("model_resolved")
        if model_resolved:
            record["rater_model_resolved"] = model_resolved
        if repo_name:
            record["repo"] = repo_name
        # Only the rows the verifier could touch: a Claude or Codex row in a verified review is
        # still raw (VERIFIED_SIDES is the verifier's own boundary).
        if meta.get("verifier") and parsed.get("side") in _round.VERIFIED_SIDES:
            record["verifier"] = meta["verifier"]
        # The hash beside the slug because a lens is edited between runs: the slug is what the
        # rows are grouped by, and the hash is the only way to tell which text was measured.
        if meta.get("lens"):
            record["lens"] = meta["lens"]
            if meta.get("lens_hash"):
                record["lens_hash"] = meta["lens_hash"]
        records.append(record)
    defects = []
    for number, key in enumerate(canonical, 1):
        finding = findings[key[0]][key[1]]
        defects.append({
            "defect_id": f"{args.run_id}#{number}",
            "file": finding.get("file"),
            "line": finding.get("line"),
            "severity": finding.get("severity"),
            "summary": finding.get("summary"),
            "canonical_rater": key[0],
            "canonical_idx": key[1],
            "caught_by": sorted(caught_by[key]),
        })
    # A crash between writing the artifacts and appending to the corpus leaves rows with no
    # verdict file: without this the correction writes artifacts and leaves the rows stale.
    already_recorded = any(row.get("run_id") == args.run_id
                           for row in _store.read_jsonl(sd / "reviews.jsonl"))
    # The attribution artifacts land first: a corpus row claiming a run is recorded while its
    # per-defect attribution failed to write is the state this whole flow exists to prevent.
    _store.write_jsonl(verdict_path, normalized_verdicts)
    _store.write_jsonl(run_dir / "defects.jsonl", defects)
    readjudicated = (verdict_existed and stored != normalized_verdicts) or (
        already_recorded and not verdict_existed)
    fresh, dropped = append_review_records(
        sd, records, replace_run=args.run_id if readjudicated else None
    )
    if verdicts_changed or fresh:
        _report.log_review_event("adjudicated", run_dir, meta)
    if readjudicated:
        print(f"re-adjudicated: replaced {dropped} row(s) with {len(fresh)} rater row(s)")
    else:
        print(f"recorded {len(fresh)} rater row(s); "
              f"skipped {len(records) - len(fresh)} existing row(s)")
    _report.emit_report(run_dir, meta)
    _round.emit_fix_handoff(run_dir, meta, normalized_verdicts)
    return 0


def main():
    parser = argparse.ArgumentParser(description="Benchmark blind code-review raters")
    subparsers = parser.add_subparsers(dest="command", required=True)
    tiers = subparsers.add_parser("tiers", help="Print the canonical review tiers")
    tiers.add_argument("--table", action="store_true", help="Print the owner composition table")
    tiers.set_defaults(func=cmd_tiers)
    review = subparsers.add_parser("review", help="Run a canonical review tier")
    review.add_argument("commitish", nargs="?")
    review.add_argument("--worktree", action="store_true")
    review.add_argument("--debt", action="store_true", help=DEBT_FLAG_HELP)
    review.add_argument("--all", action="store_true", help=DEBT_ALL_FLAG_HELP)
    review.add_argument("--range", metavar="A..B", help=RANGE_FLAG_HELP)
    review.add_argument("--repo", action="append", metavar="PATH", help=REPO_FLAG_HELP)
    review.add_argument("--scope-lines", type=int, metavar="N", help=DEBT_SCOPE_LINES_HELP)
    review.add_argument("--this-repo-only", action="store_true", help=DEBT_ALONE_FLAG_HELP)
    review.add_argument("--reason", default="", metavar="TEXT",
                       help="Why this repository goes alone, recorded with the run")
    review.add_argument("--tier", choices=_catalog.REVIEW_TIERS, required=True)
    review.add_argument("--max", action="store_true", help="Use the full tier composition")
    review.add_argument(
        "--foreground", action="store_true",
        help="Run the panel in this process instead of detaching it",
    )
    review.add_argument("--focus", default="")
    review.add_argument(
        "--chunk", action="store_true",
        help="Split the diff at file boundaries and have each cell read the chunks one after "
             "another; off unless the diff is past the byte gate no cell survives whole",
    )
    # extend, not the default store: a repeated --paths silently kept only the last flag's
    # list, and a review scoped to one file of fifteen reported itself exactly like a full one.
    review.add_argument("--paths", nargs="+", action="extend", metavar="PATH",
                        help=SCOPE_FLAG_HELP)
    review.add_argument("--lens", default="", metavar="SLUG", help=_prompts.LENS_FLAG_HELP)
    # cmd_review hands off to cmd_run, so a refusal it cannot express is a refusal it ignores.
    review_verify = review.add_mutually_exclusive_group()
    review_verify.add_argument(
        "--verify", metavar="MODEL", choices=_verify.verifier_choices(),
        help=f"Check every finding back against the file it cites with this in-plan "
             f"OpenCode model, and keep only the claims that survive (default "
             f"{_catalog.OPENCODE_VERIFIER}); agy findings are judged by {_catalog.GEMINI_VERIFIER} first and "
             f"reach this model only where that transport declined",
    )
    review_verify.add_argument(
        "--no-verify", action="store_true",
        help="Report every finding unchecked, including the ones that cite code as it is not",
    )
    review.set_defaults(func=cmd_review_detached)
    wait = subparsers.add_parser(
        "wait", help="Block until a detached panel is over, then print what it handed over"
    )
    wait.add_argument("run_id")
    wait.add_argument(
        "--session", default="", metavar="ID",
        help="Refuse the run unless this chat launched it",
    )
    wait.set_defaults(func=cmd_wait)
    receipt = subparsers.add_parser(
        "receipt", help="Print this repository's review receipt as JSON"
    )
    receipt.add_argument("--repo", default=".")
    receipt.add_argument(
        "--lens", default="", metavar="SLUG",
        help="Print that lens's own receipt instead of the repository's review receipt",
    )
    receipt.add_argument(
        "--scope", nargs="+", metavar="PATH",
        help="Print that scope's own receipt instead of the repository's review receipt",
    )
    receipt.set_defaults(func=_round.cmd_receipt)
    report = subparsers.add_parser("report", help="Print a compact benchmark run report")
    report.add_argument("run_id", nargs="?")
    report.add_argument("--last", action="store_true", help="Report the newest run")
    report.add_argument(
        "--session", default="", metavar="ID",
        help="Refuse the run (exit 2) unless this chat launched it",
    )
    report.add_argument(
        "--line", nargs="?", const="triaged", choices=("triaged", "fork"), metavar="STATE",
        help="One delivery line instead of the block: the triaged tally (default) or the fork",
    )
    report.set_defaults(func=_report.cmd_report)
    fork = subparsers.add_parser(
        "fork",
        help="Print which way a triaged round goes from here, or record its decision",
    )
    fork.add_argument("run_id")
    fork.add_argument("--choice", choices=_round.FORK_CHOICES, help="The way the round goes")
    fork.add_argument(
        "--why", metavar="TEXT",
        help=f"The reasoning behind the choice, never a list of findings, "
             f"up to {_round.FORK_WHY_MAX_CHARS} characters. "
             f"{_round.DECISION_QUESTIONS}",
    )
    fork.add_argument("--session", default="", metavar="ID", help="The chat recording it")
    fork.add_argument(
        "--check", action="store_true",
        help="Exit 3 while the round owes a decision and has none on record",
    )
    fork.set_defaults(func=_report.cmd_fork)
    decision = subparsers.add_parser(
        "decision",
        help="Print the decision recorded on a round as its own block (exit 1 if none)",
    )
    decision.add_argument("run_id")
    decision.add_argument(
        "--session", default="", metavar="ID",
        help="Refuse the run (exit 2) unless this chat launched it",
    )
    decision.set_defaults(func=_report.cmd_decision)
    pending = subparsers.add_parser(
        "pending-report",
        help="Name the worktree run still owing a triaged report (exit 1 if none)",
    )
    pending.add_argument("--repo", default=".", help="Only runs of this repository")
    pending.add_argument(
        "--mark", action="store_true",
        help=f"Count this ask, so a run is asked for at most {_round.TRIAGE_GATE_ASKS} times",
    )
    pending.add_argument(
        "--session", default="", metavar="ID",
        help="Only runs this chat launched, plus any run recording no launching chat",
    )
    pending.set_defaults(func=_round.cmd_pending_report)

    round_open = subparsers.add_parser(
        "round-open",
        help="What this chat's open round in a repository owes: <run-id> TAB ready|decide|round2",
    )
    round_open.add_argument("--repo", default=".", help="The repository to answer for")
    round_open.add_argument("--session", default="", metavar="ID",
                            help="The chat whose rounds to answer for")
    round_open.set_defaults(func=_round.cmd_round_open)

    delivery = subparsers.add_parser(
        "pending-delivery",
        help="Run ids this chat launched whose triage is recorded, one per line",
    )
    delivery.add_argument("--session", default="", metavar="ID", required=True,
                          help="The chat whose runs to answer for")
    delivery.set_defaults(func=_round.cmd_pending_delivery)

    anchor = subparsers.add_parser(
        "review-anchor",
        help="The repository this chat's live or unanswered review is about (exit 1 if none)",
    )
    anchor.add_argument("--session", default="", metavar="ID", required=True,
                        help="The chat whose review to anchor on")
    anchor.add_argument("--cwd", default="", metavar="DIR",
                        help="Prefer the merged-panel member equal to this directory's repository")
    anchor.set_defaults(func=_round.cmd_review_anchor)

    fixes = subparsers.add_parser(
        "fixes", help="Record whether a triaged round's confirmed findings were fixed"
    )
    fixes.add_argument("run_id", nargs="?",
                       help="the round; only --cover may leave it out and resolve its own")
    fixes_state = fixes.add_mutually_exclusive_group(required=True)
    fixes_state.add_argument(
        "--done", action="store_true", help="the confirmed findings are fixed"
    )
    fixes_state.add_argument(
        "--blocked", metavar="REASON", help="why the pass stopped"
    )
    fixes_state.add_argument(
        "--cover", action="store_true",
        help="close the fixing pass of every round this commit finished and cover what it landed",
    )
    fixes.add_argument("--commit", metavar="SHA",
                       help="the commit that carried the fixes (with --cover)")
    fixes.add_argument("--repo", metavar="PATH",
                       help="the checkout the commit landed in (with --cover)")
    fixes.add_argument("--session", metavar="ID",
                       help="the chat whose rounds this closes; defaults to the calling chat")
    fixes.add_argument("--fixed", type=int, metavar="N",
                       help="confirmed findings fixed (with --done; defaults to the triage's own)")
    fixes.add_argument("--fp", type=int, metavar="M",
                       help="findings that turned out false while fixing (with --done)")
    fixes.set_defaults(func=_round.cmd_fixes)

    debt = subparsers.add_parser(
        "debt",
        help="What this repository owes a review, in one line the gate reads",
    )
    debt.add_argument("--repo", default=".")
    debt.add_argument("--session", default="", metavar="ID", help="The asking chat")
    debt.add_argument(
        "--command", action="store_true",
        help="Print the --debt review command for the asking chat instead of its debt: merged "
             "over every repository that chat owes, since one round settles only what it read",
    )
    debt.add_argument(
        "--paths", nargs="*", action="extend", default=[], metavar="PATH",
        help="Repository-relative paths to answer for",
    )
    debt_answer = debt.add_mutually_exclusive_group()
    debt_answer.add_argument(
        "--list", action="store_true",
        help="Print the debt paths themselves, one per line, instead of the verdict",
    )
    debt_answer.add_argument(
        "--split", action="store_true",
        help="Print `split <own> <foreign> <orphaned>` diff lines instead of the verdict",
    )
    debt.set_defaults(func=_debt.cmd_debt)

    waive = subparsers.add_parser(
        "waive",
        help="Record that this work is going unreviewed, and why",
    )
    waive.add_argument("--repo", default=".")
    waive.add_argument("--reason", default="", metavar="TEXT", help="Why it is going unreviewed")
    waive.add_argument(
        "--paths", nargs="*", action="extend", default=[], metavar="PATH",
        help="Repository-relative paths to waive; every debt path without them",
    )
    waive.set_defaults(func=_debt.cmd_waive)

    run = subparsers.add_parser("run", help="Run blind reviewers against one commit")
    run.add_argument("commitish", nargs="?")
    run.add_argument("--worktree", action="store_true")
    run.add_argument("--range", metavar="A..B", help=RANGE_FLAG_HELP)
    run.add_argument("--repo", action="append", metavar="PATH", help=REPO_FLAG_HELP)
    selection = run.add_mutually_exclusive_group()
    selection.add_argument("--tier", choices=_catalog.REVIEW_TIERS)
    selection.add_argument(
        "--raters",
        help="Comma-separated rater specs; append ' xN' with N from 2 to 9 to repeat a cell",
    )
    selection.add_argument("--auto", type=int, metavar="N", help="Pick N least-reviewed cells")
    selection.add_argument(
        "--leg", action="store_true",
        help="Run the measured OpenCode composition — the only cells that survived strict "
             "adjudication on four commits, and no vendor quota at all",
    )
    run.add_argument("--max", action="store_true", help="Use the full tier composition")
    run.add_argument(
        "--foreground", action="store_true",
        help="Allow long tiers when stdout is not a terminal",
    )
    run.add_argument("--focus", default="")
    # Spelled on the bench run too, or the rerun line a chunked panel prints replays it unchunked.
    run.add_argument(
        "--chunk", action="store_true",
        help="Split the diff at file boundaries and have each cell read the chunks one after "
             "another; off unless the diff is past the byte gate no cell survives whole",
    )
    run.add_argument("--paths", nargs="+", action="extend", metavar="PATH",
                     help=SCOPE_FLAG_HELP)
    run.add_argument("--lens", default="", metavar="SLUG", help=_prompts.LENS_FLAG_HELP)
    # Exclusive, or `--verify X --no-verify` runs the verifier and says nothing about having
    # ignored the refusal.
    run_verify = run.add_mutually_exclusive_group()
    run_verify.add_argument(
        "--verify", metavar="MODEL", choices=_verify.verifier_choices(),
        help="Refused here, and spelled here so the refusal can name its reason: the verifier "
             "is a tier review's, and a bench row records what the rater said",
    )
    run_verify.add_argument(
        "--no-verify", action="store_true",
        help="Accepted and does nothing — a bench run reports every finding unchecked either "
             "way, and older reproduce lines spell the flag",
    )
    run.set_defaults(func=cmd_run)
    record = subparsers.add_parser("record", help="Record blind adjudication verdicts")
    record.add_argument("run_id")
    record.add_argument(
        "--verdicts",
        help="Verdict file; may be omitted only for a run with no findings to judge",
    )
    record.add_argument(
        "--no-corpus", action="store_true",
        help="report the verdicts without writing a corpus row (a fix round's own triage)"
    )
    record.add_argument(
        "--bench", action="store_true",
        help="benchmark mode: store a worktree run's verdicts in its verdicts.jsonl, for "
             "benchmark workflows Egor asked for by name (no corpus row either way)"
    )
    record.set_defaults(func=cmd_record)
    cluster = subparsers.add_parser(
        "cluster", help="Reconcile one commit's per-run defect lists into a canonical list"
    )
    cluster.add_argument("commit")
    cluster.add_argument("--groups", required=True)
    cluster.set_defaults(func=_stats.cmd_cluster)
    frontier = subparsers.add_parser(
        "frontier", help="Best measured rater composition for each waiting time"
    )
    frontier.add_argument("--commits", default="", metavar="A,B,C")
    frontier.add_argument("--budgets", default="2,6,10,20", metavar="MIN,MIN")
    frontier.add_argument("--max-cells", type=int, default=8, metavar="N")
    frontier.set_defaults(func=_stats.cmd_frontier)
    oc_models = subparsers.add_parser(
        "oc-models", help="Measured OpenCode capability table and recorded per-cell health"
    )
    oc_models.set_defaults(func=_stats.cmd_oc_models)
    findings = subparsers.add_parser(
        "findings", help="A run's findings grouped by the place they point at, agreement first"
    )
    findings.add_argument("run_id", nargs="?")
    findings.add_argument("--last", action="store_true", help="The newest run")
    findings.set_defaults(func=_report.cmd_findings)
    health = subparsers.add_parser(
        "health", help="Why recorded cells failed, per run, side, account and cell"
    )
    health.add_argument(
        "--limit", type=int, default=_report.HEALTH_DEFAULT_RUNS, metavar="N",
        help=f"only the newest N runs (default {_report.HEALTH_DEFAULT_RUNS}; 0 for every run)",
    )
    health.set_defaults(func=_report.cmd_health)
    doctor = subparsers.add_parser(
        "doctor",
        help="Anomalies in the review system's own records: runs nobody judged, reports nobody "
             "delivered, rounds nobody fixed, locks nothing opens, debt nobody owns",
    )
    doctor_mode = doctor.add_mutually_exclusive_group()
    doctor_mode.add_argument(
        "--json", action="store_true", help="One JSON object with the counts and their rows",
    )
    # Outside the group with the two agent flags: this one only ALSO writes the document, so it
    # composes with either output form, and refusing `--json --snapshot` made a collector that
    # wants both run the whole scan twice.
    doctor.add_argument(
        "--snapshot", action="store_true",
        help=f"Also write the counts to <state-dir>/{_debt.DOCTOR_SNAPSHOT}, which the menubar reads",
    )
    doctor_mode.add_argument(
        "--install-agent", action="store_true",
        help=f"Install the launchd collector that takes that snapshot every "
             f"{_debt.DOCTOR_AGENT_INTERVAL_S // 3600}h",
    )
    doctor_mode.add_argument(
        "--uninstall-agent", action="store_true", help="Remove that collector, plist and wrapper",
    )
    doctor.set_defaults(func=_debt.cmd_doctor)
    lens = subparsers.add_parser(
        "lens", help="Registered review lenses and whether each still matches its source"
    )
    lens.add_argument("action", choices=("list", "check"))
    lens.add_argument("slug", nargs="?", help="The lens to check")
    lens.set_defaults(func=_stats.cmd_lens)
    board = subparsers.add_parser(
        "board", help="Per-cell comparison table: catch, wall clock, anchored coverage and cost"
    )
    board.add_argument("--tier", choices=_catalog.REVIEW_TIERS, help="Only cells in this tier")
    board_family = board.add_mutually_exclusive_group()
    board_family.add_argument("--no-oc", action="store_true", help="Drop the OpenCode cells")
    board_family.add_argument("--oc-only", action="store_true", help="Only the OpenCode cells")
    board_format = board.add_mutually_exclusive_group()
    board_format.add_argument("--tsv", action="store_true", help="Tab-separated, tier as a column")
    board_format.add_argument("--json", action="store_true", help="One object per cell")
    board.add_argument(
        "--hand", action="store_true",
        help="Carry the hand-scored block into --tsv/--json too (the text table always has it)",
    )
    board.set_defaults(func=_stats.cmd_board)
    listing = subparsers.add_parser("list", help="List recent benchmark runs")
    listing.add_argument("--limit", type=int, default=20)
    listing.set_defaults(func=_stats.cmd_list)
    args = parser.parse_args()
    try:
        return args.func(args)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        print(f"review-bench: {exc}", file=sys.stderr)
        return 2
