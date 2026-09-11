#!/usr/bin/env python3
"""Resolve fresh launches and transcript resumes for every chat surface.

Resume preserves the source account and model; switch follows the chosen target
kind. Library callers without an explicit kind use account-store discovery.
"""

import argparse
import os
import re
import sys

GATEWAY_PREFIX = "anthropic.ccr."
# The launcher's two aliases and the label a model column shows for them; bin/statusline.sh
# carries the same pair (docs/shared-invariants.md row `cc`).
GATEWAY_LABELS = {"sol": "Sol", "astra": "Astra"}
STAMP_VERSION = "v1"
# A chat is reopened months after it was launched, so the stamp is not a cache: it is the
# only record of which gateway account a transcript belongs to.
STAMP_DIR = "sessions"
# What stands in for the account of a gateway chat nobody stamped — every chat launched
# before stamping existed. A line carrying it is for him to complete, never to run.
UNKNOWN_ACCOUNT = "<gateway-account>"
SESSION_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# bin/claudegpt account_dir's own pattern: a name outside it never named a gateway account.
ACCOUNT_OK = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


# All three resolved per call rather than at import: a test drives these surfaces by
# moving HOME, and a path frozen when the module loaded would point at his real stores.
def gateway_home():
    return os.environ.get("CLAUDEGPT_HOME") or os.path.expanduser("~/.local/share/claudegpt")


def profiles_home():
    return os.path.expanduser("~/.claude-profiles")


def corpus_home():
    return os.path.expanduser("~/.claude/projects")


def stamp_path(session, home=None):
    if not session or not SESSION_OK.match(session):
        return None
    return os.path.join(home or gateway_home(), STAMP_DIR, session)


def read_stamp(session, home=None):
    """{"account", "model"} for a chat `claudegpt` launched, else None."""
    path = stamp_path(session, home)
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            fields = handle.readline().split()
    except OSError:
        return None
    if len(fields) < 2 or fields[0] != STAMP_VERSION or not ACCOUNT_OK.match(fields[1]):
        return None
    alias = fields[2] if len(fields) > 2 else ""
    return {"account": fields[1], "model": alias if alias in GATEWAY_LABELS else ""}


def write_stamp(session, account, model, home=None):
    """Record what this launch is, so the chat can be reopened after it is closed."""
    path = stamp_path(session, home)
    if not path or not ACCOUNT_OK.match(account or ""):
        return None
    directory = os.path.dirname(path)
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        temporary = "%s.tmp.%d" % (path, os.getpid())
        with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600),
                  "w", encoding="utf-8") as handle:
            handle.write("%s %s %s\n" % (STAMP_VERSION, account,
                                         model if model in GATEWAY_LABELS else ""))
        os.replace(temporary, path)
    except OSError:
        return None
    return path


def sweep_stamps(corpus=None, home=None):
    """Drop stamps whose transcript is gone — a chat nothing can resume cannot be reopened.

    A corpus that cannot be listed sweeps nothing: an unreadable projects directory is not
    evidence that every chat was deleted.
    """
    root = os.path.join(home or gateway_home(), STAMP_DIR)
    try:
        stamps = [name for name in os.listdir(root) if SESSION_OK.match(name)]
    except OSError:
        return 0
    if not stamps:
        return 0
    live = set()
    try:
        for project in os.scandir(corpus or corpus_home()):
            if not project.is_dir():
                continue
            for entry in os.scandir(project.path):
                if entry.name.endswith(".jsonl"):
                    live.add(entry.name[: -len(".jsonl")])
    except OSError:
        return 0
    dropped = 0
    for name in stamps:
        if name in live:
            continue
        try:
            os.unlink(os.path.join(root, name))
            dropped += 1
        except OSError:
            pass
    return dropped


def gateway_alias(model_id):
    """The launcher alias behind a transcript's model id, or None for a Claude model."""
    if not model_id or not model_id.startswith(GATEWAY_PREFIX):
        return None
    alias = model_id[len(GATEWAY_PREFIX):]
    return alias if alias in GATEWAY_LABELS else None


