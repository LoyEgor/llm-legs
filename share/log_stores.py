"""The LLM log-store registry (share/log-stores.json) read by `bin/system-doctor logstores` and `bin/log-sweep`:
each store's units (one glob match each), their size, file count and age, what a store's criterion removes, the
mechanical fallback that names any big or growing directory under the scan roots no store or ignore entry covers, and
the growth lens that names any directory of the watched volumes that crossed a size or grew fast over the week."""

import fnmatch
import glob
import itertools
import json
import os
import re
import stat

from chat_names import HEADLESS_ENTRYPOINTS as HEADLESS

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
DAY_S = 86400
MB = 1 << 20
KB = 1024
CLEANERS = ("self", "sweep", "cap", "keep", "command")
CRITERIA = ("days", "max_mb", "keep_newest", "tail_mb")
KINDS = ("log", "app", "cache")
GROUPS = ("workers", "temp", "review bench", "our tools", "my chats", "LLM apps")
SPLITS = ("session", "session-id")
NEEDS_CRITERION = ("self", "sweep", "command")
SLACK = {"days": 2, "keep_newest": 1, "max_mb": 1.25, "tail_mb": 2.0}


def registry_path():
    return os.environ.get("LOG_STORES_REGISTRY") or os.path.join(ROOT_DIR, "share", "log-stores.json")


def expand(pattern):
    if pattern == "$TMPDIR" or pattern.startswith("$TMPDIR/"):
        pattern = (os.environ.get("TMPDIR") or "/tmp").rstrip("/") + pattern[len("$TMPDIR"):]
    return os.path.normpath(os.path.expanduser(pattern))


def criterion(entry):
    found = [key for key in CRITERIA if key in entry]
    return (found[0], entry[found[0]]) if found else (None, None)


def load(path=None):
    """The registry, validated: every store has a name, globs, a kind, a known cleaner and at most one criterion, which a
    `self`, `sweep` or `command` store must have, and a log store lists its readers; a `command` store is an app or
    cache store whose criterion is `days` and whose `command` is an argv list; `group_days` only on a split `days`
    store, each group known and kept no longer than `days`, which an unclassified unit keeps; every ignore entry has a
    glob and a reason. Raises ValueError naming the fault."""
    path = path or registry_path()
    with open(path, encoding="utf-8") as handle:
        registry = json.load(handle)
    names = set()
    for entry in registry.get("stores") or ():
        name = entry.get("name")
        if not name or name in names:
            raise ValueError("store %r: missing or repeated name" % name)
        names.add(name)
        if not entry.get("globs") or entry.get("cleaner") not in CLEANERS:
            raise ValueError("store %s: needs globs and a cleaner in %s" % (name, "/".join(CLEANERS)))
        found = [key for key in CRITERIA if key in entry]
        if len(found) > 1 or entry["cleaner"] in NEEDS_CRITERION and not found:
            raise ValueError("store %s: %s needs exactly one of %s" % (name, entry["cleaner"], "/".join(CRITERIA)))
        if entry.get("kind") not in KINDS:
            raise ValueError("store %s: needs a kind in %s" % (name, "/".join(KINDS)))
        argv = entry.get("command")
        if entry["cleaner"] == "command" and not (
                entry["kind"] in ("app", "cache") and isinstance(entry.get("days"), int) and entry["days"] > 0
                and isinstance(argv, list) and argv and all(isinstance(a, str) and a for a in argv)):
            raise ValueError("store %s: a command store is an app or cache store with days and a command argv list" % name)
        readers = entry.get("readers")
        if entry["kind"] == "log" and not (isinstance(readers, list) and all(isinstance(r, str) and r for r in readers)):
            raise ValueError("store %s: a log store needs readers, a list of program names or []" % name)
        if entry["kind"] == "log" and (entry.get("group") not in GROUPS or not entry.get("label")
                                       or entry.get("split", SPLITS[0]) not in SPLITS
                                       or not isinstance(entry.get("part", "-"), str) or entry.get("part") == ""):
            raise ValueError("store %s: a log store needs a group in %s, a label, no split but %s and a part only as a name" % (
                name, "/".join(GROUPS), "/".join(SPLITS)))
        by_group = entry.get("group_days")
        if by_group is not None and not (
                entry.get("split") and isinstance(entry.get("days"), int) and isinstance(by_group, dict) and by_group
                and all(g in GROUPS and isinstance(d, int) and 0 < d <= entry["days"] for g, d in by_group.items())):
            raise ValueError("store %s: group_days needs a split days store and maps groups in %s to days up to its "
                             "days" % (name, "/".join(GROUPS)))
    for entry in registry.get("ignore") or ():
        if not entry.get("glob") or not entry.get("why"):
            raise ValueError("ignore entry %r: needs a glob and a why" % entry)
    return registry


