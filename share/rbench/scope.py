import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from . import store as _store

# Where a merged review's own repository is built and kept, and the file inside one that names the
# repositories it was built from.
MERGED_DIR = "merged"
MERGED_MANIFEST = ".review-bench-merged.json"
MERGED_HOME_HEX = 16
SCOPE_TRAILER = "Scope-Path: "
# The subject line a debt review's sealed commit carries, and the only thing that tells one from
# an ordinary worktree snapshot: both are sealed under the same identity, and a rerun pinned to
# the sha has nothing else left to read the mode off.
DEBT_SNAPSHOT_SUBJECT = "review-bench debt snapshot"
# Past this many BYTES of diff a commit is chunked whether or not anybody asked; each chunk is
# packed to the target below. Both are measured in `diff_chunks` and duplicated in
# docs/review-contract.md, guarded by row `ax`.
DIFF_CHUNK_THRESHOLD_BYTES = 800_000
DIFF_CHUNK_TARGET_LINES = 800
def scope_pathspec_base(repo):
    """The repository root and the directory a `--paths` pathspec is spelled against. Asked by the
    reader of a scope and by the writer of a command that carries one, because a command printed in
    one spelling and read in the other reviewed a path that was never there: `sub/mine.txt` printed
    for a caller standing in `sub` came back as `sub/sub/mine.txt` and matched nothing.
    """
    top = Path(repo).resolve()
    try:
        cwd = Path.cwd()
    except OSError:
        cwd = top
    return top, cwd if cwd == top or top in cwd.parents else top


def normalize_scope_paths(repo, paths, option="--paths", root_is_everything=False):
    """The scope as the snapshot records it and as its receipt is named: repository-relative,
    lexically canonical, deduplicated and sorted, so two callers naming the same files differently
    — a different order, a `.`/`..` segment, an absolute path — review the same tree and answer to
    the same receipt.

    A relative pathspec is resolved the way the caller's shell would read it, against the current
    directory, since a caller standing in a subdirectory means the file beside them. Only a caller
    standing outside the repository has no such meaning to offer, and is read repository-relative.

    `root_is_everything` is for a commit pathspec rather than a review scope: `git commit -- .` at
    the top carries every tracked change, and an empty pathspec is how the callers here spell that
    same set, while a review scoped to the whole tree is a scope nobody asked for.
    """
    top, base = scope_pathspec_base(repo)
    normalized = set()
    everything = False
    for raw in paths:
        path = str(raw).strip()
        if not path:
            raise ValueError(f"{option} names no path: {raw!r}")
        # The snapshot records one trailer per path, and a trailer is a line: a path carrying a
        # newline would be read back as a scope nobody asked for.
        if "\n" in path or "\r" in path:
            raise ValueError(f"{option} entries may not contain newlines")
        relative = _store.scope_path_relative(
            top, path if os.path.isabs(path) else os.path.join(str(base), path)
        )
        if relative is None:
            raise ValueError(f"{option} names a path outside the repository: {raw}")
        if relative == os.curdir:
            if not root_is_everything:
                raise ValueError(f"{option} names no path: {raw!r}")
            everything = True
            continue
        normalized.add(relative)
    if everything:
        return []
    if not normalized:
        raise ValueError(f"{option} needs at least one path")
    return sorted(normalized)


def diff_base(repo, commit):
    """What `commit` is a change against: its parent, or the empty tree when it has none. A root
    commit introduces its whole content, and reading it as an unmeasurable diff instead is what
    made a day-one repository review as an empty change.
    """
    proc = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{commit}^"],
                          cwd=repo, capture_output=True, text=True)
    if proc.returncode == 0 and proc.stdout.strip():
        return proc.stdout.strip()
    return _store.empty_tree_hash(repo)


def head_tree_hash(repo):
    """HEAD's tree, or the empty tree when the repository has no commit yet. Every worktree path
    that spelled `HEAD` died on `Not a valid object name HEAD` in a checkout whose first commit is
    still pending, which is exactly the state the files in it most want reviewing from.
    """
    proc = subprocess.run(["git", "rev-parse", "--verify", "--quiet", "HEAD^{tree}"],
                          cwd=repo, capture_output=True, text=True)
    if proc.returncode == 0 and proc.stdout.strip():
        return proc.stdout.strip()
    return _store.empty_tree_hash(repo)


