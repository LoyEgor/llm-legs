"""The commit that settles a doctor ledger fix `{at, files: ["<repo>/<path>", ...], in}`, shared by
llm-doctor and harness-doctor, and the overlay those settled fields live in until a commit carries them:
a measuring run never writes the tracked ledger (shared-invariants row ej)."""
import datetime
import functools
import json
import os
import subprocess

CLOCK_SLACK_S = 60
FIX_KEYS = frozenset({"at", "by", "files", "in", "regressed_at"})
SETTLED_FILE = "ledger-settled.json"
SETTLED_KEYS = ("in", "regressed_at")


def read_settled(path):
    """`{row id: {fix at: {in?, regressed_at?, status?}}}` of a doctor's overlay; empty when absent or unreadable."""
    try:
        with open(path, encoding="utf-8") as handle:
            rows = json.load(handle).get("rows")
    except (OSError, ValueError, AttributeError):
        return {}
    return rows if isinstance(rows, dict) else {}


def merge_settled(ledger, settled):
    """Fill what the tracked ledger lacks from the overlay, in place: a value the file holds always wins, and
    a row turns `fixed` only from `fixed-pending` once its last fix carries the overlay's own commit."""
    if not isinstance(ledger, dict) or not isinstance(ledger.get("rows"), list) or not settled:
        return ledger
    for row in ledger["rows"]:
        found = settled.get(row.get("id")) if isinstance(row, dict) and isinstance(row.get("id"), str) else None
        fixes = row.get("fixes") if isinstance(found, dict) else None
        if not isinstance(fixes, list) or not fixes:
            continue
        for fix in fixes:
            entry = found.get(fix.get("at")) if isinstance(fix, dict) and isinstance(fix.get("at"), str) else None
            for key in SETTLED_KEYS if isinstance(entry, dict) else ():
                if entry.get(key) and not fix.get(key):
                    fix[key] = entry[key]
        last = fixes[-1]
        entry = found.get(last.get("at")) if isinstance(last, dict) and isinstance(last.get("at"), str) else None
        if isinstance(entry, dict) and entry.get("status") == "fixed" and row.get("status") == "fixed-pending" \
                and entry.get("in") and last.get("in") == entry["in"]:
            row["status"] = "fixed"
    return ledger


def load_merged(ledger_file, settled_file):
    """The tracked ledger with its doctor's overlay merged in, the one view every ledger reader takes; None when
    the file is missing or no JSON."""
    try:
        with open(ledger_file, encoding="utf-8") as handle:
            ledger = json.load(handle)
    except (OSError, ValueError):
        return None
    return merge_settled(ledger, read_settled(settled_file))


def record_settled(path, rows):
    """Keep in the overlay what a run settled on each row's last fix: its `in`, `regressed_at` and a `fixed` status."""
    rows = [row for row in rows if (row.get("fixes") or [None])[-1] and isinstance(row["fixes"][-1].get("at"), str)]
    if not rows:
        return
    settled = read_settled(path)
    for row in rows:
        fix = row["fixes"][-1]
        entry = settled.setdefault(row["id"], {}).setdefault(fix["at"], {})
        entry.update({key: fix[key] for key in SETTLED_KEYS if fix.get(key)})
        if row.get("status") == "fixed":
            entry["status"] = "fixed"
    temporary = "%s.tmp.%d" % (path, os.getpid())
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump({"rows": settled}, handle, ensure_ascii=False, indent=1, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    except OSError:
        if os.path.exists(temporary):
            os.remove(temporary)
        raise


def sync_settled(ledger_file, settled_file):
    """Write the overlay's fields into a tracked ledger file in the ledger's own layout; the count of rows changed."""
    with open(ledger_file, encoding="utf-8") as handle:
        source = handle.read()
    before = json.loads(source)
    after = merge_settled(json.loads(source), read_settled(settled_file))
    changed = sum(1 for old, new in zip(before.get("rows") or (), after.get("rows") or ()) if old != new)
    if changed:
        indent = 1 if source.startswith('{\n "') else 2
        with open(ledger_file + ".tmp", "w", encoding="utf-8") as handle:
            handle.write(json.dumps(after, ensure_ascii=False, indent=indent) + "\n")
        os.replace(ledger_file + ".tmp", ledger_file)
    return changed


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
