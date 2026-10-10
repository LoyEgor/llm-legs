#!/usr/bin/env python3
"""Copies the ElevenLabs key file (accounts.file, the master) over every accounts.mirrors path, so an app that reads
only its own file spends the same keys in the same order. llm-limits.sh runs it on every writing poll, inside elevenlabs_balance.py --sync.

A mirror line whose key the master lacks and the last sync never wrote (its header lists the hashes it wrote) was
added there by hand: it stays at the end and is named on stderr. A key the master dropped leaves the mirror.
"""
from __future__ import annotations

import hashlib
import os
import re
import sys
from pathlib import Path

from elevenlabs_media import KEYS, caps

SYNCED_RE = re.compile(r"^# elevenlabs-keys-sync .*\bsynced=(\S*)$", re.M)


def digest(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()[:12]


def key_of(line: str) -> str | None:
    parts = line.split()
    return parts[0] if parts and not parts[0].startswith("#") else None


def mirrors() -> list[Path]:
    raw = os.environ.get("ELEVENLABS_MIRRORS")
    if raw is None and os.environ.get("ELEVENLABS_KEYS"):
        return []  # a fixture master must never overwrite a real app's keys
    paths = raw.split(":") if raw is not None else caps()["accounts"].get("mirrors", [])
    return [Path(p).expanduser() for p in paths if p]


def render(master: str, old: str) -> tuple[str, list[str]]:
    lines = [line for line in master.splitlines() if key_of(line)]
    keys = {key_of(line) for line in lines}
    match = SYNCED_RE.search(old)
    synced = set(match.group(1).split(",")) if match else set()
    kept = [line for line in old.splitlines() if (key := key_of(line)) and key not in keys and digest(key) not in synced]
    header = (f"# elevenlabs-keys-sync from {KEYS}: edit the master, this copy is rewritten from it. "
              f"synced={','.join(digest(key_of(line)) for line in lines)}")
    return "\n".join([header, *lines, *kept]) + "\n", [key_of(line) for line in kept]


def main() -> int:
    if not KEYS.is_file():
        print(f"no key file {KEYS}", file=sys.stderr)
        return 1
    master = KEYS.read_text()
    for target in mirrors():
        if not target.parent.is_dir():
            continue
        old = target.read_text() if target.is_file() else ""
        text, kept = render(master, old)
        for key in kept:
            print(f"{target}: {key[:9]}…{key[-4:]} is not in {KEYS}; kept at the end", file=sys.stderr)
        if text == old:
            continue
        temp = target.with_name(f".{target.name}.sync-{os.getpid()}")
        try:
            with open(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
                handle.write(text)
            os.replace(temp, target)
        except OSError:
            temp.unlink(missing_ok=True)
            raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
