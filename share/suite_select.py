"""The suites covering changed files, for share/affected-suites.sh and share/test_health.py's fan-out (Egor, 2026-10-14:
selection follows evidence, not name mentions). A file's suites are its own plus those test_catches.fixers credits with
WHOLE catches on it over CATCH_D days, or with any credit when they also name it. Own: the file itself when it is a
suite; a suite whose name holds the file's stem; a suite, or a tests/ helper it names, that holds the file's repo path,
imports its module or requires it; for a file with none of those, the same for a repo file that imports, sources,
requires or runs it, one level. A module its package's __init__ names counts as imported by a suite importing the
package. A file with no own suite and no catch keeps the name rule: a suite, or a helper it names, naming its basename
as a word.

  suite_select.py <top> <paths-file>   suite paths on stdin, the ones covering the paths on stdout
"""

import functools
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_catches  # noqa: E402
import time_budget  # noqa: E402

CATCH_D = test_catches.UNCAUGHT_D
WORKTREES = "/.claude/worktrees/"
EDGE = r"(?<![\w.@+-])%s(?![\w.@+-])"
IMPORTS = r"^[ \t]*(?:import[ \t]+(?:[\w.]+(?:[ \t]+as[ \t]+\w+)?[ \t]*,[ \t]*)*%s\b|from[ \t]+%s[ \t]+import\b)|" \
          r"import_module\(\s*['\"]%s['\"]"
REQUIRE = r"""\brequire\s*\(?\s*["']%s["']"""
SOURCE = r"""(?:^|[\s;&|(])(?:\.|source)[ \t]+(?:[^\n;&|]*?[/"'])?%s(?![\w.@+-])"""
NOT_CODE = (":!tests/", ":!docs/", ":!*.md", ":!*.json", ":!*.jsonl")
TOKEN = re.compile(r"[\w@+-]+")
INDEX_AT = 16
WHOLE = 1.0


def repo_name(top):
    return os.path.basename(top.split(WORKTREES)[0].rstrip("/"))


def relative(top, path):
    """A path as given (from the repository root, the working directory or absolute) relative to the root."""
    if not os.path.isabs(path):
        if os.path.exists(os.path.join(top, path)) or not os.path.exists(path):
            return os.path.normpath(path)
        path = os.path.abspath(path)
    real = os.path.realpath(path)
    for root in (os.path.realpath(top), os.path.realpath(top).split(WORKTREES)[0]):
        rel = test_catches.in_repo(root, real)
        if rel:
            return rel
    return path