def outermost(paths):
    kept = []
    for path in sorted(set(paths)):
        if kept and path.startswith(kept[-1] + "/"):
            continue
        kept.append(path)
    return kept


def braces(pattern):
    """The patterns a glob's {a,b} alternatives stand for, as a shell expands them (no nesting)."""
    found = re.search(r"\{([^{}]*)\}", pattern)
    if not found:
        return [pattern]
    return [p for alt in found.group(1).split(",") for p in braces(pattern[:found.start()] + alt + pattern[found.end():])]


def units(entry):
    found = set()
    for pattern in (p for g in entry["globs"] for p in braces(g)):
        found.update(os.path.normpath(p) for p in glob.glob(expand(pattern), include_hidden=True))
    excluded = [expand(p) if p.startswith(("~", "/", "$")) else p for p in entry.get("exclude") or ()]
    wanted = {"file": (stat.S_IFREG,), "dir": (stat.S_IFDIR,)}.get(entry.get("type"),
                                                                     (stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK))
    kept = []
    for path in found:
        if any(fnmatch.fnmatch(path, x) for x in excluded):
            continue
        try:
            info = os.lstat(path)
        except OSError:
            continue
        if stat.S_IFMT(info.st_mode) in wanted and (not entry.get("type") or info.st_uid == os.getuid()):
            kept.append(path)
    return outermost(kept)


def unit_stats(path):
    """{path, bytes (allocated, as du), size (a file's length), files, newest (the newest mtime of the unit and
    everything inside it), denied (a directory macOS will not list, an app's data its privacy guard keeps, or one
    holding a non-empty directory of another owner we may not write, a tool once run as root: never swept)};
    symlinks are counted, never followed."""
    try:
        info = os.lstat(path)
    except OSError:
        return None
    row = {"path": path, "bytes": info.st_blocks * 512, "size": info.st_size, "files": 0, "newest": info.st_mtime,
           "dir": stat.S_ISDIR(info.st_mode), "reg": stat.S_ISREG(info.st_mode)}
    if not row["dir"]:
        row["files"] = 1
        return row
    stack, uid = [(path, info.st_uid)], os.getuid()
    while stack:
        top, owner = stack.pop()
        try:
            with os.scandir(top) as entries:
                for item in entries:
                    if owner != uid and not row.get("denied"):
                        row["denied"] = not os.access(top, os.W_OK)
                    try:
                        info = item.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    row["bytes"] += info.st_blocks * 512
                    row["newest"] = max(row["newest"], info.st_mtime)
                    if stat.S_ISDIR(info.st_mode):
                        stack.append((item.path, info.st_uid))
                    else:
                        row["files"] += 1
        except PermissionError:
            row["denied"] = row.get("denied") or top == path
        except OSError:
            continue
    return row


def measure(entry):
    return [row for row in (unit_stats(path) for path in units(entry)) if row]


def doomed(entry, rows, now, slack=False):
    """The units the store's criterion removes, as (row, "delete" | "truncate"); with slack, the ones past the
    criterion plus its slack, which a working cleaner never leaves behind. A unit split() classified keeps its
    group's `group_days`, any other the store's `days`."""
    key, value = criterion(entry)
    if key == "days":
        by_group = entry.get("group_days") or {}
        extra = SLACK["days"] if slack else 0
        return [(r, "delete") for r in rows if r["newest"] < now - (by_group.get(r.get("class"), value) + extra) * DAY_S]
    newest_first = sorted(rows, key=lambda r: (-r["newest"], r["path"]))
    if key == "keep_newest":
        return [(r, "delete") for r in newest_first[value + (SLACK["keep_newest"] if slack else 0):]]
    if key == "max_mb":
        limit, total, out = value * MB * (SLACK["max_mb"] if slack else 1), 0, []
        for row in newest_first:
            total += row["bytes"]
            if total > limit:
                out.append((row, "delete"))
        return out
    if key == "tail_mb":
        limit = value * MB * (SLACK["tail_mb"] if slack else 1)
        return [(r, "truncate") for r in rows if r["reg"] and r["size"] > limit]
    return []


def summary(entry, rows, now):
    """One store's measurement: bytes, files, units, the oldest unit's age and what lies past criterion + slack."""
    over = [r for r, _action in doomed(entry, rows, now, slack=True) if r["bytes"] and not r.get("denied")]
    key, value = criterion(entry)
    return {"name": entry["name"], "cleaner": entry["cleaner"], "criterion": [key, value] if key else None,
            "group_days": entry.get("group_days"), "bytes": sum(r["bytes"] for r in rows),
            "files": sum(r["files"] for r in rows), "units": len(rows),
            "oldest_s": round(min(r["newest"] for r in rows)) if rows else None,
            "over_units": len(over), "over_bytes": sum(r["bytes"] for r in over),
            "over_oldest_s": round(min(r["newest"] for r in over)) if over else None}


