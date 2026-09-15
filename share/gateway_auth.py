"""Resolve gateway targets and project access tokens without sharing refresh secrets."""

import base64
import fcntl
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import time

import codex_appserver

ACCOUNT_RE = re.compile(r"[a-z0-9][a-z0-9._-]*\Z")

# Renew ahead of expiry so a streaming answer can finish with the previous access token.
EXPIRY_MARGIN = 900

READY = "ready"
EXPIRED = "expired"
REFRESH = "refresh needed"
MALFORMED = "malformed"
MISSING = "login needed"


class Account:
    def __init__(self, name, source, status, detail="", account_id="", expires_at=None):
        self.name = name
        self.source = source
        self.status = status
        self.detail = detail
        self.account_id = account_id
        self.expires_at = expires_at

    @property
    def ready(self):
        return self.status in (READY, REFRESH)

    def as_dict(self):
        return {"account": self.name, "source": self.source, "status": self.status,
                "detail": self.detail, "expires_at": self.expires_at}


def codex_profiles_dir():
    return os.environ.get("CODEXB_PROFILES_DIR") or os.path.expanduser("~/.codex-profiles")


def codex_home_main():
    return os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")


def gateway_home():
    return os.environ.get("CLAUDEGPT_HOME") or os.path.expanduser("~/.local/share/claudegpt")


def gateway_accounts_dir(home=None):
    return os.path.join(home or gateway_home(), "accounts")


def main_removed():
    """`codexb remove main` writes a marker instead of deleting the real `~/.codex`.

    share/codex-accounts.sh owns the spelling; a second one leaves a removal only one
    of the two tools can see.
    """
    cache = os.environ.get("LLM_LIMITS_CODEX_CACHE") or os.path.expanduser("~/.llm-limits-codex.json")
    marker = os.environ.get("LLM_LIMITS_CODEX_REMOVED") or cache + ".removed"
    return os.path.exists(marker)


def codex_auth_path(name):
    if name == "main":
        return os.path.join(codex_home_main(), "auth.json")
    return os.path.join(codex_profiles_dir(), name, "auth.json")


def gateway_auth_files(name, home=None):
    directory = os.path.join(gateway_accounts_dir(home), name, "auth")
    try:
        return sorted(str(p) for p in Path(directory).glob("*.json"))
    except OSError:
        return []


