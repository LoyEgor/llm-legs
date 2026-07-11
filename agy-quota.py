#!/usr/bin/env python3
"""Fetch Antigravity quota through agy's authenticated localhost Connect RPC."""

from __future__ import annotations

import fcntl
import http.client
import json
import os
import pty
import re
import select
import signal
import ssl
import struct
import subprocess
import sys
import termios
import time
from typing import Any


AGY = os.path.expanduser(os.environ.get("AGY_BIN", "~/.local/bin/agy"))
WORKDIR = os.path.expanduser(
    os.environ.get("AGY_WORKDIR", os.path.dirname(os.path.abspath(__file__)))
)
STARTUP_TIMEOUT = float(os.environ.get("AGY_QUOTA_STARTUP_TIMEOUT", "30"))
RPC_TIMEOUT = float(os.environ.get("AGY_QUOTA_RPC_TIMEOUT", "12"))
RPC_PATH = (
    "/exa.language_server_pb.LanguageServerService/"
    "RetrieveUserQuotaSummary"
)

ANSI = re.compile(
    rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
    rb"|\x1bP.*?\x1b\\"
    rb"|\x1b\[[0-?]*[ -/]*[@-~]"
    rb"|\x1b[@-_]",
    re.S,
)


def clean_terminal(data: bytes) -> str:
    return ANSI.sub(b"", data).decode("utf-8", "replace").replace("\r", "\n")


def listening_ports(pid: int) -> list[int]:
    result = subprocess.run(
        ["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"],
        text=True,
        capture_output=True,
        timeout=2,
        check=False,
    )
    return sorted({
        int(value)
        for value in re.findall(r"127\.0\.0\.1:(\d+)", result.stdout)
    })


def call_rpc(port: int, use_tls: bool) -> tuple[dict[str, Any] | None, str | None]:
    if use_tls:
        connection: http.client.HTTPConnection = http.client.HTTPSConnection(
            "127.0.0.1",
            port,
            timeout=RPC_TIMEOUT,
            context=ssl._create_unverified_context(),
        )
    else:
        connection = http.client.HTTPConnection(
            "127.0.0.1", port, timeout=RPC_TIMEOUT
        )

    body = json.dumps({"request": {}, "forceRefresh": True})
    try:
        connection.request(
            "POST",
            RPC_PATH,
            body=body,
            headers={
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            },
        )
        response = connection.getresponse()
        payload = response.read()
    finally:
        connection.close()

    if response.status != 200:
        detail = payload.decode("utf-8", "replace")[:300]
        return None, f"HTTP {response.status}: {detail}"

    decoded = json.loads(payload)
    quota = decoded.get("response")
    if not isinstance(quota, dict) or not isinstance(quota.get("groups"), list):
        return None, "unexpected RetrieveUserQuotaSummary response"
    return quota, None


def terminate(pid: int, master_fd: int) -> None:
    for data in (b"\x1b", b"\x03"):
        try:
            os.write(master_fd, data)
            time.sleep(0.15)
        except OSError:
            break

    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except (ProcessLookupError, PermissionError):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        time.sleep(0.25)

    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass


def fetch() -> dict[str, Any]:
    if not os.path.isfile(AGY) or not os.access(AGY, os.X_OK):
        raise RuntimeError(f"agy executable not found: {AGY}")
    if not os.path.isdir(WORKDIR):
        raise RuntimeError(f"AGY_WORKDIR does not exist: {WORKDIR}")

    pid, master_fd = pty.fork()
    if pid == 0:
        os.chdir(WORKDIR)
        os.environ.update({
            "TERM": "xterm-256color",
            "COLUMNS": "120",
            "LINES": "40",
            "LANG": "en_US.UTF-8",
        })
        os.execv(AGY, [AGY])

    fcntl.ioctl(
        master_fd,
        termios.TIOCSWINSZ,
        struct.pack("HHHH", 40, 120, 0, 0),
    )
    transcript = bytearray()
    deadline = time.monotonic() + STARTUP_TIMEOUT

    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master_fd], [], [], 0.25)
            if readable:
                try:
                    chunk = os.read(master_fd, 65536)
                except OSError as error:
                    raise RuntimeError(f"agy exited during startup: {error}") from error
                if not chunk:
                    raise RuntimeError("agy exited during startup")
                transcript += chunk
                transcript = transcript[-1_000_000:]

                screen = clean_terminal(transcript)
                if "Do you trust the contents" in screen:
                    raise RuntimeError(
                        f"agy workdir is not trusted: {WORKDIR}; open agy there once manually"
                    )
                if "? for shortcuts" in screen:
                    break
        else:
            raise TimeoutError("agy startup timed out")

        ports_deadline = time.monotonic() + 5
        ports: list[int] = []
        while time.monotonic() < ports_deadline:
            ports = listening_ports(pid)
            if ports:
                break
            time.sleep(0.2)
        if not ports:
            raise RuntimeError("agy opened no localhost listeners")

        errors: list[str] = []
        for port in ports:
            for use_tls in (False, True):
                try:
                    quota, error = call_rpc(port, use_tls)
                except Exception as exc:  # Probe the other protocol/port.
                    errors.append(f"{port} tls={use_tls}: {exc}")
                    continue
                if quota is not None:
                    return quota
                errors.append(f"{port} tls={use_tls}: {error}")

        raise RuntimeError("; ".join(errors))
    finally:
        terminate(pid, master_fd)


def main() -> int:
    try:
        print(json.dumps(fetch(), ensure_ascii=False, separators=(",", ":")))
        return 0
    except Exception as exc:
        print(
            json.dumps({"error": str(exc), "source": "agy-local-rpc"}),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