def session_class(path):
    """'workers' for a headless session (claude -p, codex exec), 'my chats' for an interactive one, None when no
    entrypoint or originator turns up in its first 256 lines."""
    try:
        with open(path, "rb") as handle:
            for line in itertools.islice(handle, 256):
                if b'"entrypoint"' in line or b'"originator"' in line:
                    found = json.loads(line)
                    origin = found.get("entrypoint") or (found.get("payload") or {}).get("originator")
                    if origin:
                        return "workers" if origin in HEADLESS else "my chats"
    except (OSError, ValueError, AttributeError):
        pass
    return None


def split(entry, rows, sessions):
    """{group: bytes} of the store's units, each row's `class` set for doomed(). A `session` store's file is classified
    by session_class and recorded in `sessions` under the session id ending its name, which a later `session-id`
    store's unit named by that id inherits, so the registry lists the `session` stores first."""
    parts = {}
    for row in rows:
        name = os.path.basename(row["path"])
        if entry.get("split") == "session":
            found = session_class(row["path"]) if row["reg"] else None
            sessions[os.path.splitext(name)[0][-36:]] = found
        else:
            found = sessions.get(name) if entry.get("split") else None
        row["class"] = found
        group = found or entry["group"]
        parts[group] = parts.get(group, 0) + row["bytes"]
    return parts


# ---------------------------------------------------------------- unregistered stores


def parent(path):
    up = os.path.dirname(path)
    return up if up != path else None


def root_of(path, roots):
    best = None
    for root in roots:
        if (path == root or path.startswith(root.rstrip("/") + "/")) and (best is None or len(root) > len(best)):
            best = root
    return best


def depth_below(path, root):
    return 0 if path == root else path[len(root.rstrip("/")):].count("/")


def du_plan(roots, depth):
    """[(top root, du depth)]: one du per root no other root contains, deep enough to reach `depth` below every
    root inside it."""
    plan = []
    for top in roots:
        if root_of(top, [r for r in roots if r != top]):
            continue
        plan.append((top, max(depth_below(r, top) + depth for r in roots if root_of(r, [top]))))
    return plan


def parse_du(text):
    sizes = {}
    for line in text.splitlines():
        size, _, path = line.partition("\t")
        if size.isdigit() and path:
            sizes[os.path.normpath(path)] = int(size)
    return sizes


