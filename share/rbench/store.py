import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from functools import lru_cache
from difflib import SequenceMatcher
from pathlib import Path
from chat_names import worker_run_root, worker_session_launchers

# The package sits two levels under the repository root, and everything the program resolves
# by path hangs off these two: bin/review-bench (the shim launchd plists name), the sibling
# binaries command_path finds, and lenses/.
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BIN_DIR = REPO_ROOT / "bin"

# Hours a worktree run keeps owing its report. Past that the diff it reviewed is stale, so the
# gate stops asking rather than dragging an old run into an unrelated turn.
TRIAGE_GATE_HOURS = 6
# What `settle-delivery` writes beside a round whose report the window above has left behind:
# `{"state": ..., "queued": <iso>}` puts it back in front of its launching chat at any age, and
# `{"state": ..., "lapsed": <iso>}` records that the chat it was owed to is gone from disk, so
# nobody will ever read it. Neither is a delivery — the ledger row `au` describes stays the only
# record that a report reached Egor — and a lapsed round is still listed, by `doctor --lapsed`.
DELIVERY_MARK = "delivery.json"
REPORT_RECEIPT = "reported.json"
FIX_RECEIPT = "fixes.json"
DECREE_RECEIPT = "decree.json"
# The two heaviest panels are the owner's to start, and no agent's: tier T3, and any tier's --max
# composition. Enforcement is code on both sides — `bin/review-owner-gate.sh` denies the command
# until Egor names the panel himself, and the guard below refuses the same two panels wherever
# that hook does not run (a worker's own process, a plain shell). Naming one only unblocks it —
# nothing in this tool ever proposes a panel, so a passing mention never becomes what runs.
OWNER_TIERS = ("T3",)
OWNER_GRANT_DIR = "review-grants"
OWNER_GRANT_TTL_S = 1800

RECEIPT_DIR = "receipts"
PROGRESS_DIR = "progress"
# Where the harness registers a live chat, one file per pid, and how far up the parents a run may
# look for the one that launched it.
SESSION_REGISTRY_DIR_ENV = "REVIEW_BENCH_SESSION_DIR"
SESSION_WALK_HOPS = 15
RECEIPT_FIELDS = ("repo", "tree", "commit", "run_id", "ts")
RECEIPT_HASH_HEX = 8
# The one command that answers a repository's whole open question — the second review a locked
# round owes included, since the mode widens to that round's surviving paths by construction. The
# commit gate prints it verbatim inside a `cd`, and docs/shared-invariants.md holds the two equal;
# a caller that hand-picks paths instead is choosing the scope, which is the choice this removes.
DEBT_REVIEW_COMMAND = "REVIEW_ASKED=1 review-bench review --debt --tier T1"
# Where the artifacts that answer for a path live: the waivers beside the receipts, and the two
# journals beside each other in the git directory a chat commits from.
WAIVER_DIR = "waivers"
WAIVER_LOCK = ".waivers.lock"
DEBT_JOURNAL = "claude-review-debt"
COMMIT_JOURNAL = "claude-commit-journal"
# One identity and one clock behind every commit object review-bench writes, so the same input
# always answers with the same sha. The email is also how a snapshot is told from a real commit.
FIXED_COMMIT_IDENTITY = {
    "GIT_AUTHOR_NAME": "review-bench",
    "GIT_AUTHOR_EMAIL": "review-bench@local",
    "GIT_AUTHOR_DATE": "2005-04-07T22:13:13 +0000",
    "GIT_COMMITTER_NAME": "review-bench",
    "GIT_COMMITTER_EMAIL": "review-bench@local",
    "GIT_COMMITTER_DATE": "2005-04-07T22:13:13 +0000",
}
def utc_now():
    return datetime.now(timezone.utc)


def iso_now():
    return utc_now().isoformat()


def state_dir():
    override = os.environ.get("WORKER_STATS_DIR")
    if override:
        return Path(override)
    base = os.environ.get(
        "CLAUDEB_DIR", str(Path.home() / ".claude-profiles" / ".claudeb")
    )
    return Path(base) / "worker-stats"


# Memoized because the callers ask it once per recorded run and hundreds of runs name a handful of
# checkouts: on the statusline's own path that was hundreds of git processes inside a 3s timeout.
@lru_cache(maxsize=None)
def git_common_dir(repo):
    # A receipt may record a repository path that no longer exists; subprocess with a
    # missing cwd raises instead of failing, so the guard is here, for every caller.
    if not Path(repo).is_dir():
        return None
    proc = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"],
        cwd=repo, capture_output=True, text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    common = Path(proc.stdout.strip())
    if not common.is_absolute():
        common = Path(repo) / common
    try:
        return common.resolve(strict=True)
    except OSError:
        return None