def _jwt_expiry(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None
    expiry = claims.get("exp") if isinstance(claims, dict) else None
    return int(expiry) if (isinstance(expiry, (int, float)) and not isinstance(expiry, bool)
                          and math.isfinite(expiry) and 0 < expiry < 253402300799) else None


def _jwt_email(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return ""
    if not isinstance(claims, dict):
        return ""
    for key in ("email", "preferred_username"):
        value = claims.get(key)
        if isinstance(value, str) and value:
            return value
    profile = claims.get("https://api.openai.com/profile")
    if isinstance(profile, dict) and isinstance(profile.get("email"), str):
        return profile["email"]
    return ""


def read_codex_auth(name):
    """The canonical login's usable parts, or a status explaining why there are none.

    Returns (payload, status, detail); refreshable tokens stay resolvable without I/O.
    """
    path = codex_auth_path(name)
    try:
        with open(path, "rb") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None, MISSING, "no codex profile"
    except (OSError, ValueError):
        return None, MALFORMED, f"unreadable codex auth: {path}"
    if not isinstance(data, dict):
        return None, MALFORMED, f"unexpected codex auth shape: {path}"
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        return None, MALFORMED, f"codex auth carries no tokens: {path}"
    access = tokens.get("access_token") or ""
    account_id = tokens.get("account_id") or ""
    if not isinstance(access, str) or not access:
        return None, MISSING, f"codex auth carries no access token: {path}"
    if not isinstance(account_id, str) or not account_id:
        return None, MALFORMED, f"codex auth names no account_id: {path}"
    expiry = _jwt_expiry(access)
    if expiry is None:
        return None, MALFORMED, "codex access token has no readable expiry"
    payload = {
        "type": "codex",
        "access_token": access,
        "account_id": account_id,
        "email": _jwt_email(tokens.get("id_token") or ""),
        "last_refresh": data.get("last_refresh") or "",
    }
    if expiry is not None:
        payload["expired"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expiry))
    if expiry <= time.time() + EXPIRY_MARGIN:
        if isinstance(tokens.get("refresh_token"), str) and tokens["refresh_token"]:
            return payload, REFRESH, "Codex will renew its saved login at launch"
        return None, EXPIRED, "saved access token expired and has no renewal credential"
    return payload, READY, ""


def _gateway_record(name, home=None):
    files = gateway_auth_files(name, home)
    if not files:
        return None
    if len(files) != 1:
        raise ValueError("gateway profile must contain exactly one login")
    try:
        data = json.loads(Path(files[0]).read_text())
    except (OSError, ValueError):
        raise ValueError("unreadable gateway login") from None
    if not isinstance(data, dict) or data.get("type") != "codex" or not all(
            isinstance(data.get(key), str) and data[key] for key in ("account_id", "access_token")):
        raise ValueError("malformed gateway login")
    return data


def resolve(name, home=None):
    if not ACCOUNT_RE.fullmatch(name or ""):
        return Account(name, "", MALFORMED, "invalid account name")
    try:
        gateway = _gateway_record(name, home)
    except ValueError as error:
        return Account(name, "", MALFORMED, str(error))
    canonical = Path(codex_auth_path(name))
    if canonical.exists() and not (name == "main" and main_removed()):
        payload, status, detail = read_codex_auth(name)
        if not payload:
            return Account(name, "codex", status, detail)
        if gateway and gateway["account_id"] != payload["account_id"]:
            return Account(name, "", MALFORMED,
                           "Codex and gateway identities differ; refusing to select another account")
        return Account(name, "codex", status, detail, payload["account_id"], payload.get("expired"))
    if gateway:
        return Account(name, "gateway", READY, "", gateway["account_id"])
    return Account(name, "", MISSING, "no saved OpenAI authorization for this account")


def prepare(name, home=None, expected_id=None):
    account = resolve(name, home)
    if expected_id and account.account_id != expected_id:
        raise ValueError("saved account identity changed; refusing to switch a running chat")
    if not account.ready:
        raise ValueError(f"{name}: {account.status}: {account.detail}")
    if account.status != REFRESH:
        return account
    # Serialize gateway requests; Codex itself reloads and refreshes the canonical login.
    directory = Path(codex_auth_path(name)).parent
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(directory / ".gateway-refresh.lock", flags, 0o600)
    with os.fdopen(fd, "a") as lock:
        deadline = time.monotonic() + 35
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError("Codex authorization renewal is busy; retry shortly")
                time.sleep(0.05)
        current = resolve(name, home)
        if current.account_id != account.account_id or not current.ready:
            raise ValueError("saved authorization changed during renewal")
        if current.status == REFRESH:
            try:
                codex_appserver.call(str(directory), "account/read", {"refreshToken": True}, 30)
            except (OSError, RuntimeError, TimeoutError):
                raise ValueError("Codex could not renew its saved authorization; no browser login was started") from None
        current = resolve(name, home)
        if current.status != READY or current.account_id != account.account_id:
            raise ValueError("Codex renewal did not produce a fresh token for the same account")
        return current


def roster(home=None):
    """Every selectable target: the Codex profiles plus gateway-only leftovers."""
    names = set()
    if not main_removed() and os.path.exists(codex_auth_path("main")):
        names.add("main")
    for directory in (codex_profiles_dir(), gateway_accounts_dir(home)):
        try:
            entries = os.listdir(directory)
        except OSError:
            continue
        for entry in entries:
            if ACCOUNT_RE.match(entry) and os.path.isdir(os.path.join(directory, entry)):
                names.add(entry)
    return [resolve(name, home) for name in sorted(names)]


def is_gateway_account(name, home=None):
    return resolve(name, home).ready


def account_names(home=None):
    return [account.name for account in roster(home) if account.ready]


def project(name, destination, home=None, expected_id=None):
    """Write the access-token-only auth one run may use, and return its path.

    Atomic and owner-only: the bridge watches this directory, and a half-written file
    would be loaded as a malformed account. The projection deliberately carries no
    `refresh_token` and no `id_token` — that is what stops the bridge from rotating a
    secret the Codex CLI owns.
    """
    account = resolve(name, home)
    if account.status != READY:
        raise ValueError(f"{name}: {account.status}" + (f" ({account.detail})" if account.detail else ""))
    if account.source != "codex":
        raise ValueError(f"{name}: has its own gateway login; nothing to project")
    payload, status, detail = read_codex_auth(name)
    if not payload or status != READY:
        raise ValueError(f"{name}: {status}" + (f" ({detail})" if detail else ""))
    if payload["account_id"] != account.account_id or (expected_id and payload["account_id"] != expected_id):
        raise ValueError("saved account identity changed during projection")
    target = Path(destination)
    target.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(target, 0o700)
    final = target / f"codex-{name}.json"
    handle, temporary = tempfile.mkstemp(prefix=f".{name}-", dir=target)
    try:
        with os.fdopen(handle, "w") as stream:
            json.dump(payload, stream)
        os.replace(temporary, final)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return str(final)


def projection_is_current(name, path, home=None):
    """Compare the lease with the canonical token, without refreshing it."""
    payload, _status, _detail = read_codex_auth(name)
    if not payload:
        return False
    try:
        with open(path, "rb") as stream:
            current = json.load(stream)
    except (OSError, ValueError):
        return False
    return (current.get("access_token") == payload["access_token"]
            and current.get("account_id") == payload["account_id"])


def _cli(argv):
    if not argv:
        print("usage: gateway_auth.py list [--json] | ready <account> | project <account> <dir>",
              file=sys.stderr)
        return 2
    command, rest = argv[0], argv[1:]
    if command == "list":
        accounts = roster()
        if "--json" in rest:
            print(json.dumps([a.as_dict() for a in accounts]))
        else:
            for account in accounts:
                suffix = f" ({account.detail})" if account.detail else ""
                source = f" [{account.source}]" if account.source else ""
                print(f"{account.name}: {account.status}{source}{suffix}")
        return 0
    if command == "ready" and len(rest) == 1:
        account = resolve(rest[0])
        suffix = f" ({account.detail})" if account.detail else ""
        print(f"{account.status}{suffix}")
        return 0 if account.ready else 1
    if command == "names":
        for name in account_names():
            print(name)
        return 0
    if command == "project" and len(rest) == 2:
        try:
            print(project(rest[0], rest[1]))
        except ValueError as error:
            print(str(error), file=sys.stderr)
            return 1
        return 0
    print("usage: gateway_auth.py list [--json] | ready <account> | project <account> <dir>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
