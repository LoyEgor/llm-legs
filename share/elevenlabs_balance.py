#!/usr/bin/env python3
"""Monthly credit balance of every ElevenLabs key that may read its subscription, as one JSON line.

The menubar's ElevenLabs rows: `name` is the key line's `label=` (the account name otherwise), `reserve`
its `reserve=` floor. A key without the read permission is skipped; any other failure exits 1 so the
collector keeps the previous reading. `--sync` first runs elevenlabs_keys_sync in this process (a writing poll).
"""
from __future__ import annotations

import contextlib
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor

from elevenlabs_media import KEYS, Client, Fail, accounts, reserves


def labels() -> dict[str, str]:
    found = {}
    for line in KEYS.read_text().splitlines():
        parts = line.split()
        match = re.search(r"\blabel=(\S+)", line)
        if len(parts) >= 2 and not parts[0].startswith("#") and match:
            found[parts[1]] = match.group(1)
    return found


def main() -> int:
    try:
        keys, floors, names = accounts(), reserves(), labels()
    except Fail as error:
        print(error, file=sys.stderr)
        return 1

    def read(item):
        try:
            return Client(*item).json("GET", "/v1/user/subscription", timeout=10)
        except Fail as error:
            return error

    with ThreadPoolExecutor(max_workers=max(1, len(keys))) as pool:
        subs = list(pool.map(read, keys.items()))
    rows = []
    for account, sub in zip(keys, subs):
        if isinstance(sub, Fail):
            if sub.status == "missing_permissions":
                continue
            print(sub, file=sys.stderr)
            return 1
        rows.append({
            "account": account,
            "name": names.get(account, account),
            "used": int(sub["character_count"]),
            "limit": int(sub["character_limit"]),
            "reserve": floors.get(account, 0),
            "resets_at": sub.get("next_character_count_reset_unix"),
        })
    print(json.dumps({"as_of": int(time.time()), "accounts": rows}))
    return 0


if __name__ == "__main__":
    if "--sync" in sys.argv[1:]:
        import elevenlabs_keys_sync
        with contextlib.suppress(Exception):
            elevenlabs_keys_sync.main()
    sys.exit(main())
