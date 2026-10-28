"""Every disk rule of the local pages (share/pages/CONTRACT.md) once: bin/page's server and CLI both call it."""

import fcntl
import hashlib
import json
import os
import re
import secrets
import shutil
import string
import time

PID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,55}$")
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SID_RE = re.compile(r"^[A-Za-z0-9-]{1,80}$")
MEDIA_KEYS = ("original", "src")
COPIED = ("/tmp/", "/private/tmp/", "/private/var/folders/")
_cache = {}


class Refused(Exception):
    pass


def root():
    """PAGES_DIR, else ~/Pages; a suite (SUITE_JOURNAL_PID set) must name its own temp dir, never the real store."""
    real = os.path.expanduser("~/Pages")
    chosen = os.environ.get("PAGES_DIR") or ""
    if os.environ.get("SUITE_JOURNAL_PID") and (not chosen or os.path.abspath(chosen) == real):
        raise Refused("PAGES_DIR must be a temp dir under a test run, never unset or ~/Pages")
    return chosen or real


def page_dir(pid):
    if not isinstance(pid, str) or not PID_RE.match(pid):
        return None
    path = os.path.join(root(), pid)
    return path if os.path.isfile(os.path.join(path, "meta.json")) else None


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


EVENTS_CAP = 1 << 20


def event(where, **fields):
    """One line in <root>/.events.jsonl, for `page report` and the harness doctor. Written only when something went
    wrong (where: cli, browser, server) or a chat was about to hand-make a page (hint), never on a normal call;
    one O_APPEND write, and nothing past 1 MB."""
    try:
        path = os.path.join(root(), ".events.jsonl")
        if os.path.exists(path) and os.path.getsize(path) > EVENTS_CAP:
            return
        line = json.dumps(dict({"at": now(), "where": where}, **fields), ensure_ascii=False)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (line + "\n").encode())
        finally:
            os.close(fd)
    except (OSError, Refused):
        pass


def events(since=""):
    try:
        with open(os.path.join(root(), ".events.jsonl"), errors="replace") as handle:
            lines = [read_line(text) for text in handle]
    except OSError:
        return []
    return [e for e in lines if e and e.get("at", "") >= since]


def read_line(text):
    try:
        doc = json.loads(text)
    except ValueError:
        return None
    return doc if isinstance(doc, dict) else None


def write_json(path, doc):
    temporary = "%s.tmp.%d" % (path, os.getpid())
    with open(temporary, "w") as handle:
        json.dump(doc, handle, ensure_ascii=False, indent=1)
    os.replace(temporary, path)


def read_json(path, default=None):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def cached(path, load):
    """load(path) kept until the file's mtime or size moves."""
    try:
        st = os.stat(path)
    except OSError:
        return load(path)
    stamp = (st.st_mtime_ns, st.st_size)
    hit = _cache.get(path)
    if hit and hit[0] == stamp:
        return hit[1]
    value = load(path)
    _cache[path] = (stamp, value)
    return value


def meta(pid):
    return cached(os.path.join(root(), pid, "meta.json"), read_json) or {}


def spec(pid):
    return cached(os.path.join(root(), pid, "spec.json"), read_json) or {}


def key(pid):
    return read_json(os.path.join(root(), pid, "key.json"), {}) or {}


def _fold(path):
    items, touched, ops, rev = {}, {}, set(), 0
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        data = b""
    for raw in data.split(b"\n"):
        try:
            line = json.loads(raw)
            item, fields = line["item"], line["fields"]
            if not isinstance(fields, dict):
                continue
        except (ValueError, KeyError, TypeError):
            continue
        ops.add(line.get("op"))
        slot = items.setdefault(item, {})
        for field, value in fields.items():
            if value is None:
                slot.pop(field, None)
            else:
                slot[field] = {"v": value, "at": line.get("at"), "by": line.get("by")}
        touched[item] = rev
        rev += 1
    return {"items": {i: f for i, f in items.items() if f}, "touched": touched, "ops": ops, "rev": rev}


def fold(pid):
    """{"items": {item: {field: {v, at, by}}}, "touched": {item: last line no}, "ops", "rev"}; never mutate it."""
    return cached(os.path.join(root(), pid, "log.jsonl"), _fold)


def state(pid):
    folded = fold(pid)
    return {"rev": folded["rev"], "spec_rev": spec(pid).get("rev", 1), "items": folded["items"]}


