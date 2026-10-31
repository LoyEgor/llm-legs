#!/usr/bin/env python3
"""The OpenAI API keys' menubar rows, as one JSON line: the key file, the shared key state and the spend.

$OPENAI_KEYS (default ~/.config/openai/keys.txt): `<key> <account> [label=..] [reset_day=N]` per line, N the day
of the month the credit grant renews. No llm-legs code spends the OpenAI API, so there is no pool: a row says
whether a key-state writer (the dictation daemon) holds the key, why, and when its grant renews.

OpenAI gives no key its credit balance. $OPENAI_ADMIN_KEYS (default ~/.config/openai/admin-keys.txt):
`<admin key> <account> credit=<usd> [since=YYYY-MM-DD]`, an organization admin key restricted to the Usage API
read scope and the credit the account's grants hold (the Billing page's credit grants): a monthly grant (reset_day)
counts the organization's spend since its last renewal, one-off grants since `since`. The row then carries
`spent`, `credit` and `used_pct`; a failed costs read carries `spend_error` instead.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from key_state import keystate

VENDOR = "openai"
KEYS = Path(os.environ.get("OPENAI_KEYS") or "~/.config/openai/keys.txt").expanduser()
ADMIN_KEYS = Path(os.environ.get("OPENAI_ADMIN_KEYS") or "~/.config/openai/admin-keys.txt").expanduser()
COSTS_URL = os.environ.get("OPENAI_COSTS_URL") or "https://api.openai.com/v1/organization/costs"


def admin_lines() -> dict[str, dict]:
    """account -> {key, credit, since} from the admin key file; no file, no spend."""
    try:
        text = ADMIN_KEYS.read_text()
    except OSError:
        return {}
    found = {}
    for line in text.splitlines():
        parts = line.split()
        credit = re.search(r"\bcredit=([0-9]+(?:\.[0-9]+)?)\b", line)
        if len(parts) < 2 or parts[0].startswith("#") or not credit:
            continue
        since = re.search(r"\bsince=(\d{4}-\d{2}-\d{2})\b", line)
        found[parts[1]] = {"key": parts[0], "credit": float(credit.group(1)),
                           "since": time.mktime(time.strptime(since.group(1), "%Y-%m-%d")) if since else None}
    return found


def spent_since(key: str, start: float) -> float:
    """The organization's spend from `start` on, in USD, from its daily cost buckets."""
    total, page = 0.0, None
    while True:
        query = {"start_time": int(start), "bucket_width": "1d", "limit": 180, **({"page": page} if page else {})}
        request = urllib.request.Request(f"{COSTS_URL}?{urllib.parse.urlencode(query)}",
                                         headers={"Authorization": f"Bearer {key}"})
        with urllib.request.urlopen(request, timeout=10) as response:
            body = json.load(response)
        total += sum(float(result["amount"]["value"])
                     for bucket in body.get("data") or [] for result in bucket.get("results") or [])
        if not body.get("has_more") or not body.get("next_page"):
            return total
        page = body["next_page"]


def spend(row: dict, admin: dict, day: int | None) -> None:
    """Fill the row's spend against its credit; a monthly grant counts from its last renewal."""
    start = admin["since"]
    if day:
        start = keystate.monthly(day, keystate.monthly(day) - 32 * 86400)
    if start is None:
        return
    try:
        spent = spent_since(admin["key"], start)
    except Exception as error:  # noqa: BLE001 - one account's failed read is that row's note, not the section's loss
        row["spend_error"] = f"{type(error).__name__}: {error}"[:200]
        return
    row.update(spent=round(spent, 2), credit=admin["credit"],
               used_pct=round(100 * spent / admin["credit"]) if admin["credit"] else None)


def main() -> int:
    try:
        text = KEYS.read_text()
    except OSError as error:
        print(f"openai keys: {error}", file=sys.stderr)
        return 1
    rows, jobs = [], []
    admins = admin_lines()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0].startswith("#"):
            continue
        label = re.search(r"\blabel=(\S+)", line)
        day = re.search(r"\breset_day=(\d+)\b", line)
        day = int(day.group(1)) if day and 1 <= int(day.group(1)) <= 31 else None
        hold = keystate.held(VENDOR, parts[0])
        rows.append({
            "account": parts[1],
            "label": label.group(1) if label else None,
            "held_until": int(hold["until"]) if hold else None,
            "why": hold.get("why") if hold else None,
            "renews_at": int(keystate.monthly(day)) if day else None,
        })
        if parts[1] in admins:
            jobs.append((rows[-1], admins[parts[1]], day))
    if jobs:
        with ThreadPoolExecutor(len(jobs)) as pool:
            list(pool.map(lambda job: spend(*job), jobs))
    print(json.dumps({"as_of": int(time.time()), "accounts": rows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