def resolve_repo_arg(path, require_worktree=False):
    """The working tree `path` sits in, which is the identity a receipt and a progress file are
    keyed on. Resolving no further than `Path.resolve()` keyed them on the directory the caller
    happened to stand in, so a run started from a subdirectory wrote a name nothing could predict
    and a reader had to fall back to matching on the repository — which is shared by every linked
    worktree, and made one worktree's review show up in its siblings.

    A bare repository has no working tree and still answers a commit-only review and a `--range`
    run out of its object database, so it keeps the path it was given. Only a caller that
    must read a tree asks for one.
    """
    repo = Path(path).resolve()
    # Resolved before it becomes a cwd: `--repo ""` is a directory by `Path("").is_dir()` and a
    # FileNotFoundError by subprocess.
    if not repo.is_dir():
        return None
    top = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=repo, capture_output=True, text=True,
    )
    if top.returncode == 0 and top.stdout.strip():
        return Path(top.stdout.strip()).resolve()
    if require_worktree:
        return None
    inside = subprocess.run(
        ["git", "rev-parse", "--git-dir"], cwd=repo, capture_output=True,
    )
    return repo if inside.returncode == 0 else None


def scope_receipt_slug(scope):
    return hashlib.sha1("\0".join(scope).encode()).hexdigest()[:RECEIPT_HASH_HEX]


def receipt_file_name(repo, lens=None, scope=None):
    """The repository's review receipt, or a lens's, a scope's, or a scoped lens's own beside it.
    None of those read what the ordinary receipt answers for: a lens run read the tree by a
    methodology the tool did not write, and a scoped run read only some of it. The ordinary
    receipt answers for the whole repository, so any of them sharing it would declare the whole
    repository reviewed.
    """
    repo_path = str(Path(repo).resolve())
    repo_name = repo_identity(repo_path)
    if not repo_name:
        return None
    repo_hash = hashlib.sha1(repo_path.encode()).hexdigest()[:RECEIPT_HASH_HEX]
    if lens and scope:
        return f"{repo_name}__{repo_hash}__lens-{lens}__scope-{scope_receipt_slug(scope)}.json"
    if lens:
        return f"{repo_name}__{repo_hash}__lens-{lens}.json"
    if scope:
        return f"{repo_name}__{repo_hash}__scope-{scope_receipt_slug(scope)}.json"
    return f"{repo_name}__{repo_hash}.json"


def progress_file_name(repo, pid=None):
    receipt_name = receipt_file_name(repo)
    if not receipt_name:
        return None
    return f"{receipt_name[:-5]}-{pid if pid is not None else os.getpid()}.json"


def session_stamp():
    """The chat that launched this run, for a reader that has only the document. Absent rather than
    empty when the harness named none, so the key's presence alone says whether a chat can be
    named and no reader has to treat a blank value as a session it failed to resolve.
    """
    session = os.environ.get("CLAUDE_CODE_SESSION_ID")
    return {"session": session} if session else {}


def session_registry_dir():
    directory = os.environ.get(SESSION_REGISTRY_DIR_ENV)
    return Path(directory) if directory else Path.home() / ".claude" / "sessions"


def parent_pid(pid):
    try:
        line = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            capture_output=True, text=True, check=False,
        ).stdout.strip()
    except OSError:
        return None
    return int(line) if line.isdigit() else None


def walk_launching_session(pid=None):
    """The chat that launched this process, read from the harness registry keyed by pid: a run is
    that chat's grandchild several execs down, so the launcher is the nearest ancestor with an
    entry. Only worth asking at run start — a backgrounded run outlives its launcher and reparents
    to pid 1, which is why the answer is recorded rather than walked again by every reader.
    """
    directory = session_registry_dir()
    pid = os.getpid() if pid is None else pid
    for _ in range(SESSION_WALK_HOPS):
        if pid is None or pid <= 1:
            break
        try:
            entry = json.loads((directory / f"{pid}.json").read_text())
        except (OSError, ValueError):
            entry = None
        session = entry.get("sessionId") if isinstance(entry, dict) else None
        if isinstance(session, str) and session:
            return session
        pid = parent_pid(pid)
    return None


def launching_session():
    return session_stamp().get("session") or walk_launching_session()


def caller_chat():
    """The chat the caller's shell answers to: its own session, or the chat that launched it where
    the shell is a worker's. A worker a chat spawned IS that chat (docs/shared-invariants.md row
    `am`), and a command it runs on the round's behalf is the launcher's command.
    """
    session = launching_session()
    return worker_session_launchers().get(session, session) if session else session


