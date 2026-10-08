"""Every store that keeps something per account, per vendor (shared-invariants row di): the one table
`<vendor>b remove` purges through, the llm doctor's remnant check scans, and
tests/test_account_purge.sh fills and expects empty. A name these stores hold that the roster
(row dg) does not list is a remnant.

    account_stores.py purge <vendor> <name> [--dry-run]
    account_stores.py remnants [--json]
"""
from __future__ import annotations

import contextlib
import functools
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import account_roster
import gateway_auth
import gemini_web

SHARE = Path(__file__).resolve().parent
PATHS_READ = ('. "$0/worker-pool.sh" && . "$0/worker-claims.sh" && . "$0/worker-walls.sh" && '
              'dir=$(worker_pool_dir "$1") && printf "%s\n" "$dir" && worker_pool_file "$dir" && '
              'worker_claims_dir && worker_walls_path "$1" "{name}"')
_ROOTS: dict[str, Path] = {}

VENDORS = ("claude", "codex", "gemini", "grok")
NAME = r"[A-Za-z0-9][A-Za-z0-9._@+-]*?"


def _dir(env: str, default: str) -> Path:
    return Path(os.environ.get(env) or default).expanduser()


class Entries:
    def __init__(self, label: str, folder, pattern: str = "{name}"):
        self.label, self.folder = label, folder
        self.regex = re.compile("^" + pattern.replace("{name}", f"(?P<name>{NAME})") + "$")

    def held(self) -> dict[str, list[Path]]:
        found: dict[str, list[Path]] = {}
        with contextlib.suppress(OSError):
            for entry in self.folder().iterdir():
                match = self.regex.match(entry.name)
                if match:
                    found.setdefault(match.group("name"), []).append(entry)
        return found

    def purge(self, name: str, dry_run: bool) -> list[str]:
        gone = []
        for path in sorted(self.held().get(name, [])):
            gone.append(str(path))
            if not dry_run:
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
        return gone


class JsonNames:
    """A JSON object keyed by account (walls), or holding lists of accounts (notices' consent lists),
    rewritten under the same `.<file>.lock` gemini_web.update_json takes, through its file_lock."""

    def __init__(self, label: str, folder, file: str, lists: bool = False):
        self.label, self.folder, self.file, self.lists = label, folder, file, lists

    def _read(self) -> dict:
        try:
            data = json.loads((self.folder() / self.file).read_text())
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _names(self, data: dict) -> set[str]:
        if not self.lists:
            return set(data)
        return {item for value in data.values() if isinstance(value, list) for item in value if isinstance(item, str)}

    def held(self) -> dict[str, list[str]]:
        return {name: [f"{self.folder() / self.file}[{name}]"] for name in self._names(self._read())}

    def purge(self, name: str, dry_run: bool) -> list[str]:
        if name not in self._names(self._read()):
            return []
        where = f"{self.folder() / self.file}[{name}]"
        if dry_run:
            return [where]
        path = self.folder() / self.file
        with gemini_web.file_lock(self.folder() / f".{self.file}.lock"):
            data = self._read()
            if self.lists:
                data = {key: [item for item in value if item != name] if isinstance(value, list) else value
                        for key, value in data.items()}
            else:
                data.pop(name, None)
            tmp = path.with_name(path.name + ".tmp")
            tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
            tmp.replace(path)
        return [where]


class PoolExclusions:
    def __init__(self, label: str, word: str):
        self.label, self.word = label, word

    def file(self) -> Path:
        return _paths(self.word)["file"]

    def _lines(self) -> list[str]:
        try:
            return self.file().read_text().splitlines()
        except OSError:
            return []

    def held(self) -> dict[str, list[str]]:
        return {line.strip(): [f"{self.file()}[{line.strip()}]"] for line in self._lines() if line.strip()}

    def purge(self, name: str, dry_run: bool) -> list[str]:
        lines = self._lines()
        if name not in (line.strip() for line in lines):
            return []
        if not dry_run:
            subprocess.run(["bash", "-c", '. "$0/worker-pool.sh" && worker_pool_set_disabled "$1" "$2" off',
                            str(SHARE), str(_paths(self.word)["pool"]), name], check=True)
        return [f"{self.file()}[{name}]"]


@functools.cache
def _paths(word: str) -> dict[str, Path]:
    """The worker pool, claim and run-observed wall paths of a vendor, from their bash owners."""
    try:
        out = subprocess.run(["bash", "-c", PATHS_READ, str(SHARE), word], capture_output=True, text=True,
                             timeout=30, check=True).stdout.splitlines()
        pool, file, claims, wall = map(Path, out)
    except (subprocess.SubprocessError, ValueError) as exc:
        raise OSError(f"cannot read the {word} pool paths: {exc}") from exc
    return {"pool": pool, "file": file, "claims": claims / word, "walls": wall.parent, "wall": wall.name}


