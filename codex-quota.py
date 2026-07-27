#!/usr/bin/env python3
"""Read live Codex rate limits through the zero-spend app-server RPC."""

from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time


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


def fetch(codex_home: str | None, timeout: float) -> dict:
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
            {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}},
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
                if message.get("id") != 2:
                    continue
                if "error" in message:
                    raise RuntimeError(f"rateLimits/read failed: {message['error']}")
                result = message.get("result") or {}
                snapshot = result.get("rateLimits")
                buckets = [snapshot.get("primary"), snapshot.get("secondary")] if isinstance(snapshot, dict) else []
                if not any(isinstance(bucket, dict) and isinstance(bucket.get("usedPercent"), (int, float)) for bucket in buckets):
                    raise RuntimeError("unexpected rateLimits payload")
                return result
        raise TimeoutError("codex app-server timed out")
    finally:
        proc.kill()
        proc.wait()


def bucket_data(result: dict) -> tuple[dict, dict]:
    limits = result.get("rateLimits") or {}
    buckets = [bucket for bucket in (limits.get("primary"), limits.get("secondary")) if isinstance(bucket, dict)]
    five = next((bucket for bucket in buckets if (bucket.get("windowDurationMins") or 0) <= 300), None)
    if five is None:
        five = next((bucket for bucket in buckets if bucket.get("windowDurationMins") is None), None)
    weekly = next((bucket for bucket in buckets if (bucket.get("windowDurationMins") or 0) >= 10000), None)
    if weekly is None and len(buckets) > 1:
        weekly = buckets[1]

    def normalized(bucket: dict | None) -> dict:
        return {
            "used_pct": bucket.get("usedPercent") if bucket else None,
            "resets_at": bucket.get("resetsAt") if bucket else None,
        }

    return normalized(five), normalized(weekly)


# Only genuine auth signals — a dead/invalidated token or a not-logged-in session — map
# to auth-needed. Weather (429/5xx/000) and network/timeout errors deliberately match
# nothing here so they stay non-auth (see docs/DIAGNOSTICS.md 429 taxonomy). No bare digit
# markers ("401"): a count in an unrelated error must not read as Unauthorized.
_AUTH_MARKERS = (
    "token_invalidated",
    "token has been invalidated",
    "not logged in",
    "authentication required",
    "unauthorized",
    "invalid_grant",
    "please sign in",
    "sign in again",
    "please log in",
    "log in again",
)


def authentication_required(error: str | None) -> bool:
    message = (error or "").lower()
    return any(marker in message for marker in _AUTH_MARKERS)


def auth_cause(error: str | None) -> str:
    message = (error or "").lower()
    if "invalidated" in message:
        return "login needed: token invalidated"
    if "not logged in" in message:
        return "login needed: not logged in"
    if "authentication required" in message:
        return "login needed: authentication required"
    if "unauthorized" in message:
        return "login needed: unauthorized"
    return "login needed"


def account_entry(account: str, result: dict | None, as_of: int, error: str | None = None) -> dict:
    if authentication_required(error):
        return {"account": account, "auth_needed": True, "as_of": as_of, "cause": auth_cause(error)}

    five, weekly = bucket_data(result or {})
    limits = (result or {}).get("rateLimits")
    if not isinstance(limits, dict):
        limits = {}
    entry = {
        "account": account,
        "plan_type": limits.get("planType"),
        "five_hour": five,
        "weekly": weekly,
        "as_of": as_of,
    }
    reset_credits = (result or {}).get("rateLimitResetCredits")
    if isinstance(reset_credits, dict):
        available = reset_credits.get("availableCount")
        if isinstance(available, (int, float)) and not isinstance(available, bool):
            entry["reset_credits"] = available
    if error:
        entry["error"] = error
    return entry


def profile_accounts(home: Path) -> list[tuple[str, str | None]]:
    profiles = home / ".codex-profiles"
    accounts: list[tuple[str, str | None]] = [("main", None)]
    if profiles.is_dir():
        # `codexb` keeps its own pool state in `.codexb` alongside the accounts, and dotted
        # names are reserved from being accounts for exactly that reason. Listing them anyway
        # publishes a service directory as an account that the user is then told to log in to.
        accounts.extend(
            (path.name, str(path)) for path in sorted(profiles.iterdir())
            if path.is_dir() and not path.name.startswith(".")
        )
    return accounts


