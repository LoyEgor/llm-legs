"""Session id → the name Egor has actually seen a chat under.

The only display name a chat may carry is the one Claude Code assigned it: the `ai-title` event
its transcript records, or a `custom-title` he typed over that. The `name` in
`~/.claude-profiles/<profile>/sessions/<pid>.json` is a placeholder the harness derives from the
working directory (`arbostar-frs-frontend-59`); he has never seen one, so it is refused here and a
chat holding nothing else stays an id.

A worker run is not a chat. It surfaces as the chat that LAUNCHED it, off the run records
`worker-run` writes — the same walk `review-bench debt` folds a worker's journal entries with, kept
here so the two answers cannot diverge. A run whose launcher nothing names stays a bare id: shown
under a name of its own it would answer a question about a conversation with the errand it sent.

Consumers: `bin/chat-find` (and `bin/chats`, which also takes its project column from here) and
`bin/review-bench` (imports this checkout).
"""

import atexit
import json
import os
import re
import shutil
import subprocess
from functools import lru_cache
from pathlib import Path

NAME_MAX = 110
SHORT_ID = 8
# Chat names live in the transcript as their own tiny events: one he typed ("custom-title") and one
# the model guessed ("ai-title").
NAME_PATTERNS = ('"custom-title"', '"ai-title"')
NAME_LINE_MAX = 8 * 1024
ARGV_ROOM = 128 * 1024
# A worker, bench or subagent run is not a chat: it was launched BY one to carry out an errand.
HEADLESS_VIA = "sdk-cli"
DERIVED_NAME_SOURCE = "derived"
SESSION_OK = re.compile(r"^[A-Za-z0-9._-]+$")
# What every surface prints a chat by, and therefore what a reader has to hand when asking about
# one. Eight is the shortest run of hex that is not a coincidence across this machine's stores.
SESSION_PREFIX = re.compile(r"^[0-9a-fA-F]{8,}$")
ROOTS_ENV = "CHAT_NAME_ROOTS"
CACHE_ENV = "CHAT_NAMES_CACHE"
CACHE_VERSION = 1
# A launcher that is itself a worker of another chat is a nested spawn; the walk stops well before
# a run record that names itself could spin here.
FOLD_HOPS = 4

_UNSET = object()
# His worktrees always live at `<repo>/.claude/worktrees/<branch>` (global rule), so the repo a
# worktree cwd belongs to is the prefix before it.
WORKTREES = os.sep + os.path.join(".claude", "worktrees") + os.sep


def project_label(cwd):
    """The project folder a cwd belongs to — the MAIN checkout even inside a worktree.

    A `git` call per row would be paid on every keystroke of the picker's filter, and the
    branch a worktree is named after is already in the chat's title.
    """
    path = cwd or ""
    cut = path.find(WORKTREES)
    if cut > 0:
        path = path[:cut]
    return os.path.basename(path.rstrip(os.sep)) or "?"


def worker_run_root():
    return Path(os.environ.get("WORKER_RUN_DIR") or Path.home() / ".cache" / "claude-worker-runs")


def worker_run_launchers():
    """`{worker session id: {launcher session id, ...}}` off the run records.

    A worker that edited through the shell alone lists no file in its record, while its own hooks
    journaled every one of those edits — under the worker's session, which is no chat any reader
    would otherwise recognise (live case 2026-08-20). A `journaled` record is read too: that marker
    retires the run's LISTING, and nothing ever renames what the worker's session journaled.
    """
    mapping = {}
    try:
        directories = sorted(worker_run_root().iterdir())
    except OSError:
        return {}
    for directory in directories:
        try:
            launcher = (directory / "launcher").read_text().strip()
            workers = (directory / "worker-session").read_text().split()
        except (OSError, ValueError):
            continue
        if not launcher:
            continue
        for worker in workers:
            mapping.setdefault(worker, set()).add(launcher)
    return mapping


def worker_session_launchers():
    """`{worker session id: launcher session id}`, the unambiguous mappings only.

    A `--resume` run repeats one worker id across launches. Where those launches are one chat's it
    is still that chat's author; where TWO chats resumed the same worker session, nothing here
    divides its entries between them, and handing every entry to both hands each chat a waiver over
    the other's work — so an ambiguous id maps to nobody and its entries stay the worker's own.
    """
    return {
        worker: next(iter(owners))
        for worker, owners in worker_run_launchers().items()
        if len(owners) == 1
    }


def searcher():
    """(argv, executable) for the fastest available matcher.

    On transcripts — multi-megabyte JSON lines — ripgrep beats BSD grep by two orders of magnitude
    (0.3s vs 40s over the corpus). There is usually no rg on PATH here, but Claude Code carries one
    inside its own binary and serves it when argv[0] is "rg", which is exactly what `executable=`
    lets us do.
    """
    real = shutil.which("rg")
    if real:
        return ["rg", "-g", "*.jsonl", "--no-heading", "--no-line-number", "--no-messages"], real
    for candidate in (os.environ.get("CLAUDE_CODE_EXECPATH"),
                      os.path.expanduser("~/.local/bin/claude"),
                      shutil.which("claude")):
        if candidate and os.path.exists(candidate):
            return ["rg", "-g", "*.jsonl", "--no-heading", "--no-line-number", "--no-messages"], candidate
    grep = shutil.which("grep")
    return ["grep", "-r", "--include=*.jsonl"], grep


