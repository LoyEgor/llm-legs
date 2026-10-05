"""The commit that settles a doctor ledger fix `{at, files: ["<repo>/<path>", ...], in}`, shared by
llm-doctor and harness-doctor."""
import datetime
import functools
import os
import subprocess

CLOCK_SLACK_S = 60
FIX_KEYS = frozenset({"at", "by", "files", "in", "regressed_at"})


@functools.lru_cache(maxsize=None)
def main_checkout(root):
    """The main checkout of checkout `root`, which a linked worktree resolves too."""
    try:
        common = subprocess.run(["git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        common = ""
    return os.path.dirname(common) if common else root.split("/.claude/worktrees/")[0]


def siblings_dir(root):
    """The directory the sibling repositories of checkout `root` sit in: beside its main checkout."""
    return os.path.dirname(main_checkout(root))


def fix_record_faults(ledger):
    """`(row id, index, missing keys)` of every ledger fix record lacking a contract key."""
    faults = []
    for row in (ledger.get("rows") if isinstance(ledger, dict) else None) or ():
        for index, fix in enumerate((row.get("fixes") if isinstance(row, dict) else None) or ()):
            missing = sorted(FIX_KEYS - set(fix)) if isinstance(fix, dict) else sorted(FIX_KEYS)
            if missing:
                faults.append((row.get("id") or "?", index, missing))
    return faults


def fix_epoch(text):
    try:
        return datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def fix_commit(fix, repos):
    """`repo@hash` of the newest commit once every file of the fix is clean and committed since the fix
    was made, its repositories under `repos`; None while any file is dirty, uncommitted or unreadable."""
    names = [name.strip("/") for name in fix.get("files") or ()]
    if not names:
        return None
    since, found = (fix_epoch(fix.get("at")) or 0) - CLOCK_SLACK_S, []
    for name in names:
        repo, _, path = name.partition("/")
        top = os.path.join(repos, repo)
        if not path or not os.path.isdir(top):
            return None
        try:
            dirty = subprocess.run(["git", "-C", top, "status", "--porcelain", "--", path], capture_output=True,
                                   text=True, timeout=10)
            last = subprocess.run(["git", "-C", top, "log", "-1", "--format=%h %ct", "--", path],
                                  capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return None
        words = last.stdout.split()
        if dirty.returncode or dirty.stdout.strip() or last.returncode or len(words) != 2 or int(words[1]) < since:
            return None
        found.append((int(words[1]), repo, words[0]))
    _, repo, commit = max(found)
    return "%s@%s" % (repo, commit)


@functools.lru_cache(maxsize=None)
def fix_landed(ref, repos):
    """When the fix's `in` commit `repo@hash` reached HEAD of its checkout under `repos`: its own commit time
    when it sits on HEAD's first-parent line, else the time of the merge that brought it in; None if unknown."""
    repo, _, commit = str(ref or "").partition("@")
    top = os.path.join(repos, repo)
    if not commit or not os.path.isdir(top):
        return None
    def git(*args):
        return subprocess.run(["git", "-C", top] + list(args), capture_output=True, text=True, timeout=10)
    try:
        own = git("log", "-1", "--format=%ct %H", commit, "--")
        words = own.stdout.split()
        if own.returncode or len(words) != 2 or git("merge-base", "--is-ancestor", words[1], "HEAD").returncode:
            return None
        line = git("log", "--first-parent", "--format=%ct %H %P", words[1] + "..HEAD", "--")
        below = git("rev-list", "--ancestry-path", words[1] + "..HEAD", "--")
    except (OSError, subprocess.SubprocessError):
        return None
    if line.returncode or below.returncode:
        return None
    descendants = set(below.stdout.split())
    oldest = None
    for entry in line.stdout.splitlines():
        parts = entry.split()
        if len(parts) > 2 and parts[1] in descendants:
            oldest = parts
    return int(oldest[0]) if oldest and oldest[2] != words[1] else int(words[0])
