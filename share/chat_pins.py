"""The chats Egor pinned: the one owner of the pin list, oldest pin first.

Egor 2026-11-08: a pinned chat that is open behaves like any other; a closed one sits at the very top
of the list. Which chats are open is not this module's question (`chat_names.live_sessions`); it only
keeps which ones he pinned and in what order.

One small JSON file beside the chat-name cache (`chat_names.cache_path`), `CHAT_PINS_FILE` for tests:
`{"version": 1, "pins": ["<session id>", ...]}`. Every change is a read-modify-write under an
exclusive lock on `<file>.lock`, landed by rename, so two pickers pinning at once both keep their pin
and a reader never sees half a file. Consumers: `bin/chats`; the iPad chats app (chats-app's `share/pages/app.py`)
is meant to import it.
"""

import fcntl
import json
import os
from contextlib import contextmanager
from pathlib import Path

from chat_names import SESSION_OK, cache_path

PINS_ENV = "CHAT_PINS_FILE"
VERSION = 1


def pins_path():
    override = os.environ.get(PINS_ENV)
    return Path(override) if override else cache_path().with_name("chat-pins.json")


def _read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return []
    pins = data.get("pins") if isinstance(data, dict) and data.get("version") == VERSION else None
    if not isinstance(pins, list):
        return []
    seen = []
    for session in pins:
        if isinstance(session, str) and SESSION_OK.match(session) and session not in seen:
            seen.append(session)
    return seen


def pinned():
    """Session ids of the pinned chats, oldest pin first."""
    return _read(pins_path())


@contextmanager
def _locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(f"{path}.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def pin(session, on=True):
    """Pin (`on`) or unpin a chat by its full session id; the pins after the change.

    Pinning a pinned chat keeps its place, so re-pinning never reorders the top of the list.
    """
    session = str(session or "")
    if not SESSION_OK.match(session):
        raise ValueError("not a session id: %r" % session)
    path = pins_path()
    with _locked(path):
        pins = _read(path)
        if on and session not in pins:
            pins.append(session)
        elif not on and session in pins:
            pins.remove(session)
        else:
            return pins
        tmp = f"{path}.tmp.{os.getpid()}"
        try:
            with open(tmp, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"version": VERSION, "pins": pins}, separators=(",", ":")))
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    return pins