def working_tree_tree(repo, paths=None, env=None, literal=False):
    scope = literal_pathspecs(paths or []) if literal else list(paths or [])
    with tempfile.TemporaryDirectory(prefix="review-bench-index-") as directory:
        env = dict(env or os.environ, GIT_INDEX_FILE=str(Path(directory) / "index"))
        add = ("add", "-A", "--", *scope) if scope else ("add", "-A")
        for command in (("read-tree", head_tree_hash(repo)), add):
            proc = subprocess.run(
                ["git", *command], cwd=repo, env=env, capture_output=True, text=True,
            )
            if proc.returncode != 0:
                detail = proc.stderr.strip() or proc.stdout.strip() or "git failed"
                if scope and "did not match any files" in detail:
                    raise ValueError(f"--paths matched nothing: {detail}")
                raise RuntimeError(f"could not compute working tree: {detail}")
        proc = subprocess.run(
            ["git", "write-tree"], cwd=repo, env=env, capture_output=True, text=True,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            detail = proc.stderr.strip() or proc.stdout.strip() or "git write-tree failed"
            raise RuntimeError(f"could not compute working tree: {detail}")
        return proc.stdout.strip()


def tree_path_entries(repo, tree, paths, literal=False):
    """The `(mode, blob)` this tree holds under each of `paths`, keyed by path. A gitlink is left
    out: a submodule is not a blob, and overlaying one would rewrite a pointer nobody reviewed.
    """
    if not paths:
        return {}
    spelled = literal_pathspecs(paths) if literal else list(paths)
    proc = subprocess.run(["git", "ls-tree", "-r", "-z", tree, "--", *spelled],
                          cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"could not read the tree {tree}")
    entries = {}
    for record in proc.stdout.split("\0"):
        info, tab, path = record.partition("\t")
        fields = info.split()
        if tab and len(fields) == 3 and fields[1] == "blob":
            entries[path] = (fields[0], fields[2])
    return entries


def reachable_blobs(repo, shas):
    """Which of `shas` this repository can still read as blobs. An artifact records a sha and
    never the object behind it, so a store that was gc'd or a snapshot fetched from elsewhere
    leaves shas nothing can be diffed against — and a base built on one is a review of an error.
    """
    wanted = sorted({str(sha) for sha in shas if sha})
    if not wanted:
        return set()
    proc = subprocess.run(
        ["git", "cat-file", "--batch-check=%(objectname) %(objecttype)"],
        cwd=repo, input="".join(f"{sha}\n" for sha in wanted), capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return set()
    return {
        line.split()[0] for line in proc.stdout.splitlines() if line.endswith(" blob")
    }


def overlay_tree(repo, tree, entries):
    """`tree` with every path of `entries` set to the `(mode, blob)` it names, or removed where it
    names None.

    This is how both self-scoping reviews build their LEFT end: the result differs from `tree` at
    the named paths and nowhere else, so the diff the panel reads holds exactly the scope. A debt
    review overlays the content the covering artifact recorded, a scoped range overlays the range's
    own base — and in both cases the commits in between are invisible, which is the point: what is
    under review is the drift since something last stood behind the file, not the shape the work
    was committed in.
    """
    if not entries:
        return tree
    zero = "0" * (64 if _store.object_format(str(repo)) == "sha256" else 40)
    payload = "".join(
        (f"{entry[0]} {entry[1]}\t{path}\0" if entry else f"0 {zero}\t{path}\0")
        for path, entry in sorted(entries.items())
    )
    with tempfile.TemporaryDirectory(prefix="review-bench-overlay-") as directory:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / "index"))
        for command, stdin in ((["read-tree", tree], None),
                               (["update-index", "-z", "--index-info"], payload)):
            proc = subprocess.run(["git", *command], cwd=repo, env=env, input=stdin,
                                  capture_output=True, text=True)
            if proc.returncode != 0:
                detail = proc.stderr.strip() or proc.stdout.strip() or "git failed"
                raise RuntimeError(f"could not build the review base: {detail}")
        proc = subprocess.run(["git", "write-tree"], cwd=repo, env=env,
                              capture_output=True, text=True)
        if proc.returncode != 0 or not proc.stdout.strip():
            detail = proc.stderr.strip() or proc.stdout.strip() or "git write-tree failed"
            raise RuntimeError(f"could not build the review base: {detail}")
        return proc.stdout.strip()