def _shared(word: str) -> list:
    pool = lambda: _paths(word)["pool"]
    return [
        Entries("worker claim", lambda: _paths(word)["claims"]),
        Entries("run-observed wall", lambda: _paths(word)["walls"], _paths(word)["wall"] + r"(\.tmp\.[0-9]+)?"),
        PoolExclusions("worker pool exclusion", word),
        Entries("pool shield", lambda: pool() / "shielded"),
        Entries("pool shield override", lambda: pool() / "shield-override"),
    ]


def _web_roots() -> dict[str, Path]:
    if _ROOTS:
        return _ROOTS
    gemini = gemini_web.ROOT
    import chatgpt_web  # noqa: F401  rebinds gemini_web.ROOT to its own store at import (rows de, df)
    _ROOTS.update({"gemini-web": gemini, "chatgpt-web": gemini_web.ROOT})
    return _ROOTS


def _web(label: str) -> list:
    root = lambda: _web_roots()[label]
    return [
        Entries(f"{label} browser profile", lambda: root() / "profiles"),
        Entries(f"{label} account meta", lambda: root() / "accounts", r"{name}\.json"),
        Entries(f"{label} account lock", lambda: root() / "locks", r"{name}\.lock"),
        JsonNames(f"{label} wall", root, "walls.json"),
    ]


def stores(vendor: str) -> list:
    web_root = lambda: _web_roots()["gemini-web"]
    table = {
        "claude": _shared("claudeb"),
        "codex": _shared("codex") + _web("chatgpt-web") + [
            Entries("fast-mode setting", lambda: _paths("codex")["pool"] / "fast-mode"),
            Entries("gateway login", lambda: Path(gateway_auth.gateway_accounts_dir())),
            Entries("statusline quota kick", lambda: _dir("STATUSLINE_CACHE_DIR", "~/.cache/claude-statusline"),
                    r"codex-quota-kick-{name}(\.lock|\.tmp\.[0-9]+)?"),
        ],
        "gemini": _shared("gemini") + _web("gemini-web") + [
            JsonNames("gemini-web music wall", web_root, "music-walls.json"),
            JsonNames("gemini-web Flow Music wall", web_root, "flow-music-walls.json"),
            JsonNames("gemini-web notice consent", web_root, "notices.json", lists=True),
            Entries("quota cache", lambda: _dir("LLM_LIMITS_GEMINI_ACCOUNTS_DIR", "~/.llm-limits-gemini"),
                    r"{name}\.json(\.(err|tmp)\.[A-Za-z0-9]+)?"),
        ],
        "grok": _shared("grok") + [
            Entries("fast-mode setting", lambda: _paths("grok")["pool"] / "fast-mode"),
        ],
    }
    return table[vendor]


def purge(vendor: str, name: str, dry_run: bool = False) -> list[str]:
    if name in account_roster.roster(vendor):
        raise ValueError(f"{name} is still on the {vendor} roster the menubar lists; remove it first")
    gone = []
    for store in stores(vendor):
        gone.extend(store.purge(name, dry_run))
    return gone


def remnants() -> dict[str, dict[str, list[str]]]:
    """vendor -> off-roster account -> the stores still holding it."""
    found: dict[str, dict[str, list[str]]] = {}
    for vendor in VENDORS:
        roster = set(account_roster.roster(vendor))
        for store in stores(vendor):
            for name in store.held():
                if name not in roster:
                    found.setdefault(vendor, {}).setdefault(name, []).append(store.label)
    return found


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[0] == "purge" and argv[1] in VENDORS and argv[3:] in ([], ["--dry-run"]):
        try:
            for where in purge(argv[1], argv[2], dry_run=bool(argv[3:])):
                print(where)
        except (ValueError, account_roster.Unreadable, OSError) as exc:
            print(f"account_stores: {exc}", file=sys.stderr)
            return 2 if isinstance(exc, ValueError) else 1
        return 0
    if argv[:1] == ["remnants"] and argv[1:] in ([], ["--json"]):
        try:
            found = remnants()
        except account_roster.Unreadable as exc:
            print(f"account_stores: {exc}", file=sys.stderr)
            return 1
        if argv[1:]:
            print(json.dumps(found, sort_keys=True))
        else:
            for vendor, names in sorted(found.items()):
                for name, labels in sorted(names.items()):
                    print(f"{vendor}\t{name}\t{', '.join(labels)}")
        return 0
    print(__doc__.split("\n\n", 1)[1].rstrip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