def append(pid, item, fields, by, op=None, spec_rev=None):
    """One log line under flock; an op seen before appends nothing. -> (rev, dup)"""
    path = os.path.join(root(), pid, "log.jsonl")
    op = op or secrets.token_hex(8)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        folded = fold(pid)
        if op in folded["ops"]:
            return folded["rev"], True
        size = os.fstat(fd).st_size
        torn = size and os.pread(fd, 1, size - 1) != b"\n"
        line = {"op": op, "at": now(), "by": by, "item": item, "fields": fields,
                "spec_rev": spec_rev if spec_rev is not None else spec(pid).get("rev", 1)}
        os.write(fd, (b"\n" if torn else b"") + json.dumps(line, ensure_ascii=False).encode() + b"\n")
        return folded["rev"] + 1, False
    finally:
        os.close(fd)


def item_ids(doc):
    return [i.get("id") for i in doc.get("items") or [] if isinstance(i, dict)]


def split_keys(node):
    """(node without `_` keys, the `_` keys alone in the same shape; lists keyed by element id or index)."""
    if isinstance(node, dict):
        clean, hidden = {}, {}
        for k, v in node.items():
            if isinstance(k, str) and k.startswith("_"):
                hidden[k] = v
                continue
            clean[k], sub = split_keys(v)
            if sub:
                hidden[k] = sub
        return clean, hidden
    if isinstance(node, list):
        clean, hidden = [], {}
        for n, v in enumerate(node):
            c, sub = split_keys(v)
            clean.append(c)
            if sub:
                hidden[str(v.get("id", n)) if isinstance(v, dict) else str(n)] = sub
        return clean, hidden
    return node, {}


def media_paths(node, found=None):
    """Every media path string of the items, in document order."""
    found = [] if found is None else found
    if isinstance(node, dict):
        for k, v in node.items():
            if k in MEDIA_KEYS and isinstance(v, str):
                found.append(v)
            else:
                media_paths(v, found)
    elif isinstance(node, list):
        for v in node:
            media_paths(v, found)
    return found


def rewrite_media(node, mapping):
    if isinstance(node, dict):
        return {k: mapping.get(v, v) if k in MEDIA_KEYS and isinstance(v, str) else rewrite_media(v, mapping)
                for k, v in node.items()}
    if isinstance(node, list):
        return [rewrite_media(v, mapping) for v in node]
    return node


def modules(kit):
    if os.path.isdir(kit):
        return sorted(f[:-3] for f in os.listdir(kit) if f.endswith(".md"))
    return ["cards", "compare"]


def validate(doc, module, kit):
    if module not in modules(kit):
        raise Refused("unknown module %r (have: %s)" % (module, ", ".join(modules(kit))))
    items = doc.get("items") if isinstance(doc, dict) else None
    if not isinstance(items, list) or not items:
        raise Refused("spec has no items list")
    ids = item_ids(doc)
    for n, item in enumerate(items):
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not ID_RE.match(item["id"]):
            raise Refused("item %d: id must match %s" % (n, ID_RE.pattern))
        variants = [v.get("id") if isinstance(v, dict) else None for v in item.get("variants") or []]
        if any(not isinstance(v, str) or not ID_RE.match(v) for v in variants) or len(set(variants)) < len(variants):
            raise Refused("item %s: variant ids must be unique and match %s" % (item["id"], ID_RE.pattern))
    if len(set(ids)) < len(ids):
        raise Refused("item ids must be unique")
    for path in media_paths(items):
        if not os.path.isfile(os.path.abspath(path)):
            raise Refused("media not found: %s" % path)


def item_media(items, catalog):
    """item id -> [(src, size, mtime_ns)] of its media, from the catalog of a stored or incoming spec."""
    return {i["id"]: [catalog.get(p) for p in media_paths(i)] for i in items}


def owner_pages(sid):
    folder = os.path.join(root(), ".by-session", sid)
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return []
    return [n for n in names if page_dir(n)]


def resolve(ref, sid=None):
    """A pid, or the slug of one of this session's pages."""
    if page_dir(ref):
        return ref
    for pid in owner_pages(sid) if sid else []:
        if pid.rsplit("-", 1)[0] == ref:
            return pid
    return None


