#!/usr/bin/env python3
"""Read SuperGrok weekly quota through the Grok CLI's own billing endpoint (zero spend)."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ENDPOINT = os.environ.get(
    "GROK_QUOTA_ENDPOINT", "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
)
FALLBACK_CLIENT_VERSION = "1.0.13"
BUILD_PRODUCT = "PRODUCT_GROK_BUILD"
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
ISO_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}")
_PERSISTENT_LIMIT_MARKERS = (
    "hit the credit limit for your plan",
    "hit the rate limit for your plan",
    "run out of credits",
    "subscription:free-usage-exhausted",
)

_client_version: str | None = None


class AuthError(Exception):
    """The endpoint refused the token (HTTP 401/403)."""


class PersistentLimit(Exception):
    pass


def persistent_limit(detail: str) -> bool:
    message = detail.lower()
    return any(marker in message for marker in _PERSISTENT_LIMIT_MARKERS)


def client_version() -> str:
    global _client_version
    if _client_version is not None:
        return _client_version
    pinned = os.environ.get("GROK_QUOTA_CLIENT_VERSION")
    if pinned:
        _client_version = pinned
        return _client_version
    version = FALLBACK_CLIENT_VERSION
    binary = shutil.which(os.environ.get("GROK_BIN", "grok"))
    if binary:
        try:
            probe = subprocess.run(
                [binary, "--version"], capture_output=True, text=True, timeout=10
            )
        except (OSError, subprocess.SubprocessError):
            probe = None
        if probe is not None:
            found = VERSION_RE.search((probe.stdout or "") + " " + (probe.stderr or ""))
            if found:
                version = found.group(0)
    _client_version = version
    return version


# The CLI owns auth.json: it rotates the access token minutes before expiry and serialises
# writers through auth.json.lock. This reader never writes and never refreshes — a second
# writer is the one real hazard around that file.
def auth_entry(home: Path) -> dict | None:
    try:
        raw = (home / "auth.json").read_text()
    except OSError:
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        # Without that lock a read can land mid-rotation and see a truncated document. Calling
        # that "needs_login" would drop a signed-in account out of the pool over a race.
        raise RuntimeError("unreadable auth.json") from None
    if not isinstance(data, dict):
        return None
    if isinstance(data.get("key"), str):
        return data
    for value in data.values():
        if isinstance(value, dict) and isinstance(value.get("key"), str):
            return value
    return None


def normalize_iso(value: object) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00").replace("z", "+00:00"))
    except ValueError:
        # An older interpreter's stricter parser can refuse a real timestamp, so a date-shaped
        # string is still published; anything else is not a reset instant and saying nothing
        # beats handing every limits surface a word it will render as a time.
        return text if ISO_DATE_RE.match(text) else None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def number_or_none(value: object) -> float | int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def build_percent(body: dict, config: dict) -> float | int | None:
    for source in (body.get("productUsage"), config.get("productUsage")):
        if not isinstance(source, list):
            continue
        for item in source:
            if isinstance(item, dict) and item.get("product") == BUILD_PRODUCT:
                value = number_or_none(item.get("usagePercent"))
                if value is not None:
                    return value
    return None


def fetch(entry: dict, timeout: float) -> dict:
    headers = {
        "Authorization": "Bearer " + entry["key"],
        "X-XAI-Token-Auth": "xai-grok-cli",
        "x-grok-client-version": client_version(),
        "Accept": "application/json",
        "User-Agent": "llm-legs",
    }
    user_id = entry.get("user_id")
    if isinstance(user_id, str) and user_id:
        headers["x-userid"] = user_id
    request = urllib.request.Request(ENDPOINT, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise AuthError(f"HTTP {exc.code}") from None
        if exc.code == 402:
            try:
                detail = exc.read().decode("utf-8", "replace")
            except OSError:
                detail = ""
            if persistent_limit(detail):
                raise PersistentLimit from None
        raise RuntimeError(f"HTTP {exc.code}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"network error: {exc.reason}") from None
    except (TimeoutError, OSError) as exc:
        raise RuntimeError(f"network error: {exc}") from None
    except ValueError:
        raise RuntimeError("unparsable billing payload") from None
    if not isinstance(payload, dict):
        raise RuntimeError("unparsable billing payload")
    return payload


def account_row(account: str, entry: dict, body: dict, as_of: int) -> dict:
    config = body.get("config")
    if not isinstance(config, dict):
        # Only a field missing from a well-formed config means zero. A body carrying no config at
        # all is a shape this reader does not know, and publishing 0% for it would rank a
        # possibly-exhausted account as the freest one in the pool.
        raise RuntimeError("unexpected billing payload: no config object")
    period = config.get("currentPeriod") if isinstance(config.get("currentPeriod"), dict) else {}
    # Absent means zero, not missing data: the endpoint omits the field until the pool is touched.
    used = number_or_none(config.get("creditUsagePercent"))
    row = {
        "account": account,
        "auth": "ok",
        "used_pct": 0 if used is None else used,
        "resets_at": normalize_iso(period.get("end")),
        "as_of": as_of,
    }
    window = period.get("type")
    if isinstance(window, str) and window:
        row["period"] = window
    plan = body.get("subscriptionTier")
    if isinstance(plan, str) and plan:
        row["plan_type"] = plan
    email = entry.get("email")
    if isinstance(email, str) and email:
        row["email"] = email
    build = build_percent(body, config)
    if build is not None:
        row["build_pct"] = build
    return row


def collect(account: str, home: Path, timeout: float) -> dict:
    as_of = int(time.time())
    try:
        entry = auth_entry(home)
    except RuntimeError as exc:
        return {"account": account, "error": str(exc), "as_of": as_of}
    if entry is None:
        return {"account": account, "auth": "needs_login", "as_of": as_of}
    try:
        return account_row(account, entry, fetch(entry, timeout), as_of)
    except AuthError as exc:
        refreshable = isinstance(entry.get("refresh_token"), str) and bool(entry["refresh_token"])
        return {
            "account": account,
            "auth": "expired" if refreshable else "needs_login",
            "as_of": as_of,
            "cause": f"login needed: {exc}" if not refreshable else f"token rejected: {exc}",
        }
    except PersistentLimit:
        return {
            "account": account,
            "auth": "ok",
            "used_pct": 100,
            "resets_at": None,
            "as_of": as_of,
        }
    except RuntimeError as exc:
        return {"account": account, "error": str(exc), "as_of": as_of}


def profiles(profiles_dir: Path) -> list[tuple[str, Path]]:
    found: list[tuple[str, Path]] = []
    main = Path.home() / ".grok"
    if (main / "auth.json").is_file():
        found.append(("main", main))
    if profiles_dir.is_dir():
        # `grokb` keeps its pool state in `.grokb` beside the accounts, so dotted names are
        # reserved: listing them would publish a service directory as an account. `main` names
        # ~/.grok everywhere, `grokb add` refuses it, and a hand-made directory under that name
        # can only render as a second `main` row nothing can address.
        found.extend(
            (path.name, path)
            for path in sorted(profiles_dir.iterdir())
            if path.is_dir() and not path.name.startswith(".") and path.name != "main"
        )
    return found


def resolve(name: str, profiles_dir: Path) -> Path:
    if name == "main":
        return Path.home() / ".grok"
    return profiles_dir / name


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profiles-dir", default=os.environ.get("GROKB_PROFILES_DIR", "~/.grok-profiles"))
    parser.add_argument("--account", action="append", default=[])
    parser.add_argument("--timeout", type=float, default=10.0)
    return parser.parse_args()


def main() -> int:
    args = arguments()
    profiles_dir = Path(args.profiles_dir).expanduser()
    if args.account:
        targets = [(name, resolve(name, profiles_dir)) for name in args.account]
    else:
        targets = profiles(profiles_dir)

    rows = [collect(account, home, args.timeout) for account, home in targets]
    measured = [row for row in rows if isinstance(row.get("used_pct"), (int, float))]
    verdicts = [row for row in rows if row.get("auth") in ("needs_login", "expired")]

    print(json.dumps({"accounts": rows}, ensure_ascii=False, separators=(",", ":")))
    for row in rows:
        if "error" in row:
            print(f"grok-quota.py: {row['account']}: {row['error']}", file=sys.stderr)
    if measured:
        return 0
    if verdicts:
        return 2
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