def read(path):
    try:
        with open(path, errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def stem(rel):
    base = os.path.basename(rel)
    return os.path.splitext(base)[0] if base.endswith((".py", ".lua")) else base


@functools.lru_cache(maxsize=None)
def patterns(rel):
    """(a suite's hold, a repo file's load, the old word rule) of rel, each matched on a line holding its stem."""
    base, parent, mod = os.path.basename(rel), os.path.basename(os.path.dirname(rel)), re.escape(stem(rel))
    held, load = [EDGE % re.escape(rel)], [r"/%s(?![\w.@+-])" % re.escape(base)]
    if rel.startswith("tests/") and rel.count("/") > 1:
        held.append(EDGE % re.escape(rel[6:]))
    if parent:
        held.append(r"""["']%s["']\s*[,/]\s*["']%s["']""" % (re.escape(parent), re.escape(base)))
    extra = IMPORTS % ((mod,) * 3) if base.endswith(".py") else REQUIRE % mod if base.endswith(".lua") else \
        SOURCE % re.escape(base) if base.endswith(".sh") else None
    if extra:
        load.append(extra)
        if not base.endswith(".sh"):
            held.append(extra)
    return re.compile("|".join(held)), re.compile("|".join(load)), re.compile(r"(?<!\w)%s(?!\w)" % re.escape(base))


@functools.lru_cache(maxsize=None)
def package(top, rel):
    """rel's package spelled as a module (share/pkg.py for share/pkg/mod.py) when its __init__ names rel."""
    folder = os.path.dirname(rel)
    init = os.path.join(top, folder, "__init__.py")
    if not rel.endswith(".py") or not folder or not os.path.isfile(init):
        return None
    if os.path.basename(rel) != "__init__.py" and not re.search(r"(?<!\w)%s(?!\w)" % re.escape(stem(rel)), read(init)):
        return None
    return folder + ".py"


def lines(text, needle):
    """Each line of text holding needle, once."""
    i = text.find(needle)
    while i >= 0:
        end = text.find("\n", i)
        end = len(text) if end < 0 else end
        yield text[text.rfind("\n", 0, i) + 1:end]
        i = text.find(needle, end)


def match(text, rel, kind):
    pat = patterns(rel)[kind]
    return any(pat.search(line) for line in lines(text, os.path.basename(rel) if kind == 2 else stem(rel)))


def importers(top, rels):
    """{rel: {repo file importing, sourcing, requiring or running it}} over the repo's tracked and untracked files
    outside tests/ and docs."""
    out = {r: set() for r in rels}
    if not rels:
        return out
    args = ["git", "-C", top, "grep", "-l", "-I", "--untracked", "--full-name", "-F"]
    for r in rels:
        args += ["-e", stem(r)]
    try:
        found = subprocess.run(args + ["--", "."] + list(NOT_CODE), capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return out
    for path in found.split("\n"):
        if not path:
            continue
        text = read(os.path.join(top, path))
        for r in rels:
            if path != r and match(text, r, 1):
                out[r].add(path)
    return out


def named(names, rel):
    """The suites whose name, past test_ or e2e_, holds rel's stem as whole _-separated segments."""
    key = re.sub(r"[^a-z0-9]+", "_", os.path.splitext(os.path.basename(rel))[0].lower()).strip("_")
    if len(key) < 3 or rel.startswith("tests/"):
        return set()
    return {n for n in names if "_%s_" % key in "_%s_" % re.sub(r"^(?:test|e2e)_", "", os.path.splitext(n)[0])}


def select(top, rels, names, now=None, held=None):
    """{rel: {"own", "evidence", "fallback"}} (suite basenames) for repo-relative rels among the suite basenames."""
    now = time_budget.now_s() if now is None else now
    held = time_budget.read_json(test_catches.ledger_path(), {}) if held is None else held
    folder = os.path.join(top, "tests")
    try:
        entries = sorted(os.listdir(folder))
    except OSError:
        entries = []
    helpers = {n: read(os.path.join(folder, n)) for n in entries
               if not n.startswith(("test_", "e2e_")) and os.path.isfile(os.path.join(folder, n))}
    texts = {n: read(os.path.join(folder, n)) for n in names}
    via = {n: [h for h in helpers if h in t] for n, t in texts.items()}
    by_stem = {os.path.splitext(n)[0]: n for n in names}
    credit = test_catches.fixers(held if isinstance(held, dict) else {}, now, CATCH_D)
    repo = repo_name(top)
    tokens = {n: set(TOKEN.findall(t)) for pool in (texts, helpers) for n, t in pool.items()} \
        if len(rels) >= INDEX_AT else None

    def holding(pool, rel):
        key = os.path.basename(rel).split(".")[0]
        return {n for n, t in pool.items() if (tokens is None or not key or key in tokens[n]) and match(t, rel, 0)}

    def direct(rel):
        users = holding(helpers, rel)
        found = holding(texts, rel) | {n for n in names if users.intersection(via[n])} | named(names, rel)
        if rel.startswith("tests/") and rel.count("/") == 1 and os.path.basename(rel) in helpers:
            found |= {n for n in names if os.path.basename(rel) in via[n]}
        pkg = package(top, rel)
        return found | direct(pkg) if pkg else found

    owns = {rel: direct(rel) | ({os.path.basename(rel)} & set(names)) for rel in rels}
    out = {}
    for rel, users in importers(top, [rel for rel in rels if not owns[rel]]).items():
        for user in users:
            owns[rel] |= direct(user)
    for rel in rels:
        own = owns[rel]
        given = {by_stem[k.split("/", 1)[1]]: n for k, n in credit.get((repo, rel), {}).items()
                 if k.split("/", 1)[1] in by_stem}
        proven = {n for n, c in given.items() if c >= WHOLE}
        naming = None
        if given.keys() - proven - own or not own and not proven:
            users = {h for h, t in helpers.items() if match(t, rel, 2)}
            naming = {n for n, t in texts.items() if match(t, rel, 2) or users.intersection(via[n])}
            proven |= given.keys() & naming
        out[rel] = {"own": own, "evidence": proven, "fallback": naming if not own and not proven else set()}
    return out


def main(argv):
    top, listed = os.path.realpath(argv[0]), argv[1]
    paths = [p.strip() for p in sys.stdin.read().split("\n") if p.strip()]
    names = {os.path.basename(p): p for p in paths}
    rels = sorted({relative(top, p) for p in read(listed).split("\n") if p.strip()})
    chosen = set()
    for got in select(top, rels, sorted(names)).values():
        chosen |= got["own"] | got["evidence"] | got["fallback"]
    sys.stdout.write("".join(names[n] + "\n" for n in sorted(chosen)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
