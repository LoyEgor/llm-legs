#!/usr/bin/env python3
"""Fetch Antigravity quota from agy's print-mode `/usage` command."""

from __future__ import annotations

import json
import os
import selectors
import signal
import subprocess
import sys
import time
from typing import Any


AGY = os.path.expanduser(os.environ.get("AGY_BIN", "~/.local/bin/agy"))
WORKDIR = os.path.expanduser(
    os.environ.get("AGY_WORKDIR", os.path.dirname(os.path.abspath(__file__)))
)
TIMEOUT = float(os.environ.get("AGY_QUOTA_TIMEOUT", "45"))
SOURCE = "agy-print-usage"
AUTH_EXIT = 2
AUTH_STDERR_MARKER = "Authentication required"


class AuthRequired(Exception):
    pass


def first_line(text: str) -> str:
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line
    return ""


def kill_group(process: subprocess.Popen[bytes]) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            try:
                process.send_signal(sig)
            except (ProcessLookupError, ValueError):
                pass
        try:
            process.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            continue


def run_usage() -> tuple[str, str]:
    if not os.path.isfile(AGY) or not os.access(AGY, os.X_OK):
        raise RuntimeError(f"agy executable not found: {AGY}")
    if not os.path.isdir(WORKDIR):
        raise RuntimeError(f"AGY_WORKDIR does not exist: {WORKDIR}")

    env = dict(os.environ)
    # A logged-out leg tries to open the OAuth page in the user's real browser.
    env["BROWSER"] = "/usr/bin/true"
    env["ANTIGRAVITY_BROWSER"] = "/usr/bin/true"

    with open(os.devnull, "rb") as devnull:
        process = subprocess.Popen(
            [AGY, "-p", "/usage", "--output-format", "json"],
            cwd=WORKDIR,
            env=env,
            stdin=devnull,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )

    out = bytearray()
    err = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, out)
    selector.register(process.stderr, selectors.EVENT_READ, err)
    deadline = time.monotonic() + TIMEOUT
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"agy /usage timed out after {TIMEOUT:g}s")
            for key, _ in selector.select(min(remaining, 0.5)):
                chunk = key.fileobj.read1(65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                key.data.extend(chunk)
            if AUTH_STDERR_MARKER in err.decode("utf-8", "replace"):
                raise AuthRequired(
                    first_line(err.decode("utf-8", "replace")) or AUTH_STDERR_MARKER
                )
        remaining = deadline - time.monotonic()
        try:
            process.wait(timeout=max(remaining, 0))
        except subprocess.TimeoutExpired:
            raise TimeoutError(f"agy /usage timed out after {TIMEOUT:g}s") from None
    finally:
        selector.close()
        if process.poll() is None:
            kill_group(process)
        for stream in (process.stdout, process.stderr):
            stream.close()

    stdout = out.decode("utf-8", "replace")
    stderr = err.decode("utf-8", "replace")
    if process.returncode != 0:
        detail = first_line(stderr) or first_line(stdout) or "no output"
        raise RuntimeError(f"agy exited with status {process.returncode}: {detail}")
    return stdout, stderr


def parse_payload(stdout: str) -> dict[str, Any]:
    candidates = [stdout.strip()]
    candidates += [line for line in reversed(stdout.splitlines()) if line.strip()]
    for candidate in candidates:
        try:
            decoded = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(decoded, dict):
            return decoded
    raise RuntimeError(f"agy /usage output is not JSON: {stdout.strip()[:200] or 'empty'}")


def convert(data: dict[str, Any]) -> dict[str, Any]:
    groups = []
    for group in data.get("groups") or []:
        if not isinstance(group, dict):
            continue
        buckets = [
            {
                "window": bucket.get("window"),
                "remainingFraction": bucket.get("remaining_fraction"),
                "resetTime": bucket.get("reset_time"),
                "name": bucket.get("name"),
            }
            for bucket in group.get("buckets") or []
            if isinstance(bucket, dict)
        ]
        groups.append({
            "displayName": group.get("name"),
            "description": group.get("description"),
            "buckets": buckets,
        })

    def usable(group: dict[str, Any]) -> bool:
        windows = {
            bucket["window"]: bucket["remainingFraction"]
            for bucket in group["buckets"]
        }
        return all(
            isinstance(windows.get(window), (int, float))
            and not isinstance(windows.get(window), bool)
            for window in ("5h", "weekly")
        )

    if not any(
        "gemini" in (group["displayName"] or "").lower() and usable(group)
        for group in groups
    ):
        raise RuntimeError("unexpected /usage response: no Gemini group with 5h and weekly fractions")

    return {"description": data.get("description"), "groups": groups}


def fetch() -> dict[str, Any]:
    stdout, stderr = run_usage()
    payload = parse_payload(stdout)
    if payload.get("status") == "ERROR":
        error = str(payload.get("error") or "agy reported an error")
        if "authentication" in error.lower():
            raise AuthRequired(first_line(stderr) or error)
        raise RuntimeError(error)
    command = payload.get("command")
    data = command.get("data") if isinstance(command, dict) else None
    if not isinstance(data, dict):
        raise RuntimeError("unexpected /usage response: no command payload")
    return convert(data)


def main() -> int:
    try:
        print(json.dumps(fetch(), ensure_ascii=False, separators=(",", ":")))
        return 0
    except AuthRequired as exc:
        print(
            json.dumps(
                {"auth_needed": True, "source": SOURCE, "detail": str(exc)},
                separators=(",", ":"),
            )
        )
        return AUTH_EXIT
    except Exception as exc:
        print(json.dumps({"error": str(exc), "source": SOURCE}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
