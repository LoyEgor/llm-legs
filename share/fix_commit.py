"""The commit that settles a doctor ledger fix `{at, files: ["<repo>/<path>", ...], in}`, shared by
llm-doctor and harness-doctor."""
import datetime
import os
import subprocess

CLOCK_SLACK_S = 60


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