def parse_target(value: str | None, home: Path) -> tuple[str, str | None]:
    if value is None or value == "main":
        return "main", None
    expanded = Path(value).expanduser()
    if os.path.sep in value or expanded.is_absolute() or expanded.exists():
        return expanded.name, str(expanded)
    return value, str(home / ".codex-profiles" / value)


def read_cache(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def write_cache(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f"{path.name}.tmp.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def cache_payload(
    results: list[tuple[str, dict | None, int, str | None]],
    old: dict,
    replace_accounts: bool,
    current: str,
) -> dict:
    def has_usage(entry: dict) -> bool:
        return any(
            isinstance(bucket, dict)
            and isinstance(bucket.get("used_pct"), (int, float))
            and not isinstance(bucket.get("used_pct"), bool)
            for bucket in (entry.get("five_hour"), entry.get("weekly"))
        )

    current_result = next((result for account, result, _, _ in results if account == current and result), None)
    base = dict(current_result) if current_result else {key: value for key, value in old.items() if key not in ("accounts", "current")}
    old_by_name = {entry.get("account"): entry for entry in old.get("accounts", []) if isinstance(entry, dict)}
    refreshed = []
    for account, result, as_of, error in results:
        entry = account_entry(account, result, as_of, error)
        if result is None and not authentication_required(error):
            prior = old_by_name.get(account)
            if isinstance(prior, dict) and (prior.get("auth_needed") is True or has_usage(prior)):
                entry = prior
        refreshed.append(entry)
    if replace_accounts:
        accounts = refreshed
    else:
        names = {entry["account"] for entry in refreshed}
        retained = [
            entry
            for entry in old.get("accounts", [])
            if isinstance(entry, dict) and entry.get("account") not in names
        ]
        accounts = refreshed + retained
    base["accounts"] = accounts
    base["current"] = current
    return base


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--codex-home")
    target.add_argument("--profile")
    target.add_argument("--all-accounts", action="store_true")
    parser.add_argument("home", nargs="?")
    parser.add_argument("--cache", default=os.environ.get("LLM_LIMITS_CODEX_CACHE", "~/.llm-limits-codex.json"))
    parser.add_argument("--no-cache", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = arguments()
    home = Path.home()
    timeout = float(os.environ.get("CODEX_QUOTA_TIMEOUT", "30"))
    cache = Path(args.cache).expanduser()
    if args.all_accounts and args.home:
        print("codex-quota.py: --all-accounts does not accept a profile/home", file=sys.stderr)
        return 2
    if args.home and (args.codex_home or args.profile):
        print("codex-quota.py: profile/home may be provided only once", file=sys.stderr)
        return 2

    if args.all_accounts:
        targets = profile_accounts(home)
    elif args.codex_home:
        targets = [(Path(args.codex_home).expanduser().name, str(Path(args.codex_home).expanduser()))]
    elif args.profile or args.home:
        targets = [parse_target(args.profile or args.home, home)]
    elif os.environ.get("CODEX_HOME"):
        configured_home = str(Path(os.environ["CODEX_HOME"]).expanduser())
        targets = [(Path(configured_home).name, configured_home)]
    else:
        targets = [("main", None)]

    results: list[tuple[str, dict | None, int, str | None]] = []
    for account, codex_home in targets:
        as_of = int(time.time())
        try:
            results.append((account, fetch(codex_home, timeout), as_of, None))
        except Exception as exc:
            results.append((account, None, as_of, str(exc)))

    current = "main" if args.all_accounts else targets[0][0]
    payload = cache_payload(results, read_cache(cache), args.all_accounts, current)
    has_auth_marker = any(authentication_required(error) for _, _, _, error in results)
    if not args.no_cache and (any(result for _, result, _, _ in results) or (args.all_accounts and has_auth_marker)):
        write_cache(cache, payload)

    if args.all_accounts:
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        return 0 if any(result for _, result, _, _ in results) else 1

    account, result, _, error = results[0]
    if result is None:
        # The raw RPC blob is for the log (stderr) only; the auth verdict carried on
        # stdout uses a short cause so no unparsed blob reaches a user-visible field.
        print(json.dumps({"error": error, "source": "codex-app-server", "account": account}), file=sys.stderr)
        if authentication_required(error):
            auth = {"auth_needed": True, "cause": auth_cause(error),
                    "accounts": payload["accounts"], "current": account}
            print(json.dumps(auth, ensure_ascii=False, separators=(",", ":")))
            return 2
        return 1
    output = dict(result)
    output["accounts"] = payload["accounts"]
    output["current"] = account
    print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