def synthetic_base_commit(repo, tree, subject):
    """A parentless commit holding `tree`, so everything downstream that derives what a review is a
    change against from the sealed commit's parent needs nothing taught about a base nobody wrote.
    """
    proc = subprocess.run(
        ["git", "commit-tree", tree, "-m", subject],
        cwd=repo, env=dict(os.environ, **_store.FIXED_COMMIT_IDENTITY),
        stdin=subprocess.DEVNULL, capture_output=True, text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(proc.stderr.strip() or "could not build the review base")
    return proc.stdout.strip()


def worktree_snapshot_commit(repo, clean_command=None, paths=None):
    scope = list(paths or [])
    tree = working_tree_tree(repo, scope)
    head_commit = subprocess.run(["git", "rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
                                 cwd=repo, capture_output=True, text=True)
    head = head_commit.stdout.strip() if head_commit.returncode == 0 else ""
    if tree == head_tree_hash(repo):
        if scope:
            raise ValueError(
                "no changes under the given paths: " + " ".join(scope)
                + "; widen --paths or drop it to review the whole working tree"
            )
        raise ValueError(
            "working tree matches HEAD; review the commit instead: "
            + (clean_command or "review-bench review HEAD --tier <tier>")
        )
    message = "review-bench worktree snapshot"
    if scope:
        # Carried in the commit rather than on the rerun line: a rerun names the snapshot sha and
        # nothing else, so a scope kept outside it would silently widen to the whole tree.
        message += "\n\n" + "".join(f"{SCOPE_TRAILER}{path}\n" for path in scope)
    proc = subprocess.run(
        # A snapshot of a repository with no commit yet is a root commit, and `-p ''` is a parent
        # git refuses outright; diff_base reads its whole content against the empty tree.
        ["git", "commit-tree", tree, *(("-p", head) if head else ()), "-m", message],
        cwd=repo, env=dict(os.environ, **_store.FIXED_COMMIT_IDENTITY),
        capture_output=True, text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(proc.stderr.strip() or "could not create worktree snapshot")
    return proc.stdout.strip()


def announce_review_target(repo, sha, scope=(), members=None, head_label=None, chunks=0):
    """What this run is about to send to the panel, said out loud before it goes: which base to
    which head, how many files, how many lines, under which scope. Returns that size as
    `{"files": n, "lines": n}`, which is what the record keeps and the report's `debt:` row prints.

    The target was only ever implied by the flags — `--worktree` reads the tree, a commitish reads
    one commit — and nothing ever printed which one won. A review asked for over work that had just
    been committed read the leftovers still in the working tree instead and came back confirming
    nothing, which is indistinguishable from a clean review of the right target (Egor, 2026-08-07).
    An empty target is refused here rather than reported as a panel that found nothing.
    """
    entries = (
        [(member["label"], Path(member["repo"]), member["commit"], list(member.get("scope") or []),
          member.get("head")) for member in members]
        if members else [(None, Path(repo), sha, list(scope or ()), head_label)]
    )
    described = []
    total_files = 0
    total_lines = 0
    for label, where, commit, narrowed, head_label in entries:
        base = diff_base(where, commit)
        changes, _ = diff_numstat(where, [base, commit])
        total_files += len(changes)
        total_lines += sum(changes.values())
        # A sealed range is named by its own right end: the sha it was sealed into is nothing the
        # caller asked for, and a target line naming it answers a question nobody asked.
        right = head_label or commit
        text = (f"{base[:7]}..{right[:7]} · {len(changes)} file(s) · "
                f"{sum(changes.values())} line(s)")
        if head_label and head_label != commit:
            text += f" · sealed as {commit[:7]}"
        if narrowed:
            text += " · scope: " + " ".join(narrowed)
        if chunks and not label:
            text += f" · {chunks} chunks"
        described.append(f"  {label}/ = {where}: {text}" if label else f"reviewing {where}: {text}")
    if not total_files:
        raise ValueError(
            "this review's target is empty — "
            + "; ".join(line.strip() for line in described)
            + ". Nothing would reach the panel, so a report of it would say only that nobody "
            "found anything in nothing; name the commits to review with --range A..B or a "
            "commitish, or --worktree for uncommitted work."
        )
    if chunks and members:
        described.append(f"  {chunks} chunks over these repositories")
    for line in described:
        print(line, file=sys.stderr)
    # Handed back rather than only printed: the report's `debt:` row is this same size, and priced
    # again at render time it would answer for a tree the fixes have already moved.
    return {"files": total_files, "lines": total_lines}


def parse_range_spec(spec):
    """The two ends of an `A..B`. One parser for `review` and `run` alike, so a shape one of them
    accepts and the other refuses cannot exist.
    """
    left, separator, right = spec.partition("..")
    if not separator or not left or not right or right.startswith("."):
        raise ValueError("--range must be A..B")
    return left, right


def range_snapshot_ends(repo, sha):
    """The two commits a sealed range was sealed from, or None when this sha is not one. Sealed
    commits carry the tool's own committer, so a range would otherwise read as a snapshot of the
    working tree — and a worktree run reviews the current state by construction, which is what lets
    it stamp the repository's receipt without proving it. A range of old commits proves nothing of
    the sort. A rerun arrives as the sealed sha and no flags, so the seal itself is the only place
    the range it stands for can still be read from.
    """
    proc = subprocess.run(["git", "show", "-s", "--format=%B", sha],
                          cwd=repo, capture_output=True, text=True)
    lines = proc.stdout.splitlines() if proc.returncode == 0 else []
    if not lines or lines[0].strip() != "review-bench range snapshot":
        return None
    for line in lines[1:]:
        if ".." not in line:
            continue
        try:
            return parse_range_spec(line.strip())
        except ValueError:
            return None
    return None


def is_range_snapshot(repo, sha):
    return range_snapshot_ends(repo, sha) is not None


def range_snapshot_commit(repo, spec, scope=()):
    """A range of commits sealed as one commit to review: the tree at its right end, carrying its
    left end as the parent. Everything downstream is keyed on a single sha and derives what it is a
    change against from that sha's parent, so a range spelled this way needs nothing else taught —
    `git show` of it is the whole range as one diff, the receipt's base..tree IS the range, and a
    rerun pinned to the sha finds it again. Committed work was reviewable only one commit at a time
    before this, so a change spread over a branch cost one panel per commit, and work already
    pushed could not be sent to a panel at all except through the working tree it was no longer in.

    A `scope` narrows it to those pathspecs the way `--paths` narrows a working tree: the parent
    becomes a synthetic left end holding the range's own base content at exactly those paths and
    the right end's everywhere else, so the sealed diff is the range restricted to them while the
    tree the raters browse stays whole. The message keeps the range's REAL ends, because that is
    the question the caller asked and the synthetic parent answers no question at all.
    """
    left, right = parse_range_spec(spec)
    ends = []
    for name in (left, right):
        commit = _store.resolve_commit(repo, name)
        proc = subprocess.run(["git", "rev-parse", f"{commit}^{{tree}}"],
                              cwd=repo, capture_output=True, text=True)
        if proc.returncode != 0 or not proc.stdout.strip():
            raise RuntimeError(proc.stderr.strip() or f"{name} has no tree")
        ends.append((commit, proc.stdout.strip()))
    (base, base_tree), (head, head_tree) = ends
    if base_tree == head_tree:
        raise ValueError(
            f"{spec} changes nothing: {left} and {right} hold the same tree, so there is no "
            "review in it"
        )
    scope = list(scope or ())
    parent = base
    if scope:
        for pathspec in scope:
            changed, _ = diff_numstat(repo, [base_tree, head_tree], [pathspec])
            if not changed:
                raise ValueError(
                    f"--paths matched nothing in {spec}: {pathspec}; a range is already a fixed "
                    "set of paths, so a pathspec outside its diff narrows the review to nothing"
                )
        was = tree_path_entries(repo, base_tree, scope)
        now = tree_path_entries(repo, head_tree, scope)
        base_tree = overlay_tree(
            repo, head_tree, {path: was.get(path) for path in set(was) | set(now)}
        )
        parent = synthetic_base_commit(repo, base_tree, "review-bench range base")
    message = f"review-bench range snapshot\n\n{base}..{head}\n"
    if scope:
        message += "".join(f"{SCOPE_TRAILER}{path}\n" for path in scope)
    proc = subprocess.run(
        ["git", "commit-tree", head_tree, "-p", parent, "-m", message],
        cwd=repo, env=dict(os.environ, **_store.FIXED_COMMIT_IDENTITY),
        capture_output=True, text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(proc.stderr.strip() or "could not seal the range")
    return proc.stdout.strip()


def debt_snapshot_commit(repo, scope):
    """This repository's whole open question sealed as one commit: the content standing in the
    working tree now, over a synthetic base holding, for every path in `scope`, the content the
    newest artifact that answers for it recorded.

    Nothing else can be the base. The comparison debt is made of is per path and per artifact — one
    file was last read three commits ago, its neighbour is still uncommitted — and no commit in
    this repository holds that mixture, so the review of it has to be built rather than found. Built
    this way the commits under the drift are invisible: work reviewed, committed and then edited
    again reaches the panel as ONE diff from what was read to what is there, which is the whole
    reason a debt review cannot be spelled as a range or as a worktree run.

    The base is the one `debt_line_counts` prices against — `debt_base_blobs` answers both — so the
    panel reads exactly the lines the statusline counts. A path whose recorded blob this store
    cannot read takes the side its price takes: HEAD where the edit is uncommitted, the parent of
    the oldest unreviewed commit where it is not. A path HEAD does not hold is dropped from the
    base instead, and the diff shows the file whole, which is what a file nobody has ever read is
    worth reviewing as.
    """
    from . import debt as _debt  # here and not at module top: debt imports this module at load
    paths = [path for path, _ in scope]
    unusable = [path for path in paths if "\n" in path or "\r" in path]
    if unusable:
        raise ValueError(
            "the debt of this repository names a path carrying a newline, which the snapshot "
            "records one per line and could not read back: " + ", ".join(map(repr, unusable))
        )
    head = head_tree_hash(repo)
    held = tree_path_entries(repo, head, paths, literal=True)
    # A path in neither HEAD nor the working tree is a deletion of something never committed: the
    # run still has to answer for it, but `git add` refuses a pathspec matching nothing at all.
    staged = [path for path in paths if os.path.lexists(Path(repo) / path) or path in held]
    tree = working_tree_tree(repo, staged, literal=True) if staged else head
    current = tree_path_entries(repo, tree, paths, literal=True)
    recorded = _debt.debt_base_blobs(repo, scope)
    base_tree = overlay_tree(repo, tree, {
        # The mode the path wears NOW, so a base built for a content comparison does not report a
        # mode change nobody made; an artifact records a blob and never a mode.
        path: (current.get(path, ("100644", ""))[0], recorded[path])
        if recorded.get(path) else None
        for path in paths
    })
    if base_tree == tree:
        raise ValueError(
            "this repository's debt holds no reviewable change: every path it names stands at the "
            "content the artifact answering for it already recorded, or is gone with nothing ever "
            "recorded for it. Record why with `review-bench waive --reason ...`"
        )
    message = (
        DEBT_SNAPSHOT_SUBJECT + "\n\n"
        "Everything in this repository that nothing stands behind, as one change: for each file\n"
        "below the left side is the content the last review or waiver of it recorded, and the\n"
        "right side is what is there now. The commits in between are deliberately not shown —\n"
        "what is under review is the drift since something last answered for the file.\n\n"
        + "".join(f"{SCOPE_TRAILER}{path}\n" for path in paths)
    )
    proc = subprocess.run(
        ["git", "commit-tree", tree, "-p",
         synthetic_base_commit(repo, base_tree, "review-bench debt base"), "-m", message],
        cwd=repo, env=dict(os.environ, **_store.FIXED_COMMIT_IDENTITY),
        capture_output=True, text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(proc.stderr.strip() or "could not seal the debt review")
    return proc.stdout.strip()


def is_debt_snapshot(repo, sha):
    """Whether this sha is a debt review's seal. A rerun arrives as the sha and no flags, and the
    mode decides two things a scoped worktree run decides the other way: the scope is the whole of
    what the run answers for rather than a narrowing of it, and the receipt it writes is the
    repository's own.
    """
    proc = subprocess.run(["git", "show", "-s", "--format=%s", sha],
                          cwd=repo, capture_output=True, text=True)
    return proc.returncode == 0 and proc.stdout.strip() == DEBT_SNAPSHOT_SUBJECT


def snapshot_scope_paths(repo, sha):
    """The paths a worktree snapshot was scoped to, empty for an unscoped one. A rerun is pinned
    to the snapshot sha and carries no flags, so this is the only place its scope comes from.
    """
    proc = subprocess.run(["git", "show", "-s", "--format=%B", sha],
                          cwd=repo, capture_output=True, text=True)
    # Never an empty scope on a failed read: an unreadable message is indistinguishable from an
    # unscoped snapshot, and guessing the wrong one widens the rerun to the whole tree and stamps
    # the repository's own receipt with it.
    if proc.returncode != 0:
        raise RuntimeError(
            proc.stderr.strip() or f"could not read the snapshot message of {sha}"
        )
    scope = []
    for line in proc.stdout.splitlines():
        if not line.startswith(SCOPE_TRAILER):
            continue
        path = line[len(SCOPE_TRAILER):].strip()
        if path:
            scope.append(path)
    return scope


def is_worktree_snapshot(repo, sha):
    # A rerun of an errored worktree cell is pinned to the snapshot sha and arrives through
    # the commit path; the fixed committer identity is what keeps it out of the corpus.
    proc = subprocess.run(["git", "show", "-s", "--format=%ce", sha],
                          cwd=repo, capture_output=True, text=True)
    return proc.returncode == 0 and proc.stdout.strip() == "review-bench@local"


def literal_pathspecs(paths):
    """`paths` as git pathspecs that mean themselves, for the readers whose paths are FILES rather
    than a caller's pathspecs — a debt scope, computed from the journals and the artifacts, where a
    file honestly named `:(exclude)x` or `*` would otherwise reach git as MAGIC and silently stage,
    review and record a set nobody asked for. The journal hooks spell those same paths this way.
    A `--paths` scope is the opposite case and keeps its globs: the caller wrote them.
    """
    return [f":(literal){path}" for path in paths]


def scope_snapshot_paths(repo, scope, sha):
    """Every file a run with this scope is shown, repository-relative.

    Read out of the SEALED COMMIT and never out of the checkout standing under it: the tree moves
    while the run is in flight, and a path set listed after the seal loses whatever a co-tenant
    reverted meanwhile — files the panel was shown and the record then stops answering for.

    A scope stages the whole subtree under its paths, so the files are listed rather than assumed:
    a scope naming a directory reviewed the files inside it, not a path called after it. An empty
    scope is the whole checkout, where what the panel reads is the change the snapshot holds
    against its base — deletions included, which no listing of a tree can name.
    """
    def named(command):
        proc = subprocess.run(command, cwd=repo, capture_output=True, text=True)
        if proc.returncode != 0:
            return []
        return [path for path in proc.stdout.split("\0") if path]

    base = diff_base(repo, sha)
    if scope:
        return sorted(set(
            named(["git", "ls-tree", "-r", "-z", "--name-only", sha, "--", *scope])
            + named(["git", "diff", "--no-renames", "--name-only", "--diff-filter=D", "-z",
                     base, sha, "--", *scope])
        ))
    return sorted(set(named(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, sha]
    )))


def reviewed_blobs(repo, scope, sha, paths=None):
    """The blob the sealed commit holds for every path the panel is shown, keyed by path. A path
    the snapshot deleted is keyed to the empty string: a deletion is a change the panel read as
    surely as a rewrite is, and no blob can stand for it.

    Read out of that commit and never hashed from the working tree: the tree moves while the run is
    in flight, and a rerun pinned to an existing snapshot sha reads a commit the checkout is already
    far past — either way the anchor would be bytes no rater saw. A symlink's blob is its link
    text, which is exactly what the coverage reader prices it by.

    `paths` names the answered-for set outright instead of deriving it from the diff, which is what
    a debt review needs: a locked round's survivor sitting at exactly the sha that round recorded
    contributes no diff at all, and a run that does not HOLD it discharges no lock — so the run
    that was widened to read it has to record it too.
    """
    listed = list(paths) if paths else scope_snapshot_paths(repo, scope, sha)
    wanted = {path for path in listed if "\n" not in path}
    if not wanted:
        return {}
    proc = subprocess.run(["git", "ls-tree", "-r", "-z", sha],
                          cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0:
        return {}
    blobs, held = {}, set()
    for entry in proc.stdout.split("\0"):
        info, tab, path = entry.partition("\t")
        fields = info.split()
        if not tab or len(fields) != 3 or path not in wanted:
            continue
        held.add(path)
        if fields[1] == "blob":
            blobs[path] = fields[2]
    for path in wanted - held:
        blobs[path] = ""
    return blobs


def repo_arg_paths(args):
    """The repositories a run was pointed at, in the order they were named. `--repo` is repeatable,
    so every reader answers for both shapes — one string from a caller that names one repository,
    a list from one that names several.
    """
    value = getattr(args, "repo", None)
    if not value:
        return ["."]
    return [value] if isinstance(value, str) else list(value)


def sealed_target(repo, spec=None, scope=(), clean_command=None):
    """The commit a review of `repo` reads, and the right end it was asked about: a range sealed
    over its left end, or the working tree sealed as one commit. Every caller — solo run, merged
    member — names its half this way, so the two kinds are two arguments rather than two code paths.
    """
    if spec:
        return (range_snapshot_commit(repo, spec, scope=scope),
                _store.resolve_commit(repo, parse_range_spec(spec)[1]))
    return worktree_snapshot_commit(repo, clean_command=clean_command, paths=scope), None


def parse_repo_source(value):
    """A `--repo` value: the checkout, and the range of commits inside it this run reviews when the
    value names one as `PATH@BASE..HEAD`. Both halves of a cross-repository change are reviewable
    in one panel only if each half can be named the way it actually exists — one branch already
    pushed, the other still in the working tree — and a flag pair that reads every repository the
    same way sent the second half to a panel of its own (Egor, 2026-08-08).

    The range is split off the END, so a checkout whose own path holds an `@` still resolves; what
    marks the suffix as a range rather than as part of the path is the `..` inside it.
    """
    text = str(value)
    path, separator, spec = text.rpartition("@")
    if not separator or ".." not in spec:
        return text, None
    # `/srv/a@b/x..y/repo` is a directory, not repository `/srv/a` reviewed over range `b/x..y/repo`
    # — and both halves of that misreading name things nobody asked for.
    if os.path.isdir(text) and not os.path.isdir(path):
        return text, None
    if not path:
        raise ValueError(f"--repo names no repository before its range: {value}")
    parse_range_spec(spec)
    return path, spec


def repo_sources(args):
    """Every `--repo` of a run, parsed: what to read and, where one is named, which range of it."""
    return [parse_repo_source(path) for path in repo_arg_paths(args)]


def merged_repo_labels(repos):
    """The directory prefix each repository is mounted under in a merged review. A rater reads these
    instead of repository paths and a scope is spelled with them, so it is the basename; two
    checkouts sharing one get numbered rather than silently merging into a single prefix.
    """
    labels = []
    for repo in repos:
        base = Path(repo).name or "repo"
        label = base
        attempt = 2
        while label in labels:
            label = f"{base}-{attempt}"
            attempt += 1
        labels.append(label)
    return labels


def split_merged_scope(pairs, paths, option="--paths"):
    """Which repository each pathspec of a merged review narrows, keyed by label.

    A pathspec carries the prefix the raters read in the diff, so a scope is spelled the way the
    findings answering it will be; an absolute path is taken as well, because that is the other
    spelling a caller has in hand, and the deepest repository containing it owns it. A repository
    nobody names keeps its whole working tree — narrowing one half of a cross-repository contract
    is the normal case — and an unrecognised prefix is refused rather than read as a directory of
    whichever repository was named first.
    """
    labels = dict(pairs)
    grouped = {label: [] for label in labels}
    for raw in paths:
        text = str(raw).strip()
        if not text:
            raise ValueError(f"{option} names no path: {raw!r}")
        if os.path.isabs(text):
            owner = None
            for label, repo in labels.items():
                if _store.scope_path_relative(repo, text) is None:
                    continue
                if owner is None or len(str(labels[owner])) < len(str(repo)):
                    owner = label
            if owner is None:
                raise ValueError(
                    f"{option} names a path outside every repository under review: {raw}"
                )
            grouped[owner].append(text)
            continue
        label, separator, rest = text.partition("/")
        if not separator or not rest.strip("/") or label not in labels:
            raise ValueError(
                f"{option} entries of a merged review start with the repository's own prefix ("
                + ", ".join(f"{name}/" for name in labels) + f"): {raw}"
            )
        grouped[label].append(os.path.join(str(labels[label]), rest))
    return {
        label: normalize_scope_paths(labels[label], entries, option) if entries else []
        for label, entries in grouped.items()
    }


def merged_members(sources, paths=()):
    """Each repository of a merged review: its prefix, its sealed snapshot, what that snapshot was
    taken against and the scope it was narrowed to. Sealed exactly as a single-repository run seals
    one — `--worktree` for a repository named alone, `--range` for one named as `PATH@BASE..HEAD` —
    because these snapshots are what each repository's own receipt is written against afterwards,
    and a member is therefore worth exactly what the same review of it alone would have been.
    """
    sources = [source if isinstance(source, tuple) else (source, None) for source in sources]
    repos = [path for path, _ in sources]
    labels = merged_repo_labels(repos)
    scopes = split_merged_scope(list(zip(labels, repos)), paths)
    members = []
    for label, (repo, spec) in zip(labels, sources):
        scope = scopes[label]
        if spec:
            commit, head = sealed_target(repo, spec, scope=scope)
            members.append({
                "label": label, "repo": str(repo), "commit": commit,
                "base": diff_base(repo, commit), "scope": scope,
                # What the caller asked about, kept for every line that names this member: the
                # sealed commit is the tool's own and answers no question anybody asked.
                "head": head,
            })
            continue
        try:
            commit, _ = sealed_target(repo, scope=scope)
        except ValueError as exc:
            raise ValueError(
                f"--repo {repo} has nothing for a merged review to read ({exc}); every named "
                "repository is sealed and stamped by the run, so drop that --repo or review it "
                "on its own"
            ) from exc
        members.append({
            "label": label, "repo": str(repo), "commit": commit,
            "base": diff_base(repo, commit), "scope": scope,
        })
    return members


def merged_snapshot_message(members):
    """What the merged snapshot commit says about itself. It is the first thing every rater reads —
    `git show` prints it above the diff — so it has to say that the leading directory of each path
    is a separate checkout rather than one project's subtree, or the panel reasons about the halves
    of a cross-repository contract as if they had to agree as one tree.
    """
    ranged = all(member.get("head") for member in members)
    lines = [
        "review-bench merged range snapshot" if ranged
        else "review-bench merged worktree snapshot",
        "",
        "One change across several repositories, each sealed as a review of it alone would be and",
        "mounted under its own top-level directory. Every path below is that directory followed by",
        "the path inside that repository; the directories are separate checkouts, not subtrees of",
        "one project, and the change is meant to be read as a single contract spanning them.",
        "",
    ]
    for member in members:
        detail = (f"range {member['base'][:7]}..{member['head'][:7]}"
                  if member.get("head") else f"on {member['base'][:7]}")
        if member["scope"]:
            detail += ", scope: " + " ".join(member["scope"])
        lines.append(f"  {member['label']}/ = {member['repo']} ({detail})")
    return "\n".join(lines) + "\n"


def merged_manifest(repo):
    """The repositories a merged workspace was built from, or None for an ordinary repository.

    A rerun of an errored cell is pinned to the merged commit and names the workspace, and the
    workspace is the only place the repositories it owes receipts to are still written down.
    """
    try:
        document = json.loads((Path(repo) / MERGED_MANIFEST).read_text())
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(document, dict) or not isinstance(document.get("merged"), str):
        return None
    members = document.get("repos")
    if not isinstance(members, list) or not members:
        return None
    for member in members:
        if not isinstance(member, dict) or any(
            not isinstance(member.get(field), str) or not member[field]
            for field in ("label", "repo", "commit")
        ):
            return None
        if not isinstance(member.get("scope", []), list):
            return None
    return document


def merged_finding_label(path, members):
    """Which repository a finding is about: the prefix its path carries. Empty when it carries none
    of them, which is a rater citing a place outside the review — a fact the adjudicator has to
    see rather than a repository picked on its behalf.
    """
    text = str(path or "")
    for member in members:
        if text == member["label"] or text.startswith(f"{member['label']}/"):
            return member["label"]
    return ""


def prune_merged_workspaces(directory=None):
    """Workspaces of runs that can no longer be rerun. TRIAGE_GATE_HOURS is how long a worktree run
    is still live business, and past that its scaffolding goes rather than leaving a checkout per
    merged review on disk forever.
    """
    directory = directory or _store.state_dir() / MERGED_DIR
    if not directory.is_dir():
        return
    horizon = time.time() - _store.TRIAGE_GATE_HOURS * 3600
    for path in sorted(directory.iterdir()):
        try:
            if not path.is_dir() or path.stat().st_mtime > horizon:
                continue
        except OSError:
            continue
        shutil.rmtree(path, ignore_errors=True)


def merged_snapshot_workspace(members):
    """The one repository a merged review is read out of, and its merged snapshot commit: every
    member's snapshot under its own prefix, over a base commit holding what each was sealed
    against. `git show` of that commit is the whole cross-repository change as one diff, and every
    reader downstream — the sealed clones, the verifier's file lookups, the finding-path
    resolution — goes on working against a single repository.

    Objects are borrowed from the members to build it and then repacked into it: a workspace still
    borrowing anything is refused rather than reviewed, because a gc in a member repository would
    take the reviewed code with it.

    Named after the commit it holds, which is a function of the trees, the prefixes, the bases and
    the scopes it was built from — so the rerun of an errored cell, pinned to that commit, finds
    the workspace it needs already on disk.
    """
    def git(*arguments, env=None):
        proc = subprocess.run(["git", *arguments], env=env, capture_output=True, text=True,
                              timeout=900)
        if proc.returncode != 0:
            raise RuntimeError(
                f"merged workspace: git {arguments[0]} failed: "
                f"{proc.stderr.strip() or proc.returncode}"
            )
        return proc.stdout.strip()

    alternates = []
    for member in members:
        common = _store.git_common_dir(member["repo"])
        if common is None:
            raise RuntimeError(f"cannot reach the object store of {member['repo']}")
        alternates.append(str(common / "objects"))
    root = _store.state_dir() / MERGED_DIR
    root.mkdir(parents=True, exist_ok=True)
    prune_merged_workspaces(root)
    # Staged inside the store it will live in, so the move into place is a rename rather than a
    # copy a reader could catch half-finished.
    staging = Path(tempfile.mkdtemp(prefix=".staging-", dir=root))
    borrowed = staging / ".git" / "objects" / "info" / "alternates"
    try:
        git("init", "-q", str(staging))
        borrowed.write_text("".join(f"{path}\n" for path in alternates))
        trees = []
        for field in ("base", "commit"):
            index = staging / ".git" / f"review-bench-{field}-index"
            env = dict(os.environ, GIT_INDEX_FILE=str(index))
            for member in members:
                git("-C", str(staging), "read-tree", f"--prefix={member['label']}/",
                    member[field], env=env)
            trees.append(git("-C", str(staging), "write-tree", env=env))
            index.unlink(missing_ok=True)
        identity = dict(os.environ, **_store.FIXED_COMMIT_IDENTITY)
        base = git("-C", str(staging), "commit-tree", trees[0],
                   "-m", "review-bench merged base", env=identity)
        merged = git("-C", str(staging), "commit-tree", trees[1], "-p", base,
                     "-m", merged_snapshot_message(members), env=identity)
        git("-C", str(staging), "update-ref", "HEAD", merged)
        git("-C", str(staging), "repack", "-adq")
        borrowed.unlink()
        # Connectivity only: what has to be proven is that nothing is still borrowed, and rehashing
        # every blob of every member on top of that would cost the review minutes.
        git("-C", str(staging), "fsck", "--no-progress", "--connectivity-only")
        document = json.dumps(
            {"merged": merged, "repos": [dict(member) for member in members]}, indent=2
        ) + "\n"
        (staging / MERGED_MANIFEST).write_text(document)
        home = root / merged[:MERGED_HOME_HEX]
        # A name taken by something that is not a repository is a prune interrupted halfway, and
        # reusing it would hand the run a workspace with no objects in it.
        if home.exists() and not (home / ".git").is_dir():
            shutil.rmtree(home, ignore_errors=True)
        moved = False
        if not home.exists():
            try:
                os.replace(staging, home)
                moved = True
            except OSError:
                moved = False
        if not moved:
            # The commit is a function of everything that went into it, so a workspace already
            # under this name holds these very objects; only its manifest is rewritten, because
            # the run about to start is the one that has to be answered for.
            (home / MERGED_MANIFEST).write_text(document)
            os.utime(home)
            shutil.rmtree(staging, ignore_errors=True)
        return home, merged
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def diff_numstat(repo, revisions, paths=None, env=None, no_index=False):
    # Renames are detected, not expanded into a delete plus an add: a moved file with no edits is
    # one file and zero lines, and counting it as 2N lines escalates a trivial move to T3. With -z
    # a rename record ends with an empty path and carries the old and new names as the next two
    # NUL-separated fields — which is also the shape `--no-index` answers in, so the two modes
    # parse alike.
    #
    # `--no-index` compares two files outside the object store, for content no commit holds: it
    # exits 1 when they differ, which is its answer and not a failure, and a trailing `--` makes it
    # print the pair as ONE path, so the pathspec terminator goes in only for a revision diff.
    proc = subprocess.run(
        ["git", "diff", "--numstat", "-z", "--find-renames",
         *(("--no-index",) if no_index else ()), *revisions,
         *(() if no_index else ("--", *(paths or ())))],
        cwd=repo, capture_output=True, env=env,
    )
    if proc.returncode != 0 and not (no_index and proc.returncode == 1):
        raise RuntimeError(proc.stderr.decode(errors="replace").strip() or "git diff failed")
    fields = proc.stdout.split(b"\0")
    changes = {}
    renames = {}
    index = 0
    while index < len(fields):
        record = fields[index]
        index += 1
        if not record:
            continue
        added, deleted, raw_path = record.split(b"\t", 2)
        lines = 0 if added == b"-" or deleted == b"-" else int(added) + int(deleted)
        if not raw_path:
            if index + 1 >= len(fields):
                break
            raw_path = fields[index + 1]
            renames[os.fsdecode(raw_path)] = os.fsdecode(fields[index])
            index += 2
        changes[os.fsdecode(raw_path)] = lines
    return changes, renames


def diff_file_body(repo, sha, path, source=None):
    """One path's slice of a commit's diff. Asked of git per path rather than cut out of the whole
    diff: a review of this very repository carries diff text INSIDE its own diff, so splitting on
    the `diff --git` line would cut a chunk in the middle of a quoted patch.

    `source` is the path a rename came FROM, and it goes into the pathspec beside the destination:
    asked about the destination alone, git has nothing to pair it with and renders the rename as a
    brand-new file — the deletion of the source in no chunk at all, and a reviewer told a moved
    file was written from scratch.
    """
    proc = subprocess.run(
        # Through `:(literal)`, because this path came out of git's own listing and is a FILE: a
        # changed file honestly named `*` or `:(exclude)x` reaching git as MAGIC matches nothing,
        # and the chunk claiming to hold it would carry an empty diff.
        ["git", "show", "--format=", "--no-ext-diff", sha, "--",
         *literal_pathspecs([source, path] if source else [path])],
        cwd=repo, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"git show failed for {path}")
    return proc.stdout


def diff_chunk_groups(changes):
    """The commit's changed paths packed into groups of at most the chunk target, in the order git
    prints them.

    Packed at FILE boundaries and nowhere else, because a reviewer handed half a file reports the
    other half as missing: a group goes over the target only where ONE file does, and that file is
    a group of its own, read whole.
    """
    groups, current, current_lines = [], [], 0
    for path, lines in changes.items():
        if current and current_lines + lines > DIFF_CHUNK_TARGET_LINES:
            groups.append(current)
            current, current_lines = [], 0
        current.append(path)
        current_lines += lines
    if current:
        groups.append(current)
    return groups


def diff_chunks(repo, sha, force=False):
    """A commit's diff split into what one cell reads, or `[]` where the whole of it goes to a cell
    unsplit. Chunking is off unless `force` says a caller asked for it, or the diff is past the
    byte gate below, where it stops being reviewable at all.

    LINE count does not predict a death (665 stored runs / 7197 cells, 2026-08-27): a 19,313-line
    diff at 36 bytes/line was reviewed whole by claude, codex and opencode alike, and the deaths a
    line threshold was built for are not visible in the data — a few percent either side of 1500,
    with no spike. What IS deterministic is a BYTE wall, and only one commit on record ever hit it:
    7ed59ee, 13,263 lines but 2,397,508 bytes, killed every diff-fed leg in under two seconds —
    claude with `[Errno 7] Argument list too long` (the diff rides argv), codex with its own
    1,048,576-character `input_too_large`, opencode with a context length. So the gate is
    `DIFF_CHUNK_THRESHOLD_BYTES`. It sits under both ceilings with room to spare, because the
    claude leg's diff shares macOS's 1,048,576-byte ARG_MAX with the environment and the review
    template beside it: 800 KB leaves ~250 KB of that for them and is still above the 687 KB
    largest diff any unchunked cell ever completed. Everything below it is the caller's judgement
    rather than the tool's: chunking costs ~4.7x wall clock on claude, a cell reading its chunks
    one after another.

    Each chunk is a diff of its own — the commit header, which files it holds, and their hunks —
    so a cell reading one needs nothing the run does not hand it. Cut at FILE boundaries only: a
    file over the target is one chunk read whole rather than pieces of itself, and a commit that
    IS one such file is handed out unsplit, since a reviewer given part of a file reports the rest
    of it as missing and no two pieces of it ever see each other's text.
    """
    base = diff_base(repo, sha)
    # The DIFF's own bytes and not numstat's lines: what a cell is handed is this text, headers and
    # context included, and what kills it is how much of it there is — a commit of many small
    # scattered edits prices low by any line count while the prompt it produces is several times
    # that. Asked of the whole commit in one call, so nothing but a chunked commit pays for the
    # per-file reads below.
    whole = subprocess.run(["git", "show", "--format=", "--no-ext-diff", sha],
                           cwd=repo, capture_output=True, text=True)
    if whole.returncode != 0:
        raise RuntimeError(whole.stderr.strip() or "git show failed")
    if not force and len(whole.stdout.encode("utf-8")) <= DIFF_CHUNK_THRESHOLD_BYTES:
        return []
    changes, renames = diff_numstat(repo, [base, sha])
    proc = subprocess.run(["git", "show", "-s", "--format=fuller", sha],
                          cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "git show failed")
    header = proc.stdout
    bodies = {path: diff_file_body(repo, sha, path, renames.get(path)) for path in changes}
    measured = {path: len(body.splitlines()) for path, body in bodies.items()}
    pieces = [
        (paths, "".join(bodies[path] for path in paths))
        for paths in diff_chunk_groups(measured)
    ]
    if len(pieces) < 2:
        return []
    chunks = []
    for index, (paths, body) in enumerate(pieces):
        note = (
            f"This is chunk {index + 1} of {len(pieces)} of commit {sha}'s diff. The commit was "
            "split at file boundaries so that no reviewer is handed more diff than it reads "
            "reliably; the other chunks are being reviewed in parallel by other cells. Review "
            "ONLY what is below, and report nothing about what is missing from it. Files in this "
            "chunk: " + ", ".join(paths)
        )
        chunks.append({
            "index": index, "paths": list(paths),
            "diff": f"{header}\n{note}\n\n{body}",
        })
    return chunks


def cell_artifact(rater):
    """The stem this cell's raw artifacts are named with. A chunked cell reads its chunks one after
    another under ONE rater name, so the chunk rides the stem: two invocations writing one
    `raw-<spec>` file would leave the run priced and its model resolved at the last chunk alone."""
    chunk = rater.get("chunk")
    return f"{rater['spec']}~c{chunk['index']}" if chunk else rater["spec"]


def cell_envelope(run_dir, spec):
    """The raw envelope a cell's resolved model is read from — its own, or its first chunk's where
    the cell read several, since every chunk of one cell resolves the same model."""
    direct = run_dir / f"raw-{spec}.json"
    if direct.exists():
        return direct
    pieces = sorted(run_dir.glob(f"raw-{spec}~c*.json"))
    return pieces[0] if pieces else direct


def cell_chunk_paths(rater):
    """The files a chunked cell may look at, for the sides that read the repository instead of a
    pasted diff. Empty for an unchunked cell, which reads the commit whole."""
    chunk = rater.get("chunk")
    return list(chunk["paths"]) if chunk else []


def unread_chunk_paths(chunks, raters, errored=()):
    """The files of a chunked panel that no RECORDED cell read: every path held by a chunk not one
    such cell's pass over it came back from, whatever killed those passes.

    `raters` is the panel with the errored cells taken out. A cell the run discards — an unusable
    answer, a 429 of its own — has no findings file and no row anybody adjudicates, so counting
    the chunks it opened as covered attests content that reached no reader at all.

    `errored` names the cells the run discards — an unusable answer, a 429 of its own. Such a cell
    has no findings file and no row anybody adjudicates, so a chunk only IT opened is a chunk that
    reached no reader at all.

    A round covers its scope on its triage receipt alone, and that receipt may only attest content
    somebody actually read. Under chunking a dead pass is no longer a redundant reader — it is a
    slice of the commit nobody opened — so the paths those chunks held stay out of the run's
    snapshot and remain in debt, while everything that came back covers its own paths as always.
    A file split into pieces is unread where ANY of its pieces is: half a file read is not the file.
    """
    if not chunks:
        return set()
    alive = set()
    for rater in raters:
        if rater.get("spec") in errored:
            continue
        alive.update(rater.get("chunks_read") or ())
    return {
        path for chunk in chunks if chunk["index"] not in alive for path in chunk["paths"]
    }


def attested_paths(reviewed, unread, prefix=""):
    """A run's snapshot with the paths nothing read taken out of it. `prefix` is a merged member's
    label, since a chunk names paths of the merged workspace and a member's snapshot names its
    own."""
    if not unread:
        return reviewed
    return {path: sha for path, sha in reviewed.items() if f"{prefix}{path}" not in unread}


