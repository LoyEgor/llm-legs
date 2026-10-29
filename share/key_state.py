"""The API-key state llm-legs shares with the dictation daemon: holds and balance readings in one JSON file.

transcriptions-gpt owns the module (transcriber/keystate.py) and runs without llm-legs, so the dependency runs one
way: this is the one place llm-legs imports it, from that checkout ($TRANSCRIPTIONS_GPT_DIR), never a copy.
"""
from __future__ import annotations

import os
import sys

sys.path.append(os.environ.get("TRANSCRIPTIONS_GPT_DIR") or "/Volumes/Work/Projects/transcriptions-gpt")
from transcriber import keystate  # noqa: E402,F401
