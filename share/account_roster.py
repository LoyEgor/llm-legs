"""The one account roster per vendor (shared-invariants row dg), read through share/account-roster.sh so
no Python consumer enumerates a vendor's accounts a second way."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

SHARE = Path(__file__).resolve().parent
READ = '. "$0/account-roster.sh" && account_roster "$1"'
_cache: dict[tuple, list[str]] = {}
# Bound at import: a caller's test that patches subprocess.Popen mocks the CLI it launches, never this read.
_POPEN = subprocess.Popen


class Unreadable(Exception):
    pass


def roster(vendor: str, fresh: bool = False) -> list[str]:
    key = (vendor, tuple(sorted(os.environ.items())))
    if fresh or key not in _cache:
        try:
            with _POPEN(["bash", "-c", READ, str(SHARE), vendor], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True) as process:
                try:
                    out, err = process.communicate(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    raise
        except (OSError, subprocess.SubprocessError) as exc:
            raise Unreadable(f"cannot read the {vendor} account roster: {exc}") from exc
        if process.returncode:
            raise Unreadable(f"cannot read the {vendor} account roster: {err.strip() or process.returncode}")
        _cache[key] = out.split()
    return _cache[key]
