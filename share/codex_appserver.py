"""One JSON-RPC request over a `codex app-server` stdio session.

The vendor's own CLI is the channel, so no token is ever read, minted or refreshed here.
"""

from __future__ import annotations

import glob
import json
import os
import select
import shutil
import subprocess
import time

REQUEST_ID = 2


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
    candidates = sorted(
        glob.glob(os.path.join(home, ".nvm/versions/node/*/bin/codex")),
        key=version_key,
        reverse=True,
    )
    candidates.extend([os.path.join(home, ".local/bin/codex"), "/opt/homebrew/bin/codex"])
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.abspath(candidate)
    return configured


def call(codex_home: str | None, method: str, params: dict, timeout: float,
         label: str | None = None) -> dict:
    env = os.environ.copy()
    if codex_home is None:
        env.pop("CODEX_HOME", None)
    else:
        env["CODEX_HOME"] = codex_home
    proc = subprocess.Popen(
        [resolve_codex(), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
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
            {"jsonrpc": "2.0", "id": REQUEST_ID, "method": method, "params": params},
        ]
        assert proc.stdin is not None
        assert proc.stdout is not None
        proc.stdin.write(("\n".join(json.dumps(request) for request in requests) + "\n").encode())
        proc.stdin.flush()

        deadline = time.monotonic() + timeout
        buffer = b""
        fd = proc.stdout.fileno()
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], min(0.25, max(0, deadline - time.monotonic())))
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
                if message.get("id") != REQUEST_ID:
                    continue
                if "error" in message:
                    raise RuntimeError(f"{label or method} failed: {message['error']}")
                return message.get("result") or {}
        raise TimeoutError("codex app-server timed out")
    finally:
        proc.kill()
        proc.wait()
