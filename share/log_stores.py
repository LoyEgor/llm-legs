"""The LLM log-store registry (share/log-stores.json) read by `bin/system-doctor logstores` and `bin/log-sweep`:
each store's units (one glob match each), their size, file count and age, what a store's criterion removes, and the
mechanical fallback that names any big or growing directory under the scan roots no store or ignore entry covers."""

import fnmatch
import glob
import json
import os
import stat

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
DAY_S = 86400
MB = 1 << 20
KB = 1024
CLEANERS = ("self", "sweep", "cap", "keep")
CRITERIA = ("days", "max_mb", "keep_newest", "tail_mb")
NEEDS_CRITERION = ("self", "sweep")
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
    """The registry, validated: every store has a name, globs, a known cleaner and at most one criterion, which a
    `self` or `sweep` store must have; every ignore entry has a glob and a reason. Raises ValueError naming the fault."""
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


def units(entry):
    found = set()
    for pattern in entry["globs"]:
        found.update(os.path.normpath(p) for p in glob.glob(expand(pattern), include_hidden=True))
    excluded = [expand(p) if p.startswith(("~", "/", "$")) else p for p in entry.get("exclude") or ()]
    kept = [p for p in found if not any(fnmatch.fnmatch(p, x) for x in excluded)]
    if entry.get("type") == "file":
        kept = [p for p in kept if not os.path.isdir(p) or os.path.islink(p)]
    return outermost(kept)


def unit_stats(path):
    """{path, bytes (allocated, as du), size (a file's length), files, newest (the newest mtime of the unit and
    everything inside it)}; symlinks are counted, never followed."""
    try:
        info = os.lstat(path)
    except OSError:
        return None
    row = {"path": path, "bytes": info.st_blocks * 512, "size": info.st_size, "files": 0, "newest": info.st_mtime,
           "dir": stat.S_ISDIR(info.st_mode)}
    if not row["dir"]:
        row["files"] = 1
        return row
    stack = [path]
    while stack:
        try:
            with os.scandir(stack.pop()) as entries:
                for item in entries:
                    try:
                        info = item.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    row["bytes"] += info.st_blocks * 512
                    row["newest"] = max(row["newest"], info.st_mtime)
                    if stat.S_ISDIR(info.st_mode):
                        stack.append(item.path)
                    else:
                        row["files"] += 1
        except OSError:
            continue
    return row


def measure(entry):
    return [row for row in (unit_stats(path) for path in units(entry)) if row]


def doomed(entry, rows, now, slack=False):
    """The units the store's criterion removes, as (row, "delete" | "truncate"); with slack, the ones past the
    criterion plus its slack, which a working cleaner never leaves behind."""
    key, value = criterion(entry)
    if key == "days":
        limit = now - (value + (SLACK["days"] if slack else 0)) * DAY_S
        return [(r, "delete") for r in rows if r["newest"] < limit]
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
        return [(r, "truncate") for r in rows if not r["dir"] and r["size"] > limit]
    return []


def summary(entry, rows, now):
    """One store's measurement: bytes, files, units, the oldest unit's age and what lies past criterion + slack."""
    over = [r for r, _action in doomed(entry, rows, now, slack=True) if r["bytes"]]
    key, value = criterion(entry)
    return {"name": entry["name"], "cleaner": entry["cleaner"], "criterion": [key, value] if key else None,
            "bytes": sum(r["bytes"] for r in rows), "files": sum(r["files"] for r in rows), "units": len(rows),
            "oldest_s": round(min(r["newest"] for r in rows)) if rows else None,
            "over_units": len(over), "over_bytes": sum(r["bytes"] for r in over),
            "over_oldest_s": round(min(r["newest"] for r in over)) if over else None}


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


def unregistered(sizes, roots, depth, claims, ignores, min_kb, grow_kb_day, floor_kb, old=None, old_days=None):
    """(reported, scan) over du sizes in KB. A directory 1..depth below its root is covered when it lies in a store
    unit, or in an ignore match that its root does not lie inside. Its residual is its size minus every covered or
    already-reported part below it (and every other root inside it); it is reported when the residual reaches min_kb or
    grew by grow_kb_day a day against `old` ({path: [kb, residual]}, old_days back). `claims` maps each store unit to its
    bytes; `scan` keeps [kb, residual] of every uncovered directory of floor_kb or more for the next comparison."""
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
    for path, kb in sizes.items():
        root = root_of(path, roots)
        if root and 1 <= depth_below(path, root) <= depth and not covered(path, root):
            candidates.append((path, kb))
    reported, scan = [], {}
    for path, kb in sorted(candidates, key=lambda c: (-c[0].count("/"), c[0])):
        residual = max(0, kb - acc.get(path, 0))
        grow = None
        if old is not None and old_days:
            before = (old.get(path) or [0, 0])[1]
            grow = (residual - before) / old_days
        if kb >= floor_kb:
            scan[path] = [kb, residual]
        if residual >= min_kb or grow is not None and grow >= grow_kb_day:
            reported.append({"path": path, "kb": kb, "residual_kb": residual,
                             "grow_kb_day": round(grow) if grow is not None else None})
            lift(path, residual)
    return sorted(reported, key=lambda r: -r["residual_kb"]), scan


def ignore_paths(registry):
    found = []
    for entry in registry.get("ignore") or ():
        found += [os.path.normpath(p) for p in glob.glob(expand(entry["glob"]), include_hidden=True)]
    return found
