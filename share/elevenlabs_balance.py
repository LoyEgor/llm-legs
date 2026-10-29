#!/usr/bin/env python3
"""Monthly credit balance of every ElevenLabs key that may read its subscription, as one JSON line.

The menubar's ElevenLabs rows: `name` is the key line's `label=` (the account name otherwise), `reserve`
its `reserve=` floor. Readings live in the shared key state (share/key_state.py): a key held with a known end,
or read less than READING_FRESH_S ago, is not asked again, and every read is written there. A key without the
read permission is skipped; any other failure is that key's row alone, its last reading plus `error`. A held
key's row carries `held_until` and `why`. `--sync` first runs elevenlabs_keys_sync in this process (a writing poll).
"""
from __future__ import annotations

import contextlib
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor

from elevenlabs_media import READING_FRESH_S, VENDOR, Client, Fail, accounts, keystate, labels, reserves


def due(key: str) -> bool:
    """A quota hold set without a reading leaves its reset unknown: that key is read for it."""
    found, hold = keystate.entry(VENDOR, key), keystate.held(VENDOR, key)
    if hold and (hold.get("why") != keystate.QUOTA or found.get("reset_at")):
        return False
    return time.time() - found.get("as_of", 0) >= READING_FRESH_S


def row(account: str, key: str, name: str, reserve: int, error: str | None) -> dict:
    found = keystate.entry(VENDOR, key)
    left, limit = found.get("left"), found.get("limit")
    out = {
        "account": account,
        "name": name,
        "used": limit - left if left is not None and limit is not None else None,
        "limit": limit,
        "reserve": reserve,
        "resets_at": int(found["reset_at"]) if found.get("reset_at") else None,
        "as_of": int(found["as_of"]) if found.get("as_of") else None,
    }
    hold = keystate.held(VENDOR, key)
    if hold:
        out.update(held_until=int(hold["until"]), why=hold.get("why"))
    if error:
        out["error"] = error
    return out


def main() -> int:
    try:
        keys, floors, names = accounts(), reserves(), labels()
    except Fail as error:
        print(error, file=sys.stderr)
        return 1

    def read(account: str):
        if not due(keys[account]):
            return None
        try:
            Client(account, keys[account], names.get(account)).subscription(timeout=10)
        except Fail as error:
            return error
        except ValueError as error:
            return Fail(1, f"account {account}: unreadable subscription ({error})")
        return None

    with ThreadPoolExecutor(max_workers=max(1, len(keys))) as pool:
        failed = list(pool.map(read, keys))
    rows = []
    for account, error in zip(keys, failed):
        if error and error.status == "missing_permissions":
            continue
        if error:
            print(error, file=sys.stderr)
        rows.append(row(account, keys[account], names.get(account, account), floors.get(account, 0),
                        error.message if error else None))
    print(json.dumps({"as_of": int(time.time()), "accounts": rows}))
    return 0


if __name__ == "__main__":
    if "--sync" in sys.argv[1:]:
        import elevenlabs_keys_sync
        with contextlib.suppress(Exception):
            elevenlabs_keys_sync.main()
    sys.exit(main())