def split_hit(raw):
    """Split a matcher line into (path, json payload).

    Anchored on ":{" rather than the first colon so a path containing one still parses.
    """
    at = raw.find(b":{")
    if at < 0:
        return None, None
    return raw[:at].decode("utf-8", "replace"), raw[at + 1:]


def clean_name(text):
    return " ".join(str(text).split())[:NAME_MAX]


def note_name(names, raw):
    """Record one chat-name event, reporting whether the line was one.

    The last name of each kind in a transcript wins. False means the line is not a name event, so
    the caller goes on matching it as conversation.
    """
    path, payload = split_hit(raw)
    if payload is None:
        return False
    try:
        entry = json.loads(payload.decode("utf-8", "replace"))
    except ValueError:
        return False
    key = {"custom-title": "custom", "ai-title": "ai"}.get(entry.get("type"))
    if not key:
        return False
    text = entry.get("customTitle") if key == "custom" else entry.get("aiTitle")
    if not isinstance(text, str) or not text.strip():
        return True
    names.setdefault(path, {"custom": None, "ai": None})[key] = clean_name(text)
    return True


def names_by_path(root=None, paths=None):
    """path -> `{"custom": …, "ai": …}` for the transcripts named, from one grep pass.

    Narrowed to the chats actually being listed: naming a week of them is a pass over a few hundred
    files instead of over every transcript ever written.
    """
    argv, binary = searcher()
    if not binary or paths == [] or (paths is None and root is None):
        return {}
    command = argv + ["-a", "-H", "-F"]
    for pattern in NAME_PATTERNS:
        command += ["-e", pattern]
    # An all-time listing is thousands of paths, which is most of ARG_MAX on this machine; past the
    # threshold, scanning the whole corpus is the cheap option next to an E2BIG that would abort the
    # listing entirely.
    if paths and root is not None and sum(len(str(path)) for path in paths) > ARGV_ROOM:
        paths = None
    command += ["--"] + ([str(path) for path in paths] if paths else [str(root)])
    names = {}
    proc = subprocess.Popen(command, executable=binary, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    for raw in proc.stdout:
        raw = raw.rstrip(b"\n")
        if len(raw) < NAME_LINE_MAX:
            note_name(names, raw)
    proc.stdout.close()
    proc.wait()
    return names


def transcript_roots():
    override = os.environ.get(ROOTS_ENV)
    if override:
        return [Path(entry) for entry in override.split(os.pathsep) if entry]
    home = Path.home()
    return [home / ".claude" / "projects"] + sorted((home / ".claude-profiles").glob("*/projects"))


def session_store_files():
    home = Path.home()
    directories = [home / ".claude" / "sessions"] + sorted(
        (home / ".claude-profiles").glob("*/sessions"))
    return [path for directory in directories for path in sorted(directory.glob("*.json"))]


def transcript_path(session):
    if not SESSION_OK.match(session):
        return None
    for root in transcript_roots():
        for path in sorted(root.glob(f"*/{session}.jsonl")):
            return path
    return None


@lru_cache(maxsize=4)
def _session_id_index(roots, stores, runs):
    found = set()
    for root in roots:
        try:
            paths = list(Path(root).glob("*/*.jsonl"))
        except OSError:
            continue
        for path in paths:
            found.add(path.stem)
    for store in stores:
        try:
            entry = json.loads(Path(store).read_text())
        except (OSError, ValueError):
            continue
        session = isinstance(entry, dict) and str(entry.get("sessionId") or "")
        if session:
            found.add(session)
    # The launcher and worker ids beside a run: a chat whose transcript has been swept still names
    # the runs it spawned, and that record is the only place its id survives.
    try:
        directories = sorted(Path(runs).iterdir())
    except OSError:
        directories = []
    for directory in directories:
        for name in ("launcher", "worker-session"):
            try:
                text = (directory / name).read_text()
            except (OSError, ValueError):
                continue
            for token in text.split():
                if SESSION_OK.match(token):
                    found.add(token)
    return tuple(sorted(found))


def session_ids():
    """Every session id this machine holds, off the transcripts, the live session records and the
    worker-run store.

    Read ONCE per process, and keyed by the stores it was read from so a caller that repoints them
    is never answered out of the other one: asking about several ids then walks the corpus — 19k
    transcript files here — once rather than once per id, which is what the stop notice naming the
    chats of a turn does inside a budget of one second for up to twenty.
    """
    return _session_id_index(
        tuple(str(root) for root in transcript_roots()),
        tuple(str(path) for path in session_store_files()),
        str(worker_run_root()),
    )


def session_prefix_matches(prefix):
    """Every session id `prefix` names, across the transcripts, the live session records and the
    worker-run store.

    A full id carries dashes and never reaches here; a bare run of hex does, because the 8
    characters every surface prints a chat by ARE a prefix and asking about one of them used to
    answer nothing at all.
    """
    if not SESSION_PREFIX.match(prefix):
        return []
    lowered = prefix.lower()
    return sorted(session for session in session_ids() if session.lower().startswith(lowered))


def resolve_session(token):
    """The session ids `token` could be: itself where it is no bare hex prefix or names nothing,
    and every id it prefixes otherwise. More than one is a question the caller has to put back to
    whoever asked — shown under either, a prefix hands the reader the wrong conversation.
    """
    token = str(token or "")
    return session_prefix_matches(token) or [token]


def store_names():
    """`{session id: name}` off the live session records, the derived placeholders left out.

    The harness derives a name from the working directory for every chat that has yet to be named
    (`arbostar-frs-frontend-59`). Egor has never seen one, so it is no name a chat may be shown
    under and a chat holding only that stays an id.
    """
    names = {}
    for path in session_store_files():
        try:
            entry = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(entry, dict):
            continue
        if entry.get("nameSource") == DERIVED_NAME_SOURCE:
            continue
        session = str(entry.get("sessionId") or "")
        name = entry.get("name")
        if session and isinstance(name, str) and name.strip():
            names[session] = clean_name(name)
    return names


def store_name(session, store=None):
    return (store_names() if store is None else store).get(session)


def cache_path():
    override = os.environ.get(CACHE_ENV)
    if override:
        return Path(override)
    return Path.home() / ".cache" / "claude" / "chat-names.json"


@lru_cache(maxsize=1)
def _cache():
    """The on-disk name cache, read once per process. Keyed by the transcript's (size, mtime): a
    chat renamed after this was written rewrites its transcript, so the key moves with the name.
    """
    try:
        with open(cache_path(), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {"rows": {}, "dirty": set()}
    if not isinstance(data, dict) or data.get("version") != CACHE_VERSION:
        data = {}
    rows = data.get("rows")
    if not isinstance(rows, dict):
        rows = {}
    return {"rows": rows, "dirty": set()}


def flush_cache():
    """Best effort: a resolver that cannot write its cache is slow, never wrong."""
    state = _cache()
    if not state["dirty"]:
        return
    path = cache_path()
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        os.makedirs(path.parent or ".", exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump({"version": CACHE_VERSION, "rows": state["rows"]}, handle,
                      ensure_ascii=False)
        os.replace(tmp, path)
        state["dirty"].clear()
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


atexit.register(flush_cache)


def transcript_name(session, store=None):
    """The name `session`'s own transcript records, or the live session record's where it has none.

    Only the transcript's answer is cached, keyed by its (size, mtime): the session record is a
    live file that gains a name without a word being said, and cached beside the transcript a chat
    named while this reader watched would stay an id until it was spoken in.

    Says nothing about whether that session is a chat at all — `chat_name` decides that first.
    """
    path = transcript_path(session)
    try:
        info = os.stat(path) if path is not None else None
    except OSError:
        info = None
    if info is None:
        return store_name(session, store)
    key = "%d:%r" % (info.st_size, info.st_mtime)
    state = _cache()
    row = state["rows"].get(session)
    if isinstance(row, dict) and row.get("key") == key:
        name = row.get("name")
    else:
        found = names_by_path(paths=[path]).get(str(path)) or {}
        name = found.get("custom") or found.get("ai")
        state["rows"][session] = {"key": key, "name": name}
        state["dirty"].add(session)
    return name or store_name(session, store)


def short_session(session):
    return str(session or "")[:SHORT_ID] or "?"


def chat_name(session, name=_UNSET, headless=False, launchers=None, store=None):
    """The original name `session` may be shown under, or None where it has none it may surface by.

    `name` is the title already read out of that session's own transcript — a caller that scanned a
    corpus has it and must not be made to look it up again, and passing None says that scan found
    none rather than that it never ran. `headless` marks a transcript whose entrypoint says it is
    an errand rather than a conversation, which no run record happens to name. `launchers` and
    `store` are the two whole-store readings, for a caller naming many chats at once.
    """
    session = str(session or "")
    if not session:
        return None
    if launchers is None:
        launchers = worker_run_launchers()
    for _ in range(FOLD_HOPS):
        owners = launchers.get(session)
        if owners is None:
            break
        # Ambiguous means two chats resumed one worker session: shown under either name it hands the
        # reader the wrong conversation, so it is shown under none.
        if len(owners) != 1:
            return None
        session, name, headless = next(iter(owners)), _UNSET, False
    else:
        # Every hop spent and the walk is still on a worker: a record that names itself would
        # spin here, and the chat at the end of a chain this long is a guess.
        if session in launchers:
            return None
    if headless:
        return None
    if name is _UNSET:
        name = transcript_name(session, store)
    elif not name:
        name = store_name(session, store)
    return clean_name(name) if name else None


def chat_label(session, name=_UNSET, headless=False, launchers=None, store=None):
    """What to print where this project names a chat: its original name, else a short id."""
    return chat_name(session, name, headless, launchers, store) or short_session(session)