def round_session(run_dir):
    """The chat a round answers to: the session its own run record names, and the caller's only
    where the record names none.

    Read off the RECORD and not off the environment, so which shell typed `record` or `fixes` —
    the launching chat, its claudeb worker, a codex worker inheriting the chat's variables, a bare
    terminal — cannot move a round's report, its receipt or its fix coverage to another chat. The
    launching session is stamped once, at launch, by the only process that could know it.
    """
    try:
        recorded = json.loads((run_dir / "meta.json").read_text()).get("session")
    except (OSError, ValueError):
        recorded = None
    return recorded if isinstance(recorded, str) and recorded else (caller_chat() or "")


def review_progress_document(repo, run_id, tier, target, cells, started=None, pid=None,
                             max_panel=False, expected=None, started_epoch=None, session=None):
    timestamp = started or iso_now()
    return {
        "repo": str(Path(repo).resolve()),
        "pid": pid if pid is not None else os.getpid(),
        "run_id": run_id,
        "tier": tier,
        "max": bool(max_panel),
        "target": target,
        "cells": list(cells),
        "done": [],
        "expected": dict(expected or {}),
        "failed": 0,
        "started": timestamp,
        # One moment, one clock read: an epoch stamped here a second read later would let the
        # two start fields disagree about when the run began.
        "started_epoch": int(started_epoch if started_epoch is not None else time.time()),
        "ts": timestamp,
        **({"session": session} if session else session_stamp()),
    }


def complete_review_progress(progress, cell, failed, timestamp=None):
    progress["done"].append(cell)
    if failed:
        progress["failed"] += 1
    progress["ts"] = timestamp or iso_now()
    return progress


def persist_review_progress(path, progress, timestamp=None):
    tmp = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        progress["ts"] = timestamp or iso_now()
        tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
        tmp.write_text(json.dumps(progress) + "\n")
        os.replace(tmp, path)
        tmp = None
        return path
    finally:
        if tmp is not None:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass


def prune_review_progress(repo, directory=None):
    directory = directory or state_dir() / PROGRESS_DIR
    directory.mkdir(parents=True, exist_ok=True)
    own_name = progress_file_name(repo)
    if not own_name:
        raise RuntimeError("repository identity is unavailable")
    prefix = own_name.rsplit("-", 1)[0]
    pattern = re.compile(rf"^{re.escape(prefix)}-(\d+)\.json$")
    # iterdir, not glob(f"{prefix}-*.json"): a repository directory named with glob
    # metacharacters would turn the prefix into a pattern and the prune would miss its files.
    for path in directory.iterdir():
        match = pattern.fullmatch(path.name)
        if not match:
            continue
        try:
            os.kill(int(match.group(1)), 0)
        except ProcessLookupError:
            # An unlink that fails must not abort the caller's progress init over one
            # stale file another process may have just removed or locked.
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
        except (PermissionError, OSError):
            pass


def review_receipt(repo, lens=None, scope=None):
    name = receipt_file_name(repo, lens, scope)
    if not name:
        return None
    path = state_dir() / RECEIPT_DIR / name
    try:
        receipt = json.loads(path.read_text())
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(receipt, dict) or any(
        not isinstance(receipt.get(field), str) or not receipt[field]
        for field in RECEIPT_FIELDS
    ):
        return None
    if isinstance(receipt.get("errored"), bool) or not isinstance(receipt.get("errored"), int) \
            or receipt["errored"] < 0:
        return None
    if git_common_dir(repo) != git_common_dir(receipt["repo"]):
        return None
    proc = subprocess.run(
        ["git", "cat-file", "-t", receipt["tree"]],
        cwd=repo, capture_output=True, text=True,
    )
    return receipt if proc.returncode == 0 and proc.stdout.strip() == "tree" else None


def persist_review_receipt(repo, tree, sha, run_id, errored, timestamp=None, panel=None,
                           lens=None, scope=None):
    tmp = None
    try:
        name = receipt_file_name(repo, lens, scope)
        if not name:
            raise RuntimeError("repository identity is unavailable")
        directory = state_dir() / RECEIPT_DIR
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
        receipt = {
            "repo": str(repo), "tree": tree, "commit": sha,
            "run_id": run_id, "ts": timestamp or iso_now(), "errored": errored,
            **session_stamp(),
        }
        # The reader weighs errored cells against the panel they came from: one silent cell out
        # of nine is not the same coverage loss as four, and only the run knows how many it sent.
        if isinstance(panel, int) and not isinstance(panel, bool) and panel > 0:
            receipt["panel"] = panel
        # Carried in the document as well as the name: everything the receipt is weighed
        # against — its run's corpus rows, its findings — has to come from the same
        # methodology, and the reader has only the receipt it was handed.
        if lens:
            receipt["lens"] = lens
        # The name carries only a hash of the scope, and a reader handed the receipt has to be
        # able to say which files the run behind it actually read.
        if scope:
            receipt["scope"] = list(scope)
        tmp.write_text(json.dumps(receipt) + "\n")
        os.replace(tmp, path)
        tmp = None
        return path
    finally:
        if tmp is not None:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass


