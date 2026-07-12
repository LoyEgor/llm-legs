#!/usr/bin/env python3
"""Read live Codex rate limits via `codex app-server` (account/rateLimits/read, zero token spend)."""

from __future__ import annotations

import glob
import json
import os
import select
import shutil
import subprocess
import sys
import time

TIMEOUT = float(os.environ.get("CODEX_QUOTA_TIMEOUT", "30"))


def version_key(path: str) -> tuple[int, ...]:
    version = os.path.basename(os.path.dirname(os.path.dirname(path)))
    return tuple(int(part) if part.isdigit() else -1 for part in version.lstrip("v").split("."))


def resolve_codex() -> str:
    configured = os.environ.get("CODEX_BIN", "codex")
    resolved = shutil.which(configured)
    if resolved:
        return resolved
    if os.path.sep in configured:
        return configured

    home = os.path.expanduser("~")
    nvm_matches = glob.glob(os.path.join(home, ".nvm/versions/node/*/bin/codex"))
    candidates = sorted(nvm_matches, key=version_key, reverse=True)
    candidates.extend([
        os.path.join(home, ".local/bin/codex"),
        "/opt/homebrew/bin/codex",
    ])
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.abspath(candidate)
    return configured


def fetch() -> dict:
    proc = subprocess.Popen(
        [resolve_codex(), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    try:
        requests = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "llm-limits",
                        "title": "llm-limits",
                        "version": "1.0",
                    }
                },
            },
            {"jsonrpc": "2.0", "method": "initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}},
        ]
        proc.stdin.write(("\n".join(json.dumps(r) for r in requests) + "\n").encode())
        proc.stdin.flush()

        deadline = time.monotonic() + TIMEOUT
        buffer = b""
        fd = proc.stdout.fileno()
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.25)
            if not readable:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                raise RuntimeError("codex app-server exited before replying")
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") != 2:
                    continue
                if "error" in message:
                    raise RuntimeError(f"rateLimits/read failed: {message['error']}")
                result = message.get("result") or {}
                snapshot = result.get("rateLimits")
                if not isinstance(snapshot, dict) or not isinstance(snapshot.get("primary"), dict):
                    raise RuntimeError("unexpected rateLimits payload")
                return result
        raise TimeoutError("codex app-server timed out")
    finally:
        proc.kill()
        proc.wait()


def main() -> int:
    try:
        print(json.dumps(fetch(), ensure_ascii=False, separators=(",", ":")))
        return 0
    except Exception as exc:
        print(json.dumps({"error": str(exc), "source": "codex-app-server"}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
