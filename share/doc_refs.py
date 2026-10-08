#!/usr/bin/env python3
"""Backticked references in markdown that resolve to nothing, one a line; exit 1 on any the allowlist
does not excuse, or on an allowlist line that no longer matches.

doc_refs.py --repo <root> <md>... < allowlist   (lines `<md relative to root> <token> <reason>`)

A reference is a path under a repository's own top-level directory (`bin/x`, `share/y`, `tests/z`,
`hooks/…`), a `~/.claude/…` or `~/.local/bin/…` path, or a bare `name.sh|py|lua`. It resolves when it
exists in <root> or in any sibling repository of the projects directory, `~/.claude/…` through the
symlinks claude-setup installs. Fenced blocks, placeholders and globs are never read.
"""
import os
import re
import subprocess
import sys

from fix_commit import main_checkout, siblings_dir

PREFIXES = {"bin", "share", "tests", "hooks", "docs", "global", "skills", "skills-on-demand", "agents",
            "commands", "launchd", "hammerspoon", "git-hooks", "trap"}
CLAUDE_SETUP = {"agents": "agents", "commands": "commands", "hooks": "hooks", "skills": "skills",
                "docs": "global/docs", "CLAUDE.md": "global/CLAUDE.md", "keybindings.json": "keybindings.json"}
PLACEHOLDER_STEMS = {"x", "y", "z", "foo", "bar", "test_x"}
SPAN = re.compile(r"(`+)(.+?)\1")
SKIP = re.compile(r"[<>*?{}$\[\]\"'…|=]|\.\.")
LINE_SUFFIX = re.compile(r":[\d,-]+$")


def roots_of(repo):
    projects = siblings_dir(repo)
    roots = {os.path.basename(main_checkout(repo)): repo}
    for name in sorted(os.listdir(projects)):
        path = os.path.join(projects, name)
        if name not in roots and os.path.exists(os.path.join(path, ".git")):
            roots[name] = path
    return roots


def tracked_basenames(roots):
    names = set()
    for root in roots.values():
        out = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True).stdout
        names.update(os.path.basename(line) for line in out.splitlines())
    return names


def candidates(word, md, roots):
    home = os.path.expanduser("~")
    setup = roots.get("claude-setup", "")
    if word.startswith("~/.claude/"):
        rest = word[len("~/.claude/"):]
        head, _, tail = rest.partition("/")
        if head in CLAUDE_SETUP and setup:
            return [os.path.join(setup, CLAUDE_SETUP[head], tail) if tail else os.path.join(setup, CLAUDE_SETUP[head])]
        return [os.path.join(home, ".claude", rest)]
    if word.startswith("~/.local/bin/"):
        name = word[len("~/.local/bin/"):]
        return [os.path.join(home, ".local/bin", name)] + [os.path.join(r, "bin", name) for r in roots.values()]
    head = word.split("/")[0]
    if "/" in word and head in PREFIXES:
        paths = [os.path.join(r, word) for r in roots.values()] + [os.path.join(os.path.dirname(md), word)]
        if head == "hammerspoon" and "hammerspoon" in roots:
            paths.append(os.path.join(roots["hammerspoon"], word.partition("/")[2]))
        return paths
    if "/" not in word and re.fullmatch(r"[\w.-]+\.(sh|py|lua)", word):
        return word
    return None


def dead_refs(md, roots, names):
    fence = False
    with open(md, errors="replace") as handle:
        for number, line in enumerate(handle, 1):
            if line.lstrip().startswith(("```", "~~~")):
                fence = not fence
                continue
            if fence:
                continue
            for span in SPAN.finditer(line):
                for word in span.group(2).split():
                    if SKIP.search(word):
                        continue
                    word = LINE_SUFFIX.sub("", re.sub(r"[.,;:)]+$", "", word)).split("#")[0].rstrip("/")
                    if not word or os.path.splitext(os.path.basename(word))[0] in PLACEHOLDER_STEMS:
                        continue
                    found = candidates(word, md, roots)
                    if isinstance(found, str):
                        if not names:
                            names.update(tracked_basenames(roots))
                        if found not in names:
                            yield number, word
                    elif found is not None and not any(os.path.exists(path) for path in found):
                        yield number, word


def main():
    args = sys.argv[1:]
    if len(args) < 2 or args[0] != "--repo":
        sys.exit("usage: doc_refs.py --repo <root> <md>... < allowlist")
    repo, files = os.path.abspath(args[1]), args[2:]
    allowed = {tuple(line.split()[:2]) for line in sys.stdin if len(line.split()) >= 3}
    roots, names, hit, bad = roots_of(repo), set(), set(), 0
    for md in files:
        rel = os.path.relpath(os.path.abspath(md), repo)
        for number, word in dead_refs(md, roots, names):
            if (rel, word) in allowed:
                hit.add((rel, word))
            else:
                print(f"{rel}:{number}: `{word}` resolves to nothing")
                bad += 1
    for rel, word in sorted(allowed - hit):
        print(f"{rel}: allowlisted `{word}` is no longer flagged")
        bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
