"""The harness's tool index, derived, never hand-kept: each sweep repository's README entries (`bin/X` → `~/.local/bin/X`
and unlinked `bin/X` or `tests/X` ones), every ~/.local/bin link into a sweep repository (its job from the README
entry, else the file's first doc line), each `share/` module's first doc line, and the skills (listed, typed-only
commands and `skills-on-demand`). `bin/tools` searches it; tool_mining's adoption judges the same entries. Built once
and cached, keyed by every source's mtime, so a lookup reads one JSON file and stats the sources.

  tool_index.py [--json]   the index's lines, or its entries as JSON
"""

import json
import math
import os
import re
import sys

ENV = ("NIGHT_RUN_SWEEP_REPOS", "TOOL_BIN_DIR", "TOOL_CLAUDE_DIR", "HOME")
VERSION = 1
ENTRY = re.compile(r"^- `((?:bin|tests)/[\w.-]+)`(?: → `~/\.local/bin/([\w.-]+)`)? — (.*)$")
USAGE = re.compile(r"\busage:\s*(\S.*?)(?:\\n)?['\"]?(?:\s*>&2)?\s*$", re.I)
CODE = re.compile(r"\.(?:py|sh|bash|lua|swift|mjs|js|jq)$")
COMMENT = {".lua": "--", ".swift": "//", ".js": "//", ".mjs": "//"}
FRONT = re.compile(r"\A---\n(.*?)\n---", re.S)
WORD = re.compile(r"[a-z0-9]+")
STOP = frozenset("a an and the of to for in on by with from or my his its it is be at as into this that what which "
                 "how do does i we you me".split())
JOB_MAX, TERSE = 110, 5
SHOWN, CUT = 5, 0.5
FIELDS = (("name", 3.0), ("job", 1.0), ("call", 0.5))
# A command or skill does the job whole; a share module is a part to import.
KIND = {"share": 0.6}


def home(*parts):
    return os.path.join(os.environ.get("HOME") or os.path.expanduser("~"), *parts)


def bin_dir():
    return os.environ.get("TOOL_BIN_DIR") or home(".local", "bin")


def claude_dir():
    return os.environ.get("TOOL_CLAUDE_DIR") or home(".claude")


def cache_path():
    return os.environ.get("TOOLS_INDEX_CACHE") or home(".cache", "tools-index", "index.json")


def sweep_list():
    """The sweep repositories' list file (handoffs.sweep_repos reads it too)."""
    return os.environ.get("NIGHT_RUN_SWEEP_REPOS") or home(".claude", "sweep-repos")


def lines(path, n=None):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return [line for _, line in zip(range(n), handle)] if n else handle.read().splitlines()
    except OSError:
        return []


def short(text):
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= JOB_MAX:
        return text
    return text[:JOB_MAX].rsplit(" ", 1)[0].rstrip(",;:") + "…"


def header(path):
    """(first doc line, usage line) of a code file: its docstring's or first comment's first sentence, and the text
    after a `usage:` in its first 40 lines."""
    head = lines(path, 40)
    usage = next((m.group(1) for m in map(USAGE.search, head) if m), None)
    doc, meta = "", False
    mark = COMMENT.get(os.path.splitext(path)[1], "#")
    for i, line in enumerate(head):
        s = line.strip()
        if s.startswith("# ///"):
            meta = not meta and s != "# ///"
            continue
        if meta:
            continue
        if s.startswith(('"""', "'''")):
            body = s[3:].strip() or (head[i + 1].strip() if i + 1 < len(head) else "")
            doc = body.split('"""')[0].split("'''")[0]
            break
        if s.startswith(("#!", "# shellcheck", "# noqa", "# -*-")) or not s.startswith(mark):
            continue
        s = s[len(mark):].lstrip("#-/ ").strip()
        if len(s.split()) >= 3:
            doc = s
            break
    name = os.path.splitext(os.path.basename(path))[0]
    doc = re.sub(r"^(?:%s)(?:\.\w+)?:\s*" % re.escape(name).replace(r"\-", "[- ]").replace("_", "[_ ]"), "", doc, flags=re.I)
    return doc.split(". ")[0].rstrip("."), usage


