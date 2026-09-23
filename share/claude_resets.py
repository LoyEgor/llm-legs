"""Claude's usage-reset consumable, the `cedar_ember` program of Claude Code's own client.

    GET  /api/oauth/usage?cedar_ember=1                          the usage body plus `cedar_ember`
    POST /api/organizations/<organizationUuid>/reset_rate_limits  {"program", "grant_id", "request_id"}

`bin/claudeb` reads the same GET for the menubar's count; the POST spends a grant, so
`bin/llm-reset-redeem` is its only caller. The token is read from the keychain and never refreshed
here — robot refresh is disabled in code.
"""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SERVICE_BASE = os.environ.get("CLAUDE_RESETS_ENDPOINT", "https://api.anthropic.com").rstrip("/")
USAGE_PATH = "/api/oauth/usage?cedar_ember=1"
RESET_PATH = "/api/organizations/{organization}/reset_rate_limits"
PROGRAM = "cedar_ember"
READ_TIMEOUT = 10.0
RESET_TIMEOUT = 25.0
# The server gates the program on this version (`ineligible_reason: "cli_version"` below its
# minimum); bin/claudeb sends the same string.
USER_AGENT = "claude-cli/2.1.280 (external, cli)"

GRANT_ID_RE = re.compile(r"^[a-z0-9_-]{1,40}$")
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class TransientError(Exception):
    """The call failed without saying anything about the account."""


class AuthError(Exception):
    """No usable token, or the server refused the one presented."""


def profile_dir(account: str) -> Path:
    return Path(os.path.expanduser("~")) / ".claude-profiles" / account


def keychain_service(account: str) -> str:
    profile = os.path.join(os.path.expanduser("~"), ".claude-profiles", account)
    return "Claude Code-credentials-" + hashlib.sha256(profile.encode("utf-8")).hexdigest()[:8]


def access_token(account: str) -> str:
    try:
        read = subprocess.run(
            ["security", "find-generic-password", "-s", keychain_service(account), "-w"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError) as exc:
        raise AuthError(f"keychain unreadable ({exc.__class__.__name__})") from None
    if read.returncode != 0:
        raise AuthError("no keychain credentials")
    try:
        token = json.loads(read.stdout.decode("utf-8", "replace"))["claudeAiOauth"]["accessToken"]
    except (ValueError, TypeError, KeyError):
        token = None
    if not isinstance(token, str) or not token:
        raise AuthError("the keychain entry carries no access token")
    return token


def organization_uuid(account: str) -> str | None:
    try:
        data = json.loads((profile_dir(account) / ".claude.json").read_text())
        value = data["oauthAccount"]["organizationUuid"]
    except (OSError, ValueError, TypeError, KeyError):
        return None
    return value if isinstance(value, str) and value else None


def _request(method: str, path: str, token: str, body: dict | None, timeout: float) -> dict:
    request = urllib.request.Request(
        SERVICE_BASE + path,
        data=None if body is None else json.dumps(body).encode("utf-8"),
        method=method,
        headers={
            "Authorization": "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": USER_AGENT,
            **({} if body is None else {"Content-Type": "application/json"}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise AuthError(f"HTTP {exc.code}") from None
        if exc.code == 429:
            raise TransientError("HTTP 429 rate limited") from None
        raise TransientError(f"HTTP {exc.code}") from None
    except urllib.error.URLError as exc:
        raise TransientError(f"network error: {exc.reason}") from None
    except (TimeoutError, OSError, http.client.HTTPException) as exc:
        raise TransientError(f"network error: {exc}") from None
    try:
        payload = json.loads(raw)
    except ValueError:
        raise TransientError("unparsable reply") from None
    if not isinstance(payload, dict):
        raise TransientError("reply is not an object")
    return payload


def read_program(token: str) -> dict | None:
    program = _request("GET", USAGE_PATH, token, None, READ_TIMEOUT).get(PROGRAM)
    return program if isinstance(program, dict) else None


def spendable(grant: object) -> bool:
    return (isinstance(grant, dict) and grant.get("paused") is not True
            and grant.get("usable_now") is True
            and isinstance(grant.get("resets_left"), int) and grant["resets_left"] >= 1
            and isinstance(grant.get("id"), str) and GRANT_ID_RE.match(grant["id"]) is not None)


def _instant(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def choose_grant(program: dict) -> dict | None:
    grants = [grant for grant in program.get("grants") or [] if spendable(grant)]
    preferred = program.get("next_grant_id")
    for grant in grants:
        if grant["id"] == preferred:
            return grant
    if not grants:
        return None
    dated = [(ends, grant) for grant in grants if (ends := _instant(grant.get("ends_at")))]
    return min(dated, key=lambda pair: pair[0])[1] if dated else grants[0]


def reset(token: str, organization: str, grant_id: str, request_id: str) -> dict:
    if not GRANT_ID_RE.match(grant_id) or not REQUEST_ID_RE.match(request_id):
        raise ValueError("grant_id or request_id is outside the shape the server accepts")
    path = RESET_PATH.format(organization=urllib.parse.quote(organization, safe=""))
    return _request("POST", path, token,
                    {"program": PROGRAM, "grant_id": grant_id, "request_id": request_id},
                    RESET_TIMEOUT)
