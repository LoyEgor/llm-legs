#!/usr/bin/env python3
"""Monthly credit balance of every ElevenLabs key that may read its subscription, as one JSON line.

The menubar's ElevenLabs rows: `name` is the key line's `label=` (the account name otherwise), `reserve`
its `reserve=` floor. A key without the read permission is skipped; any other failure exits 1 so the
collector keeps the previous reading.
"""
from __future__ import annotations

import json
import re
import sys
import time

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
    rows = []
    for account, key in keys.items():
        try:
            sub = Client(account, key).json("GET", "/v1/user/subscription", timeout=10)
        except Fail as error:
            if error.rc == 4:
                continue
            print(error, file=sys.stderr)
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
    sys.exit(main())
