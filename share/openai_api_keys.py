#!/usr/bin/env python3
"""The OpenAI API keys' menubar rows, as one JSON line: the key file and the shared key state, no network.

$OPENAI_KEYS (default ~/.config/openai/keys.txt): `<key> <account> [label=..] [reset_day=N]` per line, N the day
of the month the credit grant renews. No llm-legs code calls the OpenAI API yet, so there is no pool: a row says
whether a key-state writer (the dictation daemon) holds the key, why, and when its grant renews.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

from key_state import keystate

VENDOR = "openai"
KEYS = Path(os.environ.get("OPENAI_KEYS") or "~/.config/openai/keys.txt").expanduser()


def main() -> int:
    try:
        text = KEYS.read_text()
    except OSError as error:
        print(f"openai keys: {error}", file=sys.stderr)
        return 1
    rows = []
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
    print(json.dumps({"as_of": int(time.time()), "accounts": rows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