def write_review_receipt(repo, sha, run_id, errored, panel=None, worktree=False, lens=None,
                         scope=None):
    try:
        proc = subprocess.run(
            ["git", "rev-parse", f"{sha}^{{tree}}"],
            cwd=repo, capture_output=True, text=True,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            raise RuntimeError("reviewed tree is unavailable")
        tree = proc.stdout.strip()
        # A bench run of a historical commit must not move the repository's receipt
        # backwards: it reviewed old code, not the current state. Worktree runs review
        # the current state by construction (sha is the snapshot commit).
        if not worktree:
            head = subprocess.run(
                ["git", "rev-parse", "HEAD^{tree}"],
                cwd=repo, capture_output=True, text=True,
            )
            if head.returncode == 0 and head.stdout.strip() and head.stdout.strip() != tree:
                print(
                    "receipt not written: the reviewed tree is not the repository's "
                    "current state (historical bench run)", file=sys.stderr,
                )
                return None
        return persist_review_receipt(repo, tree, sha, run_id, errored, panel=panel, lens=lens,
                                      scope=scope)
    except Exception as exc:
        print(f"warning: could not write review receipt: {exc}", file=sys.stderr)
        return None


def scope_path_relative(top, candidate):
    """`candidate` as a path under `top`, or None when it lies outside. Lexical first and only
    lexically for anything that already reads as inside: a pathspec is matched by git against the
    repository's own paths, so following a symlink out of the tree would hand git a path it does
    not know. The resolved retry exists for the reverse case only — `/var/x` and `/private/var/x`
    are the same directory, and a caller who typed one while the repository was discovered as the
    other is naming a path inside it.
    """
    for base, target in ((top, candidate), (Path(top).resolve(), Path(candidate).resolve())):
        relative = os.path.relpath(os.path.normpath(str(target)), str(base))
        if relative != os.pardir and not relative.startswith(os.pardir + os.sep):
            return relative
    return None


def empty_tree_hash(repo):
    # Asked of the repository rather than written down: the well-known 4b825dc… is the SHA-1
    # answer, and a repository on another object format has its own.
    proc = subprocess.run(["git", "hash-object", "-t", "tree", os.devnull],
                          cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(proc.stderr.strip() or "could not compute the empty tree hash")
    return proc.stdout.strip()


def read_jsonl(path):
    rows = []
    if not path.exists():
        return rows
    with open(path) as stream:
        for number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{number}: invalid JSON: {exc.msg}") from exc
            if not isinstance(row, dict):
                raise ValueError(f"{path}:{number}: expected a JSON object")
            rows.append(row)
    return rows


def write_jsonl(path, rows):
    """Written through a temp file: a kill mid-write would otherwise leave a file that parses
    cleanly and is missing rows, which no reader downstream can tell from a complete one."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def counted_int(value):
    """A count read back out of someone else's JSON: bools are ints in Python."""
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        return 0
    return value


def parse_iso_timestamp(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def newest_run_dir(benches):
    candidates = []
    for directory in benches.iterdir() if benches.exists() else ():
        meta_path = directory / "meta.json"
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text())
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        started = parse_iso_timestamp(meta.get("started") or meta.get("started_at"))
        finished = parse_iso_timestamp(meta.get("finished") or meta.get("finished_at"))
        if started is None or finished is None:
            continue
        candidates.append((started, directory.name, directory))
    return max(candidates)[2] if candidates else None


def command_path(env_name, sibling):
    override = os.environ.get(env_name)
    if override:
        return override
    local = BIN_DIR / sibling
    return str(local) if local.exists() else sibling


def extract_json_values(text):
    values = []
    decoder = json.JSONDecoder()
    position = 0
    while position < len(text):
        match = re.search(r"[\[{]", text[position:])
        if not match:
            break
        start = position + match.start()
        try:
            value, consumed = decoder.raw_decode(text[start:])
        except json.JSONDecodeError:
            position = start + 1
            continue
        values.append(value)
        position = start + consumed
    return values


def subprocess_text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return str(value)


def text_file_tail(path, limit=65536):
    try:
        with Path(path).open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - limit))
            return stream.read().decode(errors="replace")
    except OSError:
        return ""


def rater_timeout(exc, rater, started, timeout_s, command, extra_stdout=""):
    # Which budget ended the cell, and how long it held the panel: the stderr line below says
    # "timed out" the same way a side's own client timeout does, and the report cannot otherwise
    # tell a hang we killed from one the CLI gave up on.
    rater["killed"] = "watchdog"
    rater["killed_cap_s"] = timeout_s
    quiet_ms = getattr(exc, "max_quiet_ms", None)
    if quiet_ms is not None:
        rater["max_quiet_ms"] = quiet_ms
    duration = round((time.monotonic() - started) * 1000)
    stdout = "\n".join(
        part for part in (subprocess_text(exc.stdout).rstrip(), extra_stdout.rstrip()) if part
    )
    stderr = f"rater timed out after {timeout_s}s"
    partial_stderr = subprocess_text(exc.stderr).rstrip()
    if partial_stderr:
        stderr += f"\n{partial_stderr}"
    return 124, duration, stdout, stderr, command