def residuals(sizes, roots, depth, claims, ignores, floor_kb, fires):
    """(reported, scan) over du sizes in KB. A directory 1..depth below its root is covered when it lies in a store
    unit, or in an ignore match that its root does not lie inside. Its residual is its size minus every covered or
    already-reported part below it (and every other root inside it); fires(path, kb, residual) returns the row to report
    or None, deepest first. A root's own loose files are judged the same way as `<root>/*`: its size minus every
    directory and claimed file directly in it. `claims` maps each store unit to its bytes; `scan` keeps [kb, residual]
    of every uncovered directory of floor_kb or more for the next comparison."""
    roots = [r for r in roots if r in sizes]
    ignored = set(ignores)
    units = outermost(claims)
    unit_set = set(units)
    weight = {p: claims[p] // KB for p in units}
    for path in ignored:
        weight.setdefault(path, sizes.get(path, 0))
    for root in roots:
        weight.setdefault(root, sizes[root])
    claimed = set(weight)
    acc = {}

    def lift(path, kb):
        up = parent(path)
        while up and up not in claimed:
            acc[up] = acc.get(up, 0) + kb
            up = parent(up)

    for path, kb in weight.items():
        lift(path, kb)

    def covered(path, root):
        up = path
        while up:
            if up in unit_set:
                return True
            if up in ignored and not (root != up and root.startswith(up + "/")):
                return True
            up = parent(up)
        return False

    candidates = []
    loose = {root: sizes[root] for root in roots}
    for path, kb in sizes.items():
        root = root_of(path, roots)
        if parent(path) in loose:
            loose[parent(path)] -= kb
        if root and 1 <= depth_below(path, root) <= depth and not covered(path, root):
            candidates.append((path, kb))
    for path, size in claims.items():
        if path not in sizes and parent(path) in loose:
            loose[parent(path)] -= size // KB
    candidates += [(root + "/*", max(0, kb)) for root, kb in loose.items()]
    reported, scan = [], {}
    for path, kb in sorted(candidates, key=lambda c: (-c[0].count("/"), c[0])):
        residual = max(0, kb - acc.get(path, 0))
        if kb >= floor_kb:
            scan[path] = [kb, residual]
        found = fires(path, kb, residual)
        if found:
            reported.append(found)
            lift(path, residual)
    return sorted(reported, key=lambda r: -r["residual_kb"]), scan


def unregistered(sizes, roots, depth, claims, ignores, min_kb, grow_kb_day, floor_kb, old=None, old_days=None):
    """residuals() reporting a directory whose residual reaches min_kb or grew by grow_kb_day a day against `old`
    ({path: [kb, residual]}, old_days back)."""

    def fires(path, kb, residual):
        grow = None
        if old is not None and old_days:
            grow = (residual - (old.get(path) or [0, 0])[1]) / old_days
        if residual >= min_kb or grow is not None and grow >= grow_kb_day:
            return {"path": path, "kb": kb, "residual_kb": residual, "grow_kb_day": round(grow) if grow is not None else None}
        return None

    return residuals(sizes, roots, depth, claims, ignores, floor_kb, fires)


def growers(sizes, roots, depth, claims, min_kb, grow_kb, floor_kb, old=None, old_days=None, old_roots=()):
    """residuals() with no ignores over the watched volumes' roots, reporting a directory that crossed min_kb or grew
    grow_kb against `old` ({path: [kb, residual]}, old_days back): a giant that appeared or grew fast, never one that
    sat that big all along. Only a path under one of `old_roots`, the roots that scan covered, is compared; with no
    earlier scan nothing is reported. A path `old` lacks was under its floor then and counts as 0."""

    def fires(path, kb, residual):
        if old is None or not old_days or not root_of(path, old_roots):
            return None
        before = (old.get(path) or [0, 0])[1]
        if residual >= min_kb > before or residual - before >= grow_kb:
            return {"path": path, "kb": kb, "residual_kb": residual, "grew_kb": residual - before,
                    "days": round(old_days, 1)}
        return None

    return residuals(sizes, roots, depth, claims, (), floor_kb, fires)


OWNER_DIRS = ("Library/Application Support", "Library/Caches", "Library/Containers", "Library/Group Containers",
              ".cache", ".local/share", ".config")


def ignore_paths(registry):
    found = []
    for entry in registry.get("ignore") or ():
        found += [os.path.normpath(p) for p in glob.glob(expand(entry["glob"]), include_hidden=True)]
    return found


def owner_words(path, home=None):
    """Who a directory belongs to, from its place alone: the git checkout around it (`repo <name>`), the app folder
    of an Application Support, Caches or Containers root, a home dot-dir's name, else the first two folders under the
    home or the volume."""
    home = home or os.path.expanduser("~")
    path = path[:-2] if path.endswith("/*") else path
    up = path
    while up and up not in ("/", home) and not re.fullmatch(r"/Volumes/[^/]+", up):
        if os.path.exists(os.path.join(up, ".git")):
            return "repo " + os.path.basename(up)
        up = parent(up)
    if path == home:
        return "home"
    rel = path[len(home) + 1:] if path.startswith(home + "/") else None
    if rel is not None:
        for top in OWNER_DIRS:
            if rel.startswith(top + "/"):
                return rel[len(top) + 1:].split("/")[0]
        parts = rel.split("/")
        return parts[0].lstrip(".") if parts[0].startswith(".") else "/".join(parts[:2])
    parts = [p for p in path.split("/") if p and p != "private"]
    return "/".join(parts[2:4] or parts[1:2] if parts[:1] == ["Volumes"] else parts[:2]) or path


def bounded(entry):
    """A store something keeps within bounds: the app caps it, or a cleaner other than `keep` applies its criterion."""
    return entry.get("cleaner") == "cap" or entry.get("cleaner") != "keep" and bool(criterion(entry)[0])


def app_claims(registry, sizes, only=None):
    """{unit: bytes} of every app or cache store unit (of every store `only` accepts, when given), never counted but
    claimed so the fallback skips it: du's size when du listed it, else its own (a file du never lists, a directory
    below du's depth)."""
    claims = {}
    for entry in registry.get("stores") or ():
        if not (only(entry) if only else entry.get("kind") in ("app", "cache")):
            continue
        for path in units(entry):
            if path in sizes:
                claims[path] = sizes[path] * KB
            else:
                row = unit_stats(path)
                if row:
                    claims[path] = row["bytes"]
    return claims


def logs(registry):
    return [entry for entry in registry.get("stores") or () if entry.get("kind") == "log"]


def caches(registry):
    return [entry for entry in registry.get("stores") or () if entry.get("kind") == "cache"]