def model_label(model_id):
    """`Sol`/`Astra` for the gateway aliases, None for anything else."""
    alias = gateway_alias(model_id)
    return GATEWAY_LABELS[alias] if alias else None


def is_gateway_account(name):
    return bool(name) and bool(ACCOUNT_OK.match(name)) and os.path.isdir(
        os.path.join(gateway_home(), "accounts", name))


def is_claudeb_profile(name):
    # "main" names ~/.claude itself, which claudeb refuses as a profile.
    return bool(name) and name != "main" and os.path.isdir(os.path.join(profiles_home(), name))


def gateway_accounts():
    try:
        names = os.listdir(os.path.join(gateway_home(), "accounts"))
    except OSError:
        return []
    return sorted(name for name in names if ACCOUNT_OK.match(name)
                  and os.path.isdir(os.path.join(gateway_home(), "accounts", name)))


def gateway_argv(account, session, alias=None):
    argv = ["claudegpt", "p", account or UNKNOWN_ACCOUNT]
    if alias:
        argv += ["--model", alias]
    if session:
        argv += ["--resume", session]
    return argv


def claudeb_argv(account, session):
    argv = ["claudeb", "profile", account] if account else ["claude"]
    if session:
        argv += ["--resume", session]
    return argv


def is_gateway_chat(session, model_id=None):
    return bool(gateway_alias(model_id)) or read_stamp(session) is not None


def resume_argv(session, account=None, model_id=None):
    """The command that reopens chat `session` as it was launched.

    `account` is the ambient claudeb profile a Claude chat resumes under; it never
    overrides the chat's own launcher, since a gateway transcript reopened on a Claude
    account is a different conversation on a different model.
    """
    stamp = read_stamp(session)
    if stamp or gateway_alias(model_id):
        alias = gateway_alias(model_id) or (stamp or {}).get("model") or None
        return gateway_argv((stamp or {}).get("account"), session, alias)
    return claudeb_argv(account, session)


def switch_argv(session, account, model_id=None, gateway=None):
    """The command that reopens chat `session` under the account he picked.

    Which launcher that is comes from the store holding the name: `com` names both a
    claudeb profile and a gateway account, and the claudeb one keeps the name, so no
    existing switch changes meaning. `gateway=True` says the name came from a Codex row.
    """
    if gateway is None:
        gateway = not is_claudeb_profile(account) and is_gateway_account(account)
    if gateway:
        alias = gateway_alias(model_id) or (model_id if model_id in GATEWAY_LABELS else None) \
            or (read_stamp(session) or {}).get("model") or None
        return gateway_argv(account, session, alias)
    return claudeb_argv(account, session)


def launch_argv(account, gateway=False, model=None):
    if gateway:
        return gateway_argv(account, None, gateway_alias(model) or model)
    return claudeb_argv(account, None)


def shell_quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def resume_line(argv, cwd=None):
    line = " ".join(argv)
    return "cd %s && %s" % (shell_quote(cwd), line) if cwd else line


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    for mode in ("resume", "switch"):
        one = sub.add_parser(mode)
        one.add_argument("session")
        one.add_argument("--account", default=None)
        one.add_argument("--model", default=None, help="the transcript's model id")
        one.add_argument("--cwd", default=None)
        if mode == "switch":
            one.add_argument("--gateway", action="store_true",
                             help="the account names a gateway login, not a claudeb profile")
    launch = sub.add_parser("launch")
    launch.add_argument("--account", required=True)
    launch.add_argument("--gateway", action="store_true")
    launch.add_argument("--model", choices=tuple(GATEWAY_LABELS))
    args = parser.parse_args(argv)
    if args.mode == "launch":
        if args.model and not args.gateway:
            parser.error("launch --model requires --gateway")
        print(resume_line(launch_argv(args.account, args.gateway, args.model)))
        return 0
    session = args.session
    if args.mode == "switch":
        if not args.account:
            parser.error("switch needs --account")
        built = switch_argv(session, args.account, args.model,
                            gateway=args.gateway)
    else:
        built = resume_argv(session, args.account, args.model)
    print(resume_line(built, args.cwd))
    return 3 if UNKNOWN_ACCOUNT in built else 0


if __name__ == "__main__":
    sys.exit(main())