def iso_to_epoch(iso_str):
    """Parse ISO 8601 string to Unix epoch timestamp."""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return dt.timestamp()
    except (ValueError, TypeError):
        return None


def resolve_commit(repo, commitish):
    proc = subprocess.run(["git", "rev-parse", "--verify", f"{commitish}^{{commit}}"],
                          cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0:
        raise ValueError(f"cannot resolve commit {commitish!r} in {repo}")
    return proc.stdout.strip()


def commit_diff(repo, sha):
    proc = subprocess.run(["git", "show", "--format=fuller", "--no-ext-diff", sha],
                          cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "git show failed")
    return proc.stdout


def owner_grant_dir():
    return state_dir() / OWNER_GRANT_DIR


def debt_query_paths(repo, paths):
    """The queried paths as the artifacts record them: repository-relative, deduplicated, sorted.

    Spelled against the REPOSITORY ROOT and never against the caller's directory, unlike a review
    scope: these come out of the commit journal, which stores repository-relative paths, and a
    reader standing in a subdirectory would otherwise ask about `sub/sub/mine.txt`.
    """
    normalized = set()
    for raw in paths or ():
        # Never stripped: a leading or trailing space is part of a filename, and trimming one
        # asks about a path beside the one the journal named.
        item = str(raw)
        if not item.strip():
            continue
        relative = scope_path_relative(
            repo, item if os.path.isabs(item) else os.path.join(str(repo), item)
        )
        if relative is None or relative == os.curdir:
            continue
        normalized.add(relative)
    return sorted(normalized)


# Memoized for the same reason git_common_dir is: the reader walks every recorded run, and a
# handful of checkouts answer for hundreds of them.
@lru_cache(maxsize=None)
def resolved_repo_path(path):
    try:
        return Path(path).resolve()
    except OSError:
        return None


def run_repo_record(repo, meta):
    """The part of a run's record that belongs to the repository asking — the run itself, or the
    member of a merged panel that read it — or None when the run read another checkout entirely.

    Matched on the WORKING TREE and never on the repository behind it: every linked worktree shares
    one git dir, so a run of one of them would otherwise cover a sibling's paths, whose content it
    never read.
    """
    if repo is None:
        return None
    members = [entry for entry in meta.get("repos") or () if isinstance(entry, dict)]
    for entry in [meta] + members:
        recorded = str(entry.get("repo") or "")
        if recorded and resolved_repo_path(recorded) == repo:
            return entry
    return None


def session_runs(repo, session):
    """Every recorded run of `repo` that `session` launched, newest first, as
    `(run_dir, meta, record)`.

    Newest-first by directory name, which is the launch instant: the answer is about the review
    standing closest to the work in front of the reader, and an older run of the same paths cannot
    speak over it.
    """
    benches = state_dir() / "benches"
    resolved = resolved_repo_path(repo)
    runs = []
    for run_dir in sorted(benches.iterdir(), reverse=True) if benches.exists() else ():
        try:
            meta = json.loads((run_dir / "meta.json").read_text())
        except (OSError, ValueError):
            # The bench directory is shared and pruned while this walks it, and the answer must
            # not turn on which unrelated run was half-written at the time.
            continue
        if not isinstance(meta, dict) or str(meta.get("session") or "") != session:
            continue
        record = run_repo_record(resolved, meta)
        if record is not None:
            runs.append((run_dir, meta, record))
    return runs


def run_triaged(run_dir):
    """Whether anybody judged this run's findings. An untriaged run is a panel's raw output, which
    nobody has stood behind yet, so it covers nothing.
    """
    return (run_dir / "verdicts.jsonl").exists() or (run_dir / REPORT_RECEIPT).exists()


# Memoized because a debt reading asks for the same blob across paths and runs, and the statusline
# is on this path at every render.
@lru_cache(maxsize=None)
def blob_bytes(repo, sha):
    proc = subprocess.run(["git", "cat-file", "blob", sha], cwd=repo, capture_output=True)
    return proc.stdout if proc.returncode == 0 else b""


def file_bytes(path):
    try:
        return Path(path).read_bytes()
    except OSError:
        return b""


@lru_cache(maxsize=None)
def object_format(repo):
    proc = subprocess.run(
        ["git", "rev-parse", "--show-object-format"], cwd=repo, capture_output=True, text=True,
    )
    return "sha256" if proc.returncode == 0 and proc.stdout.strip() == "sha256" else "sha1"


def content_blob_sha(repo, data):
    """The sha git would give this content, so working-tree bytes and the shas an artifact recorded
    are the same kind of thing and compare directly. Hashed here rather than through `git
    hash-object`: this runs per path on the statusline's path, and a subprocess apiece was the cost
    the whole reader is memoized to avoid.
    """
    digest = hashlib.sha256 if object_format(str(repo)) == "sha256" else hashlib.sha1
    return digest(b"blob %d\0" % len(data) + data).hexdigest()


def path_content_bytes(repo, path):
    """What the working tree holds for `path` right now, as bytes, or None where nothing is there
    — which an artifact records as the empty sha, and which is not the same thing as an empty file.

    A symlink is its own link text and never the file it points at: read through, a link would be
    priced by content that may not be in this repository at all.
    """
    target = Path(repo) / path
    if target.is_symlink():
        try:
            return os.readlink(target).encode()
        except OSError:
            return None
    if not os.path.lexists(target) or target.is_dir():
        return None
    return file_bytes(target)


def path_blob_sha(repo, path):
    """The working tree's content for `path` as a blob sha — the empty string when nothing is
    there, which is also how an artifact records a path it read as deleted.
    """
    data = path_content_bytes(repo, path)
    return "" if data is None else content_blob_sha(repo, data)


def git_dir_path(repo):
    """The per-worktree git directory, where both journals live. The absolute git dir and not the
    common one: linked worktrees share the common dir, and a sibling's journal would answer for
    work this tree never saw.
    """
    # A run's recorded repository outlives the tree — a removed worktree, a pruned merged
    # workspace — and subprocess with a missing cwd RAISES rather than failing, which would cost
    # the caller its receipt entirely. Guarded here for every caller, as `git_common_dir` is.
    if not Path(repo).is_dir():
        return None
    proc = subprocess.run(
        ["git", "rev-parse", "--absolute-git-dir"], cwd=repo, capture_output=True, text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return Path(proc.stdout.strip())


def journal_entries(path):
    """`session TAB epoch TAB path` records, NUL-separated, the way the commit journal and the debt
    journal both write them, as `(session, epoch, path)` rows — epoch None where the record predates one. A record naming no session — the original
    format's bare path, or a session field left blank — comes back owned by nobody rather than
    dropped: the path is still work somebody recorded, and the debt universe is built out of
    exactly these rows. Only a record holding no path at all is not a record. The path keeps every
    tab past the second, because a tab in a filename is part of the name.
    """
    try:
        raw = Path(path).read_bytes().decode("utf-8", "replace")
    except OSError:
        return []
    rows = []
    for entry in raw.split("\0"):
        parts = entry.split("\t", 2)
        if len(parts) >= 3:
            session, path = parts[0], parts[2]
            epoch = int(parts[1]) if parts[1].isdigit() else None
        else:
            session, epoch, path = "", None, entry
        if not path:
            continue
        rows.append((session, epoch, path))
    return rows


def journal_rows(repo):
    """Every record the two journals hold, as `(session, epoch, path)`.

    Both of them, always: a path the chat has since committed has moved out of the commit journal
    into the debt one, and a reader of either alone calls that work unrecorded.
    """
    directory = git_dir_path(repo)
    if directory is None:
        return []
    return [
        row
        for name in (DEBT_JOURNAL, COMMIT_JOURNAL)
        for row in journal_entries(directory / name)
    ]


def journal_paths(repo):
    """Every path either journal names, which is the universe a repository-wide debt question asks
    about: the tool answers for paths somebody recorded work on, and never enumerates a repository
    whose unreviewed files are most of it.
    """
    return {path for _, _, path in journal_rows(repo)}


def run_id_epoch(run_id):
    try:
        return int(
            datetime.strptime(str(run_id)[:16], "%Y%m%dT%H%M%SZ")
            .replace(tzinfo=timezone.utc).timestamp()
        )
    except (ValueError, TypeError):
        return 0


def run_record_paths(repo, directory, listing="files"):
    """The repository-relative paths a run record names, read like `commit-journal.sh` reads it: the
    `WORKDIR:` line anchors every relative path, and an `UNKNOWN:`/`PARTIAL:` line is the reason the
    list is short rather than a file.

    `listing` picks which of the run's two path files is read — the tracked one, or the workdir-dirt
    snapshot beside it. Both are written in the same shape by the same code, and a second parser
    here is how the two would come to disagree about what a `WORKDIR:` line anchors.
    """
    try:
        lines = (directory / listing).read_text().splitlines()
    except OSError:
        return []
    workdir = ""
    paths = []
    for line in lines:
        if line.startswith("WORKDIR: "):
            if workdir:
                continue
            workdir = line[len("WORKDIR: "):]
            if nested_working_tree(str(repo), workdir):
                return []
            continue
        if not line or line.startswith("UNKNOWN: ") or line.startswith("PARTIAL: "):
            continue
        if line.startswith("/"):
            candidate = line
        elif workdir:
            candidate = os.path.join(workdir, line)
        else:
            continue
        relative = scope_path_relative(repo, candidate)
        if relative is not None and relative != os.curdir:
            paths.append(relative)
    return paths


@lru_cache(maxsize=None)
def nested_working_tree(repo, workdir):
    """Whether `workdir` sits in a working tree of its OWN somewhere inside `repo` — the in-repo
    worktree convention `<repo>/.claude/worktrees/<name>` first.

    Its paths read as this repository's by spelling alone, and the journals never crossed a checkout
    to reach it (each holds the paths of one git dir), so folding a run record's paths in whole is
    what puts another tree's files — which this repository's git does not even track — in this one's
    debt, and scopes a `--debt` review over them. Walked downwards from `repo` in `repo`'s own
    spelling, one `.git` entry being the whole question, and memoized because a handful of workdirs
    answer for every run on the machine.
    """
    relative = scope_path_relative(repo, workdir)
    if relative is None or relative == os.curdir:
        return False
    directory = Path(repo)
    for part in Path(relative).parts:
        directory = directory / part
        if (directory / ".git").exists():
            return True
    return False


def worker_run_dirs():
    """Every run record on this machine, in id order — which is the vendor first and the launch
    instant inside it, since that is the order the id itself is written in.
    """
    try:
        return sorted(worker_run_root().iterdir())
    except OSError:
        return []


def run_dirty_paths(repo, directories=None):
    """The paths inside `repo` that a finished run's own workdir gained uncommitted content on
    while that run ran, and that no tracker attributed to anybody — `worker-run`'s `dirty` record.

    Its whole reason to exist: a worker editing through the SHELL leaves no editor tool call in a
    transcript and no journal entry anywhere, so its work reaches `files`, the journals and every
    artifact alike as nothing at all, and a repository-wide debt question that asks only those
    stores answers `none` over files somebody rewrote (live case 2026-08-21). The dirty set is the
    only evidence there is that the content changed.

    It is evidence about CONTENT and never about authorship: a co-tenant editing beside the worker
    lands in the same `git status`, so these paths are returned as a bare set and enter the debt
    universe owned by NOBODY. `run_record_claims` is deliberately not widened with them — that
    mapping names a launcher, and a name attached here would hand one chat a waiver over another's
    work. Anonymous debt is answerable by whoever looks; misattributed debt is not.

    Only records that carry an exit code: a run still writing has a snapshot that is still moving,
    and pricing a half-written one is the same mistake as reading a round's outcome before its
    receipt exists. The `journaled` marker is NOT a reason to skip one, for the reason
    `chat_names.worker_run_launchers` reads past it too — that marker retires the run's LISTING,
    and no sweep ever names a path the listing never held.

    Over `directories` where the caller already holds the store's listing: this reading and the
    claims one walk the same records, and a caller asking both would otherwise walk it twice.
    """
    paths = set()
    for directory in (worker_run_dirs() if directories is None else directories):
        if not (directory / "exit_code").exists():
            continue
        paths.update(run_record_paths(repo, directory, listing="dirty"))
    return paths


def run_record_claims(repo, directories=None):
    """Whose the unswept worker runs' files are, as `{path: [(run id, launcher), ...]}`.

    A worker a chat spawned IS that chat (docs/shared-invariants.md row `am`), and between the
    worker writing its file list and the commit journal sweeping it, the run record is the only
    place that ownership exists — which is the same window whether the asking chat is the launcher
    or a co-tenant, so both questions come from this one reading. `directories` is the store's
    listing where the caller already holds it, so a caller asking both record questions of one
    walk asks them of the same records.
    """
    claims = {}
    for directory in (worker_run_dirs() if directories is None else directories):
        try:
            launcher = (directory / "launcher").read_text().strip()
        except OSError:
            continue
        # Swept into the journals already, so the journals are the answer and this record is
        # history — the two stores must not both claim one run.
        if not launcher or (directory / "journaled").exists():
            continue
        for path in run_record_paths(repo, directory):
            claims.setdefault(path, []).append((directory.name, launcher))
    return claims


def foreign_run_claims(repo, session):
    """The debt paths another chat's worker run owns, as `{path: (run id, launcher)}`. Read as
    unowned, a co-tenant's live work is exactly what a waiver naming no path would sign away.

    A path this chat's own run wrote too is not among them: two workers editing one file makes it
    both chats' work, and calling it a co-tenant's would refuse the launcher a waiver over its own
    output.
    """
    claims = {}
    for path, rows in run_record_claims(repo).items():
        if any(launcher == session for _, launcher in rows):
            continue
        claims[path] = rows[0]
    return claims


def session_run_paths(repo, session, claims=None):
    """The paths a run THIS chat launched wrote and no journal has swept yet. Its worker's files
    are the chat's own work, and counted as nobody's they read to the chat like a co-tenant's.

    Over `claims` where the caller already has them: this reading walks every run record on the
    machine, and a caller asking both ownership questions would otherwise walk it twice.
    """
    return {
        path for path, rows in (run_record_claims(repo) if claims is None else claims).items()
        if any(launcher == session for _, launcher in rows)
    }


def session_dirt_paths(repo, session, records=None):
    """The paths this chat's OWN finished runs recorded as workdir dirt.

    Weaker evidence than every other store here and read only where they are all silent: dirt is
    about content, not authorship, so a co-tenant's journal entry or run listing over the same path
    outranks it. What it answers is the case nothing else can — a worker whose vendor keeps no
    per-file record edits a file through the shell, and the chat that ordered the work sees its own
    bytes as debt owed by nobody, on the foreign side of its own statusline (live case 2026-08-22).
    """
    if not session:
        return set()
    launchers = worker_session_launchers()
    paths = set()
    for directory in (worker_run_dirs() if records is None else records):
        if not (directory / "exit_code").exists():
            continue
        try:
            launcher = (directory / "launcher").read_text().strip()
        except OSError:
            continue
        if not launcher or (launcher != session and launchers.get(launcher) != session):
            continue
        paths.update(run_record_paths(repo, directory, listing="dirty"))
    return paths


def reviews_current_tree(repo, sha, worktree=False):
    """Whether `sha` holds the tree standing in front of the reader of `repo`.

    The same question `write_review_receipt` asks before it refuses to move a repository's receipt
    backwards, asked here for the same reason: a bench run of a historical commit or of a range
    that ended before HEAD reviewed code the checkout no longer holds, so a fixing pass over its
    findings edits whatever the current tree happens to keep at those paths. A worktree run
    reviews the current state by construction — its sha IS the snapshot of it.

    Fails open exactly where the receipt does. A `git` that cannot answer must leave the handoff
    as it was rather than silently withhold the fixing pass from an ordinary review. `record` asks
    this long after the run, from wherever the triage happens, so a repository that has since moved
    or gone is one more `git` that cannot answer rather than a crash over the verdicts.
    """
    if worktree:
        return True
    try:
        head = subprocess.run(["git", "rev-parse", "HEAD^{tree}"],
                              cwd=repo, capture_output=True, text=True)
        if head.returncode != 0 or not head.stdout.strip():
            return True
        reviewed = subprocess.run(["git", "rev-parse", f"{sha}^{{tree}}"],
                                  cwd=repo, capture_output=True, text=True)
    except OSError:
        return True
    if reviewed.returncode != 0 or not reviewed.stdout.strip():
        return True
    return reviewed.stdout.strip() == head.stdout.strip()


def finding_rows(run_dir, rater):
    return read_jsonl(run_dir / f"findings-{rater}.jsonl")


def finding_similarity(left, right):
    if left.get("file") == right.get("file") and left.get("line") == right.get("line"):
        return 2 + SequenceMatcher(
            None, str(left.get("summary", "")).lower(), str(right.get("summary", "")).lower()
        ).ratio()
    if left.get("file") == right.get("file"):
        try:
            distance = abs(int(left.get("line")) - int(right.get("line")))
        except (TypeError, ValueError):
            distance = 100
        if distance <= 3:
            return 1 - distance / 10
    return SequenceMatcher(
        None, str(left.get("summary", "")).lower(), str(right.get("summary", "")).lower()
    ).ratio()


def repo_identity(path):
    """Name the repository a run reviewed, or nothing when the code cannot be traced.

    Benches run across several repositories and against sealed temporary copies, so a
    corpus row carrying only a commit sha cannot be resolved back to code: analysis
    silently assumes one repository and drops every finding whose paths it cannot find.
    Guessing a name from a dead path is what makes that failure quiet, so an unresolvable
    repository is recorded as absent instead.
    """
    if not isinstance(path, str) or not path or not Path(path).is_dir():
        return None
    proc = subprocess.run(["git", "rev-parse", "--git-common-dir"],
                          cwd=path, capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        return None
    # The common dir is shared by every linked worktree, so its parent names the one repository
    # they all belong to; the worktree's own directory name would split it into several.
    common = Path(proc.stdout.strip())
    if not common.is_absolute():
        common = (Path(path) / common).resolve()
    return common.parent.name if common.name == ".git" else common.name


def median(values):
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return round((ordered[middle - 1] + ordered[middle]) / 2)