def front(path):
    """A markdown file's frontmatter keys, None where it cannot be read."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            head = FRONT.match(handle.read(8192))
    except OSError:
        return None
    out = {}
    for line in head.group(1).splitlines() if head else ():
        key, sep, value = line.partition(":")
        if sep and not line[:1].isspace():
            out[key.strip()] = value.strip().strip("\"'")
    return out


def readme_entries(repo):
    """{repo-relative path: (link name or None, job text)} of the README's tool list items, continuation lines joined."""
    out, last = {}, None
    for line in lines(os.path.join(repo, "README.md")):
        found = ENTRY.match(line)
        if found:
            last = found.group(1)
            out[last] = [found.group(2), found.group(3)]
        elif last and line.startswith("  ") and line.strip():
            out[last][1] += " " + line.strip()
        else:
            last = None
    return {k: tuple(v) for k, v in out.items()}


def split_usage(name, job):
    """(call, job): a job opening with a backticked span names the arguments."""
    found = re.match(r"`([^`]+)`\s*(.*)", job)
    return (name + " " + found.group(1), found.group(2)) if found else (None, job)


def build():
    """(entries, sources): {key: {name, kind, job, call, path, family}} and every file and directory read."""
    repos = [os.path.realpath(r) for r in (l.strip() for l in lines(sweep_list())) if r]
    owner = lambda path: next((r for r in repos if path.startswith(r + os.sep)), None)
    sources, entries = [sweep_list(), bin_dir()], {}
    by_link, unlinked = {}, {}
    for repo in repos:
        sources.append(os.path.join(repo, "README.md"))
        for rel, (link, job) in readme_entries(repo).items():
            if link:
                by_link.setdefault(link, (os.path.join(repo, rel), job))
            else:
                unlinked[os.path.join(repo, rel)] = job
    tools = {}  # name: (real path, linked, README job, link missing)
    for entry in sorted(os.listdir(bin_dir())) if os.path.isdir(bin_dir()) else ():
        path = os.path.realpath(os.path.join(bin_dir(), entry))
        if owner(path) and os.path.isfile(path):
            tools[entry] = (path, True, by_link.get(entry, (None, None))[1], False)
    for link, (path, job) in by_link.items():
        if link not in tools and os.path.isfile(path):
            tools[link] = (os.path.realpath(path), True, job, True)
    for path, job in unlinked.items():
        if os.path.basename(path) not in tools and os.path.isfile(path):
            tools[os.path.basename(path)] = (os.path.realpath(path), False, job, False)
    for name, (path, link, readme, broken) in sorted(tools.items()):
        repo = owner(path)
        sources.append(path)
        doc, usage = header(path)
        call, job = split_usage(name, readme) if readme else (None, doc)
        job = job if len(job.split()) >= TERSE or not doc else doc
        rel = os.path.relpath(path, repo)
        where = name if link else (rel if rel.startswith("tests/") else path)
        call = call or (usage if usage and usage.split()[0].endswith(name) else name)
        call = call if link else call.replace(name, where, 1)
        entries["bin/" + name] = {"name": name, "kind": "bin", "job": short(job), "call": short(call), "path": path,
                                  "linked": link, "family": family(name)}
        if broken:
            entries["bin/" + name]["broken"] = True
    for repo in repos:
        share = os.path.join(repo, "share")
        sources.append(share)
        for entry in sorted(os.listdir(share)) if os.path.isdir(share) else ():
            path = os.path.join(share, entry)
            if not os.path.isfile(path) or not (CODE.search(entry) or os.access(path, os.X_OK)) or entry.startswith("."):
                continue
            sources.append(path)
            doc, usage = header(path)
            if entry.endswith(".py"):
                call = "python3 %s %s" % (path, usage.split(None, 1)[1]) if usage and " " in usage and \
                    usage.split()[0] == entry else "import %s  # %s" % (entry[:-3], share)
            else:
                call = path
            entries["share/" + entry] = {"name": entry, "kind": "share", "job": short(doc), "call": call, "path": path,
                                         "family": family(entry)}
    skills = os.path.join(claude_dir(), "skills")
    commands = os.path.join(claude_dir(), "commands")
    sources += [skills, commands]
    found = [(os.path.join(skills, d, "SKILL.md"), d, "listed") for d in sorted(os.listdir(skills))] \
        if os.path.isdir(skills) else []
    found += [(os.path.join(commands, f), f[:-3], "command") for f in sorted(os.listdir(commands)) if f.endswith(".md")] \
        if os.path.isdir(commands) else []
    for repo in repos:
        demand = os.path.join(repo, "skills-on-demand")
        sources.append(demand)
        found += [(os.path.join(demand, d, "SKILL.md"), d, "on-demand") for d in sorted(os.listdir(demand))] \
            if os.path.isdir(demand) else []
    for path, name, how in found:
        if not os.path.isfile(path):
            continue
        sources.append(path)
        meta = front(path) or {}
        name = meta.get("name") or name
        key, real = "skill/" + name, os.path.realpath(path)
        typed = meta.get("disable-model-invocation") == "true"
        if how == "on-demand" and key in entries:
            entries[key].update(job=entries[key]["job"] or short(meta.get("description") or ""), demand=real,
                                call="Read %s" % real if entries[key]["call"].startswith("/") else entries[key]["call"])
            continue
        if key in entries:
            continue
        call = "Read %s" % real if how == "on-demand" else "/%s (typed only)" % name if typed else "Skill %s" % name
        listed = how != "on-demand" and not typed
        entries[key] = {"name": name, "kind": "skill", "job": short(meta.get("description") or ""), "call": call,
                        "path": real, "listed": listed, "family": "skills",
                        "list_b": len(("- %s: %s" % (name, meta.get("description") or "")).encode()) if listed else 0}
        if how == "on-demand":
            entries[key]["demand"] = real
    return entries, sorted(set(sources))