def save(module, slug, title, doc, sid, chat_name, cwd, replace=(), kit=""):
    """Create the page, or update this session's page with that slug. -> (pid, created)"""
    if not SLUG_RE.match(slug or ""):
        raise Refused("slug must match %s" % SLUG_RE.pattern)
    validate(doc, module, kit)
    pid = resolve(slug, sid)
    created = pid is None
    if created:
        pid = "%s-%s" % (slug, "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(6)))
        os.makedirs(os.path.join(root(), pid, "media"))
    base = os.path.join(root(), pid)
    old_meta = meta(pid) if not created else {}
    old_spec = spec(pid) if not created else {}
    catalog, mapping, media = {}, {}, []
    for path in media_paths(doc["items"]):
        if path in mapping:
            continue
        real = os.path.realpath(path)
        st = os.stat(real)
        served = real
        if real.startswith(COPIED) or "/scratchpad/" in real:
            served = os.path.join(base, "media", hashlib.sha256(real.encode()).hexdigest()[:8] + "-" +
                                  os.path.basename(real))
        catalog[served] = (real, st.st_size, st.st_mtime_ns)
        mapping[path] = served
        media.append({"path": served, "src": real})
    clean, hidden = split_keys(rewrite_media(doc, mapping))
    old_catalog = {m["path"]: (m["src"], m.get("size"), m.get("mtime_ns")) for m in old_meta.get("media", [])}
    before = item_media(old_spec.get("items") or [], old_catalog)
    after = item_media(clean["items"], catalog)
    judged = fold(pid)["touched"]
    for item, now_media in after.items():
        if item in judged and item in before and before[item] != now_media and item not in replace:
            raise Refused("item %s has answers and its media changed: pass --replace %s to mark them stale" %
                          (item, item))
    for m in media:
        m["size"], m["mtime_ns"] = catalog[m["path"]][1:]
        if m["path"] != m["src"]:
            shutil.copy2(m["src"], m["path"] + ".tmp")
            os.replace(m["path"] + ".tmp", m["path"])
    rev = old_spec.get("rev", 0) + 1
    clean.update(module=module, schema=1, rev=rev, title=title or clean.get("title") or slug)
    folded = fold(pid)["items"]
    for item in replace:
        stale = {f: None for f in folded.get(item, {})}
        if stale:
            append(pid, item, stale, "chat", spec_rev=rev)
    write_json(os.path.join(base, "key.json"), dict(hidden, blind=blind_maps(pid, clean)))
    write_json(os.path.join(base, "spec.json"), clean)
    write_json(os.path.join(base, "meta.json"), {
        "pid": pid, "slug": slug, "owner": sid, "chat_name": chat_name, "cwd": cwd, "module": module,
        "title": clean["title"], "created": old_meta.get("created") or now(), "updated": now(), "media": media})
    keep = {m["path"] for m in media}
    for name in os.listdir(os.path.join(base, "media")):
        if os.path.join(base, "media", name) not in keep:
            os.remove(os.path.join(base, "media", name))
    link_dir = os.path.join(root(), ".by-session", sid)
    os.makedirs(link_dir, exist_ok=True)
    if not os.path.lexists(os.path.join(link_dir, pid)):
        os.symlink(os.path.join("..", "..", pid), os.path.join(link_dir, pid))
    return pid, created


def slots(pid, item):
    """Variant ids in served slot order: a Fisher-Yates shuffle driven by sha256(pid + item id)."""
    order = [v["id"] for v in item.get("variants") or []]
    digest = hashlib.sha256((pid + item["id"]).encode()).digest()
    for i in range(len(order) - 1, 0, -1):
        j = digest[i % len(digest)] % (i + 1)
        order[i], order[j] = order[j], order[i]
    return order


def blind_maps(pid, doc):
    if doc.get("module") != "compare" or not doc.get("blind"):
        return {}
    return {i["id"]: dict(zip(string.ascii_uppercase, slots(pid, i))) for i in doc["items"]}


def served_spec(pid):
    doc, m = spec(pid), meta(pid)
    urls = {}
    for n, entry in enumerate(m.get("media", [])):
        try:
            stamp = os.stat(entry["path"]).st_mtime_ns
        except OSError:
            stamp = 0
        urls[entry["path"]] = "/p/%s/m/%d?v=%d" % (pid, n, stamp)
    out = rewrite_media(doc, urls)
    blind = doc.get("module") == "compare" and doc.get("blind")
    for item in out.get("items", []) if blind else []:
        by_id = {v["id"]: v for v in item.get("variants") or []}
        item["variants"] = [dict({k: v for k, v in by_id[vid].items() if k not in ("id", "label")}, slot=letter)
                            for letter, vid in zip(string.ascii_uppercase, slots(pid, item))]
    out["pid"] = pid
    return out


def cursor(pid, sid, advance_to=None):
    path = os.path.join(root(), pid, ".read", sid)
    if advance_to is None:
        try:
            with open(path) as handle:
                return int(handle.read().strip() or 0)
        except (OSError, ValueError):
            return 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as handle:
        handle.write("%d\n" % advance_to)
    os.replace(path + ".tmp", path)
    return advance_to


def all_pages():
    try:
        names = os.listdir(root())
    except OSError:
        return []
    return [p for p in names if page_dir(p)]