def family(name):
    return WORD.findall(name.lower())[0] if WORD.findall(name.lower()) else name


def stamp(paths):
    out = []
    for path in paths:
        try:
            out.append(os.stat(path).st_mtime_ns)
        except OSError:
            out.append(None)
    return out


def index():
    """The entries, from the cache while every source keeps its mtime and the environment its paths."""
    env = [os.environ.get(k) for k in ENV]
    try:
        with open(cache_path()) as handle:
            cache = json.load(handle)
        if cache.get("version") == VERSION and cache.get("env") == env and stamp(cache["sources"]) == cache["stamps"]:
            return cache["entries"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    entries, sources = build()
    try:
        os.makedirs(os.path.dirname(cache_path()), exist_ok=True)
        tmp = cache_path() + ".%d" % os.getpid()
        with open(tmp, "w") as handle:
            json.dump({"version": VERSION, "env": env, "sources": sources, "stamps": stamp(sources),
                       "entries": entries}, handle, ensure_ascii=False)
        os.replace(tmp, cache_path())
    except OSError:
        pass
    return entries


def words(text):
    out = []
    for w in WORD.findall(text.lower()):
        if w in STOP:
            continue
        out.append(w[:-1] if len(w) > 4 and w.endswith("s") and not w.endswith("ss") else w)
    return out


def search(entries, query):
    """The best SHOWN entries for the query's words: each word's idf over the entries, weighted by the field it hits
    (a prefix of a word there), only those within CUT of the best."""
    asked = list(dict.fromkeys(words(query)))
    if not asked:
        return []
    texts = {k: {f: words(e.get(f) or "") for f, _ in FIELDS} for k, e in entries.items()}
    hits = lambda toks, w: any(t.startswith(w) or w.startswith(t) and len(t) >= 4 for t in toks)
    score = {}
    for w in asked:
        holders = [k for k, t in texts.items() if any(hits(v, w) for v in t.values())]
        idf = math.log(1.0 + len(entries) / (1.0 + len(holders)))
        for k in holders:
            score[k] = score.get(k, 0.0) + idf * max(weight for f, weight in FIELDS if hits(texts[k][f], w)) \
                * KIND.get(entries[k]["kind"], 1.0)
    ranked = sorted(score, key=lambda k: (-score[k], len(entries[k]["name"]), k))
    return [k for k in ranked[:SHOWN] if score[k] >= CUT * score[ranked[0]]]


def line(entry):
    return " — ".join(p for p in (entry["name"], entry["job"], entry["call"]) if p)


def overview(entries):
    """A line per family: each name-word holding three or more entries, then the rest by kind."""
    groups = {}
    for e in entries.values():
        groups.setdefault(e["family"], []).append(e)
    out, rest = [], {}
    for fam, members in sorted(groups.items()):
        if len(members) >= 3 and fam != "skills":
            out.append("%s (%d): %s" % (fam, len(members), " ".join(sorted(m["name"] for m in members))))
        else:
            for m in members:
                rest.setdefault(m["kind"], []).append(m["name"])
    for kind in ("bin", "share", "skill"):
        if rest.get(kind):
            out.append("other %s (%d): %s" % (kind, len(rest[kind]), " ".join(sorted(rest[kind]))))
    return out


def main(argv):
    entries = index()
    if argv[:1] == ["--json"]:
        print(json.dumps(entries, ensure_ascii=False, indent=1))
        return 0
    print("\n".join(line(entries[k]) for k in sorted(entries)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
